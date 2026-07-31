@echo off
REM ============================================================================
REM  SetupComplete.cmd - corre AL FINAL del setup, como SYSTEM, ANTES del OOBE.
REM  Windows lo ejecuta solo si esta en \Windows\Setup\Scripts\SetupComplete.cmd
REM  (confirmado: windeploy.exe -> "RunUserProvidedScript: Found script at
REM   [C:\WINDOWS\Setup\Scripts\SetupComplete.cmd]").
REM
REM  OJO CON EL TIMING. Medido en la VM de prueba:
REM      SetupComplete  ->  antes del OOBE
REM      21:45          ->  arranca EdgeUpdate (durante el OOBE)
REM      21:49          ->  Edge queda instalado
REM      21:52          ->  escritorio
REM  Desinstalar Edge ACA NO SIRVE: el OOBE lo reinstala despues, y el uninstaller de
REM  Microsoft se niega fuera del EEA. Lo que realmente lo neutraliza es el bloqueo
REM  IFEO que la fase 7 escribe offline (ver D21): Edge queda inejecutable pase lo que
REM  pase. Aca solo se limpian los accesos directos que el instalador dejo recien.
REM
REM  NO se tocan los servicios edgeupdate/edgeupdatem: se dejan VIVOS a proposito,
REM  son los que mantienen WebView2 parchado.
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

REM --- 2) Accesos directos de Edge que el instalador acaba de dejar ---
REM     El bloqueo real es el IFEO de la fase 7: aunque quede un icono, no ejecuta nada.
REM     Esto es solo cosmetica, para que no aparezca en el escritorio ni en el Inicio.
del /f /q "%PUBLIC%\Desktop\Microsoft Edge.lnk"                                    >nul 2>&1
del /f /q "%ProgramData%\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk" >nul 2>&1
for /d %%U in ("%SystemDrive%\Users\*") do (
  del /f /q "%%U\Desktop\Microsoft Edge.lnk"                                                          >nul 2>&1
  del /f /q "%%U\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk"            >nul 2>&1
  del /f /q "%%U\AppData\Roaming\Microsoft\Internet Explorer\Quick Launch\Microsoft Edge.lnk"         >nul 2>&1
  del /f /q "%%U\AppData\Roaming\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Microsoft Edge.lnk" >nul 2>&1
)

REM --- 3) Red de seguridad: reafirmar el bloqueo IFEO en caliente ---
REM     Si por lo que sea el hive offline no tomo, esto lo deja escrito igual.
for %%E in (msedge.exe msedge_proxy.exe msedge_pwa_launcher.exe) do (
  reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\%%E" ^
    /v Debugger /t REG_SZ /d "C:\Windows\System32\systray.exe" /f >nul 2>&1
)

REM --- 4) PROBLEMA DE TIMING: este script corre ANTES del OOBE, y Edge se instala
REM     DURANTE el OOBE. O sea que los accesos directos del paso 2 pueden no existir
REM     todavia cuando los borramos. Por eso se deja un RunOnce que corre en el PRIMER
REM     LOGIN -ya pasado el OOBE- y limpia lo que Edge haya dejado recien.
REM     El bloqueo real sigue siendo el IFEO; esto es puramente cosmetico.
set "LIMPIA=%SystemRoot%\Setup\Scripts\limpiar-edge.cmd"
> "%LIMPIA%" echo @echo off
>>"%LIMPIA%" echo del /f /q "%%PUBLIC%%\Desktop\Microsoft Edge.lnk" ^>nul 2^>^&1
>>"%LIMPIA%" echo del /f /q "%%ProgramData%%\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk" ^>nul 2^>^&1
>>"%LIMPIA%" echo for /d %%%%U in ("%%SystemDrive%%\Users\*") do (
>>"%LIMPIA%" echo   del /f /q "%%%%U\Desktop\Microsoft Edge.lnk" ^>nul 2^>^&1
>>"%LIMPIA%" echo   del /f /q "%%%%U\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk" ^>nul 2^>^&1
>>"%LIMPIA%" echo   del /f /q "%%%%U\AppData\Roaming\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Microsoft Edge.lnk" ^>nul 2^>^&1
>>"%LIMPIA%" echo )
>>"%LIMPIA%" echo del "%%~f0" ^>nul 2^>^&1
REM     EL PREFIJO 'AB' IMPORTA. RunOnce ejecuta sus entradas en orden ALFABETICO y
REM     de forma SECUENCIAL, esperando que cada una termine. Esta entrada se llamaba
REM     "ZZLimpiarEdge" y quedaba DESPUES del instalador de programas, que tarda 20+
REM     minutos: nunca llegaba a correr y el acceso directo de Edge quedaba visible.
REM     Verificado en VM: el .lnk de Edge seguia en el menu Inicio del usuario.
REM     Orden actual:  AA personalizar -> AB limpiar Edge -> ZZ instalar programas.
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v ABLunaticOSLimpiarEdge /t REG_SZ ^
  /d "cmd.exe /c \"%SystemRoot%\Setup\Scripts\limpiar-edge.cmd\"" /f >nul 2>&1

REM ============================================================================
REM  --- Servicios que el ACL no dejo tocar offline ---
REM
REM  La fase 4 deshabilita los servicios escribiendo Start=4 en el hive SYSTEM
REM  montado. Algunos servicios NIEGAN esa escritura por ACL, incluso offline:
REM  medido con TrkWks, que quedaba en Start=2 (Automatic) y CORRIENDO. El log de la
REM  fase lo avisaba, pero ahi moria el asunto y nadie lo reintentaba.
REM
REM  Aca somos SYSTEM, que SI tiene FullControl sobre esas claves, asi que este es
REM  el lugar donde se puede. El .cmd lo genera la fase 4 con la lista de los que le
REM  fallaron; si no fallo ninguno, el archivo no existe y esto no hace nada.
REM  Deja su resultado en %ProgramData%\LunaticOS\servicios.log
REM ============================================================================
if exist "%SystemRoot%\Setup\Scripts\lunaticos-servicios.cmd" (
  call "%SystemRoot%\Setup\Scripts\lunaticos-servicios.cmd"
)

REM --- Autolimpieza ---
del "%~f0" >nul 2>&1
exit /b 0
