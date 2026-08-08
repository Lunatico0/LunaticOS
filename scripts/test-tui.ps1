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

param(
  # Reescribe los snapshots de referencia con lo que se dibuja AHORA.
  # Se usa a mano y MIRANDO el diff (git diff scripts\snapshots\). Un snapshot que
  # se regenera sin leerlo no prueba nada: pasa a ser un registro de lo que hay,
  # no de lo que se quiere.
  [switch]$UpdateSnapshots
)

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

# Un string -> la lista de nombres de tecla que hay que enviar para tipearlo.
# El espacio va como 'Spacebar' porque es lo que entrega la consola de verdad
# (Key = Spacebar, KeyChar = ' '); el resto de los caracteres viajan sueltos, que
# es la otra forma que entiende ConvertTo-TuiKeyInfo.
function Get-KeysForText([string]$Text) {
  $k = @()
  foreach ($c in $Text.ToCharArray()) {
    if ($c -eq ' ') { $k += 'Spacebar' } else { $k += [string]$c }
  }
  ,$k
}

# Corre Show-TuiInput con teclas inyectadas y devuelve @{ Lines; Ret }.
#
# El filtro de $null NO es defensivo de mas: Show-TuiInput devuelve $null cuando el
# usuario cancela con Esc, y $_.GetType() sobre $null TIRA. Sin el guarda, el test
# de Esc se anotaria como EXCEPCION en vez de medir el retorno. Y el $null tiene que
# SOBREVIVIR al filtro (medido: @($null,'a') | Where { $null -eq $_ -or ... } lo
# conserva), porque "devolvio $null" y "no devolvio nada" son cosas distintas: si
# Show-TuiInput se comiera el retorno, el llamador veria lo mismo que con un Esc.
function Invoke-Input {
  param(
    [string]$Prompt = 'nombre', [string]$Default = '', [int]$MaxLen = 20,
    [scriptblock]$Validate = $null, [scriptblock]$Advise = $null,
    [string[]]$Lines = @(), [string[]]$Keys
  )
  Send-TuiKeys $Keys
  # Splatting para no pasar -Validate/-Advise en $null cuando el test no los usa:
  # asi el camino "sin validador" se ejerce de verdad.
  $p = @{ Title = 'test'; Prompt = $Prompt; Default = $Default; MaxLen = $MaxLen; Lines = $Lines }
  if ($Validate) { $p.Validate = $Validate }
  if ($Advise)   { $p.Advise   = $Advise }
  $raw = @(Show-TuiInput @p 6>&1)
  $inf = 'System.Management.Automation.InformationRecord'
  @{
    Lines = @($raw | Where-Object { ($null -ne $_) -and ($_.GetType().FullName -eq $inf) } |
                     ForEach-Object { "$($_.MessageData.Message)" })
    Ret   = @($raw | Where-Object { ($null -eq $_) -or ($_.GetType().FullName -ne $inf) })
  }
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
#  5-bis. LOS [BLINDADO] (Locked) NO SE PUEDEN MARCAR
#
#  POR QUE ESTE TEST EXISTE -- bug real, medido el 2026-08-08:
#  la checklist SI dejaba marcar un appx blindado. El usuario apretaba ESPACIO
#  sobre Microsoft.DesktopAppInstaller (winget), veia [x], el contador subia de
#  18 a 19, volvia al menu y Show-MainMenu lo borraba del perfil en silencio.
#
#  Lo grave no es el bug, es que la intencion estaba escrita en DOS lugares y
#  no implementada en ninguno:
#    - la nota del menu prometia "pero no se pueden marcar"
#    - el comentario del case 'appx' decia "los blindados no entran a la lista
#      editable"... y abajo pasaba -Items ($editables + $locked)
#  Separaba las dos listas en variables distintas y las volvia a concatenar.
#
#  Una guarda que la UI puede pasar por arriba no es una guarda. Y la de AppxKeep
#  protege winget, la Store y la seguridad.
# ===========================================================================
Test-Case 'items Locked (los [BLINDADO])' {
  $items = @(
    @{ Key='libre1'; Name='libre uno';  Rec=$true;  Cat='bloat' }
    @{ Key='libre2'; Name='libre dos';  Rec=$false; Cat='zona gris' }
    @{ Key='blind1'; Name='blindado A'; Rec=$false; Cat='BLINDADO'; Locked=$true }
    @{ Key='blind2'; Name='blindado B'; Rec=$false; Cat='BLINDADO'; Locked=$true }
  )
  $sel = [ordered]@{}
  foreach ($i in $items) { $sel[$i.Key] = [bool]$i.Rec }

  # --- ESPACIO sobre un Locked no hace nada ---
  $r = Invoke-Checklist -Items $items -Selected $sel -Keys @('DownArrow','DownArrow','Spacebar','Enter')
  Chk 'ESPACIO sobre un Locked NO lo marca' (-not $sel['blind1'])
  Chk 'y el item libre de al lado sigue como estaba' ($sel['libre1'] -eq $true)

  # --- Se DIBUJA distinto: [-] y no [ ] ---
  $lineaBlind = @($r.Lines | Where-Object { $_ -match 'blindado A' })[-1]
  Chk 'un Locked se dibuja con [-], no con [ ]' ($lineaBlind -match '\[-\]') ("-> [" + "$lineaBlind".TrimEnd() + "]")
  Chk 'y no se dibuja como marcado [x]' ($lineaBlind -notmatch '\[x\]')

  # --- 'A' todos NO los marca ---
  foreach ($i in $items) { $sel[$i.Key] = $false }
  Invoke-Checklist -Items $items -Selected $sel -Keys @('A','Enter') | Out-Null
  Chk "'A' (todos) NO marca los Locked" ((-not $sel['blind1']) -and (-not $sel['blind2'])) `
      ("-> blind1=" + $sel['blind1'] + " blind2=" + $sel['blind2'] + ": una guarda que 'todos' pasa por arriba no es guarda")
  Chk "y 'A' SI marca los libres" (($sel['libre1'] -eq $true) -and ($sel['libre2'] -eq $true))

  # --- 'R' recomendados tampoco ---
  foreach ($i in $items) { $sel[$i.Key] = $false }
  Invoke-Checklist -Items $items -Selected $sel -Keys @('R','Enter') | Out-Null
  Chk "'R' (recomendados) NO marca los Locked" (-not $sel['blind1'])
  Chk "y 'R' SI marca el recomendado libre" ($sel['libre1'] -eq $true)

  # --- 'N' ninguno no los toca (ya estan en false, pero no debe escribirlos) ---
  $sel['blind1'] = $true   # se fuerza a mano, como si viniera de un perfil viejo
  Invoke-Checklist -Items $items -Selected $sel -Keys @('N','Enter') | Out-Null
  Chk "'N' (ninguno) no toca los Locked (los deja como estaban)" ($sel['blind1'] -eq $true) `
      '-> N no debe escribir sobre un Locked: el menu es el que limpia el perfil'

  # --- El CONTADOR no puede subir por un Locked ---
  foreach ($i in $items) { $sel[$i.Key] = $false }
  $r2 = Invoke-Checklist -Items $items -Selected $sel -Keys @('DownArrow','DownArrow','Spacebar','Enter')
  $cont = @($r2.Lines | Where-Object { $_ -match 'seleccionados' })
  Chk 'el contador NO sube al apretar ESPACIO sobre un Locked' `
      (("$($cont[0])" -replace '\s','') -eq ("$($cont[-1])" -replace '\s','')) `
      ("-> primero: " + "$($cont[0])".Trim() + " | ultimo: " + "$($cont[-1])".Trim())
}

# ===========================================================================
#  5-ter. GOLDEN SNAPSHOTS -- el frame COMPLETO, con COLOR
#
#  POR QUE HACEN FALTA si ya hay 200 tests: los otros tests verifican
#  PROPIEDADES ("el footer esta", "el ancho no desborda", "R deja los
#  recomendados"). Un snapshot verifica la PANTALLA. Es la unica forma de que
#  falle algo que nadie penso en preguntar: un separador que cambia de color,
#  el cursor que deja de resaltarse, una columna que se corre dos espacios, un
#  [x] que aparece donde iba un [-].
#
#  Y POR QUE INCLUYEN EL COLOR: Write-Host devuelve un HostInformationMessage
#  con ForegroundColor, y hasta el 2026-08-08 TODOS los tests del repo leian
#  solo .Message y tiraban el color. En esta TUI el color ES informacion:
#  Yellow = donde estas parado, Green = marcado, DarkGray = no se toca,
#  Cyan = la nota. Un bug de color no lo veia ningun test.
#
#  Y POR QUE LOS ITEMS SON SINTETICOS Y NO EL CATALOGO REAL: si el snapshot
#  dependiera de $ServicesDisable, agregar un servicio lo romperia, y un
#  snapshot que se rompe en cada cambio de config se regenera sin mirarlo.
#  Con items fijos, el snapshot solo cambia cuando cambia el DIBUJO -- que es
#  justo lo que se quiere vigilar. Los catalogos reales ya los cubre el
#  -SelfTest de LunaticOS.ps1 (notas y legends que entren en pantalla).
# ===========================================================================
$script:SnapDir = Join-Path $PSScriptRoot 'snapshots'

function Get-FrameConColor($raw) {
  @($raw | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } |
           ForEach-Object {
             $m = $_.MessageData
             '{0,-10} | {1}' -f "$($m.ForegroundColor)", "$($m.Message)".TrimEnd()
           })
}

function Test-Snapshot([string]$Nombre, [string[]]$Actual) {
  if (-not (Test-Path $script:SnapDir)) { New-Item -ItemType Directory -Path $script:SnapDir -Force | Out-Null }
  $ruta = Join-Path $script:SnapDir "$Nombre.txt"

  if ($UpdateSnapshots -or -not (Test-Path $ruta)) {
    $Actual | Set-Content $ruta -Encoding UTF8
    $verbo = if ($UpdateSnapshots) { 'REESCRITO' } else { 'CREADO' }
    Chk "snapshot '$Nombre' $verbo (revisa el diff antes de commitear)" $true
    return
  }

  $esperado = @(Get-Content $ruta -Encoding UTF8)
  if ($esperado.Count -ne $Actual.Count) {
    Chk "snapshot '$Nombre' coincide" $false `
        ("-> el frame tiene $($Actual.Count) lineas y el snapshot $($esperado.Count)")
    return
  }
  for ($i = 0; $i -lt $esperado.Count; $i++) {
    if ($esperado[$i] -ne $Actual[$i]) {
      Chk "snapshot '$Nombre' coincide" $false `
          ("-> linea $($i+1):`n         esperado: [" + $esperado[$i] + "]`n         actual  : [" + $Actual[$i] + "]")
      return
    }
  }
  Chk "snapshot '$Nombre' coincide (frame de $($Actual.Count) lineas, con color)" $true
}

Test-Case 'golden snapshots' {
  $Global:TuiSizeProvider = { @{ Width = 120; Height = 40 } }
  try {
    # --- Checklist: un item marcado, uno sin marcar, uno recomendado y un Locked ---
    $items = @(
      @{ Key='a'; Name='marcado y recomendado';    Rec=$true;  Cat='bloat';     Note='Nota corta de una linea.' }
      @{ Key='b'; Name='sin marcar';               Rec=$false; Cat='zona gris'; Note='Otra nota.' }
      @{ Key='c'; Name='blindado, no se toca';     Rec=$false; Cat='BLINDADO'; Locked=$true; Note='BLINDADO: sacarlo rompe algo.' }
    )
    $sel = [ordered]@{ a = $true; b = $false; c = $false }
    Send-TuiKeys @('Escape')
    $raw = @(Show-TuiChecklist -Title 'snapshot de checklist' -Items $items -Selected $sel `
             -Legend 'marcado = se quita' 6>&1)
    Test-Snapshot 'checklist' (Get-FrameConColor $raw)

    # --- Menu principal, con banner y con separadores ---
    Send-TuiKeys @('Q')
    $raw2 = @(Show-TuiMenu -Subtitle 'snapshot de menu' -Banner @(
                'primera linea del banner'
                'segunda linea del banner'
              ) -Entries @(
                @{ Key='uno';  Label='1. opcion uno'; Info='3 marcadas'; Note='Nota de la opcion uno.' }
                @{ Key='dos';  Label='2. opcion dos'; Info='0 marcadas'; Note='Nota de la opcion dos.' }
                @{ Key='-' }
                @{ Key='gen';  Label='G. ACCION PRINCIPAL'; Info='~45 min'; Accent=$true; Note='La accion con Accent.' }
                @{ Key='-' }
                @{ Key='quit'; Label='Q. Salir'; Info='descarta'; Note='Sale sin guardar.' }
              ) 6>&1)
    Test-Snapshot 'menu' (Get-FrameConColor $raw2)

    # --- Lista vacia: el caso que parece un bug si no dice nada ---
    Send-TuiKeys @('Escape')
    $raw3 = @(Show-TuiChecklist -Title 'snapshot de lista vacia' -Items @() `
              -Selected ([ordered]@{}) -Legend 'sin items' 6>&1)
    Test-Snapshot 'checklist-vacia' (Get-FrameConColor $raw3)
  }
  finally { $Global:TuiSizeProvider = $null }
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

  # --- ATAJOS POR LA LETRA DEL LABEL ---
  # Bug real, medido el 2026-08-08: los labels dicen "1.", "G. GENERAR", "S. Guardar"
  # -- prometen un atajo -- y SOLO Q funcionaba. Se descubrio manejando la TUI con
  # teclas inyectadas para armar un perfil: se mando 'S' y el menu la ignoro.
  $conAtajos = @(
    @{ Key='appx'; Label='1. Apps preinstaladas'; Info='' }
    @{ Key='svc';  Label='2. Servicios';          Info='' }
    @{ Key='-' }
    @{ Key='gen';  Label='G. GENERAR LA ISO';     Info=''; Accent=$true }
    @{ Key='save'; Label='S. Guardar y salir';    Info='' }
    @{ Key='quit'; Label='Q. Salir sin guardar';  Info='' }
  )
  Chk "'1' elige la primera entrada sin navegar" ((Invoke-Menu -Entries $conAtajos -Keys @('1')) -eq 'appx')
  Chk "'2' elige la segunda"                     ((Invoke-Menu -Entries $conAtajos -Keys @('2')) -eq 'svc')
  Chk "'G' elige GENERAR"                        ((Invoke-Menu -Entries $conAtajos -Keys @('G')) -eq 'gen')
  Chk "'g' en minuscula tambien"                 ((Invoke-Menu -Entries $conAtajos -Keys @('g')) -eq 'gen')
  Chk "'S' elige Guardar"                        ((Invoke-Menu -Entries $conAtajos -Keys @('S')) -eq 'save')
  Chk "'Q' sigue devolviendo `$null (no 'quit')" ($null -eq (Invoke-Menu -Entries $conAtajos -Keys @('Q'))) `
      '-> Q ya devolvia $null antes de los atajos; el MAIN trata $null y quit igual, pero no se cambia'
  Chk 'una tecla sin entrada que matchee se IGNORA (no elige nada al azar)' `
      ((Invoke-Menu -Entries $conAtajos -Keys @('Z','Enter')) -eq 'appx') `
      '-> Z no matchea ninguna, el menu sigue esperando y el Enter elige donde estaba el cursor'
  Chk 'el atajo NO se confunde con un separador' `
      ((Invoke-Menu -Entries $conAtajos -Keys @('-','Enter')) -eq 'appx')
}

# ===========================================================================
#  10-bis. EL BANNER DEL MENU -- y por que se apaga en consola baja
#
#  El banner existe porque el menu no decia lo unico que hay que saber para
#  usarlo: que la seleccion YA viene con el perfil recomendado y que con G
#  alcanza. Sin eso, el que abre la TUI por primera vez cree que arranca de
#  cero y se pone a marcar 200 items.
#
#  Y se apaga en consola baja por una razon MEDIDA, no por prolijidad: este
#  menu dibuja TODAS sus entradas (no pagina como las checklists), asi que ya
#  usaba el presupuesto completo de Resolve-TuiLayout -- 15 lineas de chrome
#  + 14 de contenido = 29. Tres lineas mas empujan el FOOTER fuera de
#  pantalla, y el footer es el unico lugar donde dice como salir.
# ===========================================================================
Test-Case 'banner del menu principal' {
  # Menu del tamano REAL del de LunaticOS.ps1: 12 entradas, 2 separadores.
  $full = @(
    @{ Key='appx';  Label='1. Apps preinstaladas a quitar';   Info='18 marcadas'; Note='n' }
    @{ Key='svc';   Label='2. Servicios a deshabilitar';      Info='42 marcados'; Note='n' }
    @{ Key='feat';  Label='3. Features y capabilities';       Info='18 marcadas'; Note='n' }
    @{ Key='flags'; Label='4. Opciones del sistema';          Info='7 activas';   Note='n' }
    @{ Key='pers';  Label='5. Personalizacion (tema, color)'; Info='4 marcadas';  Note='n' }
    @{ Key='apps';  Label='6. Programas a instalar';          Info='12 marcados'; Note='n' }
    @{ Key='cuenta';Label='7. Cuenta de usuario';             Info="crear 'pato'";Note='n' }
    @{ Key='-' }
    @{ Key='gen';   Label='G. GENERAR LA ISO (guarda el perfil)'; Info='~45-60 min'; Accent=$true; Note='n' }
    @{ Key='save';  Label='S. Guardar perfil y salir';        Info='sin generar';  Note='n' }
    @{ Key='-' }
    @{ Key='quit';  Label='Q. Salir sin guardar';             Info='descarta';     Note='n' }
  )
  $banner = @('linea uno del banner', 'linea dos', 'linea tres')

  # Dibuja el menu con un tamano de consola simulado y devuelve las lineas.
  #
  # OJO con el filtro: se sale del menu con Q, y Show-TuiMenu devuelve $null en ese
  # caso. Un `$_.GetType()` sobre ese $null TIRA -- y el test se anota como EXCEPCION
  # en vez de medir el frame. Es la misma trampa que Invoke-Input ya documenta.
  # `-is` no explota con $null: devuelve $false y sigue.
  function Get-MenuFrame([int]$H, [int]$W = 120) {
    $Global:TuiSizeProvider = [scriptblock]::Create("@{ Width = $W; Height = $H }")
    try {
      Send-TuiKeys @('Q')
      $raw = @(Show-TuiMenu -Entries $full -Subtitle 'test' -Banner $banner 6>&1)
      @($raw | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } |
               ForEach-Object { "$($_.MessageData.Message)" })
    } finally { $Global:TuiSizeProvider = $null }
  }

  $alto  = Get-MenuFrame 40
  $justo = Get-MenuFrame 27
  $bajo  = Get-MenuFrame 26
  $min   = Get-MenuFrame 24

  $tieneBanner = { param($f) [bool](@($f | Where-Object { $_ -match 'linea uno del banner' }).Count) }
  $tieneFooter = { param($f) [bool](@($f | Where-Object { $_ -match 'flechas mover' }).Count) }

  Chk 'con consola alta el banner se dibuja' (& $tieneBanner $alto)
  Chk 'las TRES lineas del banner se dibujan, no solo la primera' `
      ((@($alto | Where-Object { $_ -match 'linea (uno del banner|dos|tres)' }).Count) -eq 3)
  Chk 'a 27 filas el banner todavia entra' (& $tieneBanner $justo)
  Chk 'a 26 filas el banner SE APAGA' (-not (& $tieneBanner $bajo)) `
      ("-> dibujo " + $bajo.Count + " lineas en 26 filas: el footer se iria de pantalla")
  Chk 'a 24 filas tampoco se dibuja' (-not (& $tieneBanner $min))

  # Lo que el banner NUNCA puede costar: el footer dice como salir.
  Chk 'el footer sobrevive con consola alta'  (& $tieneFooter $alto)
  Chk 'el footer sobrevive a 27 filas'        (& $tieneFooter $justo)
  Chk 'el footer sobrevive a 26 filas'        (& $tieneFooter $bajo)
  Chk 'el footer sobrevive a 24 filas'        (& $tieneFooter $min)

  # El frame entero tiene que entrar en la consola, en las cuatro medidas.
  Chk 'el frame entra en 27 filas' ($justo.Count -le 27) ("-> " + $justo.Count + " lineas")
  Chk 'el frame entra en 26 filas' ($bajo.Count  -le 26) ("-> " + $bajo.Count  + " lineas")
  Chk 'el frame entra en 24 filas' ($min.Count   -le 24) ("-> " + $min.Count   + " lineas")

  # Sin -Banner el menu se dibuja igual que siempre: el parametro es opcional.
  Send-TuiKeys @('Enter')
  $sinBanner = Show-TuiMenu -Entries $full -Subtitle 'test' 6>$null
  Chk 'sin -Banner el menu sigue funcionando (parametro opcional)' ($sinBanner -eq 'appx')

  # El ancho no lo puede romper una linea larga de banner: Write-TuiLine recorta.
  $Global:TuiSizeProvider = [scriptblock]::Create('@{ Width = 120; Height = 40 }')
  try {
    Send-TuiKeys @('Q')
    $raw = @(Show-TuiMenu -Entries $full -Subtitle 'test' -Banner @('x' * 200) 6>&1)
    $lineas = @($raw | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } |
                       ForEach-Object { "$($_.MessageData.Message)" })
    Chk 'una linea de banner mas larga que el ancho se RECORTA, no desborda' `
        ((Get-MaxLineLength $lineas) -le 78) ("-> ancho maximo " + (Get-MaxLineLength $lineas))
  } finally { $Global:TuiSizeProvider = $null }
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

# ===========================================================================
#  12. Show-TuiInput -- EL UNICO LUGAR DONDE EL USUARIO ESCRIBE
#
#  Lo que se tipea aca termina en <Name> del autounattend, o sea en el nombre de la
#  cuenta y en la CARPETA del perfil, que no se cambia mas (docs\contrato-cuenta-
#  usuario.md). Un campo de texto que no se puede testear sin humano es un campo
#  que en la practica no se testea nunca: por eso lee con Get-TuiKey y no con
#  Read-Host.
# ===========================================================================
Test-Case 'Show-TuiInput: tipear y confirmar' {
  $r = Invoke-Input -Default 'pato' -Keys ((Get-KeysForText 'juan') + @('Enter'))
  Chk 'tipear "juan" y Enter devuelve "juan"' ($r.Ret.Count -eq 1 -and $r.Ret[0] -eq 'juan') `
      ("-> devolvio: [" + ($r.Ret -join '|') + "]")
  # Update-TuiLayout devuelve un hashtable POR FRAME: si se llamara pelado, el
  # retorno de esta funcion serian 6 hashtables y un string, y el llamador se
  # guardaria cualquier cosa en el perfil. Ya paso con el exit code del self-test.
  Chk 'el retorno es UN unico string (nada se cuela al pipeline)' `
      ($r.Ret.Count -eq 1 -and $r.Ret[0] -is [string]) ("-> devolvio " + $r.Ret.Count + " objetos")
  Chk 'y el campo se dibuja con la etiqueta, el texto y el cursor' `
      (@($r.Lines | Where-Object { $_ -match '^\s+nombre: juan_' }).Count -ge 1) `
      '-> el usuario no ve lo que esta escribiendo'

  # Digitos y simbolos: el filtro de imprimibles no puede dejar pasar solo letras.
  $r = Invoke-Input -Keys ((Get-KeysForText 'pato-01.x') + @('Enter'))
  Chk 'los digitos y los simbolos permitidos entran' ($r.Ret[0] -eq 'pato-01.x') ("-> [" + $r.Ret[0] + "]")

  # Las teclas SIN KeyChar (llegan con NUL) y las de control no pueden insertar
  # basura invisible en un nombre que despues no crea la cuenta.
  $r = Invoke-Input -Keys @('DownArrow','Tab','F1','Delete','UpArrow','a','Enter')
  Chk 'las flechas, Tab, F1 y Delete no insertan nada' ($r.Ret[0] -eq 'a') `
      ("-> [" + $r.Ret[0] + "] largo " + $r.Ret[0].Length)

  # No-ASCII SI entra: la seccion 4 del contrato dice ADVERTIR, no prohibir. El
  # caracter se construye por codigo porque este archivo tiene que ser ASCII puro.
  $oAcc = [string][char]0xF3
  $r = Invoke-Input -Keys (@('p','a','t') + @($oAcc) + @('n','Enter'))
  Chk 'un caracter no-ASCII (acento) se puede tipear: se advierte, no se prohibe' `
      ($r.Ret[0] -eq ('pat' + $oAcc + 'n')) ("-> [" + $r.Ret[0] + "]")
}

Test-Case 'Show-TuiInput: Backspace' {
  $r = Invoke-Input -Keys ((Get-KeysForText 'juan') + @('Backspace','Enter'))
  Chk 'Backspace borra el ultimo caracter' ($r.Ret[0] -eq 'jua') ("-> [" + $r.Ret[0] + "]")

  $r = Invoke-Input -Keys ((Get-KeysForText 'juan') + @('Backspace','Backspace','Enter'))
  Chk 'dos Backspace borran dos' ($r.Ret[0] -eq 'ju') ("-> [" + $r.Ret[0] + "]")

  # Y despues de borrar se puede seguir escribiendo: si el Substring dejara el
  # string en un estado raro, esto lo caza.
  $r = Invoke-Input -Keys ((Get-KeysForText 'juan') + @('Backspace') + (Get-KeysForText 'na') + @('Enter'))
  Chk 'se puede seguir tipeando despues de borrar' ($r.Ret[0] -eq 'juana') ("-> [" + $r.Ret[0] + "]")

  # Backspace con el campo vacio: Substring(0,-1) TIRA. El guarda es real.
  $r = Invoke-Input -Default 'pato' -Keys @('Backspace','Backspace','Backspace','Enter')
  Chk 'Backspace con el campo vacio no explota (y sigue valiendo el default)' `
      ($r.Ret.Count -eq 1 -and $r.Ret[0] -eq 'pato') ("-> [" + ($r.Ret -join '|') + "]")

  # Borrar TODO vuelve al estado "vacio", con lo que eso implique (default o error).
  $r = Invoke-Input -Default 'pato' -Keys ((Get-KeysForText 'ab') + @('Backspace','Backspace','Enter'))
  Chk 'borrar todo lo tipeado vuelve a "vacio = default"' ($r.Ret[0] -eq 'pato') ("-> [" + $r.Ret[0] + "]")
}

Test-Case 'Show-TuiInput: Escape cancela' {
  $r = Invoke-Input -Default 'pato' -Keys @('Escape')
  Chk 'Escape devuelve $null' ($r.Ret.Count -eq 1 -and $null -eq $r.Ret[0]) `
      ("-> devolvio " + $r.Ret.Count + " objetos: [" + ($r.Ret -join '|') + "]")
  # Lo importante no es "algo falsy": es $null. Un '' pasaria el `if (-not $x)` del
  # llamador igual que $null, pero un string vacio metido en el <Name> del
  # autounattend rompe la creacion de la cuenta en la instalacion.
  Chk 'y NO devuelve un string (ni vacio ni lo tipeado)' ($r.Ret[0] -isnot [string]) `
      ("-> devolvio un " + $(if ($null -eq $r.Ret[0]) { 'null' } else { $r.Ret[0].GetType().Name }))

  $r = Invoke-Input -Default 'pato' -Keys ((Get-KeysForText 'juan') + @('Escape'))
  Chk 'Escape despues de tipear tambien devuelve $null (no lo tipeado)' `
      ($r.Ret.Count -eq 1 -and $null -eq $r.Ret[0]) ("-> [" + ($r.Ret -join '|') + "]")
  Chk 'Escape corta el bucle en el frame (no sigue pidiendo teclas)' ($Global:TuiKeyQueue.Count -eq 0)
}

# ===========================================================================
#  Enter con el campo VACIO -- la decision (b) de Show-TuiInput.
#  Con -Default: devuelve el default (el frame lo anuncia con "(vacio = pato)").
#  Sin -Default: NO confirma, porque la funcion no devuelve '' NUNCA -- un '' es
#  indistinguible de $null para un llamador que escribe `if ($nombre)`.
# ===========================================================================
Test-Case 'Show-TuiInput: Enter con el campo vacio' {
  $r = Invoke-Input -Default 'pato' -Keys @('Enter')
  Chk 'Enter con el campo vacio devuelve el -Default' ($r.Ret[0] -eq 'pato') ("-> [" + $r.Ret[0] + "]")
  Chk 'y el frame avisa que vacio = el default' `
      (@($r.Lines | Where-Object { $_ -match '\(vacio = pato\)' }).Count -ge 1) `
      '-> el usuario no puede saber que le va a pasar si aprieta Enter'

  # SIN default: los dos primeros Enter no tienen que hacer nada. Si confirmaran,
  # la cola se quedaria con teclas sin consumir y el retorno seria ''.
  $r = Invoke-Input -Keys @('Enter','Enter','x','Enter')
  Chk 'sin -Default, Enter con el campo vacio NO confirma' ($r.Ret.Count -eq 1 -and $r.Ret[0] -eq 'x') `
      ("-> devolvio: [" + ($r.Ret -join '|') + "]")
  Chk 'y consumio las dos teclas (no quedo nada en la cola)' ($Global:TuiKeyQueue.Count -eq 0)
  Chk 'y dijo por que no confirma' `
      (@($r.Lines | Where-Object { $_ -match 'ERROR.*no puede quedar vacio' }).Count -ge 1)

  # El default TAMBIEN pasa por -Validate (decision (d)): un default invalido
  # cableado por el llamador se tiene que ver EN LA TUI, no en la instalacion.
  $r = Invoke-Input -Default 'con' -Validate { param($s) Test-WindowsUserName $s -ComputerName 'PC' } `
                    -Keys @('Enter','Enter','p','a','t','o','Enter')
  Chk 'un -Default invalido no se puede confirmar con Enter' ($r.Ret[0] -eq 'pato') `
      ("-> devolvio [" + ($r.Ret -join '|') + "]: el default se colo sin validar")
  Chk 'y se ve el error del default sin haber tipeado nada' `
      (@($r.Lines | Where-Object { $_ -match 'ERROR.*reservado' }).Count -ge 1)
}

Test-Case 'Show-TuiInput: -MaxLen' {
  $r = Invoke-Input -MaxLen 3 -Keys ((Get-KeysForText 'abcdefgh') + @('Enter'))
  Chk '-MaxLen 3 corta en 3 caracteres' ($r.Ret[0] -eq 'abc') `
      ("-> [" + $r.Ret[0] + "] (" + $r.Ret[0].Length + " caracteres)")
  Chk 'y el contador dibuja el limite' (@($r.Lines | Where-Object { $_ -match '\[3/3\]' }).Count -ge 1)

  # Llegar al tope no puede TRABAR el campo: Backspace tiene que seguir andando y
  # despues se puede volver a llenar.
  $r = Invoke-Input -MaxLen 3 -Keys ((Get-KeysForText 'abcdef') + @('Backspace') + (Get-KeysForText 'z') + @('Enter'))
  Chk 'en el tope se puede borrar y volver a escribir' ($r.Ret[0] -eq 'abz') ("-> [" + $r.Ret[0] + "]")

  $r = Invoke-Input -MaxLen 1 -Keys ((Get-KeysForText 'abc') + @('Enter'))
  Chk '-MaxLen 1 deja un solo caracter' ($r.Ret[0] -eq 'a') ("-> [" + $r.Ret[0] + "]")

  # El default 20 no es un numero de adorno: es el limite de la SAM, el mismo que
  # aplica Test-WindowsUserName. Si los dos no coinciden, la TUI deja tipear un
  # nombre que su propio validador rechaza.
  $r = Invoke-Input -Keys ((Get-KeysForText ('a' * 25)) + @('Enter'))
  Chk 'el -MaxLen por default es el limite de la SAM (20)' `
      ($r.Ret[0].Length -eq $script:WinUserNameMaxLen) ("-> dejo tipear " + $r.Ret[0].Length)
  Chk 'y lo que sale del campo con el default pasa la validacion de largo' `
      ($null -eq (Test-WindowsUserName $r.Ret[0] -ComputerName 'PC'))

  # Guardas contra el llamador. Tiran a proposito en la PRIMERA llamada.
  $m = ''
  try { Send-TuiKeys @('Enter'); Show-TuiInput -Title 't' -Prompt 'n' -MaxLen 0 6>$null | Out-Null }
  catch { $m = $_.Exception.Message }
  Chk '-MaxLen 0 TIRA (un campo donde no se puede escribir es un bug del llamador)' `
      ($m -match 'MaxLen') "-> dijo: $m"
  $m = ''
  try { Send-TuiKeys @('Enter'); Show-TuiInput -Title 't' -Prompt 'n' -Default 'demasiado largo' -MaxLen 4 6>$null | Out-Null }
  catch { $m = $_.Exception.Message }
  Chk 'un -Default mas largo que -MaxLen TIRA (el frame prometeria lo que Enter no confirma)' `
      ($m -match 'Default') "-> dijo: $m"
}

# ===========================================================================
#  -Validate BLOQUEA a Enter, -Advise NO. Punto 6 de la seccion 7 del contrato.
# ===========================================================================
Test-Case 'Show-TuiInput: -Validate bloquea a Enter' {
  $val = { param($s) Test-WindowsUserName $s -ComputerName 'PC' }

  # 'pa|to' es invalido: el Enter del medio NO puede confirmar. Se borran los tres
  # ultimos caracteres ('|to') y ahi si.
  $r = Invoke-Input -Validate $val `
                    -Keys ((Get-KeysForText 'pa|to') + @('Enter','Backspace','Backspace','Backspace','Enter'))
  Chk 'un nombre con un caracter prohibido NO se confirma con Enter' `
      ($r.Ret.Count -eq 1 -and $r.Ret[0] -eq 'pa') `
      ("-> devolvio [" + ($r.Ret -join '|') + "]: se confirmo un nombre que Windows rechaza")
  Chk 'y el error se ve EN VIVO debajo del campo, con el caracter culpable' `
      (@($r.Lines | Where-Object { $_ -match 'ERROR.*no acepta estos caracteres.*\|' }).Count -ge 1) `
      '-> el usuario no tiene forma de saber por que Enter no hace nada'

  # Un nombre reservado tampoco pasa.
  $r = Invoke-Input -Validate $val -Keys ((Get-KeysForText 'con') + @('Enter','Escape'))
  Chk 'un nombre reservado (con) tampoco se confirma' ($null -eq $r.Ret[0]) `
      ("-> devolvio [" + ($r.Ret -join '|') + "]")

  # El error tiene que DESAPARECER cuando el nombre se arregla: si quedara pegado,
  # Enter no volveria a funcionar nunca y el usuario se queda encerrado.
  $r = Invoke-Input -Validate $val -Keys ((Get-KeysForText 'con') + @('Enter','x','Enter'))
  Chk 'arreglar el nombre desbloquea a Enter (el error no queda pegado)' ($r.Ret[0] -eq 'conx') `
      ("-> [" + ($r.Ret -join '|') + "]")

  # -Advise NO bloquea: 'juan carlos' es valido, solo merece el aviso de la carpeta.
  $r = Invoke-Input -Validate $val -Advise { param($s) Test-WindowsUserName $s -Advisory } `
                    -Keys ((Get-KeysForText 'juan carlos') + @('Enter'))
  Chk 'un nombre con espacios SI se confirma (el aviso no bloquea)' ($r.Ret[0] -eq 'juan carlos') `
      ("-> devolvio [" + ($r.Ret -join '|') + "]")
  Chk 'y el aviso dice la ruta concreta de la carpeta del perfil' `
      (@($r.Lines | Where-Object { $_ -match 'AVISO' }).Count -ge 1 -and `
       @($r.Lines | Where-Object { $_ -match 'C:\\Users\\juan carlos' }).Count -ge 1) `
      '-> se acepta el nombre sin decir que la carpeta queda asi para siempre'

  # UN AVISO TRUNCADO ES PEOR QUE NINGUNO: parece que la herramienta te dijo algo
  # cuando en realidad se comio el final. Se mide el PEOR caso -- 20 caracteres (el
  # tope), con espacio Y con no-ASCII, o sea el aviso mas largo que se puede
  # generar -- y se exige que entre COMPLETO en las lineas de mensaje del frame.
  # Con 2 lineas de mensaje esto se cortaba (medido); de ahi las 3.
  $peor = ('a' * 9) + ' ' + [string][char]0xF3 + ('b' * 9)
  $esperado = 'AVISO: ' + (Test-WindowsUserName $peor -ComputerName 'PC' -Advisory)
  $r = Invoke-Input -Validate $val -Advise { param($s) Test-WindowsUserName $s -Advisory } `
                    -Keys ((Get-KeysForText $peor) + @('Enter'))
  $frame = ((@($r.Lines) | Select-Object -Last 13) -join ' ') -replace '\s+', ' '
  Chk 'el aviso mas largo posible (20 caracteres, espacio y acento) entra COMPLETO' `
      ($frame -match [regex]::Escape(($esperado -replace '\s+', ' '))) `
      '-> el frame corto el aviso: el usuario ve media advertencia'
  Chk 'y ese nombre igual se confirma (el aviso nunca bloquea)' ($r.Ret[0] -eq $peor)

  # Un validador que TIRA no puede llevarse la TUI puesta a mitad de frame.
  $r = Invoke-Input -Validate { param($s) throw 'boom' } -Keys @('a','Enter','Escape')
  Chk 'un -Validate que TIRA se degrada a error (Enter bloqueado, Esc sigue saliendo)' `
      ($r.Ret.Count -eq 1 -and $null -eq $r.Ret[0]) ("-> [" + ($r.Ret -join '|') + "]")
  Chk 'y el motivo se ve en el frame' `
      (@($r.Lines | Where-Object { $_ -match 'validacion fallo.*boom' }).Count -ge 1)
}

# ===========================================================================
#  El frame del input tambien se adapta a la consola. Volver a cablear 78
#  columnas aca desarmaria el frame en cualquier ventana mas angosta.
# ===========================================================================
Test-Case 'Show-TuiInput: el frame se adapta a la consola' {
  $prev = $Global:TuiSizeProvider
  try {
    $Global:TuiSizeProvider = { @{ Width = 120; Height = 30 } }
    $r = Invoke-Input -Default 'pato' -Keys @('Enter')
    Chk 'con 120x30 el frame del input mide 78 columnas' ((Get-MaxLineLength $r.Lines) -eq 78) `
        ("-> " + (Get-MaxLineLength $r.Lines) + " columnas")

    $Global:TuiSizeProvider = { @{ Width = 46; Height = 24 } }
    $largas = @('una linea de contexto bien larga que no entra de una sola vez en un frame angosto y tiene que wrappear') * 6
    $r = Invoke-Input -Default 'pato' -Lines $largas -Keys @('Enter')
    $ancho = Get-MaxLineLength $r.Lines
    Chk 'con 46 columnas ninguna linea del input pasa de 45' ($ancho -le 45) `
        ("-> la linea mas larga midio " + $ancho + ": hace wrap y parte el frame")
    Chk 'con 24 filas el frame del input entra en 23 lineas (aun con -Lines de sobra)' `
        ($r.Lines.Count -le 23) `
        ("-> dibujo " + $r.Lines.Count + " lineas: el buffer scrollea y el redibujo queda corrido")
    Chk 'y el campo sigue funcionando con la consola chica' ($r.Ret[0] -eq 'pato')
  } finally { $Global:TuiSizeProvider = $prev }
}

# ===========================================================================
#  EL REQUISITO DE FONDO, MEDIDO COMO CLASE: la TUI no puede llamar a Read-Host
#  en NINGUN lugar. No es estilo: Read-Host escribe su propio eco y rompe el frame,
#  y ademas NO pasa por $Global:TuiKeyProvider, o sea que cualquier pedazo de input
#  que lo use deja de ser testeable sin humano -- justo lo que este archivo existe
#  para evitar. Un test por funcion se olvidaria de la funcion que se agregue
#  manana; esto cubre el archivo entero.
#
#  Se busca por AST y NO por texto: los comentarios de tui.ps1 nombran a Read-Host
#  cinco veces a proposito (para explicar por que no se usa), asi que un
#  Select-String daria falso positivo y el test terminaria borrado por molesto.
# ===========================================================================
Test-Case 'la TUI no llama a Read-Host en ningun lugar' {
  $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            "$PSScriptRoot\tui.ps1", [ref]$null, [ref]$null)
  $cmds = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object { "$($_.GetCommandName())" })
  Chk 'tui.ps1 no invoca Read-Host (todo el input entra por Get-TuiKey)' `
      (@($cmds | Where-Object { $_ -eq 'Read-Host' }).Count -eq 0) `
      '-> rompe el frame y no pasa por $TuiKeyProvider: input no testeable'
  # Y el contra-chequeo, para que el de arriba no de verde por vacio (un AST mal
  # leido devolveria cero comandos de todo tipo y "cero Read-Host" seria mentira).
  Chk 'y el AST si ve las llamadas a Get-TuiKey (el chequeo de arriba mide algo)' `
      (@($cmds | Where-Object { $_ -eq 'Get-TuiKey' }).Count -ge 4) `
      ("-> encontro " + @($cmds | Where-Object { $_ -eq 'Get-TuiKey' }).Count + " llamadas")
}

# Un campo de texto que espera el teclado cuando la cola se vacia es un test
# colgado, y a un test colgado no lo vuelve a correr nadie. Tiene que TIRAR, igual
# que el resto de la TUI.
Test-Case 'Show-TuiInput: con la cola vacia TIRA, no se cuelga' {
  $m = ''
  try { Send-TuiKeys @('p','a'); Show-TuiInput -Title 't' -Prompt 'nombre' 6>$null | Out-Null }
  catch { $m = $_.Exception.Message }
  Chk 'sin Enter ni Escape al final, Show-TuiInput TIRA' ($m -match 'cola de teclas') "-> dijo: $m"
}

# ===========================================================================
#  13. Test-WindowsUserName -- CADA REGLA DE LA SECCION 4 DEL CONTRATO
#
#  Un nombre invalido no falla en la TUI ni al generar la ISO: falla al CREAR LA
#  CUENTA durante la instalacion, 40 minutos despues, y el OOBE queda pidiendo
#  cuenta Microsoft (ya no hay bypassnro.cmd en 24H2/25H2).
#
#  -ComputerName se pasa SIEMPRE explicito: con el default ($env:COMPUTERNAME) el
#  resultado dependeria de como se llama la maquina que corre los tests.
# ===========================================================================
Test-Case 'Test-WindowsUserName: nombres validos' {
  foreach ($n in @('pato', 'p', 'Juan', 'juan.carlos', 'usuario_1', 'a-b', ('a' * 20), 'COM0', 'LPT0', 'CONS', 'pa to')) {
    Chk "'$n' es valido" ($null -eq (Test-WindowsUserName $n -ComputerName 'PC')) `
        ("-> lo rechazo: " + (Test-WindowsUserName $n -ComputerName 'PC'))
  }
  # 'COM0'/'LPT0'/'CONS' no son reservados: el test mide la CLASE (la lista exacta)
  # y no "algo que empieza con COM", que rechazaria nombres perfectamente validos.
}

Test-Case 'Test-WindowsUserName: largo (limite de la SAM)' {
  Chk 'vacio se rechaza' ($null -ne (Test-WindowsUserName '' -ComputerName 'PC'))
  Chk '$null se rechaza como vacio (puede venir de un perfil.json a mano)' `
      ($null -ne (Test-WindowsUserName $null -ComputerName 'PC'))
  Chk '20 caracteres justos pasan' ($null -eq (Test-WindowsUserName ('a' * 20) -ComputerName 'PC'))
  $e = Test-WindowsUserName ('a' * 21) -ComputerName 'PC'
  Chk '21 caracteres se rechazan' ($null -ne $e) '-> un nombre mas largo que la SAM no crea la cuenta'
  Chk 'y el mensaje dice el limite y el largo real' ($e -match '20' -and $e -match '21') "-> dijo: $e"
}

Test-Case 'Test-WindowsUserName: caracteres prohibidos' {
  # Los 15 de la tabla de la seccion 4, uno por uno: si el chequeo se hiciera con un
  # regex mal escapado, alguno se colaria y este bucle lo caza.
  $prohibidos = @('"', '/', '\', '[', ']', ':', ';', '|', '=', ',', '+', '*', '?', '<', '>')
  $colados = @()
  foreach ($c in $prohibidos) {
    if ($null -eq (Test-WindowsUserName ('pa' + $c + 'to') -ComputerName 'PC')) { $colados += $c }
  }
  Chk 'los 15 caracteres prohibidos se rechazan' ($colados.Count -eq 0) `
      ("-> se colaron: " + ($colados -join ' '))
  $e = Test-WindowsUserName 'pa|to:x' -ComputerName 'PC'
  Chk 'el mensaje junta TODOS los caracteres malos (no manda al usuario dos veces)' `
      ($e -match '\|' -and $e -match ':') "-> dijo: $e"
  Chk 'un tab (que puede venir de un perfil editado a mano) se rechaza' `
      ($null -ne (Test-WindowsUserName ("pa" + [char]9 + "to") -ComputerName 'PC'))
}

Test-Case 'Test-WindowsUserName: puntos y espacios en los bordes' {
  Chk 'terminar en punto se rechaza' ($null -ne (Test-WindowsUserName 'pato.' -ComputerName 'PC'))
  Chk 'un punto EN EL MEDIO es valido' ($null -eq (Test-WindowsUserName 'pa.to' -ComputerName 'PC'))
  Chk 'solo puntos se rechaza' ($null -ne (Test-WindowsUserName '...' -ComputerName 'PC'))
  Chk 'solo espacios se rechaza' ($null -ne (Test-WindowsUserName '   ' -ComputerName 'PC'))
  Chk 'puntos y espacios mezclados se rechaza' ($null -ne (Test-WindowsUserName '. .' -ComputerName 'PC'))
  Chk 'empezar con espacio se rechaza' ($null -ne (Test-WindowsUserName ' pato' -ComputerName 'PC'))
  Chk 'terminar con espacio se rechaza' ($null -ne (Test-WindowsUserName 'pato ' -ComputerName 'PC'))
  Chk 'un espacio EN EL MEDIO es valido (solo se advierte)' `
      ($null -eq (Test-WindowsUserName 'juan carlos' -ComputerName 'PC'))
}

Test-Case 'Test-WindowsUserName: reservados y cuentas del sistema' {
  $reservados = @('CON','PRN','AUX','NUL','COM1','COM9','LPT1','LPT9')
  $colados = @()
  foreach ($n in $reservados) {
    if ($null -eq (Test-WindowsUserName $n -ComputerName 'PC')) { $colados += $n }
  }
  Chk 'los nombres de dispositivo reservados se rechazan' ($colados.Count -eq 0) `
      ("-> se colaron: " + ($colados -join ' '))
  # La caja no salva a nadie: Windows compara sin distinguir mayusculas.
  Chk "'con' en minuscula tambien se rechaza" ($null -ne (Test-WindowsUserName 'con' -ComputerName 'PC'))
  Chk "'Com1' mezclado tambien" ($null -ne (Test-WindowsUserName 'Com1' -ComputerName 'PC'))

  $sistema = @('Administrator','Guest','DefaultAccount','WDAGUtilityAccount','SYSTEM')
  $colados = @()
  foreach ($n in $sistema) {
    if ($null -eq (Test-WindowsUserName $n -ComputerName 'PC')) { $colados += $n }
  }
  Chk 'las cuentas que Windows ya trae creadas se rechazan' ($colados.Count -eq 0) `
      ("-> se colaron: " + ($colados -join ' '))
  Chk "'administrator' en minuscula tambien" ($null -ne (Test-WindowsUserName 'administrator' -ComputerName 'PC'))
  Chk "'Administrador' (el de un Windows en espanol) NO esta en la lista y pasa" `
      ($null -eq (Test-WindowsUserName 'Administrador' -ComputerName 'PC')) `
      '-> si se agrega, que sea a proposito y documentado'
}

Test-Case 'Test-WindowsUserName: igual al nombre del equipo' {
  $e = Test-WindowsUserName 'MIPC' -ComputerName 'MIPC'
  Chk 'el nombre del equipo se rechaza' ($null -ne $e)
  Chk 'y el mensaje dice que choca con el equipo' ($e -match 'equipo') "-> dijo: $e"
  Chk 'la comparacion no distingue mayusculas' ($null -ne (Test-WindowsUserName 'mipc' -ComputerName 'MIPC'))
  Chk 'un nombre parecido pero distinto pasa' ($null -eq (Test-WindowsUserName 'MIPC2' -ComputerName 'MIPC'))
  # El default de -ComputerName tiene que ser el equipo REAL: si fuera '', la regla
  # existiria en la firma y no se aplicaria nunca.
  Chk 'por default se compara contra $env:COMPUTERNAME' `
      ($null -ne (Test-WindowsUserName "$env:COMPUTERNAME")) `
      ("-> no rechazo '" + $env:COMPUTERNAME + "', que es el nombre de esta maquina")
  Chk "y con -ComputerName '' la regla se apaga (para un caso donde no se sabe)" `
      ($null -eq (Test-WindowsUserName 'MIPC' -ComputerName ''))
}

# ===========================================================================
#  "Valido pero con advertencia" -- el matiz de la seccion 4: los espacios y los
#  no-ASCII NO se prohiben, se avisan, porque la CARPETA del perfil queda con ese
#  nombre para siempre. El aviso viaja por -Advisory: mismo tipo de retorno
#  ($null o string), misma lista de reglas, y el que llama elige el canal.
# ===========================================================================
Test-Case 'Test-WindowsUserName -Advisory' {
  $conEspacio = Test-WindowsUserName 'juan carlos' -ComputerName 'PC' -Advisory
  Chk 'un nombre con espacios es VALIDO y ademas tiene aviso' `
      (($null -eq (Test-WindowsUserName 'juan carlos' -ComputerName 'PC')) -and ($null -ne $conEspacio))
  Chk 'y el aviso dice la ruta exacta de la carpeta del perfil' `
      ($conEspacio -match 'C:\\Users\\juan carlos') "-> dijo: $conEspacio"

  $conAcento = 'pat' + [char]0xF3 + 'n'
  Chk 'un nombre con acento es VALIDO y tiene aviso' `
      (($null -eq (Test-WindowsUserName $conAcento -ComputerName 'PC')) -and `
       ($null -ne (Test-WindowsUserName $conAcento -ComputerName 'PC' -Advisory)))
  Chk 'un nombre ASCII sin espacios no tiene aviso' `
      ($null -eq (Test-WindowsUserName 'pato' -ComputerName 'PC' -Advisory))
  # Amontonar un aviso arriba de un error tapa el motivo real por el que Enter no
  # confirma, y el error ya bloquea.
  Chk 'un nombre INVALIDO no devuelve aviso (el error ya bloquea)' `
      ($null -eq (Test-WindowsUserName 'pa|to carlos' -ComputerName 'PC' -Advisory))
  # Los dos canales son la MISMA funcion: no hay dos listas de reglas que se puedan
  # desincronizar. Se verifica que -Advisory no relaje ninguna.
  $desincronizados = @()
  foreach ($n in @('', 'con', 'pato.', ' pato', 'Guest', ('a' * 21), 'pa|to')) {
    if ($null -ne (Test-WindowsUserName $n -ComputerName 'PC' -Advisory)) { $desincronizados += $n }
  }
  Chk '-Advisory no deja pasar nada que el canal de error rechace' ($desincronizados.Count -eq 0) `
      ("-> devolvio aviso para: " + ($desincronizados -join ', '))
}

# El objetivo de todo esto: la funcion se puede enchufar tal cual en la TUI.
Test-Case 'Test-WindowsUserName sirve tal cual como -Validate' {
  $val = { param($s) Test-WindowsUserName $s -ComputerName 'PC' }
  $r = Invoke-Input -Default 'pato' -Validate $val -Advise { param($s) Test-WindowsUserName $s -Advisory } `
                    -Keys @('Enter')
  Chk 'el default "pato" pasa la validacion real y se confirma' ($r.Ret[0] -eq 'pato') `
      ("-> [" + ($r.Ret -join '|') + "]")
  Chk 'y sin aviso, el frame no dibuja ningun AVISO' `
      (@($r.Lines | Where-Object { $_ -match 'AVISO' }).Count -eq 0)

  # 21 caracteres no se pueden ni tipear (MaxLen) Y ADEMAS el validador los
  # rechazaria: las dos defensas puestas, no una sola.
  $r = Invoke-Input -Validate $val -Keys ((Get-KeysForText ('a' * 21)) + @('Enter'))
  Chk 'el campo corta en 20 y lo que sale es valido' `
      (($r.Ret[0].Length -eq 20) -and ($null -eq (& $val $r.Ret[0]))) ("-> [" + $r.Ret[0] + "]")
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
