#requires -Version 5.1
<#
  apps.ps1 -- Catalogo de programas que LunaticOS puede instalar en el primer arranque.

  TODOS los IDs de winget de este archivo fueron VERIFICADOS con
  `winget show --id <id> --exact` en 25H2 (2026-07-28). No estan puestos de memoria:
  de 110 IDs candidatos, 14 no existian. Si agregas uno, VERIFICALO primero.

  ===========================================================================
  LOS DRIVERS DE GPU Y CHIPSET NO ESTAN EN WINGET. Medido:
      Nvidia.GeForceExperience ......... NO EXISTE
      Nvidia.app ....................... NO EXISTE
      AMD.AMDSoftwareAdrenalinEdition .. NO EXISTE
      AMD.Chipset / AMD.RyzenMaster .... NO EXISTE
      Intel.ChipsetDeviceSoftware ...... NO EXISTE
  Lo unico "de NVIDIA" en winget es CUDA, ICAT y Profile Inspector. Y de AMD solo
  esta AMDSoftwareCloudEdition, que es la edicion CLOUD, NO el Adrenalin de escritorio.

  Por eso los drivers van con Src='manual': el instalador NO los baja solo, te deja
  la URL oficial. Un script que promete "instalo tus drivers por winget" te esta
  mintiendo, y encima falla en silencio.
  ===========================================================================

  Campos de cada entrada:
    Key   identificador corto e interno (lo usa la TUI para guardar la seleccion)
    Name  nombre visible
    Cat   categoria (la TUI agrupa por esto)
    Src   'winget' | 'msstore' | 'manual'
    Id    ID exacto de winget o de la Store  (vacio si Src='manual')
    Url   pagina oficial de descarga         (solo si Src='manual')
    Rec   $true  -> aparece marcado como (recomendado) en la TUI
    Note  por que esta, o que hay que saber antes de marcarlo
#>

$Global:AppCatalog = @(

  # ======================= NAVEGADORES =======================
  # OJO: con Edge bloqueado (D21) NECESITAS al menos uno de estos, y ponerlo como
  # predeterminado. Si no, los links del sistema no abren en ningun lado.
  @{ Key='firefox';  Name='Firefox';            Cat='Navegadores'; Src='winget'; Id='Mozilla.Firefox';   Rec=$true
     Note='Edge queda bloqueado: hace falta un navegador real. Ponelo como predeterminado.' }
  @{ Key='chrome';   Name='Google Chrome';      Cat='Navegadores'; Src='winget'; Id='Google.Chrome';     Rec=$true
     Note='Para probar en Chromium sin depender de Edge.' }

  # ======================= LENGUAJES Y RUNTIMES =======================
  @{ Key='node-lts'; Name='Node.js LTS (+npm)'; Cat='Lenguajes';   Src='winget'; Id='OpenJS.NodeJS.LTS'; Rec=$true
     Note='npm viene incluido. LTS es la opcion sensata para trabajar; la current rompe mas seguido.' }
  @{ Key='node-cur'; Name='Node.js Current';    Cat='Lenguajes';   Src='winget'; Id='OpenJS.NodeJS';     Rec=$false
     Note='Ultima version. NO la marques junto con la LTS: se pisan entre si.' }
  @{ Key='nvm';      Name='NVM for Windows';    Cat='Lenguajes';   Src='winget'; Id='CoreyButler.NVMforWindows'; Rec=$false
     Note='Varias versiones de Node conviviendo. Si usas esto, NO instales Node por winget.' }
  @{ Key='pnpm';     Name='pnpm';               Cat='Lenguajes';   Src='winget'; Id='pnpm.pnpm';         Rec=$false
     Note='Gestor de paquetes mas rapido y con menos duplicacion que npm.' }
  @{ Key='python';   Name='Python 3.12';        Cat='Lenguajes';   Src='winget'; Id='Python.Python.3.12'; Rec=$false
     Note='Interprete de Python con pip. Lo pide un monton de herramientas ademas de programar en Python.' }
  @{ Key='go';       Name='Go';                 Cat='Lenguajes';   Src='winget'; Id='GoLang.Go';         Rec=$false
     Note='Toolchain completo de Go. Con "go install" instalas herramientas escritas en Go sin compilar a mano.' }
  @{ Key='rust';     Name='Rust (rustup)';      Cat='Lenguajes';   Src='winget'; Id='Rustlang.Rustup';   Rec=$false
     Note='Rust por rustup, que es la forma recomendada: maneja stable/nightly y trae cargo. OJO: en Windows el toolchain MSVC necesita las Build Tools de Visual Studio para poder enlazar.' }
  @{ Key='dotnet';   Name='.NET SDK 8';         Cat='Lenguajes';   Src='winget'; Id='Microsoft.DotNet.SDK.8'; Rec=$false
     Note='SDK de .NET 8 (LTS): compilador de C#/F# y la CLI dotnet. Si solo vas a EJECUTAR apps .NET no hace falta: con el runtime alcanza.' }
  @{ Key='jdk';      Name='Oracle JDK 21';      Cat='Lenguajes';   Src='winget'; Id='Oracle.JDK.21';     Rec=$false
     Note='Java 21 LTS de Oracle. OJO CON LA LICENCIA: gratis para uso personal y desarrollo, PAGA en produccion comercial. La alternativa libre es OpenJDK/Temurin.' }

  # ======================= HERRAMIENTAS DE DEV =======================
  @{ Key='git';      Name='Git';                Cat='Dev';         Src='winget'; Id='Git.Git';           Rec=$true
     Note='El control de versiones. En Windows trae ademas Git Bash, que es la forma mas comoda de tener un shell tipo Unix sin instalar nada mas.' }
  @{ Key='vscode';   Name='Visual Studio Code'; Cat='Dev';         Src='winget'; Id='Microsoft.VisualStudioCode'; Rec=$true
     Note='El editor. Liviano de entrada y con extensiones para casi cualquier lenguaje.' }
  @{ Key='gh';       Name='GitHub CLI';         Cat='Dev';         Src='winget'; Id='GitHub.cli';        Rec=$true
     Note='CLI oficial de GitHub: PRs, issues y clonar desde la terminal. Bonus: te autentica git por HTTPS sin andar generando tokens a mano.' }
  @{ Key='postman';  Name='Postman';            Cat='Dev';         Src='winget'; Id='Postman.Postman';   Rec=$true
     Note='Cliente de APIs REST y GraphQL. Pesado y te pide cuenta para lo bueno. Si buscas algo liviano, mira Insomnia en esta misma lista.' }
  @{ Key='insomnia'; Name='Insomnia';           Cat='Dev';         Src='winget'; Id='Insomnia.Insomnia'; Rec=$true
     Note='Alternativa mas liviana a Postman. Podes tener las dos, pero elegi una.' }
  @{ Key='docker';   Name='Docker Desktop';     Cat='Dev';         Src='winget'; Id='Docker.DockerDesktop'; Rec=$false
     Note='Necesita WSL2 o Hyper-V. Come RAM: no lo pongas si no lo vas a usar.' }
  @{ Key='figma';    Name='Figma';              Cat='Dev';         Src='winget'; Id='Figma.Figma';       Rec=$true
     Note='Diseno de interfaces. La app de escritorio es la misma web empaquetada, pero usa tus fuentes locales, que en el navegador no puede.' }
  @{ Key='jetbrains';Name='JetBrains Toolbox';  Cat='Dev';         Src='winget'; Id='JetBrains.Toolbox'; Rec=$false
     Note='OJO: NO instala ningun IDE. Es el GESTOR desde donde despues instalas IntelliJ, WebStorm, PyCharm o Rider, y el que los actualiza.' }
  @{ Key='npp';      Name='Notepad++';          Cat='Dev';         Src='winget'; Id='Notepad++.Notepad++'; Rec=$false
     Note='Editor liviano que abre en un segundo. Aguanta archivos enormes (logs de cientos de MB) que a VS Code lo hacen sufrir.' }
  @{ Key='winmerge'; Name='WinMerge';           Cat='Dev';         Src='winget'; Id='WinMerge.WinMerge'; Rec=$false
     Note='Compara y combina archivos y CARPETAS enteras con diff visual. Util cuando el diff de git no alcanza.' }
  @{ Key='ghdesktop';Name='GitHub Desktop';     Cat='Dev';         Src='winget'; Id='GitHub.GitHubDesktop'; Rec=$false
     Note='Git con interfaz grafica, pensado para arrancar. Si ya te manejas con git por consola, no te aporta nada.' }
  @{ Key='k8s';      Name='kubectl';            Cat='Dev';         Src='winget'; Id='Kubernetes.kubectl'; Rec=$false
     Note='El cliente de Kubernetes. Es SOLO la CLI: no instala ningun cluster. Sin un cluster al que apuntar no hace nada.' }
  @{ Key='helm';     Name='Helm';               Cat='Dev';         Src='winget'; Id='Helm.Helm';         Rec=$false
     Note='Gestor de paquetes de Kubernetes (charts). Va junto con kubectl: sin cluster, no sirve.' }
  @{ Key='terraform';Name='Terraform';          Cat='Dev';         Src='winget'; Id='Hashicorp.Terraform'; Rec=$false
     Note='Infraestructura como codigo. OJO CON LA LICENCIA: desde la 1.6 es BUSL, ya no es open source. La bifurcacion libre se llama OpenTofu.' }

  # ======================= BASES DE DATOS =======================
  @{ Key='mongo';    Name='MongoDB Server';     Cat='Bases de datos'; Src='winget'; Id='MongoDB.Server'; Rec=$true
     Note='Instala el servidor como servicio. Si solo queres conectarte a uno remoto, alcanza Compass.' }
  @{ Key='compass';  Name='MongoDB Compass';    Cat='Bases de datos'; Src='winget'; Id='MongoDB.Compass.Full'; Rec=$true
     Note='GUI de MongoDB.' }
  @{ Key='dbeaver';  Name='DBeaver Community';  Cat='Bases de datos'; Src='winget'; Id='DBeaver.DBeaver.Community'; Rec=$false
     Note='Cliente universal (Postgres, MySQL, SQLite, etc.).' }

  # ======================= TERMINAL =======================
  @{ Key='pwsh';     Name='PowerShell 7';       Cat='Terminal';    Src='winget'; Id='Microsoft.PowerShell'; Rec=$true
     Note='El PowerShell 5.1 del sistema queda igual; esto se instala al lado.' }
  @{ Key='starship'; Name='Starship (prompt)';  Cat='Terminal';    Src='winget'; Id='Starship.Starship'; Rec=$false
     Note='Prompt que muestra rama de git, estado del repo y version del lenguaje del proyecto. Anda en PowerShell, bash y zsh. NECESITA una Nerd Font instalada, si no ves cuadraditos.' }
  @{ Key='nvim';     Name='Neovim';             Cat='Terminal';    Src='winget'; Id='Neovim.Neovim';     Rec=$false
     Note='Vim moderno, con Lua y soporte LSP nativo. Si nunca usaste Vim tiene curva de aprendizaje real: arranca con el comando "vimtutor".' }
  @{ Key='wezterm';  Name='WezTerm';            Cat='Terminal';    Src='winget'; Id='wez.wezterm';       Rec=$false
     Note='Emulador de terminal con render por GPU, pestanas, paneles y configuracion en Lua. Alternativa a Windows Terminal.' }
  @{ Key='zellij';   Name='Zellij';             Cat='Terminal';    Src='winget'; Id='Zellij.Zellij';     Rec=$false
     Note='Multiplexor de terminal: paneles y sesiones que sobreviven a cerrar la ventana. Como tmux, pero muestra los atajos en pantalla.' }
  @{ Key='fzf';      Name='fzf';                Cat='Terminal';    Src='winget'; Id='junegunn.fzf';      Rec=$false
     Note='Buscador difuso para la terminal. Se combina con cualquier cosa por pipe: historial de comandos, archivos, ramas de git.' }
  @{ Key='bat';      Name='bat (cat con syntax)'; Cat='Terminal';  Src='winget'; Id='sharkdp.bat';       Rec=$false
     Note='Como cat pero con colores por lenguaje, numeros de linea y marcas de git. Reemplazo directo.' }
  @{ Key='fd';       Name='fd (find rapido)';   Cat='Terminal';    Src='winget'; Id='sharkdp.fd';        Rec=$false
     Note='Como find pero rapido y con sintaxis simple. Respeta tu .gitignore por defecto, asi que no te llena la salida con node_modules.' }
  @{ Key='rg';       Name='ripgrep';            Cat='Terminal';    Src='winget'; Id='BurntSushi.ripgrep.MSVC'; Rec=$false
     Note='grep recursivo y muy rapido, que respeta .gitignore. Es el motor de busqueda que usa VS Code por debajo.' }
  @{ Key='eza';      Name='eza (ls moderno)';   Cat='Terminal';    Src='winget'; Id='eza-community.eza'; Rec=$false
     Note='ls con colores, iconos, vista de arbol y estado de git. Es el sucesor de exa, que quedo sin mantenimiento.' }
  @{ Key='jq';       Name='jq';                 Cat='Terminal';    Src='winget'; Id='jqlang.jq';         Rec=$false
     Note='Filtra y transforma JSON en la terminal. Si tocas APIs, es la diferencia entre leer una respuesta y adivinarla.' }
  @{ Key='fastfetch';Name='Fastfetch';          Cat='Terminal';    Src='winget'; Id='Fastfetch-cli.Fastfetch'; Rec=$false
     Note='Muestra los datos del sistema con el logo en ASCII al lado. Es puramente cosmetico. Sucesor de neofetch.' }

  # ======================= GAMING: LAUNCHERS =======================
  @{ Key='steam';    Name='Steam';              Cat='Gaming';      Src='winget'; Id='Valve.Steam';       Rec=$true
     Note='La tienda mas grande de PC. IMPORTANTE si reinstalaste: si tus juegos estan en OTRO disco, agrega esa carpeta como biblioteca y Steam los re-detecta sin volver a descargar nada.' }
  @{ Key='valorant'; Name='VALORANT (LATAM)';   Cat='Gaming';      Src='winget'; Id='RiotGames.Valorant.LATAM'; Rec=$true
     Note='Trae el Riot Client y Vanguard. EXIGE Secure Boot + TPM 2.0 activos (regla D5), si no: VAN9001.' }
  @{ Key='lol';      Name='League of Legends (LAS)'; Cat='Gaming'; Src='winget'; Id='RiotGames.LeagueOfLegends.LA2'; Rec=$false
     Note='LA2 = LAS (Cono Sur). Para LAN usa RiotGames.LeagueOfLegends.LA1.' }
  @{ Key='epic';     Name='Epic Games Launcher'; Cat='Gaming';     Src='winget'; Id='EpicGames.EpicGamesLauncher'; Rec=$false
     Note='Tienda de Epic. Regala un juego por semana, y para mucha gente ese es el unico motivo de tenerlo instalado.' }
  @{ Key='battlenet';Name='Battle.net';          Cat='Gaming';     Src='winget'; Id='Blizzard.BattleNet'; Rec=$false
     Note='Launcher de Blizzard: WoW, Diablo, Overwatch, Hearthstone, StarCraft.' }
  @{ Key='ea';       Name='EA App';              Cat='Gaming';     Src='winget'; Id='ElectronicArts.EADesktop'; Rec=$false
     Note='Ex Origin. Necesario para FIFA/FC, Battlefield, Los Sims y Apex. Varios juegos de Steam lo abren igual por atras.' }
  @{ Key='ubisoft';  Name='Ubisoft Connect';     Cat='Gaming';     Src='winget'; Id='Ubisoft.Connect';   Rec=$false
     Note='Para Assassins Creed, Far Cry y Rainbow Six. Igual que EA: los juegos de Ubisoft comprados en Steam lo levantan solos.' }
  @{ Key='gog';      Name='GOG Galaxy';          Cat='Gaming';     Src='winget'; Id='GOG.Galaxy';        Rec=$false
     Note='Juegos SIN DRM y clasicos viejos ya parcheados para Windows moderno. Ademas unifica en una sola biblioteca los juegos de los otros launchers.' }

  # ======================= GAMING: MONITOREO Y HARDWARE =======================
  @{ Key='hwinfo';   Name='HWiNFO';             Cat='Monitoreo';   Src='winget'; Id='REALiX.HWiNFO';     Rec=$true
     Note='El mas completo para temperaturas y sensores. Clave si vas a overclockear o diagnosticar throttling.' }
  @{ Key='afterburner'; Name='MSI Afterburner'; Cat='Monitoreo';   Src='winget'; Id='Guru3D.Afterburner'; Rec=$false
     Note='OC de GPU y overlay de FPS (RivaTuner). OJO: algunos anticheat miran overlays; si Vanguard se queja, cerralo antes de jugar.' }
  @{ Key='gpuz';     Name='GPU-Z';              Cat='Monitoreo';   Src='winget'; Id='TechPowerUp.GPU-Z'; Rec=$false
     Note='Datos de la GPU leidos del config space PCIe: modelo, VRAM, relojes y el campo Resizable BAR. Es la unica fuente que no depende del driver. Anda portable, sin instalar.' }
  @{ Key='cpuz';     Name='CPU-Z';              Cat='Monitoreo';   Src='winget'; Id='CPUID.CPU-Z';       Rec=$false
     Note='Datos exactos de CPU, placa y RAM: modelo, timings, canales y en que slot esta cada modulo. Lo primero que abris antes de comprar memoria.' }
  @{ Key='hwmonitor';Name='HWMonitor';          Cat='Monitoreo';   Src='winget'; Id='CPUID.HWMonitor';   Rec=$false
     Note='Temperaturas, voltajes y consumo de todos los sensores en una sola lista. Si ya pusiste HWiNFO, este te sobra: hacen lo mismo.' }
  @{ Key='cdi';      Name='CrystalDiskInfo';    Cat='Monitoreo';   Src='winget'; Id='CrystalDewWorld.CrystalDiskInfo'; Rec=$true
     Note='Salud SMART del SSD. Te avisa que el disco se esta muriendo ANTES de que te lleve los datos.' }

  # ======================= PERIFERICOS =======================
  @{ Key='steelseries'; Name='SteelSeries GG';  Cat='Perifericos'; Src='winget'; Id='SteelSeries.GG';    Rec=$false
     Note='Solo si tenes periferico SteelSeries.' }
  @{ Key='razer';    Name='Razer Synapse 4';    Cat='Perifericos'; Src='winget'; Id='RazerInc.RazerInstaller.Synapse4'; Rec=$false
     Note='Para mouse/teclado Razer. Si tu modelo es viejo puede necesitar Synapse 3 (RazerInc.RazerInstaller.Synapse3).' }
  @{ Key='ghub';     Name='Logitech G HUB';     Cat='Perifericos'; Src='winget'; Id='Logitech.GHUB';     Rec=$false
     Note='Linea gaming de Logitech (G Pro, etc.).' }
  @{ Key='loptions'; Name='Logitech Options';   Cat='Perifericos'; Src='winget'; Id='Logitech.Options';  Rec=$false
     Note='Linea de oficina (MX Master y compania). NO es lo mismo que G HUB.' }
  @{ Key='lomm';     Name='Logitech Onboard Memory Manager'; Cat='Perifericos'; Src='winget'; Id='Logitech.OnboardMemoryManager'; Rec=$false
     Note='Guarda los perfiles EN el mouse: podes jugar sin tener G HUB corriendo. Ideal para FPS competitivo.' }
  @{ Key='royalkludge'; Name='Royal Kludge (software)'; Cat='Perifericos'; Src='manual'; Id=''
     Url='https://www.rkgaming.com/en/driver/'; Rec=$false
     Note='NO esta en winget (verificado: "No package found"). Descarga manual, y el driver depende del MODELO exacto del teclado.' }

  # ======================= DRIVERS (NO ESTAN EN WINGET) =======================
  @{ Key='drv-nvidia'; Name='NVIDIA (driver GPU)'; Cat='Drivers'; Src='manual'; Id=''
     Url='https://www.nvidia.com/Download/index.aspx'; Rec=$false
     Note='NO esta en winget (ni el driver ni GeForce Experience ni NVIDIA App). Bajalo del sitio. Para FPS competitivo alcanza el driver solo, sin GeForce Experience.' }
  @{ Key='drv-amd-gpu'; Name='AMD Adrenalin (driver GPU)'; Cat='Drivers'; Src='manual'; Id=''
     Url='https://www.amd.com/en/support'; Rec=$false
     Note='NO esta en winget. El unico paquete AMD que existe es AMDSoftwareCloudEdition, que es la edicion CLOUD y NO te sirve.' }
  @{ Key='drv-amd-chipset'; Name='AMD Chipset'; Cat='Drivers'; Src='manual'; Id=''
     Url='https://www.amd.com/en/support/download/drivers.html'; Rec=$false
     Note='Importante en Ryzen: trae el power plan que maneja bien los CCD y el boost.' }
  @{ Key='drv-intel'; Name='Intel Driver & Support Assistant'; Cat='Drivers'; Src='winget'; Id='Intel.IntelDriverAndSupportAssistant'; Rec=$false
     Note='Este SI esta en winget. Detecta e instala drivers Intel (chipset, red, etc.). Es lo mas cerca de un driver automatico que hay.' }

  # ======================= COMUNICACION =======================
  @{ Key='discord';  Name='Discord';            Cat='Comunicacion'; Src='winget'; Id='Discord.Discord';  Rec=$true
     Note='Chat de voz y texto. OJO: se agrega solo al arranque de Windows y se actualiza por su cuenta. El arranque automatico se saca desde su propia configuracion.' }
  @{ Key='whatsapp'; Name='WhatsApp';           Cat='Comunicacion'; Src='msstore'; Id='9NKSQGP7F2NH';    Rec=$true
     Note='Solo esta en la Microsoft Store (no hay paquete winget propio). Por eso Src=msstore.' }
  @{ Key='telegram'; Name='Telegram';           Cat='Comunicacion'; Src='winget'; Id='Telegram.TelegramDesktop'; Rec=$false
     Note='Mensajeria. A diferencia de WhatsApp, la app de escritorio funciona sola: no necesita el celular prendido ni en la misma red.' }
  @{ Key='slack';    Name='Slack';              Cat='Comunicacion'; Src='winget'; Id='SlackTechnologies.Slack'; Rec=$false
     Note='Chat de trabajo por espacios. Es Electron: con varios workspaces abiertos come RAM en serio.' }
  @{ Key='zoom';     Name='Zoom';               Cat='Comunicacion'; Src='winget'; Id='Zoom.Zoom';        Rec=$false
     Note='Videollamadas. Se instala solo cuando entras a una reunion por link, asi que tenerlo de antemano solo sirve si lo usas seguido.' }
  @{ Key='teams';    Name='Microsoft Teams';    Cat='Comunicacion'; Src='winget'; Id='Microsoft.Teams';  Rec=$false
     Note='El Teams preinstalado se saco de la imagen a proposito. Este es el de trabajo, instalado aparte.' }

  # ======================= MULTIMEDIA =======================
  @{ Key='spotify';  Name='Spotify';            Cat='Multimedia';  Src='winget'; Id='Spotify.Spotify';   Rec=$true
     Note='Musica. La app de escritorio permite calidad mas alta que la web y descarga para escuchar sin conexion, las dos cosas solo con Premium.' }
  @{ Key='vlc';      Name='VLC';                Cat='Multimedia';  Src='winget'; Id='VideoLAN.VLC';      Rec=$true
     Note='Reproduce cualquier formato sin instalar codecs aparte. Es el que abre el archivo que ninguna otra cosa abre.' }
  @{ Key='obs';      Name='OBS Studio';         Cat='Multimedia';  Src='winget'; Id='OBSProject.OBSStudio'; Rec=$false
     Note='Grabar/streamear. Para clips de gaming.' }

  # ======================= UTILIDADES =======================
  @{ Key='powertoys';Name='PowerToys';          Cat='Utilidades';  Src='winget'; Id='Microsoft.PowerToys'; Rec=$true
     Note='FancyZones, PowerRename, Run. De lo mejor que hizo Microsoft.' }
  @{ Key='7zip';     Name='7-Zip';              Cat='Utilidades';  Src='winget'; Id='7zip.7zip';         Rec=$true
     Note='Abre zip, rar, 7z, tar, iso y practicamente todo. El explorador de Windows no abre RAR, asi que esto tapa un agujero real del sistema.' }
  @{ Key='everything';Name='Everything (busqueda)'; Cat='Utilidades'; Src='winget'; Id='voidtools.Everything'; Rec=$true
     Note='IMPORTANTE: si apagaste el servicio WSearch en config.ps1, ESTE es tu reemplazo, y es mas rapido que el indice de Windows.' }
  @{ Key='bitwarden';Name='Bitwarden';          Cat='Utilidades';  Src='winget'; Id='Bitwarden.Bitwarden'; Rec=$false
     Note='Gestor de contrasenas open source, con sincronizacion gratis entre dispositivos. Si hoy las guardas en el navegador, esto es un paso arriba en serio.' }
  @{ Key='keepass';  Name='KeePassXC';          Cat='Utilidades';  Src='winget'; Id='KeePassXCTeam.KeePassXC'; Rec=$false
     Note='Alternativa offline a Bitwarden: la boveda es un archivo tuyo.' }
  @{ Key='obsidian'; Name='Obsidian';           Cat='Utilidades';  Src='winget'; Id='Obsidian.Obsidian'; Rec=$false
     Note='Notas en archivos Markdown LOCALES, con enlaces entre notas. Tus notas quedan en tu disco como texto plano: si manana desaparece el programa, se siguen leyendo.' }
  @{ Key='qbit';     Name='qBittorrent';        Cat='Utilidades';  Src='winget'; Id='qBittorrent.qBittorrent'; Rec=$false
     Note='Cliente de torrents sin publicidad ni software colado en el instalador. Es la alternativa limpia a uTorrent.' }
  @{ Key='rufus';    Name='Rufus';              Cat='Utilidades';  Src='winget'; Id='Rufus.Rufus';       Rec=$false
     Note='Para grabar la proxima ISO desde esta maquina.' }
  @{ Key='ventoy';   Name='Ventoy';             Cat='Utilidades';  Src='winget'; Id='Ventoy.Ventoy';     Rec=$false
     Note='Pendrive multi-ISO: copias los .iso y listo.' }
  @{ Key='windirstat';Name='WinDirStat';        Cat='Utilidades';  Src='winget'; Id='WinDirStat.WinDirStat'; Rec=$false
     Note='Quien se comio el disco.' }

  # ======================= BACKUP =======================
  @{ Key='restic';   Name='restic';             Cat='Backup';      Src='winget'; Id='restic.restic';     Rec=$true
     Note='Backups incrementales con deduplicacion y cifrado. Es CLI: despues hay que configurar el repo y una tarea programada.' }
)

# Categorias en el orden en que la TUI las muestra.
$Global:AppCategories = @(
  'Navegadores', 'Lenguajes', 'Dev', 'Bases de datos', 'Terminal',
  'Gaming', 'Monitoreo', 'Perifericos', 'Drivers',
  'Comunicacion', 'Multimedia', 'Utilidades', 'Backup'
)
