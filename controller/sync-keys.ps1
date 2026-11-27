param(
    [string]$RepoDir = "",
    [string]$HostsFile = "",
    [string]$IdentityFile = "",
    [string]$SelfName = "",
    [switch]$Push
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $RepoDir) {
    $cand = Split-Path -Parent $ScriptDir
    if (Test-Path (Join-Path $cand "keys\controllers.pub")) { $RepoDir = $cand }
}
$cfgPath = Join-Path $env:USERPROFILE ".taller\config.json"
if (Test-Path $cfgPath) {
    try {
        $cfg = (Get-Content -Raw $cfgPath | ConvertFrom-Json)
        if (-not $RepoDir -and $cfg.repo_dir) { $RepoDir = $cfg.repo_dir }
        if (-not $HostsFile -and $cfg.hosts_file) { $HostsFile = $cfg.hosts_file }
        if (-not $IdentityFile -and $cfg.identity_file) { $IdentityFile = $cfg.identity_file }
        if (-not $SelfName -and $cfg.self_name) { $SelfName = $cfg.self_name }
    } catch {}
}

if (-not $RepoDir) { throw "No se encontro RepoDir con keys\controllers.pub." }
$masterPub = Join-Path $RepoDir "keys\controllers.pub"
if (-not (Test-Path $masterPub)) { throw "No existe $masterPub" }

$rawKeys = [System.IO.File]::ReadAllText($masterPub)
$keyLines = @()
foreach ($l in ($rawKeys -split "`r?`n")) {
    $t = $l.Trim()
    if ($t -and -not $t.StartsWith("#")) { $keyLines += $t }
}
if ($keyLines.Count -eq 0) { throw "keys\controllers.pub no tiene claves publicas." }

$lfContent = ($keyLines -join "`n") + "`n"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# 1. Sincronizar copias locales del repo
$targets = @(
    (Join-Path $RepoDir "pendrive\TALLER_KIT\config\controllers.pub"),
    (Join-Path $RepoDir "web\controllers.pub")
)
foreach ($t in $targets) {
    $p = Split-Path -Parent $t
    if (-not (Test-Path $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
    [System.IO.File]::WriteAllText($t, $lfContent, $utf8NoBom)
    Write-Host "[OK] Actualizado $t ($($keyLines.Count) claves)" -ForegroundColor Green
}

# 2. Actualizar authorized-keys en Ubuntu autoinstall user-data si existe
$userData = Join-Path $RepoDir "pendrive\ventoy\autounattend\ubuntu-autoinstall\user-data"
if (Test-Path $userData) {
    $udText = [System.IO.File]::ReadAllText($userData)
    $startMarker = "# >>> TALLER-KEYS >>>"
    $endMarker   = "# <<< TALLER-KEYS <<<"
    if ($udText.Contains($startMarker) -and $udText.Contains($endMarker)) {
        $yamlKeys = ($keyLines | ForEach-Object { "      - `"$_`"" }) -join "`n"
        $block = "$startMarker`n$yamlKeys`n      $endMarker"
        $pattern = "(?s)" + [regex]::Escape($startMarker) + ".*?" + [regex]::Escape($endMarker)
        $udNew = [regex]::Replace($udText, $pattern, $block)
        [System.IO.File]::WriteAllText($userData, $udNew.Replace("`r`n", "`n"), $utf8NoBom)
        Write-Host "[OK] Actualizado $userData" -ForegroundColor Green
    }
}

# 3. Push opcional hacia hosts permanentes en hosts.json
if ($Push) {
    if (-not $HostsFile) { $HostsFile = Join-Path $RepoDir "controller\hosts.json" }
    if (-not (Test-Path $HostsFile)) { throw "No se encontro $HostsFile" }
    if (-not $IdentityFile) { $IdentityFile = Join-Path $env:USERPROFILE ".ssh\id_ed25519" }

    $data = Get-Content -Raw $HostsFile | ConvertFrom-Json
    $keysB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($lfContent))

    foreach ($prop in $data.hosts.PSObject.Properties) {
        $alias = $prop.Name
        if ($SelfName -and ($alias.ToLower() -eq $SelfName.ToLower())) { continue }
        $h = $prop.Value
        $ip = [string]$h.host
        $port = if ($h.port) { [int]$h.port } else { 22 }
        $user = [string]$h.user
        $osType = if ($h.os) { ([string]$h.os).ToLower() } else { "windows" }

        # Chequear TCP rapido (600ms)
        $tcp = New-Object System.Net.Sockets.TcpClient
        $ar = $tcp.BeginConnect($ip, $port, $null, $null)
        $ok = $ar.AsyncWaitHandle.WaitOne(600, $false)
        if (-not $ok -or -not $tcp.Connected) {
            $tcp.Close()
            if ($h.tailscale_ip) {
                $ip = [string]$h.tailscale_ip
                $tcp2 = New-Object System.Net.Sockets.TcpClient
                $ar2 = $tcp2.BeginConnect($ip, $port, $null, $null)
                $ok2 = $ar2.AsyncWaitHandle.WaitOne(1200, $false)
                $tcp2.Close()
                if (-not $ok2) {
                    Write-Host "[SKIP] $alias no responde ($($h.host) / $($h.tailscale_ip))" -ForegroundColor Yellow
                    continue
                }
            } else {
                Write-Host "[SKIP] $alias no responde ($ip`:$port)" -ForegroundColor Yellow
                continue
            }
        } else {
            $tcp.Close()
        }

        Write-Host "[PUSH] Sincronizando claves en $alias ($user@$ip`:$port)..." -ForegroundColor Cyan
        if ($osType -eq "linux") {
            $shCmd = "python3 -c `"import base64,os; k=base64.b64decode('$keysB64').decode().splitlines(); p=os.path.expanduser('~/.ssh/authorized_keys'); os.makedirs(os.path.dirname(p),exist_ok=True); ex=set(open(p).read().splitlines()) if os.path.exists(p) else set(); [ex.add(x) for x in k if x.strip()]; open(p,'w').write('\n'.join(sorted(ex))+'\n'); os.chmod(p,0o600); print('KEYS_OK')`""
            & ssh.exe -i $IdentityFile -p $port -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$user@$ip" $shCmd
        } else {
            $psScript = @"
`$ErrorActionPreference = 'SilentlyContinue'
`$enc = New-Object System.Text.UTF8Encoding(`$false)
`$incoming = ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$keysB64'))) -split "`r?`n" | Where-Object { `$_.Trim() }
function Merge-Auth([string]`$dest) {
    `$dir = Split-Path -Parent `$dest
    if (-not (Test-Path `$dir)) { New-Item -ItemType Directory -Force -Path `$dir | Out-Null }
    `$list = @()
    if (Test-Path `$dest) {
        foreach (`$l in ([IO.File]::ReadAllText(`$dest) -split "`r?`n")) {
            `$t = `$l.Trim(); if (`$t -and -not (`$list -contains `$t)) { `$list += `$t }
        }
    }
    foreach (`$l in `$incoming) {
        `$t = `$l.Trim(); if (`$t -and -not (`$list -contains `$t)) { `$list += `$t }
    }
    [IO.File]::WriteAllText(`$dest, (`$list -join "`n") + "`n", `$enc)
}
Merge-Auth (Join-Path `$env:USERPROFILE '.ssh\authorized_keys')
if (Test-Path 'C:\ProgramData\ssh') {
    Merge-Auth 'C:\ProgramData\ssh\administrators_authorized_keys'
    & icacls.exe 'C:\ProgramData\ssh\administrators_authorized_keys' /inheritance:r /grant '*S-1-5-18:(F)' /grant '*S-1-5-32-544:(F)' | Out-Null
}
if (Test-Path 'C:\ProgramData\Taller\authorized_keys') {
    Merge-Auth 'C:\ProgramData\Taller\authorized_keys'
}
Write-Output 'KEYS_OK'
"@
            $psB64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($psScript))
            & ssh.exe -i $IdentityFile -p $port -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$user@$ip" "powershell -NoProfile -EncodedCommand $psB64"
        }
    }
}
