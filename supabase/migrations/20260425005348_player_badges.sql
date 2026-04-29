-- =====================================================================
-- VPT Live — Badges de jugador (tags reutilizables)
-- Fecha: 2026-04-24
--
-- Crea:
--   - player_badges              catálogo de badges (label único + color)
--   - player_badge_assignments   pivote player <-> badge
--
-- Lectura pública (anon) para la app móvil; escritura sólo admins
-- (usuarios con fila en live_admins, vía is_admin()).
-- =====================================================================

-- ─── player_badges ──────────────────────────────────────────────────
create table if not exists public.player_badges (
  id          uuid primary key default gen_random_uuid(),
  label       text not null unique,
  color       text not null default '#C9A84C'
               check (color ~ '^#[0-9a-fA-F]{6}$'),
  created_at  timestamptz not null default now()
);

create index if not exists player_badges_label_idx on public.player_badges (label);

-- ─── player_badge_assignments ───────────────────────────────────────
create table if not exists public.player_badge_assignments (
  id          uuid primary key default gen_random_uuid(),
  player_id   uuid not null references public.players(id)       on delete cascade,
  badge_id    uuid not null references public.player_badges(id) on delete cascade,
  created_at  timestamptz not null default now(),
  unique (player_id, badge_id)
);

create index if not exists pba_player_idx on public.player_badge_assignments (player_id);
create index if not exists pba_badge_idx  on public.player_badge_assignments (badge_id);

-- ─── RLS ────────────────────────────────────────────────────────────
alter table public.player_badges             enable row level security;
alter table public.player_badge_assignments  enable row level security;

drop policy if exists player_badges_read_public on public.player_badges;
drop policy if exists player_badges_write_admin on public.player_badges;
create policy player_badges_read_public on public.player_badges
  for select using (true);
create policy player_badges_write_admin on public.player_badges
  for all using (public.is_admin()) with check (public.is_admin());

drop policy if exists pba_read_public on public.player_badge_assignments;
drop policy if exists pba_write_admin on public.player_badge_assignments;
create policy pba_read_public on public.player_badge_assignments
  for select using (true);
create policy pba_write_admin on public.player_badge_assignments
  for all using (public.is_admin()) with check (public.is_admin());

-- ─── Realtime ───────────────────────────────────────────────────────
do $$ begin
  alter publication supabase_realtime add table public.player_badges;
exception when duplicate_object then null; end $$;

do $$ begin
  alter publication supabase_realtime add table public.player_badge_assignments;
exception when duplicate_object then null; end $$;

-- ─── Grants ─────────────────────────────────────────────────────────
grant select on public.player_badges            to anon, authenticated;
grant select on public.player_badge_assignments to anon, authenticated;
grant insert, update, delete on public.player_badges            to authenticated;
grant insert, update, delete on public.player_badge_assignments to authenticated;
