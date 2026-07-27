#requires -Version 5.1
<#
  Fase 5 — Tweaks de UI (DEFAULT user hive, offline).
    Se editan en Users\Default\NTUSER.DAT -> TODO perfil nuevo hereda estos ajustes.
    Explorer dev-friendly + taskbar limpia + sin ads/sugerencias + Bing web fuera del Inicio.

  El "Bing web off" es como sacamos el ruido de BingSearch SIN remover el appx
  (decision de la zona gris: remover el paquete puede romper el buscador del Inicio).

  Uso:  .\05-ui-tweaks.ps1           # aplica
        .\05-ui-tweaks.ps1 -DryRun   # muestra que haria
#>
param([switch]$DryRun)

. "$PSScriptRoot\config.ps1"
. "$PSScriptRoot\lib.ps1"
$mount = $CFG.Mount
if (-not (Test-Path (Join-Path $mount 'Windows'))) {
  Write-Host "ERROR: no hay imagen montada en $mount" -ForegroundColor Red; exit 1
}

# Rutas relativas a la raiz del hive de usuario (HKCU).
$tweaks = @(
  # --- Explorer (dev-friendly) ---
  @{k='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='HideFileExt';              d=0}  # ver extensiones (critico dev)
  @{k='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='Hidden';                   d=1}  # ver archivos ocultos
  @{k='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='LaunchTo';                 d=1}  # abrir en "Este equipo"
  @{k='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='ShowTaskViewButton';       d=0}  # Task View off
  # NOTA: 'TaskbarDa' (boton Widgets) esta PROTEGIDO en el default hive y no se puede escribir
  # offline (ni reg.exe ni PS provider). No hace falta: los Widgets ya quedan OFF por la policy
  # de maquina Dsh\AllowNewsAndInterests=0 (fase 3). Reforzable per-user en SetupComplete (fase 7).
  @{k='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='TaskbarMn';                d=0}  # Chat off
  @{k='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='Start_IrisRecommendations'; d=0} # sin recomendados en Start
  # --- Search / Bing web off ---
  @{k='Software\Microsoft\Windows\CurrentVersion\Search'; v='SearchboxTaskbarMode'; d=1}  # search = solo icono
  @{k='Software\Microsoft\Windows\CurrentVersion\Search'; v='BingSearchEnabled';    d=0}  # sin web en el Inicio
  @{k='Software\Microsoft\Windows\CurrentVersion\Search'; v='CortanaConsent';       d=0}
  # --- ContentDeliveryManager (ads / sugerencias / contenido) ---
  @{k='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; v='ContentDeliveryAllowed';         d=0}
  @{k='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; v='SilentInstalledAppsEnabled';     d=0}
  @{k='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; v='SystemPaneSuggestionsEnabled';   d=0}
  @{k='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; v='PreInstalledAppsEnabled';        d=0}
  @{k='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; v='OemPreInstalledAppsEnabled';     d=0}
  @{k='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; v='RotatingLockScreenOverlayEnabled'; d=0}  # ads en lockscreen
  @{k='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; v='SubscribedContent-338388Enabled'; d=0}   # sugerencias en Start
  @{k='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; v='SubscribedContent-338389Enabled'; d=0}   # tips
  @{k='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; v='SubscribedContent-338393Enabled'; d=0}   # contenido sugerido en Settings
  @{k='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; v='SubscribedContent-353694Enabled'; d=0}
  @{k='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; v='SubscribedContent-353696Enabled'; d=0}
  # --- Advertising ID (per-user) + tailored experiences ---
  @{k='Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; v='Enabled'; d=0}
  @{k='Software\Microsoft\Windows\CurrentVersion\Privacy'; v='TailoredExperiencesWithDiagnosticDataEnabled'; d=0}
)

Write-Host "== Fase 5: tweaks de UI (DEFAULT user hive) ==" -ForegroundColor Cyan
if ($DryRun) {
  $tweaks | ForEach-Object { Write-Step ("[dry] {0}\{1} = {2}" -f $_.k, $_.v, $_.d) 'DarkGray' }
  return
}

Use-OfflineHive -HivePath (Join-Path $mount 'Users\Default\NTUSER.DAT') -MountKey 'OFF_DEF' -Action {
  param($root)
  $ok = 0; $fail = @()
  foreach ($x in $tweaks) {
    if (Set-RegDword "$root\$($x.k)" $x.v $x.d) { $ok++ } else { $fail += $x.v }
  }
  Write-Step ("aplicados=$ok  fallidos=$($fail.Count)") 'Green'
  if ($fail.Count) { Write-Step ("fallidos (revisar): " + ($fail -join ', ')) 'Yellow' }
}
