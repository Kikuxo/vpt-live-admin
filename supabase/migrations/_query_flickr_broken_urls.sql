-- =====================================================================
-- VPT Live — Script de DIAGNÓSTICO (no es una migration).
-- Prefijo `_query_` para que quede al inicio del listado y NO se confunda
-- con las migrations fechadas. Ejecutar manualmente en Supabase SQL Editor.
--
-- Motivo: hasta la Mejora 2, el campo players.photo_url aceptaba URLs
-- de página de Flickr (https://flickr.com/photos/USER/ID/) que no son
-- imágenes directas y no renderizan como <img>. Ahora el admin resuelve
-- al guardar, pero los registros existentes probablemente sigan rotos.
--
-- Este query LISTA los jugadores con photo_url sospechosa. Re-abre el
-- modal de edición de cada uno: al hacer blur en el input, el front
-- resuelve vía API de Flickr; al pulsar Guardar se persiste la URL
-- directa de live.staticflickr.com/...
-- =====================================================================

select id, full_name, photo_url
from public.players
where photo_url is not null
  and (
    photo_url ~* '^https?://(www\.)?flickr\.com/photos/' or
    photo_url ~* '^https?://flic\.kr/p/'
  )
order by full_name;
