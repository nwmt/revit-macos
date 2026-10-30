/*
 * SPDX-License-Identifier: MIT
 * revitopen -- hands a file to the Revit running in this bottle, the way Explorer does: DDE, service "Revit", topic
 * "System", command [open("<path>")] (the bottle's Revit.Project\shell\open\ddeexec). DDE lives inside one wineserver,
 * so only the Revit of this bottle can answer. It never starts a program: Windows' ShellExecute starts Revit.exe /dde
 * when DDE does not answer yet, and that would be a second Revit. scripts/open-file.sh runs it by its Mac path.
 *
 *   revitopen.exe ready <seconds>    waits until the DDE server answers; sends nothing
 *   revitopen.exe send <path>        sends the command once
 *
 * Exit code: 0 done; 2 usage or DDE unusable; 3 no DDE server; 4 Revit stayed busy (a dialog is open) for 60 s;
 * 5 no answer within 60 s: Revit may be opening the file, so the command must not be sent again; 6 Revit refused it.
 */
#include <windows.h>
#include <ddeml.h>
#include <stdio.h>
#include <wchar.h>

#define ANSWER_MS 60000

static DWORD inst;

static HDDEDATA CALLBACK callback(UINT t, UINT f, HCONV c, HSZ a, HSZ b, HDDEDATA d, ULONG_PTR x, ULONG_PTR y)
{
    return NULL;
}

static HCONV connect(void)
{
    HSZ service = DdeCreateStringHandleW(inst, L"Revit", CP_WINUNICODE);
    HSZ topic = DdeCreateStringHandleW(inst, L"System", CP_WINUNICODE);
    HCONV c = DdeConnect(inst, service, topic, NULL);
    DdeFreeStringHandle(inst, topic);
    DdeFreeStringHandle(inst, service);
    return c;
}

static int ready(int seconds)
{
    ULONGLONG end = GetTickCount64() + seconds * 1000ULL;
    for (;;) {
        HCONV c = connect();
        if (c) { DdeDisconnect(c); return 0; }
        if (GetTickCount64() >= end) return 3;
        Sleep(2000);
    }
}

static int send_open(const wchar_t *path)
{
    wchar_t cmd[1100];
    ULONGLONG end = GetTickCount64() + ANSWER_MS;
    HCONV c = connect();
    int rc = 6;

    if (!c) return 3;
    swprintf(cmd, sizeof cmd / sizeof *cmd, L"[open(\"%ls\")]", path);
    for (;;) {
        DWORD result = 0, left = (DWORD)(end - min(end, GetTickCount64()));
        UINT err;
        if (!left) { rc = 4; break; }
        if (DdeClientTransaction((BYTE *)cmd, (DWORD)((wcslen(cmd) + 1) * sizeof *cmd), c, 0, 0, XTYP_EXECUTE, left, &result)) {
            rc = 0;
            break;
        }
        err = DdeGetLastError(inst);
        if (err == DMLERR_EXECACKTIMEOUT) { rc = 5; break; }
        if (err != DMLERR_BUSY && !(result & DDE_FBUSY)) { rc = 6; break; }
        Sleep(1000);    /* an explicit "busy" means it was not taken: safe to send again */
    }
    DdeDisconnect(c);
    return rc;
}

int wmain(int argc, wchar_t **argv)
{
    int rc;

    if (argc != 3 || (wcscmp(argv[1], L"ready") && wcscmp(argv[1], L"send")) || wcslen(argv[2]) > 1000) {
        fputs("Usage: revitopen.exe ready <seconds> | send <path>\n", stderr);
        return 2;
    }
    if (DdeInitializeW(&inst, callback, APPCMD_CLIENTONLY, 0) != DMLERR_NO_ERROR) return 2;
    rc = argv[1][0] == L'r' ? ready(_wtoi(argv[2])) : send_open(argv[2]);
    DdeUninitialize(inst);
    return rc;
}
