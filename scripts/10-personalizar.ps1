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

Write-Host ""
Write-Host "Personalizacion aplicada como DEFAULT: el usuario puede cambiar todo desde Settings." -ForegroundColor Green
