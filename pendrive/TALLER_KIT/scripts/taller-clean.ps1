param(
    [switch]$Detached,
    [switch]$IncludePermanent,
    [switch]$Quiet
)

$ErrorActionPreference = "SilentlyContinue"
$ScriptPath = $MyInvocation.MyCommand.Path

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    Write-Host "[ERROR] Debe ejecutarse como Administrador." -ForegroundColor Red
    if (-not $Quiet) { Read-Host "Presiona ENTER para salir" | Out-Null }
    exit 1
}

if ($Detached) {
    $tmpCopy = Join-Path $env:TEMP "taller-clean-worker.ps1"
    Copy-Item -Path $ScriptPath -Destination $tmpCopy -Force
    $extra = if ($IncludePermanent) { " -IncludePermanent" } else { "" }
    $cmd = "ping 127.0.0.1 -n 4 >nul & powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$tmpCopy`"$extra -Quiet & del /f /q `"$tmpCopy`" >nul 2>&1"
    Start-Process -FilePath "cmd.exe" -ArgumentList "/c $cmd" -WindowStyle Hidden
    Write-Host "LIMPIEZA_PROGRAMADA_OK"
    exit 0
}

function Uninstall-TightVncIfFlagged {
    param([string]$DirPath)
    $flag = Join-Path $DirPath "installed_tightvnc.flag"
    if (-not (Test-Path $flag)) { return }
    Write-Host "[TALLER] Desinstalando TightVNC temporal..." -ForegroundColor Cyan
    Stop-Service -Name "tvnserver" -Force
    $regRoots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    $item = Get-ItemProperty $regRoots | Where-Object { $_.DisplayName -like "TightVNC*" } | Select-Object -First 1
    if ($item) {
        $guid = $item.PSChildName
        if ($guid -match '^\{[0-9A-Fa-f-]+\}$') {
            Start-Process -FilePath "msiexec.exe" -ArgumentList "/x $guid /qn /norestart" -Wait
        }
    }
}

# --- Limpiar modo Cliente (C:\TallerTmp) ---
Write-Host "[TALLER] Eliminando acceso temporal del taller..." -ForegroundColor Cyan

$svc = Get-Service -Name "TallerSSH"
if ($svc) {
    if ($svc.Status -eq "Running") {
        Stop-Service -Name "TallerSSH" -Force
        Start-Sleep -Milliseconds 500
    }
    & sc.exe delete "TallerSSH" | Out-Null
}

& netsh.exe advfirewall firewall delete rule name="TallerSSH-Cliente" | Out-Null

$tmpDir = "C:\TallerTmp"
if (Test-Path $tmpDir) {
    Uninstall-TightVncIfFlagged -DirPath $tmpDir
    Start-Sleep -Milliseconds 400
    Remove-Item -Recurse -Force $tmpDir
}

# --- Opcional: Limpiar instalacion Permanente de C:\ProgramData\Taller ---
if ($IncludePermanent) {
    $permDir = "C:\ProgramData\Taller"
    $wmiSvc = Get-WmiObject Win32_Service -Filter "Name='sshd'"
    if ($wmiSvc -and ([string]$wmiSvc.PathName -like "*\Taller\openssh\sshd.exe*")) {
        Stop-Service -Name "sshd" -Force
        Start-Sleep -Milliseconds 500
        & sc.exe delete "sshd" | Out-Null
    }
    & netsh.exe advfirewall firewall delete rule name="TallerSSH-Permanente" | Out-Null
    if (Test-Path $permDir) {
        Uninstall-TightVncIfFlagged -DirPath $permDir
        Remove-Item -Recurse -Force $permDir
    }
}

Write-Host "[OK] PC limpia. No quedaron servicios temporales ni archivos en C:\TallerTmp." -ForegroundColor Green
if (-not $Quiet) {
    Write-Host ""
    Read-Host "Presiona ENTER para cerrar" | Out-Null
}
