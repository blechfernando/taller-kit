@echo off
setlocal
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Solicitando permisos de Administrador...
    set "__BAT=%~f0"
    powershell -NoProfile -Command "Start-Process -FilePath $env:__BAT -Verb RunAs"
    exit /b
)

set "TS_KEY="
if exist "%~dp0config\tailscale-auth.txt" set "TS_KEY=FILE"
if exist "%~dp0tailscale-auth.txt" set "TS_KEY=FILE"

if defined TS_KEY (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\taller-setup.ps1"
    exit /b %errorlevel%
)

echo ============================================================
echo   TALLER KIT - CONECTAR PC (FIJA LAN + INTERNET)
echo ============================================================
echo.
set /p "TS_NAME=Nombre corto para esta PC [ENTER = %COMPUTERNAME%]: "
echo.
echo Si queres activar Internet ahora mismo, pega tu Tailscale Auth Key.
echo Si la dejas vacia (ENTER), igual instala SSH + VNC + Tailscale listo.
set /p "TS_KEY=Tailscale Auth Key [opcional, ENTER para omitir]: "
echo.

if "%TS_KEY%"=="" (
    if "%TS_NAME%"=="" (
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\taller-setup.ps1"
    ) else (
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\taller-setup.ps1" -TailscaleName "%TS_NAME%"
    )
) else (
    if "%TS_NAME%"=="" (
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\taller-setup.ps1" -TailscaleKey "%TS_KEY%"
    ) else (
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\taller-setup.ps1" -TailscaleKey "%TS_KEY%" -TailscaleName "%TS_NAME%"
    )
)
endlocal
