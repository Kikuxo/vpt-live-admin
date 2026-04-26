-- =====================================================================
-- VPT Live — Soporte de decimales en festival_mvp_ranking
-- Fecha: 2026-04-27
--
-- El Excel real del MVP del festival tiene puntos con decimales
-- (361.56, 87.0340..., etc.). Cambiamos total_points de integer a
-- numeric(10,4) para preservar la precisión.
--
-- También recreamos la función RPC replace_festival_mvp_ranking
-- con el cast actualizado a numeric. La función reusa el helper
-- public.is_admin() para autorización dentro del SECURITY DEFINER
-- (evita que clientes anónimos puedan llamarla).
-- =====================================================================

alter table public.festival_mvp_ranking
  alter column total_points type numeric(10,4)
  using total_points::numeric(10,4);

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
    (festival_id, position, name, country_iso, total_points, tournaments, prize)
  select
    p_festival_id,
    (r->>'position')::integer,
    r->>'name',
    r->>'country_iso',
    (r->>'total_points')::numeric,
    r->'tournaments',
    r->>'prize'
  from jsonb_array_elements(p_rows) as r;
end;
$$;

grant execute on function public.replace_festival_mvp_ranking(uuid, jsonb)
  to authenticated;
