-- ============================================================================
-- VIP System v2 — Revocar EXECUTE de PUBLIC en RPCs VIP (security hardening)
-- Fecha: 2026-04-30 15:01
--
-- Contexto:
--   Postgres concede automáticamente EXECUTE a PUBLIC al crear una función
--   con CREATE FUNCTION. PUBLIC es un meta-rol que incluye TODOS los roles
--   (anon, authenticated, etc.).
--
--   Aunque la migración 20260430150000 hizo `revoke ... from anon`, esto no
--   tuvo efecto: anon nunca tuvo un grant directo, su acceso a las funciones
--   se heredaba de PUBLIC. Por eso has_function_privilege('anon', ...)
--   devolvía true incluso después del revoke from anon.
--
--   Esta migración cierra el agujero revocando explícitamente de PUBLIC,
--   y reasegurando los grants para authenticated.
--
-- Resultado esperado:
--   - authenticated: SÍ puede ejecutar las 6 funciones VIP
--   - anon: NO puede ejecutar ninguna (queda denegado por defecto al perder
--           la herencia de PUBLIC)
-- ============================================================================

-- 1. Revocar EXECUTE de PUBLIC sobre las 6 funciones VIP
revoke execute on function public.add_points(uuid, int, text, text, uuid, jsonb, text, uuid, bool) from public;
revoke execute on function public.redeem_points(uuid, int, text, text, jsonb) from public;
revoke execute on function public.recalculate_vip_level(uuid) from public;
revoke execute on function public.expire_old_points() from public;
revoke execute on function public.start_new_season(int) from public;
revoke execute on function public.apply_participation_points(uuid) from public;

-- 2. Reasegurar EXECUTE para 'authenticated' (idempotente)
grant execute on function public.add_points(uuid, int, text, text, uuid, jsonb, text, uuid, bool) to authenticated;
grant execute on function public.redeem_points(uuid, int, text, text, jsonb) to authenticated;
grant execute on function public.recalculate_vip_level(uuid) to authenticated;
grant execute on function public.expire_old_points() to authenticated;
grant execute on function public.start_new_season(int) to authenticated;
grant execute on function public.apply_participation_points(uuid) to authenticated;

-- 3. Verificación
do $$
declare
  v_auth_count int;
  v_anon_count int;
begin
  select count(*) into v_auth_count
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('add_points','redeem_points','recalculate_vip_level',
                      'expire_old_points','start_new_season','apply_participation_points')
    and has_function_privilege('authenticated', p.oid, 'EXECUTE');

  select count(*) into v_anon_count
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('add_points','redeem_points','recalculate_vip_level',
                      'expire_old_points','start_new_season','apply_participation_points')
    and has_function_privilege('anon', p.oid, 'EXECUTE');

  raise notice 'authenticated puede ejecutar: % de 6 funciones VIP', v_auth_count;
  raise notice 'anon puede ejecutar:          % de 6 funciones VIP (esperado: 0)', v_anon_count;

  if v_anon_count > 0 then
    raise exception 'SECURITY: anon todavía puede ejecutar funciones VIP';
  end if;
end $$;
