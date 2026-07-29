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

# 2) autounattend.xml en la raiz de la ISO
Copy-Item (Join-Path $CFG.Root 'config\autounattend.xml') (Join-Path $CFG.IsoBuild 'autounattend.xml') -Force
Write-Step "autounattend.xml -> raiz de la ISO (cuenta local + region AR + teclado ES/EN)" 'Green'
