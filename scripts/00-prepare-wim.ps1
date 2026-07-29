#requires -Version 5.1
<#
  Fase 0 -- Prepara el WIM de trabajo:
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

# 1) Ubicar la ISO ORIGINAL
#    OJO CON EL FILTRO: en work\ conviven la ISO oficial de Microsoft y la que
#    GENERAMOS nosotros (*_debloat.iso). Sin excluirla, un "primer .iso que
#    aparezca" puede agarrar nuestra propia salida como entrada y debloatear algo
#    ya debloateado. Hoy no explota solo por el orden alfabetico, que es la peor
#    clase de seguridad: la que funciona por casualidad.
$isos = @(Get-ChildItem (Join-Path $CFG.Root 'work') -Filter *.iso -EA SilentlyContinue |
          Where-Object { $_.Name -notlike '*debloat*' } | Sort-Object Length -Descending)
if (-not $isos) {
  Write-Host "ERROR: no hay una ISO oficial de Windows en work\" -ForegroundColor Red
  Write-Host "       (se ignoran los archivos *debloat*.iso: esos los genera este pipeline)" -ForegroundColor Yellow
  exit 1
}
if ($isos.Count -gt 1) {
  Write-Step "hay $($isos.Count) ISOs candidatas, uso la mas grande:" 'Yellow'
  $isos | ForEach-Object { Write-Step "    $($_.Name)  ($([math]::Round($_.Length/1GB,2)) GB)" 'DarkGray' }
}
$iso = $isos[0].FullName
Write-Step "ISO: $iso"

# 2) Montar ISO y exportar la edicion Pro
if (Test-Path $wim) { Remove-Item $wim -Force }
$img = Mount-DiskImage -ImagePath $iso -PassThru
Start-Sleep -Seconds 2
$dl  = ($img | Get-Volume).DriveLetter
$src = "${dl}:\sources\install.wim"

# El indice de Pro NO se hardcodea. En la ISO multi-edicion de 25H2 es el 6, pero
# eso depende de la ISO: una Business/VL o una de otra version tiene otro orden, y
# exportar el indice equivocado te deja una imagen de Home o Education sin que nada
# avise. Se busca por NOMBRE EXACTO.
$info = & $dism /English /Get-WimInfo "/WimFile:$src" 2>&1
$idxPro = $null; $lastIdx = $null
foreach ($line in $info) {
  if ($line -match '^\s*Index\s*:\s*(\d+)')      { $lastIdx = $Matches[1] }
  elseif ($line -match '^\s*Name\s*:\s*(.+?)\s*$') {
    if ($Matches[1] -eq 'Windows 11 Pro') { $idxPro = $lastIdx; break }
  }
}
if (-not $idxPro) {
  Write-Host "ERROR: no encontre la edicion 'Windows 11 Pro' en $src" -ForegroundColor Red
  Write-Host "       Ediciones disponibles:" -ForegroundColor Yellow
  $info | Select-String '^\s*(Index|Name)\s*:' | ForEach-Object { Write-Host "         $($_.Line.Trim())" -ForegroundColor DarkGray }
  Dismount-DiskImage -ImagePath $iso | Out-Null
  exit 1
}
Write-Step "edicion Pro encontrada en el indice $idxPro"
Write-Step "exportando Windows 11 Pro (tarda ~15-25 minutos, no lo mates)..."
& $dism /English /Export-Image "/SourceImageFile:$src" "/SourceIndex:$idxPro" "/DestinationImageFile:$wim" /Compress:max
$rc = $LASTEXITCODE
Dismount-DiskImage -ImagePath $iso | Out-Null
if ($rc -ne 0) { Write-Host "ERROR export ($rc)" -ForegroundColor Red; exit 1 }

# 3) Montar el WIM
& $dism /English /Mount-Image "/ImageFile:$wim" /Index:1 "/MountDir:$mount"
if ($LASTEXITCODE -ne 0) { Write-Host "ERROR mount ($LASTEXITCODE)" -ForegroundColor Red; exit 1 }

Write-Step "WIM Pro montado en $mount - listo para fases 1-6" 'Green'
