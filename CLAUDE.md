# vpt-live-admin — Web admin live (VPT)

Admin tooling para festivales en directo, importación de XLSX y ranking. **Repo "fuente de verdad" para las migraciones de Supabase del ecosistema** — el único desde el que se generan.

> Lee también el `CLAUDE.md` de la carpeta padre (`C:\src\CLAUDE.md`) para el contexto del ecosistema completo.

## Stack

- **HTML/CSS/JS puro**, todo dentro de `index.html` (~8.000 líneas, app entera). Sin build step, sin bundler, sin Node.
- **Supabase JS v2** desde CDN
- **SheetJS** desde CDN (parseo de XLSX para festivales y Annual Ranking)
- Despliegue: cualquier static host (Vercel, Netlify, GitHub Pages, etc.)
- `scripts/generate-cards.ps1` — script PowerShell que regenera los SVG de cartas en `assets/cards/` (52 archivos)

## Supabase — workflow de migraciones

Este repo es el **único** desde el que se generan migraciones. Workflow:

```bash
cd C:\src\vpt-live-admin
supabase migration new <name>   # timestamp 14 dígitos YYYYMMDDHHMMSS
supabase db push
```

**Estado al 2026-05-02**: 40 migraciones, rango `20260424081610` → `20260501220000_vip_history_add_tiebreaker.sql`. Local == Remote.

`supabase/scripts/_query_flickr_broken_urls.sql` es diagnóstico, **aislado del CLI a propósito** — no migrarlo, no incluirlo en el flujo.

### Edge Functions

En `supabase/functions/`:
- `create-staff-account`
- `delete-staff-account`
- `update-user-role`

### Metadata del link

El link al proyecto remoto se guarda en `supabase/.temp/linked-project.json` (gitignoreado). Si cambias de portátil, hay que re-linkear con el access token. La carpeta `.supabase/` (oculta) **no la usa** este CLI — usa `supabase/.temp/`.

## Importación de festivales XLSX

Reglas inviolables:

- En las columnas de **MVP por festival** y **Annual Ranking**: usar **siempre el nombre real del jugador**, nunca el alias. Esto es lo que permite que el matching cross-tabla funcione.
- Si aparece un alias conocido, corregirlo en el XLSX **antes** de subir.

### Aliases Rozvadov 2026

| Alias | Nombre real |
|-------|-------------|
| `masgambling` | Alejandro Queijeiro (corregido 2026-04-29) |
| `newvyn69` | _pendiente_ |
| `teQuillaz0r` | _pendiente_ |
| `piraban` | _pendiente_ |

Si cualquiera de los pendientes vuelve a aparecer en otro festival, parar y conseguir el nombre real antes de procesar.

## Tablas de BBDD — decisión cerrada

Las 8 tablas vacías candidatas (`event_attendances`, `mvp_rankings`, `mvp_tournament_points`, `notifications`, `promotions`, `user_promotions`, `referrals`, `user_player_aliases`) **no se borran**. Decisión finalizada 2026-04-30.

## Paleta y gradientes

Compartidos con `fidelizacion_app`. Si haces UI aquí, replica los tokens del `CLAUDE.md` de ese repo o consulta el de la carpeta padre.

## Branch backup viva (2026-05-02)

- `backup-pre-reset-2026-05-02` apunta al commit `b7fe4ae` (3 commits descartados durante la sincronización del portátil).
- Solo local, no pusheada.
- Borrar con `git branch -D backup-pre-reset-2026-05-02` cuando se confirme que no hace falta nada de allí.
