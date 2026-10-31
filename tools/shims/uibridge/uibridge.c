/*
 * SPDX-License-Identifier: MIT
 * uibridge -- the windows of a running Revit for tools/ui_server.py: what is open, what a dialog says, a command to run,
 * a button to press. scripts/uibridge-launch.sh runs it by its Mac path: nothing is copied into the bottle.
 *
 *   uibridge.exe --ready <file> <year>
 *
 * It finds the bottle's Revit.exe and waits on it: when Revit ends, or its input does, it ends too. Then it creates
 * <file> (empty; the launcher waits for it) and talks on stdin/stdout, UTF-8, "\n". Protocol version 1. Coordinates are
 * physical pixels (the process is per-monitor DPI aware), hwnds are hexadecimal.
 *
 *   hello 1 <vx> <vy> <vw> <vh>     first line out: the virtual screen
 *   <seq>\t<verb>\t<args>...        a request
 *   <seq>\t+\t<fields>...           zero or more lines of its answer
 *   <seq>\t<status>\t<fields>...    its last line; status: ok, busy, blocked, refused, error
 *   <seq or 0>\t?                   a line that is not a request; a line over 4096 bytes is skipped up to its "\n"
 *   quit                            ends it, as end of input does
 *
 * Tabs and line breaks in a value become spaces. <rect> is l,t,r,b. Requests:
 *
 *   state                 + dialog <hwnd> <class> <title> <enabled> <modeless> <rect> for each dialog, then
 *                         ok <main hwnd or 0> <title> <enabled> <responds> <rect>
 *   dialog <hwnd>         + <hwnd> <class> <text> <enabled> <visible> <rect> for each control, then ok <hwnd> <title>
 *   command <id>          WM_COMMAND to the main window, if it is enabled and answers: ok posted, else blocked <why>
 *   press <hwnd>          BM_CLICK to a button of Revit: ok pressed
 *   settext <hwnd> <text> WM_SETTEXT to an Edit of Revit: ok <the text read back>
 *
 * A hwnd of another process is refused, so a stale hwnd that now names another program's window does nothing.
 *
 * Exit code: 0 (end of input, quit, Revit ended), 2 usage, 3 no Revit.exe in this bottle, 4 the ready file could not be
 * written, 5 more than one Revit.exe. Messages go to stderr.
 */
#define _WIN32_WINNT 0x0A00
#define WINVER 0x0A00
#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_LINE 4096
#define MAX_TEXT 2048
#define RESPOND_MS 500   /* how long a window has to answer before it counts as busy */
#define SEND_MS 2000

static HANDLE out;
static DWORD revit_pid;

static void put(const char *s, DWORD n)
{
    DWORD w;
    WriteFile(out, s, n, &w, NULL);
}

static void say(const char *s) { put(s, (DWORD)strlen(s)); }

static void num(long v)
{
    char b[32];
    snprintf(b, sizeof b, "%ld", v);
    say(b);
}

static void hexv(HWND h)
{
    char b[32];
    snprintf(b, sizeof b, "\t%llx", (unsigned long long)(ULONG_PTR)h);
    say(b);
}

static void bit(int v) { say(v ? "\t1" : "\t0"); }

/* one field after a tab: UTF-8, tabs and line breaks as spaces */
static void field(const WCHAR *w)
{
    static WCHAR clean[MAX_TEXT + 1];
    static char utf8[MAX_TEXT * 4 + 2];
    int i, n;
    for (i = 0; i < MAX_TEXT && w[i]; i++) clean[i] = (w[i] == L'\t' || w[i] == L'\r' || w[i] == L'\n') ? L' ' : w[i];
    clean[i] = 0;
    utf8[0] = '\t';
    n = WideCharToMultiByte(CP_UTF8, 0, clean, -1, utf8 + 1, sizeof utf8 - 1, NULL, NULL);
    if (n <= 0) utf8[1] = 0;
    say(utf8);
}

static void rect(HWND h)
{
    RECT r = {0};
    char b[64];
    GetWindowRect(h, &r);
    snprintf(b, sizeof b, "\t%ld,%ld,%ld,%ld", r.left, r.top, r.right, r.bottom);
    say(b);
}

static void head(long seq, const char *status)
{
    num(seq);
    say("\t");
    say(status);
}

static void finish(long seq, const char *status, const char *why)
{
    head(seq, status);
    if (why) { say("\t"); say(why); }
    say("\n");
}

static int ours(HWND h)
{
    DWORD pid = 0;
    if (!h || !IsWindow(h)) return 0;
    GetWindowThreadProcessId(h, &pid);
    return pid == revit_pid;
}

static int responds(HWND h)
{
    DWORD_PTR r;
    return SendMessageTimeoutW(h, WM_NULL, 0, 0, SMTO_ABORTIFHUNG, RESPOND_MS, &r) != 0;
}

static void class_of(HWND h, WCHAR *c, int n)
{
    c[0] = 0;
    GetClassNameW(h, c, n);
}

static int is_main(HWND h)
{
    WCHAR c[64], t[32];
    class_of(h, c, 64);
    t[0] = 0;
    GetWindowTextW(h, t, 32);   /* another process's window: read without a message */
    return !wcsncmp(c, L"HwndWrapper", 11) && !wcsncmp(t, L"Autodesk Revit", 14);
}

static BOOL CALLBACK main_cb(HWND h, LPARAM l)
{
    if (ours(h) && IsWindowVisible(h) && is_main(h)) { *(HWND *)l = h; return FALSE; }
    return TRUE;
}

static HWND main_window(void)
{
    HWND h = NULL;
    EnumWindows(main_cb, (LPARAM)&h);
    return h;
}

static int a_dialog(HWND h)
{
    WCHAR c[64], t[8];
    class_of(h, c, 64);
    t[0] = 0;
    GetWindowTextW(h, t, 8);
    return t[0] && (!wcscmp(c, L"#32770") || !wcsncmp(c, L"HwndWrapper", 11));
}

struct listing { long seq; HWND main; int main_enabled; };

static BOOL CALLBACK dialog_cb(HWND h, LPARAM l)
{
    struct listing *a = (struct listing *)l;
    static WCHAR c[256], t[MAX_TEXT + 1];
    if (h == a->main || !ours(h) || !IsWindowVisible(h) || !a_dialog(h)) return TRUE;
    class_of(h, c, 256);
    t[0] = 0;
    GetWindowTextW(h, t, MAX_TEXT + 1);
    num(a->seq);
    say("\t+\tdialog");
    hexv(h);
    field(c);
    field(t);
    bit(IsWindowEnabled(h));
    bit(a->main_enabled);   /* with the main window usable it is a palette, not something Revit waits for */
    rect(h);
    say("\n");
    return TRUE;
}

static void do_state(long seq)
{
    struct listing a = { seq, main_window(), 0 };
    static WCHAR t[MAX_TEXT + 1];
    a.main_enabled = a.main && IsWindowEnabled(a.main);
    EnumWindows(dialog_cb, (LPARAM)&a);
    t[0] = 0;
    if (a.main) GetWindowTextW(a.main, t, MAX_TEXT + 1);
    head(seq, "ok");
    hexv(a.main);
    field(t);
    bit(a.main_enabled);
    bit(a.main && responds(a.main));
    if (a.main) rect(a.main); else say("\t0,0,0,0");
    say("\n");
}

static void edit_text(HWND h, WCHAR *t, int n)
{
    DWORD_PTR r = 0;
    t[0] = 0;
    if (!SendMessageTimeoutW(h, WM_GETTEXT, n, (LPARAM)t, SMTO_ABORTIFHUNG, SEND_MS, &r)) t[0] = 0;
}

struct controls { long seq; };

static BOOL CALLBACK control_cb(HWND h, LPARAM l)
{
    struct controls *a = (struct controls *)l;
    static WCHAR c[256], t[MAX_TEXT + 1];
    class_of(h, c, 256);
    t[0] = 0;
    if (!wcscmp(c, L"Edit")) edit_text(h, t, MAX_TEXT + 1);
    else GetWindowTextW(h, t, MAX_TEXT + 1);
    num(a->seq);
    say("\t+");
    hexv(h);
    field(c);
    field(t);
    bit(IsWindowEnabled(h));
    bit(IsWindowVisible(h));
    rect(h);
    say("\n");
    return TRUE;
}

static void do_dialog(long seq, HWND h)
{
    struct controls a = { seq };
    WCHAR c[64];
    static WCHAR t[MAX_TEXT + 1];
    if (!ours(h)) { finish(seq, "refused", "not a window of Revit"); return; }
    class_of(h, c, 64);
    if (wcscmp(c, L"#32770")) { finish(seq, "refused", "not a Win32 dialog"); return; }
    EnumChildWindows(h, control_cb, (LPARAM)&a);
    t[0] = 0;
    GetWindowTextW(h, t, MAX_TEXT + 1);
    head(seq, "ok");
    hexv(h);
    field(t);
    say("\n");
}

static void do_command(long seq, long id)
{
    HWND m = main_window();
    if (id <= 0 || id > 0xFFFF) { finish(seq, "refused", "not a command number"); return; }
    if (!m) { finish(seq, "blocked", "no main window"); return; }
    if (!IsWindowEnabled(m)) { finish(seq, "blocked", "a dialog is open"); return; }
    if (!responds(m)) { finish(seq, "blocked", "Revit does not answer"); return; }
    if (!PostMessageW(m, WM_COMMAND, (WPARAM)id, 0)) { finish(seq, "error", "PostMessage failed"); return; }
    finish(seq, "ok", "posted");
}

static void do_press(long seq, HWND h)
{
    WCHAR c[32];
    if (!ours(h)) { finish(seq, "refused", "not a window of Revit"); return; }
    class_of(h, c, 32);
    if (wcscmp(c, L"Button")) { finish(seq, "refused", "not a button"); return; }
    if (!IsWindowEnabled(h)) { finish(seq, "refused", "the button is disabled"); return; }
    if (!PostMessageW(h, BM_CLICK, 0, 0)) { finish(seq, "error", "PostMessage failed"); return; }
    finish(seq, "ok", "pressed");
}

static void do_settext(long seq, HWND h, const char *text)
{
    WCHAR c[32];
    static WCHAR w[MAX_TEXT + 1], back[MAX_TEXT + 1];
    DWORD_PTR r = 0;
    if (!ours(h)) { finish(seq, "refused", "not a window of Revit"); return; }
    class_of(h, c, 32);
    if (wcscmp(c, L"Edit")) { finish(seq, "refused", "not an edit field"); return; }
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, w, MAX_TEXT + 1)) {
        finish(seq, "refused", "the text is not valid or too long");
        return;
    }
    if (!SendMessageTimeoutW(h, WM_SETTEXT, 0, (LPARAM)w, SMTO_ABORTIFHUNG, SEND_MS, &r)) {
        finish(seq, "busy", "Revit does not answer");
        return;
    }
    edit_text(h, back, MAX_TEXT + 1);
    head(seq, "ok");
    field(back);
    say("\n");
}

static char *next_field(char **s)   /* cuts at the next tab; NULL when there is no field left */
{
    char *f = *s, *t;
    if (!f) return NULL;
    t = strchr(f, '\t');
    if (t) { *t = 0; *s = t + 1; } else *s = NULL;
    return f;
}

static int hwnd_of(const char *f, HWND *h)
{
    char *end;
    unsigned long long v;
    if (!f || !*f) return 0;
    v = strtoull(f, &end, 16);
    if (*end) return 0;
    *h = (HWND)(ULONG_PTR)v;
    return 1;
}

static void line(char *s)
{
    char *p = s, *fseq, *verb, *a, *end;
    char bad[32];
    long seq;
    HWND h;
    if (!strcmp(s, "quit")) ExitProcess(0);
    fseq = next_field(&p);
    verb = next_field(&p);
    seq = strtol(fseq ? fseq : "", &end, 10);
    if (!fseq || !*fseq || *end || !verb) goto badline;
    if (!strcmp(verb, "state") && !p) { do_state(seq); return; }
    if (!strcmp(verb, "dialog") && hwnd_of(next_field(&p), &h) && !p) { do_dialog(seq, h); return; }
    if (!strcmp(verb, "press") && hwnd_of(next_field(&p), &h) && !p) { do_press(seq, h); return; }
    if (!strcmp(verb, "settext") && hwnd_of(next_field(&p), &h) && p) { do_settext(seq, h, p); return; }
    if (!strcmp(verb, "command") && (a = next_field(&p)) && !p) {
        long id = strtol(a, &end, 10);
        if (*a && !*end) { do_command(seq, id); return; }
    }
badline:
    seq = strtol(s, &end, 10);
    snprintf(bad, sizeof bad, "%ld\t?\n", seq);
    say(bad);
}

static DWORD WINAPI reader(void *unused)   /* reads stdin; ends at its end */
{
    static char buf[MAX_LINE + 1];
    char chunk[1024];
    DWORD got, i, len = 0;
    int skipping = 0;
    HANDLE in = GetStdHandle(STD_INPUT_HANDLE);
    while (ReadFile(in, chunk, sizeof chunk, &got, NULL) && got) {
        for (i = 0; i < got; i++) {
            char c = chunk[i];
            if (c == '\n') {
                if (!skipping) {
                    if (len && buf[len - 1] == '\r') len--;
                    buf[len] = 0;
                    line(buf);
                }
                len = 0; skipping = 0;
            } else if (skipping) {
                continue;
            } else if (len == MAX_LINE) {
                say("0\t?\n");
                skipping = 1; len = 0;
            } else {
                buf[len++] = c;
            }
        }
    }
    return 0;
}

static int find_revit(HANDLE *revit)   /* how many Revit.exe run here; with one, *revit waits on it */
{
    PROCESSENTRY32W e = { .dwSize = sizeof e };
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    int n = 0;
    if (snap == INVALID_HANDLE_VALUE) return 0;
    for (BOOL ok = Process32FirstW(snap, &e); ok; ok = Process32NextW(snap, &e))
        if (!_wcsicmp(e.szExeFile, L"Revit.exe")) { n++; revit_pid = e.th32ProcessID; }
    CloseHandle(snap);
    if (n == 1) *revit = OpenProcess(SYNCHRONIZE, FALSE, revit_pid);
    return n;
}

int wmain(int argc, WCHAR **argv)
{
    HANDLE revit = NULL, ready, waits[2];
    char hello[96];
    int n;
    if (argc != 4 || wcscmp(argv[1], L"--ready") || wcslen(argv[3]) != 4) {
        fprintf(stderr, "usage: uibridge.exe --ready <file> <year>\n");
        return 2;
    }
    n = find_revit(&revit);
    if (n > 1) { fprintf(stderr, "uibridge: more than one Revit.exe in this bottle\n"); return 5; }
    if (!n || !revit) { fprintf(stderr, "uibridge: no Revit.exe in this bottle\n"); return 3; }
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    out = GetStdHandle(STD_OUTPUT_HANDLE);
    ready = CreateFileW(argv[2], GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (ready == INVALID_HANDLE_VALUE) { fprintf(stderr, "uibridge: cannot write the ready file\n"); return 4; }
    CloseHandle(ready);
    snprintf(hello, sizeof hello, "hello 1 %d %d %d %d\n", GetSystemMetrics(SM_XVIRTUALSCREEN),
             GetSystemMetrics(SM_YVIRTUALSCREEN), GetSystemMetrics(SM_CXVIRTUALSCREEN), GetSystemMetrics(SM_CYVIRTUALSCREEN));
    say(hello);
    waits[0] = revit;
    waits[1] = CreateThread(NULL, 0, reader, NULL, 0, NULL);
    if (!waits[1]) return 0;
    WaitForMultipleObjects(2, waits, FALSE, INFINITE);   /* Revit ended, or the input did */
    ExitProcess(0);
}
