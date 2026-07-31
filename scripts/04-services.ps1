#requires -Version 5.1
<#
  Fase 4 -- Servicios a Disabled (SYSTEM hive, offline).
    Edita ControlSet001\Services\<svc>\Start = 4 (disabled) para los servicios de $ServicesDisable.
    Blindaje: si el servicio NO existe en la imagen, se saltea (no crea fantasmas).
    Solo servicios "seguros" del plan -- NO toca red/cripto/audio/update/seguridad/anticheat.

  Start: 0=boot 1=system 2=automatic 3=manual 4=disabled

  Uso:  .\04-services.ps1           # aplica
        .\04-services.ps1 -DryRun   # muestra que haria
#>
param([switch]$DryRun)

. "$PSScriptRoot\config.ps1"
. "$PSScriptRoot\lib.ps1"
$mount = $CFG.Mount
if (-not (Test-Path (Join-Path $mount 'Windows'))) {
  Write-Host "ERROR: no hay imagen montada en $mount" -ForegroundColor Red; exit 1
}

Write-Host "== Fase 4: servicios -> Disabled (SYSTEM hive) ==" -ForegroundColor Cyan
if ($DryRun) { $ServicesDisable | ForEach-Object { Write-Step "[dry] $_ -> Start=4" 'DarkGray' }; return }

Use-OfflineHive -HivePath (Join-Path $mount 'Windows\System32\config\SYSTEM') -MountKey 'OFF_SYS' -Action {
  param($root)
  $done = 0; $skip = 0; $failed = @()
  foreach ($svc in $ServicesDisable) {
    $key = "$root\ControlSet001\Services\$svc"
    & reg.exe query $key 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
      Write-Step "(no existe en la imagen) $svc" 'DarkGray'; $skip++; continue
    }
    # Set-RegDword devuelve $false en vez de tirar: algunos servicios tienen ACLs
    # que niegan la escritura incluso offline (nos paso con TrkWks). Un servicio
    # protegido NO puede abortar los otros 30 -- por eso no se usa Invoke-Reg aca.
    if (Set-RegDword $key 'Start' 4) {
      Write-Step "disabled: $svc" 'Green'; $done++
    } else {
      Write-Step "PROTEGIDO (access denied): $svc" 'Yellow'; $failed += $svc
    }
  }
  Write-Step ("disabled=$done  no-presentes=$skip  protegidos=$($failed.Count)") 'Cyan'
  if ($failed) {
    Write-Host "  ! Estos no se pudieron escribir offline (ACL del registro):" -ForegroundColor Yellow
    Write-Host "      $($failed -join ', ')" -ForegroundColor Yellow
    Write-Host "    Se reintentan en el primer arranque como SYSTEM (ver abajo)." -ForegroundColor DarkGray
  }
  # Se saca del scriptblock para que la parte de runtime lo vea.
  $Global:ServicesProtegidos = @($failed)
}

# ===========================================================================
#  SEGUNDA PASADA, EN RUNTIME: los que el ACL no dejo tocar offline
#
#  MEDIDO en la VM del 2026-07-30: TrkWks quedo con Start=2 (Automatic) y corriendo,
#  porque su clave del registro niega la escritura al Administrador del HOST incluso
#  con el hive montado. El log de la fase lo decia ("PROTEGIDO access denied") pero
#  ahi terminaba: el servicio quedaba habilitado y nadie lo reintentaba nunca.
#
#  La salida es cambiar QUIEN escribe. SetupComplete.cmd corre como SYSTEM, al final
#  del setup y antes del OOBE, y SYSTEM si tiene FullControl sobre esas claves
#  (verificado leyendo el ACL: NT AUTHORITY\SYSTEM=FullControl).
#
#  Se usa `sc.exe config` y no `reg add`: es la via soportada, actualiza la
#  configuracion del SCM y no solo el valor crudo del registro.
#
#  PROBADO EN LA VM (2026-07-30), no deducido -- se corrio dentro del SO instalado:
#      ANTES:   TrkWks StartType=Automatic Status=Running Start(reg)=2
#      sc.exe config TrkWks start= disabled  ->  ChangeServiceConfig SUCCESS
#      DESPUES: TrkWks StartType=Disabled  Status=Stopped Start(reg)=4
#  O sea: lo que el ACL niega offline, en runtime se puede.
#
#  Sobre la sintaxis: se escribe "start= disabled" con el espacio DESPUES del '='
#  porque es la forma que documenta sc.exe. Medido en 25H2, "start=disabled" sin
#  espacio TAMBIEN funciona -- asi que la advertencia clasica sobre ese espacio no
#  aplica en esta version. Se usa igual la forma documentada: no hay nada que ganar
#  apostando a que la tolerancia siga ahi en la proxima build.
# ===========================================================================
if ($Global:ServicesProtegidos -and $Global:ServicesProtegidos.Count -gt 0) {
  $scriptsDir = Join-Path $mount 'Windows\Setup\Scripts'
  New-Item -ItemType Directory -Force -Path $scriptsDir | Out-Null

  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine('@echo off')
  [void]$sb.AppendLine('REM Generado por la fase 4 de LunaticOS. Corre como SYSTEM desde SetupComplete.cmd.')
  [void]$sb.AppendLine('REM Son los servicios cuyo ACL nego la escritura con el hive montado offline.')
  [void]$sb.AppendLine('REM El espacio despues del "=" de start= es obligatorio en sc.exe.')
  [void]$sb.AppendLine('set "LOG=%ProgramData%\LunaticOS\servicios.log"')
  [void]$sb.AppendLine('if not exist "%ProgramData%\LunaticOS" mkdir "%ProgramData%\LunaticOS"')
  [void]$sb.AppendLine('echo === segunda pasada de servicios (SYSTEM) === >> "%LOG%"')
  foreach ($svc in $Global:ServicesProtegidos) {
    [void]$sb.AppendLine(('sc.exe stop "{0}" >> "%LOG%" 2>&1' -f $svc))
    [void]$sb.AppendLine(('sc.exe config "{0}" start= disabled >> "%LOG%" 2>&1' -f $svc))
    [void]$sb.AppendLine(('if errorlevel 1 (echo FALLO {0} >> "%LOG%") else (echo OK {0} >> "%LOG%")' -f $svc))
  }
  [void]$sb.AppendLine('echo === listo === >> "%LOG%"')

  $dst = Join-Path $scriptsDir 'lunaticos-servicios.cmd'
  [System.IO.File]::WriteAllText($dst, $sb.ToString(), (New-Object System.Text.ASCIIEncoding))
  Write-Step ("generado lunaticos-servicios.cmd: reintenta {0} servicio(s) como SYSTEM" -f $Global:ServicesProtegidos.Count) 'Green'
  Write-Step ("  ({0})" -f ($Global:ServicesProtegidos -join ', ')) 'DarkGray'
} else {
  Write-Step 'ninguno quedo protegido: no hace falta la segunda pasada' 'DarkGray'
}
