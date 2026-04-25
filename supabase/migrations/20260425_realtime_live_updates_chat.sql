-- =====================================================================
-- VPT Live — Añadir live_updates y live_chat_messages a la publicación
-- supabase_realtime para habilitar suscripción WebSocket desde clientes.
-- Fecha: 2026-04-25
--
-- Contexto: P3 reemplaza el polling cada 30s del feed (admin+app
-- móvil) y el polling cada 3s del chat (app móvil) por realtime
-- real. Las demás tablas que P3 utiliza (festival_players,
-- festival_videos, player_badges, player_badge_assignments,
-- chip_history, update_mentions) ya están en la publicación desde
-- migrations anteriores.
--
-- Idempotente: el bloque DO catches `duplicate_object` por si la
-- migration se re-ejecuta o si alguna tabla ya estuviera añadida.
-- =====================================================================

do $$ begin
  alter publication supabase_realtime add table public.live_updates;
exception when duplicate_object then null; end $$;

do $$ begin
  alter publication supabase_realtime add table public.live_chat_messages;
exception when duplicate_object then null; end $$;
