-- ============================================================================
-- VPT Sistema VIP — vip_history: tiebreaker determinista
-- Fecha: 2026-05-01
--
-- Refactor de la RPC public.vip_history añadiendo un segundo criterio de
-- ORDER BY (source_id desc) para que la salida sea determinista cuando
-- varias filas comparten occurred_at (caso típico: un reprocess masivo
-- inserta varias point_transactions con el mismo created_at hasta el
-- microsegundo).
--
-- Notas:
--   - Para el branch 'badge_unlocked' se usa ub.badge_id como source_id
--     (la tabla user_badges no tiene columna `id`; su PK es compuesto
--     (user_id, badge_id), por lo que badge_id es único por user).
--   - Esta migración SOLO redefine la función; no modifica datos ni
--     toca la migración 20260501210000 ya aplicada.
-- ============================================================================

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
      'points'::text                                   as type,
      pt.created_at                                    as occurred_at,
      coalesce(pt.description, 'Movimiento de puntos') as description,
      pt.points_final                                  as amount,
      pt.balance_after                                 as balance_after,
      null::text                                       as from_level,
      null::text                                       as to_level,
      null::text                                       as direction,
      null::text                                       as badge_code,
      null::text                                       as badge_tier,
      pt.metadata                                      as metadata,
      pt.id                                            as source_id
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
      lc.metadata,
      lc.id                                            as source_id
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
      ub.metadata,
      ub.badge_id                                      as source_id
    from public.user_badges ub
    join public.badges b on b.id = ub.badge_id
    where ub.user_id = p_user_id
  )
  select coalesce(jsonb_agg(to_jsonb(e)), '[]'::jsonb)
  from (
    select * from events
    order by occurred_at desc, source_id desc
    limit p_limit offset p_offset
  ) e;
$$;

grant execute on function public.vip_history(uuid, int, int) to authenticated;
