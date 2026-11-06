#Requires -Version 7.2
<#
.SYNOPSIS
    Điều khiển stack local của OL-Platform từ PowerShell trên Windows.
.DESCRIPTION
    Docker có thể là Docker Desktop (lệnh docker có trên Windows) hoặc Docker Engine trong WSL
    (chỉ có trong Ubuntu) — script tự nhận biết. Không cài Node/pnpm vào WSL.
.EXAMPLE
    ./ol.ps1 certs        # Tạo chứng chỉ HTTPS local bằng mkcert (một lần)
    ./ol.ps1 env          # Tạo .env với mật khẩu ngẫu nhiên (một lần)
    ./ol.ps1 hosts        # Thêm *.ol.test vào file hosts (cần quyền Administrator, một lần)
    ./ol.ps1 up           # Chạy toàn bộ stack bằng image giống production
    ./ol.ps1 up -Dev      # Chạy chế độ phát triển (hot reload)
    ./ol.ps1 seed         # Tạo dữ liệu demo
    ./ol.ps1 bootstrap-admin -Email platform@ol.test
    ./ol.ps1 logs bff     # Xem log một service
    ./ol.ps1 test ol-iam-service   # Chạy toàn bộ test (cả integration cần Docker) trong container
    ./ol.ps1 down         # Dừng (giữ dữ liệu)
    ./ol.ps1 reset        # Dừng và XÓA toàn bộ dữ liệu local
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory)]
    [ValidateSet('certs', 'env', 'hosts', 'up', 'down', 'reset', 'ps', 'logs', 'seed', 'bootstrap-admin', 'check', 'test')]
    [string]$Command,
    [Parameter(Position = 1)][string]$Service,
    [switch]$Dev,
    [string]$Email
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

# Danh sách file compose theo chế độ
function Get-ComposeFiles {
    $files = @('-f', 'compose.yaml', '-f', 'compose.apps.yaml')
    if ($Dev) { $files += @('-f', 'compose.dev.yaml') }
    return $files
}

# Chạy "docker compose ..." ở Windows (Docker Desktop) hoặc trong WSL (Docker Engine)
function Invoke-Compose([string[]]$ComposeArgs) {
    $all = @('compose') + (Get-ComposeFiles) + $ComposeArgs
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        Push-Location $here
        try { & docker @all } finally { Pop-Location }
    } else {
        # WSLENV: chuyển biến NODE_AUTH_TOKEN từ Windows vào WSL mà không ghi ra file
        $env:WSLENV = 'NODE_AUTH_TOKEN/u'
        & wsl --cd $here -e docker @all
    }
    if ($LASTEXITCODE -ne 0) { throw "docker compose thất bại (exit $LASTEXITCODE)" }
}

# Token đọc GitHub Packages (@ol-company/node-kit) — lấy từ phiên gh, chỉ nằm trong biến môi trường của tiến trình
function Set-NpmToken {
    if (-not $env:NODE_AUTH_TOKEN) {
        $token = (gh auth token 2>$null)
        if (-not $token) { throw 'Chưa đăng nhập gh hoặc thiếu scope read:packages (gh auth refresh -s read:packages)' }
        $env:NODE_AUTH_TOKEN = $token.Trim()
    }
}

function New-Secret([int]$Bytes = 24) {
    $b = [byte[]]::new($Bytes)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($b)
    # base64url: không có ký tự +/= gây rắc rối trong URL/shell
    return [Convert]::ToBase64String($b).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

switch ($Command) {
    'certs' {
        if (-not (Get-Command mkcert -ErrorAction SilentlyContinue)) { throw 'Chưa cài mkcert: winget install --id FiloSottile.mkcert -e' }
        mkcert -install                                         # Cài CA cục bộ vào kho tin cậy của Windows (một lần)
        $certs = Join-Path $here 'certs'
        New-Item -ItemType Directory -Force -Path $certs | Out-Null
        mkcert -cert-file (Join-Path $certs 'ol.test.pem') -key-file (Join-Path $certs 'ol.test-key.pem') '*.ol.test' 'ol.test'
        Copy-Item (Join-Path (mkcert -CAROOT) 'rootCA.pem') (Join-Path $certs 'rootCA.pem') -Force   # Để container Node tin chứng chỉ
        Write-Host 'Đã tạo chứng chỉ trong local/certs (đã nằm trong .gitignore qua *.pem)' -ForegroundColor Green
    }
    'env' {
        $target = Join-Path $here '.env'
        if (Test-Path $target) { Write-Host '.env đã tồn tại, giữ nguyên' -ForegroundColor Yellow; break }
        $keyBytes = [byte[]]::new(32); [System.Security.Cryptography.RandomNumberGenerator]::Fill($keyBytes)
        $lines = Get-Content (Join-Path $here '.env.example') | ForEach-Object {
            if ($_ -match '^([A-Z_]+)=$') {
                $name = $Matches[1]
                switch ($name) {
                    'BFF_SESSION_ENC_KEY' { "$name=$([Convert]::ToBase64String($keyBytes))" }   # Đúng 32 byte
                    default { "$name=$(New-Secret)" }
                }
            } else { $_ }
        }
        Set-Content -Path $target -Value $lines -Encoding utf8NoBOM
        Write-Host 'Đã tạo .env với giá trị ngẫu nhiên' -ForegroundColor Green
    }
    'hosts' {
        $hostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"
        $line = '127.0.0.1 app.ol.test id.ol.test mail.ol.test grafana.ol.test # ol-platform'
        if ((Get-Content $hostsFile) -contains $line) { Write-Host 'hosts đã có cấu hình'; break }
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isAdmin) { throw 'Cần chạy PowerShell bằng quyền Administrator cho lệnh này' }
        Add-Content -Path $hostsFile -Value $line
        Write-Host "Đã thêm: $line" -ForegroundColor Green
    }
    'up' {
        Set-NpmToken
        Invoke-Compose @('up', '-d', '--build', '--remove-orphans')
        Write-Host "`nỨng dụng: https://app.ol.test  |  Keycloak: https://id.ol.test  |  Email: https://mail.ol.test  |  Grafana: https://grafana.ol.test" -ForegroundColor Cyan
    }
    'down' { Invoke-Compose @('down') }
    'reset' {
        $answer = Read-Host 'XÓA toàn bộ dữ liệu local (DB, phiên, volume)? Gõ "yes" để xác nhận'
        if ($answer -eq 'yes') { Invoke-Compose @('down', '-v', '--remove-orphans') }
    }
    'ps' { Invoke-Compose @('ps') }
    'logs' { Invoke-Compose (@('logs', '-f', '--tail', '200') + @($Service | Where-Object { $_ })) }
    'seed' { Invoke-Compose @('exec', 'iam-service', 'node', 'dist/cli.js', 'seed-demo') }
    'bootstrap-admin' {
        if (-not $Email) { throw 'Cần -Email' }
        Invoke-Compose @('exec', 'iam-service', 'node', 'dist/cli.js', 'bootstrap-platform-admin', '--email', $Email)
    }
    'test' {
        # Test integration dùng Testcontainers cần nói chuyện với Docker. Khi Docker chỉ có trong WSL,
        # chạy test BÊN TRONG container dev, cấp socket Docker và cho Testcontainers biết địa chỉ máy chủ.
        if (-not $Service) { throw 'Cần tên repo, ví dụ: ./ol.ps1 test ol-iam-service' }
        Set-NpmToken
        $repo = (Resolve-Path (Join-Path $here "..\..\$Service")).Path
        $env:WSLENV = 'NODE_AUTH_TOKEN/u'
        $dockerArgs = @('run', '--rm', '-v', '/var/run/docker.sock:/var/run/docker.sock', '--add-host=host.docker.internal:host-gateway',
            '-e', 'TESTCONTAINERS_HOST_OVERRIDE=host.docker.internal', '-e', 'NODE_AUTH_TOKEN', '-v', "$($Service)_node_modules:/app/node_modules",
            '--user', 'root', '-w', '/app')
        if (Get-Command docker -ErrorAction SilentlyContinue) {
            & docker build -q -t ol-local/node-dev:dev (Join-Path $here '..\..\ol-build-tooling\dockerfiles\node-dev') | Out-Null
            & docker @dockerArgs -v "${repo}:/app" ol-local/node-dev:dev sh -c 'pnpm install --frozen-lockfile && pnpm test'
        } else {
            $linuxRepo = (& wsl wslpath -a $repo).Trim()
            & wsl --cd $here -e docker build -q -t ol-local/node-dev:dev ../../ol-build-tooling/dockerfiles/node-dev | Out-Null
            & wsl -e docker @dockerArgs -v "${linuxRepo}:/app" ol-local/node-dev:dev sh -c 'pnpm install --frozen-lockfile && pnpm test'
        }
        if ($LASTEXITCODE -ne 0) { throw "Test thất bại (exit $LASTEXITCODE)" }
    }
    'check' {
        # Kiểm tra nhanh từ Windows: HTTPS + định tuyến + health
        foreach ($u in 'https://app.ol.test/health/ready', 'https://app.ol.test/', 'https://id.ol.test/realms/ol/.well-known/openid-configuration') {
            try { $r = Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 10; Write-Host "[OK] $($r.StatusCode) $u" -ForegroundColor Green }
            catch { Write-Host "[!!] $u → $($_.Exception.Message)" -ForegroundColor Red }
        }
        try { Invoke-WebRequest -Uri 'https://app.ol.test/api/iam/v1/me' -UseBasicParsing -TimeoutSec 10 | Out-Null; Write-Host '[!!] /api không đăng nhập mà trả 2xx' -ForegroundColor Red }
        catch { Write-Host "[OK] /api chưa đăng nhập bị từ chối: $($_.Exception.Response.StatusCode.value__)" -ForegroundColor Green }
    }
}
