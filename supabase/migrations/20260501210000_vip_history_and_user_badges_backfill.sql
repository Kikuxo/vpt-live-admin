-- ============================================================================
-- VPT Sistema VIP — Historial unificado + backfill de user_badges
-- Fecha: 2026-05-01
--
-- Esta migración:
--
--   1. Crea la tabla `level_changes` con RLS, índice y trigger en `users`
--      que registra cada transición de `vip_level` (up/down/same).
--   2. Crea la RPC `vip_history(p_user_id, p_limit, p_offset)` que devuelve
--      un array JSONB unificado con eventos de tipo:
--          - points          (point_transactions)
--          - level_change    (level_changes)
--          - badge_unlocked  (user_badges + badges)
--      ordenado por fecha desc, paginado.
--   3. Backfill de `user_badges` desde `user_achievements` matcheando por
--      achievements.code = badges.code, y como fallback por display_name
--      (case-insensitive). Idempotente: ON CONFLICT DO NOTHING contra el
--      PK ya existente (user_id, badge_id).
--   4. Backfill de `level_changes` para todos los users con `vip_level`
--      no nulo, con direction='up', from_level=NULL,
--      changed_at = COALESCE(vip_level_attained_at, created_at),
--      reason='backfill'. Idempotente vía WHERE NOT EXISTS.
--
-- Verificado contra el proyecto rkaanxwiboazgutphwzx el 2026-05-01:
--   - user_badges PK = (user_id, badge_id)  → no requiere añadir UNIQUE.
--   - point_transactions ya tiene idx_pt_user_created(user_id, created_at).
--   - 0 matches achievements.code ↔ badges.code; 15 matches por display_name.
--     El backfill resultará en ~13 filas de user_badges con datos actuales.
-- ============================================================================


-- ════════════════════════════════════════════════════════════════════════════
-- 1. TABLA level_changes
-- ════════════════════════════════════════════════════════════════════════════

create table if not exists public.level_changes (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.users(id) on delete cascade,
  from_level  text null,
  to_level    text not null,
  direction   text not null check (direction in ('up','down','same')),
  changed_at  timestamptz not null default now(),
  reason      text null,
  metadata    jsonb not null default '{}'::jsonb
);

create index if not exists idx_level_changes_user_changed
  on public.level_changes(user_id, changed_at desc);


-- ════════════════════════════════════════════════════════════════════════════
-- 2. RLS sobre level_changes
-- ════════════════════════════════════════════════════════════════════════════

alter table public.level_changes enable row level security;

drop policy if exists level_changes_select_self on public.level_changes;
create policy level_changes_select_self
  on public.level_changes
  for select
  using (auth.uid() = user_id);

drop policy if exists level_changes_admin_all on public.level_changes;
create policy level_changes_admin_all
  on public.level_changes
  for all
  using (public.is_admin())
  with check (public.is_admin());


-- ════════════════════════════════════════════════════════════════════════════
-- 3. TRIGGER en users — registra transición de vip_level
-- ════════════════════════════════════════════════════════════════════════════

create or replace function public._on_vip_level_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dir       text;
  v_old_rank  int;
  v_new_rank  int;
begin
  if new.vip_level is distinct from old.vip_level then
    v_old_rank := public._vip_level_rank(old.vip_level);
    v_new_rank := public._vip_level_rank(new.vip_level);
    v_dir := case
      when v_new_rank > v_old_rank then 'up'
      when v_new_rank < v_old_rank then 'down'
      else 'same'
    end;
    insert into public.level_changes (user_id, from_level, to_level,
                                      direction, changed_at, reason)
    values (new.id, old.vip_level, new.vip_level, v_dir,
            now(), 'recalc');
  end if;
  return new;
end;
$$;

drop trigger if exists trg_vip_level_change on public.users;
create trigger trg_vip_level_change
  after update of vip_level on public.users
  for each row execute function public._on_vip_level_change();


-- ════════════════════════════════════════════════════════════════════════════
-- 4. RPC vip_history(p_user_id, p_limit, p_offset)
-- ════════════════════════════════════════════════════════════════════════════

create or replace function public.vip_history(
  p_user_id uuid,
  p_limit   int default 100,
  p_offset  int default 0
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with events as (
    select
      'points'::text                  as type,
      pt.created_at                   as occurred_at,
      coalesce(pt.description, 'Movimiento de puntos') as description,
      pt.points_final                 as amount,
      pt.balance_after                as balance_after,
      null::text                      as from_level,
      null::text                      as to_level,
      null::text                      as direction,
      null::text                      as badge_code,
      null::text                      as badge_tier,
      pt.metadata                     as metadata
    from public.point_transactions pt
    where pt.user_id = p_user_id

    union all

    select
      'level_change'::text,
      lc.changed_at,
      case lc.direction
        when 'up'   then 'Subiste a ' || lc.to_level
        when 'down' then 'Bajaste a ' || lc.to_level
        else             'Mantienes ' || lc.to_level
      end,
      null::int,
      null::int,
      lc.from_level,
      lc.to_level,
      lc.direction,
      null::text,
      null::text,
      lc.metadata
    from public.level_changes lc
    where lc.user_id = p_user_id

    union all

    select
      'badge_unlocked'::text,
      ub.unlocked_at,
      coalesce(b.display_name, b.code),
      null::int,
      null::int,
      null::text,
      null::text,
      null::text,
      b.code,
      b.tier,
      ub.metadata
    from public.user_badges ub
    join public.badges b on b.id = ub.badge_id
    where ub.user_id = p_user_id
  )
  select coalesce(jsonb_agg(to_jsonb(e)), '[]'::jsonb)
  from (
    select * from events
    order by occurred_at desc
    limit p_limit offset p_offset
  ) e;
$$;

grant execute on function public.vip_history(uuid, int, int) to authenticated;


-- ════════════════════════════════════════════════════════════════════════════
-- 5. BACKFILL user_badges desde user_achievements
--
-- Estrategia de match: por code primero, fallback por display_name (lower).
-- En la BBDD actual, code nunca matchea (achievements: rec_/uni_/mult_;
-- badges: badge_*); el branch de display_name aporta los ~15 mappings
-- naturales. DISTINCT ON garantiza una fila por (user, badge), tomando
-- la unlocked_at más reciente.
-- ════════════════════════════════════════════════════════════════════════════

do $$
declare
  v_total int;
begin
  with matches as (
    select distinct on (ua.user_id, b.id)
      ua.user_id,
      b.id          as badge_id,
      ua.unlocked_at,
      jsonb_build_object(
        'source',         'backfill_2026',
        'achievement_id', ua.achievement_id
      ) as metadata
    from public.user_achievements ua
    join public.achievements a on a.id = ua.achievement_id
    join public.badges b
      on (b.code = a.code
          or lower(b.display_name) = lower(a.display_name))
    order by ua.user_id, b.id, ua.unlocked_at desc
  )
  insert into public.user_badges (user_id, badge_id, unlocked_at, metadata)
  select user_id, badge_id, unlocked_at, metadata
  from matches
  on conflict (user_id, badge_id) do nothing;

  select count(*) into v_total
  from public.user_badges
  where metadata->>'source' = 'backfill_2026';

  raise notice 'user_badges backfill: % filas con metadata->>source = backfill_2026', v_total;
end $$;


-- ════════════════════════════════════════════════════════════════════════════
-- 6. BACKFILL level_changes para users con vip_level
--
-- Una fila inicial por user con vip_level no nulo:
--   from_level = NULL, to_level = vip_level, direction = 'up',
--   changed_at = COALESCE(vip_level_attained_at, created_at),
--   reason = 'backfill'.
-- Idempotente: WHERE NOT EXISTS sobre (user_id, reason='backfill').
-- ════════════════════════════════════════════════════════════════════════════

do $$
declare
  v_total int;
begin
  insert into public.level_changes (user_id, from_level, to_level,
                                    direction, changed_at, reason)
  select
    u.id,
    null,
    u.vip_level,
    'up',
    coalesce(u.vip_level_attained_at, u.created_at),
    'backfill'
  from public.users u
  where u.vip_level is not null
    and not exists (
      select 1 from public.level_changes lc
      where lc.user_id = u.id
        and lc.reason  = 'backfill'
    );

  select count(*) into v_total
  from public.level_changes
  where reason = 'backfill';

  raise notice 'level_changes backfill: % filas con reason = backfill', v_total;
end $$;


-- ════════════════════════════════════════════════════════════════════════════
-- Verificación
-- ════════════════════════════════════════════════════════════════════════════

do $$
begin
  raise notice 'vip_history_and_user_badges_backfill aplicada';
end $$;
