#requires -Version 5.1
<#
  config.ps1 -- Fuente de verdad del debloat. TOCA ESTO, no la logica.
  Cada compa ajusta aca que sacar/dejar segun su gusto, sin editar los scripts de fase.

  Se carga con dot-sourcing:  . "$PSScriptRoot\config.ps1"
#>

# --- Rutas (relativas al repo -> portables al clonar) ---
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
#     Comenta con # cualquier linea para CONSERVAR esa app.
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
  # Dependencias / sistema -- romper esto rompe winget/Store/seguridad
  'Microsoft.DesktopAppInstaller','Microsoft.WindowsStore','Microsoft.StorePurchaseApp'
  'Microsoft.SecHealthUI','Microsoft.ApplicationCompatibilityEnhancements'
  # Apps utiles / que usas
  'Microsoft.WindowsTerminal','Microsoft.WindowsNotepad','Microsoft.WindowsCalculator'
  'Microsoft.Paint','Microsoft.ScreenSketch','Microsoft.Windows.Photos'
  # Xbox completo (tu decision)
  'Microsoft.GamingApp','Microsoft.Xbox.TCUI','Microsoft.XboxGamingOverlay'
  'Microsoft.XboxIdentityProvider','Microsoft.XboxSpeechToTextOverlay'
  # Zona gris resuelta -> DEJAR
  'Microsoft.BingSearch','Microsoft.ZuneMusic','Microsoft.WindowsCamera'
  # Widgets: se CONSERVA (el usuario quiere el clima en la taskbar sin ads; ver flag ShowWeatherWidget)
  'MicrosoftWindows.Client.WebExperience'
  # Codecs -- sacarlos rompe reproduccion de video/imagenes
  'Microsoft.AV1VideoExtension','Microsoft.AVCEncoderVideoExtension','Microsoft.HEIFImageExtension'
  'Microsoft.HEVCVideoExtension','Microsoft.MPEG2VideoExtension','Microsoft.RawImageExtension'
  'Microsoft.VP9VideoExtensions','Microsoft.WebMediaExtensions','Microsoft.WebpImageExtension'
)

# --- Flags de fases posteriores ---
$Global:Flags = @{
  RemoveOneDrive  = $true   # sacar el cloud de MS (OneDrive) -- pedido explicito
  KillTelemetry   = $true   # DiagTrack + policy + scheduled tasks
  DisableCopilot  = $true
  DisableRecall   = $true
  BypassMsAccount   = $true   # cuenta local en el OOBE (autounattend)
  ShowWeatherWidget = $true   # clima en la taskbar (Widgets). En 25H2 el feed MSN viene OFF por defecto.
  RemoveEdgeBrowser = $true   # saca el NAVEGADOR Edge offline (fase 7). WebView2 SIEMPRE se conserva.
  # Tarea que vuelve a quitar los appx que Windows REINSTALA solo despues de
  # instalar (medido: DevHome y CrossDevice vuelven 11 min despues del boot).
  # Se autoelimina tras 3 corridas sin hallazgos. Ver fase 12.
  LimpiarReincidentes = $true
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
  'wisvc'                    # Windows Insider -- coherente con D2 (nada de Insider)

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

  # --- Agregados el 2026-08-08: diferencial medido contra el Ghost Spectre 23H2 ---
  #     Ghost los tiene en Start=4 y esta lista no los cubria. Se verificaron uno por
  #     uno: ninguno es red, cripto, updates, seguridad ni input (regla D5).
  'RemoteRegistry'           # registro remoto. Vector de ataque, cero uso en un desktop
  'CscService'               # Offline Files (archivos sin conexion). Enterprise
  'DcpSvc'                   # Data Collection and Publishing -- es telemetria, y KillTelemetry no lo tocaba
  'tzautoupdate'             # zona horaria automatica POR UBICACION. Coherente con apagar lfsvc
  'AssignedAccessManagerSvc' # modo kiosco (Assigned Access)
  'shpamsvc'                 # Shared PC account manager (aulas, PCs compartidas)
  'MsKeyboardFilter'         # filtro de teclado de Windows Embedded/kiosco
  'DialogBlockingService'    # bloqueo de dialogos, enterprise
  'diagsvc'                  # Diagnostic Execution Service
  'NetTcpPortSharing'        # port sharing de .NET (net.tcp). Casi nadie lo usa
)

# ===========================================================================
#  QUE ES CADA SERVICIO DE LA LISTA DE ARRIBA -- el texto que la TUI MUESTRA
#
#  POR QUE EXISTE ESTE HASH (agregado el 2026-08-08):
#  la TUI mostraba "Se deshabilita por defecto en el perfil de LunaticOS." para
#  los 42 servicios de $ServicesDisable. O sea que el bloque que se apaga POR
#  DEFAULT, si o si, era el unico que no decia ni QUE ES. Y al lado,
#  $ServicesOptional -- los que NO se apagan solos -- tenia explicaciones
#  buenisimas. La informacion estaba justo al reves de donde hacia falta.
#
#  POR QUE NO SE CONVIRTIO $ServicesDisable EN UN HASH, que seria mas prolijo:
#  las fases se pueden correr A MANO una por una (es una decision de diseno del
#  repo). scripts\04-services.ps1 hace `foreach ($svc in $ServicesDisable)`, y
#  en PowerShell un `foreach` sobre un HASHTABLE itera UNA sola vez con el hash
#  entero como objeto: no apagaria nada y NO daria error. Falla silenciosa.
#  Un array + un hash de notas es menos elegante y no puede romper el pipeline.
#
#  LIMITE: 222 caracteres (3 lineas de 74 en la checklist). Mas largo y el wrap
#  descarta el final EN SILENCIO. El -SelfTest lo verifica.
# ===========================================================================
$Global:ServicesNotes = @{
  # --- Telemetria y reportes ---
  'DiagTrack'        = 'Connected User Experiences and Telemetry: EL servicio de telemetria de Windows. Apagarlo no rompe nada visible. Es el primero de la lista por algo.'
  'dmwappushservice' = 'WAP Push Message Routing. Era para gestion de dispositivos moviles; hoy es un canal de telemetria mas. Sin uso en un desktop.'
  'WerSvc'           = 'Windows Error Reporting: manda los volcados de los programas que crashean a Microsoft. Perdes los reportes automaticos, NO los logs locales del Visor de eventos.'
  'wercplsupport'    = 'El panel "Informes de problemas" del Panel de control. Va junto con WerSvc: sin el servicio de arriba, este no tiene nada que mostrar.'
  'PcaSvc'           = 'Program Compatibility Assistant: el cartel de "este programa puede no funcionar bien". Para funcionar REGISTRA todo lo que ejecutas. Perdes ese asistente.'
  'DsSvc'            = 'Data Sharing Service: comparte datos entre apps y con Microsoft. Sin uso conocido en una PC personal.'
  'wisvc'            = 'Windows Insider Service. Solo sirve para recibir builds de prueba. Si algun dia te queres meter al programa Insider, lo volves a habilitar.'

  # --- Ubicacion, mapas, sensores ---
  'MapsBroker'        = 'Descarga y actualiza mapas OFFLINE de la app Mapas. No afecta Google Maps ni ningun mapa del navegador.'
  'lfsvc'             = 'Geolocation Service: la ubicacion del sistema. Perdes "donde estoy" en apps nativas. OJO: el clima de Widgets puede pedir ciudad a mano.'
  'SensorService'     = 'Servicio de sensores: brillo automatico, rotacion de pantalla, acelerometro. Una PC de escritorio no tiene ninguno.'
  'SensrSvc'          = 'Monitoreo de sensores (el par del anterior). Mismo caso: sin sensores fisicos no hace nada.'
  'SensorDataService' = 'Recolecta y publica datos de los sensores para las apps. Va con los dos de arriba.'

  # --- Telefonia, SMS, pagos, tarjetas ---
  'MessagingService'       = 'Servicio de mensajeria SMS del sistema. Es para tablets con SIM. Perdes nada en una PC: no afecta WhatsApp, Telegram ni Discord.'
  'SmsRouter'              = 'Enruta los SMS a las apps que los pidan. Va con MessagingService: sin modem no hay SMS que enrutar.'
  'PhoneSvc'               = 'Telefonia del sistema (llamadas por SIM). No es Phone Link: ese es una app y sale por separado.'
  'PimIndexMaintenanceSvc' = 'Indexa Contactos para la busqueda. Solo sirve si usas la app Contactos y Correo de Microsoft.'
  'WalletService'          = 'Billetera de Windows: tarjetas y pases. Nunca tuvo uso real fuera de Estados Unidos y esta practicamente abandonado.'
  'SEMgrSvc'               = 'Payments and NFC/SE Manager: pagos por NFC. Necesita hardware NFC, que una placa de escritorio no tiene.'
  'ScDeviceEnum'           = 'Enumera lectores de tarjetas inteligentes (smart cards). Si tu laburo usa token o tarjeta para firmar, NO lo apagues.'
  'SCPolicySvc'            = 'Politica de "que hacer al sacar la smart card" (bloquear la sesion). Va con el anterior: mismo aviso.'

  # --- Cosas que este equipo no usa ---
  'RetailDemo'      = 'Modo demostracion de local: el que corre en las PCs de exhibicion de una tienda. En una PC de verdad no tiene ningun uso.'
  'Fax'             = 'Servicio de fax. Necesita un modem telefonico. Estamos en 2026.'
  'WpcMonSvc'       = 'Control parental (Family Safety): limites de horario y de contenido. Apagalo si no controlas la PC de un chico.'
  'WMPNetworkSvc'   = 'Compartir bibliotecas de Windows Media Player por la red (UPnP). No afecta reproducir tus archivos locales.'
  'AJRouter'        = 'AllJoyn Router: protocolo de IoT que casi nadie implemento. Sin dispositivos AllJoyn en la casa, no hace nada.'
  'SharedRealitySvc'= 'Spatial Data Service, parte de Windows Mixed Reality. Si tenes visor VR de Windows MR, dejalo.'
  'RemoteAccess'    = 'Routing and Remote Access (RRAS): que esta PC funcione como router o servidor VPN. NO afecta conectarte VOS a una VPN.'
  'TrkWks'          = 'Distributed Link Tracking: mantiene vivos los accesos directos a archivos que se movieron de lugar en un dominio. Perdes esa reparacion automatica.'
  'PushToInstall'   = 'Permite instalar apps de la Store desde la web, apretando "Instalar" en otra maquina. Podes seguir instalando desde la Store local.'
  'SNMPTrap'        = 'Recibe traps SNMP de equipos de red monitoreados. Es de administracion de redes, no de una PC de escritorio.'
  'AppVClient'      = 'Microsoft Application Virtualization (App-V): apps virtualizadas de entorno corporativo. Sin infraestructura App-V no hace nada.'
  'UevAgentService' = 'User Experience Virtualization (UE-V): sincroniza configuraciones entre PCs de una empresa. Necesita servidor propio.'

  # --- Agregados el 2026-08-08 (diferencial contra Ghost Spectre) ---
  'RemoteRegistry'           = 'Permite EDITAR EL REGISTRO DE ESTA PC DESDE OTRA MAQUINA por la red. Vector de ataque clasico y cero uso en un desktop. Ghost tambien lo apaga.'
  'CscService'               = 'Offline Files: cachea carpetas de red para trabajar sin conexion. Es de entorno corporativo con unidades de red mapeadas.'
  'DcpSvc'                   = 'Data Collection and Publishing: otro canal de recoleccion, y KillTelemetry no lo cubria. Va con DiagTrack.'
  'tzautoupdate'             = 'Cambia la zona horaria SOLA segun tu ubicacion. Sin geolocalizacion (lfsvc apagado) no puede funcionar igual. La hora la sigue ajustando el servidor NTP.'
  'AssignedAccessManagerSvc' = 'Modo kiosco (Assigned Access): la PC arranca en UNA sola app a pantalla completa. Es para totems y puntos de venta.'
  'shpamsvc'                 = 'Shared PC Account Manager: cuentas temporales que se borran al cerrar sesion, para PCs compartidas de aula o biblioteca.'
  'MsKeyboardFilter'         = 'Filtro de teclado de Windows Embedded: bloquea combinaciones como Ctrl+Alt+Del en un kiosco. No se usa en un desktop normal.'
  'DialogBlockingService'    = 'Bloquea dialogos del sistema en despliegues corporativos. Sin uso en una PC personal.'
  'diagsvc'                  = 'Diagnostic Execution Service: ejecuta los diagnosticos de Microsoft. Distinto de DPS, que es el que usan los solucionadores de problemas (ese NO se toca).'
  'NetTcpPortSharing'        = 'Comparte un puerto TCP entre varias apps .NET (net.tcp). Viene apagado en Windows por defecto y casi ninguna app lo usa.'
}

# ===========================================================================
#  SERVICIOS OPCIONALES -- dependen de TU hardware y de TU uso.
#
#  NO estan activos. Para deshabilitar alguno, move la linea al bloque de
#  arriba. Cada uno dice que perdes: lee antes de mover, no copies a ciegas.
#  Esta lista es informativa; el script NO la usa.
# ===========================================================================
$Global:ServicesOptional = @{
  # --- Perifericos ---
  'Spooler'          = 'Cola de impresion. Deshabilita si NO tenes impresora. Bonus: cierra el vector de PrintNightmare. Rompe tambien "Imprimir a PDF".'
  'stisvc'           = 'Windows Image Acquisition: escaneres y algunas camaras. Deshabilita si no escaneas.'
  'bthserv'          = 'Bluetooth. Deshabilita si no usas nada BT (mouse, auriculares, joystick).'
  'BthAvctpSvc'      = 'Audio/control por Bluetooth. Va junto con bthserv.'
  'WbioSrvc'         = 'Biometria (Windows Hello: huella y cara). Deshabilita si entras con PIN o password.'

  # --- Escritorio remoto ---
  'TermService'      = 'Escritorio remoto ENTRANTE. Deshabilita si nadie se conecta a esta maquina. NO afecta conectarte VOS a otras.'
  'SessionEnv'       = 'Configuracion de sesion de RDP. Va junto con TermService.'
  'UmRdpService'     = 'Redireccion de impresoras/discos por RDP. Va junto con TermService.'

  # --- Red: OJO ACA (D5) ---
  'SSDPSRV'          = 'UPnP discovery. CUIDADO GAMING: algunos juegos y consolas lo usan para abrir NAT. Si tenes NAT tipo estricto, este es el culpable.'
  'upnphost'         = 'Host de dispositivos UPnP. Mismo cuidado que SSDPSRV.'
  'SharedAccess'     = 'Internet Connection Sharing. CUIDADO: el Default Switch de Hyper-V lo usa. Si virtualizas, dejalo.'
  'lltdsvc'          = 'Descubrimiento de topologia de red (el mapa de red). Inofensivo de sacar, pero es red: por D5 queda opcional.'

  # --- Rendimiento y busqueda (los mas discutidos) ---
  'WSearch'          = 'Windows Search. Apagarlo baja I/O de fondo, pero perdes la busqueda del menu Inicio y de Explorer. Para dev que busca archivos seguido, MALA idea.'
  'SysMain'          = 'SysMain (ex Superfetch). El clasico "apagalo para gamear", pero en 25H2 con SSD puede EMPEORAR tiempos de carga. Medilo antes de creerle a un foro.'

  # --- Diagnostico ---
  'DPS'              = 'Diagnostic Policy Service. Deshabilitarlo rompe los solucionadores de problemas de Windows (los de red incluidos).'
  'WdiServiceHost'   = 'Host de diagnostico. Va junto con DPS.'
  'WdiSystemHost'    = 'Host de diagnostico del sistema. Va junto con DPS.'
  'diagnosticshub.standardcollector.service' = 'CUIDADO DEV: lo usa el PROFILER de Visual Studio. Si perfilas codigo, dejalo.'

  # --- Notificaciones y sincronizacion ---
  'WpnService'       = 'Notificaciones push. Apagarlo mata las notificaciones de TODAS las apps, no solo las de MS.'
  'CDPSvc'           = 'Connected Devices Platform. Afecta portapapeles compartido y continuidad entre dispositivos.'
  'OneSyncSvc'       = 'Sincroniza Mail/Calendario/Contactos. Inutil si no usas las apps de Microsoft.'
  'DevicePickerUserSvc' = 'Selector de dispositivos para proyectar/transmitir.'
  'DevicesFlowUserSvc'  = 'Emparejamiento de dispositivos.'

  # --- Realidad mixta / VR ---
  'MixedRealityOpenXRSvc' = 'OpenXR de Mixed Reality. CUIDADO: si tenes visor VR (Quest por Link, Index, etc.) lo necesitas.'
  'spectrum'              = 'Windows Perception Service (MR). Mismo cuidado que el anterior.'
  'perceptionsimulation'  = 'Simulacion de percepcion (MR). Seguro de sacar si no hay VR.'

  # --- Cifrado ---
  'EFS'              = 'Encrypting File System (cifrado por archivo del NTFS). No es BitLocker. Deshabilita si no usas EFS -- pero si tenes archivos ya cifrados con EFS, NO los vas a poder abrir.'

  # --- Agregados el 2026-08-08: los que Ghost Spectre apaga y NOSOTROS NO ponemos en default ---
  #     Ghost los tiene en Start=4. Cada uno tiene un motivo concreto para quedar opcional.
  'WinRM'            = 'Windows Remote Management. Deshabilita si nadie administra esta maquina por remoto. OJO DEV: lo usan PowerShell Remoting, Ansible y varias herramientas de CI. Si automatizas con alguna de esas, dejalo.'
  'p2pimsvc'         = 'Peer Name Resolution (PNRP). Es RED (regla D5): por eso es opcional y no default. Lo usaban Grupo en el hogar y Asistencia remota.'
  'p2psvc'           = 'Peer Networking Grouping. Va junto con p2pimsvc. Tambien es red.'
  'PNRPsvc'          = 'Protocolo de resolucion de nombres entre pares. Va con los dos de arriba.'
  'PNRPAutoReg'      = 'Publicacion automatica del nombre de esta PC por PNRP. Va con los de arriba.'
  'PeerDistSvc'      = 'BranchCache: cachea descargas entre PCs de la misma red. Inutil en una casa con una sola PC, util en una oficina. Es red (D5).'
  'SENS'             = 'System Event Notification Service. CUIDADO: lo usan TAREAS PROGRAMADAS con disparadores de logon/conexion y los logon scripts. Si tenes automatizaciones que arrancan al iniciar sesion, dejalo.'
  'uhssvc'           = 'Microsoft Update Health Service. Toca WINDOWS UPDATE, que por D5 no va nunca en la lista de default. Si te molesta, va aca y con conciencia.'
  'udfs'             = 'ATENCION: es el driver con el que Windows MONTA UN .ISO (doble clic en una imagen). Ghost lo apaga. Si lo apagas no podes montar ISOs -- y si buildeas este proyecto, lo necesitas.'
  'cdfs'             = 'Driver del sistema de archivos de CD/DVD. Solo si no tenes lectora Y no montas imagenes. Ver la advertencia de udfs.'
  'ssh-agent'        = 'OpenSSH Authentication Agent: guarda tus claves SSH desbloqueadas en memoria. Ghost lo apaga. NO lo apagues si usas claves SSH con passphrase (git, servidores): sin agente la escribis en cada push.'
}

# ===========================================================================
#  LO QUE GHOST SPECTRE APAGA Y ACA NO SE COPIA -- medido el 2026-08-08
#
#  Esta lista NO la usa ningun script. Existe para que nadie "mejore" el
#  debloat copiando lo que hace una ISO de terceros. Cada uno se verifico.
#
#    Sense .............. Defender for Endpoint. Ghost lo deja en Start=4.
#    WdAiNisDrv ......... Network Inspection System de Defender.
#    (y encima Ghost NO trae Windows-Defender-Default-Definitions, que la
#     imagen limpia de 25H2 si tiene: le falta el motor de definiciones)
#    TabletInputService . rompe teclado tactil y panel de emoji. Ya estaba
#                         declarado innegociable arriba.
#    cnghwassist ........ CNG hardware assist = CRIPTO. D5, innegociable.
#
#  Ghost sirve como LIMITE ("esto se puede sacar y la maquina anda") y como
#  referencia de gusto. NUNCA como fuente de decisiones: es una ISO que
#  mutila la seguridad, y ese es justo lo que este proyecto no hace.
# ===========================================================================

# --- CAPABILITIES a remover (por PREFIJO; el script resuelve nombre+version instalado) ---
#     Comenta para conservar. NUNCA drivers de red (Wifi/Ethernet), OpenSSH, DirectX, WebView2.
$Global:CapabilitiesRemove = @(
  'App.StepsRecorder'           # grabadora de pasos (deprecado)
  'Browser.InternetExplorer'    # IE 11 legacy  (toggle: coments si usas IE mode)
  'MathRecognizer'              # reconocimiento matematico (tactil)
  'Media.WindowsMediaPlayer'    # WMP CLASICO legacy (el moderno = appx ZuneMusic, se conserva)
  'Language.Handwriting'        # escritura a mano (no hay tactil) (toggle)

  # --- Agregados el 2026-08-08 ---
  #     Medidos DENTRO de la imagen 25H2 montada (no contra una PC): los 57 capabilities
  #     instalados del install.wim. Y 6 de estos 7 estan YA sacados en el Ghost Spectre 23H2,
  #     donde se desarrolla y se juega todos los dias: prueba de que no rompen nada.
  'VBSCRIPT'                    # deprecado por Microsoft. Vector clasico de malware por adjunto
  'WMIC'                        # deprecado por Microsoft (usar PowerShell CIM). Muy usado por malware para reconocimiento
  'Windows.Telnet.Client'       # telnet: protocolo sin cifrar, uso legitimo casi nulo hoy
  'Windows.TFTP.Client'         # TFTP: idem, sin cifrado ni autenticacion
  'Windows.SimpleTCP.Content'   # Simple TCP/IP Services (echo, daytime, quote). Legado de los 90
  'Windows.DirectoryServices.ADAM.Client.Content'  # AD LDS. Enterprise, cero uso en desktop
  'Windows.TerminalServices.AppServerClient'       # RemoteApp. Va con la decision de RDP

  # WorkFolders NO va aca: como capability da error offline y queda "Staged" (inofensivo).
  # Se apaga por la FEATURE 'WorkFolders-Client' (abajo), que es lo efectivo.
  #
  # NO PONER ACA, y esta medido (2026-08-08):
  #   Edge.Webview2.Platform ... lo necesitan Store, Widgets y apps (ver D21)
  #   OpenSSH.Client ........... el usuario usa claves SSH
  #   DirectX.Configuration.Database / Tools.Graphics.DirectX ... es una PC de juegos
  #   Language.Basic|OCR|Speech|TextToSpeech ... idioma base de la imagen
  #   Windows.Kernel.LA57 ...... paginacion de 5 niveles, kernel
  #   Windows.Client.ProjFS .... Projected FS: lo usa git con VFS en repos grandes
  #   Microsoft.Windows.Sense.Client ... Defender for Endpoint
  #   Los 19 WiFi + 4 Ethernet . INNEGOCIABLE: esta ISO es GENERICA y PUBLICADA. Sin
  #                              driver WiFi, una notebook recien instalada no tiene red
  #                              -- y sin red no se instala el driver que le falta.
  #                              Que ESTA maquina sea Ethernet no autoriza a sacarlos.
)

# --- FEATURES (optional features) a deshabilitar (nombre EXACTO) ---
$Global:FeaturesDisable = @(
  'WindowsMediaPlayer'   # app WMP legacy. NO tocar 'MediaPlayback' (motor de reproduccion)
  'WorkFolders-Client'   # Work Folders

  # --- Agregados el 2026-08-08 ---
  #     Medidos DENTRO de la imagen 25H2 montada: 12 features vienen habilitadas y esta
  #     lista cubria CERO de ellas. Estas 4 son las que se pueden apagar sin perder nada.
  'MicrosoftWindowsPowerShellV2'      # PowerShell 2.0: DEPRECADO por Microsoft y bypass clasico
  'MicrosoftWindowsPowerShellV2Root'  # del logging -- "powershell -version 2" evade
                                      # ScriptBlockLogging y AMSI. El Root es el padre: van los dos
  'SmbDirect'                         # SMB sobre RDMA. Sin hardware RDMA (no lo tiene una placa
                                      # de consumo) no hace absolutamente nada
  'Printing-Foundation-InternetPrinting-Client'  # impresion IPP por internet. NO es imprimir en
                                      # red local, eso es Printing-Foundation-Features (se conserva)

  # NO PONER ACA, y esta medido (2026-08-08):
  #   MediaPlayback ................ motor de reproduccion (ya avisado arriba)
  #   NetFx4-AdvSrvs / WCF-* ....... .NET y WCF: los usan apps de escritorio y herramientas dev
  #   SearchEngine-Client-Package .. es Windows Search. Para dev que busca archivos, mala idea
  #   Printing-PrintToPDFServices-* . "Imprimir a PDF" se usa SIN tener impresora
  #   Windows-Defender-Default-Definitions ... seguridad. Ghost no la trae; nosotros SI
  #   Microsoft-Hyper-V-* .......... lo necesita el E2E en VM de este mismo repo
)

# ===========================================================================
#  OVERRIDE DEL PERFIL DEL USUARIO -- ESTE BLOQUE VA AL FINAL A PROPOSITO
#
#  EL BUG QUE ARREGLA (medido el 2026-08-08 con el E2E completo en VM):
#  lo que el usuario marcaba en la TUI NO LLEGABA A LAS FASES. El header de
#  LunaticOS.ps1 promete "el perfil PISA config.ps1 en memoria justo antes de
#  correr las fases", y pasaba exactamente lo contrario:
#
#    1. Set-GlobalsFromProfile ponia $ServicesDisable = los 63 del perfil
#    2. Invoke-Pipeline corria cada fase con  & $path
#    3. la fase arrancaba con  . "$PSScriptRoot\config.ps1"
#    4. y ESTE ARCHIVO volvia a definir $ServicesDisable = los 42 de arriba
#
#  Resultado medido en la VM: se apagaron los 42 de config y CERO de los 21
#  opcionales que la TUI habia marcado. verify-live.ps1 lo confirmo: "39
#  Disabled+Stopped, 17 mal, 12 inexistentes", 17 chequeos en rojo.
#
#  POR QUE NADIE LO VIO EN 11 DIAS: el perfil y este archivo COINCIDEN en todo
#  lo demas (appx 18 y 18, capabilities 12 y 12, features 6 y 6). El unico lugar
#  donde pueden diferir son los $ServicesOptional, y hay que marcar alguno para
#  que se note. El usuario marco 7 el 2026-07-31 y la ISO del pendrive los tiene
#  vivos sin que nadie se enterara.
#
#  POR QUE UNA VARIABLE DE ENTORNO Y NO OTRA COSA:
#   - funciona igual si la fase corre en ESTE proceso (& $path) o en uno nuevo
#   - una fase corrida A MANO, sin la variable, sigue usando los defaults de
#     arriba: esa es una decision de diseno del repo y no se toca
#   - es el MISMO patron que el repo ya usa con LUNATICOS_TEST_UNATTEND=1 para
#     la fase 8, asi que no se inventa un mecanismo nuevo
#
#  POR QUE TIRA SI EL ARCHIVO NO SE PUEDE LEER, en vez de seguir con defaults:
#  si la variable esta seteada, ALGUIEN QUISO aplicar un perfil. Buildear con
#  los defaults en silencio produce una ISO que no es la que el usuario pidio, y
#  no se enteraria hasta instalarla. Un build que falla en el segundo 1 es
#  infinitamente mas barato que una ISO equivocada descubierta 40 minutos
#  despues -- o peor, nunca.
# ===========================================================================
if ($env:LUNATICOS_PROFILE) {
  $rutaPerfil = $env:LUNATICOS_PROFILE
  if (-not (Test-Path $rutaPerfil)) {
    throw ("LUNATICOS_PROFILE apunta a '$rutaPerfil' y no existe. Se aborta a proposito: " +
           "buildear con los defaults seria darte una ISO que no es la que pediste.")
  }
  try {
    $perfilJson = Get-Content $rutaPerfil -Raw -Encoding UTF8 | ConvertFrom-Json
  } catch {
    throw ("LUNATICOS_PROFILE='$rutaPerfil' no es JSON valido ($($_.Exception.Message)). " +
           "Se aborta a proposito: ver el comentario de arriba.")
  }

  # Las claves con valor $true. El perfil que escribe Export-Profile trae TODAS
  # las claves (true y false), asi que no hace falta mergear contra los defaults:
  # el archivo ya es el resultado del merge que hizo Import-Profile.
  function script:Get-PerfilMarcados($nodo) {
    if (-not $nodo) { return @() }
    @($nodo.PSObject.Properties | Where-Object { $_.Value } | ForEach-Object { $_.Name })
  }

  $appxDelPerfil = @(Get-PerfilMarcados $perfilJson.appx)
  $svcDelPerfil  = @(Get-PerfilMarcados $perfilJson.servicios)
  $featDelPerfil = @(Get-PerfilMarcados $perfilJson.features)

  # Se pisa SOLO si el perfil trae la seccion. Un perfil viejo al que le falta una
  # categoria entera tiene que quedarse con los defaults, no con una lista vacia:
  # es la misma regla de retrocompatibilidad que Import-Profile ya respeta.
  if ($null -ne $perfilJson.appx)      { $Global:AppxRemove      = $appxDelPerfil }
  if ($null -ne $perfilJson.servicios) { $Global:ServicesDisable = $svcDelPerfil }
  if ($null -ne $perfilJson.features) {
    $Global:CapabilitiesRemove = @($featDelPerfil | Where-Object { $_ -like 'cap:*'  } | ForEach-Object { $_ -replace '^cap:'  })
    $Global:FeaturesDisable    = @($featDelPerfil | Where-Object { $_ -like 'feat:*' } | ForEach-Object { $_ -replace '^feat:' })
  }
  # Los flags se MERGEAN, no se reemplazan: si el perfil no trae una clave nueva
  # (perfil viejo + flag agregado despues), tiene que conservar su default.
  if ($null -ne $perfilJson.flags) {
    foreach ($pr in $perfilJson.flags.PSObject.Properties) { $Global:Flags[$pr.Name] = [bool]$pr.Value }
  }
  if ($null -ne $perfilJson.personalizacion) { $Global:PersonalizacionPicked = @(Get-PerfilMarcados $perfilJson.personalizacion) }
  if ($null -ne $perfilJson.programas)       { $Global:AppsPicked            = @(Get-PerfilMarcados $perfilJson.programas) }
  if ($null -ne $perfilJson.usuario)         { $Global:UsuarioPerfil         = $perfilJson.usuario }

  # Se avisa en el log del build: sin esta linea, "por que apago 63 y no 42" se
  # vuelve una hora de lectura de codigo.
  Write-Host ("  [perfil] override desde $(Split-Path $rutaPerfil -Leaf): " +
              "appx=$(@($Global:AppxRemove).Count) servicios=$(@($Global:ServicesDisable).Count) " +
              "capabilities=$(@($Global:CapabilitiesRemove).Count) features=$(@($Global:FeaturesDisable).Count) " +
              "programas=$(@($Global:AppsPicked).Count)") -ForegroundColor DarkGray
}

# ===========================================================================
#  CUENTA DE LA VM DE TEST (solo para el E2E)
#
#  La crea config\autounattend-test.xml, que es SOLO PARA TEST EN VM y FORMATEA EL
#  DISCO 0 SIN PREGUNTAR. Nada de esto se usa en produccion: el autounattend de
#  produccion crea la cuenta con password VACIO a proposito.
#
#  POR QUE SE LEE DEL XML Y NO HAY UNA CONSTANTE ESCRITA ACA:
#  el password tiene que ser EXACTAMENTE el que el instalador le puso a la cuenta.
#  Una copia en este archivo (o en un .psd1) seria una SEGUNDA fuente de verdad, y
#  dos fuentes de verdad se desincronizan: alguien edita el XML, nadie se acuerda
#  de la copia, y el sintoma aparece 35 minutos despues como "PowerShell Direct no
#  conecta" o "la VM quedo en la pantalla de login". Ese sintoma no se parece en
#  nada a la causa, que es la peor clase de bug que tiene este repo. Leyendo del
#  XML, el problema no puede existir.
#
#  Consumidores previstos (scripts\test-e2e.ps1, scripts\verify-live.ps1):
#
#    . "$PSScriptRoot\config.ps1"
#    $c = Get-TestVmAccount
#    scripts\verify-live.ps1 -VMName 'LunaticOS-Test' -User $c.User -Password $c.Password
#
#  NO IMPRIMAS $c.Password EN NINGUN LOG. Es un secreto que no protege nada (vive
#  en una VM descartable y esta versionado a proposito), pero los logs de
#  work\logs\ se comparten para diagnosticar, y un password en un log ensena que
#  esta bien poner passwords en los logs.
# ===========================================================================
$Global:TestUnattendPath = Join-Path $root 'config\autounattend-test.xml'

function Get-TestVmAccount {
  param([string]$Path = $Global:TestUnattendPath)

  if (-not (Test-Path $Path)) {
    throw "No existe $Path. Sin ese archivo no hay VM de test: es el que crea la cuenta con password."
  }
  $doc = New-Object System.Xml.XmlDocument
  $doc.Load((Resolve-Path $Path).Path)

  # local-name() en todos los pasos: el unattend declara un namespace por defecto
  # (urn:schemas-microsoft-com:unattend) y un XPath sin local-name() NO encuentra
  # nada. Y no falla ruidoso: devuelve $null.
  $la = $doc.SelectSingleNode(
    "//*[local-name()='UserAccounts']/*[local-name()='LocalAccounts']/*[local-name()='LocalAccount']")
  if (-not $la) { throw "$Path no crea ninguna LocalAccount." }

  $nUser = $la.SelectSingleNode("*[local-name()='Name']")
  $nPass = $la.SelectSingleNode("*[local-name()='Password']/*[local-name()='Value']")
  $u  = if ($nUser) { "$($nUser.InnerText)".Trim() } else { '' }
  $pw = if ($nPass) { "$($nPass.InnerText)" }        else { '' }

  if ($u -eq '' -or $pw -eq '') {
    throw ("$Path no tiene usuario o password usable (leido: usuario '$u', password " +
           "de $($pw.Length) caracteres). PowerShell Direct NO funciona con password vacio.")
  }

  # Credential armada aca para que el consumidor no tenga que repetir el
  # ConvertTo-SecureString. Si el guest rechaza el usuario pelado, probar ".\$u":
  # PowerShell Direct a veces necesita el dominio local explicito.
  $sec = ConvertTo-SecureString $pw -AsPlainText -Force
  @{
    User       = $u
    Password   = $pw
    Credential = New-Object System.Management.Automation.PSCredential($u, $sec)
  }
}
