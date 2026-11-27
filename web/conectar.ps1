param(
    [string]$Mode = "",
    [int]$Port = 0,
    [switch]$NoVnc,
    [string]$TailscaleKey = "",
    [string]$TailscaleName = "",
    [string]$TailscaleTags = "tag:remoto",
    [string]$BaseUrl = "",
    [switch]$NoMenu,
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

$DefaultBaseUrl = "https://raw.githubusercontent.com/blechfernando/taller-kit/main/web"
if (-not $BaseUrl) {
    $BaseUrl = if ($env:TALLER_BASE_URL) { $env:TALLER_BASE_URL.TrimEnd("/") } else { $DefaultBaseUrl }
} else {
    $BaseUrl = $BaseUrl.TrimEnd("/")
}

function Test-IsAdminWeb {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-FileWithFallback {
    param([string[]]$Urls, [string]$DestPath)
    $parent = Split-Path -Parent $DestPath
    if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    foreach ($u in $Urls) {
        if (-not $u) { continue }
        try {
            Write-Host "[DESCARGA] $u" -ForegroundColor DarkCyan
            if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
                & curl.exe -fSL --retry 2 --connect-timeout 10 -o $DestPath $u
                if ($LASTEXITCODE -eq 0 -and (Test-Path $DestPath) -and ((Get-Item $DestPath).Length -gt 0)) { return }
            } else {
                Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile $DestPath
                if ((Test-Path $DestPath) -and ((Get-Item $DestPath).Length -gt 0)) { return }
            }
        } catch {
            # Probar siguiente URL
        }
    }
    throw "No se pudo descargar $DestPath desde ninguna fuente."
}

function Start-ElevatedWebAction {
    param([string]$ActionMode, [string]$TsKey = "", [string]$TsName = "")
    $tmpScript = Join-Path $env:TEMP "taller-web-bootstrap.ps1"
    Get-FileWithFallback -Urls @("$BaseUrl/conectar.ps1") -DestPath $tmpScript
    $argParts = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$tmpScript`"", "-Mode", $ActionMode, "-BaseUrl", "`"$BaseUrl`"")
    if ($TsKey)  { $argParts += @("-TailscaleKey", "`"$TsKey`"") }
    if ($TsName) { $argParts += @("-TailscaleName", "`"$TsName`"") }
    if ($Quiet)  { $argParts += "-Quiet" }
    Write-Host "[TALLER] Solicitando permisos de Administrador..." -ForegroundColor Yellow
    Start-Process -FilePath "powershell.exe" -ArgumentList ($argParts -join " ") -Verb RunAs
}

function Invoke-TallerSetup {
    param(
        [string]$SetupMode = "Cliente",
        [int]$SetupPort = 0,
        [switch]$SkipVnc,
        [string]$TsKey = "",
        [string]$TsName = "",
        [string]$TsTags = "tag:remoto",
        [switch]$RunQuiet
    )

    if (-not (Test-IsAdminWeb)) {
        Start-ElevatedWebAction -ActionMode $SetupMode -TsKey $TsKey -TsName $TsName
        return
    }

    $workDir = Join-Path $env:TEMP "taller-web-cache"
    $binDir  = Join-Path $workDir "bin"
    $cfgDir  = Join-Path $workDir "config"
    $scrDir  = Join-Path $workDir "scripts"
    New-Item -ItemType Directory -Force -Path $binDir, $cfgDir, $scrDir | Out-Null

    $pubFile = Join-Path $cfgDir "controllers.pub"
    Get-FileWithFallback -Urls @("$BaseUrl/controllers.pub") -DestPath $pubFile

    # Si el servidor LAN ofrece /scripts/taller-setup.ps1 y /bin/, se reutiliza directo
    $osVer = [System.Environment]::OSVersion.Version
    try { $osVer = [version](Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Version } catch {}
    $archRaw = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    $is64    = ($archRaw -match '64')
    $arch    = if ($is64) { "x64" } else { "x86" }
    $isWin7  = ($osVer.Major -lt 10)

    $sshZipName = if ($isWin7) { "openssh-win7-$arch.zip" } else { "openssh-win10-$arch.zip" }
    $sshUrlUp   = if ($isWin7) {
        if ($is64) { "https://github.com/PowerShell/Win32-OpenSSH/releases/download/v8.1.0.0p1-Beta/OpenSSH-Win64.zip" }
        else       { "https://github.com/PowerShell/Win32-OpenSSH/releases/download/v8.1.0.0p1-Beta/OpenSSH-Win32.zip" }
    } else {
        if ($is64) { "https://github.com/PowerShell/Win32-OpenSSH/releases/download/v9.8.3.0p2-Preview/OpenSSH-Win64.zip" }
        else       { "https://github.com/PowerShell/Win32-OpenSSH/releases/download/v9.8.3.0p2-Preview/OpenSSH-Win32.zip" }
    }
    Get-FileWithFallback -Urls @("$BaseUrl/bin/$sshZipName", $sshUrlUp) -DestPath (Join-Path $binDir $sshZipName)

    if (-not $SkipVnc) {
        $vncArch    = if ($is64) { "64bit" } else { "32bit" }
        $vncMsiName = "tightvnc-$vncArch.msi"
        $vncUrlUp   = "https://www.tightvnc.com/download/2.8.90/tightvnc-2.8.90-gpl-setup-$vncArch.msi"
        Get-FileWithFallback -Urls @("$BaseUrl/bin/$vncMsiName", $vncUrlUp) -DestPath (Join-Path $binDir $vncMsiName)
    }

    if (($SetupMode -eq "Remoto" -or $TsKey) -and (-not $isWin7) -and $is64) {
        if (-not (Test-Path (Join-Path $env:ProgramFiles "Tailscale\tailscale.exe"))) {
            $tsNameFile = "tailscale-amd64.msi"
            $tsUrlUp    = "https://pkgs.tailscale.com/stable/tailscale-setup-1.104.7-amd64.msi"
            Get-FileWithFallback -Urls @("$BaseUrl/bin/$tsNameFile", $tsUrlUp) -DestPath (Join-Path $binDir $tsNameFile)
        }
    }

    # Descargar taller-setup.ps1 y taller-clean.ps1 desde servidor LAN o GitHub
    $repoRootBase = $BaseUrl -replace '/web$', ''
    $setupScript  = Join-Path $scrDir "taller-setup.ps1"
    $cleanScript  = Join-Path $scrDir "taller-clean.ps1"
    Get-FileWithFallback -Urls @(
        "$BaseUrl/scripts/taller-setup.ps1",
        "$repoRootBase/pendrive/TALLER_KIT/scripts/taller-setup.ps1"
    ) -DestPath $setupScript
    try {
        Get-FileWithFallback -Urls @(
            "$BaseUrl/scripts/taller-clean.ps1",
            "$repoRootBase/pendrive/TALLER_KIT/scripts/taller-clean.ps1"
        ) -DestPath $cleanScript
    } catch {}

    $params = @{
        Mode           = $SetupMode
        BinDir         = $binDir
        ControllersPub = $pubFile
    }
    if ($SetupPort -gt 0) { $params["Port"] = $SetupPort }
    if ($SkipVnc)         { $params["NoVnc"] = $true }
    if ($TsKey)           { $params["TailscaleKey"] = $TsKey }
    if ($TsName)          { $params["TailscaleName"] = $TsName }
    if ($TsTags)          { $params["TailscaleTags"] = $TsTags }
    if ($RunQuiet)        { $params["Quiet"] = $true }

    try {
        & $setupScript @params
    } finally {
        Remove-Item -Recurse -Force $workDir -ErrorAction SilentlyContinue
    }
}

function Start-RustDeskWeb {
    $osVer = [System.Environment]::OSVersion.Version
    try { $osVer = [version](Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Version } catch {}
    $archRaw = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    $is64    = ($archRaw -match '64')
    $isWin7  = ($osVer.Major -lt 10)

    $rdExeName = if ((-not $isWin7) -and $is64) { "rustdesk-win10-x64.exe" } else { "rustdesk-win7-x86.exe" }
    $rdUrlUp   = if ((-not $isWin7) -and $is64) {
        "https://github.com/rustdesk/rustdesk/releases/download/1.5.3/rustdesk-1.5.3-x86_64.exe"
    } else {
        "https://github.com/rustdesk/rustdesk/releases/download/1.2.3-1/rustdesk-1.2.3-1-x86-sciter.exe"
    }
    $dest = Join-Path $env:TEMP $rdExeName
    Get-FileWithFallback -Urls @("$BaseUrl/bin/$rdExeName", $rdUrlUp) -DestPath $dest
    Write-Host "[OK] Abriendo RustDesk portable ($dest)..." -ForegroundColor Green
    Start-Process -FilePath $dest
}

# --- Flujo principal ---
if ($Mode) {
    $mLow = $Mode.Trim().ToLower()
    if ($mLow -eq "rustdesk") {
        Start-RustDeskWeb
        exit 0
    }
    if ($mLow -eq "limpiar") {
        if (-not (Test-IsAdminWeb)) {
            Start-ElevatedWebAction -ActionMode "Limpiar"
            exit 0
        }
        $cleanUrl = "$BaseUrl/limpiar.ps1"
        $tmpClean = Join-Path $env:TEMP "taller-web-limpiar.ps1"
        Get-FileWithFallback -Urls @($cleanUrl) -DestPath $tmpClean
        & $tmpClean -Quiet:$Quiet
        Remove-Item -Force $tmpClean -ErrorAction SilentlyContinue
        exit 0
    }
    Invoke-TallerSetup -SetupMode $Mode -SetupPort $Port -SkipVnc:$NoVnc -TsKey $TailscaleKey -TsName $TailscaleName -TsTags $TailscaleTags -RunQuiet:$Quiet
    exit 0
}

if ($NoMenu) { return }

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "   TALLER KIT - CONEXION REMOTA RAPIDA (WEB / LAN)" -ForegroundColor Cyan
Write-Host "   Fuente: $BaseUrl" -ForegroundColor DarkGray
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  [1] Conectar temporal (PC cliente - puerto 2222 + VNC)"
Write-Host "  [2] Instalar permanente (PC propia - puerto 22 + VNC)"
Write-Host "  [3] Remoto por Internet (Resto bar / Familia - Tailscale)"
Write-Host "  [4] Solo pantalla rapida (RustDesk portable, sin instalar)"
Write-Host "  [5] Limpiar acceso temporal del taller"
Write-Host "  [0] Salir"
Write-Host "============================================================" -ForegroundColor Cyan
$choice = (Read-Host "Elige una opcion [1-5]").Trim()

switch ($choice) {
    "1" { Invoke-TallerSetup -SetupMode "Cliente" -RunQuiet:$Quiet }
    "2" { Invoke-TallerSetup -SetupMode "Permanente" -RunQuiet:$Quiet }
    "3" {
        $alias = (Read-Host "Nombre corto para esta PC (ej: restobar, mama)").Trim()
        $tkey  = (Read-Host "Pega tu Tailscale Auth Key (tskey-auth-...)").Trim()
        if (-not $tkey) { throw "No se ingreso Tailscale Auth Key." }
        Invoke-TallerSetup -SetupMode "Remoto" -TsKey $tkey -TsName $alias -RunQuiet:$Quiet
    }
    "4" { Start-RustDeskWeb }
    "5" {
        if (-not (Test-IsAdminWeb)) {
            Start-ElevatedWebAction -ActionMode "Limpiar"
        } else {
            $tmpClean = Join-Path $env:TEMP "taller-web-limpiar.ps1"
            Get-FileWithFallback -Urls @("$BaseUrl/limpiar.ps1") -DestPath $tmpClean
            & $tmpClean -Quiet:$Quiet
            Remove-Item -Force $tmpClean -ErrorAction SilentlyContinue
        }
    }
    default { Write-Host "Saliendo." }
}
