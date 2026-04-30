-- ============================================================================
-- VPT Sistema VIP v2 — Baseline consolidado
-- Fecha: 2026-04-30
--
-- Esta migración captura el estado FINAL del sistema VIP tal como quedó
-- aplicado en el proyecto Supabase tras los iterativos del 30 abril 2026.
-- Es idempotente: usa `if not exists`, `on conflict do update`, `create or
-- replace`, etc. Se puede aplicar a una BBDD vacía (staging, dev) y dejará
-- el mismo estado que producción.
--
-- Cambios vs schema previo (lo que esta migración añade):
--
--   • USERS — columnas del sistema VIP:
--       season_year, season_points, available_points,
--       season_main_tournaments, vip_level_locked_until,
--       vip_level_attained_at, season_points_year_minus_1,
--       season_points_year_minus_2
--     vip_level con check de los 7 niveles válidos.
--
--   • POINT_TRANSACTIONS — columnas VIP:
--       base_points, expires_at, remaining_for_redeem, season_year, metadata
--     type con check de los 7 tipos válidos.
--
--   • FESTIVAL_TOURNAMENTS — columnas VIP:
--       type, counts_for_tier1, buy_in_eur, points_per_position, format,
--       starts_at, active
--     type con check (warm_up, main_event, high_roller, side, partner)
--
--   • TABLAS NUEVAS (9):
--       vip_levels_config, achievements, user_achievements,
--       badges, user_badges, redemptions,
--       user_player_aliases, tournament_participations
--
--   • FUNCIONES SQL (8):
--       _vip_level_rank, recalculate_vip_level, add_points,
--       redeem_points (con FIFO determinista order by created_at, id),
--       expire_old_points (con orden determinista),
--       start_new_season, apply_participation_points
--
--   • SEEDS:
--       vip_levels_config (7 niveles)
--       achievements (85: 10 recurrentes + 50 únicos + 25 multi-season)
--       badges (100: 10 rookie + 20 player + 30 pro + 30 legend + 10 boss)
--
--   • RLS, cron jobs (expiración diaria 03:00 UTC, reset anual 1 enero 00:05)
-- ============================================================================


-- ════════════════════════════════════════════════════════════════════════════
-- 1. USERS — columnas del sistema VIP
-- ════════════════════════════════════════════════════════════════════════════

alter table public.users
  add column if not exists season_year                int          default 2026,
  add column if not exists season_points              int          default 0,
  add column if not exists available_points           int          default 0,
  add column if not exists season_main_tournaments    int          default 0,
  add column if not exists vip_level_locked_until     date         null,
  add column if not exists vip_level_attained_at      timestamptz  null,
  add column if not exists season_points_year_minus_1 int          default 0,
  add column if not exists season_points_year_minus_2 int          default 0;

-- vip_level con check de los 7 niveles
do $$
begin
  alter table public.users alter column vip_level type text using vip_level::text;
exception when others then null;
end $$;

alter table public.users alter column vip_level set default 'member';

update public.users set vip_level = 'member'
where vip_level is null
   or vip_level not in ('member','bronze','silver','gold','diamond','black','icon');

alter table public.users drop constraint if exists users_vip_level_check;
alter table public.users
  add constraint users_vip_level_check
  check (vip_level in ('member','bronze','silver','gold','diamond','black','icon'));

create index if not exists idx_users_vip_level on public.users(vip_level);
create index if not exists idx_users_season_year on public.users(season_year);


-- ════════════════════════════════════════════════════════════════════════════
-- 2. POINT_TRANSACTIONS — columnas VIP
-- ════════════════════════════════════════════════════════════════════════════

alter table public.point_transactions
  add column if not exists base_points          int         null,
  add column if not exists expires_at           timestamptz null,
  add column if not exists remaining_for_redeem int         null,
  add column if not exists season_year          int         null,
  add column if not exists metadata             jsonb       not null default '{}'::jsonb;

alter table public.point_transactions drop constraint if exists point_transactions_type_check;
alter table public.point_transactions
  add constraint point_transactions_type_check
  check (type in ('earn','multi_earn','redeem','expire','admin_add','admin_sub','correction'));

create index if not exists idx_pt_user_created on public.point_transactions(user_id, created_at);
create index if not exists idx_pt_remaining
  on public.point_transactions(user_id, remaining_for_redeem)
  where remaining_for_redeem > 0;
create index if not exists idx_pt_expires
  on public.point_transactions(expires_at)
  where expires_at is not null and remaining_for_redeem > 0;


-- ════════════════════════════════════════════════════════════════════════════
-- 3. FESTIVAL_TOURNAMENTS — columnas VIP + backfill
-- ════════════════════════════════════════════════════════════════════════════

alter table public.festival_tournaments
  add column if not exists type                text         null,
  add column if not exists counts_for_tier1    bool         null default false,
  add column if not exists buy_in_eur          int          null,
  add column if not exists points_per_position jsonb        not null default '{}'::jsonb,
  add column if not exists format              text         null,
  add column if not exists starts_at           timestamptz  null,
  add column if not exists active              bool         not null default true;

-- Backfill type/counts_for_tier1/buy_in_eur desde flags y nombres existentes
update public.festival_tournaments
set
  type = case
    when is_main_event = true then 'main_event'
    when is_high_roller = true then 'high_roller'
    when lower(name) like '%warm up%' or lower(name) like '%warmup%' then 'warm_up'
    else 'side'
  end
where type is null;

update public.festival_tournaments
set counts_for_tier1 = (type in ('warm_up','main_event','high_roller'))
where counts_for_tier1 is null;

update public.festival_tournaments
set buy_in_eur = buyin_amount
where buy_in_eur is null and buyin_amount is not null;

alter table public.festival_tournaments alter column type set not null;

alter table public.festival_tournaments drop constraint if exists festival_tournaments_type_check;
alter table public.festival_tournaments
  add constraint festival_tournaments_type_check
  check (type in ('warm_up','main_event','high_roller','side','partner'));

create index if not exists idx_ft_type on public.festival_tournaments(type);


-- ════════════════════════════════════════════════════════════════════════════
-- 4. TABLAS NUEVAS DEL SISTEMA VIP
-- ════════════════════════════════════════════════════════════════════════════

create table if not exists public.vip_levels_config (
  level                       text primary key,
  display_name                text not null,
  tier                        text not null check (tier in ('starter','player','premium','vip')),
  order_index                 int  not null,
  star_count                  int  not null,
  symbol_name                 text not null,
  color_primary               text not null,
  color_accent                text not null,
  required_main_tournaments   int  null,
  required_season_points      int  null,
  required_2y_points          int  null,
  required_3y_points          int  null,
  multiplier                  numeric(4,2) not null,
  discount_pct                numeric(4,2) not null,
  description                 text null,
  benefits                    jsonb not null default '[]'::jsonb,
  active                      bool not null default true,
  created_at                  timestamptz not null default now(),
  updated_at                  timestamptz not null default now()
);
create unique index if not exists idx_vip_levels_order on public.vip_levels_config(order_index);

create table if not exists public.user_player_aliases (
  user_id          uuid not null references public.users(id) on delete cascade,
  alias            text not null,
  alias_normalized text generated always as (lower(trim(alias))) stored,
  primary_alias    bool not null default false,
  created_at       timestamptz not null default now(),
  primary key (user_id, alias_normalized)
);
create index if not exists idx_alias_normalized on public.user_player_aliases(alias_normalized);

create table if not exists public.tournament_participations (
  id                      uuid primary key default gen_random_uuid(),
  festival_id             uuid not null,
  tournament_id           uuid not null references public.festival_tournaments(id) on delete cascade,
  user_id                 uuid null references public.users(id) on delete set null,
  player_name             text not null,
  final_position          int  null,
  total_entries           int  null,
  made_ft                 bool not null default false,
  made_money              bool not null default false,
  prize_eur               numeric(12,2) null default 0,
  base_points_awarded     int null,
  points_transaction_id   uuid null references public.point_transactions(id) on delete set null,
  uploaded_batch_id       uuid null,
  status                  text not null default 'pending'
    check (status in ('pending','matched','unmatched','awarded','cancelled')),
  created_at              timestamptz not null default now()
);
create index if not exists idx_tp_festival    on public.tournament_participations(festival_id);
create index if not exists idx_tp_tournament  on public.tournament_participations(tournament_id);
create index if not exists idx_tp_user        on public.tournament_participations(user_id);
create index if not exists idx_tp_status      on public.tournament_participations(status);
create index if not exists idx_tp_player_name on public.tournament_participations(lower(player_name));

create table if not exists public.achievements (
  id                       uuid primary key default gen_random_uuid(),
  code                     text not null unique,
  display_name             text not null,
  description              text not null,
  category                 text not null check (category in ('recurrent','season_unique','multi_season')),
  subcategory              text null,
  points_base              int  not null,
  required_level           text not null default 'member'
    check (required_level in ('member','bronze','silver','gold','diamond','black','icon')),
  assignment               text not null check (assignment in ('auto','manual')),
  recurrent_max_per_season int null,
  icon                     text null,
  active                   bool not null default true,
  sort_order               int  not null default 0,
  created_at               timestamptz not null default now()
);
create index if not exists idx_ach_category on public.achievements(category);
create index if not exists idx_ach_active   on public.achievements(active);

create table if not exists public.user_achievements (
  id                     uuid primary key default gen_random_uuid(),
  user_id                uuid not null references public.users(id) on delete cascade,
  achievement_id         uuid not null references public.achievements(id) on delete cascade,
  festival_id            uuid null,
  season_year            int  not null,
  unlock_count           int  not null default 1,
  unlocked_at            timestamptz not null default now(),
  points_transaction_id  uuid null references public.point_transactions(id) on delete set null,
  metadata               jsonb not null default '{}'::jsonb
);
create unique index if not exists idx_ua_unique_season
  on public.user_achievements(user_id, achievement_id, season_year)
  where festival_id is null;
create unique index if not exists idx_ua_unique_festival
  on public.user_achievements(user_id, achievement_id, festival_id, unlock_count)
  where festival_id is not null;
create index if not exists idx_ua_user   on public.user_achievements(user_id);
create index if not exists idx_ua_season on public.user_achievements(season_year);

create table if not exists public.badges (
  id                uuid primary key default gen_random_uuid(),
  code              text not null unique,
  display_name      text not null,
  description       text not null,
  tier              text not null check (tier in ('rookie','player','pro','legend','boss_mode')),
  category          text null,
  icon              text null,
  active            bool not null default true,
  sort_order        int  not null default 0,
  created_at        timestamptz not null default now()
);
create index if not exists idx_badges_tier on public.badges(tier);

create table if not exists public.user_badges (
  user_id     uuid not null references public.users(id) on delete cascade,
  badge_id    uuid not null references public.badges(id) on delete cascade,
  unlocked_at timestamptz not null default now(),
  metadata    jsonb not null default '{}'::jsonb,
  primary key (user_id, badge_id)
);
create index if not exists idx_ub_user on public.user_badges(user_id);

create table if not exists public.redemptions (
  id                   uuid primary key default gen_random_uuid(),
  user_id              uuid not null references public.users(id) on delete cascade,
  type                 text not null check (type in ('store_discount','hotel_discount','tournament_entry','merch','other')),
  base_points_cost     int  not null,
  multiplier_applied   numeric(4,2) not null,
  effective_value_eur  numeric(12,2) not null,
  description          text null,
  status               text not null default 'pending'
    check (status in ('pending','approved','fulfilled','rejected','cancelled')),
  rejection_reason     text null,
  approved_by          uuid null references auth.users(id) on delete set null,
  approved_at          timestamptz null,
  fulfilled_at         timestamptz null,
  metadata             jsonb not null default '{}'::jsonb,
  created_at           timestamptz not null default now()
);
create index if not exists idx_red_user    on public.redemptions(user_id);
create index if not exists idx_red_status  on public.redemptions(status);
create index if not exists idx_red_created on public.redemptions(created_at desc);


-- ════════════════════════════════════════════════════════════════════════════
-- 5. FUNCIONES SQL
-- ════════════════════════════════════════════════════════════════════════════

create or replace function public._vip_level_rank(p_level text)
returns int language sql immutable as $$
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

create or replace function public.recalculate_vip_level(p_user_id uuid)
returns text language plpgsql security definer as $$
declare
  v_user      record;
  v_new_level text;
  v_locked    bool;
begin
  select season_points, season_main_tournaments,
         season_points_year_minus_1, season_points_year_minus_2,
         vip_level, vip_level_locked_until
  into v_user from public.users where id = p_user_id;

  if not found then return null; end if;

  if (v_user.season_points + v_user.season_points_year_minus_1) >= 250000
     or (v_user.season_points + v_user.season_points_year_minus_1 + v_user.season_points_year_minus_2) >= 400000
  then v_new_level := 'icon';
  elsif v_user.season_points >= 100000 then v_new_level := 'black';
  elsif v_user.season_points >= 50000  then v_new_level := 'diamond';
  elsif v_user.season_main_tournaments >= 10 or v_user.season_points >= 20000 then v_new_level := 'gold';
  elsif v_user.season_main_tournaments >= 6  or v_user.season_points >= 10000 then v_new_level := 'silver';
  elsif v_user.season_main_tournaments >= 3  or v_user.season_points >= 5000  then v_new_level := 'bronze';
  else v_new_level := 'member';
  end if;

  v_locked := v_user.vip_level_locked_until is not null
              and v_user.vip_level_locked_until >= current_date;

  if v_locked and public._vip_level_rank(v_new_level) < public._vip_level_rank(v_user.vip_level) then
    v_new_level := v_user.vip_level;
  end if;

  if v_new_level <> v_user.vip_level then
    update public.users
    set vip_level = v_new_level, vip_level_attained_at = now()
    where id = p_user_id;
  end if;

  return v_new_level;
end;
$$;

create or replace function public.add_points(
  p_user_id        uuid,
  p_base_points    int,
  p_type           text,
  p_description    text,
  p_achievement_id uuid    default null,
  p_metadata       jsonb   default '{}'::jsonb,
  p_source_type    text    default null,
  p_source_id      uuid    default null,
  p_counts_main_tournament bool default false
) returns uuid language plpgsql security definer as $$
declare
  v_tx_id              uuid;
  v_user_season_year   int;
  v_expires_at         timestamptz;
  v_balance_after      int;
begin
  if p_base_points <= 0 then
    raise exception 'add_points: base_points debe ser > 0 (recibido: %)', p_base_points;
  end if;
  if p_type not in ('earn','multi_earn','admin_add') then
    raise exception 'add_points: type inválido: %', p_type;
  end if;

  select season_year into v_user_season_year from public.users where id = p_user_id for update;
  if not found then raise exception 'add_points: usuario % no existe', p_user_id; end if;

  v_expires_at    := now() + interval '12 months';
  v_balance_after := (select coalesce(available_points, 0) + p_base_points
                      from public.users where id = p_user_id);

  insert into public.point_transactions (
    user_id, type,
    points, points_final, multiplier,
    base_points, expires_at, remaining_for_redeem, season_year,
    metadata, source_type, source_id, description, balance_after
  ) values (
    p_user_id, p_type,
    p_base_points, p_base_points, 1.0,
    p_base_points, v_expires_at, p_base_points, v_user_season_year,
    p_metadata || jsonb_build_object('achievement_id', p_achievement_id),
    p_source_type, p_source_id, p_description, v_balance_after
  ) returning id into v_tx_id;

  update public.users set
    season_points    = season_points + p_base_points,
    available_points = available_points + p_base_points,
    season_main_tournaments = season_main_tournaments + (case when p_counts_main_tournament then 1 else 0 end)
  where id = p_user_id;

  perform public.recalculate_vip_level(p_user_id);
  return v_tx_id;
end;
$$;

-- redeem_points con FIFO determinista (order by created_at, id)
create or replace function public.redeem_points(
  p_user_id          uuid,
  p_base_points      int,
  p_redemption_type  text,
  p_description      text,
  p_metadata         jsonb default '{}'::jsonb
) returns uuid language plpgsql security definer as $$
declare
  v_user           record;
  v_multiplier     numeric(4,2);
  v_effective_eur  numeric(12,2);
  v_redemption_id  uuid;
  v_remaining      int;
  v_lot            record;
  v_take           int;
  v_consumed_lots  jsonb := '[]'::jsonb;
begin
  if p_base_points < 5000 then
    raise exception 'redeem_points: mínimo 5000 puntos para canjear';
  end if;

  select id, vip_level, available_points, season_year
  into v_user from public.users where id = p_user_id for update;
  if not found then raise exception 'redeem_points: usuario % no existe', p_user_id; end if;

  if public._vip_level_rank(v_user.vip_level) < public._vip_level_rank('silver') then
    raise exception 'redeem_points: requiere nivel Silver+ (actual: %)', v_user.vip_level;
  end if;
  if v_user.available_points < p_base_points then
    raise exception 'redeem_points: saldo insuficiente';
  end if;

  select multiplier into v_multiplier from public.vip_levels_config where level = v_user.vip_level;
  v_effective_eur := round((p_base_points * v_multiplier) / 100.0, 2);

  insert into public.redemptions (
    user_id, type, base_points_cost, multiplier_applied,
    effective_value_eur, description, status, metadata
  ) values (
    p_user_id, p_redemption_type, p_base_points, v_multiplier,
    v_effective_eur, p_description, 'pending', p_metadata
  ) returning id into v_redemption_id;

  v_remaining := p_base_points;
  for v_lot in
    select id, remaining_for_redeem, base_points
    from public.point_transactions
    where user_id = p_user_id
      and type in ('earn','multi_earn','admin_add')
      and remaining_for_redeem > 0
      and (expires_at is null or expires_at > now())
    order by created_at asc, id asc      -- FIFO determinista: id como tiebreaker
    for update
  loop
    exit when v_remaining <= 0;
    v_take := least(v_lot.remaining_for_redeem, v_remaining);
    update public.point_transactions
    set remaining_for_redeem = remaining_for_redeem - v_take
    where id = v_lot.id;
    v_consumed_lots := v_consumed_lots || jsonb_build_object('tx_id', v_lot.id, 'taken', v_take);
    v_remaining := v_remaining - v_take;
  end loop;

  if v_remaining > 0 then
    raise exception 'redeem_points: FIFO no pudo consumir % puntos', v_remaining;
  end if;

  insert into public.point_transactions (
    user_id, type,
    points, points_final, multiplier,
    base_points, season_year, metadata, description, balance_after
  ) values (
    p_user_id, 'redeem',
    -p_base_points, -p_base_points, 1.0,
    -p_base_points, v_user.season_year,
    jsonb_build_object('redemption_id', v_redemption_id, 'consumed_lots', v_consumed_lots,
                      'multiplier_applied', v_multiplier, 'effective_value_eur', v_effective_eur),
    p_description, v_user.available_points - p_base_points
  );

  update public.users set available_points = available_points - p_base_points where id = p_user_id;
  return v_redemption_id;
end;
$$;

-- expire_old_points con orden determinista
create or replace function public.expire_old_points()
returns int language plpgsql security definer as $$
declare
  v_lot record;
  v_total int := 0;
begin
  for v_lot in
    select id, user_id, remaining_for_redeem, season_year
    from public.point_transactions
    where type in ('earn','multi_earn','admin_add')
      and remaining_for_redeem > 0
      and expires_at is not null and expires_at <= now()
    order by expires_at asc, id asc      -- determinista
    for update
  loop
    perform 1 from public.users where id = v_lot.user_id for update;
    update public.point_transactions set remaining_for_redeem = 0 where id = v_lot.id;

    insert into public.point_transactions (
      user_id, type, points, points_final, multiplier,
      base_points, season_year, metadata, description, balance_after
    ) values (
      v_lot.user_id, 'expire',
      -v_lot.remaining_for_redeem, -v_lot.remaining_for_redeem, 1.0,
      -v_lot.remaining_for_redeem, v_lot.season_year,
      jsonb_build_object('expired_lot_tx_id', v_lot.id),
      'Expiración automática 12 meses',
      (select coalesce(available_points, 0) - v_lot.remaining_for_redeem
       from public.users where id = v_lot.user_id)
    );

    update public.users
    set available_points = greatest(0, available_points - v_lot.remaining_for_redeem)
    where id = v_lot.user_id;

    v_total := v_total + v_lot.remaining_for_redeem;
  end loop;
  return v_total;
end;
$$;

create or replace function public.start_new_season(p_new_year int)
returns int language plpgsql security definer as $$
declare
  v_count int := 0;
  v_user_id uuid;
  v_grace_until date;
begin
  v_grace_until := make_date(p_new_year, 12, 31);
  for v_user_id in select id from public.users for update loop
    update public.users set
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

create or replace function public.apply_participation_points(p_participation_id uuid)
returns uuid language plpgsql security definer as $$
declare
  v_part        record;
  v_tournament  record;
  v_points      int;
  v_tx_id       uuid;
  v_counts_main bool;
begin
  select * into v_part from public.tournament_participations where id = p_participation_id for update;
  if not found then raise exception 'participation % no existe', p_participation_id; end if;
  if v_part.user_id is null then raise exception 'participation % sin user matched', p_participation_id; end if;
  if v_part.status = 'awarded' then return v_part.points_transaction_id; end if;

  select * into v_tournament from public.festival_tournaments where id = v_part.tournament_id;
  v_counts_main := coalesce(v_tournament.counts_for_tier1, false);

  if v_part.base_points_awarded is not null and v_part.base_points_awarded > 0 then
    v_points := v_part.base_points_awarded;
  elsif v_tournament.points_per_position ? v_part.final_position::text then
    v_points := (v_tournament.points_per_position ->> v_part.final_position::text)::int;
  else
    v_points := 0;
  end if;

  if v_points > 0 then
    v_tx_id := public.add_points(
      p_user_id := v_part.user_id, p_base_points := v_points, p_type := 'earn',
      p_description := format('Resultado torneo (pos %s)', coalesce(v_part.final_position::text, '?')),
      p_metadata := jsonb_build_object(
        'festival_id', v_part.festival_id, 'tournament_id', v_part.tournament_id,
        'tournament_name', v_tournament.name, 'final_position', v_part.final_position,
        'made_ft', v_part.made_ft, 'made_money', v_part.made_money),
      p_source_type := 'tournament_participation', p_source_id := p_participation_id,
      p_counts_main_tournament := v_counts_main
    );
    update public.tournament_participations
    set status = 'awarded', base_points_awarded = v_points, points_transaction_id = v_tx_id
    where id = p_participation_id;
  else
    if v_counts_main then
      update public.users set season_main_tournaments = season_main_tournaments + 1
      where id = v_part.user_id;
      perform public.recalculate_vip_level(v_part.user_id);
    end if;
    update public.tournament_participations set status = 'awarded' where id = p_participation_id;
  end if;
  return v_tx_id;
end;
$$;


-- ════════════════════════════════════════════════════════════════════════════
-- 6. SEEDS — vip_levels_config (7), achievements (85), badges (100)
-- ════════════════════════════════════════════════════════════════════════════

insert into public.vip_levels_config (level, display_name, tier, order_index, star_count, symbol_name, color_primary, color_accent, required_main_tournaments, required_season_points, required_2y_points, required_3y_points, multiplier, discount_pct) values
  ('member',  'Member',  'starter', 1, 1, 'User',     '#7A726A', '#C8C0B4', null, null,    null,   null,   1.00, 5),
  ('bronze',  'Bronze',  'player',  2, 2, 'Bronze',   '#8B5E3C', '#D4A97A', 3,    5000,    null,   null,   1.25, 7.5),
  ('silver',  'Silver',  'player',  3, 3, 'Silver',   '#A8B4BE', '#E8EEF3', 6,    10000,   null,   null,   1.50, 7.5),
  ('gold',    'Gold',    'player',  4, 4, 'Gold',     '#A37C2C', '#E2D3A7', 10,   20000,   null,   null,   1.75, 7.5),
  ('diamond', 'Diamond', 'premium', 5, 5, 'Diamante', '#558899', '#A8D0DA', null, 50000,   null,   null,   2.00, 10),
  ('black',   'Black',   'premium', 6, 6, 'Corona',   '#1E1E22', '#6E737B', null, 100000,  null,   null,   2.50, 15),
  ('icon',    'Icon',    'vip',     7, 7, 'Star',     '#7B2E3A', '#C47A87', null, null,    250000, 400000, 3.00, 20)
on conflict (level) do update set
  display_name = excluded.display_name,
  tier = excluded.tier,
  multiplier = excluded.multiplier,
  discount_pct = excluded.discount_pct,
  required_main_tournaments = excluded.required_main_tournaments,
  required_season_points = excluded.required_season_points,
  required_2y_points = excluded.required_2y_points,
  required_3y_points = excluded.required_3y_points,
  updated_at = now();

-- Achievements: recurrentes (10) + únicos (50) + multi-season (25) = 85
insert into public.achievements (code, display_name, description, category, subcategory, points_base, required_level, assignment, recurrent_max_per_season, sort_order) values
  ('rec_friend_referral','Trae a un Amigo','Refiere a un nuevo jugador que se registre y dispute su primer torneo VPT.','recurrent','App',100,'member','auto',50,1),
  ('rec_play_tournament','A jugar!','Participa en cualquier torneo del VPT.','recurrent','Torneos',100,'member','auto',null,2),
  ('rec_itm_hunter','ITM Hunter','Alcanza los puestos premiados (ITM) en cualquier torneo del VPT.','recurrent','Torneos',200,'member','auto',null,3),
  ('rec_ft_hunter','FT Hunter','Llega a la mesa final en cualquier torneo del VPT.','recurrent','Torneos',500,'member','auto',null,4),
  ('rec_trophy_hunter','Trophy Hunter','Gana cualquier torneo del VPT.','recurrent','Torneos',1000,'member','auto',null,5),
  ('rec_mvp_hunter','MVP Hunter','Consigue el premio MVP en cualquier parada del VPT.','recurrent','Torneos',1000,'member','auto',null,6),
  ('rec_online_qualifier','Online Qualifier','Clasifícate a un evento VPT a través de los satélites online oficiales.','recurrent','Torneos',500,'bronze','manual',null,7),
  ('rec_vpt_store','VPT Store','Gasta en la VPT Store: 100 pts por cada 20€ (compra mínima 50€).','recurrent','VPT Store',100,'bronze','manual',null,8),
  ('rec_hotel_pack','Pack de hotel VPT','Adquiere un pack de hotel VPT (mínimo 300€).','recurrent','VPT Store',1000,'bronze','manual',null,9),
  ('rec_cash_game_deal','Cash Game Deal','Acude con deal y cumple las condiciones establecidas en la parada.','recurrent','Cash Game Deal',2500,'silver','manual',null,10)
on conflict (code) do update set
  display_name = excluded.display_name,
  description = excluded.description,
  points_base = excluded.points_base,
  required_level = excluded.required_level,
  assignment = excluded.assignment,
  recurrent_max_per_season = excluded.recurrent_max_per_season,
  sort_order = excluded.sort_order;

insert into public.achievements (code, display_name, description, category, subcategory, points_base, required_level, assignment, sort_order) values
  ('uni_first_tournament','Primer Torneo','Disputa tu primer torneo de la temporada.','season_unique','First-timer',100,'member','auto',11),
  ('uni_first_itm','Primer ITM','Consigue tu primer ITM oficial de la temporada.','season_unique','First-timer',200,'member','auto',12),
  ('uni_first_ft','Primera Mesa Final','Alcanza tu primera Mesa Final oficial de la temporada.','season_unique','First-timer',500,'member','auto',13),
  ('uni_first_trophy','Primer Trofeo','Gana tu primer torneo oficial de la temporada.','season_unique','First-timer',1000,'member','manual',14),
  ('uni_mvp_champion','MVP Champion','Gana tu primer premio MVP en una parada de la temporada.','season_unique','First-timer',2000,'member','auto',15),
  ('uni_warmup_casher','Warm Up Casher','Consigue tu primer ITM en el Warm Up de la temporada.','season_unique','First-timer',200,'member','auto',16),
  ('uni_main_event_casher','Main Event Casher','Consigue tu primer ITM en el Main Event de la temporada.','season_unique','First-timer',300,'member','auto',17),
  ('uni_high_roller_casher','High Roller Casher','Consigue tu primer ITM en el High Roller de la temporada.','season_unique','First-timer',500,'member','auto',18),
  ('uni_warmup_ft','Warm Up Final Table','Alcanza tu primera Mesa Final en el Warm Up de la temporada.','season_unique','First-timer',500,'member','auto',19),
  ('uni_main_event_ft','Main Event Final Table','Alcanza tu primera Mesa Final en el Main Event de la temporada.','season_unique','First-timer',700,'member','auto',20),
  ('uni_high_roller_ft','High Roller Final Table','Alcanza tu primera Mesa Final en el High Roller de la temporada.','season_unique','First-timer',1000,'member','auto',21),
  ('uni_triple_threat','Triple Threat','Disputa el Warm Up, el Main Event y el High Roller en una misma parada del VPT.','season_unique','VPT Regular',500,'bronze','auto',22),
  ('uni_dual_main','Dual Stop Main Event','Disputa 2 Main Events distintos del VPT durante la temporada.','season_unique','VPT Regular',500,'bronze','auto',23),
  ('uni_dual_hr','Dual Stop High Roller','Disputa 2 High Rollers distintos del VPT durante la temporada.','season_unique','VPT Regular',1000,'bronze','auto',24),
  ('uni_bubble_protection','Bubble Protection','Queda eliminado en burbuja en un Main Event y llévate la Bubble Protection.','season_unique','VPT Regular',1000,'bronze','auto',25),
  ('uni_streak_attendant','Streak Attendant','Disputa el Main Event en 3 paradas consecutivas del VPT.','season_unique','VPT Regular',1000,'bronze','auto',26),
  ('uni_double_casher','Double Casher','Consigue ITM en el Main Event y en el High Roller de una misma parada.','season_unique','VPT Regular',1000,'bronze','auto',27),
  ('uni_hot_streak_me','Hot Streak ME','Consigue ITM en 3 paradas consecutivas del VPT.','season_unique','VPT Regular',1000,'bronze','auto',28),
  ('uni_wmh_champion','WU, ME o HR Champion','Gana el Warm Up, Main Event o el High Roller del VPT durante la temporada.','season_unique','VPT Regular',1000,'bronze','auto',29),
  ('uni_grand_final','Grand Final','Participa en el Main Event de la Gran Final del VPT.','season_unique','VPT Regular',500,'silver','auto',30),
  ('uni_regular_warmup','VPT Regular Warm Up','Disputa 4 Warm Ups distintos del VPT en una misma temporada.','season_unique','VPT Regular',1000,'silver','auto',31),
  ('uni_regular_main','VPT Regular Main Event','Disputa 4 Main Events distintos del VPT en una misma temporada.','season_unique','VPT Regular',2000,'silver','auto',32),
  ('uni_regular_hr','VPT Regular High Roller','Disputa 4 High Rollers distintos del VPT en una misma temporada.','season_unique','VPT Regular',3000,'silver','auto',33),
  ('uni_global_side','Global Side Events Casher','ITM en Side Events en 3 festivales distintos durante la temporada.','season_unique','VPT Regular',1000,'silver','auto',34),
  ('uni_global_main','Global Main Event Casher','ITM en el Main Event de 3 festivales distintos durante la temporada.','season_unique','VPT Regular',2000,'silver','auto',35),
  ('uni_global_hr','Global High Roller Casher','ITM en el High Roller de 3 festivales distintos durante la temporada.','season_unique','VPT Regular',3000,'silver','auto',36),
  ('uni_mixed_player','Mixed Player','Disputa torneos en al menos 3 formatos distintos durante un mismo festival.','season_unique','VPT Regular',2000,'silver','auto',37),
  ('uni_grinder','Grinder','Disputa 7 o más torneos oficiales en una misma parada del VPT.','season_unique','VPT Regular',3000,'silver','auto',38),
  ('uni_resiliencia','Resiliencia','Disputa 5 o más torneos en una misma parada sin conseguir ningún ITM.','season_unique','VPT Regular',2500,'silver','auto',39),
  ('uni_regular_player_20','Regular Player - 20 Torneos','Disputa 20 torneos oficiales del VPT durante la temporada.','season_unique','VPT Pro',1000,'gold','auto',40),
  ('uni_regular_player_50','Regular Player - 50 Torneos','Disputa 50 torneos oficiales del VPT durante la temporada.','season_unique','VPT Pro',2000,'gold','auto',41),
  ('uni_itm_hunter_10','ITM Hunter - 10 Cashes','10 ITM oficiales VPT durante la temporada.','season_unique','VPT Pro',1000,'gold','auto',42),
  ('uni_itm_hunter_20','ITM Hunter - 20 Cashes','20 ITM oficiales VPT durante la temporada.','season_unique','VPT Pro',2000,'gold','auto',43),
  ('uni_ft_hunter_5','FT Hunter - 5 Mesas Finales','Consigue 5x Mesa Final VPT durante la temporada.','season_unique','VPT Pro',1000,'gold','auto',44),
  ('uni_ft_hunter_10','FT Hunter - 10 Mesas Finales','Consigue 10x Mesa Final VPT durante la temporada.','season_unique','VPT Pro',2000,'gold','auto',45),
  ('uni_trophy_hunter_3','Trophy Hunter - 3 Wins','Gana 3x trofeos VPT durante la temporada.','season_unique','VPT Pro',1000,'gold','auto',46),
  ('uni_trophy_hunter_10','Trophy Hunter - 10 Wins','Gana 10x trofeos VPT durante la temporada.','season_unique','VPT Pro',2000,'gold','auto',47),
  ('uni_hat_trick','Hat Trick','Entra en ITM en WU, ME y HR durante el mismo festival.','season_unique','VPT Pro',1000,'gold','auto',48),
  ('uni_flag_hunter_3','Flag Hunter - 3 Países','ITM en torneos VPT en 3 países diferentes durante la temporada.','season_unique','VPT Pro',1000,'gold','auto',49),
  ('uni_triple_threat_x3','Triple Threat x3','Triple Threat en 3 festivales distintos del VPT.','season_unique','VPT Pro',1000,'gold','auto',50),
  ('uni_double_bubble','Double Bubble','Queda burbuja en 2 o más torneos de un mismo festival de VPT.','season_unique','VPT Pro',1000,'gold','auto',51),
  ('uni_mixed_winner','Mixed Winner','Gana un torneo en 3 formatos diferentes durante una temporada.','season_unique','VPT Pro',1000,'gold','auto',52),
  ('uni_super_streak','Super Streak Attendant','Disputa el Main Event en 5 paradas consecutivas del VPT.','season_unique','VPT Pro',2000,'gold','auto',53),
  ('uni_globetrotter','Globetrotter','ITM en el ME y HR en 3 países distintos en cada uno durante la temporada.','season_unique','VPT Pro',2000,'gold','auto',54),
  ('uni_mvp_multi_champ','MVP Multi-Champion','Gana 2 o más premios MVP de paradas del VPT durante la temporada.','season_unique','VPT Pro',4000,'gold','auto',55),
  ('uni_vpt_triple_corona','VPT Triple Corona','Gana el ME, el HR y el MVP en la misma temporada de VPT.','season_unique','VPT Pro',4000,'gold','auto',56),
  ('uni_vpt_full_season','VPT Full Season','Disputa TODOS los Main Events de VPT de una temporada.','season_unique','VPT Pro',15000,'gold','auto',57),
  ('uni_kpe_event','Kikuxo Poker Events','Disputa un Main Event de Gladiator Series o European Poker Masters.','season_unique','Partners Events',2000,'gold','manual',58),
  ('uni_kpe_regular','Kikuxo Poker Events Regular','Disputa 1x ME de cada marca KPE: Vamos, Gladiator y EPM.','season_unique','Partners Events',5000,'gold','manual',59),
  ('uni_kpe_triple_corona','Kikuxo Poker Events Triple Corona','Gana un torneo de cada marca de KPE: Vamos, Gladiator y EPM.','season_unique','Partners Events',15000,'gold','manual',60)
on conflict (code) do update set
  display_name = excluded.display_name,
  description = excluded.description,
  points_base = excluded.points_base,
  required_level = excluded.required_level,
  assignment = excluded.assignment,
  sort_order = excluded.sort_order;

insert into public.achievements (code, display_name, description, category, subcategory, points_base, required_level, assignment, sort_order) values
  ('ms_player_100','Player Histórico - 100 participaciones','Participa en 100 torneos del VPT a lo largo de tu carrera.','multi_season','Multi-Season',1000,'diamond','auto',61),
  ('ms_player_200','Player Histórico - 200 participaciones','Participa en 200 torneos del VPT a lo largo de tu carrera.','multi_season','Multi-Season',2000,'diamond','auto',62),
  ('ms_me_player_20','ME Player Histórico - 20 participaciones','Participa en 20 Main Event del VPT.','multi_season','Multi-Season',2000,'diamond','auto',63),
  ('ms_hr_player_20','HR Player Histórico - 20 participaciones','Participa en 20 High Rollers del VPT.','multi_season','Multi-Season',2000,'diamond','auto',64),
  ('ms_itm_hunter_50','ITM Hunter Histórico - 50 Cashes','Consigue 50 ITM oficiales en cualquier torneo del VPT.','multi_season','Multi-Season',2000,'diamond','auto',65),
  ('ms_itm_hunter_100','ITM Hunter Histórico - 100 Cashes','Consigue 100 ITM oficiales en cualquier torneo del VPT.','multi_season','Multi-Season',5000,'diamond','auto',66),
  ('ms_ft_hunter_25','FT Hunter Histórico - 25 Mesas Finales','Alcanza 25 mesas finales en cualquier torneo del VPT.','multi_season','Multi-Season',2000,'diamond','auto',67),
  ('ms_ft_hunter_50','FT Hunter Histórico - 50 Mesas Finales','Alcanza 50 mesas finales en cualquier torneo del VPT.','multi_season','Multi-Season',5000,'diamond','auto',68),
  ('ms_trophy_hunter_10','Trophy Hunter Histórico - 10 Wins','Gana 10 trofeos en cualquier torneo del VPT.','multi_season','Multi-Season',5000,'diamond','auto',69),
  ('ms_trophy_hunter_25','Trophy Hunter Histórico - 25 Wins','Gana 25 trofeos en cualquier torneo del VPT.','multi_season','Multi-Season',10000,'diamond','auto',70),
  ('ms_mvp_hunter_3','MVP Hunter Histórico - 3 MVPs','Gana 3 premios MVP en paradas del VPT.','multi_season','Multi-Season',5000,'diamond','auto',71),
  ('ms_mvp_hunter_10','MVP Hunter Histórico - 10 MVPs','Gana 10 premios MVP en paradas del VPT.','multi_season','Multi-Season',10000,'diamond','auto',72),
  ('ms_flag_hunter_5','Flag Hunter Histórico - 5 Países','ITM en torneos oficiales del VPT en 5 países distintos.','multi_season','Multi-Season',2000,'diamond','auto',73),
  ('ms_flag_hunter_10','Flag Hunter Histórico - 10 Países','ITM en torneos oficiales del VPT en 10 países distintos.','multi_season','Multi-Season',5000,'diamond','auto',74),
  ('ms_jugador_recurrente_x2','Jugador recurrente x2','Disputa el Main Event de 2 ciudades diferentes durante 3 temporadas.','multi_season','Multi-Season',5000,'diamond','auto',75),
  ('ms_jugador_recurrente_x5','Jugador recurrente x5','Disputa el Main Event de 5 ciudades diferentes durante 3 temporadas.','multi_season','Multi-Season',10000,'diamond','auto',76),
  ('ms_vpt_legend_2','VPT Legend - 2 Seasons','Participa en al menos 4 festivales del VPT durante 2 temporadas.','multi_season','Multi-Season',2000,'diamond','auto',77),
  ('ms_vpt_legend_3','VPT Legend - 3 Seasons','Participa en al menos 4 festivales del VPT durante 3 temporadas.','multi_season','Multi-Season',5000,'diamond','auto',78),
  ('ms_vpt_legend_5','VPT Legend - 5 Seasons','Participa en al menos 4 festivales del VPT durante 5 temporadas.','multi_season','Multi-Season',10000,'diamond','auto',79),
  ('ms_team_pro_2','VPT Team Pro - 2 Seasons','Consigue el pack VPT Team Pro en al menos 2 temporadas.','multi_season','Multi-Season',5000,'diamond','auto',80),
  ('ms_team_pro_3','VPT Team Pro - 3 Seasons','Consigue el pack VPT Team Pro en al menos 3 temporadas.','multi_season','Multi-Season',10000,'diamond','auto',81),
  ('ms_team_pro_5','VPT Team Pro - 5 Seasons','Consigue el pack VPT Team Pro en al menos 5 temporadas.','multi_season','Multi-Season',15000,'diamond','auto',82),
  ('ms_cgd_5','Cash Game Deal Regular - 5 Deals','Cumple 5 Cash Game Deals en festivales del VPT.','multi_season','Multi-Season',5000,'diamond','auto',83),
  ('ms_cgd_10','Cash Game Deal Regular - 10 Deals','Cumple 10 Cash Game Deals en festivales del VPT.','multi_season','Multi-Season',10000,'diamond','auto',84),
  ('ms_cgd_25','Cash Game Deal Regular - 25 Deals','Cumple 25 Cash Game Deals en festivales del VPT.','multi_season','Multi-Season',15000,'diamond','auto',85)
on conflict (code) do update set
  display_name = excluded.display_name,
  description = excluded.description,
  points_base = excluded.points_base,
  required_level = excluded.required_level,
  assignment = excluded.assignment,
  sort_order = excluded.sort_order;

-- Badges (100): rookie 10 + player 20 + pro 30 + legend 30 + boss_mode 10
insert into public.badges (code, display_name, description, tier, category, sort_order) values
  ('badge_vpt_club','VPT Club','Regístrate en el programa VPT Club.','rookie','App',1),
  ('badge_perfil_completo','Perfil Completo','Completa todos los campos de tu perfil VPT.','rookie','App',2),
  ('badge_cumple','Cumpleaños','Añade tu fecha de nacimiento al perfil.','rookie','App',3),
  ('badge_trae_amigo','Trae a un Amigo','Trae a un amigo a la App a través del programa de referidos.','rookie','App',4),
  ('badge_primer_torneo','Primer Torneo','Juega tu primer torneo VPT verificado.','rookie','Torneos',5),
  ('badge_primer_pack','Primer Pack','Realiza tu primer pedido en la VPT Store física.','rookie','VPT Store',6),
  ('badge_home_away','Home Away','Compra tu primer pack de hotel VPT.','rookie','VPT Store',7),
  ('badge_off_the_felt','Off the Felt','Participa en tu primera actividad oficial del VPT.','rookie','Offpoker',8),
  ('badge_online_qualifier','Online Qualifier','Clasifícate online en los satélites oficiales a un evento VPT.','rookie','Online',9),
  ('badge_grinder_rookie','Grinder','Participa en 3 torneos diferentes durante un mismo Festival del VPT.','rookie','Torneos',10),
  ('badge_primer_itm','Primer ITM','Consigue tu primer ITM en un torneo VPT.','player','ITM',11),
  ('badge_bronze_member','Bronze Member','Alcanza el nivel Bronze por primera vez.','player','Sistema VIP',12),
  ('badge_mixed_player','Mixed Player','Participa en 3 torneos con formatos distintos (NLH, PLO, OFC).','player','Torneos',13),
  ('badge_main_event_debut','Main Event Debut','Juega tu primer Main Event VPT.','player','Torneos',14),
  ('badge_high_roller_debut','High Roller Debut','Juega tu primer High Roller VPT.','player','Torneos',15),
  ('badge_hotel_regular','Hotel Regular','Compra 3 packs de hotel VPT.','player','VPT Store',16),
  ('badge_cash_game_player','Cash Game Player','Participa en tu primer Cash Game Deal VPT.','player','Cash Game Deal',17),
  ('badge_mvp_top10','MVP TOP 10','Aparece en el TOP 10 del Ranking MVP de una parada VPT.','player','MVP',18),
  ('badge_two_flags','Two Flags','Juega torneos VPT en 2 países distintos.','player','Flaghunter',19),
  ('badge_team_player','Team Player','Participa en 3 actividades Vamos distintas.','player','Offpoker',20),
  ('badge_itm_machine','ITM Machine','Consigue 5 ITMs en cualquier torneo VPT.','player','ITM',21),
  ('badge_primer_trofeo','Primer Trofeo','Gana tu primer torneo VPT.','player','Trofeos',22),
  ('badge_vpt_merch_fan','VPT Merch Fan','Realiza 3 compras en la VPT Store.','player','VPT Store',23),
  ('badge_ft_rookie','Final Table Rookie','Llega a tu primera Mesa Final en VPT.','player','Mesa Final',24),
  ('badge_festival_regular','Festival Regular','Juega en 3 festivales distintos VPT.','player','Torneos',25),
  ('badge_bubble_boy','Bubble Boy','Queda como jugador burbuja en un torneo del VPT.','player','Torneos',26),
  ('badge_silver_member','Silver Member','Alcanza el nivel Silver por primera vez.','player','Sistema VIP',27),
  ('badge_main_event_casher','Main Event Casher','Consigue tu primer ITM en un Main Event VPT.','player','ITM',28),
  ('badge_high_roller_casher','High Roller Casher','Consigue tu primer ITM en un High Roller VPT.','player','ITM',29),
  ('badge_patch_holder','Patch Holder','Valida tu foto oficial con el patch VPT.','player','Promoción',30),
  ('badge_gold_member','Gold Member','Alcanza el nivel Gold por primera vez.','pro','Sistema VIP',31),
  ('badge_triple_flags','Triple Flags','Disputa torneos VPT en 3 países distintos.','pro','Flaghunter',32),
  ('badge_itm_hunter','ITM Hunter','Consigue 10 ITMs en torneos VPT.','pro','ITM',33),
  ('badge_grand_finalist','Grand Finalist','Participar en el Main Event de la Final del VPT.','pro','Torneos',34),
  ('badge_mvp','MVP','Gana un premio MVP en una parada VPT.','pro','MVP',35),
  ('badge_double_down','Double Down','Llega a 2 Mesas Finales en una misma temporada.','pro','Mesa Final',36),
  ('badge_season_opener','Season Opener','Disputa el primer festival oficial de una temporada VPT.','pro','Torneos',37),
  ('badge_mixed_casher','Mixed Casher','ITM en 3 modalidades distintas de torneo VPT.','pro','ITM',38),
  ('badge_cgd_pro','Cash Game Deal Pro','Completa 3 Cash Game Deals en VPT.','pro','Cash Game Deal',39),
  ('badge_main_event_ft','Main Event Final Table','Llega a Mesa Final en un Main Event VPT.','pro','Mesa Final',40),
  ('badge_hr_ft','High Roller Final Table','Llega a Mesa Final en un High Roller VPT.','pro','Mesa Final',41),
  ('badge_european_tour','European Tour','Disputa en 4 países distintos en una temporada.','pro','Flaghunter',42),
  ('badge_double_champion','Double Champion','Gana 2 trofeos VPT en una misma temporada.','pro','Trofeos',43),
  ('badge_vpt_regular','VPT Regular','Disputa 4 Main Events distintos en una temporada.','pro','Torneos',44),
  ('badge_hr_regular','High Roller Regular','Disputa 4 High Rollers distintos en una temporada.','pro','Torneos',45),
  ('badge_gladiator','Gladiator','Disputa el Main Event del Gladiator Poker Series.','pro','Partner Events',46),
  ('badge_epm_player','EPM Player','Disputa el Main Event del European Poker Masters.','pro','Partner Events',47),
  ('badge_back_to_back','Back to Back','ITM en 2 torneos consecutivos en el mismo festival.','pro','ITM',48),
  ('badge_hello_again','Hello Again','Disputa el Main Event de 2 ciudades diferentes al menos 2 veces.','pro','Torneos',49),
  ('badge_hot_streak','Hot Streak','Consigue ITM en 3 paradas consecutivas del VPT.','pro','ITM',50),
  ('badge_vpt_veteran','VPT Veteran','Completa 2 temporadas con al menos 3 festivales cada una.','pro','Torneos',51),
  ('badge_night_grinder','Night Grinder','Disputa 5 side events nocturnos en festivales VPT.','pro','Torneos',52),
  ('badge_full_season','Full Season','Disputa +7 Main Events del VPT durante una misma temporada.','pro','Torneos',53),
  ('badge_diamond_member','Diamond Member','Alcanza el nivel Diamond por primera vez.','pro','Sistema VIP',54),
  ('badge_kpe_regular','KPE Regular','Disputa 1 ME de cada marca KPE.','pro','Partner Events',55),
  ('badge_cgd_specialist','Cash Game Deal Specialist','Completa 5 Cash Game Deals en VPT.','pro','Cash Game Deal',56),
  ('badge_bubble_protection','Bubble Protection','Consigue la Bubble Protection.','pro','Torneos',57),
  ('badge_triple_mvp','Triple MVP','Gana 3 premios MVP en paradas VPT.','pro','MVP',58),
  ('badge_five_flags','Five Flags','ITM en torneos VPT en 5 países distintos.','pro','Flaghunter',59),
  ('badge_hotel_connoisseur','Hotel Connoisseur','Compra packs de hotel en 5 festivales distintos.','pro','VPT Store',60),
  ('badge_black_member','Black Member','Alcanza el nivel Black por primera vez.','legend','Sistema VIP',61),
  ('badge_loyalty_award','Loyalty Award','Gana el last longer del Loyalty Award en la Gran Final.','legend','Loyalty Award',62),
  ('badge_main_event_champ','Main Event Champion','Gana un Main Event VPT.','legend','Trofeos',63),
  ('badge_hr_champ','High Roller Champion','Gana un High Roller VPT.','legend','Trofeos',64),
  ('badge_20_cashes','20 Cashes','Acumula 20 ITMs en cualquier torneo VPT.','legend','ITM',65),
  ('badge_ft_hunter','Final Table Hunter','Llega a 10 Mesas Finales en torneos VPT.','legend','Mesa Final',66),
  ('badge_itm_globetrotter','ITM Globetrotter','ITM en ME y HR en 3 países distintos en una temporada.','legend','Flaghunter',67),
  ('badge_todo_terreno','Todo Terreno','Gana 1 trofeo en 3 modalidades distintas.','legend','Torneos',68),
  ('badge_kpe_season_regular','KPE Season Regular','Disputa 1 ME de cada marca KPE en una misma temporada.','legend','Partner Events',69),
  ('badge_diamond_invitational','Diamond Invitational','Participa en el torneo VIP Diamond Invitational.','legend','Exclusivo',70),
  ('badge_cgd_veteran','Cash Game Deal Veteran','Completa 10 Cash Game Deals en VPT.','legend','Cash Game Deal',71),
  ('badge_mvp_multi_champ','MVP Multi-Champion','Gana 2 o más premios MVP en una temporada.','legend','MVP',72),
  ('badge_team_pro','VPT Team Pro','Consigue el Pack Team Pro en 2 temporadas consecutivas.','legend','Torneos',73),
  ('badge_triple_season','Triple Season','Completa 3 temporadas con al menos 3 festivales.','legend','Torneos',74),
  ('badge_world_tour','World Tour','Disputa torneos VPT en 7 países distintos.','legend','Flaghunter',75),
  ('badge_50_cashes','50 Cashes','Acumula 50 ITMs en torneos VPT.','legend','ITM',76),
  ('badge_trophy_collector','Trophy Collector','Gana 5 trofeos VPT a lo largo de tu carrera.','legend','Trofeos',77),
  ('badge_gladiator_champ','Gladiator Champion','Gana un Main Event del Gladiator Poker Series.','legend','Partner Events',78),
  ('badge_epm_champ','EPM Champion','Gana un Main Event del European Poker Masters.','legend','Partner Events',79),
  ('badge_vpt_legend','VPT Legend','Completa 5 temporadas con al menos 3 festivales.','legend','Torneos',80),
  ('badge_hr_specialist','High Roller Specialist','ITM en HR en 3 festivales distintos en una temporada.','legend','ITM',81),
  ('badge_ft_x5','Final Table x5','Llega a 5 Mesas Finales en una misma temporada.','legend','Mesa Final',82),
  ('badge_vpt_triple_corona','VPT Triple Corona','ME Champion + HR Champion + MVP Champion en la misma temporada.','legend','Trofeos',83),
  ('badge_cgd_superstar','Cash Game Deal SuperStar','Completa 25 Cash Game Deals en VPT.','legend','Cash Game Deal',84),
  ('badge_mvp_legend','MVP Legend','Acumula 10 premios MVP en paradas VPT.','legend','MVP',85),
  ('badge_men_in_black','Men in Black','Alcanza Black en 2 temporadas consecutivas.','legend','Sistema VIP',86),
  ('badge_flag_hunter_pro','Flag Hunter Pro','ITM en VPT en 5 países distintos en una temporada.','legend','Flaghunter',87),
  ('badge_kpe_triple_corona','KPE Triple Corona','Gana al menos 1 torneo de cada marca KPE.','legend','Partner Events',88),
  ('badge_vpt_pro','VPT Pro','Pack Team Pro en 3 temporadas distintas.','legend','Torneos',89),
  ('badge_10_seasons','10 Seasons','Completa 10 temporadas con al menos 3 festivales.','legend','Torneos',90),
  ('badge_icon','Icon','Alcanza el nivel Icon — el más alto del circuito VPT.','boss_mode','Sistema VIP',91),
  ('badge_100_cashes','100 Cashes','Acumula 100 ITMs en torneos VPT a lo largo de tu carrera.','boss_mode','ITM',92),
  ('badge_20_trofeos','20 Trofeos','Gana 20 trofeos VPT a lo largo de tu carrera.','boss_mode','Trofeos',93),
  ('badge_ten_flags','Ten Flags','ITM en torneos VPT en 10 países distintos.','boss_mode','Flaghunter',94),
  ('badge_100_ft','100 Final Tables','Llega a 100 Mesas Finales en torneos VPT.','boss_mode','Mesa Final',95),
  ('badge_embajador','Embajador VPT','Reconocimiento oficial como figura del circuito VPT.','boss_mode','Exclusivo',96),
  ('badge_25_mvp','25 MVP','Acumula 25 premios MVP en paradas VPT.','boss_mode','MVP',97),
  ('badge_50_trofeos','50 Trofeos','Gana 50 trofeos VPT a lo largo de tu carrera.','boss_mode','Trofeos',98),
  ('badge_vpt_alltime','VPT All-Time','Acumula la mayor cantidad de puntos históricos en el circuito.','boss_mode','Exclusivo',99),
  ('badge_the_icon','The Icon','Mantén el nivel Icon durante 3 temporadas consecutivas.','boss_mode','Exclusivo',100)
on conflict (code) do update set
  display_name = excluded.display_name,
  description = excluded.description,
  tier = excluded.tier,
  category = excluded.category,
  sort_order = excluded.sort_order;


-- ════════════════════════════════════════════════════════════════════════════
-- 7. RLS
-- ════════════════════════════════════════════════════════════════════════════

alter table public.vip_levels_config         enable row level security;
alter table public.achievements              enable row level security;
alter table public.badges                    enable row level security;
alter table public.user_achievements         enable row level security;
alter table public.user_badges               enable row level security;
alter table public.user_player_aliases       enable row level security;
alter table public.tournament_participations enable row level security;
alter table public.redemptions               enable row level security;

drop policy if exists vip_levels_select_public on public.vip_levels_config;
create policy vip_levels_select_public on public.vip_levels_config for select using (true);

drop policy if exists achievements_select_public on public.achievements;
create policy achievements_select_public on public.achievements for select using (active = true);

drop policy if exists badges_select_public on public.badges;
create policy badges_select_public on public.badges for select using (active = true);

drop policy if exists ua_select_public on public.user_achievements;
create policy ua_select_public on public.user_achievements for select using (true);

drop policy if exists ub_select_public on public.user_badges;
create policy ub_select_public on public.user_badges for select using (true);

drop policy if exists upa_select_public on public.user_player_aliases;
create policy upa_select_public on public.user_player_aliases for select using (true);

drop policy if exists tp_select_public on public.tournament_participations;
create policy tp_select_public on public.tournament_participations for select using (true);

drop policy if exists red_select_own on public.redemptions;
create policy red_select_own on public.redemptions for select using (auth.uid() = user_id);


-- ════════════════════════════════════════════════════════════════════════════
-- 8. CRON JOBS
-- ════════════════════════════════════════════════════════════════════════════

create extension if not exists pg_cron with schema extensions;
grant usage on schema cron to postgres;

do $$ begin
  perform cron.unschedule('vip_expire_points_daily')
    where exists (select 1 from cron.job where jobname='vip_expire_points_daily');
  perform cron.unschedule('vip_start_new_season')
    where exists (select 1 from cron.job where jobname='vip_start_new_season');
exception when others then null;
end $$;

select cron.schedule('vip_expire_points_daily', '0 3 * * *',  $$ select public.expire_old_points(); $$);
select cron.schedule('vip_start_new_season',    '5 0 1 1 *',  $$ select public.start_new_season(extract(year from now())::int); $$);


-- ════════════════════════════════════════════════════════════════════════════
-- VERIFICACIÓN
-- ════════════════════════════════════════════════════════════════════════════

do $$
declare
  v_levels  int;
  v_ach     int;
  v_badges  int;
  v_crons   int;
begin
  select count(*) into v_levels  from public.vip_levels_config;
  select count(*) into v_ach     from public.achievements where active = true;
  select count(*) into v_badges  from public.badges where active = true;
  select count(*) into v_crons   from cron.job where jobname like 'vip_%';

  raise notice 'VIP System v2 baseline aplicado: % niveles, % logros, % badges, % crons',
    v_levels, v_ach, v_badges, v_crons;
end $$;
