-- =====================================================================
-- VPT Live — Soft-archive de festivales
-- Fecha: 2026-04-27
--
-- Añade columna archived_at para soft-archive reversible. NULL = activo,
-- timestamp = archivado en esa fecha. El admin puede archivar y
-- reactivar desde el panel; los datos asociados (live_updates, chat,
-- chipcounts, festival_videos, festival_players, etc.) se preservan
-- intactos.
--
-- La política festivals_update_admin existente (20260427_festivals_admin_
-- policies.sql) cubre el UPDATE de archived_at sin policy adicional.
--
-- Idempotente: ADD COLUMN IF NOT EXISTS + CREATE INDEX IF NOT EXISTS.
-- =====================================================================

alter table public.festivals
  add column if not exists archived_at timestamptz null;

-- Índice parcial para el query del select normal (festivales activos).
-- Cubre el filtro WHERE archived_at IS NULL + el orden por starts_at desc.
create index if not exists festivals_active_idx
  on public.festivals (starts_at desc nulls last)
  where archived_at is null;
