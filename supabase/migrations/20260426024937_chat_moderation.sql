-- =====================================================================
-- VPT Live — Moderación del chat
-- Fecha: 2026-04-26
--
-- Cambios:
--   1) live_chat_messages gana deleted_at + deleted_by_email
--      (soft-delete, mensajes invisibles para la app móvil pero
--      visibles en el admin marcados como eliminados).
--   2) Índice parcial WHERE deleted_at IS NULL para que el feed
--      móvil filtre rápido.
--   3) Tabla chat_bans con bans por festival y bans globales
--      (festival_id NULL = global). Dos índices parciales
--      garantizan unicidad en ambos modos sin colisiones por
--      el comportamiento de NULL en UNIQUE.
--   4) RLS chat_bans: lectura pública (clientes pueden verificar);
--      escritura sólo admins (is_admin()).
--   5) Política INSERT de live_chat_messages: requiere que el
--      auth.uid() coincida con user_id Y que NO exista un ban
--      activo (por festival o global) para ese usuario.
--   6) Política UPDATE de live_chat_messages: sólo admins
--      (para soft-delete vía panel web).
--
-- Idempotente: ADD COLUMN IF NOT EXISTS, CREATE TABLE IF NOT
-- EXISTS, DROP POLICY IF EXISTS antes de cada CREATE POLICY.
-- Reusa el helper is_admin() definido en 20260424_players_module.sql.
-- =====================================================================

-- ─── 1. Columnas de soft-delete en live_chat_messages ───────────────
alter table public.live_chat_messages
  add column if not exists deleted_at       timestamptz,
  add column if not exists deleted_by_email text;

-- ─── 2. Índice parcial para query del feed móvil ────────────────────
-- El feed lee con WHERE festival_id = X AND deleted_at IS NULL
-- ORDER BY created_at. Este índice cubre el filtro y el orden.
create index if not exists live_chat_messages_visible_idx
  on public.live_chat_messages (festival_id, created_at desc)
  where deleted_at is null;

-- ─── 3. Tabla chat_bans ─────────────────────────────────────────────
create table if not exists public.chat_bans (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references auth.users(id)  on delete cascade,
  festival_id     uuid          references public.festivals(id) on delete cascade,
  banned_at       timestamptz not null default now(),
  banned_by_email text not null,
  reason          text
);

-- Dos índices parciales para evitar duplicados:
--   · uno por (user_id, festival_id) cuando festival_id no es NULL
--   · otro por user_id cuando festival_id IS NULL (ban global)
-- Razón: el constraint UNIQUE de Postgres trata NULLs como
-- distintos, lo que permitiría múltiples bans globales del
-- mismo usuario.
create unique index if not exists chat_bans_user_festival_unq
  on public.chat_bans (user_id, festival_id)
  where festival_id is not null;

create unique index if not exists chat_bans_user_global_unq
  on public.chat_bans (user_id)
  where festival_id is null;

-- Índice secundario para consultas "¿está baneado este user?"
create index if not exists chat_bans_user_idx
  on public.chat_bans (user_id);

-- ─── 4. RLS chat_bans ───────────────────────────────────────────────
alter table public.chat_bans enable row level security;

drop policy if exists chat_bans_read_public  on public.chat_bans;
drop policy if exists chat_bans_write_admin  on public.chat_bans;

-- Lectura pública: clientes (app móvil) pueden consultar para
-- saber si están baneados antes de mostrar el input. Si solo
-- queremos verificación server-side, también vale; mantenemos
-- abierto para flexibilidad de UX.
create policy chat_bans_read_public on public.chat_bans
  for select using (true);

-- Escritura sólo admins (is_admin() reusa la función helper
-- definida en 20260424_players_module.sql).
create policy chat_bans_write_admin on public.chat_bans
  for all
  using     (public.is_admin())
  with check (public.is_admin());

-- ─── 5. Política INSERT de live_chat_messages con ban-check ─────────
-- Asumimos RLS ya habilitada en la tabla. Reemplazamos cualquier
-- política previa de INSERT por una nueva que añade la comprobación
-- de ban. Coherente con el patrón "auth.uid() = user_id".
alter table public.live_chat_messages enable row level security;

-- Limpieza de políticas viejas DUPLICADAS de versiones previas del
-- esquema (chat sin moderación). Postgres evalúa políticas RLS como
-- OR entre todas las que apliquen al mismo comando: si dejamos las
-- viejas activas, su WITH CHECK (sin comprobación de chat_bans)
-- permitía el INSERT pese a la nueva. Bug detectado en producción
-- 2026-04-26 — usuarios baneados podían seguir escribiendo. El fix
-- son estos DROP IF EXISTS: idempotentes, no rompen nada en envs
-- limpios donde estas políticas nunca existieron.
drop policy if exists chat_insert on public.live_chat_messages;
drop policy if exists chat_read   on public.live_chat_messages;

drop policy if exists live_chat_messages_insert_authenticated
  on public.live_chat_messages;

create policy live_chat_messages_insert_authenticated
  on public.live_chat_messages
  for insert
  to authenticated
  with check (
    auth.uid() = user_id
    and not exists (
      select 1 from public.chat_bans b
      where b.user_id = auth.uid()
        and (b.festival_id = live_chat_messages.festival_id
             or b.festival_id is null)
    )
  );

-- ─── 6. Política UPDATE de live_chat_messages (soft-delete admin) ───
drop policy if exists live_chat_messages_update_admin
  on public.live_chat_messages;

create policy live_chat_messages_update_admin
  on public.live_chat_messages
  for update
  using     (public.is_admin())
  with check (public.is_admin());

-- ─── 7. Política SELECT (asegurar lectura pública) ──────────────────
-- Los mensajes son lectura abierta como hasta ahora. La app móvil
-- filtrará deleted_at IS NULL en el cliente; el admin verá todos.
drop policy if exists live_chat_messages_read_public
  on public.live_chat_messages;

create policy live_chat_messages_read_public
  on public.live_chat_messages
  for select using (true);

-- ─── 8. Grants ──────────────────────────────────────────────────────
grant select on public.chat_bans to anon, authenticated;
grant insert, update, delete on public.chat_bans to authenticated;

-- live_chat_messages no necesita re-grants: ya están aplicados.
