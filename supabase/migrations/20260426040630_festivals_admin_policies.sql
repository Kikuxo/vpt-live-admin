-- =====================================================================
-- VPT Live — Políticas RLS para gestión de festivales desde admin web.
-- Fecha: 2026-04-27
--
-- Contexto: festivals tiene RLS habilitada pero solo política SELECT
-- (Public read). INSERT/UPDATE fallan desde el admin web por el
-- comportamiento por defecto de RLS (deny).
--
-- Esta migración añade políticas is_admin() para permitir que
-- moderadores autenticados creen y editen festivales desde el panel
-- web. Reusa el helper public.is_admin() definido en
-- 20260424_players_module.sql.
--
-- NO se añade DELETE: los festivales tienen datos asociados
-- (live_updates, festival_players, live_chat_messages, chat_bans,
-- festival_videos, etc.) que se borrarían en cascada. El borrado
-- queda como acción manual desde el dashboard de Supabase.
--
-- Idempotente: DROP POLICY IF EXISTS antes de cada CREATE POLICY.
-- =====================================================================

drop policy if exists festivals_insert_admin on public.festivals;
create policy festivals_insert_admin on public.festivals
  for insert
  with check (public.is_admin());

drop policy if exists festivals_update_admin on public.festivals;
create policy festivals_update_admin on public.festivals
  for update
  using     (public.is_admin())
  with check (public.is_admin());
