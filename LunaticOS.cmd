@echo off
REM ============================================================================
REM  LunaticOS.cmd - doble clic y anda.
REM
REM  POR QUE EXISTE ESTE ARCHIVO:
REM  Windows asocia los .ps1 al EDITOR, no al interprete. Hacer doble clic en
REM  LunaticOS.ps1 abre el Notepad y parece que la herramienta esta rota. Un .cmd
REM  si se ejecuta al doble clic, asi que este lanza el .ps1 de verdad.
REM
REM  Ademas se ELEVA SOLO: el pipeline monta imagenes y edita colmenas del
REM  registro, o sea que necesita Administrador. Sin esto, el preflight te dice
REM  "no sos admin" y tenes que volver a empezar a mano.
REM ============================================================================

cd /d "%~dp0"

REM Ya somos admin? "net session" solo funciona elevado.
net session >nul 2>&1
if %errorlevel% equ 0 goto :run

echo Pidiendo permisos de Administrador...
REM Relanza este mismo .cmd elevado y termina esta instancia.
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Start-Process -FilePath '%~f0' -Verb RunAs"
exit /b 0

:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0LunaticOS.ps1" %*
if %errorlevel% neq 0 (
  echo.
  echo LunaticOS termino con error %errorlevel%.
)
echo.
pause
