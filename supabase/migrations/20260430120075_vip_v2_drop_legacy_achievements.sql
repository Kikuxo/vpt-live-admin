-- ============================================================================
-- VIP System v2 — Migration 1.6/5: PATCH para legacy achievements/badges
-- ============================================================================
-- Las tablas achievements, user_achievements, badges, user_badges del setup
-- inicial (24 abril) tienen schema distinto y NO contienen datos de producción.
-- Las droppeamos para que la migración 2 las recree con el schema correcto.
--
-- IMPORTANTE: solo se ejecuta sobre tablas legacy. Si en algún momento alguna
-- tiene datos reales que conservar, este patch debe ajustarse.
-- ============================================================================

-- 1. Verificar primero que las tablas no tienen filas críticas
do $$
declare
  v_ach_count   int := 0;
  v_ua_count    int := 0;
  v_bd_count    int := 0;
  v_ub_count    int := 0;
begin
  if exists (select 1 from information_schema.tables
             where table_schema='public' and table_name='achievements') then
    execute 'select count(*) from public.achievements' into v_ach_count;
  end if;

  if exists (select 1 from information_schema.tables
             where table_schema='public' and table_name='user_achievements') then
    execute 'select count(*) from public.user_achievements' into v_ua_count;
  end if;

  if exists (select 1 from information_schema.tables
             where table_schema='public' and table_name='badges') then
    execute 'select count(*) from public.badges' into v_bd_count;
  end if;

  if exists (select 1 from information_schema.tables
             where table_schema='public' and table_name='user_badges') then
    execute 'select count(*) from public.user_badges' into v_ub_count;
  end if;

  raise notice '=== Estado de tablas legacy antes del drop ===';
  raise notice 'achievements: % filas', v_ach_count;
  raise notice 'user_achievements: % filas', v_ua_count;
  raise notice 'badges: % filas', v_bd_count;
  raise notice 'user_badges: % filas', v_ub_count;
end $$;

-- 2. Drop tablas legacy
-- Orden importante: primero las que dependen, luego las maestras
drop table if exists public.user_achievements cascade;
drop table if exists public.user_badges       cascade;
drop table if exists public.achievements      cascade;
drop table if exists public.badges            cascade;

-- 3. Confirmar
do $$
begin
  raise notice '=== Tablas legacy droppeadas correctamente ===';
  raise notice 'La migración 20260430120100 las recreará con el schema VIP v2.';
end $$;
