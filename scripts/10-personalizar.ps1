#requires -Version 5.1
<#
  Fase 10 - Personalizacion (estetica): tema, color de acento y wallpaper.

  ===========================================================================
  TODO LO DE ACA ES UN *DEFAULT* O UN *TEMA*, NUNCA UNA *POLICY*.

    DEFAULT (Users\Default\NTUSER.DAT)  -> punto de partida. Todo perfil nuevo lo
      hereda y el usuario lo cambia desde Settings cuando quiera.
    TEMA    (LunaticOS.theme)           -> lo aplica el motor de temas de Windows.
      Reversible: el usuario elige otro tema y listo.
    POLICY  (HKLM\SOFTWARE\Policies)    -> BLOQUEA la opcion, la deja gris y con
      el cartel "administradas por tu organizacion". PROHIBIDO.

  Esta fase no solo NO escribe policies: BORRA las que bloquean Personalization
  si aparecen en la imagen (paso 5, contrato 5.2).
  ===========================================================================

  ===========================================================================
  LA CAUSA RAIZ DE "EL TEMA Y EL ACENTO SE PIERDEN" (medida, no supuesta)
  ---------------------------------------------------------------------------
  La version anterior de esta fase decia "el OOBE pisa el tema" y peleaba con un
  RunOnce. El diagnostico estaba incompleto y por eso el arreglo no alcanzaba.

  Lo que pasa de verdad: al crear el perfil de usuario, Windows APLICA UN TEMA.
  Cual, lo dice esta clave de maquina:

    HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes
      InstallTheme      = C:\Windows\resources\Themes\aero.theme
      InstallThemeLight = C:\Windows\resources\Themes\aero.theme
    HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Themes  (idem)

  Y aero.theme trae SystemMode=Light, AppMode=Light y el azul de fabrica en
  ColorizationColor. Ese paso corre DESPUES de heredar Users\Default\NTUSER.DAT,
  asi que pisa tema y color y deja intacto todo lo demas. Eso explica exactamente
  lo que se midio en la VM: TaskbarAl, ShowSecondsInSystemClock y EnableTransparency
  sobrevivieron (no viven en un .theme) y tema+acento no (si viven en un .theme).

  La solucion NO es pelearle: es cambiarle el tema que instala. Generamos
  LunaticOS.theme y apuntamos InstallTheme ahi. Windows lo aplica con su propio
  motor, que deriva TODA la paleta de 8 tonos correctamente, y queda una sola
  fuente de verdad para el color. Es lo que hacen los OEM.

  Consecuencia directa (contrato 2.4): si el color va en el .theme, NI el hive
  DEFAULT NI el RunOnce escriben un solo valor de color. Dos fuentes fue el bug
  que llego al usuario: tema oscuro "coloreado a la fuerza" con un color que no
  eligio, porque el AccentPalette que calculabamos a mano no coincidia con el
  resto de los valores.
  ===========================================================================

  Lee $PersonalizacionPicked (lo llena LunaticOS.ps1 desde el perfil.json).
  Si corres esta fase a mano sin la TUI, se aplican los marcados como Rec.

  Uso:  .\10-personalizar.ps1           # aplica
        .\10-personalizar.ps1 -DryRun   # muestra que haria (incluido el .theme)
        . .\10-personalizar.ps1         # dot-source: SOLO carga las funciones
#>
param([switch]$DryRun)

. "$PSScriptRoot\config.ps1"
. "$PSScriptRoot\lib.ps1"
. "$PSScriptRoot\..\config\personalizacion.ps1"

# ---------------------------------------------------------------------------
# Rutas DENTRO DE LA MAQUINA INSTALADA (C:\...), no del mount.
# El .theme y el registro los lee Windows cuando ya arranco de su propio disco:
# si guardaramos aca la ruta del mount (work\mount\...), el tema no existiria.
# Mismo error clasico que el wallpaper apuntando a una carpeta del host.
# ---------------------------------------------------------------------------
$ThemeFileName      = 'LunaticOS.theme'
$ThemeDirInImage    = 'Windows\Resources\Themes'
$ThemeInstalledPath = 'C:\Windows\Resources\Themes\LunaticOS.theme'
$WallpaperDirInImage = 'Windows\Web\Wallpaper\LunaticOS'
$RunOnceScriptName  = 'lunaticos-personalizar.ps1'
$RunOnceScriptPath  = 'C:\Windows\Setup\Scripts\lunaticos-personalizar.ps1'

# ===========================================================================
#  FUNCIONES (se cargan tambien al dot-sourcear, para poder testearlas sin
#  montar una imagen -- contrato seccion 7).
# ===========================================================================

# ---------------------------------------------------------------------------
# Nombres de valor que SON color. Si el .theme lleva el color, ninguno de estos
# se escribe en el hive DEFAULT ni en el script del primer login (contrato 2.4).
#
# Es un filtro activo, no un comentario: si alguien vuelve a poner colores en
# config\personalizacion.ps1, esta fase los descarta y lo dice en el log. El bug
# no fue "escribimos un valor de mas", fue "tuvimos DOS fuentes de verdad".
#
# ColorPrevalence NO ESTA EN LA LISTA A PROPOSITO: no es un color, es el booleano
# "pintar taskbar y bordes con el acento". Ese si va al hive de usuario.
# ---------------------------------------------------------------------------
function Get-ColorValueNames {
  @('AccentColor', 'AccentColorInactive', 'AccentColorMenu', 'StartColorMenu',
    'ColorizationColor', 'ColorizationAfterglow', 'AccentPalette')
}

function Test-ColorValueName([string]$Name) {
  if ([string]::IsNullOrEmpty($Name)) { return $false }
  return ((Get-ColorValueNames) -contains $Name)
}

# ---------------------------------------------------------------------------
# Genera el CONTENIDO del .theme. Plantilla exacta del contrato 2.3.
#
# Devuelve $null si no hay NADA que declarar (ni tema, ni acento, ni wallpaper):
# en ese caso el .theme no se escribe y InstallTheme no se toca, asi la imagen
# queda con el comportamiento de fabrica. La decision vive aca adentro para que
# el test la pueda medir con una sola llamada.
#
# $ThemeColor viene tal cual de (ConvertTo-AccentDwords ...).ThemeColor: ARGB con
# alpha C4 y prefijo 0X. NO se arma un color a mano en este archivo: toda
# conversion pasa por el helper de lib.ps1 (contrato 1.3).
# ---------------------------------------------------------------------------
function New-LunaticOSTheme {
  param(
    [ValidateSet('', 'Dark', 'Light')][string]$Mode = '',
    [string]$ThemeColor = '',
    [string]$WallpaperName = ''
  )

  if (-not $Mode -and -not $ThemeColor -and -not $WallpaperName) { return $null }

  # Sin eleccion explicita, Light: es el default de Windows y evita que "solo
  # acento" fuerce un modo que el usuario no pidio.
  $modo = if ($Mode -eq 'Dark') { 'Dark' } else { 'Light' }

  $out = New-Object System.Collections.Generic.List[string]
  $out.Add('; LunaticOS')
  $out.Add('[Theme]')
  $out.Add('DisplayName=LunaticOS')
  # SetLogonBackground=0: el tema no toca el fondo de la pantalla de login.
  # Forzarlo es justo lo que hace PersonalizationCSP, que deja al usuario sin
  # poder cambiar el lockscreen (contrato 5.1). No vamos por ahi.
  $out.Add('SetLogonBackground=0')
  $out.Add('')

  # La seccion entera se omite si no hay wallpaper propio: un Wallpaper= vacio
  # en un .theme borra el fondo en vez de dejar el de fabrica.
  if ($WallpaperName) {
    $out.Add('[Control Panel\Desktop]')
    $out.Add("Wallpaper=%SystemRoot%\Web\Wallpaper\LunaticOS\$WallpaperName")
    $out.Add('TileWallpaper=0')
    $out.Add('WallpaperStyle=10')   # 10 = Rellenar
    $out.Add('Pattern=')
    $out.Add('')
  }

  $out.Add('[VisualStyles]')
  $out.Add('Path=%ResourceDir%\Themes\Aero\Aero.msstyles')
  $out.Add('ColorStyle=NormalColor')
  $out.Add('Size=NormalSize')
  # Sin acento elegido se omiten LAS DOS lineas: con AutoColorization=0 y sin
  # ColorizationColor, Windows congela el color que tenga a mano.
  if ($ThemeColor) {
    $out.Add('AutoColorization=0')
    $out.Add("ColorizationColor=$ThemeColor")
  }
  $out.Add("SystemMode=$modo")
  $out.Add("AppMode=$modo")
  $out.Add('VisualStyleVersion=10')
  $out.Add('')
  $out.Add('[boot]')
  $out.Add('SCRNSAVE.EXE=')
  $out.Add('')
  $out.Add('[MasterThemeSelector]')
  $out.Add('MTSM=RJSPBS')
  $out.Add('')
  $out.Add('[Sounds]')
  $out.Add('SchemeName=@%SystemRoot%\System32\mmres.dll,-800')

  return (($out -join "`r`n") + "`r`n")
}

# ---------------------------------------------------------------------------
# Modo de tema pedido, deducido del VALOR que escriben los items, no de su Key.
#
# Un test (y un codigo) que busca la key 'tema-oscuro' se rompe el dia que
# alguien la renombre o agregue 'tema-claro'. La definicion real de "oscuro" es
# AppsUseLightTheme/SystemUsesLightTheme = 0. Medimos la clase, no la firma.
#
# Devuelve 'Dark', 'Light' o '' (el usuario no eligio tema).
# ---------------------------------------------------------------------------
function Get-RequestedThemeMode($Items) {
  $modo = ''
  foreach ($it in $Items) {
    foreach ($r in $it.Regs) {
      if (-not $r) { continue }
      if (@('AppsUseLightTheme', 'SystemUsesLightTheme') -contains $r.v) {
        # Comparacion como string a proposito: un cast a [int] de $r.d es
        # justo el patron que el self-test prohibe en este archivo (los DWORD
        # de esta fase pasaron por overflow de Int32 dos veces ya).
        $modo = if ("$($r.d)" -eq '0') { 'Dark' } else { 'Light' }
      }
    }
  }
  return $modo
}

# ---------------------------------------------------------------------------
# Claves que BLOQUEAN Settings > Personalization (contrato 5.1).
#
# Nunca las escribimos, pero la imagen puede traerlas: un ISO de un tercero, un
# NTLite preset, o una fase futura mal escrita. Borrarlas cuesta milisegundos y
# garantiza el objetivo del proyecto (que Windows QUEDE TUYO) sin importar de
# donde vino la imagen.
#
# Value = $null  -> se borra la CLAVE entera (es un contenedor solo de policies).
# Value = 'X'    -> se borra SOLO ese valor. Se usa donde la clave tambien tiene
#                   cosas legitimas: ...\Policies\System guarda EnableLUA y los
#                   avisos de logon, borrarla entera seria una barbaridad.
# ---------------------------------------------------------------------------
function Get-PersonalizationBlockers {
  $sysValues = @('NoDispCPL', 'NoDispAppearancePage', 'NoDispBackgroundPage',
                 'NoColorChoice', 'NoThemesTab', 'SetVisualStyle')
  $lista = @(
    # --- hive SOFTWARE (maquina). Rutas relativas a la raiz del hive. ---
    @{ Scope = 'SOFTWARE'; Key = 'Policies\Microsoft\Windows\Personalization'; Value = $null }
    @{ Scope = 'SOFTWARE'; Key = 'Microsoft\Windows\CurrentVersion\PersonalizationCSP'; Value = $null }
    @{ Scope = 'SOFTWARE'; Key = 'Policies\Microsoft\Windows\Control Panel\Desktop'; Value = 'Wallpaper' }
    @{ Scope = 'SOFTWARE'; Key = 'Policies\Microsoft\Windows\Control Panel\Desktop'; Value = 'WallpaperStyle' }
    # --- hive DEFAULT (usuario). Rutas relativas a la raiz de HKCU. ---
    @{ Scope = 'DEFAULT'; Key = 'Software\Policies\Microsoft\Windows\Personalization'; Value = $null }
    @{ Scope = 'DEFAULT'; Key = 'Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop'; Value = 'NoChangingWallPaper' }
  )
  foreach ($v in $sysValues) {
    $lista += @{ Scope = 'SOFTWARE'; Key = 'Microsoft\Windows\CurrentVersion\Policies\System'; Value = $v }
    $lista += @{ Scope = 'DEFAULT';  Key = 'Software\Microsoft\Windows\CurrentVersion\Policies\System'; Value = $v }
  }
  # NoThemesTab aparece documentado tambien bajo Policies\Explorer segun la
  # version de Windows. Cubrir las dos cuesta dos queries.
  $lista += @{ Scope = 'SOFTWARE'; Key = 'Microsoft\Windows\CurrentVersion\Policies\Explorer'; Value = 'NoThemesTab' }
  $lista += @{ Scope = 'DEFAULT';  Key = 'Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Value = 'NoThemesTab' }
  return $lista
}

# Borra del hive cargado las claves/valores bloqueantes de un scope. Devuelve la
# lista de lo que borro (vacia = no habia nada). Primero pregunta con query: un
# delete de algo inexistente devuelve error y ensuciaria el log de fallos.
function Remove-PersonalizationBlockers([string]$Root, [string]$Scope) {
  $borradas = @()
  foreach ($b in (Get-PersonalizationBlockers | Where-Object { $_.Scope -eq $Scope })) {
    $key = "$Root\$($b.Key)"
    if ($b.Value) {
      & reg.exe query $key /v $b.Value 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) { continue }
      & reg.exe delete $key /v $b.Value /f 2>&1 | Out-Null
      if ($LASTEXITCODE -eq 0) { $borradas += "$($b.Key)\$($b.Value)" }
    }
    else {
      & reg.exe query $key 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) { continue }
      & reg.exe delete $key /f 2>&1 | Out-Null
      if ($LASTEXITCODE -eq 0) { $borradas += "$($b.Key) (clave entera)" }
    }
  }
  return , $borradas
}

# Escribe los Regs de una lista de items en el hive ya cargado en $root.
# Descarta los valores de color: los lleva el .theme (contrato 2.4).
function Write-Regs($root, $items, [switch]$HiveIsSoftware) {
  $ok = 0; $fail = @(); $skipColor = @(); $normalizados = @()
  foreach ($it in $items) {
    foreach ($r in $it.Regs) {
      if (-not $r) { continue }
      if (Test-ColorValueName $r.v) { $skipColor += "$($it.Key)/$($r.v)"; continue }
      $rk = "$($r.k)"
      # GUARDA MEDIDA (no la saques): los items de maquina del catalogo traen la
      # ruta con el prefijo 'SOFTWARE\', pero el hive que se carga ES el SOFTWARE.
      # Concatenar da SOFTWARE\SOFTWARE\... y el valor cae en una rama que Windows
      # NO LEE NUNCA. Verificado sobre un hive de prueba: DisableStartupSound
      # quedaba en SOFTWARE\SOFTWARE\Microsoft\...\BootAnimation, o sea que "sin
      # sonido de arranque" nunca funciono -- y fallaba en silencio porque reg.exe
      # devuelve 0: la clave se crea igual, solo que en el lugar equivocado.
      # El arreglo de fondo es sacar el prefijo en config\personalizacion.ps1;
      # esta guarda lo tolera desde los dos lados.
      if ($HiveIsSoftware -and $rk -match '^SOFTWARE\\') {
        $rk = $rk -replace '^SOFTWARE\\', ''
        $normalizados += "$($it.Key)/$($r.v)"
      }
      $key = if ($rk) { "$root\$rk" } else { $root }
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
      # [uint32] y NO [int]. Historia: los colores ARGB con alpha FF pasan de 2^31
      # y un cast a Int32 tiraba overflow, asi que los valores fallaban EN SILENCIO.
      # Hoy los colores ya no pasan por aca (los lleva el .theme), pero el cast se
      # queda: cualquier DWORD con el bit alto prendido caeria en la misma trampa.
      $data = if ($r.t -eq 'sz') { "$($r.d)" } else { [string][uint32]$r.d }
      $out = & reg.exe add $key /v $r.v /t $type /d $data /f 2>&1
      if ($LASTEXITCODE -eq 0) { $ok++ } else { $fail += "$key\$($r.v)" }
    }
  }
  Write-Step "valores escritos: $ok  fallidos: $($fail.Count)" $(if ($fail) { 'Yellow' } else { 'Green' })
  if ($fail) { $fail | ForEach-Object { Write-Step "  no pude: $_" 'Yellow' } }
  if ($skipColor) {
    Write-Step ("descartados por ser color (los lleva el .theme): " + ($skipColor -join ', ')) 'DarkGray'
  }
  if ($normalizados) {
    Write-Step ("prefijo 'SOFTWARE\' de sobra en el catalogo, lo saque: " + ($normalizados -join ', ')) 'Yellow'
  }
}

# ---------------------------------------------------------------------------
# Dot-source = SOLO cargar las funciones. Sirve para testear la generacion del
# .theme sin montar una imagen (contrato seccion 7, test 5).
#   . .\10-personalizar.ps1      -> define funciones y sale
#   .\10-personalizar.ps1        -> corre la fase (asi la invoca el pipeline)
# InvocationName vale exactamente '.' solo cuando el script se dot-sourcea.
# ---------------------------------------------------------------------------
if ($MyInvocation.InvocationName -eq '.') { return }

# ===========================================================================
#  FASE
# ===========================================================================
$mount = $CFG.Mount
if (-not (Test-Path (Join-Path $mount 'Windows'))) {
  Write-Host "ERROR: no hay imagen montada en $mount" -ForegroundColor Red; exit 1
}

# Sin TUI: caer en los recomendados. Asi la fase sirve suelta, igual que las otras.
# La comparacion es contra $null y NO `-not $...`: un array vacio es "falsy" en
# PowerShell, asi que "el usuario no marco nada" seria indistinguible de "no hay
# perfil" y le aplicariamos los recomendados a alguien que los rechazo.
if ($null -eq $Global:PersonalizacionPicked) {
  $Global:PersonalizacionPicked = @($PersonalizacionCatalog | Where-Object { $_.Rec } | ForEach-Object { $_.Key })
  Write-Host "  (sin perfil: aplico los recomendados)" -ForegroundColor DarkGray
}

$picked = @($PersonalizacionCatalog | Where-Object { $PersonalizacionPicked -contains $_.Key })

Write-Host "== Fase 10: personalizacion ($($picked.Count) items) ==" -ForegroundColor Cyan

# --- Separar lo de usuario de lo de maquina: van a hives distintos ---
$userItems    = @($picked | Where-Object { -not $_.Machine })
$machineItems = @($picked | Where-Object { $_.Machine })

# ---------------------------------------------------------------------------
# QUE PIDIO EL USUARIO, en las tres dimensiones que van al .theme
# ---------------------------------------------------------------------------
$modo = Get-RequestedThemeMode $picked

# El acento se detecta por la PROPIEDAD Accent del item, no por un patron sobre
# la Key: 'acento-en-taskbar' empieza igual y NO es un color (es ColorPrevalence).
# Filtrar por nombre era una bomba esperando a la proxima key que empiece igual.
$accentItems = @($picked | Where-Object { $_.Accent })
$accent = $null
if ($accentItems.Count -gt 0) {
  if (-not (Get-Command ConvertTo-AccentDwords -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: lib.ps1 no expone ConvertTo-AccentDwords (contrato 1.3)." -ForegroundColor Red
    exit 1
  }
  # UNA sola funcion convierte colores en todo el repo. Escribir literales
  # 0x... a mano en cada archivo fue, textualmente, el bug que llego al usuario.
  $accent = ConvertTo-AccentDwords $accentItems[0].Accent
  if ($accentItems.Count -gt 1) {
    Write-Step ("varios acentos marcados, uso el primero: " + $accentItems[0].Key) 'Yellow'
  }
}
$themeColor = if ($accent) { $accent.ThemeColor } else { '' }

# El wallpaper: se busca el primer jpg/png de config\wallpaper.
# OJO con Get-ChildItem: -Include NO filtra si la ruta no termina en \* (o si no
# hay -Recurse). Devolvia siempre vacio y "no hay wallpaper" era mentira.
$wpDir = Join-Path $CFG.Root $WallpaperDir
$wp = if (Test-Path $wpDir) {
  Get-ChildItem (Join-Path $wpDir '*') -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -match '^\.(jpg|jpeg|png)$' } | Select-Object -First 1
} else { $null }
$wpName = if ($wp) { $wp.Name } else { '' }

# El menu contextual clasico vive en Software\Classes, que en HKCU NO esta en
# NTUSER.DAT sino en UsrClass.dat, un hive SEPARADO que no se puede tocar offline.
# Es lo UNICO que necesita reiniciar el shell. Se detecta por la RUTA que escribe
# el item (la clase del problema), no por su Key.
$necesitaShell = $false
foreach ($it in $userItems) {
  foreach ($r in $it.Regs) {
    if ($r -and "$($r.k)" -like 'Software\Classes\*') { $necesitaShell = $true }
  }
}

# Items que tienen algo REAL para reaplicar en el primer login (los de acento no
# tienen Regs: su color va al .theme). Si la lista queda vacia no se genera el
# script ni el RunOnce: dejar un script que solo escribe un log en la imagen es
# ruido que despues alguien tiene que salir a investigar.
$reaplicables = @($userItems | Where-Object {
  $tiene = $false
  foreach ($r in $_.Regs) { if ($r -and -not (Test-ColorValueName $r.v)) { $tiene = $true } }
  $tiene
})

$themeContent = New-LunaticOSTheme -Mode $modo -ThemeColor $themeColor -WallpaperName $wpName

# ---------------------------------------------------------------------------
if ($DryRun) {
  foreach ($it in $picked) {
    Write-Step "[dry] $($it.Name)" 'DarkGray'
    if ($it.Accent) { Write-Step "        acento $($it.Accent) -> va al .theme" 'DarkGray' }
    foreach ($r in $it.Regs) {
      if (-not $r) { continue }
      if (Test-ColorValueName $r.v) { Write-Step "        (descartado, color) $($r.v)" 'DarkGray'; continue }
      Write-Step "        $($r.k)\$($r.v) = $($r.d)" 'DarkGray'
    }
  }
  Write-Host ""
  Write-Step "[dry] tema=$(if($modo){$modo}else{'(sin eleccion)'})  acento=$(if($themeColor){$themeColor}else{'(ninguno)'})  wallpaper=$(if($wpName){$wpName}else{'(ninguno)'})" 'DarkGray'
  if ($themeContent) {
    Write-Step "[dry] $ThemeInstalledPath :" 'DarkGray'
    $themeContent -split "`r`n" | ForEach-Object { Write-Host "        $_" -ForegroundColor DarkGray }
    Write-Step "[dry] InstallTheme / InstallThemeLight -> $ThemeInstalledPath (las 2 ramas)" 'DarkGray'
  } else {
    Write-Step "[dry] sin tema, sin acento y sin wallpaper: NO se genera el .theme ni se toca InstallTheme" 'DarkGray'
  }
  Write-Step "[dry] shell restart en el primer login: $necesitaShell" 'DarkGray'
  return
}

# OJO: aca NO hay un "if (-not $picked) { return }" y es a proposito. La limpieza
# defensiva de policies (paso 5) NO depende de lo que el usuario marque: es la
# garantia del proyecto (contrato 5.2). Y el wallpaper tampoco es un item del
# catalogo: es un archivo que el usuario dejo en config\wallpaper, o sea que ya
# dijo que lo quiere. Con cero items marcados, los pasos que escriben items no
# escriben nada (cada bloque se guarda solo) y estos dos siguen corriendo.

# ---------------------------------------------------------------------------
# 1) WALLPAPER: copiar el archivo DENTRO de la imagen
#    Si lo dejaramos apuntando a una ruta del host, el fondo aparece negro en la
#    maquina instalada y nadie entiende por que.
#    El .theme lo declara; el hive DEFAULT lo escribe igual como FALLBACK.
#    Por que el fallback: que 25H2 respete InstallTheme esta sin verificar en VM
#    (contrato 2.5). Si no lo respetara, el wallpaper igual aparece. No hay
#    conflicto posible: no es un color y el .theme gana si se aplica.
# ---------------------------------------------------------------------------
if ($wp) {
  $destDir = Join-Path $mount $WallpaperDirInImage
  New-Item -ItemType Directory -Force -Path $destDir | Out-Null
  Copy-Item $wp.FullName (Join-Path $destDir $wp.Name) -Force
  $inImage = "C:\$WallpaperDirInImage\$($wp.Name)"
  Write-Step "wallpaper: $($wp.Name) -> $inImage" 'Green'
} else {
  Write-Step "sin wallpaper propio (pone un .jpg/.png en $WallpaperDir si queres uno)" 'DarkGray'
}

# ---------------------------------------------------------------------------
# 2) EL .theme
# ---------------------------------------------------------------------------
if ($themeContent) {
  $themeDir  = Join-Path $mount $ThemeDirInImage
  New-Item -ItemType Directory -Force -Path $themeDir | Out-Null
  $themePath = Join-Path $themeDir $ThemeFileName
  # ASCII PURO Y SIN BOM. Los .theme del sistema son ANSI y el parser de temas se
  # come el BOM como parte de la primera linea: con BOM, la seccion [Theme] no se
  # reconoce y el tema entero se ignora sin decir nada.
  [System.IO.File]::WriteAllText($themePath, $themeContent, [System.Text.Encoding]::ASCII)
  Write-Step "generado $ThemeDirInImage\$ThemeFileName (tema=$(if($modo){$modo}else{'Light'}) acento=$(if($themeColor){$themeColor}else{'default'}))" 'Green'
} else {
  Write-Step "sin tema/acento/wallpaper: no se genera el .theme (la imagen queda de fabrica)" 'DarkGray'
}

# ---------------------------------------------------------------------------
# 3) Hive de usuario (DEFAULT) + limpieza defensiva + RunOnce
# ---------------------------------------------------------------------------
$script:limpiezaUser = @()
Use-OfflineHive -HivePath (Join-Path $mount 'Users\Default\NTUSER.DAT') -MountKey 'OFF_PERS' -Action {
  param($root)
  if ($userItems) { Write-Regs $root $userItems }

  # Wallpaper como fallback del .theme (ver el comentario del paso 1).
  if ($wp) {
    Invoke-Reg add "$root\Control Panel\Desktop" /v WallPaper      /t REG_SZ /d $inImage /f
    Invoke-Reg add "$root\Control Panel\Desktop" /v WallpaperStyle /t REG_SZ /d 10 /f   # 10 = Rellenar
    Invoke-Reg add "$root\Control Panel\Desktop" /v TileWallpaper  /t REG_SZ /d 0 /f
  }

  $script:limpiezaUser = Remove-PersonalizationBlockers $root 'DEFAULT'
}
foreach ($it in $userItems) {
  if ($it.Accent) { Write-Step "aplicado: $($it.Name) (via .theme)" 'Green' }
  else { Write-Step "aplicado: $($it.Name)" 'Green' }
}

# ---------------------------------------------------------------------------
# 4) Hive de maquina (SOFTWARE): items de maquina + InstallTheme + limpieza
#    Todo en UNA carga del hive: cada Use-OfflineHive es un load/unload con
#    reintentos, y un hive que no se descarga revienta el commit del WIM.
# ---------------------------------------------------------------------------
$script:limpiezaMachine = @()
Use-OfflineHive -HivePath (Join-Path $mount 'Windows\System32\config\SOFTWARE') -MountKey 'OFF_PERS_M' -Action {
  param($root)
  if ($machineItems) { Write-Regs $root $machineItems -HiveIsSoftware }

  # ESTE es el arreglo del bug del tema y del acento. Las DOS ramas: la de 64
  # bits y la de WOW6432Node. En una maquina real las dos apuntan a aero.theme,
  # asi que dejar una sin tocar es dejar la puerta por la que vuelve el azul.
  if ($themeContent) {
    foreach ($branch in @('Microsoft\Windows\CurrentVersion\Themes',
                          'WOW6432Node\Microsoft\Windows\CurrentVersion\Themes')) {
      # InstallThemeLight tambien apunta a nuestro tema: el .theme ya trae el
      # SystemMode/AppMode que el usuario pidio. A MEDIR EN VM (contrato 2.5):
      # si 25H2 usara InstallThemeLight para forzar claro, aca habria que
      # generar un segundo .theme en Light.
      Invoke-Reg add "$root\$branch" /v InstallTheme      /t REG_SZ /d $ThemeInstalledPath /f
      Invoke-Reg add "$root\$branch" /v InstallThemeLight /t REG_SZ /d $ThemeInstalledPath /f
    }
  }

  $script:limpiezaMachine = Remove-PersonalizationBlockers $root 'SOFTWARE'
}
foreach ($it in $machineItems) { Write-Step "aplicado (maquina): $($it.Name)" 'Green' }
if ($themeContent) {
  Write-Step "InstallTheme + InstallThemeLight -> $ThemeInstalledPath (Themes y WOW6432Node)" 'Green'
}

# ---------------------------------------------------------------------------
# 5) Reporte de la limpieza defensiva
# ---------------------------------------------------------------------------
$limpiadas = @($script:limpiezaMachine) + @($script:limpiezaUser)
if ($limpiadas.Count -gt 0) {
  Write-Step "policies que bloqueaban Personalization: BORRADAS ($($limpiadas.Count))" 'Yellow'
  $limpiadas | ForEach-Object { Write-Step "  borrado: $_" 'Yellow' }
} else {
  Write-Step "policies que bloquean Personalization: nada que borrar" 'Green'
}

# ===========================================================================
#  6) RED DE SEGURIDAD: reaplicar en el primer login
# ===========================================================================
#  El .theme se encarga del tema, del color y del wallpaper. Lo que queda para
#  el primer login es lo que un .theme NO puede llevar:
#
#    a) El menu contextual clasico. Vive en Software\Classes, que en HKCU NO
#       esta en NTUSER.DAT sino en UsrClass.dat, un hive SEPARADO que no existe
#       hasta que el perfil se crea. Escribirlo offline no hace absolutamente
#       nada. No hay alternativa: o RunOnce, o no hay menu clasico.
#
#    b) Reaplicar Explorer\Advanced, Control Panel\Desktop, EnableTransparency y
#       ColorPrevalence. Esos SI sobrevivieron la instalacion medida, asi que es
#       redundancia barata, no un parche.
#
#  Y NO reaplica NI UN valor de color ni el tema: el .theme es la unica fuente
#  de verdad (contrato 2.4). Si medimos en la VM que 25H2 ignora InstallTheme,
#  el plan B es que este script aplique el .theme con el motor de temas -- pero
#  entonces el .theme deja de escribirse y sigue habiendo UNA sola fuente.
# ===========================================================================
$scriptsDir = Join-Path $mount 'Windows\Setup\Scripts'
New-Item -ItemType Directory -Force -Path $scriptsDir | Out-Null

$sb = New-Object System.Text.StringBuilder
function Add-L($t) { [void]$sb.AppendLine($t) }

Add-L @'
# LunaticOS - reaplica la personalizacion de USUARIO en el primer login.
#
# QUE HACE:  Explorer\Advanced, Control Panel\Desktop, EnableTransparency,
#            ColorPrevalence y el menu contextual clasico (Software\Classes,
#            que vive en UsrClass.dat y no se puede escribir offline).
# QUE NO:    ningun valor de color y ningun cambio de tema. De eso se encarga
#            C:\Windows\Resources\Themes\LunaticOS.theme, que Windows aplica al
#            crear el perfil porque InstallTheme apunta ahi. Dos fuentes para el
#            color = el acento desalineado que vio el usuario.
#
# NO SE AUTOBORRA A PROPOSITO: el RunOnce que lo dispara vive en el hive DEFAULT,
# asi que CADA usuario nuevo hereda su propia entrada. Si el script se borrara
# despues del primer login, el segundo usuario fallaria en silencio.
$ErrorActionPreference = "Continue"
$log = "$env:ProgramData\LunaticOS\personalizar.log"
New-Item -ItemType Directory -Force -Path (Split-Path $log) | Out-Null
function L($m) { $s = "{0}  {1}" -f (Get-Date -Format "HH:mm:ss"), $m; Write-Host $s; Add-Content -Path $log -Value $s }
L "=== reaplicando personalizacion de usuario ($env:USERNAME) ==="
'@
Add-L ''

foreach ($it in $userItems) {
  $lineas = @()
  foreach ($r in $it.Regs) {
    if (-not $r) { continue }
    # Misma guarda que en el hive: ningun color, aunque el catalogo vuelva a traerlos.
    if (Test-ColorValueName $r.v) { continue }
    $key = if ($r.k) { "HKCU:\$($r.k)" } else { 'HKCU:' }
    $lineas += ("New-Item -Path '{0}' -Force -ErrorAction SilentlyContinue | Out-Null" -f $key)
    if ([string]::IsNullOrEmpty($r.v)) {
      # Valor "(Default)" vacio: en runtime se escribe con el nombre '(default)'
      $lineas += ("Set-ItemProperty -Path '{0}' -Name '(default)' -Value '' -ErrorAction SilentlyContinue" -f $key)
    } elseif ($r.t -eq 'sz') {
      $lineas += ("Set-ItemProperty -Path '{0}' -Name '{1}' -Value '{2}' -Type String -ErrorAction SilentlyContinue" -f $key, $r.v, $r.d)
    } else {
      # [uint32] y NO [int], igual que en Write-Regs: un DWORD con el bit alto
      # prendido pasa de 2^31 y un cast a Int32 tira "Value was either too large
      # or too small". Este era el SEGUNDO [int] del archivo: arregle uno y deje
      # el otro, y el test no lo agarro porque buscaba la firma exacta del primero.
      $lineas += ("Set-ItemProperty -Path '{0}' -Name '{1}' -Value {2} -Type DWord -ErrorAction SilentlyContinue" -f $key, $r.v, [uint32]$r.d)
    }
  }
  if (-not $lineas) { continue }
  Add-L ("# --- {0} ---" -f $it.Name)
  $lineas | ForEach-Object { Add-L $_ }
  Add-L ("L 'aplicado: {0}'" -f ($it.Name -replace "'", "''"))
  Add-L ''
}

# ---------------------------------------------------------------------------
# Refresco de la UI: BROADCAST, no matar procesos (contrato 4.1).
#
# Lo que habia antes era `Stop-Process -Name explorer -Force` + Start-Sleep 3 +
# un `if`. Eso es el issue #329 de cschneegans/unattend-generator: en el PRIMER
# login el shell NO respawnea solo, y el usuario se queda con un escritorio gris
# sin taskbar. No es un riesgo teorico, era una bomba activa en cada ISO.
#
# El broadcast WM_SETTINGCHANGE/"ImmersiveColorSet" es lo que usa AutoDarkMode
# (DwmRefreshHandler.Broadcast) y alcanza para tema, colores y la mayoria de los
# tweaks. No mata nada.
# ---------------------------------------------------------------------------
Add-L @'
# --- Refresco sin matar nada: broadcast WM_SETTINGCHANGE ---
try {
  Add-Type -Namespace Win32 -Name Native -MemberDefinition @"
[DllImport("user32.dll", CharSet=CharSet.Auto, SetLastError=true)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam,
  string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
"@
  [UIntPtr]$res = [UIntPtr]::Zero
  # HWND_BROADCAST=0xFFFF  WM_SETTINGCHANGE=0x1A  SMTO_ABORTIFHUNG=0x2
  [Win32.Native]::SendMessageTimeout([IntPtr]0xFFFF, 0x1A, [UIntPtr]::Zero,
    "ImmersiveColorSet", 0x2, 3000, [ref]$res) | Out-Null
  L "broadcast ImmersiveColorSet enviado"
} catch { L ("broadcast fallo (no es grave, se ve al cerrar sesion): " + $_.Exception.Message) }
'@
Add-L ''

if ($necesitaShell) {
  # ---------------------------------------------------------------------------
  # El menu contextual clasico es lo UNICO que necesita reinicio del shell: el
  # handler del menu se resuelve una sola vez al arrancar Explorer.
  # Si se reinicia, es OBLIGATORIO el bucle de verificacion (contrato 4.2):
  # un Start-Sleep seguido de un `if` es una carrera, no una garantia.
  # ---------------------------------------------------------------------------
  Add-L @'
# --- Menu contextual clasico: unico caso que pide reiniciar el shell ---
$habia = [bool](Get-Process explorer -ErrorAction SilentlyContinue)
if ($habia) {
  L "reiniciando Explorer (menu contextual clasico)..."
  Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
  # Bucle de verificacion: se relanza hasta CONFIRMAR que el shell volvio. En el
  # primer login el shell no respawnea solo (issue #329) y sin esto el usuario
  # se queda con un escritorio gris sin taskbar.
  for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 500
    if (Get-Process explorer -ErrorAction SilentlyContinue) { break }
    Start-Process explorer.exe -ErrorAction SilentlyContinue
  }
  if (Get-Process explorer -ErrorAction SilentlyContinue) { L "Explorer arriba" }
  else { L "! Explorer NO volvio: Ctrl+Shift+Esc > Ejecutar nueva tarea > explorer.exe" }
} else {
  L "no habia Explorer corriendo: no reinicio nada"
}
'@
  Add-L ''
}

Add-L 'L "=== listo ==="'

# ===========================================================================
#  7) El script y su RunOnce EN EL HIVE DE USUARIO (DEFAULT), no en HKLM
# ===========================================================================
#  Antes iba en HKLM\...\RunOnce, que lo consume EL PRIMER usuario que loguea y
#  desaparece: el segundo usuario del equipo se queda sin menu clasico y sin los
#  tweaks de Explorer. En el hive DEFAULT, cada perfil nuevo hereda su propia
#  entrada y corre una vez para cada uno. Es lo que hace unattend-generator
#  (modifier/UserOnce.cs).
#
#  El prefijo 'AA' SE CONSERVA: RunOnce corre sus entradas en orden alfabetico y
#  secuencial, y esto tiene que ir antes del instalador de programas ('ZZ', 20+
#  minutos). OJO, A MEDIR EN VM: el orden alfabetico solo ordena DENTRO de una
#  misma clave, y el instalador de apps (fase 11) vive en el RunOnce de HKLM.
#  Entre claves distintas el orden lo decide el shell. Ya no es critico igual:
#  el tema y el color ahora los aplica Windows al crear el perfil (InstallTheme),
#  asi que el escritorio se ve bien desde el primer frame incluso si esto corre
#  al final.
# ===========================================================================
if ($reaplicables.Count -eq 0) {
  Write-Step "nada de usuario que reaplicar: no genero el script ni el RunOnce" 'DarkGray'
} else {
  # ASCII PURO en el script generado: corre sobre conhost con codepage 850/437 y
  # cualquier acento se convierte en basura en pantalla y en el log.
  $runOncePath = Join-Path $scriptsDir $RunOnceScriptName
  [System.IO.File]::WriteAllText($runOncePath, $sb.ToString(), [System.Text.Encoding]::ASCII)
  Write-Step "generado $RunOnceScriptName (reaplica lo de usuario; shell restart: $necesitaShell)" 'Green'

  Use-OfflineHive -HivePath (Join-Path $mount 'Users\Default\NTUSER.DAT') -MountKey 'OFF_PERS_RO' -Action {
    param($root)
    # Las comillas van ESCAPADAS con \" a proposito. Medido: pasando comillas
    # normales, PowerShell las consume al armar la linea de comandos nativa y el
    # valor termina guardado como  -File C:\Windows\... SIN comillas. Hoy funciona
    # de casualidad porque la ruta no tiene espacios; el dia que las tenga, el
    # RunOnce falla en silencio en el primer login. Con \" el valor queda con
    # comillas de verdad en el registro (verificado con reg query).
    $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"' + $RunOnceScriptPath + '\"'
    Invoke-Reg add "$root\Software\Microsoft\Windows\CurrentVersion\RunOnce" /v AALunaticOSPersonalizar /t REG_SZ /d $cmd /f
  }
  Write-Step "RunOnce AALunaticOSPersonalizar en el hive DEFAULT (corre para cada usuario nuevo)" 'Green'
}

Write-Host ""
if ($themeContent) {
  Write-Host "Personalizacion: tema/color/wallpaper por LunaticOS.theme (InstallTheme) + tweaks en el hive DEFAULT." -ForegroundColor Green
} elseif ($picked.Count -gt 0) {
  Write-Host "Personalizacion: tweaks en el hive DEFAULT (no habia tema, acento ni wallpaper que declarar)." -ForegroundColor Green
} else {
  Write-Host "Personalizacion: nada marcado. Solo corri la limpieza de las policies que bloquean Settings." -ForegroundColor Green
}
Write-Host "Todo como DEFAULT o como TEMA, nunca como policy: el usuario cambia lo que quiera desde Settings." -ForegroundColor DarkGray
