@echo off
setlocal EnableDelayedExpansion
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Solicitando permisos de Administrador...
    set "__BAT=%~f0"
    powershell -NoProfile -Command "Start-Process -FilePath $env:__BAT -Verb RunAs"
    exit /b
)

echo ============================================================
echo   CONFIGURAR PC REMOTA POR INTERNET (RESTO BAR / FAMILIA)
echo ============================================================
echo.

set "TS_KEY="
if exist "%~dp0config\tailscale-auth.txt" (
    for /f "usebackq tokens=* delims=" %%K in ("%~dp0config\tailscale-auth.txt") do (
        if not defined TS_KEY set "TS_KEY=%%K"
    )
)
if not defined TS_KEY if exist "%~dp0tailscale-auth.txt" (
    for /f "usebackq tokens=* delims=" %%K in ("%~dp0tailscale-auth.txt") do (
        if not defined TS_KEY set "TS_KEY=%%K"
    )
)

set /p "TS_NAME=Nombre corto para esta PC (ej: restobar, mama, negocio): "
if not defined TS_KEY (
    echo.
    set /p "TS_KEY=Pega tu Tailscale Auth Key (tskey-auth-...): "
) else (
    echo Usando Auth Key encontrada en tailscale-auth.txt.
)

if "%TS_KEY%"=="" (
    echo [ERROR] No se ingreso Tailscale Auth Key. Cancelado.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\taller-setup.ps1" -Mode Remoto -TailscaleKey "%TS_KEY%" -TailscaleName "%TS_NAME%"
endlocal
