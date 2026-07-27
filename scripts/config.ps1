#requires -Version 5.1
<#
  config.ps1 — Fuente de verdad del debloat. TOCÁ ESTO, no la lógica.
  Cada compa ajusta acá qué sacar/dejar segun su gusto, sin editar los scripts de fase.

  Se carga con dot-sourcing:  . "$PSScriptRoot\config.ps1"
#>

# --- Rutas (relativas al repo → portables al clonar) ---
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$adk  = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64'

$Global:CFG = @{
  Root     = $root
  IsoBuild = Join-Path $root 'work\iso-build'
  Mount    = Join-Path $root 'work\mount'
  Dism     = Join-Path $adk  'DISM\dism.exe'
  Oscdimg  = Join-Path $adk  'Oscdimg\oscdimg.exe'
}

# --- APPX a REMOVER (perfil de referencia: dev pesado + FPS competitivo) ---
#     Comentá con # cualquier linea para CONSERVAR esa app.
$Global:AppxRemove = @(
  'Clipchamp.Clipchamp'
  'Microsoft.BingNews'
  'Microsoft.BingWeather'
  'Microsoft.GetHelp'
  'Microsoft.MicrosoftOfficeHub'
  'Microsoft.MicrosoftSolitaireCollection'
  'Microsoft.OutlookForWindows'
  'Microsoft.PowerAutomateDesktop'
  'Microsoft.Todos'
  'Microsoft.Windows.DevHome'
  'Microsoft.WindowsFeedbackHub'
  'MicrosoftCorporationII.QuickAssist'
  'MicrosoftWindows.Client.WebExperience'   # Widgets (News & Interests)
  'MicrosoftWindows.CrossDevice'
  'Microsoft.WindowsAlarms'
  'Microsoft.MicrosoftStickyNotes'
  'Microsoft.WindowsSoundRecorder'
  'Microsoft.YourPhone'                      # Phone Link
  'MSTeams'                                  # Teams preinstalado (reinstalar el de laburo por winget)
)

# --- APPX BLINDADAS: NUNCA se tocan aunque aparezcan en Remove (guarda de seguridad) ---
$Global:AppxKeep = @(
  # Dependencias / sistema — romper esto rompe winget/Store/seguridad
  'Microsoft.DesktopAppInstaller','Microsoft.WindowsStore','Microsoft.StorePurchaseApp'
  'Microsoft.SecHealthUI','Microsoft.ApplicationCompatibilityEnhancements'
  # Apps utiles / que usás
  'Microsoft.WindowsTerminal','Microsoft.WindowsNotepad','Microsoft.WindowsCalculator'
  'Microsoft.Paint','Microsoft.ScreenSketch','Microsoft.Windows.Photos'
  # Xbox completo (tu decisión)
  'Microsoft.GamingApp','Microsoft.Xbox.TCUI','Microsoft.XboxGamingOverlay'
  'Microsoft.XboxIdentityProvider','Microsoft.XboxSpeechToTextOverlay'
  # Zona gris resuelta → DEJAR
  'Microsoft.BingSearch','Microsoft.ZuneMusic','Microsoft.WindowsCamera'
  # Codecs — sacarlos rompe reproduccion de video/imagenes
  'Microsoft.AV1VideoExtension','Microsoft.AVCEncoderVideoExtension','Microsoft.HEIFImageExtension'
  'Microsoft.HEVCVideoExtension','Microsoft.MPEG2VideoExtension','Microsoft.RawImageExtension'
  'Microsoft.VP9VideoExtensions','Microsoft.WebMediaExtensions','Microsoft.WebpImageExtension'
)

# --- Flags de fases posteriores ---
$Global:Flags = @{
  RemoveOneDrive  = $true   # sacar el cloud de MS (OneDrive) — pedido explicito
  KillTelemetry   = $true   # DiagTrack + policy + scheduled tasks
  DisableCopilot  = $true
  DisableRecall   = $true
  BypassMsAccount = $true   # cuenta local en el OOBE (autounattend)
}

# --- SERVICIOS a deshabilitar (Start=4). Solo los "seguros" del plan. ---
#     Regla: "Manual > Disabled cuando dudes". NUNCA red/cripto/audio/update/seguridad/anticheat.
#     Comenta cualquier linea para conservar ese servicio.
$Global:ServicesDisable = @(
  'DiagTrack'                # telemetria (Connected User Experiences)
  'dmwappushservice'         # WAP push (telemetria)
  'WerSvc'                   # Windows Error Reporting
  'MapsBroker'               # mapas descargados
  'lfsvc'                    # geolocalizacion
  'RetailDemo'               # modo demo de tienda
  'Fax'                      # fax
  'WpcMonSvc'                # control parental
  'WMPNetworkSvc'            # uso compartido de Windows Media Player
  'MessagingService'         # SMS / mensajeria
  'PimIndexMaintenanceSvc'   # indexado de contactos
  'AJRouter'                 # AllJoyn (IoT)
  'WalletService'            # billetera
  'SharedRealitySvc'         # Mixed Reality
  'SensorService'            # sensores
  'SensrSvc'                 # monitoreo de sensores
  'SensorDataService'        # datos de sensores
  'RemoteAccess'             # enrutamiento y acceso remoto (RRAS)
)

# --- CAPABILITIES a remover (por PREFIJO; el script resuelve nombre+version instalado) ---
#     Comenta para conservar. NUNCA drivers de red (Wifi/Ethernet), OpenSSH, DirectX, WebView2.
$Global:CapabilitiesRemove = @(
  'App.StepsRecorder'           # grabadora de pasos (deprecado)
  'Browser.InternetExplorer'    # IE 11 legacy  (toggle: coments si usas IE mode)
  'MathRecognizer'              # reconocimiento matematico (tactil)
  'Media.WindowsMediaPlayer'    # WMP CLASICO legacy (el moderno = appx ZuneMusic, se conserva)
  'Language.Handwriting'        # escritura a mano (no hay tactil) (toggle)
  # WorkFolders NO va aca: como capability da error offline y queda "Staged" (inofensivo).
  # Se apaga por la FEATURE 'WorkFolders-Client' (abajo), que es lo efectivo.
)

# --- FEATURES (optional features) a deshabilitar (nombre EXACTO) ---
$Global:FeaturesDisable = @(
  'WindowsMediaPlayer'   # app WMP legacy. NO tocar 'MediaPlayback' (motor de reproduccion)
  'WorkFolders-Client'   # Work Folders
)
