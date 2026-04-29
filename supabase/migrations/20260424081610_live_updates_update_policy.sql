-- =====================================================================
-- VPT Live — Política RLS de UPDATE para live_updates
-- Fecha: 2026-04-24
--
-- Contexto:
-- live_updates tenía policies para SELECT / INSERT / DELETE pero NO
-- tenía policy de UPDATE, por lo que cualquier `update ... where id = X`
-- del admin se ejecutaba sin error pero afectaba 0 filas (RLS default-deny
-- silenciosa). Eso bloqueaba la edición de posts desde el panel.
--
-- Esta migration añade la policy que faltaba, siguiendo el mismo patrón
-- inline EXISTS contra live_admins que usan las policies vecinas
-- (live_updates_insert, live_updates_delete, live_updates_read).
--
-- Es idempotente — drop if exists + create, se puede re-ejecutar.
-- =====================================================================

alter table public.live_updates enable row level security;

drop policy if exists live_updates_update       on public.live_updates;
drop policy if exists live_updates_update_admin on public.live_updates;  -- nombre anterior, por si ya se aplicó una versión previa

create policy live_updates_update on public.live_updates
  for update
  to authenticated
  using (
    exists (
      select 1 from public.live_admins
      where live_admins.user_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1 from public.live_admins
      where live_admins.user_id = auth.uid()
    )
  );
