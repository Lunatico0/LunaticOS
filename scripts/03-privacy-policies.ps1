#requires -Version 5.1
<#
  Fase 3 — Privacidad y policies de maquina (SOFTWARE hive, offline).
    Telemetria + Copilot + Recall/AI + consumer features/ads + advertising + activity feed + location.
  Son policies HKLM (\Policies\...): sobreviven a los feature updates mejor que los toggles de Settings.

  OJO: en Win11 Pro, AllowTelemetry=0 es un PISO ("Required"), no cero real. El corte del flujo se
  completa deshabilitando el servicio DiagTrack (fase 4) y las scheduled tasks (fase 7).

  Uso:  .\03-privacy-policies.ps1           # aplica
        .\03-privacy-policies.ps1 -DryRun   # muestra que haria
#>
param([switch]$DryRun)

. "$PSScriptRoot\config.ps1"
. "$PSScriptRoot\lib.ps1"
$mount = $CFG.Mount
if (-not (Test-Path (Join-Path $mount 'Windows'))) {
  Write-Host "ERROR: no hay imagen montada en $mount" -ForegroundColor Red; exit 1
}

# Rutas relativas a la raiz del SOFTWARE hive (se antepone HKLM\OFF_SW en el loop).
$pol = @(
  # Telemetria
  @{k='Policies\Microsoft\Windows\DataCollection'; v='AllowTelemetry';                d=0}
  @{k='Policies\Microsoft\Windows\DataCollection'; v='DoNotShowFeedbackNotifications'; d=1}
  @{k='Policies\Microsoft\Windows\DataCollection'; v='DisableOneSettingsDownloads';    d=1}
  # Copilot
  @{k='Policies\Microsoft\Windows\WindowsCopilot'; v='TurnOffWindowsCopilot'; d=1}
  # Recall / Windows AI
  @{k='Policies\Microsoft\Windows\WindowsAI'; v='DisableAIDataAnalysis'; d=1}
  @{k='Policies\Microsoft\Windows\WindowsAI'; v='AllowRecallEnablement'; d=0}
  # Consumer features / ads / contenido sugerido
  @{k='Policies\Microsoft\Windows\CloudContent'; v='DisableWindowsConsumerFeatures';     d=1}
  @{k='Policies\Microsoft\Windows\CloudContent'; v='DisableConsumerAccountStateContent'; d=1}
  @{k='Policies\Microsoft\Windows\CloudContent'; v='DisableCloudOptimizedContent';       d=1}
  # Widgets (refuerzo; el appx WebExperience ya se saco en fase 1)
  @{k='Policies\Microsoft\Dsh'; v='AllowNewsAndInterests'; d=0}
  # Advertising ID
  @{k='Policies\Microsoft\Windows\AdvertisingInfo'; v='DisabledByGroupPolicy'; d=1}
  # Activity feed / timeline
  @{k='Policies\Microsoft\Windows\System'; v='EnableActivityFeed';    d=0}
  @{k='Policies\Microsoft\Windows\System'; v='PublishUserActivities'; d=0}
  @{k='Policies\Microsoft\Windows\System'; v='UploadUserActivities';  d=0}
  # Location
  @{k='Policies\Microsoft\Windows\LocationAndSensors'; v='DisableLocation'; d=1}
)

Write-Host "== Fase 3: privacidad / policies (SOFTWARE hive) ==" -ForegroundColor Cyan
if ($DryRun) {
  $pol | ForEach-Object { Write-Step ("[dry] {0}\{1} = {2}" -f $_.k, $_.v, $_.d) 'DarkGray' }
  return
}

Use-OfflineHive -HivePath (Join-Path $mount 'Windows\System32\config\SOFTWARE') -MountKey 'OFF_SW' -Action {
  param($root)
  foreach ($x in $pol) {
    Invoke-Reg add "$root\$($x.k)" /v $x.v /t REG_DWORD /d $x.d /f
  }
  Write-Step ("aplicadas {0} policies de privacidad" -f $pol.Count) 'Green'
}
