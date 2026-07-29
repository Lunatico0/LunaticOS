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
  # Widgets: se CONSERVA (el usuario quiere el clima en la taskbar sin ads; ver flag ShowWeatherWidget)
  'MicrosoftWindows.Client.WebExperience'
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
  BypassMsAccount   = $true   # cuenta local en el OOBE (autounattend)
  ShowWeatherWidget = $true   # clima en la taskbar (Widgets). En 25H2 el feed MSN viene OFF por defecto.
  RemoveEdgeBrowser = $true   # saca el NAVEGADOR Edge offline (fase 7). WebView2 SIEMPRE se conserva.
}

# --- Region del equipo ---
#   11 = Argentina. No afecta los formatos de fecha/hora/moneda (eso es UserLocale=es-AR en
#   el autounattend, independiente): afecta el catalogo de la Store y algunos servicios.
#
#   NOTA HISTORICA (ver D19/D20): se intento arrancar con GeoID 68 (Irlanda, EEA) para que
#   EdgeUpdate respetara las policies de Edge, y NO funciono: el propio <UserLocale>es-AR</UserLocale>
#   del pass oobeSystem pisa el GeoID antes de que EdgeUpdate corra durante el OOBE. Medido:
#   la fase 7 escribia 68 en Users\Default\NTUSER.DAT y terminaba en 11 sin que nadie mas lo tocara.
#   Por eso ahora Edge se frena matando EdgeUpdate (abajo), no jugando con la region.
$Global:Geo = @{
  GeoId = 11   # Argentina
}

# --- Edge: que ejecutables se BLOQUEAN por IFEO (fase 7) ---
#   Se bloquea la EJECUCION del navegador, no se desinstala. Razon medida: el instalador
#   de WebView2 y el de Edge son EL MISMO BINARIO (MicrosoftEdge_X64_<ver>.exe), asi que
#   Windows Update trae Edge cada vez que actualiza WebView2. Ver D21.
#
#   msedgewebview2.exe NO ESTA EN ESTA LISTA A PROPOSITO: es WebView2, lo necesitan la
#   Store, Widgets y muchas apps. Por eso la lista es explicita y sin comodines.
$Global:EdgeBlockedExes = @(
  'msedge.exe'                # el navegador
  'msedge_proxy.exe'          # proxy de links/PWAs
  'msedge_pwa_launcher.exe'   # lanzador de PWAs
)

#   El "Debugger" que IFEO ejecuta EN LUGAR del binario. systray.exe existe en todas las
#   instalaciones y no hace nada visible: el proceso muere sin ventana ni error.
$Global:EdgeIfeoStub = 'C:\Windows\System32\systray.exe'

# ===========================================================================
#  SERVICIOS a deshabilitar (Start=4)
#
#  REGLA DE ORO: "Manual > Disabled cuando dudes". Un servicio en Manual no
#  arranca solo, pero si algo lo necesita lo puede levantar. Disabled es una
#  puerta tapiada: cuando algo lo pide, falla y encima el error no dice por que.
#
#  LO QUE NUNCA VA EN ESTA LISTA (regla D5, innegociable):
#    Red/firewall/cripto .. BFE, mpssvc, CryptSvc, Dnscache, Dhcp, NlaSvc,
#                           netprofm, iphlpsvc  (iphlpsvc lo usan juegos y VPNs)
#    Anticheat ............ vgc, vgk  (Vanguard: sin esto Valorant no abre)
#    Store / appx ......... ClipSVC, LicenseManager, AppXSvc, InstallService,
#                           TokenBroker, StateRepository  (rompen winget y Store)
#    Updates .............. wuauserv, BITS, TrustedInstaller, msiserver
#    Seguridad ............ WinDefend, SecurityHealthService, wscsvc, Sense
#    Audio ................ Audiosrv, AudioEndpointBuilder
#    Input de texto ....... TextInputManagementService, TabletInputService
#    Xbox ................. XblAuthManager, XblGameSave, XboxNetApiSvc, XboxGipSvc
#    Webcam ............... FrameServer  (videollamadas)
#
#  Comenta cualquier linea para CONSERVAR ese servicio.
# ===========================================================================
$Global:ServicesDisable = @(
  # --- Telemetria y reportes ---
  'DiagTrack'                # telemetria (Connected User Experiences)
  'dmwappushservice'         # WAP push (telemetria)
  'WerSvc'                   # Windows Error Reporting
  'wercplsupport'            # panel de "informes de problemas"
  'PcaSvc'                   # Program Compatibility Assistant (registra que ejecutas)
  'DsSvc'                    # Data Sharing Service
  'wisvc'                    # Windows Insider — coherente con D2 (nada de Insider)

  # --- Ubicacion, mapas, sensores ---
  'MapsBroker'               # mapas descargados
  'lfsvc'                    # geolocalizacion
  'SensorService'            # sensores
  'SensrSvc'                 # monitoreo de sensores
  'SensorDataService'        # datos de sensores

  # --- Telefonia, SMS, pagos, tarjetas ---
  'MessagingService'         # SMS / mensajeria
  'SmsRouter'                # enrutamiento de SMS
  'PhoneSvc'                 # telefonia (Phone Link ya salio como appx)
  'PimIndexMaintenanceSvc'   # indexado de contactos
  'WalletService'            # billetera
  'SEMgrSvc'                 # pagos NFC / elementos seguros
  'ScDeviceEnum'             # enumeracion de smart cards
  'SCPolicySvc'              # politica de retiro de smart card

  # --- Cosas que este equipo no usa ---
  'RetailDemo'               # modo demo de tienda
  'Fax'                      # fax
  'WpcMonSvc'                # control parental
  'WMPNetworkSvc'            # uso compartido de Windows Media Player
  'AJRouter'                 # AllJoyn (IoT)
  'SharedRealitySvc'         # Mixed Reality
  'RemoteAccess'             # enrutamiento y acceso remoto (RRAS)
  'TrkWks'                   # Distributed Link Tracking (rastrea archivos movidos)
  'PushToInstall'            # instalar apps remotamente desde la web de la Store
  'SNMPTrap'                 # SNMP
  'AppVClient'               # App-V (virtualizacion de apps, enterprise)
  'UevAgentService'          # UE-V (roaming de settings, enterprise)
)

# ===========================================================================
#  SERVICIOS OPCIONALES — dependen de TU hardware y de TU uso.
#
#  NO estan activos. Para deshabilitar alguno, mové la linea al bloque de
#  arriba. Cada uno dice que perdés: leé antes de mover, no copies a ciegas.
#  Esta lista es informativa; el script NO la usa.
# ===========================================================================
$Global:ServicesOptional = @{
  # --- Perifericos ---
  'Spooler'          = 'Cola de impresion. Deshabilitá si NO tenés impresora. Bonus: cierra el vector de PrintNightmare. Rompe tambien "Imprimir a PDF".'
  'stisvc'           = 'Windows Image Acquisition: escaneres y algunas camaras. Deshabilitá si no escaneás.'
  'bthserv'          = 'Bluetooth. Deshabilitá si no usás nada BT (mouse, auriculares, joystick).'
  'BthAvctpSvc'      = 'Audio/control por Bluetooth. Va junto con bthserv.'
  'WbioSrvc'         = 'Biometria (Windows Hello: huella y cara). Deshabilitá si entrás con PIN o password.'

  # --- Escritorio remoto ---
  'TermService'      = 'Escritorio remoto ENTRANTE. Deshabilitá si nadie se conecta a esta maquina. NO afecta conectarte VOS a otras.'
  'SessionEnv'       = 'Configuracion de sesion de RDP. Va junto con TermService.'
  'UmRdpService'     = 'Redireccion de impresoras/discos por RDP. Va junto con TermService.'

  # --- Red: OJO ACA (D5) ---
  'SSDPSRV'          = 'UPnP discovery. CUIDADO GAMING: algunos juegos y consolas lo usan para abrir NAT. Si tenés NAT tipo estricto, este es el culpable.'
  'upnphost'         = 'Host de dispositivos UPnP. Mismo cuidado que SSDPSRV.'
  'SharedAccess'     = 'Internet Connection Sharing. CUIDADO: el Default Switch de Hyper-V lo usa. Si virtualizás, dejalo.'
  'lltdsvc'          = 'Descubrimiento de topologia de red (el mapa de red). Inofensivo de sacar, pero es red: por D5 queda opcional.'

  # --- Rendimiento y busqueda (los mas discutidos) ---
  'WSearch'          = 'Windows Search. Apagarlo baja I/O de fondo, pero perdés la busqueda del menu Inicio y de Explorer. Para dev que busca archivos seguido, MALA idea.'
  'SysMain'          = 'SysMain (ex Superfetch). El clasico "apagalo para gamear", pero en 25H2 con SSD puede EMPEORAR tiempos de carga. Medilo antes de creerle a un foro.'

  # --- Diagnostico ---
  'DPS'              = 'Diagnostic Policy Service. Deshabilitarlo rompe los solucionadores de problemas de Windows (los de red incluidos).'
  'WdiServiceHost'   = 'Host de diagnostico. Va junto con DPS.'
  'WdiSystemHost'    = 'Host de diagnostico del sistema. Va junto con DPS.'
  'diagnosticshub.standardcollector.service' = 'CUIDADO DEV: lo usa el PROFILER de Visual Studio. Si perfilás codigo, dejalo.'

  # --- Notificaciones y sincronizacion ---
  'WpnService'       = 'Notificaciones push. Apagarlo mata las notificaciones de TODAS las apps, no solo las de MS.'
  'CDPSvc'           = 'Connected Devices Platform. Afecta portapapeles compartido y continuidad entre dispositivos.'
  'OneSyncSvc'       = 'Sincroniza Mail/Calendario/Contactos. Inutil si no usás las apps de Microsoft.'
  'DevicePickerUserSvc' = 'Selector de dispositivos para proyectar/transmitir.'
  'DevicesFlowUserSvc'  = 'Emparejamiento de dispositivos.'

  # --- Realidad mixta / VR ---
  'MixedRealityOpenXRSvc' = 'OpenXR de Mixed Reality. CUIDADO: si tenés visor VR (Quest por Link, Index, etc.) lo necesitás.'
  'spectrum'              = 'Windows Perception Service (MR). Mismo cuidado que el anterior.'
  'perceptionsimulation'  = 'Simulacion de percepcion (MR). Seguro de sacar si no hay VR.'

  # --- Cifrado ---
  'EFS'              = 'Encrypting File System (cifrado por archivo del NTFS). No es BitLocker. Deshabilitá si no usás EFS — pero si tenés archivos ya cifrados con EFS, NO los vas a poder abrir.'
}

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
