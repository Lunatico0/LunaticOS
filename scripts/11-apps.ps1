#requires -Version 5.1
<#
  Fase 11 — Inyectar el instalador de programas del primer arranque.

  ===========================================================================
  POR QUE NO SE METEN LOS INSTALADORES DENTRO DE LA ISO

  Seria lo "obvio": copiar los .exe al WIM y ejecutarlos. Malas noticias:
    - La ISO pasaria de 7.5 GB a 15+ GB y no entra en medios comunes.
    - Quedarian VIEJOS el mismo dia. Chrome saca version cada dos semanas.
    - Habria que mantener a mano 80 instaladores.
  Por eso se inyecta un SCRIPT que usa winget en el primer arranque: la ISO no
  crece nada y siempre instala la ultima version.

  COSTO ACEPTADO: hace falta INTERNET en el primer arranque. Si no hay red, el
  script no falla en silencio: deja el log y se puede volver a correr a mano.
  ===========================================================================

  Lee $AppsPicked (lo llena LunaticOS.ps1 desde el perfil.json). Sin perfil, usa
  los recomendados.

  Uso:  .\11-apps.ps1           # aplica
        .\11-apps.ps1 -DryRun   # muestra que haria
#>
param([switch]$DryRun)

. "$PSScriptRoot\config.ps1"
. "$PSScriptRoot\lib.ps1"
. "$PSScriptRoot\..\config\apps.ps1"

$mount = $CFG.Mount
if (-not (Test-Path (Join-Path $mount 'Windows'))) {
  Write-Host "ERROR: no hay imagen montada en $mount" -ForegroundColor Red; exit 1
}

if (-not $Global:AppsPicked) {
  $Global:AppsPicked = @($AppCatalog | Where-Object { $_.Rec } | ForEach-Object { $_.Key })
  Write-Host "  (sin perfil: uso los recomendados)" -ForegroundColor DarkGray
}

$picked  = @($AppCatalog | Where-Object { $AppsPicked -contains $_.Key })
$winget  = @($picked | Where-Object { $_.Src -eq 'winget' })
$store   = @($picked | Where-Object { $_.Src -eq 'msstore' })
$manual  = @($picked | Where-Object { $_.Src -eq 'manual' })

Write-Host "== Fase 11: instalador de programas ==" -ForegroundColor Cyan
Write-Host ("  winget: {0}   store: {1}   manual: {2}" -f $winget.Count, $store.Count, $manual.Count) -ForegroundColor DarkGray

if (-not $picked) { Write-Host "  nada seleccionado, salteo" -ForegroundColor DarkGray; return }
if ($DryRun) {
  $picked | ForEach-Object { Write-Step "[dry] $($_.Src): $($_.Name) ($($_.Id))" 'DarkGray' }
  return
}

$scriptsDir = Join-Path $mount 'Windows\Setup\Scripts'
New-Item -ItemType Directory -Force -Path $scriptsDir | Out-Null

# ---------------------------------------------------------------------------
#  El script que corre en el primer login
# ---------------------------------------------------------------------------
$sb = New-Object System.Text.StringBuilder
function Add-Line($t) { [void]$sb.AppendLine($t) }

Add-Line '# LunaticOS - instalacion de programas del primer arranque.'
Add-Line '# Generado por la fase 11. Se autoborra al terminar bien.'
Add-Line '$ErrorActionPreference = "Continue"'
Add-Line '$log = "$env:ProgramData\LunaticOS\install-apps.log"'
Add-Line 'New-Item -ItemType Directory -Force -Path (Split-Path $log) | Out-Null'
Add-Line 'function L($m) { $s = "{0}  {1}" -f (Get-Date -Format "HH:mm:ss"), $m; Write-Host $s; Add-Content -Path $log -Value $s }'
Add-Line 'L "=== LunaticOS: instalando programas ==="'
Add-Line ''
Add-Line '# --- Esperar a que winget este listo ---'
Add-Line '# En el PRIMER login de un usuario nuevo, App Installer todavia se esta'
Add-Line '# registrando y winget no existe como comando por uno o dos minutos. Sin esta'
Add-Line '# espera, TODAS las instalaciones fallarian y el log diria "no se reconoce winget".'
Add-Line '$wg = $null'
Add-Line 'for ($i = 1; $i -le 30; $i++) {'
Add-Line '  $wg = (Get-Command winget -ErrorAction SilentlyContinue)'
Add-Line '  if ($wg) { break }'
Add-Line '  L "winget todavia no esta listo (intento $i/30), espero 10s..."'
Add-Line '  Start-Sleep -Seconds 10'
Add-Line '}'
Add-Line 'if (-not $wg) {'
Add-Line '  L "ERROR: winget no aparecio. Corre este script a mano mas tarde:"'
Add-Line '  L "  powershell -ExecutionPolicy Bypass -File $PSCommandPath"'
Add-Line '  exit 1'
Add-Line '}'
Add-Line 'L "winget OK: $((winget --version) 2>&1)"'
Add-Line ''
Add-Line '# --- Esperar red ---'
Add-Line 'for ($i = 1; $i -le 20; $i++) {'
Add-Line '  if (Test-Connection -ComputerName 8.8.8.8 -Count 1 -Quiet -ErrorAction SilentlyContinue) { break }'
Add-Line '  L "sin red (intento $i/20), espero 15s..."'
Add-Line '  Start-Sleep -Seconds 15'
Add-Line '}'
Add-Line ''
Add-Line '$ok = 0; $bad = @()'
Add-Line 'function Install-One($name, $id, $src) {'
Add-Line '  L "instalando $name ($id)..."'
Add-Line '  $a = @("install","--id",$id,"--exact","--silent",'
Add-Line '         "--accept-package-agreements","--accept-source-agreements")'
Add-Line '  if ($src) { $a += @("--source",$src) }'
Add-Line '  # --scope machine cuando se pueda: si no, queda instalado solo para este'
Add-Line '  # usuario y el resto de las cuentas no lo ven.'
Add-Line '  $out = & winget @a 2>&1 | Out-String'
Add-Line '  if ($LASTEXITCODE -eq 0) { $script:ok++; L "  OK $name" }'
Add-Line '  else {'
Add-Line '    # Reintento sin --source: algunos paquetes cambian de origen.'
Add-Line '    $out2 = & winget install --id $id --exact --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-String'
Add-Line '    if ($LASTEXITCODE -eq 0) { $script:ok++; L "  OK $name (2do intento)" }'
Add-Line '    else { $script:bad += $name; L "  FALLO $name -> exit $LASTEXITCODE" }'
Add-Line '  }'
Add-Line '}'
Add-Line ''

foreach ($a in $winget) {
  Add-Line ("Install-One '{0}' '{1}' 'winget'" -f ($a.Name -replace "'", "''"), $a.Id)
}
foreach ($a in $store) {
  Add-Line ("Install-One '{0}' '{1}' 'msstore'" -f ($a.Name -replace "'", "''"), $a.Id)
}

Add-Line ''
Add-Line 'L "=== resumen: $ok instalados, $($bad.Count) fallidos ==="'
Add-Line "if (`$bad) { L `"fallidos: `$(`$bad -join ', ')`" }"

# --- Descargas manuales: no se pueden automatizar, pero SI se puede no olvidarlas ---
if ($manual) {
  Add-Line ''
  Add-Line '# --- Programas que NO estan en winget (drivers, etc.) ---'
  Add-Line '$pend = "$env:USERPROFILE\Desktop\LunaticOS - descargas pendientes.txt"'
  Add-Line '$t = @()'
  Add-Line '$t += "Estos NO se pueden instalar por winget. Bajalos del sitio oficial:"'
  Add-Line '$t += ""'
  foreach ($a in $manual) {
    Add-Line ("`$t += `"{0}`"" -f ($a.Name -replace '"', '`"'))
    Add-Line ("`$t += `"   {0}`"" -f $a.Url)
    if ($a.Note) { Add-Line ("`$t += `"   nota: {0}`"" -f ($a.Note -replace '"', '`"')) }
    Add-Line '$t += ""'
  }
  Add-Line '$t += "Los drivers de GPU (NVIDIA/AMD) y de chipset NO estan en winget."'
  Add-Line '$t += "Se verifico uno por uno: no es que nos olvidamos."'
  Add-Line 'Set-Content -Path $pend -Value $t -Encoding UTF8'
  Add-Line 'L "deje la lista de descargas manuales en el escritorio"'
}

Add-Line ''
Add-Line '# Autolimpieza solo si no quedo nada pendiente: si algo fallo, el script se'
Add-Line '# queda para poder reintentarlo.'
Add-Line 'if ($bad.Count -eq 0) { Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue }'
Add-Line 'else { L "el script NO se borro: podes reintentar los fallidos corriendolo de nuevo." }'

$dest = Join-Path $scriptsDir 'lunaticos-apps.ps1'
Set-Content -Path $dest -Value $sb.ToString() -Encoding UTF8
Write-Step "instalador generado: Windows\Setup\Scripts\lunaticos-apps.ps1 ($($winget.Count + $store.Count) programas)" 'Green'

# ---------------------------------------------------------------------------
#  RunOnce que lo dispara en el primer login
# ---------------------------------------------------------------------------
# Va en RunOnce y NO en SetupComplete.cmd porque SetupComplete corre como SYSTEM
# ANTES del OOBE: ahi winget no existe todavia y no hay usuario. RunOnce corre en
# el primer login del usuario real, que es cuando winget si funciona.
# El prefijo 'ZZ' es DELIBERADO: RunOnce corre sus entradas en orden alfabetico y
# secuencial, esperando a que cada una termine. Esta tarda 20+ minutos bajando
# programas, asi que va ULTIMA. Antes se llamaba "LunaticOSApps" y bloqueaba a la
# limpieza de accesos directos de Edge, que quedaba encolada detras y no corria.
# Orden:  AA personalizar (rapido) -> AB limpiar Edge (rapido) -> ZZ apps (lento).
Use-OfflineHive -HivePath (Join-Path $mount 'Windows\System32\config\SOFTWARE') -MountKey 'OFF_SW_APPS' -Action {
  param($root)
  $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Windows\Setup\Scripts\lunaticos-apps.ps1"'
  Invoke-Reg add "$root\Microsoft\Windows\CurrentVersion\RunOnce" /v ZZLunaticOSApps /t REG_SZ /d $cmd /f
}
Write-Step "RunOnce ZZLunaticOSApps: se instalan en el primer login (ultimo de la cola)" 'Green'

Write-Host ""
Write-Host "Los programas se instalan solos en el primer arranque (hace falta internet)." -ForegroundColor Green
Write-Host "Log en: C:\ProgramData\LunaticOS\install-apps.log" -ForegroundColor DarkGray
