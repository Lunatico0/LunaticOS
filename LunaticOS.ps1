#requires -Version 5.1
<#
  LunaticOS.ps1 -- Entry point unico. Elegis que querer, y genera tu ISO.

  Uso (consola como ADMINISTRADOR):
      .\LunaticOS.ps1

  Que hace, en orden:
      1. Preflight   -> admin, Windows, espacio en disco, ADK (lo instala si falta), ISO
      2. TUI         -> elegis appx / servicios / features / personalizacion / programas
      3. perfil.json -> guarda tu seleccion (compartible y versionable)
      4. Pipeline    -> corre las fases 00..10
      5. ISO lista   -> la grabas con Ventoy o Rufus

  ===========================================================================
  POR QUE UN perfil.json Y NO EDITAR config.ps1

  El perfil se puede COMPARTIR: le pasas el JSON a un compa y genera la MISMA
  ISO que vos, sin volver a elegir 200 cosas. Y es reproducible: lo versionas en
  git y en 6 meses regeneras la ISO identica.

  config.ps1 sigue siendo el DEFAULT del proyecto. El perfil lo pisa en memoria
  justo antes de correr las fases, asi las fases no saben que existe la TUI y se
  siguen pudiendo correr a mano una por una.
  ===========================================================================
#>
param(
  [string]$ProfilePath = "$PSScriptRoot\perfil.json",
  [switch]$NoPreflight,
  [switch]$Apply,         # saltea la TUI: aplica el perfil.json que ya existe
  [switch]$SelfTest,      # valida catalogos y perfil sin abrir la TUI ni buildear
  [switch]$NoPause        # no esperar teclas: para correr desatendido (CI, background)
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

. "$root\scripts\tui.ps1"
. "$root\scripts\config.ps1"
# lib.ps1 trae ConvertTo-AccentDwords, la UNICA conversion de color del repo. El
# self-test la necesita para verificar que el acento sale del color pedido: el test
# viejo solo miraba que el DWORD entrara en uint32 y daba VERDE con los bytes al
# reves. Las fases igual la cargan por su cuenta.
. "$root\scripts\lib.ps1"
. "$root\config\apps.ps1"
. "$root\config\personalizacion.ps1"

# ===========================================================================
#  CATALOGOS PARA LA TUI
# ===========================================================================

# Notas de los appx. Salen del inventario real de la imagen (docs/inventario-appx.md),
# no de una guia de foro: 47 paquetes provisioned en el install.wim de 25H2 Pro.
$AppxNotes = @{
  'Clipchamp.Clipchamp'                     = 'Editor de video de Microsoft.'
  'Microsoft.BingNews'                      = 'Noticias de Bing.'
  'Microsoft.BingWeather'                   = 'Clima de Bing. OJO: el clima de la taskbar es Widgets, no esto.'
  'Microsoft.GetHelp'                       = 'Asistente de ayuda de Microsoft.'
  'Microsoft.MicrosoftOfficeHub'            = 'Hub de Office: basicamente publicidad de Microsoft 365.'
  'Microsoft.MicrosoftSolitaireCollection'  = 'Solitario, con anuncios.'
  'Microsoft.OutlookForWindows'             = 'Outlook "nuevo". Reincidente: vuelve en los feature updates.'
  'Microsoft.PowerAutomateDesktop'          = 'Automatizacion RPA. Pesado y casi nadie lo usa.'
  'Microsoft.Todos'                         = 'Microsoft To-Do.'
  'Microsoft.Windows.DevHome'               = 'Dev Home. Reincidente en updates y no aporta nada que no tengas.'
  'Microsoft.WindowsFeedbackHub'            = 'Feedback Hub: manda telemetria a Microsoft.'
  'MicrosoftCorporationII.QuickAssist'      = 'Asistencia remota de Microsoft.'
  'MicrosoftWindows.CrossDevice'            = 'Continuidad con el celular.'
  'Microsoft.WindowsAlarms'                 = 'Alarmas y reloj.'
  'Microsoft.MicrosoftStickyNotes'          = 'Notas adhesivas.'
  'Microsoft.WindowsSoundRecorder'          = 'Grabadora de voz.'
  'Microsoft.YourPhone'                     = 'Phone Link (vincular Android).'
  'MSTeams'                                 = 'Teams preinstalado. Si lo usas para laburo, instala el de winget aparte.'
  # --- Zona gris: leer antes de sacar ---
  'Microsoft.BingSearch'                    = 'ZONA GRIS: DEJALO. Sacarlo puede romper el buscador del menu Inicio. El ruido de Bing se apaga por tweak (BingSearchEnabled=0), sin riesgo.'
  'Microsoft.ZuneMusic'                     = 'ZONA GRIS: DEJALO. Es el reproductor de archivos locales. Sin el no abris un mp3/mp4 del disco. Spotify NO lo reemplaza.'
  'Microsoft.WindowsCamera'                 = 'ZONA GRIS: DEJALO. Es liviano y lo necesitas si algun dia conectas una webcam.'
  # --- Blindados ---
  'Microsoft.DesktopAppInstaller'           = 'BLINDADO: es WINGET. Sacarlo rompe la instalacion de programas.'
  'Microsoft.WindowsStore'                  = 'BLINDADO: Microsoft Store.'
  'Microsoft.StorePurchaseApp'              = 'BLINDADO: compras de la Store.'
  'Microsoft.SecHealthUI'                   = 'BLINDADO: interfaz de Windows Security.'
  'Microsoft.ApplicationCompatibilityEnhancements' = 'BLINDADO: parches de compatibilidad de apps.'
  'Microsoft.WindowsTerminal'               = 'BLINDADO: Terminal.'
  'Microsoft.WindowsNotepad'                = 'BLINDADO: Notepad.'
  'Microsoft.WindowsCalculator'             = 'BLINDADO: Calculadora.'
  'Microsoft.Paint'                         = 'BLINDADO: Paint.'
  'Microsoft.ScreenSketch'                  = 'BLINDADO: Recortes (Win+Shift+S).'
  'Microsoft.Windows.Photos'                = 'BLINDADO: visor de fotos.'
  'Microsoft.GamingApp'                     = 'BLINDADO: Xbox app (Game Pass).'
  'Microsoft.Xbox.TCUI'                     = 'BLINDADO: UI de Xbox Live. La usan varios juegos de Steam.'
  'Microsoft.XboxGamingOverlay'             = 'BLINDADO: Game Bar (Win+G). La barra de captura y FPS.'
  'Microsoft.XboxIdentityProvider'          = 'BLINDADO: login de Xbox. Sin esto varios juegos NO arrancan.'
  'Microsoft.XboxSpeechToTextOverlay'       = 'BLINDADO: subtitulos de Xbox.'
  'MicrosoftWindows.Client.WebExperience'   = 'BLINDADO por decision: es WIDGETS, o sea el CLIMA de la taskbar. En 25H2 el feed de MSN viene apagado, asi que tenes clima sin publicidad.'
  'Microsoft.AV1VideoExtension'             = 'BLINDADO: codec AV1. Sacarlo rompe reproduccion de video.'
  'Microsoft.AVCEncoderVideoExtension'      = 'BLINDADO: codec AVC.'
  'Microsoft.HEIFImageExtension'            = 'BLINDADO: imagenes HEIF (fotos de iPhone).'
  'Microsoft.HEVCVideoExtension'            = 'BLINDADO: codec HEVC/H.265.'
  'Microsoft.MPEG2VideoExtension'           = 'BLINDADO: codec MPEG2.'
  'Microsoft.RawImageExtension'             = 'BLINDADO: fotos RAW.'
  'Microsoft.VP9VideoExtensions'            = 'BLINDADO: codec VP9 (YouTube).'
  'Microsoft.WebMediaExtensions'            = 'BLINDADO: WebM/OGG.'
  'Microsoft.WebpImageExtension'            = 'BLINDADO: imagenes WebP.'
}

function Build-AppxCatalog {
  $cat = @()
  foreach ($a in $AppxRemove) {
    $cat += @{ Key = $a; Name = $a; Rec = $true;  Cat = 'bloat'
               Note = if ($AppxNotes[$a]) { $AppxNotes[$a] } else { 'Sin nota.' } }
  }
  foreach ($a in @('Microsoft.BingSearch','Microsoft.ZuneMusic','Microsoft.WindowsCamera')) {
    $cat += @{ Key = $a; Name = $a; Rec = $false; Cat = 'zona gris'; Note = $AppxNotes[$a] }
  }
  # Los blindados se MUESTRAN pero no se pueden marcar. Mostrarlos es didactico:
  # asi ves que se conserva y por que, en vez de preguntarte que hizo el script.
  foreach ($a in $AppxKeep) {
    if ($cat.Key -contains $a) { continue }
    $cat += @{ Key = $a; Name = $a; Rec = $false; Cat = 'BLINDADO'; Locked = $true
               Note = if ($AppxNotes[$a]) { $AppxNotes[$a] } else { 'Protegido: sacarlo rompe algo.' } }
  }
  $cat
}

function Build-ServiceCatalog {
  $cat = @()
  foreach ($s in $ServicesDisable) {
    $cat += @{ Key = $s; Name = $s; Rec = $true; Cat = 'apagado'
               Note = 'Se deshabilita por defecto en el perfil de LunaticOS.' }
  }
  foreach ($s in $ServicesOptional.Keys | Sort-Object) {
    $cat += @{ Key = $s; Name = $s; Rec = $false; Cat = 'opcional'; Note = $ServicesOptional[$s] }
  }
  $cat
}

function Build-FeatureCatalog {
  $notes = @{
    'App.StepsRecorder'        = 'Grabadora de pasos. Deprecada por Microsoft.'
    'Browser.InternetExplorer' = 'IE 11. Sacalo salvo que uses "modo IE" en algun sistema viejo de laburo.'
    'MathRecognizer'           = 'Reconocimiento de formulas escritas a mano. Necesita pantalla tactil.'
    'Media.WindowsMediaPlayer' = 'WMP CLASICO (legacy). NO es el reproductor moderno, ese es un appx y se conserva.'
    'Language.Handwriting'     = 'Escritura a mano. Sin pantalla tactil no sirve.'
    'WindowsMediaPlayer'       = 'Feature del WMP legacy. NO tocar MediaPlayback, que es el motor de reproduccion.'
    'WorkFolders-Client'       = 'Work Folders (sincronizacion corporativa).'
  }
  $cat = @()
  foreach ($c in $CapabilitiesRemove) {
    $cat += @{ Key = "cap:$c"; Name = $c; Rec = $true; Cat = 'capability'
               Note = if ($notes[$c]) { $notes[$c] } else { 'Capability opcional de Windows.' } }
  }
  foreach ($f in $FeaturesDisable) {
    $cat += @{ Key = "feat:$f"; Name = $f; Rec = $true; Cat = 'feature'
               Note = if ($notes[$f]) { $notes[$f] } else { 'Feature opcional de Windows.' } }
  }
  $cat
}

function Build-FlagCatalog {
  @(
    @{ Key='RemoveOneDrive';    Name='Quitar OneDrive';            Rec=$true
       Note='Saca el cliente de OneDrive de la imagen. No borra archivos en la nube.' }
    @{ Key='KillTelemetry';     Name='Cortar telemetria';          Rec=$true
       Note='Servicio DiagTrack + tareas programadas + policy. NUNCA por firewall ni hosts: eso rompe Windows Update.' }
    @{ Key='DisableCopilot';    Name='Desactivar Copilot';         Rec=$true
       Note='Policy TurnOffWindowsCopilot. Esta SI es policy: no querras que vuelva en un update.' }
    @{ Key='DisableRecall';     Name='Desactivar Recall';          Rec=$true
       Note='Recall saca capturas de tu pantalla continuamente. Policy, por el mismo motivo.' }
    @{ Key='BypassMsAccount';   Name='Cuenta local (sin cuenta Microsoft)'; Rec=$true
       Note='Crea el usuario por unattend: el OOBE nunca llega a pedir cuenta Microsoft.' }
    @{ Key='ShowWeatherWidget'; Name='Conservar Widgets (clima en la taskbar)'; Rec=$true
       Note='Deja el clima. En 25H2 el feed de noticias MSN viene apagado, asi que no trae publicidad.' }
    @{ Key='RemoveEdgeBrowser'; Name='Bloquear el navegador Edge'; Rec=$true
       Note='Edge queda invisible e inejecutable (IFEO), pero WebView2 sigue actualizandose solo. NECESITAS instalar otro navegador y ponerlo como predeterminado.' }
    @{ Key='DisableLocation';   Name='Desactivar ubicacion (policy)'; Rec=$false
       Note='CUIDADO: esto BLOQUEA el panel Privacidad > Ubicacion en gris y no lo podes reactivar desde Settings. Ademas choca con el clima de Widgets. Por eso viene desmarcado.' }
    @{ Key='BlockCloudContent'; Name='Bloquear contenido sugerido (policy)'; Rec=$false
       Note='CUIDADO: son las 3 policies de CloudContent y son LAS QUE PONEN EL CARTEL "administradas por tu organizacion" en Settings. Ademas ocultan opciones de Personalization > Background. Cortan las sugerencias de apps y el contenido promocionado. Por eso viene desmarcado: el resto del debloat (telemetria, Copilot, Recall, ads) NO necesita esto.' }
  )
}

# ===========================================================================
#  PERFIL (json)
# ===========================================================================
function New-DefaultProfile {
  $p = [ordered]@{
    version         = 1
    creado          = ''
    appx            = [ordered]@{}
    servicios       = [ordered]@{}
    features        = [ordered]@{}
    flags           = [ordered]@{}
    personalizacion = [ordered]@{}
    programas       = [ordered]@{}
    usuario         = [ordered]@{ nombre = 'pato'; zona = 'Argentina Standard Time'; teclado = 'es-AR;en-US' }
  }
  foreach ($i in Build-AppxCatalog)    { if (-not $i.Locked) { $p.appx[$i.Key] = [bool]$i.Rec } }
  foreach ($i in Build-ServiceCatalog) { $p.servicios[$i.Key] = [bool]$i.Rec }
  foreach ($i in Build-FeatureCatalog) { $p.features[$i.Key]  = [bool]$i.Rec }
  foreach ($i in Build-FlagCatalog)    { $p.flags[$i.Key]     = [bool]$i.Rec }
  foreach ($i in $PersonalizacionCatalog) { $p.personalizacion[$i.Key] = [bool]$i.Rec }
  foreach ($i in $AppCatalog)          { $p.programas[$i.Key] = [bool]$i.Rec }
  $p
}

function Import-Profile([string]$path) {
  if (-not (Test-Path $path)) { return $null }
  try {
    $raw = Get-Content $path -Raw | ConvertFrom-Json
  } catch {
    Write-Host "  ! perfil.json ilegible ($($_.Exception.Message)). Se ignora." -ForegroundColor Yellow
    return $null
  }
  # Se arranca del default y se PISAN las claves que el archivo trae. Asi un perfil
  # viejo (de antes de agregar opciones nuevas) sigue funcionando: las claves que
  # falten quedan con el default en vez de romper o quedar en $null.
  $p = New-DefaultProfile
  foreach ($sec in @('appx','servicios','features','flags','personalizacion','programas')) {
    if ($raw.$sec) {
      foreach ($k in $raw.$sec.PSObject.Properties.Name) { $p.$sec[$k] = [bool]$raw.$sec.$k }
    }
  }
  if ($raw.usuario) {
    foreach ($k in $raw.usuario.PSObject.Properties.Name) { $p.usuario[$k] = $raw.usuario.$k }
  }
  $p
}

function Export-Profile($profile, [string]$path, [string]$stamp) {
  $profile.creado = $stamp
  $profile | ConvertTo-Json -Depth 6 | Set-Content -Path $path -Encoding UTF8
}

# Convierte hashtable de selecciones -> array de claves marcadas
function Get-Picked($section) { @($section.Keys | Where-Object { $section[$_] }) }

# ===========================================================================
#  PREFLIGHT
# ===========================================================================
function Test-IsAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Preflight {
  Clear-Host
  Show-TuiHeader 'Chequeo de requisitos'
  Write-Host ''
  $fatal = @()

  # --- Administrador ---
  if (Test-IsAdmin) { Write-Host '  [OK]    consola como Administrador' -ForegroundColor Green }
  else { Write-Host '  [FALLA] NO sos Administrador' -ForegroundColor Red; $fatal += 'Abri PowerShell como Administrador.' }

  # --- Windows suficientemente nuevo ---
  $b = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
  if ($b -ge 22000) { Write-Host "  [OK]    Windows build $b" -ForegroundColor Green }
  # OJO: "${b}:" y no "$b:" -- PowerShell lee "$b:" como variable con calificador de
  # scope (estilo $env:PATH) y tira error de parseo. Hay que delimitar con ${}.
  else { Write-Host "  [FALLA] build ${b}: se necesita Windows 10 2004+ / 11" -ForegroundColor Red; $fatal += 'Host demasiado viejo.' }

  # --- Espacio en disco ---
  # 25 GB no es capricho: el WIM exportado (~7 GB) + el arbol de la ISO (~8 GB) +
  # el WIM montado y expandido conviven al mismo tiempo.
  $drive = (Get-Item $root).PSDrive.Name
  $free  = [math]::Round((Get-PSDrive $drive).Free / 1GB, 1)
  if ($free -ge 25) { Write-Host "  [OK]    espacio libre en ${drive}: $free GB" -ForegroundColor Green }
  else { Write-Host "  [FALLA] solo $free GB libres en ${drive}: hacen falta 25" -ForegroundColor Red; $fatal += 'Libera espacio o mueve el repo a otro disco.' }

  # --- ADK (oscdimg + dism) ---
  if ((Test-Path $CFG.Oscdimg) -and (Test-Path $CFG.Dism)) {
    Write-Host '  [OK]    Windows ADK (Deployment Tools)' -ForegroundColor Green
  } else {
    Write-Host '  [FALTA] Windows ADK: hace falta oscdimg para armar la ISO' -ForegroundColor Yellow
    Write-Host '          El ADK NO esta en winget (verificado). Se baja de Microsoft.' -ForegroundColor DarkGray
    if (Show-TuiConfirm 'Descargar e instalar el ADK ahora? (~1 GB de descarga)' @(
          'Se instala SOLO el componente Deployment Tools, en silencio.'
          'Comando: adksetup.exe /quiet /features OptionId.DeploymentTools')) {
      Install-Adk
      if (-not ((Test-Path $CFG.Oscdimg) -and (Test-Path $CFG.Dism))) { $fatal += 'El ADK no quedo instalado.' }
    } else { $fatal += 'Sin el ADK no se puede armar la ISO.' }
  }

  # --- ISO original ---
  $iso = Find-SourceIso
  if ($iso) { Write-Host "  [OK]    ISO de Windows: $(Split-Path $iso -Leaf)" -ForegroundColor Green }
  else      { Write-Host '  [FALLA] no encontre la ISO oficial de Windows 11 en work\' -ForegroundColor Red
              $fatal += 'Pone la ISO oficial de Windows 11 x64 en work\ (bajala de microsoft.com/software-download/windows11).' }

  # ==========================================================================
  #  --- Clave de Windows ---
  #  Esto NO es fatal, pero avisar ACA es lo que evita la frustracion: sin
  #  activacion, Settings > Personalization queda en gris (tema, color y fondo), y
  #  eso no se descubre hasta 45 minutos de build mas una instalacion completa
  #  despues. Le paso al usuario, y lo mando a buscar una policy que no existia.
  # ==========================================================================
  $claveFile = Join-Path $root 'clave-windows.txt'
  if (Test-Path $claveFile) {
    $lineasK = @(Get-Content $claveFile -EA SilentlyContinue | ForEach-Object { $_.Trim() } |
                 Where-Object { $_ -ne '' -and -not $_.StartsWith('#') })
    if ($lineasK.Count -eq 0) {
      Write-Host '  [OJO]   clave-windows.txt esta vacio -> se usa la clave generica' -ForegroundColor Yellow
      Write-Host '          Windows NO va a activarse y Personalization va a estar BLOQUEADA.' -ForegroundColor Yellow
    } elseif ($lineasK[0].ToUpperInvariant() -notmatch '^[A-Z0-9]{5}(-[A-Z0-9]{5}){4}$') {
      # Fatal a proposito: si la clave esta mal tipeada, mejor enterarse ahora que a
      # los 45 minutos. El sintoma que deja no se parece en nada a la causa.
      Write-Host "  [FALLA] la clave de clave-windows.txt tiene formato invalido: '$($lineasK[0])'" -ForegroundColor Red
      $fatal += 'Corregi clave-windows.txt: se espera XXXXX-XXXXX-XXXXX-XXXXX-XXXXX en una linea.'
    } else {
      $gK = $lineasK[0].ToUpperInvariant().Split('-')
      Write-Host ("  [OK]    clave de Windows propia: {0}{1}  (Windows se va a activar)" -f ('*****-' * 4), $gK[-1]) -ForegroundColor Green
    }
  } else {
    Write-Host '  [OJO]   sin clave propia: se usa la generica de Pro, que NO activa Windows' -ForegroundColor Yellow
    Write-Host '          Consecuencia: Settings > Personalization va a estar BLOQUEADA (tema,' -ForegroundColor Yellow
    Write-Host '          color y fondo en gris) hasta que actives. No es un bug del debloat:' -ForegroundColor Yellow
    Write-Host '          Windows lo bloquea por licenciamiento.' -ForegroundColor Yellow
    Write-Host '          Para arreglarlo: copia clave-windows.txt.ejemplo a clave-windows.txt y' -ForegroundColor DarkGray
    Write-Host '          pone tu clave adentro. Si tu mother ya tiene licencia digital vinculada,' -ForegroundColor DarkGray
    Write-Host '          se activa sola y no hace falta.' -ForegroundColor DarkGray
  }

  Write-Host ''
  if ($fatal) {
    Write-Host '  No se puede seguir:' -ForegroundColor Red
    $fatal | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow }
    Write-Host ''
    return $false
  }
  Write-Host '  Todo en orden.' -ForegroundColor Green
  if (-not $NoPause) { Show-TuiPause }
  $true
}

function Install-Adk {
  $exe = Join-Path $root 'work\adksetup.exe'
  if (-not (Test-Path $exe)) {
    # Link permanente de Microsoft para el ADK. Si algun dia cambia, el mensaje de
    # error tiene que ser claro en vez de dejar un archivo de 0 bytes.
    $url = 'https://go.microsoft.com/fwlink/?linkid=2289980'
    Write-Host "  descargando ADK desde Microsoft..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Force -Path (Split-Path $exe) | Out-Null
    try { Invoke-WebRequest -Uri $url -OutFile $exe -UseBasicParsing }
    catch { Write-Host "  ! fallo la descarga: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "    Bajalo a mano y ponelo en work\adksetup.exe" -ForegroundColor Yellow; return }
  }
  Write-Host '  instalando Deployment Tools (silencioso, tarda unos minutos)...' -ForegroundColor Cyan
  & $exe /quiet /features OptionId.DeploymentTools /norestart | Out-Null
  Write-Host '  listo.' -ForegroundColor Green
}

function Find-SourceIso {
  $work = Join-Path $root 'work'
  if (-not (Test-Path $work)) { return $null }
  # La ISO que GENERAMOS se llama *_debloat.iso: excluirla o nos comeriamos nuestra
  # propia salida como entrada.
  Get-ChildItem $work -Filter '*.iso' -EA SilentlyContinue |
    Where-Object { $_.Name -notlike '*debloat*' } |
    Sort-Object Length -Descending | Select-Object -First 1 -ExpandProperty FullName
}

# ===========================================================================
#  APLICAR EL PERFIL A LAS VARIABLES GLOBALES QUE LEEN LAS FASES
# ===========================================================================
function Set-GlobalsFromProfile($p) {
  $Global:AppxRemove        = @(Get-Picked $p.appx)
  $Global:ServicesDisable   = @(Get-Picked $p.servicios)
  $Global:CapabilitiesRemove = @(Get-Picked $p.features | Where-Object { $_ -like 'cap:*' }  | ForEach-Object { $_ -replace '^cap:'  })
  $Global:FeaturesDisable   = @(Get-Picked $p.features | Where-Object { $_ -like 'feat:*' } | ForEach-Object { $_ -replace '^feat:' })
  foreach ($k in $p.flags.Keys) { $Global:Flags[$k] = [bool]$p.flags[$k] }
  $Global:PersonalizacionPicked = @(Get-Picked $p.personalizacion)
  $Global:AppsPicked            = @(Get-Picked $p.programas)
  $Global:UsuarioPerfil         = $p.usuario
}

# ===========================================================================
#  MENU PRINCIPAL
# ===========================================================================
function Show-MainMenu($p) {
  while ($true) {
    $nAppx = @(Get-Picked $p.appx).Count
    $nSvc  = @(Get-Picked $p.servicios).Count
    $nFeat = @(Get-Picked $p.features).Count
    $nPers = @(Get-Picked $p.personalizacion).Count
    $nApps = @(Get-Picked $p.programas).Count
    $nFlag = @(Get-Picked $p.flags).Count

    $perfilExiste = Test-Path $ProfilePath
    $sel = Show-TuiMenu -Subtitle "perfil: $(Split-Path $ProfilePath -Leaf)$(if(-not $perfilExiste){' (todavia no guardado)'})" -Entries @(
      @{ Key='appx';  Label='1. Apps preinstaladas a quitar';   Info="$nAppx marcadas"
         Note='Appx provisioned de la imagen. Las [BLINDADO] se muestran para que veas que se conserva y por que, pero no se pueden marcar.' }
      @{ Key='svc';   Label='2. Servicios a deshabilitar';      Info="$nSvc marcados"
         Note='Los "opcional" dependen de tu hardware y tu uso: lee la nota de cada uno antes de marcarlo. Regla: Manual > Disabled cuando dudes.' }
      @{ Key='feat';  Label='3. Features y capabilities';       Info="$nFeat marcadas"
         Note='Componentes opcionales de Windows (IE 11, WMP legacy, escritura a mano, Work Folders).' }
      @{ Key='flags'; Label='4. Opciones del sistema';          Info="$nFlag activas"
         Note='Telemetria, Copilot, Recall, OneDrive, cuenta local, Widgets y el bloqueo de Edge.' }
      @{ Key='pers';  Label='5. Personalizacion (tema, color)'; Info="$nPers marcadas"
         Note='Todo se aplica como DEFAULT, no como policy: son un punto de partida y los cambias desde Settings cuando quieras.' }
      @{ Key='apps';  Label='6. Programas a instalar';          Info="$nApps marcados"
         Note='Se instalan solos por winget en el primer arranque (hace falta internet). Los drivers de GPU no estan en winget: te deja la lista con las URLs.' }
      @{ Key='-' }
      @{ Key='gen';   Label='G. GENERAR LA ISO (guarda el perfil)'; Info='~45-60 min'; Accent=$true
         Note='GUARDA el perfil.json y arranca el pipeline completo: rearma la imagen desde la ISO original. No cierres la consola.' }
      @{ Key='save';  Label='S. Guardar perfil y salir';        Info='sin generar'
         Note='Escribe el perfil.json y sale sin tocar la imagen. Sirve para dejar la seleccion lista y generar despues, o para compartir tu perfil.' }
      @{ Key='-' }
      @{ Key='quit';  Label='Q. Salir sin guardar';             Info='descarta cambios'
         Note='Sale SIN escribir el perfil.json: se pierde lo que marcaste en esta sesion.' }
    )

    switch ($sel) {
      'appx' {
        $cat = @(Build-AppxCatalog)
        # Los blindados no entran a la lista editable: mostrarlos como marcables
        # seria ofrecer algo que el pipeline va a ignorar igual (guarda de AppxKeep).
        $editables = @($cat | Where-Object { -not $_.Locked })
        $locked    = @($cat | Where-Object { $_.Locked })
        [void](Show-TuiChecklist -Title '1. Apps preinstaladas a QUITAR de la imagen' `
               -Items ($editables + $locked) -Selected $p.appx `
               -Legend 'marcado = SE QUITA - los [BLINDADO] se ignoran siempre')
        foreach ($l in $locked) { $p.appx.Remove($l.Key) }
      }
      'svc'   { [void](Show-TuiChecklist -Title '2. Servicios a DESHABILITAR' -Items (Build-ServiceCatalog) -Selected $p.servicios -Legend 'marcado = Start=4 (Disabled)') }
      'feat'  { [void](Show-TuiChecklist -Title '3. Features y capabilities a QUITAR' -Items (Build-FeatureCatalog) -Selected $p.features -Legend 'marcado = se quita') }
      'flags' { [void](Show-TuiChecklist -Title '4. Opciones del sistema' -Items (Build-FlagCatalog) -Selected $p.flags -Legend 'marcado = activado') }
      'pers'  { [void](Show-TuiChecklist -Title '5. Personalizacion (todo reversible desde Settings)' -Items $PersonalizacionCatalog -Selected $p.personalizacion -Exclusive $PersonalizacionExclusivos -Legend 'default, NO policy: lo cambias cuando quieras') }
      'apps'  { [void](Show-TuiChecklist -Title '6. Programas a instalar en el primer arranque' -Items $AppCatalog -Selected $p.programas -Legend 'se instalan por winget al primer login') }
      'gen'   { return 'gen' }
      'save'  { return 'save' }
      'quit'  { return 'quit' }
      $null   { return 'quit' }
    }
  }
}

# ===========================================================================
#  PIPELINE
# ===========================================================================
function Invoke-Pipeline {
  $fases = @(
    @{ n='00-prepare-wim.ps1';    d='exportar Pro y montar el WIM' }
    @{ n='01-remove-appx.ps1';    d='quitar apps preinstaladas' }
    @{ n='02-remove-onedrive.ps1';d='OneDrive' }
    @{ n='03-privacy-policies.ps1'; d='privacidad y policies' }
    @{ n='04-services.ps1';       d='servicios' }
    @{ n='05-ui-tweaks.ps1';      d='tweaks de UI' }
    @{ n='06-features.ps1';       d='features y capabilities' }
    @{ n='07-remove-edge.ps1';    d='bloquear Edge' }
    @{ n='10-personalizar.ps1';   d='personalizacion (tema, color)' }
    @{ n='11-apps.ps1';           d='instalador de programas' }
    @{ n='08-inject-runtime.ps1'; d='SetupComplete + autounattend' }
    @{ n='09-build-iso.ps1';      d='cerrar WIM y armar la ISO' }
  )

  # ==========================================================================
  #  LOG A ARCHIVO. NO ES OPCIONAL.
  #  La primera version no logueaba nada: cuando el pipeline se corto, la ventana
  #  se cerro y se llevo el unico registro de lo que habia pasado. Un build de 45
  #  minutos que falla sin dejar rastro es imposible de diagnosticar, y el usuario
  #  se queda sin saber si tiene que empezar de nuevo.
  # ==========================================================================
  $logDir = Join-Path $root 'work\logs'
  New-Item -ItemType Directory -Force -Path $logDir | Out-Null
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $log   = Join-Path $logDir "build-$stamp.log"

  # --------------------------------------------------------------------------
  #  Start-Transcript y no un pipe, por dos razones concretas:
  #
  #  1) Las fases escriben con Write-Host, que va DIRECTO A LA CONSOLA y NO al
  #     pipeline. Un `& fase.ps1 | ForEach-Object { ... }` captura solo la salida
  #     de comandos nativos (dism, oscdimg) y se pierde justo lo que importa:
  #     "removido: X", "bloqueado: msedge.exe", "servicio protegido", etc.
  #     Con eso el log quedaba lleno de barras de progreso y sin informacion util.
  #  2) Transcript captura TODO el host, incluido lo que escriben las fases.
  # --------------------------------------------------------------------------
  try { Start-Transcript -Path $log -Force | Out-Null; $script:transcriptOn = $true }
  catch { $script:transcriptOn = $false; Write-Host "  ! no pude iniciar el log: $($_.Exception.Message)" -ForegroundColor Yellow }

  function LogLine($t, $color = 'Gray') { Write-Host $t -ForegroundColor $color }

  # ==========================================================================
  #  Y ACA VA EL OTRO ARREGLO: 'Continue', no 'Stop'.
  #  Con ErrorActionPreference='Stop' (el default de este script) CUALQUIER error
  #  no-terminante de una fase -- un stderr de dism, un warning -- se convierte en
  #  terminante, mata el proceso entero y la ventana se cierra sin mostrar nada.
  #  Las fases ya manejan sus propios errores y devuelven exit codes; el pipeline
  #  las evalua fase por fase con try/catch. Se restaura al salir.
  # ==========================================================================
  $prevEAP = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    Clear-Host
    LogLine ''
    LogLine '  Generando la ISO. Tarda entre 45 y 60 minutos.' 'Cyan'
    LogLine "  Log: $log" 'DarkGray'
    LogLine '  No cierres la consola.' 'DarkGray'
    LogLine ''
    $inicio = Get-Date
    $i = 0
    foreach ($f in $fases) {
      $i++
      $path = Join-Path $root "scripts\$($f.n)"
      if (-not (Test-Path $path)) { LogLine "  [$i/$($fases.Count)] (no existe, salteo) $($f.n)" 'DarkGray'; continue }
      $t0 = Get-Date
      LogLine ("  [{0}/{1}] {2} -- {3}" -f $i, $fases.Count, $f.n, $f.d) 'Cyan'
      $global:LASTEXITCODE = 0
      try {
        # Las barras de progreso de dism/oscdimg son miles de lineas que tapan todo
        # lo demas en el log. Se filtran: no aportan nada despues del build.
        & $path 2>&1 | Where-Object {
          $s = "$_"
          -not ($s -match '^\s*\[[=\s]*\d+\.?\d*%[=\s]*\]\s*$' -or
                $s -match '^\s*\d+%\s+complete\s*$' -or
                $s -match 'RemoteException')
        } | ForEach-Object { Write-Host "$_" }
      } catch {
        LogLine ''
        LogLine "  ================ FALLO EN $($f.n) ================" 'Red'
        LogLine "  $($_.Exception.Message)" 'Yellow'
        if ($_.InvocationInfo) {
          LogLine "  en $($_.InvocationInfo.ScriptName) linea $($_.InvocationInfo.ScriptLineNumber)" 'Yellow'
          LogLine "  codigo: $($_.InvocationInfo.Line.Trim())" 'DarkGray'
        }
        LogLine "  Log completo: $log" 'White'
        return $false
      }
      if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        LogLine ''
        LogLine "  ABORTADO en $($f.n) (exit $LASTEXITCODE)" 'Red'
        LogLine "  Log completo: $log" 'White'
        return $false
      }
      LogLine ("        ok ({0:mm\:ss})" -f ((Get-Date) - $t0)) 'DarkGreen'
    }
    LogLine ''
    LogLine ("  Pipeline completo en {0:hh\:mm\:ss}" -f ((Get-Date) - $inicio)) 'Green'
    $true
  }
  finally {
    $ErrorActionPreference = $prevEAP
    if ($script:transcriptOn) { try { Stop-Transcript | Out-Null } catch { } }
    $script:buildLog = $log
  }
}

# ===========================================================================
#  SELF-TEST -- valida la logica sin UI ni build
# ===========================================================================
# Existe porque una TUI no se puede testear con input automatizado, pero SI se
# puede testear todo lo que hay debajo: catalogos, perfil, y la traduccion a las
# variables globales que leen las fases. Ahi vive el 90% de los bugs posibles.
function Invoke-SelfTest {
  $fail = 0
  function Chk($name, $cond, $detail = '') {
    if ($cond) { Write-Host "  OK    $name" -ForegroundColor Green }
    else       { Write-Host "  FALLA $name $detail" -ForegroundColor Red; $script:fail++ }
  }
  $script:fail = 0
  Write-Host ''
  Write-Host '== SELF-TEST de LunaticOS ==' -ForegroundColor Cyan

  # --- Catalogos ---
  $appx = @(Build-AppxCatalog); $svc = @(Build-ServiceCatalog)
  $feat = @(Build-FeatureCatalog); $flg = @(Build-FlagCatalog)
  Chk "catalogo appx no vacio ($($appx.Count))"              ($appx.Count -gt 0)
  Chk "catalogo servicios no vacio ($($svc.Count))"          ($svc.Count -gt 0)
  Chk "catalogo features no vacio ($($feat.Count))"          ($feat.Count -gt 0)
  Chk "catalogo flags no vacio ($($flg.Count))"              ($flg.Count -gt 0)
  Chk "catalogo personalizacion no vacio ($($PersonalizacionCatalog.Count))" ($PersonalizacionCatalog.Count -gt 0)
  Chk "catalogo apps no vacio ($($AppCatalog.Count))"        ($AppCatalog.Count -gt 0)

  # --- Claves duplicadas: romperian el toggle (marcas una, se marca otra) ---
  foreach ($pair in @(@{n='appx';c=$appx}, @{n='servicios';c=$svc}, @{n='features';c=$feat},
                      @{n='flags';c=$flg}, @{n='personalizacion';c=$PersonalizacionCatalog},
                      @{n='apps';c=$AppCatalog})) {
    # OJO: `Group-Object Key` sobre HASHTABLES no agrupa por la clave del hashtable
    # -- un hashtable expone .Keys, no .Key, asi que todos caen en un grupo con Name
    # nulo y parecen duplicados. Hay que extraer los strings ANTES de agrupar.
    $dup = @($pair.c | ForEach-Object { $_.Key } | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name)
    Chk "sin claves duplicadas en $($pair.n)" ($dup.Count -eq 0) ("-> " + ($dup -join ', '))
  }

  # --- Todo item de la TUI necesita Name y Key, o la lista se ve vacia ---
  foreach ($pair in @(@{n='personalizacion';c=$PersonalizacionCatalog}, @{n='apps';c=$AppCatalog})) {
    $sinNombre = @($pair.c | Where-Object { -not $_.Name -or -not $_.Key })
    Chk "todos los items de $($pair.n) tienen Key y Name" ($sinNombre.Count -eq 0)
  }

  # --- Apps: coherencia de Src / Id / Url ---
  $sinId  = @($AppCatalog | Where-Object { $_.Src -in @('winget','msstore') -and -not $_.Id })
  Chk 'toda app winget/msstore tiene Id' ($sinId.Count -eq 0) ("-> " + (($sinId | ForEach-Object Key) -join ', '))
  $sinUrl = @($AppCatalog | Where-Object { $_.Src -eq 'manual' -and -not $_.Url })
  Chk 'toda app manual tiene Url' ($sinUrl.Count -eq 0) ("-> " + (($sinUrl | ForEach-Object Key) -join ', '))
  $srcMal = @($AppCatalog | Where-Object { $_.Src -notin @('winget','msstore','manual') })
  Chk 'ningun Src invalido' ($srcMal.Count -eq 0)

  # --- WebView2 NUNCA debe estar en la lista de bloqueo de Edge (rompe Store/Widgets) ---
  Chk 'msedgewebview2.exe NO esta bloqueado' ($EdgeBlockedExes -notcontains 'msedgewebview2.exe')

  # --- Personalizacion: nada debe escribir en Policies ---
  $pol = @()
  foreach ($it in $PersonalizacionCatalog) {
    foreach ($r in $it.Regs) { if ("$($r.k)" -like '*Policies*') { $pol += "$($it.Key) -> $($r.k)" } }
  }
  Chk 'personalizacion NO usa policies (no bloquea Settings)' ($pol.Count -eq 0) ("-> " + ($pol -join '; '))

  # --- Grupos excluyentes: las claves tienen que existir ---
  foreach ($grp in $PersonalizacionExclusivos) {
    foreach ($k in $grp) {
      Chk "clave excluyente '$k' existe en el catalogo" (@($PersonalizacionCatalog | Where-Object Key -eq $k).Count -eq 1)
    }
  }

  # ==========================================================================
  #  REGRESION: la checklist tiene que modificar el perfil POR REFERENCIA.
  #
  #  Este test existe por un bug real que llego al usuario: $Selected estaba
  #  declarado [hashtable] y el perfil es [ordered]@{}. PowerShell convertia el
  #  tipo, la conversion CREABA UNA COPIA, y todo lo que el usuario marcaba se
  #  perdia al volver al menu -- el perfil se guardaba con los valores de fabrica
  #  y la ISO salia con la config default. Sin sintomas, sin error, sin log.
  # ==========================================================================
  $tipoSel = (Get-Command Show-TuiChecklist).Parameters['Selected'].ParameterType
  Chk 'Show-TuiChecklist recibe $Selected SIN tipar (por referencia)' `
      ($tipoSel -eq [object]) "-> esta tipado como [$($tipoSel.Name)]: los cambios del usuario se van a PERDER"

  # Y la prueba funcional: un [ordered] modificado dentro de una funcion con la
  # misma firma tiene que verse cambiado afuera.
  $probe = [ordered]@{ x = $false }
  function Test-RefProbe($s) { $s['x'] = $true }
  Test-RefProbe $probe
  Chk 'un [ordered] se modifica por referencia' ($probe['x'] -eq $true)

  # ==========================================================================
  #  REGRESION: "elegir cero" tiene que ser distinto de "no hay perfil".
  #  Un array vacio es FALSY en PowerShell, asi que `if (-not $AppsPicked)` toma
  #  como "sin perfil" el caso en que el usuario desmarco TODO -- y le aplica los
  #  recomendados que acababa de rechazar. Paso de verdad: el perfil pedia 0
  #  programas y la fase 11 genero los 24 recomendados igual.
  # ==========================================================================
  $malFallback = @()
  foreach ($f in @('10-personalizar.ps1', '11-apps.ps1')) {
    $c = Get-Content (Join-Path $root "scripts\$f") -Raw -ErrorAction SilentlyContinue
    if ($c -and $c -match 'if\s*\(\s*-not\s+\$Global:(PersonalizacionPicked|AppsPicked)\s*\)') { $malFallback += $f }
  }
  Chk 'el fallback compara contra $null, no con -not (array vacio es falsy)' `
      ($malFallback.Count -eq 0) ("-> " + ($malFallback -join ', '))

  # ==========================================================================
  #  REGRESION: los colores de acento son ARGB y NO ENTRAN en Int32.
  #  0xFF14B8A6 = 4.279.415.974 y el maximo de Int32 es 2.147.483.647, asi que
  #  un [int] tira overflow y el valor no se escribe. Fallaba en silencio.
  # ==========================================================================
  $overflow = @()
  foreach ($it in $PersonalizacionCatalog) {
    foreach ($r in $it.Regs) {
      if ($r.t -eq 'sz') { continue }
      try { [void][uint32]$r.d } catch { $overflow += "$($it.Key)/$($r.v)" }
      if ([double]$r.d -gt 2147483647) {
        # Tiene que poder convertirse a uint32 sin perder nada: si el codigo usara
        # [int] aca, reventaria. El test verifica que el VALOR sea representable.
        try { [void][uint32]$r.d } catch { $overflow += "$($it.Key)/$($r.v) no entra en uint32" }
      }
    }
  }
  Chk 'todos los valores DWORD entran en uint32' ($overflow.Count -eq 0) ("-> " + ($overflow -join ', '))

  # ==========================================================================
  #  REGRESION: EL COLOR RESULTANTE, no el rango del entero.
  #
  #  El test de arriba (que un DWORD entre en uint32) daba VERDE con el acento
  #  ESCRITO AL REVES. Medir que un numero entre en su tipo no dice NADA sobre si
  #  el color es el que el usuario eligio.
  #
  #  El bug real: DWM\AccentColor es ABGR y ColorizationColor es ARGB, en la misma
  #  clave del registro. Se escribia ARGB en los dos, asi que el teal #14B8A6
  #  salia #A6B814 (verde lima) en la taskbar mientras otras partes de la UI si lo
  #  tomaban teal. La UI con dos colores a la vez: el "coloreado a la fuerza".
  #
  #  Estos tests miden el COLOR, y el ancla es un dato de fabrica verificable:
  #  el acento por defecto de Windows es AccentColor = 0xFFD77800 = #0078D7.
  #  Si la conversion se rompe, este numero deja de coincidir.
  # ==========================================================================
  $c = ConvertTo-AccentDwords '#14B8A6'
  Chk 'ConvertTo-AccentDwords: ABGR de #14B8A6 es 0xFFA6B814' `
      ($c.Abgr -eq [uint32]4289116180) ("-> dio 0x{0:X8}" -f $c.Abgr)
  Chk 'ConvertTo-AccentDwords: ARGB de #14B8A6 es 0xC414B8A6' `
      ($c.Argb -eq [uint32]3289692326) ("-> dio 0x{0:X8}" -f $c.Argb)
  Chk 'ConvertTo-AccentDwords: ThemeColor con formato de .theme' ($c.ThemeColor -eq '0XC414B8A6') "-> dio $($c.ThemeColor)"
  # El ancla de fabrica. Este es EL test que agarra una inversion de bytes.
  $azul = ConvertTo-AccentDwords '#0078D7'
  Chk 'el azul de fabrica de Windows da 0xFFD77800 (ancla contra inversion de bytes)' `
      ($azul.Abgr -eq [uint32]4292311040) ("-> dio 0x{0:X8}, la conversion esta invertida" -f $azul.Abgr)
  # Ida y vuelta: reinterpretar el ABGR como bytes tiene que devolver el hex original.
  $rt = @()
  foreach ($h in @('#14B8A6', '#8B5CF6', '#F59E0B', '#0078D7', '#000000', '#FFFFFF')) {
    $x = ConvertTo-AccentDwords $h
    $back = '#{0:X2}{1:X2}{2:X2}' -f ($x.Abgr -band 0xFF), (($x.Abgr -shr 8) -band 0xFF), (($x.Abgr -shr 16) -band 0xFF)
    if ($back -ne $h.ToUpperInvariant()) { $rt += "$h -> $back" }
  }
  Chk 'ida y vuelta del ABGR devuelve el mismo hex' ($rt.Count -eq 0) ("-> " + ($rt -join ', '))
  # Un color invalido tiene que TIRAR. Fallar en silencio es lo que nos costo una ISO.
  $tiro = $false
  try { ConvertTo-AccentDwords 'ZZZZZZ' | Out-Null } catch { $tiro = $true }
  Chk 'un color invalido tira error (no falla en silencio)' $tiro

  # --- Los items de acento declaran el color UNA vez, en hex, y sin Regs de color ---
  $malAcento = @()
  foreach ($it in $PersonalizacionCatalog) {
    if (-not $it.Accent) { continue }
    try { [void](ConvertTo-AccentDwords $it.Accent) } catch { $malAcento += "$($it.Key): $($_.Exception.Message)" }
    if ($it.Regs) { $malAcento += "$($it.Key) tiene Regs: el color lo aplica el .theme, no valores sueltos" }
  }
  Chk 'los acentos del catalogo son hex validos y sin Regs' ($malAcento.Count -eq 0) ("-> " + ($malAcento -join '; '))
  # Y que no vuelva a aparecer un DWORD de color escrito a mano en el catalogo.
  $litsColor = @(Select-String -Path (Join-Path $root 'config\personalizacion.ps1') `
                               -Pattern '0x[0-9A-Fa-f]{8}' -AllMatches)
  Chk 'el catalogo no tiene literales de color de 8 digitos' ($litsColor.Count -eq 0) `
      ("-> lineas: " + (($litsColor | ForEach-Object { $_.LineNumber }) -join ', '))

  # ==========================================================================
  #  REGRESION: matar explorer en el primer login deja el escritorio SIN SHELL.
  #  Es el issue #329 de cschneegans/unattend-generator, y teniamos el mismo
  #  codigo: Stop-Process explorer + Start-Sleep + un if. En el primer login el
  #  shell NO respawnea solo, y el usuario se queda con una pantalla gris.
  #  Se mide la CLASE: si aparece un Stop-Process de explorer, TIENE que haber un
  #  bucle de relanzamiento en el mismo archivo.
  # ==========================================================================
  # ==========================================================================
  #  LEER EL CODIGO, NO LOS COMENTARIOS. Y NO ES UN DETALLE DE ESTILO.
  #
  #  scripts\10-personalizar.ps1 NOMBRA A PROPOSITO, en sus comentarios, cada bug
  #  medido y cada tecnica descartada: 'InstallThemeDark', 'dark.theme',
  #  'New-Item -Force', '/Action:OpenTheme', 'AutoColorization=1', 'uxtheme.dll'.
  #  Esa evidencia documental SE QUEDA -- es la mitad del valor del archivo.
  #
  #  CONSECUENCIA: un test que grepea el archivo CRUDO da VERDE con el bug puesto,
  #  porque el comentario que explica el bug le hace de coartada. Eso ya paso en
  #  este repo y es la razon por la que existe esta seccion.
  #
  #  Get-CodeOnly saca los bloques <# #> y toda linea cuyo primer caracter no-blanco
  #  sea '#' o '//'. Lo que queda es ESCRITURA DE CODIGO.
  #  Get-HereStringBodies devuelve el texto de los here-string @'...'@, que es
  #  literalmente el script del primer login: asi se lo puede auditar sin generarlo.
  # ==========================================================================
  function Get-CodeOnly([string]$Text) {
    $t = [regex]::Replace("$Text", '(?s)<#.*?#>', '')
    $keep = New-Object System.Collections.Generic.List[string]
    foreach ($l in ($t -split "`r?`n")) {
      $tr = "$l".TrimStart()
      if ($tr.StartsWith('#') -or $tr.StartsWith('//')) { continue }
      $keep.Add("$l")
    }
    return ($keep -join "`n")
  }
  function Get-HereStringBodies([string]$Text) {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches("$Text", "(?s)@'\r?\n(.*?)\r?\n'@")) { $out.Add($m.Groups[1].Value) }
    return ($out -join "`n")
  }

  $f10 = Get-Content (Join-Path $root 'scripts\10-personalizar.ps1') -Raw
  $f10Code = Get-CodeOnly $f10            # la fase, SIN comentarios (los de los dos niveles)
  $genRaw  = Get-HereStringBodies $f10    # el texto del script del primer login
  $genCode = Get-CodeOnly $genRaw         # ...y ese, sin SUS comentarios
  # Si la extraccion falla, TODO lo que viene abajo daria verde por vacio. Eso seria
  # el peor de los mundos: un instrumento roto que informa exito. Se mide primero.
  Chk 'pude aislar el CODIGO de la fase 10 (sin comentarios)' ($f10Code.Length -gt 4000) `
      "-> quedaron $($f10Code.Length) chars: la extraccion se rompio y los tests de abajo no miden nada"
  Chk 'pude aislar el script del PRIMER LOGIN de los here-string' ($genCode.Length -gt 2000) `
      "-> quedaron $($genCode.Length) chars: sin el texto generado, los tests del apply no miden nada"

  $mata    = $f10 -match "Stop-Process[^\r\n]*explorer"
  $relanza = $f10 -match "(?s)Stop-Process[^\r\n]*explorer.{0,600}?(for|while)\s*\("
  Chk 'si la fase 10 mata explorer, tiene bucle de relanzamiento' `
      ((-not $mata) -or $relanza) '-> mata explorer sin garantizar que vuelva (issue #329)'
  Chk 'la fase 10 refresca con el broadcast ImmersiveColorSet' ($f10 -match 'ImmersiveColorSet')

  # ==========================================================================
  #  SON TRES CLAVES, NO DOS: InstallThemeDark ERA EL BUG (contrato 2.5).
  #
  #  Al crear el perfil, Windows APLICA un tema, y cual lo dicen TRES valores:
  #      InstallTheme       rama generica
  #      InstallThemeDark   <-- esta NO se escribia
  #      InstallThemeLight
  #  x DOS ramas del hive (Themes y WOW6432Node) = 6 valores.
  #
  #  MEDIDO en la VM del build 2026-07-29 20:32: el hive DEFAULT ya traia
  #  AppsUseLightTheme=0, asi que Windows entro por la rama DARK, aplico el
  #  dark.theme DE FABRICA (ColorizationColor=0XC40078D4, el azul) y nuestro tema
  #  parecio ignorado. No se ignoro: SE APLICO OTRO.
  #
  #  EL TEST MIDE LA CLASE, no la clave que nos mordio: pide las TRES por separado
  #  y nombra la que falte. El test viejo pedia dos y daba verde con el bug puesto.
  #  Y corre sobre $f10Code: el archivo NOMBRA InstallThemeDark en sus comentarios,
  #  asi que un grep crudo pasaria igual con la escritura borrada.
  # ==========================================================================
  $itNames = @([regex]::Matches($f10Code, '/v\s+(InstallTheme\w*)') |
                 ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
  foreach ($n in @('InstallTheme', 'InstallThemeDark', 'InstallThemeLight')) {
    Chk "la fase 10 ESCRIBE $n (codigo, no comentario)" ($itNames -contains $n) `
        "-> por esa rama Windows aplica su tema DE FABRICA y vuelve el color de fabrica, EN SILENCIO"
  }
  $itRamas = @([regex]::Matches($f10Code, "'((?:WOW6432Node\\)?Microsoft\\Windows\\CurrentVersion\\Themes)'") |
                 ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
  Chk 'la fase 10 cubre las DOS ramas del hive (Themes y WOW6432Node)' ($itRamas.Count -eq 2) `
      ("-> ramas vistas: " + ($itRamas -join ', '))
  Chk 'InstallTheme* x ramas = 6 valores' (($itNames.Count * $itRamas.Count) -ge 6) `
      "-> $($itNames.Count) claves x $($itRamas.Count) ramas = $($itNames.Count * $itRamas.Count), y son 6"
  # Y las TRES tienen que escribirse SOBRE LA MISMA RUTA BASE. Si una queda afuera del
  # loop de ramas, su clave pasa a ser otra expresion: se escribe en UNA sola rama y el
  # bug vuelve a ser silencioso. Esto se mide comparando las expresiones, no contando
  # lineas ni midiendo distancias en el archivo (eso se rompe al reordenar el codigo).
  $itKeyExprs = @([regex]::Matches($f10Code, 'add\s+(\S+)\s+/v\s+InstallTheme\w*\b') |
                    ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
  Chk 'las tres InstallTheme* se escriben sobre la MISMA ruta base' ($itKeyExprs.Count -eq 1) `
      ("-> rutas distintas: " + ($itKeyExprs -join ' , ') + "  == alguna se escribe en UNA sola rama")
  Chk 'la rama de InstallTheme* la aporta una VARIABLE (el loop), no una ruta hardcodeada' `
      (($itKeyExprs.Count -eq 1) -and ($itKeyExprs[0] -match '\$\w+\\\$\w+')) `
      ("-> la ruta es " + ($itKeyExprs -join ' , ') + ": si es fija, solo cubre una de las dos ramas")
  # Ninguna puede apuntar a un tema de fabrica: ahi esta el azul.
  $itFabrica = @()
  foreach ($m in [regex]::Matches($f10Code, '/v\s+(InstallTheme\w*)[^\r\n]*?/d\s+(\S+)')) {
    if ($m.Groups[2].Value -match '(?i)(aero|dark)\.theme') {
      $itFabrica += ("{0} -> {1}" -f $m.Groups[1].Value, $m.Groups[2].Value)
    }
  }
  Chk 'ninguna clave InstallTheme* apunta a un .theme de fabrica' ($itFabrica.Count -eq 0) `
      ("-> " + ($itFabrica -join ', '))

  # Y el .theme generado tiene que ser un .theme de verdad. Se pide a la funcion real.
  . (Join-Path $root 'scripts\10-personalizar.ps1')
  if (-not (Get-Command New-LunaticOSTheme -ErrorAction SilentlyContinue)) {
    Chk 'la fase 10 expone New-LunaticOSTheme para poder testearla' $false
  } else {
    $th = New-LunaticOSTheme -Mode 'Dark' -ThemeColor $c.ThemeColor -WallpaperName 'x.jpg'
    Chk '.theme: seccion [Theme]'        ($th -match '(?m)^\[Theme\]')
    Chk '.theme: seccion [VisualStyles]' ($th -match '(?m)^\[VisualStyles\]')
    # El \r? del final NO es decorativo: el .theme se escribe con CRLF (es lo que
    # usan los .theme de Windows), y en .NET el '$' de multiline matchea ANTES del
    # \n pero DESPUES del \r, asi que '^SystemMode=Dark$' no matchea nunca sobre
    # CRLF. Sin el \r? estos dos tests fallan con el .theme perfectamente bien.
    Chk '.theme: SystemMode y AppMode en Dark|Light' `
        (($th -match '(?m)^SystemMode=(Dark|Light)\r?$') -and ($th -match '(?m)^AppMode=(Dark|Light)\r?$'))
    Chk '.theme: ColorizationColor con formato 0X + 8 hex' ($th -match '(?m)^ColorizationColor=0X[0-9A-F]{8}\r?$')
    Chk '.theme: el color es el pedido (ARGB)' ($th -match [regex]::Escape("ColorizationColor=$($c.ThemeColor)"))
    Chk '.theme: es ASCII puro' (([regex]::Matches($th, '[^\x00-\x7F]')).Count -eq 0)
    # Sin tema, sin color y sin wallpaper NO se genera nada: no hay que tocar
    # InstallTheme para no romper el default de Windows sin motivo.
    Chk '.theme: sin nada elegido no se genera' ($null -eq (New-LunaticOSTheme))

    # ========================================================================
    #  EL .theme SIEMPRE TRAE UNA LINEA Wallpaper= (contrato 2.10-A).
    #
    #  BISECADO byte a byte en Win11 22631 contra AddAndSelectTheme:
    #      sin seccion [Control Panel\Desktop]      -> hr=0x80004005  E_FAIL
    #      seccion presente pero vacia              -> hr=0x80004005  E_FAIL
    #      seccion con solo Pattern=                -> hr=0x80004005  E_FAIL
    #      seccion con Wallpaper= (valor VACIO)     -> hr=0x00000000  OK
    #  Sin esa clave el motor de temas RECHAZA el archivo entero: no aplica NI el
    #  modo NI el color. Y la version anterior omitia la seccion completa cuando no
    #  habia wallpaper propio -- QUE ES EL CASO POR DEFECTO DEL PROYECTO. O sea que
    #  el apply fallaba SIEMPRE, con un E_FAIL que nadie miraba.
    #
    #  Se piden LOS CUATRO casos, no el que nos mordio: la clase es "cualquier
    #  combinacion que genere contenido tiene que traer la seccion y la linea".
    # ========================================================================
    $casosTheme = @(
      @{ n = 'oscuro + acento + wallpaper propio'; a = @{ Mode = 'Dark'; ThemeColor = $c.ThemeColor; WallpaperName = 'fondo.jpg' } }
      @{ n = 'oscuro SIN wallpaper propio';        a = @{ Mode = 'Dark'; ThemeColor = $c.ThemeColor } }
      @{ n = 'solo acento (sin modo elegido)';     a = @{ ThemeColor = $c.ThemeColor } }
      @{ n = 'nada elegido';                       a = @{} }
    )
    $conContenido = @(); $sinSeccion = @(); $sinWallpaper = @(); $wallpaperVacio = @()
    foreach ($caso in $casosTheme) {
      $sp = $caso.a
      $tc = New-LunaticOSTheme @sp
      if ($null -eq $tc) { continue }
      $conContenido += $caso.n
      if ($tc -notmatch '(?m)^\[Control Panel\\Desktop\]\r?$') { $sinSeccion += $caso.n }
      $mw = [regex]::Match($tc, '(?m)^Wallpaper=(.*?)\r?$')
      if (-not $mw.Success) { $sinWallpaper += $caso.n }
      elseif (-not $mw.Groups[1].Value.Trim()) { $wallpaperVacio += $caso.n }
    }
    Chk '.theme: los 3 casos con contenido lo generan (y "nada elegido" no)' ($conContenido.Count -eq 3) `
        ("-> generaron contenido: " + ($conContenido -join ' | '))
    Chk '.theme: TODOS los casos traen la seccion [Control Panel\Desktop]' ($sinSeccion.Count -eq 0) `
        ("-> sin seccion: " + ($sinSeccion -join ' | ') + "  == AddAndSelectTheme devuelve E_FAIL 0x80004005")
    Chk '.theme: TODOS los casos traen una linea Wallpaper=' ($sinWallpaper.Count -eq 0) `
        ("-> sin Wallpaper=: " + ($sinWallpaper -join ' | ') + "  == el motor de temas RECHAZA el archivo entero")
    Chk '.theme: la linea Wallpaper= nunca queda vacia' ($wallpaperVacio.Count -eq 0) `
        ("-> vacia en: " + ($wallpaperVacio -join ' | ') + "  == escritorio en NEGRO cuando Windows aplica el tema al crear el perfil")

    # ========================================================================
    #  AutoColorization=0 ES OBLIGATORIO con acento (contrato 2.6).
    #  Sin eso Windows recalcula el acento A PARTIR DEL WALLPAPER y pisa el color
    #  elegido -- que es exactamente el dano colateral del truco del alto contraste.
    # ========================================================================
    $thAcc = New-LunaticOSTheme -Mode 'Dark' -ThemeColor $c.ThemeColor
    $thSin = New-LunaticOSTheme -Mode 'Dark'
    Chk '.theme: con acento trae AutoColorization=0' ($thAcc -match '(?m)^AutoColorization=0\r?$') `
        '-> sin eso Windows recalcula el acento desde el wallpaper y pisa el color elegido'
    Chk '.theme: NUNCA trae AutoColorization=1' `
        (($thAcc -notmatch 'AutoColorization\s*=\s*1') -and ($thSin -notmatch 'AutoColorization\s*=\s*1'))
    Chk '.theme: sin acento no declara ColorizationColor (Windows usa su default)' `
        ($thSin -notmatch '(?m)^ColorizationColor=')

    # ========================================================================
    #  ThemeId: GUID NUEVO en cada llamada (contrato 2.6, trampa del no-op).
    #  Si el .theme que se aplica es "el mismo" que el vigente, Windows NO HACE NADA
    #  y devuelve hr=0. Un codigo de retorno que miente es lo peor que nos puede
    #  pasar: los dos builds fallidos se veian igual de exitosos en el log.
    # ========================================================================
    $ta = New-LunaticOSTheme -Mode 'Dark' -ThemeColor $c.ThemeColor
    $tb = New-LunaticOSTheme -Mode 'Dark' -ThemeColor $c.ThemeColor
    $secTheme = [regex]::Match($ta, "(?s)\[Theme\]\r?\n(.*?)(?:\r?\n\[|$)").Groups[1].Value
    Chk '.theme: ThemeId esta DENTRO de la seccion [Theme]' `
        ($secTheme -match '(?m)^ThemeId=\{[0-9A-F-]{36}\}\r?$') "-> [Theme] dice: $($secTheme -replace "`r`n", ' / ')"
    $ida = [regex]::Match($ta, 'ThemeId=(\{[^\}]+\})').Groups[1].Value
    $idb = [regex]::Match($tb, 'ThemeId=(\{[^\}]+\})').Groups[1].Value
    Chk '.theme: el ThemeId CAMBIA entre dos llamadas (el no-op de Windows es real)' `
        ($ida -and $idb -and ($ida -ne $idb)) "-> las dos llamadas dieron ${ida}: el segundo apply seria un no-op con hr=0"
  }

  # ==========================================================================
  #  NINGUN New-Item -Force PELADO SOBRE EL REGISTRO (contrato 2.10-B).
  #
  #  BUG REAL, medido, y estuvo ACTIVO en cada ISO: New-Item -Path <clave> -Force
  #  sobre una clave QUE YA EXISTE la RECREA, o sea le BORRA TODOS LOS VALORES.
  #  Comprobado: clave con 2 valores -> queda vacia.
  #  Que hacia eso: el item 'acento-en-taskbar' (ColorPrevalence) recreaba
  #  Themes\Personalize y se comia el AppsUseLightTheme y el SystemUsesLightTheme
  #  que acababa de escribir 'tema-oscuro'. Y UN VALOR AUSENTE SIGNIFICA CLARO:
  #  nuestro propio RunOnce apagaba el modo oscuro.
  #
  #  SE MIDE LA CLASE: cualquier New-Item con -Force que no sea del filesystem
  #  (-ItemType Directory/File) y que no este guardado por un Test-Path en la misma
  #  linea. No la linea exacta que arreglamos -- el bug de la vuelta pasada fue
  #  justo ese: arreglar una instancia y dejar la otra cinco lineas mas abajo.
  #  El scan cubre la fase Y el script generado: $f10Code contiene los dos.
  # ==========================================================================
  $niMal = @()
  foreach ($m in [regex]::Matches($f10Code, '(?m)^[^\r\n]*New-Item[^\r\n]*$')) {
    $l = "$($m.Value)"
    if ($l -notmatch '-Force') { continue }
    if ($l -match '-ItemType\s+(Directory|File)') { continue }   # filesystem, no registro
    if ($l -match 'Test-Path') { continue }                      # guardado: crea SOLO si falta
    $niMal += $l.Trim()
  }
  Chk 'ningun New-Item -Force sobre el registro sin guarda de Test-Path' ($niMal.Count -eq 0) `
      ("-> " + ($niMal -join ' || ') + "  == le BORRA TODOS LOS VALORES a la clave si ya existe")

  # ==========================================================================
  #  EL APPLY DEL TEMA, EN EL SCRIPT GENERADO (contrato 2.6 y 2.10-D).
  #
  #  InstallTheme* es necesario pero NO suficiente: escribir valores no aplica nada.
  #  Quien traduce registro -> colores es el motor de temas, y solo corre cuando se
  #  APLICA un tema. El metodo esta MEDIDO: hr=0, 856 ms, no abre Settings.
  #
  #  [PreserveSig] no es cosmetico: sin eso un E_FAIL real llega como COMException,
  #  el hr logueado queda en 0xFFFFFFFF y EL LOG MIENTE justo donde mas importa.
  # ==========================================================================
  Chk 'primer login: CLSID de IThemeManager2 (9324da94-...)' `
      ($genCode -match '(?i)9324da94-50ec-4a14-a770-e90ca03e7c8f')
  Chk 'primer login: IID de IThemeManager2 (c1e8c83e-...)' `
      ($genCode -match '(?i)c1e8c83e-845d-4d95-81db-e283fdffc000')
  Chk 'primer login: LLAMA a AddAndSelectTheme (no SetCurrentTheme, que matchea un nombre localizado)' `
      ($genCode -match '\.AddAndSelectTheme\s*\(')
  Chk 'primer login: AddAndSelectTheme declarado con [PreserveSig]' `
      ($genCode -match '(?m)^[^\r\n]*\[PreserveSig\][^\r\n]*\bAddAndSelectTheme\b') `
      '-> sin PreserveSig un E_FAIL real se loguea como 0xFFFFFFFF y EL LOG MIENTE'
  Chk 'primer login: Init declarado con [PreserveSig]' `
      ($genCode -match '(?m)^[^\r\n]*\[PreserveSig\][^\r\n]*\bInit\s*\(') `
      '-> el log imprime el hr del Init: sin PreserveSig ese numero es inventado'
  Chk 'primer login: el apply corre en un thread STA (el objeto COM lo EXIGE)' `
      ($genCode -match 'SetApartmentState\s*\(\s*(\[?ApartmentState\]?::|ApartmentState\.)STA')
  Chk 'primer login: reintenta con un ThemeId nuevo generado en runtime (el no-op es por VALOR)' `
      ($genCode -match '(?s)ThemeId.{0,300}NewGuid|NewGuid.{0,300}ThemeId')
  Chk 'primer login: VERIFICA el resultado contra el registro y no solo el hr' `
      ($genCode -match '(?s)hr\s*-eq\s*0.{0,120}-not\s+\$?\w*[Oo]k|LunaticVerify')

  # --- Las tecnicas DESCARTADAS CON EVIDENCIA no pueden reaparecer -----------
  # Los comentarios de la fase 10 las nombran a proposito (es la evidencia de por que
  # no se usan), asi que esto corre sobre $f10Code. Un grep crudo daria falso positivo:
  # ya paso, y es exactamente el tipo de test que miente.
  $descartadas = @(
    @{ n = 'rundll32 desk.cpl /Action:OpenTheme -- IGNORA el flag silencioso y ABRE la UI'
       rx = '(?i)Action\s*:\s*OpenTheme' }
    @{ n = 'una llamada a ITheme::OpenTheme -- lo mismo: abre Settings'
       rx = '\.OpenTheme\s*\(' }
    @{ n = 'el truco del alto contraste -- pone AutoColorization=1 y recalcula el acento desde el wallpaper'
       rx = '(?i)highcontrast|hc(white|black|1|2)\.theme|Ease of Access' }
    @{ n = 'AutoColorization=1 -- Windows recalcula el acento desde el wallpaper y pisa el elegido'
       rx = 'AutoColorization\s*=\s*1' }
    @{ n = 'ordinales no documentados de uxtheme.dll -- MEDIDO: el mapeo que circula no se sostiene en 22631'
       rx = '(?i)uxtheme' }
  )
  $usadas = @()
  foreach ($t in $descartadas) { if ($f10Code -match $t.rx) { $usadas += $t.n } }
  Chk 'la fase 10 no usa ninguna de las tecnicas descartadas con evidencia' ($usadas.Count -eq 0) `
      ("-> " + ($usadas -join ' || '))

  # ==========================================================================
  #  AccentPalette: NO SE DERIVA CON UNA FORMULA (contrato 1.2 y 2.8).
  #
  #  No hay algoritmo publicado exacto para los 8 tonos, y el escalado lineal en RGB
  #  que haciamos daba colores QUEMADOS que no coincidian con los que genera
  #  Settings. Prueba de que ninguna formula de escalado puede estar bien: el idx 7
  #  no es un tono del acento, es un color de enfasis aparte (#107C10 verde para un
  #  gris, #881798 violeta para el teal).
  #
  #  Lo unico permitido: sobreescribir los bytes del INDICE BASE (12,13,14) de la
  #  paleta que el motor de temas acaba de generar. Se mide la clase: cualquier
  #  indice calculado, cualquier bucle sobre la paleta y cualquier factor de escala.
  # ==========================================================================
  $palBloque = ''
  foreach ($b in [regex]::Matches($f10, "(?s)@'\r?\n(.*?)\r?\n'@")) {
    if ($b.Groups[1].Value -match 'AccentPalette') { $palBloque += (Get-CodeOnly $b.Groups[1].Value) + "`n" }
  }
  Chk 'encontre el bloque de codigo que escribe AccentPalette' ($palBloque -match 'AccentPalette') `
      '-> sin el bloque, los tres tests de abajo no miden nada'
  $idxMal = @(); $idxCalc = @()
  foreach ($m in [regex]::Matches($palBloque, '(\$\w+)\[([^\]]+)\]\s*=[^=]')) {
    $i = $m.Groups[2].Value.Trim()
    if ($i -notmatch '^\d+$') { $idxCalc += ("{0}[{1}]" -f $m.Groups[1].Value, $i); continue }
    if (@('12', '13', '14') -notcontains $i) { $idxMal += ("{0}[{1}]" -f $m.Groups[1].Value, $i) }
  }
  Chk 'AccentPalette: solo se escriben los bytes del indice BASE (12,13,14)' ($idxMal.Count -eq 0) `
      ("-> tambien escribe " + ($idxMal -join ', ') + ": eso es inventar tonos")
  Chk 'AccentPalette: ni un indice CALCULADO (un indice variable es un bucle, o sea una formula)' `
      ($idxCalc.Count -eq 0) ("-> " + ($idxCalc -join ', '))
  $factores = @([regex]::Matches($palBloque, '\d*\.\d+') | ForEach-Object { $_.Value } | Sort-Object -Unique)
  Chk 'AccentPalette: ni un factor de escala (el escalado lineal en RGB da colores quemados)' `
      ($factores.Count -eq 0) ("-> factores: " + ($factores -join ', '))
  Chk 'AccentPalette: no hay bucle que recorra los 8 tonos' `
      ($palBloque -notmatch '(?i)\b(for|foreach)\s*\(|ForEach-Object') `
      '-> un bucle sobre la paleta solo puede ser una formula: no existe una publicada'

  # ==========================================================================
  #  NINGUNA fase escribe lo que bloquea Settings (contrato, seccion 5.1).
  #  Se mide la CLASE, no la lista: cualquier policy bajo una rama Personalization
  #  o con nombre NoDisp*/NoChanging*/NoThemes* deja al usuario sin poder cambiar
  #  su propia PC, que es exactamente lo contrario del objetivo del proyecto.
  # ==========================================================================
  $bloqueantes = @()
  $archivos = @(Get-ChildItem (Join-Path $root 'scripts') -Filter '*.ps1' -File) +
              @(Get-ChildItem (Join-Path $root 'config')  -Filter '*.ps1' -File)
  foreach ($a in $archivos) {
    # test-vm.ps1 y 10-personalizar.ps1 las NOMBRAN a proposito: una para auditarlas
    # y la otra para BORRARLAS. Lo que se busca es escritura: 'reg add ... /v NoX'.
    $txt = Get-Content $a.FullName -Raw
    foreach ($m in [regex]::Matches($txt, '(?m)add\s+"?[^"\r\n]*?(Policies\\Microsoft\\Windows\\Personalization|PersonalizationCSP)[^"\r\n]*"?')) {
      $bloqueantes += "$($a.Name): $($m.Value.Trim())"
    }
    foreach ($m in [regex]::Matches($txt, '(?m)add\s+[^\r\n]*?/v\s+(NoDispCPL|NoDispAppearancePage|NoDispBackgroundPage|NoColorChoice|NoThemesTab|SetVisualStyle|NoChangingWallpaper|NoChangingWallPaper)\b')) {
      $bloqueantes += "$($a.Name): $($m.Value.Trim())"
    }
  }
  Chk 'ninguna fase escribe policies que bloqueen Personalization' ($bloqueantes.Count -eq 0) `
      ("-> " + ($bloqueantes -join ' | '))
  Chk 'la fase 10 BORRA las policies bloqueantes de la imagen' `
      ($f10 -match 'PersonalizationCSP' -and $f10 -match 'delete')

  # ==========================================================================
  #  Las policies de privacidad estan partidas: las que ensucian Settings son opt-in.
  # ==========================================================================
  . (Join-Path $root 'scripts\03-privacy-policies.ps1')
  if (Get-Command Get-PrivacyPolicies -ErrorAction SilentlyContinue) {
    $sinB = @(Get-PrivacyPolicies -BlockCloudContent $false -DisableLocation $false)
    $conB = @(Get-PrivacyPolicies -BlockCloudContent $true  -DisableLocation $false)
    Chk 'sin BlockCloudContent no se escribe ninguna policy de CloudContent' `
        (@($sinB | Where-Object { $_.k -like '*CloudContent*' }).Count -eq 0)
    Chk 'con BlockCloudContent se escriben las 3 de CloudContent' `
        (@($conB | Where-Object { $_.k -like '*CloudContent*' }).Count -eq 3)
    # Un flag que no se consulta promete control y miente: DisableLocation se
    # escribia SIEMPRE, incluso desmarcado, y bloqueaba el panel de Ubicacion.
    Chk 'DisableLocation respeta su flag (no se escribe si esta desmarcado)' `
        (@($sinB | Where-Object { $_.v -eq 'DisableLocation' }).Count -eq 0)
    Chk 'DisableLocation se escribe cuando SI esta marcado' `
        (@(Get-PrivacyPolicies -DisableLocation $true | Where-Object { $_.v -eq 'DisableLocation' }).Count -eq 1)
    # El flag tiene que existir en la TUI, o nadie puede activarlo nunca.
    Chk 'el flag BlockCloudContent existe en el catalogo de la TUI' `
        (@(Build-FlagCatalog | Where-Object Key -eq 'BlockCloudContent').Count -eq 1)
  } else {
    Chk 'la fase 03 expone Get-PrivacyPolicies para poder testearla' $false
  }

  # ==========================================================================
  #  Los .ps1 tienen que ser ASCII puro: PowerShell 5.1 lee los .ps1 sin BOM como
  #  ANSI, y cualquier caracter no-ASCII sale como basura en la consola. En un
  #  comentario es cosmetico; en un string que se imprime, lo ve el usuario.
  # ==========================================================================
  $noAscii = @()
  $todos = @($archivos) + @(Get-Item (Join-Path $root 'LunaticOS.ps1')) +
           @(Get-ChildItem (Join-Path $root 'herramientas') -Filter '*.ps1' -File -EA SilentlyContinue)
  foreach ($a in $todos) {
    $n = ([regex]::Matches((Get-Content $a.FullName -Raw), '[^\x00-\x7F]')).Count
    if ($n -gt 0) { $noAscii += "$($a.Name) ($n)" }
  }
  Chk 'todos los .ps1 son ASCII puro' ($noAscii.Count -eq 0) ("-> " + ($noAscii -join ', '))
  # El test NO busca la firma exacta de un bug conocido, busca EL PATRON: cualquier
  # cast de $r.d a [int]. La version anterior buscaba solo '[string][int]$r.d' y se
  # le escapo un segundo '[int]$r.d' cinco lineas mas abajo, en el generador del
  # script de runtime. Arregle una instancia, deje la otra, y el test dio verde.
  # Cuando un bug es de CLASE, el test tiene que medir la clase.
  $castsInt = @(Select-String -Path (Join-Path $root 'scripts\10-personalizar.ps1') `
                              -Pattern '\[int\]\s*\$r\.d' -AllMatches)
  Chk 'la fase 10 nunca castea $r.d a [int] (usa uint32)' ($castsInt.Count -eq 0) `
      ("-> lineas: " + (($castsInt | ForEach-Object { $_.LineNumber }) -join ', '))

  # --- Perfil: ida y vuelta por JSON ---
  $p = New-DefaultProfile
  Chk 'perfil default se genera' ($null -ne $p)
  $tmp = Join-Path $env:TEMP 'lunaticos-selftest.json'
  Export-Profile $p $tmp '1999-01-01 00:00'
  $p2 = Import-Profile $tmp
  Chk 'perfil se guarda y se relee' ($null -ne $p2)
  Chk 'la cantidad de appx sobrevive el round-trip'   ($p.appx.Count -eq $p2.appx.Count)
  Chk 'la cantidad de programas sobrevive el round-trip' ($p.programas.Count -eq $p2.programas.Count)

  # --- Perfil viejo (le faltan claves): NO debe romper ---
  '{ "version":1, "flags": { "RemoveOneDrive": false } }' | Set-Content $tmp -Encoding UTF8
  $p3 = Import-Profile $tmp
  Chk 'un perfil incompleto no rompe (rellena con defaults)' ($null -ne $p3 -and $p3.appx.Count -gt 0)
  Chk 'y respeta lo que si trae' ($p3.flags['RemoveOneDrive'] -eq $false)

  # --- Perfil corrupto: tampoco debe romper ---
  'esto no es json {{{' | Set-Content $tmp -Encoding UTF8
  $p4 = Import-Profile $tmp
  Chk 'un perfil corrupto se ignora sin explotar' ($null -eq $p4)
  Remove-Item $tmp -Force -EA SilentlyContinue

  # --- Traduccion a las variables que leen las fases ---
  Set-GlobalsFromProfile $p
  Chk 'AppxRemove poblado desde el perfil'        (@($Global:AppxRemove).Count -gt 0)
  Chk 'ServicesDisable poblado desde el perfil'   (@($Global:ServicesDisable).Count -gt 0)
  Chk 'CapabilitiesRemove sin prefijo "cap:"'     (-not (@($Global:CapabilitiesRemove) -match '^cap:'))
  Chk 'FeaturesDisable sin prefijo "feat:"'       (-not (@($Global:FeaturesDisable) -match '^feat:'))
  Chk 'AppsPicked poblado'                        (@($Global:AppsPicked).Count -gt 0)

  # --- Los blindados NO deben poder salir en AppxRemove ---
  $leak = @($Global:AppxRemove | Where-Object { $AppxKeep -contains $_ })
  Chk 'ningun appx BLINDADO en la lista de remocion' ($leak.Count -eq 0) ("-> " + ($leak -join ', '))

  # --- Las fases que el pipeline invoca tienen que existir ---
  foreach ($f in @('00-prepare-wim.ps1','01-remove-appx.ps1','02-remove-onedrive.ps1',
                   '03-privacy-policies.ps1','04-services.ps1','05-ui-tweaks.ps1',
                   '06-features.ps1','07-remove-edge.ps1','10-personalizar.ps1',
                   '11-apps.ps1','08-inject-runtime.ps1','09-build-iso.ps1')) {
    Chk "existe scripts\$f" (Test-Path (Join-Path $root "scripts\$f"))
  }

  Write-Host ''
  if ($script:fail -eq 0) { Write-Host "  TODO OK (0 fallas)" -ForegroundColor Green }
  else { Write-Host "  $($script:fail) FALLAS" -ForegroundColor Red }
}

if ($SelfTest) {
  # OJO: NO usar `exit (Invoke-SelfTest)`. Cualquier cosa que una funcion emita al
  # pipeline se suma a su valor de retorno, asi que el "0" final puede llegar como
  # array y el exit code termina siendo otro. Reportaba TODO OK y salia con 1.
  # Un exit code que miente es peor que no tenerlo: rompe cualquier CI que lo mire.
  $script:fail = 0
  Invoke-SelfTest
  exit ([int]$script:fail)
}

# ===========================================================================
#  MAIN
# ===========================================================================
if (-not $NoPreflight) { if (-not (Invoke-Preflight)) { exit 1 } }

$profile = Import-Profile $ProfilePath
if (-not $profile) { $profile = New-DefaultProfile }

$action = if ($Apply) { 'gen' } else { Show-MainMenu $profile }

switch ($action) {
  'quit' { Clear-Host; Write-Host '  Sin cambios.' -ForegroundColor DarkGray; exit 0 }
  'save' {
    Export-Profile $profile $ProfilePath (Get-Date -Format 'yyyy-MM-dd HH:mm')
    Clear-Host
    Write-Host "  Perfil guardado en $ProfilePath" -ForegroundColor Green
    Write-Host '  Podes compartirlo: quien lo use genera la MISMA ISO que vos.' -ForegroundColor DarkGray
    exit 0
  }
  'gen' {
    Export-Profile $profile $ProfilePath (Get-Date -Format 'yyyy-MM-dd HH:mm')
    Set-GlobalsFromProfile $profile
    $ok = Invoke-Pipeline
    Write-Host ''
    if ($ok) {
      $iso = Join-Path $root 'work\Win11_25H2_Pro_debloat.iso'
      Write-Host '  ================== ISO LISTA ==================' -ForegroundColor Green
      if (Test-Path $iso) {
        Write-Host ("  {0}" -f $iso) -ForegroundColor White
        Write-Host ("  {0} GB   {1}" -f [math]::Round((Get-Item $iso).Length/1GB,2), (Get-Item $iso).LastWriteTime) -ForegroundColor White
      }
      Write-Host '  Grabala con Ventoy (copiar el .iso) o con Rufus (GPT/UEFI).' -ForegroundColor White
      Write-Host '  Checklist de instalacion: docs\dia-d.md' -ForegroundColor DarkGray
      Write-Host '  Probarla en una VM primero:  .\scripts\test-vm.ps1 -Reset -Boot' -ForegroundColor DarkGray
    } else {
      Write-Host '  ============ EL PIPELINE SE CORTO ============' -ForegroundColor Red
      Write-Host '  El detalle esta arriba y en work\logs\. La imagen quedo montada' -ForegroundColor Yellow
      Write-Host '  en work\mount: podes corregir y correr la fase que fallo a mano,' -ForegroundColor Yellow
      Write-Host '  sin volver a exportar el WIM (que son 20 minutos).' -ForegroundColor Yellow
    }
    # Pausar SALVO que se pida -NoPause. Con doble clic, sin la pausa la ventana se
    # cierra y se lleva el resultado -- salio bien? fallo? el usuario nunca lo sabe.
    Write-Host ''
    if (-not $NoPause) { Show-TuiPause 'Enter para cerrar.' }
    if (-not $ok) { exit 1 }
  }
}
