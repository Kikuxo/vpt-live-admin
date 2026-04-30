-- ============================================================================
-- VIP System v2 — Tipo 'gift' + endurecer permisos de RPCs
-- Fecha: 2026-04-30
--
-- Cambios:
--   1. Permitir el type='gift' en point_transactions.type (regalos que solo
--      suman a available_points sin afectar al nivel VIP)
--   2. Actualizar add_points para que con type='gift' NO toque season_points
--      ni season_main_tournaments (solo available_points)
--   3. SEGURIDAD: revocar EXECUTE del rol 'anon' sobre las funciones del
--      sistema VIP. Estas funciones son SECURITY DEFINER y no validan
--      internamente que el llamante sea admin — exponerlas a 'anon' permitiría
--      a usuarios no autenticados ajustar puntos de cualquier user.
--   4. Mantener EXECUTE para 'authenticated' (necesario para que el panel
--      admin las llame desde JS estando logueado).
-- ============================================================================

-- 1. Actualizar el check constraint de point_transactions.type
alter table public.point_transactions drop constraint if exists point_transactions_type_check;
alter table public.point_transactions
  add constraint point_transactions_type_check
  check (type in ('earn','multi_earn','redeem','expire','admin_add','admin_sub','correction','gift'));

-- 2. Actualizar add_points para soportar 'gift'
create or replace function public.add_points(
  p_user_id        uuid,
  p_base_points    int,
  p_type           text,
  p_description    text,
  p_achievement_id uuid    default null,
  p_metadata       jsonb   default '{}'::jsonb,
  p_source_type    text    default null,
  p_source_id      uuid    default null,
  p_counts_main_tournament bool default false
) returns uuid language plpgsql security definer as $$
declare
  v_tx_id              uuid;
  v_user_season_year   int;
  v_expires_at         timestamptz;
  v_balance_after      int;
  v_affects_season     bool;
  v_affects_tournaments bool;
begin
  if p_base_points <= 0 then
    raise exception 'add_points: base_points debe ser > 0 (recibido: %)', p_base_points;
  end if;
  if p_type not in ('earn','multi_earn','admin_add','gift') then
    raise exception 'add_points: type inválido: % (esperado earn|multi_earn|admin_add|gift)', p_type;
  end if;

  select season_year into v_user_season_year from public.users where id = p_user_id for update;
  if not found then raise exception 'add_points: usuario % no existe', p_user_id; end if;

  v_expires_at    := now() + interval '12 months';
  v_balance_after := (select coalesce(available_points, 0) + p_base_points
                      from public.users where id = p_user_id);

  -- 'gift' = regalo: solo afecta a available_points, no a season_points ni torneos.
  -- Los demás tipos afectan a season_points; 'earn' y 'admin_add' pueden afectar
  -- a season_main_tournaments si p_counts_main_tournament = true.
  v_affects_season      := (p_type <> 'gift');
  v_affects_tournaments := (p_type <> 'gift') and p_counts_main_tournament;

  insert into public.point_transactions (
    user_id, type,
    points, points_final, multiplier,
    base_points, expires_at, remaining_for_redeem, season_year,
    metadata, source_type, source_id, description, balance_after
  ) values (
    p_user_id, p_type,
    p_base_points, p_base_points, 1.0,
    p_base_points, v_expires_at, p_base_points, v_user_season_year,
    p_metadata || jsonb_build_object('achievement_id', p_achievement_id),
    p_source_type, p_source_id, p_description, v_balance_after
  ) returning id into v_tx_id;

  update public.users set
    season_points    = season_points + (case when v_affects_season then p_base_points else 0 end),
    available_points = available_points + p_base_points,
    season_main_tournaments = season_main_tournaments + (case when v_affects_tournaments then 1 else 0 end)
  where id = p_user_id;

  -- Solo recalcular nivel si el ajuste podría haber afectado al nivel
  if v_affects_season or v_affects_tournaments then
    perform public.recalculate_vip_level(p_user_id);
  end if;

  return v_tx_id;
end;
$$;

-- 3. SEGURIDAD: revocar EXECUTE de 'anon' (público sin login) sobre todas las
--    funciones del sistema VIP. Estas funciones modifican datos críticos
--    (puntos, niveles VIP) y solo deben ser invocables por usuarios autenticados.
revoke execute on function public.add_points(uuid, int, text, text, uuid, jsonb, text, uuid, bool) from anon;
revoke execute on function public.redeem_points(uuid, int, text, text, jsonb) from anon;
revoke execute on function public.recalculate_vip_level(uuid) from anon;
revoke execute on function public.expire_old_points() from anon;
revoke execute on function public.start_new_season(int) from anon;
revoke execute on function public.apply_participation_points(uuid) from anon;

-- 4. Asegurar EXECUTE para 'authenticated' (idempotente — si ya estaba, no hace nada)
grant execute on function public.add_points(uuid, int, text, text, uuid, jsonb, text, uuid, bool) to authenticated;
grant execute on function public.redeem_points(uuid, int, text, text, jsonb) to authenticated;
grant execute on function public.recalculate_vip_level(uuid) to authenticated;
grant execute on function public.expire_old_points() to authenticated;
grant execute on function public.start_new_season(int) to authenticated;
grant execute on function public.apply_participation_points(uuid) to authenticated;

-- Verificación
do $$
declare
  v_auth_count int;
  v_anon_count int;
begin
  select count(*) into v_auth_count
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('add_points','redeem_points','recalculate_vip_level',
                      'expire_old_points','start_new_season','apply_participation_points')
    and has_function_privilege('authenticated', p.oid, 'EXECUTE');

  select count(*) into v_anon_count
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('add_points','redeem_points','recalculate_vip_level',
                      'expire_old_points','start_new_season','apply_participation_points')
    and has_function_privilege('anon', p.oid, 'EXECUTE');

  raise notice 'authenticated puede ejecutar: % de 6 funciones VIP', v_auth_count;
  raise notice 'anon puede ejecutar:          % de 6 funciones VIP (esperado: 0)', v_anon_count;
end $$;
