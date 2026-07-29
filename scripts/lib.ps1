#requires -Version 5.1
<#
  lib.ps1 — Helpers compartidos por las fases. Dot-source:  . "$PSScriptRoot\lib.ps1"

  Lo importante acá es Use-OfflineHive: carga una colmena del WIM, ejecuta tus cambios,
  y SIEMPRE la descarga (finally + reintentos + GC). El fallo #1 del debloat offline es
  dejar un hive cargado: si pasa, el commit/unmount del WIM revienta. Esto lo blinda.
#>

function Write-Step($msg, [string]$color = 'Cyan') { Write-Host "  $msg" -ForegroundColor $color }

# Escribe un DWORD devolviendo $true/$false (NO tira excepcion). Para lotes: si un valor
# esta protegido/no es escribible, se registra y el resto de la fase sigue.
function Set-RegDword($KeyPath, $Name, $Value) {
  try { Invoke-Reg add $KeyPath /v $Name /t REG_DWORD /d $Value /f | Out-Null; return $true }
  catch { return $false }
}

# Ejecuta reg.exe con reintentos (los access-denied transitorios sobre una colmena
# cargada son comunes en invocaciones rapidas). Solo tira si falla las 3 veces.
#
# GUARDA ANTI-CUELGUE (no la saques): si un argumento llega vacio -tipico cuando una
# variable no es visible dentro de un scriptblock- reg.exe NO falla: se queda esperando
# input POR TIEMPO INDEFINIDO y congela el pipeline entero, en silencio. Nos colgo 11
# minutos un "reg add ... /t REG_SZ /d  /f" con el /d vacio. Mejor reventar con un
# mensaje claro que quedarse esperando para siempre.
function Invoke-Reg {
  param([Parameter(ValueFromRemainingArguments = $true)] $RegArgs)
  for ($i = 0; $i -lt $RegArgs.Count; $i++) {
    if ($null -eq $RegArgs[$i] -or "$($RegArgs[$i])".Trim() -eq '') {
      throw ("reg: argumento vacio en la posicion {0} -> '{1}'. " -f $i, ($RegArgs -join ' ')) +
            "Casi seguro una variable que no se ve dentro del scriptblock (usa una `$Global: o interpola el valor)."
    }
  }
  for ($i = 1; $i -le 3; $i++) {
    $out = & reg.exe @RegArgs 2>&1
    if ($LASTEXITCODE -eq 0) { return }
    Start-Sleep -Milliseconds 250
  }
  throw "reg $($RegArgs -join ' ') => $out"
}

# Carga un hive offline en HKLM\<MountKey>, corre el scriptblock, y lo descarga si o si.
# Dentro del scriptblock EDITÁ con reg.exe (Invoke-Reg add/delete) usando la raiz HKLM\<MountKey>,
# NO con el provider PS (Set-ItemProperty deja handles abiertos y rompe el unload).
function Use-OfflineHive {
  param(
    [Parameter(Mandatory)][string]$HivePath,   # ej: <mount>\Windows\System32\config\SOFTWARE
    [Parameter(Mandatory)][string]$MountKey,    # ej: OFF_SW
    [Parameter(Mandatory)][scriptblock]$Action
  )
  if (-not (Test-Path $HivePath)) { throw "No existe la colmena: $HivePath" }
  $full = "HKLM\$MountKey"
  Invoke-Reg load $full $HivePath
  try {
    & $Action $full
  }
  finally {
    [gc]::Collect(); [gc]::WaitForPendingFinalizers()
    $ok = $false
    for ($i = 0; $i -lt 6; $i++) {
      & reg.exe unload $full 2>$null
      if ($LASTEXITCODE -eq 0) { $ok = $true; break }
      Start-Sleep -Milliseconds 400; [gc]::Collect()
    }
    if (-not $ok) { Write-Host "  ! NO pude descargar $full (handles abiertos)" -ForegroundColor Red }
    else { Write-Host "  hive $MountKey descargado OK" -ForegroundColor DarkGray }
  }
}

# Borra un archivo protegido del WIM montado (toma ownership primero).
function Remove-ProtectedFile($path) {
  if (-not (Test-Path $path)) { return $false }
  & takeown /f $path 2>&1 | Out-Null
  & icacls $path /grant "*S-1-5-32-544:F" 2>&1 | Out-Null   # Administrators
  Remove-Item $path -Force -ErrorAction SilentlyContinue
  return -not (Test-Path $path)
}

# Idem pero para un arbol de directorios (takeown /r + icacls /t). Para carpetas
# grandes con ACLs de TrustedInstaller, como las de Edge dentro del WIM.
function Remove-ProtectedDir($path) {
  if (-not (Test-Path $path)) { return $false }
  & takeown /f $path /r /d Y 2>&1 | Out-Null
  & icacls $path /grant "*S-1-5-32-544:F" /t /c 2>&1 | Out-Null   # Administrators
  Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue
  return -not (Test-Path $path)
}
