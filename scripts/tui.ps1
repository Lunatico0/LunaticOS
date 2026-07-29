#requires -Version 5.1
<#
  tui.ps1 -- Interfaz de consola de LunaticOS. Sin dependencias externas.

  DECISIONES DE IMPLEMENTACION (por si te preguntas por que asi):

  1) ASCII puro para los marcos, NO box-drawing Unicode. PowerShell 5.1 sobre
     conhost.exe con codepage 850/437 dibuja basura con los caracteres de caja.
     Feo pero universal le gana a lindo pero roto en la mitad de las maquinas.

  2) Se redibuja el frame COMPLETO en un solo Write-Host por linea, posicionando
     el cursor en 0,0 en vez de Clear-Host. Clear-Host parpadea horrible en cada
     tecla; esto no.

  3) [Console]::ReadKey($true) en vez de Read-Host: necesitamos flechas y
     espacio, no una linea con Enter.
#>

$script:TuiWidth = 78

function Get-TuiKey {
  # $true = no ecoar la tecla en pantalla
  [Console]::ReadKey($true)
}

function Write-TuiLine([string]$text, [string]$color = 'Gray') {
  # Recorta a lo ancho y rellena con espacios: sin el padding quedan restos del
  # frame anterior cuando una linea nueva es mas corta que la que tapa.
  if ($text.Length -gt $script:TuiWidth) { $text = $text.Substring(0, $script:TuiWidth) }
  Write-Host ($text.PadRight($script:TuiWidth)) -ForegroundColor $color
}

function Reset-TuiCursor {
  try { [Console]::SetCursorPosition(0, 0) } catch { Clear-Host }
}

function Show-TuiHeader([string]$subtitle) {
  $bar = '=' * $script:TuiWidth
  Write-TuiLine $bar 'DarkCyan'
  Write-TuiLine '  LunaticOS  ~  constructor de ISO de Windows 11' 'Cyan'
  if ($subtitle) { Write-TuiLine "  $subtitle" 'DarkGray' }
  Write-TuiLine $bar 'DarkCyan'
}

function Show-TuiFooter([string[]]$hints) {
  Write-TuiLine ('-' * $script:TuiWidth) 'DarkGray'
  foreach ($h in $hints) { Write-TuiLine "  $h" 'DarkGray' }
}

function Wrap-TuiText([string]$text, [int]$width) {
  if (-not $text) { return @() }
  $out = @(); $line = ''
  foreach ($w in ($text -split '\s+')) {
    if (($line + ' ' + $w).Trim().Length -gt $width) { $out += $line.Trim(); $line = $w }
    else { $line = ($line + ' ' + $w) }
  }
  if ($line.Trim()) { $out += $line.Trim() }
  $out
}

<#
  Show-TuiChecklist -- lista navegable con marcas.

  $Items: array de hashtables con al menos Key / Name. Opcionales: Rec, Note, Cat.
  $Selected: hashtable Key -> $true/$false (SE MODIFICA en el lugar, es la salida).
  $Exclusive: array de arrays de Keys mutuamente excluyentes.

  Devuelve $true si el usuario confirmo, $false si cancelo con Esc.
#>
function Show-TuiChecklist {
  param(
    [Parameter(Mandatory)][string]$Title,
    [Parameter(Mandatory)][array]$Items,
    # ==========================================================================
    #  $Selected NO LLEVA TIPO. NO LE PONGAS [hashtable]. NUNCA.
    #
    #  El perfil usa [ordered]@{} (OrderedDictionary) para conservar el orden de
    #  las claves en el JSON. Si este parametro se declara [hashtable], PowerShell
    #  CONVIERTE el OrderedDictionary a Hashtable, y al convertir CREA UNA COPIA:
    #  esta funcion modifica la copia, el original queda intacto y TODO lo que el
    #  usuario marco se pierde al volver al menu. El perfil se guarda con los
    #  valores de fabrica y nadie entiende por que.
    #
    #  Medido:
    #     [ordered] -> parametro [hashtable]  = POR COPIA   (cambios perdidos)
    #     [ordered] -> parametro sin tipo     = POR REFERENCIA (correcto)
    #  Y de paso la conversion tambien PIERDE EL ORDEN de las claves.
    #
    #  Sin anotacion de tipo, el objeto pasa por referencia y funciona.
    #  El self-test de LunaticOS.ps1 verifica esto: si alguien vuelve a tipar el
    #  parametro, falla ahi antes de llegar al usuario.
    # ==========================================================================
    [Parameter(Mandatory)]$Selected,
    [array]$Exclusive = @(),
    [string]$Legend = 'marcado = se aplica'
  )

  $idx = 0
  $top = 0
  $rows = 14   # filas de lista visibles a la vez

  while ($true) {
    Reset-TuiCursor
    Show-TuiHeader $Title

    $count = @($Items | Where-Object { $Selected[$_.Key] }).Count
    Write-TuiLine ("  {0} de {1} seleccionados   ({2})" -f $count, $Items.Count, $Legend) 'White'
    Write-TuiLine ('-' * $script:TuiWidth) 'DarkGray'

    # Ventana de scroll
    if ($idx -lt $top)            { $top = $idx }
    if ($idx -ge ($top + $rows))  { $top = $idx - $rows + 1 }
    $end = [Math]::Min($top + $rows, $Items.Count)

    for ($i = $top; $i -lt $end; $i++) {
      $it   = $Items[$i]
      $mark = if ($Selected[$it.Key]) { 'x' } else { ' ' }
      $rec  = if ($it.Rec) { ' *' } else { '  ' }
      $cur  = if ($i -eq $idx) { '>' } else { ' ' }
      $cat  = if ($it.Cat) { "  [$($it.Cat)]" } else { '' }
      $line = "{0} [{1}]{2} {3}{4}" -f $cur, $mark, $rec, $it.Name, $cat
      $col  = if ($i -eq $idx) { 'Yellow' } elseif ($Selected[$it.Key]) { 'Green' } else { 'Gray' }
      Write-TuiLine $line $col
    }
    # Rellenar el resto para tapar el frame anterior
    for ($i = $end; $i -lt ($top + $rows); $i++) { Write-TuiLine '' }

    Write-TuiLine ('-' * $script:TuiWidth) 'DarkGray'
    # Nota del item actual: esto es el corazon del proyecto. Nadie deberia marcar
    # algo sin leer que hace. Por eso la nota va SIEMPRE visible, no en un F1.
    $note = $Items[$idx].Note
    if (-not $note) { $note = '(sin nota)' }
    $wrapped = @(Wrap-TuiText $note ($script:TuiWidth - 4))
    for ($i = 0; $i -lt 3; $i++) {
      if ($i -lt $wrapped.Count) { Write-TuiLine ("  " + $wrapped[$i]) 'Cyan' } else { Write-TuiLine '' }
    }
    if ($Items[$idx].Url) { Write-TuiLine ("  descarga: " + $Items[$idx].Url) 'DarkYellow' }
    else                  { Write-TuiLine '' }

    Show-TuiFooter @(
      'flechas mover  ESPACIO marcar  A todos  N ninguno  R solo recomendados (*)'
      'ENTER confirmar         ESC volver sin guardar'
    )

    $k = Get-TuiKey
    switch ($k.Key) {
      'UpArrow'    { if ($idx -gt 0) { $idx-- } }
      'DownArrow'  { if ($idx -lt ($Items.Count - 1)) { $idx++ } }
      'PageUp'     { $idx = [Math]::Max(0, $idx - $rows) }
      'PageDown'   { $idx = [Math]::Min($Items.Count - 1, $idx + $rows) }
      'Home'       { $idx = 0 }
      'End'        { $idx = $Items.Count - 1 }
      'Spacebar'   {
        $key = $Items[$idx].Key
        $new = -not $Selected[$key]
        $Selected[$key] = $new
        # Grupos excluyentes: al marcar uno, desmarcar los hermanos.
        if ($new) {
          foreach ($grp in $Exclusive) {
            if ($grp -contains $key) {
              foreach ($other in $grp) { if ($other -ne $key) { $Selected[$other] = $false } }
            }
          }
        }
      }
      'Enter'      { return $true }
      'Escape'     { return $false }
      default {
        switch ("$($k.KeyChar)".ToUpper()) {
          'A' { foreach ($it in $Items) { $Selected[$it.Key] = $true }
                # Con "todos" los excluyentes quedarian todos en $true: dejar solo el primero.
                foreach ($grp in $Exclusive) {
                  $first = $true
                  foreach ($g in $grp) { $Selected[$g] = $first; $first = $false }
                } }
          'N' { foreach ($it in $Items) { $Selected[$it.Key] = $false } }
          'R' { foreach ($it in $Items) { $Selected[$it.Key] = [bool]$it.Rec } }
        }
      }
    }
  }
}

<#
  Show-TuiMenu -- menu principal. $Entries: array de @{ Key; Label; Info }.
  Devuelve la Key elegida, o $null si el usuario salio con Esc/Q.
#>
function Show-TuiMenu {
  param(
    [Parameter(Mandatory)][array]$Entries,
    [string]$Subtitle = ''
  )
  $idx = 0
  while ($true) {
    Reset-TuiCursor
    Show-TuiHeader $Subtitle
    Write-TuiLine ''
    for ($i = 0; $i -lt $Entries.Count; $i++) {
      $e = $Entries[$i]
      if ($e.Key -eq '-') { Write-TuiLine ('  ' + ('-' * ($script:TuiWidth - 4))) 'DarkGray'; continue }
      $cur = if ($i -eq $idx) { '>' } else { ' ' }
      $col = if ($i -eq $idx) { 'Yellow' } elseif ($e.Accent) { 'Green' } else { 'Gray' }
      Write-TuiLine ("{0}  {1,-42} {2}" -f $cur, $e.Label, $e.Info) $col
    }
    Write-TuiLine ''
    # Nota del item seleccionado. Igual que en las checklists: si la UI no dice lo que
    # va a pasar, el usuario tiene que adivinarlo. "Generar" guardaba el perfil sin
    # avisar y nadie podia saberlo sin leer el codigo.
    Write-TuiLine ('-' * $script:TuiWidth) 'DarkGray'
    $note = $Entries[$idx].Note
    if (-not $note) { $note = '' }
    $wrapped = @(Wrap-TuiText $note ($script:TuiWidth - 4))
    for ($i = 0; $i -lt 2; $i++) {
      if ($i -lt $wrapped.Count) { Write-TuiLine ("  " + $wrapped[$i]) 'Cyan' } else { Write-TuiLine '' }
    }
    Show-TuiFooter @('flechas mover   ENTER elegir   Q salir')

    $k = Get-TuiKey
    switch ($k.Key) {
      'UpArrow'   { do { $idx = if ($idx -gt 0) { $idx - 1 } else { $Entries.Count - 1 } } while ($Entries[$idx].Key -eq '-') }
      'DownArrow' { do { $idx = if ($idx -lt ($Entries.Count - 1)) { $idx + 1 } else { 0 } } while ($Entries[$idx].Key -eq '-') }
      'Enter'     { return $Entries[$idx].Key }
      'Escape'    { return $null }
      default     { if ("$($k.KeyChar)".ToUpper() -eq 'Q') { return $null } }
    }
  }
}

function Show-TuiConfirm([string]$Question, [string[]]$Lines = @()) {
  Reset-TuiCursor
  Show-TuiHeader 'Confirmacion'
  Write-TuiLine ''
  foreach ($l in $Lines) { Write-TuiLine "  $l" 'White' }
  Write-TuiLine ''
  Write-TuiLine "  $Question" 'Yellow'
  Write-TuiLine ''
  Show-TuiFooter @('S = si    N = no')
  while ($true) {
    $c = "$((Get-TuiKey).KeyChar)".ToUpper()
    if ($c -eq 'S') { return $true }
    if ($c -eq 'N') { return $false }
  }
}

function Show-TuiPause([string]$Message = 'Enter para continuar...') {
  Write-Host ''
  Write-Host "  $Message" -ForegroundColor DarkGray
  do { $k = Get-TuiKey } while ($k.Key -ne 'Enter')
}
