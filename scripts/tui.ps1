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
      # Un Locked se dibuja con '-' y no con ' ': un checkbox vacio se lee como
      # "todavia no lo marque", y el usuario prueba. Con el guion se ve que no es
      # marcable ANTES de apretar la tecla, que es cuando sirve saberlo.
      $mark = if ($it.Locked) { '-' } elseif ($Selected[$it.Key]) { 'x' } else { ' ' }
      $rec  = if ($it.Rec) { ' *' } else { '  ' }
      $cur  = if ($i -eq $idx) { '>' } else { ' ' }
      $cat  = if ($it.Cat) { "  [$($it.Cat)]" } else { '' }
      $line = "{0} [{1}]{2} {3}{4}" -f $cur, $mark, $rec, $it.Name, $cat
      # DarkGray para los Locked: el gris apagado es la senal visual de "esto no se
      # toca". El cursor (Yellow) sigue ganando, asi que se ve donde estas parado.
      $col  = if ($i -eq $idx) { 'Yellow' }
              elseif ($it.Locked) { 'DarkGray' }
              elseif ($Selected[$it.Key]) { 'Green' } else { 'Gray' }
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
        # Y el de Locked es la GUARDA REAL de los [BLINDADO]. Antes del 2026-08-08
        # no existia: la checklist los marcaba igual, el usuario veia [x], el
        # contador subia, y al volver al menu Show-MainMenu los borraba del perfil
        # en silencio. La nota del menu PROMETIA "no se pueden marcar" y el
        # comentario del codigo decia "no entran a la lista editable" -- pero el
        # menu los pasaba igual en ($editables + $locked). La intencion estaba
        # escrita en dos lugares y no implementada en ninguno.
        if ($cnt -gt 0 -and -not $Items[$idx].Locked) {
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
          # Los tres atajos SALTEAN los Locked por el mismo motivo que Spacebar: una
          # guarda que "A todos" puede pasar por arriba no es una guarda.
          'A' { foreach ($it in $Items) { if (-not $it.Locked) { $Selected[$it.Key] = $true } }
                # Con "todos" los excluyentes quedarian todos en $true: dejar solo el primero.
                foreach ($grp in $grupos) {
                  $first = $true
                  foreach ($g in $grp) { $Selected[$g] = $first; $first = $false }
                } }
          'N' { foreach ($it in $Items) { if (-not $it.Locked) { $Selected[$it.Key] = $false } } }
          'R' { foreach ($it in $Items) { if (-not $it.Locked) { $Selected[$it.Key] = [bool]$it.Rec } } }
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
    [string]$Subtitle = '',
    # Lineas fijas arriba de las opciones. Existe para lo que el menu NO decia:
    # que la seleccion YA viene cargada con el perfil recomendado. Sin eso, el que
    # abre la TUI por primera vez no sabe que puede apretar G y terminar ahi, y se
    # pone a marcar 200 cosas creyendo que arranca de cero.
    [string[]]$Banner = @()
  )
  $idx = 0
  while ($true) {
    # La asignacion NO es cosmetica: cualquier cosa que quede en el pipeline dentro
    # de esta funcion se SUMA al valor de retorno, y el retorno de aca es la Key que
    # el menu principal usa para decidir que hacer. Ese bug ya paso en el repo con
    # el exit code del self-test. Se guarda en $l (antes era `$null =`) porque el
    # banner necesita saber el alto disponible; capturar en una variable saca la
    # salida del pipeline igual que $null.
    $l = Update-TuiLayout
    Reset-TuiCursor
    Show-TuiHeader $Subtitle
    # El banner se omite en consolas bajas, y NO es un detalle cosmetico: este menu
    # dibuja TODAS sus entradas (no pagina como las checklists), asi que ya usaba el
    # presupuesto completo de Resolve-TuiLayout -- 15 lineas de chrome + 14 de
    # contenido = 29. Cualquier linea extra empuja el footer fuera de pantalla, y el
    # footer es donde dice como salir. Rows>=12 equivale a Height>=27, que es lo que
    # necesita el menu con este banner de 3 lineas.
    if ($Banner.Count -and $l.Rows -ge 12) {
      Write-TuiLine ''
      foreach ($b in $Banner) { Write-TuiLine ("  " + $b) 'Green' }
    }
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
      default     {
        $c = "$($k.KeyChar)".ToUpper()
        if ($c -eq 'Q') { return $null }
        # ATAJOS POR LA LETRA DEL LABEL. Agregado el 2026-08-08, y es un bug que
        # este menu tuvo siempre: los labels dicen "1.", "2.", "G. GENERAR",
        # "S. Guardar" -- o sea que PROMETEN un atajo -- y solo Q funcionaba. El
        # resto eran decorativos: habia que navegar con flechas y apretar Enter.
        # Se descubrio manejando la TUI con teclas inyectadas: se mando 'S' para
        # guardar, el menu la ignoro y la cola de teclas se vacio.
        #
        # Se matchea "<letra>." al principio del Label, que es el formato que ya
        # usaban todas las entradas. Nada de mapear teclas a mano: si alguien
        # agrega "8. Otra cosa", el atajo 8 le funciona sin tocar esta funcion.
        if ($c -match '^[0-9A-Z]$') {
          foreach ($e in $Entries) {
            if ($e.Key -eq '-') { continue }
            if ("$($e.Label)" -match "^$([regex]::Escape($c))\.") { return $e.Key }
          }
        }
      }
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

# ===========================================================================
#  INPUT DE TEXTO -- lo unico que el usuario ESCRIBE en toda la herramienta
# ===========================================================================
<#
  Show-TuiInput -- campo de texto de una linea, dentro del frame de la TUI.

  Devuelve el string, o $null si el usuario cancelo con Esc.

      $n = Show-TuiInput -Title 'Cuenta de usuario' -Prompt 'nombre' -Default 'pato' `
                         -MaxLen 20 `
                         -Validate { param($s) Test-WindowsUserName $s } `
                         -Advise   { param($s) Test-WindowsUserName $s -Advisory }

  POR QUE NO Read-Host -- dos razones y las dos importan:
    1) Read-Host escribe SU prompt y SU eco donde esta el cursor. El frame de esta
       TUI se redibuja posicionando el cursor en 0,0 (decision 2 del header), asi
       que el eco de Read-Host queda pisado o pisa, y el frame siguiente sale
       corrido;
    2) Read-Host NO pasa por $Global:TuiKeyProvider. Este campo es el unico lugar
       donde el usuario escribe algo que termina DENTRO del autounattend, y seria
       justo el unico pedazo de la TUI que no se puede probar sin un humano
       tipeando. Un nombre invalido no se descubre aca: se descubre 40 minutos
       despues, con el OOBE roto.

  DECISIONES (van escritas porque son las preguntas que se hace el que lee):

  a) EL CAMPO ARRANCA VACIO y -Default es lo que devuelve "Enter sin escribir
     nada". La alternativa era arrancar con el default ya tipeado: se descarto
     porque entonces tipear 'juan' sobre 'pato' da 'patojuan', y tanto el usuario
     como el test tendrian que acordarse de borrar primero (4 Backspace que nadie
     documenta). Con el campo vacio, lo que se tipea es lo que queda y el default
     sigue estando a un Enter de distancia. El frame lo dice: "(vacio = pato)".

  b) ENTER CON EL CAMPO VACIO devuelve -Default. Si -Default esta vacio, NO
     confirma: muestra el error abajo del campo y sigue esperando.

  c) NUNCA DEVUELVE ''. Un llamador que escriba `if ($nombre) { ... }` no puede
     distinguir '' de $null: "no escribio nada" y "cancelo con Esc" terminarian en
     la misma rama por accidente. Hay exactamente dos salidas: un string no vacio,
     o $null.

  d) EL DEFAULT TAMBIEN SE VALIDA. Enter sobre el campo vacio pasa -Default por
     -Validate como si lo hubiera tipeado el usuario. Si el llamador cablea un
     default invalido, el error se ve en la TUI y no en la instalacion.

  e) -Validate BLOQUEA, -Advise NO. Son dos canales porque la seccion 4 de
     docs\contrato-cuenta-usuario.md pide las dos cosas: un nombre con un caracter
     prohibido no se puede confirmar, y un nombre con espacios SI se puede
     confirmar pero hay que avisar que la carpeta del perfil va a quedar con ese
     nombre para siempre. Con un solo canal habria que inventar un prefijo magico
     ('AVISO: ...') y parsearlo aca: un contrato invisible entre dos archivos.

  f) LA ZONA DE MENSAJE MIDE SIEMPRE LO MISMO (2 lineas). Si creciera y se
     encogiera con el largo del error, el footer -- y el frame entero -- se
     moverian solos mientras el usuario tipea.
#>
function Show-TuiInput {
  param(
    [Parameter(Mandatory)][string]$Title,
    # -Prompt es la ETIQUETA del campo ("nombre" dibuja "nombre: pato_"), no el
    # texto explicativo: ese va en -Lines, que es multilinea y se wrappea.
    [Parameter(Mandatory)][string]$Prompt,
    [string]$Default = '',
    [int]$MaxLen = 20,
    [scriptblock]$Validate = $null,
    [scriptblock]$Advise = $null,
    [string[]]$Lines = @()
  )

  # Los dos guardas son contra errores del LLAMADOR, y tiran a proposito en la
  # primera llamada: un -MaxLen de 0 deja un campo donde no se puede escribir nada
  # y un -Default mas largo que -MaxLen hace que el frame prometa "(vacio = X)" con
  # una X que -Validate va a rechazar. Fallar deterministicamente en el primer run
  # le gana a una TUI que se porta raro en la maquina del usuario.
  if ($MaxLen -lt 1) { throw "Show-TuiInput: -MaxLen tiene que ser 1 o mas (llego $MaxLen)." }
  if ($Default.Length -gt $MaxLen) {
    throw ("Show-TuiInput: -Default ('" + $Default + "', " + $Default.Length + " caracteres) no entra en " +
           "-MaxLen " + $MaxLen + ": el frame prometeria un default que Enter no puede confirmar.")
  }

  $text = ''
  # 3 lineas, igual que la nota de la checklist. MEDIDO: con 2 lineas el aviso mas
  # largo (espacios + no-ASCII + un nombre de 20 caracteres) se cortaba y el frame
  # se comia el final de la advertencia. Un aviso truncado es peor que ninguno:
  # parece que la herramienta te dijo algo cuando en realidad no lo dijo. Ver (f).
  $msgRows = 3

  while ($true) {
    # El layout ANTES de dibujar, como en la checklist: un resize a mitad de
    # tipeo se acomoda en el redibujo siguiente. Se ASIGNA (no se llama pelado)
    # porque el hashtable del layout se sumaria al valor de retorno de esta
    # funcion, que aca no es un bool: es el nombre de la cuenta del usuario.
    $lay = Update-TuiLayout
    Reset-TuiCursor
    Show-TuiHeader $Title

    # $efectivo = lo que Enter confirmaria AHORA. Se valida ESTO y no $text: con el
    # campo vacio y un default cargado, validar '' dibujaria "no puede estar vacio"
    # debajo de un campo donde Enter SI funciona. Asi, el error que se ve es
    # siempre el motivo exacto por el que Enter no confirma.
    $efectivo = if ($text.Length -eq 0 -and $Default.Length -gt 0) { $Default } else { $text }

    $err = $null
    if ($efectivo.Length -eq 0) {
      # Ver decision (c): '' no es un valor de retorno posible, asi que el campo
      # vacio sin default es un error incluso sin -Validate.
      $err = 'el campo no puede quedar vacio.'
    } elseif ($Validate) {
      # Un -Validate que TIRA no se puede llevar la TUI puesta a mitad de frame: se
      # degrada a error (Enter bloqueado, Esc sigue saliendo) y se muestra el
      # mensaje, que es mas de lo que se ve en un stack trace sobre el frame roto.
      try { $err = & $Validate $efectivo }
      catch { $err = 'la validacion fallo: ' + $_.Exception.Message }
    }
    $adv = $null
    if (-not $err -and $Advise) {
      try { $adv = & $Advise $efectivo } catch { $adv = $null }
    }

    Write-TuiLine ''
    # Las lineas de contexto se WRAPPEAN (Write-TuiLine sola las recortaria y el
    # aviso del OOBE se cortaria a la mitad) y se topean con las filas del layout:
    # el frame tiene 13 lineas fijas (4 header + 3 blancos + campo + 3 de mensaje +
    # 2 de footer), y 13 + $lay.Rows nunca pasa la altura de la consola porque Rows
    # ya es Height - 15. Sin el tope, un -Lines largo scrollea el buffer y el
    # SetCursorPosition(0,0) del frame siguiente dibuja corrido.
    $ctx = @()
    foreach ($l in $Lines) {
      if ($l -eq '') { $ctx += '' } else { $ctx += @(Wrap-TuiText $l ($script:TuiWidth - 4)) }
    }
    if ($ctx.Count -gt $lay.Rows) { $ctx = @($ctx[0..($lay.Rows - 1)]) }
    foreach ($l in $ctx) { Write-TuiLine ("  " + $l) 'White' }
    Write-TuiLine ''

    # El '_' final es el cursor: la consola real tiene el cursor fisico en 0,0
    # (Reset-TuiCursor), asi que sin este caracter el usuario no ve donde escribe.
    # El texto va como ARGUMENTO de -f y nunca dentro del formato: si el usuario
    # tipea una llave, '{0}' no se reinterpreta.
    $campo = "  {0}: {1}_" -f $Prompt, $text
    if ($text.Length -eq 0 -and $Default.Length -gt 0) { $campo += "   (vacio = $Default)" }
    else { $campo += ("   [{0}/{1}]" -f $text.Length, $MaxLen) }
    Write-TuiLine $campo 'Yellow'
    Write-TuiLine ''

    $msg = ''; $col = 'DarkGray'
    if     ($err) { $msg = 'ERROR: ' + $err; $col = 'Red' }
    elseif ($adv) { $msg = 'AVISO: ' + $adv; $col = 'Yellow' }
    $wrapped = @(Wrap-TuiText $msg ($script:TuiWidth - 4))
    for ($i = 0; $i -lt $msgRows; $i++) {
      if ($i -lt $wrapped.Count) { Write-TuiLine ("  " + $wrapped[$i]) $col } else { Write-TuiLine '' }
    }

    Show-TuiFooter @('ENTER confirmar   ESC cancelar sin elegir   BACKSPACE borrar')

    $k = Get-TuiKey
    switch ($k.Key) {
      # Enter con error NO confirma y tampoco limpia nada: el frame siguiente
      # vuelve a dibujar el mismo error. Es la seccion 3 del contrato.
      'Enter'     { if (-not $err) { return $efectivo } }
      'Escape'    { return $null }
      'Backspace' { if ($text.Length -gt 0) { $text = $text.Substring(0, $text.Length - 1) } }
      default {
        # [char]::IsControl en vez de una lista de teclas a mano: saca Enter (13),
        # Esc (27), Tab (9), Backspace (8), Delete (127) y TODAS las teclas sin
        # KeyChar -- flechas, Home/End, las F -- que llegan con NUL (medido en
        # ConvertTo-TuiKeyInfo y en la consola real). Una tecla de control nueva ya
        # esta cubierta sin tocar esto.
        # Los no-ASCII (acentos) SI entran: la seccion 4 del contrato pide
        # advertir, no prohibir. Ver Test-WindowsUserName -Advisory.
        $c = $k.KeyChar
        if ((-not [char]::IsControl($c)) -and ($text.Length -lt $MaxLen)) { $text = $text + $c }
      }
    }
  }
}

# ===========================================================================
#  VALIDACION DEL NOMBRE DE CUENTA DE WINDOWS
# ===========================================================================
<#
  Reglas de la seccion 4 de docs\contrato-cuenta-usuario.md. Vive aca, y no en
  LunaticOS.ps1, porque es el -Validate de Show-TuiInput y tui.ps1 se dot-sourcea
  antes que nada: asi la TUI y el self-test miran LA MISMA funcion. Que la
  validacion viva en un lado y la que corre en la TUI sea otra copia es el camino
  directo a "el test pasa y la instalacion falla".

  POR QUE IMPORTA: un nombre que Windows rechaza no falla en la TUI ni al generar
  la ISO. Falla al CREAR LA CUENTA durante la instalacion, o sea 40 minutos
  despues, con el OOBE pidiendo cuenta Microsoft y sin bypassnro.cmd (seccion 2
  del contrato). Y renombrar despues no arregla la CARPETA del perfil.
#>

# 20 caracteres: limite de la base SAM, no una eleccion de diseno nuestra.
$script:WinUserNameMaxLen = 20

# Los que rechaza Windows. En comillas simples a proposito: el " y el \ son
# literales y no hay interpolacion que los toque.
$script:WinUserNameBadChars = '"/\[]:;|=,+*?<>'

# Reservados por el SO (dispositivos DOS). Lista explicita y no un rango generado:
# se lee de un vistazo y no depende de que nadie se equivoque con el 1..9.
$script:WinUserNameReserved = @(
  'CON','PRN','AUX','NUL',
  'COM1','COM2','COM3','COM4','COM5','COM6','COM7','COM8','COM9',
  'LPT1','LPT2','LPT3','LPT4','LPT5','LPT6','LPT7','LPT8','LPT9'
)

# Cuentas que Windows 11 ya trae creadas: pedir una de estas no crea nada, choca.
$script:WinUserNameTaken = @('Administrator','Guest','DefaultAccount','WDAGUtilityAccount','SYSTEM')

<#
  Test-WindowsUserName -- devuelve $null si el nombre sirve, o el MENSAJE DE ERROR.
  Sirve tal cual como -Validate de Show-TuiInput y se puede testear sola.

      Test-WindowsUserName 'pato'            -> $null
      Test-WindowsUserName 'pa|to'           -> 'Windows no acepta estos caracteres...'
      Test-WindowsUserName 'pato' -Advisory  -> $null

  -Advisory: EL MISMO chequeo, pero devuelve el AVISO en vez del error.

  POR QUE UN SWITCH Y NO OTRO TIPO DE RETORNO. El contrato pide dos cosas que
  conviven: hay nombres que NO se pueden usar (bloquean) y nombres validos que
  igual merecen una advertencia (espacios, acentos: la carpeta del perfil va a
  quedar con eso). Las opciones eran:
    - devolver un objeto @{ Error; Aviso }  -> deja de servir de -Validate, que
      espera $null-o-string, y el llamador tiene que saber destriparlo;
    - devolver 'AVISO: ...' con prefijo     -> un contrato de string magico que hay
      que parsear del otro lado, y que se rompe en silencio si alguien traduce el
      mensaje;
    - dos funciones separadas               -> dos listas de reglas que se van a
      desincronizar el dia que se agregue una regla.
  Con el switch hay UNA fuente de reglas, el tipo de retorno es siempre el mismo
  ($null o string) y el que llama elige QUE canal quiere leer. Show-TuiInput pide
  los dos: -Validate sin el switch, -Advise con el switch.

  -Advisory sobre un nombre INVALIDO devuelve $null: el error ya bloquea a Enter y
  amontonar un aviso arriba de un error solo tapa el motivo real.

  -ComputerName default $env:COMPUTERNAME. MATIZ HONESTO: el nombre que importa es
  el de la maquina DONDE SE VA A INSTALAR, y a la hora de construir la ISO eso no
  se conoce (el autounattend no fija ComputerName, se lo inventa Windows). El
  nombre del host que construye es la mejor aproximacion disponible y es la regla
  que pide el contrato. Se puede desactivar con -ComputerName ''.
#>
function Test-WindowsUserName {
  param(
    # [AllowEmptyString()] por lo mismo que [AllowEmptyCollection()] en la
    # checklist: Mandatory RECHAZA '' en el binding, y "el nombre esta vacio" es
    # justo el primer caso que esta funcion tiene que poder contestar. Sin esto
    # reventaria ANTES de entrar, con un error de PowerShell.
    [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Name,
    [string]$ComputerName = $env:COMPUTERNAME,
    [switch]$Advisory
  )

  $n = [string]$Name   # $null -> ''
  $err = $null

  if ($n.Length -eq 0) {
    $err = 'el nombre no puede estar vacio.'
  }
  elseif ($n.Length -gt $script:WinUserNameMaxLen) {
    $err = ('el nombre no puede pasar de ' + $script:WinUserNameMaxLen +
            ' caracteres (tiene ' + $n.Length + '): es el limite de la base SAM.')
  }
  else {
    # Los prohibidos se juntan TODOS antes de armar el mensaje: decirle al usuario
    # "sacale el |" cuando tambien tiene un ':' lo hace volver dos veces.
    $malos = @()
    foreach ($c in $n.ToCharArray()) {
      if (($script:WinUserNameBadChars.IndexOf($c) -ge 0) -and ($malos -notcontains $c)) { $malos += $c }
    }
    $ctrl = @($n.ToCharArray() | Where-Object { [char]::IsControl($_) })

    if ($malos.Count -gt 0) {
      $err = 'Windows no acepta estos caracteres en un nombre de cuenta: ' + ($malos -join ' ')
    }
    elseif ($ctrl.Count -gt 0) {
      # No se puede tipear en la TUI, pero SI puede venir de un perfil.json editado
      # a mano (un tab pegado de otro lado). La funcion se usa en los dos caminos.
      $err = 'el nombre tiene caracteres de control (tabs, saltos de linea): sacalos.'
    }
    elseif ($n -match '^[. ]+$') {
      $err = 'el nombre no puede ser solo puntos y espacios.'
    }
    elseif ($n.EndsWith('.')) {
      $err = 'el nombre no puede terminar en punto.'
    }
    elseif ($n.StartsWith(' ') -or $n.EndsWith(' ')) {
      $err = 'el nombre no puede empezar ni terminar con un espacio.'
    }
    # -contains con strings es case-insensitive (medido): 'con' tambien esta
    # reservado, no solo 'CON'.
    elseif ($script:WinUserNameReserved -contains $n) {
      $err = ("'" + $n + "' es un nombre de dispositivo reservado por Windows (" +
              'CON PRN AUX NUL COM1-9 LPT1-9).')
    }
    elseif ($script:WinUserNameTaken -contains $n) {
      $err = ("'" + $n + "' ya es una cuenta del sistema en Windows 11: elegi otro.")
    }
    elseif ($ComputerName -and ($n -eq $ComputerName)) {
      $err = ("el nombre no puede ser igual al del equipo ('" + $ComputerName +
              "'): choca con la cuenta de maquina.")
    }
  }

  if ($Advisory) {
    if ($err) { return $null }
    $motivos = @()
    if ($n.Contains(' '))         { $motivos += 'espacios' }
    if ($n -match '[^\x00-\x7F]') { $motivos += 'caracteres no-ASCII (acentos y demas)' }
    if ($motivos.Count -eq 0) { return $null }
    # Se dice la CONSECUENCIA CONCRETA, no "puede haber problemas": la carpeta se
    # crea una sola vez y despues no se cambia mas, ni renombrando la cuenta.
    # Y se dice CORTO: el aviso tiene que entrar completo en las 3 lineas de mensaje
    # de Show-TuiInput con el nombre mas largo posible (20 caracteres) y los dos
    # motivos a la vez. Un aviso que se corta a la mitad no aviso nada.
    return ('el nombre tiene ' + ($motivos -join ' y ') + ': la carpeta del perfil va a ser ' +
            'C:\Users\' + $n + ' y eso no se cambia mas.')
  }

  $err
}
