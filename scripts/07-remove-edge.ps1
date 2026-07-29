#requires -Version 5.1
<#
  Fase 7 - Edge INVISIBLE e INEJECUTABLE, con WebView2 actualizandose solo.

  ===========================================================================
  LA HISTORIA COMPLETA (leer antes de "mejorar" esto: ya fallo dos veces)

  INTENTO 1 - desinstalarlo con su propio uninstaller. FALLO.
      Browser/WebView is sticky, uninstall not allowed.
      WARNING: Uninstall was blocked for this product: 93
  Fuera del EEA el uninstaller de Microsoft se niega.

  INTENTO 2 - borrarlo offline + policy Install{GUID}=0 + region EEA. FALLO.
      [IsEdgeUninstallablePerRegionalPolicy][0]
      [Edge not uninstallable per regional policy, skipping group policy]
  EdgeUpdate saltea las policies fuera del EEA. Y el truco de la region tampoco
  anduvo: el <UserLocale>es-AR</UserLocale> del pass oobeSystem pisa el GeoID
  antes de que EdgeUpdate corra durante el OOBE (D20).

  INTENTO 3 - borrarlo offline + matar los servicios edgeupdate. FALLO.
  Y aca aparecio LA CAUSA RAIZ, en el log de la VM:
      [Installing][display name: Microsoft EdgeWebView]
      [installer path: ...\MicrosoftEdge_X64_150.0.4078.105.exe]
      [manifest args: --msedgewebview --do-not-launch-msedge --system-level]

  EL INSTALADOR ES UNIFICADO: el MISMO binario instala WebView2 y Edge. Windows
  Update lo baja para actualizar WEBVIEW2 -que queremos conservar- y Edge viene
  adentro. Ademas el instalador RECREA los servicios edgeupdate: el Start=4 que
  escribimos offline volvio solo a 0x2.
  Y encima WU invoca el EJECUTABLE directo (/installsource windowsupdate_zdp),
  no via servicio: deshabilitar el servicio nunca iba a impedirlo.

  CONCLUSION: "WebView2 al dia" y "Edge desinstalado" son INCOMPATIBLES. Son el
  mismo paquete. No hay termino medio.

  QUE HACEMOS ENTONCES: elegimos la otra rama. Edge se queda en disco pero no
  puede EJECUTARSE ni aparece en ningun lado. EdgeUpdate sigue vivo y WebView2
  se sigue parchando solo, sin mantenimiento manual.

  VERIFICADO EN VM (25H2): tras aplicarlo, Edge desaparecio del escritorio y del
  menu Inicio, el widget del clima siguio funcionando (o sea WebView2 opera), y
  ejecutar "msedge.exe" desde Win+R no hace absolutamente nada.
  ===========================================================================

  POR QUE NO CUESTA DISCO: Edge, EdgeCore y EdgeWebView son HARDLINKS al mismo
  contenido en NTFS. Con WebView2 presente, Edge "de mas" ocupa casi nada.

  POR QUE NO ROMPE WEBVIEW2: WebView2 corre msedgewebview2.exe, un ejecutable
  DISTINTO de msedge.exe. Bloquear msedge.exe no lo toca. Por eso la lista de
  bloqueo es explicita y NO usa comodines.

  EFECTO SECUNDARIO ACEPTADO: si algo del sistema intenta abrir un link con Edge,
  falla en silencio. Pone Firefox/Chrome como predeterminado.

  Uso:  .\07-remove-edge.ps1           # aplica
        .\07-remove-edge.ps1 -DryRun   # muestra que haria
#>
param([switch]$DryRun)

. "$PSScriptRoot\config.ps1"
. "$PSScriptRoot\lib.ps1"
$mount = $CFG.Mount

if (-not (Test-Path (Join-Path $mount 'Windows'))) {
  Write-Host "ERROR: no hay imagen montada en $mount" -ForegroundColor Red; exit 1
}
if (-not $Flags.RemoveEdgeBrowser) {
  Write-Host "Flags.RemoveEdgeBrowser = false -> salteo Edge (queda usable)"; return
}

Write-Host "== Fase 7: Edge invisible e inejecutable (WebView2 sigue al dia) ==" -ForegroundColor Cyan

# --------------------------------------------------------------------------
# 0) LIMPIEZA de los enfoques viejos (idempotencia real)
# --------------------------------------------------------------------------
# Las versiones anteriores de esta fase escribian cosas que AHORA JUEGAN EN CONTRA:
#   - Install{56EB18F8-...}=0  ->  bloquea Edge Stable, y como el paquete es
#                                  compartido con WebView2, tambien lo frenaria.
#   - edgeupdate/edgeupdatem Start=4  ->  sin updater, WebView2 queda sin parches.
# Si el WIM viene de una corrida vieja, esos valores estan ahi. Hay que sacarlos,
# no alcanza con "no escribirlos". Un script idempotente tiene que dejar el estado
# correcto viniendo de CUALQUIER estado anterior, no solo de una imagen virgen.
if (-not $DryRun) {
  Use-OfflineHive -HivePath (Join-Path $mount 'Windows\System32\config\SOFTWARE') -MountKey 'OFF_SW_CLEAN' -Action {
    param($root)
    $eup = "$root\Policies\Microsoft\EdgeUpdate"
    foreach ($v in @('Install{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}',
                     'DoNotUpdateToEdgeWithChromium', 'InstallDefault')) {
      & reg.exe delete $eup /v $v /f 2>$null | Out-Null
    }
    & reg.exe delete "$root\Microsoft\EdgeUpdate" /v DoNotUpdateToEdgeWithChromium /f 2>$null | Out-Null
    Write-Step "policies viejas de bloqueo de EdgeUpdate eliminadas" 'DarkGray'
  }

  # Servicios de EdgeUpdate de vuelta a sus valores de fabrica:
  #   edgeupdate = 2 (Automatic)   edgeupdatem = 3 (Manual)
  # Verificado en la VM: son los valores que el propio instalador de Microsoft deja.
  Use-OfflineHive -HivePath (Join-Path $mount 'Windows\System32\config\SYSTEM') -MountKey 'OFF_SYS_EDGE' -Action {
    param($root)
    foreach ($s in @(@{N='edgeupdate'; V=2}, @{N='edgeupdatem'; V=3})) {
      $key = "$root\ControlSet001\Services\$($s.N)"
      & reg.exe query $key 2>$null | Out-Null
      if ($LASTEXITCODE -eq 0) {
        Invoke-Reg add $key /v Start /t REG_DWORD /d $s.V /f
        Write-Step "$($s.N) -> Start=$($s.V) (vivo, mantiene WebView2)" 'Green'
      }
    }
  }
}

# --------------------------------------------------------------------------
# 1) IFEO: que el NAVEGADOR no pueda ejecutarse
# --------------------------------------------------------------------------
# IFEO permite definir un "Debugger" que el kernel ejecuta EN LUGAR del binario.
# Apuntandolo a systray.exe (existe siempre, no hace nada visible) el proceso
# muere sin ventana, sin error y sin dependencias raras.
#
# Sobrevive a que Windows Update reinstale Edge, porque la clave es por NOMBRE
# de ejecutable y no por ruta. Eso es justo lo que los intentos anteriores no
# lograban: aca no importa cuantas veces lo reinstalen.
Use-OfflineHive -HivePath (Join-Path $mount 'Windows\System32\config\SOFTWARE') -MountKey 'OFF_SW_EDGE' -Action {
  param($root)
  $ifeo = "$root\Microsoft\Windows NT\CurrentVersion\Image File Execution Options"
  foreach ($exe in $EdgeBlockedExes) {
    Invoke-Reg add "$ifeo\$exe" /v Debugger /t REG_SZ /d $EdgeIfeoStub /f
    Write-Step "bloqueado: $exe" 'Green'
  }

  # --- Policies del navegador: que no moleste ni se auto-ancle ---
  $pol = "$root\Policies\Microsoft\Edge"
  Invoke-Reg add $pol /v HideFirstRunExperience /t REG_DWORD /d 1 /f
  Invoke-Reg add $pol /v PinBrowserToTaskbar    /t REG_DWORD /d 0 /f
  Invoke-Reg add $pol /v StartupBoostEnabled    /t REG_DWORD /d 0 /f
  Invoke-Reg add $pol /v BackgroundModeEnabled  /t REG_DWORD /d 0 /f
  Write-Step "policies: sin first-run, sin pin en taskbar, sin arranque en background" 'Green'

  # --- Que el instalador NO cree el acceso directo del escritorio ---
  # Esta es la pieza que evita que el icono reaparezca cuando WU reinstala Edge
  # junto con WebView2. Va en las policies de EdgeUpdate (el instalador las lee
  # para decidir si crea el shortcut), NO en las de Edge.
  $eup = "$root\Policies\Microsoft\EdgeUpdate"
  Invoke-Reg add $eup /v CreateDesktopShortcutDefault /t REG_DWORD /d 0 /f
  Invoke-Reg add $eup /v RemoveDesktopShortcutDefault /t REG_DWORD /d 1 /f
  Write-Step "EdgeUpdate: sin acceso directo en el escritorio" 'Green'

  # OJO: NO se escribe Install{56EB18F8-...}=0 aca. Esa policy bloqueaba la
  # instalacion de Edge Stable... y como el paquete es compartido, tambien
  # frenaba WebView2. Se saco a proposito. Tampoco se toca InstallDefault.

  # --- Autoarranque que deja el instalador ---
  # OJO CON EL PARSEO: la primera linea de `reg query` es el NOMBRE DE LA CLAVE, no un
  # valor. Si filtras por 'Edge' a lo bruto, esa linea matchea cuando el propio MountKey
  # contiene "Edge" (nos paso: OFF_SW_EDGE) y terminas intentando borrar un valor que es
  # en realidad una ruta. El regex exige el formato de VALOR: sangria + nombre + REG_TIPO.
  foreach ($runKey in @("$root\Microsoft\Windows\CurrentVersion\Run")) {
    $out = & reg.exe query $runKey 2>$null
    if ($LASTEXITCODE -ne 0) { continue }
    foreach ($line in $out) {
      if ($line -notmatch '^\s+(\S.*?)\s+REG_[A-Z_]+\s') { continue }
      $name = $Matches[1].Trim()
      if ($name -notlike '*Edge*') { continue }
      & reg.exe delete $runKey /v $name /f 2>$null | Out-Null
      if ($LASTEXITCODE -eq 0) { Write-Step "autoarranque quitado: $name" 'Green' }
    }
  }
}

# --------------------------------------------------------------------------
# 2) BORRAR los arboles del navegador de la imagen
# --------------------------------------------------------------------------
# Esto NO reemplaza al IFEO: lo COMPLEMENTA, y hace falta por un motivo concreto.
#
# El layout por defecto del menu Inicio de Windows 11 trae Edge PINNEADO. Ese pin
# no es un .lnk -- vive dentro de start2.bin, un blob binario que decidimos no
# tocar (romperlo es peor que el problema). Pero el pin solo se MATERIALIZA si el
# ejecutable existe en la imagen: si Edge no esta, el icono no aparece.
#
# Medido a la mala: una ISO armada sobre un WIM donde Edge seguia presente salio
# con Edge pinneado en el Inicio. El IFEO impedia abrirlo, pero el icono estaba
# ahi y el usuario -con razon- lo leyo como "no funciono".
#
# Entonces:
#   borrar  -> el pin y los accesos directos no existen en la instalacion inicial
#   IFEO    -> cuando Windows Update lo reinstale junto con WebView2, no ejecuta
# Los tres arboles son HARDLINKS al mismo contenido: borrar Edge y EdgeCore deja
# EdgeWebView (WebView2) intacto, que es justo lo que queremos conservar.
$pfx86kill = Join-Path $mount 'Program Files (x86)\Microsoft'
foreach ($d in @((Join-Path $pfx86kill 'Edge'), (Join-Path $pfx86kill 'EdgeCore'))) {
  if (-not (Test-Path $d)) { Write-Step "(no existe) $(Split-Path $d -Leaf)" 'DarkGray'; continue }
  $mb = [math]::Round(((Get-ChildItem $d -Recurse -Force -File -EA SilentlyContinue |
                        Measure-Object Length -Sum).Sum) / 1MB, 1)
  if ($DryRun)                    { Write-Step "[dry] borraria $d ($mb MB)" 'DarkGray' }
  elseif (Remove-ProtectedDir $d) { Write-Step "borrado de la imagen: $(Split-Path $d -Leaf) ($mb MB)" 'Green' }
  else                            { Write-Step "NO pude borrar: $d" 'Red' }
}

# --------------------------------------------------------------------------
# 3) Accesos directos que ya vienen en la imagen
# --------------------------------------------------------------------------
$lnks = @(
  (Join-Path $mount 'ProgramData\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk')
  (Join-Path $mount 'Users\Default\Desktop\Microsoft Edge.lnk')
  (Join-Path $mount 'Users\Public\Desktop\Microsoft Edge.lnk')
  (Join-Path $mount 'Users\Default\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk')
  (Join-Path $mount 'Users\Default\AppData\Roaming\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Microsoft Edge.lnk')
)
$n = 0
foreach ($l in $lnks) {
  if (-not (Test-Path $l)) { continue }
  if ($DryRun)                     { Write-Step "[dry] borraria $l" 'DarkGray'; continue }
  if (Remove-ProtectedFile $l)     { $n++ }
}
if (-not $DryRun) { Write-Step "accesos directos de la imagen borrados: $n" 'Green' }

# --------------------------------------------------------------------------
# 3) Verificar que WebView2 y EdgeUpdate quedaron INTACTOS
# --------------------------------------------------------------------------
# Esto no es decorativo: si alguno de los dos falta, la Store y Widgets se
# rompen y WebView2 se queda sin parches. Es el punto del enfoque nuevo.
$pfx86 = Join-Path $mount 'Program Files (x86)\Microsoft'
$wv    = Join-Path $pfx86 'EdgeWebView\Application'
if (Test-Path $wv) {
  $c = (Get-ChildItem $wv -Recurse -Force -Filter 'msedgewebview2.exe' -EA SilentlyContinue).Count
  Write-Step "WebView2 intacto: msedgewebview2.exe presente ($c)" 'Green'
} else {
  Write-Host "  ! ALERTA: falta EdgeWebView. La Store y Widgets se van a romper." -ForegroundColor Red
}
if (Test-Path (Join-Path $pfx86 'EdgeUpdate')) {
  Write-Step "EdgeUpdate presente y ACTIVO -> WebView2 se sigue parchando solo" 'Green'
} else {
  Write-Host "  ! OJO: no hay EdgeUpdate. WebView2 va a quedar sin actualizaciones." -ForegroundColor Yellow
}

if ($DryRun) { Write-Host "[dry] fin (no se tocaron hives de usuario)"; return }

# --------------------------------------------------------------------------
# 4) Region: Argentina y punto (el truco EEA no funciono, ver D20)
# --------------------------------------------------------------------------
foreach ($h in @(
    @{ Path = (Join-Path $mount 'Windows\System32\config\DEFAULT'); Key = 'OFF_DEFSYS'; What = 'hive DEFAULT (SYSTEM)' },
    @{ Path = (Join-Path $mount 'Users\Default\NTUSER.DAT');        Key = 'OFF_DEFUSR'; What = 'perfil Default' }
)) {
  if (-not (Test-Path $h.Path)) { Write-Step "(no existe) $($h.Path)" 'DarkGray'; continue }
  # OJO: adentro del scriptblock solo se ven las variables $Global: (config.ps1 las define
  # asi). Una variable local del script llega VACIA, y un "reg add /d" vacio cuelga para
  # siempre esperando input. Por eso se usa $Geo.GeoId (global) y no una copia local.
  Use-OfflineHive -HivePath $h.Path -MountKey $h.Key -Action {
    param($root)
    Invoke-Reg add "$root\Control Panel\International\Geo" /v Nation /t REG_SZ /d $Geo.GeoId /f
  }
  Write-Step "GeoID $($Geo.GeoId) (AR) -> $($h.What)" 'Green'
}

Write-Host ""
Write-Host "Edge oculto y bloqueado. WebView2 y EdgeUpdate conservados y funcionando." -ForegroundColor Green
Write-Host "Acordate de poner Firefox/Chrome como navegador predeterminado." -ForegroundColor Yellow
