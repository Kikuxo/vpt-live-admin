-- ============================================================================
-- Fix retroactivo: desenlazar Bader Oron de Test 2 user
-- Fecha: 2026-05-01 18:00
--
-- Test 2 user (id: c960faba-4349-49d1-b95d-5fb51e218320, name: "Test 2 Probando")
-- está matcheado a 3 participaciones:
--   1. TRIANA RUIZ DANIEL → DeepStack    ← matcheo manual (presumido OK)
--   2. TRIANA RUIZ DANIEL → Warm Up      ← matcheo automático por VPT ID
--   3. BADER ORON         → Warm Up      ← matcheo manual ERRÓNEO
--
-- "Bader Oron" no es Test 2. Lo desenlazamos.
-- Como el festival ya está procesado, también revertimos los puntos
-- otorgados retroactivamente al user Test 2 cuando se matcheó.
--
-- IMPORTANTE: este fix es local a UNA participation conocida. El cambio
-- estructural está en index.html (vpt-vip-admin) que añade validaciones
-- a confirmMatchPlayer() para evitar futuros errores similares.
-- ============================================================================

do $$
declare
  v_part_id uuid := '8bda2f3b-4dc7-49c9-bfe2-caa9844ef0e8';
  v_user_id uuid := 'c960faba-4349-49d1-b95d-5fb51e218320';
  v_part record;
  v_other_count int;
begin
  -- 1. Verificar la participation existe y está enlazada al user equivocado
  select * into v_part
  from public.tournament_participations
  where id = v_part_id;

  if not found then
    raise exception 'Participation % no existe', v_part_id;
  end if;

  if v_part.user_id <> v_user_id then
    raise notice 'Participation % ya no está enlazada a Test 2 (user_id actual: %)',
      v_part_id, v_part.user_id;
    return;
  end if;

  if upper(v_part.player_name) <> 'BADER ORON' then
    raise exception 'Participation % no es de Bader Oron (es de "%")',
      v_part_id, v_part.player_name;
  end if;

  -- 2. Desenlazar la participation
  update public.tournament_participations
  set user_id = null,
      status = 'unmatched'
  where id = v_part_id;

  -- 3. Ajustar season_main_tournaments del user.
  --    El Warm Up es is_main = true. Pero Test 2 user TAMBIÉN tiene la
  --    participation 381e0c8d (Warm Up de Daniel Triana) enlazada al mismo
  --    user_id. Como contamos count(distinct tournament_id), seguir teniendo
  --    una participation a ese mismo Warm Up basta para que season_main = 1.
  --    Solo decrementamos si el user NO tiene ninguna otra participation
  --    al mismo torneo.
  select count(*) into v_other_count
  from public.tournament_participations
  where user_id = v_user_id
    and tournament_id = v_part.tournament_id
    and status in ('matched', 'awarded');

  if v_other_count = 0 then
    -- No queda ninguna otra participation a este torneo: decrementar
    update public.users
    set season_main_tournaments = greatest(coalesce(season_main_tournaments, 0) - 1, 0)
    where id = v_user_id;
    raise notice 'season_main_tournaments decrementado para user %', v_user_id;
  else
    raise notice 'User % aún tiene % participation(s) a este torneo, no decrementamos',
      v_user_id, v_other_count;
  end if;

  raise notice 'Participation % desenlazada (Bader Oron ya NO es Test 2)', v_part_id;
end $$;

-- ════════════════════════════════════════════════════════════════════════════
-- Verificación
-- ════════════════════════════════════════════════════════════════════════════
do $$
declare
  v_count int;
begin
  select count(*) into v_count
  from public.tournament_participations
  where id = '8bda2f3b-4dc7-49c9-bfe2-caa9844ef0e8'
    and user_id is null
    and status = 'unmatched';

  if v_count <> 1 then
    raise exception 'La participation de Bader Oron no quedó como unmatched';
  end if;

  raise notice 'OK: Bader Oron está unmatched, listo para re-matchear correctamente';
end $$;
