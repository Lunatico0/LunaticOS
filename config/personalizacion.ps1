#requires -Version 5.1
<#
  personalizacion.ps1 -- Estetica de LunaticOS.

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
            k = subclave - v = nombre - d = dato - t = tipo (dword|sz)
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
  # ###################################################################
  #  EL COLOR SE DECLARA UNA SOLA VEZ, EN HEX, EN EL CAMPO 'Accent'.
  #  NO pongas Regs de color aca. NO escribas DWORDs de color en ningun archivo.
  #
  #  POR QUE: el acento no es un solo valor de registro, son seis (AccentColor,
  #  AccentColorInactive, AccentColorMenu, StartColorMenu, ColorizationColor,
  #  ColorizationAfterglow) mas AccentPalette, un blob de 32 bytes con 8 tonos.
  #  Y NO TODOS USAN EL MISMO ORDEN DE BYTES: AccentColor es ABGR y
  #  ColorizationColor es ARGB, en la misma clave del registro.
  #
  #  Este archivo tenia los DWORD escritos a mano, todos en ARGB. Resultado medido:
  #  el teal #14B8A6 se veia como #A6B814 (un verde lima) en la taskbar y los
  #  bordes, mientras que otras partes de la UI si lo tomaban teal. Eso es
  #  exactamente el "coloreado a la fuerza" que reporto el usuario: la UI con dos
  #  colores distintos al mismo tiempo.
  #
  #  QUIEN LO APLICA AHORA: la fase 10 genera un LunaticOS.theme y apunta
  #  HKLM\...\Themes\InstallTheme ahi. Windows aplica ese tema al crear el perfil
  #  con SU PROPIO motor, que deriva la paleta de 8 tonos correctamente. Nosotros
  #  no calculamos ningun tono: el escalado lineal en RGB que haciamos antes daba
  #  colores quemados que no coincidian con los que genera Settings.
  #  Y sigue siendo REVERSIBLE: es un tema, no una policy. El usuario elige otro
  #  color o otro tema desde Settings cuando quiera.
  #
  #  La conversion a los formatos de registro vive en UN solo lugar:
  #  ConvertTo-AccentDwords, en scripts\lib.ps1.
  #  Tabla completa de formatos y la evidencia: docs\personalizacion-contrato.md
  # ###################################################################
  @{ Key='acento-violeta'; Name='Color de acento: violeta'; Rec=$false
     Accent='#8B5CF6'
     Note='Lo aplica el tema de LunaticOS, con la paleta completa que deriva Windows. Podes cambiarlo despues en Settings > Personalization > Colors.' }

  @{ Key='acento-teal'; Name='Color de acento: teal'; Rec=$false
     Accent='#14B8A6'
     Note='Lo aplica el tema de LunaticOS. Excluyente con las otras opciones de acento.' }

  @{ Key='acento-ambar'; Name='Color de acento: ambar'; Rec=$false
     Accent='#F59E0B'
     Note='Lo aplica el tema de LunaticOS. Excluyente con las otras opciones de acento.' }

  @{ Key='acento-en-taskbar'; Name='Color de acento tambien en taskbar y bordes'; Rec=$false
     Note='Pinta la barra de tareas con el color elegido en vez de negro/blanco. OJO: Windows SOLO lo permite con el tema OSCURO. Con tema claro queda en gris en Settings y no hace nada: es de Windows, no un error nuestro.'
     Regs=@(
       # Esto NO es un color, es un interruptor: por eso si va como Regs.
       @{k='Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; v='ColorPrevalence'; d=1; t='dword'}
     ) }

  # ---------------------------------------------------------------- ARRANQUE
  @{ Key='sin-sonido-inicio'; Name='Sin sonido de arranque de Windows'; Rec=$true
     Note='Silencia el jingle del boot. OJO: este va en HKLM (es de maquina, no de usuario).'
     Machine=$true
     Regs=@(
       # ###################################################################
       #  LA RUTA ARRANCA EN 'Microsoft\', SIN EL PREFIJO 'SOFTWARE\'.
       #
       #  Los items con Machine=$true se escriben sobre el hive SOFTWARE ya
       #  montado, asi que la ruta es RELATIVA A LA RAIZ DE ESE HIVE -- igual que
       #  las de usuario son relativas a la raiz de NTUSER.DAT.
       #
       #  Este valor tenia el prefijo 'SOFTWARE\' de mas y terminaba escribiendose
       #  en SOFTWARE\SOFTWARE\Microsoft\..., una rama que Windows no lee nunca.
       #  O sea: la opcion NUNCA FUNCIONO, y fallaba en silencio porque
       #  `reg.exe add` devuelve 0 igual cuando la clave no existe: la crea.
       #  Un exit code 0 no significa "surtio efecto".
       # ###################################################################
       @{k='Microsoft\Windows\CurrentVersion\Authentication\LogonUI\BootAnimation'; v='DisableStartupSound'; d=1; t='dword'}
     ) }
)

# ---------------------------------------------------------------------------
# Grupos EXCLUYENTES: la TUI permite marcar solo uno de cada grupo.
# Sin esto, alguien marca los tres acentos y gana el ultimo que se escriba,
# que es justo el tipo de resultado silencioso e inexplicable que queremos evitar.
# ---------------------------------------------------------------------------
# ###################################################################
#  LA COMA DE `@( ,@(...) )` NO ES UN TYPO. NO LA SAQUES.
#
#  PowerShell APLANA un array que contiene un solo array. MEDIDO en PS 5.1:
#      @( @(1,2,3) ).Count       = 3    <-- el grupo se deshizo en 3 strings
#      @( @(1,2), @(3,4) ).Count = 2    <-- con DOS grupos NO se aplana
#      @( ,@(1,2,3) ).Count      = 1    <-- la coma lo salva
#
#  O sea: mientras hubo UN solo grupo excluyente, esta variable no contenia un
#  grupo de tres claves, contenia TRES CLAVES SUELTAS. Y con `$grp` valiendo el
#  string 'acento-teal', el `-contains` es una simple igualdad y el
#  `foreach ($other in $grp)` itera una sola vez con el mismo key: NO HAY HERMANO
#  A QUIEN DESMARCAR.
#
#  Sintoma real que llegaba al usuario: se podian marcar los TRES acentos a la vez,
#  y ganaba el ultimo que se escribiera. Justo el resultado silencioso e
#  inexplicable que los grupos excluyentes existen para evitar.
#
#  Y el self-test daba VERDE, porque solo verificaba que las claves existieran en
#  el catalogo: `foreach ($k in 'un-string')` itera una vez con el string entero.
#  El test media la existencia de las claves, no la ESTRUCTURA del grupo.
#
#  La TUI ademas normaliza esto por su cuenta (Resolve-TuiExclusive), asi que hoy
#  funciona igual. Pero un dato que miente sobre su propia forma es una trampa para
#  el proximo que lo lea: aca queda declarado como lo que es.
# ###################################################################
$Global:PersonalizacionExclusivos = @(
  , @('acento-violeta', 'acento-teal', 'acento-ambar')
)

# ---------------------------------------------------------------------------
# WALLPAPER
#   Si pones una imagen en config\wallpaper\ (jpg o png), la fase de
#   personalizacion la copia al WIM y la deja como fondo por defecto.
#   Se cambia con click derecho en el escritorio, como siempre.
# ---------------------------------------------------------------------------
$Global:WallpaperDir = 'config\wallpaper'
