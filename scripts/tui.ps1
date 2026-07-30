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

  4) TODO el input entra por Get-TuiKey, y Get-TuiKey se puede desviar a un
     scriptblock ($Global:TuiKeyProvider). Es lo que hace testeable la TUI sin
     humano ni pantalla (docs\testing-e2e.md, seccion 2). En produccion el
     provider es $null y el camino es exactamente el de siempre.

  5) El ancho del frame NO es una constante: se recalcula contra el tamano real
     de la consola en cada redibujo. Con 78 columnas fijas, una ventana mas
     angosta hace wrap en cada linea y el frame se desarma; y con menos filas que
     el frame, el buffer scrollea y el SetCursorPosition(0,0) dibuja encima de si
     mismo. Ver Resolve-TuiLayout.
#>

# Ancho del frame. Es el techo historico (78) y tambien el fallback cuando no se
# puede leer el tamano de la consola. Update-TuiLayout lo reescribe por frame.
$script:TuiWidth = 78

# ===========================================================================
#  INPUT -- el UNICO lugar donde la TUI lee el teclado
# ===========================================================================
<#
  $Global:TuiKeyProvider = scriptblock -> Get-TuiKey lo invoca en vez de leer el
  teclado. Es el punto de corte del E2E: la TUI es el primer contacto del usuario
  y no se podia probar NADA de ella (docs\testing-e2e.md 0 y 2).

  En produccion vale $null y Get-TuiKey hace lo mismo que hacia antes: una sola
  comparacion de tipo y despues [Console]::ReadKey($true). El costo es una
  comparacion por TECLA HUMANA, o sea nada, y no hay ninguna otra rama nueva en
  el camino de produccion.

  Se declara aca, y no en el script de tests, porque el runner del E2E
  (scripts\test-e2e.ps1) tambien lo consume: es contrato publico del modulo.
#>
$Global:TuiKeyProvider = $null

function Get-TuiKey {
  if ($Global:TuiKeyProvider -is [scriptblock]) { return (& $Global:TuiKeyProvider) }
  # $true = no ecoar la tecla en pantalla
  [Console]::ReadKey($true)
}

<#
  ConvertTo-TuiKeyInfo -- fabrica la tecla que el codigo de la TUI espera.

  Devuelve un [ConsoleKeyInfo] DE VERDAD, no un PSCustomObject con dos
  propiedades. Motivo: los switch de la TUI comparan $k.Key (un [ConsoleKey])
  contra strings y leen $k.KeyChar; con el struct real el test recorre EL MISMO
  codigo que recorre una tecla humana, incluida la conversion enum<->string que
  hace el switch. Un objeto falso es un segundo contrato que puede estar bien
  cuando el real esta roto.

  Detalle que importa: las flechas, Home/End/PageUp/PageDown y las F devuelven
  KeyChar = NUL en la consola real. Se replica, porque el `default` de los switch
  mira el KeyChar: si aca se inventara un caracter, el test entraria por una rama
  que el usuario no pisa nunca.
#>
function ConvertTo-TuiKeyInfo([string]$Name) {
  if (-not $Name) { throw 'Send-TuiKeys: nombre de tecla vacio.' }
  $names = [enum]::GetNames([ConsoleKey])
  # [ConsoleKey]0 TIRA en PowerShell 5.1 ("enumeration values that are not
  # valid"): el 0 no es un miembro declarado del enum. [Enum]::ToObject no
  # valida, y 0 es exactamente lo que trae un ConsoleKeyInfo de una tecla sin
  # mapeo -- es el valor fiel, no un atajo.
  $key   = [Enum]::ToObject([ConsoleKey], 0)
  $char  = [char]0

  if ($Name.Length -eq 1) {
    # Caracter suelto ('A', 'N', 'R', 'S', '3'): el KeyChar es el caracter tal
    # cual -- con su mayuscula/minuscula, como lo entrega la consola.
    $char = $Name[0]
    $up   = $Name.ToUpperInvariant()
    if     ($names -contains $up)  { $key = [ConsoleKey]$up }
    elseif ($up -match '^[0-9]$')  { $key = [ConsoleKey]("D" + $up) }
  }
  elseif ($names -contains $Name) {
    $key = [ConsoleKey]$Name
    switch ("$key") {
      'Enter'     { $char = [char]13 }
      'Escape'    { $char = [char]27 }
      'Spacebar'  { $char = ' ' }
      'Tab'       { $char = [char]9 }
      'Backspace' { $char = [char]8 }
      default {
        $n = "$key"
        if     ($n.Length -eq 1)   { $char = [char]$n }      # A..Z
        elseif ($n -match '^D\d$') { $char = [char]$n[1] }   # D0..D9 -> '0'..'9'
      }
    }
  }
  else {
    throw ("Send-TuiKeys: '$Name' no es una tecla. Se espera un nombre de " +
           '[ConsoleKey] (DownArrow, Spacebar, Enter, Escape, PageDown...) o UN ' +
           'caracter suelto (A, N, R, S). Un nombre mal escrito que se ignorara ' +
           'en silencio convierte al test en un adorno.')
  }
  New-Object System.ConsoleKeyInfo $char, $key, $false, $false, $false
}

<#
  Send-TuiKeys -- carga la cola de teclas que va a consumir Get-TuiKey.
      Send-TuiKeys 'DownArrow','DownArrow','Spacebar','Enter'
#>
function Send-TuiKeys([string[]]$Keys) {
  $q = New-Object System.Collections.Queue
  # La conversion se hace ACA, no al despachar: un nombre invalido tiene que
  # explotar cuando el test lo escribe, no tres teclas mas tarde.
  foreach ($n in $Keys) { $q.Enqueue((ConvertTo-TuiKeyInfo $n)) }
  $Global:TuiKeyQueue = $q
  $Global:TuiKeysSent = @($Keys)
  $Global:TuiKeyProvider = {
    if ($Global:TuiKeyQueue.Count -eq 0) {
      # TIRA. No devuelve $null y no espera.
      #   - esperar el teclado = un test colgado, y a un test colgado no lo vuelve
      #     a correr nadie;
      #   - devolver $null = el switch cae en `default`, el bucle gira de nuevo y
      #     pide otra tecla: el mismo cuelgue, disfrazado de bucle infinito.
      throw ('Get-TuiKey: se vacio la cola de teclas de prueba y la TUI pidio otra. ' +
             'Teclas enviadas: ' + (@($Global:TuiKeysSent) -join ' ') +
             '. Falta un Enter/Escape al final, o la TUI no consumio las teclas que el test creia.')
    }
    $Global:TuiKeyQueue.Dequeue()
  }
}

# ===========================================================================
#  LAYOUT -- el frame se adapta a la consola que hay, no a la que quisieramos
# ===========================================================================
<#
  $Global:TuiSizeProvider = scriptblock -> devuelve @{ Width; Height } en vez de
  preguntarle a la consola. Existe por el mismo motivo que TuiKeyProvider: sin
  esto, "el frame no se desarma con la consola chica" solo se puede probar
  cambiandole el tamano a la ventana del que corre el test -- o sea que el
  resultado depende de la terminal y el test miente en cualquier otra maquina.
  En produccion es $null.
#>
$Global:TuiSizeProvider = $null

function Get-TuiConsoleSize {
  if ($Global:TuiSizeProvider -is [scriptblock]) { return (& $Global:TuiSizeProvider) }
  # MEDIDO: [Console]::WindowWidth TIRA IOException cuando la salida esta
  # redirigida (un `powershell -File ... > log.txt`, o el runner del E2E leyendo
  # por pipe). Sin el try/catch, adaptarse a la consola le habria AGREGADO un
  # crash a la herramienta en el unico caso donde nadie mira la pantalla.
  try { return @{ Width = [Console]::WindowWidth; Height = [Console]::WindowHeight } } catch { }
  # $Host.UI.RawUI si funciona con la salida redirigida (medido: 120x30).
  try {
    $s = $Host.UI.RawUI.WindowSize
    if ($s -and $s.Width -gt 0) { return @{ Width = $s.Width; Height = $s.Height } }
  } catch { }
  # Ultimo recurso: el tamano que asumia el codigo original (78 + 1 columna).
  @{ Width = 79; Height = 30 }
}

<#
  Resolve-TuiLayout -- funcion PURA: (columnas, filas de la consola) -> layout.
  Separada de la lectura de la consola justamente para poder testearla con
  numeros, sin ventana.

  Ancho:
    - techo 78: es el diseno original y no gana nada estirandose mas;
    - -1 columna: escribir EN la ultima columna mueve el cursor a la linea
      siguiente, o sea que cada linea del frame contaria doble y el frame se
      desarma solo. Por eso 78 columnas necesitan una consola de 79;
    - piso 40: mas angosto que eso el frame es ilegible igual, y las cuentas
      internas (Wrap-TuiText con Width-4) dejan de tener sentido. Con menos de 41
      columnas va a haber wrap: es un frame feo, NO un crash.
  Filas de lista:
    - el frame tiene 14 lineas fijas (4 header + contador + separador +
      separador + 3 de nota + 1 de URL + 3 de footer), asi que la lista puede
      usar Height - 15 y queda una linea libre: sin esa linea, el ultimo
      Write-Host scrollea el buffer y Reset-TuiCursor pasa a dibujar corrido;
    - techo 14 (lo de siempre) y piso 3, porque una checklist con cero filas
      visibles no sirve para nada. Con una consola de menos de 18 filas el frame
      no entra ni con el piso: se prioriza que se pueda usar.
#>
function Resolve-TuiLayout([int]$Width, [int]$Height) {
  $w = [Math]::Min(78, $Width - 1)
  if ($w -lt 40) { $w = 40 }
  $r = $Height - 15
  if ($r -gt 14) { $r = 14 }
  if ($r -lt 3)  { $r = 3 }
  @{ Width = $w; Rows = $r }
}

# Lee la consola, fija el ancho y devuelve el layout. Las funciones de dibujo la
# llaman UNA vez por frame: asi un resize a mitad de camino se acomoda solo.
function Update-TuiLayout {
  $s = Get-TuiConsoleSize
  $l = Resolve-TuiLayout ([int]$s.Width) ([int]$s.Height)
  $script:TuiWidth = $l.Width
  $l
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
  Resolve-TuiExclusive -- normaliza $Exclusive a una lista de GRUPOS.

  ESTO ARREGLA UN BUG VIVO, y el culpable es una regla de PowerShell: un literal
  @( ... ) APLANA el array anidado cuando es el UNICO elemento.

      MEDIDO en PS 5.1:
          @( @(1,2,3) ).Count        = 3   <-- el grupo se deshizo en 3 strings
          @( @(1,2), @(3,4) ).Count  = 2   <-- con DOS grupos NO se aplana
          @( ,@(1,2,3) ).Count       = 1   <-- la coma lo salva

  config\personalizacion.ps1 declara UN grupo (los tres acentos) con la primera
  forma, asi que $Exclusive llegaba aca como TRES STRINGS SUELTOS. Medido sobre el
  catalogo real, con la logica de abajo tal cual estaba:
      marcar el acento teal  -> violeta quedaba marcado TAMBIEN
      la tecla A             -> los TRES acentos marcados a la vez
  Porque `'acento-teal' -contains 'acento-teal'` es $true (con un escalar a la
  izquierda, -contains es una igualdad) y despues `foreach ($other in $grp)`
  recorre UN string: el mismo key. No habia hermano a quien desmarcar.
  O sea: los grupos excluyentes NO EXCLUIAN NADA, y en silencio -- el mismo bug
  que docs\testing-e2e.md 2.2 marca como "este ya fue un bug", de vuelta.
  El self-test de LunaticOS.ps1 no lo ve porque solo verifica que las claves
  existan en el catalogo, y `foreach ($k in 'un-string')` itera una vez con el
  string entero: da verde con el grupo destruido.

  Un grupo de UN elemento no puede excluir a nadie, asi que un string suelto no
  puede ser un grupo: solo puede ser el resto de un grupo aplanado. Se juntan
  todos en uno. Normalizar ACA -- y no solo en el catalogo -- hace inmune a la
  TUI: el que escriba el proximo grupo no tiene que conocer esta regla del
  lenguaje para que su grupo funcione.
#>
function Resolve-TuiExclusive($Exclusive) {
  $grupos  = @()
  $sueltos = @()
  foreach ($g in @($Exclusive)) {
    if ($g -is [string])       { $sueltos += $g }
    elseif (@($g).Count -gt 0) { $grupos  += ,@($g) }
  }
  if ($sueltos.Count -gt 0) { $grupos += ,@($sueltos) }
  # La coma de la salida es la misma historia: sin ella, devolver UN grupo lo
  # aplanaria de vuelta y el arreglo no serviria justo en el caso que lo motivo.
  ,$grupos
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
    # [AllowEmptyCollection()] NO es decorativo: Mandatory RECHAZA @() en el
    # binding ("Cannot bind argument to parameter 'Items' because it is an empty
    # collection"), asi que una lista vacia -- un catalogo que quedo sin items
    # despues de filtrar los blindados, por ejemplo -- reventaba ANTES de entrar
    # a la funcion, con un error de PowerShell que al usuario no le dice nada.
    [Parameter(Mandatory)][AllowEmptyCollection()][array]$Items,
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
  # Una sola fuente para la cantidad: con la lista vacia hay CUATRO lugares que
  # calculan indices y todos tienen que mirar el mismo numero.
  $cnt = @($Items).Count
  # $Exclusive puede llegar APLANADO por el literal del catalogo: ver
  # Resolve-TuiExclusive. Se normaliza UNA vez, afuera del bucle de teclas.
  $grupos = Resolve-TuiExclusive $Exclusive

  while ($true) {
    # El layout ANTES de dibujar: si la ventana cambio de tamano, este redibujo ya
    # sale con la medida nueva. $rows deja de ser una constante (era 14 fijas).
    $lay  = Update-TuiLayout
    $rows = $lay.Rows

    Reset-TuiCursor
    Show-TuiHeader $Title

    # Clamp del cursor. Con la lista vacia queda en 0 y NADIE lo usa de indice
    # (ver los guardas de abajo): $Items[0] sobre @() devuelve $null sin error,
    # pero $Selected[$null] TIRA -- ahi estaba el crash de la lista vacia.
    if ($idx -gt ($cnt - 1)) { $idx = $cnt - 1 }
    if ($idx -lt 0)          { $idx = 0 }

    $count = @($Items | Where-Object { $Selected[$_.Key] }).Count
    Write-TuiLine ("  {0} de {1} seleccionados   ({2})" -f $count, $cnt, $Legend) 'White'
    Write-TuiLine ('-' * $script:TuiWidth) 'DarkGray'

    # Ventana de scroll. Los dos clamps de $top no son redundantes: si la consola
    # se hace mas alta (o mas baja) a mitad de camino, $rows cambia y la ventana
    # que quedo del frame anterior puede caer fuera de la lista.
    if ($idx -lt $top)            { $top = $idx }
    if ($idx -ge ($top + $rows))  { $top = $idx - $rows + 1 }
    if ($top -gt ($cnt - $rows))  { $top = $cnt - $rows }
    if ($top -lt 0)               { $top = 0 }
    $end = [Math]::Min($top + $rows, $cnt)

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
    # Con la lista vacia se dice que esta vacia: un frame en blanco parece un bug.
    $curItem = if ($cnt -gt 0) { $Items[$idx] } else { $null }
    $note = if ($cnt -eq 0) { '(esta lista no tiene items)' } else { $curItem.Note }
    if (-not $note) { $note = '(sin nota)' }
    $wrapped = @(Wrap-TuiText $note ($script:TuiWidth - 4))
    for ($i = 0; $i -lt 3; $i++) {
      if ($i -lt $wrapped.Count) { Write-TuiLine ("  " + $wrapped[$i]) 'Cyan' } else { Write-TuiLine '' }
    }
    if ($curItem -and $curItem.Url) { Write-TuiLine ("  descarga: " + $curItem.Url) 'DarkYellow' }
    else                            { Write-TuiLine '' }

    Show-TuiFooter @(
      'flechas mover  ESPACIO marcar  A todos  N ninguno  R solo recomendados (*)'
      'ENTER confirmar         ESC volver sin guardar'
    )

    $k = Get-TuiKey
    switch ($k.Key) {
      'UpArrow'    { if ($idx -gt 0) { $idx-- } }
      'DownArrow'  { if ($idx -lt ($cnt - 1)) { $idx++ } }
      'PageUp'     { $idx = [Math]::Max(0, $idx - $rows) }
      'PageDown'   { $idx = [Math]::Min([Math]::Max(0, $cnt - 1), $idx + $rows) }
      'Home'       { $idx = 0 }
      # End con la lista vacia daba $idx = -1: $Items[-1] es "el ultimo" y con 0
      # items eso es $null, asi que el Spacebar siguiente hacia $Selected[$null].
      'End'        { $idx = [Math]::Max(0, $cnt - 1) }
      'Spacebar'   {
        # El guarda es por la lista vacia: $Selected[$null] TIRA (medido).
        if ($cnt -gt 0) {
          $key = $Items[$idx].Key
          $new = -not $Selected[$key]
          $Selected[$key] = $new
          # Grupos excluyentes: al marcar uno, desmarcar los hermanos.
          if ($new) {
            foreach ($grp in $grupos) {
              if ($grp -contains $key) {
                foreach ($other in $grp) { if ($other -ne $key) { $Selected[$other] = $false } }
              }
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
                foreach ($grp in $grupos) {
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
    # `$null =` NO es cosmetico: cualquier cosa que quede en el pipeline dentro de
    # esta funcion se SUMA al valor de retorno, y el retorno de aca es la Key que
    # el menu principal usa para decidir que hacer. Ese bug ya paso en el repo con
    # el exit code del self-test.
    $null = Update-TuiLayout
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
  $null = Update-TuiLayout
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
