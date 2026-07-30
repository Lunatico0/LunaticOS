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
  LA CAUSA RAIZ, EN DOS PARTES. LAS DOS MEDIDAS, NINGUNA SUPUESTA.
  ---------------------------------------------------------------------------
  PARTE 1 -- SON TRES RAMAS, NO DOS: InstallThemeDark era el bug.

  Al crear el perfil de usuario, Windows APLICA UN TEMA. Cual, lo dicen estas
  claves de maquina -- y son TRES valores, no dos:

    HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes
      InstallTheme      = C:\Windows\resources\Themes\aero.theme
      InstallThemeDark  = C:\Windows\resources\Themes\dark.theme   <-- ESTA
      InstallThemeLight = C:\Windows\resources\Themes\aero.theme
    HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Themes  (idem)

  Los tres los pone Windows desde el manifest del componente
  microsoft-windows-themeui-client. Nosotros escribiamos DOS: InstallTheme e
  InstallThemeLight. Como el hive DEFAULT ya traia AppsUseLightTheme=0 y
  SystemUsesLightTheme=0, Windows tomo la rama DARK y aplico el dark.theme DE
  FABRICA, que trae ColorizationColor=0XC40078D4 (el azul conocido) y
  Wallpaper=img19.jpg.

  MEDIDO en el build del 2026-07-29 20:32 (VM instalada): el tema salio oscuro
  pero con el acento AZUL, y parecia que nuestro LunaticOS.theme se ignoraba.
  NO se ignoraba: SE APLICO OTRO. De ahi salia el azul.
  -> Hay que escribir las TRES en las DOS ramas = 6 valores (contrato 2.5).

  PARTE 2 -- escribir valores NO APLICA NADA.

  Quien traduce registro -> colores reales es el MOTOR DE TEMAS, y ese solo
  corre cuando se APLICA un tema. Staff de NTLite lo confirma en dos hilos: el
  aprovisionamiento del usuario nuevo (corre justo antes del primer logon)
  ignora o pisa las settings HKCU de escritorio que dejaste en el NTUSER.DAT
  del perfil Default. Por eso el modo oscuro quedaba ESCRITO pero la UI se veia
  clara hasta que el usuario forzaba un ciclo de apply a mano.

  Entonces el primer login APLICA el tema con IThemeManager2::AddAndSelectTheme
  (contrato 2.6). MEDIDO en una maquina real: hr=0x00000000, 856 ms, NO abre
  Settings, y de UNA sola llamada dejo escritos AccentColor, ColorizationColor,
  ColorizationAfterglow, AccentColorMenu, StartColorMenu, AccentPalette y
  CurrentTheme.

  ---------------------------------------------------------------------------
  DOS CAPAS COHERENTES, NO DOS FUENTES EN CONFLICTO
  ---------------------------------------------------------------------------
  El color va en el .theme Y en el hive DEFAULT. Eso NO es volver al bug viejo.

  El bug viejo era que config\personalizacion.ps1 tenia los DWORD de color
  escritos A MANO, todos en ARGB, cuando AccentColor es ABGR: el teal #14B8A6
  se veia verde lima en la taskbar y teal en otras partes de la UI AL MISMO
  TIEMPO. El problema no era "escribir dos veces", era "escribir dos veces
  distinto".

  Ahora las dos capas derivan del MISMO hex por el MISMO helper
  (ConvertTo-AccentDwords, en lib.ps1), asi que no pueden desalinearse, y hacen
  falta las dos:
    - el .theme para que el motor de temas derive la paleta de 8 tonos;
    - el hive DEFAULT para que el color exista desde el primer frame y para no
      quedar en el azul de fabrica si el apply del primer login fallara.
  Si alguien "limpia" una de las dos por parecer redundante, vuelve el bug.
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
# ---------------------------------------------------------------------------
# DECISION: el archivo se llama SIEMPRE LunaticOS.theme. Lo que cambia en cada
# build es el ThemeId (un GUID nuevo), no el nombre.
#
# Por que no un nombre por build (tipo LunaticOS-a1b2c3d4.theme):
#   - El no-op silencioso de Windows (contrato 2.6) compara el CONTENIDO del
#     tema, no su nombre: con un ThemeId nuevo el contenido ya es distinto, asi
#     que el nombre no aporta nada mas.
#   - InstallTheme* tiene que apuntar al nombre REAL. Un nombre variable es una
#     fuente de desincronizacion gratis entre el archivo y las 6 claves.
#   - Un nombre nuevo por build va dejando LunaticOS-*.theme viejos en
#     Resources\Themes (la fase puede correr varias veces sobre la misma imagen
#     montada), y limpiarlos es codigo que puede borrar lo que no debe.
#   - Con nombre fijo, la lista de temas de Settings queda con UNA entrada
#     "LunaticOS", que es lo que el usuario espera ver.
# El riesgo que el nombre por build pretendia cubrir (que el apply no-opee) se
# cubre de verdad VERIFICANDO el registro despues del apply y reintentando con
# un ThemeId nuevo generado en runtime. Ver el paso 6.
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
# Nombres de valor que SON color. El filtro se aplica SOLO a los Regs que vienen
# del CATALOGO (config\personalizacion.ps1), no a lo que escribe esta fase.
#
# La distincion es todo el punto: esta fase SI escribe los colores, pero los
# deriva de ConvertTo-AccentDwords, con el formato de bytes correcto para cada
# valor (ABGR o ARGB segun la tabla del contrato 1). Un DWORD de color escrito a
# mano en el catalogo seria otra vez lo que causo el bug: un segundo valor, sin
# verificar, casi siempre en el formato equivocado.
#
# O sea: es una red de seguridad contra el catalogo, no contra nosotros. Los
# items de acento hoy declaran el color en la propiedad Accent (hex) y no traen
# Regs, asi que en condiciones normales este filtro no descarta nada -- y por eso
# mismo se queda: el dia que alguien "agregue el acento tambien como Regs para
# que ande seguro", este filtro es lo que evita la desalineacion.
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
#
# $ThemeId: GUID NUEVO EN CADA BUILD, y no es cosmetico. TRAMPA CRITICA medida
# (contrato 2.6): si el .theme que se aplica es "el mismo" que el actual, Windows
# NO HACE NADA y devuelve hr=0. Un codigo de retorno que miente es lo peor que
# nos puede pasar: los dos builds fallidos se veian igual de exitosos en el log.
# Con un ThemeId distinto, el contenido del archivo nunca es identico al del tema
# vigente y el apply no puede no-opear. Es la misma clase de workaround que tiene
# AutoDarkMode (ThemeFile.PatchColorsWin11InMemory nudgea +-1 un canal de color).
# ---------------------------------------------------------------------------
function New-LunaticOSTheme {
  param(
    [ValidateSet('', 'Dark', 'Light')][string]$Mode = '',
    [string]$ThemeColor = '',
    [string]$WallpaperName = '',
    [guid]$ThemeId = [guid]::NewGuid()
  )

  if (-not $Mode -and -not $ThemeColor -and -not $WallpaperName) { return $null }

  # Sin eleccion explicita, Light: es el default de Windows y evita que "solo
  # acento" fuerce un modo que el usuario no pidio.
  $modo = if ($Mode -eq 'Dark') { 'Dark' } else { 'Light' }

  $out = New-Object System.Collections.Generic.List[string]
  $out.Add('; LunaticOS')
  $out.Add('[Theme]')
  $out.Add('DisplayName=LunaticOS')
  # ToString('B') = con llaves, tal como lo escriben los .theme de Windows.
  $out.Add('ThemeId=' + $ThemeId.ToString('B').ToUpperInvariant())
  # SetLogonBackground=0: el tema no toca el fondo de la pantalla de login.
  # Forzarlo es justo lo que hace PersonalizationCSP, que deja al usuario sin
  # poder cambiar el lockscreen (contrato 5.1). No vamos por ahi.
  $out.Add('SetLogonBackground=0')
  $out.Add('')

  # =========================================================================
  #  LA SECCION [Control Panel\Desktop] CON UNA LINEA Wallpaper= ES OBLIGATORIA.
  #  NO LA SAQUES AUNQUE NO HAYA WALLPAPER PROPIO.
  #
  #  MEDIDO en Win11 22631 con AddAndSelectTheme, bisecando el archivo linea por
  #  linea:
  #      sin seccion [Control Panel\Desktop]   -> hr=0x80004005  E_FAIL
  #      seccion presente pero vacia           -> hr=0x80004005  E_FAIL
  #      seccion con solo Pattern=             -> hr=0x80004005  E_FAIL
  #      seccion con Wallpaper= (VACIO)        -> hr=0x00000000  OK
  #      seccion con Wallpaper=<no existe>     -> hr=0x00000000  OK
  #      seccion con Wallpaper=img19.jpg       -> hr=0x00000000  OK
  #  O sea: alcanza con que la CLAVE Wallpaper exista. Ni el archivo tiene que
  #  existir. Pero sin esa clave, el motor de temas RECHAZA el .theme entero y no
  #  aplica NI el modo NI el color. La version anterior omitia la seccion completa
  #  cuando no habia wallpaper propio -- que es el caso por defecto del proyecto --
  #  asi que el tema era invalido justo en la configuracion mas comun.
  #
  #  Y no se pone Wallpaper= vacio: cuando Windows aplica el tema al crear el
  #  perfil lo hace SIN nuestros flags, o sea que tambien aplica el fondo, y un
  #  valor vacio deja el escritorio en negro. Se pone el wallpaper DE FABRICA que
  #  corresponde al modo, exactamente el mismo que declaran aero.theme (img0.jpg,
  #  claro) y dark.theme (img19.jpg, oscuro). Resultado: si el usuario no trajo
  #  fondo propio, ve el de Windows -- que es lo que esperaria.
  # =========================================================================
  $wall = if ($WallpaperName) { "%SystemRoot%\Web\Wallpaper\LunaticOS\$WallpaperName" }
          elseif ($modo -eq 'Dark') { '%SystemRoot%\web\wallpaper\Windows\img19.jpg' }
          else { '%SystemRoot%\web\wallpaper\Windows\img0.jpg' }
  $out.Add('[Control Panel\Desktop]')
  $out.Add("Wallpaper=$wall")
  $out.Add('TileWallpaper=0')
  $out.Add('WallpaperStyle=10')   # 10 = Rellenar
  $out.Add('Pattern=')
  $out.Add('')

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
# tienen Regs: su color lo lleva el .theme y lo escribe esta fase en el hive).
$reaplicables = @($userItems | Where-Object {
  $tiene = $false
  foreach ($r in $_.Regs) { if ($r -and -not (Test-ColorValueName $r.v)) { $tiene = $true } }
  $tiene
})

# ---------------------------------------------------------------------------
# El GUID del tema: UNO por build. Se genera aca, una sola vez, y viaja al
# .theme. Ver el comentario de New-LunaticOSTheme: sin esto, un segundo apply
# del "mismo" tema es un no-op silencioso con hr=0.
# ---------------------------------------------------------------------------
$themeId      = [guid]::NewGuid()
$themeContent = New-LunaticOSTheme -Mode $modo -ThemeColor $themeColor -WallpaperName $wpName -ThemeId $themeId

# Los DWORD del acento, ya en DECIMAL y como string, listos para reg.exe.
# En decimal a proposito: en este repo no se escribe NI UN literal hexadecimal de
# color. Los dos valores salen del MISMO helper, uno en ABGR y otro en ARGB
# (contrato 1): esa asimetria es justo lo que el bug viejo ignoraba.
$accentAbgrStr = ''
$accentArgbStr = ''
if ($accent) {
  $accentAbgrStr = [string][uint32]$accent.Abgr
  $accentArgbStr = [string][uint32]$accent.Argb
}

# El script del primer login se genera si hay algo de usuario que reaplicar O si
# hay un tema que aplicar. Lo segundo es nuevo y NO es un detalle: con "solo
# acento" marcado no hay ni un Reg de usuario, y con la condicion vieja no se
# generaba script, o sea que el tema no se aplicaba NUNCA en el primer login.
$generarScript = ($reaplicables.Count -gt 0) -or [bool]$themeContent

# ---------------------------------------------------------------------------
if ($DryRun) {
  foreach ($it in $picked) {
    Write-Step "[dry] $($it.Name)" 'DarkGray'
    if ($it.Accent) { Write-Step "        acento $($it.Accent) -> .theme + hive DEFAULT (mismo helper)" 'DarkGray' }
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
    Write-Step "[dry] InstallTheme / InstallThemeDark / InstallThemeLight -> $ThemeInstalledPath (las 2 ramas = 6 valores)" 'DarkGray'
    Write-Step "[dry] primer login: AddAndSelectTheme sobre ese .theme (STA) + verificacion en el registro" 'DarkGray'
  } else {
    Write-Step "[dry] sin tema, sin acento y sin wallpaper: NO se genera el .theme ni se toca InstallTheme" 'DarkGray'
  }
  if ($accentAbgrStr) {
    Write-Step "[dry] hive DEFAULT: AccentColor/AccentColorInactive/AccentColorMenu/StartColorMenu=$accentAbgrStr (ABGR)  ColorizationColor/Afterglow=$accentArgbStr (ARGB)" 'DarkGray'
    Write-Step "[dry] primer login: AccentPalette idx3 = R=$($accent.R) G=$($accent.G) B=$($accent.B) (solo ese indice)" 'DarkGray'
  }
  Write-Step "[dry] script del primer login: $generarScript  (shell restart: $necesitaShell)" 'DarkGray'
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
  Write-Step "ThemeId=$($themeId.ToString('B').ToUpperInvariant()) (nuevo en cada build: sin esto el apply puede no-opear con hr=0)" 'DarkGray'
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

  # -------------------------------------------------------------------------
  # EL COLOR, TAMBIEN EN EL HIVE. Y NO es la duplicacion que causo el bug.
  #
  # Historia corta: se habian sacado estos valores apostando a que el .theme los
  # aplicaria solo. No alcanza -- escribir un .theme no aplica nada, y si el
  # apply del primer login fallara, el usuario arranca con el azul de fabrica.
  #
  # Por que ahora si es seguro: el bug viejo era que el catalogo traia estos
  # DWORD escritos a mano, TODOS en ARGB, cuando AccentColor es ABGR. Aca los dos
  # formatos salen del MISMO hex por el MISMO helper, con la tabla del contrato 1:
  #     ABGR (0xFFBBGGRR) -> AccentColor, AccentColorInactive,
  #                          Explorer\Accent\AccentColorMenu, StartColorMenu
  #     ARGB (0xC4RRGGBB) -> DWM\ColorizationColor, ColorizationAfterglow
  # Es imposible que las dos capas se desalineen: derivan del mismo dato.
  #
  # AccentPalette NO se escribe aca: son 8 tonos y no hay formula publicada para
  # derivarlos. El motor de temas la genera bien cuando aplica el tema, y el
  # script del primer login solo corrige el indice 3 (contrato 2.8).
  # -------------------------------------------------------------------------
  if ($accentAbgrStr) {
    $keyDwm    = "$root\Software\Microsoft\Windows\DWM"
    $keyAccent = "$root\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent"
    Invoke-Reg add $keyDwm    /v AccentColor           /t REG_DWORD /d $accentAbgrStr /f
    Invoke-Reg add $keyDwm    /v AccentColorInactive   /t REG_DWORD /d $accentAbgrStr /f
    Invoke-Reg add $keyDwm    /v ColorizationColor     /t REG_DWORD /d $accentArgbStr /f
    Invoke-Reg add $keyDwm    /v ColorizationAfterglow /t REG_DWORD /d $accentArgbStr /f
    Invoke-Reg add $keyAccent /v AccentColorMenu       /t REG_DWORD /d $accentAbgrStr /f
    Invoke-Reg add $keyAccent /v StartColorMenu        /t REG_DWORD /d $accentAbgrStr /f
  }

  $script:limpiezaUser = Remove-PersonalizationBlockers $root 'DEFAULT'
}
foreach ($it in $userItems) {
  if ($it.Accent) { Write-Step "aplicado: $($it.Name) (.theme + hive DEFAULT)" 'Green' }
  else { Write-Step "aplicado: $($it.Name)" 'Green' }
}
if ($accentAbgrStr) {
  Write-Step "color en el hive DEFAULT: ABGR=$accentAbgrStr (AccentColor, Inactive, Menu, Start) ARGB=$accentArgbStr (Colorization, Afterglow)" 'Green'
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

  # =========================================================================
  #  ESTE ERA EL BUG. SON TRES VALORES, NO DOS.
  #
  #    InstallTheme       rama generica
  #    InstallThemeDark   <-- FALTABA. Es la que Windows uso, y de fabrica
  #                           apunta a dark.theme (ColorizationColor=0XC40078D4,
  #                           el azul, y Wallpaper=img19.jpg).
  #    InstallThemeLight
  #
  #  MEDIDO en la VM del build 2026-07-29 20:32: el hive DEFAULT ya traia
  #  AppsUseLightTheme=0, Windows eligio la rama DARK, aplico el dark.theme DE
  #  FABRICA y de ahi salio el acento azul. Nuestro .theme no se ignoro: se
  #  aplico OTRO.
  #
  #  NO BORRES NINGUNA DE LAS TRES POR PARECER REDUNDANTE. Apuntan al mismo
  #  archivo a proposito: nuestro .theme ya declara el SystemMode/AppMode que el
  #  usuario pidio, asi que por cualquier rama que Windows entre, entra al tema
  #  correcto. La que falte es la puerta por la que vuelve el azul, y falla en
  #  SILENCIO: el registro queda "bien" y la UI sale de otro color.
  #
  #  Y las DOS ramas del hive (64 bits y WOW6432Node): en una maquina real las
  #  dos existen y las dos apuntan a aero.theme/dark.theme. 3 x 2 = 6 valores.
  # =========================================================================
  if ($themeContent) {
    foreach ($branch in @('Microsoft\Windows\CurrentVersion\Themes',
                          'WOW6432Node\Microsoft\Windows\CurrentVersion\Themes')) {
      Invoke-Reg add "$root\$branch" /v InstallTheme      /t REG_SZ /d $ThemeInstalledPath /f
      Invoke-Reg add "$root\$branch" /v InstallThemeDark  /t REG_SZ /d $ThemeInstalledPath /f
      Invoke-Reg add "$root\$branch" /v InstallThemeLight /t REG_SZ /d $ThemeInstalledPath /f
    }
  }

  $script:limpiezaMachine = Remove-PersonalizationBlockers $root 'SOFTWARE'
}
foreach ($it in $machineItems) { Write-Step "aplicado (maquina): $($it.Name)" 'Green' }
if ($themeContent) {
  Write-Step "InstallTheme + InstallThemeDark + InstallThemeLight -> $ThemeInstalledPath (Themes y WOW6432Node = 6 valores)" 'Green'
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
#  6) EL SCRIPT DEL PRIMER LOGIN
# ===========================================================================
#  Ya NO es solo una red de seguridad: es donde el tema se APLICA de verdad.
#
#    a) APLICAR EL TEMA con IThemeManager2::AddAndSelectTheme (contrato 2.6).
#       InstallTheme* es necesario pero NO suficiente: escribir valores no aplica
#       nada, y el aprovisionamiento del usuario nuevo pisa las settings HKCU de
#       escritorio del hive Default. Quien traduce registro -> colores es el motor
#       de temas, y solo corre cuando se APLICA un tema.
#
#    b) El AccentPalette exacto, DESPUES del apply (contrato 2.8): con teal
#       #14B8A6 el motor deja AccentColor exacto pero AccentPalette[3] = #008979.
#
#    c) El menu contextual clasico. Vive en Software\Classes, que en HKCU NO
#       esta en NTUSER.DAT sino en UsrClass.dat, un hive SEPARADO que no existe
#       hasta que el perfil se crea. Escribirlo offline no hace absolutamente
#       nada. No hay alternativa: o RunOnce, o no hay menu clasico. Y es lo UNICO
#       que todavia necesita reiniciar Explorer (el handler del menu se resuelve
#       una sola vez, al arrancar el shell).
#
#    d) Reaplicar Explorer\Advanced, Control Panel\Desktop, EnableTransparency y
#       ColorPrevalence. Esos SI sobrevivieron la instalacion medida, asi que es
#       redundancia barata, no un parche. Van DESPUES del apply, para que el
#       motor de temas no los pise.
#
#  DESCARTADO CON EVIDENCIA, no por gusto:
#    - `rundll32 ... desk.cpl desk,@Themes /Action:OpenTheme`: es ITheme::OpenTheme,
#      IGNORA el flag silencioso y ABRE la UI. El propio codigo de AutoDarkMode lo
#      comenta: "This does not work". Los scripts de la comunidad lo tapan con
#      `timeout 3 & taskkill /im systemsettings.exe` -- una carrera, no una solucion.
#    - El truco del alto contraste: SI fuerza el ciclo de apply, pero blanquea
#      CurrentTheme, fuerza el wallpaper a color solido y pone AutoColorization=1,
#      o sea que Windows recalcula el acento desde el wallpaper y ROMPE justo lo
#      que queriamos (contrato 2.7).
#    - Bajar a los ordinales de uxtheme.dll: MEDIDO, el mapeo que circula no se
#      sostiene en 22631 (los ord 49 y 138 devolvieron lo contrario a lo esperado).
#      Y no hace falta: IThemeManager2 hace el trabajo completo.
# ===========================================================================
$scriptsDir = Join-Path $mount 'Windows\Setup\Scripts'
New-Item -ItemType Directory -Force -Path $scriptsDir | Out-Null

$sb = New-Object System.Text.StringBuilder
function Add-L($t) { [void]$sb.AppendLine($t) }

Add-L @'
# LunaticOS - personalizacion del PRIMER LOGIN.
#
# QUE HACE:
#   1) APLICA C:\Windows\Resources\Themes\LunaticOS.theme con
#      IThemeManager2::AddAndSelectTheme, y VERIFICA en el registro que surtio
#      efecto. Escribir valores no aplica nada: quien traduce registro -> colores
#      es el motor de temas, y solo corre cuando se aplica un tema.
#   2) Reaplica Explorer\Advanced, Control Panel\Desktop, EnableTransparency y
#      ColorPrevalence (van DESPUES del apply para que el tema no los pise).
#   3) Corrige AccentPalette[3] para que el acento sea EXACTO (Windows lo
#      normaliza a su rampa de luminancias).
#   4) El menu contextual clasico (Software\Classes vive en UsrClass.dat, un hive
#      separado que no se puede escribir offline).
#
# NO SE AUTOBORRA A PROPOSITO: el RunOnce que lo dispara vive en el hive DEFAULT,
# asi que CADA usuario nuevo hereda su propia entrada. Si el script se borrara
# despues del primer login, el segundo usuario fallaria en silencio.
$ErrorActionPreference = "Continue"
$log = "$env:ProgramData\LunaticOS\personalizar.log"
New-Item -ItemType Directory -Force -Path (Split-Path $log) | Out-Null
function L($m) { $s = "{0}  {1}" -f (Get-Date -Format "HH:mm:ss"), $m; Write-Host $s; Add-Content -Path $log -Value $s }
L "=== personalizacion del primer login ($env:USERNAME) ==="

# ===========================================================================
#  LunaticKey: crear la clave SOLO si no existe. NO uses New-Item -Force.
#
#  BUG REAL, MEDIDO, y estuvo ACTIVO en cada ISO:
#    New-Item -Path <clave del registro> -Force  sobre una clave QUE YA EXISTE
#    la RECREA, o sea le BORRA TODOS LOS VALORES.
#  Comprobado: clave con valor1+blob -> New-Item -Force -> queda VACIA.
#
#  Que hacia eso aca: este script escribia
#      New-Item -Path '...\Themes\Personalize' -Force
#      Set-ItemProperty ... AppsUseLightTheme 0
#      New-Item -Path '...\Themes\Personalize' -Force      <-- borra la anterior
#      Set-ItemProperty ... SystemUsesLightTheme 0
#  y mas abajo el item del acento en la taskbar volvia a hacer New-Item -Force
#  sobre LA MISMA clave y borraba las dos. Resultado en el primer login:
#  Themes\Personalize quedaba con SOLO ColorPrevalence, sin AppsUseLightTheme ni
#  SystemUsesLightTheme -- y un valor ausente significa CLARO. O sea que nuestro
#  propio script de primer login borraba el tema oscuro que la fase habia dejado
#  en el hive. Exactamente el sintoma medido: "el modo oscuro queda escrito pero
#  la UI se ve clara".
#  Tambien se comio el AccentPalette al tocar Explorer\Accent.
#
#  -Force sigue estando, pero SOLO cuando la clave no existe: ahi sirve para
#  crear los padres que falten, que es para lo que uno lo pone.
# ===========================================================================
function LunaticKey($k) {
  if (-not (Test-Path $k)) { New-Item -Path $k -Force -ErrorAction SilentlyContinue | Out-Null }
}
'@
Add-L ''

# ---------------------------------------------------------------------------
# 6.a) EL APPLY DEL TEMA. Aca es donde el proyecto se rompio DOS VECES.
#
# Los datos esperados se interpolan como DECIMALES: en este repo no se escribe
# ni un literal hexadecimal de color. Salen de ConvertTo-AccentDwords.
# ---------------------------------------------------------------------------
if ($themeContent) {
  Add-L ('$LunaticTheme     = "{0}"' -f $ThemeInstalledPath)
  Add-L ('$LunaticModo      = "{0}"' -f $(if ($modo) { $modo } else { 'Light' }))
  # $true solo si shipeamos wallpaper propio: si el .theme no trae la seccion
  # [Control Panel\Desktop], dejar que el apply toque el fondo puede blanquearlo.
  Add-L ('$LunaticWallpaper = ${0}' -f $(if ($wpName) { 'true' } else { 'false' }))
  if ($accent) {
    Add-L ('$LunaticAbgr      = {0}' -f $accentAbgrStr)   # AccentColor esperado (ABGR)
    Add-L ('$LunaticArgb      = {0}' -f $accentArgbStr)   # ColorizationColor (ARGB, alpha C4)
    Add-L ('$LunaticR         = {0}' -f [string][int]$accent.R)
    Add-L ('$LunaticG         = {0}' -f [string][int]$accent.G)
    Add-L ('$LunaticB         = {0}' -f [string][int]$accent.B)
  } else {
    Add-L '$LunaticAbgr      = $null   # el usuario no eligio acento: no hay color que verificar'
    Add-L '$LunaticArgb      = $null'
  }
  Add-L ''
  Add-L @'
# ===========================================================================
#  APLICAR EL TEMA -- IThemeManager2::AddAndSelectTheme (contrato 2.6)
#
#  MEDIDO en una maquina real (Win11 22631, PowerShell 5.1): hr=0x00000000,
#  856 ms, NO abre Settings, y de UNA sola llamada deja escritos AccentColor,
#  ColorizationColor, ColorizationAfterglow, AccentColorMenu, StartColorMenu,
#  AccentPalette y CurrentTheme.
#
#  POR QUE AddAndSelectTheme Y NO SetCurrentTheme(idx): AddAndSelectTheme toma un
#  PATH. SetCurrentTheme obliga a enumerar temas y matchear un DisplayName que
#  esta LOCALIZADO ("Windows (dark)" vs "Windows (oscuro)"): en una ISO
#  multi-idioma eso se rompe y no avisa.
#
#  POR QUE UN THREAD STA PROPIO Y NO confiar en el apartment del host:
#  el objeto COM EXIGE STA. powershell.exe 5.1 arranca en STA por defecto, pero
#  ESO NO SE PUEDE ASUMIR: cambia con -MTA, con ISE, con un runspace embebido, con
#  una Scheduled Task o con powershell 7 (que es MTA por defecto). Este script se
#  invoca hoy con `powershell.exe -File`, pero el dia que alguien lo llame de otra
#  forma la falla seria un COM que cuelga o revienta en el primer login, o sea el
#  peor lugar posible para depender de un default implicito. Un Thread propio con
#  SetApartmentState(STA) es correcto SIEMPRE, cuesta nada, muere en el Join y no
#  le deja el apartment sucio al que llama. Es tambien el codigo exacto que se
#  midio funcionando.
# ===========================================================================
$LunaticCS = @"
using System;
using System.Threading;
using System.Runtime.InteropServices;
public static class LunaticThemeApply {
    // ITheme: solo hacen falta los 6 primeros slots del vtable, pero la interfaz
    // se declara igual porque IThemeManager2 la referencia en su vtable.
    // Los slots 0-33 son identicos de 1809 a 24H2 (verificado contra desk.cpl).
    [Guid("26e4185f-0528-475f-acaf-abe89ba6017d")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface ITheme {
        string DisplayName  { get; set; }
        string VisualStyle1 { get; set; }
        string VisualStyle2 { get; set; }
    }
    // EL ORDEN DE ESTOS METODOS ES EL VTABLE. No reordenar, no borrar, no agregar
    // en el medio: cada firma es un slot y llamar al slot equivocado es undefined
    // behavior dentro de explorer/themeui.
    //
    // [PreserveSig] EN LOS TRES QUE LLAMAMOS, y no es cosmetico. Sin PreserveSig el
    // CLR asume "HRESULT + un puntero extra de retval": en los metodos que fallan
    // tira COMException en vez de devolver el codigo, y en los que devuelven int
    // lee un retval que el nativo NUNCA escribio. MEDIDO: sin PreserveSig un
    // E_FAIL real se veia como "COMException" y el hr logueado quedaba en
    // 0xFFFFFFFF (el valor inicial), o sea que el log mentia justo cuando mas
    // importaba. Con PreserveSig el hr del log es el HRESULT de verdad: 0x80004005.
    [Guid("c1e8c83e-845d-4d95-81db-e283fdffc000")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IThemeManager2 {
        [PreserveSig] int Init(int initFlags);
        void InitAsync(IntPtr hwnd, int unk1);
        void Refresh();
        void RefreshAsync(IntPtr hwnd, int unk1);
        void RefreshComplete();
        int  GetThemeCount(out int count);
        void GetTheme(int index, out ITheme theme);
        void IsThemeDisabled(int index, out int disabled);
        void GetCurrentTheme(out int index);
        int  SetCurrentTheme(IntPtr parent, int themeIndex, int applyNow, int applyFlags, int packFlags);
        void GetCustomTheme(out int index);
        void GetDefaultTheme(out int index);
        void CreateThemePack(IntPtr hwnd, string path, int packFlags);
        void CloneAndSetCurrentTheme(IntPtr hwnd, string path, out string cloned);
        void InstallThemePack(IntPtr hwnd, string path, int unk, int packFlags, out string outPath, out ITheme outTheme);
        void DeleteTheme(string displayName);
        int  OpenTheme(IntPtr hwnd, string path, int packFlags);
        [PreserveSig] int AddAndSelectTheme(IntPtr hwnd, string path, int applyFlags, int packFlags);
        void SQMCurrentTheme();
        void ExportRoamingThemeToStream(System.Runtime.InteropServices.ComTypes.IStream s, int unk);
        void ImportRoamingThemeFromStream(System.Runtime.InteropServices.ComTypes.IStream s, int unk);
        void UpdateColorSettingsForLogonUI();
        void GetDefaultThemeId(out Guid guid);
        [PreserveSig] int UpdateCustomTheme();
    }
    [DllImport("ole32.dll")]
    static extern int CoCreateInstance(
        [In, MarshalAs(UnmanagedType.LPStruct)] Guid rclsid, IntPtr pUnkOuter, uint ctx,
        [In, MarshalAs(UnmanagedType.LPStruct)] Guid riid,
        [MarshalAs(UnmanagedType.IUnknown)] out object ppv);

    // ThemeApplyFlags: que partes del .theme NO tocar.
    const int IGNORE_BACKGROUND    = 1 << 0;
    const int IGNORE_CURSOR        = 1 << 1;
    const int IGNORE_DESKTOP_ICONS = 1 << 2;
    const int IGNORE_SOUND         = 1 << 4;
    const int IGNORE_SCREENSAVER   = 1 << 5;
    const int NO_HOURGLASS         = 1 << 8;
    // ThemePackFlags: PACK_SILENT es lo que evita que se abra ninguna UI.
    const int PACK_SILENT          = 1 << 2;

    public static int    LastHr    = -1;
    public static int    LastInit  = -1;
    public static string LastError = null;

    public static void Apply(string path, bool applyWallpaper) {
        LastHr = -1; LastInit = -1; LastError = null;
        Thread t = new Thread(delegate() {
            IThemeManager2 m = null;
            try {
                object o;
                int hrc = CoCreateInstance(
                    new Guid("9324da94-50ec-4a14-a770-e90ca03e7c8f"),  // CLSID_ThemeManager2
                    IntPtr.Zero,
                    0x17,                                             // INPROC_SERVER|INPROC_HANDLER|LOCAL_SERVER
                    typeof(IThemeManager2).GUID,
                    out o);
                if (o == null) { LastError = "CoCreateInstance hr=0x" + hrc.ToString("x8"); return; }
                m = (IThemeManager2)o;
                LastInit = m.Init(0);                                 // ThemeInitNoFlags
                int flags = IGNORE_CURSOR | IGNORE_DESKTOP_ICONS | IGNORE_SOUND | IGNORE_SCREENSAVER | NO_HOURGLASS;
                if (!applyWallpaper) flags |= IGNORE_BACKGROUND;
                LastHr = m.AddAndSelectTheme(IntPtr.Zero, path, flags, PACK_SILENT);
                m.UpdateCustomTheme();
            } catch (Exception ex) { LastError = ex.GetType().Name + ": " + ex.Message; }
            finally { if (m != null) Marshal.ReleaseComObject(m); }
        });
        t.SetApartmentState(ApartmentState.STA);
        t.Start();
        t.Join();
    }
}
"@

$LunaticKeyDwm    = "HKCU:\SOFTWARE\Microsoft\Windows\DWM"
$LunaticKeyAccent = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Accent"
$LunaticKeyPers   = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize"

# MEDIDO en Win11 22631 / PowerShell 5.1, y NO es lo que uno esperaria:
#   Get-ItemProperty  AccentColor -> 4282927692  System.UInt32
#   (Get-Item).GetValue('AccentColor') -> -12039604  System.Int32
# O sea que el MISMO valor vuelve como UInt32 o como Int32 segun COMO lo leas.
# Por eso el paso obligado es [long] antes de la mascara: castear a [int] tira
# "Value was either too large or too small for an Int32" con cualquier color de
# alpha FF o C4, que son justo TODOS los nuestros. Es la tercera vez que el
# overflow de Int32 muerde a este proyecto: [long] aguanta las tres formas
# (Int32 negativo, UInt32 positivo, Int64) y no puede fallar.
# 4294967295 en decimal a proposito: aca no se escriben mascaras hexadecimales de
# 8 digitos, porque despues parecen colores.
function LunaticU32($v) {
  if ($null -eq $v) { return $null }
  return [uint32](([long]$v) -band 4294967295)
}
function LunaticHex($u) {
  if ($null -eq $u) { return "(no existe)" }
  return ("0x{0:X8}" -f $u)
}

# Dump del estado real. Se loguea ANTES y DESPUES del apply: es la unica forma de
# distinguir "aplico" de "devolvio hr=0 y no hizo nada".
function LunaticDump($cuando) {
  $d = Get-ItemProperty $LunaticKeyDwm    -ErrorAction SilentlyContinue
  $a = Get-ItemProperty $LunaticKeyAccent -ErrorAction SilentlyContinue
  $p = Get-ItemProperty $LunaticKeyPers   -ErrorAction SilentlyContinue
  $pal = "(no hay)"
  if ($a -and $a.AccentPalette -and $a.AccentPalette.Length -eq 32) {
    $pal = "#{0:X2}{1:X2}{2:X2}" -f $a.AccentPalette[12], $a.AccentPalette[13], $a.AccentPalette[14]
  }
  $t1 = "  [{0}] AccentColor={1} Colorization={2} Afterglow={3}" -f $cuando,
        (LunaticHex (LunaticU32 $d.AccentColor)), (LunaticHex (LunaticU32 $d.ColorizationColor)),
        (LunaticHex (LunaticU32 $d.ColorizationAfterglow))
  $t2 = "  [{0}] Menu={1} Start={2} palette[3]={3} Apps={4} System={5}" -f $cuando,
        (LunaticHex (LunaticU32 $a.AccentColorMenu)), (LunaticHex (LunaticU32 $a.StartColorMenu)),
        $pal, $p.AppsUseLightTheme, $p.SystemUsesLightTheme
  L $t1
  L $t2
}

# VERIFICACION REAL. No alcanza con hr=0: si el .theme es "el mismo" que el tema
# vigente, Windows no hace NADA y devuelve 0 igual (contrato 2.6). Se mide el
# resultado, no el codigo de retorno.
function LunaticVerify {
  $ok = $true
  $esperado = 1
  if ($LunaticModo -eq "Dark") { $esperado = 0 }
  $p = Get-ItemProperty $LunaticKeyPers -ErrorAction SilentlyContinue
  if ($null -eq $p -or $p.AppsUseLightTheme -ne $esperado -or $p.SystemUsesLightTheme -ne $esperado) { $ok = $false }
  if ($null -ne $LunaticAbgr) {
    $d = Get-ItemProperty $LunaticKeyDwm -ErrorAction SilentlyContinue
    if ($null -eq $d -or (LunaticU32 $d.AccentColor) -ne [uint32]$LunaticAbgr) { $ok = $false }
  }
  return $ok
}

function LunaticApply($ruta) {
  L ("aplicando tema: " + $ruta)
  $t0 = Get-Date
  [LunaticThemeApply]::Apply($ruta, $LunaticWallpaper)
  $ms = [int]((Get-Date) - $t0).TotalMilliseconds
  $hr = [LunaticThemeApply]::LastHr
  if ([LunaticThemeApply]::LastError) { L ("! EXCEPCION en el apply: " + [LunaticThemeApply]::LastError) }
  L ("AddAndSelectTheme hr=0x{0:X8}  (Init hr=0x{1:X8}, {2} ms)" -f $hr, [LunaticThemeApply]::LastInit, $ms)
  # 0x80004005 = E_FAIL. El caso conocido: al .theme le falta la linea Wallpaper=
  # en [Control Panel\Desktop] y el motor de temas rechaza el archivo entero.
  if ($hr -eq -2147467259) { L "! E_FAIL: el .theme fue RECHAZADO. Chequea que tenga [Control Panel\Desktop] con una linea Wallpaper=." }
  Start-Sleep -Milliseconds 700
  LunaticDump "despues"
  $ok = LunaticVerify
  if ($hr -eq 0 -and -not $ok) {
    L "! hr=0 pero el registro NO quedo como se pidio: es el NO-OP SILENCIOSO de Windows."
    L "! (si el .theme es el mismo que el vigente, no hace nada y devuelve 0 igual)"
  }
  return $ok
}

$LunaticOk = $false
try {
  Add-Type -TypeDefinition $LunaticCS -Language CSharp -ErrorAction Stop
  if (-not (Test-Path $LunaticTheme)) {
    L ("! NO EXISTE " + $LunaticTheme + ": no hay tema que aplicar. Revisa la fase 10 del build.")
  } else {
    LunaticDump "antes"
    $LunaticOk = LunaticApply $LunaticTheme
    if (-not $LunaticOk) {
      # REINTENTO con un ThemeId nuevo generado AHORA. Cubre el caso que nos
      # rompio: Windows ya aplico este mismo .theme al crear el perfil (por
      # InstallThemeDark) y despues el aprovisionamiento piso los valores HKCU.
      # Ahi el tema vigente ES el nuestro, el apply no-opea, y el color queda mal
      # con hr=0. Con otro ThemeId el contenido difiere y el motor no puede
      # saltearlo. Es la misma idea que el nudge de AutoDarkMode.
      L "reintento con un ThemeId nuevo (para que Windows no lo tome como el mismo tema)"
      try {
        $txt = [System.IO.File]::ReadAllText($LunaticTheme)
        $nuevo = "ThemeId={" + ([guid]::NewGuid().ToString().ToUpperInvariant()) + "}"
        if ($txt -match "ThemeId=\{[^\}]*\}") { $txt = $txt -replace "ThemeId=\{[^\}]*\}", $nuevo }
        else { $txt = $txt -replace "(?m)^\[Theme\]\r?$", ("[Theme]`r`n" + $nuevo) }
        $reintento = Join-Path $env:TEMP "LunaticOS-reintento.theme"
        [System.IO.File]::WriteAllText($reintento, $txt, [System.Text.Encoding]::ASCII)
        $LunaticOk = LunaticApply $reintento
      } catch { L ("! no pude generar el .theme de reintento: " + $_.Exception.Message) }
    }
    if (-not $LunaticOk) {
      # ==================================================================
      #  ULTIMO RECURSO: escribir los valores exactos a mano.
      #
      #  MEDIDO en esta maquina, y es el hallazgo que obliga a este paso:
      #  el no-op de Windows es POR VALOR, no por tema. Se piso a mano
      #  DWM\AccentColor dejando ColorizationColor bien, y se reaplico el
      #  .theme: hr=0, el MODO se corrigio (Apps/System volvieron a 0) pero
      #  AccentColor QUEDO MAL. Con otro ThemeId, igual. O sea: si el
      #  ColorizationColor del registro ya coincide con el del .theme, el
      #  motor no vuelve a derivar el acento, y NINGUN apply lo arregla.
      #
      #  Estos son los MISMOS numeros que la fase escribio en el hive
      #  DEFAULT: mismo hex, mismo helper, mismos formatos ABGR/ARGB. No es
      #  una tercera fuente de verdad, es la misma escrita en otro momento.
      # ==================================================================
      L "ultimo recurso: escribo el modo y los valores del acento a mano"
      try {
        $modoVal = 1
        if ($LunaticModo -eq "Dark") { $modoVal = 0 }
        LunaticKey $LunaticKeyPers
        Set-ItemProperty -Path $LunaticKeyPers -Name AppsUseLightTheme    -Value $modoVal -Type DWord
        Set-ItemProperty -Path $LunaticKeyPers -Name SystemUsesLightTheme -Value $modoVal -Type DWord
        if ($null -ne $LunaticAbgr) {
          # Set-ItemProperty -Type DWord NO acepta un numero mayor que Int32.MaxValue:
          # hay que pasarle el MISMO patron de bits como Int32 con signo. Es el
          # overflow de Int32 de siempre, esta vez del lado de la escritura.
          $abgrI = [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]$LunaticAbgr), 0)
          $argbI = [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]$LunaticArgb), 0)
          LunaticKey $LunaticKeyDwm
          LunaticKey $LunaticKeyAccent
          Set-ItemProperty -Path $LunaticKeyDwm    -Name AccentColor           -Value $abgrI -Type DWord
          Set-ItemProperty -Path $LunaticKeyDwm    -Name AccentColorInactive   -Value $abgrI -Type DWord
          Set-ItemProperty -Path $LunaticKeyDwm    -Name ColorizationColor     -Value $argbI -Type DWord
          Set-ItemProperty -Path $LunaticKeyDwm    -Name ColorizationAfterglow -Value $argbI -Type DWord
          Set-ItemProperty -Path $LunaticKeyAccent -Name AccentColorMenu       -Value $abgrI -Type DWord
          Set-ItemProperty -Path $LunaticKeyAccent -Name StartColorMenu        -Value $abgrI -Type DWord
        }
        LunaticDump "a mano"
        $LunaticOk = LunaticVerify
        if ($LunaticOk) { L "los valores quedaron correctos escribiendolos a mano (el motor de temas los ignoro)" }
      } catch { L ("! no pude escribir los valores a mano: " + $_.Exception.Message) }
    }
  }
} catch { L ("! no pude preparar el apply del tema: " + $_.Exception.Message) }

if ($LunaticOk) {
  L "tema APLICADO y verificado contra el registro"
} else {
  L "!!! EL TEMA NO SE APLICO. Este es el punto exacto donde el proyecto se rompio dos veces."
  L "!!! Sintoma esperable: modo correcto pero acento AZUL de fabrica, o modo claro."
  L "!!! Arreglo manual: Settings > Personalization > Themes > elegir LunaticOS."
}
'@
  Add-L ''
}

foreach ($it in $userItems) {
  $lineas = @()
  foreach ($r in $it.Regs) {
    if (-not $r) { continue }
    # Misma guarda que en el hive: ningun color, aunque el catalogo vuelva a traerlos.
    if (Test-ColorValueName $r.v) { continue }
    $key = if ($r.k) { "HKCU:\$($r.k)" } else { 'HKCU:' }
    # LunaticKey, NO New-Item -Force: sobre una clave existente, -Force le borra
    # TODOS los valores. Ver la definicion del helper arriba del script generado.
    $lineas += ("LunaticKey '{0}'" -f $key)
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
# 6.b) AccentPalette: el indice 3 exacto, DESPUES del apply (contrato 2.8)
#
# MEDIDO: con teal #14B8A6 el motor de temas deja DWM\AccentColor EXACTO, pero
# AccentPalette[3] sale #008979 -- Windows normaliza el color a su rampa de
# luminancias. Start, taskbar y controles usan la paleta, no AccentColor, asi que
# el usuario ve un teal distinto al que eligio.
#
# DECISION: se lee la paleta que Windows acaba de generar y se sobreescribe SOLO
# el indice 3 (bytes 12-14). Lo minimo invasivo posible:
#   - NO se derivan los 8 tonos con una formula. No hay algoritmo publicado
#     exacto, y el escalado lineal en RGB que haciamos antes daba colores
#     quemados que no coincidian con los que genera Settings. El propio idx7 no
#     es un tono del acento: es un color de enfasis aparte (#107C10 verde para un
#     gris, #881798 violeta para el teal), o sea que ninguna formula de escalado
#     puede estar bien.
#   - NO se hardcodea una rampa: los otros 7 tonos que derivo el motor son
#     internamente coherentes, y reemplazarlos por una lista fija seria volver a
#     inventar colores.
#   - Si la paleta no existe o no mide 32 bytes, NO SE INVENTA NADA: se loguea.
#
# El byte de alpha (indice 15) NO SE TOCA. Es padding a efectos practicos:
# MEDIDO, Settings escribe 0x00, el motor de temas a veces 0xFF, y funciona con
# los dos. Dejar el que puso Windows es una variable menos.
#
# ORDEN: este bloque va DESPUES del apply (obvio: la paleta la genera el apply) y
# ANTES del reinicio de Explorer. No es casual. Explorer lee AccentPalette al
# arrancar, asi que si el reinicio del shell ocurre despues, el Explorer nuevo ya
# levanta con el acento exacto. Al reves habria que esperar otro refresco.
# ---------------------------------------------------------------------------
if ($accent) {
  Add-L @'
# --- AccentPalette: indice 3 = el acento EXACTO (contrato 2.8) ---
try {
  $pal = (Get-ItemProperty -Path $LunaticKeyAccent -Name AccentPalette -ErrorAction SilentlyContinue).AccentPalette
  if ($pal -and $pal.Length -eq 32) {
    $previo = "#{0:X2}{1:X2}{2:X2}" -f $pal[12], $pal[13], $pal[14]
    $pal[12] = [byte]$LunaticR
    $pal[13] = [byte]$LunaticG
    $pal[14] = [byte]$LunaticB
    # $pal[15] (alpha) queda como lo dejo Windows: es padding.
    Set-ItemProperty -Path $LunaticKeyAccent -Name AccentPalette -Value $pal -Type Binary -ErrorAction Stop
    $ahora = (Get-ItemProperty -Path $LunaticKeyAccent -Name AccentPalette).AccentPalette
    $leido = "#{0:X2}{1:X2}{2:X2}" -f $ahora[12], $ahora[13], $ahora[14]
    $pedido = "#{0:X2}{1:X2}{2:X2}" -f $LunaticR, $LunaticG, $LunaticB
    if ($leido -eq $pedido) { L ("AccentPalette[3]: " + $previo + " -> " + $leido + " (exacto)") }
    else { L ("! AccentPalette[3] quedo en " + $leido + " y se pidio " + $pedido) }
  } else {
    L "! no hay AccentPalette de 32 bytes: no la invento (no existe formula publicada para los 8 tonos)"
  }
} catch { L ("! no pude escribir AccentPalette: " + $_.Exception.Message) }
'@
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
# YA NO ES NECESARIO PARA EL TEMA: el apply de IThemeManager2 dispara toda la
# cascada por dentro (WM_THEMECHANGED, WM_DWMCOLORIZATIONCOLORCHANGED,
# WM_SYSCOLORCHANGE) y los valores de DWM cambian solos -- medido, sin broadcast.
# Se queda igual porque cuesta milisegundos y SI hace falta para los tweaks que
# este script escribe DESPUES del apply (Explorer\Advanced, ColorPrevalence,
# EnableTransparency) y para el AccentPalette que acabamos de corregir a mano.
# Es lo que usa AutoDarkMode (DwmRefreshHandler.Broadcast). No mata nada.
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
#  El prefijo 'AA' SE CONSERVA, y ahora SI es critico: RunOnce corre sus entradas
#  en orden alfabetico y secuencial, y este script es el que APLICA el tema. Tiene
#  que ir antes del instalador de programas ('ZZ', 20+ minutos) o el usuario mira
#  un escritorio con el color equivocado durante media hora.
#  OJO, A MEDIR EN VM: el orden alfabetico solo ordena DENTRO de una misma clave,
#  y el instalador de apps (fase 11) vive en el RunOnce de HKLM. Entre claves
#  distintas el orden lo decide el shell.
# ===========================================================================
if (-not $generarScript) {
  Write-Step "nada que aplicar ni reaplicar en el primer login: no genero el script ni el RunOnce" 'DarkGray'
} else {
  # ASCII PURO en el script generado: corre sobre conhost con codepage 850/437 y
  # cualquier acento se convierte en basura en pantalla y en el log.
  $runOncePath = Join-Path $scriptsDir $RunOnceScriptName
  [System.IO.File]::WriteAllText($runOncePath, $sb.ToString(), [System.Text.Encoding]::ASCII)
  Write-Step "generado $RunOnceScriptName (aplica el tema: $([bool]$themeContent); items: $($reaplicables.Count); shell restart: $necesitaShell)" 'Green'

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
  Write-Host "Personalizacion: LunaticOS.theme + las 6 claves InstallTheme* + color en el hive DEFAULT," -ForegroundColor Green
  Write-Host "y el primer login lo APLICA con IThemeManager2 y verifica el resultado en el registro." -ForegroundColor Green
} elseif ($picked.Count -gt 0) {
  Write-Host "Personalizacion: tweaks en el hive DEFAULT (no habia tema, acento ni wallpaper que declarar)." -ForegroundColor Green
} else {
  Write-Host "Personalizacion: nada marcado. Solo corri la limpieza de las policies que bloquean Settings." -ForegroundColor Green
}
Write-Host "Todo como DEFAULT o como TEMA, nunca como policy: el usuario cambia lo que quiera desde Settings." -ForegroundColor DarkGray
