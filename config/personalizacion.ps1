#requires -Version 5.1
<#
  personalizacion.ps1 — Estetica de LunaticOS.

  ===========================================================================
  REGLA DE ORO DE ESTE ARCHIVO: TODO VA COMO *DEFAULT*, NADA COMO *POLICY*.

  Hay dos formas de escribir un ajuste en Windows y solo una deja al usuario
  cambiarlo despues:

    Valor en el hive DEFAULT (Users\Default\NTUSER.DAT)
        -> es un PUNTO DE PARTIDA. Todo perfil nuevo lo hereda, y el usuario
           lo cambia desde Settings cuando quiera. ESTO es lo que usamos.

    Policy en HKLM\SOFTWARE\Policies\...
        -> BLOQUEA la opcion. Settings la muestra en gris con el cartel
           "Algunas configuraciones estan administradas por tu organizacion".
           NO usamos esto para estetica. Nunca.

  Ese cartel es la marca de los scripts de debloat mal hechos: te dejan medio
  panel de Settings inutilizable. LunaticOS te da un Windows que arranca lindo
  y QUEDA TUYO, no uno que arranca lindo y no podes tocar.
  ===========================================================================

  Cada entrada:
    Key   identificador para el perfil.json
    Name  nombre visible en la TUI
    Rec   $true -> marcado como (recomendado)
    Note  que hace, o que hay que saber
    Regs  lista de valores a escribir en el hive DEFAULT (rutas relativas a HKCU)
            k = subclave · v = nombre · d = dato · t = tipo (dword|sz)
#>

$Global:PersonalizacionCatalog = @(

  # ---------------------------------------------------------------- TEMA
  @{ Key='tema-oscuro'; Name='Tema oscuro'; Rec=$true
     Note='Apps y sistema en oscuro. Lo cambias en Settings > Personalization > Colors cuando quieras.'
     Regs=@(
       @{k='Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; v='AppsUseLightTheme';   d=0; t='dword'}
       @{k='Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; v='SystemUsesLightTheme'; d=0; t='dword'}
     ) }

  @{ Key='sin-transparencia'; Name='Sin efectos de transparencia'; Rec=$false
     Note='Apaga el acrilico/mica. Gana algunos FPS en equipos justos y se ve mas plano.'
     Regs=@(
       @{k='Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; v='EnableTransparency'; d=0; t='dword'}
     ) }

  # ---------------------------------------------------------------- TASKBAR
  @{ Key='taskbar-izquierda'; Name='Botones de la taskbar a la izquierda'; Rec=$true
     Note='Como Windows 10. Reversible desde Settings > Personalization > Taskbar.'
     Regs=@(
       @{k='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='TaskbarAl'; d=0; t='dword'}
     ) }

  @{ Key='reloj-segundos'; Name='Segundos en el reloj'; Rec=$false
     Note='Muestra los segundos en la bandeja. Consume un pelin mas de CPU por el repintado.'
     Regs=@(
       @{k='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='ShowSecondsInSystemClock'; d=1; t='dword'}
     ) }

  @{ Key='taskbar-chica'; Name='Iconos chicos en la taskbar'; Rec=$false
     Note='Barra mas compacta. En 25H2 este valor puede ser ignorado segun la build: si no cambia nada, no es tu culpa.'
     Regs=@(
       @{k='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='TaskbarSi'; d=0; t='dword'}
     ) }

  # ---------------------------------------------------------------- EXPLORER
  @{ Key='menu-clasico'; Name='Menu contextual clasico (estilo Win10)'; Rec=$true
     Note='Vuelve el menu derecho completo, sin el "Mostrar mas opciones". De lo mas pedido. Se revierte borrando la clave CLSID.'
     Regs=@(
       # El truco: registrar el CLSID del menu nuevo con un InprocServer32 VACIO.
       # Windows no encuentra el handler y cae al menu clasico. No borra nada del sistema.
       @{k='Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'; v=''; d=''; t='sz'}
     ) }

  @{ Key='explorer-compacto'; Name='Vista compacta en el Explorer'; Rec=$true
     Note='Menos espacio entre filas: entran mas archivos en pantalla. Pensado para mouse, no para tactil.'
     Regs=@(
       @{k='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='UseCompactMode'; d=1; t='dword'}
     ) }

  @{ Key='sin-gallery'; Name='Sin "Galeria" ni "Inicio" en el panel del Explorer'; Rec=$false
     Note='Saca los accesos que Microsoft agrego arriba de "Este equipo".'
     Regs=@(
       @{k='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='LaunchTo'; d=1; t='dword'}
     ) }

  # ---------------------------------------------------------------- RENDIMIENTO VISUAL
  @{ Key='sin-animaciones'; Name='Sin animaciones de ventanas'; Rec=$false
     Note='Minimizar/maximizar instantaneo. Se siente mas rapido y ayuda en FPS competitivo. Reversible en Performance Options.'
     Regs=@(
       @{k='Control Panel\Desktop\WindowMetrics'; v='MinAnimate'; d='0'; t='sz'}
     ) }

  @{ Key='menu-rapido'; Name='Menus sin retardo'; Rec=$false
     Note='Baja el delay de apertura de menus de 400ms a 0. Cambio chico, se nota todo el dia.'
     Regs=@(
       @{k='Control Panel\Desktop'; v='MenuShowDelay'; d='0'; t='sz'}
     ) }

  # ---------------------------------------------------------------- COLOR DE ACENTO
  # OJO CON ESTO: el color de acento de Windows 11 no es un solo valor. La UI usa
  # tambien AccentPalette, un blob BINARIO de 32 bytes con 8 tonos derivados. Escribir
  # solo AccentColor deja partes de la UI con el color viejo. Por eso la fase 10
  # calcula el AccentPalette y lo escribe en el primer login.
  # El usuario igual puede elegir CUALQUIER color despues, desde Settings.
  #
  # ###################################################################
  #  EL SUFIJO 'L' DE LOS VALORES NO ES DECORATIVO. NO LO SAQUES.
  #
  #  PowerShell parsea un literal hexadecimal de 8 digitos como Int32 CON SIGNO:
  #      0xFF14B8A6         ->  -15419226   (Int32, NEGATIVO)
  #      0xFF14B8A6L        ->  4279548070  (Int64, correcto)
  #  Estos colores son ARGB con alpha FF, asi que el bit alto siempre esta prendido
  #  y SIEMPRE caen en negativo sin la L. Con un negativo, el `reg add /t REG_DWORD`
  #  escribe basura o falla, y `[uint32]` de un negativo tira excepcion.
  #  Sintoma real: los tres valores del acento fallaban EN SILENCIO y Windows se
  #  quedaba con su azul por defecto.
  #  El self-test de LunaticOS.ps1 verifica que todos los DWORD entren en uint32:
  #  si alguien saca una L, falla ahi antes de llegar a una ISO.
  # ###################################################################
  @{ Key='acento-violeta'; Name='Color de acento: violeta'; Rec=$false
     Note='Paleta completa (AccentPalette incluido). Podes cambiarlo despues en Settings > Colors.'
     Regs=@(
       @{k='Software\Microsoft\Windows\CurrentVersion\Explorer\Accent'; v='AccentColorMenu'; d=0xFF8B5CF6L; t='dword'}
       @{k='Software\Microsoft\Windows\DWM';                            v='AccentColor';     d=0xFF8B5CF6L; t='dword'}
       @{k='Software\Microsoft\Windows\DWM';                            v='ColorizationColor'; d=0xC48B5CF6L; t='dword'}
       @{k='Software\Microsoft\Windows\DWM';                            v='ColorPrevalence'; d=0; t='dword'}
     ) }

  @{ Key='acento-teal'; Name='Color de acento: teal'; Rec=$false
     Note='Paleta completa. Excluyente con las otras opciones de acento.'
     Regs=@(
       @{k='Software\Microsoft\Windows\CurrentVersion\Explorer\Accent'; v='AccentColorMenu'; d=0xFF14B8A6L; t='dword'}
       @{k='Software\Microsoft\Windows\DWM';                            v='AccentColor';     d=0xFF14B8A6L; t='dword'}
       @{k='Software\Microsoft\Windows\DWM';                            v='ColorizationColor'; d=0xC414B8A6L; t='dword'}
       @{k='Software\Microsoft\Windows\DWM';                            v='ColorPrevalence'; d=0; t='dword'}
     ) }

  @{ Key='acento-ambar'; Name='Color de acento: ambar'; Rec=$false
     Note='Paleta completa. Excluyente con las otras opciones de acento.'
     Regs=@(
       @{k='Software\Microsoft\Windows\CurrentVersion\Explorer\Accent'; v='AccentColorMenu'; d=0xFFF59E0BL; t='dword'}
       @{k='Software\Microsoft\Windows\DWM';                            v='AccentColor';     d=0xFFF59E0BL; t='dword'}
       @{k='Software\Microsoft\Windows\DWM';                            v='ColorizationColor'; d=0xC4F59E0BL; t='dword'}
       @{k='Software\Microsoft\Windows\DWM';                            v='ColorPrevalence'; d=0; t='dword'}
     ) }

  @{ Key='acento-en-taskbar'; Name='Color de acento tambien en taskbar y bordes'; Rec=$false
     Note='Pinta la barra de tareas con el color elegido en vez de negro/blanco.'
     Regs=@(
       @{k='Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; v='ColorPrevalence'; d=1; t='dword'}
     ) }

  # ---------------------------------------------------------------- ARRANQUE
  @{ Key='sin-sonido-inicio'; Name='Sin sonido de arranque de Windows'; Rec=$true
     Note='Silencia el jingle del boot. OJO: este va en HKLM (es de maquina, no de usuario).'
     Machine=$true
     Regs=@(
       @{k='SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\BootAnimation'; v='DisableStartupSound'; d=1; t='dword'}
     ) }
)

# ---------------------------------------------------------------------------
# Grupos EXCLUYENTES: la TUI permite marcar solo uno de cada grupo.
# Sin esto, alguien marca los tres acentos y gana el ultimo que se escriba,
# que es justo el tipo de resultado silencioso e inexplicable que queremos evitar.
# ---------------------------------------------------------------------------
$Global:PersonalizacionExclusivos = @(
  @('acento-violeta', 'acento-teal', 'acento-ambar')
)

# ---------------------------------------------------------------------------
# WALLPAPER
#   Si pones una imagen en config\wallpaper\ (jpg o png), la fase de
#   personalizacion la copia al WIM y la deja como fondo por defecto.
#   Se cambia con click derecho en el escritorio, como siempre.
# ---------------------------------------------------------------------------
$Global:WallpaperDir = 'config\wallpaper'
