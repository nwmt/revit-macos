/*
 * SPDX-License-Identifier: MIT
 * mcppipes -- lets Autodesk's Revit MCP Server find Revit's named pipe under Wine. Loaded into
 * Autodesk.RevitMcpServer.Stdio.exe by our launcher (tools/shims/mcphost) after coreclr.dll is there; nothing on disk
 * is changed.
 *
 * The server finds Revit by listing pipes: Directory.GetFiles(@"\\.\pipe\") (CreateFileW of "\\.\pipe\", then
 * NtQueryDirectoryFile) and connects to revit-mcp-<year>-<guid>. Wine cannot list pipes, so the server sees none.
 * mcphost keeps one empty marker file per live Revit pipe in a folder of its own and passes the folder in
 * REVIT_MCP_PIPES (an absolute Windows path). Here kernelbase's import of ntdll!NtCreateFile is replaced: an open of
 * exactly \??\pipe or \??\pipe\ opens that folder instead, so the listing returns the markers' names; every other
 * open, the pipe connection itself included, goes to ntdll unchanged. Patching the import works whenever the DLL
 * arrives: .NET's cached P/Invoke target (kernelbase!CreateFileW) still calls NtCreateFile through it.
 *
 * Acknowledgement for mcphost: <folder>\.hook = "ok <own pid>" after the patch, or "fail <reason>" (then DllMain
 * returns FALSE), written through .hook.tmp and a rename. No REVIT_MCP_PIPES: no hook and no file.
 * Test builds for mcphost's harness only, never released: -DMCPPIPES_TEST=1 (no .hook), 2 (fail), 3 (ok <pid+1>),
 * 4 (DllMain sleeps 60 s).
 */
#include <windows.h>
#include <winternl.h>
#define SHIM_NAME "mcppipes"
#include "hook.h"

typedef NTSTATUS (NTAPI *ntcreate_fn)(PHANDLE, ACCESS_MASK, POBJECT_ATTRIBUTES, PIO_STATUS_BLOCK, PLARGE_INTEGER, ULONG,
                                      ULONG, ULONG, ULONG, PVOID, ULONG);
static ntcreate_fn orig_create;
static WCHAR folder[MAX_PATH];             /* C:\...\<marker folder> */
static WCHAR nt_folder[MAX_PATH + 8];      /* \??\C:\...\<marker folder>\ */
static UNICODE_STRING nt_name;

static BOOL is_pipe_root(const UNICODE_STRING *u)
{
    static const WCHAR root[] = L"\\??\\pipe";
    USHORT n = u->Length / 2, k = (USHORT)lstrlenW(root);
    if (n != k && !(n == k + 1 && u->Buffer[k] == L'\\')) return FALSE;
    return CompareStringOrdinal(u->Buffer, k, root, k, TRUE) == CSTR_EQUAL;
}

static NTSTATUS NTAPI hook_create(PHANDLE h, ACCESS_MASK acc, POBJECT_ATTRIBUTES oa, PIO_STATUS_BLOCK io, PLARGE_INTEGER al,
                                  ULONG attr, ULONG share, ULONG disp, ULONG opt, PVOID ea, ULONG eal)
{
    if (oa && oa->ObjectName && oa->ObjectName->Buffer && is_pipe_root(oa->ObjectName)) {
        OBJECT_ATTRIBUTES o2 = *oa;
        o2.ObjectName = &nt_name; o2.RootDirectory = NULL;
        return orig_create(h, acc, &o2, io, al, attr, share, disp, opt, ea, eal);
    }
    return orig_create(h, acc, oa, io, al, attr, share, disp, opt, ea, eal);
}

static BOOL in_module(HMODULE mod, void *p)
{
    BYTE *base = (BYTE *)mod;
    IMAGE_NT_HEADERS *nt = (IMAGE_NT_HEADERS *)(base + ((IMAGE_DOS_HEADER *)base)->e_lfanew);
    return mod && (BYTE *)p >= base && (BYTE *)p < base + nt->OptionalHeader.SizeOfImage;
}

/* kernelbase's import of ntdll!NtCreateFile → hook; the original must lie inside ntdll's image */
static const char *patch_import(void)
{
    HMODULE kb = GetModuleHandleW(L"kernelbase.dll"), nt = GetModuleHandleW(L"ntdll.dll");
    if (!kb || !nt) return "no kernelbase or ntdll";
    BYTE *base = (BYTE *)kb;
    IMAGE_NT_HEADERS *h = (IMAGE_NT_HEADERS *)(base + ((IMAGE_DOS_HEADER *)base)->e_lfanew);
    IMAGE_DATA_DIRECTORY dir = h->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    for (IMAGE_IMPORT_DESCRIPTOR *imp = (IMAGE_IMPORT_DESCRIPTOR *)(base + dir.VirtualAddress); dir.VirtualAddress && imp->Name; imp++) {
        if (lstrcmpiA((char *)(base + imp->Name), "ntdll.dll") || !imp->OriginalFirstThunk) continue;
        IMAGE_THUNK_DATA *names = (IMAGE_THUNK_DATA *)(base + imp->OriginalFirstThunk), *iat = (IMAGE_THUNK_DATA *)(base + imp->FirstThunk);
        for (; names->u1.AddressOfData; names++, iat++) {
            if (IMAGE_SNAP_BY_ORDINAL(names->u1.Ordinal)) continue;
            if (lstrcmpA((char *)((IMAGE_IMPORT_BY_NAME *)(base + names->u1.AddressOfData))->Name, "NtCreateFile")) continue;
            void *cur = (void *)iat->u1.Function;
            if (!in_module(nt, cur)) return "NtCreateFile import does not point into ntdll";
            DWORD old;
            if (!VirtualProtect(&iat->u1.Function, sizeof(void *), PAGE_READWRITE, &old)) return "VirtualProtect failed";
            orig_create = (ntcreate_fn)cur;
            iat->u1.Function = (ULONG_PTR)hook_create;
            VirtualProtect(&iat->u1.Function, sizeof(void *), old, &old);
            return NULL;
        }
    }
    return "kernelbase does not import NtCreateFile";
}

static void acknowledge(const char *text)   /* <folder>\.hook = text, through .hook.tmp and a rename */
{
    WCHAR tmp[MAX_PATH + 16], fin[MAX_PATH + 16];
    wsprintfW(tmp, L"%s\\.hook.tmp", folder); wsprintfW(fin, L"%s\\.hook", folder);
    HANDLE f = CreateFileW(tmp, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f == INVALID_HANDLE_VALUE) { trace("cannot write %ls\n", tmp); return; }
    DWORD n;
    WriteFile(f, text, lstrlenA(text), &n, NULL);
    CloseHandle(f);
    if (!MoveFileExW(tmp, fin, MOVEFILE_REPLACE_EXISTING)) trace("cannot rename %ls\n", tmp);
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, void *reserved)
{
    char msg[128];
    if (reason != DLL_PROCESS_ATTACH) return TRUE;
    DisableThreadLibraryCalls(inst);
#if MCPPIPES_TEST == 4
    Sleep(60000);
#endif
    DWORD n = GetEnvironmentVariableW(L"REVIT_MCP_PIPES", folder, MAX_PATH);
    if (!n) return TRUE;
    if (n >= MAX_PATH || n < 4 || folder[1] != L':' || folder[2] != L'\\') { trace("REVIT_MCP_PIPES is not an absolute path\n"); return FALSE; }
    while (n > 3 && folder[n - 1] == L'\\') folder[--n] = 0;
    wsprintfW(nt_folder, L"\\??\\%s\\", folder);
    nt_name.Length = (USHORT)(lstrlenW(nt_folder) * sizeof(WCHAR));
    nt_name.MaximumLength = (USHORT)sizeof(nt_folder);
    nt_name.Buffer = nt_folder;
#if MCPPIPES_TEST == 2
    acknowledge("fail test build");
    return FALSE;
#endif
    /* pinned: the hook must outlive any FreeLibrary */
    HMODULE self;
    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_PIN | GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS, (LPCWSTR)DllMain, &self);
    const char *err = patch_import();
    if (err) {
        wsprintfA(msg, "fail %s", err);
        acknowledge(msg); trace("%s\n", msg);
        return FALSE;
    }
#if MCPPIPES_TEST == 1
    return TRUE;
#elif MCPPIPES_TEST == 3
    wsprintfA(msg, "ok %lu", GetCurrentProcessId() + 1);
#else
    wsprintfA(msg, "ok %lu", GetCurrentProcessId());
#endif
    acknowledge(msg); trace("hooked; markers in %ls\n", folder);
    return TRUE;
}
