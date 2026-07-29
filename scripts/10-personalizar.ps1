#requires -Version 5.1
<#
  Fase 10 — Personalizacion (estetica) en el hive DEFAULT, offline.

  ===========================================================================
  TODO LO DE ACA ES UN *DEFAULT*, NO UNA *POLICY*. La diferencia importa:

    DEFAULT (Users\Default\NTUSER.DAT)  -> punto de partida. Todo perfil nuevo lo
      hereda y el usuario lo cambia desde Settings cuando quiera.
    POLICY  (HKLM\SOFTWARE\Policies)    -> BLOQUEA la opcion, la deja gris y con
      el cartel "administradas por tu organizacion".

  Esta fase NUNCA escribe policies. Si en el futuro alguien quiere "asegurar" un
  ajuste estetico con una policy: no. El usuario tiene que poder cambiar el color
  de su propia computadora.
  ===========================================================================

  Lee $PersonalizacionPicked (lo llena LunaticOS.ps1 desde el perfil.json).
  Si corres esta fase a mano sin la TUI, se aplican los marcados como Rec.

  Uso:  .\10-personalizar.ps1           # aplica
        .\10-personalizar.ps1 -DryRun   # muestra que haria
#>
param([switch]$DryRun)

. "$PSScriptRoot\config.ps1"
. "$PSScriptRoot\lib.ps1"
. "$PSScriptRoot\..\config\personalizacion.ps1"

$mount = $CFG.Mount
if (-not (Test-Path (Join-Path $mount 'Windows'))) {
  Write-Host "ERROR: no hay imagen montada en $mount" -ForegroundColor Red; exit 1
}

# Sin TUI: caer en los recomendados. Asi la fase sirve suelta, igual que las otras.
if (-not $Global:PersonalizacionPicked) {
  $Global:PersonalizacionPicked = @($PersonalizacionCatalog | Where-Object { $_.Rec } | ForEach-Object { $_.Key })
  Write-Host "  (sin perfil: aplico los recomendados)" -ForegroundColor DarkGray
}

$picked = @($PersonalizacionCatalog | Where-Object { $PersonalizacionPicked -contains $_.Key })

Write-Host "== Fase 10: personalizacion ($($picked.Count) items) ==" -ForegroundColor Cyan
if (-not $picked) { Write-Host "  nada seleccionado, salteo" -ForegroundColor DarkGray; return }

if ($DryRun) {
  foreach ($it in $picked) {
    Write-Step "[dry] $($it.Name)" 'DarkGray'
    foreach ($r in $it.Regs) { Write-Step "        $($r.k)\$($r.v) = $($r.d)" 'DarkGray' }
  }
  return
}

# --- Separar lo de usuario de lo de maquina: van a hives distintos ---
$userItems    = @($picked | Where-Object { -not $_.Machine })
$machineItems = @($picked | Where-Object { $_.Machine })

function Write-Regs($root, $items) {
  $ok = 0; $fail = @()
  foreach ($it in $items) {
    foreach ($r in $it.Regs) {
      $key = if ($r.k) { "$root\$($r.k)" } else { $root }
      # Un valor con nombre vacio es el "(Default)" de la clave: reg.exe lo escribe
      # con /ve, no con /v "". Es exactamente el caso del menu contextual clasico.
      if ([string]::IsNullOrEmpty($r.v)) {
        # OJO: NO se puede pasar /d con string vacio -- reg.exe se queda esperando
        # input para siempre (misma trampa que documenta la guarda de Invoke-Reg en
        # lib.ps1). Omitir /d crea el valor "(Default)" vacio, que es lo que queremos.
        & reg.exe add $key /ve /t REG_SZ /f 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $ok++ } else { $fail += "$key\(Default)" }
        continue
      }
      $type = if ($r.t -eq 'sz') { 'REG_SZ' } else { 'REG_DWORD' }
      $data = if ($r.t -eq 'sz') { "$($r.d)" } else { [string][int]$r.d }
      $out = & reg.exe add $key /v $r.v /t $type /d $data /f 2>&1
      if ($LASTEXITCODE -eq 0) { $ok++ } else { $fail += "$key\$($r.v)"; }
    }
  }
  Write-Step "valores escritos: $ok  fallidos: $($fail.Count)" $(if ($fail) { 'Yellow' } else { 'Green' })
  if ($fail) { $fail | ForEach-Object { Write-Step "  no pude: $_" 'Yellow' } }
}

# --- Hive de usuario (DEFAULT) ---
if ($userItems) {
  Use-OfflineHive -HivePath (Join-Path $mount 'Users\Default\NTUSER.DAT') -MountKey 'OFF_PERS' -Action {
    param($root)
    Write-Regs $root $userItems
  }
  foreach ($it in $userItems) { Write-Step "aplicado: $($it.Name)" 'Green' }
}

# --- Hive de maquina (SOFTWARE) ---
if ($machineItems) {
  Use-OfflineHive -HivePath (Join-Path $mount 'Windows\System32\config\SOFTWARE') -MountKey 'OFF_PERS_M' -Action {
    param($root)
    Write-Regs $root $machineItems
  }
  foreach ($it in $machineItems) { Write-Step "aplicado (maquina): $($it.Name)" 'Green' }
}

# ---------------------------------------------------------------------------
# WALLPAPER
# ---------------------------------------------------------------------------
$wpDir = Join-Path $CFG.Root $WallpaperDir
$wp = if (Test-Path $wpDir) {
  Get-ChildItem $wpDir -Include '*.jpg','*.jpeg','*.png' -File -EA SilentlyContinue | Select-Object -First 1
} else { $null }

if ($wp) {
  # Se copia DENTRO de la imagen: si lo dejaramos apuntando a una ruta del host, el
  # fondo aparece negro en la maquina instalada y nadie entiende por que.
  $destDir = Join-Path $mount 'Windows\Web\Wallpaper\LunaticOS'
  New-Item -ItemType Directory -Force -Path $destDir | Out-Null
  Copy-Item $wp.FullName (Join-Path $destDir $wp.Name) -Force
  $inImage = "C:\Windows\Web\Wallpaper\LunaticOS\$($wp.Name)"
  Use-OfflineHive -HivePath (Join-Path $mount 'Users\Default\NTUSER.DAT') -MountKey 'OFF_WP' -Action {
    param($root)
    Invoke-Reg add "$root\Control Panel\Desktop" /v WallPaper      /t REG_SZ /d $inImage /f
    Invoke-Reg add "$root\Control Panel\Desktop" /v WallpaperStyle /t REG_SZ /d 10 /f   # 10 = Rellenar
    Invoke-Reg add "$root\Control Panel\Desktop" /v TileWallpaper  /t REG_SZ /d 0 /f
  }
  Write-Step "wallpaper: $($wp.Name) -> $inImage" 'Green'
} else {
  Write-Step "sin wallpaper propio (poné un .jpg/.png en $WallpaperDir si querés uno)" 'DarkGray'
}

# ===========================================================================
#  REAPLICAR EN EL PRIMER LOGIN (RunOnce)
# ===========================================================================
#  ESCRIBIR EL HIVE DEFAULT NO ALCANZA. Medido en VM, auditando el hive del
#  usuario despues de instalar:
#
#    tema oscuro ............ pedido 0, quedo 1   <- EL OOBE LO PISO
#    color de acento ........ pedido teal, quedo 0xFFD47800 (el azul de Windows)
#    sin transparencia ...... OK
#    taskbar izquierda ...... OK
#    segundos en el reloj ... OK
#
#  O sea: la escritura offline funciona (tres valores del MISMO hive quedaron
#  bien), pero el OOBE sobreescribe ESPECIFICAMENTE el tema y el acento cuando
#  crea el perfil del usuario. No hay forma de ganarle desde offline: corre despues.
#
#  Y hay un segundo problema, distinto: el menu contextual clasico vive en
#  Software\Classes, que en HKCU NO esta en NTUSER.DAT sino en UsrClass.dat, un
#  hive SEPARADO. Escribirlo en NTUSER.DAT no hace absolutamente nada.
#
#  Los dos se resuelven igual: reaplicar en el primer login, cuando el OOBE ya
#  termino y HKCU apunta a los hives de verdad.
# ===========================================================================
$scriptsDir = Join-Path $mount 'Windows\Setup\Scripts'
New-Item -ItemType Directory -Force -Path $scriptsDir | Out-Null

$sb = New-Object System.Text.StringBuilder
function Add-L($t) { [void]$sb.AppendLine($t) }

Add-L '# LunaticOS - reaplica la personalizacion en el primer login.'
Add-L '# Existe porque el OOBE pisa el tema y el acento, y porque Software\Classes'
Add-L '# vive en UsrClass.dat y no en NTUSER.DAT (ver fase 10).'
Add-L '$ErrorActionPreference = "Continue"'
Add-L '$log = "$env:ProgramData\LunaticOS\personalizar.log"'
Add-L 'New-Item -ItemType Directory -Force -Path (Split-Path $log) | Out-Null'
Add-L 'function L($m) { $s = "{0}  {1}" -f (Get-Date -Format "HH:mm:ss"), $m; Write-Host $s; Add-Content -Path $log -Value $s }'
Add-L 'L "=== reaplicando personalizacion ==="'
Add-L ''

foreach ($it in $userItems) {
  Add-L ("# --- {0} ---" -f $it.Name)
  foreach ($r in $it.Regs) {
    $key = if ($r.k) { "HKCU:\$($r.k)" } else { 'HKCU:' }
    Add-L ("New-Item -Path '{0}' -Force -ErrorAction SilentlyContinue | Out-Null" -f $key)
    if ([string]::IsNullOrEmpty($r.v)) {
      # Valor "(Default)" vacio: en runtime se escribe con el nombre '(default)'
      Add-L ("Set-ItemProperty -Path '{0}' -Name '(default)' -Value '' -ErrorAction SilentlyContinue" -f $key)
    } elseif ($r.t -eq 'sz') {
      Add-L ("Set-ItemProperty -Path '{0}' -Name '{1}' -Value '{2}' -Type String -ErrorAction SilentlyContinue" -f $key, $r.v, $r.d)
    } else {
      Add-L ("Set-ItemProperty -Path '{0}' -Name '{1}' -Value {2} -Type DWord -ErrorAction SilentlyContinue" -f $key, $r.v, [int]$r.d)
    }
  }
  Add-L ("L 'aplicado: {0}'" -f ($it.Name -replace "'", "''"))
  Add-L ''
}

# El acento necesita ademas AccentPalette (blob de 8 tonos) para que TODA la UI
# tome el color. Sin eso, partes de la interfaz siguen con el azul viejo.
$acento = @($userItems | Where-Object { $_.Key -like 'acento-*' -and $_.Key -ne 'acento-en-taskbar' })
if ($acento) {
  $col = ($acento[0].Regs | Where-Object { $_.v -eq 'AccentColor' } | Select-Object -First 1).d
  Add-L '# --- AccentPalette: la UI usa 8 tonos derivados, no solo AccentColor ---'
  Add-L ("`$c = [uint32]{0}" -f $col)
  Add-L '$b = ($c -shr 16) -band 0xFF; $g = ($c -shr 8) -band 0xFF; $r8 = $c -band 0xFF'
  Add-L '$pal = New-Object byte[] 32'
  Add-L '# 8 entradas BGRA: de mas claro a mas oscuro, escalando el color base.'
  Add-L '$facts = @(2.2, 1.8, 1.4, 1.0, 0.75, 0.55, 0.4, 0.3)'
  Add-L 'for ($i = 0; $i -lt 8; $i++) {'
  Add-L '  $f = $facts[$i]'
  Add-L '  $pal[$i*4+0] = [byte][Math]::Min(255, [int]($b  * $f))'
  Add-L '  $pal[$i*4+1] = [byte][Math]::Min(255, [int]($g  * $f))'
  Add-L '  $pal[$i*4+2] = [byte][Math]::Min(255, [int]($r8 * $f))'
  Add-L '  $pal[$i*4+3] = 255'
  Add-L '}'
  Add-L 'Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent" -Name AccentPalette -Value $pal -Type Binary -ErrorAction SilentlyContinue'
  Add-L 'L "AccentPalette escrito"'
  Add-L ''
}

Add-L '# Reiniciar Explorer para que tome el tema, el acento y el menu contextual.'
Add-L '# Sin esto hay que cerrar sesion: los cambios estan escritos pero no se ven,'
Add-L '# y parece que el script no hizo nada.'
Add-L 'L "reiniciando Explorer..."'
Add-L 'Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue'
Add-L 'Start-Sleep -Seconds 3'
Add-L 'if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }'
Add-L 'L "=== listo ==="'
Add-L 'Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue'

Set-Content -Path (Join-Path $scriptsDir 'lunaticos-personalizar.ps1') -Value $sb.ToString() -Encoding UTF8
Write-Step "generado lunaticos-personalizar.ps1 (reaplica en el primer login)" 'Green'

# RunOnce con prefijo 'AA' A PROPOSITO: RunOnce ejecuta sus entradas en orden
# alfabetico y de forma secuencial. La personalizacion es rapida y tiene que correr
# ANTES del instalador de programas (ZZ...), que tarda 20+ minutos. Si quedara
# despues, el usuario ve el tema claro durante toda la instalacion.
Use-OfflineHive -HivePath (Join-Path $mount 'Windows\System32\config\SOFTWARE') -MountKey 'OFF_SW_PERS_RO' -Action {
  param($root)
  $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Windows\Setup\Scripts\lunaticos-personalizar.ps1"'
  Invoke-Reg add "$root\Microsoft\Windows\CurrentVersion\RunOnce" /v AALunaticOSPersonalizar /t REG_SZ /d $cmd /f
}
Write-Step "RunOnce AALunaticOSPersonalizar (corre antes que el instalador de apps)" 'Green'

Write-Host ""
Write-Host "Personalizacion: escrita en el hive DEFAULT + reaplicada en el primer login." -ForegroundColor Green
Write-Host "Todo como DEFAULT, no como policy: el usuario cambia lo que quiera desde Settings." -ForegroundColor DarkGray
