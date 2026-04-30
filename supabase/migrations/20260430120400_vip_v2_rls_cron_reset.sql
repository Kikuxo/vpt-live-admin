-- ============================================================================
-- VIP System v2 — Migration 5/5: RLS, cron jobs, user reset
-- ============================================================================
-- Cierre del Bloque 1:
--   * RLS policies en las tablas nuevas
--   * Cron jobs con pg_cron (expiración diaria, reset anual)
--   * Reset de users existentes a 'member' (decisión del plan)
-- ============================================================================

-- ============================================================================
-- 5.1 RLS — Row Level Security
-- ============================================================================

-- Catálogos (read-only para todos los authenticated, write solo admins)
alter table public.vip_levels_config        enable row level security;
alter table public.achievements             enable row level security;
alter table public.badges                   enable row level security;
alter table public.festival_tournaments     enable row level security;

-- Datos por usuario
alter table public.user_achievements        enable row level security;
alter table public.user_badges              enable row level security;
alter table public.user_player_aliases      enable row level security;
alter table public.tournament_participations enable row level security;
alter table public.redemptions              enable row level security;

-- ---- vip_levels_config: lectura pública (la app pública la consume sin auth) ----
drop policy if exists vip_levels_select_public on public.vip_levels_config;
create policy vip_levels_select_public on public.vip_levels_config
  for select using (true);

-- ---- achievements: lectura pública ----
drop policy if exists achievements_select_public on public.achievements;
create policy achievements_select_public on public.achievements
  for select using (active = true);

-- ---- badges: lectura pública ----
drop policy if exists badges_select_public on public.badges;
create policy badges_select_public on public.badges
  for select using (active = true);

-- ---- festival_tournaments: lectura pública ----
drop policy if exists ft_select_public on public.festival_tournaments;
create policy ft_select_public on public.festival_tournaments
  for select using (true);

-- ---- user_achievements: cada user ve los suyos. La app puede leer de otros para mostrar
-- en perfiles públicos, así que dejamos lectura pública también.
drop policy if exists ua_select_public on public.user_achievements;
create policy ua_select_public on public.user_achievements
  for select using (true);

-- ---- user_badges: lectura pública (badges visibles en perfil) ----
drop policy if exists ub_select_public on public.user_badges;
create policy ub_select_public on public.user_badges
  for select using (true);

-- ---- user_player_aliases: lectura pública (necesaria para matching XLSX) ----
drop policy if exists upa_select_public on public.user_player_aliases;
create policy upa_select_public on public.user_player_aliases
  for select using (true);

-- ---- tournament_participations: lectura pública (rankings y perfiles públicos) ----
drop policy if exists tp_select_public on public.tournament_participations;
create policy tp_select_public on public.tournament_participations
  for select using (true);

-- ---- redemptions: solo el propio user ve sus canjes ----
drop policy if exists red_select_own on public.redemptions;
create policy red_select_own on public.redemptions
  for select using (auth.uid() = user_id);

-- Las escrituras desde admin se harán con service_role, que bypassa RLS.
-- Si en el futuro queremos políticas de admin específicas, las añadimos.

-- ============================================================================
-- 5.2 CRON JOBS con pg_cron
-- ============================================================================

-- Habilitar la extensión pg_cron si no está
create extension if not exists pg_cron with schema extensions;

-- Asegurar permisos para que pg_cron pueda ejecutar las funciones
grant usage on schema cron to postgres;

-- ---- Job 1: expiración diaria de puntos a las 03:00 UTC ----
-- Limpiar job anterior si existe
do $$
begin
  perform cron.unschedule('vip_expire_points_daily')
  where exists (select 1 from cron.job where jobname = 'vip_expire_points_daily');
exception when others then null;
end $$;

select cron.schedule(
  'vip_expire_points_daily',
  '0 3 * * *',
  $$ select public.expire_old_points(); $$
);

-- ---- Job 2: reset de temporada el 1 enero a las 00:05 UTC ----
do $$
begin
  perform cron.unschedule('vip_start_new_season')
  where exists (select 1 from cron.job where jobname = 'vip_start_new_season');
exception when others then null;
end $$;

select cron.schedule(
  'vip_start_new_season',
  '5 0 1 1 *',
  $$ select public.start_new_season(extract(year from now())::int); $$
);

-- ============================================================================
-- 5.3 RESET de users existentes
-- ============================================================================
-- Decisión del plan: todos los users vuelven a 'member' y empiezan de cero.
-- Recalcularán cuando se suba el primer XLSX de festival.

update public.users
set
  vip_level                  = 'member',
  vip_level_attained_at      = null,
  vip_level_locked_until     = null,
  season_year                = 2026,
  season_points              = 0,
  available_points           = 0,
  season_main_tournaments    = 0,
  season_points_year_minus_1 = 0,
  season_points_year_minus_2 = 0;

-- Marcar todas las point_transactions existentes como 'legacy' en metadata
-- (No las borramos por trazabilidad, pero no afectan a los nuevos saldos.)
update public.point_transactions
set metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('legacy_pre_v2', true)
where metadata is null or not (metadata ? 'legacy_pre_v2');

-- ============================================================================
-- 5.4 SEED de aliases conocidos (de las memorias de Francisco)
-- ============================================================================
-- Aliases identificados durante Rozvadov 2026.
-- Si el user_id real existe lo vinculamos. Si no, queda como referencia.

-- Esto es solo un placeholder: los users tienen que existir en public.users.
-- Si Francisco aún no ha registrado a Alejandro Queijeiro como user, esto no ejecutará nada.
do $$
declare
  v_user_id uuid;
begin
  -- masgambling = Alejandro Queijeiro
  select id into v_user_id from public.users
  where lower(name) like '%alejandro%queijeiro%' or lower(email) like '%queijeiro%'
  limit 1;
  if v_user_id is not null then
    insert into public.user_player_aliases (user_id, alias, primary_alias)
    values (v_user_id, 'masgambling', false)
    on conflict do nothing;

    insert into public.user_player_aliases (user_id, alias, primary_alias)
    values (v_user_id, 'Alejandro Queijeiro', true)
    on conflict do nothing;
  end if;
end $$;

-- ============================================================================
-- VERIFICACIÓN FINAL — queries que se ejecutan al final para confirmar el estado
-- ============================================================================

do $$
declare
  v_levels_count   int;
  v_ach_count      int;
  v_badges_count   int;
  v_users_reset    int;
  v_cron_count     int;
begin
  select count(*) into v_levels_count from public.vip_levels_config;
  select count(*) into v_ach_count from public.achievements where active = true;
  select count(*) into v_badges_count from public.badges where active = true;
  select count(*) into v_users_reset from public.users where vip_level = 'member';
  select count(*) into v_cron_count from cron.job where jobname like 'vip_%';

  raise notice '=== VIP System v2 — Estado tras migración ===';
  raise notice 'vip_levels_config: % filas (esperado: 7)', v_levels_count;
  raise notice 'achievements activos: % filas (esperado: 85)', v_ach_count;
  raise notice 'badges activos: % filas (esperado: 100)', v_badges_count;
  raise notice 'users en nivel member: %', v_users_reset;
  raise notice 'cron jobs vip_*: % (esperado: 2)', v_cron_count;
end $$;
