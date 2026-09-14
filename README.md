# virtual-mouse

Sunshine/Moonlight로 Mac → Windows 원격 플레이 중, 게임이 "물리 HID 마우스가 연결되어 있는지"를 확인하고 그 결과에 따라 클릭 입력을 막는 문제를 해결하기 위한 프로젝트.

## 배경

- Mac(Moonlight) → Windows(Sunshine) 원격 플레이 환경.
- 마우스 이동/클릭 자체는 Sunshine의 기존 입력 주입(SendInput 또는 유료 Virtual HID Driver)으로 이미 잘 전달됨.
- 문제는 일부 게임이 `GetRawInputDeviceList()` 등으로 **HID 마우스 장치의 존재 여부**를 먼저 확인하고, 없으면 마우스 입력 자체를 무시/비활성화한다는 점.
- Windows는 실제 디바이스 트리를 반영하기 때문에, 유저모드 프로그램만으로는 "마우스가 꽂혀있다"고 OS를 속일 수 없음 → **가상 HID 버스 드라이버**가 필요.
- 안티치트 없는 싱글플레이 환경이므로 드라이버 테스트 서명(test-signing) 모드 사용은 허용 가능.

## 목표

Windows에 "HID-compliant mouse"로 열거되는 **더미 가상 마우스 장치**를 하나 상주시킨다.
- 실제 이동/클릭 데이터를 흘려보낼 필요는 없음 (전부 0인 빈 리포트만 유지해도 됨).
- 목적은 오직 "마우스 장치 존재 여부 체크"를 통과시키는 것.
- 실제 커서 이동/클릭은 지금처럼 Sunshine 경로로 계속 처리됨.

## 접근 방식

Microsoft 공식 WDK 샘플인 [`Windows-driver-samples/hid/vhidmini2`](https://github.com/microsoft/Windows-driver-samples/tree/main/hid/vhidmini2) (UMDF2, MIT 라이선스)를 뼈대로 삼아,
샘플의 리포트 디스크립터를 표준 3버튼 상대좌표 마우스용으로 교체한 최소 가상 HID 마우스 드라이버를 직접 작성한다.

- `hidclass.sys` / `mouclass.sys`는 top-level collection의 Usage Page가 Generic Desktop(0x01), Usage가 Mouse(0x02)인 HID 장치를 자동으로 "HID-compliant mouse"로 바인딩한다.
- 이 조건만 만족하면 `RIDI_DEVICEINFO`/`GetRawInputDeviceList()`에 정상적인 마우스 장치로 잡힌다.

## 현재 진행 상태

- [x] 리포트 디스크립터 설계 (`driver/ReportDescriptor.h`)
- [ ] Windows 빌드 환경(Visual Studio + WDK) 확인
- [ ] vhidmini2 샘플 포팅 / INF 작성
- [ ] 드라이버 빌드 및 자체 서명
- [ ] 테스트 서명 모드 활성화 + 설치
- [ ] Windows에서 마우스 장치로 열거되는지 검증

## 다음 단계

1. Windows 머신에서 `docs/check-wdk.md`를 따라 Visual Studio + WDK 설치 여부 확인
2. 확인되면 vhidmini2 샘플을 받아 `driver/ReportDescriptor.h`의 디스크립터로 교체
3. INF 파일 작성 (하드웨어 ID: `root\virtualmouse` 같은 소프트웨어 열거 장치로 설치)
4. 빌드 → 자체 서명 → `bcdedit /set testsigning on` → 설치 → Device Manager에서 "HID-compliant mouse"로 보이는지 확인
