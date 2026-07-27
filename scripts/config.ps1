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
