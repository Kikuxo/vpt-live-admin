-- ============================================================================
-- VIP System v2 — Fix configuración de logros únicos (season_unique)
-- Fecha: 2026-04-30 17:00
--
-- Cambios:
--   1. recurrent_max_per_season = 1 para los 50 logros únicos.
--      (Información explícita: máximo 1 desbloqueo por temporada.
--       La lógica de unlock_achievement ya bloquea duplicados en season_unique
--       independientemente de este valor, pero documentarlo es útil para la UI
--       y para futura coherencia con otras categorías.)
--
--   2. assignment = 'auto' para todos los únicos EXCEPTO los 3 de Partners
--      Events (uni_kpe_event, uni_kpe_regular, uni_kpe_triple_corona) que se
--      mantienen como 'manual'.
--      Esto incluye el cambio de uni_first_trophy de manual → auto para
--      consistencia con el resto de First-timer.
-- ============================================================================

-- 1. recurrent_max_per_season = 1 para todos los season_unique
update public.achievements
set recurrent_max_per_season = 1
where category = 'season_unique';

-- 2. assignment = 'auto' para todos los season_unique
update public.achievements
set assignment = 'auto'
where category = 'season_unique';

-- 3. Excepción: los 3 logros de Partners Events son manuales
update public.achievements
set assignment = 'manual'
where category = 'season_unique'
  and code in ('uni_kpe_event', 'uni_kpe_regular', 'uni_kpe_triple_corona');

-- Verificación
do $$
declare
  v_total int;
  v_auto int;
  v_manual int;
  v_with_max int;
begin
  select count(*) into v_total
  from public.achievements where category = 'season_unique';

  select count(*) into v_auto
  from public.achievements where category = 'season_unique' and assignment = 'auto';

  select count(*) into v_manual
  from public.achievements where category = 'season_unique' and assignment = 'manual';

  select count(*) into v_with_max
  from public.achievements where category = 'season_unique' and recurrent_max_per_season = 1;

  raise notice 'season_unique: % total, % auto, % manual, % con max=1',
    v_total, v_auto, v_manual, v_with_max;

  if v_total <> 50 then
    raise exception 'esperado 50 únicos, encontrados %', v_total;
  end if;
  if v_auto <> 47 then
    raise exception 'esperado 47 auto, encontrados %', v_auto;
  end if;
  if v_manual <> 3 then
    raise exception 'esperado 3 manual (KPE), encontrados %', v_manual;
  end if;
  if v_with_max <> 50 then
    raise exception 'esperado 50 con max=1, encontrados %', v_with_max;
  end if;
end $$;
