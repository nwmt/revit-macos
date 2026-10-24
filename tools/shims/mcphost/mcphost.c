/*
 * SPDX-License-Identifier: MIT
 * mcphost -- starts Autodesk's Revit MCP Server (Autodesk.RevitMcpServer.Stdio.exe) in a bottle so that it finds Revit
 * under Wine. scripts/mcp-launch.sh (./revit mcp) runs it; it sits next to the server with mcppipes.dll.
 *
 *   mcphost.exe --launch <token> [--gate <module>] -- <server exe> [arguments...]
 *   mcphost.exe --scan <generation> <out file>      (internal: one scan of Revit's handles, see below)
 *
 * The server looks for Revit's pipe revit-mcp-<year>-<guid> by listing \\.\pipe\, which Wine cannot list. mcphost
 * keeps one empty marker file per live Revit pipe in a folder of its own, and mcppipes.dll, loaded into the server,
 * makes the listing read that folder (tools/shims/mcppipes). Exit code: the server's; 2 usage; 3 mcppipes.dll could not
 * be loaded into the server; 4 the server could not be started.
 *
 * 1. Launch confirmation: C:\users\crossover\AppData\Local\Temp\revit-macos-mcp\launch-<token> holds our PID (written
 *    through a .tmp file and a rename), deleted on exit. mcp-launch.sh waits for it: only this file shows that our
 *    launcher runs, not the CrossOver loader that has the same arguments.
 * 2. Marker folder ...\revit-macos-mcp\<pid>-<creation time, hex>\. Folders whose owner is gone (no such process, or a
 *    process with another creation time) are removed; on any doubt they stay.
 * 3. The server starts suspended in a job object that kills it when the job closes (that is, when mcphost ends in any
 *    way), inherits only stdin, stdout and stderr, and gets REVIT_MCP_PIPES=<marker folder>.
 * 4. mcppipes.dll goes in within one 30 s deadline from the resume: wait for the gate module (coreclr.dll: .NET is up;
 *    the harness passes kernelbase.dll), CreateRemoteThread(LoadLibraryW), that thread must end with a module, then the
 *    DLL's acknowledgement <folder>\.hook must read "ok <server pid>". Anything else: one line on stderr naming the
 *    stage, the job is ended, exit 3.
 * 5. A scan process (mcphost --scan, in the job, one at a time) reads the handle tables of the bottle's Revit.exe
 *    processes and writes the names of their \Device\NamedPipe\revit-mcp-<year>-<32 hex> handles, then
 *    "complete <generation>", to <out>.tmp and renames it. Under Wine object names come from wineserver without I/O,
 *    so a query is not expected to block; still, a scan that runs over 1.5 s is ended and waited for, and its files
 *    are not read. Only a complete scan of the current generation changes the folder: new names get a marker, markers
 *    the scan did not see go. Scans run every 2 s only until every Revit.exe has a pipe: a scan duplicates each of
 *    Revit's handles, and doing that while the add-in's pipe changes about 5 minutes after the last tool call crashes
 *    wineserver (CrossOver 26). Once settled, every 2 s mcphost only lists the Revit.exe processes (PID and creation
 *    time) and asks for each marker's pipe by name (WaitNamedPipeW); a changed list or a pipe that is gone means a
 *    new scan.
 * 6. If a Revit.exe runs and no scan found a pipe 20 s after the resume, one line on stderr says so; the server keeps
 *    running (Revit may still be opening).
 * Test build for the harness only: -DMCPHOST_TEST_SCAN_HANG (the scan sleeps 60 s).
 */
#include <windows.h>
#include <winternl.h>
#include <tlhelp32.h>
#include <psapi.h>
#define SHIM_NAME "mcphost"
#include "hook.h"

#define BASE L"C:\\users\\crossover\\AppData\\Local\\Temp\\revit-macos-mcp"
#define DEADLINE_MS 30000
#define SCAN_EVERY_MS 2000
#define SCAN_LIMIT_MS 1500
#define NOTICE_AFTER_MS 20000
#define MAX_NAMES 64
#define NAME_LEN 64   /* revit-mcp-2027-<32 hex> = 47 characters */

static WCHAR launch_file[MAX_PATH], folder[MAX_PATH], scan_out[MAX_PATH], scan_tmp[MAX_PATH], self_path[MAX_PATH];
static HANDLE job;

static void err(const char *text)   /* one line on stderr */
{
    DWORD n;
    HANDLE e = GetStdHandle(STD_ERROR_HANDLE);
    if (e && e != INVALID_HANDLE_VALUE) { WriteFile(e, text, lstrlenA(text), &n, NULL); WriteFile(e, "\n", 1, &n, NULL); }
    trace("%s\n", text);
}

static BOOL write_atomic(const WCHAR *path, const char *text)   /* through <path>.tmp and a rename */
{
    WCHAR tmp[MAX_PATH + 8];
    DWORD n;
    wsprintfW(tmp, L"%s.tmp", path);
    HANDLE f = CreateFileW(tmp, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f == INVALID_HANDLE_VALUE) return FALSE;
    BOOL ok = WriteFile(f, text, lstrlenA(text), &n, NULL) && n == (DWORD)lstrlenA(text);
    CloseHandle(f);
    if (ok && MoveFileExW(tmp, path, MOVEFILE_REPLACE_EXISTING)) return TRUE;
    DeleteFileW(tmp);
    return FALSE;
}

static DWORD read_small(const WCHAR *path, char *buf, DWORD cap)   /* whole file, NUL-terminated; 0 = none */
{
    DWORD n = 0;
    HANDLE f = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING, 0, NULL);
    if (f == INVALID_HANDLE_VALUE) return 0;
    if (!ReadFile(f, buf, cap - 1, &n, NULL)) n = 0;
    CloseHandle(f);
    buf[n] = 0;
    return n;
}

static void remove_folder(const WCHAR *dir)   /* its files, then itself */
{
    WCHAR pat[MAX_PATH + 4], p[MAX_PATH * 2];
    WIN32_FIND_DATAW fd;
    wsprintfW(pat, L"%s\\*", dir);
    HANDLE h = FindFirstFileW(pat, &fd);
    if (h != INVALID_HANDLE_VALUE) {
        do if (!(fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) { wsprintfW(p, L"%s\\%s", dir, fd.cFileName); DeleteFileW(p); }
        while (FindNextFileW(h, &fd));
        FindClose(h);
    }
    RemoveDirectoryW(dir);
}

static void cleanup(void)   /* our files: launch confirmation, marker folder, scan results */
{
    DeleteFileW(launch_file);
    if (folder[0]) remove_folder(folder);
    if (scan_out[0]) { DeleteFileW(scan_out); DeleteFileW(scan_tmp); }
}

static BOOL WINAPI on_ctrl(DWORD type)   /* Ctrl-C, close, logoff, shutdown: end the server with us */
{
    cleanup();
    if (job) TerminateJobObject(job, 1);
    ExitProcess(1);
}

static BOOL hex_ok(const WCHAR *s, int n, BOOL upper_ok)
{
    for (int i = 0; i < n; i++) {
        WCHAR c = s[i];
        if (!((c >= L'0' && c <= L'9') || (c >= L'a' && c <= L'f') || (upper_ok && c >= L'A' && c <= L'F'))) return FALSE;
    }
    return TRUE;
}

static BOOL pipe_name_ok(const WCHAR *s)   /* revit-mcp-<4 digits>-<32 lowercase hex>, nothing more */
{
    if (lstrlenW(s) != 47 || CompareStringOrdinal(s, 10, L"revit-mcp-", 10, FALSE) != CSTR_EQUAL) return FALSE;
    for (int i = 10; i < 14; i++) if (s[i] < L'0' || s[i] > L'9') return FALSE;
    return s[14] == L'-' && hex_ok(s + 15, 32, FALSE);
}

/* folders of other mcphost processes that are gone: <pid>-<16 hex>, and their scan files */
static void remove_stale_folders(void)
{
    WIN32_FIND_DATAW fd;
    WCHAR pat[MAX_PATH], p[MAX_PATH * 2];
    wsprintfW(pat, L"%s\\*", BASE);
    HANDLE h = FindFirstFileW(pat, &fd);
    if (h == INVALID_HANDLE_VALUE) return;
    do {
        if (!(fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) continue;
        WCHAR *dash = wcschr(fd.cFileName, L'-');
        if (!dash || dash == fd.cFileName || lstrlenW(dash + 1) != 16 || !hex_ok(dash + 1, 16, TRUE)) continue;
        DWORD pid = 0; BOOL digits = TRUE;
        for (WCHAR *c = fd.cFileName; c < dash; c++) { if (*c < L'0' || *c > L'9') digits = FALSE; else pid = pid * 10 + (*c - L'0'); }
        if (!digits) continue;
        ULONGLONG want = 0;
        for (int i = 0; i < 16; i++) { WCHAR c = dash[1 + i]; want = want * 16 + (c <= L'9' ? c - L'0' : (c | 0x20) - L'a' + 10); }
        BOOL gone = FALSE;
        HANDLE pr = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
        if (!pr) gone = GetLastError() == ERROR_INVALID_PARAMETER;   /* no such process; access denied etc.: keep */
        else {
            FILETIME c, e, k, u; DWORD code;
            if (GetProcessTimes(pr, &c, &e, &k, &u))
                gone = (((ULONGLONG)c.dwHighDateTime << 32) | c.dwLowDateTime) != want
                    || (GetExitCodeProcess(pr, &code) && code != STILL_ACTIVE);
            CloseHandle(pr);
        }
        if (!gone) continue;
        wsprintfW(p, L"%s\\%s", BASE, fd.cFileName);
        if (!lstrcmpiW(p, folder)) continue;
        remove_folder(p);
        wsprintfW(p, L"%s\\%s.scan", BASE, fd.cFileName); DeleteFileW(p);
        wsprintfW(p, L"%s\\%s.scan.tmp", BASE, fd.cFileName); DeleteFileW(p);
    } while (FindNextFileW(h, &fd));
    FindClose(h);
}

/* ---- --scan: one pass over the handle tables of every Revit.exe ---- */
typedef struct { PVOID Object; ULONG_PTR Pid; ULONG_PTR Handle; ULONG Access; USHORT BackTrace; USHORT Type; ULONG Attr; ULONG Reserved; } HENTRY;
typedef struct { ULONG_PTR Count; ULONG_PTR Reserved; HENTRY H[1]; } HTABLE;
#define SystemExtendedHandleInformation 64
#define STATUS_INFO_LENGTH_MISMATCH ((NTSTATUS)0xC0000004)

static int scan(const WCHAR *gen, const WCHAR *out)
{
#ifdef MCPHOST_TEST_SCAN_HANG
    Sleep(60000);
#endif
    static char text[MAX_NAMES * 80 + 256];
    DWORD pids[64]; HANDLE procs[64]; int np = 0, len = 0, names = 0;
    PROCESSENTRY32W pe = { sizeof(pe) };
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return 1;
    if (Process32FirstW(snap, &pe)) do
        if (!lstrcmpiW(pe.szExeFile, L"Revit.exe") && np < 64) {
            procs[np] = OpenProcess(PROCESS_DUP_HANDLE, FALSE, pe.th32ProcessID);
            if (procs[np]) { pids[np++] = pe.th32ProcessID; len += wsprintfA(text + len, "revit %lu\n", pe.th32ProcessID); }
        }
    while (Process32NextW(snap, &pe));
    CloseHandle(snap);
    if (np) {
        ULONG size = 1 << 20, need = 0;
        HTABLE *t = NULL;
        NTSTATUS st;
        for (;;) {
            t = VirtualAlloc(NULL, size, MEM_COMMIT, PAGE_READWRITE);
            if (!t) return 1;
            st = NtQuerySystemInformation(SystemExtendedHandleInformation, t, size, &need);
            if (st != STATUS_INFO_LENGTH_MISMATCH || size >= (1u << 28)) break;
            VirtualFree(t, 0, MEM_RELEASE);
            size *= 2;
        }
        if (st) return 1;
        static const WCHAR dev[] = L"\\Device\\NamedPipe\\";
        const int nd = (int)(sizeof(dev) / sizeof(WCHAR)) - 1;
        for (ULONG_PTR i = 0; i < t->Count && names < MAX_NAMES; i++) {
            int k;
            for (k = 0; k < np && pids[k] != t->H[i].Pid; k++) ;
            if (k == np) continue;
            HANDLE dup;
            if (!DuplicateHandle(procs[k], (HANDLE)t->H[i].Handle, GetCurrentProcess(), &dup, 0, FALSE, DUPLICATE_SAME_ACCESS)) continue;
            BYTE buf[1024]; ULONG got = 0;
            if (!NtQueryObject(dup, ObjectNameInformation, buf, sizeof(buf) - 2, &got)) {
                UNICODE_STRING *u = (UNICODE_STRING *)buf;
                int n = u->Length / 2;
                WCHAR name[NAME_LEN];
                if (n > nd && n - nd < NAME_LEN && CompareStringOrdinal(u->Buffer, nd, dev, nd, TRUE) == CSTR_EQUAL) {
                    memcpy(name, u->Buffer + nd, (n - nd) * sizeof(WCHAR)); name[n - nd] = 0;
                    if (pipe_name_ok(name)) { len += wsprintfA(text + len, "name %ls\n", name); names++; }
                }
            }
            CloseHandle(dup);
        }
    }
    wsprintfA(text + len, "complete %ls\n", gen);
    return write_atomic(out, text) ? 0 : 1;
}

/* ---- --launch ---- */
static WCHAR *command_line(int argc, WCHAR **argv)   /* argv quoted as CommandLineToArgvW reads it back */
{
    size_t cap = 1;
    for (int i = 0; i < argc; i++) cap += 2 * lstrlenW(argv[i]) + 3;
    WCHAR *cmd = HeapAlloc(GetProcessHeap(), 0, cap * sizeof(WCHAR)), *o = cmd;
    if (!cmd) return NULL;
    for (int i = 0; i < argc; i++) {
        const WCHAR *a = argv[i];
        if (i) *o++ = L' ';
        *o++ = L'"';
        for (int bs = 0;; a++) {
            if (*a == L'\\') { bs++; continue; }
            if (*a == L'"' || !*a) { for (int j = 0; j < bs * 2; j++) *o++ = L'\\'; }
            else for (int j = 0; j < bs; j++) *o++ = L'\\';
            bs = 0;
            if (!*a) break;
            if (*a == L'"') *o++ = L'\\';
            *o++ = *a;
        }
        *o++ = L'"';
    }
    *o = 0;
    return cmd;
}

static BOOL has_module(HANDLE proc, const WCHAR *name)
{
    HMODULE mods[1024]; DWORD need = 0; WCHAR base[MAX_PATH];
    if (!K32EnumProcessModulesEx(proc, mods, sizeof(mods), &need, LIST_MODULES_ALL)) return FALSE;
    for (DWORD i = 0; i < need / sizeof(HMODULE) && i < 1024; i++)
        if (K32GetModuleBaseNameW(proc, mods[i], base, MAX_PATH) && !lstrcmpiW(base, name)) return TRUE;
    return FALSE;
}

static const char *inject(PROCESS_INFORMATION *pi, const WCHAR *gate, ULONGLONG deadline, char *why)
{
    WCHAR dll[MAX_PATH], hook[MAX_PATH + 8];
    char ack[128];
    lstrcpyW(dll, self_path);
    WCHAR *slash = wcsrchr(dll, L'\\');
    lstrcpyW(slash ? slash + 1 : dll, L"mcppipes.dll");
    wsprintfW(hook, L"%s\\.hook", folder);
    while (!has_module(pi->hProcess, gate)) {
        if (WaitForSingleObject(pi->hProcess, 0) == WAIT_OBJECT_0) return "gate (the server ended)";
        if (GetTickCount64() >= deadline) return "gate";
        Sleep(20);
    }
    SIZE_T size = (lstrlenW(dll) + 1) * sizeof(WCHAR);
    void *mem = VirtualAllocEx(pi->hProcess, NULL, size, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!mem || !WriteProcessMemory(pi->hProcess, mem, dll, size, NULL)) return "load thread (no memory in the server)";
    LPTHREAD_START_ROUTINE load = (LPTHREAD_START_ROUTINE)GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "LoadLibraryW");
    HANDLE t = CreateRemoteThread(pi->hProcess, NULL, 0, load, mem, 0, NULL);
    if (!t) return "load thread";
    ULONGLONG now = GetTickCount64();
    DWORD w = WaitForSingleObject(t, now < deadline ? (DWORD)(deadline - now) : 0), code = 0;
    BOOL got = w == WAIT_OBJECT_0 && GetExitCodeThread(t, &code);
    CloseHandle(t);
    if (!got) return "load thread";
    VirtualFreeEx(pi->hProcess, mem, 0, MEM_RELEASE);
    for (;;) {
        if (read_small(hook, ack, sizeof(ack))) {
            DeleteFileW(hook);   /* the folder holds markers only: the server lists it */
            if (ack[0] == 'o' && ack[1] == 'k' && ack[2] == ' ') {
                DWORD pid = 0;
                for (char *c = ack + 3; *c >= '0' && *c <= '9'; c++) pid = pid * 10 + (*c - '0');
                return pid == pi->dwProcessId ? NULL : "acknowledgement from another process";
            }
            if (!memcmp(ack, "fail ", 5)) { wsprintfA(why, "hook failed: %.100s", ack + 5); return why; }
            return "acknowledgement unreadable";
        }
        if (!code) return "LoadLibraryW returned 0";
        if (GetTickCount64() >= deadline) return "no acknowledgement";
        Sleep(20);
    }
}

typedef struct { HANDLE proc; ULONGLONG started; BOOL ended; BOOL warned; } SCANNER;

static BOOL scan_start(SCANNER *s, DWORD gen)
{
    WCHAR args[MAX_PATH * 3];
    STARTUPINFOW si = { sizeof(si) };
    PROCESS_INFORMATION pi;
    DeleteFileW(scan_out); DeleteFileW(scan_tmp);
    wsprintfW(args, L"\"%s\" --scan %lu \"%s\"", self_path, gen, scan_out);
    if (!CreateProcessW(self_path, args, NULL, NULL, FALSE, CREATE_SUSPENDED | CREATE_NO_WINDOW, NULL, NULL, &si, &pi)) return FALSE;
    AssignProcessToJobObject(job, pi.hProcess);
    ResumeThread(pi.hThread); CloseHandle(pi.hThread);
    s->proc = pi.hProcess; s->started = GetTickCount64(); s->ended = FALSE; s->warned = FALSE;
    return TRUE;
}

/* a finished scan of generation gen: markers for its names, other files go. -1 = not complete, else the names */
static int scan_apply(DWORD gen, int *revits)
{
    static char text[MAX_NAMES * 80 + 256];
    WCHAR seen[MAX_NAMES][NAME_LEN], p[MAX_PATH * 2], pat[MAX_PATH + 4];
    int n = 0, r = 0;
    char want[32], *line, *next;
    if (!read_small(scan_out, text, sizeof(text))) return -1;
    wsprintfA(want, "complete %lu", gen);
    BOOL complete = FALSE;
    for (line = text; *line; line = next) {
        for (next = line; *next && *next != '\n'; next++) ;
        if (*next) *next++ = 0;
        if (!lstrcmpA(line, want)) complete = TRUE;
        else if (line[0] == 'r' && !memcmp(line, "revit ", 6)) r++;
        else if (!memcmp(line, "name ", 5) && n < MAX_NAMES && lstrlenA(line + 5) < NAME_LEN) {
            MultiByteToWideChar(CP_ACP, 0, line + 5, -1, seen[n], NAME_LEN);
            int d; for (d = 0; d < n && lstrcmpW(seen[d], seen[n]); d++) ;   /* one per pipe, not per instance */
            if (d == n && pipe_name_ok(seen[n])) n++;
        }
    }
    if (!complete) return -1;
    *revits = r;
    for (int i = 0; i < n; i++) {
        wsprintfW(p, L"%s\\%s", folder, seen[i]);
        HANDLE f = CreateFileW(p, GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
        if (f != INVALID_HANDLE_VALUE) CloseHandle(f);
    }
    WIN32_FIND_DATAW fd;
    wsprintfW(pat, L"%s\\*", folder);
    HANDLE h = FindFirstFileW(pat, &fd);
    if (h != INVALID_HANDLE_VALUE) {
        do {
            if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) continue;
            int i;
            for (i = 0; i < n && lstrcmpW(seen[i], fd.cFileName); i++) ;
            if (i < n) continue;
            wsprintfW(p, L"%s\\%s", folder, fd.cFileName); DeleteFileW(p);
        } while (FindNextFileW(h, &fd));
        FindClose(h);
    }
    return n;
}

/* the Revit.exe processes now: their count, and *sig, which changes when one starts or ends; no handle is duplicated */
static int revits_now(ULONGLONG *sig)
{
    PROCESSENTRY32W pe = { sizeof(pe) };
    int r = 0;
    *sig = 0;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) { *sig = ~0ULL; return -1; }
    if (Process32FirstW(snap, &pe)) do
        if (!lstrcmpiW(pe.szExeFile, L"Revit.exe")) {
            ULONGLONG t = 0;
            HANDLE p = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pe.th32ProcessID);
            if (p) {
                FILETIME c, e, k, u;
                if (GetProcessTimes(p, &c, &e, &k, &u)) t = ((ULONGLONG)c.dwHighDateTime << 32) | c.dwLowDateTime;
                CloseHandle(p);
            }
            *sig += (t ^ pe.th32ProcessID) * 0x9E3779B97F4A7C15ULL + pe.th32ProcessID;
            r++;
        }
    while (Process32NextW(snap, &pe));
    CloseHandle(snap);
    return r;
}

/* markers whose pipe no longer exists go, asked by name; TRUE when one went. Any other answer keeps the marker */
static BOOL markers_gone(void)
{
    WIN32_FIND_DATAW fd;
    WCHAR pat[MAX_PATH + 4], p[MAX_PATH * 2], pipe[NAME_LEN + 16];
    BOOL gone = FALSE;
    wsprintfW(pat, L"%s\\*", folder);
    HANDLE h = FindFirstFileW(pat, &fd);
    if (h == INVALID_HANDLE_VALUE) return FALSE;
    do {
        if ((fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) || !pipe_name_ok(fd.cFileName)) continue;
        wsprintfW(pipe, L"\\\\.\\pipe\\%s", fd.cFileName);
        if (WaitNamedPipeW(pipe, 1) || GetLastError() != ERROR_FILE_NOT_FOUND) continue;
        wsprintfW(p, L"%s\\%s", folder, fd.cFileName); DeleteFileW(p);
        gone = TRUE;
    } while (FindNextFileW(h, &fd));
    FindClose(h);
    return gone;
}

static BOOL token_ok(const WCHAR *t)
{
    int n = lstrlenW(t);
    if (n < 1 || n > 64) return FALSE;
    for (int i = 0; i < n; i++)
        if (!((t[i] >= L'0' && t[i] <= L'9') || (t[i] >= L'a' && t[i] <= L'z') || (t[i] >= L'A' && t[i] <= L'Z') || t[i] == L'-')) return FALSE;
    return TRUE;
}

static int usage(void)
{
    err("usage: mcphost.exe --launch <token> [--gate <module>] -- <server exe> [arguments...]");
    return 2;
}

int wmain(int argc, WCHAR **argv)
{
    char line[256], why[160];
    if (argc >= 2 && !lstrcmpW(argv[1], L"--scan")) {
        if (argc != 4 || !argv[2][0] || !argv[3][0]) return usage();
        for (WCHAR *c = argv[2]; *c; c++) if (*c < L'0' || *c > L'9') return usage();
        return scan(argv[2], argv[3]);
    }
    if (argc < 5 || lstrcmpW(argv[1], L"--launch") || !token_ok(argv[2])) return usage();
    const WCHAR *token = argv[2], *gate = L"coreclr.dll";
    int i = 3;
    if (!lstrcmpW(argv[i], L"--gate")) { if (i + 1 >= argc) return usage(); gate = argv[i + 1]; i += 2; }
    if (i + 1 >= argc || lstrcmpW(argv[i], L"--")) return usage();
    i++;

    if (!GetModuleFileNameW(NULL, self_path, MAX_PATH)) return 4;
    CreateDirectoryW(BASE, NULL);
    wsprintfW(launch_file, L"%s\\launch-%s", BASE, token);
    wsprintfA(line, "%lu\n", GetCurrentProcessId());
    if (!write_atomic(launch_file, line)) { err("mcphost: cannot write the launch confirmation"); return 4; }
    SetConsoleCtrlHandler(on_ctrl, TRUE);

    FILETIME c, e, k, u;
    GetProcessTimes(GetCurrentProcess(), &c, &e, &k, &u);
    wsprintfW(folder, L"%s\\%lu-%08lx%08lx", BASE, GetCurrentProcessId(), c.dwHighDateTime, c.dwLowDateTime);
    wsprintfW(scan_out, L"%s.scan", folder);
    wsprintfW(scan_tmp, L"%s.scan.tmp", folder);
    remove_stale_folders();
    if (!CreateDirectoryW(folder, NULL)) { err("mcphost: cannot create the marker folder"); cleanup(); return 4; }

    JOBOBJECT_EXTENDED_LIMIT_INFORMATION lim = { 0 };
    lim.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    job = CreateJobObjectW(NULL, NULL);
    if (!job || !SetInformationJobObject(job, JobObjectExtendedLimitInformation, &lim, sizeof(lim))) {
        err("mcphost: cannot create the job object"); cleanup(); return 4;
    }

    /* only the standard handles reach the server */
    HANDLE std[3], list[3];
    int nl = 0;
    std[0] = GetStdHandle(STD_INPUT_HANDLE); std[1] = GetStdHandle(STD_OUTPUT_HANDLE); std[2] = GetStdHandle(STD_ERROR_HANDLE);
    for (int j = 0; j < 3; j++) {
        if (!std[j] || std[j] == INVALID_HANDLE_VALUE) continue;
        int d; for (d = 0; d < nl && list[d] != std[j]; d++) ;
        if (d < nl) continue;
        if (SetHandleInformation(std[j], HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT)) list[nl++] = std[j];
    }
    SIZE_T asz = 0;
    InitializeProcThreadAttributeList(NULL, 1, 0, &asz);
    LPPROC_THREAD_ATTRIBUTE_LIST attrs = HeapAlloc(GetProcessHeap(), 0, asz);
    STARTUPINFOEXW si = { { sizeof(si) } };
    si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    si.StartupInfo.hStdInput = std[0]; si.StartupInfo.hStdOutput = std[1]; si.StartupInfo.hStdError = std[2];
    if (nl) {
        if (!attrs || !InitializeProcThreadAttributeList(attrs, 1, 0, &asz)
            || !UpdateProcThreadAttribute(attrs, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, list, nl * sizeof(HANDLE), NULL, NULL)) {
            err("mcphost: cannot limit the handles the server inherits"); cleanup(); return 4;
        }
        si.lpAttributeList = attrs;
    }
    SetEnvironmentVariableW(L"REVIT_MCP_PIPES", folder);
    WCHAR *cmd = command_line(argc - i, argv + i);
    PROCESS_INFORMATION pi;
    if (!cmd || !CreateProcessW(argv[i], cmd, NULL, NULL, nl > 0, CREATE_SUSPENDED | EXTENDED_STARTUPINFO_PRESENT,
                                NULL, NULL, &si.StartupInfo, &pi)) {
        wsprintfA(line, "mcphost: cannot start the MCP server (error %lu)", GetLastError());
        err(line); cleanup(); return 4;
    }
    SetEnvironmentVariableW(L"REVIT_MCP_PIPES", NULL);   /* not for the scan processes */
    if (!AssignProcessToJobObject(job, pi.hProcess)) {
        TerminateProcess(pi.hProcess, 4); err("mcphost: cannot put the MCP server in a job"); cleanup(); return 4;
    }
    ResumeThread(pi.hThread); CloseHandle(pi.hThread);
    ULONGLONG resumed = GetTickCount64();

    const char *stage = inject(&pi, gate, resumed + DEADLINE_MS, why);
    if (stage) {
        wsprintfA(line, "mcphost: cannot load mcppipes.dll into the MCP server: %.180s", stage);
        err(line);
        TerminateJobObject(job, 3);
        WaitForSingleObject(pi.hProcess, 5000);
        cleanup();
        return 3;
    }

    SCANNER s = { 0 };
    DWORD gen = 0;
    ULONGLONG next_scan = GetTickCount64(), scan_sig = 0, settled_sig = 0;
    BOOL found = FALSE, told = FALSE, settled = FALSE;   /* settled: the last scan found a pipe for every Revit.exe */
    int revits = 0;
    while (WaitForSingleObject(pi.hProcess, 100) == WAIT_TIMEOUT) {
        ULONGLONG now = GetTickCount64();
        if (s.proc) {
            if (WaitForSingleObject(s.proc, 0) == WAIT_OBJECT_0) {
                CloseHandle(s.proc); s.proc = NULL;
                if (!s.ended) {
                    int r = 0, n = scan_apply(gen, &r);
                    if (n >= 0) {
                        revits = r; if (n) found = TRUE;
                        settled = r > 0 && n >= r; settled_sig = scan_sig;
                    }
                }
                DeleteFileW(scan_out); DeleteFileW(scan_tmp);
            } else if (!s.ended && now - s.started > SCAN_LIMIT_MS) {
                TerminateProcess(s.proc, 1); s.ended = TRUE;
                WaitForSingleObject(s.proc, 2000);   /* the next round sees whether it is gone */
            } else if (s.ended && !s.warned && now - s.started > 10000) {
                err("mcphost: a pipe scan does not end; the pipe list is not refreshed until it does"); s.warned = TRUE;
            }
        }
        if (!s.proc && now >= next_scan) {
            ULONGLONG sig;
            next_scan = now + SCAN_EVERY_MS;
            revits_now(&sig);
            if (settled && (sig != settled_sig || markers_gone())) settled = FALSE;
            if (!settled) { scan_sig = sig; scan_start(&s, ++gen); }
        }
        if (!told && !found && revits && now - resumed >= NOTICE_AFTER_MS) {
            err("mcphost: the Revit MCP add-in has not opened its connection: Autodesk analytics (ADP) may be off, the add-in "
                "may not have loaded, or the Technical Preview has expired (May 2028)");
            told = TRUE;
        }
    }
    DWORD code = 1;
    GetExitCodeProcess(pi.hProcess, &code);
    if (s.proc) { TerminateProcess(s.proc, 1); WaitForSingleObject(s.proc, 2000); }
    cleanup();
    return (int)code;
}
