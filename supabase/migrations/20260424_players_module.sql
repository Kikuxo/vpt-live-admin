-- =====================================================================
-- VPT Live — Módulo de jugadores y chip counts
-- Fecha: 2026-04-24
--
-- Crea:
--   - players              catálogo global de jugadores
--   - festival_players     pivote festival <-> player con chip_count/status
--   - chip_history         histórico de fichas (alimentado por trigger)
--   - update_mentions      N:N entre live_updates y players (@menciones)
--   - v_festival_leaderboard  vista con posición y last_delta
--
-- Convenciones: snake_case, tablas en plural, FKs <tabla>_id, is_*/_at.
-- Lectura pública (anon key) para la app móvil; escritura solo admins
-- (usuarios con fila en live_admins).
-- =====================================================================

-- ─── Extensiones ─────────────────────────────────────────────────────
create extension if not exists "pgcrypto";

-- ─── Helper: is_admin() ──────────────────────────────────────────────
-- Centraliza la comprobación contra live_admins para las políticas RLS.
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.live_admins where user_id = auth.uid()
  );
$$;

-- ─── Helper: touch updated_at ────────────────────────────────────────
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- =====================================================================
-- TABLA: players (catálogo global)
-- =====================================================================
create table if not exists public.players (
  id               uuid primary key default gen_random_uuid(),
  full_name        text not null,
  nickname         text,
  nationality_iso  char(2),
  vpt_ranking      integer,
  photo_url        text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint players_nationality_iso_format
    check (nationality_iso is null or nationality_iso ~ '^[A-Z]{2}$')
);

create index if not exists players_full_name_idx   on public.players (full_name);
create index if not exists players_nickname_idx    on public.players (nickname);
create index if not exists players_vpt_ranking_idx on public.players (vpt_ranking);

drop trigger if exists trg_players_updated_at on public.players;
create trigger trg_players_updated_at
  before update on public.players
  for each row execute function public.set_updated_at();

-- =====================================================================
-- TABLA: festival_players (pivote festival <-> player)
-- =====================================================================
create table if not exists public.festival_players (
  id              uuid primary key default gen_random_uuid(),
  festival_id     uuid not null references public.festivals(id) on delete cascade,
  player_id       uuid not null references public.players(id)   on delete cascade,
  chip_count      bigint not null default 0,
  status          text   not null default 'active'
                   check (status in ('active', 'eliminated')),
  seat_info       text,
  registered_at   timestamptz not null default now(),
  eliminated_at   timestamptz,
  updated_at      timestamptz not null default now(),
  unique (festival_id, player_id)
);

create index if not exists festival_players_festival_idx
  on public.festival_players (festival_id);
create index if not exists festival_players_chip_count_idx
  on public.festival_players (festival_id, chip_count desc);
create index if not exists festival_players_status_idx
  on public.festival_players (festival_id, status);

drop trigger if exists trg_festival_players_updated_at on public.festival_players;
create trigger trg_festival_players_updated_at
  before update on public.festival_players
  for each row execute function public.set_updated_at();

-- Marca eliminated_at automáticamente cuando cambia el status
create or replace function public.set_eliminated_at()
returns trigger
language plpgsql
as $$
begin
  if new.status = 'eliminated' and old.status is distinct from 'eliminated' then
    new.eliminated_at := coalesce(new.eliminated_at, now());
  elsif new.status = 'active' and old.status = 'eliminated' then
    new.eliminated_at := null;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_festival_players_eliminated_at on public.festival_players;
create trigger trg_festival_players_eliminated_at
  before update of status on public.festival_players
  for each row execute function public.set_eliminated_at();

-- =====================================================================
-- TABLA: chip_history (alimentada por trigger, no se escribe a mano)
-- =====================================================================
create table if not exists public.chip_history (
  id                   uuid primary key default gen_random_uuid(),
  festival_player_id   uuid not null references public.festival_players(id) on delete cascade,
  chip_count           bigint not null,
  delta                bigint not null default 0,
  recorded_by          uuid references auth.users(id),
  recorded_at          timestamptz not null default now()
);

create index if not exists chip_history_festival_player_idx
  on public.chip_history (festival_player_id, recorded_at desc);

-- Trigger: registra inserts iniciales y cambios de chip_count
create or replace function public.log_chip_change()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.chip_history (festival_player_id, chip_count, delta, recorded_by)
    values (new.id, new.chip_count, new.chip_count, auth.uid());
  elsif tg_op = 'UPDATE' and new.chip_count is distinct from old.chip_count then
    insert into public.chip_history (festival_player_id, chip_count, delta, recorded_by)
    values (new.id, new.chip_count, new.chip_count - old.chip_count, auth.uid());
  end if;
  return null;
end;
$$;

drop trigger if exists trg_festival_players_chip_log on public.festival_players;
create trigger trg_festival_players_chip_log
  after insert or update of chip_count on public.festival_players
  for each row execute function public.log_chip_change();

-- =====================================================================
-- TABLA: update_mentions (live_updates <-> players)
-- =====================================================================
create table if not exists public.update_mentions (
  id          uuid primary key default gen_random_uuid(),
  update_id   uuid not null references public.live_updates(id) on delete cascade,
  player_id   uuid not null references public.players(id)      on delete cascade,
  created_at  timestamptz not null default now(),
  unique (update_id, player_id)
);

create index if not exists update_mentions_update_idx on public.update_mentions (update_id);
create index if not exists update_mentions_player_idx on public.update_mentions (player_id);

-- =====================================================================
-- VISTA: v_festival_leaderboard
-- Posición entre activos; last_delta = último delta registrado.
-- security_invoker=true para que RLS aplique al usuario que consulta.
-- =====================================================================
create or replace view public.v_festival_leaderboard
  with (security_invoker = true)
  as
select
  fp.id                as festival_player_id,
  fp.festival_id,
  fp.player_id,
  p.full_name,
  p.nickname,
  p.nationality_iso,
  p.vpt_ranking,
  p.photo_url,
  fp.chip_count,
  fp.status,
  fp.seat_info,
  fp.registered_at,
  fp.eliminated_at,
  fp.updated_at,
  case
    when fp.status = 'active' then
      row_number() over (
        partition by fp.festival_id, fp.status
        order by fp.chip_count desc nulls last, p.full_name
      )
  end as position,
  (
    select ch.delta
    from public.chip_history ch
    where ch.festival_player_id = fp.id
    order by ch.recorded_at desc
    limit 1
  ) as last_delta
from public.festival_players fp
join public.players p on p.id = fp.player_id;

-- =====================================================================
-- Row-Level Security
-- Lectura pública (anon) para que la app móvil pueda consumir con anon key.
-- Escritura restringida a usuarios con fila en live_admins.
-- =====================================================================

alter table public.players           enable row level security;
alter table public.festival_players  enable row level security;
alter table public.chip_history      enable row level security;
alter table public.update_mentions   enable row level security;

-- players ------------------------------------------------------------
drop policy if exists players_read_public  on public.players;
drop policy if exists players_write_admin  on public.players;

create policy players_read_public  on public.players
  for select using (true);

create policy players_write_admin  on public.players
  for all
  using     (public.is_admin())
  with check (public.is_admin());

-- festival_players ---------------------------------------------------
drop policy if exists festival_players_read_public on public.festival_players;
drop policy if exists festival_players_write_admin on public.festival_players;

create policy festival_players_read_public on public.festival_players
  for select using (true);

create policy festival_players_write_admin on public.festival_players
  for all
  using     (public.is_admin())
  with check (public.is_admin());

-- chip_history -------------------------------------------------------
-- Sólo lectura para anon; INSERT únicamente vía trigger en contexto admin.
drop policy if exists chip_history_read_public on public.chip_history;
drop policy if exists chip_history_write_admin on public.chip_history;

create policy chip_history_read_public on public.chip_history
  for select using (true);

create policy chip_history_write_admin on public.chip_history
  for all
  using     (public.is_admin())
  with check (public.is_admin());

-- update_mentions ----------------------------------------------------
drop policy if exists update_mentions_read_public on public.update_mentions;
drop policy if exists update_mentions_write_admin on public.update_mentions;

create policy update_mentions_read_public on public.update_mentions
  for select using (true);

create policy update_mentions_write_admin on public.update_mentions
  for all
  using     (public.is_admin())
  with check (public.is_admin());

-- =====================================================================
-- Realtime: publicación para que el admin (y la app móvil) reciban
-- cambios push en festival_players, chip_history y update_mentions.
-- =====================================================================
do $$
begin
  alter publication supabase_realtime add table public.festival_players;
exception when duplicate_object then null;
end $$;

do $$
begin
  alter publication supabase_realtime add table public.chip_history;
exception when duplicate_object then null;
end $$;

do $$
begin
  alter publication supabase_realtime add table public.update_mentions;
exception when duplicate_object then null;
end $$;

-- =====================================================================
-- Grants mínimos (Supabase los aplica automáticamente a anon/authenticated
-- cuando hay RLS, pero explicitamos por claridad).
-- =====================================================================
grant select on public.players           to anon, authenticated;
grant select on public.festival_players  to anon, authenticated;
grant select on public.chip_history      to anon, authenticated;
grant select on public.update_mentions   to anon, authenticated;
grant select on public.v_festival_leaderboard to anon, authenticated;

grant insert, update, delete on public.players          to authenticated;
grant insert, update, delete on public.festival_players to authenticated;
grant insert, update, delete on public.chip_history     to authenticated;
grant insert, update, delete on public.update_mentions  to authenticated;
