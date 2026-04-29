-- =====================================================================
-- VPT Live — Rename extra key "Blinds" → "Ciegas" en live_updates
-- Fecha: 2026-04-25
--
-- Contexto:
-- live_updates.extra (jsonb) almacenaba la clave "Blinds" para el nivel
-- de ciegas del torneo. A partir de la mejora UI/UX del 2026-04-25 la
-- clave pasa a llamarse "Ciegas" para coherencia con el español del
-- resto del panel.
--
-- Esta migration renombra la clave en las filas existentes. El JS nuevo
-- sigue leyendo extra.Ciegas con fallback a extra.Blinds, así que si
-- esta migration tarda en aplicarse los posts viejos se siguen viendo.
-- Tras aplicarla, el fallback ya no se necesitaría, pero no lo quito
-- del cliente por seguridad.
--
-- Idempotente: solo toca filas donde la clave "Blinds" existe y la
-- clave "Ciegas" aún no. Se puede re-ejecutar sin efecto.
-- =====================================================================

update public.live_updates
set extra = (extra - 'Blinds') || jsonb_build_object('Ciegas', extra->'Blinds')
where extra ? 'Blinds'
  and not (extra ? 'Ciegas');

-- Caso raro: fila con AMBAS claves presentes (p.ej. alguien reeditó
-- mientras la migration no había corrido). Dejamos la clave Ciegas
-- como autoritativa y borramos la Blinds residual.
update public.live_updates
set extra = extra - 'Blinds'
where extra ? 'Blinds'
  and extra ? 'Ciegas';
