-- ============================================================================
-- VIP System v2 — Migration 1.5/5: PATCH para festival_tournaments existente
-- ============================================================================
-- La tabla festival_tournaments ya existía con un schema más rico:
--   id, festival_id, number, name, gtd, buyin, buyin_amount, stack,
--   level_duration, reentry, is_main_event, is_high_roller, created_at
--
-- En lugar de recrearla, la fusionamos:
--   * Mantenemos TODOS los datos y columnas existentes
--   * Añadimos las columnas que el sistema VIP necesita
--   * Calculamos `type` desde is_main_event/is_high_roller/name
--   * Calculamos `counts_for_tier1` desde la lógica de torneos principales
-- ============================================================================

-- 1. Añadir columnas nuevas (idempotente)
alter table public.festival_tournaments
  add column if not exists type                text,
  add column if not exists counts_for_tier1    bool,
  add column if not exists buy_in_eur          int,
  add column if not exists points_per_position jsonb default '{}'::jsonb,
  add column if not exists format              text,
  add column if not exists starts_at           timestamptz,
  add column if not exists active              bool not null default true;

-- 2. Backfill de `type` desde is_main_event / is_high_roller / name
update public.festival_tournaments
set type = case
  when is_main_event = true then 'main_event'
  when is_high_roller = true then 'high_roller'
  when lower(name) like '%warm up%' or lower(name) like '%warmup%' then 'warm_up'
  else 'side'
end
where type is null;

-- 3. Backfill de `counts_for_tier1`: WU + ME + HR cuentan
update public.festival_tournaments
set counts_for_tier1 = (type in ('warm_up','main_event','high_roller'))
where counts_for_tier1 is null;

-- 4. Backfill de buy_in_eur desde buyin_amount si existe
update public.festival_tournaments
set buy_in_eur = buyin_amount
where buy_in_eur is null and buyin_amount is not null;

-- 5. Defaults para que las inserciones futuras desde admin funcionen sin pensar
alter table public.festival_tournaments
  alter column counts_for_tier1 set default false,
  alter column points_per_position set default '{}'::jsonb;

-- 6. Constraint del check sobre `type`
alter table public.festival_tournaments
  drop constraint if exists festival_tournaments_type_check;

alter table public.festival_tournaments
  add constraint festival_tournaments_type_check
  check (type in ('warm_up','main_event','high_roller','side','partner'));

-- 7. NOT NULL sobre type (después del backfill)
alter table public.festival_tournaments
  alter column type set not null;

-- 8. Índices
create index if not exists idx_ft_festival on public.festival_tournaments(festival_id);
create index if not exists idx_ft_type on public.festival_tournaments(type);

-- 9. Verificación
do $$
declare
  v_total       int;
  v_typed       int;
  v_main_count  int;
  v_hr_count    int;
  v_wu_count    int;
  v_tier1_count int;
begin
  select count(*) into v_total       from public.festival_tournaments;
  select count(*) into v_typed       from public.festival_tournaments where type is not null;
  select count(*) into v_main_count  from public.festival_tournaments where type = 'main_event';
  select count(*) into v_hr_count    from public.festival_tournaments where type = 'high_roller';
  select count(*) into v_wu_count    from public.festival_tournaments where type = 'warm_up';
  select count(*) into v_tier1_count from public.festival_tournaments where counts_for_tier1 = true;

  raise notice '=== festival_tournaments tras patch ===';
  raise notice 'Total filas: %', v_total;
  raise notice 'Con type asignado: % (debe igualar total)', v_typed;
  raise notice 'main_event: %', v_main_count;
  raise notice 'high_roller: %', v_hr_count;
  raise notice 'warm_up: %', v_wu_count;
  raise notice 'cuentan para tier1: %', v_tier1_count;
end $$;
