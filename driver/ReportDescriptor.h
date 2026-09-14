// ReportDescriptor.h
//
// 표준 3버튼 + 상대좌표 X/Y + 휠을 갖는 최소 HID 마우스 리포트 디스크립터.
// vhidmini2 샘플(Windows-driver-samples/hid/vhidmini2)의 기존 조이스틱형
// 디스크립터를 이걸로 교체해서 사용한다.
//
// 핵심 포인트: top-level collection이
//   Usage Page = Generic Desktop (0x01)
//   Usage      = Mouse           (0x02)
// 이어야 mouclass.sys / hidclass.sys가 이 장치를
// "HID-compliant mouse"로 자동 바인딩하고, RawInput/레거시 마우스 API에
// 정상적인 마우스 장치로 노출된다.
//
// 이 프로젝트의 목적상 실제로 0이 아닌 리포트를 보낼 필요는 없다 —
// 장치가 "존재"하기만 하면 게임의 "마우스 연결됨" 체크를 통과시키는 게
// 목표이고, 실제 커서 이동/클릭은 기존 Sunshine 입력 경로가 담당한다.

#pragma once

#include <hidpddi.h> // vhidmini2 샘플과 동일한 HID minidriver 헤더 세트 기준

//
// 입력 리포트 레이아웃 (총 4바이트)
//
//   byte 0 : bit0 = Button1(Left), bit1 = Button2(Right), bit2 = Button3(Middle)
//            bit3~7 = 미사용 (0으로 패딩)
//   byte 1 : X  (relative, signed, -127..127)
//   byte 2 : Y  (relative, signed, -127..127)
//   byte 3 : Wheel (relative, signed, -127..127)
//
// 더미 장치로만 쓸 거라면 이 구조체는 항상 전부 0으로 채워서 보내면 된다.
//
#include <pshpack1.h>
typedef struct _MOUSE_REPORT
{
    UCHAR ReportId;   // 리포트 ID를 안 쓰면 이 필드는 생략 가능 (아래 디스크립터는 ID 없음 버전)
    UCHAR Buttons;    // 하위 3비트만 사용
    CHAR  X;
    CHAR  Y;
    CHAR  Wheel;
} MOUSE_REPORT, *PMOUSE_REPORT;
#include <poppack.h>

//
// HID 리포트 디스크립터 (리포트 ID 없음, 단일 리포트)
//
#define MOUSE_REPORT_DESCRIPTOR                                            \
{                                                                          \
    0x05, 0x01,        /* Usage Page (Generic Desktop Ctrls)          */  \
    0x09, 0x02,        /* Usage (Mouse)                               */  \
    0xA1, 0x01,        /* Collection (Application)                    */  \
    0x09, 0x01,        /*   Usage (Pointer)                           */  \
    0xA1, 0x00,        /*   Collection (Physical)                     */  \
    0x05, 0x09,        /*     Usage Page (Button)                     */  \
    0x19, 0x01,        /*     Usage Minimum (Button 1)                */  \
    0x29, 0x03,        /*     Usage Maximum (Button 3)                */  \
    0x15, 0x00,        /*     Logical Minimum (0)                     */  \
    0x25, 0x01,        /*     Logical Maximum (1)                     */  \
    0x95, 0x03,        /*     Report Count (3)                        */  \
    0x75, 0x01,        /*     Report Size (1)                         */  \
    0x81, 0x02,        /*     Input (Data,Var,Abs) -- 3 button bits   */  \
    0x95, 0x01,        /*     Report Count (1)                        */  \
    0x75, 0x05,        /*     Report Size (5)                         */  \
    0x81, 0x03,        /*     Input (Const,Var,Abs) -- 5 bit padding  */  \
    0x05, 0x01,        /*     Usage Page (Generic Desktop Ctrls)      */  \
    0x09, 0x30,        /*     Usage (X)                               */  \
    0x09, 0x31,        /*     Usage (Y)                               */  \
    0x09, 0x38,        /*     Usage (Wheel)                           */  \
    0x15, 0x81,        /*     Logical Minimum (-127)                  */  \
    0x25, 0x7F,        /*     Logical Maximum (127)                   */  \
    0x75, 0x08,        /*     Report Size (8)                         */  \
    0x95, 0x03,        /*     Report Count (3)                        */  \
    0x81, 0x06,        /*     Input (Data,Var,Rel) -- X, Y, Wheel     */  \
    0xC0,              /*   End Collection                            */  \
    0xC0,              /* End Collection                              */  \
}

// 위 배열의 바이트 길이 (디스크립터 등록 시 필요)
#define MOUSE_REPORT_DESCRIPTOR_SIZE 50

// 참고: byte 단위로 세어보면 실제로는 아래와 같음.
//   총 항목 수 = 위 배열의 원소 개수. 포팅 시 sizeof(g_MouseReportDescriptor)로
//   다시 계산해서 이 매크로 값과 맞는지 반드시 확인할 것.
