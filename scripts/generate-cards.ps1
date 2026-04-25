# Genera el set completo de SVGs de cartas de poker en assets/cards/.
# Diseño "pill PokerNews": cápsula 60×40, rango+palo centrados.
# 13 rangos × 4 palos = 52 + 1 dorso = 53 archivos.
# Re-ejecutar tras cualquier cambio de plantilla.
#
# Uso (desde cualquier cwd):
#   pwsh -File scripts/generate-cards.ps1
#   o:  & .\scripts\generate-cards.ps1
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$out  = Join-Path $root 'assets\cards'
New-Item -ItemType Directory -Path $out -Force | Out-Null

# Palos como geometría SVG (no caracteres Unicode). Razón: en Android,
# flutter_svg renderiza los chars ♠♥♦♣ usando la fuente del sistema,
# que aplica presentación emoji color e ignora el `fill` del SVG —
# rompiendo nuestro 4-color deck. Con <path>/<circle> el fill se
# respeta siempre, independiente del runtime.
#
# Cada `shape` es un fragmento SVG centrado en (0,0) con bounding box
# ~14×14. NO lleva fill propio: el `<g>` contenedor inyecta el color
# del palo. Así reusamos un único string por palo, sin parametrizar.
$ranks = [ordered]@{
  '2' = '2';  '3' = '3';  '4' = '4';  '5' = '5';  '6' = '6'
  '7' = '7';  '8' = '8';  '9' = '9';  'T' = 'T'
  'J' = 'J';  'Q' = 'Q';  'K' = 'K';  'A' = 'A'
}
#
# Coordenadas pre-multiplicadas por 1.3 (bbox ~18×18 en lugar de
# ~14×14). El factor lo aplicamos en los números directamente porque
# flutter_svg ^2.x ignora `transform="scale(...)"` cuando se anida o
# combina con translate. Pre-baking en el path es 100% portable.
$suits = [ordered]@{
  's' = @{
    color = '#1a1a1a'  # picas: negro
    shape = '<path d="M0,-9.1 C-3.9,-2.6 -9.1,2.6 -9.1,5.2 C-9.1,7.8 -6.5,9.1 -3.9,6.5 L-5.2,9.1 L5.2,9.1 L3.9,6.5 C6.5,9.1 9.1,7.8 9.1,5.2 C9.1,2.6 3.9,-2.6 0,-9.1 Z"/>'
  }
  'h' = @{
    color = '#c93030'  # corazones: rojo
    shape = '<path d="M0,9.1 C-3.9,5.2 -9.1,1.3 -9.1,-3.9 C-9.1,-9.1 -3.9,-9.1 0,-3.9 C3.9,-9.1 9.1,-9.1 9.1,-3.9 C9.1,1.3 3.9,5.2 0,9.1 Z"/>'
  }
  'd' = @{
    color = '#2e6dd6'  # diamantes: azul
    shape = '<path d="M0,-9.1 L7.8,0 L0,9.1 L-7.8,0 Z"/>'
  }
  'c' = @{
    color = '#2da94f'  # tréboles: verde
    shape = '<circle cx="0" cy="-3.9" r="3.9"/><circle cx="-3.9" cy="2.6" r="3.9"/><circle cx="3.9" cy="2.6" r="3.9"/><path d="M-2.6,2.6 L-3.9,9.1 L3.9,9.1 L2.6,2.6 Z"/>'
  }
}

# UTF-8 sin BOM (Edge/Chrome no quieren BOM en SVGs)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$count = 0
foreach ($r in $ranks.Keys) {
  $label = $ranks[$r]
  foreach ($s in $suits.Keys) {
    $color = $suits[$s].color
    $shape = $suits[$s].shape
    # Composición invertida: pill rellena con el color del palo (sin
    # stroke), rango y palo en BLANCO encima. Mayor contraste visual
    # y reconocimiento del palo a primera vista por el color de fondo.
    # El palo (shape) usa fill="#ffffff" del <g>; las shapes ya vienen
    # pre-escaladas a bbox ~18×18 en sus coordenadas (ver $suits).
    $svg = @"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 60 40">
<rect x="1" y="1" width="58" height="38" rx="20" fill="$color"/>
<text x="20" y="28" font-family="Arial,sans-serif" font-size="22" font-weight="700" fill="#ffffff" text-anchor="middle">$label</text>
<g transform="translate(40,22)" fill="#ffffff">$shape</g>
</svg>
"@
    $path = Join-Path $out "card-$r$s.svg"
    [System.IO.File]::WriteAllText($path, $svg, $utf8NoBom)
    $count++
  }
}

# Vx: dorso VPT (carta boca abajo). Pill con borde dorado y "V"
# central. Fondo dorado muy claro (alpha 30/256 ≈ 12%) como
# diferenciador visual sutil.
$vback = @"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 60 40">
<rect x="1" y="1" width="58" height="38" rx="20" fill="#C9A84C"/>
<text x="30" y="28" font-family="Arial,sans-serif" font-size="22" font-weight="700" fill="#ffffff" text-anchor="middle">V</text>
</svg>
"@
[System.IO.File]::WriteAllText((Join-Path $out 'card-Vx.svg'), $vback, $utf8NoBom)
$count++

# Xx: carta desconocida / cualquier carta. Pill blanca como las
# cartas normales pero con X gris central — placeholder para
# rangos de mano, "alguna carta", flop sin revelar, etc.
$xunknown = @"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 60 40">
<rect x="1" y="1" width="58" height="38" rx="20" fill="#ffffff" stroke="#999" stroke-width="2"/>
<text x="30" y="28" font-family="Arial,sans-serif" font-size="22" font-weight="700" fill="#666" text-anchor="middle">X</text>
</svg>
"@
[System.IO.File]::WriteAllText((Join-Path $out 'card-Xx.svg'), $xunknown, $utf8NoBom)
$count++

Write-Output ("OK: {0} SVGs generados en {1}" -f $count, $out)
