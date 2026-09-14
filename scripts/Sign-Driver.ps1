<#
.SYNOPSIS
    dist\<Platform>\ 의 드라이버 패키지를 자체 서명 인증서로 테스트 서명한다.

.DESCRIPTION
    1) 자체 서명 코드 서명 인증서를 만든다 (없으면). CurrentUser\My 에 들어가므로
       이 단계는 관리자 권한이 필요 없다.
    2) vmouse.sys 에 임베디드 서명을 넣는다.
    3) Inf2Cat 으로 vmouse.cat 카탈로그를 만든다.
    4) 카탈로그에도 서명한다.
    5) 인증서를 vmouse.cer 로 내보낸다 (Install-Driver.ps1 이 신뢰 저장소에 넣는다).

    이 인증서는 테스트 서명 전용이다. test signing 모드가 켜져 있고 Secure Boot 가
    꺼져 있는 머신에서만 드라이버가 로드된다. 배포용이 아니다.

.EXAMPLE
    .\scripts\Sign-Driver.ps1
#>
[CmdletBinding()]
param(
    [ValidateSet('x64', 'ARM64')]
    [string]$Platform = 'x64',

    [string]$CertSubject = 'CN=virtual-mouse test signing',

    # Inf2Cat 의 /os 값. 최신 WDK 는 10_NI_X64 같은 값도 받지만
    # 10_X64 카탈로그도 Windows 11 에서 그대로 통한다.
    [string[]]$Inf2CatOs = @()
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$distDir  = Join-Path $repoRoot "dist\$Platform"
$sysPath  = Join-Path $distDir 'vmouse.sys'
$infPath  = Join-Path $distDir 'vmouse.inf'
$catPath  = Join-Path $distDir 'vmouse.cat'
$cerPath  = Join-Path $distDir 'vmouse.cer'

if (-not (Test-Path $sysPath)) { throw "vmouse.sys 없음. 먼저 .\scripts\Build-Driver.ps1 을 실행할 것." }
if (-not (Test-Path $infPath)) { throw "vmouse.inf 없음. 먼저 .\scripts\Build-Driver.ps1 을 실행할 것." }

# --- SDK/WDK 도구 찾기 ---------------------------------------------------
$kitRoot = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots' -ErrorAction SilentlyContinue).KitsRoot10
if (-not $kitRoot) { throw "Windows Kits 를 찾을 수 없다." }

function Find-KitTool {
    param([string]$Name, [string[]]$PreferDirs = @('x64', 'x86'))
    $all = Get-ChildItem (Join-Path $kitRoot 'bin') -Recurse -Filter $Name -File -ErrorAction SilentlyContinue
    foreach ($d in $PreferDirs) {
        $hit = $all | Where-Object { $_.Directory.Name -eq $d } |
            Sort-Object { $_.Directory.Parent.Name } -Descending | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    $hit = $all | Select-Object -First 1
    if ($hit) { return $hit.FullName }
    return $null
}

$signtool = Find-KitTool -Name 'signtool.exe'
if (-not $signtool) { throw "signtool.exe 를 찾을 수 없다 (Windows SDK 의 Signing Tools 구성 요소)." }

$inf2cat = Find-KitTool -Name 'Inf2Cat.exe' -PreferDirs @('x86', 'x64')
if (-not $inf2cat) { throw "Inf2Cat.exe 를 찾을 수 없다 (WDK 제공). docs\install-wdk.md 참고." }

Write-Host "signtool : $signtool" -ForegroundColor DarkGray
Write-Host "inf2cat  : $inf2cat"  -ForegroundColor DarkGray

# --- 1) 인증서 준비 ------------------------------------------------------
$cert = Get-ChildItem Cert:\CurrentUser\My |
    Where-Object { $_.Subject -eq $CertSubject -and $_.NotAfter -gt (Get-Date) } |
    Sort-Object NotAfter -Descending | Select-Object -First 1

if ($cert) {
    Write-Host "기존 인증서 재사용: $($cert.Thumbprint)" -ForegroundColor DarkGray
} else {
    Write-Host "자체 서명 인증서 생성: $CertSubject" -ForegroundColor Cyan
    $cert = New-SelfSignedCertificate `
        -Subject $CertSubject `
        -Type CodeSigningCert `
        -CertStoreLocation Cert:\CurrentUser\My `
        -KeyUsage DigitalSignature `
        -KeyExportPolicy Exportable `
        -HashAlgorithm sha256 `
        -NotAfter (Get-Date).AddYears(5) `
        -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3')   # EKU: Code Signing
    Write-Host "  thumbprint: $($cert.Thumbprint)" -ForegroundColor DarkGray
}

# --- 2) vmouse.sys 임베디드 서명 ----------------------------------------
Write-Host "`n[1/3] vmouse.sys 서명" -ForegroundColor Cyan
& $signtool sign /v /fd SHA256 /sha1 $cert.Thumbprint `
    /tr http://timestamp.digicert.com /td SHA256 $sysPath
if ($LASTEXITCODE -ne 0) {
    Write-Host "타임스탬프 서버 접속 실패로 보인다. 타임스탬프 없이 재시도한다." -ForegroundColor Yellow
    & $signtool sign /v /fd SHA256 /sha1 $cert.Thumbprint $sysPath
    if ($LASTEXITCODE -ne 0) { throw "vmouse.sys 서명 실패" }
}

# --- 3) 카탈로그 생성 ----------------------------------------------------
Write-Host "`n[2/3] 카탈로그(vmouse.cat) 생성" -ForegroundColor Cyan
Remove-Item $catPath -Force -ErrorAction SilentlyContinue

if ($Inf2CatOs.Count -eq 0) {
    $Inf2CatOs = if ($Platform -eq 'ARM64') {
        @('10_NI_ARM64', '10_VB_ARM64', '10_ARM64')
    } else {
        @('10_NI_X64', '10_VB_X64', '10_X64')
    }
}

$catOk = $false
foreach ($os in $Inf2CatOs) {
    & $inf2cat /driver:$distDir "/os:$os" /verbose 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0 -and (Test-Path $catPath)) {
        Write-Host "  Inf2Cat /os:$os -> OK" -ForegroundColor DarkGray
        $catOk = $true
        break
    }
    Write-Host "  Inf2Cat /os:$os -> 실패, 다음 값 시도" -ForegroundColor DarkGray
}
if (-not $catOk) {
    # 마지막 시도를 출력까지 보여주며 다시 실행해 원인을 드러낸다.
    & $inf2cat /driver:$distDir "/os:$($Inf2CatOs[-1])" /verbose
    throw "Inf2Cat 실패. INF 의 [Manufacturer] 데코레이션과 /os 값이 맞는지 확인할 것."
}

# --- 4) 카탈로그 서명 ----------------------------------------------------
Write-Host "`n[3/3] vmouse.cat 서명" -ForegroundColor Cyan
& $signtool sign /v /fd SHA256 /sha1 $cert.Thumbprint `
    /tr http://timestamp.digicert.com /td SHA256 $catPath
if ($LASTEXITCODE -ne 0) {
    & $signtool sign /v /fd SHA256 /sha1 $cert.Thumbprint $catPath
    if ($LASTEXITCODE -ne 0) { throw "vmouse.cat 서명 실패" }
}

# --- 5) 인증서 내보내기 --------------------------------------------------
Export-Certificate -Cert $cert -FilePath $cerPath -Type CERT -Force | Out-Null

# --- 검증 ----------------------------------------------------------------
Write-Host "`n검증:" -ForegroundColor Cyan
# /pa = Default Authenticode 정책. 자체 서명이라 루트 신뢰 전에는 실패하는 게
# 정상이므로 결과는 참고용으로만 출력한다.
& $signtool verify /v /pa /c $catPath $sysPath
Write-Host "(위 검증은 인증서를 신뢰 저장소에 넣기 전에는 실패하는 게 정상이다.)" -ForegroundColor DarkGray

Write-Host "`nOK. dist 내용:" -ForegroundColor Green
Get-ChildItem $distDir | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize

Write-Host "다음: 관리자 PowerShell 에서 .\scripts\Install-Driver.ps1 -Platform $Platform" -ForegroundColor Cyan

# 위 signtool verify 는 실패하는 게 정상이므로 그 종료 코드가 스크립트의
# 종료 코드로 새어나가지 않게 한다. 여기까지 왔으면 서명은 성공한 것이다.
exit 0
