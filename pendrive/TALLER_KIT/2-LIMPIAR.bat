@echo off
setlocal
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Solicitando permisos de Administrador...
    set "__BAT=%~f0"
    powershell -NoProfile -Command "Start-Process -FilePath $env:__BAT -Verb RunAs"
    exit /b
)

echo ============================================================
echo   TALLER KIT - LIMPIAR PC PARA ENTREGAR / VENDER
echo ============================================================
echo.
echo   Esto desinstalara TallerSSH, TightVNC y Tailscale
echo   (si fueron instalados por el kit) y borrara C:\ProgramData\Taller.
echo.
echo   Presiona ENTER para limpiar ahora, o cierra esta ventana para cancelar.
pause >nul
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\taller-clean.ps1"
endlocal
