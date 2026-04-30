-- ============================================================================
-- VIP System v2 — Migration 3/5: Funciones SQL
-- ============================================================================
-- Funciones del motor de puntos:
--   * recalculate_vip_level(uuid)
--   * add_points(...)              → otorga puntos
--   * redeem_points(...)           → canjea puntos con FIFO
--   * expire_old_points()          → cron diario
--   * start_new_season(int)        → cron 1 enero
--   * apply_participation_points(uuid) → otorga puntos a una participación
-- ============================================================================

-- ============================================================================
-- 3.1 recalculate_vip_level
-- ============================================================================

create or replace function public.recalculate_vip_level(p_user_id uuid)
returns text
language plpgsql
security definer
as $$
declare
  v_user                  record;
  v_new_level             text;
  v_locked                bool;
begin
  select
    season_points,
    season_main_tournaments,
    season_points_year_minus_1,
    season_points_year_minus_2,
    vip_level,
    vip_level_locked_until
  into v_user
  from public.users
  where id = p_user_id;

  if not found then
    return null;
  end if;

  -- Calcular nivel desde el más alto al más bajo. El primero que cumpla, gana.

  -- Icon: 250K en últimas 2 temporadas o 400K en últimas 3
  if (v_user.season_points + v_user.season_points_year_minus_1) >= 250000
     or (v_user.season_points + v_user.season_points_year_minus_1 + v_user.season_points_year_minus_2) >= 400000
  then
    v_new_level := 'icon';

  -- Black: 100K en la temporada
  elsif v_user.season_points >= 100000 then
    v_new_level := 'black';

  -- Diamond: 50K en la temporada
  elsif v_user.season_points >= 50000 then
    v_new_level := 'diamond';

  -- Gold: 10 torneos principales O 20K puntos
  elsif v_user.season_main_tournaments >= 10 or v_user.season_points >= 20000 then
    v_new_level := 'gold';

  -- Silver: 6 torneos O 10K puntos
  elsif v_user.season_main_tournaments >= 6 or v_user.season_points >= 10000 then
    v_new_level := 'silver';

  -- Bronze: 3 torneos O 5K puntos
  elsif v_user.season_main_tournaments >= 3 or v_user.season_points >= 5000 then
    v_new_level := 'bronze';

  else
    v_new_level := 'member';
  end if;

  -- Protección: si bajaría de nivel y sigue dentro del periodo de gracia, mantiene el actual.
  v_locked := v_user.vip_level_locked_until is not null
              and v_user.vip_level_locked_until >= current_date;

  if v_locked and public._vip_level_rank(v_new_level) < public._vip_level_rank(v_user.vip_level) then
    v_new_level := v_user.vip_level;
  end if;

  -- Si cambia, actualizamos
  if v_new_level <> v_user.vip_level then
    update public.users
    set vip_level = v_new_level,
        vip_level_attained_at = now()
    where id = p_user_id;
  end if;

  return v_new_level;
end;
$$;

-- Helper: ranking numérico de niveles
create or replace function public._vip_level_rank(p_level text)
returns int
language sql
immutable
as $$
  select case p_level
    when 'member'  then 0
    when 'bronze'  then 1
    when 'silver'  then 2
    when 'gold'    then 3
    when 'diamond' then 4
    when 'black'   then 5
    when 'icon'    then 6
    else -1
  end;
$$;

comment on function public.recalculate_vip_level(uuid) is
  'Recalcula el nivel VIP del user en base a season_points, season_main_tournaments y snapshots multi-año. Respeta vip_level_locked_until.';

-- ============================================================================
-- 3.2 add_points — otorgar puntos en valor BASE
-- ============================================================================

create or replace function public.add_points(
  p_user_id        uuid,
  p_base_points    int,
  p_type           text,                 -- 'earn' | 'multi_earn' | 'admin_add'
  p_description    text,
  p_achievement_id uuid default null,
  p_metadata       jsonb default '{}'::jsonb,
  p_source_type    text default null,
  p_source_id      uuid default null,
  p_counts_main_tournament bool default false  -- true si es de un WU/ME/HR
)
returns uuid
language plpgsql
security definer
as $$
declare
  v_tx_id              uuid;
  v_season_year        int;
  v_user_season_year   int;
  v_expires_at         timestamptz;
begin
  if p_base_points <= 0 then
    raise exception 'add_points: base_points debe ser > 0 (recibido: %)', p_base_points;
  end if;

  if p_type not in ('earn','multi_earn','admin_add') then
    raise exception 'add_points: type inválido: % (esperado earn|multi_earn|admin_add)', p_type;
  end if;

  -- Bloqueo de la fila para serializar updates al saldo
  select season_year into v_user_season_year from public.users where id = p_user_id for update;
  if not found then
    raise exception 'add_points: usuario % no existe', p_user_id;
  end if;

  v_season_year := v_user_season_year;
  v_expires_at  := now() + interval '12 months';

  -- Insertar transacción
  insert into public.point_transactions (
    user_id, type, base_points, points_final, multiplier,
    expires_at, remaining_for_redeem, season_year, metadata,
    source_type, source_id, description, balance_after
  )
  values (
    p_user_id, p_type, p_base_points, p_base_points, 1.0,
    v_expires_at, p_base_points, v_season_year,
    p_metadata || jsonb_build_object('achievement_id', p_achievement_id),
    p_source_type, p_source_id, p_description,
    (select coalesce(available_points, 0) + p_base_points from public.users where id = p_user_id)
  )
  returning id into v_tx_id;

  -- Actualizar saldos del user
  update public.users
  set season_points    = season_points + p_base_points,
      available_points = available_points + p_base_points,
      season_main_tournaments = season_main_tournaments + (case when p_counts_main_tournament then 1 else 0 end)
  where id = p_user_id;

  -- Recalcular nivel
  perform public.recalculate_vip_level(p_user_id);

  return v_tx_id;
end;
$$;

comment on function public.add_points is
  'Otorga puntos en valor BASE. El multiplicador se aplica solo en redeem. Actualiza saldos y recalcula nivel.';

-- ============================================================================
-- 3.3 redeem_points — canjear con FIFO sobre lotes
-- ============================================================================

create or replace function public.redeem_points(
  p_user_id          uuid,
  p_base_points      int,
  p_redemption_type  text,
  p_description      text,
  p_metadata         jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
as $$
declare
  v_user            record;
  v_multiplier      numeric(4,2);
  v_effective_eur   numeric(12,2);
  v_redemption_id   uuid;
  v_tx_id           uuid;
  v_remaining       int;
  v_lot             record;
  v_take            int;
  v_consumed_lots   jsonb := '[]'::jsonb;
begin
  if p_base_points < 5000 then
    raise exception 'redeem_points: mínimo 5000 puntos para canjear (solicitado: %)', p_base_points;
  end if;

  -- Lock user
  select id, vip_level, available_points
  into v_user
  from public.users
  where id = p_user_id
  for update;

  if not found then
    raise exception 'redeem_points: usuario % no existe', p_user_id;
  end if;

  -- Validar nivel mínimo Silver
  if public._vip_level_rank(v_user.vip_level) < public._vip_level_rank('silver') then
    raise exception 'redeem_points: requiere nivel Silver o superior (actual: %)', v_user.vip_level;
  end if;

  if v_user.available_points < p_base_points then
    raise exception 'redeem_points: saldo insuficiente (disponible: %, solicitado: %)',
      v_user.available_points, p_base_points;
  end if;

  -- Multiplier desde la config
  select multiplier into v_multiplier
  from public.vip_levels_config
  where level = v_user.vip_level;

  if v_multiplier is null then
    raise exception 'redeem_points: no hay config para nivel %', v_user.vip_level;
  end if;

  v_effective_eur := round((p_base_points * v_multiplier) / 100.0, 2);

  -- Crear el redemption
  insert into public.redemptions (
    user_id, type, base_points_cost, multiplier_applied,
    effective_value_eur, description, status, metadata
  )
  values (
    p_user_id, p_redemption_type, p_base_points, v_multiplier,
    v_effective_eur, p_description, 'pending', p_metadata
  )
  returning id into v_redemption_id;

  -- FIFO: consumir lotes ordenados por created_at
  v_remaining := p_base_points;

  for v_lot in
    select id, remaining_for_redeem, base_points
    from public.point_transactions
    where user_id = p_user_id
      and type in ('earn','multi_earn','admin_add')
      and remaining_for_redeem > 0
      and (expires_at is null or expires_at > now())
    order by created_at asc
    for update
  loop
    exit when v_remaining <= 0;

    v_take := least(v_lot.remaining_for_redeem, v_remaining);

    update public.point_transactions
    set remaining_for_redeem = remaining_for_redeem - v_take
    where id = v_lot.id;

    v_consumed_lots := v_consumed_lots || jsonb_build_object(
      'tx_id', v_lot.id,
      'taken', v_take
    );

    v_remaining := v_remaining - v_take;
  end loop;

  if v_remaining > 0 then
    raise exception 'redeem_points: no se pudieron consumir % puntos (FIFO incompleto)', v_remaining;
  end if;

  -- Crear la transacción de redeem
  insert into public.point_transactions (
    user_id, type, base_points, points_final, multiplier,
    season_year, metadata, description, balance_after
  )
  values (
    p_user_id, 'redeem', -p_base_points, -p_base_points, 1.0,
    (select season_year from public.users where id = p_user_id),
    jsonb_build_object(
      'redemption_id', v_redemption_id,
      'consumed_lots', v_consumed_lots,
      'multiplier_applied', v_multiplier,
      'effective_value_eur', v_effective_eur
    ),
    p_description,
    v_user.available_points - p_base_points
  )
  returning id into v_tx_id;

  -- Actualizar saldo: NO toca season_points (mantienes nivel aunque gastes)
  update public.users
  set available_points = available_points - p_base_points
  where id = p_user_id;

  return v_redemption_id;
end;
$$;

comment on function public.redeem_points is
  'Canjea puntos con FIFO sobre lotes. Aplica multiplicador del nivel actual. NO afecta season_points (el nivel se mantiene).';

-- ============================================================================
-- 3.4 expire_old_points — cron diario
-- ============================================================================

create or replace function public.expire_old_points()
returns int
language plpgsql
security definer
as $$
declare
  v_lot           record;
  v_user_id       uuid;
  v_total_expired int := 0;
begin
  for v_lot in
    select id, user_id, remaining_for_redeem, season_year
    from public.point_transactions
    where type in ('earn','multi_earn','admin_add')
      and remaining_for_redeem > 0
      and expires_at is not null
      and expires_at <= now()
    for update
  loop
    -- Lock user para serializar
    perform 1 from public.users where id = v_lot.user_id for update;

    -- Marcar lote como agotado
    update public.point_transactions
    set remaining_for_redeem = 0
    where id = v_lot.id;

    -- Crear fila de expiración
    insert into public.point_transactions (
      user_id, type, base_points, points_final, multiplier,
      season_year, metadata, description, balance_after
    )
    values (
      v_lot.user_id, 'expire',
      -v_lot.remaining_for_redeem, -v_lot.remaining_for_redeem, 1.0,
      v_lot.season_year,
      jsonb_build_object('expired_lot_tx_id', v_lot.id),
      'Expiración automática a los 12 meses',
      (select coalesce(available_points, 0) - v_lot.remaining_for_redeem
       from public.users where id = v_lot.user_id)
    );

    -- Restar de available_points (NO de season_points)
    update public.users
    set available_points = greatest(0, available_points - v_lot.remaining_for_redeem)
    where id = v_lot.user_id;

    v_total_expired := v_total_expired + v_lot.remaining_for_redeem;
  end loop;

  return v_total_expired;
end;
$$;

comment on function public.expire_old_points is
  'Expira lotes con expires_at <= now(). Resta de available_points. No toca season_points. Ejecutar diariamente vía pg_cron.';

-- ============================================================================
-- 3.5 start_new_season — cron 1 enero
-- ============================================================================

create or replace function public.start_new_season(p_new_year int)
returns int
language plpgsql
security definer
as $$
declare
  v_count       int := 0;
  v_user_id     uuid;
  v_grace_until date;
begin
  -- Periodo de gracia: 1 temporada completa desde el cambio (hasta el 31 dic del nuevo año)
  v_grace_until := make_date(p_new_year, 12, 31);

  for v_user_id in
    select id from public.users for update
  loop
    update public.users
    set
      season_points_year_minus_2 = season_points_year_minus_1,
      season_points_year_minus_1 = season_points,
      season_points              = 0,
      season_main_tournaments    = 0,
      season_year                = p_new_year,
      vip_level_locked_until     = v_grace_until
    where id = v_user_id;

    perform public.recalculate_vip_level(v_user_id);
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

comment on function public.start_new_season is
  'Cierra la temporada actual: rota snapshots multi-año, resetea season_points y season_main_tournaments, activa protección de nivel hasta 31 dic. Ejecutar el 1 enero vía pg_cron.';

-- ============================================================================
-- 3.6 apply_participation_points — otorga puntos a una participation
-- ============================================================================

create or replace function public.apply_participation_points(p_participation_id uuid)
returns uuid
language plpgsql
security definer
as $$
declare
  v_part      record;
  v_tournament record;
  v_points    int;
  v_tx_id     uuid;
  v_counts_main bool;
begin
  select * into v_part
  from public.tournament_participations
  where id = p_participation_id
  for update;

  if not found then
    raise exception 'apply_participation_points: participation % no existe', p_participation_id;
  end if;

  if v_part.user_id is null then
    raise exception 'apply_participation_points: participation % no tiene user matched', p_participation_id;
  end if;

  if v_part.status = 'awarded' then
    raise notice 'apply_participation_points: participation % ya fue awarded', p_participation_id;
    return v_part.points_transaction_id;
  end if;

  -- Cargar tournament para saber si cuenta para tier1 y los puntos por posición
  select * into v_tournament
  from public.festival_tournaments
  where id = v_part.tournament_id;

  v_counts_main := coalesce(v_tournament.counts_for_tier1, false);

  -- Puntos: si ya están precalculados (override del XLSX), los usamos.
  -- Si no, miramos points_per_position con la posición.
  if v_part.base_points_awarded is not null and v_part.base_points_awarded > 0 then
    v_points := v_part.base_points_awarded;
  elsif v_tournament.points_per_position ? v_part.final_position::text then
    v_points := (v_tournament.points_per_position ->> v_part.final_position::text)::int;
  else
    v_points := 0;
  end if;

  -- Aunque no haya puntos por posición, si jugó el torneo y cuenta para tier1,
  -- el contador sube (pero no creamos transacción de puntos vacía).
  if v_points > 0 then
    v_tx_id := public.add_points(
      p_user_id        := v_part.user_id,
      p_base_points    := v_points,
      p_type           := 'earn',
      p_description    := format('Resultado torneo (posición %s)', coalesce(v_part.final_position::text, '?')),
      p_metadata       := jsonb_build_object(
        'festival_id', v_part.festival_id,
        'tournament_id', v_part.tournament_id,
        'tournament_name', v_tournament.name,
        'final_position', v_part.final_position,
        'made_ft', v_part.made_ft,
        'made_money', v_part.made_money
      ),
      p_source_type    := 'tournament_participation',
      p_source_id      := p_participation_id,
      p_counts_main_tournament := v_counts_main
    );

    update public.tournament_participations
    set status = 'awarded',
        base_points_awarded = v_points,
        points_transaction_id = v_tx_id
    where id = p_participation_id;
  else
    -- Aunque no haya puntos, si cuenta para tier1, registramos el torneo
    if v_counts_main then
      update public.users
      set season_main_tournaments = season_main_tournaments + 1
      where id = v_part.user_id;

      perform public.recalculate_vip_level(v_part.user_id);
    end if;

    update public.tournament_participations
    set status = 'awarded'
    where id = p_participation_id;
  end if;

  return v_tx_id;
end;
$$;

comment on function public.apply_participation_points is
  'Procesa una tournament_participation matched: otorga puntos por posición y suma a season_main_tournaments si aplica.';
