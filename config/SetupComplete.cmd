@echo off
REM ============================================================================
REM  SetupComplete.cmd - corre AL FINAL del setup, como SYSTEM, antes del 1er login.
REM  Hace lo que no se puede 100%% offline:
REM    1) deshabilita scheduled tasks de telemetria
REM    2) quita el navegador Edge (preservando WebView2)
REM  Windows lo ejecuta solo si esta en \Windows\Setup\Scripts\SetupComplete.cmd
REM ============================================================================

REM --- 1) Scheduled tasks de telemetria (2>nul: varias no existen en 25H2) ---
for %%T in (
  "\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser"
  "\Microsoft\Windows\Application Experience\ProgramDataUpdater"
  "\Microsoft\Windows\Application Experience\StartupAppTask"
  "\Microsoft\Windows\Application Experience\PcaPatchDbTask"
  "\Microsoft\Windows\Customer Experience Improvement Program\Consolidator"
  "\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip"
  "\Microsoft\Windows\Customer Experience Improvement Program\KernelCeipTask"
  "\Microsoft\Windows\Autochk\Proxy"
  "\Microsoft\Windows\Feedback\Siuf\DmClient"
  "\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload"
  "\Microsoft\Windows\Windows Error Reporting\QueueReporting"
  "\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector"
  "\Microsoft\Windows\Maps\MapsUpdateTask"
  "\Microsoft\Windows\Maps\MapsToastTask"
) do schtasks /Change /TN %%T /Disable >nul 2>&1

REM --- 2) Quitar el NAVEGADOR Edge (NO WebView2) ---
REM     El browser vive en Edge\Application; WebView2 en EdgeWebView\Application (intacto).
set "EDGEBASE=%ProgramFiles(x86)%\Microsoft\Edge\Application"
if not exist "%EDGEBASE%" set "EDGEBASE=%ProgramFiles%\Microsoft\Edge\Application"
for /d %%V in ("%EDGEBASE%\*") do (
  if exist "%%V\Installer\setup.exe" (
    "%%V\Installer\setup.exe" --uninstall --msedge --system-level --verbose-logging --force-uninstall
  )
)

REM --- Bloquear que Edge vuelva por update (WebView2 sigue actualizando aparte) ---
reg add "HKLM\SOFTWARE\Microsoft\EdgeUpdate" /v DoNotUpdateToEdgeWithChromium /t REG_DWORD /d 1 /f >nul 2>&1

REM --- Autolimpieza ---
del "%~f0" >nul 2>&1
exit /b 0
