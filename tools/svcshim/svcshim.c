// SPDX-License-Identifier: MIT
// Native service shim for AdskLicensingService under Wine: replaces tools/AdskSvcShim.cs without .NET Framework
// (Revit 2025+ runs on .NET 8; we don't want .NET Framework just for the shim: CLR 4.8 crashes for us under Wine).
//
// Why: AdskLicensingService is written in Go (kardianos/service). It decides whether it is a service via
// svc.IsAnInteractiveSession(); under Wine the token carries the Interactive SID, so it thinks it was started from
// a console and never calls StartServiceCtrlDispatcher. SCM waits until the timeout (error 1053) and kills the process.
//
// What it does: registers with SCM as a regular service, reports RUNNING and keeps the real
// AdskLicensingService.exe as a child process in console mode. If the child dies, the service stops.
// Usage (service ImagePath): svcshim.exe ["path to the real exe"]
#include <windows.h>
#include <stdio.h>

static const wchar_t *DEFAULT_TARGET =
    L"C:\\Program Files (x86)\\Common Files\\Autodesk Shared\\AdskLicensing\\Current\\AdskLicensingService\\AdskLicensingService.exe";
static const wchar_t *LOG_PATH = L"C:\\ProgramData\\Autodesk\\AdskLicensingService\\Log\\svcshim.log";
static wchar_t target[MAX_PATH] = L"";
static SERVICE_STATUS_HANDLE status_handle;
static SERVICE_STATUS status = { SERVICE_WIN32_OWN_PROCESS, SERVICE_START_PENDING, 0, 0, 0, 0, 0 };
static PROCESS_INFORMATION child;
static HANDLE stop_event;

static void logf(const wchar_t *fmt, ...) {
    FILE *f = _wfopen(LOG_PATH, L"a");
    if (!f) return;
    SYSTEMTIME t; GetLocalTime(&t);
    fwprintf(f, L"%04d/%02d/%02d %02d:%02d:%02d.%03d ", t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond, t.wMilliseconds);
    va_list ap; va_start(ap, fmt); vfwprintf(f, fmt, ap); va_end(ap);
    fputwc(L'\n', f); fclose(f);
}

static void set_state(DWORD state, DWORD code) {
    status.dwCurrentState = state;
    status.dwWin32ExitCode = code;
    status.dwControlsAccepted = state == SERVICE_RUNNING ? SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN : 0;
    SetServiceStatus(status_handle, &status);
}

static DWORD WINAPI ctrl_handler(DWORD ctrl, DWORD type, void *data, void *ctx) {
    if (ctrl == SERVICE_CONTROL_STOP || ctrl == SERVICE_CONTROL_SHUTDOWN) {
        set_state(SERVICE_STOP_PENDING, 0);
        SetEvent(stop_event);
    }
    return NO_ERROR;
}

static void WINAPI service_main(DWORD argc, wchar_t **argv) {
    status_handle = RegisterServiceCtrlHandlerExW(L"AdskLicensingService", ctrl_handler, NULL);
    stop_event = CreateEventW(NULL, TRUE, FALSE, NULL);

    wchar_t dir[MAX_PATH], cmd[MAX_PATH + 2];
    wcscpy(dir, target);
    wchar_t *slash = wcsrchr(dir, L'\\'); if (slash) *slash = 0;
    swprintf(cmd, MAX_PATH + 2, L"\"%ls\"", target);
    STARTUPINFOW si = { sizeof si };
    if (!CreateProcessW(target, cmd, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, dir, &si, &child)) {
        DWORD e = GetLastError();
        logf(L"CreateProcess failed %lu: %ls", e, target);
        set_state(SERVICE_STOPPED, e);
        return;
    }
    logf(L"started child pid=%lu %ls", child.dwProcessId, target);
    set_state(SERVICE_RUNNING, 0);

    HANDLE h[2] = { stop_event, child.hProcess };
    DWORD r = WaitForMultipleObjects(2, h, FALSE, INFINITE);
    if (r == WAIT_OBJECT_0) { // stop from SCM
        TerminateProcess(child.hProcess, 0);
        WaitForSingleObject(child.hProcess, 5000);
        logf(L"stopped");
        set_state(SERVICE_STOPPED, 0);
    } else {
        DWORD code = 0; GetExitCodeProcess(child.hProcess, &code);
        logf(L"child exited code=%lu, stopping service", code);
        // nonzero code -> SCM applies the sc failure policy (restart)
        set_state(SERVICE_STOPPED, code ? ERROR_SERVICE_SPECIFIC_ERROR : 0);
    }
}

int wmain(int argc, wchar_t **argv) {
    wcsncpy(target, argc > 1 ? argv[1] : DEFAULT_TARGET, MAX_PATH - 1);
    SERVICE_TABLE_ENTRYW table[] = { { L"AdskLicensingService", service_main }, { NULL, NULL } };
    if (!StartServiceCtrlDispatcherW(table)) {
        logf(L"StartServiceCtrlDispatcher failed %lu (not started by SCM?)", GetLastError());
        return 1;
    }
    return 0;
}
