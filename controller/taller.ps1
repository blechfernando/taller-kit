$ErrorActionPreference = "Stop"

$RawArgs = @($args)
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$StateDir  = Join-Path $env:USERPROFILE ".taller"
$CfgPath   = Join-Path $StateDir "config.json"
$ScanCache = Join-Path $StateDir "last-scan.json"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# --- Cargar configuracion del controlador ---
$Config = [PSCustomObject]@{
    self_name     = $env:COMPUTERNAME.ToLower()
    identity_file = (Join-Path $env:USERPROFILE ".ssh\id_ed25519")
    repo_dir      = ""
    hosts_file    = (Join-Path $StateDir "hosts.json")
    python_exe    = "python"
    gui_script    = (Join-Path $ScriptDir "taller_gui.py")
    lan_server    = (Join-Path $ScriptDir "lan_server.py")
    sync_script   = (Join-Path $ScriptDir "sync-keys.ps1")
    viewer_exe    = (Join-Path $ScriptDir "tvnviewer\tvnviewer.exe")
}

if (Test-Path $CfgPath) {
    try {
        $loaded = Get-Content -Raw $CfgPath | ConvertFrom-Json
        foreach ($p in $loaded.PSObject.Properties) {
            if ($null -ne $p.Value -and [string]$p.Value -ne "") {
                $Config | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
            }
        }
    } catch {}
}

if (-not $Config.repo_dir) {
    $parentRepo = Split-Path -Parent $ScriptDir
    if (Test-Path (Join-Path $parentRepo "keys\controllers.pub")) {
        $Config.repo_dir = $parentRepo
    }
}
if (-not (Test-Path $Config.hosts_file)) {
    if ($Config.repo_dir -and (Test-Path (Join-Path $Config.repo_dir "controller\hosts.json"))) {
        $Config.hosts_file = Join-Path $Config.repo_dir "controller\hosts.json"
    }
}

function Show-Help {
    Write-Host ""
    Write-Host "TALLER KIT - Control remoto multi-PC desde consola o agentes IA" -ForegroundColor Cyan
    Write-Host "Uso: taller <comando> [argumentos]"
    Write-Host ""
    Write-Host "  DESCUBRIMIENTO Y LISTADO:" -ForegroundColor Yellow
    Write-Host "    taller scan [subred]                Escanea LAN (2222, 22) + Tailscale"
    Write-Host "    taller list                         Lista PCs fijas, Tailscale y ultimo scan"
    Write-Host ""
    Write-Host "  CONSOLA Y ARCHIVOS:" -ForegroundColor Yellow
    Write-Host "    taller ssh <destino> [comando...]   Abre SSH o ejecuta comando en destino"
    Write-Host "    taller scp <origen> <destino>       Copia archivos (ej: archivo.exe ultimo:C:\Temp\)"
    Write-Host ""
    Write-Host "  CONTROL GRAFICO (TUNEL SSH + VNC):" -ForegroundColor Yellow
    Write-Host "    taller screen <destino> [out.png]   Captura pantalla a PNG (para IA o revision)"
    Write-Host "    taller click <destino> <x> <y> [--right|--double]"
    Write-Host "    taller drag <destino> <x1> <y1> <x2> <y2>"
    Write-Host "    taller type <destino> `"<texto>`"     Escribe texto en la ventana activa"
    Write-Host "    taller key <destino> <tecla>        Tecla/atajo (Enter, Alt+F4, Ctrl+Shift+Esc)"
    Write-Host "    taller vnc <destino>                Abre ventana TightVNC interactiva"
    Write-Host ""
    Write-Host "  ADMINISTRACION Y RED:" -ForegroundColor Yellow
    Write-Host "    taller clean <destino>              Limpia acceso temporal de PC cliente"
    Write-Host "    taller add-host <alias> <ip> <user> [puerto] [notas]"
    Write-Host "    taller serve [puerto]               Sirve el kit web + binarios por LAN (def 8787)"
    Write-Host "    taller sync-keys [--push]           Sincroniza controllers.pub (y push por SSH)"
    Write-Host ""
    Write-Host "  <destino> acepta: alias (lech, restobar), 'ultimo' (ultimo cliente escaneado),"
    Write-Host "  hostname, nombre Tailscale, IP directa o usuario@ip."
    Write-Host ""
}

function Get-HostsInventory {
    if (-not (Test-Path $Config.hosts_file)) {
        return [PSCustomObject]@{ hosts = [PSCustomObject]@{} }
    }
    return (Get-Content -Raw $Config.hosts_file | ConvertFrom-Json)
}

function Test-TcpQuick {
    param([string]$Ip, [int]$Port, [int]$TimeoutMs = 450)
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $c.BeginConnect($Ip, $Port, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false) -and $c.Connected) {
            return $true
        }
        return $false
    } catch {
        return $false
    } finally {
        try { $c.Close() } catch {}
    }
}

function Read-TallerBanner {
    param([string]$Ip, [int]$Port, [int]$TimeoutMs = 500)
    $res = [PSCustomObject]@{
        open     = $false
        banner   = ""
        hostname = ""
        user     = ""
        os       = ""
        vnc      = $false
    }
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $c.BeginConnect($Ip, $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false) -or -not $c.Connected) {
            return $res
        }
        $res.open = $true
        $stream = $c.GetStream()
        $stream.ReadTimeout = $TimeoutMs
        $buf = New-Object byte[] 512
        $n = $stream.Read($buf, 0, $buf.Length)
        if ($n -gt 0) {
            $txt = [Text.Encoding]::ASCII.GetString($buf, 0, $n).Trim()
            $res.banner = $txt
            if ($txt -match 'TALLER:([A-Za-z0-9+/=]+)') {
                $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches[1]))
                $parts = $decoded.Split('|')
                if ($parts.Length -ge 1) { $res.hostname = $parts[0] }
                if ($parts.Length -ge 2) { $res.user     = $parts[1] }
                if ($parts.Length -ge 3) { $res.os       = $parts[2] }
                if ($parts.Length -ge 4) { $res.vnc      = ($parts[3] -eq "VNC=1") }
            }
        }
    } catch {}
    finally {
        try { $c.Close() } catch {}
    }
    return $res
}

function Get-PrimaryLanIp {
    try {
        $cfgs = Get-NetIPConfiguration -ErrorAction Stop | Where-Object { $_.IPv4DefaultGateway -ne $null -and $_.IPv4Address }
        $first = $cfgs | Select-Object -First 1
        if ($first) { return [string]($first.IPv4Address | Select-Object -First 1).IPAddress }
    } catch {}
    $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
        $_.IPAddress -notlike '127.*' -and
        $_.IPAddress -notlike '169.254.*' -and
        $_.IPAddress -notlike '100.*' -and
        $_.IPAddress -notlike '192.168.56.*' -and
        $_.IPAddress -notlike '172.*'
    } | Select-Object -First 1
    if ($ips) { return [string]$ips.IPAddress }
    return ""
}

function Get-TailscalePeers {
    $peers = @()
    $tsCmd = Get-Command tailscale -ErrorAction SilentlyContinue
    if (-not $tsCmd) { return $peers }
    try {
        $raw = & $tsCmd.Source status --json 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $raw) { return $peers }
        $st = $raw | ConvertFrom-Json
        if ($st.Peer) {
            foreach ($pProp in $st.Peer.PSObject.Properties) {
                $p = $pProp.Value
                $ip4 = ($p.TailscaleIPs | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1)
                if ($ip4) {
                    $dnsShort = ([string]$p.DNSName).Split('.')[0]
                    $peers += [PSCustomObject]@{
                        hostname = if ($dnsShort) { $dnsShort } else { [string]$p.HostName }
                        ip       = [string]$ip4
                        online   = [bool]$p.Online
                        os       = [string]$p.OS
                        tags     = if ($p.Tags) { ($p.Tags -join ",") } else { "" }
                    }
                }
            }
        }
    } catch {}
    return $peers
}

function Invoke-ScanBatch {
    param([string[]]$Ips, [int]$Port, [int]$TimeoutMs = 450)
    $jobs = New-Object System.Collections.Generic.List[object]
    foreach ($ip in $Ips) {
        $client = New-Object System.Net.Sockets.TcpClient
        $task = $client.ConnectAsync($ip, $Port)
        $jobs.Add([PSCustomObject]@{ Ip = $ip; Port = $Port; Client = $client; Task = $task })
    }
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        $pending = $false
        foreach ($j in $jobs) {
            if (-not $j.Task.IsCompleted) { $pending = $true; break }
        }
        if (-not $pending) { break }
        Start-Sleep -Milliseconds 25
    }
    $openHosts = @()
    foreach ($j in $jobs) {
        if ($j.Task.IsCompleted -and -not $j.Task.IsFaulted -and $j.Client.Connected) {
            $hostname = ""
            $user     = ""
            $os       = ""
            $vnc      = $false
            $banner   = ""
            try {
                $stream = $j.Client.GetStream()
                $stream.ReadTimeout = 350
                $buf = New-Object byte[] 512
                $n = $stream.Read($buf, 0, $buf.Length)
                if ($n -gt 0) {
                    $banner = [Text.Encoding]::ASCII.GetString($buf, 0, $n).Trim()
                    if ($banner -match 'TALLER:([A-Za-z0-9+/=]+)') {
                        $dec = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches[1]))
                        $parts = $dec.Split('|')
                        if ($parts.Length -ge 1) { $hostname = $parts[0] }
                        if ($parts.Length -ge 2) { $user     = $parts[1] }
                        if ($parts.Length -ge 3) { $os       = $parts[2] }
                        if ($parts.Length -ge 4) { $vnc      = ($parts[3] -eq "VNC=1") }
                    }
                }
            } catch {}
            $openHosts += [PSCustomObject]@{
                ip       = $j.Ip
                port     = $j.Port
                hostname = $hostname
                user     = $user
                os       = $os
                vnc      = $vnc
                banner   = $banner
                source   = if ($j.Port -eq 2222) { "cliente" } else { "lan" }
            }
        }
        try { $j.Client.Close() } catch {}
    }
    return $openHosts
}

function Invoke-Scan {
    param([string]$SubnetArg = "")
    $prefix = ""
    if ($SubnetArg) {
        if ($SubnetArg -match '^(\d+\.\d+\.\d+)') { $prefix = $Matches[1] }
        else { throw "Subred invalida: $SubnetArg (usa ej: 192.168.3.0/24)" }
    } else {
        $lanIp = Get-PrimaryLanIp
        if (-not $lanIp) { throw "No se detecto IP LAN activa. Pasa la subred manual: taller scan 192.168.1.0/24" }
        if ($lanIp -match '^(\d+\.\d+\.\d+)\.\d+$') { $prefix = $Matches[1] }
    }

    Write-Host "[SCAN] Escaneando ${prefix}.1-254 (puertos 2222 y 22) + Tailscale..." -ForegroundColor Cyan
    $ips = 1..254 | ForEach-Object { "${prefix}.$_" }
    $found = @()
    $found += Invoke-ScanBatch -Ips $ips -Port 2222 -TimeoutMs 450
    $found += Invoke-ScanBatch -Ips $ips -Port 22   -TimeoutMs 450

    $inv = Get-HostsInventory
    foreach ($item in $found) {
        if (-not $item.hostname -or -not $item.user) {
            foreach ($p in $inv.hosts.PSObject.Properties) {
                if ($p.Value.host -eq $item.ip -or $p.Value.tailscale_ip -eq $item.ip) {
                    if (-not $item.hostname) { $item.hostname = $p.Name }
                    if (-not $item.user)     { $item.user     = [string]$p.Value.user }
                    if (-not $item.os)       { $item.os       = [string]$p.Value.os }
                    break
                }
            }
        }
    }

    $tsPeers = Get-TailscalePeers
    foreach ($tp in $tsPeers) {
        if ($tp.online) {
            $b = Read-TallerBanner -Ip $tp.ip -Port 22 -TimeoutMs 600
            if ($b.open) {
                $found += [PSCustomObject]@{
                    ip       = $tp.ip
                    port     = 22
                    hostname = if ($b.hostname) { $b.hostname } else { $tp.hostname }
                    user     = $b.user
                    os       = if ($b.os) { $b.os } else { $tp.os }
                    vnc      = $b.vnc
                    banner   = $b.banner
                    source   = "tailscale"
                }
            }
        }
    }

    if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }
    $payload = [PSCustomObject]@{
        scanned_at = (Get-Date).ToString("o")
        subnet     = "${prefix}.0/24"
        hosts      = $found
    }
    [IO.File]::WriteAllText($ScanCache, ($payload | ConvertTo-Json -Depth 5), $Utf8NoBom)

    if ($found.Count -eq 0) {
        Write-Host "[AVISO] No se encontraron PCs con SSH abierto en ${prefix}.0/24." -ForegroundColor Yellow
        return
    }

    Write-Host ""
    $found | Select-Object @{N='TIPO';E={$_.source}}, @{N='NOMBRE';E={if($_.hostname){$_.hostname}else{"-"}}}, @{N='IP';E={$_.ip}}, @{N='PUERTO';E={$_.port}}, @{N='USUARIO';E={if($_.user){$_.user}else{"?"}}}, @{N='OS';E={if($_.os){$_.os}else{"?"}}}, @{N='VNC';E={if($_.vnc){"SI"}else{"-"}}} | Format-Table -AutoSize
}

function Invoke-List {
    $inv = Get-HostsInventory
    Write-Host "`n=== PCs FIJAS GUARDADAS ($($Config.hosts_file)) ===" -ForegroundColor Cyan
    $rows = @()
    foreach ($p in $inv.hosts.PSObject.Properties) {
        $v = $p.Value
        $rows += [PSCustomObject]@{
            ALIAS     = $p.Name
            IP_LAN    = $v.host
            TAILSCALE = if ($v.tailscale_ip) { $v.tailscale_ip } else { "-" }
            USUARIO   = $v.user
            PUERTO    = if ($v.port) { $v.port } else { 22 }
            NOTAS     = $v.notes
        }
    }
    if ($rows.Count -gt 0) { $rows | Format-Table -AutoSize } else { Write-Host "(vacio)" }

    $tsPeers = Get-TailscalePeers
    if ($tsPeers.Count -gt 0) {
        Write-Host "=== PEERS EN TAILSCALE ===" -ForegroundColor Cyan
        $tsPeers | Select-Object @{N='NOMBRE';E={$_.hostname}}, @{N='IP';E={$_.ip}}, @{N='ONLINE';E={$_.online}}, @{N='OS';E={$_.os}}, @{N='TAGS';E={$_.tags}} | Format-Table -AutoSize
    }

    if (Test-Path $ScanCache) {
        $sc = Get-Content -Raw $ScanCache | ConvertFrom-Json
        Write-Host "=== ULTIMO ESCANEO ($($sc.scanned_at)) ===" -ForegroundColor Cyan
        if ($sc.hosts -and $sc.hosts.Count -gt 0) {
            $sc.hosts | Select-Object @{N='TIPO';E={$_.source}}, @{N='NOMBRE';E={$_.hostname}}, @{N='IP';E={$_.ip}}, @{N='PUERTO';E={$_.port}}, @{N='USUARIO';E={$_.user}}, @{N='OS';E={$_.os}} | Format-Table -AutoSize
        } else {
            Write-Host "(sin resultados)"
        }
    }
}

function Resolve-TallerTarget {
    param([string]$Target)
    if (-not $Target) { throw "Debes indicar un destino (alias, 'ultimo', hostname o IP)." }
    $tLow = $Target.Trim().ToLower()
    $inv  = Get-HostsInventory
    $scanHosts = @()
    if (Test-Path $ScanCache) {
        try { $scanHosts = @((Get-Content -Raw $ScanCache | ConvertFrom-Json).hosts) } catch {}
    }

    # 1. 'ultimo' -> ultimo cliente en puerto 2222 (o ultimo host escaneado)
    if ($tLow -eq "ultimo" -or $tLow -eq "last") {
        $cand = $scanHosts | Where-Object { $_.port -eq 2222 } | Select-Object -First 1
        if (-not $cand) { $cand = $scanHosts | Select-Object -First 1 }
        if (-not $cand) { throw "No hay escaneo reciente. Ejecuta primero: taller scan" }
        return [PSCustomObject]@{
            alias = if ($cand.hostname) { $cand.hostname } else { $cand.ip }
            ip    = [string]$cand.ip
            port  = [int]$cand.port
            user  = if ($cand.user) { [string]$cand.user } else { $env:USERNAME }
            os    = if ($cand.os) { [string]$cand.os } else { "windows" }
        }
    }

    # 2. user@host[:port]
    if ($Target -match '^([^@]+)@([^:]+)(?::(\d+))?$') {
        $u = $Matches[1]; $h = $Matches[2]; $p = if ($Matches[3]) { [int]$Matches[3] } else { 0 }
        if ($p -eq 0) {
            if (Test-TcpQuick -Ip $h -Port 2222 -TimeoutMs 400) { $p = 2222 } else { $p = 22 }
        }
        return [PSCustomObject]@{ alias = $h; ip = $h; port = $p; user = $u; os = "windows" }
    }

    # 3. Alias en hosts.json
    foreach ($prop in $inv.hosts.PSObject.Properties) {
        if ($prop.Name.ToLower() -eq $tLow) {
            $v = $prop.Value
            $port = if ($v.port) { [int]$v.port } else { 22 }
            $ip   = [string]$v.host
            if ($v.tailscale_ip) {
                if (-not (Test-TcpQuick -Ip $ip -Port $port -TimeoutMs 350)) {
                    $ip = [string]$v.tailscale_ip
                }
            }
            return [PSCustomObject]@{
                alias = $prop.Name
                ip    = $ip
                port  = $port
                user  = [string]$v.user
                os    = if ($v.os) { ([string]$v.os).ToLower() } else { "windows" }
            }
        }
    }

    # 4. Coincidencia en last-scan.json por hostname o ip (prioriza puerto 2222)
    $matchScan = $scanHosts | Where-Object {
        ($_.hostname -and $_.hostname.ToLower() -eq $tLow) -or ($_.ip -eq $Target)
    } | Sort-Object @{Expression={if($_.port -eq 2222){0}else{1}}} | Select-Object -First 1
    if ($matchScan) {
        return [PSCustomObject]@{
            alias = if ($matchScan.hostname) { [string]$matchScan.hostname } else { [string]$matchScan.ip }
            ip    = [string]$matchScan.ip
            port  = [int]$matchScan.port
            user  = if ($matchScan.user) { [string]$matchScan.user } else { $env:USERNAME }
            os    = if ($matchScan.os) { ([string]$matchScan.os).ToLower() } else { "windows" }
        }
    }

    # 5. Peer en Tailscale
    $tsPeers = Get-TailscalePeers
    $tsMatch = $tsPeers | Where-Object { $_.hostname.ToLower() -eq $tLow -or $_.ip -eq $Target } | Select-Object -First 1
    if ($tsMatch) {
        $b = Read-TallerBanner -Ip $tsMatch.ip -Port 22 -TimeoutMs 700
        if (-not $b.open) { $b = Read-TallerBanner -Ip $tsMatch.ip -Port 2222 -TimeoutMs 700; $p = 2222 } else { $p = 22 }
        return [PSCustomObject]@{
            alias = $tsMatch.hostname
            ip    = $tsMatch.ip
            port  = $p
            user  = if ($b.user) { $b.user } else { $env:USERNAME }
            os    = if ($b.os) { $b.os.ToLower() } else { $tsMatch.os.ToLower() }
        }
    }

    # 6. IP directa
    if ($Target -match '^\d+\.\d+\.\d+\.\d+$') {
        $b = Read-TallerBanner -Ip $Target -Port 2222 -TimeoutMs 500
        $p = 2222
        if (-not $b.open) {
            $b = Read-TallerBanner -Ip $Target -Port 22 -TimeoutMs 500
            $p = 22
        }
        return [PSCustomObject]@{
            alias = if ($b.hostname) { $b.hostname } else { $Target }
            ip    = $Target
            port  = $p
            user  = if ($b.user) { $b.user } else { $env:USERNAME }
            os    = if ($b.os) { $b.os.ToLower() } else { "windows" }
        }
    }

    throw "No se encontro el destino '$Target'. Ejecuta 'taller scan' o 'taller list'."
}

function Invoke-RemoteEncodedPs {
    param($TargetObj, [string]$ScriptText)
    $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($ScriptText))
    & ssh.exe -i $Config.identity_file -p $TargetObj.port -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new "$($TargetObj.user)@$($TargetObj.ip)" "powershell -NoProfile -EncodedCommand $b64"
}

function Read-RemoteVncPassword {
    param($TargetObj)
    if ($TargetObj.os -like "*linux*") {
        $pw = & ssh.exe -i $Config.identity_file -p $TargetObj.port -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new "$($TargetObj.user)@$($TargetObj.ip)" "cat /opt/taller-tmp/vnc.pass 2>/dev/null || cat /etc/taller/vnc.pass 2>/dev/null" 2>$null
        return ([string]$pw).Trim()
    }
    $ps = "foreach(`$p in @('C:\TallerTmp\vnc.pass','C:\ProgramData\Taller\vnc.pass')){if(Test-Path `$p){[IO.File]::ReadAllText(`$p).Trim();break}}"
    $pw = Invoke-RemoteEncodedPs -TargetObj $TargetObj -ScriptText $ps
    return ([string]$pw).Trim()
}

function Get-FreeLocalPort {
    $l = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $l.Start()
    $p = ([Net.IPEndPoint]$l.LocalEndpoint).Port
    $l.Stop()
    return $p
}

function With-VncTunnel {
    param($TargetObj, [scriptblock]$Action)
    $vncPass = Read-RemoteVncPassword -TargetObj $TargetObj
    if (-not $vncPass) {
        throw "No se encontro vnc.pass en '$($TargetObj.alias)'. TightVNC esta activo en esa PC?"
    }
    $localPort = Get-FreeLocalPort
    $sshArgs = @(
        "-i", $Config.identity_file,
        "-p", "$($TargetObj.port)",
        "-o", "BatchMode=yes",
        "-o", "ExitOnForwardFailure=yes",
        "-o", "ConnectTimeout=6",
        "-o", "StrictHostKeyChecking=accept-new",
        "-N",
        "-L", "127.0.0.1:${localPort}:127.0.0.1:5900",
        "$($TargetObj.user)@$($TargetObj.ip)"
    )
    $tunnel = Start-Process -FilePath "ssh.exe" -ArgumentList $sshArgs -PassThru -WindowStyle Hidden
    $prevEnv = $env:TALLER_VNC_PASS
    try {
        $ready = $false
        for ($i = 0; $i -lt 30; $i++) {
            if ($tunnel.HasExited) {
                throw "El tunel SSH VNC se cerro (exit $($tunnel.ExitCode)). Verifica AllowTcpForwarding o puerto 5900 remoto."
            }
            if (Test-TcpQuick -Ip "127.0.0.1" -Port $localPort -TimeoutMs 150) {
                $ready = $true; break
            }
            Start-Sleep -Milliseconds 150
        }
        if (-not $ready) { throw "Tiempo agotado esperando tunel VNC local en puerto $localPort." }
        $env:TALLER_VNC_PASS = $vncPass
        & $Action $localPort $vncPass
    } finally {
        $env:TALLER_VNC_PASS = $prevEnv
        if ($tunnel -and -not $tunnel.HasExited) {
            Stop-Process -Id $tunnel.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- Despacho de comandos ---
if ($RawArgs.Count -eq 0) { Show-Help; exit 0 }
$cmd = $RawArgs[0].ToLower()
$rest = if ($RawArgs.Count -gt 1) { $RawArgs[1..($RawArgs.Count - 1)] } else { @() }

switch ($cmd) {
    "help" { Show-Help }
    "-h"   { Show-Help }
    "--help" { Show-Help }

    "scan" {
        $sub = if ($rest.Count -ge 1) { $rest[0] } else { "" }
        Invoke-Scan -SubnetArg $sub
    }

    "list" {
        Invoke-List
    }

    "ssh" {
        if ($rest.Count -lt 1) { throw "Uso: taller ssh <destino> [comando...]" }
        $t = Resolve-TallerTarget -Target $rest[0]
        $sshArgs = @("-i", $Config.identity_file, "-p", "$($t.port)", "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=6")
        if ($rest.Count -gt 1) {
            $sshArgs += @("-o", "BatchMode=yes", "$($t.user)@$($t.ip)")
            $sshArgs += $rest[1..($rest.Count - 1)]
        } else {
            $sshArgs += "$($t.user)@$($t.ip)"
        }
        & ssh.exe @sshArgs
        exit $LASTEXITCODE
    }

    "scp" {
        if ($rest.Count -lt 2) { throw "Uso: taller scp <origen> <destino>" }
        $scpPort = 22
        $resolved = @()
        foreach ($arg in $rest) {
            if ($arg -match '^([^:\\/]{2,}):(.+)$') {
                $t = Resolve-TallerTarget -Target $Matches[1]
                $scpPort = $t.port
                $resolved += "$($t.user)@$($t.ip):$($Matches[2])"
            } else {
                $resolved += $arg
            }
        }
        $scpArgs = @("-i", $Config.identity_file, "-P", "$scpPort", "-o", "StrictHostKeyChecking=accept-new") + $resolved
        & scp.exe @scpArgs
        exit $LASTEXITCODE
    }

    "screen" {
        if ($rest.Count -lt 1) { throw "Uso: taller screen <destino> [salida.png]" }
        $t = Resolve-TallerTarget -Target $rest[0]
        $outPng = if ($rest.Count -ge 2) { $rest[1] } else {
            $screensDir = Join-Path $StateDir "screens"
            if (-not (Test-Path $screensDir)) { New-Item -ItemType Directory -Force -Path $screensDir | Out-Null }
            $safe = ($t.alias -replace '[^A-Za-z0-9_.-]', '_')
            Join-Path $screensDir "${safe}_screen.png"
        }
        With-VncTunnel -TargetObj $t -Action {
            param($lp, $pw)
            & $Config.python_exe $Config.gui_script screen --port $lp --out $outPng
            if ($LASTEXITCODE -ne 0) { throw "taller_gui.py screen fallo (codigo $LASTEXITCODE)" }
        }
    }

    "click" {
        if ($rest.Count -lt 3) { throw "Uso: taller click <destino> <x> <y> [--right|--middle|--double]" }
        $t = Resolve-TallerTarget -Target $rest[0]
        $x = [int]$rest[1]; $y = [int]$rest[2]
        $btn = "left"; $dbl = $false
        foreach ($f in ($rest | Select-Object -Skip 3)) {
            if ($f -eq "--right")  { $btn = "right" }
            if ($f -eq "--middle") { $btn = "middle" }
            if ($f -eq "--double") { $dbl = $true }
        }
        With-VncTunnel -TargetObj $t -Action {
            param($lp, $pw)
            $pyArgs = @($Config.gui_script, "click", "--port", "$lp", "--x", "$x", "--y", "$y", "--button", $btn)
            if ($dbl) { $pyArgs += "--double" }
            & $Config.python_exe @pyArgs
            if ($LASTEXITCODE -ne 0) { throw "taller_gui.py click fallo (codigo $LASTEXITCODE)" }
        }
    }

    "drag" {
        if ($rest.Count -lt 5) { throw "Uso: taller drag <destino> <x1> <y1> <x2> <y2>" }
        $t = Resolve-TallerTarget -Target $rest[0]
        With-VncTunnel -TargetObj $t -Action {
            param($lp, $pw)
            & $Config.python_exe $Config.gui_script drag --port $lp --x1 $rest[1] --y1 $rest[2] --x2 $rest[3] --y2 $rest[4]
            if ($LASTEXITCODE -ne 0) { throw "taller_gui.py drag fallo (codigo $LASTEXITCODE)" }
        }
    }

    "type" {
        if ($rest.Count -lt 2) { throw "Uso: taller type <destino> `"<texto>`"" }
        $t = Resolve-TallerTarget -Target $rest[0]
        $txt = ($rest[1..($rest.Count - 1)]) -join " "
        With-VncTunnel -TargetObj $t -Action {
            param($lp, $pw)
            & $Config.python_exe $Config.gui_script type --port $lp --text $txt
            if ($LASTEXITCODE -ne 0) { throw "taller_gui.py type fallo (codigo $LASTEXITCODE)" }
        }
    }

    "key" {
        if ($rest.Count -lt 2) { throw "Uso: taller key <destino> <tecla_o_atajo>" }
        $t = Resolve-TallerTarget -Target $rest[0]
        With-VncTunnel -TargetObj $t -Action {
            param($lp, $pw)
            & $Config.python_exe $Config.gui_script key --port $lp --combo $rest[1]
            if ($LASTEXITCODE -ne 0) { throw "taller_gui.py key fallo (codigo $LASTEXITCODE)" }
        }
    }

    "vnc" {
        if ($rest.Count -lt 1) { throw "Uso: taller vnc <destino>" }
        if (-not (Test-Path $Config.viewer_exe)) {
            throw "No se encontro tvnviewer.exe en $($Config.viewer_exe)"
        }
        $t = Resolve-TallerTarget -Target $rest[0]
        With-VncTunnel -TargetObj $t -Action {
            param($lp, $pw)
            Write-Host "[VNC] Abriendo TightVNC Viewer hacia $($t.alias) (127.0.0.1:$lp). Cierra la ventana al terminar." -ForegroundColor Green
            $p = Start-Process -FilePath $Config.viewer_exe -ArgumentList "-host=127.0.0.1 -port=$lp -password=$pw" -PassThru -Wait
        }
    }

    "clean" {
        if ($rest.Count -lt 1) { throw "Uso: taller clean <destino>" }
        $t = Resolve-TallerTarget -Target $rest[0]
        Write-Host "[CLEAN] Limpiando acceso temporal en $($t.alias) ($($t.user)@$($t.ip):$($t.port))..." -ForegroundColor Cyan
        if ($t.os -like "*linux*") {
            & ssh.exe -i $Config.identity_file -p $t.port -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$($t.user)@$($t.ip)" "nohup sudo bash -c 'sleep 2; kill `$(cat /opt/taller-tmp/sshd.pid 2>/dev/null) 2>/dev/null || true; kill `$(cat /opt/taller-tmp/x11vnc.pid 2>/dev/null) 2>/dev/null || true; rm -rf /opt/taller-tmp' >/dev/null 2>&1 &"
        } else {
            $psClean = @"
if (Test-Path 'C:\TallerTmp\taller-clean.ps1') {
    & 'C:\TallerTmp\taller-clean.ps1' -Detached -Quiet
} else {
    `$c = 'ping 127.0.0.1 -n 4 >nul & sc stop TallerSSH >nul 2>&1 & ping 127.0.0.1 -n 2 >nul & sc delete TallerSSH >nul 2>&1 & netsh advfirewall firewall delete rule name=TallerSSH-Cliente >nul 2>&1 & rmdir /s /q C:\TallerTmp >nul 2>&1'
    Start-Process cmd.exe -ArgumentList "/c `$c" -WindowStyle Hidden
    Write-Output 'LIMPIEZA_INLINE_OK'
}
"@
            Invoke-RemoteEncodedPs -TargetObj $t -ScriptText $psClean
        }
        Write-Host "[OK] Limpieza disparada en $($t.alias)." -ForegroundColor Green
    }

    "add-host" {
        if ($rest.Count -lt 3) { throw "Uso: taller add-host <alias> <host_o_ip> <usuario> [puerto] [notas...]" }
        $alias = $rest[0].Trim()
        $hIp   = $rest[1].Trim()
        $hUser = $rest[2].Trim()
        $hPort = if ($rest.Count -ge 4 -and $rest[3] -match '^\d+$') { [int]$rest[3] } else { 22 }
        $notesIdx = if ($rest.Count -ge 4 -and $rest[3] -match '^\d+$') { 4 } else { 3 }
        $notes = if ($rest.Count -gt $notesIdx) { ($rest[$notesIdx..($rest.Count - 1)]) -join " " } else { "" }

        $inv = Get-HostsInventory
        $entry = [PSCustomObject]@{
            host  = $hIp
            user  = $hUser
            port  = $hPort
            os    = "windows"
            notes = $notes
        }
        if ($hIp -like "100.*") {
            $entry | Add-Member -NotePropertyName "tailscale_ip" -NotePropertyValue $hIp
        }
        $inv.hosts | Add-Member -NotePropertyName $alias -NotePropertyValue $entry -Force
        [IO.File]::WriteAllText($Config.hosts_file, ($inv | ConvertTo-Json -Depth 5), $Utf8NoBom)

        # Actualizar bloque gestionado en ~/.ssh/config sin tocar entradas previas del usuario
        $sshDir = Join-Path $env:USERPROFILE ".ssh"
        if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Force -Path $sshDir | Out-Null }
        $sshCfg = Join-Path $sshDir "config"
        $existingCfg = if (Test-Path $sshCfg) { [IO.File]::ReadAllText($sshCfg) } else { "" }
        $startM = "# >>> TALLER-KIT >>>"
        $endM   = "# <<< TALLER-KIT <<<"
        if ($existingCfg.Contains($startM) -and $existingCfg.Contains($endM)) {
            $existingCfg = [regex]::Replace($existingCfg, "(?s)\r?\n?" + [regex]::Escape($startM) + ".*?" + [regex]::Escape($endM) + "\r?\n?", "")
        }

        $idTilde = $Config.identity_file -replace [regex]::Escape($env:USERPROFILE), '~' -replace '\\', '/'
        $blocks = @($startM)
        foreach ($p in $inv.hosts.PSObject.Properties) {
            if ($p.Name.ToLower() -eq $Config.self_name.ToLower()) { continue }
            $v = $p.Value
            $ep = if ($v.port) { $v.port } else { 22 }
            $blocks += "Host taller-$($p.Name)"
            $blocks += "  HostName $($v.host)"
            $blocks += "  User $($v.user)"
            $blocks += "  Port $ep"
            $blocks += "  IdentityFile $idTilde"
            $blocks += "  IdentitiesOnly yes"
            $blocks += "  StrictHostKeyChecking accept-new"
            $blocks += ""
        }
        $blocks += $endM
        $newCfg = ($existingCfg.TrimEnd() + "`n`n" + ($blocks -join "`n") + "`n").TrimStart("`r", "`n")
        [IO.File]::WriteAllText($sshCfg, $newCfg, $Utf8NoBom)

        Write-Host "[OK] Host '$alias' guardado en $($Config.hosts_file) y ~/.ssh/config (alias taller-$alias)." -ForegroundColor Green
    }

    "serve" {
        $port = if ($rest.Count -ge 1) { [int]$rest[0] } else { 8787 }
        if (-not $Config.repo_dir) { throw "No se configuro repo_dir (necesita carpeta web/ y pendrive/TALLER_KIT/bin/)." }
        $lanIp = Get-PrimaryLanIp
        if (-not $lanIp) { $lanIp = "127.0.0.1" }
        Write-Host ""
        Write-Host "============================================================" -ForegroundColor Green
        Write-Host "  SERVIDOR LAN TALLER KIT ACTIVO" -ForegroundColor Green
        Write-Host "============================================================" -ForegroundColor Green
        Write-Host "  En cualquier PC Windows del taller (PowerShell):" -ForegroundColor Cyan
        Write-Host "    `$env:TALLER_BASE_URL='http://${lanIp}:${port}'; irm http://${lanIp}:${port}/conectar.ps1 | iex"
        Write-Host ""
        Write-Host "  En cualquier PC Linux del taller:" -ForegroundColor Cyan
        Write-Host "    curl -fsSL http://${lanIp}:${port}/linux.sh | sudo TALLER_BASE_URL='http://${lanIp}:${port}' bash"
        Write-Host "============================================================" -ForegroundColor Green
        Write-Host "  (Si otra PC no conecta, ejecuta como Admin: netsh advfirewall firewall add rule name=TallerServe dir=in action=allow protocol=TCP localport=$port profile=any)" -ForegroundColor DarkGray
        Write-Host ""
        & $Config.python_exe $Config.lan_server --port $port --repo $Config.repo_dir
    }

    "sync-keys" {
        $pushFlag = ($rest -contains "--push") -or ($rest -contains "-Push")
        $p = @{
            RepoDir      = $Config.repo_dir
            HostsFile    = $Config.hosts_file
            IdentityFile = $Config.identity_file
            SelfName     = $Config.self_name
        }
        if ($pushFlag) { $p["Push"] = $true }
        & $Config.sync_script @p
    }

    default {
        Write-Host "[ERROR] Comando desconocido: $cmd" -ForegroundColor Red
        Show-Help
        exit 1
    }
}
