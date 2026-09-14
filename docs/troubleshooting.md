# 트러블슈팅

먼저 상태를 본다:

```powershell
.\build\x64\Release\vmousectl.exe status
.\build\x64\Release\vmousectl.exe rawinput
```

`status` 가 찍는 `problem` 값이 대부분의 경우 원인을 바로 알려준다.

---

## `rawinput` 이 마우스를 0개로 보고한다 (드라이버 설치 전)

정상이다. 이 프로젝트가 해결하려는 바로 그 상태다.
실제로 이 머신의 설치 전 기준선이 그랬다:

```
GetRawInputDeviceList reports 3 device(s):
  [HID] \\?\Microsoft HID RID\000D_0002\1
  [HID] \\?\Microsoft HID RID\000D_0004\0
  [HID] \\?\HID#VID_0B05&PID_18F3&MI_02#...
Summary: 0 mouse device(s) visible to RawInput
```

마우스 타입(`RIM_TYPEMOUSE`) 장치가 하나도 없다. 게임이
`GetRawInputDeviceList()` 로 마우스를 찾으면 못 찾는다.
설치 후 이 숫자가 1 이상이 되고 `<<< VIRTUAL MOUSE` 표시가 붙어야 성공이다.

---

## CM_PROB_DRIVER_FAILED_LOAD (코드 52) — "디지털 서명을 확인할 수 없습니다"

커널이 드라이버 서명을 거부했다. 순서대로 확인한다.

1. **Secure Boot 가 켜져 있는가?**
   Secure Boot 가 켜져 있으면 `testsigning` 플래그는 **무시된다.**
   이게 가장 흔한 원인이다.
   ```powershell
   Confirm-SecureBootUEFI      # 관리자 권한 필요
   ```
   `True` 면 UEFI 펌웨어 설정에서 Secure Boot 를 끈다.

2. **test signing 이 실제로 켜져 있는가?**
   ```powershell
   bcdedit /enum '{current}' | Select-String testsigning
   ```
   `Yes` 가 아니면 `.\scripts\Enable-TestSigning.ps1` 실행 후 **재부팅**.
   재부팅을 안 하면 적용되지 않는다.

3. **인증서가 신뢰 저장소에 들어갔는가?**
   ```powershell
   Get-ChildItem Cert:\LocalMachine\Root, Cert:\LocalMachine\TrustedPublisher |
       Where-Object Subject -eq 'CN=virtual-mouse test signing'
   ```
   두 저장소 모두에 있어야 한다. 없으면 `Install-Driver.ps1` 을 다시 돌린다.

4. **서명 자체가 유효한가?**
   ```powershell
   $st = (Get-ChildItem "C:\Program Files (x86)\Windows Kits\10\bin" -Recurse -Filter signtool.exe |
          Where-Object { $_.Directory.Name -eq 'x64' } | Select-Object -First 1).FullName
   & $st verify /v /kp /c .\dist\x64\vmouse.cat .\dist\x64\vmouse.sys
   ```

---

## CM_PROB_NOT_CONFIGURED (코드 28) — 드라이버가 설치되지 않음

INF 가 `root\virtualmouse` 하드웨어 ID 에 매칭되지 않았다.

- INF 의 Models 섹션이 `NT$ARCH$.10.0...22000` 으로 데코레이션되어 있다.
  Windows 빌드가 22000 미만이면 매칭되지 않는다.
  ```powershell
  [System.Environment]::OSVersion.Version.Build
  ```
- `stampinf` 가 `$ARCH$` 를 치환했는지 확인한다. `dist\x64\vmouse.inf` 를 열어
  `NT$ARCH$` 가 아니라 `NTamd64` 로 바뀌어 있어야 한다.
- setupapi 로그를 본다: `C:\Windows\INF\setupapi.dev.log` 의 마지막 부분.

---

## CM_PROB_FAILED_START (코드 10) — 드라이버가 시작되지 않음

드라이버는 로드됐는데 `DriverEntry` / `EvtDeviceAdd` 가 실패했다.

[DebugView](https://learn.microsoft.com/sysinternals/downloads/debugview) 를
관리자로 띄우고 *Capture Kernel* 을 켜면 `vmouse:` 로 시작하는 로그가 보인다.
(체크드 빌드가 아니어도 `KdPrint` 는 Debug 구성에서 출력된다. Release 로
빌드했다면 `-Configuration Debug` 로 다시 빌드할 것.)

---

## 장치는 정상인데 RawInput 에 마우스로 안 잡힌다

`vmousectl status` 에 자식으로 "HID-compliant mouse" 가 보이는지 확인한다.

- **자식이 아예 없다** → hidclass 가 리포트 디스크립터를 파싱하지 못했다.
  `IOCTL_HID_GET_REPORT_DESCRIPTOR` 응답 길이가 HID 디스크립터의
  `wReportLength` 와 정확히 같아야 한다. `driver/ReportDescriptor.h` 의
  `MOUSE_REPORT_DESCRIPTOR_SIZE` 는 `vmouse.c` 의 `C_ASSERT` 가 검증하므로
  빌드가 됐다면 이쪽은 맞다.
- **HID 장치로는 보이는데 마우스가 아니다** → top-level collection 이
  Usage Page 0x01 / Usage 0x02 가 아니다. 디스크립터 첫 4바이트가
  `05 01 09 02` 인지 확인한다.
- **`Summary:` 에 마우스는 1개인데 `none of them the virtual mouse` 라고 한다**
  → `vmousectl rawinput` 은 `root\virtualmouse` devnode 의 자손 인스턴스 ID 를
  모아 RawInput 장치 경로와 대조한다. `vmousectl status` 의 트리에 자식이
  보이는데도 매칭이 안 되면, 경로 정규화(`\\?\` 제거, `#`→`\`, `#{GUID}` 절단)가
  새 Windows 빌드의 경로 형식과 어긋난 것이다. `status` 가 찍는 자식 ID 와
  `rawinput` 이 찍는 경로를 나란히 놓고 비교할 것.
  (참고: 예전 버전은 `VID_FEED&PID_0001` 문자열로 찾았는데, hidclass 가
  root-enumerated 자식 경로를 `HID\HIDCLASS\...` 로 지어서 항상 실패했다.)

---

## 설치했는데 커서가 움직이거나 절전이 안 걸린다

이 드라이버는 입력 리포트를 **절대** 올리지 않도록 만들어져 있다
(`ManualQueueCreate` 주석 참고). 그래도 증상이 있다면 이 드라이버가 아니라
Sunshine 쪽 입력 주입을 의심할 것.

---

## 깨끗하게 되돌리기

```powershell
# 관리자 권한
.\scripts\Uninstall-Driver.ps1 -RemoveCertificate
.\scripts\Enable-TestSigning.ps1 -Disable
# 재부팅
```
