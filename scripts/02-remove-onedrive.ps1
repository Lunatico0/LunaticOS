#requires -Version 5.1
<#
  Fase 2 — Sacar OneDrive (el cloud de MS) de la imagen, offline.
    1) Borra OneDriveSetup.exe del WIM (System32 / SysWOW64)
    2) Policy DisableFileSyncNGSC=1                         (SOFTWARE hive)
    3) Oculta la carpeta OneDrive del panel del Explorador  (SOFTWARE hive, CLSID)
    4) Quita el Run que lo instala en el primer login       (DEFAULT user hive)
  Controlado por $Flags.RemoveOneDrive en config.ps1.

  Uso:  .\02-remove-onedrive.ps1           # aplica
        .\02-remove-onedrive.ps1 -DryRun   # muestra que haria
#>
param([switch]$DryRun)

. "$PSScriptRoot\config.ps1"
. "$PSScriptRoot\lib.ps1"
$mount = $CFG.Mount

if (-not (Test-Path (Join-Path $mount 'Windows'))) {
  Write-Host "ERROR: no hay imagen montada en $mount" -ForegroundColor Red; exit 1
}
if (-not $Flags.RemoveOneDrive) { Write-Host "Flags.RemoveOneDrive = false -> salteo OneDrive"; return }

Write-Host "== Fase 2: OneDrive (cloud de MS) fuera ==" -ForegroundColor Cyan

# 1) Instalador de OneDrive
$setups = @(
  (Join-Path $mount 'Windows\System32\OneDriveSetup.exe'),
  (Join-Path $mount 'Windows\SysWOW64\OneDriveSetup.exe')
)
foreach ($s in $setups) {
  if (Test-Path $s) {
    if ($DryRun)                       { Write-Step "[dry] borraria $s" 'DarkGray' }
    elseif (Remove-ProtectedFile $s)   { Write-Step "borrado: $s" 'Green' }
    else                               { Write-Step "NO pude borrar: $s" 'Red' }
  } else { Write-Step "(no existe) $s" 'DarkGray' }
}

if ($DryRun) { Write-Host "[dry] fin (no se tocaron hives)"; return }

# 2) SOFTWARE hive: policy + ocultar del Explorer
Use-OfflineHive -HivePath (Join-Path $mount 'Windows\System32\config\SOFTWARE') -MountKey 'OFF_SW' -Action {
  param($root)
  Invoke-Reg add "$root\Policies\Microsoft\Windows\OneDrive" /v DisableFileSyncNGSC /t REG_DWORD /d 1 /f
  Write-Step "policy DisableFileSyncNGSC=1"
  $clsid = '{018D5C66-4533-4307-9B53-224DE2ED1FE6}'
  Invoke-Reg add "$root\Classes\CLSID\$clsid"             /v System.IsPinnedToNameSpaceTree /t REG_DWORD /d 0 /f
  Invoke-Reg add "$root\Classes\Wow6432Node\CLSID\$clsid" /v System.IsPinnedToNameSpaceTree /t REG_DWORD /d 0 /f
  Write-Step "carpeta OneDrive oculta del Explorador"
}

# 3) DEFAULT user hive: quitar el Run que lo instala en el primer login
Use-OfflineHive -HivePath (Join-Path $mount 'Users\Default\NTUSER.DAT') -MountKey 'OFF_DEF' -Action {
  param($root)
  $run = "$root\Software\Microsoft\Windows\CurrentVersion\Run"
  & reg.exe delete $run /v OneDriveSetup /f 2>$null
  if ($LASTEXITCODE -eq 0) { Write-Step "Run\OneDriveSetup eliminado (no se instala en el primer login)" }
  else                     { Write-Step "Run\OneDriveSetup no estaba" 'DarkGray' }
}

Write-Host ""
Write-Host "OneDrive fuera de la imagen." -ForegroundColor Green
