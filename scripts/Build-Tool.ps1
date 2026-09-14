<#
.SYNOPSIS
    vmousectl.exe (유저모드 제어/검증 툴)를 빌드한다.

.DESCRIPTION
    Windows SDK + MSVC 만 있으면 빌드된다. WDK 는 필요 없다.
    드라이버를 아직 못 만드는 상태에서도 'vmousectl rawinput' 으로
    현재 이 PC 가 RawInput 에 마우스를 몇 개 노출하는지 먼저 확인할 수 있다.

.EXAMPLE
    .\scripts\Build-Tool.ps1
    .\scripts\Build-Tool.ps1 -Platform arm64
#>
[CmdletBinding()]
param(
    [ValidateSet('x64', 'arm64')]
    [string]$Platform = 'x64',

    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'

$repoRoot   = Split-Path -Parent $PSScriptRoot
$srcFile    = Join-Path $repoRoot 'tools\vmousectl\vmousectl.c'
$descheckSrc= Join-Path $repoRoot 'tools\descheck\descheck.c'
$driverDir  = Join-Path $repoRoot 'driver'
$outDir     = Join-Path $repoRoot "build\$Platform\$Configuration"
$objDir     = Join-Path $repoRoot "build\obj\$Platform\$Configuration\vmousectl"
$exePath    = Join-Path $outDir 'vmousectl.exe'
$descheckExe= Join-Path $outDir 'descheck.exe'

if (-not (Test-Path $srcFile)) { throw "source not found: $srcFile" }
if (-not (Test-Path $descheckSrc)) { throw "source not found: $descheckSrc" }

# --- locate the MSVC developer environment -------------------------------
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) {
    throw "vswhere.exe not found. Install Visual Studio (or Build Tools) with the 'Desktop development with C++' workload."
}

$vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsPath) {
    throw "No Visual Studio instance with the MSVC C++ toolset was found."
}

$vcvars = Join-Path $vsPath 'VC\Auxiliary\Build\vcvarsall.bat'
if (-not (Test-Path $vcvars)) { throw "vcvarsall.bat not found under $vsPath" }

New-Item -ItemType Directory -Force -Path $outDir, $objDir | Out-Null

# --- compile -------------------------------------------------------------
# /W4 /WX      : same strictness as the driver project
# /utf-8       : source is UTF-8; all string literals in the tool are ASCII
# /GS /guard:cf: default hardening
$clFlags = @(
    '/nologo', '/W4', '/WX', '/utf-8', '/GS', '/guard:cf'
    '/D_UNICODE', '/DUNICODE', '/D_CRT_SECURE_NO_WARNINGS'
    "/Fo$objDir\"
    "/Fd$objDir\vmousectl.pdb"
)
if ($Configuration -eq 'Debug') { $clFlags += @('/Od', '/Zi', '/MTd') }
else                            { $clFlags += @('/O2', '/Zi', '/MT') }

$linkFlags = @('/link', '/nologo', "/OUT:$exePath", '/DEBUG', '/SUBSYSTEM:CONSOLE')

$cmdline = 'cl.exe ' + ($clFlags -join ' ') + ' "' + $srcFile + '" ' + ($linkFlags -join ' ')

# descheck validates driver\ReportDescriptor.h.
# /wd4127: its checks compare compile-time constants on purpose, which is
# exactly what C4127 (constant conditional expression) complains about.
$descheckCmd = 'cl.exe /nologo /W4 /WX /wd4127 /utf-8 /I "' + $driverDir + '" "' + $descheckSrc +
    '" /Fo"' + $objDir + '\\" /Fe:"' + $descheckExe + '" /link /nologo'

# vcvarsall needs the host/target pair; from an x64 host build x64 or arm64.
$arch = if ($Platform -eq 'x64') { 'x64' } else { 'x64_arm64' }

Write-Host "Building vmousectl.exe + descheck.exe ($Platform / $Configuration)..." -ForegroundColor Cyan
# vcvarsall shells out to vswhere; make sure it can find it on PATH.
$vswhereDir = Split-Path -Parent $vswhere
$batch = @"
@echo off
set "PATH=$vswhereDir;%PATH%"
call "$vcvars" $arch >nul || exit /b 1
$cmdline
if errorlevel 1 exit /b 1
$descheckCmd
if errorlevel 1 exit /b 1
"@

$tmp = [System.IO.Path]::GetTempFileName() + '.cmd'
Set-Content -Path $tmp -Value $batch -Encoding ASCII
try {
    & cmd.exe /c $tmp
    $code = $LASTEXITCODE
} finally {
    Remove-Item $tmp -ErrorAction SilentlyContinue
}

if ($code -ne 0) { throw "build failed (exit $code)" }
if (-not (Test-Path $exePath)) { throw "build reported success but $exePath is missing" }
if (-not (Test-Path $descheckExe)) { throw "build reported success but $descheckExe is missing" }

Write-Host "`nOK:" -ForegroundColor Green
Get-Item $exePath, $descheckExe | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize

# 리포트 디스크립터는 이 프로젝트의 핵심이다. 빌드할 때마다 검증한다.
# ARM64 로 크로스 빌드한 경우 x64 호스트에서 실행할 수 없으므로 건너뛴다.
if ($Platform -eq 'x64') {
    Write-Host "리포트 디스크립터 검증:" -ForegroundColor Cyan
    & $descheckExe
    if ($LASTEXITCODE -ne 0) {
        throw "driver\ReportDescriptor.h 검증 실패 (exit $LASTEXITCODE)"
    }
} else {
    Write-Host "descheck 는 $Platform 바이너리라 이 호스트에서 실행하지 않는다." -ForegroundColor DarkGray
}
