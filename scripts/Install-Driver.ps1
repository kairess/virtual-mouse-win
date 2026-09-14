<#
.SYNOPSIS
    서명된 드라이버 패키지를 설치하고 root\virtualmouse 장치를 만든다.
    (관리자 권한 필요)

.DESCRIPTION
    순서:
      1) test signing / Secure Boot 상태 확인
      2) vmouse.cer 를 LocalMachine\Root 와 LocalMachine\TrustedPublisher 에 등록
      3) pnputil /add-driver 로 드라이버 스토어에 등록
      4) vmousectl install 로 root\virtualmouse devnode 생성 + 드라이버 바인딩
      5) vmousectl status / rawinput 으로 검증

.EXAMPLE
    .\scripts\Install-Driver.ps1
#>
[CmdletBinding()]
param(
    [ValidateSet('x64', 'ARM64')]
    [string]$Platform = 'x64'
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$distDir  = Join-Path $repoRoot "dist\$Platform"
$infPath  = Join-Path $distDir 'vmouse.inf'
$catPath  = Join-Path $distDir 'vmouse.cat'
$cerPath  = Join-Path $distDir 'vmouse.cer'
$ctl      = Join-Path $repoRoot "build\$Platform\Release\vmousectl.exe"

$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) { throw "관리자 권한 PowerShell 에서 실행해야 한다." }

foreach ($f in @($infPath, $catPath, $cerPath)) {
    if (-not (Test-Path $f)) {
        throw "$f 가 없다. Build-Driver.ps1 -> Sign-Driver.ps1 순서로 먼저 실행할 것."
    }
}

if (-not (Test-Path $ctl)) {
    Write-Host "vmousectl.exe 가 없다. 지금 빌드한다." -ForegroundColor Yellow
    & (Join-Path $PSScriptRoot 'Build-Tool.ps1') -Platform $Platform.ToLower()
    if (-not (Test-Path $ctl)) { throw "vmousectl.exe 빌드 실패" }
}

# --- 1) 부팅 정책 확인 ---------------------------------------------------
Write-Host "`n[1/5] 부팅 서명 정책 확인" -ForegroundColor Cyan

$bcd = (bcdedit /enum '{current}' | Out-String)
if ($bcd -notmatch '(?im)^testsigning\s+Yes') {
    throw @"
test signing 이 꺼져 있다. 자체 서명 드라이버는 로드되지 않는다.
  .\scripts\Enable-TestSigning.ps1 실행 후 재부팅하고 다시 시도할 것.
"@
}
Write-Host "  test signing: 켜짐" -ForegroundColor Green

try {
    if (Confirm-SecureBootUEFI) {
        Write-Host @"
  경고: Secure Boot 가 켜져 있다. 이 상태에서는 test signing 이 무시되어
        드라이버가 코드 52 로 실패할 가능성이 높다. UEFI 에서 끄는 것을 권장.
"@ -ForegroundColor Yellow
    } else {
        Write-Host "  Secure Boot: 꺼짐" -ForegroundColor Green
    }
} catch {
    Write-Host "  Secure Boot: 확인 불가 (레거시 BIOS 일 수 있음)" -ForegroundColor DarkGray
}

# --- 2) 인증서 신뢰 ------------------------------------------------------
Write-Host "`n[2/5] 테스트 인증서를 신뢰 저장소에 등록" -ForegroundColor Cyan

foreach ($store in 'Root', 'TrustedPublisher') {
    Import-Certificate -FilePath $cerPath -CertStoreLocation "Cert:\LocalMachine\$store" | Out-Null
    Write-Host "  LocalMachine\$store <- vmouse.cer" -ForegroundColor Green
}

# --- 3) 드라이버 스토어 등록 --------------------------------------------
Write-Host "`n[3/5] pnputil /add-driver" -ForegroundColor Cyan

$pnpOut = & pnputil.exe /add-driver $infPath 2>&1 | Out-String
Write-Host $pnpOut.Trim() -ForegroundColor DarkGray
if ($LASTEXITCODE -ne 0) {
    throw "pnputil /add-driver 실패 (exit $LASTEXITCODE). 서명이 신뢰되는지 확인할 것."
}

# --- 4) devnode 생성 + 드라이버 설치 ------------------------------------
Write-Host "`n[4/5] root\virtualmouse devnode 생성" -ForegroundColor Cyan

& $ctl install $infPath
if ($LASTEXITCODE -ne 0) { throw "vmousectl install 실패 (exit $LASTEXITCODE)" }

# PnP 가 스택을 올릴 시간을 잠깐 준다.
Start-Sleep -Seconds 2

# --- 5) 검증 -------------------------------------------------------------
Write-Host "`n[5/5] 검증" -ForegroundColor Cyan

& $ctl status
$statusCode = $LASTEXITCODE

Write-Host ""
& $ctl rawinput
$rawCode = $LASTEXITCODE

Write-Host ""
if ($statusCode -eq 0 -and $rawCode -eq 0) {
    Write-Host "성공: 가상 마우스가 RawInput 에 마우스로 보인다." -ForegroundColor Green
    exit 0
}

Write-Host @"
아직 마우스로 잡히지 않는다. 확인할 것:

  - 'vmousectl status' 의 problem 값
      CM_PROB_DRIVER_FAILED_LOAD -> 서명/Secure Boot 문제
      CM_PROB_FAILED_START       -> 드라이버 자체 오류. DebugView 로 'vmouse:' 로그 확인
      CM_PROB_NOT_CONFIGURED     -> INF 매칭 실패. [Manufacturer] 데코레이션 확인
  - 장치 관리자에서 "Virtual HID Mouse" 아래 "HID-compliant mouse" 가 생겼는지
  - docs\troubleshooting.md
"@ -ForegroundColor Yellow
exit 1
