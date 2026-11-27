param(
    [switch]$Detached,
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
    $cmd = "ping 127.0.0.1 -n 4 >nul & powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$tmpCopy`" -Quiet & del /f /q `"$tmpCopy`" >nul 2>&1"
    Start-Process -FilePath "cmd.exe" -ArgumentList "/c $cmd" -WindowStyle Hidden
    Write-Host "LIMPIEZA_PROGRAMADA_OK"
    exit 0
}

function Uninstall-MsiByDisplayName {
    param([string]$DisplayNamePattern)
    $regRoots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    $items = Get-ItemProperty $regRoots | Where-Object { $_.DisplayName -like $DisplayNamePattern }
    foreach ($item in $items) {
        $guid = $item.PSChildName
        if ($guid -match '^\{[0-9A-Fa-f-]+\}$') {
            Start-Process -FilePath "msiexec.exe" -ArgumentList "/x $guid /qn /norestart" -Wait
        }
    }
}

function Remove-KeysFromFile {
    param([string]$FilePath, [string[]]$KeysToRemove)
    if (-not (Test-Path $FilePath) -or -not $KeysToRemove -or $KeysToRemove.Count -eq 0) { return }
    $lines = [System.IO.File]::ReadAllText($FilePath) -split "`r?`n"
    $kept = @()
    foreach ($l in $lines) {
        $t = $l.Trim()
        if ($t -and -not ($KeysToRemove -contains $t)) {
            $kept += $t
        }
    }
    $enc = New-Object System.Text.UTF8Encoding($false)
    if ($kept.Count -gt 0) {
        [System.IO.File]::WriteAllText($FilePath, (($kept -join "`n") + "`n"), $enc)
    } else {
        Remove-Item -Force $FilePath
    }
}

function Remove-TallerDir {
    param([string]$DirPath)
    if (-not (Test-Path $DirPath)) { return }

    # 1. Tailscale (si fue instalado por Taller Kit)
    if (Test-Path (Join-Path $DirPath "installed_tailscale.flag")) {
        Write-Host "[TALLER] Desconectando y desinstalando Tailscale..." -ForegroundColor Cyan
        $tsExe = Join-Path $env:ProgramFiles "Tailscale\tailscale.exe"
        if (Test-Path $tsExe) {
            & $tsExe logout | Out-Null
            Start-Sleep -Seconds 1
        }
        Stop-Service -Name "Tailscale" -Force
        Uninstall-MsiByDisplayName -DisplayNamePattern "Tailscale*"
    }

    # 2. TightVNC (si fue instalado por Taller Kit)
    if (Test-Path (Join-Path $DirPath "installed_tightvnc.flag")) {
        Write-Host "[TALLER] Desinstalando TightVNC..." -ForegroundColor Cyan
        Stop-Service -Name "tvnserver" -Force
        Uninstall-MsiByDisplayName -DisplayNamePattern "TightVNC*"
    }

    # 3. Claves agregadas a OpenSSH nativo (si correspondia)
    $nativeFlag = Join-Path $DirPath "added_native_keys.flag"
    if (Test-Path $nativeFlag) {
        $keysToRemove = @()
        foreach ($l in ([System.IO.File]::ReadAllText($nativeFlag) -split "`r?`n")) {
            $t = $l.Trim()
            if ($t) { $keysToRemove += $t }
        }
        Remove-KeysFromFile -FilePath "C:\ProgramData\ssh\administrators_authorized_keys" -KeysToRemove $keysToRemove
        Get-ChildItem "C:\Users" -Directory | ForEach-Object {
            Remove-KeysFromFile -FilePath (Join-Path $_.FullName ".ssh\authorized_keys") -KeysToRemove $keysToRemove
        }
    }

    # 4. Servicio SSH del Taller (o legacy sshd apuntando a Taller)
    foreach ($svcName in @("TallerSSH", "sshd")) {
        $wmiSvc = Get-WmiObject Win32_Service -Filter "Name='$svcName'"
        if ($wmiSvc) {
            $p = [string]$wmiSvc.PathName
            if (($svcName -eq "TallerSSH") -or ($p -like "*\Taller\openssh\sshd.exe*") -or ($p -like "*\TallerTmp\openssh\sshd.exe*")) {
                Stop-Service -Name $svcName -Force
                Start-Sleep -Milliseconds 500
                & sc.exe delete $svcName | Out-Null
            }
        }
    }

    Start-Sleep -Milliseconds 400
    Remove-Item -Recurse -Force $DirPath
}

Write-Host "[TALLER] Limpiando por completo el acceso remoto del taller..." -ForegroundColor Cyan

Remove-TallerDir -DirPath "C:\ProgramData\Taller"
Remove-TallerDir -DirPath "C:\TallerTmp"

foreach ($rule in @("TallerSSH", "TallerSSH-Cliente", "TallerSSH-Permanente")) {
    & netsh.exe advfirewall firewall delete rule name="$rule" | Out-Null
}

Write-Host "[OK] PC limpia. Se eliminaron TallerSSH, TightVNC, Tailscale (si los instalo el kit) y archivos." -ForegroundColor Green
if (-not $Quiet) {
    Write-Host ""
    Read-Host "Presiona ENTER para cerrar" | Out-Null
}
