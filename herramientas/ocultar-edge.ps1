#requires -Version 5.1
<#
  ocultar-edge.ps1 - Edge invisible e inejecutable, PERO WebView2 sigue actualizandose.

  ===========================================================================
  POR QUE OCULTAR Y NO DESINSTALAR (esto se decidio con evidencia, no por gusto):

  Se intento borrar Edge de la imagen offline y matar los servicios de EdgeUpdate.
  Fallo. Log real de la VM de prueba (MicrosoftEdgeUpdate.log):

      [Installing][display name: Microsoft EdgeWebView]
      [installer path: ...\MicrosoftEdge_X64_150.0.4078.105.exe]
      [manifest args: --msedgewebview --do-not-launch-msedge --system-level]

  EL INSTALADOR ES UNIFICADO: el mismo binario instala WebView2 y Edge. Windows
  Update lo baja para actualizar WEBVIEW2 -que queremos conservar- y Edge viene
  adentro del paquete. Ademas el instalador RECREA los servicios edgeupdate, asi
  que el Start=4 que pusimos offline volvio a 0x2 solo.

  Conclusion: "WebView2 al dia" y "Edge desinstalado" son incompatibles. Son el
  mismo paquete. Asi que se elige la otra rama: Edge se queda en disco pero no
  puede ejecutarse ni se ve en ningun lado.

  POR QUE NO CUESTA DISCO: Edge, EdgeCore y EdgeWebView son HARDLINKS al mismo
  contenido en NTFS. Con WebView2 presente, Edge "de mas" ocupa casi nada.

  POR QUE NO ROMPE WEBVIEW2: WebView2 corre msedgewebview2.exe, un ejecutable
  DISTINTO de msedge.exe. Bloquear msedge.exe no lo toca.
  ===========================================================================

  EFECTO SECUNDARIO ACEPTADO: si algo del sistema intenta abrir un link con Edge,
  falla en silencio. Pone otro navegador como predeterminado.

  Uso (consola como Administrador):
      .\ocultar-edge.ps1
      .\ocultar-edge.ps1 -DryRun     # muestra que haria
      .\ocultar-edge.ps1 -Revert     # deshace el bloqueo
#>
param(
  [switch]$DryRun,
  [switch]$Revert
)

$ErrorActionPreference = 'Continue'
$IFEO = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'

# Solo el NAVEGADOR. msedgewebview2.exe NO esta en esta lista a proposito.
$Blocked = @('msedge.exe', 'msedge_proxy.exe', 'msedge_pwa_launcher.exe')

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-Admin)) {
  Write-Host "ERROR: abri la consola como Administrador." -ForegroundColor Red; exit 1
}

function Step($msg, $color = 'Green') { Write-Host "  $msg" -ForegroundColor $color }

# --------------------------------------------------------------------------
# REVERT
# --------------------------------------------------------------------------
if ($Revert) {
  Write-Host "== Revirtiendo: Edge vuelve a ser ejecutable ==" -ForegroundColor Cyan
  foreach ($exe in $Blocked) {
    $k = Join-Path $IFEO $exe
    if (Test-Path $k) {
      Remove-Item $k -Recurse -Force
      Step "desbloqueado: $exe"
    } else { Step "(no estaba bloqueado) $exe" 'DarkGray' }
  }
  Write-Host "`nListo. Los accesos directos no se restauran: reinstala Edge si los queres." -ForegroundColor Yellow
  return
}

Write-Host "== Ocultando Edge (WebView2 se conserva y se sigue actualizando) ==" -ForegroundColor Cyan

# --------------------------------------------------------------------------
# 1) IFEO: que msedge.exe no pueda ejecutarse
# --------------------------------------------------------------------------
# El truco: IFEO permite definir un "Debugger" que se ejecuta EN LUGAR del binario.
# Apuntandolo a systray.exe (que existe siempre y no hace nada visible) el proceso
# muere sin ventana, sin error y sin dependencias raras.
$stub = "$env:SystemRoot\System32\systray.exe"
if (-not (Test-Path $stub)) { $stub = "$env:SystemRoot\System32\rundll32.exe" }

foreach ($exe in $Blocked) {
  $k = Join-Path $IFEO $exe
  if ($DryRun) { Step "[dry] bloquearia $exe -> Debugger=$stub" 'DarkGray'; continue }
  try {
    if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
    New-ItemProperty -Path $k -Name 'Debugger' -Value $stub -PropertyType String -Force | Out-Null
    Step "bloqueado: $exe"
  } catch { Step "NO pude bloquear $exe -> $($_.Exception.Message)" 'Red' }
}

# --------------------------------------------------------------------------
# 2) Accesos directos: escritorio, menu Inicio, taskbar
# --------------------------------------------------------------------------
$lnks = @(
  "$env:PUBLIC\Desktop\Microsoft Edge.lnk"
  "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk"
  "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk"
  "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\Microsoft Edge.lnk"
  "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Microsoft Edge.lnk"
  "$env:USERPROFILE\Desktop\Microsoft Edge.lnk"
)
# Y los de CUALQUIER perfil: el .lnk del escritorio se recrea por usuario.
Get-ChildItem "$env:SystemDrive\Users" -Directory -Force -EA SilentlyContinue | ForEach-Object {
  $lnks += "$($_.FullName)\Desktop\Microsoft Edge.lnk"
  $lnks += "$($_.FullName)\AppData\Roaming\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Microsoft Edge.lnk"
}

$n = 0
foreach ($l in ($lnks | Select-Object -Unique)) {
  if (-not (Test-Path $l)) { continue }
  if ($DryRun) { Step "[dry] borraria $l" 'DarkGray'; continue }
  Remove-Item $l -Force -EA SilentlyContinue
  if (-not (Test-Path $l)) { $n++ }
}
if (-not $DryRun) { Step "accesos directos borrados: $n" }

# --------------------------------------------------------------------------
# 3) Que Windows no lo vuelva a anclar ni lo promocione
# --------------------------------------------------------------------------
if (-not $DryRun) {
  $edgePol = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
  if (-not (Test-Path $edgePol)) { New-Item -Path $edgePol -Force | Out-Null }
  # Sin pantalla de bienvenida ni importacion, por si alguna vez se ejecuta.
  New-ItemProperty -Path $edgePol -Name 'HideFirstRunExperience' -Value 1 -PropertyType DWord -Force | Out-Null
  # Que no se clave en la taskbar durante actualizaciones.
  New-ItemProperty -Path $edgePol -Name 'PinBrowserToTaskbar'    -Value 0 -PropertyType DWord -Force | Out-Null
  # Que no se auto-inicie con la sesion.
  New-ItemProperty -Path $edgePol -Name 'StartupBoostEnabled'    -Value 0 -PropertyType DWord -Force | Out-Null
  New-ItemProperty -Path $edgePol -Name 'BackgroundModeEnabled'  -Value 0 -PropertyType DWord -Force | Out-Null
  Step "policies: sin first-run, sin pin en taskbar, sin arranque en background"

  # Entradas de autoarranque que deja el instalador
  foreach ($run in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
                     'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run')) {
    Get-Item $run -EA SilentlyContinue | ForEach-Object {
      $_.Property | Where-Object { $_ -like '*Edge*' } | ForEach-Object {
        Remove-ItemProperty -Path $run -Name $_ -Force -EA SilentlyContinue
        Step "autoarranque quitado: $_"
      }
    }
  }
}

# --------------------------------------------------------------------------
# 4) Matar Edge si esta corriendo ahora
# --------------------------------------------------------------------------
if (-not $DryRun) {
  $procs = Get-Process msedge -EA SilentlyContinue
  if ($procs) { $procs | Stop-Process -Force -EA SilentlyContinue; Step "procesos msedge terminados: $($procs.Count)" }
}

# --------------------------------------------------------------------------
# Verificacion
# --------------------------------------------------------------------------
if ($DryRun) { Write-Host "`n[dry] fin - no se cambio nada."; return }

Write-Host "`n== Verificacion ==" -ForegroundColor Cyan
$ok = $true
foreach ($exe in $Blocked) {
  $d = (Get-ItemProperty -Path (Join-Path $IFEO $exe) -Name Debugger -EA SilentlyContinue).Debugger
  if ($d) { Step "$exe -> Debugger OK" } else { Step "$exe -> SIN bloqueo" 'Red'; $ok = $false }
}
$wv = "${env:ProgramFiles(x86)}\Microsoft\EdgeWebView\Application"
if (Test-Path $wv) { Step "WebView2 intacto (se sigue actualizando solo)" }
else               { Step "ALERTA: falta WebView2 - la Store y Widgets se rompen" 'Red'; $ok = $false }

$svc = Get-Service edgeupdate -EA SilentlyContinue
if ($svc) { Step "edgeupdate: $($svc.StartType) - a proposito VIVO, es quien parcha WebView2" 'DarkGray' }

Write-Host ""
if ($ok) {
  Write-Host "Edge oculto y bloqueado. WebView2 sigue al dia por EdgeUpdate." -ForegroundColor Green
  Write-Host "Pone tu navegador (Firefox/Chrome) como predeterminado en Settings > Apps > Default apps." -ForegroundColor Yellow
} else {
  Write-Host "Termino con advertencias: revisa las lineas en rojo." -ForegroundColor Red
}
