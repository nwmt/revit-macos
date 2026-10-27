/*
 * SPDX-License-Identifier: MIT
 * themeset -- sets the Windows theme of a bottle (light or dark) and tells the running Revit, so Revit 2027 follows the
 * Mac's look. Wine does not carry the Mac's appearance into the registry; with "Use system setting" Revit reads
 * AppsUseLightTheme at start and repaints when it gets WM_SETTINGCHANGE "ImmersiveColorSet". The step theme copies it
 * into the bottle (C:\Program Files\revit-macos\themeset.exe); the Revit app and ./revit theme run it there.
 *
 *   themeset.exe light|dark
 *
 * Writes AppsUseLightTheme and SystemUsesLightTheme (1 light, 0 dark) under HKCU\...\Themes\Personalize, then sends
 * the notice to every top-level window one by one: Wine's HWND_BROADCAST answers TRUE whether or not a window got it,
 * a window of its own answers whether it did. Windows of Revit.exe are counted. One line on stderr, e.g.
 * "dark: 20 Revit windows, 0 did not answer".
 *
 * Exit code: 0 written, and every Revit window answered (or no Revit runs); 1 the registry could not be written;
 * 2 usage; 3 written, but a Revit window did not answer within 5 s (busy or hung: try again later).
 */
#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <stdlib.h>

static DWORD *revit;
static int nrevit, answered, missed;

static int is_revit(DWORD pid)
{
    for (int i = 0; i < nrevit; i++)
        if (revit[i] == pid) return 1;
    return 0;
}

static void find_revits(void)
{
    PROCESSENTRY32W e = { .dwSize = sizeof e };
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    int cap = 0;
    if (snap == INVALID_HANDLE_VALUE) return;
    for (BOOL ok = Process32FirstW(snap, &e); ok; ok = Process32NextW(snap, &e)) {
        if (_wcsicmp(e.szExeFile, L"Revit.exe")) continue;
        if (nrevit == cap) {
            DWORD *more = realloc(revit, (cap = cap ? cap * 2 : 4) * sizeof *revit);
            if (!more) break;
            revit = more;
        }
        revit[nrevit++] = e.th32ProcessID;
    }
    CloseHandle(snap);
}

static BOOL CALLBACK notify(HWND h, LPARAM unused)
{
    DWORD pid = 0;
    DWORD_PTR r;
    LRESULT ok = SendMessageTimeoutW(h, WM_SETTINGCHANGE, 0, (LPARAM)L"ImmersiveColorSet", SMTO_ABORTIFHUNG, 5000, &r);
    GetWindowThreadProcessId(h, &pid);
    if (is_revit(pid)) {
        if (ok) answered++;
        else missed++;
    }
    return TRUE;
}

int wmain(int argc, WCHAR **argv)
{
    HKEY k;
    DWORD light;
    if (argc != 2 || (wcscmp(argv[1], L"light") && wcscmp(argv[1], L"dark"))) {
        fprintf(stderr, "usage: themeset.exe light|dark\n");
        return 2;
    }
    light = !wcscmp(argv[1], L"light");
    if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize", 0,
                        NULL, 0, KEY_SET_VALUE, NULL, &k, NULL)) {
        fprintf(stderr, "themeset: cannot open the Personalize key\n");
        return 1;
    }
    if (RegSetValueExW(k, L"AppsUseLightTheme", 0, REG_DWORD, (BYTE *)&light, sizeof light) ||
        RegSetValueExW(k, L"SystemUsesLightTheme", 0, REG_DWORD, (BYTE *)&light, sizeof light)) {
        RegCloseKey(k);
        fprintf(stderr, "themeset: cannot write the theme\n");
        return 1;
    }
    RegCloseKey(k);
    find_revits();
    EnumWindows(notify, 0);
    fprintf(stderr, "%ls: %d Revit windows, %d did not answer\n", argv[1], answered + missed, missed);
    return missed ? 3 : 0;
}
