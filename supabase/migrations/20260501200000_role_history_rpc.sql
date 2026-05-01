-- ============================================================================
-- RPC: get_role_change_history
-- Devuelve el histórico de cambios de role enriquecido con emails (en lugar
-- de solo UUIDs). Solo admin puede ejecutarla.
--
-- Usado por el panel "Gestión de Personal" para mostrar la auditoría.
-- ============================================================================

create or replace function public.get_role_change_history(p_limit int default 100)
returns table (
  id            bigint,
  target_user   uuid,
  target_email  text,
  target_name   text,
  old_role      text,
  new_role      text,
  changed_by    uuid,
  changed_by_email text,
  reason        text,
  changed_at    timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    rcl.id,
    rcl.target_user,
    tu.email as target_email,
    tu.name as target_name,
    rcl.old_role,
    rcl.new_role,
    rcl.changed_by,
    cb.email as changed_by_email,
    rcl.reason,
    rcl.changed_at
  from public.role_change_log rcl
  left join public.users tu on tu.id = rcl.target_user
  left join public.users cb on cb.id = rcl.changed_by
  where public.is_admin()
  order by rcl.id desc
  limit greatest(p_limit, 1);
$$;

-- Verificación
do $$
begin
  raise notice 'get_role_change_history creada';
end $$;
