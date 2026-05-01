-- ============================================================================
-- Trigger: garantizar coherencia is_main_tournament <-> type
-- Fecha: 2026-05-01 17:00
--
-- Defensa en profundidad: aunque el frontend mande mal el flag
-- is_main_tournament al insertar/actualizar un festival_tournament,
-- la BBDD lo recalcula automáticamente desde el type.
--
-- Es is_main_tournament = (type IN ('warm_up','main_event','high_roller')).
-- ============================================================================

create or replace function public._sync_is_main_tournament()
returns trigger
language plpgsql
as $$
begin
  new.is_main_tournament := (new.type in ('warm_up', 'main_event', 'high_roller'));
  return new;
end;
$$;

drop trigger if exists trg_sync_is_main_tournament on public.festival_tournaments;

create trigger trg_sync_is_main_tournament
  before insert or update of type, is_main_tournament
  on public.festival_tournaments
  for each row
  execute function public._sync_is_main_tournament();

-- ════════════════════════════════════════════════════════════════════════════
-- Verificación
-- ════════════════════════════════════════════════════════════════════════════
do $$
declare
  v_inconsistent int;
begin
  select count(*) into v_inconsistent
  from public.festival_tournaments
  where (type in ('warm_up','main_event','high_roller')) <> is_main_tournament;

  if v_inconsistent > 0 then
    -- Forzar UPDATE para que el trigger los corrija
    update public.festival_tournaments set type = type;

    select count(*) into v_inconsistent
    from public.festival_tournaments
    where (type in ('warm_up','main_event','high_roller')) <> is_main_tournament;

    if v_inconsistent > 0 then
      raise exception 'Tras forzar trigger, siguen % torneos con flag inconsistente', v_inconsistent;
    end if;
  end if;

  raise notice 'Trigger _sync_is_main_tournament instalado y datos coherentes';
end $$;
