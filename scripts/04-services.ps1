#requires -Version 5.1
<#
  Fase 4 — Servicios a Disabled (SYSTEM hive, offline).
    Edita ControlSet001\Services\<svc>\Start = 4 (disabled) para los servicios de $ServicesDisable.
    Blindaje: si el servicio NO existe en la imagen, se saltea (no crea fantasmas).
    Solo servicios "seguros" del plan — NO toca red/cripto/audio/update/seguridad/anticheat.

  Start: 0=boot 1=system 2=automatic 3=manual 4=disabled

  Uso:  .\04-services.ps1           # aplica
        .\04-services.ps1 -DryRun   # muestra que haria
#>
param([switch]$DryRun)

. "$PSScriptRoot\config.ps1"
. "$PSScriptRoot\lib.ps1"
$mount = $CFG.Mount
if (-not (Test-Path (Join-Path $mount 'Windows'))) {
  Write-Host "ERROR: no hay imagen montada en $mount" -ForegroundColor Red; exit 1
}

Write-Host "== Fase 4: servicios -> Disabled (SYSTEM hive) ==" -ForegroundColor Cyan
if ($DryRun) { $ServicesDisable | ForEach-Object { Write-Step "[dry] $_ -> Start=4" 'DarkGray' }; return }

Use-OfflineHive -HivePath (Join-Path $mount 'Windows\System32\config\SYSTEM') -MountKey 'OFF_SYS' -Action {
  param($root)
  $done = 0; $skip = 0
  foreach ($svc in $ServicesDisable) {
    $key = "$root\ControlSet001\Services\$svc"
    & reg.exe query $key 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
      Invoke-Reg add $key /v Start /t REG_DWORD /d 4 /f
      Write-Step "disabled: $svc" 'Green'; $done++
    } else {
      Write-Step "(no existe en la imagen) $svc" 'DarkGray'; $skip++
    }
  }
  Write-Step ("disabled=$done  no-presentes=$skip") 'Cyan'
}
