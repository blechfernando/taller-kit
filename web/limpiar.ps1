param(
    [string]$BaseUrl = "",
    [switch]$Quiet
)

$ErrorActionPreference = "SilentlyContinue"
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

$DefaultBaseUrl = "https://raw.githubusercontent.com/blechfernando/taller-kit/main/web"
if (-not $BaseUrl) {
    $BaseUrl = if ($env:TALLER_BASE_URL) { $env:TALLER_BASE_URL.TrimEnd("/") } else { $DefaultBaseUrl }
} else {
    $BaseUrl = $BaseUrl.TrimEnd("/")
}

function Test-IsAdminClean {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdminClean)) {
    $tmp = Join-Path $env:TEMP "taller-web-limpiar.ps1"
    $uri = "$BaseUrl/limpiar.ps1"
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        & curl.exe -fSL --retry 2 -o $tmp $uri
    } else {
        Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $tmp
    }
    $extra = if ($Quiet) { " -Quiet" } else { "" }
    Write-Host "[TALLER] Solicitando permisos de Administrador..." -ForegroundColor Yellow
    Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$tmp`" -BaseUrl `"$BaseUrl`"$extra" -Verb RunAs
    exit 0
}

if (Test-Path "C:\ProgramData\Taller\taller-clean.ps1") {
    & "C:\ProgramData\Taller\taller-clean.ps1" -Quiet:$Quiet
    exit 0
}

if (Test-Path "C:\TallerTmp\taller-clean.ps1") {
    & "C:\TallerTmp\taller-clean.ps1" -Quiet:$Quiet
    exit 0
}

$repoRootBase = $BaseUrl -replace '/web$', ''
$tmpClean = Join-Path $env:TEMP "taller-clean-remote.ps1"
foreach ($u in @("$BaseUrl/scripts/taller-clean.ps1", "$repoRootBase/pendrive/TALLER_KIT/scripts/taller-clean.ps1")) {
    try {
        if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
            & curl.exe -fSL --retry 2 -o $tmpClean $u
        } else {
            Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile $tmpClean
        }
        if ((Test-Path $tmpClean) -and ((Get-Item $tmpClean).Length -gt 0)) { break }
    } catch {}
}

if (Test-Path $tmpClean) {
    & $tmpClean -Quiet:$Quiet
    Remove-Item -Force $tmpClean -ErrorAction SilentlyContinue
} else {
    Write-Host "[ERROR] No se pudo descargar taller-clean.ps1." -ForegroundColor Red
    if (-not $Quiet) { Read-Host "Presiona ENTER para salir" | Out-Null }
    exit 1
}
