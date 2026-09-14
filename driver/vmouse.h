/*++

Module Name:

    vmouse.h

Abstract:

    가상 HID 마우스 KMDF minidriver 의 타입 정의.

    Microsoft WDK 샘플 Windows-driver-samples/hid/vhidmini2 (KMDF 버전)의
    구조를 그대로 따르되, 벤더 정의 컬렉션 / feature 리포트 / 레지스트리
    디스크립터 로딩 같이 이 프로젝트에 필요 없는 부분은 전부 걷어냈다.

Environment:

    Kernel mode. Windows Driver Framework (KMDF).

--*/

#pragma once

#include <ntddk.h>
#include <wdf.h>
#include <hidport.h>

#include "ReportDescriptor.h"

typedef UCHAR HID_REPORT_DESCRIPTOR, *PHID_REPORT_DESCRIPTOR;

//
// IOCTL_HID_GET_DEVICE_ATTRIBUTES 로 보고할 장치 속성.
// 실제 벤더와 충돌하지 않도록 의도적으로 존재하지 않는 VID 를 쓴다.
// (실제 VID 를 흉내내면 해당 벤더용 필터 드라이버가 붙을 수 있다.)
//
#define VMOUSE_VID              0xFEED
#define VMOUSE_PID              0x0001
#define VMOUSE_VERSION          0x0100

#define VMOUSE_MANUFACTURER_STRING  L"virtual-mouse"
#define VMOUSE_PRODUCT_STRING       L"Virtual HID Mouse"
#define VMOUSE_SERIAL_NUMBER_STRING L"0000"

typedef struct _DEVICE_CONTEXT
{
    WDFDEVICE               Device;

    //
    // hidclass.sys 에서 오는 IOCTL 을 처리하는 기본 큐.
    //
    WDFQUEUE                DefaultQueue;

    //
    // IOCTL_HID_READ_REPORT 를 보관해 두는 수동 큐.
    // 더미 장치라 입력이 영원히 발생하지 않으므로 여기 들어온 요청은
    // 장치가 제거되거나 hidclass 가 취소할 때까지 그냥 대기한다.
    // (물리 마우스가 가만히 있을 때와 정확히 같은 동작이다.)
    //
    WDFQUEUE                ManualQueue;

    HID_DEVICE_ATTRIBUTES   HidDeviceAttributes;
    HID_DESCRIPTOR          HidDescriptor;

} DEVICE_CONTEXT, *PDEVICE_CONTEXT;

WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(DEVICE_CONTEXT, GetDeviceContext)

DRIVER_INITIALIZE                           DriverEntry;
EVT_WDF_DRIVER_DEVICE_ADD                   EvtDeviceAdd;
EVT_WDF_IO_QUEUE_IO_INTERNAL_DEVICE_CONTROL EvtIoInternalDeviceControl;

NTSTATUS
QueueCreate(
    _In_  WDFDEVICE         Device,
    _Out_ WDFQUEUE         *Queue
    );

NTSTATUS
ManualQueueCreate(
    _In_  WDFDEVICE         Device,
    _Out_ WDFQUEUE         *Queue
    );

NTSTATUS
ReadReport(
    _In_  PDEVICE_CONTEXT   DeviceContext,
    _In_  WDFREQUEST        Request,
    _Always_(_Out_)
          BOOLEAN          *CompleteRequest
    );

NTSTATUS
GetString(
    _In_  WDFREQUEST        Request
    );

NTSTATUS
GetStringId(
    _In_  WDFREQUEST        Request,
    _Out_ ULONG            *StringId,
    _Out_ ULONG            *LanguageId
    );

NTSTATUS
RequestCopyFromBuffer(
    _In_  WDFREQUEST        Request,
    _In_  PVOID             SourceBuffer,
    _When_(NumBytesToCopyFrom == 0, __drv_reportError(NumBytesToCopyFrom cannot be zero))
    _In_  size_t            NumBytesToCopyFrom
    );
