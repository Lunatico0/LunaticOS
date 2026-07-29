#requires -Version 5.1
<#
  lib.ps1 -- Helpers compartidos por las fases. Dot-source:  . "$PSScriptRoot\lib.ps1"

  Lo importante aca es Use-OfflineHive: carga una colmena del WIM, ejecuta tus cambios,
  y SIEMPRE la descarga (finally + reintentos + GC). El fallo #1 del debloat offline es
  dejar un hive cargado: si pasa, el commit/unmount del WIM revienta. Esto lo blinda.
#>

function Write-Step($msg, [string]$color = 'Cyan') { Write-Host "  $msg" -ForegroundColor $color }

# ===========================================================================
#  ConvertTo-AccentDwords - LA UNICA conversion de color del repo.
#
#  ###################################################################
#   NO ESCRIBAS UN COLOR A MANO EN NINGUN OTRO ARCHIVO. NUNCA.
#  ###################################################################
#
#  POR QUE existe: dos valores de LA MISMA clave del registro usan formatos de
#  bytes DISTINTOS. Escribir ARGB en los dos hizo que el acento saliera de otro
#  color y que partes de la UI tomaran colores diferentes entre si -- el
#  "coloreado a la fuerza" que reporto el usuario.
#
#  Para el color #RRGGBB:
#    ABGR = 0xFFBBGGRR -> DWM\AccentColor, AccentColorInactive,
#                         Explorer\Accent\AccentColorMenu, StartColorMenu
#    ARGB = 0xC4RRGGBB -> DWM\ColorizationColor, ColorizationAfterglow,
#                         y el ColorizationColor del .theme
#
#  LA PRUEBA (medida en una maquina real, no deducida): el default de fabrica de
#  Windows es AccentColor = 0xFFD77800. Leido como ABGR da #0078D7, que es el azul
#  conocido de Windows. Leido como ARGB daria #D77800, un naranja que Windows no
#  usa en ninguna parte. Y en la misma maquina ColorizationColor = 0xC44C4A48 con
#  un acento real de #4C4A48: ahi los bytes van derechos. Cierra por los dos lados.
#  Detalle completo y tabla en docs\personalizacion-contrato.md, seccion 1.
#
#  POR QUE con corrimientos de bits y no con literales: PowerShell parsea un
#  literal hexadecimal de 8 digitos como Int32 CON SIGNO, asi que 0xFF14B8A6 da
#  -15419226. Todo ARGB con alpha FF tiene el bit alto prendido y SIEMPRE cae
#  negativo. Eso ya costo una ISO entera: los tres valores del acento fallaban en
#  silencio. Operando sobre [uint32] con -shl el problema no puede ocurrir.
# ===========================================================================
function ConvertTo-AccentDwords([string]$Hex) {
  # Fallar RUIDOSO es el objetivo. Un color mal tipeado que pasa desapercibido
  # reaparece 45 minutos despues, dentro de una ISO, y nadie sabe por que.
  if ([string]::IsNullOrWhiteSpace($Hex)) {
    throw "ConvertTo-AccentDwords: color vacio. Se esperaba algo tipo '#14B8A6'."
  }
  $h = "$Hex".Trim().TrimStart('#').ToUpperInvariant()
  if ($h -notmatch '^[0-9A-F]{6}$') {
    throw "ConvertTo-AccentDwords: color invalido '$Hex'. Se esperan 6 digitos hexadecimales, tipo '#14B8A6'."
  }

  [uint32]$r = [Convert]::ToUInt32($h.Substring(0, 2), 16)
  [uint32]$g = [Convert]::ToUInt32($h.Substring(2, 2), 16)
  [uint32]$b = [Convert]::ToUInt32($h.Substring(4, 2), 16)

  # ABGR: alpha FF opaco, y despues B, G, R. El byte MENOS significativo es el rojo.
  [uint32]$abgr = ([uint32]0xFF -shl 24) -bor ($b -shl 16) -bor ($g -shl 8) -bor $r
  # ARGB: alpha C4 (el que usa Windows en ColorizationColor y en los .theme de
  # fabrica: dark.theme trae 0XC40078D4), y despues R, G, B en orden natural.
  [uint32]$argb = ([uint32]0xC4 -shl 24) -bor ($r -shl 16) -bor ($g -shl 8) -bor $b

  @{
    Hex        = $h
    R          = [byte]$r
    G          = [byte]$g
    B          = [byte]$b
    Abgr       = $abgr
    Argb       = $argb
    # '0X' en mayuscula a proposito: es como lo escriben los .theme de Windows.
    ThemeColor = ('0X{0:X8}' -f $argb)
  }
}

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
# Dentro del scriptblock EDITA con reg.exe (Invoke-Reg add/delete) usando la raiz HKLM\<MountKey>,
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
