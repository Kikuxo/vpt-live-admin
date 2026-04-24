-- =====================================================================
-- VPT Live — Vídeos por festival (sólo YouTube por ahora)
-- Fecha: 2026-04-25
--
-- Crea:
--   - festival_videos    catálogo de vídeos asociados a un festival
--
-- Lectura pública (anon) para la app móvil; escritura sólo admins
-- (usuarios con fila en live_admins, vía is_admin()).
-- =====================================================================

create table if not exists public.festival_videos (
  id            uuid primary key default gen_random_uuid(),
  festival_id   uuid not null references public.festivals(id) on delete cascade,
  youtube_id    text not null,             -- "dQw4w9WgXcQ"
  url           text not null,             -- URL completa pegada
  title         text not null,
  thumbnail_url text,
  "position"    integer not null default 0,
  created_at    timestamptz not null default now()
);

create index if not exists festival_videos_festival_idx
  on public.festival_videos (festival_id, "position");

alter table public.festival_videos enable row level security;

drop policy if exists festival_videos_read_public on public.festival_videos;
drop policy if exists festival_videos_write_admin on public.festival_videos;
create policy festival_videos_read_public on public.festival_videos
  for select using (true);
create policy festival_videos_write_admin on public.festival_videos
  for all using (public.is_admin()) with check (public.is_admin());

do $$ begin
  alter publication supabase_realtime add table public.festival_videos;
exception when duplicate_object then null; end $$;

grant select on public.festival_videos to anon, authenticated;
grant insert, update, delete on public.festival_videos to authenticated;
