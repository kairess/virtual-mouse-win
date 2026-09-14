<#
.SYNOPSIS
    빌드/설치에 필요한 환경이 갖춰져 있는지 한 번에 확인한다.

.DESCRIPTION
    docs/check-wdk.md 를 수동으로 따라가는 대신 이 스크립트를 돌리면 된다.
    관리자 권한이 없어도 대부분 확인되며, Secure Boot / test signing 상태만
    관리자 권한이 필요하다 (없으면 "확인 불가"로 표시된다).

.EXAMPLE
    .\scripts\Check-Environment.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

$script:problems = @()

function Write-Check {
    param(
        [string]$Name,
        [ValidateSet('OK', 'FAIL', 'WARN', 'INFO')][string]$State,
        [string]$Detail,
        [string]$Fix
    )
    $color = switch ($State) {
        'OK'   { 'Green' }
        'FAIL' { 'Red' }
        'WARN' { 'Yellow' }
        default { 'Gray' }
    }
    Write-Host ("  [{0,-4}] {1}" -f $State, $Name) -ForegroundColor $color
    if ($Detail) { Write-Host "         $Detail" -ForegroundColor DarkGray }
    if ($State -eq 'FAIL') {
        $script:problems += [pscustomobject]@{ Name = $Name; Fix = $Fix }
    }
}

function Test-Admin {
    ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$isAdmin = Test-Admin

Write-Host "`n=== virtual-mouse build environment ===" -ForegroundColor Cyan
Write-Host ("running {0}elevated`n" -f $(if ($isAdmin) { '' } else { 'NOT ' })) -ForegroundColor DarkGray

# ---------------------------------------------------------------- OS ------
Write-Host "OS" -ForegroundColor White
$build = [System.Environment]::OSVersion.Version.Build
if ($build -ge 22000) {
    Write-Check 'Windows build >= 22000' 'OK' "build $build (MsHidKmdf.inf is inbox from 22000)"
} else {
    Write-Check 'Windows build >= 22000' 'FAIL' "build $build" `
        'INF 이 MsHidKmdf.inf 에 의존한다. Windows 11 (22000+) 이 필요하거나 INF 를 구식 방식으로 다시 써야 한다.'
}

foreach ($f in @("$env:SystemRoot\INF\mshidkmdf.inf", "$env:SystemRoot\System32\drivers\mshidkmdf.sys")) {
    if (Test-Path $f) { Write-Check (Split-Path $f -Leaf) 'OK' $f }
    else { Write-Check (Split-Path $f -Leaf) 'FAIL' "없음: $f" 'Windows 구성 요소 누락. sfc /scannow 를 고려.' }
}

# ------------------------------------------------------- Visual Studio ----
Write-Host "`nVisual Studio / MSVC" -ForegroundColor White
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vsPath = $null
if (Test-Path $vswhere) {
    $vsPath = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath
}
if ($vsPath) {
    $name = & $vswhere -latest -products * -property displayName
    Write-Check 'MSVC C++ toolset' 'OK' "$name  ($vsPath)"
} else {
    Write-Check 'MSVC C++ toolset' 'FAIL' 'vswhere 가 C++ 툴셋이 있는 인스턴스를 못 찾음' `
        'Visual Studio (또는 Build Tools) 를 "Desktop development with C++" 워크로드로 설치.'
}

$msbuild = $null
if ($vsPath) {
    $candidate = Join-Path $vsPath 'MSBuild\Current\Bin\MSBuild.exe'
    if (Test-Path $candidate) { $msbuild = $candidate }
}
if ($msbuild) { Write-Check 'MSBuild.exe' 'OK' $msbuild }
else { Write-Check 'MSBuild.exe' 'FAIL' '못 찾음' 'Visual Studio 설치를 복구/재설치.' }

# ------------------------------------------------------------- SDK/WDK ---
Write-Host "`nWindows SDK / WDK" -ForegroundColor White
$kitRoot = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots' -ErrorAction SilentlyContinue).KitsRoot10
if ($kitRoot) {
    Write-Check 'Windows Kits root' 'OK' $kitRoot
} else {
    Write-Check 'Windows Kits root' 'FAIL' '레지스트리에 Installed Roots 없음' 'Windows SDK 를 설치.'
}

$sdkVersions = @()
if ($kitRoot -and (Test-Path (Join-Path $kitRoot 'Include'))) {
    $sdkVersions = Get-ChildItem (Join-Path $kitRoot 'Include') -Directory |
        Where-Object { $_.Name -match '^10\.' } | Select-Object -ExpandProperty Name | Sort-Object
}
if ($sdkVersions) { Write-Check 'SDK 버전' 'OK' ($sdkVersions -join ', ') }
else { Write-Check 'SDK 버전' 'FAIL' '설치된 SDK 없음' 'Windows SDK 를 설치.' }

# WDK 여부는 커널 헤더/라이브러리/WDF 존재로 판별한다.
# (SDK 만 깔려 있어도 Windows Kits 폴더 자체는 존재하기 때문에
#  폴더 존재 여부만으로 판단하면 안 된다.)
$wdkVersion = $null
foreach ($v in ($sdkVersions | Sort-Object -Descending)) {
    if (Test-Path (Join-Path $kitRoot "Include\$v\km\wdm.h")) { $wdkVersion = $v; break }
}
if ($wdkVersion) {
    Write-Check 'WDK 커널 헤더 (km)' 'OK' "Include\$wdkVersion\km"
} else {
    Write-Check 'WDK 커널 헤더 (km)' 'FAIL' 'km\wdm.h 가 없음 -> WDK 미설치 (SDK 만 있음)' `
        'docs/install-wdk.md 참고. SDK 와 같은 버전의 WDK 를 설치해야 한다.'
}

$wdfInc = if ($kitRoot) { Join-Path $kitRoot 'Include\wdf' } else { $null }
if ($wdfInc -and (Test-Path $wdfInc)) {
    $kmdfVers = Get-ChildItem (Join-Path $wdfInc 'kmdf') -Directory -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty Name
    Write-Check 'KMDF 헤더' 'OK' ("kmdf " + ($kmdfVers -join ', '))
} else {
    Write-Check 'KMDF 헤더' 'FAIL' 'Include\wdf 없음' 'WDK 를 설치.'
}

$wdkBuild = if ($kitRoot) { Join-Path $kitRoot 'build' } else { $null }
if ($wdkBuild -and (Test-Path $wdkBuild)) {
    Write-Check 'WDK MSBuild 타겟' 'OK' $wdkBuild
} else {
    Write-Check 'WDK MSBuild 타겟' 'FAIL' 'Windows Kits\10\build 없음' `
        'WDK 설치 후, Build Tools 를 쓴다면 WDK VSIX 도 함께 설치해야 한다 (docs/install-wdk.md).'
}

# WDK VSIX (드라이버 프로젝트 플랫폼 툴셋) 확인
$vsixOk = $false
if ($vsPath) {
    $toolset = Join-Path $vsPath 'MSBuild\Microsoft\VC\v170\Platforms\x64\PlatformToolsets\WindowsKernelModeDriver10.0'
    $vsixOk = Test-Path $toolset
}
if ($vsixOk) {
    Write-Check 'WindowsKernelModeDriver10.0 툴셋' 'OK' '드라이버 프로젝트를 빌드할 수 있음'
} else {
    Write-Check 'WindowsKernelModeDriver10.0 툴셋' 'FAIL' 'VS 인스턴스에 드라이버 플랫폼 툴셋이 없음' `
        'WDK 설치 마지막 단계의 WDK.vsix 를 설치 (docs/install-wdk.md).'
}

# ------------------------------------------------------------- 서명 도구 --
Write-Host "`n서명 도구" -ForegroundColor White
foreach ($tool in 'signtool.exe', 'Inf2Cat.exe', 'stampinf.exe') {
    $found = $null
    if ($kitRoot -and (Test-Path (Join-Path $kitRoot 'bin'))) {
        $found = Get-ChildItem (Join-Path $kitRoot 'bin') -Recurse -Filter $tool -ErrorAction SilentlyContinue |
            Select-Object -First 1
    }
    if ($found) { Write-Check $tool 'OK' $found.FullName }
    elseif ($tool -eq 'signtool.exe') { Write-Check $tool 'FAIL' '없음' 'Windows SDK 의 "Signing Tools" 구성 요소를 설치.' }
    else { Write-Check $tool 'FAIL' '없음 (WDK 제공)' 'WDK 를 설치.' }
}

# --------------------------------------------------------- 설치 전제조건 --
Write-Host "`n드라이버 설치 전제조건" -ForegroundColor White
if ($isAdmin) {
    $bcd = (bcdedit /enum '{current}' | Out-String)
    if ($bcd -match '(?im)^testsigning\s+Yes') {
        Write-Check 'test signing' 'OK' '켜져 있음'
    } else {
        Write-Check 'test signing' 'WARN' '꺼져 있음 - 자체 서명 드라이버는 로드되지 않는다' `
            'scripts\Enable-TestSigning.ps1 실행 후 재부팅.'
    }

} else {
    Write-Check 'test signing' 'INFO' '관리자 권한으로 다시 실행하면 확인된다'
}

# Secure Boot 는 관리자 권한 없이도 레지스트리로 읽을 수 있다.
# Confirm-SecureBootUEFI 는 권한을 요구하므로 레지스트리를 먼저 본다.
$sb = $null
try {
    $sb = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -ErrorAction Stop).UEFISecureBootEnabled
} catch {
    if ($isAdmin) {
        try { $sb = [int](Confirm-SecureBootUEFI) } catch { }
    }
}

if ($sb -eq 1) {
    Write-Check 'Secure Boot' 'FAIL' '켜져 있음 - 이 상태에서는 test signing 이 무시된다' `
        'UEFI 펌웨어 설정에서 Secure Boot 를 끌 것. 안 끄면 드라이버가 코드 52 로 실패한다.'
} elseif ($sb -eq 0) {
    Write-Check 'Secure Boot' 'OK' '꺼져 있음 (test signing 사용 가능)'
} else {
    Write-Check 'Secure Boot' 'INFO' '확인 불가 (레거시 BIOS 이거나 레지스트리 키 없음)'
}

# ------------------------------------------------------------------ 요약 --
Write-Host "`n=== 요약 ===" -ForegroundColor Cyan
if ($script:problems.Count -eq 0) {
    Write-Host "문제 없음. scripts\Build-Driver.ps1 로 진행하면 된다." -ForegroundColor Green
    exit 0
}

Write-Host "해결해야 할 항목 $($script:problems.Count)개:" -ForegroundColor Yellow
foreach ($p in $script:problems) {
    Write-Host "  - $($p.Name)" -ForegroundColor Yellow
    Write-Host "      $($p.Fix)" -ForegroundColor DarkGray
}
exit 1
