#requires -Version 5.1
<#
  Fase 7 - Inyeccion de runtime:
    1) SetupComplete.cmd  -> dentro del WIM en Windows\Setup\Scripts\ (corre al final del setup)
    2) autounattend.xml   -> en la RAIZ del arbol de la ISO (lo lee el instalador)
  Ambos templates viven en config\ (versionados). Este script solo los copia a su lugar.
#>

. "$PSScriptRoot\config.ps1"
. "$PSScriptRoot\lib.ps1"
$mount = $CFG.Mount
if (-not (Test-Path (Join-Path $mount 'Windows'))) {
  Write-Host "ERROR: no hay imagen montada en $mount" -ForegroundColor Red; exit 1
}

Write-Host "== Fase 7: inyeccion de runtime ==" -ForegroundColor Cyan

# 1) SetupComplete.cmd dentro del WIM
$scriptsDir = Join-Path $mount 'Windows\Setup\Scripts'
New-Item -ItemType Directory -Force -Path $scriptsDir | Out-Null
Copy-Item (Join-Path $CFG.Root 'config\SetupComplete.cmd') (Join-Path $scriptsDir 'SetupComplete.cmd') -Force
Write-Step "SetupComplete.cmd -> Windows\Setup\Scripts\ (tasks telemetria + quitar Edge)" 'Green'

# 2) autounattend.xml en la raiz de la ISO
Copy-Item (Join-Path $CFG.Root 'config\autounattend.xml') (Join-Path $CFG.IsoBuild 'autounattend.xml') -Force
Write-Step "autounattend.xml -> raiz de la ISO (cuenta local + region AR + teclado ES/EN)" 'Green'
