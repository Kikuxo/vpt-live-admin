-- ============================================================================
-- VIP System v2 — Festivales: alineación con schema real del live-admin
-- Fecha: 2026-04-30 23:30
--
-- Contexto: la tabla `festivals` ya existe en BBDD (creada por el live-admin)
-- con un schema rico, pero le faltan algunas columnas que el sistema VIP
-- necesita para procesar resultados (metadata, processed_at, processed_by).
--
-- Esta migración:
--   1. Añade columnas faltantes a `festivals` y `festival_tournaments`
--   2. Añade `metadata jsonb` a `tournament_participations`
--   3. Reescribe la RPC `process_festival` para usar los nombres reales
--      (title, starts_at, ends_at, season, is_main_event, format, etc.)
--
-- NO toca columnas existentes. Solo añade las que faltan.
-- ============================================================================

-- ════════════════════════════════════════════════════════════════════════════
-- 1. AÑADIR COLUMNAS FALTANTES
-- ════════════════════════════════════════════════════════════════════════════

-- festivals: campos del sistema VIP
alter table public.festivals
  add column if not exists metadata     jsonb       not null default '{}'::jsonb,
  add column if not exists processed_at timestamptz null,
  add column if not exists processed_by uuid        null references auth.users(id) on delete set null,
  add column if not exists updated_at   timestamptz not null default now();

-- festival_tournaments: campos para procesamiento VIP
alter table public.festival_tournaments
  add column if not exists metadata           jsonb not null default '{}'::jsonb,
  add column if not exists itm_threshold      int   null,
  add column if not exists ft_threshold       int   default 9,
  add column if not exists total_entries      int   null,
  add column if not exists is_main_tournament boolean null;

-- Si is_main_tournament está null, sincronizar con is_main_event para datos existentes
update public.festival_tournaments
set is_main_tournament = (is_main_event = true or is_high_roller = true or lower(coalesce(name, '')) like '%warm up%')
where is_main_tournament is null;

-- tournament_participations: añadir metadata
alter table public.tournament_participations
  add column if not exists metadata jsonb not null default '{}'::jsonb;


-- ════════════════════════════════════════════════════════════════════════════
-- 2. RPC: process_festival (versión adaptada al schema real)
-- ════════════════════════════════════════════════════════════════════════════

create or replace function public.process_festival(
  p_festival_id uuid
) returns jsonb language plpgsql security definer as $$
declare
  v_festival         record;
  v_admin_id         uuid;
  v_season           int;
  v_p                record;
  v_users_processed  int := 0;
  v_points_total     int := 0;
  v_unmatched_count  int := 0;
  v_summary          jsonb;
  v_mvp_top_n        int;
  v_mvp_user         record;
  v_is_grand_final   bool;
begin
  -- 1. Cargar festival
  select * into v_festival
  from public.festivals
  where id = p_festival_id
  for update;

  if not found then
    raise exception 'process_festival: festival % no existe', p_festival_id;
  end if;

  if coalesce(v_festival.status, '') = 'processed' then
    raise exception 'process_festival: festival "%" ya fue procesado el %. Si quieres rehacerlo, primero recrea las participations',
      v_festival.title, v_festival.processed_at;
  end if;

  v_admin_id        := auth.uid();
  v_season          := coalesce(v_festival.season, extract(year from current_date)::int);
  v_is_grand_final  := coalesce(v_festival.is_grand_final, false);

  -- 2. MATCHING: actualizar user_id en participations pending
  update public.tournament_participations tp
  set
    user_id = public._match_player_to_user(tp.player_name, tp.metadata->>'vpt_id'),
    status = case
      when public._match_player_to_user(tp.player_name, tp.metadata->>'vpt_id') is null then 'unmatched'
      else 'matched'
    end
  where tp.festival_id = p_festival_id
    and tp.user_id is null
    and tp.status = 'pending';

  -- ════════════════════════════════════════════════════════════════
  -- A. LOGROS INMEDIATOS por participation (con mejor posición)
  -- ════════════════════════════════════════════════════════════════
  for v_p in
    with best_pos as (
      select
        tp.user_id,
        tp.tournament_id,
        min(tp.final_position) as best_position,
        bool_or(tp.made_money) as made_money,
        bool_or(tp.made_ft) as made_ft,
        max(tp.prize_eur) as prize_eur,
        bool_or(coalesce((tp.metadata->>'is_bubble')::bool, false)) as is_bubble
      from public.tournament_participations tp
      where tp.festival_id = p_festival_id
        and tp.user_id is not null
        and tp.status = 'matched'
      group by tp.user_id, tp.tournament_id
    )
    select
      bp.*,
      ft.type as t_type,
      coalesce(ft.is_main_tournament, ft.is_main_event, false) as is_main,
      ft.name as t_name,
      ft.format as t_format
    from best_pos bp
    join public.festival_tournaments ft on ft.id = bp.tournament_id
    order by bp.user_id, bp.tournament_id
  loop
    -- a) "A jugar!" recurrente (100 pts)
    perform public.unlock_achievement(
      v_p.user_id, 'rec_play_tournament',
      jsonb_build_object('festival_id', p_festival_id, 'tournament_id', v_p.tournament_id,
        'tournament_type', v_p.t_type, 'tournament_name', v_p.t_name,
        'best_position', v_p.best_position, 'source', 'festival_processing'),
      true
    );
    v_points_total := v_points_total + 100;

    -- b) Si torneo principal, +1 a season_main_tournaments
    if v_p.is_main then
      update public.users
      set season_main_tournaments = coalesce(season_main_tournaments, 0) + 1
      where id = v_p.user_id;
    end if;

    -- c) ITM: rec_itm_hunter + uni_first_itm + casher por tipo
    if v_p.made_money then
      perform public.unlock_achievement(v_p.user_id, 'rec_itm_hunter',
        jsonb_build_object('festival_id', p_festival_id, 'tournament_id', v_p.tournament_id,
          'position', v_p.best_position, 'prize_eur', v_p.prize_eur), true);
      v_points_total := v_points_total + 200;

      begin
        perform public.unlock_achievement(v_p.user_id, 'uni_first_itm',
          jsonb_build_object('festival_id', p_festival_id, 'tournament_id', v_p.tournament_id), true);
        v_points_total := v_points_total + 200;
      exception when others then null; end;

      if v_p.t_type = 'warm_up' then
        begin
          perform public.unlock_achievement(v_p.user_id, 'uni_warm_up_casher',
            jsonb_build_object('festival_id', p_festival_id, 'tournament_id', v_p.tournament_id), true);
          v_points_total := v_points_total + 200;
        exception when others then null; end;
      elsif v_p.t_type = 'main_event' then
        begin
          perform public.unlock_achievement(v_p.user_id, 'uni_main_event_casher',
            jsonb_build_object('festival_id', p_festival_id, 'tournament_id', v_p.tournament_id), true);
          v_points_total := v_points_total + 300;
        exception when others then null; end;
      elsif v_p.t_type = 'high_roller' then
        begin
          perform public.unlock_achievement(v_p.user_id, 'uni_high_roller_casher',
            jsonb_build_object('festival_id', p_festival_id, 'tournament_id', v_p.tournament_id), true);
          v_points_total := v_points_total + 500;
        exception when others then null; end;
      end if;
    end if;

    -- d) FT: rec_ft_hunter + uni_first_ft + ft por tipo
    if v_p.made_ft then
      perform public.unlock_achievement(v_p.user_id, 'rec_ft_hunter',
        jsonb_build_object('festival_id', p_festival_id, 'tournament_id', v_p.tournament_id,
          'position', v_p.best_position), true);
      v_points_total := v_points_total + 500;

      begin
        perform public.unlock_achievement(v_p.user_id, 'uni_first_ft',
          jsonb_build_object('festival_id', p_festival_id, 'tournament_id', v_p.tournament_id), true);
        v_points_total := v_points_total + 500;
      exception when others then null; end;

      if v_p.t_type = 'warm_up' then
        begin
          perform public.unlock_achievement(v_p.user_id, 'uni_warm_up_ft',
            jsonb_build_object('festival_id', p_festival_id, 'tournament_id', v_p.tournament_id), true);
          v_points_total := v_points_total + 500;
        exception when others then null; end;
      elsif v_p.t_type = 'main_event' then
        begin
          perform public.unlock_achievement(v_p.user_id, 'uni_main_event_ft',
            jsonb_build_object('festival_id', p_festival_id, 'tournament_id', v_p.tournament_id), true);
          v_points_total := v_points_total + 700;
        exception when others then null; end;
      elsif v_p.t_type = 'high_roller' then
        begin
          perform public.unlock_achievement(v_p.user_id, 'uni_high_roller_ft',
            jsonb_build_object('festival_id', p_festival_id, 'tournament_id', v_p.tournament_id), true);
          v_points_total := v_points_total + 1000;
        exception when others then null; end;
      end if;
    end if;

    -- e) Trophy Hunter (1000 pts) + WU/ME/HR Champion + Primer Trofeo
    if v_p.best_position = 1 then
      perform public.unlock_achievement(v_p.user_id, 'rec_trophy_hunter',
        jsonb_build_object('festival_id', p_festival_id, 'tournament_id', v_p.tournament_id,
          'tournament_name', v_p.t_name), true);
      v_points_total := v_points_total + 1000;

      if v_p.t_type in ('warm_up','main_event','high_roller') then
        begin
          perform public.unlock_achievement(v_p.user_id, 'uni_wu_me_hr_champion',
            jsonb_build_object('festival_id', p_festival_id, 'tournament_id', v_p.tournament_id,
              'tournament_type', v_p.t_type), true);
          v_points_total := v_points_total + 1000;
        exception when others then null; end;
      end if;

      begin
        perform public.unlock_achievement(v_p.user_id, 'uni_first_trophy',
          jsonb_build_object('festival_id', p_festival_id, 'tournament_id', v_p.tournament_id), true);
        v_points_total := v_points_total + 1000;
      exception when others then null; end;
    end if;

    -- f) Bubble Protection
    if v_p.is_bubble and v_p.t_type = 'main_event' then
      begin
        perform public.unlock_achievement(v_p.user_id, 'uni_bubble_protection',
          jsonb_build_object('festival_id', p_festival_id, 'tournament_id', v_p.tournament_id), true);
        v_points_total := v_points_total + 1000;
      exception when others then null; end;
    end if;

    -- g) Primer Torneo del año
    begin
      perform public.unlock_achievement(v_p.user_id, 'uni_first_tournament',
        jsonb_build_object('festival_id', p_festival_id, 'tournament_id', v_p.tournament_id), true);
      v_points_total := v_points_total + 100;
    exception when others then null; end;

    -- h) Grand Final
    if v_p.t_type = 'main_event' and v_is_grand_final then
      begin
        perform public.unlock_achievement(v_p.user_id, 'uni_grand_final',
          jsonb_build_object('festival_id', p_festival_id, 'tournament_id', v_p.tournament_id), true);
        v_points_total := v_points_total + 500;
      exception when others then null; end;
    end if;

    v_users_processed := v_users_processed + 1;
  end loop;

  -- ════════════════════════════════════════════════════════════════
  -- B. LOGROS AGREGADOS POR FESTIVAL
  -- ════════════════════════════════════════════════════════════════
  for v_p in
    with by_user as (
      select
        tp.user_id,
        count(distinct tp.tournament_id) as tournaments_played,
        count(distinct ft.type) filter (where ft.type in ('warm_up','main_event','high_roller')) as main_types_played,
        count(distinct case when tp.made_money then ft.type end) filter (where ft.type in ('main_event','high_roller')) as money_in_me_hr,
        count(distinct case when tp.made_money then ft.type end) filter (where ft.type in ('warm_up','main_event','high_roller')) as money_in_wu_me_hr,
        count(distinct ft.format) filter (where ft.format is not null) as formats_played,
        count(*) filter (where coalesce((tp.metadata->>'is_bubble')::bool, false)) as bubbles,
        bool_or(tp.made_money) as any_itm
      from public.tournament_participations tp
      join public.festival_tournaments ft on ft.id = tp.tournament_id
      where tp.festival_id = p_festival_id
        and tp.user_id is not null
        and tp.status = 'matched'
      group by tp.user_id
    )
    select * from by_user
  loop
    if v_p.main_types_played >= 3 then
      begin
        perform public.unlock_achievement(v_p.user_id, 'uni_triple_threat',
          jsonb_build_object('festival_id', p_festival_id), true);
        v_points_total := v_points_total + 500;
      exception when others then null; end;
    end if;

    if v_p.money_in_me_hr >= 2 then
      begin
        perform public.unlock_achievement(v_p.user_id, 'uni_double_casher',
          jsonb_build_object('festival_id', p_festival_id), true);
        v_points_total := v_points_total + 1000;
      exception when others then null; end;
    end if;

    if v_p.money_in_wu_me_hr >= 3 then
      begin
        perform public.unlock_achievement(v_p.user_id, 'uni_hat_trick',
          jsonb_build_object('festival_id', p_festival_id), true);
        v_points_total := v_points_total + 1000;
      exception when others then null; end;
    end if;

    if v_p.formats_played >= 3 then
      begin
        perform public.unlock_achievement(v_p.user_id, 'uni_mixed_player',
          jsonb_build_object('festival_id', p_festival_id, 'formats', v_p.formats_played), true);
        v_points_total := v_points_total + 2000;
      exception when others then null; end;
    end if;

    if v_p.tournaments_played >= 7 then
      begin
        perform public.unlock_achievement(v_p.user_id, 'uni_grinder',
          jsonb_build_object('festival_id', p_festival_id, 'tournaments_played', v_p.tournaments_played), true);
        v_points_total := v_points_total + 3000;
      exception when others then null; end;
    end if;

    if v_p.tournaments_played >= 5 and not v_p.any_itm then
      begin
        perform public.unlock_achievement(v_p.user_id, 'uni_resiliencia',
          jsonb_build_object('festival_id', p_festival_id, 'tournaments_played', v_p.tournaments_played), true);
        v_points_total := v_points_total + 2500;
      exception when others then null; end;
    end if;

    if v_p.bubbles >= 2 then
      begin
        perform public.unlock_achievement(v_p.user_id, 'uni_double_bubble',
          jsonb_build_object('festival_id', p_festival_id, 'bubbles', v_p.bubbles), true);
        v_points_total := v_points_total + 1000;
      exception when others then null; end;
    end if;
  end loop;

  -- ════════════════════════════════════════════════════════════════
  -- C. MVP DEL FESTIVAL
  -- ════════════════════════════════════════════════════════════════
  v_mvp_top_n := coalesce((v_festival.metadata->>'mvp_top_n')::int, 10);

  for v_mvp_user in
    with mvp_agg as (
      select
        tp.user_id,
        sum(coalesce((tp.metadata->>'mvp_ranking_points')::numeric, 0)) as total_mvp,
        rank() over (order by sum(coalesce((tp.metadata->>'mvp_ranking_points')::numeric, 0)) desc) as mvp_rank
      from public.tournament_participations tp
      where tp.festival_id = p_festival_id
        and tp.user_id is not null
        and tp.status = 'matched'
        and (tp.metadata->>'mvp_ranking_points')::numeric > 0
      group by tp.user_id
    )
    select * from mvp_agg
    where mvp_rank <= v_mvp_top_n
  loop
    perform public.unlock_achievement(v_mvp_user.user_id, 'rec_mvp_hunter',
      jsonb_build_object('festival_id', p_festival_id, 'mvp_rank', v_mvp_user.mvp_rank,
        'mvp_points', v_mvp_user.total_mvp), true);
    v_points_total := v_points_total + 1000;

    if v_mvp_user.mvp_rank = 1 then
      begin
        perform public.unlock_achievement(v_mvp_user.user_id, 'uni_mvp_champion',
          jsonb_build_object('festival_id', p_festival_id, 'mvp_points', v_mvp_user.total_mvp), true);
        v_points_total := v_points_total + 2000;
      exception when others then null; end;
    end if;
  end loop;

  -- ════════════════════════════════════════════════════════════════
  -- D. SEASON-LEVEL: recalcular y otorgar logros que cruzan umbral
  -- ════════════════════════════════════════════════════════════════
  for v_p in
    with users_in_festival as (
      select distinct user_id
      from public.tournament_participations
      where festival_id = p_festival_id and user_id is not null and status = 'matched'
    ),
    season_stats as (
      select
        u.user_id,
        count(distinct tp_best.tournament_id) as tournaments_total,
        sum(case when tp_best.made_money then 1 else 0 end) as itms_total,
        sum(case when tp_best.made_ft then 1 else 0 end) as fts_total,
        sum(case when tp_best.best_position = 1 then 1 else 0 end) as trophies_total
      from users_in_festival u
      left join lateral (
        select
          tp.tournament_id,
          min(tp.final_position) as best_position,
          bool_or(tp.made_money) as made_money,
          bool_or(tp.made_ft) as made_ft
        from public.tournament_participations tp
        join public.festival_tournaments ft2 on ft2.id = tp.tournament_id
        join public.festivals f on f.id = ft2.festival_id
        where tp.user_id = u.user_id
          and tp.status in ('matched','awarded')
          and coalesce(f.season, extract(year from current_date)::int) = v_season
        group by tp.tournament_id
      ) tp_best on true
      group by u.user_id
    )
    select * from season_stats
  loop
    if coalesce(v_p.tournaments_total, 0) >= 50 then
      begin
        perform public.unlock_achievement(v_p.user_id, 'uni_regular_player_50',
          jsonb_build_object('festival_id', p_festival_id, 'tournaments_total', v_p.tournaments_total), true);
        v_points_total := v_points_total + 2000;
      exception when others then null; end;
    end if;
    if coalesce(v_p.tournaments_total, 0) >= 20 then
      begin
        perform public.unlock_achievement(v_p.user_id, 'uni_regular_player_20',
          jsonb_build_object('festival_id', p_festival_id, 'tournaments_total', v_p.tournaments_total), true);
        v_points_total := v_points_total + 1000;
      exception when others then null; end;
    end if;
    if coalesce(v_p.itms_total, 0) >= 20 then
      begin
        perform public.unlock_achievement(v_p.user_id, 'uni_itm_hunter_20',
          jsonb_build_object('festival_id', p_festival_id, 'itms_total', v_p.itms_total), true);
        v_points_total := v_points_total + 2000;
      exception when others then null; end;
    end if;
    if coalesce(v_p.itms_total, 0) >= 10 then
      begin
        perform public.unlock_achievement(v_p.user_id, 'uni_itm_hunter_10',
          jsonb_build_object('festival_id', p_festival_id, 'itms_total', v_p.itms_total), true);
        v_points_total := v_points_total + 1000;
      exception when others then null; end;
    end if;
    if coalesce(v_p.fts_total, 0) >= 10 then
      begin
        perform public.unlock_achievement(v_p.user_id, 'uni_ft_hunter_10',
          jsonb_build_object('festival_id', p_festival_id, 'fts_total', v_p.fts_total), true);
        v_points_total := v_points_total + 2000;
      exception when others then null; end;
    end if;
    if coalesce(v_p.fts_total, 0) >= 5 then
      begin
        perform public.unlock_achievement(v_p.user_id, 'uni_ft_hunter_5',
          jsonb_build_object('festival_id', p_festival_id, 'fts_total', v_p.fts_total), true);
        v_points_total := v_points_total + 1000;
      exception when others then null; end;
    end if;
    if coalesce(v_p.trophies_total, 0) >= 10 then
      begin
        perform public.unlock_achievement(v_p.user_id, 'uni_trophy_hunter_10',
          jsonb_build_object('festival_id', p_festival_id, 'trophies_total', v_p.trophies_total), true);
        v_points_total := v_points_total + 2000;
      exception when others then null; end;
    end if;
    if coalesce(v_p.trophies_total, 0) >= 3 then
      begin
        perform public.unlock_achievement(v_p.user_id, 'uni_trophy_hunter_3',
          jsonb_build_object('festival_id', p_festival_id, 'trophies_total', v_p.trophies_total), true);
        v_points_total := v_points_total + 1000;
      exception when others then null; end;
    end if;
  end loop;

  -- E. Marcar matched → awarded
  update public.tournament_participations tp
  set status = 'awarded'
  where tp.festival_id = p_festival_id and tp.status = 'matched';

  -- F. Contar unmatched
  select count(*) into v_unmatched_count
  from public.tournament_participations
  where festival_id = p_festival_id and status = 'unmatched';

  -- G. Marcar festival como procesado
  update public.festivals set
    status = 'processed',
    processed_at = now(),
    processed_by = v_admin_id,
    updated_at = now(),
    metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
      'processed_summary', jsonb_build_object(
        'rows_processed', v_users_processed,
        'rows_unmatched', v_unmatched_count,
        'points_total_granted', v_points_total
      )
    )
  where id = p_festival_id;

  v_summary := jsonb_build_object(
    'festival_id', p_festival_id,
    'festival_name', v_festival.title,
    'rows_processed', v_users_processed,
    'rows_unmatched', v_unmatched_count,
    'points_total_granted', v_points_total,
    'processed_at', now()
  );

  return v_summary;
end;
$$;

revoke execute on function public.process_festival(uuid) from public;
revoke execute on function public.process_festival(uuid) from anon;
grant execute on function public.process_festival(uuid) to authenticated;

-- Verificación
do $$
declare
  v_auth bool;
  v_cols int;
begin
  v_auth := has_function_privilege('authenticated', 'public.process_festival(uuid)', 'EXECUTE');

  select count(*) into v_cols
  from information_schema.columns
  where table_schema = 'public' and table_name = 'festivals'
    and column_name in ('metadata', 'processed_at', 'processed_by', 'updated_at');

  raise notice 'Festivals: % de 4 columnas VIP añadidas (metadata, processed_at, processed_by, updated_at)', v_cols;
  raise notice 'process_festival v3 (schema-aligned) creada. authenticated=% (esperado: t)', v_auth;

  if v_cols <> 4 then
    raise exception 'Esperadas 4 columnas, encontradas %', v_cols;
  end if;
end $$;
