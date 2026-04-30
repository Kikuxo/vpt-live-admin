-- ============================================================================
-- VIP System v2 — Migration 1.7/5: PATCH para drop de funciones legacy
-- ============================================================================
-- El setup inicial creó funciones con firmas distintas a las del sistema VIP v2.
-- Postgres no permite cambiar el return type con CREATE OR REPLACE FUNCTION,
-- así que dropeamos las legacy primero.
--
-- Las funciones que se recrean en la migración 3/5:
--   * recalculate_vip_level(uuid)
--   * add_points(...)
--   * redeem_points(...)
--   * expire_old_points()
--   * start_new_season(int)
--   * apply_participation_points(uuid)
--   * _vip_level_rank(text)
-- ============================================================================

-- Drop con CASCADE para eliminar también triggers y dependencias asociadas.
-- Si las funciones no existen (no aplicaron en el setup inicial), no_op.

-- 1. Reportar qué funciones existen antes del drop
do $$
declare
  v_funcs text;
begin
  select string_agg(
    proname || '(' ||
      pg_get_function_identity_arguments(p.oid) ||
    ') -> ' || pg_get_function_result(p.oid),
    E'\n  ' order by proname
  )
  into v_funcs
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and proname in (
      'recalculate_vip_level',
      'add_points',
      'redeem_points',
      'expire_old_points',
      'start_new_season',
      'apply_participation_points',
      '_vip_level_rank',
      'award_welcome_points',
      'generate_referral_code'
    );

  if v_funcs is null then
    raise notice 'No hay funciones legacy del sistema VIP. Drop step se saltará.';
  else
    raise notice '=== Funciones legacy encontradas (se dropearán) ===\n  %', v_funcs;
  end if;
end $$;

-- 2. Drop de TODAS las posibles firmas de cada función.
-- Usamos pg_proc para encontrar y dropear cada una con su firma exacta.
do $$
declare
  v_proc record;
  v_drop_sql text;
begin
  for v_proc in
    select
      n.nspname as schema_name,
      p.proname as func_name,
      pg_get_function_identity_arguments(p.oid) as args
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in (
        'recalculate_vip_level',
        'add_points',
        'redeem_points',
        'expire_old_points',
        'start_new_season',
        'apply_participation_points',
        '_vip_level_rank',
        'award_welcome_points'
      )
  loop
    v_drop_sql := format(
      'drop function if exists %I.%I(%s) cascade',
      v_proc.schema_name, v_proc.func_name, v_proc.args
    );
    raise notice 'Ejecutando: %', v_drop_sql;
    execute v_drop_sql;
  end loop;
end $$;

-- 3. Triggers que dependieran de esas funciones se dropean automáticamente
-- por el CASCADE. Si quedó alguno huérfano, lo limpiamos:
drop trigger if exists set_referral_code on public.users;
drop trigger if exists award_welcome_points_trigger on public.users;
drop trigger if exists trg_award_welcome_points on public.users;

-- 4. Confirmar
do $$
begin
  raise notice '=== Funciones legacy droppeadas correctamente ===';
  raise notice 'La migración 20260430120200 las recreará con el schema VIP v2.';
end $$;
