-- =====================================================================
-- VPT Live — Soporte de TOP 10 en festival_mvp_ranking (schema)
-- Fecha: 2026-04-28
--
-- El ranking real del MVP del festival es el TOP 10 del Club VPT
-- (10 mejores resultados de cada jugador entre los 12 torneos del
-- festival), NO el TOTAL (suma de todos los torneos). Hasta ahora
-- la tabla solo guardaba los datos del TOTAL; este commit añade
-- las columnas para guardar también el TOP 10 sin tirar el TOTAL
-- (lo seguimos necesitando como fallback y como dato anexo).
--
-- Las 4 columnas nuevas son nullables (excepto in_club, BOOLEAN
-- NOT NULL DEFAULT false) por compatibilidad con datos antiguos.
-- La app móvil hará fallback al TOTAL cuando top10_* sean null.
--
-- El RPC replace_festival_mvp_ranking se actualiza en una migración
-- aparte (20260428_mvp_ranking_top10_rpc.sql) tras confirmar el
-- shape de los datos que envía el admin web.
-- =====================================================================

alter table public.festival_mvp_ranking
  add column if not exists top10_position integer null,
  add column if not exists top10_points numeric(10,4) null,
  add column if not exists top10_tournaments jsonb null,
  add column if not exists in_club boolean not null default false;

-- Index para el orden frecuente del ranking visible en la app
-- (festival + top10_position asc). Partial: filas sin top10
-- (datos antiguos) no entran al índice — se resuelven por fallback
-- al TOTAL en cliente, sin tocar este índice.
create index if not exists festival_mvp_ranking_top10_idx
  on public.festival_mvp_ranking (festival_id, top10_position)
  where top10_position is not null;
