#requires -Version 5.1
<#
  test-e2e.ps1 -- El runner del E2E: de la TUI al SO CORRIENDO, con un comando.

  Contrato: docs\testing-e2e.md, seccion 4 (el runner) y seccion 5 (matriz de perfiles).

  OCHO CAPAS, en este orden y con este criterio:

      1. -SelfTest + guardas de los autounattend   rapido: si esto falla, no gastes 35 min
      2. tests de TUI                              teclas inyectadas, sin humano
      3. build con el perfil de test                ~9 min si el WIM ya esta exportado
      4. VM: reset + boot                          autounattend-test = CERO clics
      5. esperar la instalacion                    ~25 min, con timeout y evidencia
      6. verify-live.ps1                           SO corriendo, PowerShell Direct
      7. test-vm.ps1 -Verify                       disco instalado, VM apagada
      8. reporte final                             una linea por capa

  ===========================================================================
  LAS TRES REGLAS QUE GOBIERNAN ESTE ARCHIVO

  1) "SIN MEDIR" ES UN RESULTADO. "PASA" sin evidencia ya costo dos sesiones en
     este repo. Cada capa reporta uno de cinco estados y NUNCA se redondea para
     arriba:
         PASA        se midio y salio bien, y la linea de detalle dice CON QUE
         FALLA       se midio y salio mal
         SIN MEDIR   el instrumento no pudo medir (VM apagada, timeout, sin
                     credencial). No es un OK y no es un bug del producto.
         SIN CORRER  quedo afuera por -From/-To, o una capa anterior fallo
         SIMULADO    -Simulate: no se midio NADA. No puede leerse como PASA.

  2) TODA CAPA TIENE TIMEOUT, Y EL TIMEOUT ES UN PARAMETRO. Un E2E que se cuelga
     para siempre no se corre nunca mas, y un timeout escondido en el codigo no se
     puede subir cuando la maquina esta lenta.

  3) LA MAQUINA NO QUEDA EN UN ESTADO RARO. La limpieza corre en un finally Y
     TAMBIEN al arrancar: si una corrida anterior murio de un Ctrl+C en el peor
     momento, la siguiente arranca limpia y ademas te dice que encontro sucio.
     Se limpia: la variable de entorno del modo test, los hives offline cargados,
     los VHDX/ISO montados y la ISO tomada por el DVD de la VM.
     NO se desmonta el WIM de work\mount: ahi puede haber trabajo del usuario y
     descartarlo seria irreversible. Se avisa y se deja.
  ===========================================================================

  POR QUE EL RUNNER PISA perfil.json (Y LO DEVUELVE AL FINAL)

  MEDIDO, y es la limitacion mas importante de este archivo:
  verify-live.ps1 (Get-LiveProfileWants) y test-vm.ps1 -Verify leen el perfil de
  UNA ruta fija, `<repo>\perfil.json`. No aceptan -ProfilePath. O sea que las capas
  6 y 7 comparan lo instalado contra el perfil que este ahi, no contra el que
  construyo la ISO. Si el runner buildeara con un perfil de test y dejara el del
  usuario en su lugar, las capas 6 y 7 medirian contra la expectativa EQUIVOCADA:
  el peor falso FALLA posible.

  Asi que el runner:
    - copia perfil.json a work\logs\perfil-usuario-backup-<stamp>.json,
    - deja el perfil de test en su lugar durante toda la corrida,
    - y lo restaura en el finally (tambien con Ctrl+C).
  El backup NO se borra: es la red de seguridad si la maquina se corta al medio.

  EL ARREGLO DE VERDAD es que verify-live.ps1 y test-vm.ps1 acepten -ProfilePath.
  Mientras no exista, esto es lo unico honesto que se puede hacer desde aca.

  ===========================================================================
  LOS PERFILES DE TEST NO SON UN ARCHIVO VERSIONADO: SE GENERAN

  Se generan de New-DefaultProfile y de los catalogos REALES de LunaticOS.ps1,
  extraidos con el parser de PowerShell (AST) del propio LunaticOS.ps1. No se
  reimplementa ni un catalogo: el dia que alguien agregue una opcion, los perfiles
  de la matriz la incluyen solos. Un perfil de test versionado a mano se queda
  viejo en silencio, y un test que mide una expectativa vieja es peor que ninguno.

  Y NO se usa el perfil.json del usuario: es suyo, esta gitignored, y cada uno
  tiene el suyo.

  ===========================================================================
  USO

      # la corrida completa (~35 min): tema oscuro + acento teal
      .\scripts\test-e2e.ps1

      # solo las capas rapidas, sin tocar VM ni disco
      .\scripts\test-e2e.ps1 -To 2

      # fallo la capa 6? se retoma sin rehacer los 35 minutos
      .\scripts\test-e2e.ps1 -From 6 -KeepVM

      # la matriz de la seccion 5 (una corrida por perfil, ~35 min cada una)
      .\scripts\test-e2e.ps1 -ListProfiles

      # probar el runner mismo sin gastar una hora
      .\scripts\test-e2e.ps1 -Simulate -KeepGoing

  Exit code:  0 todo PASA   1 alguna FALLA   2 alguna SIN MEDIR/SIN CORRER
              3 error del runner (sin admin, parametros malos, perfil imposible)
#>

[CmdletBinding()]
param(
  # --- que capas correr -----------------------------------------------------
  [int]$From = 1,
  [int]$To   = 8,

  # --- que perfil buildear (matriz de la seccion 5; -ListProfiles los lista) --
  [Alias('Perfil')]
  [string]$Profile = 'oscuro',
  # Escotilla: un .json propio en vez de uno generado. Se copia igual, no se pisa.
  [string]$ProfileFile = '',

  [string]$VMName = 'LunaticOS-Test',

  # --- comportamiento -------------------------------------------------------
  [switch]$KeepVM,        # dejar la VM viva para mirarla cuando algo falla
  [switch]$DestroyVM,     # borrar la VM y su VHDX al final (util en la matriz nocturna)
  [switch]$KeepGoing,     # no cortar en la primera FALLA
  [switch]$ListProfiles,  # imprimir la matriz y salir
  [switch]$Simulate,      # simular las capas 3..7 (para probar el runner, no mide nada)
  [int[]]$SimFail     = @(),   # con -Simulate: capas que deben salir FALLA
  [int[]]$SimSinMedir = @(),   # con -Simulate: capas que deben salir SIN MEDIR

  # --- TIMEOUTS. Todos parametros a proposito (regla 2 del header) -----------
  [int]$SelfTestTimeoutSec      = 600,    # capa 1: -SelfTest + los dos unattend
  [int]$TuiTimeoutSec           = 600,    # capa 2: 86 tests de TUI
  [int]$BuildTimeoutSec         = 5400,   # capa 3: 90 min (sin WIM exportado son ~45)
  [int]$VmSetupTimeoutSec       = 900,    # capa 4: reset + boot
  [int]$InstallTimeoutSec       = 3600,   # capa 5: hasta la PRIMERA respuesta de PS Direct
  [int]$SettleTimeoutSec        = 1800,   # capa 5: desde que contesta hasta que se asienta
  [int]$ProbeTimeoutSec         = 45,     # capa 5: timeout de CADA intento de PS Direct
  [int]$ProbeIntervalSec        = 20,     # capa 5: espera entre intentos
  [int]$VerifyLiveTimeoutSec    = 1200,   # capa 6
  [int]$ShutdownTimeoutSec      = 300,    # capa 7: apagado ordenado antes del -TurnOff
  [int]$VerifyOfflineTimeoutSec = 900     # capa 7
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

# config.ps1 trae $CFG (rutas, oscdimg, dism), $Global:TestUnattendPath y
# Get-TestVmAccount. Se dot-sourcea SOLO esto y los dos catalogos de config\: son
# archivos que declaran variables y funciones, no tienen param() y no corren nada.
# NO se dot-sourcea test-vm.ps1: su bloque param() bindearia SU $VMName en MI scope
# y pisaria el que me pasaron (la trampa que documenta verify-live.ps1).
. "$PSScriptRoot\config.ps1"
. "$root\config\personalizacion.ps1"
. "$root\config\apps.ps1"

$script:Pwsh = (Join-Path $PSHOME 'powershell.exe')
if (-not (Test-Path $script:Pwsh)) { $script:Pwsh = 'powershell.exe' }

# Build-AppxCatalog (que se trae de LunaticOS.ps1 mas abajo) indexa $AppxNotes solo
# para el texto de la nota, y esa variable vive en LunaticOS.ps1. Un hashtable vacio
# alcanza: una clave que no esta devuelve $null y el catalogo cae en su else. Sin
# declararlo, indexar $null tira con $ErrorActionPreference = 'Stop'.
$AppxNotes = @{}

# ===========================================================================
#  LAS OCHO CAPAS. El nombre es lo que se lee en el reporte final, asi que dice
#  QUE se midio, no como se llama la funcion.
# ===========================================================================
$script:Capas = @(
  @{ N = 1; Nombre = 'logica sin UI: -SelfTest + guardas de los unattend' }
  @{ N = 2; Nombre = 'TUI: teclas inyectadas (test-tui.ps1)' }
  @{ N = 3; Nombre = 'pipeline -> ISO de test (build con el perfil)' }
  @{ N = 4; Nombre = 'VM: reset + boot (autounattend-test, cero clics)' }
  @{ N = 5; Nombre = 'instalacion desatendida (senal: PowerShell Direct)' }
  @{ N = 6; Nombre = 'SO CORRIENDO: verify-live.ps1' }
  @{ N = 7; Nombre = 'disco instalado, VM apagada: test-vm.ps1 -Verify' }
  @{ N = 8; Nombre = 'reporte y log completo' }
)

# Resultado por capa. Arranca TODO en SIN CORRER: para que una capa diga PASA
# alguien tiene que escribirlo, y para eso tiene que haber medido.
$script:Res = @{}
foreach ($c in $script:Capas) {
  $script:Res[$c.N] = @{ Estado = 'SIN CORRER'; Detalle = 'no se corrio'; Seg = 0; Evidencia = @() }
}
$script:ErrFatal     = $null    # excepcion no esperada del runner (no del producto)
$script:Interrumpido = $false   # Ctrl+C que SI llego al catch
# ###################################################################
#  POR QUE HAY UNA BANDERA "EL BUCLE TERMINO" Y NO ALCANZA EL catch.
#  MEDIDO: un pipeline stop (lo que produce Ctrl+C) corre los finally pero NO
#  SIEMPRE entra al catch. En la prueba de interrupcion el finally limpio todo y
#  restauro el perfil, pero $script:Interrumpido quedo en $false: nadie atrapo nada.
#  Sin esta bandera, una corrida cortada a mitad se veria igual que una que
#  termino: capas en SIN CORRER y ninguna linea diciendo que se corto.
#  Se mide el HECHO (el bucle no llego al final), no la excepcion.
# ###################################################################
$script:LoopTermino  = $false

# Lo que NO se puede medir desde una VM. Va SIEMPRE en el reporte, dicho de frente
# (contrato, seccion 6): un E2E que calla lo que no cubre miente por omision.
$script:NoMedible = @(
  'la activacion real: necesita licencia legitima y hardware que coincida. En VM'
  '   no activa nunca, asi que Settings > Personalization queda en gris. NO es un bug.'
  'la instalacion en hardware real (Secure Boot/TPM/drivers/anticheat): ver docs\dia-d.md'
  'que cada app de winget instale bien: depende de internet y de repos de terceros.'
  '   Se mide que el instalador CORRIO y dejo log, no que cada app este.'
)

# ===========================================================================
#  LOG Y SALIDA POR PANTALLA
#
#  No se usa Start-Transcript: la capa 3 lanza LunaticOS.ps1 -Apply, que arranca
#  SU PROPIO transcript, y PowerShell 5.1 no anida dos. Ademas necesito decidir yo
#  que linea va con que color y con que prefijo.
# ===========================================================================
$script:LogWriter = $null
$script:LogPath   = ''

function Write-E2E {
  param([string]$Text = '', [string]$Color = 'Gray')
  Write-Host $Text -ForegroundColor $Color
  if ($script:LogWriter) {
    try { $script:LogWriter.WriteLine($Text) } catch { }
  }
}

# Linea que va SOLO al log: la salida cruda de los procesos hijos. Miles de lineas
# de dism en pantalla tapan el reporte; en el archivo son justo lo que se necesita
# cuando algo falla.
function Write-E2ELog {
  param([string]$Text = '')
  if ($script:LogWriter) { try { $script:LogWriter.WriteLine($Text) } catch { } }
}

function Write-E2ETitulo {
  param([int]$N, [string]$Nombre)
  Write-E2E ''
  Write-E2E ('=============================================================================') 'DarkCyan'
  Write-E2E ("  CAPA {0}/8  {1}" -f $N, $Nombre) 'Cyan'
  Write-E2E ("  {0}" -f (Get-Date -Format 'HH:mm:ss')) 'DarkGray'
  Write-E2E ('=============================================================================') 'DarkCyan'
}

function Write-E2EEstado {
  param([string]$Estado, [string]$Texto)
  $color = switch ($Estado) {
    'PASA'       { 'Green' }
    'FALLA'      { 'Red' }
    'SIN MEDIR'  { 'Yellow' }
    'SIMULADO'   { 'Magenta' }
    default      { 'DarkGray' }
  }
  Write-E2E ("  -> {0,-10} {1}" -f $Estado, $Texto) $color
}

# ===========================================================================
#  PROCESOS HIJOS CON TIMEOUT Y CON SALIDA EN VIVO
#
#  Cada capa lenta corre en un powershell.exe aparte. Tres razones medidas:
#
#  1) TIMEOUT. Es la unica forma de cortar algo que se cuelga: no hay como
#     interrumpir un dism que no vuelve si corre en mi propio proceso.
#  2) EXIT CODE DE VERDAD. Las fases y los tests comunican por exit code, y en el
#     mismo proceso habria que pelearse con $LASTEXITCODE y con lo que quede en el
#     pipeline (el bug que hacia que el self-test dijera TODO OK y saliera 1).
#  3) AISLAMIENTO. LunaticOS.ps1 -Apply pisa variables globales y abre su propio
#     transcript. En mi proceso me dejaria el scope sucio para las capas 6 y 7.
#
#  -WindowStyle Hidden y NO -NoNewWindow: con -NoNewWindow el hijo comparte MI
#  consola, y el Clear-Host de Invoke-Pipeline me borra el reporte de la pantalla.
#  Con una consola propia y oculta, Clear-Host funciona y no se lleva nada mio
#  (medido: con la consola compartida el reporte desaparecia a mitad del build).
#
#  $null = $p.Handle NO ES DECORATIVO: sin tocar el Handle antes de que el proceso
#  termine, Start-Process -PassThru deja .ExitCode VACIO. Medido: exit=[] con el
#  hijo saliendo 7. Un exit code vacio se evalua como 0, o sea "paso": exactamente
#  la clase de falso OK que este archivo existe para evitar.
# ===========================================================================
$script:TmpDir = Join-Path $env:TEMP ('lunaticos-e2e-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Stop-E2EArbol {
  param([int]$Id)
  # Matar solo el powershell.exe deja al dism/oscdimg que lanzo corriendo suelto y
  # con el WIM tomado. Se mata el arbol, de las hojas a la raiz.
  $hijos = @()
  try { $hijos = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$Id" -ErrorAction SilentlyContinue) } catch { }
  foreach ($h in $hijos) { Stop-E2EArbol -Id ([int]$h.ProcessId) }
  try { Stop-Process -Id $Id -Force -ErrorAction Stop } catch { }
}

function Invoke-E2EChild {
  param(
    [Parameter(Mandatory)][string[]]$ScriptArgs,   # ruta del .ps1 + sus argumentos
    [Parameter(Mandatory)][int]$TimeoutSec,
    [Parameter(Mandatory)][string]$Tag,
    [switch]$Mostrar                                # tambien por pantalla, no solo al log
  )
  New-Item -ItemType Directory -Force -Path $script:TmpDir | Out-Null
  $sello = Get-Date -Format 'HHmmss'
  $fOut  = Join-Path $script:TmpDir ("{0}-{1}.out" -f $Tag, $sello)
  $fErr  = Join-Path $script:TmpDir ("{0}-{1}.err" -f $Tag, $sello)
  # NO se llama $args: es una variable automatica de PowerShell y pisarla dentro de
  # una funcion es pedirle un bug raro al proximo que agregue un parametro.
  $cmd = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File') + $ScriptArgs

  Write-E2ELog ("--- hijo: powershell.exe " + ($cmd -join ' '))
  Write-E2ELog ("--- timeout: {0}s" -f $TimeoutSec)

  $p = Start-Process -FilePath $script:Pwsh -ArgumentList $cmd -PassThru `
                     -WindowStyle Hidden -RedirectStandardOutput $fOut -RedirectStandardError $fErr
  $null = $p.Handle   # ver el header de esta seccion. NO lo saques.

  $script:ChildLineas = New-Object System.Collections.Generic.List[string]
  $script:ChildPend   = ''
  $script:ChildFs     = $null
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  $timedOut = $false

  # El archivo lo esta escribiendo el hijo: hay que abrirlo con FileShare ReadWrite
  # o el open falla con "being used by another process".
  for ($i = 0; $i -lt 40 -and -not $script:ChildFs; $i++) {
    try { $script:ChildFs = New-Object System.IO.FileStream($fOut, 'Open', 'Read', 'ReadWrite') }
    catch { Start-Sleep -Milliseconds 250 }
  }

  # OJO CON EL SCOPE: el estado del tailer va en variables $script:. Un scriptblock
  # invocado con & corre en un scope HIJO, asi que `$pend = ...` adentro crearia una
  # copia local y el buffer se perderia en cada vuelta -- el log saldria con lineas
  # duplicadas o cortadas justo cuando hace falta leerlo.
  # Se emite SOLO hasta el ultimo salto de linea: leer al voleo parte las lineas al medio.
  $emitir = {
    param([switch]$Final)
    if (-not $script:ChildFs) { return }
    $buf = New-Object byte[] 65536
    while (($n = $script:ChildFs.Read($buf, 0, $buf.Length)) -gt 0) {
      $script:ChildPend += [System.Text.Encoding]::Default.GetString($buf, 0, $n)
    }
    $corte = if ($Final) { $script:ChildPend.Length } else { $script:ChildPend.LastIndexOf("`n") + 1 }
    if ($corte -le 0) { return }
    $bloque = $script:ChildPend.Substring(0, $corte)
    $script:ChildPend = $script:ChildPend.Substring($corte)
    foreach ($l in ($bloque -split "`r?`n")) {
      if ($Final -and $l -eq '') { continue }
      [void]$script:ChildLineas.Add($l)
      Write-E2ELog ('    | ' + $l)
      # Las barras de progreso de dism/oscdimg son miles de lineas iguales: al log si,
      # a la pantalla no. Mismo filtro que Invoke-Pipeline.
      if ($Mostrar -and
          -not ($l -match '^\s*\[[=\s]*\d+\.?\d*%[=\s]*\]\s*$' -or
                $l -match '^\s*\d+%\s+complete\s*$' -or
                $l -match 'RemoteException')) {
        Write-Host ('    | ' + $l) -ForegroundColor DarkGray
      }
    }
  }

  while (-not $p.HasExited) {
    & $emitir
    if ((Get-Date) -ge $deadline) { $timedOut = $true; break }
    Start-Sleep -Milliseconds 500
  }
  if ($timedOut) {
    Write-E2E ("  ! TIMEOUT: el hijo paso los {0}s y lo corto (arbol de procesos incluido)" -f $TimeoutSec) 'Red'
    Stop-E2EArbol -Id $p.Id
    Start-Sleep -Milliseconds 500
  }
  & $emitir -Final
  $lineas = @($script:ChildLineas)
  if ($script:ChildFs) { try { $script:ChildFs.Close() } catch { } ; $script:ChildFs = $null }

  $code = -1
  if (-not $timedOut) {
    try { $p.WaitForExit(5000) | Out-Null } catch { }
    try { $code = [int]$p.ExitCode } catch { $code = -1 }
  }

  $errTxt = @()
  if (Test-Path $fErr) {
    $errTxt = @(Get-Content $fErr -ErrorAction SilentlyContinue)
    foreach ($l in $errTxt) { Write-E2ELog ('    !e ' + $l) }
  }

  return @{
    ExitCode = $code
    TimedOut = $timedOut
    Lineas   = @($lineas)
    Errores  = @($errTxt)
    OutFile  = $fOut
  }
}

# ===========================================================================
#  PERFILES DE TEST -- LA MATRIZ DE LA SECCION 5
#
#  Se construyen sobre New-DefaultProfile y los catalogos REALES de LunaticOS.ps1.
#  Se extraen con el parser de PowerShell en vez de dot-sourcear LunaticOS.ps1
#  (que no tiene guarda de dot-source: dot-sourcearlo abriria la TUI) y en vez de
#  copiar los catalogos aca (una segunda copia de un catalogo es una segunda
#  oportunidad de que se queden distintos, y el que se queda viejo es el del test).
# ===========================================================================
$script:PerfilesDef = @(
  @{ Nombre = 'oscuro'
     Desc   = 'recomendados + tema OSCURO + acento teal + 1 programa'
     Por    = 'el default del runner: ejercita la rama InstallThemeDark y el acento,'
     Por2   = 'que es donde el proyecto se rompio dos veces. Corrida corta.' }
  @{ Nombre = 'claro'
     Desc   = 'recomendados SIN tema oscuro + acento ambar + 1 programa'
     Por    = 'la rama InstallThemeLight. InstallThemeDark era el bug PORQUE nunca'
     Por2   = 'probamos con tema claro. Otro acento a proposito: dos ramas cubiertas.' }
  @{ Nombre = 'recomendados'
     Desc   = 'exactamente los defaults (Rec=$true), sin tocar nada'
     Por    = 'lo que va a usar el 90%. OJO: son 24 programas por winget, la'
     Por2   = 'corrida mas larga de la matriz.' }
  @{ Nombre = 'todo'
     Desc   = 'TODO marcado (un solo acento: los grupos excluyentes se respetan)'
     Por    = 'el maximo de debloat: encuentra lo que se rompe al sacar de mas.'
     Por2   = 'Incluye BlockCloudContent y DisableLocation, con sus consecuencias.' }
  @{ Nombre = 'nada'
     Desc   = 'NADA marcado: Windows limpio'
     Por    = '"cero marcados" tiene que ser distinguible de "sin perfil": el bug'
     Por2   = 'de "elegir 0 apps instalaba los 24 recomendados" era exactamente eso.' }
)

function Get-E2ECatalogoSrc {
  # Devuelve el TEXTO de las funciones de LunaticOS.ps1 que construyen el perfil.
  # Devuelve texto y no las define aca a proposito: Invoke-Expression adentro de una
  # funcion define las funciones EN EL SCOPE DE ESA FUNCION y desaparecen al volver.
  # El call site lo evalua en el scope del script, que es donde tienen que vivir.
  #
  # Y se extrae del AST en vez de dot-sourcear LunaticOS.ps1 porque ese archivo no
  # tiene guarda de dot-source: dot-sourcearlo correria el MAIN y abriria la TUI.
  $lp = Join-Path $root 'LunaticOS.ps1'
  if (-not (Test-Path $lp)) { throw "no existe $lp" }
  $tk = $null; $er = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($lp, [ref]$tk, [ref]$er)
  if ($er -and $er.Count -gt 0) { throw ("LunaticOS.ps1 no parsea ({0} errores): no puedo leer los catalogos" -f $er.Count) }
  $quiero = @('Build-AppxCatalog', 'Build-ServiceCatalog', 'Build-FeatureCatalog',
              'Build-FlagCatalog', 'New-DefaultProfile', 'Find-SourceIso')
  $fns = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
  $src = ''
  foreach ($q in $quiero) {
    $f = @($fns | Where-Object { $_.Name -eq $q }) | Select-Object -First 1
    if (-not $f) { throw "LunaticOS.ps1 ya no define $q -- el generador de perfiles quedo viejo. Arreglalo antes de correr el E2E." }
    $src += $f.Extent.Text + "`n"
  }
  return $src
}

function Resolve-E2EExclusivos {
  # Los grupos excluyentes (los acentos) NO pueden quedar los tres en $true: eso es
  # lo que la TUI impide con Resolve-TuiExclusive, y un perfil escrito a mano que se
  # los saltea prueba un camino que ningun usuario puede producir. Se deja el PRIMERO
  # del grupo que este marcado y se apagan los hermanos.
  param([Parameter(Mandatory)]$Pers)
  foreach ($grupo in @($Global:PersonalizacionExclusivos)) {
    $marcados = @(@($grupo) | Where-Object { $Pers.Contains($_) -and $Pers[$_] })
    if ($marcados.Count -le 1) { continue }
    for ($i = 1; $i -lt $marcados.Count; $i++) { $Pers[$marcados[$i]] = $false }
  }
}

function New-E2EPerfil {
  param([Parameter(Mandatory)][string]$Nombre)

  $p = New-DefaultProfile          # la fuente de verdad: el mismo que usa la TUI
  $secs = @('appx', 'servicios', 'features', 'flags', 'personalizacion', 'programas')

  switch ($Nombre) {
    'recomendados' { }   # tal cual sale: Rec=$true de cada catalogo

    'nada' {
      foreach ($s in $secs) { foreach ($k in @($p.$s.Keys)) { $p.$s[$k] = $false } }
    }

    'todo' {
      foreach ($s in $secs) { foreach ($k in @($p.$s.Keys)) { $p.$s[$k] = $true } }
      Resolve-E2EExclusivos -Pers $p.personalizacion
      # Los 'manual' del catalogo de programas no instalan nada por winget: solo
      # dejan una lista de URLs en el escritorio. Se dejan marcados a proposito
      # (es lo que haria alguien que marca todo) y el runner no espera nada de ellos.
    }

    'oscuro' {
      $p.personalizacion['tema-oscuro']  = $true
      $p.personalizacion['acento-teal']  = $true
      Resolve-E2EExclusivos -Pers $p.personalizacion
      foreach ($k in @($p.programas.Keys)) { $p.programas[$k] = $false }
      $p.programas['7zip'] = $true
    }

    'claro' {
      # No hay key 'tema-claro': el tema claro ES la ausencia de 'tema-oscuro'.
      # Justo por eso nunca se probo, y justo ahi estaba el bug de InstallThemeDark.
      $p.personalizacion['tema-oscuro']   = $false
      $p.personalizacion['acento-ambar']  = $true
      # ColorPrevalence (acento en la taskbar) Windows SOLO lo respeta con tema
      # oscuro: marcarlo con tema claro seria pedir algo que no puede pasar y el
      # verify lo reportaria como falla nuestra. Se apaga a proposito.
      $p.personalizacion['acento-en-taskbar'] = $false
      Resolve-E2EExclusivos -Pers $p.personalizacion
      foreach ($k in @($p.programas.Keys)) { $p.programas[$k] = $false }
      $p.programas['7zip'] = $true
    }

    default { throw "perfil de test desconocido: '$Nombre'. Los que hay: " + (($script:PerfilesDef | ForEach-Object { $_.Nombre }) -join ', ') }
  }

  # La cuenta del usuario tiene que ser la de config\autounattend-test.xml o el
  # AutoLogon crea 'pato' y el perfil pide otro nombre: dos usuarios, y la
  # personalizacion aplicada al que no se loguea.
  try {
    $acc = Get-TestVmAccount
    $p.usuario['nombre'] = $acc.User
  } catch {
    Write-E2E ("  ! no pude leer el usuario de config\autounattend-test.xml: " + $_.Exception.Message) 'Yellow'
  }
  return $p
}

function Get-E2EResumenPerfil {
  param($P)
  $n = @{}
  foreach ($s in @('appx', 'servicios', 'features', 'flags', 'personalizacion', 'programas')) {
    $n[$s] = @(@($P.$s.Keys) | Where-Object { $P.$s[$_] }).Count
  }
  $pers = @(@($P.personalizacion.Keys) | Where-Object { $P.personalizacion[$_] })
  $tema = if ($P.personalizacion['tema-oscuro']) { 'oscuro' } else { 'claro' }
  $ac   = @($pers | Where-Object { $_ -like 'acento-*' -and $_ -ne 'acento-en-taskbar' })
  $acTx = if ($ac.Count -eq 0) { 'sin acento' } else { ($ac -join '+') }
  return ("tema {0}, {1}, appx {2}, servicios {3}, features {4}, flags {5}, pers {6}, programas {7}" -f `
          $tema, $acTx, $n['appx'], $n['servicios'], $n['features'], $n['flags'], $n['personalizacion'], $n['programas'])
}

function Show-E2EMatriz {
  Write-Host ''
  Write-Host '  MATRIZ DE PERFILES (docs\testing-e2e.md, seccion 5)' -ForegroundColor Cyan
  Write-Host '  Cada corrida son ~35 min: la matriz NO va en cada cambio. Va en una' -ForegroundColor DarkGray
  Write-Host '  corrida nocturna, o a mano antes de publicar.' -ForegroundColor DarkGray
  Write-Host ''
  foreach ($d in $script:PerfilesDef) {
    $def = if ($d.Nombre -eq 'oscuro') { '   (default)' } else { '' }
    Write-Host ("  -Profile {0,-14}{1}" -f $d.Nombre, $def) -ForegroundColor White
    Write-Host ("      {0}" -f $d.Desc) -ForegroundColor Gray
    Write-Host ("      {0}" -f $d.Por)  -ForegroundColor DarkGray
    Write-Host ("      {0}" -f $d.Por2) -ForegroundColor DarkGray
    Write-Host ''
  }
  Write-Host '  La matriz completa, una linea por corrida:' -ForegroundColor Cyan
  foreach ($d in $script:PerfilesDef) {
    Write-Host ("    .\scripts\test-e2e.ps1 -Profile {0} -DestroyVM" -f $d.Nombre) -ForegroundColor DarkGray
  }
  Write-Host ''
  Write-Host '  -DestroyVM en la matriz porque cada corrida deja un VHDX de 64 GB.' -ForegroundColor DarkGray
  Write-Host ''
}

# ===========================================================================
#  LIMPIEZA -- corre en el finally Y AL ARRANCAR (regla 3 del header)
# ===========================================================================
# Todas las claves con las que este repo carga hives offline. Si una quedo cargada,
# BLOQUEA el VHDX o el WIM y el proximo build falla con un error que no dice por que.
$script:HiveKeys = @('OFF_SW', 'OFF_DEF', 'OFF_SYS', 'OFF_SW_EDGE', 'OFF_SW_CLEAN',
                     'OFF_SYS_EDGE', 'OFF_DEFSYS', 'OFF_DEFUSR', 'OFF_PERS',
                     'OFF_PERS_M', 'OFF_PERS_RO', 'OFF_SW_APPS', 'VRF_USR', 'VRF_POL')

function Clear-E2EEnvTest {
  $v = $env:LUNATICOS_TEST_UNATTEND
  if ($null -ne $v -and $v -ne '') {
    Remove-Item Env:LUNATICOS_TEST_UNATTEND -ErrorAction SilentlyContinue
    return "LUNATICOS_TEST_UNATTEND estaba en '$v' -> limpiada"
  }
  return ''
}

# ###################################################################
#  reg.exe Y $ErrorActionPreference = 'Stop': TRAMPA MEDIDA, no teorica.
#
#  `& reg.exe query HKLM\OFF_SW 2>$null` sobre una clave que NO EXISTE (el caso
#  NORMAL: casi nunca hay un hive colgado) escribe en stderr, y con EAP='Stop'
#  PowerShell 5.1 convierte ese stderr en un error TERMINANTE (NativeCommandError)
#  A PESAR del 2>$null. Sintoma real de la primera version de este archivo:
#  la limpieza de arranque tiraba, el bucle de capas NUNCA corria, las 8 capas
#  salian SIN CORRER y el exit code lo ponia PowerShell, no el reporte.
#  Por eso se baja el EAP alrededor de reg.exe y se decide por $LASTEXITCODE,
#  que es la unica cosa que reg.exe dice sin ambiguedad.
# ###################################################################
function Invoke-E2EReg {
  param([Parameter(Mandatory)][string[]]$RegArgs)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'SilentlyContinue'
  try {
    $null = & reg.exe @RegArgs 2>&1
    return [int]$LASTEXITCODE
  }
  finally { $ErrorActionPreference = $prev }
}

function Clear-E2EHives {
  $hechos = @()
  foreach ($k in $script:HiveKeys) {
    if ((Invoke-E2EReg -RegArgs @('query', "HKLM\$k")) -ne 0) { continue }
    $ok = $false
    for ($i = 0; $i -lt 6 -and -not $ok; $i++) {
      # El GC antes del unload no es supersticion: un handle sin finalizar sobre la
      # colmena hace fallar el unload y deja el VHDX bloqueado (mismo patron que
      # Use-OfflineHive en lib.ps1).
      [gc]::Collect(); [gc]::WaitForPendingFinalizers()
      if ((Invoke-E2EReg -RegArgs @('unload', "HKLM\$k")) -eq 0) { $ok = $true }
      else { Start-Sleep -Milliseconds 400 }
    }
    if ($ok) { $hechos += "hive HKLM\$k estaba cargado -> descargado" }
    else     { $hechos += "hive HKLM\$k CARGADO y NO pude descargarlo (handles abiertos)" }
  }
  return $hechos
}

function Clear-E2EMontajes {
  $hechos = @()
  $cands = @(
    (Join-Path $root ('work\' + $VMName + '.vhdx'))
    (Join-Path $root 'work\Win11_25H2_Pro_debloat.iso')
  )
  # La ISO original tambien: la fase 00 la monta para copiar el arbol.
  try { $src = Find-SourceIso; if ($src) { $cands += $src } } catch { }
  foreach ($f in $cands) {
    if (-not $f -or -not (Test-Path $f)) { continue }
    $di = $null
    try { $di = Get-DiskImage -ImagePath $f -ErrorAction SilentlyContinue } catch { }
    if ($di -and $di.Attached) {
      try {
        Dismount-DiskImage -ImagePath $f -ErrorAction Stop | Out-Null
        $hechos += ("estaba montado -> desmontado: " + (Split-Path $f -Leaf))
      } catch {
        $hechos += ("MONTADO y no pude desmontarlo: " + (Split-Path $f -Leaf) + " -- " + $_.Exception.Message)
      }
    }
  }
  return $hechos
}

function Clear-E2EDvd {
  # Libera la ISO del DVD de LA VM DEL RUNNER. De las VMs ajenas no se toca nada:
  # apagar o reconfigurar algo de otro para desbloquear un archivo es la clase de
  # "ayuda" que arruina la tarde de alguien (mismo criterio que la fase 09).
  param([switch]$Force)
  $hechos = @()
  if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) { return $hechos }
  $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
  if (-not $vm) { return $hechos }
  $iso = Join-Path $root 'work\Win11_25H2_Pro_debloat.iso'
  $dvd = @(Get-VMDvdDrive -VMName $VMName -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $iso })
  if ($dvd.Count -eq 0) { return $hechos }

  # Sacarle el DVD a una VM que TODAVIA SE ESTA INSTALANDO rompe la instalacion.
  # Solo se expulsa si la VM esta apagada, o si la capa 5 ya confirmo que el SO
  # arranco (ahi el DVD no hace falta mas: bootea del disco).
  $seguro = ($vm.State -eq 'Off') -or $Force -or ($script:Res[5].Estado -eq 'PASA')
  if (-not $seguro) {
    $hechos += ("la ISO sigue en el DVD de {0} y la VM esta {1}: NO la expulso (podria estar instalandose todavia)." -f $VMName, $vm.State)
    $hechos += ("   el proximo build va a fallar con Error 32. Apagala:  Stop-VM -Name '{0}'" -f $VMName)
    return $hechos
  }
  try {
    Set-VMDvdDrive -VMName $VMName -Path $null -ErrorAction Stop
    $hechos += ("ISO expulsada del DVD de {0} (asi el proximo build no falla con Error 32)" -f $VMName)
  } catch {
    $hechos += ("no pude expulsar la ISO del DVD de {0}: {1}" -f $VMName, $_.Exception.Message)
  }
  return $hechos
}

$script:PerfilBackup  = ''       # '' = todavia no se toco nada
$script:PerfilHabia   = $false
$script:PerfilPisado  = $false   # solo entonces hay algo que devolver
$script:PerfilUser    = Join-Path $root 'perfil.json'

function Restore-E2EPerfil {
  $hechos = @()
  if (-not $script:PerfilPisado) { return $hechos }
  if ($script:PerfilHabia) {
    if (Test-Path $script:PerfilBackup) {
      try {
        Copy-Item $script:PerfilBackup $script:PerfilUser -Force -ErrorAction Stop
        $hechos += ("perfil.json del usuario restaurado desde " + (Split-Path $script:PerfilBackup -Leaf))
      } catch {
        $hechos += ("NO PUDE restaurar perfil.json. Tu perfil esta a salvo en: " + $script:PerfilBackup)
      }
    } else {
      $hechos += ("el backup de tu perfil.json no esta donde lo deje ({0}): dejo el de test en su lugar" -f $script:PerfilBackup)
    }
    return $hechos
  }
  # No habia perfil antes de la corrida: el que quedo es el de test. Se borra para no
  # dejarle al usuario un perfil que no eligio (la TUI arranca en los defaults, y un
  # perfil de test tirado ahi haria que su proximo build salga con otras opciones).
  if (Test-Path $script:PerfilUser) {
    try {
      Remove-Item $script:PerfilUser -Force -ErrorAction Stop
      $hechos += 'perfil.json borrado: no habia ninguno antes de la corrida'
    } catch {
      $hechos += 'no pude borrar el perfil.json de test que deje: borralo a mano'
    }
  }
  return $hechos
}

function Invoke-E2ELimpieza {
  param([string]$Momento)   # 'arranque' o 'salida'
  $hechos = @()
  $e = Clear-E2EEnvTest;  if ($e) { $hechos += $e }
  $hechos += Clear-E2EHives
  $hechos += Clear-E2EMontajes
  if ($Momento -eq 'salida') {
    # LA VM SE TOCA SOLO SI ESTA CORRIDA LA USO. Un `-To 2` mide self-tests y nada
    # mas: apagarle la VM o expulsarle el DVD seria cambiarle el estado de la maquina
    # a alguien que solo pidio correr los tests rapidos, y eso desconcierta con razon.
    # -Simulate tampoco: una simulacion que cambia el estado de la maquina no es una
    # simulacion. (Medido: la primera version le expulsaba el DVD a la VM en cada
    # corrida con -Simulate, sin haber tocado la VM para nada.)
    $usoLaVm = ($From -le 7 -and $To -ge 4 -and -not $Simulate)
    if ($usoLaVm) {
      if (-not $KeepVM) { $hechos += Stop-E2EVm }
      $hechos += Clear-E2EDvd
      if ($DestroyVM -and -not $KeepVM) { $hechos += Remove-E2EVm }
    }
    elseif ($DestroyVM) {
      $hechos += ("-DestroyVM ignorado: las capas de esta corrida ({0}-{1}) no usan la VM" -f $From, $To)
    }
    $hechos += Restore-E2EPerfil
  }
  # El WIM montado NO se toca: ahi puede haber trabajo del usuario y el propio
  # LunaticOS.ps1 le dice que corrija y reintente la fase sin re-exportar (20 min).
  $wim = Join-Path $CFG.Mount 'Windows'
  if (Test-Path $wim) {
    $hechos += ("OJO: hay un WIM montado en {0}. NO lo desmonto (podria ser tu trabajo)." -f $CFG.Mount)
    $hechos += '   si es basura de una corrida cortada:  dism /Unmount-Wim /MountDir:"' + $CFG.Mount + '" /Discard'
  }

  if ($hechos.Count -eq 0) {
    Write-E2E ("  limpieza ({0}): nada que limpiar" -f $Momento) 'DarkGray'
  } else {
    Write-E2E ("  limpieza ({0}):" -f $Momento) 'Yellow'
    foreach ($h in $hechos) { Write-E2E ('    - ' + $h) 'Yellow' }
  }
  return $hechos
}

function Stop-E2EVm {
  $hechos = @()
  if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) { return $hechos }
  $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
  if (-not $vm -or $vm.State -eq 'Off') { return $hechos }
  try {
    Stop-VM -Name $VMName -Force -ErrorAction Stop
    $hechos += ("VM {0} apagada (ordenado)" -f $VMName)
  } catch {
    try {
      Stop-VM -Name $VMName -TurnOff -Force -ErrorAction Stop
      $hechos += ("VM {0} apagada con -TurnOff (el apagado ordenado no anduvo)" -f $VMName)
    } catch {
      $hechos += ("no pude apagar la VM {0}: {1}" -f $VMName, $_.Exception.Message)
    }
  }
  return $hechos
}

function Remove-E2EVm {
  $hechos = @()
  $r = Invoke-E2EChild -ScriptArgs @((Join-Path $PSScriptRoot 'test-vm.ps1'), '-Destroy', '-VMName', $VMName) `
                       -TimeoutSec 300 -Tag 'destroy'
  if ($r.ExitCode -eq 0) { $hechos += ("VM {0} y su VHDX borrados (-DestroyVM)" -f $VMName) }
  else { $hechos += ("-DestroyVM fallo (exit {0}): la VM puede seguir ahi" -f $r.ExitCode) }
  return $hechos
}

# ===========================================================================
#  HELPERS DE RESULTADO
# ===========================================================================
function Set-E2ERes {
  param([int]$N, [string]$Estado, [string]$Detalle, [string[]]$Evidencia = @(), [datetime]$T0)
  $seg = 0
  if ($T0) { $seg = [int]((Get-Date) - $T0).TotalSeconds }
  $script:Res[$N] = @{ Estado = $Estado; Detalle = $Detalle; Seg = $seg; Evidencia = @($Evidencia) }
  Write-E2EEstado $Estado $Detalle
  foreach ($e in @($Evidencia)) { Write-E2E ('       ' + $e) 'DarkGray' }
}

function Test-E2EHyperV {
  return [bool](Get-Command Get-VM -ErrorAction SilentlyContinue)
}

function Get-E2EVm {
  if (-not (Test-E2EHyperV)) { return $null }
  return (Get-VM -Name $VMName -ErrorAction SilentlyContinue)
}

# ===========================================================================
#  CAPA 1 -- logica sin UI. Rapido y primero: si esto falla, no gastes 35 min.
# ===========================================================================
function Invoke-E2ECapa1 {
  $t0 = Get-Date
  $ev = @()

  $r1 = Invoke-E2EChild -ScriptArgs @((Join-Path $root 'LunaticOS.ps1'), '-SelfTest') `
                        -TimeoutSec $SelfTestTimeoutSec -Tag 'selftest'
  $oks    = @($r1.Lineas | Where-Object { $_ -match '^\s*OK\s' }).Count
  $fallas = @($r1.Lineas | Where-Object { $_ -match '^\s*FALLA\s' })
  $ev += ("LunaticOS.ps1 -SelfTest: exit {0}, {1} OK, {2} FALLA" -f $r1.ExitCode, $oks, $fallas.Count)
  if ($r1.TimedOut) {
    Set-E2ERes 1 'FALLA' ("-SelfTest paso los {0}s y lo corte" -f $SelfTestTimeoutSec) $ev $t0; return
  }
  if ($r1.ExitCode -ne 0) {
    foreach ($f in ($fallas | Select-Object -First 8)) { $ev += ('  ' + $f.Trim()) }
    Set-E2ERes 1 'FALLA' ("-SelfTest: {0} falla(s). NO se sigue: el resto son 35 minutos" -f $r1.ExitCode) $ev $t0; return
  }

  # Las guardas de los DOS autounattend, que cuestan un segundo. Descubrir un
  # unattend roto DESPUES del build es tirar el build entero.
  $r2 = Invoke-E2EChild -ScriptArgs @((Join-Path $PSScriptRoot '08-inject-runtime.ps1'), '-ValidateOnly') `
                        -TimeoutSec 120 -Tag 'unattend'
  $ev += ("08-inject-runtime.ps1 -ValidateOnly: exit {0}" -f $r2.ExitCode)
  foreach ($l in @($r2.Lineas | Where-Object { $_ -match 'OK \(|problemas|no existe' })) { $ev += ('  ' + $l.Trim()) }
  if ($r2.TimedOut -or $r2.ExitCode -ne 0) {
    Set-E2ERes 1 'FALLA' 'los autounattend NO pasan las guardas (ver el log)' $ev $t0; return
  }
  # Que el de test EXISTA no es un detalle: sin el no hay E2E, hay un build.
  if (-not (Test-Path $Global:TestUnattendPath)) {
    $ev += ('falta ' + $Global:TestUnattendPath)
    Set-E2ERes 1 'FALLA' 'no existe config\autounattend-test.xml: sin el, la instalacion pide un clic humano' $ev $t0; return
  }
  Set-E2ERes 1 'PASA' ("{0} tests sin UI en verde y los dos autounattend pasan las guardas" -f $oks) $ev $t0
}

# ===========================================================================
#  CAPA 2 -- la TUI, con teclas inyectadas. Exit code = cantidad de fallas.
# ===========================================================================
function Invoke-E2ECapa2 {
  $t0 = Get-Date
  $r = Invoke-E2EChild -ScriptArgs @((Join-Path $PSScriptRoot 'test-tui.ps1')) `
                       -TimeoutSec $TuiTimeoutSec -Tag 'tui'
  $oks    = @($r.Lineas | Where-Object { $_ -match '^\s*OK\s' }).Count
  $fallas = @($r.Lineas | Where-Object { $_ -match '^\s*FALLA\s' })
  $ev = @("test-tui.ps1: exit {0} (= cantidad de fallas), {1} OK, {2} FALLA" -f $r.ExitCode, $oks, $fallas.Count)
  if ($r.TimedOut) {
    $ev += 'un test de TUI colgado es el escenario que Send-TuiKeys existe para evitar: mira si alguien devolvio $null en vez de tirar'
    Set-E2ERes 2 'FALLA' ("los tests de TUI pasaron los {0}s y los corte" -f $TuiTimeoutSec) $ev $t0; return
  }
  if ($r.ExitCode -ne 0) {
    foreach ($f in ($fallas | Select-Object -First 10)) { $ev += ('  ' + $f.Trim()) }
    Set-E2ERes 2 'FALLA' ("{0} test(s) de TUI en rojo" -f $r.ExitCode) $ev $t0; return
  }
  Set-E2ERes 2 'PASA' ("{0} tests de TUI en verde" -f $oks) $ev $t0
}

# ===========================================================================
#  CAPA 3 -- el build. Lo unico que cambia respecto de un build normal es
#  LUNATICOS_TEST_UNATTEND=1: el pipeline invoca las fases con `& $path` SIN
#  argumentos, asi que el modo test solo puede viajar por variable de entorno.
# ===========================================================================
function Invoke-E2ECapa3 {
  $t0 = Get-Date
  $ev = @()

  # --- precondiciones. Se chequean aca porque el build corre con -NoPreflight:
  #     el preflight de LunaticOS.ps1 es INTERACTIVO (pregunta si instalar el ADK)
  #     y en una corrida desatendida se quedaria esperando una tecla hasta el timeout.
  if (-not (Test-Path $CFG.Oscdimg) -or -not (Test-Path $CFG.Dism)) {
    Set-E2ERes 3 'SIN MEDIR' 'falta el Windows ADK (oscdimg/dism): sin eso no hay ISO' `
      @("busque en: $($CFG.Oscdimg)", 'instalalo con la TUI (.\LunaticOS.ps1) y volve a correr esto') $t0; return
  }
  $src = Find-SourceIso
  if (-not $src) {
    Set-E2ERes 3 'SIN MEDIR' 'no encontre la ISO oficial de Windows 11 en work\' `
      @('pone la ISO original (no la *_debloat.iso) en work\ y volve a correr') $t0; return
  }
  $ev += ('ISO original: ' + (Split-Path $src -Leaf))
  $libre = [math]::Round((Get-PSDrive (Get-Item $root).PSDrive.Name).Free / 1GB, 1)
  $ev += ("espacio libre: {0} GB" -f $libre)
  if ($libre -lt 25) {
    Set-E2ERes 3 'SIN MEDIR' ("solo {0} GB libres: el build necesita 25" -f $libre) $ev $t0; return
  }

  # --- liberar la ISO de salida. oscdimg falla con Error 32 si alguien la tiene
  #     abierta, y eso pasa AL FINAL de un build de 45 minutos.
  $iso = Join-Path $root 'work\Win11_25H2_Pro_debloat.iso'
  foreach ($h in (Clear-E2EDvd -Force)) { $ev += $h; Write-E2E ('  ' + $h) 'Yellow' }
  if (Test-E2EHyperV) {
    $ajenas = @()
    foreach ($vm in @(Get-VM -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne $VMName })) {
      $d = @(Get-VMDvdDrive -VMName $vm.Name -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $iso })
      if ($d.Count -gt 0 -and $vm.State -ne 'Off') { $ajenas += $vm.Name }
    }
    if ($ajenas.Count -gt 0) {
      $ev += ('VMs ajenas ENCENDIDAS con la ISO en el DVD: ' + ($ajenas -join ', '))
      $ev += 'no las apago yo: podria haber trabajo tuyo adentro. Apagalas y volve a correr con -From 3'
      foreach ($a in $ajenas) { $ev += ("   Stop-VM -Name '{0}'" -f $a) }
      Set-E2ERes 3 'SIN MEDIR' 'la ISO de salida esta tomada por el DVD de una VM que no es mia' $ev $t0; return
    }
  }
  # El chequeo que de verdad sirve: abrirla en modo ESCRITURA. Si se puede, esta libre;
  # si no, esta tomada por algo (Explorer con la ISO montada, un antivirus, otra cosa).
  if (Test-Path $iso) {
    try {
      $fsx = [System.IO.File]::Open($iso, 'Open', 'ReadWrite', 'None'); $fsx.Close()
      $ev += 'la ISO de salida se puede abrir en modo escritura: esta libre'
    } catch {
      $ev += 'no puedo abrir la ISO de salida en modo escritura: algo la tiene tomada'
      $ev += ("   Dismount-DiskImage -ImagePath '{0}'" -f $iso)
      Set-E2ERes 3 'SIN MEDIR' 'la ISO de salida esta tomada: oscdimg fallaria con Error 32 al final del build' $ev $t0; return
    }
  }

  # --- el modo test. TIENE que valer exactamente '1' (asi lo compara la fase 08).
  $env:LUNATICOS_TEST_UNATTEND = '1'
  if ($env:LUNATICOS_TEST_UNATTEND -ne '1') {
    Set-E2ERes 3 'SIN MEDIR' 'no pude poner LUNATICOS_TEST_UNATTEND=1' $ev $t0; return
  }
  $ev += "LUNATICOS_TEST_UNATTEND='1' (la fase 08 compara por igualdad exacta)"
  Write-E2E '  LUNATICOS_TEST_UNATTEND=1 -> la ISO va a llevar config\autounattend-test.xml' 'Yellow'
  Write-E2E '  ESA ISO FORMATEA EL DISCO 0 SIN PREGUNTAR. Es para la VM y para nada mas.' 'Yellow'

  $marca = Join-Path $CFG.IsoBuild 'LUNATICOS-TEST-ISO.txt'
  $antes = if (Test-Path $iso) { (Get-Item $iso).LastWriteTime } else { [datetime]'1900-01-01' }

  try {
    $r = Invoke-E2EChild -ScriptArgs @((Join-Path $root 'LunaticOS.ps1'), '-Apply', '-NoPause', '-NoPreflight',
                                       '-ProfilePath', $script:PerfilUser) `
                         -TimeoutSec $BuildTimeoutSec -Tag 'build' -Mostrar
  }
  finally {
    # Se limpia YA, no en el finally global: si la capa 4 o 5 lanzara algo que
    # invoque la fase 08 con la variable puesta, se armaria otra ISO de test sin
    # que nadie lo pidiera.
    Remove-Item Env:LUNATICOS_TEST_UNATTEND -ErrorAction SilentlyContinue
  }

  $log = @(Get-ChildItem (Join-Path $root 'work\logs') -Filter 'build-*.log' -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending | Select-Object -First 1)
  if ($log.Count -gt 0) { $ev += ('log del build: ' + $log[0].FullName) }

  if ($r.TimedOut) {
    Set-E2ERes 3 'FALLA' ("el build paso los {0}s ({1} min) y lo corte" -f $BuildTimeoutSec, [int]($BuildTimeoutSec / 60)) $ev $t0; return
  }
  if ($r.ExitCode -ne 0) {
    Set-E2ERes 3 'FALLA' ("el pipeline se corto (exit {0})" -f $r.ExitCode) $ev $t0; return
  }
  if (-not (Test-Path $iso)) {
    Set-E2ERes 3 'FALLA' 'el pipeline salio 0 pero la ISO no esta' $ev $t0; return
  }
  $it = Get-Item $iso
  if ($it.LastWriteTime -le $antes) {
    $ev += ("la ISO tiene fecha {0} y el build arranco {1}" -f $it.LastWriteTime, $t0)
    Set-E2ERes 3 'FALLA' 'la ISO no se regenero: es la de antes' $ev $t0; return
  }
  $ev += ("ISO: {0}  {1} GB  {2}" -f $it.Name, [math]::Round($it.Length / 1GB, 2), $it.LastWriteTime)

  # EVIDENCIA DURA de que se uso el unattend de TEST y no el de produccion: la
  # fase 08 deja este marcador en la raiz del arbol de la ISO SOLO en modo test.
  # Sin este chequeo, una variable de entorno que no llego se veria igual que un
  # exito, y la capa 5 se colgaria esperando un clic humano hasta el timeout.
  if (Test-Path $marca) {
    $ev += ('marcador de ISO de test presente: ' + $marca)
  } else {
    $ev += ('NO esta el marcador ' + $marca)
    $ev += 'o sea que la ISO se armo con el autounattend de PRODUCCION: la instalacion va a pedir un clic humano'
    Set-E2ERes 3 'FALLA' 'la ISO NO es de test: falta LUNATICOS-TEST-ISO.txt en el arbol' $ev $t0; return
  }
  Set-E2ERes 3 'PASA' ("ISO de test armada en {0:mm\:ss}" -f ((Get-Date) - $t0)) $ev $t0
}

# ===========================================================================
#  CAPA 4 -- VM: reset + boot. Con autounattend-test no hay ni un clic humano.
# ===========================================================================
function Invoke-E2ECapa4 {
  $t0 = Get-Date
  $ev = @()
  if (-not (Test-E2EHyperV)) {
    Set-E2ERes 4 'SIN MEDIR' 'no esta el modulo de Hyper-V en este host' `
      @('Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All') $t0; return
  }
  $iso = Join-Path $root 'work\Win11_25H2_Pro_debloat.iso'
  if (-not (Test-Path $iso)) {
    Set-E2ERes 4 'SIN MEDIR' 'no existe work\Win11_25H2_Pro_debloat.iso: corre la capa 3 primero (-From 3)' @() $t0; return
  }
  if ($script:Res[3].Estado -ne 'PASA') {
    $ev += 'OJO: la capa 3 no corrio en esta corrida. Asumo que la ISO que hay es de TEST y se armo con este mismo perfil.'
    $ev += '     Si no lo es, las capas 6 y 7 van a medir contra la expectativa equivocada.'
  }

  # La primera vez que alguien corre esto, la VM ya existe pero esta instalada con
  # el autounattend de PRODUCCION: su cuenta NO tiene password, PowerShell Direct
  # no funciona y verify-live.ps1 sale con exit 5 (credencial rechazada). Este
  # reset la reinstala con el de TEST y eso se arregla solo. Queda anotado para que
  # nadie se asuste la primera vez.
  $vm = Get-E2EVm
  $cmdVm = @((Join-Path $PSScriptRoot 'test-vm.ps1'), '-Reset', '-VMName', $VMName)
  if (-not $vm) {
    $ev += ("la VM '{0}' no existe: se crea (Gen2 + TPM + Secure Boot)" -f $VMName)
    # -Create ya hace el -Reset por su cuenta (se pone la ISO igual): no hace falta pedir los dos.
    $cmdVm = @((Join-Path $PSScriptRoot 'test-vm.ps1'), '-Create', '-VMName', $VMName)
  } else {
    $ev += ("la VM '{0}' existe y estaba {1}: -Reset le borra el VHDX y le pone la ISO de test" -f $VMName, $vm.State)
    $ev += 'si esta VM venia instalada con el unattend de PRODUCCION, su cuenta no tenia password y'
    $ev += '   verify-live daba exit 5. Este reset la reinstala con el de TEST: se arregla solo.'
  }
  $r = Invoke-E2EChild -ScriptArgs $cmdVm -TimeoutSec $VmSetupTimeoutSec -Tag 'vmreset' -Mostrar
  if ($r.TimedOut -or $r.ExitCode -ne 0) {
    Set-E2ERes 4 'FALLA' ("el reset de la VM fallo (exit {0}{1})" -f $r.ExitCode, $(if ($r.TimedOut) { ', timeout' } else { '' })) $ev $t0; return
  }

  $r2 = Invoke-E2EChild -ScriptArgs @((Join-Path $PSScriptRoot 'test-vm.ps1'), '-Boot', '-VMName', $VMName) `
                        -TimeoutSec $VmSetupTimeoutSec -Tag 'vmboot' -Mostrar
  if ($r2.TimedOut -or $r2.ExitCode -ne 0) {
    Set-E2ERes 4 'FALLA' ("el boot de la VM fallo (exit {0}{1})" -f $r2.ExitCode, $(if ($r2.TimedOut) { ', timeout' } else { '' })) $ev $t0; return
  }
  # -Boot imprime "ACCION MANUAL REQUERIDA": ese texto es para la ISO de PRODUCCION,
  # que se para en "Select location to install Windows 11". Con autounattend-test hay
  # DiskConfiguration y esa pantalla no aparece.
  $ev += 'test-vm.ps1 -Boot avisa de una "ACCION MANUAL REQUERIDA": con la ISO de TEST NO hace falta.'
  $ev += '   Ese aviso es para la ISO de produccion, que a proposito le deja el disco al usuario.'

  Start-Sleep -Seconds 3
  $vm = Get-E2EVm
  if (-not $vm -or $vm.State -ne 'Running') {
    Set-E2ERes 4 'FALLA' ("la VM quedo en estado '{0}' y no Running" -f $(if ($vm) { $vm.State } else { 'inexistente' })) $ev $t0; return
  }
  $fw  = Get-VMFirmware -VMName $VMName -ErrorAction SilentlyContinue
  $sec = Get-VMSecurity  -VMName $VMName -ErrorAction SilentlyContinue
  $ev += ("VM Running. SecureBoot={0} TPM={1} RAM={2} GB vCPU={3}" -f `
          $(if ($fw) { $fw.SecureBoot } else { '?' }), $(if ($sec) { $sec.TpmEnabled } else { '?' }),
          [math]::Round($vm.MemoryStartup / 1GB, 0), $vm.ProcessorCount)
  Set-E2ERes 4 'PASA' 'VM reseteada, booteando de la ISO de test, cero clics humanos' $ev $t0
}

# ===========================================================================
#  CAPA 5 -- ESPERAR LA INSTALACION. Este es EL problema dificil del E2E.
#
#  NO HAY UNA SENAL LIMPIA DE "LA INSTALACION TERMINO". Lo que hay:
#    - screenshots por WMI (test-vm.ps1 -Shot). Se descarta: para decidir habria
#      que MIRAR una imagen, y encima devuelve una pantalla NEGRA cuando el display
#      esta dormido. Un runner que decide por pixeles es un runner que no se puede
#      correr desatendido.
#    - "la VM reinicio N veces": la instalacion reinicia varias veces y el numero
#      no es estable entre versiones. Contar reinicios es adivinar.
#    - el heartbeat de Hyper-V: dice que el SO arranco, NO que termino de
#      configurarse. Da un falso "listo" en medio del OOBE.
#
#  LA SENAL ELEGIDA: **que PowerShell Direct conteste.**
#  Tres motivos, y el tercero es el que decide:
#    1) Es binaria y no tiene interpretacion: contesta o no contesta.
#    2) Solo puede contestar si el SO arranco, si el usuario del unattend existe
#       y si su password funciona -- o sea, si la instalacion llego al final.
#       Con AutoLogon (LogonCount 5) la VM llega sola al escritorio.
#    3) ES EXACTAMENTE LO QUE LA CAPA 6 NECESITA. Esperar por otra cosa y despues
#       descubrir que PS Direct no anda es gastar 25 minutos para nada: aca la
#       espera y la precondicion de la capa siguiente son la MISMA medicion.
#
#  Y despues de que contesta hay una SEGUNDA espera, la de "asentarse": el script
#  del primer login (RunOnce) es el que APLICA el tema, y corre DESPUES del primer
#  logon. Medir el tema antes de que termine da un falso FALLA. El marcador es el
#  que el propio script escribe al final: "=== listo ===" en
#  C:\ProgramData\LunaticOS\personalizar.log. Es texto, no una imagen.
#
#  Evidencia de progreso mientras espera (sin mirar pantallas): uptime de la VM,
#  heartbeat, y el TAMANO DEL VHDX, que crece varios GB durante la instalacion.
#  Si el VHDX no crece y el heartbeat no aparece, algo esta trabado de verdad.
# ===========================================================================
$script:GuestProbe = @'
$ErrorActionPreference = 'SilentlyContinue'
$persLog = "$env:ProgramData\LunaticOS\personalizar.log"
$appsLog = "$env:ProgramData\LunaticOS\install-apps.log"
$r = @{
  Computer = $env:COMPUTERNAME; User = $env:USERNAME
  Ps = $PSVersionTable.PSVersion.ToString()
  Explorer = @(Get-Process -Name explorer).Count
  PersLog = (Test-Path $persLog); PersLines = 0; PersListo = $false
  AppsLog = (Test-Path $appsLog); AppsLines = 0
  Uptime = 0; Instalando = ''
}
if ($r.PersLog) {
  $l = @(Get-Content $persLog)
  $r.PersLines = $l.Count
  $r.PersListo = (@($l | Where-Object { $_ -match '=== listo ===' }).Count -gt 0)
}
if ($r.AppsLog) { $r.AppsLines = @(Get-Content $appsLog).Count }
$os = Get-CimInstance Win32_OperatingSystem
if ($os) { $r.Uptime = [int]((Get-Date) - $os.LastBootUpTime).TotalSeconds }
$busy = @(Get-Process -Name winget, msiexec, TiWorker, TrustedInstaller | Select-Object -Expand Name -Unique)
if ($busy.Count -gt 0) { $r.Instalando = ($busy -join ',') }
$r
'@

$script:ProbeRunner = @'
param($VMName, $Cred, $Code)
$ErrorActionPreference = 'Stop'
Invoke-Command -VMName $VMName -Credential $Cred -ScriptBlock ([scriptblock]::Create($Code))
'@

function Invoke-E2EProbe {
  param([Parameter(Mandatory)]$Cred, [int]$TimeoutSec)
  # Mismo patron que Invoke-LiveWithTimeout de verify-live.ps1: un runspace propio
  # con WaitOne. Invoke-Command -VMName no acepta timeout y puede quedarse colgado
  # un rato largo cuando el invitado no atiende.
  $ps = [powershell]::Create()
  [void]$ps.AddScript($script:ProbeRunner)
  [void]$ps.AddParameter('VMName', $VMName)
  [void]$ps.AddParameter('Cred',   $Cred)
  [void]$ps.AddParameter('Code',   $script:GuestProbe)
  try {
    $h = $ps.BeginInvoke()
    if (-not $h.AsyncWaitHandle.WaitOne([int]($TimeoutSec * 1000))) {
      try { [void]$ps.BeginStop($null, $null) } catch { }
      return @{ Ok = $false; TimedOut = $true; Data = $null; Error = 'timeout del intento' }
    }
    $out = @($ps.EndInvoke($h))
    $errs = @()
    foreach ($e in $ps.Streams.Error) { $errs += "$($e.Exception.Message)" }
    try { $ps.Dispose() } catch { }
    if ($out.Count -gt 0 -and $out[0]) { return @{ Ok = $true; TimedOut = $false; Data = $out[0]; Error = '' } }
    return @{ Ok = $false; TimedOut = $false; Data = $null; Error = (($errs -join ' ; ')) }
  }
  catch {
    try { $ps.Dispose() } catch { }
    return @{ Ok = $false; TimedOut = $false; Data = $null; Error = "$($_.Exception.Message)" }
  }
}

function Get-E2EErrorKind {
  param([string]$Texto)
  if ($Texto -match '(?i)credential (is )?invalid|invalid credential|logon failure|user name or password|1326|credencial|contrase') { return 'CRED' }
  if ($Texto -match '(?i)not in (the )?running state|is not running|no esta en ejecucion') { return 'NOTRUNNING' }
  if ($Texto -match '(?i)not listening|connection attempt failed|timed out|Hyper-V socket|no se pudo conectar|target process') { return 'NOTREADY' }
  # Los tres textos MEDIDOS con Invoke-Command -VMName contra una VM inexistente:
  #   "Hyper-V was unable to find a virtual machine with name X."
  #   "The input VMName X does not resolve to a single virtual machine."
  # El segundo es el que llega en .Exception.Message, y la version anterior de esta
  # linea (solo "cannot find the virtual machine") lo clasificaba como OTHER.
  if ($Texto -match '(?i)cannot find the virtual machine|no such virtual machine|unable to find a virtual machine|does not resolve to a single virtual machine|no se pudo encontrar (una )?maquina virtual') { return 'NOVM' }
  if ($Texto -match '(?i)access is denied|acceso denegado') { return 'DENIED' }
  if (-not $Texto) { return 'NONE' }
  return 'OTHER'
}

function Invoke-E2ECapa5 {
  $t0 = Get-Date
  $ev = @()
  if (-not (Test-E2EHyperV)) { Set-E2ERes 5 'SIN MEDIR' 'no esta el modulo de Hyper-V' @() $t0; return }
  $vm = Get-E2EVm
  if (-not $vm) { Set-E2ERes 5 'SIN MEDIR' ("no existe la VM '{0}': corre la capa 4 (-From 4)" -f $VMName) @() $t0; return }
  if ($vm.State -ne 'Running') {
    Set-E2ERes 5 'SIN MEDIR' ("la VM esta {0} y no Running: no hay instalacion que esperar" -f $vm.State) `
      @("arrancala con la capa 4:  .\scripts\test-e2e.ps1 -From 4") $t0; return
  }
  $cred = $null
  try {
    $acc = Get-TestVmAccount
    $cred = $acc.Credential
    $ev += ("credencial: usuario '{0}' leido de config\autounattend-test.xml (el password NO se imprime ni se pasa por linea de comandos)" -f $acc.User)
  } catch {
    Set-E2ERes 5 'SIN MEDIR' 'sin credencial usable: PowerShell Direct NO funciona con password vacio' `
      @("$($_.Exception.Message)") $t0; return
  }

  $vhdx = Join-Path $root ('work\' + $VMName + '.vhdx')
  $capa4Corrio = ($script:Res[4].Estado -eq 'PASA')
  $ev += ("senal de 'listo': que PowerShell Direct conteste (hasta {0} min), y despues el marcador '=== listo ===' del primer login (hasta {1} min)" -f `
          [int]($InstallTimeoutSec / 60), [int]($SettleTimeoutSec / 60))

  # ---------- ETAPA A: hasta la PRIMERA respuesta ----------
  $deadline = (Get-Date).AddSeconds($InstallTimeoutSec)
  $intento = 0; $credSeguidas = 0; $data = $null; $ultimoKind = 'NONE'
  Write-E2E ("  esperando que el invitado atienda (intento cada {0}s, {1}s por intento)..." -f $ProbeIntervalSec, $ProbeTimeoutSec) 'DarkGray'
  while ((Get-Date) -lt $deadline) {
    $intento++
    $r = Invoke-E2EProbe -Cred $cred -TimeoutSec $ProbeTimeoutSec
    if ($r.Ok) { $data = $r.Data; break }

    $kind = if ($r.TimedOut) { 'NOTREADY' } else { Get-E2EErrorKind $r.Error }
    $ultimoKind = $kind
    # Progreso REAL, sin mirar pantallas.
    $vm = Get-E2EVm
    $hb = Get-VMIntegrationService -VMName $VMName -Name 'Heartbeat' -ErrorAction SilentlyContinue
    $gb = if (Test-Path $vhdx) { [math]::Round((Get-Item $vhdx).Length / 1GB, 2) } else { 0 }
    Write-E2E ("    [{0,3}] {1,-11} estado={2} uptime={3} vhdx={4} GB heartbeat={5}" -f `
               $intento, $kind, $(if ($vm) { $vm.State } else { '?' }), $(if ($vm) { $vm.Uptime } else { '?' }),
               $gb, $(if ($hb) { $hb.PrimaryStatusDescription } else { '-' })) 'DarkGray'

    if ($vm -and $vm.State -eq 'Off') {
      $ev += ("la VM se APAGO sola en el intento {0}: la instalacion no la apaga nunca" -f $intento)
      Set-E2ERes 5 'FALLA' 'la VM se apago durante la instalacion' $ev $t0; return
    }
    # "credencial rechazada" SIN que la capa 4 haya reinstalado significa que la VM
    # esta instalada con el unattend de PRODUCCION (cuenta sin password). Eso no se
    # arregla esperando: se corta ya en vez de quemar 45 minutos.
    if ($kind -eq 'CRED') { $credSeguidas++ } else { $credSeguidas = 0 }
    if ($kind -eq 'CRED' -and $credSeguidas -ge 3 -and -not $capa4Corrio) {
      $ev += 'la credencial de config\autounattend-test.xml fue RECHAZADA tres veces y la capa 4 no corrio en esta corrida.'
      $ev += 'sintoma tipico: la VM esta instalada con el autounattend de PRODUCCION, cuya cuenta NO tiene password.'
      $ev += 'PowerShell Direct no funciona con password vacio. Se arregla reinstalando:  .\scripts\test-e2e.ps1 -From 3'
      Set-E2ERes 5 'SIN MEDIR' 'credencial rechazada: la VM no esta instalada con el unattend de TEST' $ev $t0; return
    }
    Start-Sleep -Seconds $ProbeIntervalSec
  }

  if (-not $data) {
    $gb = if (Test-Path $vhdx) { [math]::Round((Get-Item $vhdx).Length / 1GB, 2) } else { 0 }
    $ev += ("{0} intentos en {1} min, ultimo error: {2}" -f $intento, [int]($InstallTimeoutSec / 60), $ultimoKind)
    $ev += ("VHDX: {0} GB (si no crecio, la instalacion nunca arranco: mira la pantalla con .\scripts\test-vm.ps1 -Shot)" -f $gb)
    $ev += 'una pantalla NEGRA en el -Shot puede ser solo el display dormido: mandale un -Enter y volve a sacarla.'
    Set-E2ERes 5 'SIN MEDIR' ("el invitado no atendio PowerShell Direct en {0} min" -f [int]($InstallTimeoutSec / 60)) $ev $t0; return
  }
  $segConexion = [int]((Get-Date) - $t0).TotalSeconds
  $ev += ("PowerShell Direct contesto a los {0}s (intento {1}): {2} / {3} / PS {4}" -f `
          $segConexion, $intento, "$($data.Computer)", "$($data.User)", "$($data.Ps)")
  Write-E2E ("  el invitado atiende: {0} / {1}" -f "$($data.Computer)", "$($data.User)") 'Green'

  # ---------- ETAPA B: asentarse ----------
  # Que esperar depende del perfil: si no se pidio personalizacion, no hay RunOnce
  # que espere y exigir su marcador colgaria la corrida hasta el timeout.
  $esperaPers = $script:PerfilPidePers
  $esperaApps = $script:PerfilPideApps
  $ev += ("este perfil pide personalizacion={0} programas={1} -> se espera lo que corresponde y nada mas" -f $esperaPers, $esperaApps)

  $dl2 = (Get-Date).AddSeconds($SettleTimeoutSec)
  $asentado = $false
  while ((Get-Date) -lt $dl2) {
    $faltan = @()
    if ([int]"$($data.Explorer)" -lt 1) { $faltan += 'explorer.exe' }
    if ($esperaPers -and -not [bool]$data.PersListo) { $faltan += 'personalizar.log con "=== listo ==="' }
    if ($esperaApps -and -not [bool]$data.AppsLog)   { $faltan += 'install-apps.log' }
    if ($faltan.Count -eq 0) { $asentado = $true; break }
    Write-E2E ("    asentandose... falta: {0}   (explorer={1} persLog={2}/{3} lineas appsLog={4}/{5} corriendo={6})" -f `
               ($faltan -join ', '), "$($data.Explorer)", "$($data.PersLog)", "$($data.PersLines)",
               "$($data.AppsLog)", "$($data.AppsLines)", $(if ("$($data.Instalando)") { "$($data.Instalando)" } else { '-' })) 'DarkGray'
    Start-Sleep -Seconds $ProbeIntervalSec
    $r = Invoke-E2EProbe -Cred $cred -TimeoutSec $ProbeTimeoutSec
    if ($r.Ok) { $data = $r.Data }
    else { Write-E2E ("    (un intento fallo: {0} -- la VM puede estar reiniciando)" -f (Get-E2EErrorKind $r.Error)) 'DarkGray' }
  }

  $ev += ("estado final del invitado: explorer={0} personalizar.log={1} ({2} lineas, listo={3}) install-apps.log={4} ({5} lineas) uptime={6}s" -f `
          "$($data.Explorer)", "$($data.PersLog)", "$($data.PersLines)", "$($data.PersListo)",
          "$($data.AppsLog)", "$($data.AppsLines)", "$($data.Uptime)")
  if (-not $asentado) {
    $ev += ("pasaron los {0} min de espera y el sistema no llego al estado esperado." -f [int]($SettleTimeoutSec / 60))
    $ev += 'el SO SI atiende, asi que la capa 6 puede correr igual y va a decir exactamente que falta.'
    Set-E2ERes 5 'SIN MEDIR' 'el invitado atiende pero el primer login no cerro dentro del timeout' $ev $t0; return
  }
  Set-E2ERes 5 'PASA' ("instalacion terminada y primer login cerrado ({0:mm\:ss})" -f ((Get-Date) - $t0)) $ev $t0
}

# ===========================================================================
#  CAPA 6 -- el SO CORRIENDO, por PowerShell Direct.
#
#  verify-live.ps1 se llama SIN -User/-Password a proposito: los lee el mismo de
#  config\autounattend-test.xml. Un password en la linea de comandos de un proceso
#  lo puede leer cualquiera de la maquina (Task Manager lo muestra).
# ===========================================================================
function Invoke-E2ECapa6 {
  $t0 = Get-Date
  $ev = @()
  if (-not (Test-E2EHyperV)) { Set-E2ERes 6 'SIN MEDIR' 'no esta el modulo de Hyper-V' @() $t0; return }
  $vm = Get-E2EVm
  if (-not $vm) { Set-E2ERes 6 'SIN MEDIR' ("no existe la VM '{0}'" -f $VMName) @() $t0; return }
  if ($vm.State -ne 'Running') {
    # verify-live.ps1 es un OBSERVADOR: exige la VM Running y NO la arranca. Y esta
    # bien que sea asi, asi que el runner tampoco la arranca por atras.
    Set-E2ERes 6 'SIN MEDIR' ("la VM esta {0}: esto se mide con el SO CORRIENDO" -f $vm.State) `
      @('verify-live.ps1 no arranca la VM a proposito (es un observador).'
        ".\scripts\test-e2e.ps1 -From 4    # reinstala y espera, o arrancala a mano con Start-VM") $t0; return
  }

  # -ProfilePath: se mide contra el perfil de test, no contra el del usuario. Antes
  # el runner pisaba <repo>\perfil.json para conseguir esto; ya no hace falta.
  $r = Invoke-E2EChild -ScriptArgs @((Join-Path $PSScriptRoot 'verify-live.ps1'), '-VMName', $VMName,
                                     '-ProfilePath', $script:PerfilTestPath) `
                       -TimeoutSec $VerifyLiveTimeoutSec -Tag 'verifylive' -Mostrar

  # El reporte entero, aparte: es lo primero que se mira cuando esta capa falla.
  # GetFileNameWithoutExtension y NO Split-Path -LeafBase: -LeafBase es PowerShell 6+
  # y este repo corre en 5.1 (tira "A parameter cannot be found that matches -LeafBase").
  $baseLog = [System.IO.Path]::GetFileNameWithoutExtension($script:LogPath)
  $rep = Join-Path (Split-Path $script:LogPath -Parent) ($baseLog + '-verify-live.txt')
  try { $r.Lineas | Set-Content -Path $rep -Encoding ASCII; $ev += ('reporte completo: ' + $rep) } catch { }

  foreach ($l in @($r.Lineas | Where-Object { $_ -match 'OK=\d+\s+FALLA=' })) { $ev += $l.Trim() }
  foreach ($l in @($r.Lineas | Where-Object { $_ -match '^VEREDICTO' })) { $ev += $l.Trim() }
  $fallas = @($r.Lineas | Where-Object { $_ -match '^\s{2}FALLA\s' })
  foreach ($f in ($fallas | Select-Object -First 6)) { $ev += ('  ' + $f.Trim()) }

  if ($r.TimedOut) {
    Set-E2ERes 6 'SIN MEDIR' ("verify-live paso los {0}s y lo corte" -f $VerifyLiveTimeoutSec) $ev $t0; return
  }
  # Los exit codes de verify-live.ps1 (su header los documenta) se traducen sin
  # redondear para arriba: "no pude medir" NUNCA se convierte en PASA.
  switch ([int]$r.ExitCode) {
    0 { Set-E2ERes 6 'PASA'  'verify-live: PASA (todos los grupos con evidencia)' $ev $t0 }
    1 { Set-E2ERes 6 'FALLA' ("verify-live: FALLA ({0} chequeo(s) en rojo)" -f $fallas.Count) $ev $t0 }
    8 { $ev += 'SIN MEDIR es un resultado valido y honesto: PASA sin evidencia no.'
        Set-E2ERes 6 'SIN MEDIR' 'verify-live: INCOMPLETO -- sin FALLA, pero hay chequeos SIN MEDIR' $ev $t0 }
    2 { Set-E2ERes 6 'SIN MEDIR' 'verify-live: la VM no existe (exit 2)' $ev $t0 }
    3 { Set-E2ERes 6 'SIN MEDIR' 'verify-live: la VM esta apagada (exit 3)' $ev $t0 }
    4 { Set-E2ERes 6 'SIN MEDIR' 'verify-live: sin credencial usable (exit 4)' $ev $t0 }
    5 { $ev += 'la VM esta instalada con el unattend de PRODUCCION (cuenta sin password). Reinstalala:  -From 3'
        Set-E2ERes 6 'SIN MEDIR' 'verify-live: credencial RECHAZADA por el invitado (exit 5)' $ev $t0 }
    6 { Set-E2ERes 6 'SIN MEDIR' 'verify-live: timeout hablando con la VM (exit 6)' $ev $t0 }
    7 { Set-E2ERes 6 'SIN MEDIR' 'verify-live: falta admin o el modulo de Hyper-V (exit 7)' $ev $t0 }
    default { Set-E2ERes 6 'FALLA' ("verify-live salio con {0}, que no es un codigo documentado" -f $r.ExitCode) $ev $t0 }
  }
}

# ===========================================================================
#  CAPA 7 -- el disco instalado, con la VM APAGADA (monta el VHDX).
#
#  LIMITACION MEDIDA: test-vm.ps1 -Verify NO devuelve un exit code segun sus
#  hallazgos -- imprime y sale 0 igual. Asi que el veredicto se saca PARSEANDO su
#  salida (las lineas "  FALLA " / "  SOSPECHA " que emite Write-Finding). Parsear
#  texto es fragil, y por eso: si no aparece NI UNA linea de hallazgo reconocible,
#  esta capa dice SIN MEDIR en vez de asumir que todo salio bien.
#  El arreglo de verdad es que test-vm.ps1 -Verify devuelva exit code.
# ===========================================================================
function Invoke-E2ECapa7 {
  $t0 = Get-Date
  $ev = @()
  if (-not (Test-E2EHyperV)) { Set-E2ERes 7 'SIN MEDIR' 'no esta el modulo de Hyper-V' @() $t0; return }
  $vm = Get-E2EVm
  if (-not $vm) { Set-E2ERes 7 'SIN MEDIR' ("no existe la VM '{0}'" -f $VMName) @() $t0; return }

  if ($vm.State -ne 'Off') {
    Write-E2E ("  apagando la VM (ordenado, hasta {0}s): montar el VHDX de una VM encendida lo corrompe" -f $ShutdownTimeoutSec) 'DarkGray'
    $apagada = $false
    try {
      Stop-VM -Name $VMName -Force -ErrorAction Stop
      $dl = (Get-Date).AddSeconds($ShutdownTimeoutSec)
      while ((Get-Date) -lt $dl) {
        if ((Get-E2EVm).State -eq 'Off') { $apagada = $true; break }
        Start-Sleep -Seconds 3
      }
    } catch { Write-E2E ('  ! el apagado ordenado fallo: ' + $_.Exception.Message) 'Yellow' }
    if (-not $apagada) {
      # Fallback declarado: -TurnOff es tirar del cable. Se anota porque un apagado
      # sucio puede dejar hives con transacciones pendientes y eso ensucia lo que
      # la capa mide.
      Write-E2E '  el apagado ordenado no termino: -TurnOff (equivale a tirar del cable)' 'Yellow'
      $ev += 'la VM no se apago ordenadamente: se uso -TurnOff. Un hive cerrado a la fuerza puede leerse raro.'
      try {
        Stop-VM -Name $VMName -TurnOff -Force -ErrorAction Stop
        Start-Sleep -Seconds 4
      } catch { }
    } else {
      $ev += 'la VM se apago ordenadamente antes de montar el VHDX'
    }
    $vm = Get-E2EVm
    if ($vm.State -ne 'Off') {
      Set-E2ERes 7 'SIN MEDIR' ("no pude apagar la VM (quedo {0}): no monto el VHDX de una VM encendida" -f $vm.State) $ev $t0; return
    }
  } else { $ev += 'la VM ya estaba apagada' }

  # -ProfilePath: mide contra el perfil de test sin tocar el del usuario.
  $r = Invoke-E2EChild -ScriptArgs @((Join-Path $PSScriptRoot 'test-vm.ps1'), '-Verify', '-VMName', $VMName,
                                     '-ProfilePath', $script:PerfilTestPath) `
                       -TimeoutSec $VerifyOfflineTimeoutSec -Tag 'verifyoffline' -Mostrar

  $baseLog = [System.IO.Path]::GetFileNameWithoutExtension($script:LogPath)
  $rep = Join-Path (Split-Path $script:LogPath -Parent) ($baseLog + '-verify-offline.txt')
  try { $r.Lineas | Set-Content -Path $rep -Encoding ASCII; $ev += ('reporte completo: ' + $rep) } catch { }

  if ($r.TimedOut) {
    $ev += 'OJO: un -Verify cortado a la mitad puede dejar el VHDX montado o un hive cargado. La limpieza del final lo revisa.'
    Set-E2ERes 7 'SIN MEDIR' ("test-vm.ps1 -Verify paso los {0}s y lo corte" -f $VerifyOfflineTimeoutSec) $ev $t0; return
  }
  # ==========================================================================
  #  EL VEREDICTO SALE DEL EXIT CODE, NO DE PARSEAR TEXTO.
  #
  #  test-vm.ps1 -Verify ahora devuelve:  0 = pasa   1 = hay FALLA
  #                                       8 = no hay FALLA pero quedo algo SIN MEDIR
  #  Antes salia 0 SIEMPRE, incluso con FALLA en pantalla, y esta capa tenia que
  #  deducir el resultado con un regexp sobre la salida. Eso se rompe EN SILENCIO el
  #  dia que alguien reformatea un mensaje: el runner diria PASA con el bug presente.
  #  El parseo se conserva, pero solo como EVIDENCIA para el reporte.
  # ==========================================================================
  $nOk    = @($r.Lineas | Where-Object { $_ -match '^\s{2}OK\s' }).Count
  $nFalla = @($r.Lineas | Where-Object { $_ -match '^\s{2}FALLA\s' })
  $nSos   = @($r.Lineas | Where-Object { $_ -match '^\s{2}SOSPECHA\s' })
  $nOjo   = @($r.Lineas | Where-Object { $_ -match '^\s{2}OJO\s' }).Count
  $ev += ("exit code del -Verify: {0}   (0=pasa 1=falla 8=incompleto)" -f $r.ExitCode)
  $ev += ("hallazgos: OK={0} FALLA={1} SOSPECHA={2} OJO={3}" -f $nOk, $nFalla.Count, $nSos.Count, $nOjo)
  foreach ($f in ($nFalla | Select-Object -First 6)) { $ev += ('  ' + $f.Trim()) }

  if ($r.ExitCode -eq 8) {
    Set-E2ERes 7 'SIN MEDIR' 'el -Verify no pudo medir todo (exit 8): no se puede afirmar que pasa' $ev $t0; return
  }
  if ($r.ExitCode -ne 0 -and $r.ExitCode -ne 1) {
    # Un exit code que no es ninguno de los suyos: revento antes de auditar.
    Set-E2ERes 7 'SIN MEDIR' ("test-vm.ps1 -Verify salio con {0}: no llego a auditar" -f $r.ExitCode) $ev $t0; return
  }
  if ($r.ExitCode -eq 1) {
    Set-E2ERes 7 'FALLA' ("el -Verify encontro {0} FALLA en el disco instalado" -f $nFalla.Count) $ev $t0; return
  }

  if (($nOk + $nFalla.Count + $nSos.Count + $nOjo) -eq 0) {
    Set-E2ERes 7 'SIN MEDIR' 'no reconoci ni un hallazgo en la salida del -Verify: no lo doy por bueno' $ev $t0; return
  }
  if ($nFalla.Count -gt 0) {
    Set-E2ERes 7 'FALLA' ("{0} hallazgo(s) FALLA en el disco instalado" -f $nFalla.Count) $ev $t0; return
  }
  if ($nSos.Count -gt 0) {
    Set-E2ERes 7 'SIN MEDIR' ("{0} SOSPECHA y ninguna FALLA: hay que mirarlas a mano" -f $nSos.Count) $ev $t0; return
  }
  Set-E2ERes 7 'PASA' ("{0} chequeos OK sobre el disco instalado, ninguna FALLA" -f $nOk) $ev $t0
}

# ===========================================================================
#  CAPA 8 -- el reporte. Es una capa y no un epilogo porque tambien se puede
#  medir: si el log no quedo escrito, la corrida no dejo evidencia.
# ===========================================================================
function Write-E2EReporte {
  $fin  = Get-Date
  $dur  = $fin - $script:T0Global
  $ancho = 78

  # $script:RepLineas y no una local: el scriptblock de abajo corre en un scope hijo
  # (es una List, o sea referencia, asi que .Add() si persiste -- pero se deja
  # explicito para que nadie lo convierta en una asignacion y lo rompa en silencio).
  $script:RepLineas = New-Object System.Collections.Generic.List[string]
  $add = {
    param([string]$t, [string]$c = 'Gray')
    [void]$script:RepLineas.Add($t)
    Write-E2E $t $c
  }

  & $add ''
  & $add ('=' * $ancho) 'Cyan'
  & $add '  REPORTE E2E de LunaticOS' 'Cyan'
  & $add ('=' * $ancho) 'Cyan'
  if ($Simulate) {
    & $add '  #################################################################' 'Magenta'
    & $add '  #  -Simulate: LAS CAPAS 3..7 NO SE MIDIERON. Este reporte NO' 'Magenta'
    & $add '  #  dice nada sobre el producto: sirve para probar el runner.' 'Magenta'
    & $add '  #################################################################' 'Magenta'
  }
  & $add ("  perfil    {0}   ({1})" -f $script:PerfilNombre, $script:PerfilResumen) 'White'
  & $add ("  VM        {0}" -f $VMName) 'White'
  & $add ("  ventana   capas {0} a {1}{2}" -f $From, $To, $(if ($KeepGoing) { '  (-KeepGoing: no corta en la primera FALLA)' } else { '' })) 'White'
  & $add ("  arranque  {0}      duracion  {1:hh\:mm\:ss}" -f $script:T0Global.ToString('dd/MM/yy HH:mm:ss'), $dur) 'White'
  if ($script:Interrumpido) {
    & $add '  LA CORRIDA NO LLEGO AL FINAL (Ctrl+C o stop): lo que sigue es solo lo que se' 'Yellow'
    & $add '  llego a medir, y el exit code va a ser 3 -- una corrida cortada nunca es un PASA.' 'Yellow'
  } elseif ($script:ErrFatal) {
    & $add ('  EL RUNNER SE CORTO POR UN ERROR PROPIO: ' + $script:ErrFatal.Exception.Message) 'Red'
    & $add '  Eso es un bug del runner, no del producto: lo de abajo puede estar incompleto.' 'Red'
  }
  # El formato de la fila y el del encabezado salen del MISMO -f para que las
  # columnas no se desalineen el dia que alguien renombre una capa.
  $fila = "   {0}  {1,-50} {2,-10} {3,8}"
  & $add ''
  & $add ($fila -f '#', 'capa', 'resultado', 'tiempo') 'DarkGray'
  & $add ('  ' + ('-' * 75)) 'DarkGray'
  foreach ($c in $script:Capas) {
    $r = $script:Res[$c.N]
    $color = switch ($r.Estado) {
      'PASA'      { 'Green' }
      'FALLA'     { 'Red' }
      'SIN MEDIR' { 'Yellow' }
      'SIMULADO'  { 'Magenta' }
      default     { 'DarkGray' }
    }
    $t = if ($r.Seg -gt 0) { ([timespan]::FromSeconds($r.Seg)).ToString('hh\:mm\:ss') } else { '-' }
    & $add ($fila -f $c.N, $c.Nombre, $r.Estado, $t) $color
  }
  & $add ('  ' + ('-' * 75)) 'DarkGray'

  $nF = 0; $nS = 0; $nP = 0; $nSim = 0; $nNo = 0
  foreach ($c in $script:Capas) {
    switch ($script:Res[$c.N].Estado) {
      'PASA'       { $nP++ }
      'FALLA'      { $nF++ }
      'SIN MEDIR'  { $nS++ }
      'SIMULADO'   { $nSim++ }
      default      { $nNo++ }
    }
  }
  # El exit code refleja LA VENTANA PEDIDA: las capas que quedaron afuera de
  # -From/-To no cuentan (el usuario las excluyo a proposito), pero las que estaban
  # adentro y no corrieron SI cuentan -- ahi hubo trabajo que no se hizo.
  $dentroSinCorrer = @($script:Capas | Where-Object {
    $_.N -ge $From -and $_.N -le $To -and $script:Res[$_.N].Estado -eq 'SIN CORRER' })

  $code = 0
  if ($nF -gt 0) { $code = 1 }
  elseif ($nS -gt 0 -or $dentroSinCorrer.Count -gt 0) { $code = 2 }
  # EL CODIGO QUE SE IMPRIME ES EL QUE SE DEVUELVE. Se decide aca, en un solo lugar,
  # con el override de "no llego al final" incluido: la primera version calculaba el
  # 3 en el `exit` del final y el reporte imprimia "exit 2". Un veredicto que no
  # coincide con el exit code es peor que no imprimirlo: la corrida nocturna cree una
  # cosa y el que lee el log cree otra.
  if ($script:ErrFatal -or $script:Interrumpido) { $code = 3 }

  if ($script:Interrumpido) {
    & $add ("  VEREDICTO: CORRIDA CORTADA -- {0} capa(s) medidas, el resto sin correr.   exit {1}" -f ($nP + $nF + $nS), $code) 'Yellow'
  }
  elseif ($script:ErrFatal) {
    & $add ("  VEREDICTO: ERROR DEL RUNNER -- no del producto. Arreglalo y volve a correr.   exit {0}" -f $code) 'Red'
  }
  elseif ($Simulate) {
    & $add ("  VEREDICTO: SIMULACION -- no se midio nada real.   exit {0}" -f $code) 'Magenta'
  }
  elseif ($code -eq 0 -and $From -eq 1 -and $To -eq 8) {
    & $add '  VEREDICTO: PASA -- las 8 capas medidas y en verde.   exit 0' 'Green'
  }
  elseif ($code -eq 0) {
    & $add ("  VEREDICTO: PASA en las capas {0}-{1}. Las de afuera NO se midieron.   exit 0" -f $From, $To) 'Green'
  }
  elseif ($code -eq 1) {
    & $add ("  VEREDICTO: FALLA -- {0} capa(s) en FALLA, {1} SIN MEDIR.   exit 1" -f $nF, $nS) 'Red'
  }
  else {
    & $add ("  VEREDICTO: INCOMPLETO -- ninguna FALLA, pero {0} SIN MEDIR y {1} sin correr.   exit 2" -f $nS, $dentroSinCorrer.Count) 'Yellow'
    & $add '  SIN MEDIR es un resultado valido y honesto: PASA sin evidencia no.' 'Yellow'
  }

  & $add ''
  & $add '  DETALLE Y EVIDENCIA POR CAPA (que se midio, no solo el veredicto):' 'Cyan'
  foreach ($c in $script:Capas) {
    $r = $script:Res[$c.N]
    $color = switch ($r.Estado) {
      'PASA' { 'Green' } 'FALLA' { 'Red' } 'SIN MEDIR' { 'Yellow' } 'SIMULADO' { 'Magenta' } default { 'DarkGray' }
    }
    & $add ("   {0}  {1,-10} {2}" -f $c.N, $r.Estado, $r.Detalle) $color
    foreach ($e in @($r.Evidencia)) { & $add ('        - ' + $e) 'DarkGray' }
  }

  & $add ''
  & $add '  LO QUE NO SE PUEDE MEDIR DESDE UNA VM (contrato, seccion 6):' 'DarkCyan'
  foreach ($n in $script:NoMedible) { & $add ('    SIN MEDIR  ' + $n) 'DarkCyan' }

  & $add ''
  & $add '  EVIDENCIA EN DISCO:' 'Cyan'
  & $add ('    log completo de esta corrida   ' + $script:LogPath) 'White'
  if ($script:PerfilTestPath) { & $add ('    perfil de test usado           ' + $script:PerfilTestPath) 'White' }
  if ($script:PerfilBackup -and (Test-Path "$($script:PerfilBackup)")) {
    & $add ('    backup de TU perfil.json       ' + $script:PerfilBackup) 'White'
  }

  if ($nF -gt 0 -or $nS -gt 0 -or $dentroSinCorrer.Count -gt 0) {
    $primeraMala = @($script:Capas | Where-Object {
      $script:Res[$_.N].Estado -eq 'FALLA' -or $script:Res[$_.N].Estado -eq 'SIN MEDIR' } | Select-Object -First 1)
    if ($primeraMala.Count -gt 0) {
      & $add ''
      & $add '  COMO RETOMAR SIN REHACER LOS 35 MINUTOS:' 'Cyan'
      & $add ("    .\scripts\test-e2e.ps1 -From {0} -Profile {1} -KeepVM" -f $primeraMala[0].N, $script:PerfilNombre) 'White'
      & $add ("    -KeepVM deja la VM viva para mirarla:  vmconnect.exe localhost {0}" -f $VMName) 'DarkGray'
    }
  }
  if ($KeepVM) {
    & $add ''
    & $add ("  -KeepVM: la VM '{0}' queda como esta. Cuando termines de mirarla:" -f $VMName) 'Yellow'
    & $add ("     Stop-VM -Name '{0}'    # y despues el proximo build ya no choca con Error 32" -f $VMName) 'DarkGray'
  }
  & $add ('=' * $ancho) 'Cyan'

  return @{ Code = $code; Lineas = @($script:RepLineas) }
}

# ===========================================================================
#  SIMULACION -- para probar el runner (parseo, -From, cortes, reporte) sin
#  gastar 35 minutos de maquina. NUNCA devuelve PASA: devuelve SIMULADO, que en
#  el reporte no se puede confundir con "se midio y salio bien".
# ===========================================================================
function Invoke-E2ESimulada {
  param([int]$N)
  $t0 = Get-Date
  Start-Sleep -Milliseconds 600
  if ($SimFail -contains $N) {
    Set-E2ERes $N 'FALLA' ("SIMULADO: falla forzada con -SimFail {0}" -f $N) `
      @('no se midio nada: esto viene de -Simulate') $t0; return
  }
  if ($SimSinMedir -contains $N) {
    Set-E2ERes $N 'SIN MEDIR' ("SIMULADO: SIN MEDIR forzado con -SimSinMedir {0}" -f $N) `
      @('no se midio nada: esto viene de -Simulate') $t0; return
  }
  Set-E2ERes $N 'SIMULADO' 'SIMULADO: la capa no corrio de verdad' `
    @('no se midio nada: esto viene de -Simulate') $t0
}

# ===========================================================================
#  MAIN
# ===========================================================================
if ($ListProfiles) { Show-E2EMatriz; exit 0 }

# --- parametros, antes de tocar nada ---
if ($From -lt 1 -or $From -gt 8 -or $To -lt 1 -or $To -gt 8) {
  Write-Host ''
  Write-Host ("  ERROR: -From/-To tienen que estar entre 1 y 8 (me pasaron -From {0} -To {1})." -f $From, $To) -ForegroundColor Red
  Write-Host '  Las capas: 1 self-test  2 TUI  3 build  4 VM  5 instalacion  6 verify-live  7 disco  8 reporte' -ForegroundColor Yellow
  exit 3
}
if ($From -gt $To) {
  Write-Host ''
  Write-Host ("  ERROR: -From {0} es mayor que -To {1}: no hay ninguna capa para correr." -f $From, $To) -ForegroundColor Red
  exit 3
}

# --- ADMIN. Esto monta imagenes, carga hives y toca VMs: sin admin no arranca ---
$idn = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($idn)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Host ''
  Write-Host '  ERROR: esto necesita ADMINISTRADOR.' -ForegroundColor Red
  Write-Host '  Monta imagenes, carga colmenas del registro y maneja VMs de Hyper-V:' -ForegroundColor Yellow
  Write-Host '  sin elevacion la mitad de las capas darian SIN MEDIR y la otra mitad, un error raro.' -ForegroundColor Yellow
  Write-Host ''
  Write-Host '  Abri PowerShell como Administrador y volve a correr:' -ForegroundColor White
  Write-Host ('    .\scripts\test-e2e.ps1 ' + ($MyInvocation.UnboundArguments -join ' ')) -ForegroundColor DarkGray
  exit 3
}

# --- perfil de test ---
$script:PerfilNombre  = $Profile
$script:PerfilTestPath = ''
$script:PerfilResumen  = ''
$script:PerfilPidePers = $false
$script:PerfilPideApps = $false
try {
  # En el scope del SCRIPT, no adentro de una funcion: ver Get-E2ECatalogoSrc.
  Invoke-Expression (Get-E2ECatalogoSrc)
  if (-not (Get-Command New-DefaultProfile -ErrorAction SilentlyContinue)) {
    throw 'no pude cargar New-DefaultProfile de LunaticOS.ps1'
  }
  if ($ProfileFile) {
    if (-not (Test-Path $ProfileFile)) { throw "no existe el perfil que me pasaste: $ProfileFile" }
    $script:PerfilTestPath = (Resolve-Path $ProfileFile).Path
    $script:PerfilNombre   = ('archivo:' + (Split-Path $script:PerfilTestPath -Leaf))
    $raw = Get-Content $script:PerfilTestPath -Raw | ConvertFrom-Json
    $script:PerfilPidePers = @($raw.personalizacion.PSObject.Properties | Where-Object { $_.Value }).Count -gt 0
    $script:PerfilPideApps = @($raw.programas.PSObject.Properties | Where-Object { $_.Value }).Count -gt 0
    $script:PerfilResumen  = ("pers {0}, programas {1}" -f `
      @($raw.personalizacion.PSObject.Properties | Where-Object { $_.Value }).Count,
      @($raw.programas.PSObject.Properties | Where-Object { $_.Value }).Count)
  }
  else {
    $p = New-E2EPerfil -Nombre $Profile
    $script:PerfilResumen  = Get-E2EResumenPerfil $p
    $script:PerfilPidePers = @(@($p.personalizacion.Keys) | Where-Object { $p.personalizacion[$_] }).Count -gt 0
    $script:PerfilPideApps = @(@($p.programas.Keys) | Where-Object { $p.programas[$_] }).Count -gt 0
    $dir = Join-Path $root 'work\logs'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $script:PerfilTestPath = Join-Path $dir ("perfil-test-{0}.json" -f $Profile)
    $p.creado = ('generado por test-e2e.ps1 -Profile ' + $Profile + ' el ' + (Get-Date -Format 'yyyy-MM-dd HH:mm'))
    $p | ConvertTo-Json -Depth 6 | Set-Content -Path $script:PerfilTestPath -Encoding UTF8
  }
}
catch {
  Write-Host ''
  Write-Host ('  ERROR armando el perfil de test: ' + $_.Exception.Message) -ForegroundColor Red
  Write-Host '  Los perfiles disponibles:  .\scripts\test-e2e.ps1 -ListProfiles' -ForegroundColor Yellow
  exit 3
}

# --- log ---
$script:T0Global = Get-Date
$logDir = Join-Path $root 'work\logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$stamp = $script:T0Global.ToString('yyyyMMdd-HHmmss')
$script:LogPath = Join-Path $logDir ("e2e-{0}{1}.log" -f $stamp, $(if ($Simulate) { '-SIMULADO' } else { '' }))
try {
  $script:LogWriter = New-Object System.IO.StreamWriter($script:LogPath, $false, [System.Text.Encoding]::ASCII)
  $script:LogWriter.AutoFlush = $true
} catch {
  Write-Host ('  ! no pude abrir el log ' + $script:LogPath + ': ' + $_.Exception.Message) -ForegroundColor Yellow
}

$reporte = $null
try {
  Write-E2E ''
  Write-E2E '  ####################################################################' 'Cyan'
  Write-E2E '  #  E2E de LunaticOS: de la TUI al SO CORRIENDO' 'Cyan'
  Write-E2E '  ####################################################################' 'Cyan'
  Write-E2E ("  arranque   {0}" -f $script:T0Global.ToString('dd/MM/yyyy HH:mm:ss')) 'White'
  Write-E2E ("  perfil     {0}  ->  {1}" -f $script:PerfilNombre, $script:PerfilResumen) 'White'
  Write-E2E ("  perfil en  {0}" -f $script:PerfilTestPath) 'DarkGray'
  Write-E2E ("  VM         {0}" -f $VMName) 'White'
  Write-E2E ("  capas      {0} a {1}" -f $From, $To) 'White'
  Write-E2E ("  log        {0}" -f $script:LogPath) 'White'
  Write-E2E ("  timeouts   selftest={0}s tui={1}s build={2}s vm={3}s instalacion={4}s asentar={5}s verify-live={6}s verify-offline={7}s" -f `
             $SelfTestTimeoutSec, $TuiTimeoutSec, $BuildTimeoutSec, $VmSetupTimeoutSec,
             $InstallTimeoutSec, $SettleTimeoutSec, $VerifyLiveTimeoutSec, $VerifyOfflineTimeoutSec) 'DarkGray'
  if ($Simulate) {
    Write-E2E ''
    Write-E2E '  -Simulate: las capas 3..7 NO se van a medir. Las 1, 2 y 8 si.' 'Magenta'
  }
  Write-E2E ''

  # Limpieza AL ARRANCAR: si la corrida anterior murio de un Ctrl+C, esto lo dice.
  [void](Invoke-E2ELimpieza -Momento 'arranque')

  # ==========================================================================
  #  EL perfil.json DEL USUARIO NO SE TOCA. Nunca.
  #
  #  Esto antes se pisaba: las capas 6 y 7 leian el perfil de la ruta fija
  #  <repo>\perfil.json, asi que el runner copiaba el de test encima, corria, y lo
  #  restauraba desde el finally. Funcionaba, pero el precio era inaceptable: si el
  #  proceso moria entre el pisado y el restore, el usuario perdia su seleccion y no
  #  se enteraba hasta el proximo build.
  #
  #  Ya no hace falta: verify-live.ps1 y test-vm.ps1 -Verify aceptan -ProfilePath, y
  #  las capas 6 y 7 les pasan el perfil de test por ahi. El del usuario queda
  #  intacto, incluso si esto se muere de un Ctrl+C en el peor momento.
  # ==========================================================================
  $script:PerfilPisado = $false
  Write-E2E ("  tu perfil.json NO se toca: las capas 6 y 7 miden con -ProfilePath") 'DarkGray'
  if ($From -ge 4) {
    Write-E2E ''
    Write-E2E ("  OJO: -From {0} salta el build. Asumo que la ISO y la VM que hay se armaron con el" -f $From) 'Yellow'
    Write-E2E ("       perfil '{0}'. Si no, las capas 6 y 7 van a medir contra otra expectativa." -f $script:PerfilNombre) 'Yellow'
  }

  # --- el bucle de capas ---
  foreach ($c in $script:Capas) {
    if ($c.N -lt $From -or $c.N -gt $To) {
      $script:Res[$c.N] = @{ Estado = 'SIN CORRER'
                             Detalle = ("fuera de la ventana pedida (-From {0} -To {1})" -f $From, $To)
                             Seg = 0; Evidencia = @() }
      continue
    }
    $mala = @($script:Capas | Where-Object { $_.N -lt $c.N -and $script:Res[$_.N].Estado -eq 'FALLA' })
    if ($mala.Count -gt 0 -and -not $KeepGoing -and $c.N -ne 8) {
      $script:Res[$c.N] = @{ Estado = 'SIN CORRER'
                             Detalle = ("no se corrio: la capa {0} fallo. Se retoma con -From {1}" -f $mala[0].N, $c.N)
                             Seg = 0; Evidencia = @() }
      continue
    }

    Write-E2ETitulo $c.N $c.Nombre
    if ($Simulate -and $c.N -ge 3 -and $c.N -le 7) { Invoke-E2ESimulada -N $c.N; continue }

    switch ($c.N) {
      1 { Invoke-E2ECapa1 }
      2 { Invoke-E2ECapa2 }
      3 { Invoke-E2ECapa3 }
      4 { Invoke-E2ECapa4 }
      5 { Invoke-E2ECapa5 }
      6 { Invoke-E2ECapa6 }
      7 { Invoke-E2ECapa7 }
      8 {
        # La capa 8 se resuelve despues del reporte: su medicion ES el reporte.
        $script:Res[8] = @{ Estado = 'PASA'; Detalle = 'reporte emitido'; Seg = 0; Evidencia = @() }
      }
    }
  }
  $script:LoopTermino = $true
}
catch {
  # ==========================================================================
  #  UN CATCH, PORQUE SIN EL EL EXIT CODE LO ELIGE POWERSHELL.
  #  Si algo tira adentro del try, el finally corre igual pero la linea `exit`
  #  del final NO se alcanza: PowerShell termina el proceso con SU codigo y el
  #  veredicto del reporte no llega a nadie. Medido: la limpieza de arranque tiro
  #  por un stderr de reg.exe, el reporte dijo "exit 2" y el proceso salio 1.
  #  Un exit code que no coincide con el reporte rompe cualquier corrida nocturna.
  #  Ctrl+C llega aca como PipelineStoppedException: se reporta como INTERRUMPIDO,
  #  que es lo que paso, y no como un bug del producto.
  # ==========================================================================
  $script:ErrFatal = $_
  $script:Interrumpido = ($_.Exception -is [System.Management.Automation.PipelineStoppedException])
}
finally {
  # ==========================================================================
  #  TODO LO QUE DEJA LA MAQUINA COMO ESTABA VIVE ACA. Tambien con Ctrl+C:
  #  PowerShell corre el finally al desarmar la pipeline. Y si igual se muere de
  #  la peor forma, la limpieza de ARRANQUE de la proxima corrida lo agarra.
  # ==========================================================================
  Write-E2E ''
  Write-E2E '-----------------------------------------------------------------------------' 'DarkGray'
  if (-not $script:LoopTermino -and -not $script:ErrFatal) { $script:Interrumpido = $true }
  if ($script:Interrumpido) {
    Write-E2E '  INTERRUMPIDO (Ctrl+C o stop). Limpio igual y despues reporto lo que si se midio.' 'Yellow'
  }
  elseif ($script:ErrFatal) {
    Write-E2E ('  ERROR NO ESPERADO DEL RUNNER: ' + $script:ErrFatal.Exception.Message) 'Red'
    if ($script:ErrFatal.InvocationInfo) {
      Write-E2E ("  en {0} linea {1}" -f $script:ErrFatal.InvocationInfo.ScriptName,
                 $script:ErrFatal.InvocationInfo.ScriptLineNumber) 'Yellow'
      Write-E2E ('  codigo: ' + "$($script:ErrFatal.InvocationInfo.Line)".Trim()) 'DarkGray'
    }
  }
  try { [void](Invoke-E2ELimpieza -Momento 'salida') }
  catch { Write-E2E ('  ! la limpieza tiro: ' + $_.Exception.Message) 'Red' }

  # La capa 8 mide su propia evidencia: si el log no quedo en disco, la corrida no
  # dejo rastro y eso NO es un PASA.
  if ($script:Res[8].Estado -eq 'PASA') {
    if (Test-Path $script:LogPath) {
      $script:Res[8] = @{ Estado = 'PASA'
                          Detalle = 'reporte por pantalla y log completo en disco'
                          Seg = 0; Evidencia = @(('log: ' + $script:LogPath)) }
    } else {
      $script:Res[8] = @{ Estado = 'FALLA'; Detalle = 'el log no quedo escrito: la corrida no dejo evidencia'
                          Seg = 0; Evidencia = @() }
    }
  }

  try { $reporte = Write-E2EReporte }
  catch { Write-Host ('  ! no pude armar el reporte: ' + $_.Exception.Message) -ForegroundColor Red }

  if ($script:TmpDir -and (Test-Path $script:TmpDir)) {
    # La salida cruda de los hijos ya esta entera en el log: los temporales no aportan.
    Remove-Item $script:TmpDir -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($script:LogWriter) { try { $script:LogWriter.Flush(); $script:LogWriter.Close() } catch { } }
}

# UN SOLO exit, y el codigo es EL MISMO que imprimio el reporte (Write-E2EReporte ya
# aplico el override de error/interrupcion). Si el reporte no se pudo armar, 3: sin
# reporte no hay veredicto, y sin veredicto no hay 0.
exit $(if ($reporte) { [int]$reporte.Code } else { 3 })
