#requires -Version 5.1
<#
  Fase 6 -- Capabilities + optional features (DISM offline).
    Capabilities: se remueven por prefijo (el script resuelve el nombre+version instalado en la imagen).
    Features: se deshabilitan por nombre exacto.
    Usa el DISM del ADK (26100). Blindaje: solo toca lo listado en config.

  Uso:  .\06-features.ps1           # aplica
        .\06-features.ps1 -DryRun   # muestra que haria
#>
param([switch]$DryRun)

. "$PSScriptRoot\config.ps1"
. "$PSScriptRoot\lib.ps1"
$mount = $CFG.Mount
$dism  = $CFG.Dism
if (-not (Test-Path (Join-Path $mount 'Windows'))) {
  Write-Host "ERROR: no hay imagen montada en $mount" -ForegroundColor Red; exit 1
}

Write-Host "== Fase 6: capabilities + features (DISM) ==" -ForegroundColor Cyan

# --- Capabilities ---
Write-Host "-- Capabilities --" -ForegroundColor Cyan
$installed = Get-WindowsCapability -Path $mount | Where-Object State -eq 'Installed'
foreach ($prefix in $CapabilitiesRemove) {
  $found = $installed | Where-Object { $_.Name -like "$prefix*" }
  if (-not $found) { Write-Step "(no instalada) $prefix" 'DarkGray'; continue }
  foreach ($c in $found) {
    if ($DryRun) { Write-Step "[dry] removeria $($c.Name)" 'DarkGray'; continue }
    & $dism /English /Image:"$mount" /Remove-Capability /CapabilityName:"$($c.Name)" | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Step "removida: $($c.Name)" 'Green' }
    else { Write-Step "ERROR ($LASTEXITCODE) $($c.Name)" 'Red' }
  }
}

# --- Features ---
Write-Host "-- Features --" -ForegroundColor Cyan
$enabled = Get-WindowsOptionalFeature -Path $mount | Where-Object State -eq 'Enabled' |
           Select-Object -ExpandProperty FeatureName
foreach ($f in $FeaturesDisable) {
  if ($enabled -notcontains $f) { Write-Step "(no habilitada) $f" 'DarkGray'; continue }
  if ($DryRun) { Write-Step "[dry] deshabilitaria $f" 'DarkGray'; continue }
  & $dism /English /Image:"$mount" /Disable-Feature /FeatureName:"$f" | Out-Null
  if ($LASTEXITCODE -eq 0) { Write-Step "deshabilitada: $f" 'Green' }
  else { Write-Step "ERROR ($LASTEXITCODE) $f" 'Red' }
}
