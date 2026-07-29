#requires -Version 5.1
<#
  Fase 9 - Cerrar el WIM y rearmar la ISO booteable.
    1) commit + unmount del WIM (guarda todos los cambios offline)
    2) oscdimg -> ISO booteable (UEFI + BIOS legacy)
  Idempotente: si el WIM ya esta desmontado, salta directo al armado de la ISO.
#>

. "$PSScriptRoot\config.ps1"
. "$PSScriptRoot\lib.ps1"
$mount   = $CFG.Mount
$build   = $CFG.IsoBuild
$dism    = $CFG.Dism
$oscdimg = $CFG.Oscdimg
$outIso  = Join-Path (Join-Path $CFG.Root 'work') 'Win11_25H2_Pro_debloat.iso'

Write-Host "== Fase 9: cerrar WIM + rearmar ISO ==" -ForegroundColor Cyan

# 1) Commit + unmount (solo si sigue montado)
if (Test-Path (Join-Path $mount 'Windows')) {
  Write-Step "commit + unmount del WIM (guarda los cambios; tarda)..."
  & $dism /English /Unmount-Image "/MountDir:$mount" /Commit
  if ($LASTEXITCODE -ne 0) { Write-Host "ERROR unmount/commit ($LASTEXITCODE)" -ForegroundColor Red; exit 1 }
} else {
  Write-Step "WIM ya desmontado - salto al armado de ISO" 'DarkGray'
}

# 2) Rearmar ISO booteable
#
#    SE USA efisys.bin (CON prompt "Press any key to boot from CD or DVD") A PROPOSITO.
#
#    Es tentador cambiarlo por efisys_noprompt.bin para que el medio arranque solo: la
#    primera vez es mas comodo y evita el "The boot loader failed" si nadie aprieta una
#    tecla a tiempo. NO LO HAGAS. Ese prompt es lo que hace que los reinicios INTERMEDIOS
#    de la instalacion no vuelvan a bootear del medio: Windows reinicia varias veces
#    durante el setup y, sin el prompt, cada reinicio relanza el instalador desde cero.
#    Loop infinito. El prompt es el mecanismo que rompe ese ciclo.
#
#    Consecuencia practica en el dia D: al bootear del USB hay que apretar una tecla en
#    los primeros ~5 segundos. Una sola vez. Despues, ni la toques.
$etfs = Join-Path $build 'boot\etfsboot.com'
$efi  = Join-Path $build 'efi\microsoft\boot\efisys.bin'
if (-not (Test-Path $etfs) -or -not (Test-Path $efi)) {
  Write-Host "ERROR: faltan boot sectors (etfsboot.com / efisys.bin)" -ForegroundColor Red; exit 1
}
Write-Step "boot UEFI CON prompt (efisys.bin) - apreta una tecla al bootear del USB" 'DarkGray'
$bootdata = "2#p0,e,b$etfs#pEF,e,b$efi"
if (Test-Path $outIso) { Remove-Item $outIso -Force }
Write-Step "armando ISO booteable con oscdimg..."
& $oscdimg -m -o -u2 -udfver102 "-bootdata:$bootdata" $build $outIso
if ($LASTEXITCODE -ne 0) { Write-Host "ERROR oscdimg ($LASTEXITCODE)" -ForegroundColor Red; exit 1 }

$sz = [math]::Round((Get-Item $outIso).Length / 1GB, 2)
Write-Step "ISO LISTA: $outIso ($sz GB)" 'Green'
