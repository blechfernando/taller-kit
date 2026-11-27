@echo off
setlocal
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Solicitando permisos de Administrador...
    set "__BAT=%~f0"
    powershell -NoProfile -Command "Start-Process -FilePath $env:__BAT -Verb RunAs"
    exit /b
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\taller-setup.ps1" -Mode Permanente
endlocal
