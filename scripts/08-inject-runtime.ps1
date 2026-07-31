#requires -Version 5.1
<#
  Fase 8 - Inyeccion de runtime:
    1) SetupComplete.cmd  -> dentro del WIM en Windows\Setup\Scripts\ (corre al final del setup)
    2) autounattend.xml   -> en la RAIZ del arbol de la ISO (lo lee el instalador)
  Ambos templates viven en config\ (versionados). Este script solo los copia a su lugar.

  El autounattend.xml se valida como XML antes de copiarlo: un XML mal formado (o
  sin el pass windowsPE) hace que el instalador lo descarte SIN AVISAR y se pierden
  los tres pases. Nos paso una vez; no queremos que pase de nuevo.

  ===========================================================================
  MODO TEST (-TestUnattend / LUNATICOS_TEST_UNATTEND=1)

  Hay DOS autounattend en config\ y este script elige uno:

    config\autounattend.xml       PRODUCCION. Sin DiskConfiguration: el disco lo
                                  elige el usuario a mano. ES EL DEFAULT.
    config\autounattend-test.xml  SOLO TEST EN VM. Con DiskConfiguration:
                                  FORMATEA EL DISCO 0 SIN PREGUNTAR.

  El de test existe porque el setup de Windows 11, sin DiskConfiguration, se para
  en "Select location to install Windows 11" y espera un CLIC HUMANO. El teclado
  sintetico de Hyper-V no llega a WinPE (5 intentos, todos con ReturnValue=0 y cero
  efecto: ReturnValue=0 miente), asi que no hay clic que automatizar. La unica
  salida es que la pantalla no aparezca. Ver docs\testing-e2e.md seccion 1.

  ELEGIR EL DE TEST TIENE QUE SER DIFICIL DE HACER SIN QUERER, porque el costo de
  equivocarse es el disco de alguien. Por eso NO hay deteccion automatica, NO es
  default y NO alcanza con que el archivo exista: hay que pedirlo explicito, de una
  de estas dos formas:

    scripts\08-inject-runtime.ps1 -TestUnattend      (a mano, una fase sola)
    $env:LUNATICOS_TEST_UNATTEND = '1'               (el runner del E2E)

  La variable de entorno tiene que valer EXACTAMENTE '1'. Un '0', un 'false' o un
  string vacio NO activan nada. Es la unica forma que sirve para el pipeline
  completo: la TUI corre las fases con `& $path`, sin argumentos, y una variable de
  entorno se ve igual en el mismo proceso y en un proceso hijo.

  Ademas se puede validar sin escribir nada:

    scripts\08-inject-runtime.ps1 -ValidateOnly

  que pasa LOS DOS archivos por todas las guardas y sale 0/1. Cuesta un segundo y
  ahorra descubrir un unattend roto a los 40 minutos de build.

  ===========================================================================
  LA CUENTA DE USUARIO (perfil.json -> usuario.crear / usuario.nombre)

  El nombre de la cuenta NO se edita mas a mano en config\autounattend.xml: lo
  elige el usuario en la TUI y esta fase lo inyecta, SOBRE UNA COPIA EN MEMORIA,
  igual que la clave de producto. config\autounattend.xml NUNCA se modifica.

  Por que se elige antes de instalar y no despues: renombrar una cuenta de Windows
  NO renombra la CARPETA del perfil. C:\Users\pato se queda 'pato' para siempre.

  Dos caminos, los dos del contrato (docs\contrato-cuenta-usuario.md):

    usuario.crear = true   -> se reemplazan <Name> y <DisplayName> de la
                              LocalAccount con el nombre elegido. El OOBE no
                              pregunta nada. ES EL DEFAULT.
    usuario.crear = false  -> se quita el bloque <UserAccounts> COMPLETO y
                              ademas <HideLocalAccountScreen>, para que el OOBE
                              muestre la pantalla de cuenta.

  EL COSTO DE crear = false, QUE SE LOGUEA EN AMARILLO AL GENERAR LA ISO:
  Windows 11 24H2 y 25H2 ya no traen bypassnro.cmd (Microsoft lo saco). Sin cuenta
  local en el autounattend, el OOBE EXIGE cuenta Microsoft y conexion a internet.
  Para hacer cuenta local hay que apretar Shift+F10 en el OOBE y escribir
  "start ms-cxh:localonly". Ofrecer la opcion sin decir eso es tenderle una trampa
  al usuario, asi que el aviso sale con el comando exacto.

  config\autounattend-test.xml NO SE TOCA POR ESTA VIA, y no depende de que el
  call site se acuerde: Set-UnattendCuenta MISMA se niega a tocar un documento que
  tenga DiskConfiguration o AutoLogon (los dos son exclusivos del de test, y las
  guardas 6 y 8 lo garantizan en los dos sentidos). Su cuenta lleva password fijo
  porque PowerShell Direct no funciona sin password y el E2E depende de eso.

  Se puede probar todo esto sin build, sin ISO y sin VM:

    scripts\08-inject-runtime.ps1 -SelfTest

  que corre los dos caminos sobre copias, verifica por hash que los archivos del
  repo no se movieron, y prueba POR MUTACION que las guardas rechazan un bloque de
  cuenta mal quitado (un <LocalAccounts> huerfano, una remocion a medias).
  ===========================================================================
#>
param(
  # Usa config\autounattend-test.xml en vez del de produccion. LA ISO RESULTANTE
  # FORMATEA EL DISCO 0 DE LO QUE LA BOOTEE. Solo para VM descartable.
  [switch]$TestUnattend,
  # Corre todas las guardas sobre los dos autounattend y sale. No toca nada.
  [switch]$ValidateOnly,
  # Corre los dos caminos de la cuenta de usuario sobre COPIAS y sale 0/1.
  # No monta nada, no escribe en el arbol de la ISO, no necesita el WIM.
  [switch]$SelfTest
)

. "$PSScriptRoot\config.ps1"
. "$PSScriptRoot\lib.ps1"
$mount     = $CFG.Mount
$wimMounted = Test-Path (Join-Path $mount 'Windows')

$AuProd   = Join-Path $CFG.Root 'config\autounattend.xml'
$AuTest   = Join-Path $CFG.Root 'config\autounattend-test.xml'
$MarcaIso = 'LUNATICOS-TEST-ISO.txt'

# El aviso de la cabecera del archivo de test es parte del contrato: si alguien lo
# borra, el archivo deja de gritar lo que hace. Se verifica que siga ahi.
$MarcasAviso = @('SOLO PARA TEST EN VM', 'FORMATEA EL DISCO 0')

# --------------------------------------------------------------------------
#  Helpers de XPath. TODO nombre va envuelto en local-name(): el unattend declara
#  un namespace por defecto (urn:schemas-microsoft-com:unattend) y un XPath sin
#  local-name() NO ENCUENTRA NADA. Eso no falla ruidoso: devuelve $null y la
#  guarda queda de adorno, aprobando cualquier cosa. Concentrarlo en dos
#  funciones es lo que evita que el proximo XPath se escriba mal.
#  Las comillas del XPath son SIMPLES para poder interpolar desde PowerShell con
#  comillas dobles sin anidar comillas.
# --------------------------------------------------------------------------
function Get-XNode($Node, [string]$Ruta) {
  if (-not $Node) { return $null }
  $xp = (($Ruta -split '/') | ForEach-Object { "*[local-name()='$_']" }) -join '/'
  return $Node.SelectSingleNode($xp)
}
#  OJO CON EL RESULTADO DE Get-XNodes: ENVOLVELO SIEMPRE EN @() EN EL CALL SITE.
#  PowerShell devuelve un solo elemento sin array cuando hay uno solo, y sobre un
#  XmlElement el adaptador de XML resuelve `.Count` como si fuera un HIJO llamado
#  "Count": no existe, devuelve $null, y una guarda que compara $null -ne 1 acusa
#  un error que no esta. Paso aca mismo: "DiskConfiguration tiene  <Disk> y se
#  espera exactamente 1", con el numero vacio, sobre un archivo correcto.
function Get-XNodes($Node, [string]$Ruta) {
  if (-not $Node) { return @() }
  $xp = (($Ruta -split '/') | ForEach-Object { "*[local-name()='$_']" }) -join '/'
  return @($Node.SelectNodes($xp))
}
# Texto de un descendiente, o '' si no esta. Nunca $null: asi las comparaciones
# no dependen de si el nodo existe.
function Get-XText($Node, [string]$Ruta) {
  $n = Get-XNode $Node $Ruta
  if (-not $n) { return '' }
  return "$($n.InnerText)".Trim()
}

# ===========================================================================
#  GUARDAS DEL AUTOUNATTEND
#
#  Un autounattend roto NO falla de frente: falla 20 o 40 minutos despues, adentro
#  del instalador, y de dos maneras distintas segun el defecto:
#
#   a) XML mal formado, o sin el pass windowsPE -> el setup lo DESCARTA ENTERO, en
#      silencio, y sigue como si no existiera (D14). Sintomas: pide product key,
#      pide idioma y teclado, BypassNRO no se escribe y UserLocale queda en en-US.
#      Un solo defecto, cuatro sintomas, y ninguno menciona al unattend.
#   b) un setting en el componente equivocado -> "The provided unattend file is
#      not valid; hrResult = 0x80220001" y la instalacion ABORTA a mitad de camino
#      con "The computer restarted unexpectedly" (D15). Un setting que no existe en
#      su componente NO se ignora: invalida el archivo entero.
#
#  Las dos cuestan una instalacion completa para descubrirse. Por eso se valida
#  ACA, antes de armar la ISO, y por eso las guardas corren sobre LOS DOS archivos,
#  no solo sobre el de produccion: si el de test esta mal armado, mejor enterarse
#  ahora que a mitad de una instalacion desatendida que nadie esta mirando.
#
#  Devuelve el XmlDocument cargado si pasa TODO, o $null (ya imprimio el detalle
#  en rojo) si no.
# ===========================================================================
function Get-Unattend {
  param(
    [Parameter(Mandatory)][string]$Path,
    [bool]$EsTest = $false,
    # Como se lo nombra en los mensajes. Existe porque esta funcion valida DOS
    # archivos que se llaman igual: config\autounattend.xml y la copia que quedo en
    # la raiz de la ISO. Dos "autounattend.xml OK" seguidos, sin distinguir cual es
    # cual, no son evidencia de nada.
    [string]$Rotulo = ''
  )

  $nombre = if ($Rotulo -ne '') { $Rotulo } else { Split-Path $Path -Leaf }
  if (-not (Test-Path $Path)) {
    Write-Host "ERROR: no existe $Path" -ForegroundColor Red
    return $null
  }

  $doc = New-Object System.Xml.XmlDocument
  # PreserveWhitespace: el documento que devuelve esta funcion es el mismo que se
  # MODIFICA y se guarda en la raiz de la ISO. Con el default ($false), Save()
  # reformatea todo: se lleva las lineas en blanco y junta los atributos de cada
  # <component> en una sola linea. Ese archivo es lo unico que puede leer alguien
  # que quiera entender que hizo el instalador, y los comentarios de este repo son
  # su memoria. Medido el 2026-07-31 sobre config\autounattend.xml: 9643 bytes y 24
  # lineas en blanco el original, 9501 bytes y 14 lineas en blanco reformateado (los
  # numeros se mueven cuando el archivo cambia; la diferencia no). Ver Save-Unattend,
  # que es la otra mitad de esto.
  $doc.PreserveWhitespace = $true
  try { $doc.Load($Path) }
  catch {
    Write-Host "ERROR: $nombre no es XML valido -> $($_.Exception.Message)" -ForegroundColor Red
    return $null
  }

  $err = @()

  # --- 1) El pass windowsPE (D14) -----------------------------------------
  $passes = @($doc.unattend.settings | ForEach-Object { $_.pass })
  if ($passes -notcontains 'windowsPE') {
    $err += "le falta el pass 'windowsPE': el instalador DESCARTA EL ARCHIVO ENTERO"
  }

  # --- 2) Settings en el componente equivocado (D15) ----------------------
  #  Cada entrada es "setting -> unico componente que lo acepta".
  $homes = @{
    'RunSynchronous'    = 'Microsoft-Windows-Deployment'
    'RunAsynchronous'   = 'Microsoft-Windows-Deployment'
    'UserAccounts'      = 'Microsoft-Windows-Shell-Setup'
    'OOBE'              = 'Microsoft-Windows-Shell-Setup'
    'AutoLogon'         = 'Microsoft-Windows-Shell-Setup'
    'UserData'          = 'Microsoft-Windows-Setup'
    'DiskConfiguration' = 'Microsoft-Windows-Setup'
    'ImageInstall'      = 'Microsoft-Windows-Setup'
  }
  foreach ($s in $doc.unattend.settings) {
    foreach ($c in @($s.component)) {
      if (-not $c) { continue }
      foreach ($k in $homes.Keys) {
        if ($c.$k -and $c.name -ne $homes[$k]) {
          $err += "pass '$($s.pass)': <$k> esta en '$($c.name)' y va en '$($homes[$k])'"
        }
      }
    }
  }

  # =========================================================================
  #  3) NODOS HUERFANOS: cada elemento, DEBAJO DEL PADRE QUE LE CORRESPONDE.
  #
  #  Esta guarda existe por la remocion del bloque de cuenta (usuario.crear=false).
  #  Quitar un bloque XML tiene una forma de salir mal que no se ve: se quita el
  #  padre y quedan los hijos, o se quita el hijo y queda el padre vacio. Un
  #  <LocalAccounts> colgado directo del <component> es EXACTAMENTE el defecto D15:
  #
  #    SMI data results dump: Description = Setting is not defined in this component.
  #    The provided unattend file is not valid; hrResult = 0x80220001
  #
  #  y eso ABORTA la instalacion a mitad de camino con "The computer restarted
  #  unexpectedly". La guarda 2 no lo agarra: mira una lista de settings de primer
  #  nivel, y 'LocalAccounts' no es uno de esos (solo existe DENTRO de UserAccounts).
  #
  #  Se mide la CLASE, no el caso: por cada nombre cuyo padre es UNICO y conocido,
  #  se verifica el padre real. Asi cae cualquier remocion a medias, no solo la que
  #  ya vimos. SOLO van en el mapa los nombres cuyo padre no es ambiguo:
  #  <UILanguage> queda afuera porque es hijo de <component> Y de <SetupUILanguage>,
  #  y <Order>, <Type> o <WillShowUI> viven en varios lugares distintos.
  # =========================================================================
  $padres = @{
    'UserAccounts'              = @('component')
    'AdministratorPassword'     = @('UserAccounts')
    'LocalAccounts'             = @('UserAccounts')
    'DomainAccounts'            = @('UserAccounts')
    'LocalAccount'              = @('LocalAccounts')
    'DisplayName'               = @('LocalAccount')
    'Group'                     = @('LocalAccount')
    'Password'                  = @('LocalAccount', 'AutoLogon')
    'OOBE'                      = @('component')
    'HideEULAPage'              = @('OOBE')
    'HideOEMRegistrationScreen' = @('OOBE')
    'HideOnlineAccountScreens'  = @('OOBE')
    'HideLocalAccountScreen'    = @('OOBE')
    'HideWirelessSetupInOOBE'   = @('OOBE')
    'ProtectYourPC'             = @('OOBE')
    'AutoLogon'                 = @('component')
    'RunSynchronous'            = @('component')
    'RunSynchronousCommand'     = @('RunSynchronous')
    'UserData'                  = @('component')
    'ProductKey'                = @('UserData')
    'AcceptEula'                = @('UserData')
    'DiskConfiguration'         = @('component')
    'Disk'                      = @('DiskConfiguration')
    'CreatePartitions'          = @('Disk')
    'CreatePartition'           = @('CreatePartitions')
    'ModifyPartitions'          = @('Disk')
    'ModifyPartition'           = @('ModifyPartitions')
    'ImageInstall'              = @('component')
    'OSImage'                   = @('ImageInstall')
    'InstallTo'                 = @('OSImage')
  }
  # '//*' matchea elementos de CUALQUIER namespace, asi que aca no hace falta
  # local-name(): el wildcard ya lo cubre. LocalName es el nombre sin prefijo.
  foreach ($el in @($doc.SelectNodes('//*'))) {
    $ln = "$($el.LocalName)"
    if (-not $padres.ContainsKey($ln)) { continue }
    $pn = if ($el.ParentNode) { "$($el.ParentNode.LocalName)" } else { '(sin padre)' }
    if ($padres[$ln] -notcontains $pn) {
      $err += ("<{0}> esta colgado de <{1}> y solo es valido dentro de <{2}>: " -f $ln, $pn, ($padres[$ln] -join '> o <')) +
              'un setting en el lugar equivocado NO se ignora, invalida el archivo entero (hrResult = 0x80220001)'
    }
  }

  # =========================================================================
  #  4) LA CUENTA Y LA PANTALLA DE CUENTA DEL OOBE TIENEN QUE SER COHERENTES.
  #
  #  Son dos settings separados que describen UNA sola decision, y las dos
  #  combinaciones incoherentes dejan al usuario sin poder crear ninguna cuenta:
  #
  #   a) <UserAccounts> sin ninguna <LocalAccount> adentro: el bloque esta pero no
  #      crea nada. Con HideLocalAccountScreen puesto, el OOBE tampoco la pide.
  #   b) sin <UserAccounts> pero con <HideLocalAccountScreen>true</...>: nadie crea
  #      la cuenta Y el OOBE esconde la pantalla para crearla. Callejon sin salida.
  #
  #  (b) es justo lo que queda si alguien quita el bloque de cuenta y se olvida del
  #  HideLocalAccountScreen, que es la mitad mas facil de olvidar porque esta en
  #  otro nodo. El sintoma no seria un error: seria un OOBE que no ofrece salida.
  # =========================================================================
  $ua      = Get-XNode  $doc 'unattend/settings/component/UserAccounts'
  $cuentas = @(Get-XNodes $doc 'unattend/settings/component/UserAccounts/LocalAccounts/LocalAccount')
  $hideLA  = Get-XNode  $doc 'unattend/settings/component/OOBE/HideLocalAccountScreen'
  if ($ua -and $cuentas.Count -eq 0) {
    $err += 'tiene <UserAccounts> pero NINGUNA <LocalAccount> adentro: el bloque no crea ninguna cuenta. ' +
            'Si la idea es que la cuenta la pida el OOBE, hay que quitar <UserAccounts> ENTERO'
  }
  if (-not $ua -and $hideLA -and "$($hideLA.InnerText)".Trim().ToLowerInvariant() -eq 'true') {
    $err += 'no crea ninguna cuenta (no hay <UserAccounts>) y ADEMAS trae ' +
            '<HideLocalAccountScreen>true</HideLocalAccountScreen>: el OOBE esconde la pantalla de cuenta local ' +
            'y no hay cuenta creada por el unattend. El usuario se queda sin ninguna forma de crear su cuenta'
  }

  # --- 5) El nodo donde se inyecta la clave del usuario -------------------
  if (-not (Get-XNode $doc 'unattend/settings/component/UserData/ProductKey/Key')) {
    $err += 'no tiene UserData/ProductKey/Key: la fase 8 inyecta ahi la clave de clave-windows.txt'
  }

  # =========================================================================
  #  6) DiskConfiguration: LA GUARDA QUE MAS IMPORTA, Y VA EN LOS DOS SENTIDOS.
  #
  #  Produccion NO puede tenerlo: una ISO que se graba a un USB y se bootea en
  #  una maquina real le borraria el disco al usuario, sin preguntar y sin vuelta
  #  atras. Es la unica decision de este repo que es irreversible.
  #
  #  El de test SI tiene que tenerlo: sin DiskConfiguration el setup se para
  #  esperando un clic, el runner del E2E espera hasta el timeout y el resultado
  #  no es "falla" sino 35 minutos tirados sin ninguna medicion.
  # =========================================================================
  $dc = Get-XNode $doc 'unattend/settings/component/DiskConfiguration'
  if ($EsTest -and -not $dc) {
    $err += 'es el unattend de TEST y NO tiene DiskConfiguration: el setup se va a parar en ' +
            '"Select location to install Windows 11" esperando un clic que nadie puede dar'
  }
  if (-not $EsTest -and $dc) {
    $err += 'es el unattend de PRODUCCION y TIENE DiskConfiguration: esa ISO le FORMATEA EL ' +
            'DISCO a cualquiera que la bootee. Saca ese bloque.'
  }

  # --- 7) Coherencia del layout de particiones ----------------------------
  #  Un layout mal armado no dice "el layout esta mal": el setup falla de formas
  #  que no se parecen a la causa, o instala sobre la particion equivocada.
  if ($dc) {
    $discos = @(Get-XNodes $dc 'Disk')
    if ($discos.Count -ne 1) {
      $err += "DiskConfiguration tiene $($discos.Count) <Disk> y se espera exactamente 1 (el disco 0)"
    } else {
      $d      = $discos[0]
      $diskId = Get-XText $d 'DiskID'

      if ((Get-XText $d 'WillWipeDisk').ToLowerInvariant() -ne 'true') {
        $err += 'el <Disk> no tiene WillWipeDisk=true: sin eso el particionado falla si el disco ya traia particiones'
      }

      # CreatePartition: <Order> ES el orden fisico. Tiene que ser 1..N, sin
      # huecos ni repetidos.
      $creates = @(Get-XNodes $d 'CreatePartitions/CreatePartition')
      $ordTxt  = @($creates | ForEach-Object { Get-XText $_ 'Order' })
      $tipos   = @($creates | ForEach-Object { Get-XText $_ 'Type' })
      # El <Order> se compara como TEXTO y se castea solo despues de verificar que
      # sea numerico. Un [int]'' es un error de conversion TERMINANTE: reventaria
      # la fase en vez de reportar el problema, que es justo lo contrario de lo
      # que tiene que hacer una guarda.
      if ($creates.Count -eq 0) {
        $err += 'DiskConfiguration no crea ninguna particion'
      } elseif (@($ordTxt | Where-Object { $_ -notmatch '^\d+$' }).Count) {
        $err += "hay CreatePartition sin <Order> numerico: [$($ordTxt -join ',')]"
      } else {
        $ordStr = (@([int[]]$ordTxt | Sort-Object) -join ',')
        $expStr = (@(1..$creates.Count) -join ',')
        if ($ordStr -ne $expStr) {
          $err += "los <Order> de CreatePartition son [$ordStr] y tendrian que ser [$expStr]"
        }
      }

      # GPT/UEFI: exactamente un ESP y exactamente una MSR.
      foreach ($t in @('EFI', 'MSR')) {
        $n = @($tipos | Where-Object { $_ -eq $t }).Count
        if ($n -ne 1) { $err += "hay $n particiones de tipo $t y se espera exactamente 1 (layout GPT/UEFI)" }
      }

      # <Extend> se come TODO el resto del disco: si no es la ultima, las que
      # vienen despues se quedan sin espacio.
      $extends = @($creates | Where-Object { Get-XNode $_ 'Extend' })
      if ($extends.Count -ne 1) {
        $err += "hay $($extends.Count) particiones con <Extend> y se espera exactamente 1 (la ultima)"
      } else {
        $oExt = Get-XText $extends[0] 'Order'
        if ($oExt -ne "$($creates.Count)") {
          $err += "la particion con <Extend> es la #$oExt de $($creates.Count): tiene que ser la ULTIMA o las que siguen quedan sin espacio"
        }
      }

      $mods = @(Get-XNodes $d 'ModifyPartitions/ModifyPartition')

      # La particion de Windows es la que lleva letra C, e InstallTo TIENE que
      # apuntar a ESA. Con WinRE en la particion 1, este es justo el numero facil
      # de escribir mal, y el sintoma no dice "elegiste la particion equivocada".
      $modC = @($mods | Where-Object { (Get-XText $_ 'Letter').ToUpperInvariant() -eq 'C' })
      if ($modC.Count -ne 1) {
        $err += "hay $($modC.Count) ModifyPartition con <Letter>C</Letter> y se espera exactamente 1 (la de Windows)"
      } else {
        $pidWin  = Get-XText $modC[0] 'PartitionID'
        $tipoWin = @($creates | Where-Object { (Get-XText $_ 'Order') -eq $pidWin } |
                                ForEach-Object { Get-XText $_ 'Type' })
        if ($tipoWin.Count -ne 1 -or $tipoWin[0] -ne 'Primary') {
          $err += "la particion C: es la #$pidWin y su CreatePartition no es <Type>Primary</Type> (dice '$($tipoWin -join ',')')"
        }

        $it = Get-XNode $doc 'unattend/settings/component/ImageInstall/OSImage/InstallTo'
        if (-not $it) {
          $err += 'hay DiskConfiguration pero no hay ImageInstall/OSImage/InstallTo: el setup no sabe donde instalar y vuelve a preguntar'
        } else {
          $itDisk = Get-XText $it 'DiskID'
          $itPart = Get-XText $it 'PartitionID'
          if ($itDisk -ne $diskId) { $err += "InstallTo/DiskID=$itDisk pero el <Disk> configurado es el $diskId" }
          if ($itPart -ne $pidWin) {
            $err += "InstallTo/PartitionID=$itPart pero la particion de Windows (la que lleva C:) es la $pidWin"
          }
        }
      }

      # El ESP tiene que quedar en FAT32: es de donde bootea el firmware UEFI.
      $ordEfi = @($creates | Where-Object { (Get-XText $_ 'Type') -eq 'EFI' } |
                             ForEach-Object { Get-XText $_ 'Order' })
      if ($ordEfi.Count -eq 1) {
        $modEfi = @($mods | Where-Object { (Get-XText $_ 'PartitionID') -eq $ordEfi[0] })
        if ($modEfi.Count -ne 1) {
          $err += "el ESP (particion $($ordEfi[0])) no tiene ModifyPartition: hay que formatearlo en FAT32"
        } elseif ((Get-XText $modEfi[0] 'Format').ToUpperInvariant() -ne 'FAT32') {
          $err += 'el ESP no queda formateado en FAT32: el firmware UEFI no puede bootear de ahi'
        }
      }

      # La MSR NO se puede modificar (Microsoft, textual: "Microsoft Reserved
      # (MSR) and Extended partitions cannot be modified"). Un ModifyPartition
      # apuntandole es un error de numeracion, y ese error arrastra a InstallTo.
      $ordMsr = @($creates | Where-Object { (Get-XText $_ 'Type') -eq 'MSR' } |
                             ForEach-Object { Get-XText $_ 'Order' })
      if ($ordMsr.Count -eq 1) {
        $modMsr = @($mods | Where-Object { (Get-XText $_ 'PartitionID') -eq $ordMsr[0] })
        if ($modMsr.Count -ne 0) {
          $err += "hay un ModifyPartition sobre la particion $($ordMsr[0]), que es la MSR y NO se puede modificar"
        }
      }
    }
  }

  # =========================================================================
  #  8) Solo el de test: la credencial.
  #
  #  PowerShell Direct (Invoke-Command -VMName) NO funciona con password vacio.
  #  Si el password se pierde, o el de AutoLogon se desincroniza del de la
  #  cuenta, el sintoma aparece DESPUES de 35 minutos de instalacion y es "no
  #  conecta" o "la VM quedo en el login": ninguno se parece a la causa.
  # =========================================================================
  if ($EsTest) {
    $la = Get-XNode $doc 'unattend/settings/component/UserAccounts/LocalAccounts/LocalAccount'
    if (-not $la) {
      $err += 'no crea ninguna LocalAccount: sin cuenta local el OOBE pide cuenta Microsoft y el test se cuelga ahi'
    } else {
      $u  = Get-XText $la 'Name'
      $pw = Get-XText $la 'Password/Value'
      if ($u -eq '')  { $err += 'la LocalAccount no tiene <Name>' }
      if ($pw -eq '') {
        $err += 'la LocalAccount tiene password VACIO: PowerShell Direct no funciona sin password, ' +
                'y ese es el unico motivo por el que este archivo existe aparte del de produccion'
      }

      $al = Get-XNode $doc 'unattend/settings/component/AutoLogon'
      if (-not $al) {
        $err += 'no tiene AutoLogon: la VM queda en la pantalla de login y nada de lo que corre en el ' +
                'primer login (apps por winget, tema) llega a correr; el E2E mediria una maquina a medio configurar'
      } else {
        $alEn = (Get-XText $al 'Enabled').ToLowerInvariant()
        $alU  = Get-XText $al 'Username'
        $alPw = Get-XText $al 'Password/Value'
        if ($alEn -ne 'true') { $err += "AutoLogon/Enabled='$alEn' y se espera 'true'" }
        if ($alU -ne $u)      { $err += "AutoLogon/Username='$alU' pero la cuenta local se llama '$u'" }
        if ($alPw -ne $pw)    { $err += 'el password de AutoLogon NO coincide con el de la cuenta local: el autologon falla en silencio' }
      }
    }

    # El aviso de la cabecera: que nadie lo borre y el archivo deje de gritar.
    $coms = @($doc.SelectNodes('//comment()'))
    $primerComentario = if ($coms.Count) { "$($coms[0].Value)" } else { '' }
    foreach ($m in $MarcasAviso) {
      if ($primerComentario -notlike "*$m*") {
        $err += "al primer comentario del archivo le falta el aviso '$m': ese aviso es lo unico que evita que alguien copie este archivo por error"
      }
    }
  }

  if ($err.Count) {
    Write-Host "ERROR: $nombre no paso las guardas:" -ForegroundColor Red
    $err | ForEach-Object { Write-Host "         $_" -ForegroundColor Red }
    return $null
  }

  $etiqueta = if ($EsTest) { 'TEST' } else { 'PRODUCCION' }
  Write-Step "$nombre OK ($etiqueta) - passes: $($passes -join ', ')" 'DarkGray'
  return $doc
}

# ===========================================================================
#  ESCRITURA DEL AUTOUNATTEND: SIN BOM Y SIN REFORMATEAR EL ARCHIVO.
#
#  $doc.Save($ruta) a secas hace dos cosas que no queremos, las dos medidas hoy
#  sobre config\autounattend.xml:
#
#   1) ESCRIBE UN BOM DE UTF-8 (EF BB BF). Los dos archivos de config\ NO tienen
#      BOM (medido: arrancan en 3C 3F 78, o sea "<?x"), y el unico autounattend
#      que se probo en una instalacion real es uno sin BOM. Un BOM no deberia
#      molestarle a ningun parser de XML, pero el modo de fallar de ESTE archivo
#      es que el instalador lo DESCARTE EN SILENCIO (D14): no es lugar para
#      estrenar una diferencia de bytes que nadie verifico. Y hasta hoy la
#      diferencia solo aparecia si el usuario tenia clave propia, o sea justo en
#      el camino menos transitado.
#   2) REFORMATEA: sin PreserveWhitespace se lleva las lineas en blanco (24 -> 14)
#      y junta los atributos de cada <component> en una sola linea. Ese archivo
#      queda en la RAIZ de la ISO y es lo unico que puede leer alguien que quiera
#      entender que hizo el instalador.
#
#  Con PreserveWhitespace=$true (lo pone Get-Unattend) el round trip da 9418 bytes
#  contra 9643, y la comparacion linea por linea da 25 lineas distintas que son
#  TODAS la apertura de los 5 <component>: los saltos de linea ENTRE ATRIBUTOS no
#  son nodos del DOM y no hay forma de preservarlos. Los comentarios, la
#  declaracion <?xml?> y las lineas en blanco quedan intactos.
#  (Medido el 2026-07-31; los bytes se mueven con el archivo, la diferencia no.)
# ===========================================================================
function Save-Unattend {
  param(
    [Parameter(Mandatory)]$Doc,
    [Parameter(Mandatory)][string]$Path
  )
  $enc = New-Object System.Text.UTF8Encoding($false)   # $false = SIN BOM
  $sw  = New-Object System.IO.StreamWriter($Path, $false, $enc)
  try { $Doc.Save($sw) } finally { $sw.Dispose() }
}

# ===========================================================================
#  LA CUENTA DE USUARIO: perfil.json -> el autounattend de la ISO
#
#  Contrato completo en docs\contrato-cuenta-usuario.md, secciones 2 y 6.
#
#  De donde sale el dato: $Global:UsuarioPerfil, que LunaticOS.ps1 llena desde
#  perfil.json antes de correr el pipeline. Las fases se invocan con `& $path`, o
#  sea en el MISMO runspace, asi que las $Global: se ven (es el mismo mecanismo que
#  usan $Global:AppxRemove en la fase 01 y $Global:PersonalizacionPicked en la 10).
#
#  Si no esta (la fase corrida a mano, sin TUI), se cae al comportamiento de
#  siempre: queda la cuenta que trae el template. Sin romper y sin inventar.
# ===========================================================================

# Lee un campo del perfil sin asumir el tipo del contenedor. $p.usuario es un
# [ordered]@{} (IDictionary) cuando viene de Import-Profile, pero si algun dia
# llega el JSON crudo es un PSCustomObject y $obj['clave'] no funcionaria.
function Get-PerfilCampo {
  param($Obj, [Parameter(Mandatory)][string]$Campo)
  if ($null -eq $Obj) { return $null }
  if ($Obj -is [System.Collections.IDictionary]) {
    if ($Obj.Contains($Campo)) { return $Obj[$Campo] }
    return $null
  }
  $prop = $Obj.PSObject.Properties[$Campo]
  if ($prop) { return $prop.Value }
  return $null
}

# OJO CON [bool] SOBRE UN STRING: [bool]'false' es $true (cualquier string no
# vacio lo es). ConvertFrom-Json devuelve booleanos de verdad, asi que hoy no
# pasa, pero un perfil editado a mano con "crear": "false" invertiria la decision
# del usuario EN SILENCIO, y el sintoma seria "elegi que la pida el OOBE y me creo
# la cuenta igual". El default es $true: los perfiles viejos no tienen la clave y
# el comportamiento de siempre es crear la cuenta.
function ConvertTo-BoolPerfil {
  param($Valor, [bool]$Default = $true)
  if ($null -eq $Valor) { return $Default }
  if ($Valor -is [bool]) { return $Valor }
  $t = "$Valor".Trim().ToLowerInvariant()
  if ($t -eq '') { return $Default }
  return ($t -notin @('false', '0', 'no', 'off'))
}

# ===========================================================================
#  VALIDACION DEL NOMBRE DE CUENTA (segunda linea de defensa)
#
#  La primera linea es la TUI, que valida mientras el usuario tipea (seccion 4 del
#  contrato). Esta es la segunda, y no es redundante: el perfil.json se EDITA A
#  MANO y se COMPARTE. Un nombre invalido no falla aca: falla creando la cuenta
#  DURANTE la instalacion, 40 minutos despues, y deja un OOBE roto.
#
#  Devuelve '' si el nombre sirve, o el motivo si no.
#
#  Lo que NO se puede chequear aca: que el nombre no sea igual al nombre del
#  EQUIPO. El autounattend no fija <ComputerName>, asi que el nombre del equipo lo
#  decide el setup en la maquina destino y no existe todavia. Eso lo chequea la
#  TUI contra el nombre de la maquina del usuario, que es lo unico verificable.
# ===========================================================================
function Test-NombreCuentaLocal {
  param([string]$Nombre)

  $n = "$Nombre"
  if ($n.Trim() -eq '')  { return 'esta vacio' }
  # 20 es el limite de SAM. Con 21 la creacion de la cuenta falla.
  if ($n.Length -gt 20)  { return "tiene $($n.Length) caracteres y el maximo de Windows es 20" }
  if ($n -ne $n.Trim())  { return 'empieza o termina con un espacio (genera perfiles raros)' }
  if ($n.EndsWith('.'))  { return 'termina en punto, y Windows lo rechaza' }
  if ($n -match '^[\.\s]+$') { return 'es solo puntos y/o espacios' }

  # Los que rechaza Windows:  " / \ [ ] : ; | = , + * ? < >
  $prohibidos = [regex]::Matches($n, '["/\\\[\]:;\|=,\+\*\?<>]') | ForEach-Object { $_.Value }
  if (@($prohibidos).Count) {
    return ("tiene caracteres que Windows no acepta: {0}" -f (($prohibidos | Select-Object -Unique) -join ' '))
  }

  $reservados = @('CON','PRN','AUX','NUL') +
                @(1..9 | ForEach-Object { "COM$_" }) +
                @(1..9 | ForEach-Object { "LPT$_" })
  if ($reservados -contains $n.ToUpperInvariant()) {
    return "'$n' es un nombre reservado por el sistema operativo"
  }
  # Cuentas y carpetas que YA existen en cualquier Windows: crear una con ese
  # nombre falla, o colisiona con C:\Users\Default.
  # -contains compara strings SIN distinguir mayusculas, asi que no hace falta
  # normalizar los dos lados: 'administrator' cae igual que 'Administrator'.
  $delSistema = @('Administrator','Administrador','Guest','Invitado','DefaultAccount',
                  'WDAGUtilityAccount','SYSTEM','Default','Public','All Users')
  if ($delSistema -contains $n) {
    return "'$n' es una cuenta (o una carpeta de perfil) que Windows ya trae"
  }
  return ''
}

# Avisos que NO bloquean: el nombre es valido, pero conviene que el usuario sepa
# en que se mete. La carpeta del perfil toma ese nombre TAL CUAL y no se puede
# renombrar despues.
function Get-AvisosNombreCuenta {
  param([string]$Nombre)
  $av = @()
  if ($Nombre -match '\s')            { $av += "'$Nombre' tiene espacios: la carpeta del perfil va a ser C:\Users\$Nombre, con espacios y todo" }
  if ($Nombre -match '[^\x00-\x7F]')  { $av += "'$Nombre' tiene caracteres no-ASCII: C:\Users\$Nombre puede romper herramientas viejas que no manejan rutas Unicode" }
  return $av
}

# ===========================================================================
#  Set-UnattendCuenta: aplica la decision del perfil SOBRE EL DOCUMENTO EN
#  MEMORIA. Nunca toca un archivo. Nunca toca config\autounattend.xml.
#
#  Devuelve un hashtable con lo que hizo, para poder loguearlo y para poder
#  verificarlo despues contra el archivo escrito (Test-CuentaAplicada).
#  Tira excepcion si el perfil pide algo imposible: mejor cortar el build ahora
#  que descubrirlo en el OOBE.
# ===========================================================================
function Set-UnattendCuenta {
  param(
    [Parameter(Mandatory)]$Doc,
    $Perfil
  )

  $res = @{
    Cambio  = $false       # hubo que modificar el documento?
    Crear   = $true        # que decidio el perfil
    Nombre  = ''
    Motivo  = ''           # de donde salio la decision (para el log)
    Resumen = ''
    Avisos  = @()
    Quitado = @()
    EsTest  = $false       # el documento es el autounattend de test -> no se toca
  }

  # =========================================================================
  #  GUARDA: ESTE CAMINO NO TOCA EL AUTOUNATTEND DE TEST. NUNCA.
  #
  #  El call site ya elige el archivo de produccion, pero esta guarda no depende de
  #  que el call site siga acordandose manana. Discriminar es facil y no tiene
  #  falsos positivos, porque las dos marcas estan garantizadas EN LOS DOS
  #  SENTIDOS por las guardas de Get-Unattend: DiskConfiguration es obligatorio en
  #  el de test y PROHIBIDO en el de produccion (guarda 6), y AutoLogon es
  #  obligatorio en el de test (guarda 8) y no existe en el de produccion.
  #
  #  Por que importa tanto: si el usuario elige "que la pida el OOBE" y esto le
  #  quitara la cuenta al de test, el E2E perderia PowerShell Direct y el AutoLogon,
  #  y el sintoma llegaria 35 minutos despues como "no conecta con la VM".
  # =========================================================================
  if ((Get-XNode $Doc 'unattend/settings/component/DiskConfiguration') -or
      (Get-XNode $Doc 'unattend/settings/component/AutoLogon')) {
    $res.Motivo  = 'es el unattend de TEST (tiene DiskConfiguration y/o AutoLogon)'
    $res.Nombre  = Get-XText $Doc 'unattend/settings/component/UserAccounts/LocalAccounts/LocalAccount/Name'
    $res.Resumen = "cuenta de TEST '$($res.Nombre)' intacta (password fijo + AutoLogon: el E2E depende de eso)"
    $res.EsTest  = $true
    return $res
  }

  # --- Sin perfil: comportamiento de siempre, el del template ---------------
  if ($null -eq $Perfil) {
    $res.Motivo  = 'no hay $Global:UsuarioPerfil (fase corrida a mano, sin la TUI)'
    $res.Nombre  = Get-XText $Doc 'unattend/settings/component/UserAccounts/LocalAccounts/LocalAccount/Name'
    $res.Resumen = "cuenta local '$($res.Nombre)' (la del template: no hay perfil cargado)"
    return $res
  }

  $res.Crear = ConvertTo-BoolPerfil (Get-PerfilCampo $Perfil 'crear') $true
  if ($null -eq (Get-PerfilCampo $Perfil 'crear')) {
    $res.Motivo = 'el perfil no trae usuario.crear (perfil viejo) -> se crea la cuenta, como siempre'
  } else {
    $res.Motivo = "el perfil dice usuario.crear = $($res.Crear)"
  }

  # =========================================================================
  #  CAMINO 1: crear la cuenta con el nombre elegido.
  # =========================================================================
  if ($res.Crear) {
    $nombre = "$(Get-PerfilCampo $Perfil 'nombre')".Trim()
    if ($nombre -eq '') {
      throw 'perfil.json pide crear la cuenta (usuario.crear = true) pero usuario.nombre esta vacio. ' +
            'Elegi un nombre en la TUI (opcion 7) o escribilo en perfil.json.'
    }
    $malo = Test-NombreCuentaLocal $nombre
    if ($malo -ne '') {
      throw ("perfil.json: usuario.nombre = '{0}' no sirve como nombre de cuenta de Windows: {1}. " -f $nombre, $malo) +
            'Con ese nombre la creacion de la cuenta falla DURANTE la instalacion y el OOBE queda roto, ' +
            'asi que se corta el build ahora.'
    }

    $la = Get-XNode $Doc 'unattend/settings/component/UserAccounts/LocalAccounts/LocalAccount'
    if (-not $la) {
      throw 'el autounattend no tiene UserAccounts/LocalAccounts/LocalAccount: no hay donde inyectar el nombre. ' +
            'Alguien le saco el bloque de cuenta a config\autounattend.xml.'
    }
    $nName = Get-XNode $la 'Name'
    $nDisp = Get-XNode $la 'DisplayName'
    # Los dos tienen que existir en el template. Crearlos aca seria peor: en el
    # esquema del unattend el ORDEN de los hijos importa (Name, DisplayName, Group,
    # Password) y un hijo en la posicion equivocada invalida el archivo entero.
    if (-not $nName -or -not $nDisp) {
      throw 'la LocalAccount del autounattend no tiene <Name> y <DisplayName>: los dos tienen que estar en el template.'
    }

    $viejo = "$($nName.InnerText)".Trim()
    $nName.InnerText = $nombre
    $nDisp.InnerText = $nombre

    $res.Nombre  = $nombre
    # Si el nombre elegido es el mismo que ya traia el template, NO hubo cambio: el
    # call site copia el archivo tal cual en vez de reescribirlo. Byte por byte.
    $res.Cambio  = ($viejo -ne $nombre)
    $res.Avisos  = @(Get-AvisosNombreCuenta $nombre)
    $res.Resumen = "cuenta local '$nombre' (Name y DisplayName inyectados desde el perfil)"
    return $res
  }

  # =========================================================================
  #  CAMINO 2: que la cuenta la pida el OOBE.
  #
  #  Se quitan DOS cosas, y las dos hacen falta:
  #    <UserAccounts>            porque es el bloque que crea la cuenta.
  #    <HideLocalAccountScreen>  porque si queda, el OOBE esconde la pantalla de
  #                              cuenta local y no habria NINGUNA forma de crearla.
  #
  #  Se quita con el DOM (RemoveChild), no con -replace sobre el texto: RemoveChild
  #  se lleva el subarbol COMPLETO y no puede dejar hijos huerfanos. Un -replace de
  #  "<UserAccounts>" a "" dejaria un <LocalAccounts> colgado del <component>, que
  #  es el defecto D15 exacto: "Setting is not defined in this component",
  #  hrResult = 0x80220001, y la instalacion aborta a mitad de camino.
  #
  #  Y ademas se deja un comentario EN EL LUGAR donde estaba el bloque: el archivo
  #  viaja en la raiz de la ISO y tiene que poder explicarse solo.
  # =========================================================================
  $ua = Get-XNode $Doc 'unattend/settings/component/UserAccounts'
  if ($ua) {
    $padre = $ua.ParentNode
    $sig   = $ua.NextSibling          # con PreserveWhitespace, el salto de linea
    [void]$padre.RemoveChild($ua)
    # OJO: un comentario XML no puede contener dos guiones seguidos ni terminar en
    # guion. Es el mismo motivo por el que la cabecera de este XML no los usa.
    $txt = @(
      ' LunaticOS: ACA IBA EL BLOQUE UserAccounts, el que crea la cuenta local.'
      '           Se quito a proposito porque el perfil pidio usuario.crear = false:'
      '           la cuenta la pide el OOBE durante la instalacion.'
      ''
      '           OJO: Windows 11 24H2 y 25H2 ya no traen bypassnro.cmd, asi que el'
      '           OOBE va a EXIGIR cuenta Microsoft y conexion a internet. Para hacer'
      '           una cuenta LOCAL: Shift+F10 y despues  start ms-cxh:localonly'
      ''
      '           Tambien se quito HideLocalAccountScreen del bloque OOBE: si quedara,'
      '           la pantalla de cuenta local no aparece nunca y no habria salida. '
    ) -join "`r`n"
    $com = $Doc.CreateComment($txt)
    if ($sig) { [void]$padre.InsertBefore($com, $sig) } else { [void]$padre.AppendChild($com) }
    $res.Quitado += 'UserAccounts'
    $res.Cambio   = $true
  }

  $hls = Get-XNode $Doc 'unattend/settings/component/OOBE/HideLocalAccountScreen'
  if ($hls) {
    # Aca si se limpia el whitespace de adelante: sin comentario que ocupe el lugar,
    # quedaria una linea en blanco suelta adentro del <OOBE>.
    $prev = $hls.PreviousSibling
    [void]$hls.ParentNode.RemoveChild($hls)
    if ($prev -and $prev.NodeType -eq [System.Xml.XmlNodeType]::Whitespace) {
      [void]$prev.ParentNode.RemoveChild($prev)
    }
    $res.Quitado += 'HideLocalAccountScreen'
    $res.Cambio   = $true
  }

  $res.Nombre  = ''
  $res.Resumen = 'la cuenta la va a pedir el OOBE (quitados: ' + (($res.Quitado -join ', ')) + ')'
  if ($res.Quitado.Count -eq 0) {
    $res.Resumen = 'la cuenta la va a pedir el OOBE (el autounattend ya no traia bloque de cuenta)'
  }
  return $res
}

# ===========================================================================
#  Test-CuentaAplicada: la POSTCONDICION, medida sobre el archivo YA ESCRITO.
#
#  No alcanza con que la funcion de arriba haya corrido: lo que importa es lo que
#  quedo en el archivo que se mete en la ISO. Es el mismo criterio que ya se usaba
#  con la clave de producto (se reabre el archivo y se relee el <Key>), y existe
#  porque todo lo que falla en este archivo falla en silencio.
#
#  Imprime el detalle en rojo y devuelve $true/$false.
# ===========================================================================
function Test-CuentaAplicada {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)]$Res
  )
  $mal = @()
  $doc = New-Object System.Xml.XmlDocument
  try { $doc.Load($Path) }
  catch {
    Write-Host "ERROR: el autounattend escrito no es XML valido -> $($_.Exception.Message)" -ForegroundColor Red
    return $false
  }

  $cuentas = @(Get-XNodes $doc 'unattend/settings/component/UserAccounts/LocalAccounts/LocalAccount')

  if ($Res.Crear) {
    if ($cuentas.Count -ne 1) {
      $mal += "quedaron $($cuentas.Count) <LocalAccount> y se esperaba exactamente 1"
    } else {
      $n = Get-XText $cuentas[0] 'Name'
      $d = Get-XText $cuentas[0] 'DisplayName'
      if ($n -ne $Res.Nombre) { $mal += "el <Name> quedo en '$n' y el perfil pidio '$($Res.Nombre)'" }
      if ($d -ne $Res.Nombre) { $mal += "el <DisplayName> quedo en '$d' y el perfil pidio '$($Res.Nombre)'" }
    }
  } else {
    # Se busca en TODO el documento, no solo donde esperamos encontrarlo: si
    # quedara un UserAccounts en otro pass, tambien crearia la cuenta.
    $ua = @($doc.SelectNodes("//*[local-name()='UserAccounts']"))
    if ($ua.Count -ne 0) { $mal += "quedaron $($ua.Count) bloques <UserAccounts> y el perfil pidio que la cuenta la pida el OOBE" }
    $hl = @($doc.SelectNodes("//*[local-name()='HideLocalAccountScreen']"))
    if ($hl.Count -ne 0) { $mal += 'quedo <HideLocalAccountScreen>: el OOBE esconderia la pantalla de cuenta local y no hay ninguna cuenta creada' }
  }

  if ($mal.Count) {
    Write-Host 'ERROR: la cuenta de usuario NO quedo como pedia el perfil:' -ForegroundColor Red
    $mal | ForEach-Object { Write-Host "         $_" -ForegroundColor Red }
    return $false
  }
  return $true
}

# ===========================================================================
#  Test-PlantillaCuenta: chequeo que SOLO vale para los archivos de config\.
#
#  No puede vivir dentro de Get-Unattend, porque Get-Unattend tambien valida el
#  archivo YA PROCESADO, y ese archivo puede no tener bloque de cuenta a proposito
#  (usuario.crear = false). Un template sin <Name>/<DisplayName>, en cambio, es un
#  archivo roto: no hay donde inyectar el nombre que eligio el usuario.
# ===========================================================================
function Test-PlantillaCuenta {
  param([Parameter(Mandatory)]$Doc, [Parameter(Mandatory)][string]$Rotulo)
  $la = Get-XNode $Doc 'unattend/settings/component/UserAccounts/LocalAccounts/LocalAccount'
  $falta = @()
  if (-not $la) {
    $falta += 'no tiene UserAccounts/LocalAccounts/LocalAccount'
  } else {
    if (-not (Get-XNode $la 'Name'))        { $falta += 'la LocalAccount no tiene <Name>' }
    if (-not (Get-XNode $la 'DisplayName')) { $falta += 'la LocalAccount no tiene <DisplayName>' }
  }
  if ($falta.Count) {
    Write-Host "ERROR: $Rotulo no sirve como plantilla de cuenta:" -ForegroundColor Red
    $falta | ForEach-Object { Write-Host "         $_ -> la fase 8 inyecta ahi el nombre elegido en la TUI" -ForegroundColor Red }
    return $false
  }
  return $true
}

# ===========================================================================
#  -ValidateOnly: pasa LOS DOS archivos por las guardas y sale. No escribe nada.
#  Barato (un segundo) y sirve como primer paso del runner del E2E: descubrir un
#  unattend roto ANTES de gastar el build es todo el punto de tener guardas.
# ===========================================================================
if ($ValidateOnly) {
  Write-Host "== Fase 8: validacion de los autounattend (no se escribe nada) ==" -ForegroundColor Cyan
  $malos = 0
  $docP = Get-Unattend -Path $AuProd -EsTest $false
  if (-not $docP) { $malos++ }
  # La plantilla, aparte: sin <Name>/<DisplayName> no hay donde inyectar el nombre
  # que eligio el usuario, y eso NO se puede chequear dentro de Get-Unattend porque
  # el archivo procesado puede quedar sin bloque de cuenta a proposito.
  elseif (-not (Test-PlantillaCuenta -Doc $docP -Rotulo 'config\autounattend.xml')) { $malos++ }
  if (Test-Path $AuTest) {
    $docT = Get-Unattend -Path $AuTest -EsTest $true
    if (-not $docT) { $malos++ }
    elseif (-not (Test-PlantillaCuenta -Doc $docT -Rotulo 'config\autounattend-test.xml')) { $malos++ }
  } else {
    Write-Step "config\autounattend-test.xml no existe: el modo test no esta disponible" 'DarkGray'
  }
  if ($malos) { Write-Host "  $malos archivo(s) con problemas." -ForegroundColor Red; exit 1 }
  Write-Step 'los autounattend pasan todas las guardas' 'Green'
  exit 0
}

# ===========================================================================
#  -SelfTest: los DOS caminos de la cuenta de usuario, sobre COPIAS.
#
#  Cubre los puntos 9 a 12 de la seccion 7 del contrato
#  (docs\contrato-cuenta-usuario.md) sin build, sin ISO y sin VM:
#
#    9)  crear = true  -> el XML resultante tiene ESE <Name>
#    10) crear = false -> no tiene UserAccounts ni HideLocalAccountScreen, y sigue
#        siendo XML valido con sus 3 passes
#    11) config\autounattend.xml NO se modifica en ninguno de los dos casos (hash)
#    12) config\autounattend-test.xml conserva su cuenta con password pase lo que pase
#
#  Y ademas prueba POR MUTACION que las guardas sirven: se rompe el bloque de
#  cuenta a mano de tres formas distintas y se verifica que Get-Unattend LAS
#  RECHACE. Un test que no falla con el bug puesto no prueba nada, y este repo ya
#  tuvo dos guardas de adorno (el .Count sobre un XmlElement y el [int] del Order).
# ===========================================================================
if ($SelfTest) {
  Write-Host "== Fase 8: self-test de la inyeccion de la cuenta de usuario ==" -ForegroundColor Cyan
  $script:fallas = 0
  function Chk($nombre, $cond, $detalle = '') {
    if ($cond) { Write-Host "  OK    $nombre" -ForegroundColor Green }
    else       { Write-Host "  FALLA $nombre $detalle" -ForegroundColor Red; $script:fallas++ }
  }
  # Todo se escribe en TEMP: el self-test no tiene por que tocar work\iso-build.
  $tmp = Join-Path $env:TEMP ('lunaticos-fase08-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null

  try {
    $hProdAntes = (Get-FileHash $AuProd -Algorithm SHA256).Hash
    $hTestAntes = if (Test-Path $AuTest) { (Get-FileHash $AuTest -Algorithm SHA256).Hash } else { '' }
    Write-Host "  config\autounattend.xml SHA256 antes: $hProdAntes" -ForegroundColor DarkGray

    # ---------------------------------------------------------------------
    #  CAMINO 1: crear = true con un nombre elegido.
    # ---------------------------------------------------------------------
    Write-Host ''
    Write-Host "  -- camino 1: usuario.crear = true, nombre 'lunatico' --" -ForegroundColor Cyan
    $perfilCrear = [ordered]@{ crear = $true; nombre = 'lunatico' }
    $d1 = Get-Unattend -Path $AuProd -EsTest $false -Rotulo 'plantilla (camino crear=true)'
    Chk 'la plantilla de produccion pasa las guardas' ($null -ne $d1)
    if ($d1) {
      $r1 = Set-UnattendCuenta -Doc $d1 -Perfil $perfilCrear
      $p1 = Join-Path $tmp 'crear-true.xml'
      Save-Unattend -Doc $d1 -Path $p1
      Chk "el resultado pasa TODAS las guardas" ($null -ne (Get-Unattend -Path $p1 -EsTest $false -Rotulo 'resultado crear=true'))
      Chk 'la postcondicion de la cuenta se cumple' (Test-CuentaAplicada -Path $p1 -Res $r1)
      $x1 = $null
      try { $x1 = [xml](Get-Content $p1 -Raw) } catch { }
      Chk 'el resultado es XML valido' ($null -ne $x1)
      if ($x1) {
        $passes1 = @($x1.unattend.settings | ForEach-Object { $_.pass })
        Chk 'estan los 3 passes' ($passes1.Count -eq 3 -and $passes1 -contains 'windowsPE') "-> [$($passes1 -join ', ')]"
        $la1 = $x1.SelectSingleNode("//*[local-name()='LocalAccount']")
        Chk "el <Name> quedo en 'lunatico'"        ((Get-XText $la1 'Name') -eq 'lunatico')        "-> '$(Get-XText $la1 'Name')'"
        Chk "el <DisplayName> quedo en 'lunatico'" ((Get-XText $la1 'DisplayName') -eq 'lunatico') "-> '$(Get-XText $la1 'DisplayName')'"
        Chk 'el <Group> del template sigue intacto' ((Get-XText $la1 'Group') -eq 'Administrators')
      }
      Chk 'el archivo escrito NO lleva BOM' (([System.IO.File]::ReadAllBytes($p1))[0] -eq 0x3C) '-> arranca con un BOM y los archivos de config\ no lo tienen'
    }

    # ---------------------------------------------------------------------
    #  CAMINO 2: crear = false -> la cuenta la pide el OOBE.
    # ---------------------------------------------------------------------
    Write-Host ''
    Write-Host '  -- camino 2: usuario.crear = false (la pide el OOBE) --' -ForegroundColor Cyan
    $perfilOobe = [ordered]@{ crear = $false; nombre = 'lunatico' }
    $d2 = Get-Unattend -Path $AuProd -EsTest $false -Rotulo 'plantilla (camino crear=false)'
    $p2 = Join-Path $tmp 'crear-false.xml'
    if ($d2) {
      $r2 = Set-UnattendCuenta -Doc $d2 -Perfil $perfilOobe
      Save-Unattend -Doc $d2 -Path $p2
      Chk 'quito los DOS nodos (UserAccounts + HideLocalAccountScreen)' `
          (@($r2.Quitado).Count -eq 2) "-> quito [$($r2.Quitado -join ', ')]"
      Chk 'el resultado pasa TODAS las guardas' ($null -ne (Get-Unattend -Path $p2 -EsTest $false -Rotulo 'resultado crear=false'))
      Chk 'la postcondicion de la cuenta se cumple' (Test-CuentaAplicada -Path $p2 -Res $r2)
      $x2 = $null
      try { $x2 = [xml](Get-Content $p2 -Raw) } catch { }
      Chk 'el resultado es XML valido' ($null -ne $x2)
      if ($x2) {
        $passes2 = @($x2.unattend.settings | ForEach-Object { $_.pass })
        Chk 'estan los 3 passes' ($passes2.Count -eq 3 -and $passes2 -contains 'windowsPE') "-> [$($passes2 -join ', ')]"
        Chk 'no quedo ningun UserAccounts'           (@($x2.SelectNodes("//*[local-name()='UserAccounts']")).Count -eq 0)
        Chk 'no quedo ningun LocalAccounts huerfano' (@($x2.SelectNodes("//*[local-name()='LocalAccounts']")).Count -eq 0)
        Chk 'no quedo HideLocalAccountScreen'        (@($x2.SelectNodes("//*[local-name()='HideLocalAccountScreen']")).Count -eq 0)
        # Lo que NO se tiene que haber llevado: el resto del bloque OOBE y los
        # otros dos passes. Una remocion que se lleva medio archivo tambien
        # "cumple" el requisito de arriba.
        Chk 'el resto del OOBE sigue ahi (HideEULAPage, ProtectYourPC)' `
            ((@($x2.SelectNodes("//*[local-name()='HideEULAPage']")).Count -eq 1) -and
             (@($x2.SelectNodes("//*[local-name()='ProtectYourPC']")).Count -eq 1))
        Chk 'la clave de producto y el RunSynchronous siguen ahi' `
            ((@($x2.SelectNodes("//*[local-name()='ProductKey']")).Count -eq 1) -and
             (@($x2.SelectNodes("//*[local-name()='RunSynchronousCommand']")).Count -eq 1))
      }
      $txt2  = Get-Content $p2 -Raw
      $nCom2 = @([regex]::Matches($txt2, '<!--')).Count
      $nComT = @([regex]::Matches((Get-Content $AuProd -Raw), '<!--')).Count
      Chk 'los comentarios del template sobrevivieron' ($nCom2 -ge $nComT) "-> el template tiene $nComT y quedaron $nCom2"
      # OJO: no alcanza con buscar 'ms-cxh:localonly' en el archivo. El comentario
      # del TEMPLATE ya lo menciona, asi que ese match da verde incluso si la marca
      # no se inserto nunca. Lo que se mide es la marca que agrega la remocion.
      Chk 'la remocion deja su propia marca en el XML que va a la ISO' `
          (($nCom2 -eq $nComT + 1) -and $txt2 -match 'ACA IBA EL BLOQUE UserAccounts') `
          "-> comentarios: template $nComT / resultado $nCom2"
      # Y el comando se busca DENTRO de la marca, no en el archivo: el comentario del
      # template tambien lo nombra, asi que un match global tampoco probaria nada.
      $marca = @($x2.SelectNodes('//comment()') |
                 Where-Object { "$($_.Value)" -match 'ACA IBA EL BLOQUE UserAccounts' })
      Chk 'la marca trae el comando exacto (start ms-cxh:localonly)' `
          ($marca.Count -eq 1 -and "$($marca[0].Value)" -match 'start ms-cxh:localonly')
      Chk 'la marca quedo dentro del component Shell-Setup del pass oobeSystem' `
          ($marca.Count -eq 1 -and "$($marca[0].ParentNode.GetAttribute('name'))" -eq 'Microsoft-Windows-Shell-Setup')
      # El resto del archivo, linea por linea: lo unico que puede DESAPARECER son
      # las lineas del bloque de cuenta. Si se fue algo mas, esto lo caza.
      $antes   = @(Get-Content $AuProd)
      $despues = @(Get-Content $p2)
      $perdidas = @(Compare-Object $antes $despues | Where-Object { $_.SideIndicator -eq '<=' } |
                    ForEach-Object { "$($_.InputObject)".Trim() } | Where-Object { $_ -ne '' })
      $esperadas = @('<UserAccounts>','</UserAccounts>','<LocalAccounts>','</LocalAccounts>',
                     '<LocalAccount wcm:action="add">','</LocalAccount>','<Name>pato</Name>',
                     '<DisplayName>pato</DisplayName>','<Group>Administrators</Group>','<Password>',
                     '</Password>','<Value></Value>','<PlainText>true</PlainText>',
                     '<HideLocalAccountScreen>true</HideLocalAccountScreen>')
      # Las lineas de apertura de cada <component> cambian SIEMPRE, y no es un
      # defecto: sus atributos estan escritos en 4 lineas y el whitespace ENTRE
      # ATRIBUTOS no es un nodo del DOM, asi que ni PreserveWhitespace lo conserva.
      # Se reescriben en una sola linea con los mismos atributos y los mismos
      # valores (por eso el archivo sigue pasando todas las guardas). Es la unica
      # diferencia cosmetica que Save-Unattend no puede evitar, y esta medida:
      # 25 lineas distintas en el round trip, TODAS de los 5 <component>.
      $sobran = @($perdidas | Where-Object {
        $esperadas -notcontains $_ -and
        $_ -notmatch '^<component ' -and
        $_ -notmatch '^(xmlns:|publicKeyToken=|processorArchitecture=|language=|versionScope=)'
      })
      Chk 'no se perdio ninguna linea que no sea del bloque de cuenta' ($sobran.Count -eq 0) `
          ("-> se perdio tambien: " + (($sobran | Select-Object -First 6) -join ' | '))
    }

    # ---------------------------------------------------------------------
    #  El archivo del repo no se movio (punto 11 del contrato).
    # ---------------------------------------------------------------------
    Write-Host ''
    $hProdDespues = (Get-FileHash $AuProd -Algorithm SHA256).Hash
    Chk 'config\autounattend.xml del repo NO se modifico (SHA256 igual)' ($hProdDespues -eq $hProdAntes) `
        "-> antes $hProdAntes / despues $hProdDespues"

    # ---------------------------------------------------------------------
    #  El de test conserva su cuenta CON password, pase lo que pase (punto 12).
    #  Se prueba de las dos formas: el archivo del repo intacto, y la funcion de
    #  inyeccion NEGANDOSE a tocarlo aunque le pasen crear = false.
    # ---------------------------------------------------------------------
    if (Test-Path $AuTest) {
      Chk 'config\autounattend-test.xml del repo NO se modifico (SHA256 igual)' `
          ((Get-FileHash $AuTest -Algorithm SHA256).Hash -eq $hTestAntes)
      $dT = Get-Unattend -Path $AuTest -EsTest $true -Rotulo 'plantilla de TEST'
      if ($dT) {
        $rT = Set-UnattendCuenta -Doc $dT -Perfil ([ordered]@{ crear = $false; nombre = 'otro' })
        Chk 'Set-UnattendCuenta se NIEGA a tocar el unattend de test' ($rT.EsTest -and -not $rT.Cambio) "-> $($rT.Resumen)"
        $laT = Get-XNode $dT 'unattend/settings/component/UserAccounts/LocalAccounts/LocalAccount'
        Chk 'el de test conserva su LocalAccount' ($null -ne $laT)
        Chk 'el de test conserva el password (PowerShell Direct depende de eso)' `
            ((Get-XText $laT 'Password/Value') -ne '')
        Chk 'el de test conserva el AutoLogon sincronizado' `
            ((Get-XText $dT 'unattend/settings/component/AutoLogon/Username') -eq (Get-XText $laT 'Name'))
      }
    }

    # ---------------------------------------------------------------------
    #  MUTACION: con el bug puesto, las guardas TIENEN que rechazar.
    # ---------------------------------------------------------------------
    Write-Host ''
    Write-Host '  -- mutacion: las guardas contra un bloque de cuenta mal quitado --' -ForegroundColor Cyan
    Write-Host '     (los ERROR que siguen son ESPERADOS: es el bug puesto a proposito)' -ForegroundColor DarkGray

    # (a) se quita UserAccounts y quedan sus hijos colgados del <component>:
    #     el defecto D15 exacto (hrResult = 0x80220001, la instalacion aborta).
    $dm = New-Object System.Xml.XmlDocument
    $dm.PreserveWhitespace = $true
    $dm.Load($AuProd)
    $uaM = $dm.SelectSingleNode("//*[local-name()='UserAccounts']")
    $laM = $dm.SelectSingleNode("//*[local-name()='LocalAccounts']")
    [void]$uaM.ParentNode.InsertBefore($laM, $uaM)     # el hijo se queda...
    [void]$uaM.ParentNode.RemoveChild($uaM)            # ...y el padre se va
    $hM = $dm.SelectSingleNode("//*[local-name()='HideLocalAccountScreen']")
    [void]$hM.ParentNode.RemoveChild($hM)
    $pm1 = Join-Path $tmp 'mutante-localaccounts-huerfano.xml'
    Save-Unattend -Doc $dm -Path $pm1
    Chk 'RECHAZA un <LocalAccounts> huerfano colgado del <component>' `
        ($null -eq (Get-Unattend -Path $pm1 -EsTest $false -Rotulo 'mutante: LocalAccounts huerfano'))

    # (b) remocion a medias: se va UserAccounts y queda HideLocalAccountScreen.
    #     Nadie crea la cuenta y el OOBE esconde la pantalla para crearla.
    $dm2 = New-Object System.Xml.XmlDocument
    $dm2.PreserveWhitespace = $true
    $dm2.Load($AuProd)
    $uaM2 = $dm2.SelectSingleNode("//*[local-name()='UserAccounts']")
    [void]$uaM2.ParentNode.RemoveChild($uaM2)
    $pm2 = Join-Path $tmp 'mutante-remocion-a-medias.xml'
    Save-Unattend -Doc $dm2 -Path $pm2
    Chk 'RECHAZA la remocion a medias (queda HideLocalAccountScreen)' `
        ($null -eq (Get-Unattend -Path $pm2 -EsTest $false -Rotulo 'mutante: remocion a medias'))

    # (c) UserAccounts vacio: el bloque esta pero no crea ninguna cuenta.
    $dm3 = New-Object System.Xml.XmlDocument
    $dm3.PreserveWhitespace = $true
    $dm3.Load($AuProd)
    $laM3 = $dm3.SelectSingleNode("//*[local-name()='LocalAccounts']")
    [void]$laM3.ParentNode.RemoveChild($laM3)
    $pm3 = Join-Path $tmp 'mutante-useraccounts-vacio.xml'
    Save-Unattend -Doc $dm3 -Path $pm3
    Chk 'RECHAZA un <UserAccounts> sin ninguna <LocalAccount>' `
        ($null -eq (Get-Unattend -Path $pm3 -EsTest $false -Rotulo 'mutante: UserAccounts vacio'))

    # (d) CONTROL: la remocion BIEN hecha tiene que pasar. Sin esto, una guarda
    #     que rechaza cualquier cosa daria los tres OK de arriba y seria inutil.
    Write-Host '     (de aca en mas ya no se esperan ERROR)' -ForegroundColor DarkGray
    Chk 'ACEPTA la remocion bien hecha (la guarda no rechaza todo)' `
        ($null -ne (Get-Unattend -Path $p2 -EsTest $false -Rotulo 'control: remocion bien hecha'))

    # ---------------------------------------------------------------------
    #  Validacion del nombre: cada regla del contrato, con su caso.
    # ---------------------------------------------------------------------
    Write-Host ''
    Write-Host '  -- validacion del nombre de cuenta --' -ForegroundColor Cyan
    foreach ($caso in @(
      @{ n = 'pato';                   ok = $true  }
      @{ n = 'juan.perez';             ok = $true  }
      @{ n = '';                       ok = $false }
      @{ n = 'a' * 21;                 ok = $false }
      @{ n = 'juan perez';             ok = $true  }   # valido, solo avisa
      @{ n = ' pato';                  ok = $false }
      @{ n = 'pato.';                  ok = $false }
      @{ n = '...';                    ok = $false }
      @{ n = 'pa/to';                  ok = $false }
      @{ n = 'pa:to';                  ok = $false }
      @{ n = 'CON';                    ok = $false }
      @{ n = 'com1';                   ok = $false }
      @{ n = 'Administrator';          ok = $false }
      @{ n = 'defaultaccount';         ok = $false }
    )) {
      $r = Test-NombreCuentaLocal $caso.n
      $etq = if ($caso.n -eq '') { '(vacio)' } else { "'$($caso.n)'" }
      Chk ("nombre {0,-18} {1}" -f $etq, $(if ($caso.ok) { 'se acepta' } else { 'se rechaza' })) `
          ($caso.ok -eq ($r -eq '')) "-> devolvio '$r'"
    }
    Chk 'un nombre con espacios avisa por la carpeta del perfil' (@(Get-AvisosNombreCuenta 'juan perez').Count -ge 1)

    # =====================================================================
    #  QUE LA VALIDACION ESTE ENCHUFADA, no solo que exista.
    #  Los casos de arriba llaman a Test-NombreCuentaLocal DIRECTO, asi que dan
    #  verde igual si alguien borra la llamada desde Set-UnattendCuenta. Medido:
    #  con esa mutacion puesta, el self-test entero seguia en 0 fallas. Este caso
    #  pasa por el camino de verdad y exige que CORTE.
    # =====================================================================
    $dv = Get-Unattend -Path $AuProd -EsTest $false -Rotulo 'plantilla (nombre invalido)'
    if ($dv) {
      foreach ($caso in @(
        @{ nombre = 'CON';      que = 'un nombre reservado' }
        @{ nombre = 'pa|to';    que = 'un caracter prohibido' }
        @{ nombre = ('x' * 21); que = '21 caracteres' }
        @{ nombre = '';         que = 'crear=true sin nombre' }
      )) {
        $tiro = $false
        try { [void](Set-UnattendCuenta -Doc $dv -Perfil ([ordered]@{ crear = $true; nombre = $caso.nombre })) }
        catch { $tiro = $true }
        Chk ("Set-UnattendCuenta CORTA con {0}" -f $caso.que) $tiro '-> inyecto el nombre igual'
      }
    }
    # [bool]'false' es $true en PowerShell: la conversion tiene que ser explicita.
    Chk 'la cadena "false" en usuario.crear NO se lee como true' ((ConvertTo-BoolPerfil 'false') -eq $false)
    Chk 'usuario.crear ausente se lee como true (perfiles viejos)' ((ConvertTo-BoolPerfil $null) -eq $true)

    # ---------------------------------------------------------------------
    #  Sin perfil: comportamiento de siempre, sin romper.
    # ---------------------------------------------------------------------
    $d3 = Get-Unattend -Path $AuProd -EsTest $false -Rotulo 'plantilla (sin perfil)'
    if ($d3) {
      $r3 = Set-UnattendCuenta -Doc $d3 -Perfil $null
      Chk 'sin $Global:UsuarioPerfil no se toca nada y queda la cuenta del template' `
          ((-not $r3.Cambio) -and $r3.Nombre -eq 'pato') "-> $($r3.Resumen)"
    }
  }
  finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }

  Write-Host ''
  if ($script:fallas -eq 0) { Write-Host "  TODO OK (0 fallas)" -ForegroundColor Green }
  else { Write-Host "  $($script:fallas) FALLAS" -ForegroundColor Red }
  # exit con el valor guardado, NO con el retorno de nada: cualquier cosa que caiga
  # al pipeline se sumaria al valor y el exit code mentiria (paso en LunaticOS.ps1).
  exit ([int]$script:fallas)
}

# --------------------------------------------------------------------------
#  Que archivo se usa. EL DEFAULT ES SIEMPRE EL DE PRODUCCION: para usar el de
#  test hay que pedirlo, y pedirlo cuesta tipear algo que no se tipea solo.
# --------------------------------------------------------------------------
$modoTest = $TestUnattend.IsPresent -or ($env:LUNATICOS_TEST_UNATTEND -eq '1')
$auSrc    = if ($modoTest) { $AuTest } else { $AuProd }

# El autounattend.xml va a la RAIZ de la ISO: no necesita el WIM montado. Solo el
# SetupComplete.cmd lo necesita. Separar las dos cosas permite corregir el unattend
# y rearmar la ISO sin volver a montar y commitear el WIM (que son ~20 minutos).
Write-Host "== Fase 8: inyeccion de runtime ==" -ForegroundColor Cyan
if (-not $wimMounted) {
  Write-Step "WIM no montado -> solo se actualiza el autounattend.xml de la ISO" 'Yellow'
}

if ($modoTest) {
  # Si se pidio el de test y no esta, se CORTA. Volver al de produccion en
  # silencio dejaria una ISO que pide un clic humano, y el runner del E2E se
  # quedaria esperando ese clic hasta el timeout sin entender por que.
  if (-not (Test-Path $AuTest)) {
    Write-Host "ERROR: se pidio el autounattend de TEST y no existe:" -ForegroundColor Red
    Write-Host "       $AuTest" -ForegroundColor Red
    Write-Host "       NO se cae al de produccion a proposito: esa ISO pediria un clic" -ForegroundColor Red
    Write-Host "       humano y el test se colgaria esperandolo." -ForegroundColor Red
    exit 1
  }
  $comoSePidio = if ($TestUnattend.IsPresent) { '-TestUnattend' } else { "LUNATICOS_TEST_UNATTEND=$($env:LUNATICOS_TEST_UNATTEND)" }
  Write-Host ''
  Write-Host "  ###################################################################" -ForegroundColor Yellow
  Write-Host "  #  MODO TEST: se usa config\autounattend-test.xml" -ForegroundColor Yellow
  Write-Host "  #  (pedido por $comoSePidio)" -ForegroundColor Yellow
  Write-Host "  #" -ForegroundColor Yellow
  Write-Host "  #  LA ISO QUE SALGA DE ESTE BUILD FORMATEA EL DISCO 0 SIN" -ForegroundColor Yellow
  Write-Host "  #  PREGUNTAR NADA: borra particiones y datos, sin confirmacion y" -ForegroundColor Yellow
  Write-Host "  #  sin vuelta atras." -ForegroundColor Yellow
  Write-Host "  #" -ForegroundColor Yellow
  Write-Host "  #  NO LA GRABES A UN USB. NO LA BOOTEES EN UNA MAQUINA REAL." -ForegroundColor Yellow
  Write-Host "  #  Es para una VM descartable y para nada mas." -ForegroundColor Yellow
  Write-Host "  #" -ForegroundColor Yellow
  Write-Host "  #  Ademas crea la cuenta local CON password (documentado en la" -ForegroundColor Yellow
  Write-Host "  #  cabecera del XML) y deja AutoLogon activado, para que" -ForegroundColor Yellow
  Write-Host "  #  PowerShell Direct pueda verificar el SO corriendo." -ForegroundColor Yellow
  Write-Host "  ###################################################################" -ForegroundColor Yellow
  Write-Host ''
}

# 0) Guardas: XML valido, pass windowsPE, componentes correctos, layout coherente
#    y credencial usable. Corren igual para el de produccion y para el de test.
$xml = Get-Unattend -Path $auSrc -EsTest $modoTest
if (-not $xml) { exit 1 }

# 1) SetupComplete.cmd dentro del WIM (solo si esta montado)
if ($wimMounted) {
  $scriptsDir = Join-Path $mount 'Windows\Setup\Scripts'
  New-Item -ItemType Directory -Force -Path $scriptsDir | Out-Null
  Copy-Item (Join-Path $CFG.Root 'config\SetupComplete.cmd') (Join-Path $scriptsDir 'SetupComplete.cmd') -Force
  Write-Step "SetupComplete.cmd -> Windows\Setup\Scripts\ (tasks de telemetria; Edge ya salio en la fase 7)" 'Green'
} else {
  Write-Step "SetupComplete.cmd: salteado (el del WIM commiteado sigue vigente)" 'DarkGray'
}

# ===========================================================================
#  2) autounattend.xml en la raiz de la ISO, con LO QUE ELIGIO EL USUARIO:
#     la clave de producto (clave-windows.txt) y la cuenta (perfil.json).
#
#  Las dos inyecciones se hacen sobre EL MISMO documento en memoria y se escriben
#  UNA SOLA VEZ. Antes habia una escritura por camino, y con dos cosas que inyectar
#  eso se convierte en cuatro combinaciones: la que nadie prueba es la que falla.
#  Si no hubo NINGUN cambio, se copia el archivo tal cual (byte por byte).
#
#  POR QUE LA CLAVE IMPORTA MAS DE LO QUE PARECE:
#  la clave generica publica de Pro (VK7JG-...) fija la EDICION pero NO ACTIVA
#  Windows. Y sin activacion, Settings > Personalization esta bloqueada por diseno
#  de licenciamiento: no hay policy ni truco de registro que lo evite. Ese fue uno
#  de los dos motivos por los que el usuario no podia cambiar el tema ni el color
#  en el build del 2026-07-29 (el otro era el formato de bytes del acento).
#
#  La clave real vive en clave-windows.txt, en la raiz del repo, GITIGNOREADO.
#  Y NUNCA se escribe en perfil.json: el perfil es para compartir, la licencia no.
#
#  Se inyecta sobre una COPIA EN MEMORIA ($xml, el que ya cargo la guarda de
#  arriba). Ni config\autounattend.xml ni config\autounattend-test.xml se tocan
#  jamas: si les escribieramos la clave, el proximo `git status` la mostraria ahi
#  y la primera vez que el usuario compartiera el repo, regalaria su licencia.
#
#  Y funciona igual con los dos archivos porque los dos tienen el mismo nodo
#  UserData/ProductKey/Key, cosa que la guarda 5 verifica.
# ===========================================================================
function Get-WindowsProductKey {
  param([Parameter(Mandatory)][string]$Path)

  if (-not (Test-Path $Path)) { return $null }

  # Se ignoran lineas vacias y comentarios: el .ejemplo viene con instrucciones.
  $lineas = @(Get-Content $Path -ErrorAction SilentlyContinue |
              ForEach-Object { $_.Trim() } |
              Where-Object { $_ -ne '' -and -not $_.StartsWith('#') })

  if ($lineas.Count -eq 0) { return $null }

  $k = $lineas[0].ToUpperInvariant()
  # 5 grupos de 5 alfanumericos. Si el archivo existe pero la clave esta mal, se
  # CORTA EL BUILD: una clave mal tipeada cuesta 45 minutos de build mas una
  # instalacion entera para descubrirse, y el sintoma que deja (Personalization en
  # gris) no se parece en nada a la causa.
  if ($k -notmatch '^[A-Z0-9]{5}(-[A-Z0-9]{5}){4}$') {
    throw ("clave-windows.txt tiene una clave con formato invalido: '{0}'. " -f $lineas[0]) +
          "Se espera XXXXX-XXXXX-XXXXX-XXXXX-XXXXX."
  }
  $k
}

# Enmascarada al loguear: los logs de work\logs\ se comparten para diagnosticar.
function Format-KeyMasked([string]$k) {
  if (-not $k) { return '(ninguna)' }
  $g = $k.Split('-')
  ('*****-' * ($g.Count - 1)) + $g[-1]
}

$claveFile = Join-Path $CFG.Root 'clave-windows.txt'
$clave = Get-WindowsProductKey -Path $claveFile   # tira si el formato es invalido

$auDst = Join-Path $CFG.IsoBuild 'autounattend.xml'

# $cambios describe lo que se modifico SOBRE LA COPIA EN MEMORIA. Si queda vacio,
# no se reescribe el archivo: se copia el del repo tal cual.
$cambios = @()

# --- 2a) la clave de producto ---------------------------------------------
if ($clave) {
  # Se navega al nodo, no se hace -replace sobre texto: el XML tiene namespaces y
  # un replace ciego le pegaria a cualquier otro <Key> que apareciera manana.
  $node = $xml.SelectSingleNode('//*[local-name()="UserData"]/*[local-name()="ProductKey"]/*[local-name()="Key"]')
  if (-not $node) {
    Write-Host "ERROR: no encontre UserData\ProductKey\Key en el autounattend." -ForegroundColor Red; exit 1
  }
  $node.InnerText = $clave
  $cambios += 'clave de producto'
}

# ===========================================================================
#  2b) LA CUENTA DE USUARIO (perfil.json -> usuario.crear / usuario.nombre)
#
#  $Global:UsuarioPerfil lo llena LunaticOS.ps1 antes del pipeline. Las fases se
#  invocan con `& $path`, o sea en el MISMO runspace, asi que se ve (igual que
#  $Global:AppxRemove en la fase 01). Si la fase se corre a mano, no esta, y
#  Set-UnattendCuenta cae al comportamiento de siempre sin romper.
#
#  La variable se pasa TAL CUAL y la decision de "hay perfil o no" la toma
#  Set-UnattendCuenta comparando contra $null. NO se usa `if (-not $Global:...)`:
#  un hashtable vacio es FALSY en PowerShell, y ese es exactamente el bug que hizo
#  que "elegir 0 programas" instalara los 24 recomendados. Aca la variable puede
#  llegar como [ordered]@{} vacio, que no es lo mismo que no llegar.
# ===========================================================================
try {
  $resCuenta = Set-UnattendCuenta -Doc $xml -Perfil $Global:UsuarioPerfil
} catch {
  # Un nombre invalido, o un perfil que pide crear la cuenta sin decir como se
  # llama. Se corta ACA: con el nombre mal, la cuenta falla DURANTE la instalacion
  # y el usuario se entera a los 40 minutos, con el OOBE roto.
  Write-Host "ERROR: no puedo aplicar la cuenta de usuario del perfil:" -ForegroundColor Red
  Write-Host "       $($_.Exception.Message)" -ForegroundColor Red
  exit 1
}
if ($resCuenta.Cambio) { $cambios += 'cuenta de usuario' }

# --- 2c) UNA escritura, y despues TODAS las guardas sobre lo que quedo -----
if ($cambios.Count) {
  Save-Unattend -Doc $xml -Path $auDst
} else {
  # OJO: se copia $auSrc, NO una ruta fija. Hardcodear config\autounattend.xml aca
  # haria que el modo test se ignore EN SILENCIO justo cuando no hay nada que
  # inyectar, y el sintoma seria "el test se colgo pidiendo un clic" sin pista.
  Copy-Item $auSrc $auDst -Force
}

# Las guardas otra vez, pero ahora sobre EL ARCHIVO QUE VA A LA ISO. No es
# paranoia decorativa: es el unico archivo que el instalador va a leer, y las dos
# formas en que este archivo falla (descarte silencioso D14, aborto por componente
# equivocado D15) cuestan una instalacion completa cada una. Cuesta un segundo.
if (-not (Get-Unattend -Path $auDst -EsTest $modoTest -Rotulo 'autounattend.xml (el que va a la ISO)')) {
  Write-Host "ERROR: el autounattend que quedo en el arbol de la ISO NO pasa las guardas." -ForegroundColor Red
  Write-Host "       Se corta el build ANTES de armar la ISO: mejor fallar ahora que" -ForegroundColor Red
  Write-Host "       descubrirlo a los 40 minutos, adentro del instalador." -ForegroundColor Red
  exit 1
}
# Y las postcondiciones puntuales: que lo que se pidio este REALMENTE escrito.
if ($clave) {
  $chk = New-Object System.Xml.XmlDocument
  $chk.Load($auDst)
  $nodoK = $chk.SelectSingleNode('//*[local-name()="UserData"]/*[local-name()="ProductKey"]/*[local-name()="Key"]')
  $leido = if ($nodoK) { "$($nodoK.InnerText)" } else { '' }
  if ($leido -ne $clave) {
    Write-Host "ERROR: la clave no quedo escrita en el autounattend (se leyo '$leido')" -ForegroundColor Red; exit 1
  }
}
if (-not (Test-CuentaAplicada -Path $auDst -Res $resCuenta)) { exit 1 }

# --- 2d) que se llevo la ISO, dicho de frente -----------------------------
$queLleva = @($resCuenta.Resumen, 'region AR', 'teclado ES/EN')
Write-Step ("autounattend.xml -> raiz de la ISO: " + ($queLleva -join ' + ')) 'Green'
Write-Step ("cuenta de usuario: $($resCuenta.Motivo)") 'DarkGray'
foreach ($a in @($resCuenta.Avisos)) { Write-Step "OJO: $a" 'Yellow' }

# ===========================================================================
#  EL AVISO QUE NO SE PUEDE OMITIR: sin cuenta local en el unattend, el OOBE de
#  24H2/25H2 exige cuenta Microsoft.
#
#  Microsoft SACO bypassnro.cmd de Windows 11 24H2 en adelante, asi que el truco de
#  siempre ya no existe. Lo que queda es ms-cxh:localonly, y hay que saberlo ANTES
#  de estar parado frente al OOBE de una maquina recien instalada, sin internet o
#  sin ganas de crear una cuenta Microsoft.
#
#  Se avisa al GENERAR la ISO (aca) porque es el ultimo momento en que el usuario
#  puede cambiar de opinion barato: cambiar de opinion despues cuesta rearmar la
#  ISO. La TUI tambien lo dice al elegir la opcion (contrato, seccion 2).
# ===========================================================================
if (-not $resCuenta.Crear -and -not $resCuenta.EsTest) {
  Write-Host ''
  Write-Host "  ###################################################################" -ForegroundColor Yellow
  Write-Host "  #  ESTA ISO NO CREA NINGUNA CUENTA: LA VA A PEDIR EL OOBE." -ForegroundColor Yellow
  Write-Host "  #" -ForegroundColor Yellow
  Write-Host "  #  Windows 11 24H2 y 25H2 YA NO TRAEN bypassnro.cmd (Microsoft lo" -ForegroundColor Yellow
  Write-Host "  #  saco). Sin cuenta local en el autounattend, el OOBE EXIGE cuenta" -ForegroundColor Yellow
  Write-Host "  #  Microsoft y conexion a internet." -ForegroundColor Yellow
  Write-Host "  #" -ForegroundColor Yellow
  Write-Host "  #  Para hacer una cuenta LOCAL igual, en la pantalla del OOBE:" -ForegroundColor Yellow
  Write-Host "  #" -ForegroundColor Yellow
  Write-Host "  #      1) Shift + F10                 (abre una consola)" -ForegroundColor Yellow
  Write-Host "  #      2) start ms-cxh:localonly      (tal cual, con los dos puntos)" -ForegroundColor Yellow
  Write-Host "  #" -ForegroundColor Yellow
  Write-Host "  #  y recien ahi aparece el formulario de cuenta local." -ForegroundColor Yellow
  Write-Host "  #" -ForegroundColor Yellow
  Write-Host "  #  Si no queres esto: opcion 7 de la TUI -> 'crear la cuenta ahora'" -ForegroundColor Yellow
  Write-Host "  #  (o usuario.crear = true en perfil.json) y volve a generar la ISO." -ForegroundColor Yellow
  Write-Host "  #  El comando tambien quedo escrito como comentario adentro del" -ForegroundColor Yellow
  Write-Host "  #  autounattend.xml de la ISO, para poder leerlo desde el medio." -ForegroundColor Yellow
  Write-Host "  ###################################################################" -ForegroundColor Yellow
  Write-Host ''
}

if ($clave) {
  Write-Step ("clave de producto: la TUYA, {0}" -f (Format-KeyMasked $clave)) 'Green'
  Write-Step "Windows va a activarse solo (necesita internet en algun momento)." 'DarkGray'
} else {
  Write-Host ''
  Write-Host "  ###################################################################" -ForegroundColor Yellow
  Write-Host "  #  SIN CLAVE PROPIA: se usa la generica de Pro y WINDOWS NO VA A" -ForegroundColor Yellow
  Write-Host "  #  QUEDAR ACTIVADO." -ForegroundColor Yellow
  Write-Host "  #" -ForegroundColor Yellow
  Write-Host "  #  Consecuencia concreta: Settings > Personalization va a estar" -ForegroundColor Yellow
  Write-Host "  #  BLOQUEADA (tema, color, fondo en gris) hasta que actives. No es un" -ForegroundColor Yellow
  Write-Host "  #  bug de LunaticOS: Windows lo bloquea por licenciamiento." -ForegroundColor Yellow
  Write-Host "  #" -ForegroundColor Yellow
  Write-Host "  #  Para arreglarlo: pone tu clave en clave-windows.txt (hay un" -ForegroundColor Yellow
  Write-Host "  #  clave-windows.txt.ejemplo al lado) y volve a generar la ISO." -ForegroundColor Yellow
  Write-Host "  ###################################################################" -ForegroundColor Yellow
  Write-Host ''
}

# ===========================================================================
#  3) Marcador en la raiz de la ISO: que la de test se pueda distinguir.
#
#  Una vez armadas, la ISO de test y la de produccion son dos archivos que se
#  llaman parecido y pesan casi lo mismo. El marcador es la unica forma de mirar
#  un medio y saber cual es cual sin bootearlo.
#
#  NO se renombra la ISO: el nombre lo decide la fase 9 y lo consumen test-vm.ps1
#  y el chequeo de "la ISO esta montada en una VM encendida". Cambiarlo obligaria
#  a tocar tres archivos de otros para ganar lo mismo que gana este .txt.
#
#  Y LA PARTE QUE IMPORTA: work\iso-build\ SOBREVIVE ENTRE BUILDS. Si el marcador
#  se creara y no se borrara, un build de test seguido de uno de produccion
#  dejaria el marcador metido en la ISO de produccion, avisando de un formateo que
#  esa ISO no hace. Un aviso que miente entrena a la gente a ignorar los avisos.
#  Por eso el else BORRA: no es limpieza cosmetica, es la mitad de la guarda.
# ===========================================================================
$marcaPath = Join-Path $CFG.IsoBuild $MarcaIso
if ($modoTest) {
  @(
    'ISO DE TEST DE LunaticOS. NO LA USES EN UNA MAQUINA REAL.'
    ''
    'Esta ISO se armo con config\autounattend-test.xml, que FORMATEA EL DISCO 0'
    'SIN PREGUNTAR: borra particiones y datos, sin confirmacion y sin vuelta atras.'
    ''
    'Existe solo para el test end to end en una VM descartable. El contrato esta'
    'en docs\testing-e2e.md. La ISO de produccion NO trae este archivo y NO toca'
    'el particionado: ahi el disco lo elige el usuario a mano.'
    ''
    'Ademas crea una cuenta local CON un password conocido y versionado, y deja'
    'AutoLogon activado. En una maquina real eso es un agujero.'
    ''
    ('Generada: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
  ) | Set-Content -Path $marcaPath -Encoding ASCII
  Write-Step "$MarcaIso -> raiz de la ISO (marcador de ISO de test)" 'Yellow'
} elseif (Test-Path $marcaPath) {
  Remove-Item $marcaPath -Force
  Write-Step "$MarcaIso borrado del arbol de la ISO (habia quedado de un build de test)" 'Yellow'
}
