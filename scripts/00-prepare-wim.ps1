#requires -Version 5.1
<#
  Fase 0 — Prepara el WIM de trabajo:
    1) descarta cualquier mount previo (idempotente)
    2) monta la ISO original y exporta SOLO Windows 11 Pro (index 6) al arbol de build
    3) monta la imagen en work\mount, lista para las fases 1-6
  Correr como Admin. La ISO tiene que estar en work\ (un solo .iso).
#>

. "$PSScriptRoot\config.ps1"
. "$PSScriptRoot\lib.ps1"

$mount = $CFG.Mount
$wim   = Join-Path $CFG.IsoBuild 'sources\install.wim'
$dism  = $CFG.Dism

Write-Host "== Fase 0: preparar WIM (export Pro + montar) ==" -ForegroundColor Cyan

# 0) Descartar mount previo si lo hay
if (Test-Path (Join-Path $mount 'Windows')) {
  Write-Step "descartando mount previo..."
  & $dism /English /Unmount-Image "/MountDir:$mount" /Discard | Out-Null
}
& $dism /English /Cleanup-Mountpoints | Out-Null
New-Item -ItemType Directory -Force -Path $mount | Out-Null

# 1) Ubicar la ISO
$iso = (Get-ChildItem (Join-Path $CFG.Root 'work') -Filter *.iso | Select-Object -First 1).FullName
if (-not $iso) { Write-Host "ERROR: no hay .iso en work\" -ForegroundColor Red; exit 1 }
Write-Step "ISO: $iso"

# 2) Montar ISO y exportar Pro (index 6)
if (Test-Path $wim) { Remove-Item $wim -Force }
$img = Mount-DiskImage -ImagePath $iso -PassThru
Start-Sleep -Seconds 2
$dl  = ($img | Get-Volume).DriveLetter
$src = "${dl}:\sources\install.wim"
Write-Step "exportando Windows 11 Pro desde $src (tarda unos minutos)..."
& $dism /English /Export-Image "/SourceImageFile:$src" /SourceIndex:6 "/DestinationImageFile:$wim" /Compress:max
$rc = $LASTEXITCODE
Dismount-DiskImage -ImagePath $iso | Out-Null
if ($rc -ne 0) { Write-Host "ERROR export ($rc)" -ForegroundColor Red; exit 1 }

# 3) Montar el WIM
& $dism /English /Mount-Image "/ImageFile:$wim" /Index:1 "/MountDir:$mount"
if ($LASTEXITCODE -ne 0) { Write-Host "ERROR mount ($LASTEXITCODE)" -ForegroundColor Red; exit 1 }

Write-Step "WIM Pro montado en $mount - listo para fases 1-6" 'Green'
