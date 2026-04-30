-- ============================================================================
-- VIP System v2 — Migration 1.8/5: HOTFIX columna legacy `points`
-- ============================================================================
-- La columna `points` (NOT NULL) del schema antiguo no se rellena desde las
-- funciones nuevas (add_points, redeem_points), que usan `base_points` y
-- `points_final` como las columnas canónicas del v2.
--
-- Hacemos `points` nullable para no bloquear los inserts. La columna se
-- mantiene por compatibilidad con queries legacy que aún la lean, pero no
-- se escribe nada nuevo en ella.
-- ============================================================================

-- 1. Drop NOT NULL si existe
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema='public'
      and table_name='point_transactions'
      and column_name='points'
      and is_nullable='NO'
  ) then
    alter table public.point_transactions alter column points drop not null;
    raise notice 'Columna points pasó a ser NULL-able';
  else
    raise notice 'Columna points ya era NULL-able o no existe, no_op';
  end if;
end $$;

-- 2. Verificación
do $$
declare
  v_status text;
begin
  select is_nullable into v_status
  from information_schema.columns
  where table_schema='public' and table_name='point_transactions' and column_name='points';

  if v_status = 'YES' then
    raise notice 'OK: point_transactions.points ahora acepta NULL';
  elsif v_status is null then
    raise notice 'OK: columna points no existe (esquema más nuevo)';
  else
    raise exception 'FALLO: point_transactions.points sigue siendo NOT NULL';
  end if;
end $$;
