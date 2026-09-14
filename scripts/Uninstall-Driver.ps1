<#
.SYNOPSIS
    가상 마우스 장치와 드라이버 패키지를 제거한다. (관리자 권한 필요)

.DESCRIPTION
    1) root\virtualmouse devnode 제거
    2) 드라이버 스토어에서 vmouse.inf 로 등록된 oemNN.inf 제거
    3) (옵션) 신뢰 저장소에 넣었던 테스트 인증서 제거

.EXAMPLE
    .\scripts\Uninstall-Driver.ps1
    .\scripts\Uninstall-Driver.ps1 -RemoveCertificate
#>
[CmdletBinding()]
param(
    [ValidateSet('x64', 'ARM64')]
    [string]$Platform = 'x64',

    [switch]$RemoveCertificate,

    [string]$CertSubject = 'CN=virtual-mouse test signing'
)

$ErrorActionPreference = 'Continue'

$repoRoot = Split-Path -Parent $PSScriptRoot
$ctl      = Join-Path $repoRoot "build\$Platform\Release\vmousectl.exe"

$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) { throw "관리자 권한 PowerShell 에서 실행해야 한다." }

# --- 1) devnode 제거 -----------------------------------------------------
Write-Host "`n[1/3] devnode 제거" -ForegroundColor Cyan
if (Test-Path $ctl) {
    & $ctl remove
} else {
    Write-Host "  vmousectl.exe 가 없다. devnode 제거를 건너뛴다." -ForegroundColor Yellow
    Write-Host "  장치 관리자에서 'Virtual HID Mouse' 를 수동으로 제거할 것." -ForegroundColor Yellow
}

# --- 2) 드라이버 패키지 제거 --------------------------------------------
Write-Host "`n[2/3] 드라이버 스토어에서 제거" -ForegroundColor Cyan

# pnputil /enum-drivers 출력은 로케일에 따라 레이블이 달라진다.
# 원본 이름(vmouse.inf)이 등장하는 블록에서 oemNN.inf 를 역으로 찾는다.
$lines = (& pnputil.exe /enum-drivers) -split "`r?`n"
$currentOem = $null
$targets = @()

foreach ($line in $lines) {
    if ($line -match '(oem\d+\.inf)') {
        $currentOem = $Matches[1]
    }
    if ($currentOem -and $line -match '(?i)\bvmouse\.inf\b') {
        $targets += $currentOem
        $currentOem = $null
    }
}
$targets = $targets | Select-Object -Unique

if ($targets.Count -eq 0) {
    Write-Host "  등록된 vmouse.inf 패키지가 없다." -ForegroundColor DarkGray
} else {
    foreach ($oem in $targets) {
        Write-Host "  pnputil /delete-driver $oem /uninstall /force" -ForegroundColor DarkGray
        & pnputil.exe /delete-driver $oem /uninstall /force
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  제거됨: $oem" -ForegroundColor Green
        } else {
            Write-Host "  제거 실패: $oem (exit $LASTEXITCODE)" -ForegroundColor Yellow
        }
    }
}

# --- 3) 인증서 제거 ------------------------------------------------------
Write-Host "`n[3/3] 테스트 인증서" -ForegroundColor Cyan
if ($RemoveCertificate) {
    foreach ($store in 'Root', 'TrustedPublisher') {
        $certs = Get-ChildItem "Cert:\LocalMachine\$store" -ErrorAction SilentlyContinue |
            Where-Object { $_.Subject -eq $CertSubject }
        foreach ($c in $certs) {
            Remove-Item $c.PSPath -Force
            Write-Host "  제거됨: LocalMachine\$store\$($c.Thumbprint)" -ForegroundColor Green
        }
    }
    $mine = Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -eq $CertSubject }
    foreach ($c in $mine) {
        Remove-Item $c.PSPath -Force
        Write-Host "  제거됨: CurrentUser\My\$($c.Thumbprint)" -ForegroundColor Green
    }
} else {
    Write-Host "  그대로 둔다 (-RemoveCertificate 를 주면 지운다)." -ForegroundColor DarkGray
}

Write-Host "`n완료. test signing 도 끄려면:" -ForegroundColor Cyan
Write-Host "  .\scripts\Enable-TestSigning.ps1 -Disable" -ForegroundColor DarkGray
