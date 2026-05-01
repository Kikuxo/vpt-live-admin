-- ============================================================================
-- VIP levels: ajuste de multiplicadores y descuentos
-- Fecha: 2026-05-01 15:00
--
-- Cambios:
--   1. ALTER tabla: vip_levels_config.multiplier permite NULL
--      (para Member y Bronze que NO canjean)
--
--   2. Multiplicador:
--      - Member: 1.00 → NULL (no canjea)
--      - Bronze: 1.25 → NULL (no canjea)
--      - Silver: 1.50 → 1.00
--      - Gold:   1.75 → 1.50
--      - Diamond, Black, Icon: sin cambios (2.00 / 2.50 / 3.00)
--
--   3. Descuento:
--      - Member: 5%   (sin cambios)
--      - Bronze: 7.5% → 5%
--      - Silver: 7.5% → 5%
--      - Gold:   7.5% → 5%
--      - Diamond: 10% (sin cambios)
--      - Black:   15% (sin cambios)
--      - Icon:    20% (sin cambios)
--
-- El RPC redeem_points ya valida vip_level >= silver ANTES de leer el
-- multiplier, así que NULL en Member/Bronze nunca se usa en una operación.
-- ============================================================================

-- ════════════════════════════════════════════════════════════════════════════
-- 1. ALTER: permitir NULL en multiplier
-- ════════════════════════════════════════════════════════════════════════════
alter table public.vip_levels_config alter column multiplier drop not null;

-- ════════════════════════════════════════════════════════════════════════════
-- 2. UPDATE vip_levels_config
-- ════════════════════════════════════════════════════════════════════════════
update public.vip_levels_config set multiplier = null,  discount_pct = 5.00  where level = 'member';
update public.vip_levels_config set multiplier = null,  discount_pct = 5.00  where level = 'bronze';
update public.vip_levels_config set multiplier = 1.00,  discount_pct = 5.00  where level = 'silver';
update public.vip_levels_config set multiplier = 1.50,  discount_pct = 5.00  where level = 'gold';
update public.vip_levels_config set multiplier = 2.00,  discount_pct = 10.00 where level = 'diamond';
update public.vip_levels_config set multiplier = 2.50,  discount_pct = 15.00 where level = 'black';
update public.vip_levels_config set multiplier = 3.00,  discount_pct = 20.00 where level = 'icon';

-- ════════════════════════════════════════════════════════════════════════════
-- 3. Verificación
-- ════════════════════════════════════════════════════════════════════════════
do $$
declare
  v_row record;
  v_errors text := '';
begin
  for v_row in
    select level, multiplier, discount_pct
    from public.vip_levels_config
    order by order_index
  loop
    if v_row.level = 'member' and (v_row.multiplier is not null or v_row.discount_pct <> 5.00) then
      v_errors := v_errors || format('member: multiplier=%s, discount=%s; ', v_row.multiplier, v_row.discount_pct);
    end if;
    if v_row.level = 'bronze' and (v_row.multiplier is not null or v_row.discount_pct <> 5.00) then
      v_errors := v_errors || format('bronze: multiplier=%s, discount=%s; ', v_row.multiplier, v_row.discount_pct);
    end if;
    if v_row.level = 'silver' and (v_row.multiplier <> 1.00 or v_row.discount_pct <> 5.00) then
      v_errors := v_errors || format('silver: multiplier=%s, discount=%s; ', v_row.multiplier, v_row.discount_pct);
    end if;
    if v_row.level = 'gold' and (v_row.multiplier <> 1.50 or v_row.discount_pct <> 5.00) then
      v_errors := v_errors || format('gold: multiplier=%s, discount=%s; ', v_row.multiplier, v_row.discount_pct);
    end if;
    if v_row.level = 'diamond' and (v_row.multiplier <> 2.00 or v_row.discount_pct <> 10.00) then
      v_errors := v_errors || format('diamond: multiplier=%s, discount=%s; ', v_row.multiplier, v_row.discount_pct);
    end if;
    if v_row.level = 'black' and (v_row.multiplier <> 2.50 or v_row.discount_pct <> 15.00) then
      v_errors := v_errors || format('black: multiplier=%s, discount=%s; ', v_row.multiplier, v_row.discount_pct);
    end if;
    if v_row.level = 'icon' and (v_row.multiplier <> 3.00 or v_row.discount_pct <> 20.00) then
      v_errors := v_errors || format('icon: multiplier=%s, discount=%s; ', v_row.multiplier, v_row.discount_pct);
    end if;
  end loop;

  if v_errors <> '' then
    raise exception 'Validación falló: %', v_errors;
  end if;

  raise notice 'vip_levels_config actualizada: 7 niveles con multipliers/discounts correctos';
end $$;
