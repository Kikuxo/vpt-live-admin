-- ============================================================================
-- VIP System v2 — Admin RLS para point_transactions
-- Fecha: 2026-05-01 00:00
--
-- Bug detectado: la única policy SELECT en point_transactions era
-- "usuario ve sus puntos" con auth.uid() = user_id, lo que impedía a los
-- admins (vpt-vip-admin) ver el log de puntos de otros users.
--
-- Solución: añadir una policy adicional para admins, igual que se hizo con
-- redemptions y users.
-- ============================================================================

drop policy if exists admin_ve_todas_transacciones on public.point_transactions;
create policy admin_ve_todas_transacciones on public.point_transactions
  for select
  to authenticated
  using (public.is_admin());

-- Verificación
do $$
declare
  v_count int;
begin
  select count(*) into v_count
  from pg_policies
  where schemaname = 'public' and tablename = 'point_transactions'
    and policyname = 'admin_ve_todas_transacciones';

  if v_count <> 1 then
    raise exception 'Policy admin_ve_todas_transacciones no se creó correctamente';
  end if;
  raise notice 'Policy admin_ve_todas_transacciones creada en point_transactions';
end $$;
