#requires -Version 5.1
<#
  verify-live.ps1 -- Verificacion del SO CORRIENDO, por PowerShell Direct.
  Contrato: docs\testing-e2e.md seccion 3. Fuente de verdad de tema/color/policies:
  docs\personalizacion-contrato.md.

  ===========================================================================
  POR QUE EXISTE (y por que NO duplica a test-vm.ps1 -Verify)

  El -Verify de test-vm.ps1 mide HIVES OFFLINE sobre el VHDX apagado. Eso alcanza
  para "que escribimos" y NO alcanza para "que esta pasando". Lo que offline es
  OPACO y aca se mide de verdad:

    1. LA ACTIVACION. Vive en tokens.dat y HKLM\SYSTEM\WPA: blobs opacos. El
       -Verify offline lo dice con estas palabras -- "NO invento un resultado" -- y
       manda a correr slmgr /xpr dentro de la VM. Esto es eso.
    2. LOS COLORES EFECTIVOS. Que un DWORD diga #14B8A6 NO prueba que la UI lo use.
       Ya pasamos por tener el registro correcto y la pantalla en modo claro.
    3. winget y las apps realmente instaladas.
    4. LOS SERVICIOS en su estado real. Start=4 en el hive no garantiza que el SO
       haya arrancado bien sin ellos.
    5. QUE EXPLORER SOBREVIVIO AL PRIMER LOGIN (issue #329 de unattend-generator:
       escritorio gris sin shell). Offline no se ve.
    6. Que Settings > Personalization se pueda abrir sin el cartel de organizacion.

  ===========================================================================
  EL MECANISMO Y SU UNICO REQUISITO

  Invoke-Command -VMName (PowerShell Direct) NO funciona con password vacio. Ese
  es el unico motivo por el que config\autounattend-test.xml existe aparte del de
  produccion (que deja el password VACIO a proposito: no se hardcodea un secreto
  en una ISO que se reparte).

  Si esta VM se instalo con el autounattend de PRODUCCION, la conexion se rechaza
  y este script lo dice con esas palabras y con el arreglo (exit 5). NO lo maquilla
  como un OK.

  EL PASSWORD NO SE IMPRIME NUNCA: ni en pantalla, ni en el objeto de salida, ni en
  un mensaje de error. Todo texto de excepcion pasa por Hide-Secret antes de salir.

  ===========================================================================
  QUIEN JUZGA: EL HOST. QUIEN MIDE: EL INVITADO.

  El scriptblock que corre adentro de la VM NO emite veredictos: junta DATO CRUDO y
  lo devuelve. Todo el juicio se hace en el host, con los MISMOS helpers que usa el
  -Verify offline (Test-AccentAlignment, Get-SettingsBlockerFindings,
  Get-RunOnceLogFindings, Get-CustomThemeFindings, ConvertTo-AccentDwords).

  Dos razones, las dos aprendidas a golpes en este repo:
    - UN SOLO INSTRUMENTO. Si el live tuviera su propia conversion de color o su
      propia lista de policies, podria equivocarse igual que el producto y darle la
      razon al bug. Ya paso: siete veces fallo el instrumento y no el producto.
    - SE PUEDE PROBAR SIN VM. Dot-sourceando este archivo se cargan SOLO las
      funciones de juicio, asi que se las puede correr contra un payload armado a
      mano:
          . .\verify-live.ps1
          Get-LiveExplorerFindings -Payload @{ Explorer = @() }     # -> FALLA GRAVE
      Un chequeo que no se puede probar no es un chequeo.

  ===========================================================================
  LOS NIVELES, Y POR QUE "SIN MEDIR" NO ES LO MISMO QUE "NO MEDIBLE"

    OK          medido y correcto.
    FALLA       medido y mal.                          -> exit 1
    SOSPECHA    de la CLASE de un bug conocido, sin estar en la lista literal.
    OJO         raro o esperable-pero-anotado (ej: la VM sin activar).
    SIN MEDIR   SE PODIA medir y no se pudo (dato faltante, error del invitado).
                No se rellena con un OK.               -> exit 8
    NO MEDIBLE  estructuralmente imposible desde aca (ej: probar que la pagina de
                Settings ABRE sin lanzar UI a ciegas). Se declara y no se inventa.
                NO afecta el exit code: no es una falta, es un limite conocido.

  Separar los dos ultimos es a proposito. Si "no medible" contara como "sin medir",
  el exit 8 seria el resultado normal y dejaria de significar algo.

  ===========================================================================
  EXIT CODES (el runner los consume)

    0  PASA        ni FALLA ni SIN MEDIR
    1  FALLA       uno o mas chequeos fallaron
    2  la VM no existe
    3  la VM no esta Running (este script NO la arranca: es un observador)
    4  sin credenciales usables (Get-TestVmAccount fallo, o password vacio)
    5  PowerShell Direct RECHAZO la credencial  <-- el caso "se instalo con el
                                                    autounattend de produccion"
    6  timeout: la VM no contesto, o la recoleccion se colgo
    7  el host no puede usar PowerShell Direct (sin admin / sin modulo Hyper-V)
    8  INCOMPLETO  sin FALLA pero con chequeos SIN MEDIR

  ===========================================================================
  LA VM QUEDA COMO ESTABA. Este script LEE. No instala, no configura, no reinicia,
  no apaga y no lanza ventanas. Lo unico que deja es la sesion de PowerShell Direct
  que Invoke-Command abre y cierra sola.

  ===========================================================================
  Uso:
    .\verify-live.ps1                                   # VM LunaticOS-Test, credencial del XML
    .\verify-live.ps1 -VMName X -User u -Password p     # credencial explicita
    . .\verify-live.ps1                                 # dot-source: SOLO las funciones
#>
param(
  [string]$VMName = 'LunaticOS-Test',
  [string]$User     = '',
  [string]$Password = '',
  [int]$ConnectTimeoutSec = 240,   # presupuesto TOTAL para lograr la primera respuesta
  [int]$ProbeTimeoutSec   = 60,    # timeout de CADA intento de conexion
  [int]$CollectTimeoutSec = 300,   # timeout de la recoleccion adentro de la VM
  # ==========================================================================
  #  Perfil contra el cual comparar. Vacio = <repo>\perfil.json, el del usuario.
  #
  #  POR QUE EXISTE ESTE PARAMETRO: sin el, este script leia SIEMPRE la ruta fija
  #  <repo>\perfil.json, asi que el runner del E2E tenia que PISAR el perfil del
  #  usuario con el perfil de test, correr, y restaurarlo desde un finally. Eso
  #  funcionaba, pero sobreescribir el archivo de alguien para poder medir es un
  #  precio que no hay que pagar: si el proceso muere entre el pisado y el
  #  restore, el usuario pierde su seleccion y no se entera hasta el proximo build.
  # ==========================================================================
  [string]$ProfilePath = '',
  [switch]$Quiet                   # no imprime; el reporte queda en el objeto (.Lines)
)

# ===========================================================================
#  TRAMPA MEDIDA: dot-sourcear test-vm.ps1 PISA $VMName.
#
#  Un script dot-sourceado corre en el scope del que lo llama, asi que su bloque
#  param() BINDEA SUS DEFAULTS EN MI SCOPE. test-vm.ps1 declara
#  [string]$VMName = 'LunaticOS-Test', o sea que despues del dot-source mi $VMName
#  vale 'LunaticOS-Test' AUNQUE me hayan pasado otro nombre. Comprobado:
#     verify -VMName 'OTRA-VM'  ->  antes: OTRA-VM   despues: LunaticOS-Test
#  Con el default igual al mio el bug es INVISIBLE, y el sintoma seria "verifique
#  la VM equivocada y dije que estaba todo bien", que es la peor clase de falso OK.
#
#  Por eso los parametros se copian ANTES del dot-source y de ahi en adelante se usan
#  SOLO las copias. No uses $VMName mas abajo.
# ===========================================================================
$LiveVM       = $VMName
$LiveUser     = $User
$LivePassword = $Password

. "$PSScriptRoot\config.ps1"
. "$PSScriptRoot\lib.ps1"
# test-vm.ps1 dot-sourceado carga SOLO sus funciones de auditoria (tiene la guarda
# InvocationName -eq '.'). De ahi salen los jueces compartidos con el -Verify offline.
. "$PSScriptRoot\test-vm.ps1"

$script:ReportLines = New-Object System.Collections.Generic.List[string]
$script:Groups      = New-Object System.Collections.Generic.List[object]
$script:Payload     = $null
$script:Connected   = $false
$script:GuestInfo   = $null
$script:TempFiles   = New-Object System.Collections.Generic.List[string]

# ---------------------------------------------------------------------------
#  Salida: todo lo que se imprime queda TAMBIEN en el objeto (.Lines).
#  Write-Host no va al pipeline -- ya nos costo un log vacio -- asi que el runner
#  no tiene que pelearse con transcripciones para guardar el reporte.
# ---------------------------------------------------------------------------
function Write-LiveLine {
  param([string]$Text = '', [string]$Color = 'Gray')
  [void]$script:ReportLines.Add($Text)
  if (-not $Quiet) { Write-Host $Text -ForegroundColor $Color }
}

function Write-LiveFinding {
  param($Finding)
  $lvl = "$($Finding.Level)"
  $color = switch ($lvl) {
    'OK'         { 'Green' }
    'FALLA'      { 'Red' }
    'SOSPECHA'   { 'Magenta' }
    'OJO'        { 'Yellow' }
    'SIN MEDIR'  { 'Yellow' }
    'NO MEDIBLE' { 'DarkCyan' }
    default      { 'DarkGray' }
  }
  Write-LiveLine ("  {0,-10} {1}" -f $lvl, "$($Finding.Text)") $color
}

function Add-LiveGroup {
  param([Parameter(Mandatory)][string]$Name, $Findings)
  $arr = @()
  foreach ($f in $Findings) { if ($f) { $arr += $f } }
  $script:Groups.Add([pscustomobject]@{ Name = $Name; Findings = $arr })
  Write-LiveLine ''
  Write-LiveLine ("--- {0} ---" -f $Name) 'Cyan'
  foreach ($f in $arr) { Write-LiveFinding $f }
}

function New-LiveFinding {
  # [AllowEmptyString] en $Text a proposito: un dato del invitado puede venir vacio
  # (un producto de licencia sin Name, por ejemplo) y con [string] Mandatory pelado
  # PowerShell RECHAZA el string vacio y tira -- o sea que un dato raro de la VM
  # mataria la verificacion entera en vez de reportarse. El reporte tiene que
  # sobrevivir a los datos feos: para eso existe.
  param(
    [Parameter(Mandatory)][string]$Level,
    [Parameter(Mandatory)][AllowEmptyString()][string]$Text
  )
  return @{ Level = $Level; Text = $Text }
}

# ---------------------------------------------------------------------------
#  EL PASSWORD NO SALE DE ACA. Ni por un mensaje de excepcion.
#
#  Es un secreto que no protege nada (vive en una VM descartable y esta versionado
#  a proposito), pero los logs de work\logs\ se comparten para diagnosticar y un
#  password en un log ensena que esta bien poner passwords en los logs.
# ---------------------------------------------------------------------------
function Hide-Secret {
  param([string]$Text, [string]$Secret = '')
  $t = "$Text"
  $s = $Secret
  if (-not $s) { $s = $script:SecretForRedaction }
  if ($s -and $s.Length -ge 3 -and $t) { $t = $t -replace [regex]::Escape($s), '<REDACTADO>' }
  return $t
}

# ---------------------------------------------------------------------------
#  TIMEOUT EN TODO. Un chequeo que se cuelga para siempre hace que nadie vuelva a
#  correr el E2E.
#
#  Invoke-Command -VMName SE CUELGA si el invitado esta a medio arrancar, y no tiene
#  parametro de timeout. Se ejecuta en un runspace aparte y se espera con
#  WaitOne(ms): asi el cuelgue del invitado es un TIMEOUT REPORTADO y no un E2E
#  abandonado.
#
#  Por que un runspace y no Start-Job: el job serializa los argumentos, y hay que
#  pasar un PSCredential. En el runspace es el MISMO objeto en el MISMO proceso: no
#  hay serializacion de secretos ni dependencia de DPAPI.
#
#  Y por que no se hace Dispose() cuando hubo timeout: Dispose sobre un pipeline
#  clavado en una llamada nativa BLOQUEA -- seria cambiar un cuelgue por otro. El
#  runspace queda huerfano a proposito; el proceso termina en segundos.
# ---------------------------------------------------------------------------
function Invoke-LiveWithTimeout {
  param(
    [Parameter(Mandatory)][string]$Code,
    [hashtable]$Parameters = @{},
    [int]$TimeoutSec = 60
  )
  $ps = [powershell]::Create()
  [void]$ps.AddScript($Code)
  foreach ($k in @($Parameters.Keys)) { [void]$ps.AddParameter($k, $Parameters[$k]) }
  $handle = $null
  try {
    $handle = $ps.BeginInvoke()
    $ms = [int]([Math]::Max(1, [Math]::Min($TimeoutSec, 3600)) * 1000)
    if (-not $handle.AsyncWaitHandle.WaitOne($ms)) {
      try { [void]$ps.BeginStop($null, $null) } catch { }
      return @{ TimedOut = $true; Output = @(); Errors = @() }
    }
    $out  = @($ps.EndInvoke($handle))
    $errs = @()
    foreach ($e in $ps.Streams.Error) {
      $errs += (Hide-Secret ("{0} [{1}]" -f "$($e.Exception.Message)", "$($e.FullyQualifiedErrorId)"))
    }
    $ps.Dispose()
    return @{ TimedOut = $false; Output = $out; Errors = $errs }
  }
  catch {
    $msg = Hide-Secret "$($_.Exception.Message)"
    try { $ps.Dispose() } catch { }
    return @{ TimedOut = $false; Output = @(); Errors = @($msg) }
  }
}

# El texto que corre en el runspace. Recibe el codigo del invitado como TEXTO y lo
# reconstruye ahi: un scriptblock creado en otro runspace tiene afinidad con el suyo
# y pasarlo entre runspaces es una fuente de rarezas que no vale la pena.
$script:LiveRemoteRunner = @'
param($VMName, $Cred, $GuestCode, $GuestArgs)
$ErrorActionPreference = 'Stop'
$sb = [scriptblock]::Create($GuestCode)
if ($null -eq $GuestArgs) { $GuestArgs = @() }
Invoke-Command -VMName $VMName -Credential $Cred -ScriptBlock $sb -ArgumentList $GuestArgs
'@

# ---------------------------------------------------------------------------
#  Clasificacion del error de conexion. Importa MUCHISIMO cual es: "credencial
#  rechazada" y "el invitado todavia no atiende" se arreglan de formas opuestas
#  (reinstalar con el unattend de test vs esperar) y confundirlas cuesta una
#  corrida de 35 minutos.
#
#  Se matchea en ingles Y en castellano: el host puede tener cualquier UI.
# ---------------------------------------------------------------------------
function Get-LiveConnectErrorKind {
  param($Errors)
  $t = (@($Errors) -join ' ; ')
  if ($t -match '(?i)credential (is )?invalid|invalid credential|logon failure|user name or password|1326|credencial.*(no es valida|invalida)|nombre de usuario o la contrase') {
    return 'CRED'
  }
  if ($t -match '(?i)not in (the )?running state|is not running|no esta en ejecucion|not currently running') { return 'NOTRUNNING' }
  if ($t -match '(?i)not listening|connection attempt failed|operation timed out|timed out|Hyper-V socket|no se pudo conectar|target process') { return 'NOTREADY' }
  if ($t -match '(?i)cannot find the virtual machine|no such virtual machine|not find a virtual machine') { return 'NOVM' }
  if ($t -match '(?i)access is denied|acceso denegado') { return 'DENIED' }
  if (-not $t) { return 'NONE' }
  return 'OTHER'
}

# ===========================================================================
#  EL RECOLECTOR QUE CORRE ADENTRO DE LA VM
#
#  Reglas de este bloque, todas por una razon:
#    - NO emite veredictos. Devuelve dato crudo. El juez es el host.
#    - Cada medicion en su try/catch: un chequeo que revienta no se lleva puestos
#      los otros ocho.
#    - NADA que pueda colgarse sin timeout. Los .exe se lanzan con
#      Process.WaitForExit(ms) y se matan si se pasan.
#    - NO ESCRIBE NADA. Ni un archivo, ni una clave, ni un proceso nuevo con UI.
#    - ASCII puro, PowerShell 5.1: es el PowerShell del invitado, no el del host.
# ===========================================================================
$script:LiveGuestCode = @'
param($AskedServices, $AskedAppx)

$ErrorActionPreference = 'Continue'
$R = @{}
$R.Errors = New-Object System.Collections.Generic.List[string]
function Note($m) { [void]$R.Errors.Add("$m") }

function RegRaw($path, $name) {
  try { return (Get-ItemProperty -LiteralPath $path -Name $name -ErrorAction Stop).$name }
  catch { return $null }
}

# UN REG_DWORD CON EL BIT 31 PRENDIDO LLEGA COMO Int32 NEGATIVO.
# Todo ARGB/ABGR con alpha FF lo tiene prendido, asi que sin esta mascara el color
# viaja negativo y el hex sale de otro planeta. Ese cast ya fallo dos veces en este
# repo (ver el commit del overflow de Int32).
function RegU32($path, $name) {
  $v = RegRaw $path $name
  if ($null -eq $v) { return $null }
  try { return [uint32]([uint64]((([int64]$v)) -band 0xFFFFFFFFL)) } catch { return $null }
}

function FileLines($path) {
  if (-not "$path") { return $null }
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  try { return @(Get-Content -LiteralPath $path -ErrorAction Stop) } catch { return $null }
}

# Un .exe con timeout DURO. Y las salidas se leen ASINCRONAS antes del WaitForExit:
# si el proceso llena el buffer del pipe y nadie lo vacia, se bloquea para siempre.
# Ese es el deadlock clasico de RedirectStandardOutput, y aca seria un cuelgue.
function RunExe($exe, $argLine, $timeoutMs) {
  $out = @{ Ran = $false; TimedOut = $false; ExitCode = $null; Out = ''; Err = ''; Error = '' }
  if (-not (Test-Path -LiteralPath $exe)) { $out.Error = "no existe $exe"; return $out }
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $exe
    $psi.Arguments              = $argLine
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    $p  = [System.Diagnostics.Process]::Start($psi)
    $so = $p.StandardOutput.ReadToEndAsync()
    $se = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($timeoutMs)) {
      $out.TimedOut = $true
      try { $p.Kill() } catch { }
      return $out
    }
    $out.Ran      = $true
    $out.ExitCode = $p.ExitCode
    $out.Out      = "$($so.Result)"
    $out.Err      = "$($se.Result)"
  }
  catch { $out.Error = "$($_.Exception.Message)" }
  return $out
}

# --- identidad y tiempos ---------------------------------------------------
$R.ComputerName = "$env:COMPUTERNAME"
$R.WhoAmI       = "$env:USERDOMAIN\$env:USERNAME"
$R.PsVersion    = "$($PSVersionTable.PSVersion)"
$R.Now          = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
$R.Os           = @{ Caption = ''; Version = ''; Build = ''; InstallDate = ''; LastBoot = ''; UpMin = $null }
$osCim = $null
try { $osCim = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop }
catch { Note "Win32_OperatingSystem: $($_.Exception.Message)" }
if ($osCim) {
  $R.Os.Caption     = "$($osCim.Caption)"
  $R.Os.Version     = "$($osCim.Version)"
  $R.Os.Build       = "$($osCim.BuildNumber)"
  $R.Os.InstallDate = $osCim.InstallDate.ToString('yyyy-MM-dd HH:mm:ss')
  $R.Os.LastBoot    = $osCim.LastBootUpTime.ToString('yyyy-MM-dd HH:mm:ss')
  $R.Os.UpMin       = [math]::Round(((Get-Date) - $osCim.LastBootUpTime).TotalMinutes, 1)
}
$R.DisplayVersion = "$(RegRaw 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'DisplayVersion')"
$R.EditionId      = "$(RegRaw 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'EditionID')"

# --- 1. ACTIVACION ---------------------------------------------------------
# PartialProductKey son los ULTIMOS 5 de la clave y ya viene parcial de fabrica:
# es lo unico de la licencia que se puede loguear (contrato 6).
$R.Activation       = @()
$R.ActivationFailed = $false
try {
  $flt = "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL"
  foreach ($p in @(Get-CimInstance -ClassName SoftwareLicensingProduct -Filter $flt -ErrorAction Stop)) {
    $R.Activation += @{
      Name                = "$($p.Name)"
      Description         = "$($p.Description)"
      LicenseStatus       = [int]$p.LicenseStatus
      LicenseStatusReason = "$($p.LicenseStatusReason)"
      PartialProductKey   = "$($p.PartialProductKey)"
      ProductKeyChannel   = "$($p.ProductKeyChannel)"
      GraceMinutes        = [int]$p.GracePeriodRemaining
    }
  }
}
catch { $R.ActivationFailed = $true; Note "SoftwareLicensingProduct: $($_.Exception.Message)" }

# slmgr /xpr SIEMPRE invocando CSCRIPT.EXE por ruta, NUNCA 'slmgr /xpr' pelado: el
# host de scripts por defecto es wscript.exe, que muestra el resultado en un MsgBox y
# espera el OK. En una sesion sin escritorio interactivo eso no es "lento": es un
# cuelgue eterno. Lo que protege de eso es elegir cscript.exe a mano, que es un host
# de consola y nunca abre un dialogo.
#
# Y NO SE USA //B. MEDIDO en una maquina activada:
#     cscript //Nologo //B slmgr.vbs /xpr  ->  exit 0 y CERO salida
#     cscript //Nologo     slmgr.vbs /xpr  ->  "The machine is permanently activated."
# El modo batch se COME el WScript.Echo, o sea que el chequeo devolvia "Ran=True,
# exit=0" con la evidencia vacia: un OK sin dato, justo lo que este archivo existe
# para no hacer. Se descubrio corriendo el recolector de verdad, no leyendolo.
$R.Slmgr = @{ Ran = $false; Error = 'no se intento' }
$slmgr = Join-Path $env:SystemRoot 'System32\slmgr.vbs'
if (Test-Path -LiteralPath $slmgr) {
  $R.Slmgr = RunExe (Join-Path $env:SystemRoot 'System32\cscript.exe') ('//Nologo "' + $slmgr + '" /xpr') 90000
} else {
  $R.Slmgr = @{ Ran = $false; Error = "no existe $slmgr" }
}

# --- 2. TEMA Y COLOR ------------------------------------------------------
# HKCU de ESTA sesion = el hive del usuario logueado (la sesion de PowerShell Direct
# corre como el mismo usuario que tiene el escritorio abierto por AutoLogon).
$kThemes = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes'
$kPers   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$kDwm    = 'HKCU:\Software\Microsoft\Windows\DWM'
$kAccent = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent'
$R.Theme = @{
  AppsUseLightTheme     = RegU32 $kPers 'AppsUseLightTheme'
  SystemUsesLightTheme  = RegU32 $kPers 'SystemUsesLightTheme'
  EnableTransparency    = RegU32 $kPers 'EnableTransparency'
  ColorPrevalence       = RegU32 $kPers 'ColorPrevalence'
  DwmColorPrevalence    = RegU32 $kDwm  'ColorPrevalence'
  AccentColor           = RegU32 $kDwm  'AccentColor'
  AccentColorInactive   = RegU32 $kDwm  'AccentColorInactive'
  ColorizationColor     = RegU32 $kDwm  'ColorizationColor'
  ColorizationAfterglow = RegU32 $kDwm  'ColorizationAfterglow'
  AccentColorMenu       = RegU32 $kAccent 'AccentColorMenu'
  StartColorMenu        = RegU32 $kAccent 'StartColorMenu'
  AccentPaletteHex      = ''
  CurrentTheme          = "$(RegRaw $kThemes 'CurrentTheme')"
  PersonalizeNames      = @()
}
$pal = RegRaw $kAccent 'AccentPalette'
if ($pal) {
  $sb = New-Object System.Text.StringBuilder
  foreach ($b in @($pal)) { [void]$sb.Append(('{0:X2}' -f [byte]$b)) }
  $R.Theme.AccentPaletteHex = $sb.ToString()
}
try {
  $kp = Get-Item -LiteralPath $kPers -ErrorAction Stop
  $R.Theme.PersonalizeNames = @($kp.GetValueNames())
} catch { Note "Themes\Personalize: $($_.Exception.Message)" }

$R.Theme.CustomThemePath    = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Themes\Custom.theme'
$R.Theme.CustomThemeLines   = FileLines $R.Theme.CustomThemePath
$R.Theme.CurrentThemeLines  = FileLines $R.Theme.CurrentTheme
$R.Theme.InstalledThemePath = Join-Path $env:SystemRoot 'Resources\Themes\LunaticOS.theme'

# EL COLOR EFECTIVO, no el escrito. Dos fuentes, las dos fuera del registro:
#
#   UISettings (WinRT) es lo que las apps de la plataforma consultan para pintarse:
#   GetColorValue(Accent) es el acento que la UI USA y GetColorValue(Background) es
#   NEGRO en modo oscuro y BLANCO en modo claro. Eso responde exactamente la
#   pregunta que el registro no puede responder ("el DWORD dice oscuro, la pantalla
#   se ve clara").
#   UIColorType: Background=0 Foreground=1 AccentDark3=2 AccentDark2=3 AccentDark1=4
#                Accent=5 AccentLight1=6 AccentLight2=7 AccentLight3=8
#   Se pasa el numero y se documenta la tabla: el enum puede no resolver en una
#   sesion remota, el numero siempre resuelve.
$R.Effective = @{ Ok = $false; Error = ''; AccentHex = ''; BackgroundHex = ''; ForegroundHex = '' }
try {
  [void][Windows.UI.ViewManagement.UISettings, Windows.UI.ViewManagement, ContentType=WindowsRuntime]
  $ui = New-Object Windows.UI.ViewManagement.UISettings
  $ca = $ui.GetColorValue(5)
  $cb = $ui.GetColorValue(0)
  $cf = $ui.GetColorValue(1)
  $R.Effective.AccentHex     = ('#{0:X2}{1:X2}{2:X2}' -f [int]$ca.R, [int]$ca.G, [int]$ca.B)
  $R.Effective.BackgroundHex = ('#{0:X2}{1:X2}{2:X2}' -f [int]$cb.R, [int]$cb.G, [int]$cb.B)
  $R.Effective.ForegroundHex = ('#{0:X2}{1:X2}{2:X2}' -f [int]$cf.R, [int]$cf.G, [int]$cf.B)
  $R.Effective.Ok = $true
}
catch { $R.Effective.Error = "$($_.Exception.Message)" }

#   DwmGetColorizationColor es el color que el COMPOSITOR esta usando. PreserveSig
#   a proposito, para leer el HRESULT de verdad: sin eso un fallo real llega como
#   excepcion y el codigo que se loguea es mentira. Es la misma leccion que el
#   contrato 2.10-D sobre AddAndSelectTheme.
$R.DwmApi = @{ Ok = $false; Error = ''; Hr = ''; Raw = ''; Hex = ''; Opaque = $null }
try {
  if (-not ('LunaticLive.DwmProbe' -as [type])) {
    Add-Type -Namespace LunaticLive -Name DwmProbe -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("dwmapi.dll", PreserveSig = true)]
public static extern int DwmGetColorizationColor(out uint pcrColorization, out bool pfOpaqueBlend);
"@
  }
  $c = [uint32]0
  $op = $false
  $hr = [LunaticLive.DwmProbe]::DwmGetColorizationColor([ref]$c, [ref]$op)
  $R.DwmApi.Hr = ('0x{0:X8}' -f [uint32]$hr)
  if ($hr -eq 0) {
    $R.DwmApi.Ok     = $true
    $R.DwmApi.Raw    = ('0x{0:X8}' -f $c)
    $R.DwmApi.Hex    = ('#{0:X2}{1:X2}{2:X2}' -f [int](($c -shr 16) -band 0xFF), [int](($c -shr 8) -band 0xFF), [int]($c -band 0xFF))
    $R.DwmApi.Opaque = [bool]$op
  }
}
catch { $R.DwmApi.Error = "$($_.Exception.Message)" }

# --- 3. EXPLORER ----------------------------------------------------------
$R.Explorer = @()
foreach ($p in @(Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
  $st = ''; $sec = $null
  try {
    $st = $p.StartTime.ToString('yyyy-MM-dd HH:mm:ss')
    if ($osCim) { $sec = [math]::Round(($p.StartTime - $osCim.LastBootUpTime).TotalSeconds, 1) }
  } catch { }
  $R.Explorer += @{ Id = [int]$p.Id; SessionId = [int]$p.SessionId; StartTime = $st; SecondsAfterBoot = $sec }
}
$R.DwmProcs   = @(Get-Process -Name dwm     -ErrorAction SilentlyContinue).Count
$R.LogonUiPro = @(Get-Process -Name LogonUI -ErrorAction SilentlyContinue).Count

# --- 4. SERVICIOS ---------------------------------------------------------
# Los per-user (PimIndexMaintenanceSvc, OneSyncSvc...) existen como PLANTILLA y como
# instancia '<nombre>_<luid>'. El offline mide la plantilla en ControlSet001; aca hay
# que mirar las dos o el chequeo dice "no existe" con el servicio delante.
# OJO con "$s_*": PowerShell parsearia $s_ como variable. Va ($s + '_*').
$R.Services = @()
foreach ($s in @($AskedServices)) {
  $item = @{ Asked = "$s"; Instances = @() }
  $found = @()
  try { $found += @(Get-Service -Name "$s" -ErrorAction SilentlyContinue) } catch { }
  try { $found += @(Get-Service -Name ("$s" + '_*') -ErrorAction SilentlyContinue) } catch { }
  foreach ($svc in $found) {
    $st = ''
    try { $st = "$($svc.StartType)" } catch { $st = '?' }
    $item.Instances += @{ Name = "$($svc.Name)"; Status = "$($svc.Status)"; StartType = $st }
  }
  $R.Services += $item
}

# --- 5. APPX -------------------------------------------------------------
# La fecha de creacion de InstallLocation es lo que distingue "no lo removimos" de
# "se reinstalo solo": un paquete que venia en la imagen tiene la carpeta creada
# durante el setup; uno que volvio por Windows Update la tiene creada despues. Se
# mide el TIEMPO, no una lista de nombres: la lista es lo que sabemos hoy.
$R.AppxScope = 'AllUsers'
$R.AppxError = ''
$pkgs = @()
try { $pkgs = @(Get-AppxPackage -AllUsers -ErrorAction Stop) }
catch {
  $R.AppxScope = 'CurrentUser'
  $R.AppxError = "$($_.Exception.Message)"
  try { $pkgs = @(Get-AppxPackage -ErrorAction Stop) } catch { $R.AppxError += " / " + "$($_.Exception.Message)" }
}
$R.Appx = @()
foreach ($p in $pkgs) {
  $loc = "$($p.InstallLocation)"
  $cre = ''
  $min = $null
  if ($loc -and (Test-Path -LiteralPath $loc)) {
    try {
      $ci = (Get-Item -LiteralPath $loc -Force -ErrorAction Stop).CreationTime
      $cre = $ci.ToString('yyyy-MM-dd HH:mm:ss')
      if ($osCim) { $min = [math]::Round(($ci - $osCim.InstallDate).TotalMinutes, 1) }
    } catch { }
  }
  $R.Appx += @{ Name = "$($p.Name)"; Version = "$($p.Version)"; Location = $loc; Created = $cre; MinutesAfterInstall = $min }
}

# --- 6. WINGET -----------------------------------------------------------
$R.Winget = @{ Path = ''; AliasPath = ''; AliasExists = $false; PackageVersion = ''; Run = $null }
$cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
if ($cmd) { $R.Winget.Path = "$($cmd.Source)" }
$alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
$R.Winget.AliasPath   = $alias
$R.Winget.AliasExists = [bool](Test-Path -LiteralPath $alias)
try {
  $dai = @(Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction SilentlyContinue) | Select-Object -First 1
  if ($dai) { $R.Winget.PackageVersion = "$($dai.Version)" }
} catch { }
$exe = $R.Winget.Path
if (-not $exe -and $R.Winget.AliasExists) { $exe = $alias }
if ($exe) { $R.Winget.Run = RunExe $exe '--version' 30000 }

# --- logs de LunaticOS ---------------------------------------------------
$R.RunOnceLog = @{ Path = 'C:\ProgramData\LunaticOS\personalizar.log' }
$R.RunOnceLog.Lines = FileLines $R.RunOnceLog.Path
$R.AppsLog = @{ Path = 'C:\ProgramData\LunaticOS\install-apps.log' }
$R.AppsLog.Lines = FileLines $R.AppsLog.Path

# --- 8. POLICIES ---------------------------------------------------------
# Se usa el provider del registro y no reg.exe: aca no hay hive offline que se
# pueda quedar cargado, asi que el motivo del reg.exe del -Verify no aplica.
# Las rutas se normalizan a HKLM\... / HKCU\... porque el juez del host
# (Get-SettingsBlockerFindings) matchea sobre esas rutas REALES.
function DumpPolicyBranch($psPath, $label) {
  $out = @()
  if (-not (Test-Path -LiteralPath $psPath)) { return $out }
  $keys = @()
  try { $keys += @(Get-Item -LiteralPath $psPath -ErrorAction Stop) } catch { return $out }
  try { $keys += @(Get-ChildItem -LiteralPath $psPath -Recurse -ErrorAction SilentlyContinue) } catch { }
  foreach ($k in $keys) {
    if (-not $k) { continue }
    $real = "$($k.Name)" -replace '^HKEY_LOCAL_MACHINE', 'HKLM' -replace '^HKEY_CURRENT_USER', 'HKCU'
    $names = @()
    try { $names = @($k.GetValueNames()) } catch { }
    if ($names.Count -eq 0) {
      $out += @{ Branch = $label; Key = $real; Name = ''; Type = '(clave sin valores)'; Data = '' }
      continue
    }
    foreach ($n in $names) {
      $kind = ''; $data = ''
      try { $kind = "$($k.GetValueKind($n))" } catch { }
      try {
        $v = $k.GetValue($n)
        if ($v -is [byte[]]) {
          $sb2 = New-Object System.Text.StringBuilder
          foreach ($b in $v) { [void]$sb2.Append(('{0:X2}' -f [byte]$b)) }
          $data = $sb2.ToString()
        }
        elseif ($v -is [object[]]) { $data = (@($v) -join ' | ') }
        else { $data = "$v" }
      } catch { }
      $out += @{ Branch = $label; Key = $real; Name = "$n"; Type = $kind; Data = $data }
    }
  }
  return $out
}
$R.Policies = @()
$R.Policies += DumpPolicyBranch 'HKLM:\SOFTWARE\Policies' 'HKLM\SOFTWARE\Policies'
$R.Policies += DumpPolicyBranch 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies' 'HKLM\SOFTWARE\...\CurrentVersion\Policies'
$R.Policies += DumpPolicyBranch 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP' 'HKLM\SOFTWARE\...\PersonalizationCSP'
$R.Policies += DumpPolicyBranch 'HKCU:\Software\Policies' 'HKCU\Software\Policies'
$R.Policies += DumpPolicyBranch 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies' 'HKCU\Software\...\CurrentVersion\Policies'

# --- 9. PRECONDICIONES DE SETTINGS ---------------------------------------
$R.SettingsApp = @{
  PanelPackage       = ''
  PanelPresent       = $false
  MsSettingsProtocol = $false
  SettingsPageVisibility = ''
  NoControlPanel     = $null
  ConsumerFeatures   = $null
  ConsumerAccount    = $null
  CloudOptimized     = $null
}
try {
  $p = @(Get-AppxPackage -Name 'windows.immersivecontrolpanel' -ErrorAction SilentlyContinue) | Select-Object -First 1
  if (-not $p) { $p = @(Get-AppxPackage -AllUsers -Name 'windows.immersivecontrolpanel' -ErrorAction SilentlyContinue) | Select-Object -First 1 }
  if ($p) { $R.SettingsApp.PanelPresent = $true; $R.SettingsApp.PanelPackage = "$($p.PackageFullName)" }
} catch { Note "immersivecontrolpanel: $($_.Exception.Message)" }
$R.SettingsApp.MsSettingsProtocol = [bool](Test-Path -LiteralPath 'Registry::HKEY_CLASSES_ROOT\ms-settings')
$R.SettingsApp.SettingsPageVisibility = "$(RegRaw 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'SettingsPageVisibility')"
$R.SettingsApp.NoControlPanel   = RegU32 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoControlPanel'
if ($null -eq $R.SettingsApp.NoControlPanel) {
  $R.SettingsApp.NoControlPanel = RegU32 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoControlPanel'
}
$cc = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'
$R.SettingsApp.ConsumerFeatures = RegU32 $cc 'DisableWindowsConsumerFeatures'
$R.SettingsApp.ConsumerAccount  = RegU32 $cc 'DisableConsumerAccountStateContent'
$R.SettingsApp.CloudOptimized   = RegU32 $cc 'DisableCloudOptimizedContent'

$R.Errors = @($R.Errors)
$R
'@

# ===========================================================================
#  QUE PIDIO EL PERFIL (lado host)
#
#  Se resuelve igual que en el -Verify offline: perfil.json da los booleanos por
#  Key y el catalogo da el hex del acento. Y se deduce de los VALORES que escriben
#  los items, no de sus Key: un test que busca la key 'tema-oscuro' da verde el dia
#  que alguien la renombre.
# ===========================================================================
function Get-LiveProfileWants {
  param(
    [string]$Root = $CFG.Root,
    # Si viene vacio se cae al perfil del repo. Que el llamador pueda pasar OTRO
    # perfil es lo que le permite al runner del E2E medir contra el perfil de test
    # SIN tocar el del usuario.
    [string]$Path = ''
  )
  $w = @{
    Ok = $false; Mode = ''; Accent = ''; ThemeColor = ''; ColorPrevalence = $false
    Wallpaper = ''; ThemeExpected = $false
    Appx = @(); Services = @(); ProgramCount = 0; BlockCloudContent = $false
    Note = ''
  }
  $perfilPath = if ($Path) { $Path } else { Join-Path $Root 'perfil.json' }
  if (-not (Test-Path -LiteralPath $perfilPath)) {
    # NO "$perfilPath: ..." interpolado: los dos puntos pegados a la variable hacen
    # que PowerShell lo lea como un calificador de scope/drive ($var:algo) y el
    # archivo NO PARSEA. Es un error de sintaxis, no un detalle de estilo.
    $w.Note = ('no existe ' + $perfilPath + ': no hay contra que comparar')
    return $w
  }
  $j = $null
  try { $j = Get-Content -LiteralPath $perfilPath -Raw | ConvertFrom-Json }
  catch { $w.Note = "no pude leer perfil.json: $($_.Exception.Message)"; return $w }
  $w.Ok = $true

  if ($j.appx) {
    $w.Appx = @($j.appx.PSObject.Properties | Where-Object { $_.Value } | ForEach-Object { $_.Name })
  }
  if ($j.servicios) {
    $w.Services = @($j.servicios.PSObject.Properties | Where-Object { $_.Value } | ForEach-Object { $_.Name })
  }
  if ($j.programas) {
    $w.ProgramCount = @($j.programas.PSObject.Properties | Where-Object { $_.Value }).Count
  }
  if ($j.flags -and $null -ne $j.flags.BlockCloudContent) { $w.BlockCloudContent = [bool]$j.flags.BlockCloudContent }

  $catPath = Join-Path $Root 'config\personalizacion.ps1'
  if (Test-Path -LiteralPath $catPath) { . $catPath }
  $picked = @()
  if ($j.personalizacion -and $Global:PersonalizacionCatalog) {
    $keys   = @($j.personalizacion.PSObject.Properties | Where-Object { $_.Value } | ForEach-Object { $_.Name })
    $picked = @($Global:PersonalizacionCatalog | Where-Object { $keys -contains $_.Key })
  }
  if ($picked.Count -eq 0) { $w.Note = 'no pude resolver personalizacion contra el catalogo' }
  $w.Mode            = Get-VerifyRequestedMode $picked
  $w.Accent          = Get-VerifyRequestedAccent $picked
  $w.ColorPrevalence = Get-VerifyRequestedColorPrevalence $picked
  if ($w.Accent) { $w.ThemeColor = (ConvertTo-AccentDwords $w.Accent).ThemeColor }

  # Misma carpeta y mismo patron que la fase 10 y que el -Verify: con -Include y sin
  # '\*' el filtro no filtra NADA y "no hay wallpaper" sale mentira.
  $wpDir = Join-Path $Root $(if ($Global:WallpaperDir) { $Global:WallpaperDir } else { 'config\wallpaper' })
  if (Test-Path -LiteralPath $wpDir) {
    $f = Get-ChildItem (Join-Path $wpDir '*') -File -ErrorAction SilentlyContinue |
           Where-Object { $_.Extension -match '^\.(jpg|jpeg|png)$' } | Select-Object -First 1
    if ($f) { $w.Wallpaper = $f.Name }
  }
  $w.ThemeExpected = [bool]($w.Mode -or $w.Accent -or $w.Wallpaper)
  return $w
}

# ===========================================================================
#  LOS JUECES. Uno por grupo, todos puros: reciben el payload (y los wants) y
#  devuelven findings. Se pueden correr con un payload armado a mano.
# ===========================================================================

# --- 1. ACTIVACION --------------------------------------------------------
function Get-LiveActivationName {
  param([int]$Status)
  switch ($Status) {
    0 { 'Unlicensed (SIN LICENCIA)' }
    1 { 'Licensed (ACTIVADO)' }
    2 { 'OOB Grace (periodo de gracia inicial)' }
    3 { 'OOT Grace (gracia por fuera de tolerancia)' }
    4 { 'Non-Genuine Grace' }
    5 { 'Notification (sin activar, avisando)' }
    6 { 'Extended Grace' }
    default { "desconocido ($Status)" }
  }
}

function Get-LiveActivationFindings {
  param($Payload)
  $out = @()
  $act = @($Payload.Activation)
  if ($Payload.ActivationFailed -or $act.Count -eq 0) {
    $out += New-LiveFinding 'SIN MEDIR' ('no pude leer SoftwareLicensingProduct en el invitado. ' +
      'La activacion es EL dato que solo existe con el SO corriendo (offline vive en tokens.dat y ' +
      'HKLM\SYSTEM\WPA, blobs opacos), asi que esto no se da por bueno.')
    if ($Payload.Errors) {
      foreach ($e in @($Payload.Errors)) {
        if ("$e" -match 'SoftwareLicensingProduct') { $out += New-LiveFinding 'info' ("      $e") }
      }
    }
  }
  $licenciado = $false
  foreach ($p in $act) {
    $st = [int]$p.LicenseStatus
    if ($st -eq 1) { $licenciado = $true }
    $out += New-LiveFinding 'info' ('{0}' -f "$($p.Name)")
    $out += New-LiveFinding 'info' ('      canal={0}  LicenseStatus={1} -> {2}' -f `
              $(if ("$($p.ProductKeyChannel)") { "$($p.ProductKeyChannel)" } else { '?' }), $st, (Get-LiveActivationName $st))
    $out += New-LiveFinding 'info' ('      clave (ultimos 5) = ...{0}   {1}' -f "$($p.PartialProductKey)",
              $(if ([int]$p.GraceMinutes -gt 0) { "gracia restante: $([math]::Round([int]$p.GraceMinutes / 60 / 24, 1)) dias" } else { 'sin periodo de gracia' }))
    $out += New-LiveFinding 'info' ('      {0}' -f "$($p.Description)")
  }
  $sl = $Payload.Slmgr
  if ($sl -and $sl.TimedOut) {
    $out += New-LiveFinding 'OJO' ('slmgr /xpr se paso del timeout y lo mate. El dato estructurado de ' +
      'SoftwareLicensingProduct sigue valiendo; esto era la confirmacion legible.')
  }
  elseif ($sl -and $sl.Ran) {
    foreach ($l in @("$($sl.Out)" -split "`r?`n")) {
      if ("$l".Trim()) { $out += New-LiveFinding 'info' ('      slmgr /xpr: ' + "$l".Trim()) }
    }
    if ("$($sl.Err)".Trim()) { $out += New-LiveFinding 'info' ('      slmgr stderr: ' + "$($sl.Err)".Trim()) }
  }
  elseif ($sl) {
    $out += New-LiveFinding 'info' ('slmgr /xpr no corrio: ' + "$($sl.Error)")
  }

  if ($licenciado) {
    $out += New-LiveFinding 'OK' 'Windows ACTIVADO: Personalization no va a estar en gris por licenciamiento.'
  }
  elseif ($act.Count -gt 0) {
    $out += New-LiveFinding 'OJO' ('Windows SIN ACTIVAR. EN UNA VM ESTO ES LO ESPERADO Y NO ES UN FALLO: la ' +
      'activacion necesita una licencia legitima y hardware que coincida (contrato 6 de personalizacion, ' +
      'seccion 6 del contrato de testing).')
    $out += New-LiveFinding 'OJO' ('CONSECUENCIA, Y NO CONFUNDIRLA: Settings > Personalization va a estar en GRIS ' +
      'POR LICENCIAMIENTO, no por el debloat ni por nuestras policies. Es diseno de Microsoft ("It is required ' +
      'to activate Windows 11 before you can choose an accent color", contrato 5.4) y NO tiene arreglo por ' +
      'registro. Confundir esta causa con la del debloat ya nos costo una sesion entera: el juicio sobre las ' +
      'policies esta en el grupo SETTINGS, y es INDEPENDIENTE de esto.')
    $out += New-LiveFinding 'info' 'el .theme que aplico el sistema SI toma efecto sin activacion; lo que no se puede es cambiarlo desde la UI.'
  }
  return $out
}

# --- 2. TEMA Y COLOR EFECTIVOS -------------------------------------------
function Get-LiveThemeFindings {
  param($Payload, $Wants)
  $out = @()
  $t = $Payload.Theme
  if (-not $t) {
    $out += New-LiveFinding 'SIN MEDIR' 'el invitado no devolvio nada de tema: no puedo juzgar el color ni el modo.'
    return $out
  }

  # --- el modo escrito, con el dato crudo primero ---
  $out += New-LiveFinding 'info' ('Themes\Personalize del usuario logueado: {0}' -f `
            $(if (@($t.PersonalizeNames).Count -gt 0) { (@($t.PersonalizeNames) -join ' ') } else { '(vacio)' }))
  foreach ($v in @(
      @{ n = 'AppsUseLightTheme';    got = $t.AppsUseLightTheme }
      @{ n = 'SystemUsesLightTheme'; got = $t.SystemUsesLightTheme }
    )) {
    $modoGot = ''
    if ($null -ne $v.got) { $modoGot = $(if ([int]$v.got -eq 0) { 'Dark' } else { 'Light' }) }
    if ($null -eq $v.got) {
      if ($Wants.Mode) {
        $out += New-LiveFinding 'FALLA' ('{0} NO EXISTE en el HKCU del usuario logueado y el perfil pidio {1}. ' -f $v.n, $Wants.Mode +
          'Y un valor AUSENTE no es neutro: para Windows significa CLARO (contrato 2.10-B).')
      } else {
        $out += New-LiveFinding 'info' ('{0} no existe (el perfil no pidio modo)' -f $v.n)
      }
      continue
    }
    if (-not $Wants.Mode) {
      $out += New-LiveFinding 'info' ('{0}={1} -> {2} (el perfil no pidio modo)' -f $v.n, [int]$v.got, $modoGot)
      continue
    }
    if ($modoGot -eq $Wants.Mode) {
      $out += New-LiveFinding 'OK' ('{0}={1} -> {2}: es el modo que pidio el perfil' -f $v.n, [int]$v.got, $modoGot)
    } else {
      $out += New-LiveFinding 'FALLA' ('{0}={1} -> {2} y el perfil pidio {3}' -f $v.n, [int]$v.got, $modoGot, $Wants.Mode)
    }
  }
  if ($Wants.ColorPrevalence) {
    if ($null -eq $t.ColorPrevalence) {
      $out += New-LiveFinding 'FALLA' 'el perfil pidio el acento en taskbar y Themes\Personalize\ColorPrevalence NO EXISTE'
    } elseif ([int]$t.ColorPrevalence -eq 1) {
      $out += New-LiveFinding 'OK' 'ColorPrevalence=1: acento en taskbar y bordes, como pidio el perfil'
    } else {
      $out += New-LiveFinding 'FALLA' ('ColorPrevalence={0} y el perfil pidio 1' -f [int]$t.ColorPrevalence)
    }
  }
  if ($null -ne $t.EnableTransparency) {
    $out += New-LiveFinding 'info' ('EnableTransparency={0}' -f [int]$t.EnableTransparency)
  }

  # --- el color escrito, SIEMPRE en hex legible ---
  # '4288685588' no le dice nada a nadie; '#A6B814 (esperaba #14B8A6)' se entiende
  # al instante, y es exactamente el bug que tuvimos.
  foreach ($vc in @(
      @{ n = 'DWM\AccentColor';            d = $t.AccentColor;           l = 'ABGR' }
      @{ n = 'DWM\AccentColorInactive';    d = $t.AccentColorInactive;   l = 'ABGR' }
      @{ n = 'DWM\ColorizationColor';      d = $t.ColorizationColor;     l = 'ARGB' }
      @{ n = 'DWM\ColorizationAfterglow';  d = $t.ColorizationAfterglow; l = 'ARGB' }
      @{ n = 'Accent\AccentColorMenu';     d = $t.AccentColorMenu;       l = 'ABGR' }
      @{ n = 'Accent\StartColorMenu';      d = $t.StartColorMenu;        l = 'ABGR' }
    )) {
    if ($null -eq $vc.d) { $out += New-LiveFinding 'info' ('{0}: no existe en el HKCU' -f $vc.n); continue }
    $c = Convert-DwordToColor -Dword $vc.d -Layout $vc.l
    $out += New-LiveFinding 'info' ('{0} = {1}   ({2} leido como {3})' -f $vc.n, $c.Hex, $c.Raw, $vc.l)
  }
  $palBytes = @()
  if ("$($t.AccentPaletteHex)") { $palBytes = @(Convert-HexStringToBytes "$($t.AccentPaletteHex)") }
  if ($palBytes.Count -ge 4) {
    $out += New-LiveFinding 'info' ('Accent\AccentPalette ({0} bytes): {1}' -f $palBytes.Count, ((Get-AccentPaletteColors $palBytes) -join ' '))
    $out += New-LiveFinding 'info' '      (indice 3 = el acento base; el 7 es el verde fijo #107C10 de Windows)'
  }

  # --- el juicio del color escrito, con el MISMO juez que el -Verify offline ---
  if (-not $Wants.Accent) {
    $out += New-LiveFinding 'info' 'el perfil no pidio acento: no hay color contra que comparar (arriba esta lo que quedo)'
  }
  else {
    foreach ($f in (Test-AccentAlignment -WantHex $Wants.Accent -PaletteBytes $palBytes `
                      -AccentColor $t.AccentColor -ColorizationColor $t.ColorizationColor `
                      -AccentColorMenu $t.AccentColorMenu)) { $out += $f }
    # StartColorMenu se juzga aparte y NUNCA como FALLA: la tabla del contrato 1 dice
    # que lleva el acento, y el 1.2 dice que el indice 4 de la paleta (dark1) ES
    # StartColorMenu. Las dos cosas son ciertas segun quien escriba ultimo: nosotros
    # o el motor de temas. Se informa la diferencia y quien la produjo.
    if ($null -ne $t.StartColorMenu) {
      $exp = ConvertTo-AccentDwords $Wants.Accent
      $sc  = Convert-DwordToColor -Dword $t.StartColorMenu -Layout 'ABGR'
      $want = Format-ColorHex $exp.R $exp.G $exp.B
      if ($sc.Hex -eq $want) {
        $out += New-LiveFinding 'OK' ('Accent\StartColorMenu = {0}: el acento pedido' -f $sc.Hex)
      } elseif ($palBytes.Count -ge 20 -and $sc.Hex -eq (Format-ColorHex $palBytes[16] $palBytes[17] $palBytes[18])) {
        $out += New-LiveFinding 'info' ('Accent\StartColorMenu = {0} y coincide con AccentPalette[4] (dark1): ' -f $sc.Hex +
          'es el tono derivado por el motor de temas (contrato 1.2), no un color equivocado.')
      } else {
        $out += New-LiveFinding 'OJO' ('Accent\StartColorMenu = {0} (el acento pedido es {1}) y tampoco es el ' -f $sc.Hex, $want +
          'AccentPalette[4]: miralo a mano antes de cantar bug.')
      }
    }
  }

  # --- EL COLOR EFECTIVO: lo que la UI USA, no lo que hay escrito ---
  $eff = $Payload.Effective
  if ($eff -and $eff.Ok) {
    $out += New-LiveFinding 'info' ('UISettings (WinRT, lo que la UI USA): Accent={0}  Background={1}  Foreground={2}' -f `
              "$($eff.AccentHex)", "$($eff.BackgroundHex)", "$($eff.ForegroundHex)")
    # El Background efectivo es NEGRO en oscuro y BLANCO en claro. ESTE es el chequeo
    # que caza "el registro dice oscuro y la pantalla se ve clara".
    $bg = "$($eff.BackgroundHex)".ToUpperInvariant()
    $modoEfectivo = ''
    if ($bg -eq '#000000') { $modoEfectivo = 'Dark' }
    elseif ($bg -eq '#FFFFFF') { $modoEfectivo = 'Light' }
    if (-not $modoEfectivo) {
      $out += New-LiveFinding 'OJO' ('el Background efectivo es {0} y no es ni #000000 (Dark) ni #FFFFFF (Light): ' -f $bg +
        'puede haber un tema de alto contraste activo, que ademas deshabilita la eleccion de acento (contrato 5.5).')
    }
    elseif (-not $Wants.Mode) {
      $out += New-LiveFinding 'info' ('el modo EFECTIVO de la UI es {0} (el perfil no pidio modo)' -f $modoEfectivo)
    }
    elseif ($modoEfectivo -eq $Wants.Mode) {
      $out += New-LiveFinding 'OK' ('EL MODO EFECTIVO DE LA UI ES {0}, el que pidio el perfil. Esto es lo que el ' -f $modoEfectivo +
        'registro NO puede probar: no es un DWORD, es el color que la plataforma les da a las apps para pintarse.')
    }
    else {
      $out += New-LiveFinding 'FALLA' ('EL REGISTRO DICE {0} PERO LA UI ESTA USANDO {1} (Background efectivo {2}). ' -f $Wants.Mode, $modoEfectivo, $bg +
        'Es EXACTAMENTE el bug que ya tuvimos: los valores escritos y la pantalla en otro modo. Quien traduce ' +
        'registro -> colores es el motor de temas, y solo corre cuando se APLICA un tema (contrato 2.5): mira el ' +
        'hr del apply en el log del RunOnce.')
    }
    # El acento efectivo. Un delta contra el pedido NO es bug automatico: Windows
    # normaliza el color a su rampa de luminancias (contrato 2.8, medido: con
    # #14B8A6 el AccentPalette[3] sale #008979). Se dice cual de las dos cosas es.
    if ($Wants.Accent) {
      $exp  = ConvertTo-AccentDwords $Wants.Accent
      $want = Format-ColorHex $exp.R $exp.G $exp.B
      $got  = "$($eff.AccentHex)".ToUpperInvariant()
      if ($got -eq $want) {
        $out += New-LiveFinding 'OK' ('EL ACENTO EFECTIVO ES {0}: la UI esta usando el color pedido. Un DWORD ' -f $got +
          'correcto no probaba esto.')
      }
      elseif ($palBytes.Count -ge 16 -and $got -eq (Format-ColorHex $palBytes[12] $palBytes[13] $palBytes[14])) {
        $out += New-LiveFinding 'OJO' ('el acento efectivo es {0} y el perfil pidio {1}, pero coincide con ' -f $got, $want +
          'AccentPalette[3]: es la normalizacion del motor de temas a su rampa de luminancias (contrato 2.8, ' +
          'medido). No es una desalineacion de bytes.')
      }
      else {
        $out += New-LiveFinding 'FALLA' ('el acento EFECTIVO es {0} y el perfil pidio {1}, y no coincide con ' -f $got, $want +
          'AccentPalette[3]: la UI esta pintando otro color y no es la normalizacion conocida.')
      }
    }
  }
  elseif ($eff) {
    $out += New-LiveFinding 'info' ('UISettings (WinRT) no se pudo instanciar en la sesion de PowerShell Direct: {0}. ' -f (Hide-Secret "$($eff.Error)") +
      'No es SIN MEDIR: el modo y el color efectivos igual se juzgan con el Custom.theme que escribio Windows y ' +
      'con el HKCU del usuario logueado. Era la evidencia mas directa, no la unica.')
  }
  $dwmApi = $Payload.DwmApi
  if ($dwmApi -and $dwmApi.Ok) {
    $out += New-LiveFinding 'info' ('DwmGetColorizationColor (lo que usa el compositor) = {0}  raw={1}  opaque={2}' -f `
              "$($dwmApi.Hex)", "$($dwmApi.Raw)", "$($dwmApi.Opaque)")
  }
  elseif ($dwmApi) {
    $out += New-LiveFinding 'info' ('DwmGetColorizationColor no devolvio color (hr={0} {1}): la sesion de ' -f "$($dwmApi.Hr)", (Hide-Secret "$($dwmApi.Error)") +
      'PowerShell Direct no tiene composicion propia. Es informativo, no un fallo del SO.')
  }

  # --- CurrentTheme: QUE tema esta vigente ---
  $ct = "$($t.CurrentTheme)"
  if (-not $ct) {
    $out += New-LiveFinding 'OJO' 'Themes\CurrentTheme esta vacio: no hay tema vigente registrado (el truco del alto contraste lo blanquea, contrato 2.7)'
  }
  else {
    $out += New-LiveFinding 'info' ('Themes\CurrentTheme = {0}' -f $ct)
    if ($ct -match '(?i)\\Windows\\Resources\\Themes\\([^\\]+\.theme)$') {
      $arch = $Matches[1]
      if ($arch -match '(?i)^LunaticOS\.theme$') {
        $out += New-LiveFinding 'OK' 'el tema vigente es LunaticOS.theme'
      } else {
        $out += New-LiveFinding 'FALLA' ('el tema VIGENTE es {0}, un tema DE FABRICA de Windows. Por esa rama vuelve ' -f $arch +
          'el color de fabrica (dark.theme trae 0XC40078D4, el azul) y el bug es SILENCIOSO: el registro puede ' +
          'quedar coherente con el tema equivocado (contrato 2.5).')
      }
    }
  }
  return $out
}

# --- 3. EXPLORER ---------------------------------------------------------
function Get-LiveExplorerFindings {
  param($Payload)
  $out = @()
  $ex = @($Payload.Explorer)
  if ($ex.Count -eq 0) {
    $out += New-LiveFinding 'FALLA' ('NO HAY NI UN PROCESO explorer.exe CORRIENDO. ESTO ES FALLA GRAVE: es el ' +
      'ESCRITORIO GRIS SIN SHELL. En el PRIMER login el shell NO respawnea solo, asi que un Stop-Process ' +
      '-Name explorer -Force sin bucle de relanzamiento deja la sesion sin escritorio. Es el issue #329 de ' +
      'cschneegans/unattend-generator, con exactamente el codigo que teniamos (contrato 4).')
    $out += New-LiveFinding 'FALLA' ('  Donde mirar: el script del primer login (Windows\Setup\Scripts\lunaticos-personalizar.ps1) ' +
      'y el log C:\ProgramData\LunaticOS\personalizar.log. El relanzamiento tiene que ser un BUCLE con ' +
      'verificacion (contrato 4.2): un Start-Sleep 3 seguido de un if es una carrera, no una garantia.')
    if ([int]$Payload.LogonUiPro -gt 0) {
      $out += New-LiveFinding 'OJO' ('ademas hay LogonUI.exe corriendo: puede que NADIE este logueado y que el ' +
        'AutoLogon del autounattend de test no haya entrado. En ese caso lo del primer login todavia no corrio, ' +
        'y este FALLA es sobre una maquina a medio configurar.')
    }
    return $out
  }
  foreach ($p in $ex) {
    $t = "$($p.StartTime)"
    if (-not $t) { $t = '(sin StartTime: proceso protegido)' }
    $seg = ''
    if ($null -ne $p.SecondsAfterBoot) { $seg = (' -> {0} s despues del boot' -f $p.SecondsAfterBoot) }
    $out += New-LiveFinding 'info' ('explorer.exe pid={0} sesion={1} arrancado {2}{3}' -f [int]$p.Id, [int]$p.SessionId, $t, $seg)
  }
  $out += New-LiveFinding 'OK' ('EXPLORER SOBREVIVIO AL PRIMER LOGIN: {0} proceso(s) vivo(s). No hay escritorio gris ' -f $ex.Count +
    '(issue #329). Offline esto NO se puede ver.')
  if ([int]$Payload.DwmProcs -le 0) {
    $out += New-LiveFinding 'OJO' 'no veo dwm.exe: sin compositor no hay transparencias ni acento en la UI.'
  } else {
    $out += New-LiveFinding 'info' ('dwm.exe: {0} proceso(s)' -f [int]$Payload.DwmProcs)
  }
  $out += New-LiveFinding 'info' ('la maquina lleva {0} minutos encendida (boot {1})' -f "$($Payload.Os.UpMin)", "$($Payload.Os.LastBoot)")
  return $out
}

# --- 4. SERVICIOS --------------------------------------------------------
function Get-LiveServiceFindings {
  param($Payload, $Wants)
  $out = @()
  $svcs = @($Payload.Services)
  if (@($Wants.Services).Count -eq 0) {
    $out += New-LiveFinding 'info' 'el perfil no pidio deshabilitar ningun servicio: nada que verificar'
    return $out
  }
  if ($svcs.Count -eq 0) {
    $out += New-LiveFinding 'SIN MEDIR' ('el perfil pidio deshabilitar {0} servicio(s) y el invitado no devolvio ' -f @($Wants.Services).Count +
      'ninguno: no puedo juzgar su estado real.')
    return $out
  }
  $ok = @(); $noExiste = @(); $malos = @(); $corriendo = @()
  foreach ($s in $svcs) {
    $inst = @($s.Instances)
    if ($inst.Count -eq 0) { $noExiste += "$($s.Asked)"; continue }
    foreach ($i in $inst) {
      $st = "$($i.StartType)"
      $sa = "$($i.Status)"
      if ($st -eq 'Disabled' -and $sa -eq 'Stopped') { $ok += "$($i.Name)"; continue }
      if ($st -ne 'Disabled') { $malos += ('{0} StartType={1} Status={2}' -f "$($i.Name)", $st, $sa); continue }
      $corriendo += ('{0} StartType=Disabled pero Status={1}' -f "$($i.Name)", $sa)
    }
  }
  $out += New-LiveFinding 'info' ('el perfil pidio deshabilitar {0} servicio(s). Estado REAL (Get-Service, no el hive): ' -f @($Wants.Services).Count +
    ('{0} Disabled+Stopped, {1} mal, {2} inexistentes en esta instalacion' -f $ok.Count, ($malos.Count + $corriendo.Count), $noExiste.Count))
  foreach ($m in $malos) {
    $out += New-LiveFinding 'FALLA' ('{0}: el perfil pidio deshabilitarlo y NO esta Disabled. ' -f $m +
      'Start=4 en el hive offline no garantiza esto: algo lo volvio a habilitar despues de instalar.')
  }
  foreach ($m in $corriendo) {
    $out += New-LiveFinding 'OJO' ('{0}: esta Disabled y aun asi no figura detenido. Miralo a mano.' -f $m)
  }
  if ($noExiste.Count -gt 0) {
    $out += New-LiveFinding 'info' ('no existen en esta instalacion (NO es un fallo: no todos los servicios estan en ' +
      'todas las SKU/builds): ' + ($noExiste -join ', '))
  }
  if ($ok.Count -gt 0) {
    $out += New-LiveFinding 'OK' ('{0} servicio(s) Disabled y detenidos, y el SO arranco bien sin ellos (Explorer, ' -f $ok.Count +
      'DWM y esta sesion son la prueba)')
    $out += New-LiveFinding 'info' ('      ' + ($ok -join ', '))
  }
  return $out
}

# --- 5. APPX ------------------------------------------------------------
function Get-LiveAppxFindings {
  param($Payload, $Wants)
  $out = @()
  $pkgs = @($Payload.Appx)
  if ($pkgs.Count -eq 0) {
    $out += New-LiveFinding 'SIN MEDIR' ('el invitado no devolvio ni un paquete appx: no puedo decir si los removidos ' +
      'estan o no. ' + (Hide-Secret "$($Payload.AppxError)"))
    return $out
  }
  $out += New-LiveFinding 'info' ('{0} paquete(s) appx instalados (scope {1}); el perfil pidio remover {2}' -f `
            $pkgs.Count, "$($Payload.AppxScope)", @($Wants.Appx).Count)
  if ("$($Payload.AppxScope)" -ne 'AllUsers') {
    $out += New-LiveFinding 'OJO' ('solo pude enumerar los appx del usuario actual (Get-AppxPackage -AllUsers fallo): ' +
      'un paquete provisionado para otro usuario no se veria. ' + (Hide-Secret "$($Payload.AppxError)"))
  }
  if (@($Wants.Appx).Count -eq 0) {
    $out += New-LiveFinding 'info' 'el perfil no pidio remover ningun appx: nada que juzgar'
    return $out
  }
  $porNombre = @{}
  foreach ($p in $pkgs) { $porNombre["$($p.Name)"] = $p }

  # Los "reincidentes" documentados. La lista NO es el criterio: es CONTEXTO. El
  # criterio es la fecha de creacion de la carpeta del paquete vs la fecha de
  # instalacion del SO -- eso mide la CLASE (volvio despues) y no la instancia.
  $reincidentes = @('Microsoft.Windows.DevHome', 'Microsoft.MicrosoftEdge', 'MicrosoftEdge')
  $fuera = @(); $volvieron = @(); $nunca = @()
  foreach ($name in @($Wants.Appx)) {
    $p = $porNombre["$name"]
    if (-not $p) { $fuera += "$name"; continue }
    $min = $null
    if ($null -ne $p.MinutesAfterInstall) { $min = [double]$p.MinutesAfterInstall }
    $esReincidente = $false
    foreach ($r in $reincidentes) { if ("$name" -like ("*" + $r + "*")) { $esReincidente = $true } }
    if ($null -ne $min -and $min -gt 15) {
      $volvieron += @{ Name = "$name"; Min = $min; Created = "$($p.Created)"; Ver = "$($p.Version)"; Known = $esReincidente }
    } else {
      $nunca += @{ Name = "$name"; Min = $min; Created = "$($p.Created)"; Ver = "$($p.Version)"; Known = $esReincidente }
    }
  }
  if ($fuera.Count -gt 0) {
    $out += New-LiveFinding 'OK' ('{0} de {1} appx pedidos NO estan instalados' -f $fuera.Count, @($Wants.Appx).Count)
    $out += New-LiveFinding 'info' ('      ' + ($fuera -join ', '))
  }
  # "No lo removimos" y "se reinstalo solo" son problemas DISTINTOS y se arreglan en
  # lugares distintos: uno es la fase 1 del pipeline, el otro es Windows Update
  # trayendolo de vuelta. Un chequeo que los mezcla manda a arreglar el archivo
  # equivocado.
  foreach ($v in $volvieron) {
    $txt = ('{0} {1} PRESENTE, pero su carpeta se creo {2} min DESPUES de la instalacion del SO ({3}): ' -f `
            $v.Name, $v.Ver, [math]::Round($v.Min, 1), $v.Created) +
           'SE REINSTALO SOLO. NO es que la fase 1 no lo saco.'
    if ($v.Known) { $txt += ' Es un reincidente DOCUMENTADO (DevHome y Edge vuelven por Windows Update).' }
    $out += New-LiveFinding 'OJO' $txt
  }
  foreach ($v in $nunca) {
    $cuando = ''
    if ($null -ne $v.Min) { $cuando = (' (carpeta creada {0}, {1} min de la instalacion del SO)' -f $v.Created, [math]::Round($v.Min, 1)) }
    $out += New-LiveFinding 'FALLA' ('{0} {1} SIGUE INSTALADO y NO parece reinstalado{2}: la imagen salio con el ' -f $v.Name, $v.Ver, $cuando +
      'paquete adentro. Se arregla en la fase 1 (remocion de appx), no culpando a Windows Update.')
  }
  if ($volvieron.Count -gt 0) {
    $out += New-LiveFinding 'info' ('criterio usado: carpeta del paquete creada mas de 15 minutos despues de ' +
      'Win32_OperatingSystem.InstallDate = ' + "$($Payload.Os.InstallDate)" + '. Es la CLASE (volvio despues), no una lista de nombres.')
  }
  return $out
}

# --- 6. WINGET Y PROGRAMAS ----------------------------------------------
function Get-LiveWingetFindings {
  param($Payload, $Wants)
  $out = @()
  $w = $Payload.Winget
  if (-not $w) {
    $out += New-LiveFinding 'SIN MEDIR' 'el invitado no devolvio nada de winget'
  }
  else {
    $out += New-LiveFinding 'info' ('winget: Get-Command -> {0} ; alias {1} existe={2} ; paquete DesktopAppInstaller {3}' -f `
              $(if ("$($w.Path)") { "$($w.Path)" } else { '(no resuelve)' }),
              "$($w.AliasPath)", "$($w.AliasExists)",
              $(if ("$($w.PackageVersion)") { "$($w.PackageVersion)" } else { '(ausente)' }))
    if ("$($w.PackageVersion)") {
      $out += New-LiveFinding 'OK' ('Microsoft.DesktopAppInstaller {0} instalado: winget esta en la imagen ' -f "$($w.PackageVersion)" +
        '(esta en AppxKeep justamente porque sacarlo rompe winget y la Store)')
    } else {
      $out += New-LiveFinding 'FALLA' ('NO esta Microsoft.DesktopAppInstaller: sin ese paquete NO HAY winget, y el ' +
        'instalador de programas del primer arranque no puede funcionar. Es una de las appx BLINDADAS del config.')
    }
    $r = $w.Run
    if ($r -and $r.Ran -and [int]$r.ExitCode -eq 0) {
      $out += New-LiveFinding 'OK' ('winget --version = ' + ("$($r.Out)" -replace '\s+', ' ').Trim() + ' (ejecutado adentro de la VM)')
    }
    elseif ($r -and $r.TimedOut) {
      $out += New-LiveFinding 'OJO' 'winget --version se paso del timeout y lo mate. El paquete es la evidencia de que winget esta; ejecutarlo no era el objetivo.'
    }
    elseif ($r) {
      $out += New-LiveFinding 'OJO' ('winget --version no corrio bien (exit={0} err={1} {2}). OJO CON LA CONCLUSION: ' -f `
                "$($r.ExitCode)", ("$($r.Err)" -replace '\s+', ' ').Trim(), (Hide-Secret "$($r.Error)") +
              'el alias de ejecucion vive en el perfil del usuario y una sesion de PowerShell Direct no ' +
              'interactiva no siempre lo resuelve. Eso es un limite del instrumento, no prueba que falte winget.')
    }
    elseif (-not "$($w.Path)" -and -not $w.AliasExists) {
      $out += New-LiveFinding 'OJO' 'no encontre el ejecutable de winget ni por PATH ni por el alias de WindowsApps'
    }
  }

  # El log del instalador de programas. La expectativa la fija el PERFIL, no las ganas:
  # medido en la fase 11, con CERO programas elegidos la fase se saltea entera y no
  # genera ni script ni log. Pedir un log ahi seria inventar un fallo.
  $al = $Payload.AppsLog
  $lineas = @()
  if ($al) { $lineas = @($al.Lines) }
  $existe = ($null -ne $al -and $null -ne $al.Lines)
  if ([int]$Wants.ProgramCount -le 0) {
    if ($existe) {
      $out += New-LiveFinding 'OJO' ('el perfil pidio 0 programas y existe {0} con {1} lineas: alguien instalo algo ' -f "$($al.Path)", $lineas.Count +
        'que el perfil no pidio (o el perfil.json del repo no es el que se uso para este build)')
    } else {
      $out += New-LiveFinding 'OK' ('el perfil pidio 0 programas y no hay {0}: correcto, con cero seleccionados la ' -f "$($al.Path)" +
        'fase 11 se saltea y no genera nada')
    }
  }
  elseif (-not $existe) {
    $out += New-LiveFinding 'FALLA' ('el perfil pidio {0} programa(s) y NO existe {1}: el instalador del primer ' -f [int]$Wants.ProgramCount, "$($al.Path)" +
      'arranque nunca corrio (o todavia esta corriendo: son 20+ minutos)')
  }
  else {
    $ok  = @($lineas | Where-Object { $_ -match '^\s*\d+:\d+:\d+\s+  OK ' })
    $bad = @($lineas | Where-Object { $_ -match 'FALLO ' })
    $lvl = 'OK'
    if ($bad.Count -gt 0) { $lvl = 'OJO' }
    $out += New-LiveFinding $lvl ('{0}: {1} lineas, {2} instalados OK, {3} fallidos (el contrato verifica que el ' -f `
              "$($al.Path)", $lineas.Count, $ok.Count, $bad.Count +
            'instalador CORRIO y dejo log, no que cada app este: depende de internet y de repos de terceros)')
    foreach ($l in @($lineas | Where-Object { $_ -match 'resumen:|winget todavia|sin red|ERROR' } | Select-Object -Last 5)) {
      $out += New-LiveFinding 'info' ('      ' + "$l".Trim())
    }
    foreach ($l in @($bad | Select-Object -First 8)) { $out += New-LiveFinding 'OJO' ('      ' + "$l".Trim()) }
  }
  return $out
}

# --- 8 y 9. POLICIES Y SETTINGS ----------------------------------------
function Get-LiveSettingsFindings {
  param($Payload, $Wants)
  $out = @()
  $pol = @($Payload.Policies)
  $out += New-LiveFinding 'info' ('inventario de policies del SO corriendo: {0} entrada(s) en HKLM\SOFTWARE\Policies, ' -f $pol.Count +
    'HKLM y HKCU CurrentVersion\Policies y PersonalizationCSP')
  if ($pol.Count -eq 0) {
    $out += New-LiveFinding 'SIN MEDIR' ('no lei ni una entrada de policies. Con las ramas realmente vacias esto seria ' +
      'correcto, pero no lo puedo distinguir de "no pude leer", asi que NO lo doy por bueno.')
  }

  # El MISMO juez que el -Verify offline: no busca la lista literal del contrato 5.1,
  # busca la CLASE (rama Personalization, nombres NoDisp*/NoChanging*/NoThemes*,
  # PersonalizationCSP, Wallpaper*). La lista es lo que sabemos hoy; la clase es lo
  # que nos va a morder manana.
  $blockers = @(Get-SettingsBlockerFindings $pol)
  $fallas = @($blockers | Where-Object { $_.Level -eq 'FALLA' })
  $sosp   = @($blockers | Where-Object { $_.Level -eq 'SOSPECHA' })
  foreach ($b in $blockers) { $out += @{ Level = "$($b.Level)"; Text = "$($b.Text)" } }
  if ($blockers.Count -eq 0 -and $pol.Count -gt 0) {
    $out += New-LiveFinding 'OK' ('ninguna clave de la seccion 5.1 en el SO corriendo, y ninguna policy de la misma ' +
      'clase. Personalization queda EN MANOS DEL USUARIO.')
  }
  if ($fallas.Count -gt 0) {
    $out += New-LiveFinding 'FALLA' ('{0} policy(s) de la seccion 5.1 VIVAS en el SO. Settings > Personalization va a ' -f $fallas.Count +
      'estar roto o en gris, y esto NO es la falta de activacion: es por estas claves (contrato 5.2).')
  }
  if ($sosp.Count -gt 0) {
    $out += New-LiveFinding 'SOSPECHA' ('{0} policy(s) de la misma familia que las del 5.1 sin estar en la lista: ' -f $sosp.Count +
      'miralas a mano y, si bloquean algo, van al contrato.')
  }

  $sa = $Payload.SettingsApp
  if (-not $sa) {
    $out += New-LiveFinding 'SIN MEDIR' 'el invitado no devolvio las precondiciones de Settings'
    return $out
  }
  # SettingsPageVisibility y NoControlPanel no estan en la 5.1 pero apagan la pagina
  # entera. Van aparte porque el juez de arriba matchea por rama/nombre y estos
  # cuelgan de Explorer.
  if ("$($sa.SettingsPageVisibility)") {
    $out += New-LiveFinding 'FALLA' ('Policies\Explorer\SettingsPageVisibility = "{0}": esta policy ESCONDE paginas de ' -f "$($sa.SettingsPageVisibility)" +
      'Settings. No esta en la lista del contrato 5.1 y tiene que estar: agregala.')
  } else {
    $out += New-LiveFinding 'OK' 'no hay SettingsPageVisibility: ninguna pagina de Settings esta escondida por policy'
  }
  if ($null -ne $sa.NoControlPanel -and [int]$sa.NoControlPanel -ne 0) {
    $out += New-LiveFinding 'FALLA' ('Policies\Explorer\NoControlPanel={0}: mata Settings y el Panel de control enteros' -f [int]$sa.NoControlPanel)
  }
  if ($sa.PanelPresent) {
    $out += New-LiveFinding 'OK' ('la app de Settings esta instalada: {0}' -f "$($sa.PanelPackage)")
  } else {
    $out += New-LiveFinding 'FALLA' ('NO encontre windows.immersivecontrolpanel: la app de Settings no esta instalada. ' +
      'Sin ella no hay Personalization que abrir.')
  }
  if ($sa.MsSettingsProtocol) {
    $out += New-LiveFinding 'OK' 'el protocolo ms-settings: esta registrado en HKCR (ms-settings:personalization tiene quien lo atienda)'
  } else {
    $out += New-LiveFinding 'FALLA' 'el protocolo ms-settings: NO esta registrado: ningun ms-settings:<pagina> va a abrir nada'
  }

  # El cartel de "administradas por tu organizacion" (contrato 5.3). Se juzga contra
  # el FLAG del perfil: si el usuario lo marco, el cartel es una consecuencia que ya
  # acepto; si no lo marco, es un bug nuestro.
  $cc = @(
    @{ n = 'DisableWindowsConsumerFeatures';     v = $sa.ConsumerFeatures }
    @{ n = 'DisableConsumerAccountStateContent'; v = $sa.ConsumerAccount }
    @{ n = 'DisableCloudOptimizedContent';       v = $sa.CloudOptimized }
  )
  $puestas = @($cc | Where-Object { $null -ne $_.v -and [int]$_.v -ne 0 })
  if ($puestas.Count -eq 0) {
    $out += New-LiveFinding 'OK' ('ninguna policy de CloudContent puesta: NO va a aparecer el cartel "administradas por ' +
      'tu organizacion" en Settings ni se van a perder opciones de Background/Spotlight (contrato 5.3)')
  }
  elseif ($Wants.BlockCloudContent) {
    $out += New-LiveFinding 'OJO' ('CloudContent puesto ({0}) y el perfil marco BlockCloudContent: es lo pedido. ' -f (($puestas | ForEach-Object { $_.n }) -join ', ') +
      'CONSECUENCIA ACEPTADA: Settings va a mostrar el cartel "administradas por tu organizacion" y desaparecen ' +
      'opciones de Personalization > Background (Spotlight).')
  }
  else {
    $out += New-LiveFinding 'FALLA' ('CloudContent puesto ({0}) y el perfil NO marco BlockCloudContent. ' -f (($puestas | ForEach-Object { $_.n }) -join ', ') +
      'DisableWindowsConsumerFeatures=1 dispara el cartel "administradas por tu organizacion" y se come opciones ' +
      'de Background (contrato 5.3): nadie lo pidio y esta puesto.')
  }

  # Y ACA NO SE INVENTA NADA (contrato: seccion 9 del pedido).
  $out += New-LiveFinding 'NO MEDIBLE' ('que la pagina Settings > Personalization ABRA de verdad NO se puede probar desde ' +
    'aca. Lanzar ms-settings:personalization desde una sesion no interactiva no dice si la pagina se dibujo, y en ' +
    'la sesion interactiva dejaria una ventana abierta: cambiaria el estado de la VM y este script es un ' +
    'observador. Un chequeo que lanza UI a ciegas y despues informa "OK" es la clase de OK sin evidencia que ya ' +
    'nos costo dos sesiones. Lo que SI esta medido arriba son las precondiciones: la app instalada, el protocolo ' +
    'registrado, ninguna policy que bloquee y el cartel de organizacion. Lo que falta comprobar a ojo es un clic.')
  return $out
}

# --- 7. EL LOG DEL RunOnce, y el Custom.theme --------------------------
# Los dos se juzgan con los MISMOS jueces del -Verify offline (Get-RunOnceLogFindings
# y Get-CustomThemeFindings), que leen de un PATH. El contenido viene del invitado, se
# escribe en un temporal del host y se borra al final. Preferir un archivo temporal
# antes que duplicar la logica: una segunda implementacion del juez es una segunda
# oportunidad de equivocarse, y en este repo el instrumento fallo mas veces que el
# producto.
function New-LiveTempFile {
  param([string]$Suffix, $Lines)
  $p = Join-Path $env:TEMP ('lunaticos-live-{0}-{1}{2}' -f (Get-Date -Format 'HHmmss'), (Get-Random -Maximum 99999), $Suffix)
  $arr = @()
  foreach ($l in @($Lines)) { $arr += "$l" }
  [System.IO.File]::WriteAllLines($p, [string[]]$arr, (New-Object System.Text.UTF8Encoding($false)))
  [void]$script:TempFiles.Add($p)
  return $p
}

function Get-LiveRunOnceFindings {
  param($Payload, $Wants)
  $out = @()
  $rl = $Payload.RunOnceLog
  $path = 'C:\ProgramData\LunaticOS\personalizar.log'
  if ($rl) { $path = "$($rl.Path)" }
  $out += New-LiveFinding 'info' ('fuente: {0} (leido de la VM y juzgado con el MISMO Get-RunOnceLogFindings que el -Verify offline)' -f $path)
  if (-not $rl -or $null -eq $rl.Lines) {
    # Se llama al juez con un path inexistente para que el veredicto y el texto sean
    # EXACTAMENTE los del offline, sin una segunda redaccion del mismo mensaje.
    $fake = Join-Path $env:TEMP ('lunaticos-live-no-existe-{0}.log' -f (Get-Random -Maximum 99999))
    foreach ($f in (Get-RunOnceLogFindings -Path $fake -Expected $Wants.ThemeExpected)) {
      $out += @{ Level = "$($f.Level)"; Text = ("$($f.Text)" -replace [regex]::Escape($fake), $path) }
    }
    return $out
  }
  $tmp = New-LiveTempFile '.log' $rl.Lines
  foreach ($f in (Get-RunOnceLogFindings -Path $tmp -Expected $Wants.ThemeExpected)) {
    $out += @{ Level = "$($f.Level)"; Text = ("$($f.Text)" -replace [regex]::Escape($tmp), $path) }
  }
  return $out
}

function Get-LiveCustomThemeFindings {
  param($Payload, $Wants)
  $out = @()
  $t = $Payload.Theme
  $path = ''
  if ($t) { $path = "$($t.CustomThemePath)" }
  if (-not $t -or $null -eq $t.CustomThemeLines) {
    $fake = Join-Path $env:TEMP ('lunaticos-live-no-existe-{0}.theme' -f (Get-Random -Maximum 99999))
    foreach ($f in (Get-CustomThemeFindings -Path $fake -WantMode $Wants.Mode -WantThemeColor $Wants.ThemeColor -ThemeExpected $Wants.ThemeExpected)) {
      $out += @{ Level = "$($f.Level)"; Text = ("$($f.Text)" -replace [regex]::Escape($fake), $path) }
    }
    return $out
  }
  $out += New-LiveFinding 'info' ('fuente: {0} (lo escribe WINDOWS con el tema VIGENTE: no es lo que pedimos, es lo que hizo)' -f $path)
  $tmp = New-LiveTempFile '.theme' $t.CustomThemeLines
  foreach ($f in (Get-CustomThemeFindings -Path $tmp -WantMode $Wants.Mode -WantThemeColor $Wants.ThemeColor -ThemeExpected $Wants.ThemeExpected)) {
    $out += @{ Level = "$($f.Level)"; Text = ("$($f.Text)" -replace [regex]::Escape($tmp), $path) }
  }
  return $out
}

# ===========================================================================
#  Resumen y objeto de salida
# ===========================================================================
function Get-LiveCounts {
  param($Groups)
  $c = @{ OK = 0; FALLA = 0; SOSPECHA = 0; OJO = 0; SINMEDIR = 0; NOMEDIBLE = 0; info = 0 }
  foreach ($g in $Groups) {
    foreach ($f in @($g.Findings)) {
      switch ("$($f.Level)") {
        'OK'         { $c.OK++ }
        'FALLA'      { $c.FALLA++ }
        'SOSPECHA'   { $c.SOSPECHA++ }
        'OJO'        { $c.OJO++ }
        'SIN MEDIR'  { $c.SINMEDIR++ }
        'NO MEDIBLE' { $c.NOMEDIBLE++ }
        default      { $c.info++ }
      }
    }
  }
  return $c
}

function Get-LiveGroupVerdict {
  param($Group)
  $lv = @(@($Group.Findings) | ForEach-Object { "$($_.Level)" })
  if ($lv -contains 'FALLA')     { return 'FALLA' }
  if ($lv -contains 'SIN MEDIR') { return 'SIN MEDIR' }
  if ($lv -contains 'SOSPECHA')  { return 'SOSPECHA' }
  return 'PASA'
}

function New-LiveResult {
  param([int]$Code, [string]$Verdict, [string]$Message = '')
  # OJO CON LOS @(): envolver un System.Collections.Generic.List[object] con @() tira
  # "Argument types do not match" en PS 5.1 (medido, y ya habia reventado el -Verify
  # entero por lo mismo). Con List[string] y con ArrayList funciona; con List[object]
  # NO. Por eso aca va .ToArray() y no @().
  return [pscustomobject]@{
    Script    = 'verify-live.ps1'
    VMName    = $script:LiveVmForReport
    Stamp     = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    Connected = $script:Connected
    Verdict   = $Verdict
    ExitCode  = $Code
    Message   = $Message
    Counts    = (Get-LiveCounts $script:Groups)
    Groups    = $script:Groups.ToArray()
    Guest     = $script:GuestInfo
    Lines     = @($script:ReportLines.ToArray())
    Raw       = $script:Payload
  }
}

function Remove-LiveTempFiles {
  foreach ($p in $script:TempFiles.ToArray()) {
    if ($p -and (Test-Path -LiteralPath $p)) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
  }
}

# ---------------------------------------------------------------------------
#  Dot-source = SOLO cargar las funciones, sin tocar ninguna VM. Mismo patron que
#  test-vm.ps1 y que 10-personalizar.ps1: es lo que permite probar los jueces con
#  payloads armados a mano. InvocationName vale '.' unicamente al dot-sourcear.
# ---------------------------------------------------------------------------
if ($MyInvocation.InvocationName -eq '.') { return }

# ===========================================================================
#  MAIN
# ===========================================================================
$script:LiveVmForReport   = $LiveVM
$script:SecretForRedaction = ''

Write-LiveLine ("== verify-live: SO CORRIENDO en '{0}' (PowerShell Direct) ==" -f $LiveVM) 'Cyan'
Write-LiveLine ("   {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) 'DarkGray'

try {
  # --- el host puede? ---
  $esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
               [Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $esAdmin) {
    Write-LiveLine '' ; Write-LiveLine 'ERROR: PowerShell Direct necesita una consola ELEVADA en el host.' 'Red'
    Write-LiveLine '  Abri PowerShell como Administrador y volve a correr esto.' 'Yellow'
    Write-Output (New-LiveResult 7 'ERROR' 'el host no esta elevado')
    exit 7
  }
  if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
    Write-LiveLine '' ; Write-LiveLine 'ERROR: no esta el modulo de Hyper-V en el host.' 'Red'
    Write-LiveLine '  Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All' 'Yellow'
    Write-Output (New-LiveResult 7 'ERROR' 'sin modulo Hyper-V')
    exit 7
  }

  # --- la VM existe y esta corriendo? ---
  $vm = Get-VM -Name $LiveVM -ErrorAction SilentlyContinue
  if (-not $vm) {
    Write-LiveLine ''
    Write-LiveLine ("ERROR: no existe la VM '{0}' en este host." -f $LiveVM) 'Red'
    $otras = @(Get-VM -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name) [$($_.State)]" })
    if ($otras.Count -gt 0) { Write-LiveLine ('  VMs que SI existen: ' + ($otras -join ', ')) 'Yellow' }
    else { Write-LiveLine '  este host no tiene ninguna VM.' 'Yellow' }
    Write-LiveLine ("  Crear la de test:  scripts\test-vm.ps1 -Create -VMName '{0}'" -f $LiveVM) 'DarkGray'
    Write-Output (New-LiveResult 2 'ERROR' ("no existe la VM '{0}'" -f $LiveVM))
    exit 2
  }
  Write-LiveLine ("   VM '{0}': State={1}  Uptime={2}" -f $LiveVM, $vm.State, $vm.Uptime) 'DarkGray'
  $hb = Get-VMIntegrationService -VMName $LiveVM -Name 'Heartbeat' -ErrorAction SilentlyContinue
  if ($hb) { Write-LiveLine ("   Heartbeat: {0} / {1}" -f $hb.PrimaryStatusDescription, $hb.SecondaryStatusDescription) 'DarkGray' }

  if ("$($vm.State)" -ne 'Running') {
    Write-LiveLine ''
    Write-LiveLine ("ERROR: la VM '{0}' esta en estado {1} y esto se mide con el SO CORRIENDO." -f $LiveVM, $vm.State) 'Red'
    Write-LiveLine '  NO la arranco yo a proposito: este script es un observador y la VM tiene que quedar' 'Yellow'
    Write-LiveLine '  como estaba. Arrancala y volve a correrlo:' 'Yellow'
    Write-LiveLine ("     Start-VM -Name '{0}'   # y espera a que termine de loguear" -f $LiveVM) 'DarkGray'
    Write-LiveLine '  Lo que se mide con la VM APAGADA es otra cosa:  scripts\test-vm.ps1 -Verify' 'DarkGray'
    Write-Output (New-LiveResult 3 'ERROR' ("la VM esta {0}, no Running" -f $vm.State))
    exit 3
  }

  # --- credenciales ---
  $u = $LiveUser
  $p = $LivePassword
  if (-not $u -or -not $p) {
    try {
      $acc = Get-TestVmAccount
      if (-not $u) { $u = $acc.User }
      if (-not $p) { $p = $acc.Password }
      Write-LiveLine ("   credencial: usuario '{0}' leido de config\autounattend-test.xml (el password NO se imprime)" -f $u) 'DarkGray'
    }
    catch {
      Write-LiveLine ''
      Write-LiveLine ('ERROR: no pude obtener la credencial de la VM de test: ' + (Hide-Secret "$($_.Exception.Message)" $p)) 'Red'
      Write-LiveLine '  Pasala a mano:  -User <u> -Password <p>' 'Yellow'
      Write-Output (New-LiveResult 4 'ERROR' 'sin credencial usable')
      exit 4
    }
  }
  else {
    Write-LiveLine ("   credencial: usuario '{0}' pasado por parametro (el password NO se imprime)" -f $u) 'DarkGray'
  }
  $script:SecretForRedaction = $p
  if (-not $p) {
    Write-LiveLine ''
    Write-LiveLine 'ERROR: password VACIO. PowerShell Direct NO funciona con password vacio -- ese es el unico' 'Red'
    Write-LiveLine '       motivo por el que config\autounattend-test.xml existe aparte del de produccion.' 'Red'
    Write-Output (New-LiveResult 4 'ERROR' 'password vacio')
    exit 4
  }
  $cred = New-Object System.Management.Automation.PSCredential($u, (ConvertTo-SecureString $p -AsPlainText -Force))

  # --- conectar, con presupuesto y sin colgarse ---
  Write-LiveLine ''
  Write-LiveLine ("   conectando por PowerShell Direct (hasta {0}s, {1}s por intento)..." -f $ConnectTimeoutSec, $ProbeTimeoutSec) 'DarkGray'
  $probeCode = @'
param($VMName, $Cred)
$ErrorActionPreference = 'Stop'
Invoke-Command -VMName $VMName -Credential $Cred -ScriptBlock {
  "{0}|{1}|{2}" -f $env:COMPUTERNAME, $env:USERNAME, $PSVersionTable.PSVersion.ToString()
}
'@
  $deadline  = (Get-Date).AddSeconds($ConnectTimeoutSec)
  $intento   = 0
  $credFails = 0
  $ultimo    = @{ TimedOut = $false; Errors = @('sin intentos') }
  $probeOk   = $null
  while ((Get-Date) -lt $deadline) {
    $intento++
    $r = Invoke-LiveWithTimeout -Code $probeCode -TimeoutSec $ProbeTimeoutSec `
           -Parameters @{ VMName = $LiveVM; Cred = $cred }
    $ultimo = $r
    if (-not $r.TimedOut -and @($r.Output).Count -gt 0 -and @($r.Errors).Count -eq 0) {
      $probeOk = "$(@($r.Output)[0])"
      break
    }
    $kind = Get-LiveConnectErrorKind $r.Errors
    if ($r.TimedOut) { $kind = 'TIMEOUT' }
    Write-LiveLine ("   intento {0}: {1}" -f $intento, $kind) 'DarkGray'
    if ($kind -eq 'CRED') {
      $credFails++
      # Una credencial rechazada no se arregla esperando. Igual se reintenta un par de
      # veces: durante el primer arranque el invitado puede rechazar antes de terminar
      # de crear el perfil. Tres seguidas ya no es una carrera, es el password.
      if ($credFails -ge 3) { break }
    }
    Start-Sleep -Seconds 8
  }

  if (-not $probeOk) {
    $kind = Get-LiveConnectErrorKind $ultimo.Errors
    if ($ultimo.TimedOut) { $kind = 'TIMEOUT' }
    Write-LiveLine ''
    foreach ($e in @($ultimo.Errors)) { Write-LiveLine ('   error del host: ' + (Hide-Secret "$e")) 'DarkGray' }
    if ($kind -eq 'CRED') {
      Write-LiveLine ''
      Write-LiveLine '############  PowerShell Direct RECHAZO LA CREDENCIAL  ############' 'Red'
      Write-LiveLine ("  usuario probado: '{0}'  (el password NO se imprime)" -f $u) 'Red'
      Write-LiveLine '' 'Red'
      Write-LiveLine '  CAUSA MAS PROBABLE, y es la de siempre: esta VM se instalo con' 'Red'
      Write-LiveLine '  config\autounattend.xml (PRODUCCION), donde la cuenta se crea con password' 'Red'
      Write-LiveLine '  VACIO a proposito -- y PowerShell Direct NO FUNCIONA CON PASSWORD VACIO.' 'Red'
      Write-LiveLine '  Ese es el unico motivo por el que existe config\autounattend-test.xml.' 'Red'
      Write-LiveLine '' 'Red'
      Write-LiveLine '  QUE HACER (no hay atajo: el password se le pone a la cuenta al crearla,' 'Yellow'
      Write-LiveLine '  o sea durante la instalacion):' 'Yellow'
      Write-LiveLine '    1. Generar la ISO de TEST, la que lleva config\autounattend-test.xml.' 'Yellow'
      Write-LiveLine '    2. Reinstalar la VM con esa ISO:  scripts\test-vm.ps1 -Reset -Boot' 'Yellow'
      Write-LiveLine '       (ese unattend particiona solo: cero clics, y borra el disco 0 de la VM)' 'DarkGray'
      Write-LiveLine '    3. Volver a correr este script.' 'Yellow'
      Write-LiveLine '' 'Yellow'
      Write-LiveLine '  OTRA CAUSA POSIBLE: el usuario no es el de la VM. Se lee de' 'Yellow'
      Write-LiveLine '  config\autounattend-test.xml con Get-TestVmAccount; si alguien edito el XML' 'Yellow'
      Write-LiveLine '  DESPUES de instalar, el XML y la VM dicen cosas distintas.' 'Yellow'
      Write-LiveLine '' 'Yellow'
      Write-LiveLine '  ESTO NO ES UN OK NI UN "SIN MEDIR" PARCIAL: sin conexion no se midio NADA' 'Red'
      Write-LiveLine '  de lo que este script existe para medir.' 'Red'
      Write-Output (New-LiveResult 5 'ERROR' 'PowerShell Direct rechazo la credencial (password vacio en la VM?)')
      exit 5
    }
    Write-LiveLine ''
    Write-LiveLine ("ERROR: la VM no contesto por PowerShell Direct en {0}s ({1} intento(s), ultimo: {2})." -f `
                    $ConnectTimeoutSec, $intento, $kind) 'Red'
    Write-LiveLine '  Cosas que lo explican, en orden de probabilidad:' 'Yellow'
    Write-LiveLine '    - el invitado todavia esta arrancando o esta en la pantalla de login' 'Yellow'
    Write-LiveLine '      (con AutoLogon del unattend de test no deberia: mira scripts\test-vm.ps1 -Shot)' 'DarkGray'
    Write-LiveLine '    - el servicio del invitado "Hyper-V PowerShell Direct" (vmicvmsession) esta detenido' 'Yellow'
    Write-LiveLine '    - la instalacion todavia no termino' 'Yellow'
    Write-LiveLine '  NO invento un veredicto: sin conexion, TODO queda SIN MEDIR.' 'Yellow'
    Write-Output (New-LiveResult 6 'SIN MEDIR' ("la VM no contesto en {0}s ({1})" -f $ConnectTimeoutSec, $kind))
    exit 6
  }

  $partes = @("$probeOk" -split '\|')
  $script:Connected = $true
  $script:GuestInfo = @{
    ComputerName = $(if ($partes.Count -gt 0) { $partes[0] } else { '' })
    User         = $(if ($partes.Count -gt 1) { $partes[1] } else { '' })
    PsVersion    = $(if ($partes.Count -gt 2) { $partes[2] } else { '' })
  }
  Write-LiveLine ("   CONECTADO: {0} como {1}, PowerShell {2}" -f `
                  $script:GuestInfo.ComputerName, $script:GuestInfo.User, $script:GuestInfo.PsVersion) 'Green'

  # --- que pidio el perfil (host) ---
  $wants = Get-LiveProfileWants -Path $ProfilePath
  Write-LiveLine ("   el perfil pidio: tema={0} acento={1} wallpaper={2} appx-a-remover={3} servicios-a-deshabilitar={4} programas={5}" -f `
                  $(if ($wants.Mode) { $wants.Mode } else { '(sin eleccion)' }),
                  $(if ($wants.Accent) { $wants.Accent } else { '(ninguno)' }),
                  $(if ($wants.Wallpaper) { $wants.Wallpaper } else { '(ninguno)' }),
                  @($wants.Appx).Count, @($wants.Services).Count, [int]$wants.ProgramCount) 'DarkGray'
  if ($wants.Note) { Write-LiveLine ('   ! ' + $wants.Note) 'Yellow' }

  # --- recoleccion ---
  Write-LiveLine ("   midiendo adentro de la VM (timeout {0}s)..." -f $CollectTimeoutSec) 'DarkGray'
  $col = Invoke-LiveWithTimeout -Code $script:LiveRemoteRunner -TimeoutSec $CollectTimeoutSec -Parameters @{
    VMName = $LiveVM; Cred = $cred; GuestCode = $script:LiveGuestCode
    GuestArgs = @(, @($wants.Services)) + @(, @($wants.Appx))
  }
  if ($col.TimedOut) {
    Write-LiveLine ''
    Write-LiveLine ("ERROR: la recoleccion adentro de la VM se paso de {0}s y la corte." -f $CollectTimeoutSec) 'Red'
    Write-LiveLine '  La VM contestaba (la conexion funciono), asi que algo de la medicion se colgo adentro.' 'Yellow'
    Write-LiveLine '  Subi -CollectTimeoutSec si la VM esta lenta, o mirala con scripts\test-vm.ps1 -Shot.' 'Yellow'
    Write-Output (New-LiveResult 6 'SIN MEDIR' 'timeout en la recoleccion dentro de la VM')
    exit 6
  }
  $payload = @($col.Output) | Select-Object -First 1
  if (-not $payload) {
    Write-LiveLine ''
    Write-LiveLine 'ERROR: la VM contesto pero no devolvio datos.' 'Red'
    foreach ($e in @($col.Errors)) { Write-LiveLine ('   ' + (Hide-Secret "$e")) 'DarkGray' }
    Write-Output (New-LiveResult 6 'SIN MEDIR' 'el invitado no devolvio payload')
    exit 6
  }
  $script:Payload = $payload
  foreach ($e in @($col.Errors)) { Write-LiveLine ('   ! error del invitado: ' + (Hide-Secret "$e")) 'Yellow' }

  Write-LiveLine ''
  Write-LiveLine ("   invitado: {0} / {1} / {2} build {3} ({4})" -f "$($payload.ComputerName)", "$($payload.WhoAmI)",
                  "$($payload.Os.Caption)", "$($payload.Os.Build)", "$($payload.DisplayVersion)") 'DarkGray'
  Write-LiveLine ("   instalado el {0}   boot {1}   ahora {2}" -f "$($payload.Os.InstallDate)", "$($payload.Os.LastBoot)", "$($payload.Now)") 'DarkGray'
  foreach ($e in @($payload.Errors)) { Write-LiveLine ('   ! el invitado anoto: ' + (Hide-Secret "$e")) 'Yellow' }

  # --- juicio ---
  Add-LiveGroup 'ACTIVACION (informativo: en VM va a estar SIN activar, y eso es esperado)' (Get-LiveActivationFindings -Payload $payload)
  Add-LiveGroup 'TEMA Y COLOR EFECTIVOS (no los escritos: los que la UI usa)' (Get-LiveThemeFindings -Payload $payload -Wants $wants)
  Add-LiveGroup 'Custom.theme: QUE APLICO WINDOWS DE VERDAD' (Get-LiveCustomThemeFindings -Payload $payload -Wants $wants)
  Add-LiveGroup 'EXPLORER: sobrevivio al primer login?' (Get-LiveExplorerFindings -Payload $payload)
  Add-LiveGroup 'SERVICIOS: estado REAL, no el del hive' (Get-LiveServiceFindings -Payload $payload -Wants $wants)
  Add-LiveGroup 'APPX: los removidos no deben estar (y "se reinstalo solo" es otro problema)' (Get-LiveAppxFindings -Payload $payload -Wants $wants)
  Add-LiveGroup 'WINGET y el log del instalador de programas' (Get-LiveWingetFindings -Payload $payload -Wants $wants)
  Add-LiveGroup 'RunOnce del primer login: el log y el hr del apply' (Get-LiveRunOnceFindings -Payload $payload -Wants $wants)
  Add-LiveGroup 'SETTINGS: policies que lo bloquean (contrato 5.1) y precondiciones' (Get-LiveSettingsFindings -Payload $payload -Wants $wants)

  # --- resumen ---
  $counts = Get-LiveCounts $script:Groups
  Write-LiveLine ''
  Write-LiveLine '=========================  RESUMEN  =========================' 'Cyan'
  foreach ($g in $script:Groups) {
    $v = Get-LiveGroupVerdict $g
    $color = switch ($v) {
      'FALLA'     { 'Red' }
      'SIN MEDIR' { 'Yellow' }
      'SOSPECHA'  { 'Magenta' }
      default     { 'Green' }
    }
    $nombre = "$($g.Name)"
    if ($nombre.Length -gt 62) { $nombre = $nombre.Substring(0, 59) + '...' }
    Write-LiveLine ("  {0,-62} {1}" -f $nombre, $v) $color
  }
  Write-LiveLine ("  OK={0}  FALLA={1}  SOSPECHA={2}  OJO={3}  SIN MEDIR={4}  NO MEDIBLE={5}" -f `
                  $counts.OK, $counts.FALLA, $counts.SOSPECHA, $counts.OJO, $counts.SINMEDIR, $counts.NOMEDIBLE) 'DarkGray'

  $code = 0
  $verdict = 'PASA'
  if ([int]$counts.FALLA -gt 0) { $code = 1; $verdict = 'FALLA' }
  elseif ([int]$counts.SINMEDIR -gt 0) { $code = 8; $verdict = 'INCOMPLETO' }

  Write-LiveLine ''
  if ($verdict -eq 'FALLA') {
    Write-LiveLine ("VEREDICTO: FALLA ({0} chequeo(s)). exit {1}" -f $counts.FALLA, $code) 'Red'
  }
  elseif ($verdict -eq 'INCOMPLETO') {
    Write-LiveLine ("VEREDICTO: INCOMPLETO -- sin FALLA pero {0} chequeo(s) SIN MEDIR. exit {1}" -f $counts.SINMEDIR, $code) 'Yellow'
    Write-LiveLine '  SIN MEDIR es un resultado valido y honesto: PASA sin evidencia no.' 'Yellow'
  }
  else {
    Write-LiveLine ("VEREDICTO: PASA. exit {0}" -f $code) 'Green'
    if ([int]$counts.NOMEDIBLE -gt 0) {
      Write-LiveLine ("  ({0} cosa(s) declaradas NO MEDIBLES desde aca: estan listadas arriba con el motivo)" -f $counts.NOMEDIBLE) 'DarkCyan'
    }
  }
  if ([int]$counts.OJO -gt 0) {
    Write-LiveLine ("  {0} aviso(s) OJO: no cambian el exit code, pero leelos (la VM sin activar es uno de ellos)." -f $counts.OJO) 'DarkGray'
  }

  Write-Output (New-LiveResult $code $verdict)
  exit $code
}
finally {
  Remove-LiveTempFiles
}
