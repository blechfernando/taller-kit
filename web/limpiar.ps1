param(
    [switch]$IncludePermanent,
    [switch]$Quiet
)

$ErrorActionPreference = "SilentlyContinue"

function Test-IsAdminClean {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdminClean)) {
    Write-Host "[ERROR] Ejecuta PowerShell como Administrador para limpiar el equipo." -ForegroundColor Red
    if (-not $Quiet) { Read-Host "Presiona ENTER para salir" | Out-Null }
    exit 1
}

if (Test-Path "C:\TallerTmp\scripts\taller-clean.ps1") {
    & "C:\TallerTmp\scripts\taller-clean.ps1" -IncludePermanent:$IncludePermanent -Quiet:$Quiet
    exit 0
}

Write-Host "[TALLER] Eliminando acceso temporal del taller..." -ForegroundColor Cyan
$svc = Get-Service -Name "TallerSSH"
if ($svc) {
    Stop-Service -Name "TallerSSH" -Force
    Start-Sleep -Milliseconds 500
    & sc.exe delete "TallerSSH" | Out-Null
}
& netsh.exe advfirewall firewall delete rule name="TallerSSH-Cliente" | Out-Null

if (Test-Path "C:\TallerTmp\installed_tightvnc.flag") {
    Stop-Service -Name "tvnserver" -Force
    $regRoots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    $item = Get-ItemProperty $regRoots | Where-Object { $_.DisplayName -like "TightVNC*" } | Select-Object -First 1
    if ($item -and ($item.PSChildName -match '^\{[0-9A-Fa-f-]+\}$')) {
        Start-Process -FilePath "msiexec.exe" -ArgumentList "/x $($item.PSChildName) /qn /norestart" -Wait
    }
}

Remove-Item -Recurse -Force "C:\TallerTmp"
Remove-Item -Recurse -Force (Join-Path $env:TEMP "taller-web-cache")
Remove-Item -Force (Join-Path $env:TEMP "taller-web-bootstrap.ps1")

if ($IncludePermanent) {
    $wmiSvc = Get-WmiObject Win32_Service -Filter "Name='sshd'"
    if ($wmiSvc -and ([string]$wmiSvc.PathName -like "*\Taller\openssh\sshd.exe*")) {
        Stop-Service -Name "sshd" -Force
        Start-Sleep -Milliseconds 500
        & sc.exe delete "sshd" | Out-Null
    }
    & netsh.exe advfirewall firewall delete rule name="TallerSSH-Permanente" | Out-Null
    if (Test-Path "C:\ProgramData\Taller\installed_tightvnc.flag") {
        Stop-Service -Name "tvnserver" -Force
        $regRoots = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
        )
        $item = Get-ItemProperty $regRoots | Where-Object { $_.DisplayName -like "TightVNC*" } | Select-Object -First 1
        if ($item -and ($item.PSChildName -match '^\{[0-9A-Fa-f-]+\}$')) {
            Start-Process -FilePath "msiexec.exe" -ArgumentList "/x $($item.PSChildName) /qn /norestart" -Wait
        }
    }
    Remove-Item -Recurse -Force "C:\ProgramData\Taller"
}

Write-Host "[OK] PC limpia." -ForegroundColor Green
if (-not $Quiet) { Read-Host "Presiona ENTER para cerrar" | Out-Null }
