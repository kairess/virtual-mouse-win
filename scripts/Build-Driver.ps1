<#
.SYNOPSIS
    가상 HID 마우스 KMDF 드라이버(vmouse.sys)를 빌드한다.

.DESCRIPTION
    WDK 가 필요하다. 먼저 scripts\Check-Environment.ps1 로 확인할 것.
    빌드 산출물(vmouse.sys, vmouse.inf)은 dist\<Platform>\ 에 모아둔다.
    서명은 scripts\Sign-Driver.ps1 가 별도로 한다.

.EXAMPLE
    .\scripts\Build-Driver.ps1
    .\scripts\Build-Driver.ps1 -Platform arm64 -Configuration Debug
#>
[CmdletBinding()]
param(
    [ValidateSet('x64', 'ARM64')]
    [string]$Platform = 'x64',

    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [switch]$Clean
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$project  = Join-Path $repoRoot 'driver\vmouse.vcxproj'
$distDir  = Join-Path $repoRoot "dist\$Platform"

if (-not (Test-Path $project)) { throw "project not found: $project" }

# --- WDK 존재 확인 (없으면 msbuild 가 난해한 에러를 뱉으므로 먼저 잡는다) ---
$kitRoot = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots' -ErrorAction SilentlyContinue).KitsRoot10
$hasWdk = $false
if ($kitRoot -and (Test-Path (Join-Path $kitRoot 'Include'))) {
    foreach ($v in (Get-ChildItem (Join-Path $kitRoot 'Include') -Directory | Sort-Object Name -Descending)) {
        if (Test-Path (Join-Path $v.FullName 'km\wdm.h')) { $hasWdk = $true; break }
    }
}
if (-not $hasWdk) {
    throw "WDK 가 설치되어 있지 않다 (커널 헤더 km\wdm.h 없음). docs\install-wdk.md 참고."
}

# --- MSBuild 찾기 --------------------------------------------------------
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) { throw "vswhere.exe 없음. Visual Studio 를 설치할 것." }

$vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsPath) { throw "MSVC C++ 툴셋이 있는 Visual Studio 인스턴스를 못 찾음." }

$msbuild = Join-Path $vsPath 'MSBuild\Current\Bin\MSBuild.exe'
if (-not (Test-Path $msbuild)) { throw "MSBuild.exe 없음: $msbuild" }

$toolset = Join-Path $vsPath "MSBuild\Microsoft\VC\v170\Platforms\$Platform\PlatformToolsets\WindowsKernelModeDriver10.0"
if (-not (Test-Path $toolset)) {
    throw @"
드라이버 플랫폼 툴셋(WindowsKernelModeDriver10.0)이 이 VS 인스턴스에 없다:
  $toolset
WDK 설치 후 WDK.vsix 를 이 인스턴스에 설치해야 한다. docs\install-wdk.md 참고.
"@
}

# --- 빌드 ----------------------------------------------------------------
$target = if ($Clean) { 'Rebuild' } else { 'Build' }

Write-Host "Building vmouse.sys ($Platform / $Configuration)..." -ForegroundColor Cyan
& $msbuild $project `
    "/t:$target" `
    "/p:Configuration=$Configuration" `
    "/p:Platform=$Platform" `
    /p:TargetVersion=Windows10 `
    /nologo `
    /verbosity:minimal

if ($LASTEXITCODE -ne 0) { throw "msbuild 실패 (exit $LASTEXITCODE)" }

# --- 산출물 수집 ---------------------------------------------------------
# 드라이버 프로젝트는 $(OutDir) 아래에 패키지 하위 폴더를 만들기도 하고
# 곧바로 떨구기도 한다. 양쪽 다 훑어서 가장 최근 것을 고른다.
$buildDir = Join-Path $repoRoot "build\$Platform\$Configuration"
if (-not (Test-Path $buildDir)) { throw "빌드 출력 폴더가 없다: $buildDir" }

function Find-Newest {
    param([string]$Root, [string]$Filter)
    Get-ChildItem -Path $Root -Recurse -Filter $Filter -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

$sys = Find-Newest -Root $buildDir -Filter 'vmouse.sys'
$inf = Find-Newest -Root $buildDir -Filter 'vmouse.inf'
$pdb = Find-Newest -Root $buildDir -Filter 'vmouse.pdb'

if (-not $sys) { throw "빌드는 성공했는데 vmouse.sys 를 못 찾겠다 ($buildDir)" }
if (-not $inf) { throw "vmouse.inf 가 생성되지 않았다. stampinf 가 vmouse.inx 를 처리했는지 확인할 것." }

New-Item -ItemType Directory -Force -Path $distDir | Out-Null
# 이전 서명 산출물이 남아 헷갈리지 않도록 정리한다.
Remove-Item (Join-Path $distDir '*') -Force -ErrorAction SilentlyContinue

Copy-Item $sys.FullName $distDir -Force
Copy-Item $inf.FullName $distDir -Force
if ($pdb) { Copy-Item $pdb.FullName $distDir -Force }

Write-Host "`nOK. dist 내용:" -ForegroundColor Green
Get-ChildItem $distDir | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize

Write-Host "다음: .\scripts\Sign-Driver.ps1 -Platform $Platform" -ForegroundColor Cyan
