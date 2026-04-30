-- ============================================================================
-- VIP System v2 — Fix configuración de logros multi-season
-- Fecha: 2026-04-30 17:30
--
-- Cambios:
--   recurrent_max_per_season = 1 para los 25 logros multi-season.
--
-- Semántica:
--   Los multi-season se desbloquean máximo 1 vez en la carrera del user.
--   Esta columna queda explícita por consistencia con la categoría
--   season_unique (que ya tiene max=1).
--
--   La lógica actual de unlock_achievement bloquea cualquier duplicado de
--   multi_season independientemente del valor de max (ya está garantizado
--   "1 vez en la historia"). Este UPDATE es informativo/documentativo.
--
--   En el futuro, si se quiere permitir x2/x3 en multi-season, habrá que:
--     a) Subir el max_per_season aquí (ej. a 2 o 3)
--     b) Modificar unlock_achievement para respetar max en multi_season
--        en lugar de bloquear siempre. Hoy NO se hace (out of scope).
-- ============================================================================

update public.achievements
set recurrent_max_per_season = 1
where category = 'multi_season';

-- Verificación
do $$
declare
  v_total int;
  v_with_max int;
  v_auto int;
begin
  select count(*) into v_total
  from public.achievements where category = 'multi_season';

  select count(*) into v_with_max
  from public.achievements where category = 'multi_season' and recurrent_max_per_season = 1;

  select count(*) into v_auto
  from public.achievements where category = 'multi_season' and assignment = 'auto';

  raise notice 'multi_season: % total, % con max=1, % auto', v_total, v_with_max, v_auto;

  if v_total <> 25 then
    raise exception 'esperado 25 multi-season, encontrados %', v_total;
  end if;
  if v_with_max <> 25 then
    raise exception 'esperado 25 con max=1, encontrados %', v_with_max;
  end if;
end $$;
