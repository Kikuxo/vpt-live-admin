-- ============================================================================
-- VIP System v2 — Festivales (RPC v2: detección completa de logros)
-- Fecha: 2026-04-30 23:00
--
-- Reemplaza la función public.process_festival con una versión que detecta:
--
-- A. LOGROS INMEDIATOS (por participation, ya considerando re-entries con
--    "mejor posición"):
--    - rec_play_tournament         (100 pts)  por cada user que jugó
--    - rec_itm_hunter              (200 pts)  por cada ITM
--    - rec_ft_hunter               (500 pts)  por cada FT
--    - rec_trophy_hunter          (1000 pts)  por cada victoria
--    - uni_first_tournament        (100 pts)  1er torneo del año
--    - uni_first_itm               (200 pts)  1er ITM del año
--    - uni_first_ft                (500 pts)  1ª FT del año
--    - uni_warm_up_casher          (200 pts)  1er ITM en WU del año
--    - uni_main_event_casher       (300 pts)  1er ITM en ME del año
--    - uni_high_roller_casher      (500 pts)  1er ITM en HR del año
--    - uni_warm_up_ft              (500 pts)  1ª FT en WU del año
--    - uni_main_event_ft           (700 pts)  1ª FT en ME del año
--    - uni_high_roller_ft         (1000 pts)  1ª FT en HR del año
--    - uni_bubble_protection      (1000 pts)  bubble en ME (1ª vez del año)
--    - uni_wu_me_hr_champion      (1000 pts)  ganar WU/ME/HR (1ª vez del año)
--    - uni_grand_final             (500 pts)  jugar ME de gran final
--
-- B. LOGROS AGREGADOS POR FESTIVAL (después de procesar todas las
--    participations, contar agregados):
--    - uni_triple_threat           (500 pts)  jugar WU+ME+HR misma parada
--    - uni_double_casher          (1000 pts)  ITM en ME y HR misma parada
--    - uni_hat_trick              (1000 pts)  ITM en WU+ME+HR misma parada
--    - uni_mixed_player           (2000 pts)  jugar 3 formatos en festival
--    - uni_grinder                (3000 pts)  7+ torneos en una parada
--    - uni_resiliencia            (2500 pts)  5+ torneos sin ITM
--    - uni_double_bubble          (1000 pts)  2+ bubbles en mismo festival
--    - rec_mvp_hunter             (1000 pts)  top X en ranking MVP del festival
--    - uni_mvp_champion           (2000 pts)  1er MVP de la temporada
--
-- C. LOGROS SEASON-LEVEL (recalcular tras procesar el festival, mirar todo
--    el año actual):
--    - uni_regular_player_20      (1000 pts)  20 torneos en temporada
--    - uni_regular_player_50      (2000 pts)  50 torneos en temporada
--    - uni_itm_hunter_10          (1000 pts)  10 ITMs en temporada
--    - uni_itm_hunter_20          (2000 pts)  20 ITMs en temporada
--    - uni_ft_hunter_5            (1000 pts)  5 FTs en temporada
--    - uni_ft_hunter_10           (2000 pts)  10 FTs en temporada
--    - uni_trophy_hunter_3        (1000 pts)  3 trofeos en temporada
--    - uni_trophy_hunter_10       (2000 pts)  10 trofeos en temporada
--
-- D. MATCHING (con vpt_id ahora):
--    - 1º: VPT ID exacto (XLSX trae 'VPT 248 987 449', normalizar quitando
--          espacios y comparar con users.vpt_id)
--    - 2º: Nombre normalizado (lower + trim + sin acentos)
--    - 3º: Si nada → unmatched
--
-- E. RE-ENTRIES:
--    - Misma persona aparece N veces → solo la mejor posición cuenta para
--      todos los puntos. La query agregada por user_id+tournament_id ya
--      coge la mejor posición (min final_position).
--
-- IMPORTANTE: la migración previa creó una versión simple de process_festival.
-- Esta la reemplaza completamente con CREATE OR REPLACE.
-- ============================================================================

-- ════════════════════════════════════════════════════════════════════════════
-- 1. HELPER: matching con VPT ID o nombre
-- ════════════════════════════════════════════════════════════════════════════

-- Normaliza un VPT ID quitando espacios y mayúsculas
create or replace function public._normalize_vpt_id(p_id text)
returns text language sql immutable as $$
  select upper(regexp_replace(coalesce(p_id, ''), '\s+', '', 'g'));
$$;

-- Matchea por vpt_id (si existe) o por nombre
create or replace function public._match_player_to_user(
  p_player_name text,
  p_vpt_id      text default null
) returns uuid language plpgsql stable as $$
declare
  v_user_id     uuid;
  v_vpt_id_norm text;
  v_name_norm   text;
begin
  -- 1. Intento por vpt_id
  v_vpt_id_norm := public._normalize_vpt_id(p_vpt_id);
  if v_vpt_id_norm is not null and v_vpt_id_norm <> '' then
    select id into v_user_id
    from public.users
    where public._normalize_vpt_id(vpt_id) = v_vpt_id_norm
    limit 1;
    if v_user_id is not null then return v_user_id; end if;
  end if;

  -- 2. Intento por nombre normalizado
  if p_player_name is null or trim(p_player_name) = '' then
    return null;
  end if;
  v_name_norm := public._normalize_alias(p_player_name);
  select id into v_user_id
  from public.users
  where public._normalize_alias(name) = v_name_norm
  limit 1;

  return v_user_id;
end;
$$;


-- ════════════════════════════════════════════════════════════════════════════
-- 2. RPC: process_festival (versión ampliada)
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
begin
  -- 1. Cargar festival
  select * into v_festival
  from public.festivals
  where id = p_festival_id
  for update;

  if not found then
    raise exception 'process_festival: festival % no existe', p_festival_id;
  end if;

  if v_festival.status = 'processed' then
    raise exception 'process_festival: festival "%" ya fue procesado el %. Si quieres rehacerlo, primero recrea las participations',
      v_festival.name, v_festival.processed_at;
  end if;

  v_admin_id := auth.uid();
  v_season := v_festival.season_year;

  -- 2. MATCHING: actualizar user_id en todas las participations pending.
  --    Usa vpt_id (de metadata) o player_name.
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
  -- Para cada (user_id, tournament_id), nos quedamos con la mejor posición.
  -- Esto resuelve el problema de re-entries: si Juan tiene 4 entries en WU,
  -- contamos solo su mejor posición.

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
      ft.is_main_tournament,
      ft.name as t_name,
      ft.itm_threshold
    from best_pos bp
    join public.festival_tournaments ft on ft.id = bp.tournament_id
    order by bp.user_id, bp.tournament_id
  loop
    -- a) "A jugar!" recurrente, 100 pts
    perform public.unlock_achievement(
      v_p.user_id,
      'rec_play_tournament',
      jsonb_build_object(
        'festival_id', p_festival_id,
        'tournament_id', v_p.tournament_id,
        'tournament_type', v_p.t_type,
        'tournament_name', v_p.t_name,
        'best_position', v_p.best_position,
        'source', 'festival_processing'
      ),
      true
    );
    v_points_total := v_points_total + 100;

    -- b) Si torneo principal, +1 a season_main_tournaments
    if v_p.is_main_tournament then
      update public.users
      set season_main_tournaments = coalesce(season_main_tournaments, 0) + 1
      where id = v_p.user_id;
    end if;

    -- c) Logros recurrentes según resultado
    if v_p.made_money then
      perform public.unlock_achievement(
        v_p.user_id, 'rec_itm_hunter',
        jsonb_build_object('festival_id', p_festival_id, 'tournament_id', v_p.tournament_id, 'position', v_p.best_position, 'prize_eur', v_p.prize_eur),
        true
      );
      v_points_total := v_points_total + 200;

      -- "Primer ITM" único — solo se desbloquea si es el 1º del año
      begin
        perform public.unlock_achievement(
          v_p.user_id, 'uni_first_itm',
          jsonb_build_object('festival_id', p_festival_id, 'tournament_id', v_p.tournament_id),
          true
        );
        v_points_total := v_points_total + 200;
      exception when others then null; end;

      -- ITM por tipo de torneo (warm_up_casher, main_event_casher, high_roller_casher)
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

    -- d) FT Hunter recurrente (500 pts)
    if v_p.made_ft then
      perform public.unlock_achievement(
        v_p.user_id, 'rec_ft_hunter',
        jsonb_build_object('festival_id', p_festival_id, 'tournament_id', v_p.tournament_id, 'position', v_p.best_position),
        true
      );
      v_points_total := v_points_total + 500;

      -- "Primera FT" única (1ª del año)
      begin
        perform public.unlock_achievement(v_p.user_id, 'uni_first_ft',
          jsonb_build_object('festival_id', p_festival_id, 'tournament_id', v_p.tournament_id), true);
        v_points_total := v_points_total + 500;
      exception when others then null; end;

      -- FT por tipo
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

    -- e) Trophy Hunter (1000 pts) si position=1
    if v_p.best_position = 1 then
      perform public.unlock_achievement(
        v_p.user_id, 'rec_trophy_hunter',
        jsonb_build_object('festival_id', p_festival_id, 'tournament_id', v_p.tournament_id, 'tournament_name', v_p.t_name),
        true
      );
      v_points_total := v_points_total + 1000;

      -- WU/ME/HR Champion único (1ª vez de la temporada)
      if v_p.t_type in ('warm_up','main_event','high_roller') then
        begin
          perform public.unlock_achievement(v_p.user_id, 'uni_wu_me_hr_champion',
            jsonb_build_object('festival_id', p_festival_id, 'tournament_id', v_p.tournament_id, 'tournament_type', v_p.t_type), true);
          v_points_total := v_points_total + 1000;
        exception when others then null; end;
      end if;

      -- Primer Trofeo (manual en Excel pero lo otorgamos auto si position=1
      -- y aún no lo tenía esta temporada)
      begin
        perform public.unlock_achievement(v_p.user_id, 'uni_first_trophy',
          jsonb_build_object('festival_id', p_festival_id, 'tournament_id', v_p.tournament_id), true);
        v_points_total := v_points_total + 1000;
      exception when others then null; end;
    end if;

    -- f) Bubble Protection (1000 pts) si is_bubble Y main_event
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

    -- h) Grand Final si el festival es la Gran Final Y es ME
    if v_p.t_type = 'main_event'
       and coalesce((v_festival.metadata->>'is_grand_final')::bool, false) then
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
        count(distinct (ft.metadata->>'format')) filter (where ft.metadata->>'format' is not null) as formats_played,
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
    -- Triple Threat: 3 tipos principales (WU+ME+HR) en mismo festival
    if v_p.main_types_played >= 3 then
      begin
        perform public.unlock_achievement(v_p.user_id, 'uni_triple_threat',
          jsonb_build_object('festival_id', p_festival_id), true);
        v_points_total := v_points_total + 500;
      exception when others then null; end;
    end if;

    -- Double Casher: ITM en ME y HR misma parada
    if v_p.money_in_me_hr >= 2 then
      begin
        perform public.unlock_achievement(v_p.user_id, 'uni_double_casher',
          jsonb_build_object('festival_id', p_festival_id), true);
        v_points_total := v_points_total + 1000;
      exception when others then null; end;
    end if;

    -- Hat Trick: ITM en WU+ME+HR misma parada
    if v_p.money_in_wu_me_hr >= 3 then
      begin
        perform public.unlock_achievement(v_p.user_id, 'uni_hat_trick',
          jsonb_build_object('festival_id', p_festival_id), true);
        v_points_total := v_points_total + 1000;
      exception when others then null; end;
    end if;

    -- Mixed Player: 3 formatos distintos en festival
    if v_p.formats_played >= 3 then
      begin
        perform public.unlock_achievement(v_p.user_id, 'uni_mixed_player',
          jsonb_build_object('festival_id', p_festival_id, 'formats', v_p.formats_played), true);
        v_points_total := v_points_total + 2000;
      exception when others then null; end;
    end if;

    -- Grinder: 7+ torneos en una parada
    if v_p.tournaments_played >= 7 then
      begin
        perform public.unlock_achievement(v_p.user_id, 'uni_grinder',
          jsonb_build_object('festival_id', p_festival_id, 'tournaments_played', v_p.tournaments_played), true);
        v_points_total := v_points_total + 3000;
      exception when others then null; end;
    end if;

    -- Resiliencia: 5+ torneos sin ITM
    if v_p.tournaments_played >= 5 and not v_p.any_itm then
      begin
        perform public.unlock_achievement(v_p.user_id, 'uni_resiliencia',
          jsonb_build_object('festival_id', p_festival_id, 'tournaments_played', v_p.tournaments_played), true);
        v_points_total := v_points_total + 2500;
      exception when others then null; end;
    end if;

    -- Double Bubble: 2+ bubbles en mismo festival
    if v_p.bubbles >= 2 then
      begin
        perform public.unlock_achievement(v_p.user_id, 'uni_double_bubble',
          jsonb_build_object('festival_id', p_festival_id, 'bubbles', v_p.bubbles), true);
        v_points_total := v_points_total + 1000;
      exception when others then null; end;
    end if;
  end loop;

  -- ════════════════════════════════════════════════════════════════
  -- C. MVP DEL FESTIVAL (top X reciben rec_mvp_hunter; top 1 → uni_mvp_champion)
  -- ════════════════════════════════════════════════════════════════
  -- Agregar puntos MVP de todos los torneos del festival por user.
  -- Top X según festival.metadata->>'mvp_top_n' (default 10).

  v_mvp_top_n := coalesce((v_festival.metadata->>'mvp_top_n')::int, 10);

  for v_mvp_user in
    with mvp_agg as (
      select
        tp.user_id,
        sum(coalesce((tp.metadata->>'mvp_ranking_points')::numeric, 0)) as total_mvp,
        rank() over (
          order by sum(coalesce((tp.metadata->>'mvp_ranking_points')::numeric, 0)) desc
        ) as mvp_rank
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
    -- Top X: rec_mvp_hunter (1000 pts)
    perform public.unlock_achievement(
      v_mvp_user.user_id, 'rec_mvp_hunter',
      jsonb_build_object('festival_id', p_festival_id, 'mvp_rank', v_mvp_user.mvp_rank, 'mvp_points', v_mvp_user.total_mvp),
      true
    );
    v_points_total := v_points_total + 1000;

    -- Top 1: MVP Champion (2000 pts, único de temporada)
    if v_mvp_user.mvp_rank = 1 then
      begin
        perform public.unlock_achievement(v_mvp_user.user_id, 'uni_mvp_champion',
          jsonb_build_object('festival_id', p_festival_id, 'mvp_points', v_mvp_user.total_mvp), true);
        v_points_total := v_points_total + 2000;
      exception when others then null; end;
    end if;
  end loop;

  -- ════════════════════════════════════════════════════════════════
  -- D. SEASON-LEVEL: contar resultados de la temporada y otorgar logros
  -- ════════════════════════════════════════════════════════════════
  -- Para cada user que ha participado en este festival, recalcular:
  --   - tornaments_total: count distinct tournament_id en el año
  --   - itms_total: count made_money en el año
  --   - fts_total: count made_ft en el año
  --   - trophies_total: count position=1 en el año

  for v_p in
    with users_in_festival as (
      select distinct user_id
      from public.tournament_participations
      where festival_id = p_festival_id and user_id is not null and status = 'matched'
    ),
    season_stats as (
      select
        u.user_id,
        count(distinct tp.tournament_id) filter (
          where ft.festival_id is not null
        ) as tournaments_total,
        sum(case when tp_best.made_money then 1 else 0 end) as itms_total,
        sum(case when tp_best.made_ft then 1 else 0 end) as fts_total,
        sum(case when tp_best.best_position = 1 then 1 else 0 end) as trophies_total
      from users_in_festival u
      left join lateral (
        select
          tp.user_id,
          tp.tournament_id,
          min(tp.final_position) as best_position,
          bool_or(tp.made_money) as made_money,
          bool_or(tp.made_ft) as made_ft
        from public.tournament_participations tp
        join public.festival_tournaments ft2 on ft2.id = tp.tournament_id
        join public.festivals f on f.id = ft2.festival_id
        where tp.user_id = u.user_id
          and tp.status in ('matched','awarded')
          and f.season_year = v_season
        group by tp.user_id, tp.tournament_id
      ) tp_best on true
      left join public.festival_tournaments ft on ft.id = tp_best.tournament_id
      group by u.user_id
    )
    select * from season_stats
  loop
    -- Regular Player 20 / 50 torneos
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

    -- ITM Hunter 10 / 20
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

    -- FT Hunter 5 / 10
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

    -- Trophy Hunter 3 / 10
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

  -- ════════════════════════════════════════════════════════════════
  -- E. Marcar todas las participations matched como awarded
  -- ════════════════════════════════════════════════════════════════
  update public.tournament_participations tp
  set status = 'awarded'
  where tp.festival_id = p_festival_id
    and tp.status = 'matched';

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
    metadata = metadata || jsonb_build_object(
      'processed_summary', jsonb_build_object(
        'rows_processed', v_users_processed,
        'rows_unmatched', v_unmatched_count,
        'points_total_granted', v_points_total
      )
    )
  where id = p_festival_id;

  -- H. Construir summary
  v_summary := jsonb_build_object(
    'festival_id', p_festival_id,
    'festival_name', v_festival.name,
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
begin
  v_auth := has_function_privilege('authenticated', 'public.process_festival(uuid)', 'EXECUTE');
  raise notice 'process_festival v2 (40+ logros, season-level, MVP) creada. authenticated=% (esperado: t)', v_auth;
end $$;
