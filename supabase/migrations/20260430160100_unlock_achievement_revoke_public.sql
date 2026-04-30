-- ============================================================================
-- VIP System v2 — Revocar EXECUTE de PUBLIC en unlock_achievement
-- Fecha: 2026-04-30 16:01
--
-- La migración 20260430160000 creó la función unlock_achievement, pero el
-- revoke from public dentro del mismo statement no aplicó por completo
-- (mismo comportamiento que vimos con las 6 funciones VIP del baseline).
--
-- Esta migración cierra el agujero revocando explícitamente de PUBLIC y
-- reasegurando el grant a authenticated.
-- ============================================================================

revoke execute on function public.unlock_achievement(uuid, text, bool, uuid, jsonb) from public;
revoke execute on function public.unlock_achievement(uuid, text, bool, uuid, jsonb) from anon;
grant execute on function public.unlock_achievement(uuid, text, bool, uuid, jsonb) to authenticated;

-- Verificación
do $$
declare
  v_auth bool;
  v_anon bool;
begin
  v_auth := has_function_privilege('authenticated', 'public.unlock_achievement(uuid, text, bool, uuid, jsonb)', 'EXECUTE');
  v_anon := has_function_privilege('anon',          'public.unlock_achievement(uuid, text, bool, uuid, jsonb)', 'EXECUTE');
  raise notice 'unlock_achievement: authenticated=% anon=% (esperado: t / f)', v_auth, v_anon;
end $$;
