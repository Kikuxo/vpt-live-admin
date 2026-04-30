-- ============================================================================
-- VIP System v2 — RPC process_redemption
-- Fecha: 2026-04-30 20:00
--
-- Función para gestionar el ciclo de vida de un canje (redemption):
--   - approve  : pending → approved
--   - reject   : pending|approved → rejected (REQUIERE reason; refund automático)
--   - fulfill  : approved → fulfilled (opcionalmente con info extra)
--   - cancel   : pending|approved → cancelled (refund automático)
--
-- Reglas críticas:
--   - Solo desde 'pending' se puede aprobar o rechazar
--   - Solo desde 'approved' se puede fulfillar o cancelar
--   - Estados finales (fulfilled, rejected, cancelled) no pueden cambiar
--   - reject y cancel: devuelven los puntos al user con type='correction'
--     (no cuenta nivel ni temporada — coherente con la decisión de UX)
--
-- Parámetros:
--   p_redemption_id    uuid   — canje a procesar
--   p_action           text   — 'approve' | 'reject' | 'fulfill' | 'cancel'
--   p_reason           text   — motivo (obligatorio para reject)
--   p_fulfillment_info jsonb  — info extra para fulfill (tracking, etc.)
-- ============================================================================

create or replace function public.process_redemption(
  p_redemption_id    uuid,
  p_action           text,
  p_reason           text default null,
  p_fulfillment_info jsonb default '{}'::jsonb
) returns void language plpgsql security definer as $$
declare
  v_red record;
  v_admin_id uuid;
  v_user_id uuid;
  v_refund_amount int;
  v_user_data record;
begin
  -- 1. Validar acción
  if p_action not in ('approve', 'reject', 'fulfill', 'cancel') then
    raise exception 'process_redemption: acción inválida "%". Permitidas: approve, reject, fulfill, cancel', p_action;
  end if;

  -- 2. Cargar canje con lock
  select * into v_red
  from public.redemptions
  where id = p_redemption_id
  for update;

  if not found then
    raise exception 'process_redemption: canje % no existe', p_redemption_id;
  end if;

  -- 3. Validar transición de estado
  case p_action
    when 'approve' then
      if v_red.status <> 'pending' then
        raise exception 'process_redemption: solo se pueden aprobar canjes "pending" (actual: %)', v_red.status;
      end if;
    when 'reject' then
      if v_red.status not in ('pending', 'approved') then
        raise exception 'process_redemption: solo se pueden rechazar canjes "pending" o "approved" (actual: %)', v_red.status;
      end if;
      if p_reason is null or trim(p_reason) = '' then
        raise exception 'process_redemption: el motivo (reason) es obligatorio al rechazar';
      end if;
    when 'fulfill' then
      if v_red.status <> 'approved' then
        raise exception 'process_redemption: solo se pueden fulfillar canjes "approved" (actual: %)', v_red.status;
      end if;
    when 'cancel' then
      if v_red.status not in ('pending', 'approved') then
        raise exception 'process_redemption: solo se pueden cancelar canjes "pending" o "approved" (actual: %)', v_red.status;
      end if;
  end case;

  -- 4. Capturar admin actual (si lo hay; si la llamada es por service_role, será null)
  v_admin_id := auth.uid();
  v_user_id := v_red.user_id;

  -- 5. Aplicar acción
  case p_action
    when 'approve' then
      update public.redemptions set
        status = 'approved',
        approved_by = v_admin_id,
        approved_at = now(),
        metadata = metadata || coalesce(p_fulfillment_info, '{}'::jsonb)
      where id = p_redemption_id;

    when 'reject' then
      -- Refund: devolver base_points_cost al user con type='correction'
      v_refund_amount := v_red.base_points_cost;

      select available_points, season_year into v_user_data
      from public.users
      where id = v_user_id
      for update;

      -- Insertar transacción de devolución
      insert into public.point_transactions (
        user_id, type, points, points_final, base_points, multiplier,
        season_year, description, source_type, source_id, metadata,
        balance_after, remaining_for_redeem, expires_at
      ) values (
        v_user_id,
        'correction',
        v_refund_amount,
        v_refund_amount,
        v_refund_amount,
        1.0,
        v_user_data.season_year,
        format('Devolución de canje rechazado: %s', coalesce(p_reason, 'sin motivo')),
        'redemption_refund',
        p_redemption_id,
        jsonb_build_object(
          'admin_user_id', v_admin_id,
          'rejected_redemption_id', p_redemption_id,
          'rejection_reason', p_reason
        ),
        coalesce(v_user_data.available_points, 0) + v_refund_amount,
        v_refund_amount,
        now() + interval '12 months'
      );

      -- Actualizar saldo del user
      update public.users
      set available_points = coalesce(available_points, 0) + v_refund_amount
      where id = v_user_id;

      -- Actualizar canje
      update public.redemptions set
        status = 'rejected',
        rejection_reason = p_reason,
        approved_by = v_admin_id,
        approved_at = coalesce(approved_at, now()),
        metadata = metadata || jsonb_build_object(
          'rejected_at', now(),
          'rejected_by', v_admin_id,
          'refund_amount', v_refund_amount
        )
      where id = p_redemption_id;

    when 'fulfill' then
      update public.redemptions set
        status = 'fulfilled',
        fulfilled_at = now(),
        metadata = metadata || coalesce(p_fulfillment_info, '{}'::jsonb) || jsonb_build_object(
          'fulfilled_by', v_admin_id
        )
      where id = p_redemption_id;

    when 'cancel' then
      -- Cancel también devuelve los puntos
      v_refund_amount := v_red.base_points_cost;

      select available_points, season_year into v_user_data
      from public.users
      where id = v_user_id
      for update;

      insert into public.point_transactions (
        user_id, type, points, points_final, base_points, multiplier,
        season_year, description, source_type, source_id, metadata,
        balance_after, remaining_for_redeem, expires_at
      ) values (
        v_user_id,
        'correction',
        v_refund_amount,
        v_refund_amount,
        v_refund_amount,
        1.0,
        v_user_data.season_year,
        format('Devolución de canje cancelado: %s', coalesce(p_reason, 'sin motivo')),
        'redemption_refund',
        p_redemption_id,
        jsonb_build_object(
          'admin_user_id', v_admin_id,
          'cancelled_redemption_id', p_redemption_id,
          'cancellation_reason', p_reason
        ),
        coalesce(v_user_data.available_points, 0) + v_refund_amount,
        v_refund_amount,
        now() + interval '12 months'
      );

      update public.users
      set available_points = coalesce(available_points, 0) + v_refund_amount
      where id = v_user_id;

      update public.redemptions set
        status = 'cancelled',
        rejection_reason = p_reason,
        metadata = metadata || jsonb_build_object(
          'cancelled_at', now(),
          'cancelled_by', v_admin_id,
          'refund_amount', v_refund_amount
        )
      where id = p_redemption_id;
  end case;
end;
$$;

-- Permisos: revoke from public/anon, grant to authenticated
revoke execute on function public.process_redemption(uuid, text, text, jsonb) from public;
revoke execute on function public.process_redemption(uuid, text, text, jsonb) from anon;
grant execute on function public.process_redemption(uuid, text, text, jsonb) to authenticated;

-- Verificación informativa
do $$
declare
  v_auth bool;
  v_anon bool;
begin
  v_auth := has_function_privilege('authenticated', 'public.process_redemption(uuid, text, text, jsonb)', 'EXECUTE');
  v_anon := has_function_privilege('anon',          'public.process_redemption(uuid, text, text, jsonb)', 'EXECUTE');
  raise notice 'process_redemption creada. authenticated=% anon=% (esperado tras commit: t / f)', v_auth, v_anon;
end $$;
