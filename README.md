# virtual-mouse

Sunshine/Moonlight로 Mac → Windows 원격 플레이 중, 게임이 "물리 HID 마우스가 연결되어 있는지"를 확인하고 그 결과에 따라 클릭 입력을 막는 문제를 해결하기 위한 프로젝트.

## 배경

- Mac(Moonlight) → Windows(Sunshine) 원격 플레이 환경.
- 마우스 이동/클릭 자체는 Sunshine의 기존 입력 주입(SendInput 또는 유료 Virtual HID Driver)으로 이미 잘 전달됨.
- 문제는 일부 게임이 `GetRawInputDeviceList()` 등으로 **HID 마우스 장치의 존재 여부**를 먼저 확인하고, 없으면 마우스 입력 자체를 무시/비활성화한다는 점.
- Windows는 실제 디바이스 트리를 반영하기 때문에, 유저모드 프로그램만으로는 "마우스가 꽂혀있다"고 OS를 속일 수 없음 → **가상 HID 버스 드라이버**가 필요.
- 안티치트 없는 싱글플레이 환경이므로 드라이버 테스트 서명(test-signing) 모드 사용은 허용 가능.

### 문제 확인됨

이 머신에서 실제로 측정한 설치 전 기준선:

```
> vmousectl rawinput
GetRawInputDeviceList reports 3 device(s):
  [HID] \\?\Microsoft HID RID\000D_0002\1
  [HID] \\?\Microsoft HID RID\000D_0004\0
  [HID] \\?\HID#VID_0B05&PID_18F3&MI_02#...
Summary: 0 mouse device(s) visible to RawInput
```

`RIM_TYPEMOUSE` 장치가 **0개**다. 게임이 마우스를 못 찾는 게 당연한 상태.

## 목표

Windows에 "HID-compliant mouse"로 열거되는 **더미 가상 마우스 장치**를 하나 상주시킨다.
- 실제 이동/클릭 데이터를 흘려보낼 필요는 없음 (리포트를 아예 올리지 않음).
- 목적은 오직 "마우스 장치 존재 여부 체크"를 통과시키는 것.
- 실제 커서 이동/클릭은 지금처럼 Sunshine 경로로 계속 처리됨.

## 구조

Microsoft 공식 WDK 샘플 [`Windows-driver-samples/hid/vhidmini2`](https://github.com/microsoft/Windows-driver-samples/tree/main/hid/vhidmini2)
(KMDF 버전, MIT)의 구조를 따르되, 벤더 정의 컬렉션 / feature 리포트 / 레지스트리
디스크립터 로딩 / 가짜 입력 타이머 같은 불필요한 부분을 전부 걷어낸 최소 구현이다.

```
hidclass.sys          HID 클래스 드라이버
  mshidkmdf.sys       HID -> KMDF 패스스루 (MsHidKmdf.inf, Windows 11 인박스)
    vmouse.sys        이 프로젝트. lower filter 로 붙는다.
```

`root\virtualmouse` 라는 소프트웨어 열거 장치를 만들고, 그 위에 위 스택을 올린다.
`vmouse.sys` 가 `IOCTL_HID_GET_REPORT_DESCRIPTOR` 에 마우스 디스크립터로 답하면
hidclass 가 top-level collection 의 Usage Page 0x01 / Usage 0x02 를 보고
`mouclass.sys` 를 붙이고, 그 결과 `GetRawInputDeviceList()` 와 레거시 마우스 API에
정상적인 마우스로 노출된다.

## 파일

| 경로 | 설명 |
|---|---|
| `driver/ReportDescriptor.h` | HID 리포트 디스크립터 (3버튼 + 상대 X/Y + 휠, 리포트 ID 없음, 52바이트) |
| `driver/vmouse.h` / `vmouse.c` | KMDF HID minidriver 구현 |
| `driver/vmouse.inx` | INF 템플릿 (빌드 시 stampinf 가 `vmouse.inf` 로 변환) |
| `driver/vmouse.vcxproj` | 드라이버 MSBuild 프로젝트 (WDK 필요) |
| `tools/vmousectl/vmousectl.c` | 설치/제거/상태확인/RawInput 검증 CLI (SDK만 필요) |
| `tools/descheck/descheck.c` | 리포트 디스크립터 검증기. 빌드할 때마다 자동 실행 (SDK만 필요) |
| `scripts/*.ps1` | 환경확인 · WDK 툴셋 · 빌드 · 서명 · 설치 · 제거 |
| `docs/install-wdk.md` | WDK 설치 방법 |
| `docs/troubleshooting.md` | 증상별 원인/해결 |

## 현재 진행 상태

- [x] 리포트 디스크립터 설계 (`driver/ReportDescriptor.h`) — 크기 매크로 오류(50→52) 및
      쓰이지 않는 `ReportId` 필드 수정, `descheck` 로 **검증 통과**
- [x] KMDF 드라이버 소스 작성 (`driver/vmouse.c`)
- [x] INF 작성 (`driver/vmouse.inx`, `root\virtualmouse`)
- [x] 드라이버 MSBuild 프로젝트 작성
- [x] 빌드/서명/설치/제거 스크립트 작성
- [x] 검증 도구 작성 및 **빌드·실행 완료** (`vmousectl`)
- [x] 설치 전 기준선 측정 (마우스 0개 — 문제 재현됨)
- [x] WDK 설치 + 드라이버 플랫폼 툴셋(`Install-WdkToolset.ps1`)
- [x] **드라이버 빌드 성공** — 오류 0, 경고 0, Inf2Cat signability 통과
- [x] **자체 서명 완료** — `vmouse.sys` 임베디드 서명 + `vmouse.cat` 카탈로그 서명
- [x] 테스트 서명 모드 활성화 + 재부팅
- [x] 설치 완료 — devnode `started: yes / problem: none`
- [x] **설치 후 검증 통과** — RawInput 마우스 0개 → 1개

**완료.** 2026-09-14 기준 이 머신에서 실제로 동작 확인됨.

빌드 산출물은 `dist\x64\` 에 있다 (`vmouse.sys`, `vmouse.inf`, `vmouse.cat`, `vmouse.cer`).
INF 는 `NTamd64.10.0...22000` 으로 정상 스탬프됐고 KMDF 1.15 로 링크됐다.

### 설치 후 실측 결과

```
> vmousectl status
=== virtual mouse devnode #1 ===
  started : yes
  problem : none
  device tree (children are created by hidclass/mouclass):
    - Virtual HID Mouse
      ROOT\HIDCLASS\0000
    - HID 규격 마우스                       <- hidclass/mouclass 가 만든 자식
        HID\HIDCLASS\1&2D595CA7&0&0000

> vmousectl rawinput
  [MOUSE   ] <<< VIRTUAL MOUSE
      \\?\HID#HIDCLASS#1&2d595ca7&0&0000#{378de44c-56ef-11d1-bc8c-00a0c91405dd}
      id=256 buttons=3 sampleRate=0 hWheel=no

Summary: 1 mouse device(s) visible to RawInput, 1 of them the virtual mouse.
RESULT: PASS - a game calling GetRawInputDeviceList() will see a mouse.
```

`buttons=3` 은 디스크립터의 Button 1..3 이 그대로 반영된 것이다.
`{378de44c-...}` 는 `GUID_DEVINTERFACE_MOUSE` 다.

한 가지 알아둘 점: hidclass 는 root-enumerated 장치의 자식 인스턴스 경로를
`HID\VID_FEED&PID_0001\...` 이 아니라 **`HID\HIDCLASS\...`** 로 짓는다.
VID/PID 는 `RIDI_DEVICEINFO` 나 `HidD_GetAttributes` 로는 나오지만 경로에는
들어가지 않는다. 그래서 `vmousectl rawinput` 은 VID/PID 문자열이 아니라
실제 PnP 트리(devnode 의 자손 인스턴스 ID)와 대조해서 자기 장치를 알아본다.

## 시작하기

### 0. 환경 확인

```powershell
.\scripts\Check-Environment.ps1
```

### 1. 검증 도구 빌드 (WDK 불필요, 지금 바로 가능)

```powershell
.\scripts\Build-Tool.ps1
.\build\x64\Release\vmousectl.exe rawinput
```

설치 전 기준선을 먼저 찍어 두면 나중에 비교가 된다.

### 2. WDK 설치 (관리자 권한)

```powershell
winget install --id Microsoft.WindowsWDK.10.0.22621 --exact
```

설치된 SDK(`10.0.22621.0`)와 **같은 버전**이어야 한다.

이 머신은 full Visual Studio 가 아니라 **Build Tools** 라서, WDK 본체를 깔아도
드라이버 플랫폼 툴셋이 따라 들어오지 않는다 (`WDK.vsix` 가 Build Tools 를
설치 대상으로 선언하지 않아 VSIXInstaller 가 코드 2003 으로 거부한다).
한 단계가 더 필요하다:

```powershell
.\scripts\Install-WdkToolset.ps1      # 관리자 권한
```

자세한 건 [`docs/install-wdk.md`](docs/install-wdk.md).

### 3. 빌드 + 서명 (일반 권한)

```powershell
.\scripts\Build-Driver.ps1
.\scripts\Sign-Driver.ps1
```

### 4. 테스트 서명 모드 (관리자 권한 → 재부팅)

```powershell
.\scripts\Enable-TestSigning.ps1
Restart-Computer
```

> **Secure Boot 가 켜져 있으면 test signing 은 무시된다.** 이 머신은 확인 결과
> 이미 꺼져 있으므로(`UEFISecureBootEnabled = 0`) UEFI 설정에 들어갈 필요 없다.
> 다른 머신에서 쓴다면 `Check-Environment.ps1` 의 Secure Boot 항목을 먼저 볼 것.

### 5. 설치 + 검증 (관리자 권한)

```powershell
.\scripts\Install-Driver.ps1
```

성공하면 `vmousectl rawinput` 이 이렇게 나온다:

```
  [MOUSE   ] <<< VIRTUAL MOUSE
      \\?\HID#HIDCLASS#1&...#{378de44c-56ef-11d1-bc8c-00a0c91405dd}
      id=256 buttons=3 sampleRate=0 hWheel=no

Summary: 1 mouse device(s) visible to RawInput, 1 of them the virtual mouse.
RESULT: PASS - a game calling GetRawInputDeviceList() will see a mouse.
```

### 되돌리기

```powershell
.\scripts\Uninstall-Driver.ps1 -RemoveCertificate
.\scripts\Enable-TestSigning.ps1 -Disable
```

## 주의

- 이 드라이버는 **테스트 서명 전용**이다. 자체 서명 인증서로 서명하므로
  test signing 모드 + Secure Boot 해제 상태에서만 로드된다.
- 커널 드라이버다. 문제가 생기면 부팅이 안 될 수도 있다. 시스템 복원 지점을
  먼저 만들어 두는 것을 권장한다.
- 안티치트가 있는 게임에서는 쓰지 말 것. 이 프로젝트는 싱글플레이 원격
  플레이 환경을 전제로 한다.
