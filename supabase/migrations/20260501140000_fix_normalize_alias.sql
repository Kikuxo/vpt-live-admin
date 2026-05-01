-- ============================================================================
-- Fix: _normalize_alias missing dependency
-- Fecha: 2026-05-01 14:00
--
-- Bug: la función public._match_player_to_user llama a public._normalize_alias
-- que no existe en BBDD. Esto rompe el matching durante reprocess_festival
-- (y cualquier otra llamada a match_player_to_user).
--
-- Solución: crear _normalize_alias como helper de normalización de nombres
-- (lower + trim + sin acentos), y recrear _match_player_to_user para que
-- explícitamente lo use (idempotente, igual que está ahora).
-- ============================================================================

-- Helper: normaliza un nombre de jugador para matching
-- (lower + trim + sin acentos + sin espacios múltiples)
create or replace function public._normalize_alias(p_name text)
returns text language sql immutable as $$
  select trim(regexp_replace(
    translate(
      lower(coalesce(p_name, '')),
      'áàâäãéèêëíìîïóòôöõúùûüñÁÀÂÄÃÉÈÊËÍÌÎÏÓÒÔÖÕÚÙÛÜÑ',
      'aaaaaeeeeiiiiooooouuuunAAAAAEEEEIIIIOOOOOUUUUN'
    ),
    '\s+', ' ', 'g'
  ));
$$;

-- Recrear _match_player_to_user (idempotente, mismo cuerpo que ya tiene)
create or replace function public._match_player_to_user(
  p_player_name text,
  p_vpt_id      text default null
) returns uuid language plpgsql stable as $$
declare
  v_user_id     uuid;
  v_vpt_id_norm text;
  v_name_norm   text;
begin
  -- 1. Intento por vpt_id
  v_vpt_id_norm := public._normalize_vpt_id(p_vpt_id);
  if v_vpt_id_norm is not null and v_vpt_id_norm <> '' then
    select id into v_user_id
    from public.users
    where public._normalize_vpt_id(vpt_id) = v_vpt_id_norm
    limit 1;
    if v_user_id is not null then return v_user_id; end if;
  end if;

  -- 2. Intento por nombre normalizado
  if p_player_name is null or trim(p_player_name) = '' then
    return null;
  end if;
  v_name_norm := public._normalize_alias(p_player_name);
  select id into v_user_id
  from public.users
  where public._normalize_alias(name) = v_name_norm
  limit 1;

  return v_user_id;
end;
$$;

-- Verificación
do $$
declare
  v_count int;
  v_test_norm text;
begin
  select count(*) into v_count
  from pg_proc
  where pronamespace = 'public'::regnamespace
    and proname in ('_normalize_alias', '_normalize_vpt_id', '_match_player_to_user');

  if v_count <> 3 then
    raise exception 'Esperadas 3 funciones helper, encontradas %', v_count;
  end if;

  -- Test de normalización
  v_test_norm := public._normalize_alias('  José GARCÍA Niño  ');
  if v_test_norm <> 'jose garcia nino' then
    raise exception '_normalize_alias falló: % (esperado: jose garcia nino)', v_test_norm;
  end if;

  raise notice '_normalize_alias creada y validada (test: % → jose garcia nino)', v_test_norm;
end $$;
