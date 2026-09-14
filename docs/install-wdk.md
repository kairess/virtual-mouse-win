# WDK 설치

`scripts\Check-Environment.ps1` 이 WDK 관련 항목에서 FAIL 을 내면 이 문서를 따른다.

## 현재 이 머신 상태 (2026-09-14 확인)

| 항목 | 상태 |
|---|---|
| Visual Studio Build Tools 2022 (17.11) | 설치됨 |
| MSVC C++ 툴셋 | 설치됨 |
| Windows SDK 10.0.22621.0 | 설치됨 |
| **WDK (커널 헤더 / KMDF / Inf2Cat / stampinf)** | **없음** |
| `mshidkmdf.sys`, `MsHidKmdf.inf` | 인박스로 존재 (OS build 26200) |
| 펌웨어 | UEFI |
| Secure Boot | **꺼짐** (`UEFISecureBootEnabled = 0`) — test signing 사용 가능 |

즉 부족한 건 WDK 하나다. Secure Boot 는 이미 꺼져 있어서 UEFI 설정을 건드릴 필요가 없다.

## 중요: SDK 와 WDK 버전은 반드시 일치해야 한다

WDK 는 같은 버전의 SDK 위에서만 빌드된다. 이 머신의 SDK 는 `10.0.22621.0` 이므로
**WDK 10.0.22621** 을 설치해야 한다. 다른 버전(26100, 28000 등)을 깔면 그에 맞는
SDK 도 같이 설치해야 하고, 드라이버 프로젝트의 `TargetVersion` 도 맞춰야 한다.

## 설치 (winget, 권장)

관리자 권한 PowerShell 에서:

```powershell
winget install --id Microsoft.WindowsWDK.10.0.22621 --exact --accept-package-agreements --accept-source-agreements
```

> Claude Code 세션 안에서라면 프롬프트에 `! winget install ...` 처럼 `!` 를 붙여
> 바로 실행할 수 있다. 단 관리자 권한 세션이어야 한다.

## 설치 (수동)

1. <https://learn.microsoft.com/windows-hardware/drivers/download-the-wdk> 에서
   "Windows 11, version 22H2 WDK" (10.0.22621) 다운로드
2. 설치 프로그램 실행
3. **설치 마지막 단계에서 "Install Windows Driver Kit Visual Studio Extension" 체크를 반드시 켤 것.**
   이게 `WDK.vsix` 이고, 여기에 `WindowsKernelModeDriver10.0` 플랫폼 툴셋이 들어 있다.
   이게 없으면 `driver\vmouse.vcxproj` 를 msbuild 로 빌드할 수 없다.

## Build Tools 만 설치된 경우 (이 머신이 해당)

이 머신에는 full Visual Studio 가 아니라 **Build Tools 2022** 만 있다.
WDK 본체는 정상 설치되지만, 드라이버 플랫폼 툴셋
(`WindowsKernelModeDriver10.0`)이 VS 인스턴스에 들어가지 않는다.
이게 없으면 msbuild 가 드라이버 프로젝트의 `PlatformToolset` 을 해석하지 못한다.

원인은 단순하다. `WDK.vsix` 의 매니페스트가 설치 대상을 이렇게만 선언한다:

```xml
<InstallationTarget Version="[17.0,18.0)" Id="Microsoft.VisualStudio.Community" />
<InstallationTarget Version="[17.0,18.0)" Id="Microsoft.VisualStudio.Pro" />
<InstallationTarget Version="[17.0,18.0)" Id="Microsoft.VisualStudio.Enterprise" />
```

**Build Tools 는 목록에 없다.** 그래서 VSIXInstaller 는 종료 코드 **2003**
("설치된 제품 중 설치 가능한 대상이 없음")으로 거부한다. 이건 버그나 일시적
실패가 아니라 의도된 거부이므로, 재시도하거나 `/admin` 을 붙여도 안 된다.

### 해결

```powershell
# 관리자 권한
.\scripts\Install-WdkToolset.ps1
```

이 스크립트는 제품을 보고 알아서 갈라진다:

- **full VS** → VSIXInstaller 로 정식 설치
- **Build Tools** → VSIX 를 풀어서 그 안의 `$MSBuild\Microsoft\VC\v170\` 를
  VS 인스턴스의 같은 경로로 복사

명령줄 빌드에 실제로 필요한 건 그 MSBuild props/targets 54개 파일뿐이다.
VSIX 의 나머지(프로젝트 템플릿, 메뉴, pkgdef)는 IDE 전용이라 msbuild 에는
쓰이지 않는다.

복사되는 54개 파일은 전부 WDK 전용 경로
(`Platforms\*\PlatformToolsets\Windows*Driver10.0\`, `ImportBefore`,
`ImportAfter`, `PlatformUpgrade`, `WDKConversion`)에만 들어가며 기존 VS 파일과
**단 한 건도 겹치지 않는다.** 순수하게 추가만 하는 작업이고, 스크립트는 혹시
덮어쓰게 되는 파일이 있으면 아예 중단한다.

미리 확인하려면:

```powershell
.\scripts\Install-WdkToolset.ps1 -WhatIf     # 아무것도 건드리지 않고 목록만 출력
```

되돌리려면:

```powershell
.\scripts\Install-WdkToolset.ps1 -Uninstall
```

### 대안

파일 복사가 꺼림칙하면 **Visual Studio Community 2022**(무료)를
"Desktop development with C++" 워크로드로 설치하면 된다. 그러면 WDK 확장이
정식 경로로 붙는다. 다만 다운로드가 수 GB 로 훨씬 크다.

## 확인

```powershell
.\scripts\Check-Environment.ps1
```

아래 4개가 전부 OK 로 바뀌어야 한다:

- WDK 커널 헤더 (km)
- KMDF 헤더
- WDK MSBuild 타겟
- WindowsKernelModeDriver10.0 툴셋

그리고 서명 도구 `Inf2Cat.exe`, `stampinf.exe` 도 OK 가 된다.

## 그 다음

```powershell
.\scripts\Build-Driver.ps1        # 일반 권한
.\scripts\Sign-Driver.ps1         # 일반 권한 (자체 서명 인증서 생성 + 서명)
.\scripts\Enable-TestSigning.ps1  # 관리자, 이후 재부팅
.\scripts\Install-Driver.ps1      # 관리자, 재부팅 후
```
