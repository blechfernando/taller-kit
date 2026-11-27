@echo off
setlocal
set "ARCH=%PROCESSOR_ARCHITECTURE%"
if defined PROCESSOR_ARCHITEW6432 set "ARCH=%PROCESSOR_ARCHITEW6432%"

ver | findstr /R /C:"\[.* 10\." /C:"\[.* 11\." >nul
if %errorlevel% equ 0 (
    if /I "%ARCH%"=="AMD64" (
        if exist "%~dp0bin\rustdesk-win10-x64.exe" (
            start "" "%~dp0bin\rustdesk-win10-x64.exe"
            exit /b 0
        )
    )
)

if exist "%~dp0bin\rustdesk-win7-x86.exe" (
    start "" "%~dp0bin\rustdesk-win7-x86.exe"
    exit /b 0
)

echo [ERROR] No se encontro binario portable de RustDesk en %~dp0bin\
pause
exit /b 1
