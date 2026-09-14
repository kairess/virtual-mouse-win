# Windows 빌드 환경 확인 (Visual Studio + WDK)

Windows 머신에서 아래를 순서대로 확인하세요.

## 1. Visual Studio 설치 확인

PowerShell에서:

```powershell
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\VisualStudio\*" -ErrorAction SilentlyContinue |
  Select-Object DisplayName, InstallLocation
```

또는 그냥 시작 메뉴에서 "Visual Studio Installer"가 있는지 확인.

없다면: [Visual Studio 설치](https://visualstudio.microsoft.com/downloads/) (Community 버전 무료)에서
워크로드 "Desktop development with C++"를 선택해 설치.

## 2. WDK(Windows Driver Kit) 설치 확인

PowerShell에서:

```powershell
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots" -ErrorAction SilentlyContinue
```

또는 시작 메뉴에서 "Windows Driver Kit"가 보이는지 확인.

없다면: [WDK 다운로드 페이지](https://learn.microsoft.com/windows-hardware/drivers/download-the-wdk)에서
**"Windows Driver Kit"** 를 받아 설치. 순서 중요:

1. Visual Studio 먼저 설치 (Desktop C++ 워크로드 포함)
2. Visual Studio에서 "Windows SDK" 최신 버전 설치 확인
3. 그 다음 WDK 설치 (WDK installer가 VS를 자동 감지해서 확장으로 통합됨)

## 3. 설치 후 확인

Visual Studio를 열고 새 프로젝트 생성 화면에서 "Driver" 카테고리(예: "Kernel Mode Driver, Empty (KMDF)",
"User Mode Driver, Empty (UMDF 2)")가 목록에 뜨면 정상 설치된 것입니다.

## 4. 준비되면

`Windows-driver-samples` 저장소를 클론해서 `hid/vhidmini2` 샘플을 엽니다:

```powershell
git clone https://github.com/microsoft/Windows-driver-samples.git
```

`hid/vhidmini2/sys` 프로젝트를 Visual Studio로 열고 원래 리포트 디스크립터가 정의된 소스 파일을
`../driver/ReportDescriptor.h`의 내용으로 교체하는 게 다음 단계입니다.
