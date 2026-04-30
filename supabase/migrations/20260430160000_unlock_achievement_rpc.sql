-- ============================================================================
-- VIP System v2 — RPC unlock_achievement
-- Fecha: 2026-04-30 16:00
--
-- Función para desbloquear un logro a un user (asignación manual desde el
-- admin, o automática desde la app/XLSX). Encapsula toda la lógica:
--   - Valida que el logro está activo
--   - Aplica las reglas según category:
--     * recurrent     → incrementa unlock_count (puede repetirse)
--     * season_unique → bloquea si ya está desbloqueado esta temporada
--     * multi_season  → bloquea si ya está desbloqueado nunca
--   - Opcionalmente otorga los puntos del logro (llamando a add_points)
--   - Inserta/actualiza la fila en user_achievements
--   - Devuelve el ID de la fila creada/actualizada
-- ============================================================================

create or replace function public.unlock_achievement(
  p_user_id          uuid,
  p_achievement_code text,
  p_grant_points     bool default true,
  p_festival_id      uuid default null,
  p_metadata         jsonb default '{}'::jsonb
) returns uuid language plpgsql security definer as $$
declare
  v_ach            record;
  v_user           record;
  v_existing       record;
  v_ua_id          uuid;
  v_tx_id          uuid;
  v_season_year    int;
begin
  -- 1. Cargar logro
  select * into v_ach from public.achievements where code = p_achievement_code;
  if not found then
    raise exception 'unlock_achievement: achievement code "%" no existe', p_achievement_code;
  end if;
  if not v_ach.active then
    raise exception 'unlock_achievement: achievement "%" no está activo', p_achievement_code;
  end if;

  -- 2. Cargar user (lock para serializar)
  select id, season_year into v_user from public.users where id = p_user_id for update;
  if not found then
    raise exception 'unlock_achievement: user % no existe', p_user_id;
  end if;
  v_season_year := v_user.season_year;

  -- 3. Aplicar reglas según category
  if v_ach.category = 'season_unique' then
    select id, unlock_count into v_existing
    from public.user_achievements
    where user_id = p_user_id
      and achievement_id = v_ach.id
      and season_year = v_season_year
    limit 1;

    if found then
      raise exception 'unlock_achievement: el logro "%" ya está desbloqueado en la temporada %', v_ach.code, v_season_year;
    end if;

  elsif v_ach.category = 'multi_season' then
    select id, unlock_count into v_existing
    from public.user_achievements
    where user_id = p_user_id
      and achievement_id = v_ach.id
    limit 1;

    if found then
      raise exception 'unlock_achievement: el logro multi-season "%" ya está desbloqueado para este user', v_ach.code;
    end if;

  elsif v_ach.category = 'recurrent' then
    select id, unlock_count into v_existing
    from public.user_achievements
    where user_id = p_user_id
      and achievement_id = v_ach.id
      and season_year = v_season_year
    limit 1;

    if found then
      if v_ach.recurrent_max_per_season is not null
         and v_existing.unlock_count >= v_ach.recurrent_max_per_season then
        raise exception 'unlock_achievement: logro recurrente "%" alcanzó el máximo de % por temporada',
                        v_ach.code, v_ach.recurrent_max_per_season;
      end if;

      if p_grant_points and v_ach.points_base > 0 then
        v_tx_id := public.add_points(
          p_user_id := p_user_id,
          p_base_points := v_ach.points_base,
          p_type := 'earn',
          p_description := format('Logro: %s (×%s)', v_ach.display_name, v_existing.unlock_count + 1),
          p_achievement_id := v_ach.id,
          p_metadata := p_metadata || jsonb_build_object(
            'achievement_code', v_ach.code,
            'unlock_count', v_existing.unlock_count + 1,
            'manual', true
          ),
          p_source_type := 'achievement_unlock',
          p_source_id := v_ach.id,
          p_counts_main_tournament := false
        );
      end if;

      update public.user_achievements set
        unlock_count = unlock_count + 1,
        unlocked_at = now(),
        festival_id = coalesce(p_festival_id, festival_id),
        points_transaction_id = coalesce(v_tx_id, points_transaction_id),
        metadata = metadata || jsonb_build_object('last_unlock_at', now())
      where id = v_existing.id
      returning id into v_ua_id;

      return v_ua_id;
    end if;
  end if;

  -- 4. Inserción nueva
  if p_grant_points and v_ach.points_base > 0 then
    v_tx_id := public.add_points(
      p_user_id := p_user_id,
      p_base_points := v_ach.points_base,
      p_type := 'earn',
      p_description := format('Logro: %s', v_ach.display_name),
      p_achievement_id := v_ach.id,
      p_metadata := p_metadata || jsonb_build_object(
        'achievement_code', v_ach.code,
        'unlock_count', 1,
        'manual', true
      ),
      p_source_type := 'achievement_unlock',
      p_source_id := v_ach.id,
      p_counts_main_tournament := false
    );
  end if;

  insert into public.user_achievements (
    user_id, achievement_id, festival_id, season_year,
    unlock_count, points_transaction_id, metadata
  ) values (
    p_user_id, v_ach.id, p_festival_id, v_season_year,
    1, v_tx_id, p_metadata
  ) returning id into v_ua_id;

  return v_ua_id;
end;
$$;

-- Permisos: revocar de PUBLIC (Postgres concede automáticamente al crear),
-- otorgar solo a authenticated.
revoke execute on function public.unlock_achievement(uuid, text, bool, uuid, jsonb) from public;
grant execute on function public.unlock_achievement(uuid, text, bool, uuid, jsonb) to authenticated;

-- Verificación informativa (no falla si los grants no se ven aún por
-- transacción, lo importante es que las sentencias REVOKE/GRANT se ejecutaron).
do $$
declare
  v_auth_can bool;
  v_anon_can bool;
begin
  v_auth_can := has_function_privilege('authenticated',
    'public.unlock_achievement(uuid, text, bool, uuid, jsonb)', 'EXECUTE');
  v_anon_can := has_function_privilege('anon',
    'public.unlock_achievement(uuid, text, bool, uuid, jsonb)', 'EXECUTE');
  raise notice 'unlock_achievement creada. authenticated=% anon=% (anon false tras commit)',
    v_auth_can, v_anon_can;
end $$;
