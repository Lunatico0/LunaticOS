#requires -Version 5.1
<#
  apps.ps1 — Catalogo de programas que LunaticOS puede instalar en el primer arranque.

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
  @{ Key='python';   Name='Python 3.12';        Cat='Lenguajes';   Src='winget'; Id='Python.Python.3.12'; Rec=$false }
  @{ Key='go';       Name='Go';                 Cat='Lenguajes';   Src='winget'; Id='GoLang.Go';         Rec=$false }
  @{ Key='rust';     Name='Rust (rustup)';      Cat='Lenguajes';   Src='winget'; Id='Rustlang.Rustup';   Rec=$false }
  @{ Key='dotnet';   Name='.NET SDK 8';         Cat='Lenguajes';   Src='winget'; Id='Microsoft.DotNet.SDK.8'; Rec=$false }
  @{ Key='jdk';      Name='Oracle JDK 21';      Cat='Lenguajes';   Src='winget'; Id='Oracle.JDK.21';     Rec=$false }

  # ======================= HERRAMIENTAS DE DEV =======================
  @{ Key='git';      Name='Git';                Cat='Dev';         Src='winget'; Id='Git.Git';           Rec=$true }
  @{ Key='vscode';   Name='Visual Studio Code'; Cat='Dev';         Src='winget'; Id='Microsoft.VisualStudioCode'; Rec=$true }
  @{ Key='gh';       Name='GitHub CLI';         Cat='Dev';         Src='winget'; Id='GitHub.cli';        Rec=$true }
  @{ Key='postman';  Name='Postman';            Cat='Dev';         Src='winget'; Id='Postman.Postman';   Rec=$true }
  @{ Key='insomnia'; Name='Insomnia';           Cat='Dev';         Src='winget'; Id='Insomnia.Insomnia'; Rec=$true
     Note='Alternativa mas liviana a Postman. Podes tener las dos, pero elegi una.' }
  @{ Key='docker';   Name='Docker Desktop';     Cat='Dev';         Src='winget'; Id='Docker.DockerDesktop'; Rec=$false
     Note='Necesita WSL2 o Hyper-V. Come RAM: no lo pongas si no lo vas a usar.' }
  @{ Key='figma';    Name='Figma';              Cat='Dev';         Src='winget'; Id='Figma.Figma';       Rec=$true }
  @{ Key='jetbrains';Name='JetBrains Toolbox';  Cat='Dev';         Src='winget'; Id='JetBrains.Toolbox'; Rec=$false }
  @{ Key='npp';      Name='Notepad++';          Cat='Dev';         Src='winget'; Id='Notepad++.Notepad++'; Rec=$false }
  @{ Key='winmerge'; Name='WinMerge';           Cat='Dev';         Src='winget'; Id='WinMerge.WinMerge'; Rec=$false }
  @{ Key='ghdesktop';Name='GitHub Desktop';     Cat='Dev';         Src='winget'; Id='GitHub.GitHubDesktop'; Rec=$false }
  @{ Key='k8s';      Name='kubectl';            Cat='Dev';         Src='winget'; Id='Kubernetes.kubectl'; Rec=$false }
  @{ Key='helm';     Name='Helm';               Cat='Dev';         Src='winget'; Id='Helm.Helm';         Rec=$false }
  @{ Key='terraform';Name='Terraform';          Cat='Dev';         Src='winget'; Id='Hashicorp.Terraform'; Rec=$false }

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
  @{ Key='starship'; Name='Starship (prompt)';  Cat='Terminal';    Src='winget'; Id='Starship.Starship'; Rec=$false }
  @{ Key='nvim';     Name='Neovim';             Cat='Terminal';    Src='winget'; Id='Neovim.Neovim';     Rec=$false }
  @{ Key='wezterm';  Name='WezTerm';            Cat='Terminal';    Src='winget'; Id='wez.wezterm';       Rec=$false }
  @{ Key='zellij';   Name='Zellij';             Cat='Terminal';    Src='winget'; Id='Zellij.Zellij';     Rec=$false }
  @{ Key='fzf';      Name='fzf';                Cat='Terminal';    Src='winget'; Id='junegunn.fzf';      Rec=$false }
  @{ Key='bat';      Name='bat (cat con syntax)'; Cat='Terminal';  Src='winget'; Id='sharkdp.bat';       Rec=$false }
  @{ Key='fd';       Name='fd (find rapido)';   Cat='Terminal';    Src='winget'; Id='sharkdp.fd';        Rec=$false }
  @{ Key='rg';       Name='ripgrep';            Cat='Terminal';    Src='winget'; Id='BurntSushi.ripgrep.MSVC'; Rec=$false }
  @{ Key='eza';      Name='eza (ls moderno)';   Cat='Terminal';    Src='winget'; Id='eza-community.eza'; Rec=$false }
  @{ Key='jq';       Name='jq';                 Cat='Terminal';    Src='winget'; Id='jqlang.jq';         Rec=$false }
  @{ Key='fastfetch';Name='Fastfetch';          Cat='Terminal';    Src='winget'; Id='Fastfetch-cli.Fastfetch'; Rec=$false }

  # ======================= GAMING: LAUNCHERS =======================
  @{ Key='steam';    Name='Steam';              Cat='Gaming';      Src='winget'; Id='Valve.Steam';       Rec=$true }
  @{ Key='valorant'; Name='VALORANT (LATAM)';   Cat='Gaming';      Src='winget'; Id='RiotGames.Valorant.LATAM'; Rec=$true
     Note='Trae el Riot Client y Vanguard. EXIGE Secure Boot + TPM 2.0 activos (regla D5), si no: VAN9001.' }
  @{ Key='lol';      Name='League of Legends (LAS)'; Cat='Gaming'; Src='winget'; Id='RiotGames.LeagueOfLegends.LA2'; Rec=$false
     Note='LA2 = LAS (Cono Sur). Para LAN usa RiotGames.LeagueOfLegends.LA1.' }
  @{ Key='epic';     Name='Epic Games Launcher'; Cat='Gaming';     Src='winget'; Id='EpicGames.EpicGamesLauncher'; Rec=$false }
  @{ Key='battlenet';Name='Battle.net';          Cat='Gaming';     Src='winget'; Id='Blizzard.BattleNet'; Rec=$false }
  @{ Key='ea';       Name='EA App';              Cat='Gaming';     Src='winget'; Id='ElectronicArts.EADesktop'; Rec=$false }
  @{ Key='ubisoft';  Name='Ubisoft Connect';     Cat='Gaming';     Src='winget'; Id='Ubisoft.Connect';   Rec=$false }
  @{ Key='gog';      Name='GOG Galaxy';          Cat='Gaming';     Src='winget'; Id='GOG.Galaxy';        Rec=$false }

  # ======================= GAMING: MONITOREO Y HARDWARE =======================
  @{ Key='hwinfo';   Name='HWiNFO';             Cat='Monitoreo';   Src='winget'; Id='REALiX.HWiNFO';     Rec=$true
     Note='El mas completo para temperaturas y sensores. Clave si vas a overclockear o diagnosticar throttling.' }
  @{ Key='afterburner'; Name='MSI Afterburner'; Cat='Monitoreo';   Src='winget'; Id='Guru3D.Afterburner'; Rec=$false
     Note='OC de GPU y overlay de FPS (RivaTuner). OJO: algunos anticheat miran overlays; si Vanguard se queja, cerralo antes de jugar.' }
  @{ Key='gpuz';     Name='GPU-Z';              Cat='Monitoreo';   Src='winget'; Id='TechPowerUp.GPU-Z'; Rec=$false }
  @{ Key='cpuz';     Name='CPU-Z';              Cat='Monitoreo';   Src='winget'; Id='CPUID.CPU-Z';       Rec=$false }
  @{ Key='hwmonitor';Name='HWMonitor';          Cat='Monitoreo';   Src='winget'; Id='CPUID.HWMonitor';   Rec=$false }
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
  @{ Key='discord';  Name='Discord';            Cat='Comunicacion'; Src='winget'; Id='Discord.Discord';  Rec=$true }
  @{ Key='whatsapp'; Name='WhatsApp';           Cat='Comunicacion'; Src='msstore'; Id='9NKSQGP7F2NH';    Rec=$true
     Note='Solo esta en la Microsoft Store (no hay paquete winget propio). Por eso Src=msstore.' }
  @{ Key='telegram'; Name='Telegram';           Cat='Comunicacion'; Src='winget'; Id='Telegram.TelegramDesktop'; Rec=$false }
  @{ Key='slack';    Name='Slack';              Cat='Comunicacion'; Src='winget'; Id='SlackTechnologies.Slack'; Rec=$false }
  @{ Key='zoom';     Name='Zoom';               Cat='Comunicacion'; Src='winget'; Id='Zoom.Zoom';        Rec=$false }
  @{ Key='teams';    Name='Microsoft Teams';    Cat='Comunicacion'; Src='winget'; Id='Microsoft.Teams';  Rec=$false
     Note='El Teams preinstalado se saco de la imagen a proposito. Este es el de trabajo, instalado aparte.' }

  # ======================= MULTIMEDIA =======================
  @{ Key='spotify';  Name='Spotify';            Cat='Multimedia';  Src='winget'; Id='Spotify.Spotify';   Rec=$true }
  @{ Key='vlc';      Name='VLC';                Cat='Multimedia';  Src='winget'; Id='VideoLAN.VLC';      Rec=$true }
  @{ Key='obs';      Name='OBS Studio';         Cat='Multimedia';  Src='winget'; Id='OBSProject.OBSStudio'; Rec=$false
     Note='Grabar/streamear. Para clips de gaming.' }

  # ======================= UTILIDADES =======================
  @{ Key='powertoys';Name='PowerToys';          Cat='Utilidades';  Src='winget'; Id='Microsoft.PowerToys'; Rec=$true
     Note='FancyZones, PowerRename, Run. De lo mejor que hizo Microsoft.' }
  @{ Key='7zip';     Name='7-Zip';              Cat='Utilidades';  Src='winget'; Id='7zip.7zip';         Rec=$true }
  @{ Key='everything';Name='Everything (busqueda)'; Cat='Utilidades'; Src='winget'; Id='voidtools.Everything'; Rec=$true
     Note='IMPORTANTE: si apagaste el servicio WSearch en config.ps1, ESTE es tu reemplazo, y es mas rapido que el indice de Windows.' }
  @{ Key='bitwarden';Name='Bitwarden';          Cat='Utilidades';  Src='winget'; Id='Bitwarden.Bitwarden'; Rec=$false }
  @{ Key='keepass';  Name='KeePassXC';          Cat='Utilidades';  Src='winget'; Id='KeePassXCTeam.KeePassXC'; Rec=$false
     Note='Alternativa offline a Bitwarden: la boveda es un archivo tuyo.' }
  @{ Key='obsidian'; Name='Obsidian';           Cat='Utilidades';  Src='winget'; Id='Obsidian.Obsidian'; Rec=$false }
  @{ Key='qbit';     Name='qBittorrent';        Cat='Utilidades';  Src='winget'; Id='qBittorrent.qBittorrent'; Rec=$false }
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
