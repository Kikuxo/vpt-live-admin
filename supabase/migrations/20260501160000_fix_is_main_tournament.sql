-- ============================================================================
-- Fix is_main_tournament: solo torneos tipo warm_up/main_event/high_roller
-- Fecha: 2026-05-01 16:00
--
-- Problema detectado:
--   El XLSX uploader marcaba TODOS los torneos como is_main_tournament=true,
--   incluyendo side events (DeepStack, etc). Esto inflaba el contador
--   season_main_tournaments y rompía la progresión Tier 1 del sistema VIP.
--
-- Definición oficial de "torneo principal":
--   Warm Up (warm_up) + Main Event (main_event) + High Roller (high_roller)
--   Side events (DeepStack, etc) NO cuentan.
--
-- Esta migration:
--   1. Recalcula is_main_tournament en festival_tournaments según el type
--   2. Recalcula season_main_tournaments en users (count distinct correcto)
--   3. Reescribe process_festival para que confíe en `type` en lugar
--      del flag is_main_tournament (que puede venir mal del upload)
-- ============================================================================

-- ════════════════════════════════════════════════════════════════════════════
-- 1. Recalcular is_main_tournament en festival_tournaments
-- ════════════════════════════════════════════════════════════════════════════
update public.festival_tournaments
set is_main_tournament = (type in ('warm_up', 'main_event', 'high_roller'));

-- ════════════════════════════════════════════════════════════════════════════
-- 2. Recalcular season_main_tournaments en users (count distinct correcto)
-- ════════════════════════════════════════════════════════════════════════════
update public.users u
set season_main_tournaments = coalesce((
  select count(distinct tp.tournament_id)
  from public.tournament_participations tp
  join public.festival_tournaments ft on ft.id = tp.tournament_id
  join public.festivals f on f.id = ft.festival_id
  where tp.user_id = u.id
    and tp.status in ('matched', 'awarded')
    and ft.type in ('warm_up', 'main_event', 'high_roller')
    and coalesce(f.season, extract(year from current_date)::int) = u.season_year
), 0);

-- ════════════════════════════════════════════════════════════════════════════
-- 3. Reescribir process_festival para usar `type` en lugar de is_main_tournament
-- ════════════════════════════════════════════════════════════════════════════
create or replace function public.process_festival(p_festival_id uuid)
returns jsonb
language plpgsql
security definer
as $function$
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
  select * into v_festival from public.festivals where id = p_festival_id for update;
  if not found then
    raise exception 'process_festival: festival % no existe', p_festival_id;
  end if;
  if coalesce(v_festival.status, '') = 'processed' then
    raise exception 'process_festival: festival "%" ya fue procesado el %', v_festival.title, v_festival.processed_at;
  end if;

  v_admin_id        := auth.uid();
  v_season          := coalesce(v_festival.season, extract(year from current_date)::int);
  v_is_grand_final  := coalesce(v_festival.is_grand_final, false);

  -- Matching
  update public.tournament_participations tp
  set
    user_id = public._match_player_to_user(tp.player_name, tp.metadata->>'vpt_id'),
    status = case
      when public._match_player_to_user(tp.player_name, tp.metadata->>'vpt_id') is null then 'unmatched'
      else 'matched'
    end
  where tp.festival_id = p_festival_id and tp.user_id is null and tp.status = 'pending';

  -- ════ A. LOGROS INMEDIATOS por participation ════
  for v_p in
    with best_pos as (
      select
        tp.user_id, tp.tournament_id,
        min(tp.final_position) as best_position,
        bool_or(tp.made_money) as made_money,
        bool_or(tp.made_ft) as made_ft,
        max(tp.prize_eur) as prize_eur,
        bool_or(coalesce((tp.metadata->>'is_bubble')::bool, false)) as is_bubble
      from public.tournament_participations tp
      where tp.festival_id = p_festival_id and tp.user_id is not null and tp.status = 'matched'
      group by tp.user_id, tp.tournament_id
    )
    select bp.*, ft.type as t_type,
      -- CAMBIO: confiar SOLO en `type`, ignorar el flag is_main_tournament
      -- (que puede venir mal del XLSX upload).
      (ft.type in ('warm_up', 'main_event', 'high_roller')) as is_main,
      ft.name as t_name, ft.format as t_format
    from best_pos bp
    join public.festival_tournaments ft on ft.id = bp.tournament_id
    order by bp.user_id, bp.tournament_id
  loop
    -- a) "A jugar!" recurrente (100 pts)
    perform public.unlock_achievement(
      v_p.user_id, 'rec_play_tournament', true, p_festival_id,
      jsonb_build_object('tournament_id', v_p.tournament_id, 'tournament_type', v_p.t_type,
        'tournament_name', v_p.t_name, 'best_position', v_p.best_position, 'source', 'festival_processing')
    );
    v_points_total := v_points_total + 100;

    -- b) Torneo principal → +1
    if v_p.is_main then
      update public.users
      set season_main_tournaments = coalesce(season_main_tournaments, 0) + 1
      where id = v_p.user_id;
    end if;

    -- c) ITM
    if v_p.made_money then
      perform public.unlock_achievement(v_p.user_id, 'rec_itm_hunter', true, p_festival_id,
        jsonb_build_object('tournament_id', v_p.tournament_id, 'position', v_p.best_position, 'prize_eur', v_p.prize_eur));
      v_points_total := v_points_total + 200;

      begin
        perform public.unlock_achievement(v_p.user_id, 'uni_first_itm', true, p_festival_id,
          jsonb_build_object('tournament_id', v_p.tournament_id));
        v_points_total := v_points_total + 200;
      exception when others then null; end;

      if v_p.t_type = 'warm_up' then
        begin perform public.unlock_achievement(v_p.user_id, 'uni_warm_up_casher', true, p_festival_id,
          jsonb_build_object('tournament_id', v_p.tournament_id));
          v_points_total := v_points_total + 200;
        exception when others then null; end;
      elsif v_p.t_type = 'main_event' then
        begin perform public.unlock_achievement(v_p.user_id, 'uni_main_event_casher', true, p_festival_id,
          jsonb_build_object('tournament_id', v_p.tournament_id));
          v_points_total := v_points_total + 300;
        exception when others then null; end;
      elsif v_p.t_type = 'high_roller' then
        begin perform public.unlock_achievement(v_p.user_id, 'uni_high_roller_casher', true, p_festival_id,
          jsonb_build_object('tournament_id', v_p.tournament_id));
          v_points_total := v_points_total + 500;
        exception when others then null; end;
      end if;
    end if;

    -- d) FT
    if v_p.made_ft then
      perform public.unlock_achievement(v_p.user_id, 'rec_ft_hunter', true, p_festival_id,
        jsonb_build_object('tournament_id', v_p.tournament_id, 'position', v_p.best_position));
      v_points_total := v_points_total + 500;

      begin perform public.unlock_achievement(v_p.user_id, 'uni_first_ft', true, p_festival_id,
        jsonb_build_object('tournament_id', v_p.tournament_id));
        v_points_total := v_points_total + 500;
      exception when others then null; end;

      if v_p.t_type = 'warm_up' then
        begin perform public.unlock_achievement(v_p.user_id, 'uni_warm_up_ft', true, p_festival_id,
          jsonb_build_object('tournament_id', v_p.tournament_id));
          v_points_total := v_points_total + 500;
        exception when others then null; end;
      elsif v_p.t_type = 'main_event' then
        begin perform public.unlock_achievement(v_p.user_id, 'uni_main_event_ft', true, p_festival_id,
          jsonb_build_object('tournament_id', v_p.tournament_id));
          v_points_total := v_points_total + 700;
        exception when others then null; end;
      elsif v_p.t_type = 'high_roller' then
        begin perform public.unlock_achievement(v_p.user_id, 'uni_high_roller_ft', true, p_festival_id,
          jsonb_build_object('tournament_id', v_p.tournament_id));
          v_points_total := v_points_total + 1000;
        exception when others then null; end;
      end if;
    end if;

    -- e) Trophy
    if v_p.best_position = 1 then
      perform public.unlock_achievement(v_p.user_id, 'rec_trophy_hunter', true, p_festival_id,
        jsonb_build_object('tournament_id', v_p.tournament_id, 'tournament_name', v_p.t_name));
      v_points_total := v_points_total + 1000;

      if v_p.t_type in ('warm_up','main_event','high_roller') then
        begin perform public.unlock_achievement(v_p.user_id, 'uni_wu_me_hr_champion', true, p_festival_id,
          jsonb_build_object('tournament_id', v_p.tournament_id, 'tournament_type', v_p.t_type));
          v_points_total := v_points_total + 1000;
        exception when others then null; end;
      end if;

      begin perform public.unlock_achievement(v_p.user_id, 'uni_first_trophy', true, p_festival_id,
        jsonb_build_object('tournament_id', v_p.tournament_id));
        v_points_total := v_points_total + 1000;
      exception when others then null; end;
    end if;

    -- f) Bubble Protection
    if v_p.is_bubble and v_p.t_type = 'main_event' then
      begin perform public.unlock_achievement(v_p.user_id, 'uni_bubble_protection', true, p_festival_id,
        jsonb_build_object('tournament_id', v_p.tournament_id));
        v_points_total := v_points_total + 1000;
      exception when others then null; end;
    end if;

    -- g) Primer Torneo del año
    begin perform public.unlock_achievement(v_p.user_id, 'uni_first_tournament', true, p_festival_id,
      jsonb_build_object('tournament_id', v_p.tournament_id));
      v_points_total := v_points_total + 100;
    exception when others then null; end;

    -- h) Grand Final
    if v_p.t_type = 'main_event' and v_is_grand_final then
      begin perform public.unlock_achievement(v_p.user_id, 'uni_grand_final', true, p_festival_id,
        jsonb_build_object('tournament_id', v_p.tournament_id));
        v_points_total := v_points_total + 500;
      exception when others then null; end;
    end if;

    v_users_processed := v_users_processed + 1;
  end loop;

  -- ════ B. LOGROS AGREGADOS POR FESTIVAL ════
  for v_p in
    with by_user as (
      select tp.user_id,
        count(distinct tp.tournament_id) as tournaments_played,
        count(distinct ft.type) filter (where ft.type in ('warm_up','main_event','high_roller')) as main_types_played,
        count(distinct case when tp.made_money then ft.type end) filter (where ft.type in ('main_event','high_roller')) as money_in_me_hr,
        count(distinct case when tp.made_money then ft.type end) filter (where ft.type in ('warm_up','main_event','high_roller')) as money_in_wu_me_hr,
        count(distinct ft.format) filter (where ft.format is not null) as formats_played,
        count(*) filter (where coalesce((tp.metadata->>'is_bubble')::bool, false)) as bubbles,
        bool_or(tp.made_money) as any_itm
      from public.tournament_participations tp
      join public.festival_tournaments ft on ft.id = tp.tournament_id
      where tp.festival_id = p_festival_id and tp.user_id is not null and tp.status = 'matched'
      group by tp.user_id
    )
    select * from by_user
  loop
    if v_p.main_types_played >= 3 then
      begin perform public.unlock_achievement(v_p.user_id, 'uni_triple_threat', true, p_festival_id, '{}'::jsonb);
        v_points_total := v_points_total + 500;
      exception when others then null; end;
    end if;
    if v_p.money_in_me_hr >= 2 then
      begin perform public.unlock_achievement(v_p.user_id, 'uni_double_casher', true, p_festival_id, '{}'::jsonb);
        v_points_total := v_points_total + 1000;
      exception when others then null; end;
    end if;
    if v_p.money_in_wu_me_hr >= 3 then
      begin perform public.unlock_achievement(v_p.user_id, 'uni_hat_trick', true, p_festival_id, '{}'::jsonb);
        v_points_total := v_points_total + 1000;
      exception when others then null; end;
    end if;
    if v_p.formats_played >= 3 then
      begin perform public.unlock_achievement(v_p.user_id, 'uni_mixed_player', true, p_festival_id,
        jsonb_build_object('formats', v_p.formats_played));
        v_points_total := v_points_total + 2000;
      exception when others then null; end;
    end if;
    if v_p.tournaments_played >= 7 then
      begin perform public.unlock_achievement(v_p.user_id, 'uni_grinder', true, p_festival_id,
        jsonb_build_object('tournaments_played', v_p.tournaments_played));
        v_points_total := v_points_total + 3000;
      exception when others then null; end;
    end if;
    if v_p.tournaments_played >= 5 and not v_p.any_itm then
      begin perform public.unlock_achievement(v_p.user_id, 'uni_resiliencia', true, p_festival_id,
        jsonb_build_object('tournaments_played', v_p.tournaments_played));
        v_points_total := v_points_total + 2500;
      exception when others then null; end;
    end if;
    if v_p.bubbles >= 2 then
      begin perform public.unlock_achievement(v_p.user_id, 'uni_double_bubble', true, p_festival_id,
        jsonb_build_object('bubbles', v_p.bubbles));
        v_points_total := v_points_total + 1000;
      exception when others then null; end;
    end if;
  end loop;

  -- ════ C. MVP DEL FESTIVAL ════
  v_mvp_top_n := coalesce((v_festival.metadata->>'mvp_top_n')::int, 10);

  for v_mvp_user in
    with mvp_agg as (
      select tp.user_id,
        sum(coalesce((tp.metadata->>'mvp_ranking_points')::numeric, 0)) as total_mvp,
        rank() over (order by sum(coalesce((tp.metadata->>'mvp_ranking_points')::numeric, 0)) desc) as mvp_rank
      from public.tournament_participations tp
      where tp.festival_id = p_festival_id and tp.user_id is not null and tp.status = 'matched'
        and (tp.metadata->>'mvp_ranking_points')::numeric > 0
      group by tp.user_id
    )
    select * from mvp_agg where mvp_rank <= v_mvp_top_n
  loop
    perform public.unlock_achievement(v_mvp_user.user_id, 'rec_mvp_hunter', true, p_festival_id,
      jsonb_build_object('mvp_rank', v_mvp_user.mvp_rank, 'mvp_points', v_mvp_user.total_mvp));
    v_points_total := v_points_total + 1000;

    if v_mvp_user.mvp_rank = 1 then
      begin perform public.unlock_achievement(v_mvp_user.user_id, 'uni_mvp_champion', true, p_festival_id,
        jsonb_build_object('mvp_points', v_mvp_user.total_mvp));
        v_points_total := v_points_total + 2000;
      exception when others then null; end;
    end if;
  end loop;

  -- ════ D. SEASON-LEVEL ════
  for v_p in
    with users_in_festival as (
      select distinct user_id from public.tournament_participations
      where festival_id = p_festival_id and user_id is not null and status = 'matched'
    ),
    season_stats as (
      select u.user_id,
        count(distinct tp_best.tournament_id) as tournaments_total,
        sum(case when tp_best.made_money then 1 else 0 end) as itms_total,
        sum(case when tp_best.made_ft then 1 else 0 end) as fts_total,
        sum(case when tp_best.best_position = 1 then 1 else 0 end) as trophies_total
      from users_in_festival u
      left join lateral (
        select tp.tournament_id,
          min(tp.final_position) as best_position,
          bool_or(tp.made_money) as made_money,
          bool_or(tp.made_ft) as made_ft
        from public.tournament_participations tp
        join public.festival_tournaments ft2 on ft2.id = tp.tournament_id
        join public.festivals f on f.id = ft2.festival_id
        where tp.user_id = u.user_id and tp.status in ('matched','awarded')
          and coalesce(f.season, extract(year from current_date)::int) = v_season
        group by tp.tournament_id
      ) tp_best on true
      group by u.user_id
    )
    select * from season_stats
  loop
    if coalesce(v_p.tournaments_total, 0) >= 50 then
      begin perform public.unlock_achievement(v_p.user_id, 'uni_regular_player_50', true, p_festival_id,
        jsonb_build_object('tournaments_total', v_p.tournaments_total));
        v_points_total := v_points_total + 2000;
      exception when others then null; end;
    end if;
    if coalesce(v_p.tournaments_total, 0) >= 20 then
      begin perform public.unlock_achievement(v_p.user_id, 'uni_regular_player_20', true, p_festival_id,
        jsonb_build_object('tournaments_total', v_p.tournaments_total));
        v_points_total := v_points_total + 1000;
      exception when others then null; end;
    end if;
    if coalesce(v_p.itms_total, 0) >= 20 then
      begin perform public.unlock_achievement(v_p.user_id, 'uni_itm_hunter_20', true, p_festival_id,
        jsonb_build_object('itms_total', v_p.itms_total));
        v_points_total := v_points_total + 2000;
      exception when others then null; end;
    end if;
    if coalesce(v_p.itms_total, 0) >= 10 then
      begin perform public.unlock_achievement(v_p.user_id, 'uni_itm_hunter_10', true, p_festival_id,
        jsonb_build_object('itms_total', v_p.itms_total));
        v_points_total := v_points_total + 1000;
      exception when others then null; end;
    end if;
    if coalesce(v_p.fts_total, 0) >= 10 then
      begin perform public.unlock_achievement(v_p.user_id, 'uni_ft_hunter_10', true, p_festival_id,
        jsonb_build_object('fts_total', v_p.fts_total));
        v_points_total := v_points_total + 2000;
      exception when others then null; end;
    end if;
    if coalesce(v_p.fts_total, 0) >= 5 then
      begin perform public.unlock_achievement(v_p.user_id, 'uni_ft_hunter_5', true, p_festival_id,
        jsonb_build_object('fts_total', v_p.fts_total));
        v_points_total := v_points_total + 1000;
      exception when others then null; end;
    end if;
    if coalesce(v_p.trophies_total, 0) >= 10 then
      begin perform public.unlock_achievement(v_p.user_id, 'uni_trophy_hunter_10', true, p_festival_id,
        jsonb_build_object('trophies_total', v_p.trophies_total));
        v_points_total := v_points_total + 2000;
      exception when others then null; end;
    end if;
    if coalesce(v_p.trophies_total, 0) >= 3 then
      begin perform public.unlock_achievement(v_p.user_id, 'uni_trophy_hunter_3', true, p_festival_id,
        jsonb_build_object('trophies_total', v_p.trophies_total));
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
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- 4. Verificación
-- ════════════════════════════════════════════════════════════════════════════
do $$
declare
  v_bad_count int;
begin
  select count(*) into v_bad_count
  from public.festival_tournaments
  where (type in ('warm_up','main_event','high_roller')) <> is_main_tournament;

  if v_bad_count > 0 then
    raise exception 'Hay % torneos con is_main_tournament inconsistente con type', v_bad_count;
  end if;

  raise notice 'Migration aplicada: is_main_tournament corregido, season_main_tournaments recalculado, process_festival actualizado';
end $$;
