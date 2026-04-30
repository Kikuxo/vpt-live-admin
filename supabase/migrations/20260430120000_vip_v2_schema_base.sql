-- ============================================================================
-- VIP System v2 — Migration 1/5: Schema base
-- ============================================================================
-- Cambios:
--   * Añade columnas nuevas a `users` para el sistema VIP v2
--   * Refactor de `point_transactions` con tipos extendidos y FIFO
--   * No elimina columnas antiguas todavía (lo haremos en migration 5)
-- ============================================================================

-- ============================================================================
-- 1.1 USERS — nuevas columnas
-- ============================================================================

alter table public.users
  add column if not exists season_year                int          default 2026,
  add column if not exists season_points              int          default 0,
  add column if not exists available_points           int          default 0,
  add column if not exists season_main_tournaments    int          default 0,
  add column if not exists vip_level_locked_until     date         null,
  add column if not exists vip_level_attained_at      timestamptz  null,
  add column if not exists season_points_year_minus_1 int          default 0,
  add column if not exists season_points_year_minus_2 int          default 0;

-- vip_level: ya existe pero quizás como enum bronze/silver/gold/platinum
-- Lo convertimos a text libre para soportar los 7 niveles nuevos.
-- Si era enum, lo casteamos a text. Si ya era text, este alter es no-op idempotente.
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='users' and column_name='vip_level'
      and udt_name <> 'text'
  ) then
    alter table public.users alter column vip_level type text using vip_level::text;
  end if;
end $$;

-- Default y check de los 7 niveles válidos
alter table public.users alter column vip_level set default 'member';
update public.users set vip_level = 'member' where vip_level is null;

alter table public.users
  drop constraint if exists users_vip_level_check;

alter table public.users
  add constraint users_vip_level_check
  check (vip_level in ('member','bronze','silver','gold','diamond','black','icon'));

-- Índices útiles
create index if not exists idx_users_vip_level on public.users(vip_level);
create index if not exists idx_users_season_year on public.users(season_year);

comment on column public.users.season_points is
  'Puntos VPT acumulados en la temporada actual (en valor BASE, sin multiplicador). Determina nivel Tier 2.';
comment on column public.users.available_points is
  'Saldo VPT disponible para canjear (en valor BASE). El multiplicador se aplica al canjear, no aquí.';
comment on column public.users.season_main_tournaments is
  'Número de torneos principales (Warm Up + Main Event + High Roller) jugados en la temporada actual. Determina nivel Tier 1.';
comment on column public.users.vip_level_locked_until is
  'Protección de nivel: si bajaría de nivel, mantiene el actual hasta esta fecha. Se setea al cambiar de temporada.';

-- ============================================================================
-- 1.2 POINT_TRANSACTIONS — refactor
-- ============================================================================

-- Renombrar columnas antiguas (legacy) si existen, para no romper queries actuales
-- mientras migramos. Las eliminamos en la migration 5.
do $$
begin
  -- points_balance → legacy_points_balance (si existe)
  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='users' and column_name='points_balance'
  ) then
    alter table public.users rename column points_balance to legacy_points_balance;
  end if;

  -- points_12m → legacy_points_12m (si existe)
  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='users' and column_name='points_12m'
  ) then
    alter table public.users rename column points_12m to legacy_points_12m;
  end if;
end $$;

-- Nuevas columnas en point_transactions
alter table public.point_transactions
  add column if not exists base_points           int          null,
  add column if not exists expires_at            timestamptz  null,
  add column if not exists remaining_for_redeem  int          null,
  add column if not exists season_year           int          null,
  add column if not exists metadata              jsonb        not null default '{}'::jsonb;

-- Backfill base_points desde points si existe
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='point_transactions' and column_name='points'
  ) then
    update public.point_transactions
    set base_points = points
    where base_points is null;
  end if;
end $$;

-- Tipos válidos (extendemos el set actual)
-- type es text actualmente, le ponemos check para validar valores nuevos
alter table public.point_transactions
  drop constraint if exists point_transactions_type_check;

alter table public.point_transactions
  add constraint point_transactions_type_check
  check (type in ('earn','multi_earn','redeem','expire','admin_add','admin_sub','correction'));

-- Índices para FIFO
create index if not exists idx_pt_user_created
  on public.point_transactions(user_id, created_at);

create index if not exists idx_pt_remaining
  on public.point_transactions(user_id, remaining_for_redeem)
  where remaining_for_redeem > 0;

create index if not exists idx_pt_expires
  on public.point_transactions(expires_at)
  where expires_at is not null and remaining_for_redeem > 0;

comment on column public.point_transactions.base_points is
  'Puntos en valor BASE (sin multiplicador). El multiplicador se aplica al canjear.';
comment on column public.point_transactions.expires_at is
  'Fecha en la que el lote expira. Solo en filas earn/multi_earn. Default: created_at + 12 months.';
comment on column public.point_transactions.remaining_for_redeem is
  'Cuántos puntos del lote siguen disponibles. Decrece con FIFO al canjear o expirar.';
comment on column public.point_transactions.metadata is
  'Info auxiliar: festival_id, tournament_id, achievement_code, lotes consumidos en redeem, etc.';
