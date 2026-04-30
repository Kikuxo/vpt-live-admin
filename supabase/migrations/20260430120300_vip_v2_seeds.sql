-- ============================================================================
-- VIP System v2 — Migration 4/5: Seeds (datos iniciales)
-- ============================================================================
-- Carga inicial:
--   * vip_levels_config (7 niveles)
--   * achievements      (10 recurrentes + 50 únicos por temporada + 25 multi-season = 85)
--   * badges            (100 badges en 5 tiers)
-- Idempotente: usa ON CONFLICT DO UPDATE
-- ============================================================================

-- ============================================================================
-- 4.1 VIP_LEVELS_CONFIG — 7 niveles
-- ============================================================================

insert into public.vip_levels_config (
  level, display_name, tier, order_index, star_count, symbol_name,
  color_primary, color_accent,
  required_main_tournaments, required_season_points,
  required_2y_points, required_3y_points,
  multiplier, discount_pct
) values
  ('member',  'Member',  'starter', 1, 1, 'User',     '#7A726A', '#C8C0B4', null, null,    null,   null,   1.00, 5),
  ('bronze',  'Bronze',  'player',  2, 2, 'Bronze',   '#8B5E3C', '#D4A97A', 3,    5000,    null,   null,   1.25, 7.5),
  ('silver',  'Silver',  'player',  3, 3, 'Silver',   '#A8B4BE', '#E8EEF3', 6,    10000,   null,   null,   1.50, 7.5),
  ('gold',    'Gold',    'player',  4, 4, 'Gold',     '#A37C2C', '#E2D3A7', 10,   20000,   null,   null,   1.75, 7.5),
  ('diamond', 'Diamond', 'premium', 5, 5, 'Diamante', '#558899', '#A8D0DA', null, 50000,   null,   null,   2.00, 10),
  ('black',   'Black',   'premium', 6, 6, 'Corona',   '#1E1E22', '#6E737B', null, 100000,  null,   null,   2.50, 15),
  ('icon',    'Icon',    'vip',     7, 7, 'Star',     '#7B2E3A', '#C47A87', null, null,    250000, 400000, 3.00, 20)
on conflict (level) do update set
  display_name = excluded.display_name,
  tier = excluded.tier,
  order_index = excluded.order_index,
  star_count = excluded.star_count,
  symbol_name = excluded.symbol_name,
  color_primary = excluded.color_primary,
  color_accent = excluded.color_accent,
  required_main_tournaments = excluded.required_main_tournaments,
  required_season_points = excluded.required_season_points,
  required_2y_points = excluded.required_2y_points,
  required_3y_points = excluded.required_3y_points,
  multiplier = excluded.multiplier,
  discount_pct = excluded.discount_pct,
  updated_at = now();

-- ============================================================================
-- 4.2 ACHIEVEMENTS — 10 recurrentes + 50 únicos + 25 multi-season
-- ============================================================================

-- Helper para insertar achievements de forma idempotente
-- (usaremos ON CONFLICT (code) DO UPDATE)

-- ---- RECURRENTES (10) ----
insert into public.achievements (code, display_name, description, category, subcategory, points_base, required_level, assignment, recurrent_max_per_season, sort_order) values
  ('rec_friend_referral',   'Trae a un Amigo',     'Refiere a un nuevo jugador que se registre y dispute su primer torneo VPT.', 'recurrent', 'App',            100,  'member', 'auto',   50,   1),
  ('rec_play_tournament',   'A jugar!',            'Participa en cualquier torneo del VPT.',                                       'recurrent', 'Torneos',        100,  'member', 'auto',   null, 2),
  ('rec_itm_hunter',        'ITM Hunter',          'Alcanza los puestos premiados (ITM) en cualquier torneo del VPT.',           'recurrent', 'Torneos',        200,  'member', 'auto',   null, 3),
  ('rec_ft_hunter',         'FT Hunter',           'Llega a la mesa final en cualquier torneo del VPT.',                          'recurrent', 'Torneos',        500,  'member', 'auto',   null, 4),
  ('rec_trophy_hunter',     'Trophy Hunter',       'Gana cualquier torneo del VPT.',                                              'recurrent', 'Torneos',        1000, 'member', 'auto',   null, 5),
  ('rec_mvp_hunter',        'MVP Hunter',          'Consigue el premio MVP en cualquier parada del VPT.',                          'recurrent', 'Torneos',        1000, 'member', 'auto',   null, 6),
  ('rec_online_qualifier',  'Online Qualifier',    'Clasifícate a un evento VPT a través de los satélites online oficiales.',     'recurrent', 'Torneos',        500,  'bronze', 'manual', null, 7),
  ('rec_vpt_store',         'VPT Store',           'Gasta en la VPT Store: 100 pts por cada 20€ (compra mínima 50€).',            'recurrent', 'VPT Store',      100,  'bronze', 'manual', null, 8),
  ('rec_hotel_pack',        'Pack de hotel VPT',   'Adquiere un pack de hotel VPT (mínimo 300€).',                                'recurrent', 'VPT Store',      1000, 'bronze', 'manual', null, 9),
  ('rec_cash_game_deal',    'Cash Game Deal',      'Acude con deal y cumple las condiciones establecidas en la parada.',          'recurrent', 'Cash Game Deal', 2500, 'silver', 'manual', null, 10)
on conflict (code) do update set
  display_name = excluded.display_name,
  description = excluded.description,
  points_base = excluded.points_base,
  required_level = excluded.required_level,
  assignment = excluded.assignment,
  recurrent_max_per_season = excluded.recurrent_max_per_season,
  sort_order = excluded.sort_order;

-- ---- ÚNICOS POR TEMPORADA (50) ----
insert into public.achievements (code, display_name, description, category, subcategory, points_base, required_level, assignment, sort_order) values
  -- First-timer (11)
  ('uni_first_tournament',     'Primer Torneo',          'Disputa tu primer torneo de la temporada.',                                        'season_unique', 'First-timer',  100,  'member', 'auto', 11),
  ('uni_first_itm',            'Primer ITM',             'Consigue tu primer ITM oficial de la temporada.',                                  'season_unique', 'First-timer',  200,  'member', 'auto', 12),
  ('uni_first_ft',             'Primera Mesa Final',     'Alcanza tu primera Mesa Final (sin trofeo) oficial de la temporada.',              'season_unique', 'First-timer',  500,  'member', 'auto', 13),
  ('uni_first_trophy',         'Primer Trofeo',          'Gana tu primer torneo oficial de la temporada.',                                   'season_unique', 'First-timer',  1000, 'member', 'manual', 14),
  ('uni_mvp_champion',         'MVP Champion',           'Gana tu primer premio MVP en una parada de la temporada.',                         'season_unique', 'First-timer',  2000, 'member', 'auto', 15),
  ('uni_warmup_casher',        'Warm Up Casher',         'Consigue tu primer ITM en el Warm Up de la temporada.',                            'season_unique', 'First-timer',  200,  'member', 'auto', 16),
  ('uni_main_event_casher',    'Main Event Casher',      'Consigue tu primer ITM en el Main Event de la temporada.',                         'season_unique', 'First-timer',  300,  'member', 'auto', 17),
  ('uni_high_roller_casher',   'High Roller Casher',     'Consigue tu primer ITM en el High Roller de la temporada.',                        'season_unique', 'First-timer',  500,  'member', 'auto', 18),
  ('uni_warmup_ft',            'Warm Up Final Table',    'Alcanza tu primera Mesa Final en el Warm Up de la temporada.',                     'season_unique', 'First-timer',  500,  'member', 'auto', 19),
  ('uni_main_event_ft',        'Main Event Final Table', 'Alcanza tu primera Mesa Final en el Main Event de la temporada.',                  'season_unique', 'First-timer',  700,  'member', 'auto', 20),
  ('uni_high_roller_ft',       'High Roller Final Table','Alcanza tu primera Mesa Final en el High Roller de la temporada.',                 'season_unique', 'First-timer',  1000, 'member', 'auto', 21),
  -- VPT Regular (18 logros desde Bronze/Silver)
  ('uni_triple_threat',        'Triple Threat',          'Disputa el Warm Up, el Main Event y el High Roller en una misma parada del VPT.', 'season_unique', 'VPT Regular', 500,  'bronze', 'auto', 22),
  ('uni_dual_main',            'Dual Stop Main Event',   'Disputa 2 Main Events distintos del VPT durante la temporada.',                    'season_unique', 'VPT Regular', 500,  'bronze', 'auto', 23),
  ('uni_dual_hr',              'Dual Stop High Roller',  'Disputa 2 High Rollers distintos del VPT durante la temporada.',                   'season_unique', 'VPT Regular', 1000, 'bronze', 'auto', 24),
  ('uni_bubble_protection',    'Bubble Protection',      'Queda eliminado en burbuja en un Main Event y llévate la Bubble Protection.',     'season_unique', 'VPT Regular', 1000, 'bronze', 'auto', 25),
  ('uni_streak_attendant',     'Streak Attendant',       'Disputa el Main Event en 3 paradas consecutivas del VPT.',                         'season_unique', 'VPT Regular', 1000, 'bronze', 'auto', 26),
  ('uni_double_casher',        'Double Casher',          'Consigue ITM en el Main Event y en el High Roller de una misma parada.',           'season_unique', 'VPT Regular', 1000, 'bronze', 'auto', 27),
  ('uni_hot_streak_me',        'Hot Streak ME',          'Consigue ITM en 3 paradas consecutivas del VPT.',                                  'season_unique', 'VPT Regular', 1000, 'bronze', 'auto', 28),
  ('uni_wmh_champion',         'WU, ME o HR Champion',   'Gana el Warm Up, Main Event o el High Roller del VPT durante la temporada.',       'season_unique', 'VPT Regular', 1000, 'bronze', 'auto', 29),
  ('uni_grand_final',          'Grand Final',            'Participa en el Main Event de la Gran Final del VPT.',                             'season_unique', 'VPT Regular', 500,  'silver', 'auto', 30),
  ('uni_regular_warmup',       'VPT Regular Warm Up',    'Disputa 4 Warm Ups distintos del VPT en una misma temporada.',                     'season_unique', 'VPT Regular', 1000, 'silver', 'auto', 31),
  ('uni_regular_main',         'VPT Regular Main Event', 'Disputa 4 Main Events distintos del VPT en una misma temporada.',                  'season_unique', 'VPT Regular', 2000, 'silver', 'auto', 32),
  ('uni_regular_hr',           'VPT Regular High Roller','Disputa 4 High Rollers distintos del VPT en una misma temporada.',                 'season_unique', 'VPT Regular', 3000, 'silver', 'auto', 33),
  ('uni_global_side',          'Global Side Events Casher','ITM en Side Events (no WU/ME/HR) en 3 festivales distintos durante la temporada.', 'season_unique', 'VPT Regular', 1000, 'silver', 'auto', 34),
  ('uni_global_main',          'Global Main Event Casher','ITM en el Main Event de 3 festivales distintos durante la temporada.',            'season_unique', 'VPT Regular', 2000, 'silver', 'auto', 35),
  ('uni_global_hr',            'Global High Roller Casher','ITM en el High Roller de 3 festivales distintos durante la temporada.',          'season_unique', 'VPT Regular', 3000, 'silver', 'auto', 36),
  ('uni_mixed_player',         'Mixed Player',           'Disputa torneos en al menos 3 formatos distintos durante un mismo festival (Hold''em, PLO y OFC).', 'season_unique', 'VPT Regular', 2000, 'silver', 'auto', 37),
  ('uni_grinder',              'Grinder',                'Disputa 7 o más torneos oficiales en una misma parada del VPT.',                   'season_unique', 'VPT Regular', 3000, 'silver', 'auto', 38),
  ('uni_resiliencia',          'Resiliencia',            'Disputa 5 o más torneos en una misma parada sin conseguir ningún ITM.',            'season_unique', 'VPT Regular', 2500, 'silver', 'auto', 39),
  -- VPT Pro (18 logros desde Gold)
  ('uni_regular_player_20',    'Regular Player - 20 Torneos','Disputa 20 torneos oficiales del VPT durante la temporada.',                   'season_unique', 'VPT Pro',     1000, 'gold',   'auto', 40),
  ('uni_regular_player_50',    'Regular Player - 50 Torneos','Disputa 50 torneos oficiales del VPT durante la temporada.',                   'season_unique', 'VPT Pro',     2000, 'gold',   'auto', 41),
  ('uni_itm_hunter_10',        'ITM Hunter - 10 Cashes', '10 ITM oficiales VPT durante la temporada.',                                       'season_unique', 'VPT Pro',     1000, 'gold',   'auto', 42),
  ('uni_itm_hunter_20',        'ITM Hunter - 20 Cashes', '20 ITM oficiales VPT durante la temporada.',                                       'season_unique', 'VPT Pro',     2000, 'gold',   'auto', 43),
  ('uni_ft_hunter_5',          'FT Hunter - 5 Mesas Finales','Consigue 5x Mesa Final VPT durante la temporada.',                             'season_unique', 'VPT Pro',     1000, 'gold',   'auto', 44),
  ('uni_ft_hunter_10',         'FT Hunter - 10 Mesas Finales','Consigue 10x Mesa Final VPT durante la temporada.',                           'season_unique', 'VPT Pro',     2000, 'gold',   'auto', 45),
  ('uni_trophy_hunter_3',      'Trophy Hunter - 3 Wins', 'Gana 3x trofeos VPT durante la temporada.',                                        'season_unique', 'VPT Pro',     1000, 'gold',   'auto', 46),
  ('uni_trophy_hunter_10',     'Trophy Hunter - 10 Wins','Gana 10x trofeos VPT durante la temporada.',                                       'season_unique', 'VPT Pro',     2000, 'gold',   'auto', 47),
  ('uni_hat_trick',            'Hat Trick',              'Entra en ITM en WU, ME y HR durante el mismo festival.',                           'season_unique', 'VPT Pro',     1000, 'gold',   'auto', 48),
  ('uni_flag_hunter_3',        'Flag Hunter - 3 Países', 'ITM en torneos VPT en 3 países diferentes durante la temporada.',                   'season_unique', 'VPT Pro',     1000, 'gold',   'auto', 49),
  ('uni_triple_threat_x3',     'Triple Threat x3',       'Triple Threat en 3 festivales distintos del VPT.',                                 'season_unique', 'VPT Pro',     1000, 'gold',   'auto', 50),
  ('uni_double_bubble',        'Double Bubble',          'Queda burbuja en 2 o más torneos de un mismo festival de VPT.',                    'season_unique', 'VPT Pro',     1000, 'gold',   'auto', 51),
  ('uni_mixed_winner',         'Mixed Winner',           'Gana un torneo en 3 formatos diferentes (Holdem, PLO, OFC) durante una temporada.', 'season_unique', 'VPT Pro',     1000, 'gold',   'auto', 52),
  ('uni_super_streak',         'Super Streak Attendant', 'Disputa el Main Event en 5 paradas consecutivas del VPT.',                          'season_unique', 'VPT Pro',     2000, 'gold',   'auto', 53),
  ('uni_globetrotter',         'Globetrotter',           'ITM en el ME y HR en 3 países distintos en cada uno durante la temporada.',         'season_unique', 'VPT Pro',     2000, 'gold',   'auto', 54),
  ('uni_mvp_multi_champ',      'MVP Multi-Champion',     'Gana 2 o más premios MVP de paradas del VPT durante la temporada.',                 'season_unique', 'VPT Pro',     4000, 'gold',   'auto', 55),
  ('uni_vpt_triple_corona',    'VPT Triple Corona',      'Gana el ME, el HR y el MVP en la misma temporada de VPT.',                          'season_unique', 'VPT Pro',     4000, 'gold',   'auto', 56),
  ('uni_vpt_full_season',      'VPT Full Season',        'Disputa TODOS los Main Events de VPT de una temporada (Final incluida).',           'season_unique', 'VPT Pro',     15000, 'gold',  'auto', 57),
  -- Partners Events (3)
  ('uni_kpe_event',            'Kikuxo Poker Events',    'Disputa un Main Event de Gladiator Series o European Poker Masters.',               'season_unique', 'Partners Events', 2000,  'gold', 'manual', 58),
  ('uni_kpe_regular',          'Kikuxo Poker Events Regular','Disputa 1x ME de cada marca KPE: Vamos, Gladiator y EPM.',                      'season_unique', 'Partners Events', 5000,  'gold', 'manual', 59),
  ('uni_kpe_triple_corona',    'Kikuxo Poker Events Triple Corona','Gana un torneo de cada marca de KPE: Vamos, Gladiator y EPM.',            'season_unique', 'Partners Events', 15000, 'gold', 'manual', 60)
on conflict (code) do update set
  display_name = excluded.display_name,
  description = excluded.description,
  points_base = excluded.points_base,
  required_level = excluded.required_level,
  assignment = excluded.assignment,
  sort_order = excluded.sort_order;

-- ---- MULTI-SEASON (25) ----
insert into public.achievements (code, display_name, description, category, subcategory, points_base, required_level, assignment, sort_order) values
  ('ms_player_100',         'Player Histórico - 100 participaciones',  'Participa en 100 torneos del VPT a lo largo de tu carrera.',                       'multi_season', 'Multi-Season', 1000,  'diamond', 'auto', 61),
  ('ms_player_200',         'Player Histórico - 200 participaciones',  'Participa en 200 torneos del VPT a lo largo de tu carrera.',                       'multi_season', 'Multi-Season', 2000,  'diamond', 'auto', 62),
  ('ms_me_player_20',       'ME Player Histórico - 20 participaciones','Participa en 20 Main Event del VPT a lo largo de tu carrera.',                     'multi_season', 'Multi-Season', 2000,  'diamond', 'auto', 63),
  ('ms_hr_player_20',       'HR Player Histórico - 20 participaciones','Participa en 20 High Rollers del VPT a lo largo de tu carrera.',                   'multi_season', 'Multi-Season', 2000,  'diamond', 'auto', 64),
  ('ms_itm_hunter_50',      'ITM Hunter Histórico - 50 Cashes',        'Consigue 50 ITM oficiales en cualquier torneo del VPT a lo largo de tu carrera.', 'multi_season', 'Multi-Season', 2000,  'diamond', 'auto', 65),
  ('ms_itm_hunter_100',     'ITM Hunter Histórico - 100 Cashes',       'Consigue 100 ITM oficiales en cualquier torneo del VPT a lo largo de tu carrera.','multi_season', 'Multi-Season', 5000,  'diamond', 'auto', 66),
  ('ms_ft_hunter_25',       'FT Hunter Histórico - 25 Mesas Finales',  'Alcanza 25 mesas finales en cualquier torneo del VPT a lo largo de tu carrera.',  'multi_season', 'Multi-Season', 2000,  'diamond', 'auto', 67),
  ('ms_ft_hunter_50',       'FT Hunter Histórico - 50 Mesas Finales',  'Alcanza 50 mesas finales en cualquier torneo del VPT a lo largo de tu carrera.',  'multi_season', 'Multi-Season', 5000,  'diamond', 'auto', 68),
  ('ms_trophy_hunter_10',   'Trophy Hunter Histórico - 10 Wins',       'Gana 10 trofeos en cualquier torneo del VPT a lo largo de tu carrera.',           'multi_season', 'Multi-Season', 5000,  'diamond', 'auto', 69),
  ('ms_trophy_hunter_25',   'Trophy Hunter Histórico - 25 Wins',       'Gana 25 trofeos en cualquier torneo del VPT a lo largo de tu carrera.',           'multi_season', 'Multi-Season', 10000, 'diamond', 'auto', 70),
  ('ms_mvp_hunter_3',       'MVP Hunter Histórico - 3 MVPs',           'Gana 3 premios MVP en paradas del VPT a lo largo de tu carrera.',                 'multi_season', 'Multi-Season', 5000,  'diamond', 'auto', 71),
  ('ms_mvp_hunter_10',      'MVP Hunter Histórico - 10 MVPs',          'Gana 10 premios MVP en paradas del VPT a lo largo de tu carrera.',                'multi_season', 'Multi-Season', 10000, 'diamond', 'auto', 72),
  ('ms_flag_hunter_5',      'Flag Hunter Histórico - 5 Países',        'ITM en torneos oficiales del VPT en 5 países distintos a lo largo de tu carrera.','multi_season', 'Multi-Season', 2000,  'diamond', 'auto', 73),
  ('ms_flag_hunter_10',     'Flag Hunter Histórico - 10 Países',       'ITM en torneos oficiales del VPT en 10 países distintos a lo largo de tu carrera.','multi_season', 'Multi-Season', 5000, 'diamond', 'auto', 74),
  ('ms_jugador_recurrente_x2','Jugador recurrente x2',                 'Disputa el Main Event de 2 ciudades diferentes durante 3 temporadas.',             'multi_season', 'Multi-Season', 5000,  'diamond', 'auto', 75),
  ('ms_jugador_recurrente_x5','Jugador recurrente x5',                 'Disputa el Main Event de 5 ciudades diferentes durante 3 temporadas.',             'multi_season', 'Multi-Season', 10000, 'diamond', 'auto', 76),
  ('ms_vpt_legend_2',       'VPT Legend - 2 Seasons',                  'Participa en al menos 4 festivales del VPT durante 2 temporadas distintas.',       'multi_season', 'Multi-Season', 2000,  'diamond', 'auto', 77),
  ('ms_vpt_legend_3',       'VPT Legend - 3 Seasons',                  'Participa en al menos 4 festivales del VPT durante 3 temporadas distintas.',       'multi_season', 'Multi-Season', 5000,  'diamond', 'auto', 78),
  ('ms_vpt_legend_5',       'VPT Legend - 5 Seasons',                  'Participa en al menos 4 festivales del VPT durante 5 temporadas distintas.',       'multi_season', 'Multi-Season', 10000, 'diamond', 'auto', 79),
  ('ms_team_pro_2',         'VPT Team Pro - 2 Seasons',                'Consigue el pack VPT Team Pro en al menos 2 temporadas del VPT.',                  'multi_season', 'Multi-Season', 5000,  'diamond', 'auto', 80),
  ('ms_team_pro_3',         'VPT Team Pro - 3 Seasons',                'Consigue el pack VPT Team Pro en al menos 3 temporadas del VPT.',                  'multi_season', 'Multi-Season', 10000, 'diamond', 'auto', 81),
  ('ms_team_pro_5',         'VPT Team Pro - 5 Seasons',                'Consigue el pack VPT Team Pro en al menos 5 temporadas del VPT.',                  'multi_season', 'Multi-Season', 15000, 'diamond', 'auto', 82),
  ('ms_cgd_5',              'Cash Game Deal Regular - 5 Deals',        'Cumple 5 Cash Game Deals en festivales del VPT a lo largo de tu carrera.',         'multi_season', 'Multi-Season', 5000,  'diamond', 'auto', 83),
  ('ms_cgd_10',             'Cash Game Deal Regular - 10 Deals',       'Cumple 10 Cash Game Deals en festivales del VPT a lo largo de tu carrera.',        'multi_season', 'Multi-Season', 10000, 'diamond', 'auto', 84),
  ('ms_cgd_25',             'Cash Game Deal Regular - 25 Deals',       'Cumple 25 Cash Game Deals en festivales del VPT a lo largo de tu carrera.',        'multi_season', 'Multi-Season', 15000, 'diamond', 'auto', 85)
on conflict (code) do update set
  display_name = excluded.display_name,
  description = excluded.description,
  points_base = excluded.points_base,
  required_level = excluded.required_level,
  assignment = excluded.assignment,
  sort_order = excluded.sort_order;

-- ============================================================================
-- 4.3 BADGES — 100 badges en 5 tiers
-- ============================================================================

insert into public.badges (code, display_name, description, tier, category, sort_order) values
  -- Rookie (10)
  ('badge_vpt_club',           'VPT Club',           'Regístrate en el programa VPT Club.',                                          'rookie', 'App',           1),
  ('badge_perfil_completo',    'Perfil Completo',    'Completa todos los campos de tu perfil VPT.',                                  'rookie', 'App',           2),
  ('badge_cumple',             'Cumpleaños',         'Añade tu fecha de nacimiento al perfil.',                                      'rookie', 'App',           3),
  ('badge_trae_amigo',         'Trae a un Amigo',    'Trae a un amigo a la App a través del programa de referidos.',                'rookie', 'App',           4),
  ('badge_primer_torneo',      'Primer Torneo',      'Juega tu primer torneo VPT verificado.',                                       'rookie', 'Torneos',       5),
  ('badge_primer_pack',        'Primer Pack',        'Realiza tu primer pedido en la VPT Store física.',                             'rookie', 'VPT Store',     6),
  ('badge_home_away',          'Home Away',          'Compra tu primer pack de hotel VPT.',                                          'rookie', 'VPT Store',     7),
  ('badge_off_the_felt',       'Off the Felt',       'Participa en tu primera actividad oficial del VPT.',                           'rookie', 'Offpoker',      8),
  ('badge_online_qualifier',   'Online Qualifier',   'Clasifícate online en los satélites oficiales a un evento VPT.',               'rookie', 'Online',        9),
  ('badge_grinder_rookie',     'Grinder',            'Participa en 3 torneos diferentes durante un mismo Festival del VPT.',         'rookie', 'Torneos',       10),
  -- Player (20)
  ('badge_primer_itm',         'Primer ITM',         'Consigue tu primer ITM en un torneo VPT.',                                     'player', 'ITM',           11),
  ('badge_bronze_member',      'Bronze Member',      'Alcanza el nivel Bronze por primera vez.',                                     'player', 'Sistema VIP',   12),
  ('badge_mixed_player',       'Mixed Player',       'Participa en 3 torneos con formatos distintos (NLH, PLO, OFC).',               'player', 'Torneos',       13),
  ('badge_main_event_debut',   'Main Event Debut',   'Juega tu primer Main Event VPT.',                                              'player', 'Torneos',       14),
  ('badge_high_roller_debut',  'High Roller Debut',  'Juega tu primer High Roller VPT.',                                             'player', 'Torneos',       15),
  ('badge_hotel_regular',      'Hotel Regular',      'Compra 3 packs de hotel VPT.',                                                 'player', 'VPT Store',     16),
  ('badge_cash_game_player',   'Cash Game Player',   'Participa en tu primer Cash Game Deal VPT.',                                   'player', 'Cash Game Deal',17),
  ('badge_mvp_top10',          'MVP TOP 10',         'Aparece en el TOP 10 del Ranking MVP de una parada VPT.',                      'player', 'MVP',           18),
  ('badge_two_flags',          'Two Flags',          'Juega torneos VPT en 2 países distintos.',                                     'player', 'Flaghunter',    19),
  ('badge_team_player',        'Team Player',        'Participa en 3 actividades Vamos distintas.',                                  'player', 'Offpoker',      20),
  ('badge_itm_machine',        'ITM Machine',        'Consigue 5 ITMs en cualquier torneo VPT.',                                     'player', 'ITM',           21),
  ('badge_primer_trofeo',      'Primer Trofeo',      'Gana tu primer torneo VPT.',                                                   'player', 'Trofeos',       22),
  ('badge_vpt_merch_fan',      'VPT Merch Fan',      'Realiza 3 compras en la VPT Store.',                                           'player', 'VPT Store',     23),
  ('badge_ft_rookie',          'Final Table Rookie', 'Llega a tu primera Mesa Final en VPT.',                                        'player', 'Mesa Final',    24),
  ('badge_festival_regular',   'Festival Regular',   'Juega en 3 festivales distintos VPT.',                                         'player', 'Torneos',       25),
  ('badge_bubble_boy',         'Bubble Boy',         'Queda como jugador burbuja en un torneo del VPT.',                             'player', 'Torneos',       26),
  ('badge_silver_member',      'Silver Member',      'Alcanza el nivel Silver por primera vez.',                                     'player', 'Sistema VIP',   27),
  ('badge_main_event_casher',  'Main Event Casher',  'Consigue tu primer ITM en un Main Event VPT.',                                 'player', 'ITM',           28),
  ('badge_high_roller_casher', 'High Roller Casher', 'Consigue tu primer ITM en un High Roller VPT.',                                'player', 'ITM',           29),
  ('badge_patch_holder',       'Patch Holder',       'Valida tu foto oficial con el patch VPT.',                                     'player', 'Promoción',     30),
  -- Pro (30)
  ('badge_gold_member',        'Gold Member',        'Alcanza el nivel Gold por primera vez.',                                       'pro', 'Sistema VIP',     31),
  ('badge_triple_flags',       'Triple Flags',       'Disputa torneos VPT en 3 países distintos.',                                   'pro', 'Flaghunter',      32),
  ('badge_itm_hunter',         'ITM Hunter',         'Consigue 10 ITMs en torneos VPT.',                                             'pro', 'ITM',             33),
  ('badge_grand_finalist',     'Grand Finalist',     'Participar en el Main Event de la Final del VPT.',                             'pro', 'Torneos',         34),
  ('badge_mvp',                'MVP',                'Gana un premio MVP en una parada VPT.',                                        'pro', 'MVP',             35),
  ('badge_double_down',        'Double Down',        'Llega a 2 Mesas Finales en una misma temporada.',                              'pro', 'Mesa Final',      36),
  ('badge_season_opener',      'Season Opener',      'Disputa el primer festival oficial de una temporada VPT.',                     'pro', 'Torneos',         37),
  ('badge_mixed_casher',       'Mixed Casher',       'ITM en 3 modalidades distintas de torneo VPT (NLH, PLO, OFC).',                'pro', 'ITM',             38),
  ('badge_cgd_pro',            'Cash Game Deal Pro', 'Completa 3 Cash Game Deals en VPT.',                                           'pro', 'Cash Game Deal',  39),
  ('badge_main_event_ft',      'Main Event Final Table','Llega a Mesa Final en un Main Event VPT.',                                  'pro', 'Mesa Final',      40),
  ('badge_hr_ft',              'High Roller Final Table','Llega a Mesa Final en un High Roller VPT.',                                'pro', 'Mesa Final',      41),
  ('badge_european_tour',      'European Tour',      'Disputa en 4 países distintos en una temporada.',                              'pro', 'Flaghunter',      42),
  ('badge_double_champion',    'Double Champion',    'Gana 2 trofeos VPT en una misma temporada.',                                   'pro', 'Trofeos',         43),
  ('badge_vpt_regular',        'VPT Regular',        'Disputa 4 Main Events distintos en una temporada.',                            'pro', 'Torneos',         44),
  ('badge_hr_regular',         'High Roller Regular','Disputa 4 High Rollers distintos en una temporada.',                            'pro', 'Torneos',         45),
  ('badge_gladiator',          'Gladiator',          'Disputa el Main Event del Gladiator Poker Series.',                             'pro', 'Partner Events',  46),
  ('badge_epm_player',         'EPM Player',         'Disputa el Main Event del European Poker Masters.',                             'pro', 'Partner Events',  47),
  ('badge_back_to_back',       'Back to Back',       'ITM en 2 torneos consecutivos en el mismo festival.',                          'pro', 'ITM',             48),
  ('badge_hello_again',        'Hello Again',        'Disputa el Main Event de 2 ciudades diferentes al menos 2 veces.',             'pro', 'Torneos',         49),
  ('badge_hot_streak',         'Hot Streak',         'Consigue ITM en 3 paradas consecutivas del VPT.',                              'pro', 'ITM',             50),
  ('badge_vpt_veteran',        'VPT Veteran',        'Completa 2 temporadas con al menos 3 festivales cada una.',                    'pro', 'Torneos',         51),
  ('badge_night_grinder',      'Night Grinder',      'Disputa 5 side events nocturnos en festivales VPT.',                           'pro', 'Torneos',         52),
  ('badge_full_season',        'Full Season',        'Disputa +7 Main Events del VPT durante una misma temporada.',                  'pro', 'Torneos',         53),
  ('badge_diamond_member',     'Diamond Member',     'Alcanza el nivel Diamond por primera vez.',                                    'pro', 'Sistema VIP',     54),
  ('badge_kpe_regular',        'KPE Regular',        'Disputa 1 ME de cada marca KPE: Vamos, Gladiator y EPM.',                      'pro', 'Partner Events',  55),
  ('badge_cgd_specialist',     'Cash Game Deal Specialist','Completa 5 Cash Game Deals en VPT.',                                     'pro', 'Cash Game Deal',  56),
  ('badge_bubble_protection',  'Bubble Protection',  'Consigue la Bubble Protection (burbuja en el ME y estar registrado).',         'pro', 'Torneos',         57),
  ('badge_triple_mvp',         'Triple MVP',         'Gana 3 premios MVP en paradas VPT.',                                           'pro', 'MVP',             58),
  ('badge_five_flags',         'Five Flags',         'ITM en torneos VPT en 5 países distintos.',                                    'pro', 'Flaghunter',      59),
  ('badge_hotel_connoisseur',  'Hotel Connoisseur',  'Compra packs de hotel en 5 festivales distintos.',                             'pro', 'VPT Store',       60),
  -- Legend (30)
  ('badge_black_member',       'Black Member',       'Alcanza el nivel Black por primera vez.',                                      'legend', 'Sistema VIP',  61),
  ('badge_loyalty_award',      'Loyalty Award',      'Gana el last longer del Loyalty Award en la Gran Final.',                      'legend', 'Loyalty Award',62),
  ('badge_main_event_champ',   'Main Event Champion','Gana un Main Event VPT.',                                                       'legend', 'Trofeos',      63),
  ('badge_hr_champ',           'High Roller Champion','Gana un High Roller VPT.',                                                     'legend', 'Trofeos',      64),
  ('badge_20_cashes',          '20 Cashes',          'Acumula 20 ITMs en cualquier torneo VPT.',                                     'legend', 'ITM',          65),
  ('badge_ft_hunter',          'Final Table Hunter', 'Llega a 10 Mesas Finales en torneos VPT.',                                     'legend', 'Mesa Final',   66),
  ('badge_itm_globetrotter',   'ITM Globetrotter',   'ITM en ME y HR en 3 países distintos en una temporada.',                       'legend', 'Flaghunter',   67),
  ('badge_todo_terreno',       'Todo Terreno',       'Gana 1 trofeo en 3 modalidades distintas (Hold''em, PLO, OFC).',                'legend', 'Torneos',      68),
  ('badge_kpe_season_regular', 'KPE Season Regular', 'Disputa 1 ME de cada marca KPE en una misma temporada.',                       'legend', 'Partner Events',69),
  ('badge_diamond_invitational','Diamond Invitational','Participa en el torneo VIP Diamond Invitational.',                            'legend', 'Exclusivo',    70),
  ('badge_cgd_veteran',        'Cash Game Deal Veteran','Completa 10 Cash Game Deals en VPT.',                                        'legend', 'Cash Game Deal',71),
  ('badge_mvp_multi_champ',    'MVP Multi-Champion', 'Gana 2 o más premios MVP en una temporada.',                                   'legend', 'MVP',          72),
  ('badge_team_pro',           'VPT Team Pro',       'Consigue el Pack Team Pro en 2 temporadas consecutivas.',                       'legend', 'Torneos',      73),
  ('badge_triple_season',      'Triple Season',      'Completa 3 temporadas con al menos 3 festivales.',                              'legend', 'Torneos',      74),
  ('badge_world_tour',         'World Tour',         'Disputa torneos VPT en 7 países distintos.',                                    'legend', 'Flaghunter',   75),
  ('badge_50_cashes',          '50 Cashes',          'Acumula 50 ITMs en torneos VPT.',                                              'legend', 'ITM',          76),
  ('badge_trophy_collector',   'Trophy Collector',   'Gana 5 trofeos VPT a lo largo de tu carrera.',                                  'legend', 'Trofeos',      77),
  ('badge_gladiator_champ',    'Gladiator Champion', 'Gana un Main Event del Gladiator Poker Series.',                                'legend', 'Partner Events',78),
  ('badge_epm_champ',          'EPM Champion',       'Gana un Main Event del European Poker Masters.',                                'legend', 'Partner Events',79),
  ('badge_vpt_legend',         'VPT Legend',         'Completa 5 temporadas con al menos 3 festivales.',                              'legend', 'Torneos',      80),
  ('badge_hr_specialist',      'High Roller Specialist','ITM en HR en 3 festivales distintos en una temporada.',                       'legend', 'ITM',          81),
  ('badge_ft_x5',              'Final Table x5',     'Llega a 5 Mesas Finales en una misma temporada.',                              'legend', 'Mesa Final',   82),
  ('badge_vpt_triple_corona',  'VPT Triple Corona',  'ME Champion + HR Champion + MVP Champion en la misma temporada.',               'legend', 'Trofeos',      83),
  ('badge_cgd_superstar',      'Cash Game Deal SuperStar','Completa 25 Cash Game Deals en VPT.',                                       'legend', 'Cash Game Deal',84),
  ('badge_mvp_legend',         'MVP Legend',         'Acumula 10 premios MVP en paradas VPT.',                                       'legend', 'MVP',          85),
  ('badge_men_in_black',       'Men in Black',       'Alcanza Black en 2 temporadas consecutivas.',                                  'legend', 'Sistema VIP', 86),
  ('badge_flag_hunter_pro',    'Flag Hunter Pro',    'ITM en VPT en 5 países distintos en una temporada.',                            'legend', 'Flaghunter',   87),
  ('badge_kpe_triple_corona',  'KPE Triple Corona',  'Gana al menos 1 torneo de cada marca KPE: Vamos, Gladiator y EPM.',             'legend', 'Partner Events',88),
  ('badge_vpt_pro',            'VPT Pro',            'Pack Team Pro en 3 temporadas distintas.',                                     'legend', 'Torneos',      89),
  ('badge_10_seasons',         '10 Seasons',         'Completa 10 temporadas con al menos 3 festivales.',                            'legend', 'Torneos',      90),
  -- Boss Mode (10)
  ('badge_icon',               'Icon',               'Alcanza el nivel Icon — el más alto del circuito VPT.',                         'boss_mode', 'Sistema VIP',91),
  ('badge_100_cashes',         '100 Cashes',         'Acumula 100 ITMs en torneos VPT a lo largo de tu carrera.',                     'boss_mode', 'ITM',        92),
  ('badge_20_trofeos',         '20 Trofeos',         'Gana 20 trofeos VPT a lo largo de tu carrera.',                                 'boss_mode', 'Trofeos',    93),
  ('badge_ten_flags',          'Ten Flags',          'ITM en torneos VPT en 10 países distintos.',                                    'boss_mode', 'Flaghunter', 94),
  ('badge_100_ft',             '100 Final Tables',   'Llega a 100 Mesas Finales en torneos VPT.',                                    'boss_mode', 'Mesa Final', 95),
  ('badge_embajador',          'Embajador VPT',      'Reconocimiento oficial como figura del circuito VPT.',                         'boss_mode', 'Exclusivo',  96),
  ('badge_25_mvp',             '25 MVP',             'Acumula 25 premios MVP en paradas VPT.',                                       'boss_mode', 'MVP',        97),
  ('badge_50_trofeos',         '50 Trofeos',         'Gana 50 trofeos VPT a lo largo de tu carrera.',                                'boss_mode', 'Trofeos',    98),
  ('badge_vpt_alltime',        'VPT All-Time',       'Acumula la mayor cantidad de puntos históricos en el circuito.',               'boss_mode', 'Exclusivo',  99),
  ('badge_the_icon',           'The Icon',           'Mantén el nivel Icon durante 3 temporadas consecutivas.',                       'boss_mode', 'Exclusivo',  100)
on conflict (code) do update set
  display_name = excluded.display_name,
  description = excluded.description,
  tier = excluded.tier,
  category = excluded.category,
  sort_order = excluded.sort_order;
