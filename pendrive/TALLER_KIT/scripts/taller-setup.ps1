param(
    [int]$Port = 22,
    [switch]$NoVnc,
    [switch]$NoTailscale,
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

$TargetDir = "C:\ProgramData\Taller"
$LogFile   = Join-Path $TargetDir "install.log"
$LogReady  = $false

function Write-Log {
    param([string]$Line)
    if (-not $LogReady) { return }
    try {
        $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::AppendAllText($LogFile, "[$ts] $Line`r`n", $enc)
    } catch {}
}

function Write-Info { param([string]$Msg) Write-Host "[TALLER] $Msg" -ForegroundColor Cyan; Write-Log "[TALLER] $Msg" }
function Write-Ok   { param([string]$Msg) Write-Host "[OK]     $Msg" -ForegroundColor Green; Write-Log "[OK] $Msg" }
function Write-Warn { param([string]$Msg) Write-Host "[AVISO]  $Msg" -ForegroundColor Yellow; Write-Log "[AVISO] $Msg" }

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
    $existingList = @()
    if (Test-Path $DestAuthKeys) {
        $existing = [System.IO.File]::ReadAllText($DestAuthKeys)
        foreach ($l in ($existing -split "`r?`n")) {
            $t = $l.Trim()
            if ($t -and -not ($existingList -contains $t)) { $existingList += $t }
        }
    }
    $addedKeys = @()
    $incoming = [System.IO.File]::ReadAllText($SourcePub)
    foreach ($l in ($incoming -split "`r?`n")) {
        $t = $l.Trim()
        if ($t -and -not $t.StartsWith("#") -and -not ($existingList -contains $t)) {
            $existingList += $t
            $addedKeys += $t
        }
    }
    $joined = ($existingList -join "`n") + "`n"
    Write-Utf8NoBom -Path $DestAuthKeys -Content $joined
    return $addedKeys
}

function Set-FirewallRuleCompat {
    param([string]$RuleName, [int]$ListenPort)
    & netsh.exe advfirewall firewall delete rule name="$RuleName" | Out-Null
    & netsh.exe advfirewall firewall add rule name="$RuleName" dir=in action=allow protocol=TCP localport=$ListenPort profile=any remoteip="localsubnet,100.64.0.0/10" | Out-Null
    if ($LASTEXITCODE -ne 0) {
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
                    if ($ip -match '^\d+\.\d+\.\d+\.\d+$' -and $ip -notlike '127.*' -and $ip -notlike '169.254.*' -and $ip -notlike '100.*') {
                        $ips += $ip
                    }
                }
            }
        }
    } catch {}
    return $ips
}

function Read-FirstNonCommentLine {
    param([string]$FilePath)
    if (-not (Test-Path $FilePath)) { return "" }
    $txt = [System.IO.File]::ReadAllText($FilePath)
    foreach ($l in ($txt -split "`r?`n")) {
        $t = $l.Trim()
        if ($t -and -not $t.StartsWith("#")) { return $t }
    }
    return ""
}

# --- Validaciones iniciales ---
if (-not (Test-IsAdmin)) {
    Write-Host "[ERROR] Este script debe ejecutarse como Administrador." -ForegroundColor Red
    if (-not $Quiet) { Read-Host "Presiona ENTER para salir" | Out-Null }
    exit 1
}

if (-not (Test-Path $ControllersPub)) {
    throw "No se encontro el archivo de claves publicas: $ControllersPub"
}

if (-not $TailscaleKey) {
    $c1 = Join-Path $KitRoot "config\tailscale-auth.txt"
    $c2 = Join-Path $KitRoot "tailscale-auth.txt"
    $TailscaleKey = Read-FirstNonCommentLine -FilePath $c1
    if (-not $TailscaleKey) { $TailscaleKey = Read-FirstNonCommentLine -FilePath $c2 }
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

$ServiceName = "TallerSSH"
$FwRuleName  = "TallerSSH"

if (-not (Test-Path $TargetDir)) {
    New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
}
Set-StrictAdminAcl -Path $TargetDir -Container
$LogReady = $true
Write-Utf8NoBom -Path $LogFile -Content ""
trap {
    if ($LogReady) { Write-Log ("[ERROR] " + $_.Exception.Message) }
    break
}

Write-Info "Equipo: $env:COMPUTERNAME | Usuario: $currentUser | Sistema: $osShort ($arch) | Instalacion fija completa"

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

# --- 2. OpenSSH Server fijo (puerto 22) ---
$managedSshDir = Join-Path $TargetDir "openssh"
$managedExe    = Join-Path $managedSshDir "sshd.exe"
$nativeSshSvc  = Get-WmiObject Win32_Service -Filter "Name='sshd'" -ErrorAction SilentlyContinue
$useNativeSshd = $false
$activeSshName = $ServiceName

if ($nativeSshSvc -and ($Port -eq 22)) {
    $svcPath = [string]$nativeSshSvc.PathName
    if ($svcPath -notlike "*\Taller\openssh\sshd.exe*") {
        $useNativeSshd = $true
        $activeSshName = "sshd"
    }
}

if ($useNativeSshd) {
    Write-Info "Se detecto OpenSSH nativo de Windows en puerto 22. Autorizando claves del taller..."
    $userAuth  = Join-Path $env:USERPROFILE ".ssh\authorized_keys"
    $addedUser = Merge-AuthorizedKeys -SourcePub $ControllersPub -DestAuthKeys $userAuth

    $progDataSsh = Join-Path $env:ProgramData "ssh"
    $adminAuth   = Join-Path $progDataSsh "administrators_authorized_keys"
    $addedAdmin  = Merge-AuthorizedKeys -SourcePub $ControllersPub -DestAuthKeys $adminAuth
    Set-StrictAdminAcl -Path $adminAuth

    $allAdded = @()
    foreach ($k in ($addedUser + $addedAdmin)) {
        if ($k -and -not ($allAdded -contains $k)) { $allAdded += $k }
    }
    if ($allAdded.Count -gt 0) {
        $flagPath = Join-Path $TargetDir "added_native_keys.flag"
        $prevAdded = @()
        if (Test-Path $flagPath) {
            foreach ($l in ([System.IO.File]::ReadAllText($flagPath) -split "`r?`n")) {
                $t = $l.Trim()
                if ($t -and -not ($prevAdded -contains $t)) { $prevAdded += $t }
            }
        }
        foreach ($k in $allAdded) {
            if (-not ($prevAdded -contains $k)) { $prevAdded += $k }
        }
        Write-Utf8NoBom -Path $flagPath -Content (($prevAdded -join "`n") + "`n")
    }

    $nativeCfg  = Join-Path $progDataSsh "sshd_config"
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
    [void](Merge-AuthorizedKeys -SourcePub $ControllersPub -DestAuthKeys $authKeysPath)
    Set-StrictAdminAcl -Path $authKeysPath

    $metaRaw = "$env:COMPUTERNAME|$currentUser|$osShort|$vncFlag"
    $metaB64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($metaRaw))

    $dirFwd  = $TargetDir.Replace("\", "/")
    $sftpFwd = (Join-Path $managedSshDir "sftp-server.exe").Replace("\", "/")
    $sshdCfg = Join-Path $TargetDir "sshd_config"
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
        & sc.exe config $ServiceName binPath= $binPathArg start= auto DisplayName= "Taller OpenSSH" | Out-Null
    } else {
        & sc.exe create $ServiceName binPath= $binPathArg start= auto DisplayName= "Taller OpenSSH" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "No se pudo crear el servicio $ServiceName" }
    }
    & sc.exe failure $ServiceName reset= 60 actions= restart/5000/restart/5000/restart/5000 | Out-Null
    Write-Utf8NoBom -Path (Join-Path $TargetDir "installed_ssh.flag") -Content "1"

    Set-FirewallRuleCompat -RuleName $FwRuleName -ListenPort $Port

    Start-Service -Name $ServiceName
    Write-Ok "Servicio $ServiceName iniciado en puerto $Port (arranque automatico)."
}

# Copiar taller-clean.ps1 para limpieza remota o manual
$cleanSrc = Join-Path $ScriptDir "taller-clean.ps1"
if (Test-Path $cleanSrc) {
    Copy-Item -Path $cleanSrc -Destination (Join-Path $TargetDir "taller-clean.ps1") -Force -ErrorAction SilentlyContinue
}

# --- 3. Tailscale (Internet fijo con tag:remoto) ---
$tailscaleIp     = ""
$tailscaleStatus = "No instalado"
if (-not $NoTailscale) {
    if ($isWin7Legacy -or -not $is64) {
        $tailscaleStatus = "No compatible con Win7/32-bit (solo LAN en esta PC)"
        Write-Warn "Tailscale moderno requiere Windows 10/11 64-bit. En Windows 7 queda listo SSH + VNC por LAN."
    } else {
        $tsExe = Join-Path $env:ProgramFiles "Tailscale\tailscale.exe"
        if (-not (Test-Path $tsExe)) {
            $tsMsi = Join-Path $BinDir "tailscale-amd64.msi"
            if (Test-Path $tsMsi) {
                Write-Info "Instalando Tailscale silenciosamente..."
                $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$tsMsi`" /qn /norestart" -Wait -PassThru
                if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
                    Write-Utf8NoBom -Path (Join-Path $TargetDir "installed_tailscale.flag") -Content "1"
                    $wait = 0
                    while ($wait -lt 40) {
                        $tsSvc = Get-Service -Name "Tailscale" -ErrorAction SilentlyContinue
                        if ($tsSvc -and $tsSvc.Status -eq "Running" -and (Test-Path $tsExe)) { break }
                        if ($tsSvc -and $tsSvc.Status -ne "Running") { Start-Service -Name "Tailscale" -ErrorAction SilentlyContinue }
                        Start-Sleep -Milliseconds 500
                        $wait++
                    }
                    $tailscaleStatus = "Instalado (listo para activar)"
                } else {
                    Write-Warn "Tailscale MSI devolvio codigo $($proc.ExitCode)."
                    $tailscaleStatus = "Error instalando ($($proc.ExitCode))"
                }
            } else {
                Write-Warn "No se encontro $tsMsi; se omite Tailscale."
            }
        } else {
            $tailscaleStatus = "Ya instalado"
        }

        if (Test-Path $tsExe) {
            try { $tailscaleIp = (& $tsExe ip -4 2>$null | Select-Object -First 1).Trim() } catch {}
            if ($tailscaleIp -match '^\d+\.\d+\.\d+\.\d+$') {
                $tailscaleStatus = "Conectado ($tailscaleIp)"
            } elseif ($TailscaleKey) {
                Write-Info "Conectando Tailscale a tu red en modo desatendido..."
                $tsArgs = @("up", "--authkey=$TailscaleKey", "--advertise-tags=$TailscaleTags", "--unattended")
                if ($TailscaleName) { $tsArgs += "--hostname=$TailscaleName" }
                & $tsExe @tsArgs
                if ($LASTEXITCODE -eq 0) {
                    Start-Sleep -Seconds 2
                    try { $tailscaleIp = (& $tsExe ip -4 2>$null | Select-Object -First 1).Trim() } catch {}
                    if ($tailscaleIp) {
                        $tailscaleStatus = "Conectado ($tailscaleIp)"
                        Write-Ok "Tailscale conectado! IP Tailscale: $tailscaleIp"
                    }
                } else {
                    Write-Warn "tailscale up devolvio codigo $LASTEXITCODE. Revisa la Auth Key."
                    $tailscaleStatus = "Error de Auth Key ($LASTEXITCODE)"
                }
            } else {
                $tailscaleStatus = "Instalado (pendiente de activar desde controlador con 'taller tailscale')"
                Write-Info "Tailscale quedo instalado. Podes activarlo remoto con: taller tailscale $env:COMPUTERNAME"
            }
        }
    }
}

# --- 4. Resumen final ---
$lanIps = Get-LanIpv4List
$lanStr = if ($lanIps.Count -gt 0) { $lanIps -join ", " } else { "Sin IP LAN detectada" }
$firstLan = if ($lanIps.Count -gt 0) { $lanIps[0] } else { $env:COMPUTERNAME }
$aliasHint = if ($TailscaleName) { $TailscaleName.ToLower() } else { $env:COMPUTERNAME.ToLower() }

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  LISTO! PC CONECTADA (FIJA PARA TALLER / LOCAL / INTERNET)" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  Equipo       : $env:COMPUTERNAME ($osShort $arch)"
Write-Host "  Usuario SSH  : $currentUser"
Write-Host "  IP(s) LAN    : $lanStr"
Write-Host "  Internet TS  : $tailscaleStatus"
Write-Host "  Puerto SSH   : $Port  (Servicio: $activeSshName)"
Write-Host "  Pantalla VNC : $vncStatus"
Write-Host "------------------------------------------------------------"
Write-Host "  Desde tu PC principal o Lech:"
Write-Host "    taller scan"
if ($tailscaleIp) {
Write-Host "    taller add-host $aliasHint $firstLan $currentUser $Port   (o IP $tailscaleIp)"
Write-Host "    taller ssh $tailscaleIp"
} else {
Write-Host "    taller ssh $env:COMPUTERNAME"
if ((-not $isWin7Legacy) -and $is64 -and (-not $NoTailscale)) {
Write-Host "    taller tailscale $env:COMPUTERNAME $aliasHint   (activa Internet remoto)"
}
}
Write-Host "  Al entregar al cliente o vender la PC, ejecuta 2-LIMPIAR.bat o 'taller clean'."
Write-Host "============================================================" -ForegroundColor Green

Write-Log "RESUMEN: Equipo=$env:COMPUTERNAME | Usuario=$currentUser | OS=$osShort ($arch) | LAN=$lanStr | TS=$tailscaleStatus | Puerto=$Port ($activeSshName) | VNC=$vncStatus"

if (-not $Quiet) {
    Write-Host ""
    Read-Host "Presiona ENTER para cerrar esta ventana" | Out-Null
}
