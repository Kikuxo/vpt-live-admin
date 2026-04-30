-- ============================================================================
-- VIP System v2 — Beneficios oficiales por nivel VIP
-- Fecha: 2026-04-30 18:00
--
-- Origen: SISTEMA_VIP_-_VAMOS_POKER_TOUR.xlsx (hoja "Beneficios")
--
-- Cada nivel solo guarda SUS beneficios específicos (no acumulados).
-- La acumulación se construye en la app/UI mostrando "Todo lo de [nivel anterior]"
-- + los beneficios propios. Esta convención permite que la BBDD refleje el Excel
-- 1:1 sin duplicar texto.
--
-- Member: 11 beneficios base
-- Bronze: 3 propios + "Todo lo incluido en Member"
-- Silver: 3 propios + "Todo lo incluido en Bronze"
-- Gold:   2 propios + "Todo lo incluido en Silver"
-- Diamond: 7 propios + "Todo lo incluido en Gold"
-- Black:   5 propios + "Todo lo incluido en Diamond"
-- Icon:    5 propios + "Todo lo incluido en Black"
-- ============================================================================

-- MEMBER (Starter)
update public.vip_levels_config set benefits = jsonb_build_array(
  'Acceso al Club VPT y al Sistema VIP de Vamos Poker Tour',
  'Resultados y logros en perfil oficial',
  'Acumulación de puntos VPT por logros conseguidos',
  'Insignias VPT visibles en perfil',
  'Acceso al Ranking MVP oficial de cada festival',
  'Acceso a actividades oficiales en los festivales del Vamos Poker Tour (pádel, fútbol…)',
  'Acceso al Loyalty Award de la temporada',
  'Acceso a la promoción "Bubble Protection" en cada ME de la temporada',
  'Descuento del 5% en la VPT Store en la tienda física',
  'Descuento del 5% en los packs oficiales del VPT',
  'Acceso a la Newsletter del VPT con novedades del circuito antes que nadie'
) where level = 'member';

-- BRONZE (Player)
update public.vip_levels_config set benefits = jsonb_build_array(
  'Todo lo incluido en Member',
  'Elegible para Cash Game Deals en las paradas VPT (sujeto a disponibilidad)',
  'Descuento del 7,5% en la VPT Store en la tienda física',
  'Descuento del 7,5% en los packs oficiales del VPT'
) where level = 'bronze';

-- SILVER (Player)
update public.vip_levels_config set benefits = jsonb_build_array(
  'Todo lo incluido en Bronze',
  'Acceso preferente a promociones y ofertas exclusivas VPT',
  'Aparición activa en contenidos y medios oficiales VPT',
  'Acumulación de puntos VPT por Cash Game Deals cumplidos'
) where level = 'silver';

-- GOLD (Player)
update public.vip_levels_config set benefits = jsonb_build_array(
  'Todo lo incluido en Silver',
  'Regalo de bienvenida exclusivo VPT Gold (se entrega en el siguiente festival)',
  'Ofertas especiales en European Poker Masters y Gladiator Series'
) where level = 'gold';

-- DIAMOND (Premium)
update public.vip_levels_config set benefits = jsonb_build_array(
  'Todo lo incluido en Gold',
  '50% de descuento en la 1ª entrada del Main Event de la Final del VPT',
  'Torneo VIP exclusivo para jugadores Diamond+ en la Gran Final',
  'Merchandise exclusivo Diamond al inicio de cada temporada',
  'Posibilidad de upgrade en packs de hotel VPT (sujeto a disponibilidad)',
  'Presencia destacada en comunicaciones oficiales VPT',
  'Descuento del 10% en la VPT Store en la tienda física',
  'Descuento del 10% en los packs oficiales del VPT'
) where level = 'diamond';

-- BLACK (Premium)
update public.vip_levels_config set benefits = jsonb_build_array(
  'Todo lo incluido en Diamond',
  '1 entrada gratis para el Main Event de la Final del VPT',
  '1 noche gratis en cada pack oficial de hotel del VPT que se compre',
  'Fichero exclusivo de Vamos Poker Tour de regalo',
  'Descuento del 15% en la VPT Store en la tienda física',
  'Descuento del 15% en los packs oficiales del VPT'
) where level = 'black';

-- ICON (VIP)
update public.vip_levels_config set benefits = jsonb_build_array(
  'Todo lo incluido en Black',
  'Hotel gratis en 3 festivales durante el primer año del status (4 noches)',
  'Barra VIP incluida durante el festival (según condiciones del evento)',
  'Productos exclusivos y ediciones limitadas Icon en la VPT Store',
  'Descuento del 20% en la VPT Store en la tienda física',
  'Descuento del 20% en los packs oficiales del VPT'
) where level = 'icon';

-- Forzar updated_at para refrescar caches
update public.vip_levels_config set updated_at = now()
where level in ('member','bronze','silver','gold','diamond','black','icon');

-- Verificación
do $$
declare
  v_total int;
  v_with_benefits int;
  v_member_count int;
  v_icon_count int;
begin
  select count(*) into v_total from public.vip_levels_config;
  select count(*) into v_with_benefits
    from public.vip_levels_config
    where jsonb_array_length(benefits) > 0;
  select jsonb_array_length(benefits) into v_member_count
    from public.vip_levels_config where level = 'member';
  select jsonb_array_length(benefits) into v_icon_count
    from public.vip_levels_config where level = 'icon';

  raise notice 'vip_levels_config: % niveles, % con beneficios', v_total, v_with_benefits;
  raise notice '  member: % beneficios (esperado: 11)', v_member_count;
  raise notice '  icon:   % beneficios (esperado: 6)',  v_icon_count;

  if v_total <> 7         then raise exception 'esperado 7 niveles'; end if;
  if v_with_benefits <> 7 then raise exception 'todos los niveles deben tener al menos 1 beneficio'; end if;
  if v_member_count <> 11 then raise exception 'member debe tener 11, tiene %', v_member_count; end if;
  if v_icon_count <> 6    then raise exception 'icon debe tener 6, tiene %', v_icon_count; end if;
end $$;
