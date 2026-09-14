<#
.SYNOPSIS
    test signing 모드를 켠다 (관리자 권한 필요, 재부팅 필요).

.DESCRIPTION
    자체 서명한 커널 드라이버를 로드하려면 test signing 모드가 필요하다.
    주의:
      - Secure Boot 가 켜져 있으면 test signing 은 무시된다. UEFI 에서 꺼야 한다.
      - BitLocker 로 OS 볼륨이 잠겨 있으면 부팅 구성 변경 시 복구 키를 물어볼 수
        있다. 미리 일시 중단(suspend)하는 것이 안전하다.
      - 켜져 있는 동안 바탕화면 우측 하단에 "테스트 모드" 워터마크가 뜬다.

    되돌리려면: .\scripts\Enable-TestSigning.ps1 -Disable

.EXAMPLE
    .\scripts\Enable-TestSigning.ps1
    .\scripts\Enable-TestSigning.ps1 -Disable
#>
[CmdletBinding()]
param(
    [switch]$Disable
)

$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    throw "관리자 권한 PowerShell 에서 실행해야 한다."
}

# --- Secure Boot 확인 ----------------------------------------------------
$secureBoot = $null
try { $secureBoot = Confirm-SecureBootUEFI } catch { }

if ($secureBoot -eq $true -and -not $Disable) {
    Write-Host @"

경고: Secure Boot 가 켜져 있다.

  Secure Boot 가 활성화된 상태에서는 test signing 플래그를 켜도 Windows 가
  이를 무시하고, 자체 서명 드라이버는 여전히 로드되지 않는다
  (장치 관리자에 코드 52 / CM_PROB_DRIVER_FAILED_LOAD 로 뜬다).

  UEFI 펌웨어 설정에 들어가 Secure Boot 를 끈 뒤 다시 실행할 것.

"@ -ForegroundColor Red

    $answer = Read-Host "그래도 계속 진행할까? (y/N)"
    if ($answer -ne 'y') {
        Write-Host "중단했다." -ForegroundColor Yellow
        exit 1
    }
}

# --- BitLocker 확인 ------------------------------------------------------
try {
    $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
    if ($bl.ProtectionStatus -eq 'On') {
        Write-Host @"

경고: OS 볼륨($env:SystemDrive)에 BitLocker 보호가 켜져 있다.
  부팅 구성(BCD)을 바꾸면 다음 부팅 때 복구 키를 요구할 수 있다.
  진행 전에 복구 키를 확보하거나 BitLocker 를 일시 중단할 것:
      Suspend-BitLocker -MountPoint $env:SystemDrive -RebootCount 1

"@ -ForegroundColor Yellow
        $answer = Read-Host "계속 진행할까? (y/N)"
        if ($answer -ne 'y') {
            Write-Host "중단했다." -ForegroundColor Yellow
            exit 1
        }
    }
} catch {
    # BitLocker 가 없는 시스템이면 여기로 온다. 무시해도 된다.
}

# --- 적용 ----------------------------------------------------------------
$value = if ($Disable) { 'off' } else { 'on' }

Write-Host "bcdedit /set testsigning $value" -ForegroundColor Cyan
bcdedit /set testsigning $value
if ($LASTEXITCODE -ne 0) { throw "bcdedit 실패 (exit $LASTEXITCODE)" }

Write-Host "`n현재 부팅 항목:" -ForegroundColor Cyan
bcdedit /enum '{current}' | Select-String -Pattern 'identifier|testsigning|description'

Write-Host "`n재부팅해야 적용된다." -ForegroundColor Yellow
Write-Host "재부팅 후 scripts\Install-Driver.ps1 로 진행할 것." -ForegroundColor Cyan
