#requires -Version 5.1
<#
  Fase 1 — Remover appx provisioned del WIM montado (offline).
  Lee la lista de config.ps1. Blinda lo que este en AppxKeep aunque figure en Remove.

  Requiere: WIM ya montado en $CFG.Mount (ver 00-mount).
  Uso:  .\01-remove-appx.ps1            # aplica
        .\01-remove-appx.ps1 -DryRun    # muestra que haria
#>
param([switch]$DryRun)

. "$PSScriptRoot\config.ps1"
$mount = $CFG.Mount

if (-not (Test-Path (Join-Path $mount 'Windows'))) {
  Write-Host "ERROR: no hay imagen montada en $mount" -ForegroundColor Red; exit 1
}

Write-Host "== Fase 1: APPX provisioned ==" -ForegroundColor Cyan
$provisioned = Get-AppxProvisionedPackage -Path $mount
$removed = 0; $skipped = 0; $missing = 0

foreach ($name in $AppxRemove) {
  if ($AppxKeep -contains $name) {
    Write-Host "  BLINDADO (no se toca) $name" -ForegroundColor Yellow; $skipped++; continue
  }
  $pkg = $provisioned | Where-Object { $_.DisplayName -eq $name }
  if (-not $pkg) { Write-Host "  (no estaba) $name" -ForegroundColor DarkGray; $missing++; continue }

  if ($DryRun) { Write-Host "  [dry] removeria $name" -ForegroundColor DarkGray; continue }
  try {
    Remove-AppxProvisionedPackage -Path $mount -PackageName $pkg.PackageName -ErrorAction Stop | Out-Null
    Write-Host "  removido: $name" -ForegroundColor Green; $removed++
  } catch {
    Write-Host "  ERROR $name : $($_.Exception.Message)" -ForegroundColor Red
  }
}

Write-Host ""
Write-Host ("Resumen: removidos=$removed  blindados=$skipped  no-presentes=$missing") -ForegroundColor Cyan
