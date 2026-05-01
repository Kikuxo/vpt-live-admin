-- ============================================================================
-- Fix: replace_mvp_ranking ahora usa is_staff_or_admin() en lugar de live_admins
-- Fecha: 2026-05-01 19:30
--
-- La tabla live_admins fue eliminada en migration 20260501190000. Esta función
-- aún la consultaba directamente y daría error si alguien la llama.
-- Aprovechamos para añadir auditoría.
-- ============================================================================

create or replace function public.replace_mvp_ranking(p_festival_id uuid, p_rows jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare
  row_data jsonb;
  new_ranking_id uuid;
  tournament jsonb;
  idx int;
  v_rows_count int;
begin
  -- Verificar permisos: staff o admin
  if not public.is_staff_or_admin() then
    raise exception 'Solo staff o admin pueden modificar el ranking MVP';
  end if;

  v_rows_count := jsonb_array_length(coalesce(p_rows, '[]'::jsonb));

  -- Borrar ranking anterior del festival (cascade borra tournament_points)
  delete from public.mvp_rankings where festival_id = p_festival_id;

  -- Insertar nuevas filas
  for row_data in select * from jsonb_array_elements(p_rows)
  loop
    insert into public.mvp_rankings(
      festival_id, vpt_id, position, player_name, country_code, total_points
    ) values (
      p_festival_id,
      row_data->>'vpt_id',
      (row_data->>'position')::int,
      row_data->>'player_name',
      row_data->>'country_code',
      (row_data->>'total_points')::numeric
    ) returning id into new_ranking_id;

    idx := 0;
    for tournament in select * from jsonb_array_elements(row_data->'tournaments')
    loop
      insert into public.mvp_tournament_points(
        ranking_id, tournament_name, points, display_order
      ) values (
        new_ranking_id,
        tournament->>'name',
        (tournament->>'points')::numeric,
        idx
      );
      idx := idx + 1;
    end loop;
  end loop;

  -- Auditoría
  perform public._log_admin_activity(
    'replace_mvp_ranking',
    'festival',
    p_festival_id,
    jsonb_build_object('rows_count', v_rows_count)
  );
end;
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- Verificación
-- ════════════════════════════════════════════════════════════════════════════
do $$
declare
  v_def text;
begin
  v_def := pg_get_functiondef('public.replace_mvp_ranking'::regproc);

  if v_def ilike '%live_admins%' then
    raise exception 'replace_mvp_ranking aún referencia live_admins';
  end if;

  if v_def not ilike '%is_staff_or_admin%' then
    raise exception 'replace_mvp_ranking no usa is_staff_or_admin()';
  end if;

  raise notice 'replace_mvp_ranking actualizada correctamente';
end $$;
