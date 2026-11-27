param(
    [string]$SelfName = "",
    [string]$RepoDir = "",
    [string]$IdentityFile = ""
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ParentDir = Split-Path -Parent $ScriptDir
if (-not $RepoDir) {
    if ((Test-Path (Join-Path $ParentDir "keys\controllers.pub")) -and (Test-Path (Join-Path $ParentDir "web\conectar.ps1"))) {
        $RepoDir = $ParentDir
    }
}

$TargetDir = Join-Path $env:USERPROFILE ".taller"
New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# 1. Copiar archivos del controlador a ~/.taller
$filesToCopy = @("taller.ps1", "taller.cmd", "taller_gui.py", "lan_server.py", "sync-keys.ps1")
foreach ($f in $filesToCopy) {
    $src = Join-Path $ScriptDir $f
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination (Join-Path $TargetDir $f) -Force
    }
}

$tvnSrc = Join-Path $ScriptDir "tvnviewer"
if (Test-Path $tvnSrc) {
    $tvnDst = Join-Path $TargetDir "tvnviewer"
    New-Item -ItemType Directory -Force -Path $tvnDst | Out-Null
    Copy-Item -Path (Join-Path $tvnSrc "*") -Destination $tvnDst -Recurse -Force
}

$hostsSrc = Join-Path $ScriptDir "hosts.json"
$hostsDst = Join-Path $TargetDir "hosts.json"
if ((Test-Path $hostsSrc) -and -not (Test-Path $hostsDst)) {
    Copy-Item -Path $hostsSrc -Destination $hostsDst -Force
}

# 2. Detectar o generar clave SSH del controlador
$sshDir = Join-Path $env:USERPROFILE ".ssh"
New-Item -ItemType Directory -Force -Path $sshDir | Out-Null

if (-not $IdentityFile) {
    $cands = @(
        (Join-Path $sshDir "id_ed25519"),
        (Join-Path $sshDir "casa_b_to_a"),
        (Join-Path $sshDir "id_rsa")
    )
    foreach ($c in $cands) {
        if (Test-Path $c) { $IdentityFile = $c; break }
    }
    if (-not $IdentityFile) {
        $IdentityFile = Join-Path $sshDir "id_ed25519"
        $kg = Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue
        if (-not $kg) { throw "No se encontro ssh-keygen.exe" }
        Write-Host "[SSH] Generando nueva clave de controlador en $IdentityFile..." -ForegroundColor Cyan
        & cmd.exe /c "`"`"$($kg.Source)`" -t ed25519 -N `"`" -C `"$env:COMPUTERNAME`" -f `"$IdentityFile`" -q`""
    }
}

# 3. Detectar Python 3
$pyExe = "python"
foreach ($cand in @("python", "python3", "py")) {
    $cmd = Get-Command $cand -ErrorAction SilentlyContinue
    if ($cmd) {
        try {
            $verOut = & $cmd.Source --version 2>&1
            if ($verOut -match 'Python 3\.') {
                $pyExe = $cmd.Source
                break
            }
        } catch {}
    }
}

if (-not $SelfName) {
    if ($env:COMPUTERNAME -eq "DESKTOP-LSDMKT9") { $SelfName = "casa-a" }
    elseif ($env:COMPUTERNAME -eq "DESKTOP-SHO7RNL") { $SelfName = "lech" }
    else { $SelfName = $env:COMPUTERNAME.ToLower() }
}

# 4. Escribir ~/.taller/config.json
$effectiveHosts = if ($RepoDir -and (Test-Path (Join-Path $RepoDir "controller\hosts.json"))) {
    Join-Path $RepoDir "controller\hosts.json"
} else {
    $hostsDst
}

$cfgObj = [PSCustomObject]@{
    self_name     = $SelfName
    identity_file = $IdentityFile
    repo_dir      = $RepoDir
    hosts_file    = $effectiveHosts
    python_exe    = $pyExe
    gui_script    = (Join-Path $TargetDir "taller_gui.py")
    lan_server    = (Join-Path $TargetDir "lan_server.py")
    sync_script   = (Join-Path $TargetDir "sync-keys.ps1")
    viewer_exe    = (Join-Path $TargetDir "tvnviewer\tvnviewer.exe")
}
[IO.File]::WriteAllText((Join-Path $TargetDir "config.json"), ($cfgObj | ConvertTo-Json -Depth 4), $Utf8NoBom)

# 5. Agregar ~/.taller al PATH del usuario (idempotente)
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
$parts = if ($userPath) { $userPath.Split(';') | Where-Object { $_ } } else { @() }
if (-not ($parts -contains $TargetDir)) {
    $newPath = (($parts + $TargetDir) -join ';')
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    Write-Host "[OK] Agregado $TargetDir al PATH de usuario." -ForegroundColor Green
}
if (-not ($env:Path.Split(';') -contains $TargetDir)) {
    $env:Path = "$env:Path;$TargetDir"
}

# 6. Instalar Skill global para agentes IA (Antigravity + Codex si existe)
$skillSrc = $null
foreach ($sc in @(
    $(if ($RepoDir) { Join-Path $RepoDir "skill\taller-remote\SKILL.md" }),
    (Join-Path $ParentDir "skill\taller-remote\SKILL.md"),
    (Join-Path $ScriptDir "skill\taller-remote\SKILL.md")
)) {
    if ($sc -and (Test-Path $sc)) { $skillSrc = $sc; break }
}

if ($skillSrc) {
    $skillDests = @(
        (Join-Path $env:USERPROFILE ".gemini\config\skills\taller-remote\SKILL.md")
    )
    if (Test-Path (Join-Path $env:USERPROFILE ".codex")) {
        $skillDests += (Join-Path $env:USERPROFILE ".codex\skills\taller-remote\SKILL.md")
    }
    foreach ($sd in $skillDests) {
        $sdDir = Split-Path -Parent $sd
        New-Item -ItemType Directory -Force -Path $sdDir | Out-Null
        Copy-Item -Path $skillSrc -Destination $sd -Force
        Write-Host "[OK] Skill instalado en $sd" -ForegroundColor Green
    }
}

# 7. Verificar si la clave publica ya esta en controllers.pub
$pubPath = "$IdentityFile.pub"
if (Test-Path $pubPath) {
    $myPub = ([IO.File]::ReadAllText($pubPath)).Trim()
    $myKeyB64 = ($myPub -split '\s+')[1]
    $masterPub = ""
    foreach ($mc in @(
        $(if ($RepoDir) { Join-Path $RepoDir "keys\controllers.pub" }),
        (Join-Path $ParentDir "keys\controllers.pub")
    )) {
        if ($mc -and (Test-Path $mc)) { $masterPub = $mc; break }
    }
    $alreadyIn = $false
    if ($masterPub -and (Test-Path $masterPub)) {
        $masterText = [IO.File]::ReadAllText($masterPub)
        if ($masterText.Contains($myKeyB64)) { $alreadyIn = $true }
    }
    Write-Host ""
    Write-Host "[OK] Controlador '$SelfName' instalado en $TargetDir" -ForegroundColor Green
    Write-Host "     Clave SSH: $IdentityFile"
    if (-not $alreadyIn -and $masterPub) {
        Write-Host ""
        Write-Host "[IMPORTANTE] Esta clave aun no figura en keys\controllers.pub:" -ForegroundColor Yellow
        Write-Host "  $myPub" -ForegroundColor White
        Write-Host "  Agregala a keys\controllers.pub y ejecuta: taller sync-keys --push" -ForegroundColor Yellow
    }
}
