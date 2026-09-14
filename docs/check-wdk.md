# Windows 빌드 환경 확인

> 이 문서의 수동 확인 절차는 **`scripts\Check-Environment.ps1` 로 자동화됐다.**
> 먼저 그것을 실행할 것:
>
> ```powershell
> .\scripts\Check-Environment.ps1
> ```
>
> WDK 가 빠져 있다면 [`install-wdk.md`](install-wdk.md) 로 간다.
> 아래는 스크립트가 무엇을 어떻게 판정하는지에 대한 설명이다.

## 1. Visual Studio / MSVC

`vswhere.exe` 로 C++ 툴셋이 있는 인스턴스를 찾는다:

```powershell
& "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" `
    -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath
```

레지스트리(`HKLM:\SOFTWARE\Microsoft\VisualStudio\*`)를 보는 방식은 VS 2017 이후
신뢰할 수 없다. `vswhere` 가 공식 방법이다.

full Visual Studio 가 아니라 **Build Tools** 만 있어도 빌드는 된다.
(이 머신이 그 경우다.)

## 2. WDK

**중요: `Windows Kits\10` 폴더가 있다고 WDK 가 설치된 게 아니다.**
SDK 만 설치해도 그 폴더는 생긴다. 실제로 구분하려면 WDK 에만 있는 것을 봐야 한다:

| 확인 대상 | 경로 |
|---|---|
| 커널 헤더 | `Windows Kits\10\Include\<ver>\km\wdm.h` |
| KMDF 헤더 | `Windows Kits\10\Include\wdf\kmdf\<ver>\` |
| MSBuild 타겟 | `Windows Kits\10\build\` |
| 카탈로그 도구 | `Windows Kits\10\bin\<ver>\x86\Inf2Cat.exe` |
| INF 스탬프 도구 | `Windows Kits\10\bin\<ver>\x86\stampinf.exe` |

이 머신은 SDK `10.0.22621.0` 만 있고 위 항목이 전부 없었다.

## 3. 드라이버 플랫폼 툴셋 (VSIX)

WDK 본체와 별개로, MSBuild 가 드라이버 프로젝트를 빌드하려면
`WindowsKernelModeDriver10.0` 플랫폼 툴셋이 VS 인스턴스 안에 있어야 한다:

```
<VS설치경로>\MSBuild\Microsoft\VC\v170\Platforms\x64\PlatformToolsets\WindowsKernelModeDriver10.0
```

이건 WDK 인스톨러 마지막의 `WDK.vsix` 가 넣어준다. 체크를 빼먹으면
WDK 헤더는 다 있는데 프로젝트가 안 열리는 상황이 된다.

## 4. 설치 전제조건 (관리자 권한 필요)

```powershell
bcdedit /enum '{current}' | Select-String testsigning   # Yes 여야 함
Confirm-SecureBootUEFI                                   # False 여야 함
```

Secure Boot 가 `True` 면 test signing 을 켜도 **무시된다.** 이게 자체 서명
드라이버가 코드 52 로 실패하는 가장 흔한 원인이다.

## 5. 참고 샘플

이 프로젝트는 `hid/vhidmini2` 를 뼈대로 삼았다. 원본을 보고 싶으면:

```powershell
git clone --depth 1 --filter=blob:none --sparse https://github.com/microsoft/Windows-driver-samples.git
cd Windows-driver-samples
git sparse-checkout set hid/vhidmini2
```

전체 저장소는 매우 크므로 위처럼 sparse checkout 을 쓰는 게 좋다.
