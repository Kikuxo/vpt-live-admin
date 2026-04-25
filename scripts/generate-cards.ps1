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

# Variation Selector-15 (U+FE0E): fuerza presentación text (no emoji
# a color) en los símbolos de palo. Combinado con `font-variant-emoji`
# del style cubre Android/iOS antiguos y modernos.
$VS15 = [char]0xFE0E

$ranks = [ordered]@{
  '2' = '2';  '3' = '3';  '4' = '4';  '5' = '5';  '6' = '6'
  '7' = '7';  '8' = '8';  '9' = '9';  'T' = '10'
  'J' = 'J';  'Q' = 'Q';  'K' = 'K';  'A' = 'A'
}
$suits = [ordered]@{
  's' = @{ char = ([char]0x2660) + $VS15; color = '#1a1a1a' }  # picas:    negro
  'h' = @{ char = ([char]0x2665) + $VS15; color = '#c93030' }  # corazones: rojo
  'd' = @{ char = ([char]0x2666) + $VS15; color = '#2e6dd6' }  # diamantes: azul
  'c' = @{ char = ([char]0x2663) + $VS15; color = '#2da94f' }  # tréboles:  verde
}

# UTF-8 sin BOM (Edge/Chrome no quieren BOM en SVGs)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$count = 0
foreach ($r in $ranks.Keys) {
  $label = $ranks[$r]
  foreach ($s in $suits.Keys) {
    $color = $suits[$s].color
    $sym   = $suits[$s].char
    # text-anchor="middle" centra el conjunto rango+palo en x=30 sin
    # cálculos por longitud (1 char vs "10" se autocentra). dx=3 deja
    # espacio cómodo entre rango y palo. El palo a font-size 28
    # compensa el bounding box más estrecho de los símbolos ♠♥♦♣
    # (renderizan visualmente ~30% menores que las letras a igual size).
    $svg = @"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 60 40">
<style>text { font-variant-emoji: text; }</style>
<rect x="1" y="1" width="58" height="38" rx="20" fill="#ffffff" stroke="#999" stroke-width="2"/>
<text x="30" y="28" font-family="Arial,sans-serif" font-size="22" fill="$color" text-anchor="middle"><tspan font-weight="700">$label</tspan><tspan dx="3" font-size="28">$sym</tspan></text>
</svg>
"@
    $path = Join-Path $out "card-$r$s.svg"
    [System.IO.File]::WriteAllText($path, $svg, $utf8NoBom)
    $count++
  }
}

# Dorso: pill con borde dorado VPT y "V" central. Fondo dorado muy
# claro (alpha 30/256 ≈ 12%) como diferenciador visual sutil.
$back = @"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 60 40">
<rect x="1" y="1" width="58" height="38" rx="20" fill="#C9A84C30" stroke="#C9A84C" stroke-width="2"/>
<text x="30" y="28" font-family="Arial,sans-serif" font-size="22" font-weight="700" fill="#C9A84C" text-anchor="middle">V</text>
</svg>
"@
[System.IO.File]::WriteAllText((Join-Path $out 'card-Xx.svg'), $back, $utf8NoBom)
$count++

Write-Output ("OK: {0} SVGs generados en {1}" -f $count, $out)
