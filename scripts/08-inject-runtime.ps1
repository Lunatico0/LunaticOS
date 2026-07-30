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
#>
param(
  # Usa config\autounattend-test.xml en vez del de produccion. LA ISO RESULTANTE
  # FORMATEA EL DISCO 0 DE LO QUE LA BOOTEE. Solo para VM descartable.
  [switch]$TestUnattend,
  # Corre todas las guardas sobre los dos autounattend y sale. No toca nada.
  [switch]$ValidateOnly
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
    [bool]$EsTest = $false
  )

  $nombre = Split-Path $Path -Leaf
  if (-not (Test-Path $Path)) {
    Write-Host "ERROR: no existe $Path" -ForegroundColor Red
    return $null
  }

  $doc = New-Object System.Xml.XmlDocument
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

  # --- 3) El nodo donde se inyecta la clave del usuario -------------------
  if (-not (Get-XNode $doc 'unattend/settings/component/UserData/ProductKey/Key')) {
    $err += 'no tiene UserData/ProductKey/Key: la fase 8 inyecta ahi la clave de clave-windows.txt'
  }

  # =========================================================================
  #  4) DiskConfiguration: LA GUARDA QUE MAS IMPORTA, Y VA EN LOS DOS SENTIDOS.
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

  # --- 5) Coherencia del layout de particiones ----------------------------
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
  #  6) Solo el de test: la credencial.
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
#  -ValidateOnly: pasa LOS DOS archivos por las guardas y sale. No escribe nada.
#  Barato (un segundo) y sirve como primer paso del runner del E2E: descubrir un
#  unattend roto ANTES de gastar el build es todo el punto de tener guardas.
# ===========================================================================
if ($ValidateOnly) {
  Write-Host "== Fase 8: validacion de los autounattend (no se escribe nada) ==" -ForegroundColor Cyan
  $malos = 0
  if (-not (Get-Unattend -Path $AuProd -EsTest $false)) { $malos++ }
  if (Test-Path $AuTest) {
    if (-not (Get-Unattend -Path $AuTest -EsTest $true)) { $malos++ }
  } else {
    Write-Step "config\autounattend-test.xml no existe: el modo test no esta disponible" 'DarkGray'
  }
  if ($malos) { Write-Host "  $malos archivo(s) con problemas." -ForegroundColor Red; exit 1 }
  Write-Step 'los autounattend pasan todas las guardas' 'Green'
  exit 0
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
#  2) autounattend.xml en la raiz de la ISO, con la clave de producto del usuario
#
#  POR QUE ESTO IMPORTA MAS DE LO QUE PARECE:
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
#  UserData/ProductKey/Key, cosa que la guarda #3 verifica.
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
if ($clave) {
  # Se navega al nodo, no se hace -replace sobre texto: el XML tiene namespaces y
  # un replace ciego le pegaria a cualquier otro <Key> que apareciera manana.
  $node = $xml.SelectSingleNode('//*[local-name()="UserData"]/*[local-name()="ProductKey"]/*[local-name()="Key"]')
  if (-not $node) {
    Write-Host "ERROR: no encontre UserData\ProductKey\Key en el autounattend." -ForegroundColor Red; exit 1
  }
  $node.InnerText = $clave
  $xml.Save($auDst)
  # Guarda: que lo que quedo escrito siga siendo XML valido y traiga la clave.
  try {
    $chk = New-Object System.Xml.XmlDocument
    $chk.Load($auDst)
    $leido = $chk.SelectSingleNode('//*[local-name()="UserData"]/*[local-name()="ProductKey"]/*[local-name()="Key"]').InnerText
    if ($leido -ne $clave) { throw "la clave no quedo escrita (se leyo '$leido')" }
  } catch {
    Write-Host "ERROR: el autounattend con la clave no valido -> $($_.Exception.Message)" -ForegroundColor Red; exit 1
  }
  Write-Step ("autounattend.xml -> raiz de la ISO, con TU clave: {0}" -f (Format-KeyMasked $clave)) 'Green'
  Write-Step "Windows va a activarse solo (necesita internet en algun momento)." 'DarkGray'
} else {
  # OJO: se copia $auSrc, NO una ruta fija. Hardcodear config\autounattend.xml aca
  # haria que el modo test se ignore EN SILENCIO justo cuando no hay clave propia,
  # y el sintoma seria "el test se colgo pidiendo un clic" sin ninguna pista.
  Copy-Item $auSrc $auDst -Force
  Write-Step "autounattend.xml -> raiz de la ISO (cuenta local + region AR + teclado ES/EN)" 'Green'
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
