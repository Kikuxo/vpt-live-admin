-- ============================================================================
-- VIP System v2 — RLS de admin sobre redemptions
-- Fecha: 2026-04-30 21:00
--
-- Contexto:
--   La tabla redemptions tenía solo una política RLS:
--     red_select_own: el user ve solo sus propios canjes (auth.uid() = user_id)
--
--   Esto es correcto para users normales en la app, pero impide que el panel
--   admin (vpt-vip-admin) liste todos los canjes para gestionarlos.
--
-- Solución:
--   Añadir 2 políticas adicionales para admins (live_admins):
--     - "admin_ve_todos_canjes" — SELECT sin restricción si is_admin()
--     - "admin_actualiza_canjes" — UPDATE sin restricción si is_admin()
--
--   El UPDATE permite que el admin cambie status, rejection_reason, etc.
--   directamente. La RPC process_redemption usa SECURITY DEFINER, así que
--   en realidad no necesita esta policy, pero la añadimos por si acaso el
--   frontend hace algún UPDATE directo en el futuro.
-- ============================================================================

-- 1. Política SELECT para admins
drop policy if exists admin_ve_todos_canjes on public.redemptions;
create policy admin_ve_todos_canjes on public.redemptions
  for select
  to authenticated
  using (public.is_admin());

-- 2. Política UPDATE para admins (defensiva — la RPC ya usa SECURITY DEFINER)
drop policy if exists admin_actualiza_canjes on public.redemptions;
create policy admin_actualiza_canjes on public.redemptions
  for update
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- Verificación
do $$
declare
  v_count int;
begin
  select count(*) into v_count
  from pg_policies
  where schemaname = 'public' and tablename = 'redemptions';

  raise notice 'redemptions tiene ahora % policies (esperado: 3+ — red_select_own + 2 nuevas de admin)', v_count;

  if v_count < 3 then
    raise exception 'esperadas al menos 3 policies, encontradas %', v_count;
  end if;
end $$;
