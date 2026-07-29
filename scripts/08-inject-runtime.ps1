#requires -Version 5.1
<#
  Fase 8 - Inyeccion de runtime:
    1) SetupComplete.cmd  -> dentro del WIM en Windows\Setup\Scripts\ (corre al final del setup)
    2) autounattend.xml   -> en la RAIZ del arbol de la ISO (lo lee el instalador)
  Ambos templates viven en config\ (versionados). Este script solo los copia a su lugar.

  El autounattend.xml se valida como XML antes de copiarlo: un XML mal formado (o
  sin el pass windowsPE) hace que el instalador lo descarte SIN AVISAR y se pierden
  los tres pases. Nos paso una vez; no queremos que pase de nuevo.
#>

. "$PSScriptRoot\config.ps1"
. "$PSScriptRoot\lib.ps1"
$mount     = $CFG.Mount
$wimMounted = Test-Path (Join-Path $mount 'Windows')

# El autounattend.xml va a la RAIZ de la ISO: no necesita el WIM montado. Solo el
# SetupComplete.cmd lo necesita. Separar las dos cosas permite corregir el unattend
# y rearmar la ISO sin volver a montar y commitear el WIM (que son ~20 minutos).
Write-Host "== Fase 8: inyeccion de runtime ==" -ForegroundColor Cyan
if (-not $wimMounted) {
  Write-Step "WIM no montado -> solo se actualiza el autounattend.xml de la ISO" 'Yellow'
}

# 0) Guarda: el autounattend tiene que ser XML valido Y traer el pass windowsPE.
$auSrc = Join-Path $CFG.Root 'config\autounattend.xml'
try {
  $xml = New-Object System.Xml.XmlDocument
  $xml.Load($auSrc)
} catch {
  Write-Host "ERROR: autounattend.xml no es XML valido -> $($_.Exception.Message)" -ForegroundColor Red; exit 1
}
$passes = @($xml.unattend.settings | ForEach-Object { $_.pass })
if ($passes -notcontains 'windowsPE') {
  Write-Host "ERROR: al autounattend.xml le falta el pass 'windowsPE'." -ForegroundColor Red
  Write-Host "       Sin ese pass el instalador DESCARTA EL ARCHIVO ENTERO." -ForegroundColor Red
  exit 1
}

# Guarda 2: settings ubicados en el componente equivocado. Un setting que no existe
# en su componente NO se ignora: invalida el archivo entero y aborta la instalacion
# con "The computer restarted unexpectedly" (hrResult = 0x80220001). Cada entrada es
# "setting -> unico componente que lo acepta".
$homes = @{
  'RunSynchronous' = 'Microsoft-Windows-Deployment'
  'RunAsynchronous' = 'Microsoft-Windows-Deployment'
  'UserAccounts'   = 'Microsoft-Windows-Shell-Setup'
  'OOBE'           = 'Microsoft-Windows-Shell-Setup'
  'UserData'       = 'Microsoft-Windows-Setup'
}
$bad = @()
foreach ($s in $xml.unattend.settings) {
  foreach ($c in @($s.component)) {
    if (-not $c) { continue }
    foreach ($k in $homes.Keys) {
      if ($c.$k -and $c.name -ne $homes[$k]) {
        $bad += "  pass '$($s.pass)': <$k> esta en '$($c.name)' y va en '$($homes[$k])'"
      }
    }
  }
}
if ($bad) {
  Write-Host "ERROR: settings en el componente equivocado en autounattend.xml:" -ForegroundColor Red
  $bad | ForEach-Object { Write-Host $_ -ForegroundColor Red }
  Write-Host "       Esto NO se ignora: invalida el archivo y aborta la instalacion." -ForegroundColor Red
  exit 1
}
Write-Step "autounattend.xml valido - passes: $($passes -join ', ')" 'DarkGray'

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
#  Se inyecta sobre una COPIA EN MEMORIA. config\autounattend.xml no se toca jamas:
#  si le escribieramos la clave, el proximo `git status` la mostraria ahi y la
#  primera vez que el usuario compartiera el repo, regalaria su licencia.
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
  Copy-Item (Join-Path $CFG.Root 'config\autounattend.xml') $auDst -Force
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
