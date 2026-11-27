param(
    [int]$Port = 22,
    [switch]$NoVnc,
    [switch]$NoTailscale,
    [string]$TailscaleKey = "",
    [string]$TailscaleName = "",
    [string]$TailscaleTags = "tag:remoto",
    [string]$BaseUrl = "",
    [switch]$NoPrompt,
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

function Invoke-TallerSetup {
    param(
        [int]$SetupPort = 22,
        [switch]$SkipVnc,
        [switch]$SkipTailscale,
        [string]$TsKey = "",
        [string]$TsName = "",
        [string]$TsTags = "tag:remoto",
        [switch]$RunQuiet
    )

    if (-not (Test-IsAdminWeb)) {
        $tmpScript = Join-Path $env:TEMP "taller-web-bootstrap.ps1"
        Get-FileWithFallback -Urls @("$BaseUrl/conectar.ps1") -DestPath $tmpScript
        $argParts = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$tmpScript`"", "-Port", "$SetupPort", "-BaseUrl", "`"$BaseUrl`"", "-NoPrompt")
        if ($SkipVnc)       { $argParts += "-NoVnc" }
        if ($SkipTailscale) { $argParts += "-NoTailscale" }
        if ($TsKey)         { $argParts += @("-TailscaleKey", "`"$TsKey`"") }
        if ($TsName)        { $argParts += @("-TailscaleName", "`"$TsName`"") }
        if ($TsTags)        { $argParts += @("-TailscaleTags", "`"$TsTags`"") }
        if ($RunQuiet)      { $argParts += "-Quiet" }
        Write-Host "[TALLER] Solicitando permisos de Administrador..." -ForegroundColor Yellow
        Start-Process -FilePath "powershell.exe" -ArgumentList ($argParts -join " ") -Verb RunAs
        return
    }

    $workDir = Join-Path $env:TEMP "taller-web-cache"
    $binDir  = Join-Path $workDir "bin"
    $cfgDir  = Join-Path $workDir "config"
    $scrDir  = Join-Path $workDir "scripts"
    New-Item -ItemType Directory -Force -Path $binDir, $cfgDir, $scrDir | Out-Null

    $pubFile = Join-Path $cfgDir "controllers.pub"
    Get-FileWithFallback -Urls @("$BaseUrl/controllers.pub") -DestPath $pubFile

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

    if (-not $SkipTailscale) {
        $hasTs = $false
        foreach ($r in @([Environment]::GetEnvironmentVariable("ProgramFiles"), [Environment]::GetEnvironmentVariable("ProgramFiles(x86)"))) {
            if ($r -and ((Test-Path (Join-Path $r "Tailscale\tailscale.exe")) -or (Test-Path (Join-Path $r "Tailscale IPN\tailscale.exe")))) {
                $hasTs = $true; break
            }
        }
        if (-not $hasTs) {
            if ($isWin7) {
                $tsNameFile = "tailscale-win7-$arch.msi"
                $tsUrlUp    = if ($is64) { "https://pkgs.tailscale.com/stable/tailscale-setup-1.44.3-amd64.msi" } else { "https://pkgs.tailscale.com/stable/tailscale-setup-1.44.3-x86.msi" }
            } else {
                $tsNameFile = if ($is64) { "tailscale-amd64.msi" } else { "tailscale-x86.msi" }
                $tsUrlUp    = if ($is64) { "https://pkgs.tailscale.com/stable/tailscale-setup-1.104.7-amd64.msi" } else { "https://pkgs.tailscale.com/stable/tailscale-setup-1.104.7-x86.msi" }
            }
            Get-FileWithFallback -Urls @("$BaseUrl/bin/$tsNameFile", $tsUrlUp) -DestPath (Join-Path $binDir $tsNameFile)
        }
    }

    $repoRootBase = $BaseUrl -replace '/web$', ''
    $setupScript  = Join-Path $scrDir "taller-setup.ps1"
    $cleanScript  = Join-Path $scrDir "taller-clean.ps1"
    Get-FileWithFallback -Urls @(
        "$BaseUrl/scripts/taller-setup.ps1",
        "$repoRootBase/pendrive/TALLER_KIT/scripts/taller-setup.ps1"
    ) -DestPath $setupScript
    Get-FileWithFallback -Urls @(
        "$BaseUrl/scripts/taller-clean.ps1",
        "$repoRootBase/pendrive/TALLER_KIT/scripts/taller-clean.ps1"
    ) -DestPath $cleanScript

    $params = @{
        Port           = $SetupPort
        BinDir         = $binDir
        ControllersPub = $pubFile
    }
    if ($SkipVnc)       { $params["NoVnc"] = $true }
    if ($SkipTailscale) { $params["NoTailscale"] = $true }
    if ($TsKey)         { $params["TailscaleKey"] = $TsKey }
    if ($TsName)        { $params["TailscaleName"] = $TsName }
    if ($TsTags)        { $params["TailscaleTags"] = $TsTags }
    if ($RunQuiet)      { $params["Quiet"] = $true }

    try {
        & $setupScript @params
    } finally {
        Remove-Item -Recurse -Force $workDir -ErrorAction SilentlyContinue
    }
}

# --- Flujo directo: 1 sola instalacion fija (LAN + Internet) ---
if (-not $NoPrompt -and -not $Quiet -and -not $TailscaleKey) {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  TALLER KIT - CONECTAR PC (FIJA LAN + INTERNET)" -ForegroundColor Cyan
    Write-Host "  Fuente: $BaseUrl" -ForegroundColor DarkGray
    Write-Host "============================================================" -ForegroundColor Cyan
    if (-not $TailscaleName) {
        $TailscaleName = (Read-Host "Nombre corto para esta PC [ENTER = $env:COMPUTERNAME]").Trim()
    }
    Write-Host "Si queres activar Internet ahora mismo, pega tu Tailscale Auth Key."
    Write-Host "Si apretas ENTER, igual instala SSH + VNC + Tailscale listo para activar remoto."
    $TailscaleKey = (Read-Host "Tailscale Auth Key [opcional, ENTER para omitir]").Trim()
}

Invoke-TallerSetup -SetupPort $Port -SkipVnc:$NoVnc -SkipTailscale:$NoTailscale -TsKey $TailscaleKey -TsName $TailscaleName -TsTags $TailscaleTags -RunQuiet:$Quiet
