-- ============================================================================
-- VIP System v2 — Festivales: reproceso de XLSX
-- Fecha: 2026-05-01 13:00
--
-- 2 RPCs:
--
--  1. find_festival_by_xlsx(p_name, p_season):
--     Busca festival existente que coincida con nombre + temporada.
--     Devuelve uuid si existe (un único match), null si no existe,
--     o lanza excepción si hay match ambiguo (>1 festival).
--
--  2. reprocess_festival(p_festival_id, p_changes):
--     Reemplaza el stub. Aplica cambios SOLO ADITIVOS:
--     - Inserta nuevos torneos al festival
--     - Inserta nuevas participations
--     - Matchea retroactivamente unmatched que ahora tienen vpt_id/nombre
--     - Actualiza posiciones que mejoraron (otorga diferencia de logros)
--     - Recalcula logros agregados por festival (Triple Threat, etc.)
--     - Recalcula MVP del festival
--     - Recalcula season-level (Regular Player 20/50, ITM Hunter 10/20, etc.)
--
--     NO procesa cambios destructivos. Si el frontend los detecta, debe
--     bloquear el reproceso y exigir revert_festival primero.
-- ============================================================================

-- ════════════════════════════════════════════════════════════════════════════
-- 1. find_festival_by_xlsx
-- ════════════════════════════════════════════════════════════════════════════

create or replace function public.find_festival_by_xlsx(
  p_name   text,
  p_season int
) returns uuid language plpgsql stable security definer as $$
declare
  v_id     uuid;
  v_count  int;
begin
  if p_name is null or trim(p_name) = '' then
    return null;
  end if;

  select count(*) into v_count
  from public.festivals
  where lower(trim(title)) = lower(trim(p_name))
    and coalesce(season, 0) = coalesce(p_season, 0);

  if v_count = 0 then
    return null;
  end if;

  if v_count > 1 then
    raise exception 'find_festival_by_xlsx: hay % festivales con nombre "%" en temporada %. Imposible determinar cuál reprocesar.',
      v_count, p_name, p_season;
  end if;

  select id into v_id
  from public.festivals
  where lower(trim(title)) = lower(trim(p_name))
    and coalesce(season, 0) = coalesce(p_season, 0)
  limit 1;

  return v_id;
end;
$$;

revoke execute on function public.find_festival_by_xlsx(text, int) from public;
revoke execute on function public.find_festival_by_xlsx(text, int) from anon;
grant execute on function public.find_festival_by_xlsx(text, int) to authenticated;


-- ════════════════════════════════════════════════════════════════════════════
-- 2. reprocess_festival (versión completa)
-- ════════════════════════════════════════════════════════════════════════════

create or replace function public.reprocess_festival(
  p_festival_id uuid,
  p_changes     jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer as $$
declare
  v_festival           record;
  v_admin_id           uuid;
  v_season             int;
  v_is_grand_final     bool;

  -- Contadores
  v_tournaments_added  int := 0;
  v_parts_added        int := 0;
  v_matched_count      int := 0;
  v_improved_count     int := 0;
  v_aggr_logros        int := 0;
  v_mvp_logros         int := 0;
  v_season_logros      int := 0;
  v_points_total       int := 0;

  -- Iteradores
  v_t                  jsonb;
  v_p                  jsonb;
  v_part_record        record;
  v_match              jsonb;
  v_improvement        jsonb;
  v_loop               record;
  v_mvp_user           record;
  v_mvp_top_n          int;
  v_user_id            uuid;
  v_old_pos            int;
  v_new_pos            int;
  v_was_itm            bool;
  v_now_itm            bool;
  v_was_ft             bool;
  v_now_ft             bool;
  v_was_winner         bool;
  v_now_winner         bool;
  v_now_pos            int;
  v_t_type             text;
  v_t_main             bool;
  v_t_id               uuid;
  v_part_id            uuid;
  v_existing_t_id      uuid;
begin
  v_admin_id := auth.uid();

  -- 1. Cargar festival
  select * into v_festival from public.festivals where id = p_festival_id for update;
  if not found then
    raise exception 'reprocess_festival: festival % no existe', p_festival_id;
  end if;

  if v_festival.status <> 'processed' then
    raise exception 'reprocess_festival: festival "%" no está procesado todavía. Usa process_festival primero.', v_festival.title;
  end if;

  v_season         := coalesce(v_festival.season, extract(year from current_date)::int);
  v_is_grand_final := coalesce(v_festival.is_grand_final, false);

  -- ════════════════════════════════════════════════════════════════
  -- A. INSERTAR NUEVOS TORNEOS
  -- ════════════════════════════════════════════════════════════════
  if jsonb_array_length(coalesce(p_changes->'new_tournaments', '[]'::jsonb)) > 0 then
    for v_t in select * from jsonb_array_elements(p_changes->'new_tournaments')
    loop
      insert into public.festival_tournaments (
        festival_id, type, name, is_main_event, is_high_roller, is_main_tournament,
        buyin, buyin_amount, buy_in_eur, total_entries, itm_threshold, ft_threshold,
        format, active, metadata
      ) values (
        p_festival_id,
        v_t->>'type',
        v_t->>'name',
        coalesce((v_t->>'is_main_event')::bool, false),
        coalesce((v_t->>'is_high_roller')::bool, false),
        coalesce((v_t->>'is_main_tournament')::bool, false),
        v_t->>'buyin',
        (v_t->>'buyin_amount')::numeric,
        (v_t->>'buy_in_eur')::int,
        (v_t->>'total_entries')::int,
        (v_t->>'itm_threshold')::int,
        coalesce((v_t->>'ft_threshold')::int, 9),
        v_t->>'format',
        true,
        coalesce(v_t->'metadata', '{}'::jsonb)
      );
      v_tournaments_added := v_tournaments_added + 1;
    end loop;
  end if;

  -- ════════════════════════════════════════════════════════════════
  -- B. INSERTAR NUEVAS PARTICIPATIONS
  -- ════════════════════════════════════════════════════════════════
  if jsonb_array_length(coalesce(p_changes->'new_participations', '[]'::jsonb)) > 0 then
    for v_p in select * from jsonb_array_elements(p_changes->'new_participations')
    loop
      v_existing_t_id := (v_p->>'tournament_id')::uuid;

      -- Si no viene tournament_id resuelto desde el front, intentar resolver
      -- por sheet_name (los torneos nuevos no tienen id todavía cuando el front
      -- arma el payload). En este caso buscamos el último torneo del festival
      -- con name = sheet_name.
      if v_existing_t_id is null and (v_p->>'tournament_sheet_name') is not null then
        select id into v_existing_t_id
        from public.festival_tournaments
        where festival_id = p_festival_id
          and name = v_p->>'tournament_sheet_name'
        order by created_at desc
        limit 1;
      end if;

      if v_existing_t_id is null then
        raise exception 'reprocess_festival: new_participation sin tournament_id ni tournament_sheet_name resoluble (player=%)', v_p->>'player_name';
      end if;

      -- Resolver user_id si trae vpt_id o nombre matching
      v_user_id := null;
      if (v_p->>'matched_user_id') is not null then
        v_user_id := (v_p->>'matched_user_id')::uuid;
      else
        v_user_id := public._match_player_to_user(v_p->>'player_name', v_p->>'vpt_id');
      end if;

      insert into public.tournament_participations (
        festival_id, tournament_id, user_id, player_name, final_position,
        total_entries, made_ft, made_money, prize_eur, status, metadata
      ) values (
        p_festival_id,
        v_existing_t_id,
        v_user_id,
        v_p->>'player_name',
        (v_p->>'final_position')::int,
        (v_p->>'total_entries')::int,
        coalesce((v_p->>'made_ft')::bool, false),
        coalesce((v_p->>'made_money')::bool, false),
        (v_p->>'prize_eur')::numeric,
        case when v_user_id is null then 'unmatched' else 'awarded' end,
        coalesce(v_p->'metadata', '{}'::jsonb)
      );
      v_parts_added := v_parts_added + 1;

      -- Si esta nueva participation está matched, otorgar logros aplicables
      -- (solo logros INMEDIATOS por participation; agregados se calcularán al final)
      if v_user_id is not null then
        -- Obtener metadata del torneo para evaluar logros
        select type,
               coalesce(is_main_tournament, is_main_event, false) as is_main
        into v_loop
        from public.festival_tournaments
        where id = v_existing_t_id;

        v_t_type := v_loop.type;
        v_t_main := v_loop.is_main;

        v_now_pos    := (v_p->>'final_position')::int;
        v_now_itm    := coalesce((v_p->>'made_money')::bool, false);
        v_now_ft     := coalesce((v_p->>'made_ft')::bool, false);
        v_now_winner := (v_now_pos = 1);

        -- Otorgar logros INMEDIATOS (réplica del bloque A de process_festival)
        perform public.unlock_achievement(v_user_id, 'rec_play_tournament', true, p_festival_id,
          jsonb_build_object('tournament_id', v_existing_t_id, 'tournament_type', v_t_type,
            'best_position', v_now_pos, 'source', 'reprocess'));
        v_points_total := v_points_total + 100;

        if v_t_main then
          update public.users set season_main_tournaments = coalesce(season_main_tournaments, 0) + 1
          where id = v_user_id;
        end if;

        if v_now_itm then
          perform public.unlock_achievement(v_user_id, 'rec_itm_hunter', true, p_festival_id,
            jsonb_build_object('tournament_id', v_existing_t_id, 'position', v_now_pos));
          v_points_total := v_points_total + 200;

          begin perform public.unlock_achievement(v_user_id, 'uni_first_itm', true, p_festival_id,
            jsonb_build_object('tournament_id', v_existing_t_id));
            v_points_total := v_points_total + 200;
          exception when others then null; end;

          if v_t_type = 'warm_up' then
            begin perform public.unlock_achievement(v_user_id, 'uni_warm_up_casher', true, p_festival_id,
              jsonb_build_object('tournament_id', v_existing_t_id));
              v_points_total := v_points_total + 200;
            exception when others then null; end;
          elsif v_t_type = 'main_event' then
            begin perform public.unlock_achievement(v_user_id, 'uni_main_event_casher', true, p_festival_id,
              jsonb_build_object('tournament_id', v_existing_t_id));
              v_points_total := v_points_total + 300;
            exception when others then null; end;
          elsif v_t_type = 'high_roller' then
            begin perform public.unlock_achievement(v_user_id, 'uni_high_roller_casher', true, p_festival_id,
              jsonb_build_object('tournament_id', v_existing_t_id));
              v_points_total := v_points_total + 500;
            exception when others then null; end;
          end if;
        end if;

        if v_now_ft then
          perform public.unlock_achievement(v_user_id, 'rec_ft_hunter', true, p_festival_id,
            jsonb_build_object('tournament_id', v_existing_t_id, 'position', v_now_pos));
          v_points_total := v_points_total + 500;

          begin perform public.unlock_achievement(v_user_id, 'uni_first_ft', true, p_festival_id,
            jsonb_build_object('tournament_id', v_existing_t_id));
            v_points_total := v_points_total + 500;
          exception when others then null; end;

          if v_t_type = 'warm_up' then
            begin perform public.unlock_achievement(v_user_id, 'uni_warm_up_ft', true, p_festival_id,
              jsonb_build_object('tournament_id', v_existing_t_id));
              v_points_total := v_points_total + 500;
            exception when others then null; end;
          elsif v_t_type = 'main_event' then
            begin perform public.unlock_achievement(v_user_id, 'uni_main_event_ft', true, p_festival_id,
              jsonb_build_object('tournament_id', v_existing_t_id));
              v_points_total := v_points_total + 700;
            exception when others then null; end;
          elsif v_t_type = 'high_roller' then
            begin perform public.unlock_achievement(v_user_id, 'uni_high_roller_ft', true, p_festival_id,
              jsonb_build_object('tournament_id', v_existing_t_id));
              v_points_total := v_points_total + 1000;
            exception when others then null; end;
          end if;
        end if;

        if v_now_winner then
          perform public.unlock_achievement(v_user_id, 'rec_trophy_hunter', true, p_festival_id,
            jsonb_build_object('tournament_id', v_existing_t_id));
          v_points_total := v_points_total + 1000;

          if v_t_type in ('warm_up','main_event','high_roller') then
            begin perform public.unlock_achievement(v_user_id, 'uni_wu_me_hr_champion', true, p_festival_id,
              jsonb_build_object('tournament_id', v_existing_t_id, 'tournament_type', v_t_type));
              v_points_total := v_points_total + 1000;
            exception when others then null; end;
          end if;

          begin perform public.unlock_achievement(v_user_id, 'uni_first_trophy', true, p_festival_id,
            jsonb_build_object('tournament_id', v_existing_t_id));
            v_points_total := v_points_total + 1000;
          exception when others then null; end;
        end if;

        -- Bubble (si la metadata lo trae)
        if coalesce((v_p->'metadata'->>'is_bubble')::bool, false) and v_t_type = 'main_event' then
          begin perform public.unlock_achievement(v_user_id, 'uni_bubble_protection', true, p_festival_id,
            jsonb_build_object('tournament_id', v_existing_t_id));
            v_points_total := v_points_total + 1000;
          exception when others then null; end;
        end if;

        -- Primer Torneo
        begin perform public.unlock_achievement(v_user_id, 'uni_first_tournament', true, p_festival_id,
          jsonb_build_object('tournament_id', v_existing_t_id));
          v_points_total := v_points_total + 100;
        exception when others then null; end;

        -- Grand Final
        if v_t_type = 'main_event' and v_is_grand_final then
          begin perform public.unlock_achievement(v_user_id, 'uni_grand_final', true, p_festival_id,
            jsonb_build_object('tournament_id', v_existing_t_id));
            v_points_total := v_points_total + 500;
          exception when others then null; end;
        end if;
      end if;
    end loop;
  end if;

  -- ════════════════════════════════════════════════════════════════
  -- C. MATCH RETROACTIVO de unmatched que ahora tienen user
  -- ════════════════════════════════════════════════════════════════
  if jsonb_array_length(coalesce(p_changes->'matched_unmatched', '[]'::jsonb)) > 0 then
    for v_match in select * from jsonb_array_elements(p_changes->'matched_unmatched')
    loop
      -- Reusamos match_unmatched_player para coherencia
      perform public.match_unmatched_player(
        (v_match->>'participation_id')::uuid,
        (v_match->>'user_id')::uuid
      );
      v_matched_count := v_matched_count + 1;
    end loop;
  end if;

  -- ════════════════════════════════════════════════════════════════
  -- D. POSICIONES MEJORADAS — otorgar diferencia de logros
  -- ════════════════════════════════════════════════════════════════
  if jsonb_array_length(coalesce(p_changes->'improved_positions', '[]'::jsonb)) > 0 then
    for v_improvement in select * from jsonb_array_elements(p_changes->'improved_positions')
    loop
      v_part_id := (v_improvement->>'participation_id')::uuid;

      select tp.user_id, tp.final_position, tp.made_money, tp.made_ft,
             ft.type, coalesce(ft.is_main_tournament, ft.is_main_event, false) as is_main
      into v_loop
      from public.tournament_participations tp
      join public.festival_tournaments ft on ft.id = tp.tournament_id
      where tp.id = v_part_id;

      if not found or v_loop.user_id is null then
        continue;
      end if;

      v_old_pos    := (v_improvement->>'old_position')::int;
      v_new_pos    := (v_improvement->>'new_position')::int;
      v_was_itm    := coalesce((v_improvement->>'was_itm')::bool, false);
      v_now_itm    := coalesce((v_improvement->>'now_itm')::bool, false);
      v_was_ft     := coalesce((v_improvement->>'was_ft')::bool, false);
      v_now_ft     := coalesce((v_improvement->>'now_ft')::bool, false);
      v_was_winner := (v_old_pos = 1);
      v_now_winner := (v_new_pos = 1);
      v_t_type     := v_loop.type;
      v_user_id    := v_loop.user_id;

      -- Actualizar la participation con la nueva posición
      update public.tournament_participations
      set final_position = v_new_pos,
          made_money = v_now_itm,
          made_ft = v_now_ft,
          prize_eur = coalesce((v_improvement->>'prize_eur')::numeric, prize_eur),
          metadata = metadata || jsonb_build_object('reprocessed_at', now(), 'old_position', v_old_pos)
      where id = v_part_id;

      v_improved_count := v_improved_count + 1;

      -- Otorgar diferencia de logros: solo si pasó de no-X a sí-X
      -- (pasar de sí-X a no-X NO se procesa aquí; eso sería destructivo)
      if not v_was_itm and v_now_itm then
        perform public.unlock_achievement(v_user_id, 'rec_itm_hunter', true, p_festival_id,
          jsonb_build_object('tournament_id', v_loop.tournament_id, 'position', v_new_pos, 'reason', 'reprocess_improvement'));
        v_points_total := v_points_total + 200;

        begin perform public.unlock_achievement(v_user_id, 'uni_first_itm', true, p_festival_id,
          jsonb_build_object('tournament_id', v_loop.tournament_id));
          v_points_total := v_points_total + 200;
        exception when others then null; end;

        if v_t_type = 'warm_up' then
          begin perform public.unlock_achievement(v_user_id, 'uni_warm_up_casher', true, p_festival_id, '{}'::jsonb);
            v_points_total := v_points_total + 200;
          exception when others then null; end;
        elsif v_t_type = 'main_event' then
          begin perform public.unlock_achievement(v_user_id, 'uni_main_event_casher', true, p_festival_id, '{}'::jsonb);
            v_points_total := v_points_total + 300;
          exception when others then null; end;
        elsif v_t_type = 'high_roller' then
          begin perform public.unlock_achievement(v_user_id, 'uni_high_roller_casher', true, p_festival_id, '{}'::jsonb);
            v_points_total := v_points_total + 500;
          exception when others then null; end;
        end if;
      end if;

      if not v_was_ft and v_now_ft then
        perform public.unlock_achievement(v_user_id, 'rec_ft_hunter', true, p_festival_id,
          jsonb_build_object('tournament_id', v_loop.tournament_id, 'position', v_new_pos, 'reason', 'reprocess_improvement'));
        v_points_total := v_points_total + 500;

        begin perform public.unlock_achievement(v_user_id, 'uni_first_ft', true, p_festival_id, '{}'::jsonb);
          v_points_total := v_points_total + 500;
        exception when others then null; end;

        if v_t_type = 'warm_up' then
          begin perform public.unlock_achievement(v_user_id, 'uni_warm_up_ft', true, p_festival_id, '{}'::jsonb);
            v_points_total := v_points_total + 500;
          exception when others then null; end;
        elsif v_t_type = 'main_event' then
          begin perform public.unlock_achievement(v_user_id, 'uni_main_event_ft', true, p_festival_id, '{}'::jsonb);
            v_points_total := v_points_total + 700;
          exception when others then null; end;
        elsif v_t_type = 'high_roller' then
          begin perform public.unlock_achievement(v_user_id, 'uni_high_roller_ft', true, p_festival_id, '{}'::jsonb);
            v_points_total := v_points_total + 1000;
          exception when others then null; end;
        end if;
      end if;

      if not v_was_winner and v_now_winner then
        perform public.unlock_achievement(v_user_id, 'rec_trophy_hunter', true, p_festival_id,
          jsonb_build_object('tournament_id', v_loop.tournament_id, 'reason', 'reprocess_improvement'));
        v_points_total := v_points_total + 1000;

        if v_t_type in ('warm_up','main_event','high_roller') then
          begin perform public.unlock_achievement(v_user_id, 'uni_wu_me_hr_champion', true, p_festival_id,
            jsonb_build_object('tournament_type', v_t_type));
            v_points_total := v_points_total + 1000;
          exception when others then null; end;
        end if;

        begin perform public.unlock_achievement(v_user_id, 'uni_first_trophy', true, p_festival_id, '{}'::jsonb);
          v_points_total := v_points_total + 1000;
        exception when others then null; end;
      end if;
    end loop;
  end if;

  -- ════════════════════════════════════════════════════════════════
  -- E. RECALCULAR LOGROS AGREGADOS POR FESTIVAL
  -- ════════════════════════════════════════════════════════════════
  for v_loop in
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
      where tp.festival_id = p_festival_id
        and tp.user_id is not null
        and tp.status in ('matched','awarded')
      group by tp.user_id
    )
    select * from by_user
  loop
    if v_loop.main_types_played >= 3 then
      begin perform public.unlock_achievement(v_loop.user_id, 'uni_triple_threat', true, p_festival_id, '{}'::jsonb);
        v_points_total := v_points_total + 500; v_aggr_logros := v_aggr_logros + 1;
      exception when others then null; end;
    end if;
    if v_loop.money_in_me_hr >= 2 then
      begin perform public.unlock_achievement(v_loop.user_id, 'uni_double_casher', true, p_festival_id, '{}'::jsonb);
        v_points_total := v_points_total + 1000; v_aggr_logros := v_aggr_logros + 1;
      exception when others then null; end;
    end if;
    if v_loop.money_in_wu_me_hr >= 3 then
      begin perform public.unlock_achievement(v_loop.user_id, 'uni_hat_trick', true, p_festival_id, '{}'::jsonb);
        v_points_total := v_points_total + 1000; v_aggr_logros := v_aggr_logros + 1;
      exception when others then null; end;
    end if;
    if v_loop.formats_played >= 3 then
      begin perform public.unlock_achievement(v_loop.user_id, 'uni_mixed_player', true, p_festival_id,
        jsonb_build_object('formats', v_loop.formats_played));
        v_points_total := v_points_total + 2000; v_aggr_logros := v_aggr_logros + 1;
      exception when others then null; end;
    end if;
    if v_loop.tournaments_played >= 7 then
      begin perform public.unlock_achievement(v_loop.user_id, 'uni_grinder', true, p_festival_id,
        jsonb_build_object('tournaments_played', v_loop.tournaments_played));
        v_points_total := v_points_total + 3000; v_aggr_logros := v_aggr_logros + 1;
      exception when others then null; end;
    end if;
    if v_loop.tournaments_played >= 5 and not v_loop.any_itm then
      begin perform public.unlock_achievement(v_loop.user_id, 'uni_resiliencia', true, p_festival_id,
        jsonb_build_object('tournaments_played', v_loop.tournaments_played));
        v_points_total := v_points_total + 2500; v_aggr_logros := v_aggr_logros + 1;
      exception when others then null; end;
    end if;
    if v_loop.bubbles >= 2 then
      begin perform public.unlock_achievement(v_loop.user_id, 'uni_double_bubble', true, p_festival_id,
        jsonb_build_object('bubbles', v_loop.bubbles));
        v_points_total := v_points_total + 1000; v_aggr_logros := v_aggr_logros + 1;
      exception when others then null; end;
    end if;
  end loop;

  -- ════════════════════════════════════════════════════════════════
  -- F. RECALCULAR MVP DEL FESTIVAL
  -- ════════════════════════════════════════════════════════════════
  v_mvp_top_n := coalesce((v_festival.metadata->>'mvp_top_n')::int, 10);

  for v_mvp_user in
    with mvp_agg as (
      select tp.user_id,
        sum(coalesce((tp.metadata->>'mvp_ranking_points')::numeric, 0)) as total_mvp,
        rank() over (order by sum(coalesce((tp.metadata->>'mvp_ranking_points')::numeric, 0)) desc) as mvp_rank
      from public.tournament_participations tp
      where tp.festival_id = p_festival_id
        and tp.user_id is not null
        and tp.status in ('matched','awarded')
        and (tp.metadata->>'mvp_ranking_points')::numeric > 0
      group by tp.user_id
    )
    select * from mvp_agg where mvp_rank <= v_mvp_top_n
  loop
    begin perform public.unlock_achievement(v_mvp_user.user_id, 'rec_mvp_hunter', true, p_festival_id,
      jsonb_build_object('mvp_rank', v_mvp_user.mvp_rank, 'mvp_points', v_mvp_user.total_mvp));
      v_points_total := v_points_total + 1000; v_mvp_logros := v_mvp_logros + 1;
    exception when others then null; end;

    if v_mvp_user.mvp_rank = 1 then
      begin perform public.unlock_achievement(v_mvp_user.user_id, 'uni_mvp_champion', true, p_festival_id,
        jsonb_build_object('mvp_points', v_mvp_user.total_mvp));
        v_points_total := v_points_total + 2000; v_mvp_logros := v_mvp_logros + 1;
      exception when others then null; end;
    end if;
  end loop;

  -- ════════════════════════════════════════════════════════════════
  -- G. RECALCULAR SEASON-LEVEL
  -- ════════════════════════════════════════════════════════════════
  for v_loop in
    with users_in_festival as (
      select distinct user_id from public.tournament_participations
      where festival_id = p_festival_id and user_id is not null and status in ('matched','awarded')
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
    if coalesce(v_loop.tournaments_total, 0) >= 50 then
      begin perform public.unlock_achievement(v_loop.user_id, 'uni_regular_player_50', true, p_festival_id,
        jsonb_build_object('tournaments_total', v_loop.tournaments_total));
        v_points_total := v_points_total + 2000; v_season_logros := v_season_logros + 1;
      exception when others then null; end;
    end if;
    if coalesce(v_loop.tournaments_total, 0) >= 20 then
      begin perform public.unlock_achievement(v_loop.user_id, 'uni_regular_player_20', true, p_festival_id,
        jsonb_build_object('tournaments_total', v_loop.tournaments_total));
        v_points_total := v_points_total + 1000; v_season_logros := v_season_logros + 1;
      exception when others then null; end;
    end if;
    if coalesce(v_loop.itms_total, 0) >= 20 then
      begin perform public.unlock_achievement(v_loop.user_id, 'uni_itm_hunter_20', true, p_festival_id,
        jsonb_build_object('itms_total', v_loop.itms_total));
        v_points_total := v_points_total + 2000; v_season_logros := v_season_logros + 1;
      exception when others then null; end;
    end if;
    if coalesce(v_loop.itms_total, 0) >= 10 then
      begin perform public.unlock_achievement(v_loop.user_id, 'uni_itm_hunter_10', true, p_festival_id,
        jsonb_build_object('itms_total', v_loop.itms_total));
        v_points_total := v_points_total + 1000; v_season_logros := v_season_logros + 1;
      exception when others then null; end;
    end if;
    if coalesce(v_loop.fts_total, 0) >= 10 then
      begin perform public.unlock_achievement(v_loop.user_id, 'uni_ft_hunter_10', true, p_festival_id,
        jsonb_build_object('fts_total', v_loop.fts_total));
        v_points_total := v_points_total + 2000; v_season_logros := v_season_logros + 1;
      exception when others then null; end;
    end if;
    if coalesce(v_loop.fts_total, 0) >= 5 then
      begin perform public.unlock_achievement(v_loop.user_id, 'uni_ft_hunter_5', true, p_festival_id,
        jsonb_build_object('fts_total', v_loop.fts_total));
        v_points_total := v_points_total + 1000; v_season_logros := v_season_logros + 1;
      exception when others then null; end;
    end if;
    if coalesce(v_loop.trophies_total, 0) >= 10 then
      begin perform public.unlock_achievement(v_loop.user_id, 'uni_trophy_hunter_10', true, p_festival_id,
        jsonb_build_object('trophies_total', v_loop.trophies_total));
        v_points_total := v_points_total + 2000; v_season_logros := v_season_logros + 1;
      exception when others then null; end;
    end if;
    if coalesce(v_loop.trophies_total, 0) >= 3 then
      begin perform public.unlock_achievement(v_loop.user_id, 'uni_trophy_hunter_3', true, p_festival_id,
        jsonb_build_object('trophies_total', v_loop.trophies_total));
        v_points_total := v_points_total + 1000; v_season_logros := v_season_logros + 1;
      exception when others then null; end;
    end if;
  end loop;

  -- ════════════════════════════════════════════════════════════════
  -- H. ACTUALIZAR FESTIVAL: marcar como reprocessed_at
  -- ════════════════════════════════════════════════════════════════
  update public.festivals set
    updated_at = now(),
    metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
      'last_reprocessed_at', now(),
      'last_reprocessed_by', v_admin_id
    )
  where id = p_festival_id;

  return jsonb_build_object(
    'festival_id', p_festival_id,
    'tournaments_added', v_tournaments_added,
    'participations_added', v_parts_added,
    'matched_retroactively', v_matched_count,
    'positions_improved', v_improved_count,
    'aggregate_achievements', v_aggr_logros,
    'mvp_achievements', v_mvp_logros,
    'season_achievements', v_season_logros,
    'points_total_granted', v_points_total
  );
end;
$$;

revoke execute on function public.reprocess_festival(uuid, jsonb) from public;
revoke execute on function public.reprocess_festival(uuid, jsonb) from anon;
grant execute on function public.reprocess_festival(uuid, jsonb) to authenticated;

-- Eliminar la versión antigua (1 arg) que era stub
drop function if exists public.reprocess_festival(uuid);


-- Verificación
do $$
declare
  v_count int;
begin
  select count(*) into v_count
  from pg_proc
  where pronamespace = 'public'::regnamespace
    and proname in ('find_festival_by_xlsx', 'reprocess_festival');

  if v_count <> 2 then
    raise exception 'Esperadas 2 funciones, encontradas %', v_count;
  end if;

  raise notice 'find_festival_by_xlsx + reprocess_festival creadas';
end $$;
