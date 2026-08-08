#requires -Version 5.1
<#
  Fase 12 -- Los REINCIDENTES: appx que se quitan de la imagen y VUELVEN solos.

  ===========================================================================
  EL PROBLEMA, MEDIDO EN VM EL 2026-08-08

  La fase 1 quita los appx provisioned de la imagen offline. Funciona: el log
  del build dice "removido: Microsoft.Windows.DevHome". Y despues de instalar,
  con internet, VUELVEN:

      Windows instalado : 15:16:21
      boot              : 15:24:21
      Edge.Stable       : 15:21:16    5 min despues de instalar
      CrossDevice       : 15:34:53   11 min DESPUES del boot
      DevHome           : 15:35:02   idem

  Los trae Windows Update / la Store, no el instalador.

  ===========================================================================
  POR QUE NO ALCANZA SetupComplete.cmd, Y POR QUE TAMPOCO RunOnce

  SetupComplete corre como SYSTEM ANTES del OOBE. RunOnce corre en el primer
  login. Los dos terminan MUCHO antes de los 11 minutos post-boot en que los
  reincidentes aparecen: un Remove-AppxProvisionedPackage ahi no encuentra nada
  y deja la sensacion de que el problema esta resuelto. Eso es peor que no
  hacer nada, porque nadie vuelve a mirar.

  Este archivo ya documentaba el mismo descubrimiento para Edge:
    "Desinstalar Edge ACA NO SIRVE: el OOBE lo reinstala despues"
  (config\SetupComplete.cmd). Es la misma leccion, otra app.

  ===========================================================================
  LA SOLUCION: una TAREA PROGRAMADA que corre DESPUES, y que SE BORRA SOLA

  SetupComplete.cmd crea la tarea (eso es lo que SetupComplete SI puede hacer
  bien: registrar algo para mas tarde). La tarea corre al logon con 10 minutos
  de retraso, o sea DESPUES de la ventana en que vuelven.

  Y se autoelimina: el script cuenta corridas consecutivas sin encontrar nada y
  a la tercera borra la tarea. Una herramienta de debloat que se queda residente
  para siempre borrando apps es exactamente lo que este proyecto NO quiere ser:
  el usuario tiene que poder instalar Dev Home a mano el dia que lo quiera, sin
  pelear con un fantasma que se lo desinstala a los 10 minutos.

  ===========================================================================
  QUE NO HACE, A PROPOSITO

  No usa la policy DisableWindowsConsumerFeatures, que seria mas efectiva y
  permanente. Esa policy es parte del bloque CloudContent, y CloudContent es el
  que pone el cartel "administrada por tu organizacion" en Settings y oculta
  opciones de Personalization. El flag BlockCloudContent existe y viene
  DESMARCADO por esa razon. Quien lo quiera, lo marca.

  Dato medido que respalda el diseno: Microsoft.Copilot NO volvio en la VM. La
  policy TurnOffWindowsCopilot (flag DisableCopilot) lo frena de verdad. Cuando
  existe una policy especifica, la policy gana; esta tarea es para los que no
  la tienen.

  Uso:  .\12-reincidentes.ps1           # genera el script y la tarea
        .\12-reincidentes.ps1 -DryRun   # muestra que haria
#>
param([switch]$DryRun)

. "$PSScriptRoot\config.ps1"
. "$PSScriptRoot\lib.ps1"

$mount = $CFG.Mount
if (-not (Test-Path (Join-Path $mount 'Windows'))) {
  Write-Host "ERROR: no hay imagen montada en $mount" -ForegroundColor Red; exit 1
}

Write-Host "== Fase 12: reincidentes (appx que vuelven solos) ==" -ForegroundColor Cyan

if (-not $Global:Flags['LimpiarReincidentes']) {
  Write-Step "LimpiarReincidentes=false: no se inyecta nada" 'DarkGray'
  return
}

# La lista es $AppxRemove COMPLETA, no tres nombres a mano: si el usuario pidio
# quitar algo y Windows lo trae de vuelta, se vuelve a quitar. Y $AppxKeep se
# respeta como guarda, igual que en la fase 1: si alguien mete un blindado en
# Remove, la guarda gana en las dos fases y no en una sola.
$aQuitar = @($Global:AppxRemove | Where-Object { $Global:AppxKeep -notcontains $_ })
if ($aQuitar.Count -eq 0) {
  Write-Step "la lista de appx a quitar esta vacia: no hay nada que vigilar" 'DarkGray'
  return
}
Write-Step "vigilando $($aQuitar.Count) appx (de `$AppxRemove, menos los blindados)" 'Gray'

if ($DryRun) {
  $aQuitar | ForEach-Object { Write-Step "[dry] vigilar $_" 'DarkGray' }
  return
}

$scriptsDir = Join-Path $mount 'Windows\Setup\Scripts'
New-Item -ItemType Directory -Force -Path $scriptsDir | Out-Null

# ---------------------------------------------------------------------------
#  El script que va a correr DENTRO del Windows instalado
# ---------------------------------------------------------------------------
$sb = New-Object System.Text.StringBuilder
function Add-Line([string]$s) { [void]$sb.AppendLine($s) }

Add-Line '# LunaticOS - limpieza de appx reincidentes.'
Add-Line '# Generado por la fase 12. Lo dispara la tarea LunaticOS-Reincidentes.'
Add-Line '# La tarea SE BORRA SOLA despues de 3 corridas seguidas sin encontrar nada.'
Add-Line '$ErrorActionPreference = "Continue"'
Add-Line '$log   = "$env:ProgramData\LunaticOS\reincidentes.log"'
Add-Line '$marca = "$env:ProgramData\LunaticOS\reincidentes-limpias.txt"'
Add-Line 'New-Item -ItemType Directory -Force -Path (Split-Path $log) | Out-Null'
Add-Line 'function L($m) { $s = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m; Write-Host $s; Add-Content -Path $log -Value $s }'
Add-Line 'L "=== pasada de reincidentes ==="'
Add-Line ''
Add-Line '# La lista viene embebida a proposito: este script corre en una maquina que'
Add-Line '# no tiene el repo, asi que no puede leer config.ps1.'
Add-Line ('$vigilados = @(' + (($aQuitar | ForEach-Object { "'$_'" }) -join ',') + ')')
Add-Line ''
Add-Line '$quitados = 0'
Add-Line 'foreach ($n in $vigilados) {'
Add-Line '  # Provisioned = lo que se le instala a CADA usuario nuevo. Es lo que hay que'
Add-Line '  # matar para que no vuelva en el proximo perfil que se cree.'
Add-Line '  $prov = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $n }'
Add-Line '  foreach ($p in $prov) {'
Add-Line '    try { Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction Stop | Out-Null'
Add-Line '          L "  provisioned quitado: $n"; $quitados++ }'
Add-Line '    catch { L "  NO pude quitar provisioned $n : $($_.Exception.Message)" }'
Add-Line '  }'
Add-Line '  # Y la copia instalada en los usuarios que ya existen.'
Add-Line '  $pkgs = Get-AppxPackage -Name $n -AllUsers -ErrorAction SilentlyContinue'
Add-Line '  foreach ($k in $pkgs) {'
Add-Line '    try { Remove-AppxPackage -Package $k.PackageFullName -AllUsers -ErrorAction Stop'
Add-Line '          L "  instalado quitado: $n"; $quitados++ }'
Add-Line '    catch { L "  NO pude quitar instalado $n : $($_.Exception.Message)" }'
Add-Line '  }'
Add-Line '}'
Add-Line ''
Add-Line '# --- Autoborrado de la tarea ---'
Add-Line '# Tres corridas seguidas sin encontrar nada = Windows dejo de traerlos. Se borra'
Add-Line '# la tarea para no quedar como un proceso residente que le desinstala apps al'
Add-Line '# usuario cuando el las instale a proposito.'
Add-Line 'if ($quitados -gt 0) {'
Add-Line '  L "quitados en esta pasada: $quitados (el contador de limpias vuelve a 0)"'
Add-Line '  Set-Content -Path $marca -Value "0" -Encoding ASCII'
Add-Line '} else {'
Add-Line '  $n = 0'
Add-Line '  if (Test-Path $marca) { $n = [int]("0" + (Get-Content $marca -Raw).Trim()) }'
Add-Line '  $n++'
Add-Line '  Set-Content -Path $marca -Value "$n" -Encoding ASCII'
Add-Line '  L "nada que quitar ($n corrida(s) limpia(s) seguidas de 3)"'
Add-Line '  if ($n -ge 3) {'
Add-Line '    L "3 corridas limpias: la tarea se elimina sola. Si algun dia vuelve un appx,"'
Add-Line '    L "corre este script a mano o volve a generar la ISO."'
Add-Line '    try { Unregister-ScheduledTask -TaskName "LunaticOS-Reincidentes" -Confirm:$false -ErrorAction Stop'
Add-Line '          L "tarea LunaticOS-Reincidentes eliminada" }'
Add-Line '    catch { L "no pude eliminar la tarea: $($_.Exception.Message)" }'
Add-Line '  }'
Add-Line '}'
Add-Line 'L "=== fin de la pasada ==="'

$dest = Join-Path $scriptsDir 'lunaticos-reincidentes.ps1'
[System.IO.File]::WriteAllText($dest, $sb.ToString(), (New-Object System.Text.UTF8Encoding $false))
Write-Step "generado: Windows\Setup\Scripts\lunaticos-reincidentes.ps1 ($($aQuitar.Count) appx vigilados)" 'Green'

# ---------------------------------------------------------------------------
#  La tarea la crea SetupComplete.cmd, no este script
# ---------------------------------------------------------------------------
# No se puede registrar una tarea programada DENTRO de una imagen offline con
# Register-ScheduledTask: ese cmdlet habla con el Task Scheduler de la maquina
# que esta corriendo, no con el hive de la imagen. Se podria escribir el XML de
# la tarea a mano en Windows\System32\Tasks + las claves de TaskCache, pero eso
# es replicar un formato interno no documentado y romperlo es silencioso.
#
# SetupComplete.cmd corre como SYSTEM en la maquina YA instalada, asi que ahi
# `schtasks /Create` es una linea y funciona. Es el lugar correcto: SetupComplete
# no puede QUITAR los reincidentes (corre demasiado temprano) pero si puede
# DEJAR PROGRAMADO quien los va a quitar.
Write-Step "la tarea la crea config\SetupComplete.cmd (schtasks /Create ONLOGON /DELAY 10min)" 'DarkGray'
Write-Host ""
Write-Host "Los reincidentes se limpian 10 min despues de cada logon." -ForegroundColor Green
Write-Host "Log en: C:\ProgramData\LunaticOS\reincidentes.log" -ForegroundColor DarkGray
Write-Host "La tarea se borra sola tras 3 corridas sin hallazgos." -ForegroundColor DarkGray
