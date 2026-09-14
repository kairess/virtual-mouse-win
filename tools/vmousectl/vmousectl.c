/*
 * vmousectl.c
 *
 * Control and verification tool for the virtual HID mouse driver.
 *
 *   vmousectl install <path-to-vmouse.inf>
 *       Creates the root\virtualmouse devnode and installs the driver on it.
 *       This is the "devcon install" operation; having it here means the
 *       project does not depend on devcon.exe being present.
 *
 *   vmousectl remove
 *       Removes every root\virtualmouse devnode.
 *
 *   vmousectl status
 *       Shows the devnode, its PnP status, and its children (the HID
 *       collection and the mouse device that hidclass/mouclass create).
 *
 *   vmousectl rawinput
 *       Dumps GetRawInputDeviceList() the same way a game would, so you can
 *       confirm the virtual mouse is actually visible through RawInput.
 *
 * Output is deliberately ASCII-only: the Windows console codepage varies by
 * locale and mojibake in a verification tool defeats its purpose.
 *
 * Build: scripts\Build-Tool.ps1   (Windows SDK only, no WDK required)
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <setupapi.h>
#include <newdev.h>
#include <cfgmgr32.h>
#include <stdio.h>
#include <stdlib.h>
#include <locale.h>
#include <wchar.h>

#pragma comment(lib, "setupapi.lib")
#pragma comment(lib, "newdev.lib")
#pragma comment(lib, "cfgmgr32.lib")
#pragma comment(lib, "advapi32.lib")   // OpenProcessToken, GetTokenInformation
#pragma comment(lib, "user32.lib")     // GetRawInputDeviceList, GetRawInputDeviceInfoW

//
// Must match driver/vmouse.inx.
//
#define VMOUSE_HARDWARE_ID   L"root\\virtualmouse"

//
// Instance IDs of the root\virtualmouse devnode(s) and everything below them
// (the HID collection hidclass creates, the mouse device mouclass creates).
// This is how 'rawinput' decides whether a RawInput device is ours: the
// RawInput device name embeds the instance path, so we compare against the
// real PnP tree instead of guessing at a VID/PID substring. (hidclass names
// the child of a root-enumerated device HID\HIDCLASS\..., not HID\VID_...,
// which is exactly the guess that would have been wrong.)
//
#define MAX_VMOUSE_IDS 32
typedef struct _VMOUSE_IDS {
    WCHAR ids[MAX_VMOUSE_IDS][MAX_DEVICE_ID_LEN];
    int   count;
} VMOUSE_IDS;

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

static void PrintLastError(const char *what)
{
    DWORD  err = GetLastError();
    LPWSTR msg = NULL;

    FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
                       FORMAT_MESSAGE_IGNORE_INSERTS,
                   NULL, err, 0, (LPWSTR)&msg, 0, NULL);

    fprintf(stderr, "ERROR: %s failed (0x%08lX)", what, err);
    if (msg) {
        // Trim trailing CR/LF that FormatMessage appends.
        size_t n = wcslen(msg);
        while (n > 0 && (msg[n - 1] == L'\r' || msg[n - 1] == L'\n')) {
            msg[--n] = L'\0';
        }
        fwprintf(stderr, L": %s", msg);
        LocalFree(msg);
    }
    fprintf(stderr, "\n");
}

static BOOL IsElevated(void)
{
    HANDLE          token = NULL;
    TOKEN_ELEVATION elevation;
    DWORD           cb = sizeof(elevation);
    BOOL            elevated = FALSE;

    if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
        if (GetTokenInformation(token, TokenElevation, &elevation, cb, &cb)) {
            elevated = elevation.TokenIsElevated ? TRUE : FALSE;
        }
        CloseHandle(token);
    }
    return elevated;
}

//
// Reads a REG_MULTI_SZ / REG_SZ device property into a caller-freed buffer.
//
static WCHAR *GetDeviceProperty(HDEVINFO set, PSP_DEVINFO_DATA info, DWORD prop)
{
    DWORD  cb = 0;
    WCHAR *buf;

    SetupDiGetDeviceRegistryPropertyW(set, info, prop, NULL, NULL, 0, &cb);
    if (cb == 0) {
        return NULL;
    }

    // Two extra WCHARs so the result is always double-NUL terminated.
    buf = (WCHAR *)calloc(cb + 2 * sizeof(WCHAR), 1);
    if (!buf) {
        return NULL;
    }

    if (!SetupDiGetDeviceRegistryPropertyW(set, info, prop, NULL, (PBYTE)buf, cb, NULL)) {
        free(buf);
        return NULL;
    }
    return buf;
}

static BOOL MultiSzContains(const WCHAR *multiSz, const WCHAR *needle)
{
    const WCHAR *p;

    if (!multiSz) {
        return FALSE;
    }
    for (p = multiSz; *p; p += wcslen(p) + 1) {
        if (_wcsicmp(p, needle) == 0) {
            return TRUE;
        }
    }
    return FALSE;
}

// ---------------------------------------------------------------------------
// install
// ---------------------------------------------------------------------------

static int CmdInstall(const WCHAR *infArg)
{
    WCHAR          infPath[MAX_PATH];
    WCHAR          className[MAX_CLASS_NAME_LEN];
    GUID           classGuid;
    HDEVINFO       set = INVALID_HANDLE_VALUE;
    SP_DEVINFO_DATA info;
    WCHAR          hwid[64];
    DWORD          hwidCb;
    BOOL           rebootRequired = FALSE;
    int            rc = 1;

    if (!IsElevated()) {
        fprintf(stderr, "ERROR: install requires an elevated (Administrator) prompt.\n");
        return 1;
    }

    // UpdateDriverForPlugAndPlayDevices needs a fully qualified path.
    if (GetFullPathNameW(infArg, MAX_PATH, infPath, NULL) == 0) {
        PrintLastError("GetFullPathName");
        return 1;
    }
    if (GetFileAttributesW(infPath) == INVALID_FILE_ATTRIBUTES) {
        fwprintf(stderr, L"ERROR: INF not found: %s\n", infPath);
        return 1;
    }

    // Take the device setup class straight from the INF rather than hardcoding
    // HIDClass, so the tool stays correct if the INF's class ever changes.
    if (!SetupDiGetINFClassW(infPath, &classGuid, className,
                             MAX_CLASS_NAME_LEN, NULL)) {
        PrintLastError("SetupDiGetINFClass");
        return 1;
    }

    // Build the REG_MULTI_SZ hardware ID list: "root\virtualmouse\0\0".
    ZeroMemory(hwid, sizeof(hwid));
    wcscpy_s(hwid, ARRAYSIZE(hwid) - 1, VMOUSE_HARDWARE_ID);
    hwidCb = (DWORD)((wcslen(hwid) + 2) * sizeof(WCHAR));

    set = SetupDiCreateDeviceInfoList(&classGuid, NULL);
    if (set == INVALID_HANDLE_VALUE) {
        PrintLastError("SetupDiCreateDeviceInfoList");
        return 1;
    }

    ZeroMemory(&info, sizeof(info));
    info.cbSize = sizeof(info);

    if (!SetupDiCreateDeviceInfoW(set, className, &classGuid, NULL, NULL,
                                  DICD_GENERATE_ID, &info)) {
        PrintLastError("SetupDiCreateDeviceInfo");
        goto cleanup;
    }

    if (!SetupDiSetDeviceRegistryPropertyW(set, &info, SPDRP_HARDWAREID,
                                           (PBYTE)hwid, hwidCb)) {
        PrintLastError("SetupDiSetDeviceRegistryProperty(HARDWAREID)");
        goto cleanup;
    }

    // Creates the devnode in the PnP tree (still driverless at this point).
    if (!SetupDiCallClassInstaller(DIF_REGISTERDEVICE, set, &info)) {
        PrintLastError("SetupDiCallClassInstaller(DIF_REGISTERDEVICE)");
        goto cleanup;
    }

    wprintf(L"Created devnode for %s\n", VMOUSE_HARDWARE_ID);

    // Now install the driver package onto it.
    if (!UpdateDriverForPlugAndPlayDevicesW(NULL, VMOUSE_HARDWARE_ID, infPath,
                                            INSTALLFLAG_FORCE, &rebootRequired)) {
        DWORD           err = GetLastError();
        SP_REMOVEDEVICE_PARAMS rm;

        PrintLastError("UpdateDriverForPlugAndPlayDevices");
        if (err == ERROR_FILE_NOT_FOUND) {
            fprintf(stderr,
                    "HINT: this usually means the driver package is not signed with a\n"
                    "      certificate Windows trusts, or test signing is off.\n"
                    "      Run scripts\\Sign-Driver.ps1 and scripts\\Enable-TestSigning.ps1.\n");
        }

        // Do not leave an orphaned driverless devnode behind.
        ZeroMemory(&rm, sizeof(rm));
        rm.ClassInstallHeader.cbSize = sizeof(SP_CLASSINSTALL_HEADER);
        rm.ClassInstallHeader.InstallFunction = DIF_REMOVE;
        rm.Scope = DI_REMOVEDEVICE_GLOBAL;
        if (SetupDiSetClassInstallParamsW(set, &info, &rm.ClassInstallHeader,
                                          sizeof(rm))) {
            SetupDiCallClassInstaller(DIF_REMOVE, set, &info);
        }
        fprintf(stderr, "Rolled back the devnode.\n");
        goto cleanup;
    }

    printf("Driver installed.%s\n",
           rebootRequired ? " A reboot is required." : "");
    printf("Run 'vmousectl status' and 'vmousectl rawinput' to verify.\n");
    rc = 0;

cleanup:
    if (set != INVALID_HANDLE_VALUE) {
        SetupDiDestroyDeviceInfoList(set);
    }
    return rc;
}

// ---------------------------------------------------------------------------
// remove
// ---------------------------------------------------------------------------

static int CmdRemove(void)
{
    HDEVINFO        set;
    SP_DEVINFO_DATA info;
    DWORD           i;
    int             removed = 0;
    int             failed = 0;

    if (!IsElevated()) {
        fprintf(stderr, "ERROR: remove requires an elevated (Administrator) prompt.\n");
        return 1;
    }

    // No DIGCF_PRESENT: a disabled or problem devnode should still be removable.
    set = SetupDiGetClassDevsW(NULL, NULL, NULL, DIGCF_ALLCLASSES);
    if (set == INVALID_HANDLE_VALUE) {
        PrintLastError("SetupDiGetClassDevs");
        return 1;
    }

    ZeroMemory(&info, sizeof(info));
    info.cbSize = sizeof(info);

    for (i = 0; SetupDiEnumDeviceInfo(set, i, &info); i++) {
        WCHAR *hwids = GetDeviceProperty(set, &info, SPDRP_HARDWAREID);
        SP_REMOVEDEVICE_PARAMS rm;

        if (!MultiSzContains(hwids, VMOUSE_HARDWARE_ID)) {
            free(hwids);
            continue;
        }
        free(hwids);

        ZeroMemory(&rm, sizeof(rm));
        rm.ClassInstallHeader.cbSize = sizeof(SP_CLASSINSTALL_HEADER);
        rm.ClassInstallHeader.InstallFunction = DIF_REMOVE;
        rm.Scope = DI_REMOVEDEVICE_GLOBAL;

        if (SetupDiSetClassInstallParamsW(set, &info, &rm.ClassInstallHeader,
                                          sizeof(rm)) &&
            SetupDiCallClassInstaller(DIF_REMOVE, set, &info)) {
            removed++;
        } else {
            PrintLastError("SetupDiCallClassInstaller(DIF_REMOVE)");
            failed++;
        }
    }

    SetupDiDestroyDeviceInfoList(set);

    printf("Removed %d devnode(s).%s\n", removed,
           failed ? " Some removals failed." : "");
    if (removed == 0 && failed == 0) {
        printf("Nothing to remove: no %ls devnode found.\n", VMOUSE_HARDWARE_ID);
    }
    printf("NOTE: this removes the device, not the driver package from the\n"
           "      driver store. Use 'pnputil /enum-drivers' and\n"
           "      'pnputil /delete-driver oemNN.inf /uninstall' for that.\n");
    return failed ? 1 : 0;
}

// ---------------------------------------------------------------------------
// status
// ---------------------------------------------------------------------------

static const char *ProblemText(ULONG problem)
{
    switch (problem) {
    case 0:                        return "none";
    case CM_PROB_NOT_CONFIGURED:   return "CM_PROB_NOT_CONFIGURED (no driver installed)";
    case CM_PROB_FAILED_START:     return "CM_PROB_FAILED_START (driver failed to start)";
    case CM_PROB_DISABLED:         return "CM_PROB_DISABLED";
    case CM_PROB_FAILED_INSTALL:   return "CM_PROB_FAILED_INSTALL";
    case CM_PROB_DRIVER_FAILED_LOAD: return "CM_PROB_DRIVER_FAILED_LOAD (signature?)";
    case CM_PROB_NEED_RESTART:     return "CM_PROB_NEED_RESTART";
    default:                       return "see CM_PROB_* in cfgmgr32.h";
    }
}

static void PrintDevnodeTree(DEVINST dev, int depth)
{
    WCHAR   instanceId[MAX_DEVICE_ID_LEN];
    WCHAR   desc[512];
    ULONG   cb;
    DEVINST child;
    int     i;

    for (i = 0; i < depth; i++) {
        printf("  ");
    }

    if (CM_Get_Device_IDW(dev, instanceId, ARRAYSIZE(instanceId), 0) != CR_SUCCESS) {
        wcscpy_s(instanceId, ARRAYSIZE(instanceId), L"<unknown>");
    }

    cb = sizeof(desc);
    if (CM_Get_DevNode_Registry_PropertyW(dev, CM_DRP_FRIENDLYNAME, NULL, desc,
                                          &cb, 0) != CR_SUCCESS) {
        cb = sizeof(desc);
        if (CM_Get_DevNode_Registry_PropertyW(dev, CM_DRP_DEVICEDESC, NULL, desc,
                                              &cb, 0) != CR_SUCCESS) {
            wcscpy_s(desc, ARRAYSIZE(desc), L"<no description>");
        }
    }

    wprintf(L"- %s\n", desc);
    for (i = 0; i < depth; i++) {
        printf("  ");
    }
    wprintf(L"    %s\n", instanceId);

    if (CM_Get_Child(&child, dev, 0) == CR_SUCCESS) {
        for (;;) {
            DEVINST sibling;
            PrintDevnodeTree(child, depth + 1);
            if (CM_Get_Sibling(&sibling, child, 0) != CR_SUCCESS) {
                break;
            }
            child = sibling;
        }
    }
}

//
// Appends the instance ID of 'dev' and of every descendant to 'out'.
//
static void CollectSubtreeIds(DEVINST dev, VMOUSE_IDS *out)
{
    DEVINST child;

    if (out->count < MAX_VMOUSE_IDS &&
        CM_Get_Device_IDW(dev, out->ids[out->count], MAX_DEVICE_ID_LEN, 0) == CR_SUCCESS) {
        out->count++;
    }

    if (CM_Get_Child(&child, dev, 0) == CR_SUCCESS) {
        for (;;) {
            DEVINST sibling;
            CollectSubtreeIds(child, out);
            if (CM_Get_Sibling(&sibling, child, 0) != CR_SUCCESS) {
                break;
            }
            child = sibling;
        }
    }
}

//
// Finds every root\virtualmouse devnode and collects its whole subtree.
//
static void CollectVirtualMouseIds(VMOUSE_IDS *out)
{
    HDEVINFO        set;
    SP_DEVINFO_DATA info;
    DWORD           i;

    out->count = 0;

    set = SetupDiGetClassDevsW(NULL, NULL, NULL, DIGCF_ALLCLASSES);
    if (set == INVALID_HANDLE_VALUE) {
        return;
    }

    ZeroMemory(&info, sizeof(info));
    info.cbSize = sizeof(info);

    for (i = 0; SetupDiEnumDeviceInfo(set, i, &info); i++) {
        WCHAR *hwids = GetDeviceProperty(set, &info, SPDRP_HARDWAREID);
        BOOL   ours  = MultiSzContains(hwids, VMOUSE_HARDWARE_ID);
        free(hwids);
        if (ours) {
            CollectSubtreeIds(info.DevInst, out);
        }
    }

    SetupDiDestroyDeviceInfoList(set);
}

//
// A RawInput device name looks like
//     \\?\HID#HIDCLASS#1&2d595ca7&0&0000#{378de44c-56ef-11d1-bc8c-00a0c91405dd}
// which is the instance ID  HID\HIDCLASS\1&2D595CA7&0&0000  with '\' turned
// into '#', a \\?\ prefix, and an interface GUID appended. Undo that and
// compare against the collected IDs.
//
static BOOL IsVirtualMouseRawName(const WCHAR *rawName, const VMOUSE_IDS *ids)
{
    WCHAR  norm[MAX_DEVICE_ID_LEN];
    WCHAR *p;
    int    i;

    if (wcsncmp(rawName, L"\\\\?\\", 4) == 0) {
        rawName += 4;
    }
    wcscpy_s(norm, ARRAYSIZE(norm), rawName);

    p = wcsstr(norm, L"#{");
    if (p) {
        *p = L'\0';
    }
    for (p = norm; *p; p++) {
        if (*p == L'#') {
            *p = L'\\';
        }
    }

    for (i = 0; i < ids->count; i++) {
        if (_wcsicmp(norm, ids->ids[i]) == 0) {
            return TRUE;
        }
    }
    return FALSE;
}

static int CmdStatus(void)
{
    HDEVINFO        set;
    SP_DEVINFO_DATA info;
    DWORD           i;
    int             found = 0;

    set = SetupDiGetClassDevsW(NULL, NULL, NULL, DIGCF_ALLCLASSES);
    if (set == INVALID_HANDLE_VALUE) {
        PrintLastError("SetupDiGetClassDevs");
        return 1;
    }

    ZeroMemory(&info, sizeof(info));
    info.cbSize = sizeof(info);

    for (i = 0; SetupDiEnumDeviceInfo(set, i, &info); i++) {
        WCHAR *hwids = GetDeviceProperty(set, &info, SPDRP_HARDWAREID);
        ULONG  status = 0, problem = 0;

        if (!MultiSzContains(hwids, VMOUSE_HARDWARE_ID)) {
            free(hwids);
            continue;
        }
        free(hwids);
        found++;

        printf("=== virtual mouse devnode #%d ===\n", found);

        if (CM_Get_DevNode_Status(&status, &problem, info.DevInst, 0) == CR_SUCCESS) {
            printf("  started : %s\n", (status & DN_STARTED) ? "yes" : "NO");
            printf("  problem : %s\n", ProblemText(problem));
        } else {
            printf("  status  : CM_Get_DevNode_Status failed\n");
        }

        printf("  device tree (children are created by hidclass/mouclass):\n");
        printf("  ");
        PrintDevnodeTree(info.DevInst, 1);
        printf("\n");
    }

    SetupDiDestroyDeviceInfoList(set);

    if (found == 0) {
        printf("No %ls devnode found. The driver is not installed.\n",
               VMOUSE_HARDWARE_ID);
        return 1;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// rawinput
// ---------------------------------------------------------------------------

static int CmdRawInput(void)
{
    UINT              count = 0;
    PRAWINPUTDEVICELIST list;
    UINT              i;
    int               mice = 0;
    int               ours = 0;
    VMOUSE_IDS        vmIds;

    CollectVirtualMouseIds(&vmIds);

    if (GetRawInputDeviceList(NULL, &count, sizeof(RAWINPUTDEVICELIST)) != 0) {
        PrintLastError("GetRawInputDeviceList(count)");
        return 1;
    }
    if (count == 0) {
        printf("GetRawInputDeviceList reported 0 devices.\n");
        return 1;
    }

    list = (PRAWINPUTDEVICELIST)calloc(count, sizeof(RAWINPUTDEVICELIST));
    if (!list) {
        fprintf(stderr, "ERROR: out of memory\n");
        return 1;
    }

    if (GetRawInputDeviceList(list, &count, sizeof(RAWINPUTDEVICELIST)) == (UINT)-1) {
        PrintLastError("GetRawInputDeviceList");
        free(list);
        return 1;
    }

    printf("GetRawInputDeviceList reports %u device(s):\n\n", count);

    for (i = 0; i < count; i++) {
        WCHAR        name[512] = L"<unavailable>";
        UINT         nameLen = ARRAYSIZE(name);
        RID_DEVICE_INFO rdi;
        UINT         cb = sizeof(rdi);
        const char  *type;

        GetRawInputDeviceInfoW(list[i].hDevice, RIDI_DEVICENAME, name, &nameLen);

        ZeroMemory(&rdi, sizeof(rdi));
        rdi.cbSize = sizeof(rdi);
        if (GetRawInputDeviceInfoW(list[i].hDevice, RIDI_DEVICEINFO, &rdi, &cb) == (UINT)-1) {
            rdi.dwType = list[i].dwType;
        }

        switch (list[i].dwType) {
        case RIM_TYPEMOUSE:    type = "MOUSE   "; break;
        case RIM_TYPEKEYBOARD: type = "KEYBOARD"; break;
        default:               type = "HID     "; break;
        }

        if (list[i].dwType == RIM_TYPEMOUSE) {
            mice++;
        }

        if (IsVirtualMouseRawName(name, &vmIds)) {
            ours++;
            printf("  [%s] <<< VIRTUAL MOUSE\n", type);
        } else {
            printf("  [%s]\n", type);
        }

        wprintf(L"      %s\n", name);

        if (list[i].dwType == RIM_TYPEMOUSE && rdi.dwType == RIM_TYPEMOUSE) {
            printf("      id=%lu buttons=%lu sampleRate=%lu hWheel=%s\n",
                   rdi.mouse.dwId, rdi.mouse.dwNumberOfButtons,
                   rdi.mouse.dwSampleRate,
                   rdi.mouse.fHasHorizontalWheel ? "yes" : "no");
        } else if (rdi.dwType == RIM_TYPEHID) {
            printf("      vid=0x%04lX pid=0x%04lX usagePage=0x%02X usage=0x%02X\n",
                   rdi.hid.dwVendorId, rdi.hid.dwProductId,
                   rdi.hid.usUsagePage, rdi.hid.usUsage);
        }
        printf("\n");
    }

    free(list);

    printf("Summary: %d mouse device(s) visible to RawInput", mice);
    if (ours > 0) {
        printf(", %d of them the virtual mouse.\n", ours);
        printf("RESULT: PASS - a game calling GetRawInputDeviceList() will see a mouse.\n");
        return 0;
    }

    printf(", none of them the virtual mouse.\n");
    printf("RESULT: the virtual mouse is NOT visible. Check 'vmousectl status'.\n");
    return 1;
}

// ---------------------------------------------------------------------------

static void Usage(void)
{
    printf(
        "vmousectl - control and verify the virtual HID mouse\n"
        "\n"
        "Usage:\n"
        "  vmousectl install <path-to-vmouse.inf>   create devnode + install driver (admin)\n"
        "  vmousectl remove                         remove the devnode (admin)\n"
        "  vmousectl status                         show devnode state and children\n"
        "  vmousectl rawinput                       dump GetRawInputDeviceList()\n");
}

int __cdecl wmain(int argc, wchar_t **argv)
{
    // wprintf narrows wide strings through the C locale, and the default "C"
    // locale can only represent ASCII, so a device description like
    // "HID 호환 마우스" comes out as "HID ?? ???". Adopting the user's locale
    // makes the conversion target the console's ANSI codepage instead.
    setlocale(LC_ALL, "");

    if (argc < 2) {
        Usage();
        return 2;
    }

    if (_wcsicmp(argv[1], L"install") == 0) {
        if (argc < 3) {
            fprintf(stderr, "ERROR: install needs the path to vmouse.inf\n");
            return 2;
        }
        return CmdInstall(argv[2]);
    }
    if (_wcsicmp(argv[1], L"remove") == 0) {
        return CmdRemove();
    }
    if (_wcsicmp(argv[1], L"status") == 0) {
        return CmdStatus();
    }
    if (_wcsicmp(argv[1], L"rawinput") == 0) {
        return CmdRawInput();
    }

    Usage();
    return 2;
}
