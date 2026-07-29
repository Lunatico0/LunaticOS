#requires -Version 5.1
<#
  test-vm.ps1 - Probar la ISO generada en una VM Hyper-V, sin intervencion manual.

  Por que existe: cada bug que encontro este proyecto (D14, D18, D19, D20) salio de
  instalar la ISO en una VM y leer los logs. NO de revisar el codigo. Rehacer una ISO
  cuesta ~45 min; descubrir el problema en la mother real cuesta reinstalar.

  ===========================================================================
  EL TECLADO SINTETICO SIRVE PARA EL FIRMWARE, NO PARA EL SETUP.
  Esta distincion costo un test entero: leela antes de tocar el bloque -Boot.

  FUNCIONA en el firmware UEFI. La ISO usa efisys.bin, o sea pide "Press any key
  to boot from CD or DVD" y aborta con "The boot loader failed" si nadie aprieta
  nada en ~5 segundos (D17). Mandar Enter por WMI durante ~25s tras Start-VM SI
  pasa ese prompt:
      Msvm_Keyboard.TypeKey(0x0D)   en root\virtualization\v2

  NO FUNCIONA una vez que arranco WinPE. En "Select location to install Windows 11"
  no llega absolutamente nada. Se probaron cinco variantes, todas con
  ReturnValue=0 y CERO efecto:
      TypeKey(0x0D) · ALT+N via PressKey/ReleaseKey · TypeKey(0x09) TAB x3
      TypeScancodes(0x0F/0x8F) · todo lo anterior con vmconnect.exe abierto
  El TAB es la prueba limpia: el foco no se movio ni un pixel. `ReturnValue=0` es
  una MENTIRA UTIL -- WMI acepta la llamada y descarta el evento.

  COMO SE APRENDIO (y por que el loop no se toca): en una corrida se saco este loop
  creyendo que era inutil, razonando que "con un VHDX vacio el prompt no aparece
  porque no hay otro dispositivo booteable". FALSO: el boot siguiente murio con
  "The boot loader failed" en el SCSI DVD. El prompt aparece igual, y el loop era
  lo unico que lo pasaba. Correlacion mal leida en las dos direcciones.

  EN EL SO YA INSTALADO el teclado vuelve a funcionar para ATAJOS (Win, Win+R,
  Escape), pero NO para escribir texto: `TypeText` y los VK de letras dejan el
  campo vacio. Y `PowerShell Direct` no sirve con password vacio ("The credential
  is invalid").

  CONSECUENCIA: el test NO es 100% desatendido. Hay UN clic humano, en la seleccion
  de disco. Es coherente con D14 (el particionado se deja a mano a proposito, para
  no formatear el disco equivocado).
  ===========================================================================

  Uso:
    .\test-vm.ps1 -Reset       # VHDX limpio + ISO en el DVD + boot del DVD
    .\test-vm.ps1 -Boot        # arranca y manda Enter 25s (pasa el prompt de boot)
    .\test-vm.ps1 -Shot        # screenshot de la pantalla de la VM -> PNG
    .\test-vm.ps1 -Verify      # VM apagada: monta el VHDX y audita el resultado
    .\test-vm.ps1 -Reset -Boot # el flujo tipico -> despues UN clic en "Next"
#>
param(
  [switch]$Reset,
  [switch]$Boot,
  [switch]$Shot,
  [switch]$Verify,
  [switch]$Enter,               # manda UN Enter. OJO: NO funciona en el setup (ver header)
  [string]$VMName  = 'Debloat-Test',
  [int]$KeySeconds = 25         # cuanto tiempo mandar Enter para pasar el prompt de boot
)

. "$PSScriptRoot\config.ps1"

$iso  = Join-Path $CFG.Root 'work\Win11_25H2_Pro_debloat.iso'
$vhdx = Join-Path $CFG.Root 'work\test-vm.vhdx'
$ns   = 'root\virtualization\v2'

function Get-VmCim {
  Get-CimInstance -Namespace $ns -ClassName Msvm_ComputerSystem -Filter "ElementName='$VMName'"
}

if (-not ($Reset -or $Boot -or $Shot -or $Verify -or $Enter)) {
  Write-Host "Nada que hacer. Usa -Reset / -Boot / -Enter / -Shot / -Verify (ver el header)." -ForegroundColor Yellow
  return
}

# --------------------------------------------------------------------------
# ENTER: una sola tecla. El setup pide confirmar el disco a mano (a proposito, D14).
# --------------------------------------------------------------------------
if ($Enter) {
  $vmc = Get-VmCim
  $kbd = Get-CimAssociatedInstance -InputObject $vmc -ResultClassName Msvm_Keyboard -ErrorAction SilentlyContinue
  if (-not $kbd) { Write-Host "ERROR: no encontre el Msvm_Keyboard de la VM" -ForegroundColor Red; exit 1 }
  Invoke-CimMethod -InputObject $kbd -MethodName TypeKey -Arguments @{ keyCode = [uint16]0x0D } | Out-Null
  Write-Host "Enter enviado." -ForegroundColor Green
}

# --------------------------------------------------------------------------
# RESET: VHDX en blanco, ISO montada, DVD primero en el boot order
# --------------------------------------------------------------------------
if ($Reset) {
  Write-Host "== Reset de la VM $VMName ==" -ForegroundColor Cyan
  if (-not (Test-Path $iso)) { Write-Host "ERROR: no existe $iso" -ForegroundColor Red; exit 1 }

  $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
  if (-not $vm) { Write-Host "ERROR: no existe la VM '$VMName'." -ForegroundColor Red; exit 1 }

  if ($vm.State -ne 'Off') {
    Write-Host "  apagando la VM (force)..."
    Stop-VM -Name $VMName -TurnOff -Force
    Start-Sleep -Seconds 3
  }

  # VHDX desde cero: una instalacion sobre restos de la anterior no prueba nada.
  Get-VMHardDiskDrive -VMName $VMName | Remove-VMHardDiskDrive
  if (Test-Path $vhdx) { Remove-Item $vhdx -Force; Write-Host "  VHDX viejo borrado" }
  New-VHD -Path $vhdx -SizeBytes 64GB -Dynamic | Out-Null
  Add-VMHardDiskDrive -VMName $VMName -Path $vhdx
  Write-Host "  VHDX nuevo: 64 GB dinamico" -ForegroundColor Green

  # DVD con la ISO recien generada
  if (-not (Get-VMDvdDrive -VMName $VMName)) { Add-VMDvdDrive -VMName $VMName }
  Set-VMDvdDrive -VMName $VMName -Path $iso
  $dvd = Get-VMDvdDrive -VMName $VMName
  Set-VMFirmware -VMName $VMName -FirstBootDevice $dvd
  Write-Host "  DVD -> $(Split-Path $iso -Leaf) (primero en el boot order)" -ForegroundColor Green

  # Requisitos de Windows 11 y de Vanguard (regla de oro D5): sin esto el test no
  # representa a la maquina real.
  $fw = Get-VMFirmware -VMName $VMName
  if ($fw.SecureBoot -ne 'On') {
    Set-VMFirmware -VMName $VMName -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows
  }
  $tpm = Get-VMSecurity -VMName $VMName
  if (-not $tpm.TpmEnabled) {
    try {
      if (-not $tpm.KeyProtector -or $tpm.KeyProtector.Length -le 4) {
        Set-VMKeyProtector -VMName $VMName -NewLocalKeyProtector
      }
      Enable-VMTPM -VMName $VMName
    } catch { Write-Host "  ! no pude habilitar TPM: $($_.Exception.Message)" -ForegroundColor Yellow }
  }
  $fw  = Get-VMFirmware -VMName $VMName
  $sec = Get-VMSecurity  -VMName $VMName
  Write-Host "  SecureBoot=$($fw.SecureBoot)  TPM=$($sec.TpmEnabled)" -ForegroundColor Green
  Write-Host "Reset OK." -ForegroundColor Green
}

# --------------------------------------------------------------------------
# BOOT: arrancar y pasar el prompt "Press any key"
# --------------------------------------------------------------------------
if ($Boot) {
  Write-Host "== Arrancando $VMName ==" -ForegroundColor Cyan
  if ((Get-VM -Name $VMName).State -ne 'Running') { Start-VM -Name $VMName }

  # NO SAQUES ESTE LOOP. Es lo unico que pasa el prompt "Press any key to boot from
  # CD or DVD"; sin el, el boot muere con "The boot loader failed" (probado a la mala).
  # Y TIENE que cortar despues del primer boot: Windows reinicia varias veces durante
  # el setup y, si seguimos mandando Enter, cada reinicio vuelve a bootear del DVD y
  # el instalador arranca de cero. Loop infinito -- justo lo que el prompt evita (D17).
  $vmc = Get-VmCim
  $kbd = Get-CimAssociatedInstance -InputObject $vmc -ResultClassName Msvm_Keyboard -ErrorAction SilentlyContinue
  if (-not $kbd) {
    Write-Host "  ! no encontre el Msvm_Keyboard: vas a tener que apretar una tecla a mano" -ForegroundColor Yellow
  } else {
    Write-Host "  mandando Enter ${KeySeconds}s para pasar el prompt de boot..."
    Write-Host "  (y NI UNO MAS, o cada reinicio del setup vuelve a bootear del DVD)" -ForegroundColor DarkGray
    $deadline = (Get-Date).AddSeconds($KeySeconds)
    while ((Get-Date) -lt $deadline) {
      try { Invoke-CimMethod -InputObject $kbd -MethodName TypeKey -Arguments @{ keyCode = [uint16]0x0D } | Out-Null } catch { }
      Start-Sleep -Milliseconds 500
    }
    Write-Host "  teclado liberado: el setup sigue solo." -ForegroundColor Green
  }
  Write-Host ""
  Write-Host "  ACCION MANUAL REQUERIDA (una sola, ver el header):" -ForegroundColor Yellow
  Write-Host "    1. Abri la consola:  vmconnect.exe localhost $VMName" -ForegroundColor Yellow
  Write-Host "    2. En 'Select location to install Windows 11' -> clic en Next" -ForegroundColor Yellow
  Write-Host "       El teclado sintetico NO funciona ahi. Tiene que ser un clic." -ForegroundColor DarkGray
  Write-Host ""
  Write-Host "  Despues sigue solo (~20-30 min). Progreso:  .\test-vm.ps1 -Shot"
  Write-Host "  Cuando termine:  Stop-VM $VMName  y luego  .\test-vm.ps1 -Verify"
}

# --------------------------------------------------------------------------
# SHOT: screenshot de la VM (sin pedirle capturas al usuario)
# --------------------------------------------------------------------------
if ($Shot) {
  Add-Type -AssemblyName System.Drawing
  # OJO: aca se usa WMI y no CIM a proposito. GetVirtualSystemThumbnailImage recibe el
  # TargetSystem por REFERENCIA, e Invoke-CimMethod no sabe convertir un [ref]CimInstance
  # a InstanceHandle: revienta con "Unable to cast object of type PSReference". Con
  # Get-WmiObject se pasa el __PATH como string y funciona.
  $vmw  = Get-WmiObject -Namespace $ns -Class Msvm_ComputerSystem -Filter "ElementName='$VMName'"
  $mgmt = Get-WmiObject -Namespace $ns -Class Msvm_VirtualSystemManagementService

  # La resolucion se le PREGUNTA a la VM, no se asume. Pedir un tamaño que el video
  # head no tiene devuelve un buffer de largo distinto al que espera el bitmap, y el
  # Marshal.Copy se va de rango: AccessViolationException y muere el proceso entero.
  $vh = $vmw.GetRelated('Msvm_VideoHead') | Select-Object -First 1
  if ($vh -and $vh.CurrentHorizontalResolution -and $vh.CurrentVerticalResolution) {
    $w = [int]$vh.CurrentHorizontalResolution
    $h = [int]$vh.CurrentVerticalResolution
  } else {
    $w = 1024; $h = 768   # sin video head activo (VM recien arrancada): valor tipico
  }

  # El thumbnail se pide contra el SETTING DATA activo, no contra el ComputerSystem.
  $set  = $vmw.GetRelated('Msvm_VirtualSystemSettingData', 'Msvm_SettingsDefineState',
                          $null, $null, $null, $null, $false, $null) | Select-Object -First 1
  $res  = $mgmt.GetVirtualSystemThumbnailImage($set.__PATH, $w, $h)
  if (-not $res.ImageData) { Write-Host "ERROR: sin imagen (la VM esta apagada?)" -ForegroundColor Red; exit 1 }

  # El buffer viene en RGB565: 2 bytes por pixel. Hay que declararlo asi o sale basura.
  $bytes = [byte[]]$res.ImageData
  $bmp  = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format16bppRgb565)
  $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
  $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly,
                        [System.Drawing.Imaging.PixelFormat]::Format16bppRgb565)
  # Guarda: nunca copiar mas de lo que entra en el bitmap. Si Hyper-V devolvio otro
  # tamaño, preferimos una imagen parcial antes que corromper memoria.
  $capacity = $data.Stride * $h
  $len = [Math]::Min($bytes.Length, $capacity)
  if ($bytes.Length -ne $capacity) {
    Write-Host ("  ! buffer {0} bytes vs bitmap {1} ({2}x{3}) - copio {4}" -f `
                $bytes.Length, $capacity, $w, $h, $len) -ForegroundColor Yellow
  }
  [System.Runtime.InteropServices.Marshal]::Copy($bytes, 0, $data.Scan0, $len)
  $bmp.UnlockBits($data)
  $out = Join-Path $env:TEMP ("vm-{0}.png" -f (Get-Date -Format 'HHmmss'))
  $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  Write-Host "screenshot: $out" -ForegroundColor Green
}

# --------------------------------------------------------------------------
# VERIFY: auditar el disco instalado (VM APAGADA)
# --------------------------------------------------------------------------
if ($Verify) {
  Write-Host "== Auditoria del disco instalado ==" -ForegroundColor Cyan
  if ((Get-VM -Name $VMName).State -ne 'Off') {
    Write-Host "ERROR: apaga la VM primero (Stop-VM $VMName). Montar el VHDX de una VM" -ForegroundColor Red
    Write-Host "       encendida corrompe el disco." -ForegroundColor Red
    exit 1
  }

  $img = Mount-DiskImage -ImagePath $vhdx -Access ReadOnly -PassThru
  try {
    # La particion de Windows es la mas grande con letra asignada.
    $vol = $img | Get-Disk | Get-Partition | Get-Volume |
             Where-Object { $_.DriveLetter } | Sort-Object Size -Descending | Select-Object -First 1
    $d = "$($vol.DriveLetter):"
    Write-Host "  Windows montado en $d" -ForegroundColor DarkGray

    # OJO: el criterio cambio con D21. Edge SI puede estar en disco -- de hecho va a
    # estar, porque Windows Update lo trae junto con WebView2 (mismo instalador). Lo
    # que se verifica es que NO PUEDA EJECUTARSE y que NO SE VEA. Verificar "ausencia
    # de Edge" seria medir contra un objetivo que ya descartamos.
    Write-Host "`n--- IFEO: el navegador NO debe poder ejecutarse (esto es el fix real) ---" -ForegroundColor Cyan
    & reg.exe load HKLM\VRF_SW "$d\Windows\System32\config\SOFTWARE" 2>&1 | Out-Null
    $ifeo = 'HKLM\VRF_SW\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
    foreach ($e in @('msedge.exe','msedge_proxy.exe','msedge_pwa_launcher.exe')) {
      $q = (& reg.exe query "$ifeo\$e" /v Debugger 2>&1) -join "`n"
      if ($q -match 'Debugger') { Write-Host "  OK: $e bloqueado" -ForegroundColor Green }
      else                      { Write-Host "  FALLO: $e SIN bloqueo -> Edge se puede abrir" -ForegroundColor Red }
    }
    # WebView2 tiene que quedar LIBRE: si lo bloqueamos, se rompen la Store y Widgets.
    $q = (& reg.exe query "$ifeo\msedgewebview2.exe" /v Debugger 2>&1) -join "`n"
    if ($q -match 'Debugger') { Write-Host "  FALLO: msedgewebview2.exe bloqueado (rompe Store/Widgets)" -ForegroundColor Red }
    else                      { Write-Host "  OK: msedgewebview2.exe libre (correcto)" -ForegroundColor Green }
    & reg.exe unload HKLM\VRF_SW 2>&1 | Out-Null

    Write-Host "`n--- ACCESOS DIRECTOS de Edge: no deben verse ---" -ForegroundColor Cyan
    $lnks = @("$d\Users\Public\Desktop\Microsoft Edge.lnk",
              "$d\ProgramData\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk")
    Get-ChildItem "$d\Users" -Directory -Force -EA SilentlyContinue | ForEach-Object {
      $lnks += "$($_.FullName)\Desktop\Microsoft Edge.lnk"
      $lnks += "$($_.FullName)\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk"
    }
    $vis = @($lnks | Select-Object -Unique | Where-Object { Test-Path $_ })
    if ($vis) { $vis | ForEach-Object { Write-Host "  QUEDO VISIBLE: $_" -ForegroundColor Yellow } }
    else      { Write-Host "  OK: ningun acceso directo de Edge" -ForegroundColor Green }

    Write-Host "`n--- WEBVIEW2: debe estar PRESENTE (si falta, Store y Widgets se rompen) ---" -ForegroundColor Cyan
    $wv = "$d\Program Files (x86)\Microsoft\EdgeWebView\Application"
    if (Test-Path $wv) { Write-Host "  OK: $wv" -ForegroundColor Green }
    else               { Write-Host "  FALLO: falta WebView2" -ForegroundColor Red }

    Write-Host "`n--- SERVICIOS edgeupdate: deben estar VIVOS (mantienen WebView2) ---" -ForegroundColor Cyan
    & reg.exe load HKLM\VRF_SYS "$d\Windows\System32\config\SYSTEM" 2>&1 | Out-Null
    foreach ($s in @('edgeupdate','edgeupdatem')) {
      $q = (& reg.exe query "HKLM\VRF_SYS\ControlSet001\Services\$s" /v Start 2>&1) -join "`n"
      $v = if ($q -match '0x(\d)') { $Matches[1] } else { '?' }
      switch ($v) {
        '2' { Write-Host "  OK: $s Automatic" -ForegroundColor Green }
        '3' { Write-Host "  OK: $s Manual" -ForegroundColor Green }
        '4' { Write-Host "  FALLO: $s Disabled -> WebView2 se queda sin parches" -ForegroundColor Red }
        default { Write-Host "  (no existe el servicio $s)" -ForegroundColor DarkGray }
      }
    }
    & reg.exe unload HKLM\VRF_SYS 2>&1 | Out-Null

    Write-Host "`n--- SERVICIOS de la fase 4: muestra (deben estar Disabled=0x4) ---" -ForegroundColor Cyan
    & reg.exe load HKLM\VRF_SY2 "$d\Windows\System32\config\SYSTEM" 2>&1 | Out-Null
    foreach ($s in @('DiagTrack','wisvc','SEMgrSvc','PushToInstall','PcaSvc','lfsvc')) {
      $q = (& reg.exe query "HKLM\VRF_SY2\ControlSet001\Services\$s" /v Start 2>&1) -join "`n"
      $v = if ($q -match '0x(\d)') { $Matches[1] } else { '?' }
      if ($v -eq '4') { Write-Host "  OK: $s Disabled" -ForegroundColor Green }
      else            { Write-Host "  OJO: $s Start=$v (esperado 4)" -ForegroundColor Yellow }
    }
    & reg.exe unload HKLM\VRF_SY2 2>&1 | Out-Null

    Write-Host "`n--- EDGEUPDATE corrio? (ahora es ESPERADO: mantiene WebView2) ---" -ForegroundColor Cyan
    $log = "$d\ProgramData\Microsoft\EdgeUpdate\Log\MicrosoftEdgeUpdate.log"
    if (Test-Path $log) {
      # Lo que importa no es que corra, sino CON QUE installsource. 'windowsupdate_zdp'
      # es Windows Update empujando el paquete; 'core'/'scheduler' es mantenimiento normal.
      $src = Select-String -Path $log -Pattern 'installsource (\w+)' -AllMatches |
               ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value } |
               Group-Object | Sort-Object Count -Descending
      Write-Host "  EdgeUpdate corrio (esperado). installsource visto:" -ForegroundColor DarkGray
      $src | ForEach-Object { Write-Host ("    {0,-22} x{1}" -f $_.Name, $_.Count) }
    } else {
      Write-Host "  no hay log -> EdgeUpdate no corrio (WebView2 no se va a actualizar)" -ForegroundColor Yellow
    }

    Write-Host "`n--- UNATTEND: se proceso? ---" -ForegroundColor Cyan
    if (Test-Path "$d\Windows\Panther\unattend.xml") {
      Write-Host "  OK: existe Panther\unattend.xml (el unattend se aplico)" -ForegroundColor Green
    } else {
      Write-Host "  FALLO: no existe Panther\unattend.xml -> el unattend se descarto (ver D14)" -ForegroundColor Red
    }

    Write-Host "`n--- ERRORES del setup ---" -ForegroundColor Cyan
    $err = "$d\Windows\Panther\setuperr.log"
    if ((Test-Path $err) -and (Get-Item $err).Length -gt 0) {
      Get-Content $err -Tail 15 | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
    } else { Write-Host "  sin errores registrados" -ForegroundColor Green }

    Write-Host "`n--- PERFILES de usuario (deberia estar 'pato') ---" -ForegroundColor Cyan
    Get-ChildItem "$d\Users" -Directory -Force -EA SilentlyContinue |
      Where-Object { $_.Name -notin @('Public','Default','Default User','All Users') } |
      ForEach-Object { Write-Host "  $($_.Name)" }

    Write-Host "`n--- BLOAT: appx que sacamos (no deberian aparecer) ---" -ForegroundColor Cyan
    $found = @()
    foreach ($a in @('Clipchamp','BingNews','MicrosoftOfficeHub','YourPhone','MSTeams','DevHome')) {
      if (Get-ChildItem "$d\Program Files\WindowsApps" -Directory -Filter "*$a*" -Force -EA SilentlyContinue) { $found += $a }
    }
    if ($found) { Write-Host "  presentes: $($found -join ', ')" -ForegroundColor Red }
    else        { Write-Host "  OK: ninguno de los removidos aparece" -ForegroundColor Green }
  }
  finally {
    Dismount-DiskImage -ImagePath $vhdx | Out-Null
    Write-Host "`nVHDX desmontado." -ForegroundColor DarkGray
  }
}
