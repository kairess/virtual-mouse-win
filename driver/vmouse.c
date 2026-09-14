/*++

Module Name:

    vmouse.c

Abstract:

    가상 HID 마우스 KMDF minidriver 구현.

    이 드라이버는 root\virtualmouse 로 열거되는 소프트웨어 장치 위에
    lower filter 로 붙는다. 스택은 아래와 같다:

        hidclass.sys          (HID 클래스 드라이버)
          mshidkmdf.sys       (HID -> KMDF 패스스루, INF 의 MsHidKmdf.inf 가 설치)
            vmouse.sys        (이 드라이버, lower filter)

    mshidkmdf 가 hidclass 의 IOCTL_HID_* 를 IRP_MJ_INTERNAL_DEVICE_CONTROL 로
    내려주면 우리가 마우스용 디스크립터로 응답한다. hidclass 는 top-level
    collection 의 Usage Page/Usage 를 보고 Generic Desktop(0x01)/Mouse(0x02)
    이므로 mouclass.sys 를 붙이고, 그 결과 이 장치가 GetRawInputDeviceList()
    와 레거시 마우스 API 에 실제 마우스로 노출된다.

Environment:

    Kernel mode. Windows Driver Framework (KMDF).

--*/

#include "vmouse.h"

//
// IOCTL_HID_GET_REPORT_DESCRIPTOR 응답으로 돌려줄 리포트 디스크립터.
//
HID_REPORT_DESCRIPTOR g_MouseReportDescriptor[] = MOUSE_REPORT_DESCRIPTOR;

//
// ReportDescriptor.h 의 크기 매크로가 실제 배열과 어긋나면 빌드를 깬다.
// (디스크립터를 손대고 매크로를 안 고치는 실수를 컴파일 타임에 잡는다.)
//
C_ASSERT(sizeof(g_MouseReportDescriptor) == MOUSE_REPORT_DESCRIPTOR_SIZE);
C_ASSERT(sizeof(MOUSE_INPUT_REPORT) == MOUSE_INPUT_REPORT_SIZE_CB);

//
// IOCTL_HID_GET_DEVICE_DESCRIPTOR 응답으로 돌려줄 HID 디스크립터.
//
HID_DESCRIPTOR g_MouseHidDescriptor = {
    0x09,   // bLength: HID 디스크립터 길이
    0x21,   // bDescriptorType: HID
    0x0100, // bcdHID: HID 1.00
    0x00,   // bCountry: Not Specified
    0x01,   // bNumDescriptors
    {
        0x22,                                       // bReportType: Report
        (USHORT)sizeof(g_MouseReportDescriptor)     // wReportLength
    }
};

NTSTATUS
DriverEntry(
    _In_ PDRIVER_OBJECT  DriverObject,
    _In_ PUNICODE_STRING RegistryPath
    )
/*++
Routine Description:

    드라이버 로드 시 최초로 호출된다. WDF 드라이버 객체를 만들고
    EvtDeviceAdd 콜백을 등록한다.

--*/
{
    WDF_DRIVER_CONFIG config;
    NTSTATUS          status;

    KdPrint(("vmouse: DriverEntry\n"));

    //
    // Windows 8 이상에서 non-executable pool 사용 (POOL_NX_OPTIN=1 필요).
    //
    ExInitializeDriverRuntime(DrvRtPoolNxOptIn);

    WDF_DRIVER_CONFIG_INIT(&config, EvtDeviceAdd);

    status = WdfDriverCreate(DriverObject,
                             RegistryPath,
                             WDF_NO_OBJECT_ATTRIBUTES,
                             &config,
                             WDF_NO_HANDLE);
    if (!NT_SUCCESS(status)) {
        KdPrint(("vmouse: WdfDriverCreate failed 0x%x\n", status));
    }

    return status;
}

NTSTATUS
EvtDeviceAdd(
    _In_    WDFDRIVER       Driver,
    _Inout_ PWDFDEVICE_INIT DeviceInit
    )
/*++
Routine Description:

    PnP 매니저가 root\virtualmouse 장치를 열거할 때 호출된다.
    이 드라이버는 mshidkmdf.sys 아래에 붙는 lower filter 이므로
    WdfFdoInitSetFilter 로 필터임을 선언한다 (전원 정책 소유권도 포기).

--*/
{
    NTSTATUS               status;
    WDF_OBJECT_ATTRIBUTES  deviceAttributes;
    WDFDEVICE              device;
    PDEVICE_CONTEXT        deviceContext;
    PHID_DEVICE_ATTRIBUTES hidAttributes;

    UNREFERENCED_PARAMETER(Driver);

    KdPrint(("vmouse: EvtDeviceAdd\n"));

    WdfFdoInitSetFilter(DeviceInit);

    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&deviceAttributes, DEVICE_CONTEXT);

    status = WdfDeviceCreate(&DeviceInit, &deviceAttributes, &device);
    if (!NT_SUCCESS(status)) {
        KdPrint(("vmouse: WdfDeviceCreate failed 0x%x\n", status));
        return status;
    }

    deviceContext = GetDeviceContext(device);
    deviceContext->Device        = device;
    deviceContext->HidDescriptor = g_MouseHidDescriptor;

    hidAttributes = &deviceContext->HidDeviceAttributes;
    RtlZeroMemory(hidAttributes, sizeof(HID_DEVICE_ATTRIBUTES));
    hidAttributes->Size          = sizeof(HID_DEVICE_ATTRIBUTES);
    hidAttributes->VendorID      = VMOUSE_VID;
    hidAttributes->ProductID     = VMOUSE_PID;
    hidAttributes->VersionNumber = VMOUSE_VERSION;

    status = QueueCreate(device, &deviceContext->DefaultQueue);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    status = ManualQueueCreate(device, &deviceContext->ManualQueue);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    return STATUS_SUCCESS;
}

NTSTATUS
QueueCreate(
    _In_  WDFDEVICE Device,
    _Out_ WDFQUEUE *Queue
    )
/*++
Routine Description:

    hidclass.sys 의 IOCTL 을 처리할 기본 병렬 큐를 만든다.

--*/
{
    NTSTATUS            status;
    WDF_IO_QUEUE_CONFIG queueConfig;
    WDFQUEUE            queue;

    WDF_IO_QUEUE_CONFIG_INIT_DEFAULT_QUEUE(&queueConfig,
                                           WdfIoQueueDispatchParallel);

    queueConfig.EvtIoInternalDeviceControl = EvtIoInternalDeviceControl;

    status = WdfIoQueueCreate(Device,
                              &queueConfig,
                              WDF_NO_OBJECT_ATTRIBUTES,
                              &queue);
    if (!NT_SUCCESS(status)) {
        KdPrint(("vmouse: WdfIoQueueCreate (default) failed 0x%x\n", status));
        return status;
    }

    *Queue = queue;
    return status;
}

NTSTATUS
ManualQueueCreate(
    _In_  WDFDEVICE Device,
    _Out_ WDFQUEUE *Queue
    )
/*++
Routine Description:

    IOCTL_HID_READ_REPORT 를 담아 둘 수동 큐를 만든다.

    vhidmini2 샘플은 여기에 주기 타이머를 걸어 가짜 입력을 만들어내지만,
    이 드라이버는 일부러 그렇게 하지 않는다. 이 장치의 목적은 "존재"이지
    입력이 아니고, 0으로 채운 리포트라도 주기적으로 올리면 시스템 입장에서는
    마우스 활동으로 취급되어 절전/화면보호기 타이머를 계속 리셋시킨다.
    가만히 있는 물리 마우스와 똑같이, 요청을 그냥 대기시켜 둔다.

    큐에 대기 중인 요청은 hidclass 가 취소하거나 장치가 제거되면서 큐가
    purge 될 때 프레임워크가 알아서 STATUS_CANCELLED 로 완료시킨다.

--*/
{
    NTSTATUS            status;
    WDF_IO_QUEUE_CONFIG queueConfig;
    WDFQUEUE            queue;

    WDF_IO_QUEUE_CONFIG_INIT(&queueConfig, WdfIoQueueDispatchManual);

    status = WdfIoQueueCreate(Device,
                              &queueConfig,
                              WDF_NO_OBJECT_ATTRIBUTES,
                              &queue);
    if (!NT_SUCCESS(status)) {
        KdPrint(("vmouse: WdfIoQueueCreate (manual) failed 0x%x\n", status));
        return status;
    }

    *Queue = queue;
    return status;
}

VOID
EvtIoInternalDeviceControl(
    _In_ WDFQUEUE   Queue,
    _In_ WDFREQUEST Request,
    _In_ size_t     OutputBufferLength,
    _In_ size_t     InputBufferLength,
    _In_ ULONG      IoControlCode
    )
/*++
Routine Description:

    hidclass.sys 가 mshidkmdf 를 통해 내려보내는 IOCTL_HID_* 를 처리한다.

    마우스로 열거되기 위해 반드시 성공해야 하는 것은 아래 셋이다:
      IOCTL_HID_GET_DEVICE_DESCRIPTOR
      IOCTL_HID_GET_REPORT_DESCRIPTOR
      IOCTL_HID_GET_DEVICE_ATTRIBUTES
    나머지는 없어도 장치 열거에는 지장이 없다.

--*/
{
    NTSTATUS        status;
    BOOLEAN         completeRequest = TRUE;
    WDFDEVICE       device          = WdfIoQueueGetDevice(Queue);
    PDEVICE_CONTEXT deviceContext   = GetDeviceContext(device);

    UNREFERENCED_PARAMETER(OutputBufferLength);
    UNREFERENCED_PARAMETER(InputBufferLength);

    switch (IoControlCode) {

    case IOCTL_HID_GET_DEVICE_DESCRIPTOR:       // METHOD_NEITHER
        //
        // HID 디스크립터. 여기 담긴 wReportLength 를 보고 hidclass 가
        // 이어서 GET_REPORT_DESCRIPTOR 버퍼 크기를 정한다.
        //
        _Analysis_assume_(deviceContext->HidDescriptor.bLength != 0);
        status = RequestCopyFromBuffer(Request,
                                       &deviceContext->HidDescriptor,
                                       deviceContext->HidDescriptor.bLength);
        break;

    case IOCTL_HID_GET_REPORT_DESCRIPTOR:       // METHOD_NEITHER
        //
        // 마우스 리포트 디스크립터. 이게 이 프로젝트의 핵심이다.
        //
        status = RequestCopyFromBuffer(
                     Request,
                     g_MouseReportDescriptor,
                     deviceContext->HidDescriptor.DescriptorList[0].wReportLength);
        break;

    case IOCTL_HID_GET_DEVICE_ATTRIBUTES:       // METHOD_NEITHER
        //
        // VID/PID/버전. RIDI_DEVICEINFO 의 hid.dwVendorId 등으로 노출된다.
        //
        status = RequestCopyFromBuffer(Request,
                                       &deviceContext->HidDeviceAttributes,
                                       sizeof(HID_DEVICE_ATTRIBUTES));
        break;

    case IOCTL_HID_READ_REPORT:                 // METHOD_NEITHER
        //
        // 입력 리포트 요청. 수동 큐로 넘겨서 계속 대기시킨다.
        //
        status = ReadReport(deviceContext, Request, &completeRequest);
        break;

    case IOCTL_HID_GET_STRING:                  // METHOD_NEITHER
        //
        // 제조사/제품/시리얼 문자열. HidD_GetProductString 등이 쓴다.
        //
        status = GetString(Request);
        break;

    case IOCTL_HID_WRITE_REPORT:                // METHOD_NEITHER
    case IOCTL_HID_GET_FEATURE:                 // METHOD_OUT_DIRECT
    case IOCTL_HID_SET_FEATURE:                 // METHOD_IN_DIRECT
    case IOCTL_HID_GET_INPUT_REPORT:            // METHOD_OUT_DIRECT
    case IOCTL_HID_SET_OUTPUT_REPORT:           // METHOD_IN_DIRECT
    case IOCTL_HID_GET_INDEXED_STRING:          // METHOD_OUT_DIRECT
    case IOCTL_HID_SEND_IDLE_NOTIFICATION_REQUEST:
    case IOCTL_HID_ACTIVATE_DEVICE:
    case IOCTL_HID_DEACTIVATE_DEVICE:
    case IOCTL_GET_PHYSICAL_DESCRIPTOR:
        //
        // 표준 부팅 마우스에는 필요 없는 것들. 구현하지 않는다.
        //
    default:
        status = STATUS_NOT_IMPLEMENTED;
        break;
    }

    if (completeRequest) {
        WdfRequestComplete(Request, status);
    }
}

NTSTATUS
ReadReport(
    _In_ PDEVICE_CONTEXT DeviceContext,
    _In_ WDFREQUEST      Request,
    _Always_(_Out_)
         BOOLEAN        *CompleteRequest
    )
/*++
Routine Description:

    IOCTL_HID_READ_REPORT 를 수동 큐로 넘긴다. 성공하면 호출자는 요청을
    완료하면 안 된다 (큐가 소유권을 가져간다). 실패하면 호출자가 에러로
    즉시 완료해야 한다.

--*/
{
    NTSTATUS status;

    status = WdfRequestForwardToIoQueue(Request, DeviceContext->ManualQueue);
    if (!NT_SUCCESS(status)) {
        KdPrint(("vmouse: WdfRequestForwardToIoQueue failed 0x%x\n", status));
        *CompleteRequest = TRUE;
    } else {
        *CompleteRequest = FALSE;
    }

    return status;
}

NTSTATUS
RequestCopyFromBuffer(
    _In_ WDFREQUEST Request,
    _In_ PVOID      SourceBuffer,
    _When_(NumBytesToCopyFrom == 0, __drv_reportError(NumBytesToCopyFrom cannot be zero))
    _In_ size_t     NumBytesToCopyFrom
    )
/*++
Routine Description:

    요청의 출력 버퍼로 지정한 바이트 수만큼 복사하고 Information 을 세팅한다.

--*/
{
    NTSTATUS  status;
    WDFMEMORY memory;
    size_t    outputBufferLength;

    status = WdfRequestRetrieveOutputMemory(Request, &memory);
    if (!NT_SUCCESS(status)) {
        KdPrint(("vmouse: WdfRequestRetrieveOutputMemory failed 0x%x\n", status));
        return status;
    }

    WdfMemoryGetBuffer(memory, &outputBufferLength);
    if (outputBufferLength < NumBytesToCopyFrom) {
        KdPrint(("vmouse: output buffer too small. size %d, expect %d\n",
                 (int)outputBufferLength, (int)NumBytesToCopyFrom));
        return STATUS_INVALID_BUFFER_SIZE;
    }

    status = WdfMemoryCopyFromBuffer(memory, 0, SourceBuffer, NumBytesToCopyFrom);
    if (!NT_SUCCESS(status)) {
        KdPrint(("vmouse: WdfMemoryCopyFromBuffer failed 0x%x\n", status));
        return status;
    }

    WdfRequestSetInformation(Request, NumBytesToCopyFrom);
    return status;
}

NTSTATUS
GetStringId(
    _In_  WDFREQUEST Request,
    _Out_ ULONG     *StringId,
    _Out_ ULONG     *LanguageId
    )
/*++
Routine Description:

    IOCTL_HID_GET_STRING 에서 문자열 ID 를 꺼낸다.

    hidclass.sys 는 Parameters.DeviceIoControl.InputBufferLength 를 채우지
    않고, 버퍼 "주소" 자리에 값 자체를 넣어 보낸다. 그래서 일반적인
    WdfRequestRetrieveInputMemory 로는 읽을 수 없고 Type3InputBuffer 를
    직접 봐야 한다. (vhidmini2 샘플과 동일한 처리)

--*/
{
    WDF_REQUEST_PARAMETERS requestParameters;
    ULONG                  inputValue;

    WDF_REQUEST_PARAMETERS_INIT(&requestParameters);
    WdfRequestGetParameters(Request, &requestParameters);

    inputValue = PtrToUlong(
        requestParameters.Parameters.DeviceIoControl.Type3InputBuffer);

    //
    // 하위 2바이트 = 문자열 ID, 상위 2바이트 = 언어 ID.
    //
    *StringId   = (inputValue & 0x0ffff);
    *LanguageId = (inputValue >> 16);

    return STATUS_SUCCESS;
}

NTSTATUS
GetString(
    _In_ WDFREQUEST Request
    )
/*++
Routine Description:

    IOCTL_HID_GET_STRING 처리. HidD_GetManufacturerString /
    HidD_GetProductString / HidD_GetSerialNumberString 가 이걸 탄다.

--*/
{
    NTSTATUS status;
    ULONG    languageId, stringId;
    size_t   stringSizeCb;
    PCWSTR   string;

    status = GetStringId(Request, &stringId, &languageId);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    UNREFERENCED_PARAMETER(languageId);

    switch (stringId) {
    case HID_STRING_ID_IMANUFACTURER:
        stringSizeCb = sizeof(VMOUSE_MANUFACTURER_STRING);
        string       = VMOUSE_MANUFACTURER_STRING;
        break;
    case HID_STRING_ID_IPRODUCT:
        stringSizeCb = sizeof(VMOUSE_PRODUCT_STRING);
        string       = VMOUSE_PRODUCT_STRING;
        break;
    case HID_STRING_ID_ISERIALNUMBER:
        stringSizeCb = sizeof(VMOUSE_SERIAL_NUMBER_STRING);
        string       = VMOUSE_SERIAL_NUMBER_STRING;
        break;
    default:
        KdPrint(("vmouse: GetString: unknown string id %d\n", stringId));
        return STATUS_INVALID_PARAMETER;
    }

    return RequestCopyFromBuffer(Request, (PVOID)string, stringSizeCb);
}
