param(
    [string]$Mode = "Cliente",
    [int]$Port = 0,
    [switch]$NoVnc,
    [string]$TailscaleKey = "",
    [string]$TailscaleName = "",
    [string]$TailscaleTags = "tag:remoto",
    [string]$BinDir = "",
    [string]$ControllersPub = "",
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

# --- Compatibilidad PowerShell 2.0 (Windows 7 SP1+) ---
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$KitRoot   = Split-Path -Parent $ScriptDir
if (-not $BinDir)         { $BinDir = Join-Path $KitRoot "bin" }
if (-not $ControllersPub) { $ControllersPub = Join-Path $KitRoot "config\controllers.pub" }

function Write-Info { param([string]$Msg) Write-Host "[TALLER] $Msg" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host "[OK]     $Msg" -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host "[AVISO]  $Msg" -ForegroundColor Yellow }

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

function Set-StrictAdminAcl {
    param([string]$Path, [switch]$Container)
    if (-not (Test-Path $Path)) { return }
    if ($Container) {
        & icacls.exe $Path /inheritance:r /grant "*S-1-5-18:(OI)(CI)(F)" /grant "*S-1-5-32-544:(OI)(CI)(F)" | Out-Null
    } else {
        & icacls.exe $Path /inheritance:r /grant "*S-1-5-18:(F)" /grant "*S-1-5-32-544:(F)" | Out-Null
    }
}

function Expand-ZipCompat {
    param([string]$ZipPath, [string]$DestDir)
    if (-not (Test-Path $ZipPath)) { throw "Archivo no encontrado: $ZipPath" }
    if (Test-Path $DestDir) { Remove-Item -Recurse -Force $DestDir }
    New-Item -ItemType Directory -Force -Path $DestDir | Out-Null

    $expandCmd = Get-Command Expand-Archive -ErrorAction SilentlyContinue
    if ($expandCmd) {
        Expand-Archive -Path $ZipPath -DestinationPath $DestDir -Force
        return
    }

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $DestDir)
        return
    } catch {
        # Fallback COM Shell.Application para Windows 7 sin .NET 4.5
    }

    $shell = New-Object -ComObject Shell.Application
    $src   = $shell.NameSpace($ZipPath)
    $dst   = $shell.NameSpace($DestDir)
    if (-not $src -or -not $dst) { throw "No se pudo abrir el ZIP con Shell.Application: $ZipPath" }
    $expected = $src.Items().Count
    $dst.CopyHere($src.Items(), 0x14)
    $waited = 0
    while (($dst.Items().Count -lt $expected) -and ($waited -lt 600)) {
        Start-Sleep -Milliseconds 200
        $waited++
    }
    Start-Sleep -Milliseconds 500
}

function New-RandomPassword8 {
    $chars = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789".ToCharArray()
    $bytes = New-Object byte[] 8
    $rng   = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $rng.GetBytes($bytes)
    $out = ""
    foreach ($b in $bytes) {
        $out += $chars[$b % $chars.Length]
    }
    return $out
}

function Merge-AuthorizedKeys {
    param([string]$SourcePub, [string]$DestAuthKeys)
    $lines = @()
    if (Test-Path $DestAuthKeys) {
        $existing = [System.IO.File]::ReadAllText($DestAuthKeys)
        foreach ($l in ($existing -split "`r?`n")) {
            $t = $l.Trim()
            if ($t -and -not ($lines -contains $t)) { $lines += $t }
        }
    }
    $incoming = [System.IO.File]::ReadAllText($SourcePub)
    foreach ($l in ($incoming -split "`r?`n")) {
        $t = $l.Trim()
        if ($t -and -not $t.StartsWith("#") -and -not ($lines -contains $t)) {
            $lines += $t
        }
    }
    $joined = ($lines -join "`n") + "`n"
    Write-Utf8NoBom -Path $DestAuthKeys -Content $joined
}

function Set-FirewallRuleCompat {
    param([string]$RuleName, [int]$ListenPort)
    & netsh.exe advfirewall firewall delete rule name="$RuleName" | Out-Null
    & netsh.exe advfirewall firewall add rule name="$RuleName" dir=in action=allow protocol=TCP localport=$ListenPort profile=any remoteip="localsubnet,100.64.0.0/10" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        # Fallback por si remoteip multiple falla en algun Win7 antiguo
        & netsh.exe advfirewall firewall add rule name="$RuleName" dir=in action=allow protocol=TCP localport=$ListenPort profile=any | Out-Null
    }
}

function Get-LanIpv4List {
    $ips = @()
    try {
        $cfgs = Get-WmiObject Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" -ErrorAction SilentlyContinue
        foreach ($c in $cfgs) {
            if ($c.IPAddress) {
                foreach ($ip in $c.IPAddress) {
                    if ($ip -match '^\d+\.\d+\.\d+\.\d+$' -and $ip -notlike '127.*' -and $ip -notlike '169.254.*') {
                        $ips += $ip
                    }
                }
            }
        }
    } catch {}
    return $ips
}

# --- Validaciones iniciales ---
if (-not (Test-IsAdmin)) {
    Write-Host "[ERROR] Este script debe ejecutarse como Administrador." -ForegroundColor Red
    if (-not $Quiet) { Read-Host "Presiona ENTER para salir" | Out-Null }
    exit 1
}

$modeNorm = $Mode.Trim().ToLower()
if ($modeNorm -eq "cliente")         { $Mode = "Cliente" }
elseif ($modeNorm -eq "permanente") { $Mode = "Permanente" }
elseif ($modeNorm -eq "remoto")     { $Mode = "Remoto" }
else { throw "Modo invalido: '$Mode'. Usa Cliente, Permanente o Remoto." }

if ($Port -le 0) {
    if ($Mode -eq "Cliente") { $Port = 2222 } else { $Port = 22 }
}

if (-not (Test-Path $ControllersPub)) {
    throw "No se encontro el archivo de claves publicas: $ControllersPub"
}

# --- Detectar OS y arquitectura ---
$osVer     = [System.Environment]::OSVersion.Version
$osCaption = "Windows"
try {
    $wmiOs = Get-WmiObject Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($wmiOs) {
        $osVer     = [version]$wmiOs.Version
        $osCaption = [string]$wmiOs.Caption
    }
} catch {}

$archRaw = $env:PROCESSOR_ARCHITEW6432
if (-not $archRaw) { $archRaw = $env:PROCESSOR_ARCHITECTURE }
$is64 = ($archRaw -match '64')
$arch = if ($is64) { "x64" } else { "x86" }

$osShort = "Win10"
if ($osCaption -match 'Windows 11') { $osShort = "Win11" }
elseif ($osVer.Major -ge 10 -and $osVer.Build -ge 22000) { $osShort = "Win11" }
elseif ($osVer.Major -ge 10) { $osShort = "Win10" }
elseif ($osVer.Major -eq 6 -and $osVer.Minor -ge 2) { $osShort = "Win8" }
else { $osShort = "Win7" }

$isWin7Legacy = ($osVer.Major -lt 10)
$currentUser  = $env:USERNAME
if (-not $currentUser -or $currentUser -eq "$env:COMPUTERNAME`$") {
    try { $currentUser = (& whoami.exe).Split('\')[-1].Trim() } catch {}
}

Write-Info "Equipo: $env:COMPUTERNAME | Usuario: $currentUser | Sistema: $osShort ($arch) | Modo: $Mode (puerto $Port)"

# --- Rutas destino ---
if ($Mode -eq "Cliente") {
    $TargetDir   = "C:\TallerTmp"
    $ServiceName = "TallerSSH"
    $FwRuleName  = "TallerSSH-Cliente"
} else {
    $TargetDir   = "C:\ProgramData\Taller"
    $ServiceName = "sshd"
    $FwRuleName  = "TallerSSH-Permanente"
}

if (-not (Test-Path $TargetDir)) {
    New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
}
Set-StrictAdminAcl -Path $TargetDir -Container

# --- 1. TightVNC localhost-only (Session 0) ---
$vncStatus = "Deshabilitado"
$vncFlag   = "VNC=0"
if (-not $NoVnc) {
    $tvnSvc = Get-Service -Name "tvnserver" -ErrorAction SilentlyContinue
    $vncPassPath = Join-Path $TargetDir "vnc.pass"
    if ($tvnSvc) {
        if ($tvnSvc.Status -ne "Running") {
            Start-Service -Name "tvnserver" -ErrorAction SilentlyContinue
        }
        $vncStatus = "Ya instalado (servicio tvnserver)"
        if (Test-Path $vncPassPath) { $vncFlag = "VNC=1" }
    } else {
        $msiName = if ($is64) { "tightvnc-64bit.msi" } else { "tightvnc-32bit.msi" }
        $vncMsi  = Join-Path $BinDir $msiName
        if (Test-Path $vncMsi) {
            Write-Info "Instalando TightVNC Server solo en 127.0.0.1:5900 (sin abrir firewall)..."
            $vncPass = New-RandomPassword8
            Write-Utf8NoBom -Path $vncPassPath -Content $vncPass
            Set-StrictAdminAcl -Path $vncPassPath
            Write-Utf8NoBom -Path (Join-Path $TargetDir "installed_tightvnc.flag") -Content "1"

            $msiArgs = "/i `"$vncMsi`" /quiet /norestart ADDLOCAL=`"Server`" SERVER_REGISTER_AS_SERVICE=1 SERVER_ADD_FIREWALL_EXCEPTION=0 SET_LOOPBACKONLY=1 VALUE_OF_LOOPBACKONLY=1 SET_ALLOWLOOPBACK=1 VALUE_OF_ALLOWLOOPBACK=1 SET_USEVNCAUTHENTICATION=1 VALUE_OF_USEVNCAUTHENTICATION=1 SET_PASSWORD=1 VALUE_OF_PASSWORD=`"$vncPass`" SET_USECONTROLAUTHENTICATION=1 VALUE_OF_USECONTROLAUTHENTICATION=1 SET_CONTROLPASSWORD=1 VALUE_OF_CONTROLPASSWORD=`"$vncPass`""
            $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru
            if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
                $wait = 0
                while ($wait -lt 20) {
                    $s = Get-Service -Name "tvnserver" -ErrorAction SilentlyContinue
                    if ($s -and $s.Status -eq "Running") { break }
                    if ($s -and $s.Status -ne "Running") { Start-Service -Name "tvnserver" -ErrorAction SilentlyContinue }
                    Start-Sleep -Milliseconds 500
                    $wait++
                }
                $vncStatus = "Activo solo por tunel SSH (127.0.0.1:5900)"
                $vncFlag   = "VNC=1"
                Write-Ok "TightVNC instalado y asegurado solo en localhost."
            } else {
                Write-Warn "TightVNC devolvio codigo $($proc.ExitCode). SSH seguira funcionando normalmente."
                $vncStatus = "Error al instalar ($($proc.ExitCode))"
            }
        } else {
            Write-Warn "No se encontro $vncMsi; se omite VNC."
        }
    }
}

# --- 2. OpenSSH Server ---
$managedSshDir = Join-Path $TargetDir "openssh"
$managedExe    = Join-Path $managedSshDir "sshd.exe"
$existingSvc   = Get-WmiObject Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
$useBuiltinSshd = $false

if ($Mode -ne "Cliente" -and $existingSvc) {
    $svcPath = [string]$existingSvc.PathName
    if ($svcPath -notlike "*\Taller\openssh\sshd.exe*") {
        $useBuiltinSshd = $true
    }
}

if ($useBuiltinSshd) {
    Write-Info "Se detecto OpenSSH nativo de Windows en puerto 22. Autorizando claves del taller..."
    $userAuth = Join-Path $env:USERPROFILE ".ssh\authorized_keys"
    Merge-AuthorizedKeys -SourcePub $ControllersPub -DestAuthKeys $userAuth

    $progDataSsh = Join-Path $env:ProgramData "ssh"
    $adminAuth   = Join-Path $progDataSsh "administrators_authorized_keys"
    Merge-AuthorizedKeys -SourcePub $ControllersPub -DestAuthKeys $adminAuth
    Set-StrictAdminAcl -Path $adminAuth

    $nativeCfg = Join-Path $progDataSsh "sshd_config"
    $cfgChanged = $false
    if (Test-Path $nativeCfg) {
        $cfgText = [System.IO.File]::ReadAllText($nativeCfg)
        if ($cfgText -match '(?im)^\s*AllowTcpForwarding\s+no\b') {
            $cfgText = [regex]::Replace($cfgText, '(?im)^\s*AllowTcpForwarding\s+no\b', 'AllowTcpForwarding yes')
            Write-Utf8NoBom -Path $nativeCfg -Content $cfgText
            $cfgChanged = $true
        }
    }

    Set-FirewallRuleCompat -RuleName $FwRuleName -ListenPort $Port
    Set-Service -Name "sshd" -StartupType Automatic
    if ($cfgChanged) {
        Restart-Service -Name "sshd" -Force
    } else {
        $s = Get-Service -Name "sshd"
        if ($s.Status -ne "Running") { Start-Service -Name "sshd" }
    }
    Write-Ok "OpenSSH nativo actualizado con las claves del taller."
} else {
    $zipName = if ($isWin7Legacy) { "openssh-win7-$arch.zip" } else { "openssh-win10-$arch.zip" }
    $sshZip  = Join-Path $BinDir $zipName
    if (-not (Test-Path $sshZip)) {
        throw "No se encontro paquete OpenSSH: $sshZip"
    }

    $curSvc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($curSvc -and $curSvc.Status -eq "Running") {
        Write-Info "Deteniendo servicio previo $ServiceName..."
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 700
    }

    Write-Info "Extrayendo $zipName en $managedSshDir..."
    $tmpExtract = Join-Path $TargetDir "openssh_extract"
    Expand-ZipCompat -ZipPath $sshZip -DestDir $tmpExtract
    $foundSshd = Get-ChildItem -Path $tmpExtract -Recurse -Filter "sshd.exe" | Select-Object -First 1
    if (-not $foundSshd) { throw "No se encontro sshd.exe dentro de $zipName" }
    $srcSshDir = $foundSshd.Directory.FullName

    if (Test-Path $managedSshDir) { Remove-Item -Recurse -Force $managedSshDir }
    New-Item -ItemType Directory -Force -Path $managedSshDir | Out-Null
    Copy-Item -Path (Join-Path $srcSshDir "*") -Destination $managedSshDir -Recurse -Force
    Remove-Item -Recurse -Force $tmpExtract -ErrorAction SilentlyContinue

    $hostKeyPath = Join-Path $TargetDir "ssh_host_ed25519_key"
    $keygenExe   = Join-Path $managedSshDir "ssh-keygen.exe"
    if (-not (Test-Path $hostKeyPath)) {
        Write-Info "Generando clave host Ed25519..."
        $cmdLine = "`"`"$keygenExe`" -t ed25519 -N `"`" -f `"$hostKeyPath`" -q`""
        & cmd.exe /c $cmdLine
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $hostKeyPath)) {
            throw "Fallo la generacion de ssh_host_ed25519_key"
        }
    }
    Set-StrictAdminAcl -Path $hostKeyPath
    Set-StrictAdminAcl -Path ($hostKeyPath + ".pub")

    $authKeysPath = Join-Path $TargetDir "authorized_keys"
    Merge-AuthorizedKeys -SourcePub $ControllersPub -DestAuthKeys $authKeysPath
    Set-StrictAdminAcl -Path $authKeysPath

    $metaRaw = "$env:COMPUTERNAME|$currentUser|$osShort|$vncFlag"
    $metaB64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($metaRaw))

    $dirFwd     = $TargetDir.Replace("\", "/")
    $sftpFwd    = (Join-Path $managedSshDir "sftp-server.exe").Replace("\", "/")
    $sshdCfg    = Join-Path $TargetDir "sshd_config"
    $cfgLines = @(
        "Port $Port",
        "ListenAddress 0.0.0.0",
        "HostKey $dirFwd/ssh_host_ed25519_key",
        "PidFile $dirFwd/sshd.pid",
        "AuthorizedKeysFile $dirFwd/authorized_keys",
        "PubkeyAuthentication yes",
        "PasswordAuthentication no",
        "ChallengeResponseAuthentication no",
        "StrictModes no",
        "AllowTcpForwarding yes",
        "GatewayPorts no",
        "VersionAddendum TALLER:$metaB64",
        "Subsystem sftp $sftpFwd"
    )
    Write-Utf8NoBom -Path $sshdCfg -Content (($cfgLines -join "`n") + "`n")

    Write-Info "Verificando configuracion OpenSSH..."
    & $managedExe -t -f $sshdCfg
    if ($LASTEXITCODE -ne 0) {
        throw "sshd.exe -t rechazo la configuracion generada en $sshdCfg"
    }

    $binPathArg = "`"$managedExe`" -f `"$sshdCfg`""
    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
        & sc.exe config $ServiceName binPath= $binPathArg start= auto DisplayName= "Taller OpenSSH ($Mode)" | Out-Null
    } else {
        & sc.exe create $ServiceName binPath= $binPathArg start= auto DisplayName= "Taller OpenSSH ($Mode)" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "No se pudo crear el servicio $ServiceName" }
    }
    & sc.exe failure $ServiceName reset= 60 actions= restart/5000/restart/5000/restart/5000 | Out-Null

    Set-FirewallRuleCompat -RuleName $FwRuleName -ListenPort $Port

    Start-Service -Name $ServiceName
    Write-Ok "Servicio $ServiceName iniciado en puerto $Port."
}

$cleanSrc = Join-Path $ScriptDir "taller-clean.ps1"
if ((Test-Path $cleanSrc) -and ($Mode -eq "Cliente")) {
    Copy-Item -Path $cleanSrc -Destination (Join-Path $TargetDir "taller-clean.ps1") -Force -ErrorAction SilentlyContinue
}

# --- 3. Tailscale (solo Remoto o si se paso TailscaleKey) ---
$tailscaleIp = ""
if ($Mode -eq "Remoto" -or $TailscaleKey) {
    if ($isWin7Legacy -or -not $is64) {
        Write-Warn "Tailscale moderno requiere Windows 10/11 64-bit. En esta PC usa 5-PANTALLA-RAPIDA-RUSTDESK.bat."
    } else {
        $tsExe = Join-Path $env:ProgramFiles "Tailscale\tailscale.exe"
        if (-not (Test-Path $tsExe)) {
            $tsMsi = Join-Path $BinDir "tailscale-amd64.msi"
            if (-not (Test-Path $tsMsi)) {
                throw "No se encontro $tsMsi para modo Remoto."
            }
            Write-Info "Instalando Tailscale silenciosamente..."
            $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$tsMsi`" /qn /norestart" -Wait -PassThru
            if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
                throw "Fallo instalacion de Tailscale (codigo $($proc.ExitCode))."
            }
            $wait = 0
            while ($wait -lt 40) {
                $tsSvc = Get-Service -Name "Tailscale" -ErrorAction SilentlyContinue
                if ($tsSvc -and $tsSvc.Status -eq "Running" -and (Test-Path $tsExe)) { break }
                Start-Sleep -Milliseconds 500
                $wait++
            }
        }
        if ($TailscaleKey) {
            Write-Info "Conectando Tailscale en modo desatendido..."
            $tsArgs = @("up", "--authkey=$TailscaleKey", "--advertise-tags=$TailscaleTags", "--unattended")
            if ($TailscaleName) { $tsArgs += "--hostname=$TailscaleName" }
            & $tsExe @tsArgs
            if ($LASTEXITCODE -ne 0) {
                Write-Warn "tailscale up devolvio codigo $LASTEXITCODE. Revisa la Auth Key o permisos."
            } else {
                Start-Sleep -Seconds 2
                try { $tailscaleIp = (& $tsExe ip -4 2>$null | Select-Object -First 1).Trim() } catch {}
                if ($tailscaleIp) { Write-Ok "Tailscale conectado! IP Tailscale: $tailscaleIp" }
            }
        } else {
            Write-Warn "No se ingreso TailscaleKey; Tailscale instalado pero sin autenticar."
        }
    }
}

# --- 4. Resumen final ---
$lanIps = Get-LanIpv4List
$lanStr = if ($lanIps.Count -gt 0) { $lanIps -join ", " } else { "Sin IP LAN detectada" }

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  LISTO! PC PREPARADA PARA CONTROL REMOTO DEL TALLER" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  Equipo       : $env:COMPUTERNAME ($osShort $arch)"
Write-Host "  Usuario SSH  : $currentUser"
Write-Host "  IP(s) LAN    : $lanStr"
if ($tailscaleIp) {
Write-Host "  IP Tailscale : $tailscaleIp" -ForegroundColor Cyan
}
Write-Host "  Puerto SSH   : $Port  (Servicio: $ServiceName)"
Write-Host "  Pantalla VNC : $vncStatus"
Write-Host "------------------------------------------------------------"
if ($Mode -eq "Cliente") {
Write-Host "  Desde tu PC principal o Lech decile al agente:"
Write-Host "    'Ya conecte la PC nueva ($env:COMPUTERNAME), entrale'"
Write-Host "  O ejecuta:   taller scan   /   taller ssh $env:COMPUTERNAME"
} elseif ($tailscaleIp) {
Write-Host "  Desde tu PC principal ejecuta:"
Write-Host "    taller add-host $($TailscaleName.ToLower()) $tailscaleIp $currentUser $Port"
Write-Host "    taller ssh $tailscaleIp"
} else {
Write-Host "  Desde tu PC principal o Lech ejecuta:"
Write-Host "    taller scan   /   taller ssh $($lanIps | Select-Object -First 1)"
}
Write-Host "============================================================" -ForegroundColor Green

if (-not $Quiet) {
    Write-Host ""
    Read-Host "Presiona ENTER para cerrar esta ventana" | Out-Null
}
