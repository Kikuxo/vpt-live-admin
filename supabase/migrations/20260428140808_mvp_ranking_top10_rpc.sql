-- =====================================================================
-- VPT Live — RPC replace_festival_mvp_ranking con soporte TOP 10
-- Fecha: 2026-04-28
--
-- Extiende el RPC existente para aceptar los 4 campos nuevos:
-- top10_position, top10_points, top10_tournaments, in_club.
-- Los 4 son OPCIONALES: si no vienen en el payload, se insertan
-- como NULL/false (compatibilidad con uploads anteriores al fix
-- del admin).
--
-- TOTAL sigue siendo el dato de fallback. La app móvil rankea por
-- top10_position cuando está disponible, y por position (TOTAL)
-- cuando no.
-- =====================================================================

create or replace function public.replace_festival_mvp_ranking(
  p_festival_id uuid,
  p_rows jsonb
) returns void
language plpgsql
security definer
as $$
begin
  if not public.is_admin() then
    raise exception 'Not authorized: requires admin';
  end if;

  delete from public.festival_mvp_ranking
    where festival_id = p_festival_id;

  insert into public.festival_mvp_ranking
    (festival_id, position, name, country_iso, total_points,
     tournaments, prize,
     top10_position, top10_points, top10_tournaments, in_club)
  select
    p_festival_id,
    (r->>'position')::integer,
    r->>'name',
    r->>'country_iso',
    (r->>'total_points')::numeric,
    r->'tournaments',
    r->>'prize',
    nullif(r->>'top10_position', '')::integer,
    nullif(r->>'top10_points', '')::numeric,
    case when r ? 'top10_tournaments' then r->'top10_tournaments' else null end,
    coalesce((r->>'in_club')::boolean, false)
  from jsonb_array_elements(p_rows) as r;
end;
$$;

grant execute on function public.replace_festival_mvp_ranking(uuid, jsonb)
  to authenticated;
