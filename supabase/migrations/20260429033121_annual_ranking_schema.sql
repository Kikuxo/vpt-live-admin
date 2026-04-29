-- =====================================================================
-- VPT Live — Schema Annual Ranking + RPC replace_annual_ranking
-- Fecha: 2026-04-29
--
-- El "Annual Ranking" (Vamos a Las Vegas) suma los puntos del MVP de
-- los 5 mejores festivales + Final del año, con puntos extra ME/HR
-- por participación (3/5/7 festivales). Hasta ahora vivía hardcoded
-- en cliente (rankings_screen.dart, home_screen.dart). Esta migration
-- introduce la tabla `annual_ranking` + tabla auxiliar de uploads +
-- RPC `replace_annual_ranking` para que el admin pueda subir el XLSX
-- desde vpt-live-admin (commit B) y la app móvil consuma la fuente
-- real (commit C).
--
-- El RPC archiva por `archived_at` en lugar de borrar para conservar
-- histórico de uploads (útil para auditoría y comparativas
-- inter-temporada).
-- =====================================================================

-- ── Tabla principal ─────────────────────────────────────────
create table public.annual_ranking (
  id bigserial primary key,
  season int not null,
  position int not null,
  name text not null,
  -- "Spain" / "Romania" / "UK" — nombre país tal como viene del XLSX,
  -- NO el ISO 3166. La app móvil resolverá el ISO en cliente cuando
  -- haga falta para CountryFlag. Mantenemos string crudo aquí para
  -- preservar la fuente y permitir nombres no estándar (Kosovo, etc.).
  country text not null,
  -- BEST 5 + FINAL: la suma que rige el ranking visible.
  best_points numeric(10,4) not null,
  -- TOTAL POINTS (con bonificaciones extras incluidas).
  total_points numeric(10,4) not null,
  -- Puntos extra acumulados (ME/HR por 3/5/7 festivales). 0 por defecto.
  extra_points numeric(10,4) not null default 0,
  -- Columna FESTIVALS del XLSX (cuántos festivales jugó).
  festivals_count int not null,
  -- Desglose por festival. Shape: [{name, points, counted}]
  -- Solo festivales con puntos > 0. Reemplaza el `_mockBreakdown`
  -- provisional de la app móvil (rankings_screen.dart).
  festival_breakdown jsonb not null default '[]'::jsonb,
  -- Premio (solo top 10, NULL para resto).
  prize_description text,
  prize_value int,
  -- Validación cruzada con `name` — si el XLSX trae el ganador en
  -- otra columna, lo guardamos para detectar inconsistencias en el
  -- admin antes de publicar.
  prize_winner text,
  -- Bonus desglose: {me_3, hr_3, me_5, hr_5, me_6, hr_6}. Nullable.
  bonuses jsonb,
  created_at timestamptz not null default now(),
  -- Soft-archive para reemplazos: el RPC marca archived_at = now()
  -- en las filas previas antes de insertar el nuevo upload, en lugar
  -- de borrarlas. Histórico preservado.
  archived_at timestamptz
);

-- Una sola fila ACTIVA por (season, position). Las archivadas no
-- entran al index → permite tantos snapshots históricos como uploads.
create unique index annual_ranking_season_position_idx
  on public.annual_ranking (season, position)
  where archived_at is null;

-- Listado/orden por season de filas activas (la query principal de
-- la app móvil filtrará por season=2026 + archived_at IS NULL).
create index annual_ranking_season_idx
  on public.annual_ranking (season)
  where archived_at is null;

-- Lookup ad-hoc del histórico (auditoría desde el admin).
create index annual_ranking_archived_idx
  on public.annual_ranking (archived_at)
  where archived_at is not null;

-- ── RLS ─────────────────────────────────────────────────────
alter table public.annual_ranking enable row level security;

-- Lectura pública de las filas activas — la app móvil no requiere
-- autenticación para ver el ranking del público.
create policy "annual_ranking_select_public"
  on public.annual_ranking for select
  using (archived_at is null);

-- Escritura/borrado solo admin (mismo helper que el resto de
-- tablas: public.is_admin()).
create policy "annual_ranking_admin_all"
  on public.annual_ranking for all
  using (public.is_admin())
  with check (public.is_admin());

-- ── Tabla auxiliar de uploads ──────────────────────────────
-- Una fila por cada upload de XLSX. Permite mostrar al admin el
-- histórico de cuándo y quién subió cada snapshot, y a la app móvil
-- saber la marca temporal del último update visible.
create table public.annual_ranking_uploads (
  id bigserial primary key,
  season int not null,
  uploaded_at timestamptz not null default now(),
  uploaded_by uuid references auth.users(id),
  rows_count int not null,
  prizes_count int not null,
  source_filename text
);

create index annual_ranking_uploads_season_idx
  on public.annual_ranking_uploads (season, uploaded_at desc);

alter table public.annual_ranking_uploads enable row level security;

-- Lectura pública: la app móvil necesita ver `uploaded_at` para
-- pintar la fecha "Última actualización · DD/MM/YYYY" en el sub-tab
-- Ranking Anual.
create policy "annual_uploads_select_public"
  on public.annual_ranking_uploads for select
  using (true);

create policy "annual_uploads_admin_all"
  on public.annual_ranking_uploads for all
  using (public.is_admin())
  with check (public.is_admin());

-- ── RPC: replace_annual_ranking ────────────────────────────
-- Reemplaza el ranking de una temporada con un payload JSON nuevo.
-- Patrón consistente con replace_festival_mvp_ranking: SECURITY DEFINER
-- + validación is_admin() + archive en lugar de DELETE para conservar
-- histórico.
--
-- Payload esperado:
--   {
--     "entries": [
--       {
--         "position": 1,
--         "name": "...",
--         "country": "Spain",
--         "best_points": 361.56,
--         "total_points": 361.56,
--         "extra_points": 0,
--         "festivals_count": 1,
--         "festival_breakdown": [{"name": "Rozvadov", "points": 361.56, "counted": true}],
--         "prize_description": "Team Pro VPT 2027 + WSOP ME 2027",
--         "prize_value": 11000,
--         "prize_winner": "Francisco Penalva Rivas",
--         "bonuses": {"me_3": 25, "hr_3": 25}
--       },
--       ...
--     ]
--   }
--
-- Devuelve {season, rows_count, prizes_count} para feedback al admin.
create or replace function public.replace_annual_ranking(
  p_season int,
  p_payload jsonb,
  p_filename text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count int;
  v_prizes int;
  v_entry jsonb;
begin
  -- Solo admin (RLS aplicaría igual, pero defensivo y explícito).
  if not public.is_admin() then
    raise exception 'unauthorized: admin only';
  end if;

  -- Soft-archive de las filas activas previas de esta temporada.
  -- No DELETE: preservamos histórico para auditoría y comparativas.
  update public.annual_ranking
    set archived_at = now()
    where season = p_season
      and archived_at is null;

  -- Insertar las nuevas entries.
  v_count := 0;
  v_prizes := 0;

  for v_entry in select * from jsonb_array_elements(p_payload->'entries')
  loop
    insert into public.annual_ranking (
      season, position, name, country,
      best_points, total_points, extra_points, festivals_count,
      festival_breakdown, prize_description, prize_value, prize_winner,
      bonuses
    ) values (
      p_season,
      (v_entry->>'position')::int,
      v_entry->>'name',
      v_entry->>'country',
      coalesce((v_entry->>'best_points')::numeric, 0),
      coalesce((v_entry->>'total_points')::numeric, 0),
      coalesce((v_entry->>'extra_points')::numeric, 0),
      coalesce((v_entry->>'festivals_count')::int, 0),
      coalesce(v_entry->'festival_breakdown', '[]'::jsonb),
      v_entry->>'prize_description',
      nullif(v_entry->>'prize_value', '')::int,
      v_entry->>'prize_winner',
      v_entry->'bonuses'
    );

    v_count := v_count + 1;
    if v_entry->>'prize_description' is not null then
      v_prizes := v_prizes + 1;
    end if;
  end loop;

  -- Registrar el upload (uploaded_by puede ser NULL si auth.uid()
  -- devuelve null, pero is_admin() garantiza que hay sesión válida).
  insert into public.annual_ranking_uploads
    (season, uploaded_by, rows_count, prizes_count, source_filename)
  values
    (p_season, auth.uid(), v_count, v_prizes, p_filename);

  return jsonb_build_object(
    'season', p_season,
    'rows_count', v_count,
    'prizes_count', v_prizes
  );
end;
$$;

grant execute on function public.replace_annual_ranking(int, jsonb, text)
  to authenticated;
