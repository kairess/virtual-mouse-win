<#
.SYNOPSIS
    드라이버 플랫폼 툴셋(WindowsKernelModeDriver10.0)을 Visual Studio 인스턴스에
    설치한다. (관리자 권한 필요)

.DESCRIPTION
    WDK 본체를 설치해도 이 툴셋이 VS 인스턴스에 없으면 드라이버 프로젝트를
    빌드할 수 없다. 툴셋을 넣어주는 건 WDK.vsix 인데, 그 매니페스트는
    설치 대상을 아래 셋으로만 선언한다:

        Microsoft.VisualStudio.Community
        Microsoft.VisualStudio.Pro
        Microsoft.VisualStudio.Enterprise

    즉 **Build Tools 는 지원 대상이 아니고**, VSIXInstaller 는 종료 코드 2003
    ("설치된 제품 중 설치 가능한 대상이 없음")으로 거부한다. 재시도해도 안 된다.

    그래서 이 스크립트는 두 갈래로 동작한다:

      full VS (Community/Pro/Enterprise)
          VSIXInstaller 로 정식 설치한다.

      Build Tools
          VSIX 는 그냥 zip 이므로 풀어서 그 안의
          `$MSBuild\Microsoft\VC\v170\` 를 VS 인스턴스의 같은 경로로 복사한다.
          명령줄 빌드에 필요한 건 이 MSBuild props/targets 뿐이고,
          VSIX 의 나머지(프로젝트 템플릿, 메뉴, pkgdef)는 IDE 전용이라
          msbuild 에는 필요 없다.

          복사되는 54개 파일은 전부 WDK 전용 경로에만 들어가며 기존 VS 파일과
          겹치지 않는다(충돌 0건 확인). 순수하게 추가만 하는 작업이다.
          기존 파일을 덮어쓰게 되는 상황이면 중단한다.

    되돌리려면: .\scripts\Install-WdkToolset.ps1 -Uninstall

.EXAMPLE
    .\scripts\Install-WdkToolset.ps1
    .\scripts\Install-WdkToolset.ps1 -WhatIf
    .\scripts\Install-WdkToolset.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    # 지정하지 않으면 가장 높은 버전의 WDK.vsix 를 자동 선택한다.
    [string]$VsixPath,

    # 지정하지 않으면 vswhere 로 찾은 첫 인스턴스를 쓴다.
    [string]$InstanceId,

    # VSIXInstaller 를 쓰지 않고 무조건 파일 복사 방식을 쓴다.
    [switch]$ForceFileCopy,

    [switch]$Uninstall,

    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------- VSIX ----
if (-not $VsixPath) {
    $kitRoot = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots' -ErrorAction SilentlyContinue).KitsRoot10
    if (-not $kitRoot) { throw "Windows Kits 를 찾을 수 없다. WDK 가 설치되어 있나?" }

    $candidates = Get-ChildItem (Join-Path $kitRoot 'Vsix') -Recurse -Filter 'WDK.vsix' -ErrorAction SilentlyContinue |
        Sort-Object { [version]$_.Directory.Name } -Descending
    if (-not $candidates) {
        throw "WDK.vsix 를 찾을 수 없다. WDK 를 설치했는지 확인할 것 (docs\install-wdk.md)."
    }
    $VsixPath = $candidates[0].FullName
}
if (-not (Test-Path $VsixPath)) { throw "VSIX 없음: $VsixPath" }

# ----------------------------------------------------- VS 인스턴스 ------
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) { throw "vswhere.exe 없음." }

$instances = @(& $vswhere -all -products * -format json | ConvertFrom-Json)
if ($instances.Count -eq 0) { throw "Visual Studio 인스턴스를 못 찾음." }

if ($InstanceId) {
    $target = $instances | Where-Object { $_.instanceId -eq $InstanceId } | Select-Object -First 1
    if (-not $target) { throw "instanceId '$InstanceId' 인 인스턴스가 없다." }
} else {
    if ($instances.Count -gt 1) {
        Write-Host "여러 인스턴스가 있다. 첫 번째를 쓴다 (-InstanceId 로 지정 가능):" -ForegroundColor Yellow
        $instances | ForEach-Object { Write-Host "  $($_.instanceId)  $($_.displayName)" }
    }
    $target = $instances[0]
}

$InstanceId = $target.instanceId
$vsPath     = $target.installationPath
$productId  = $target.productId

Write-Host "대상   : $($target.displayName)" -ForegroundColor DarkGray
Write-Host "id     : $InstanceId"            -ForegroundColor DarkGray
Write-Host "경로   : $vsPath"                -ForegroundColor DarkGray
Write-Host "product: $productId"             -ForegroundColor DarkGray
Write-Host "vsix   : $VsixPath"              -ForegroundColor DarkGray

$toolsetDir = Join-Path $vsPath 'MSBuild\Microsoft\VC\v170\Platforms\x64\PlatformToolsets\WindowsKernelModeDriver10.0'
$vcDstRoot  = Join-Path $vsPath 'MSBuild\Microsoft\VC\v170'

# WDK.vsix 가 정식으로 지원하는 제품들.
$vsixSupported = @(
    'Microsoft.VisualStudio.Product.Community',
    'Microsoft.VisualStudio.Product.Professional',
    'Microsoft.VisualStudio.Product.Enterprise'
)
$useVsix = (-not $ForceFileCopy) -and ($vsixSupported -contains $productId)

# ------------------------------------------------------------ 공통 준비 --
function Expand-Vsix {
    param([string]$Path)
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("wdkvsix_" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    # VSIX 는 zip 이지만 확장자 때문에 Expand-Archive 가 거부한다. 복사 후 푼다.
    $zip = Join-Path $tmp 'WDK.zip'
    Copy-Item $Path $zip
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    return $tmp
}

function Get-VsixMsBuildRoot {
    param([string]$ExtractDir)
    $root = Join-Path $ExtractDir '$MSBuild\Microsoft\VC\v170'
    if (-not (Test-Path $root)) { throw "VSIX 안에 `$MSBuild\Microsoft\VC\v170 가 없다: $ExtractDir" }
    return $root
}

# ------------------------------------------------------------ Uninstall --
if ($Uninstall) {
    $isAdmin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin -and -not $WhatIf) { throw "관리자 권한 PowerShell 에서 실행해야 한다." }

    $ex = Expand-Vsix -Path $VsixPath
    try {
        $srcRoot = Get-VsixMsBuildRoot -ExtractDir $ex
        $removed = 0
        Get-ChildItem $srcRoot -Recurse -File | ForEach-Object {
            $rel = $_.FullName.Substring($srcRoot.Length + 1)
            $dst = Join-Path $vcDstRoot $rel
            if (Test-Path $dst) {
                if ($WhatIf) { Write-Host "  [WhatIf] 삭제: $rel" -ForegroundColor DarkGray }
                else { Remove-Item $dst -Force; $removed++ }
            }
        }
        Write-Host "`n$removed 개 파일 삭제됨." -ForegroundColor Green
        Write-Host "(빈 폴더는 남을 수 있다. 무해하다.)" -ForegroundColor DarkGray
    } finally {
        Remove-Item $ex -Recurse -Force -ErrorAction SilentlyContinue
    }
    exit 0
}

# --------------------------------------------------------------- 이미? --
if (Test-Path $toolsetDir) {
    Write-Host "`n이미 설치되어 있다: $toolsetDir" -ForegroundColor Green
    Write-Host "다음: .\scripts\Build-Driver.ps1" -ForegroundColor Cyan
    exit 0
}

# --------------------------------------------------------------- 설치 ---
if ($useVsix) {
    $installer = Get-ChildItem (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer') `
        -Recurse -Filter 'VSIXInstaller.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $installer) { throw "VSIXInstaller.exe 를 찾을 수 없다." }

    if ($WhatIf) {
        Write-Host "`n[WhatIf] 실행할 명령:" -ForegroundColor Cyan
        Write-Host "& `"$($installer.FullName)`" /quiet /admin /instanceIds:$InstanceId `"$VsixPath`""
        exit 0
    }

    $isAdmin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw "관리자 권한 PowerShell 에서 실행해야 한다." }

    Write-Host "`nVSIXInstaller 로 설치 중... (몇 분 걸릴 수 있다)" -ForegroundColor Cyan
    $proc = Start-Process -FilePath $installer.FullName `
        -ArgumentList @('/quiet', '/admin', "/instanceIds:$InstanceId", "`"$VsixPath`"") `
        -Wait -PassThru -NoNewWindow

    switch ($proc.ExitCode) {
        0    { Write-Host "설치 완료." -ForegroundColor Green }
        1001 { Write-Host "이미 설치되어 있다." -ForegroundColor Green }
        2003 {
            Write-Host "종료 코드 2003: 이 제품은 WDK.vsix 의 설치 대상이 아니다." -ForegroundColor Yellow
            Write-Host "파일 복사 방식으로 전환한다." -ForegroundColor Yellow
            $useVsix = $false
        }
        default {
            Write-Host "VSIXInstaller 종료 코드: $($proc.ExitCode)" -ForegroundColor Yellow
            Write-Host "파일 복사 방식으로 전환한다." -ForegroundColor Yellow
            $useVsix = $false
        }
    }
}

if (-not $useVsix) {
    Write-Host "`n파일 복사 방식 (Build Tools 등 VSIX 미지원 제품용)" -ForegroundColor Cyan

    $ex = Expand-Vsix -Path $VsixPath
    try {
        $srcRoot = Get-VsixMsBuildRoot -ExtractDir $ex
        $files = Get-ChildItem $srcRoot -Recurse -File

        # 기존 VS 파일을 덮어쓰는 상황이면 손대지 않는다.
        $collisions = @()
        foreach ($f in $files) {
            $rel = $f.FullName.Substring($srcRoot.Length + 1)
            if (Test-Path (Join-Path $vcDstRoot $rel)) { $collisions += $rel }
        }
        if ($collisions.Count -gt 0) {
            Write-Host "`n기존 파일과 충돌한다. 덮어쓰지 않고 중단한다:" -ForegroundColor Red
            $collisions | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
            throw "충돌 $($collisions.Count)건. 수동으로 확인할 것."
        }

        Write-Host "  복사할 파일: $($files.Count)개 -> $vcDstRoot" -ForegroundColor DarkGray

        if ($WhatIf) {
            $files | ForEach-Object {
                Write-Host "  [WhatIf] $($_.FullName.Substring($srcRoot.Length + 1))" -ForegroundColor DarkGray
            }
            exit 0
        }

        $isAdmin = ([Security.Principal.WindowsPrincipal] `
            [Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isAdmin) { throw "관리자 권한 PowerShell 에서 실행해야 한다." }

        foreach ($f in $files) {
            $rel = $f.FullName.Substring($srcRoot.Length + 1)
            $dst = Join-Path $vcDstRoot $rel
            New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
            Copy-Item $f.FullName $dst
        }
        Write-Host "  $($files.Count)개 파일 복사 완료." -ForegroundColor Green
    } finally {
        Remove-Item $ex -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --------------------------------------------------------------- 검증 ---
Write-Host ""
if (Test-Path $toolsetDir) {
    Write-Host "OK: WindowsKernelModeDriver10.0 툴셋 설치됨." -ForegroundColor Green
    Write-Host "    $toolsetDir" -ForegroundColor DarkGray
    Write-Host "`n다음: .\scripts\Build-Driver.ps1" -ForegroundColor Cyan
    exit 0
}

Write-Host "실패: 툴셋이 여전히 없다." -ForegroundColor Red
Write-Host "    $toolsetDir" -ForegroundColor DarkGray
Write-Host @"

대안: Visual Studio Community 2022 (무료) 를 'Desktop development with C++'
      워크로드로 설치하면 WDK 확장이 정식으로 붙는다.
"@ -ForegroundColor Yellow
exit 1
