-- ============================================================================
-- VIP System v2 — RPC unlock_badge
-- Fecha: 2026-04-30 19:00
--
-- Función para desbloquear una badge a un user (asignación manual desde el
-- admin, o automática desde la app/festivales).
--
-- Reglas:
--   - Valida que la badge existe y está activa
--   - Bloquea si el user ya tiene esa badge (las badges son binarias, no
--     se pueden duplicar)
--   - Inserta fila en user_badges con metadata
--   - Devuelve nada significativo (la PK de user_badges es compuesta)
--
-- Parámetros:
--   p_user_id     uuid    — user destinatario
--   p_badge_code  text    — code de la badge (ej. 'first_tournament')
--   p_metadata    jsonb   — metadata extra para auditoría
-- ============================================================================

create or replace function public.unlock_badge(
  p_user_id    uuid,
  p_badge_code text,
  p_metadata   jsonb default '{}'::jsonb
) returns void language plpgsql security definer as $$
declare
  v_badge       record;
  v_user_exists bool;
  v_already     bool;
begin
  -- 1. Cargar badge
  select * into v_badge from public.badges where code = p_badge_code;
  if not found then
    raise exception 'unlock_badge: badge code "%" no existe', p_badge_code;
  end if;
  if not v_badge.active then
    raise exception 'unlock_badge: badge "%" no está activa', p_badge_code;
  end if;

  -- 2. Verificar que user existe
  select exists(select 1 from public.users where id = p_user_id) into v_user_exists;
  if not v_user_exists then
    raise exception 'unlock_badge: user % no existe', p_user_id;
  end if;

  -- 3. Bloquear si ya tiene la badge
  select exists(
    select 1 from public.user_badges
    where user_id = p_user_id and badge_id = v_badge.id
  ) into v_already;

  if v_already then
    raise exception 'unlock_badge: el user ya tiene desbloqueada la badge "%"', v_badge.code;
  end if;

  -- 4. Insertar
  insert into public.user_badges (user_id, badge_id, metadata)
  values (p_user_id, v_badge.id, p_metadata);
end;
$$;

-- Permisos: revoke from public, grant to authenticated
revoke execute on function public.unlock_badge(uuid, text, jsonb) from public;
revoke execute on function public.unlock_badge(uuid, text, jsonb) from anon;
grant execute on function public.unlock_badge(uuid, text, jsonb) to authenticated;

-- Verificación informativa
do $$
declare
  v_auth bool;
  v_anon bool;
begin
  v_auth := has_function_privilege('authenticated', 'public.unlock_badge(uuid, text, jsonb)', 'EXECUTE');
  v_anon := has_function_privilege('anon',          'public.unlock_badge(uuid, text, jsonb)', 'EXECUTE');
  raise notice 'unlock_badge creada. authenticated=% anon=% (esperado tras commit: t / f)', v_auth, v_anon;
end $$;
