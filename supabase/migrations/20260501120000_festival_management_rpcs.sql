-- ============================================================================
-- VIP System v2 — Festivales: RPCs para gestión post-procesamiento
-- Fecha: 2026-05-01 12:00
--
-- 3 RPCs nuevas:
--
--  1. match_unmatched_player(p_participation_id, p_user_id):
--     Matchea manualmente un jugador unmatched a un user del sistema.
--     Si el festival ya está procesado, otorga puntos retroactivamente.
--
--  2. revert_festival(p_festival_id):
--     Revierte completamente el procesamiento de un festival:
--     - Crea transacciones 'correction' que restan los puntos otorgados
--     - Borra user_achievements con metadata.festival_id = X
--     - Resetea participations.status a 'pending' y user_id = null
--     - Marca festival como 'draft' de nuevo
--
--  3. reprocess_festival(p_festival_id):
--     Esqueleto inicial: solo procesa los unmatched que ahora se han
--     matcheado manualmente. Lógica completa de re-subida XLSX queda para
--     futura iteración.
-- ============================================================================

-- ════════════════════════════════════════════════════════════════════════════
-- 1. match_unmatched_player
-- ════════════════════════════════════════════════════════════════════════════

create or replace function public.match_unmatched_player(
  p_participation_id uuid,
  p_user_id          uuid
) returns jsonb language plpgsql security definer as $$
declare
  v_part           record;
  v_user           record;
  v_festival       record;
  v_admin_id       uuid;
  v_points_granted int := 0;
  v_logros_count   int := 0;
  v_t              record;
  v_is_grand_final bool;
  v_other_in_fest  record;
  v_summary        jsonb;
begin
  v_admin_id := auth.uid();

  -- 1. Cargar la participation
  select tp.*, ft.type as t_type, ft.name as t_name,
         coalesce(ft.is_main_tournament, ft.is_main_event, false) as is_main,
         ft.format as t_format
  into v_part
  from public.tournament_participations tp
  join public.festival_tournaments ft on ft.id = tp.tournament_id
  where tp.id = p_participation_id
  for update;

  if not found then
    raise exception 'match_unmatched_player: participation % no existe', p_participation_id;
  end if;

  if v_part.user_id is not null then
    raise exception 'match_unmatched_player: la participation ya está matcheada al user %', v_part.user_id;
  end if;

  -- 2. Cargar el user destino
  select * into v_user from public.users where id = p_user_id;
  if not found then
    raise exception 'match_unmatched_player: user % no existe', p_user_id;
  end if;

  -- 3. Cargar el festival
  select * into v_festival from public.festivals where id = v_part.festival_id;
  v_is_grand_final := coalesce(v_festival.is_grand_final, false);

  -- 4. Si hay OTRAS participations del mismo player en el festival con misma
  --    name pero ya matched (improbable pero posible), buscamos al user.
  --    En este caso simplemente actualizamos esta entry.

  -- 5. Match: actualizar user_id y status
  update public.tournament_participations
  set user_id = p_user_id,
      status = case when v_festival.status = 'processed' then 'awarded' else 'matched' end
  where id = p_participation_id;

  -- 6. Si el festival YA fue procesado, otorgar puntos retroactivamente.
  --    Aplicamos solo los logros INMEDIATOS por participation (los del bloque A
  --    de process_festival). Los agregados por festival y season-level se
  --    pueden recalcular después con reprocess_festival si se desea.
  if v_festival.status = 'processed' then
    -- Para evaluar best_position: agrupar TODAS las entries del player en este torneo
    -- (incluyendo la recién matcheada).
    select
      min(tp.final_position) as best_position,
      bool_or(tp.made_money) as made_money,
      bool_or(tp.made_ft) as made_ft,
      max(tp.prize_eur) as prize_eur,
      bool_or(coalesce((tp.metadata->>'is_bubble')::bool, false)) as is_bubble
    into v_t
    from public.tournament_participations tp
    where tp.tournament_id = v_part.tournament_id and tp.user_id = p_user_id;

    -- a) "A jugar!"
    perform public.unlock_achievement(p_user_id, 'rec_play_tournament', true, v_part.festival_id,
      jsonb_build_object('tournament_id', v_part.tournament_id, 'tournament_type', v_part.t_type,
        'tournament_name', v_part.t_name, 'best_position', v_t.best_position, 'source', 'manual_match'));
    v_points_granted := v_points_granted + 100; v_logros_count := v_logros_count + 1;

    -- b) Torneo principal
    if v_part.is_main then
      update public.users set season_main_tournaments = coalesce(season_main_tournaments, 0) + 1
      where id = p_user_id;
    end if;

    -- c) ITM
    if v_t.made_money then
      perform public.unlock_achievement(p_user_id, 'rec_itm_hunter', true, v_part.festival_id,
        jsonb_build_object('tournament_id', v_part.tournament_id, 'position', v_t.best_position, 'prize_eur', v_t.prize_eur));
      v_points_granted := v_points_granted + 200; v_logros_count := v_logros_count + 1;

      begin perform public.unlock_achievement(p_user_id, 'uni_first_itm', true, v_part.festival_id,
        jsonb_build_object('tournament_id', v_part.tournament_id));
        v_points_granted := v_points_granted + 200; v_logros_count := v_logros_count + 1;
      exception when others then null; end;

      if v_part.t_type = 'warm_up' then
        begin perform public.unlock_achievement(p_user_id, 'uni_warm_up_casher', true, v_part.festival_id,
          jsonb_build_object('tournament_id', v_part.tournament_id));
          v_points_granted := v_points_granted + 200; v_logros_count := v_logros_count + 1;
        exception when others then null; end;
      elsif v_part.t_type = 'main_event' then
        begin perform public.unlock_achievement(p_user_id, 'uni_main_event_casher', true, v_part.festival_id,
          jsonb_build_object('tournament_id', v_part.tournament_id));
          v_points_granted := v_points_granted + 300; v_logros_count := v_logros_count + 1;
        exception when others then null; end;
      elsif v_part.t_type = 'high_roller' then
        begin perform public.unlock_achievement(p_user_id, 'uni_high_roller_casher', true, v_part.festival_id,
          jsonb_build_object('tournament_id', v_part.tournament_id));
          v_points_granted := v_points_granted + 500; v_logros_count := v_logros_count + 1;
        exception when others then null; end;
      end if;
    end if;

    -- d) FT
    if v_t.made_ft then
      perform public.unlock_achievement(p_user_id, 'rec_ft_hunter', true, v_part.festival_id,
        jsonb_build_object('tournament_id', v_part.tournament_id, 'position', v_t.best_position));
      v_points_granted := v_points_granted + 500; v_logros_count := v_logros_count + 1;

      begin perform public.unlock_achievement(p_user_id, 'uni_first_ft', true, v_part.festival_id,
        jsonb_build_object('tournament_id', v_part.tournament_id));
        v_points_granted := v_points_granted + 500; v_logros_count := v_logros_count + 1;
      exception when others then null; end;

      if v_part.t_type = 'warm_up' then
        begin perform public.unlock_achievement(p_user_id, 'uni_warm_up_ft', true, v_part.festival_id,
          jsonb_build_object('tournament_id', v_part.tournament_id));
          v_points_granted := v_points_granted + 500; v_logros_count := v_logros_count + 1;
        exception when others then null; end;
      elsif v_part.t_type = 'main_event' then
        begin perform public.unlock_achievement(p_user_id, 'uni_main_event_ft', true, v_part.festival_id,
          jsonb_build_object('tournament_id', v_part.tournament_id));
          v_points_granted := v_points_granted + 700; v_logros_count := v_logros_count + 1;
        exception when others then null; end;
      elsif v_part.t_type = 'high_roller' then
        begin perform public.unlock_achievement(p_user_id, 'uni_high_roller_ft', true, v_part.festival_id,
          jsonb_build_object('tournament_id', v_part.tournament_id));
          v_points_granted := v_points_granted + 1000; v_logros_count := v_logros_count + 1;
        exception when others then null; end;
      end if;
    end if;

    -- e) Trophy
    if v_t.best_position = 1 then
      perform public.unlock_achievement(p_user_id, 'rec_trophy_hunter', true, v_part.festival_id,
        jsonb_build_object('tournament_id', v_part.tournament_id, 'tournament_name', v_part.t_name));
      v_points_granted := v_points_granted + 1000; v_logros_count := v_logros_count + 1;

      if v_part.t_type in ('warm_up','main_event','high_roller') then
        begin perform public.unlock_achievement(p_user_id, 'uni_wu_me_hr_champion', true, v_part.festival_id,
          jsonb_build_object('tournament_id', v_part.tournament_id, 'tournament_type', v_part.t_type));
          v_points_granted := v_points_granted + 1000; v_logros_count := v_logros_count + 1;
        exception when others then null; end;
      end if;

      begin perform public.unlock_achievement(p_user_id, 'uni_first_trophy', true, v_part.festival_id,
        jsonb_build_object('tournament_id', v_part.tournament_id));
        v_points_granted := v_points_granted + 1000; v_logros_count := v_logros_count + 1;
      exception when others then null; end;
    end if;

    -- f) Bubble
    if v_t.is_bubble and v_part.t_type = 'main_event' then
      begin perform public.unlock_achievement(p_user_id, 'uni_bubble_protection', true, v_part.festival_id,
        jsonb_build_object('tournament_id', v_part.tournament_id));
        v_points_granted := v_points_granted + 1000; v_logros_count := v_logros_count + 1;
      exception when others then null; end;
    end if;

    -- g) Primer Torneo
    begin perform public.unlock_achievement(p_user_id, 'uni_first_tournament', true, v_part.festival_id,
      jsonb_build_object('tournament_id', v_part.tournament_id));
      v_points_granted := v_points_granted + 100; v_logros_count := v_logros_count + 1;
    exception when others then null; end;

    -- h) Grand Final
    if v_part.t_type = 'main_event' and v_is_grand_final then
      begin perform public.unlock_achievement(p_user_id, 'uni_grand_final', true, v_part.festival_id,
        jsonb_build_object('tournament_id', v_part.tournament_id));
        v_points_granted := v_points_granted + 500; v_logros_count := v_logros_count + 1;
      exception when others then null; end;
    end if;
  end if;

  v_summary := jsonb_build_object(
    'participation_id', p_participation_id,
    'user_id', p_user_id,
    'festival_status', v_festival.status,
    'logros_count', v_logros_count,
    'points_granted', v_points_granted
  );

  return v_summary;
end;
$$;

revoke execute on function public.match_unmatched_player(uuid, uuid) from public;
revoke execute on function public.match_unmatched_player(uuid, uuid) from anon;
grant execute on function public.match_unmatched_player(uuid, uuid) to authenticated;


-- ════════════════════════════════════════════════════════════════════════════
-- 2. revert_festival
-- ════════════════════════════════════════════════════════════════════════════

create or replace function public.revert_festival(
  p_festival_id uuid
) returns jsonb language plpgsql security definer as $$
declare
  v_festival     record;
  v_admin_id     uuid;
  v_tx           record;
  v_corrections  int := 0;
  v_points_back  int := 0;
  v_ach_deleted  int := 0;
  v_parts_reset  int := 0;
begin
  v_admin_id := auth.uid();

  select * into v_festival from public.festivals where id = p_festival_id for update;
  if not found then
    raise exception 'revert_festival: festival % no existe', p_festival_id;
  end if;

  -- 1. Para cada point_transaction asociada (vía user_achievements
  --    o vía metadata.festival_id), crear una correction inversa.
  for v_tx in
    select pt.id, pt.user_id, pt.points_final
    from public.point_transactions pt
    where pt.metadata->>'festival_id' = p_festival_id::text
      or pt.id in (
        select points_transaction_id from public.user_achievements
        where festival_id = p_festival_id and points_transaction_id is not null
      )
  loop
    -- Crear correction (puntos negativos)
    perform public.add_points(
      p_user_id := v_tx.user_id,
      p_base_points := -v_tx.points_final,
      p_type := 'correction',
      p_description := format('Reversión festival "%s"', v_festival.title),
      p_metadata := jsonb_build_object('festival_id', p_festival_id, 'reverts_tx', v_tx.id),
      p_source_type := 'festival_revert',
      p_source_id := p_festival_id
    );
    v_corrections := v_corrections + 1;
    v_points_back := v_points_back + v_tx.points_final;
  end loop;

  -- 2. Borrar user_achievements del festival
  delete from public.user_achievements
  where festival_id = p_festival_id;
  GET DIAGNOSTICS v_ach_deleted = ROW_COUNT;

  -- 3. Resetear participations
  update public.tournament_participations
  set user_id = null, status = 'pending'
  where festival_id = p_festival_id;
  GET DIAGNOSTICS v_parts_reset = ROW_COUNT;

  -- 4. Resetear festival a draft
  update public.festivals set
    status = 'draft',
    processed_at = null,
    processed_by = null,
    updated_at = now(),
    metadata = coalesce(metadata, '{}'::jsonb) - 'processed_summary'
      || jsonb_build_object('reverted_at', now(), 'reverted_by', v_admin_id)
  where id = p_festival_id;

  return jsonb_build_object(
    'festival_id', p_festival_id,
    'corrections_created', v_corrections,
    'points_returned', v_points_back,
    'achievements_deleted', v_ach_deleted,
    'participations_reset', v_parts_reset
  );
end;
$$;

revoke execute on function public.revert_festival(uuid) from public;
revoke execute on function public.revert_festival(uuid) from anon;
grant execute on function public.revert_festival(uuid) to authenticated;


-- ════════════════════════════════════════════════════════════════════════════
-- 3. reprocess_festival (esqueleto)
-- ════════════════════════════════════════════════════════════════════════════
-- Por ahora solo recalcula logros agregados y season-level del festival.
-- La re-subida de XLSX completa queda para futura iteración.

create or replace function public.reprocess_festival(
  p_festival_id uuid
) returns jsonb language plpgsql security definer as $$
declare
  v_festival     record;
  v_msg          text;
begin
  select * into v_festival from public.festivals where id = p_festival_id for update;
  if not found then
    raise exception 'reprocess_festival: festival % no existe', p_festival_id;
  end if;

  if v_festival.status <> 'processed' then
    raise exception 'reprocess_festival: festival "%" no está procesado todavía. Usa process_festival.', v_festival.title;
  end if;

  -- Por ahora solo retorna un mensaje placeholder. La lógica completa de
  -- comparación XLSX vs participations existentes queda para iteración futura.
  v_msg := 'reprocess_festival: aún no implementado. Para corregir errores, '
        || 'usa revert_festival y vuelve a procesar el XLSX corregido.';

  return jsonb_build_object(
    'festival_id', p_festival_id,
    'status', 'not_implemented',
    'message', v_msg
  );
end;
$$;

revoke execute on function public.reprocess_festival(uuid) from public;
revoke execute on function public.reprocess_festival(uuid) from anon;
grant execute on function public.reprocess_festival(uuid) to authenticated;


-- Verificación
do $$
declare
  v_count int;
begin
  select count(*) into v_count
  from pg_proc
  where pronamespace = 'public'::regnamespace
    and proname in ('match_unmatched_player', 'revert_festival', 'reprocess_festival');

  if v_count <> 3 then
    raise exception 'Esperadas 3 funciones, encontradas %', v_count;
  end if;

  raise notice '3 RPCs de gestión de festivales creadas: match_unmatched_player, revert_festival, reprocess_festival';
end $$;
