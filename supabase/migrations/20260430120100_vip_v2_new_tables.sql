-- ============================================================================
-- VIP System v2 — Migration 2/5: Tablas nuevas (REVISADA)
-- ============================================================================
-- Cambio respecto v1:
--   * `festival_tournaments` se gestiona en el patch 20260430120050 porque ya
--     existía con datos. Esta migración solo asegura los índices.
-- ============================================================================

-- ============================================================================
-- 2.1 VIP_LEVELS_CONFIG
-- ============================================================================

create table if not exists public.vip_levels_config (
  level                       text primary key,
  display_name                text not null,
  tier                        text not null check (tier in ('starter','player','premium','vip')),
  order_index                 int  not null,
  star_count                  int  not null,
  symbol_name                 text not null,
  color_primary               text not null,
  color_accent                text not null,
  required_main_tournaments   int  null,
  required_season_points      int  null,
  required_2y_points          int  null,
  required_3y_points          int  null,
  multiplier                  numeric(4,2) not null,
  discount_pct                numeric(4,2) not null,
  description                 text null,
  benefits                    jsonb not null default '[]'::jsonb,
  active                      bool not null default true,
  created_at                  timestamptz not null default now(),
  updated_at                  timestamptz not null default now()
);

create unique index if not exists idx_vip_levels_order
  on public.vip_levels_config(order_index);

comment on table public.vip_levels_config is
  'Configuración de los 7 niveles VIP. Editable desde admin.';

-- ============================================================================
-- 2.2 FESTIVAL_TOURNAMENTS — gestionado por el patch 120050
-- ============================================================================
-- Solo aseguramos los índices (ya creados por el patch, idempotentes)
create index if not exists idx_ft_festival on public.festival_tournaments(festival_id);
create index if not exists idx_ft_type on public.festival_tournaments(type);

-- ============================================================================
-- 2.3 USER_PLAYER_ALIASES — mapeo nombre/alias → user
-- ============================================================================

create table if not exists public.user_player_aliases (
  user_id    uuid not null references public.users(id) on delete cascade,
  alias      text not null,
  alias_normalized text generated always as (lower(trim(alias))) stored,
  primary_alias bool not null default false,
  created_at timestamptz not null default now(),
  primary key (user_id, alias_normalized)
);

create index if not exists idx_alias_normalized
  on public.user_player_aliases(alias_normalized);

comment on table public.user_player_aliases is
  'Mapea aliases conocidos (nicknames del XLSX) al user_id real. Persistente entre festivales.';

-- ============================================================================
-- 2.4 TOURNAMENT_PARTICIPATIONS — resultados de torneos
-- ============================================================================

create table if not exists public.tournament_participations (
  id                      uuid primary key default gen_random_uuid(),
  festival_id             uuid not null,
  tournament_id           uuid not null references public.festival_tournaments(id) on delete cascade,
  user_id                 uuid null references public.users(id) on delete set null,
  player_name             text not null,
  final_position          int  null,
  total_entries           int  null,
  made_ft                 bool not null default false,
  made_money              bool not null default false,
  prize_eur               numeric(12,2) null default 0,
  base_points_awarded     int null,
  points_transaction_id   uuid null references public.point_transactions(id) on delete set null,
  uploaded_batch_id       uuid null,
  status                  text not null default 'pending'
    check (status in ('pending','matched','unmatched','awarded','cancelled')),
  created_at              timestamptz not null default now()
);

create index if not exists idx_tp_festival on public.tournament_participations(festival_id);
create index if not exists idx_tp_tournament on public.tournament_participations(tournament_id);
create index if not exists idx_tp_user on public.tournament_participations(user_id);
create index if not exists idx_tp_status on public.tournament_participations(status);
create index if not exists idx_tp_player_name on public.tournament_participations(lower(player_name));

comment on table public.tournament_participations is
  'Resultados subidos por XLSX. Si user_id es null, está pendiente de matching manual.';

-- ============================================================================
-- 2.5 ACHIEVEMENTS — catálogo de logros (puntos)
-- ============================================================================

create table if not exists public.achievements (
  id                       uuid primary key default gen_random_uuid(),
  code                     text not null unique,
  display_name             text not null,
  description              text not null,
  category                 text not null check (category in ('recurrent','season_unique','multi_season')),
  subcategory              text null,
  points_base              int  not null,
  required_level           text not null default 'member'
    check (required_level in ('member','bronze','silver','gold','diamond','black','icon')),
  assignment               text not null check (assignment in ('auto','manual')),
  recurrent_max_per_season int null,
  icon                     text null,
  active                   bool not null default true,
  sort_order               int  not null default 0,
  created_at               timestamptz not null default now()
);

create index if not exists idx_ach_category on public.achievements(category);
create index if not exists idx_ach_active on public.achievements(active);

comment on column public.achievements.points_base is
  'Puntos en valor BASE. El multiplicador del nivel se aplica al canjear, no al otorgar.';
comment on column public.achievements.recurrent_max_per_season is
  'null = ilimitado. Solo aplica a category=recurrent. Ej: Trae a un Amigo tiene max 50.';

-- ============================================================================
-- 2.6 USER_ACHIEVEMENTS — logros desbloqueados
-- ============================================================================

create table if not exists public.user_achievements (
  id                     uuid primary key default gen_random_uuid(),
  user_id                uuid not null references public.users(id) on delete cascade,
  achievement_id         uuid not null references public.achievements(id) on delete cascade,
  festival_id            uuid null,
  season_year            int  not null,
  unlock_count           int  not null default 1,
  unlocked_at            timestamptz not null default now(),
  points_transaction_id  uuid null references public.point_transactions(id) on delete set null,
  metadata               jsonb not null default '{}'::jsonb
);

create unique index if not exists idx_ua_unique_season
  on public.user_achievements(user_id, achievement_id, season_year)
  where festival_id is null;

create unique index if not exists idx_ua_unique_festival
  on public.user_achievements(user_id, achievement_id, festival_id, unlock_count)
  where festival_id is not null;

create index if not exists idx_ua_user on public.user_achievements(user_id);
create index if not exists idx_ua_season on public.user_achievements(season_year);

-- ============================================================================
-- 2.7 BADGES — catálogo de 100 badges
-- ============================================================================

create table if not exists public.badges (
  id                uuid primary key default gen_random_uuid(),
  code              text not null unique,
  display_name      text not null,
  description       text not null,
  tier              text not null check (tier in ('rookie','player','pro','legend','boss_mode')),
  category          text null,
  icon              text null,
  active            bool not null default true,
  sort_order        int  not null default 0,
  created_at        timestamptz not null default now()
);

create index if not exists idx_badges_tier on public.badges(tier);

-- ============================================================================
-- 2.8 USER_BADGES — badges desbloqueadas
-- ============================================================================

create table if not exists public.user_badges (
  user_id     uuid not null references public.users(id) on delete cascade,
  badge_id    uuid not null references public.badges(id) on delete cascade,
  unlocked_at timestamptz not null default now(),
  metadata    jsonb not null default '{}'::jsonb,
  primary key (user_id, badge_id)
);

create index if not exists idx_ub_user on public.user_badges(user_id);

-- ============================================================================
-- 2.9 REDEMPTIONS — canjes de puntos
-- ============================================================================

create table if not exists public.redemptions (
  id                   uuid primary key default gen_random_uuid(),
  user_id              uuid not null references public.users(id) on delete cascade,
  type                 text not null check (type in ('store_discount','hotel_discount','tournament_entry','merch','other')),
  base_points_cost     int  not null,
  multiplier_applied   numeric(4,2) not null,
  effective_value_eur  numeric(12,2) not null,
  description          text null,
  status               text not null default 'pending'
    check (status in ('pending','approved','fulfilled','rejected','cancelled')),
  rejection_reason     text null,
  approved_by          uuid null references auth.users(id) on delete set null,
  approved_at          timestamptz null,
  fulfilled_at         timestamptz null,
  metadata             jsonb not null default '{}'::jsonb,
  created_at           timestamptz not null default now()
);

create index if not exists idx_red_user on public.redemptions(user_id);
create index if not exists idx_red_status on public.redemptions(status);
create index if not exists idx_red_created on public.redemptions(created_at desc);

comment on column public.redemptions.base_points_cost is
  'Puntos en valor BASE consumidos del available_points del user.';
comment on column public.redemptions.multiplier_applied is
  'Snapshot del multiplicador del nivel del user en el momento del canje.';
comment on column public.redemptions.effective_value_eur is
  'Valor en euros recibido por el user: (base_points_cost × multiplier_applied) / 100.';
