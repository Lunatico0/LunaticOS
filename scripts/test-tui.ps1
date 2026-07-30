#requires -Version 5.1
<#
  test-tui.ps1 -- Tests de la TUI sin UI y sin humano.

  POR QUE EXISTE (docs\testing-e2e.md, secciones 0 y 2):
  la TUI es el PRIMER CONTACTO del usuario con el proyecto y no tenia un solo
  test. Y ya hubo un bug que llego al usuario justo ahi: $Selected declarado
  [hashtable] contra un perfil [ordered], PowerShell convertia el tipo, la
  conversion creaba una COPIA y todo lo que el usuario marcaba se perdia al volver
  al menu. Sin error, sin log, sin sintoma. El self-test de LunaticOS.ps1 cubre la
  logica de abajo (catalogos, perfil, colores); esto cubre LO QUE PASA CUANDO
  ALGUIEN APRIETA TECLAS.

  COMO CORRE SIN PANTALLA -- tres decisiones, y ninguna mete un `if ($test)` en el
  codigo de produccion:

  1) TECLAS: $Global:TuiKeyProvider (tui.ps1). Send-TuiKeys carga una cola y
     Get-TuiKey la consume. Con la cola vacia TIRA, no espera: un test colgado no
     lo vuelve a correr nadie.

  2) DIBUJO: se silencia con `6>$null` y se MIDE con `6>&1`. Write-Host escribe en
     el stream de informacion desde PowerShell 5.0, asi que la redireccion 6 lo
     captura entero: los InformationRecord son las lineas del frame y lo que no es
     InformationRecord es el valor de retorno de la funcion. Cero cambios en
     produccion, y de paso se puede medir el ANCHO real de lo que se dibuja.

  3) CURSOR: Reset-TuiCursor se reemplaza aca abajo por un no-op. Es el UNICO
     punto que toca el cursor real y, si no se neutraliza, [Console]::SetCursor-
     Position(0,0) devuelve el cursor arriba en cada frame y el reporte de los
     tests se escribe encima de si mismo; y con la salida redirigida tira
     IOException y el catch hace Clear-Host, que se lleva el reporte entero.
     Son dos lineas de posicionamiento: lo que se testea es la LOGICA y el ANCHO,
     que no dependen del cursor.

  LO QUE SE AFIRMA es el estado del hashtable $Selected y el valor de retorno.
  NUNCA posiciones ni colores: un test que mira la pantalla se rompe con cualquier
  cambio cosmetico y termina borrado por molesto.

  Uso:
      powershell -File scripts\test-tui.ps1
  Exit code = cantidad de fallas (0 = todo OK). Lo consume scripts\test-e2e.ps1.
#>

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\tui.ps1"
# El catalogo REAL de personalizacion: los grupos excluyentes que se testean son
# los que usa el usuario, no unos de juguete. Solo declara variables globales.
. "$PSScriptRoot\..\config\personalizacion.ps1"

# Se lee ANTES de que cualquier test llame a Send-TuiKeys: si tui.ps1 quedara con
# un provider cargado, produccion arrancaria en modo test y la TUI no leeria el
# teclado de nadie.
$providerAlCargar = $Global:TuiKeyProvider
$sizeAlCargar     = $Global:TuiSizeProvider

function Reset-TuiCursor { }   # no-op a proposito (ver decision 3 del header)

# ===========================================================================
#  REPORTE -- mismo formato que Invoke-SelfTest de LunaticOS.ps1
# ===========================================================================
$script:fail  = 0
$script:total = 0
function Chk($name, $cond, $detail = '') {
  $script:total++
  if ($cond) { Write-Host "  OK    $name" -ForegroundColor Green }
  else       { Write-Host "  FALLA $name $detail" -ForegroundColor Red; $script:fail++ }
}

# Cada bloque corre aislado: si uno TIRA, se anota como falla y los demas siguen.
# Sin esto una excepcion se lleva la corrida entera y el exit code no cuenta nada.
function Test-Case([string]$Name, [scriptblock]$Body) {
  try { & $Body }
  catch { Chk $Name $false ("-> EXCEPCION: " + $_.Exception.Message) }
}

# ===========================================================================
#  HELPERS
# ===========================================================================
function New-TestItems([int]$N) {
  $out = @()
  for ($i = 0; $i -lt $N; $i++) {
    $out += @{ Key = ("k{0:d2}" -f $i); Name = ("item {0:d2}" -f $i)
               Rec = (($i % 3) -eq 0); Note = "nota del item $i" }
  }
  ,$out
}

# [ordered] A PROPOSITO: es lo que usa el perfil real (para conservar el orden de
# las claves en el JSON) y es el tipo con el que aparecio el bug de la copia.
function New-TestSelected($Items) {
  $s = [ordered]@{}
  foreach ($it in $Items) { $s[$it.Key] = $false }
  $s
}

# Teclas para dejar el cursor en un indice exacto. Home primero para no depender
# de donde venia el cursor.
function Get-KeysToIndex([int]$Index) {
  $k = @('Home')
  for ($i = 0; $i -lt $Index; $i++) { $k += 'DownArrow' }
  ,$k
}

function Get-IndexOfKey($Items, [string]$Key) {
  for ($i = 0; $i -lt @($Items).Count; $i++) { if ($Items[$i].Key -eq $Key) { return $i } }
  return -1
}

function Get-MaxLineLength($Lines) {
  $m = 0
  foreach ($l in @($Lines)) { if ("$l".Length -gt $m) { $m = "$l".Length } }
  $m
}

# Corre la checklist con teclas inyectadas y devuelve @{ Lines; Ret }.
#   Lines = las lineas dibujadas (para medir el ancho del frame)
#   Ret   = TODO lo que la funcion dejo en el pipeline. Se guarda completo a
#           proposito: si algo se cuela ahi, el retorno deja de ser un bool y el
#           `if ($ok)` del llamador empieza a mentir. Ya paso con el exit code
#           del self-test.
function Invoke-Checklist {
  param($Items, $Selected, $Exclusive = @(), [string[]]$Keys, [string]$Title = 'test')
  Send-TuiKeys $Keys
  $raw = @(Show-TuiChecklist -Title $Title -Items $Items -Selected $Selected -Exclusive $Exclusive 6>&1)
  $inf = 'System.Management.Automation.InformationRecord'
  @{
    Lines = @($raw | Where-Object { $_.GetType().FullName -eq $inf } |
                     ForEach-Object { "$($_.MessageData.Message)" })
    Ret   = @($raw | Where-Object { $_.GetType().FullName -ne $inf })
  }
}

# El menu devuelve $null cuando el usuario sale, y un $null no sobrevive bien a un
# filtrado de pipeline: aca se silencia con 6>$null y se mira el valor pelado.
function Invoke-Menu {
  param($Entries, [string[]]$Keys)
  Send-TuiKeys $Keys
  Show-TuiMenu -Entries $Entries -Subtitle 'test' 6>$null
}

Write-Host ''
Write-Host '== TESTS de la TUI (teclas inyectadas, sin UI ni humano) ==' -ForegroundColor Cyan

# ===========================================================================
#  0. EL INSTRUMENTO PRIMERO
#  Si la inyeccion de teclas o el catalogo estan mal, todo lo de abajo da verde
#  por vacio. Un instrumento roto que informa exito es el peor de los mundos.
# ===========================================================================
Test-Case 'infra de teclas' {
  Chk 'tui.ps1 se carga con $TuiKeyProvider en $null (produccion no queda en modo test)' `
      ($null -eq $providerAlCargar) '-> quedo un provider cargado: la TUI no leeria el teclado del usuario'
  Chk 'tui.ps1 se carga con $TuiSizeProvider en $null' ($null -eq $sizeAlCargar)

  $k = ConvertTo-TuiKeyInfo 'DownArrow'
  Chk 'Send-TuiKeys fabrica un [ConsoleKeyInfo] de verdad (mismo tipo que la consola)' `
      ($k -is [ConsoleKeyInfo])
  Chk 'DownArrow: .Key es DownArrow y .KeyChar es NUL (como la consola real)' `
      ($k.Key -eq [ConsoleKey]::DownArrow -and [int]$k.KeyChar -eq 0)
  Chk 'Spacebar: .KeyChar es un espacio'  ((ConvertTo-TuiKeyInfo 'Spacebar').KeyChar -eq ' ')
  Chk 'Enter: .Key es Enter'              ((ConvertTo-TuiKeyInfo 'Enter').Key -eq [ConsoleKey]::Enter)
  Chk 'Escape: .Key es Escape'            ((ConvertTo-TuiKeyInfo 'Escape').Key -eq [ConsoleKey]::Escape)
  Chk 'un caracter suelto conserva su caja: A -> KeyChar A'  ((ConvertTo-TuiKeyInfo 'A').KeyChar -eq 'A')
  Chk 'y a -> KeyChar a con .Key = A'     (((ConvertTo-TuiKeyInfo 'a').KeyChar -eq 'a') -and `
                                           ((ConvertTo-TuiKeyInfo 'a').Key -eq [ConsoleKey]::A))
  # Un nombre mal escrito que se ignora en silencio convierte al test en un adorno:
  # el test "pasa" porque la tecla nunca llego.
  $tiro = $false
  try { ConvertTo-TuiKeyInfo 'DownArow' | Out-Null } catch { $tiro = $true }
  Chk 'un nombre de tecla invalido TIRA (no se ignora en silencio)' $tiro

  Send-TuiKeys @('DownArrow','Spacebar')
  Chk 'Get-TuiKey consume la cola en orden' `
      (((Get-TuiKey).Key -eq [ConsoleKey]::DownArrow) -and ((Get-TuiKey).Key -eq [ConsoleKey]::Spacebar))
  $msg = ''
  try { Get-TuiKey | Out-Null } catch { $msg = $_.Exception.Message }
  Chk 'con la cola vacia Get-TuiKey TIRA (no se cuelga ni devuelve $null)' `
      ($msg -match 'cola de teclas') "-> dijo: $msg"
}

Test-Case 'el catalogo real tiene grupos excluyentes que testear' {
  # OJO: se mira el catalogo COMO LO VE LA TUI (normalizado). Crudo llega aplanado
  # por el literal @( @(...) ) -- ver Resolve-TuiExclusive en tui.ps1 -- y sin
  # normalizar, "un grupo de tres" se lee como "tres grupos de uno", o sea nada.
  $grupos = Resolve-TuiExclusive @($Global:PersonalizacionExclusivos)
  Chk 'el catalogo declara al menos un grupo excluyente' (@($grupos).Count -ge 1) `
      '-> sin grupos, los tests de exclusividad no miden NADA'
  $chicos = @($grupos | Where-Object { @($_).Count -lt 2 })
  Chk 'todos los grupos excluyentes tienen 2 claves o mas' ($chicos.Count -eq 0) `
      '-> un grupo de una sola clave no excluye a nadie: es un grupo que no existe'
}

# Tamano de consola FIJO para todos los tests de logica: sin esto el layout sale
# de la terminal del que corre el test y el resultado cambia de maquina en maquina.
$Global:TuiSizeProvider = { @{ Width = 120; Height = 30 } }
$script:rowsDefault = (Resolve-TuiLayout 120 30).Rows

# ===========================================================================
#  1. SPACEBAR marca
# ===========================================================================
Test-Case 'Spacebar marca' {
  $items = New-TestItems 5
  $sel   = New-TestSelected $items
  $r = Invoke-Checklist -Items $items -Selected $sel -Keys @('Spacebar','Enter')
  Chk 'Spacebar deja el item en $true en $Selected' ($sel['k00'] -eq $true)
  Chk 'y no toca a los demas' (@($sel.Keys | Where-Object { $sel[$_] }).Count -eq 1)
  Chk 'el retorno es UN unico bool (nada se cuela al pipeline)' `
      ($r.Ret.Count -eq 1 -and $r.Ret[0] -is [bool]) ("-> devolvio " + $r.Ret.Count + " objetos")

  $sel2 = New-TestSelected $items
  Invoke-Checklist -Items $items -Selected $sel2 -Keys @('Spacebar','Spacebar','Enter') | Out-Null
  Chk 'Spacebar dos veces desmarca (toggle)' ($sel2['k00'] -eq $false)

  $sel3 = New-TestSelected $items
  Invoke-Checklist -Items $items -Selected $sel3 -Keys @('DownArrow','DownArrow','Spacebar','Enter') | Out-Null
  Chk 'marca el item bajo el cursor, no el primero' `
      (($sel3['k02'] -eq $true) -and ($sel3['k00'] -eq $false))

  # El bug de la COPIA, medido por comportamiento y no por el tipo del parametro
  # (eso ya lo mira el self-test): el objeto que entro tiene que ser el que salio.
  $sel4 = New-TestSelected $items
  Invoke-Checklist -Items $items -Selected $sel4 -Keys @('Spacebar','Enter') | Out-Null
  Chk 'los cambios viven en el MISMO objeto que se paso (por referencia)' `
      ($sel4 -is [System.Collections.Specialized.OrderedDictionary] -and $sel4['k00'] -eq $true) `
      '-> la checklist trabajo sobre una copia: todo lo que marque el usuario se pierde'
  Chk 'y el orden de las claves sobrevive' `
      ((@($sel4.Keys) -join ',') -eq (@($items | ForEach-Object { $_.Key }) -join ','))
}

# ===========================================================================
#  2. GRUPOS EXCLUYENTES -- ESTO YA FUE UN BUG
# ===========================================================================
Test-Case 'grupos excluyentes' {
  $items = @($Global:PersonalizacionCatalog)
  # $exc se pasa CRUDO, exactamente como lo pasa Show-MainMenu: si la TUI dejara
  # de normalizarlo, estos tests tienen que caerse.
  $exc   = @($Global:PersonalizacionExclusivos)
  $grp   = @((Resolve-TuiExclusive $exc)[0])

  foreach ($target in $grp) {
    $sel = New-TestSelected $items
    $i   = Get-IndexOfKey $items $target
    Invoke-Checklist -Items $items -Selected $sel -Exclusive $exc `
                     -Keys ((Get-KeysToIndex $i) + @('Spacebar','Enter')) | Out-Null
    $marcados = @($grp | Where-Object { $sel[$_] })
    Chk "marcar '$target' deja SOLO a '$target' del grupo" `
        (($marcados.Count -eq 1) -and ($marcados[0] -eq $target)) `
        ("-> quedaron marcados: " + ($marcados -join ', '))
  }

  # El caso que se vio en la maquina del usuario: marcar dos acentos seguidos.
  $sel = New-TestSelected $items
  $keys = @()
  foreach ($t in @($grp[0], $grp[1])) { $keys += (Get-KeysToIndex (Get-IndexOfKey $items $t)) + @('Spacebar') }
  Invoke-Checklist -Items $items -Selected $sel -Exclusive $exc -Keys ($keys + @('Enter')) | Out-Null
  Chk 'marcar un segundo acento desmarca el primero' `
      (($sel[$grp[1]] -eq $true) -and ($sel[$grp[0]] -eq $false)) `
      '-> quedaron dos acentos marcados: gana el ultimo que escriba la fase y el resultado es inexplicable'

  # Desmarcar NO tiene que arrastrar a los hermanos: el grupo queda en cero, que es
  # una eleccion valida (ningun acento = el de fabrica de Windows).
  $sel2 = New-TestSelected $items
  $i0 = Get-IndexOfKey $items $grp[0]
  Invoke-Checklist -Items $items -Selected $sel2 -Exclusive $exc `
                   -Keys ((Get-KeysToIndex $i0) + @('Spacebar','Spacebar','Enter')) | Out-Null
  Chk 'desmarcar deja el grupo entero en cero (no re-marca hermanos)' `
      (@($grp | Where-Object { $sel2[$_] }).Count -eq 0)

  # Y un grupo sintetico de tres, para medir la CLASE y no solo los acentos.
  $it3 = New-TestItems 4
  $g3  = @('k00','k01','k02')
  $sel3 = New-TestSelected $it3
  Invoke-Checklist -Items $it3 -Selected $sel3 -Exclusive @(,$g3) `
                   -Keys @('Home','Spacebar','DownArrow','Spacebar','DownArrow','Spacebar','Enter') | Out-Null
  Chk 'un grupo de tres tambien deja uno solo' `
      ((@($g3 | Where-Object { $sel3[$_] }) -join ',') -eq 'k02')
  Chk 'y el item de afuera del grupo no se toca' ($sel3['k03'] -eq $false)
}

# ===========================================================================
#  2b. EL GRUPO APLANADO -- el bug que estaba VIVO cuando se escribieron estos tests
#
#  PowerShell aplana el array anidado unico de un literal: @( @(a,b,c) ) ES
#  @(a,b,c). Medido: @(@(1,2,3)).Count = 3, y @(@(1,2),@(3,4)).Count = 2 (con dos
#  grupos no pasa). config\personalizacion.ps1 declara UN grupo con la primera
#  forma, asi que la TUI recibia tres strings sueltos y los excluyentes no
#  excluian NADA: marcar el acento teal dejaba violeta marcado tambien, y la tecla
#  A marcaba los tres. Ver Resolve-TuiExclusive en tui.ps1.
# ===========================================================================
Test-Case 'un grupo aplanado sigue excluyendo' {
  $items = New-TestItems 4
  $plano = @('k00','k01','k02')   # <- lo que PowerShell entrega de @( @(...) )

  $sel = New-TestSelected $items
  Invoke-Checklist -Items $items -Selected $sel -Exclusive $plano `
                   -Keys @('Home','Spacebar','DownArrow','Spacebar','Enter') | Out-Null
  Chk 'con el grupo aplanado, marcar el segundo desmarca el primero' `
      (($sel['k01'] -eq $true) -and ($sel['k00'] -eq $false)) `
      '-> el grupo llego como strings sueltos y la exclusividad se perdio EN SILENCIO'
  Chk 'y el item de afuera del grupo no se toca' ($sel['k03'] -eq $false)

  $sel2 = New-TestSelected $items
  Invoke-Checklist -Items $items -Selected $sel2 -Exclusive $plano -Keys @('A','Enter') | Out-Null
  Chk "'A' con el grupo aplanado deja UNO solo del grupo" `
      (@($plano | Where-Object { $sel2[$_] }).Count -eq 1) `
      ("-> quedaron " + @($plano | Where-Object { $sel2[$_] }).Count + " marcados de 3")
}

# ===========================================================================
#  3. 'A' = todos, pero UNO por grupo excluyente
# ===========================================================================
Test-Case 'la tecla A' {
  $items = @($Global:PersonalizacionCatalog)
  $exc   = @($Global:PersonalizacionExclusivos)   # crudo, como lo pasa Show-MainMenu
  $grupos = Resolve-TuiExclusive $exc             # normalizado, para poder afirmar
  $sel   = New-TestSelected $items
  Invoke-Checklist -Items $items -Selected $sel -Exclusive $exc -Keys @('A','Enter') | Out-Null

  $enGrupo = @($grupos | ForEach-Object { $_ })
  $libres  = @($items | Where-Object { $enGrupo -notcontains $_.Key } | ForEach-Object { $_.Key })
  $sinMarcar = @($libres | Where-Object { -not $sel[$_] })
  Chk "'A' marca todos los items que no son excluyentes" ($sinMarcar.Count -eq 0) `
      ("-> quedaron sin marcar: " + ($sinMarcar -join ', '))
  foreach ($grp in $grupos) {
    $m = @($grp | Where-Object { $sel[$_] })
    Chk ("'A' deja UNO solo del grupo (" + ($grp -join '/') + ")") ($m.Count -eq 1) `
        ("-> quedaron " + $m.Count + ": " + ($m -join ', '))
  }
  Chk "'A' en minuscula hace lo mismo" (& {
    $s = New-TestSelected $items
    Invoke-Checklist -Items $items -Selected $s -Exclusive $exc -Keys @('a','Enter') | Out-Null
    @($grupos[0] | Where-Object { $s[$_] }).Count -eq 1
  })
}

# ===========================================================================
#  4. 'N' = ninguno, y "cero marcados" != "sin perfil"
# ===========================================================================
Test-Case 'la tecla N' {
  $items = New-TestItems 6
  $sel   = New-TestSelected $items
  Invoke-Checklist -Items $items -Selected $sel -Keys @('A','N','Enter') | Out-Null
  $marcados = @($sel.Keys | Where-Object { $sel[$_] })
  Chk "'N' deja todo en `$false" ($marcados.Count -eq 0) ("-> siguen marcados: " + ($marcados -join ', '))
  # ==========================================================================
  #  El bug de "elegir 0 apps instalaba los 24 recomendados" salio de aca: si la
  #  TUI borrara las claves en vez de ponerlas en $false, "cero marcados" quedaria
  #  indistinguible de "no hay perfil" y el fallback aplicaria los recomendados
  #  que el usuario acababa de rechazar. Las claves TIENEN que seguir estando.
  # ==========================================================================
  Chk 'las claves siguen existiendo: "cero marcados" es distinguible de "sin perfil"' `
      ($sel.Count -eq @($items).Count) ("-> quedaron " + $sel.Count + " claves de " + @($items).Count)
  $tipos = @($sel.Keys | Where-Object { $sel[$_] -isnot [bool] })
  Chk 'y todas valen un $false de verdad, no $null' ($tipos.Count -eq 0)
}

# ===========================================================================
#  5. 'R' = solo los recomendados
# ===========================================================================
Test-Case 'la tecla R' {
  $items = New-TestItems 9
  $sel   = New-TestSelected $items
  # A marca TODO primero: asi R tiene que DESMARCAR lo que no es recomendado, no
  # solo marcar. Un R que solo marca daria verde partiendo de todo en $false.
  Invoke-Checklist -Items $items -Selected $sel -Keys @('A','R','Enter') | Out-Null
  $mal = @($items | Where-Object { $sel[$_.Key] -ne [bool]$_.Rec } | ForEach-Object { $_.Key })
  Chk "'R' deja exactamente los recomendados" ($mal.Count -eq 0) ("-> mal: " + ($mal -join ', '))
  Chk 'y hay recomendados y no-recomendados en la muestra (el test mide algo)' `
      ((@($items | Where-Object { $_.Rec }).Count -gt 0) -and `
       (@($items | Where-Object { -not $_.Rec }).Count -gt 0))
}

# ===========================================================================
#  6. Enter confirma, Escape cancela
# ===========================================================================
Test-Case 'Enter y Escape' {
  $items = New-TestItems 4
  $s1 = New-TestSelected $items
  $r1 = Invoke-Checklist -Items $items -Selected $s1 -Keys @('Enter')
  Chk 'Enter devuelve $true'   ($r1.Ret.Count -eq 1 -and $r1.Ret[0] -eq $true)
  $s2 = New-TestSelected $items
  $r2 = Invoke-Checklist -Items $items -Selected $s2 -Keys @('Escape')
  Chk 'Escape devuelve $false' ($r2.Ret.Count -eq 1 -and $r2.Ret[0] -eq $false) `
      ("-> devolvio: " + ($r2.Ret -join ', '))
  Chk 'y los dos retornos son bool, no string ni array' `
      (($r1.Ret[0] -is [bool]) -and ($r2.Ret[0] -is [bool]))
  Chk 'Escape corta el bucle en el primer frame (no sigue pidiendo teclas)' `
      ($Global:TuiKeyQueue.Count -eq 0)
}

# ===========================================================================
#  7. SCROLL -- navegar mas alla de la ventana visible
#  El cursor no se puede leer de afuera, asi que se usa Spacebar de sonda: la
#  clave que quedo marcada dice EXACTAMENTE donde estaba el cursor.
# ===========================================================================
Test-Case 'scroll y limites' {
  $items = New-TestItems 30
  $rows  = $script:rowsDefault

  $sel = New-TestSelected $items
  $r = Invoke-Checklist -Items $items -Selected $sel -Keys ((Get-KeysToIndex 20) + @('Spacebar','Enter'))
  Chk "bajar 20 veces (mas que las $rows filas visibles) deja el cursor en el item 20" ($sel['k20'] -eq $true)

  $sel = New-TestSelected $items
  Invoke-Checklist -Items $items -Selected $sel -Keys @('End','Spacebar','Enter') | Out-Null
  Chk 'End va al ultimo item' ($sel['k29'] -eq $true)

  $sel = New-TestSelected $items
  Invoke-Checklist -Items $items -Selected $sel -Keys @('End','Home','Spacebar','Enter') | Out-Null
  Chk 'Home vuelve al primero' ($sel['k00'] -eq $true)

  # 50 bajadas en una lista de 30: el clamp tiene que aguantar sin salirse.
  $sel = New-TestSelected $items
  $abajo = @('Home'); for ($i = 0; $i -lt 50; $i++) { $abajo += 'DownArrow' }
  Invoke-Checklist -Items $items -Selected $sel -Keys ($abajo + @('Spacebar','Enter')) | Out-Null
  Chk 'bajar 50 veces en 30 items se queda en el ultimo (no sale del rango)' ($sel['k29'] -eq $true)

  $sel = New-TestSelected $items
  $arriba = @('End'); for ($i = 0; $i -lt 50; $i++) { $arriba += 'UpArrow' }
  Invoke-Checklist -Items $items -Selected $sel -Keys ($arriba + @('Spacebar','Enter')) | Out-Null
  Chk 'subir 50 veces se queda en el primero' ($sel['k00'] -eq $true)

  $sel = New-TestSelected $items
  Invoke-Checklist -Items $items -Selected $sel -Keys @('Home','PageDown','Spacebar','Enter') | Out-Null
  Chk "PageDown baja $rows items (una ventana)" ($sel[("k{0:d2}" -f $rows)] -eq $true)

  $sel = New-TestSelected $items
  $pg = @('Home'); for ($i = 0; $i -lt 6; $i++) { $pg += 'PageDown' }
  Invoke-Checklist -Items $items -Selected $sel -Keys ($pg + @('Spacebar','Enter')) | Out-Null
  Chk 'PageDown de mas se queda en el ultimo' ($sel['k29'] -eq $true)

  $sel = New-TestSelected $items
  $pu = @('End'); for ($i = 0; $i -lt 6; $i++) { $pu += 'PageUp' }
  Invoke-Checklist -Items $items -Selected $sel -Keys ($pu + @('Spacebar','Enter')) | Out-Null
  Chk 'PageUp de mas se queda en el primero' ($sel['k00'] -eq $true)

  # La ventana visible tiene que SEGUIR al cursor: si no scrollea, el usuario mueve
  # el cursor a ciegas fuera de pantalla. Se mira el CONTENIDO dibujado, no
  # posiciones ni colores.
  $sel = New-TestSelected $items
  $r = Invoke-Checklist -Items $items -Selected $sel -Keys @('End','Enter')
  $ultimoFrame = @($r.Lines | Select-Object -Last (14 + $rows))
  # El '\[.\]' pide la fila de la LISTA ("> [x]*  item 29") y no la linea de nota
  # ("nota del item 29"), que tambien contiene el texto y hacia contar dos.
  Chk 'con el cursor al final, la ventana visible muestra el ultimo item' `
      (@($ultimoFrame | Where-Object { $_ -match '\[.\].*item 29' }).Count -eq 1) `
      '-> la ventana no siguio al cursor: el usuario mueve el cursor fuera de la pantalla'
  Chk 'y ya no muestra el primero (scrolleo de verdad)' `
      (@($ultimoFrame | Where-Object { $_ -match '\[.\].*item 00' }).Count -eq 0)
}

# ===========================================================================
#  8. LISTA VACIA
#  Hoy esto reventaba de dos maneras distintas, las dos medidas:
#    - [Parameter(Mandatory)] RECHAZA @() en el binding: "Cannot bind argument to
#      parameter 'Items' because it is an empty collection" (ni entraba);
#    - End dejaba $idx = -1 y el Spacebar siguiente hacia $Selected[$null], que TIRA.
# ===========================================================================
Test-Case 'lista vacia' {
  $sel = [ordered]@{}
  $r = Invoke-Checklist -Items @() -Selected $sel `
        -Keys @('Spacebar','DownArrow','UpArrow','End','Spacebar','Home','PageDown','PageUp','A','N','R','Enter')
  Chk 'una lista vacia no explota y confirma con Enter' ($r.Ret.Count -eq 1 -and $r.Ret[0] -eq $true)
  Chk 'y no inventa claves en $Selected' ($sel.Count -eq 0) ("-> aparecieron " + $sel.Count + " claves")
  Chk 'y dibujo un frame igual (no se colgo ni salio en blanco)' ($r.Lines.Count -gt 0)

  # Un item solo: el otro borde de los indices.
  $uno = @(@{ Key='solo'; Name='unico'; Note='n' })
  $s1  = New-TestSelected $uno
  Invoke-Checklist -Items $uno -Selected $s1 -Keys @('DownArrow','End','Spacebar','Enter') | Out-Null
  Chk 'con UN solo item los indices no se pasan' ($s1['solo'] -eq $true)
}

# ===========================================================================
#  9. EL FRAME CON LA CONSOLA CHICA
#  Antes: 78 columnas y 14 filas FIJAS. Con una ventana mas angosta cada linea
#  hacia wrap y el frame se desarmaba; con menos filas que el frame, el buffer
#  scrolleaba y el SetCursorPosition(0,0) dibujaba encima de si mismo.
# ===========================================================================
Test-Case 'layout (funcion pura)' {
  $l = Resolve-TuiLayout 120 30
  Chk 'consola normal (120x30): 78 columnas y 14 filas -- el frame de siempre' `
      ($l.Width -eq 78 -and $l.Rows -eq 14) ("-> dio " + $l.Width + "x" + $l.Rows)
  Chk 'consola gigante (300x80): el ancho no pasa de 78' ((Resolve-TuiLayout 300 80).Width -eq 78)
  Chk '79 columnas alcanzan para el frame completo' ((Resolve-TuiLayout 79 30).Width -eq 78)
  Chk '78 columnas justas dan 77 (nunca se escribe en la ultima columna)' `
      ((Resolve-TuiLayout 78 30).Width -eq 77)
  Chk 'consola angosta (46): el ancho baja a 45' ((Resolve-TuiLayout 46 30).Width -eq 45)
  Chk 'consola absurda (20): piso de 40 (frame feo, pero sin cuentas negativas)' `
      ((Resolve-TuiLayout 20 30).Width -eq 40)
  Chk 'consola baja (24 filas): 9 filas de lista' ((Resolve-TuiLayout 120 24).Rows -eq 9)
  Chk 'consola muy baja (12 filas): piso de 3 filas' ((Resolve-TuiLayout 120 12).Rows -eq 3)
  Chk 'consola alta (80 filas): techo de 14 filas' ((Resolve-TuiLayout 120 80).Rows -eq 14)

  # Get-TuiConsoleSize no puede tirar NUNCA: en esta misma corrida la salida esta
  # redirigida y [Console]::WindowWidth tira IOException (medido).
  $prev = $Global:TuiSizeProvider
  try {
    $Global:TuiSizeProvider = $null
    $s = Get-TuiConsoleSize
    Chk 'Get-TuiConsoleSize devuelve algo usable aun con la salida redirigida' `
        ($s.Width -gt 0 -and $s.Height -gt 0) ("-> dio " + $s.Width + "x" + $s.Height)
  } finally { $Global:TuiSizeProvider = $prev }
}

Test-Case 'el frame se adapta a la consola' {
  $items = New-TestItems 30
  $prev  = $Global:TuiSizeProvider
  try {
    # --- Consola normal: el frame tiene que ser IDENTICO al de siempre ---
    $Global:TuiSizeProvider = { @{ Width = 120; Height = 30 } }
    $sel = New-TestSelected $items
    $r = Invoke-Checklist -Items $items -Selected $sel -Keys @('Enter')
    $ancho = Get-MaxLineLength $r.Lines
    Chk 'con 120x30 el frame mide 78 columnas y 28 lineas (el de siempre)' `
        (($ancho -eq 78) -and ($r.Lines.Count -eq 28)) `
        ("-> " + $ancho + " columnas x " + $r.Lines.Count + " lineas")

    # --- Consola angosta y baja: nada de wrap, y el frame entra ---
    $Global:TuiSizeProvider = { @{ Width = 46; Height = 24 } }
    $sel = New-TestSelected $items
    $r = Invoke-Checklist -Items $items -Selected $sel -Keys @('Enter')
    $ancho = Get-MaxLineLength $r.Lines
    Chk 'con 46 columnas ninguna linea del frame pasa de 45' ($ancho -le 45) `
        ("-> la linea mas larga midio " + $ancho + ": hace wrap y parte el frame")
    Chk 'con 24 filas el frame entra en 23 lineas' ($r.Lines.Count -le 23) `
        ("-> dibujo " + $r.Lines.Count + " lineas en 24 filas: el buffer scrollea y el redibujo queda corrido")
    Chk 'y la checklist sigue funcionando con la consola chica' `
        (& {
          $s = New-TestSelected $items
          Invoke-Checklist -Items $items -Selected $s -Keys @('DownArrow','Spacebar','Enter') | Out-Null
          $s['k01'] -eq $true
        })

    # --- Consola absurda: el piso de 40 no tiene que producir cuentas negativas ---
    $Global:TuiSizeProvider = { @{ Width = 12; Height = 6 } }
    $sel = New-TestSelected $items
    $r = Invoke-Checklist -Items $items -Selected $sel -Keys @('Spacebar','Enter')
    Chk 'una consola de 12x6 no rompe la TUI (frame feo, sin excepcion)' `
        (($sel['k00'] -eq $true) -and ($r.Ret[0] -eq $true))

    # Write-TuiLine tiene que RECORTAR, no dejar pasar una linea mas larga que el frame.
    $null = Update-TuiLayout
    $larga = @(Write-TuiLine ('x' * 200) 6>&1)
    Chk 'Write-TuiLine recorta al ancho del frame' `
        ("$($larga[0].MessageData.Message)".Length -eq $script:TuiWidth)
  } finally { $Global:TuiSizeProvider = $prev }
}

# ===========================================================================
#  10. EL MENU PRINCIPAL -- el primer frame que ve el usuario
# ===========================================================================
Test-Case 'menu principal' {
  $entries = @(
    @{ Key='uno';  Label='1. uno';  Info='a'; Note='nota uno' }
    @{ Key='-' }
    @{ Key='dos';  Label='2. dos';  Info='b' }
    @{ Key='quit'; Label='Q. salir'; Info='' }
  )
  Chk 'Enter devuelve la Key de la entrada elegida' ((Invoke-Menu -Entries $entries -Keys @('Enter')) -eq 'uno')
  Chk 'la flecha abajo SALTA el separador' ((Invoke-Menu -Entries $entries -Keys @('DownArrow','Enter')) -eq 'dos')
  Chk 'la flecha arriba da la vuelta al final de la lista' `
      ((Invoke-Menu -Entries $entries -Keys @('UpArrow','Enter')) -eq 'quit')
  Chk 'la flecha abajo da la vuelta al principio' `
      ((Invoke-Menu -Entries $entries -Keys @('DownArrow','DownArrow','DownArrow','Enter')) -eq 'uno')
  Chk 'Escape devuelve $null (salir sin elegir)' `
      ($null -eq (Invoke-Menu -Entries $entries -Keys @('Escape')))
  Chk 'Q devuelve $null' ($null -eq (Invoke-Menu -Entries $entries -Keys @('Q')))
  Chk 'q en minuscula tambien' ($null -eq (Invoke-Menu -Entries $entries -Keys @('q')))
  $ret = Invoke-Menu -Entries $entries -Keys @('Enter')
  Chk 'el menu devuelve UN solo valor (nada se cuela al pipeline)' (@($ret).Count -eq 1) `
      ("-> devolvio " + @($ret).Count + " objetos: el switch del menu principal elegiria cualquier cosa")
}

# ===========================================================================
#  11. CONFIRMACION Y PAUSA -- las dos puertas antes de tocar el disco
# ===========================================================================
Test-Case 'confirmar y pausar' {
  Send-TuiKeys @('S')
  Chk 'S confirma'     ((Show-TuiConfirm 'seguro?' @('linea') 6>$null) -eq $true)
  Send-TuiKeys @('N')
  Chk 'N cancela'      ((Show-TuiConfirm 'seguro?' @('linea') 6>$null) -eq $false)
  Send-TuiKeys @('s')
  Chk 's minuscula tambien confirma' ((Show-TuiConfirm 'seguro?' @() 6>$null) -eq $true)
  # Lo que no es S ni N se ignora y se sigue esperando: si Show-TuiConfirm tomara
  # cualquier tecla, un Enter de mas arrancaria un build de 45 minutos.
  Send-TuiKeys @('DownArrow','X','N')
  Chk 'las teclas que no son S/N se ignoran' ((Show-TuiConfirm 'seguro?' @() 6>$null) -eq $false)

  Send-TuiKeys @('A','Spacebar','Enter')
  Show-TuiPause 'seguir' 6>$null
  Chk 'Show-TuiPause solo vuelve con Enter' ($Global:TuiKeyQueue.Count -eq 0)
}

# El estado global no se deja sucio: si otro script se carga en la misma sesion
# despues de este, la TUI tiene que volver a leer el teclado de verdad.
$Global:TuiKeyProvider  = $null
$Global:TuiSizeProvider = $null

Write-Host ''
if ($script:fail -eq 0) { Write-Host "  TODO OK ($($script:total) tests, 0 fallas)" -ForegroundColor Green }
else { Write-Host "  $($script:fail) FALLAS de $($script:total) tests" -ForegroundColor Red }

# El exit code lo consume scripts\test-e2e.ps1. Se usa la variable, NO el valor de
# retorno de una funcion: cualquier cosa que quede en el pipeline se suma al
# retorno y el exit code termina siendo otro (ya paso con el self-test, que
# reportaba TODO OK y salia con 1).
exit ([int]$script:fail)
