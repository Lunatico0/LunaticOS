<#
  install.ps1 -- Instalador de un solo comando de LunaticOS.

  Uso (cualquier PowerShell, no hace falta que sea admin):
      irm https://github.com/Lunatico0/LunaticOS/releases/latest/download/install.ps1 | iex

  Que hace:
      1. Elige la unidad con mas espacio libre y baja el ultimo release a <unidad>:\LunaticOS
      2. Crea work\ y te la abre para que pongas la ISO oficial de Windows 11
      3. Lanza LunaticOS.cmd, que se eleva solo a Administrador y abre la TUI

  ===========================================================================
  POR QUE APUNTA AL RELEASE Y NO A main
  Esto se corre con "irm | iex" y despues pide Administrador. Si bajara main,
  cada push cambiaria lo que ejecutan los demas sin que nadie lo revise. El
  release es una version fija: lo que se publico es lo que corre.

  POR QUE TODO VA ADENTRO DE UNA FUNCION
  Con "iex" el script corre en la sesion del usuario: un "exit" le cerraria la
  consola. Adentro de una funcion alcanza con "return".
  ===========================================================================
#>

function Install-LunaticOS {
  $ErrorActionPreference = 'Stop'
  # Sin esto PowerShell 5.1 dibuja la barra de progreso por cada KB y la descarga
  # tarda 10 veces mas.
  $ProgressPreference = 'SilentlyContinue'
  # PowerShell 5.1 negocia TLS 1.0 por defecto y GitHub lo rechaza.
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

  $zipUrl = 'https://github.com/Lunatico0/LunaticOS/releases/latest/download/LunaticOS.zip'

  Write-Host ''
  Write-Host '  LunaticOS: debloat offline de Windows 11' -ForegroundColor Cyan
  Write-Host ''

  # --- Destino: la unidad fija con mas espacio libre ---
  # El build necesita ~25 GB de scratch mas la ISO original (~8 GB). Elegir C: a
  # ciegas falla en la PC tipica con un SSD chico para el sistema y un disco de datos.
  $disco = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' |
           Sort-Object FreeSpace -Descending | Select-Object -First 1
  $libreGB = [math]::Round($disco.FreeSpace / 1GB, 1)
  $dest = Join-Path "$($disco.DeviceID)\" 'LunaticOS'
  Write-Host "  destino: $dest  ($libreGB GB libres)" -ForegroundColor Gray
  if ($libreGB -lt 35) {
    Write-Host '  [OJO] hacen falta ~35 GB libres (25 de build + la ISO). Puede no alcanzar.' -ForegroundColor Yellow
  }

  # --- Descarga y extraccion ---
  $tmp = Join-Path $env:TEMP "lunaticos-$(Get-Random)"
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  try {
    Write-Host '  descargando el ultimo release...' -ForegroundColor Gray
    $zip = Join-Path $tmp 'LunaticOS.zip'
    Invoke-WebRequest -Uri $zipUrl -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath (Join-Path $tmp 'src') -Force

    # Se copia ENCIMA y no se borra el destino: si ya lo tenias, work\ (la ISO),
    # perfil.json y clave-windows.txt no vienen en el zip y quedan intactos.
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Copy-Item -Path (Join-Path $tmp 'src\*') -Destination $dest -Recurse -Force
  } catch {
    Write-Host "  [FALLA] no pude bajar LunaticOS: $($_.Exception.Message)" -ForegroundColor Red
    return
  } finally {
    Remove-Item $tmp -Recurse -Force -EA SilentlyContinue
  }
  # Los archivos bajados de internet traen la marca "Mark of the Web" y Windows
  # los frena o pregunta antes de correrlos.
  Get-ChildItem $dest -Recurse -File | Unblock-File
  Write-Host "  [OK]   instalado en $dest" -ForegroundColor Green

  # --- La ISO original: el unico paso que no se puede automatizar ---
  $work = Join-Path $dest 'work'
  New-Item -ItemType Directory -Force -Path $work | Out-Null
  $iso = Get-ChildItem $work -Filter '*.iso' -EA SilentlyContinue |
         Where-Object { $_.Name -notlike '*debloat*' } | Select-Object -First 1
  if (-not $iso) {
    Write-Host ''
    Write-Host '  Falta la ISO oficial de Windows 11 x64 (25H2).' -ForegroundColor Yellow
    Write-Host '  Bajala de https://www.microsoft.com/software-download/windows11' -ForegroundColor Yellow
    Write-Host '  ("Descargar imagen de disco (ISO) de Windows 11 para dispositivos x64")' -ForegroundColor DarkGray
    Write-Host "  y ponela en: $work" -ForegroundColor Yellow
    Start-Process explorer.exe $work
    Write-Host ''
    Read-Host '  Cuando la ISO este en esa carpeta, apreta ENTER'
  } else {
    Write-Host "  [OK]   ISO encontrada: $($iso.Name)" -ForegroundColor Green
  }

  # LunaticOS.cmd pide Administrador solo y abre la TUI en su propia ventana.
  Write-Host '  abriendo LunaticOS (va a pedir permisos de Administrador)...' -ForegroundColor Cyan
  Start-Process -FilePath (Join-Path $dest 'LunaticOS.cmd') -WorkingDirectory $dest
}

Install-LunaticOS
