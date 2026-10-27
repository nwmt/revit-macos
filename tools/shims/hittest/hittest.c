/*
 * SPDX-License-Identifier: MIT
 * hittest -- answers "which Windows window is under this point" for the menu bar app's trackpad gestures. The app turns
 * two-finger scrolling into a middle-button drag only over Revit's views; macOS sees one window for all of Revit, so
 * the window under the cursor has to be asked inside the bottle. scripts/hittest-launch.sh (./revit hittest) runs it
 * from the app (or this checkout), by its Mac path: nothing is copied into the bottle.
 *
 *   hittest.exe --ready <file> <year>
 *
 * It finds the bottle's Revit.exe and waits on it: when Revit ends, hittest ends too, so it never keeps a bottle busy
 * longer than Revit does. Then it creates <file> (empty; the launcher waits for it) and talks on stdin/stdout, one line
 * each way, UTF-8, "\n". Protocol version 1:
 *
 *   hello 1 <vx> <vy> <vw> <vh>       first line out: the virtual screen in Wine's coordinates (DPI aware)
 *   <seq> <x> <y>                     a request: a point in Wine's coordinates; seq is echoed
 *   <seq>\t<class>\t<title>...\t.     the answer: the window under the point, then its parents up to the top-level
 *                                     window (at most 8), each as class and title; "." the chain is complete, "+" it
 *                                     was cut at 8. No window: "<seq>\t.". Tabs and line breaks in a title become
 *                                     spaces, titles keep at most 128 characters
 *   <seq or 0>\t?                     a line that is not a request; a line over 4096 bytes is skipped up to its "\n"
 *   quit                              ends it, as end of input does
 *
 * Example:  > hello 1 0 0 3024 1964   < 7 1512 900
 *           > 7  AfxFrameOrView140u  (no title)  AfxMDIFrame140u  Floor Plan: L1  ...  .      (fields split by tabs)
 *
 * Exit code: 0 (end of input, quit, Revit ended), 2 usage, 3 no Revit.exe in this bottle, 4 the ready file could not be
 * written. Messages go to stderr.
 */
#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <stdlib.h>

#define MAX_LINE 4096
#define MAX_DEPTH 8
#define MAX_TITLE 128

static HANDLE out;

static void put(const char *s, DWORD n)
{
    DWORD w;
    WriteFile(out, s, n, &w, NULL);
}

static void say(const char *s) { put(s, (DWORD)strlen(s)); }

/* one field: UTF-8 of at most MAX_TITLE characters, tabs and line breaks as spaces, after a tab */
static void field(const WCHAR *w)
{
    WCHAR clean[MAX_TITLE + 1];
    char utf8[MAX_TITLE * 4 + 2];
    int i, n;
    for (i = 0; i < MAX_TITLE && w[i]; i++) clean[i] = (w[i] == L'\t' || w[i] == L'\r' || w[i] == L'\n') ? L' ' : w[i];
    clean[i] = 0;
    utf8[0] = '\t';
    n = WideCharToMultiByte(CP_UTF8, 0, clean, -1, utf8 + 1, sizeof utf8 - 1, NULL, NULL);
    if (n <= 0) utf8[1] = 0;
    say(utf8);
}

static void answer(long seq, POINT p)
{
    char head[32];
    WCHAR cls[256], title[MAX_TITLE + 1];
    HWND h = WindowFromPoint(p), desk = GetDesktopWindow();
    int depth;
    snprintf(head, sizeof head, "%ld", seq);
    say(head);
    for (depth = 0; h && h != desk && depth < MAX_DEPTH; depth++) {
        cls[0] = title[0] = 0;
        GetClassNameW(h, cls, 256);
        GetWindowTextW(h, title, MAX_TITLE + 1);   /* another process's window: read without a message */
        field(cls);
        field(title);
        h = GetAncestor(h, GA_PARENT);
    }
    say(h && h != desk ? "\t+\n" : "\t.\n");
}

static int number(const char **s, long *v)   /* a signed decimal, then a space or the end */
{
    char *end;
    if (!**s || **s == ' ') return 0;
    *v = strtol(*s, &end, 10);
    if (end == *s || (*end && *end != ' ')) return 0;
    *s = *end ? end + 1 : end;
    return 1;
}

static void line(const char *s)
{
    long seq = 0, x, y;
    const char *p = s;
    char bad[32];
    POINT pt;
    if (!strcmp(s, "quit")) ExitProcess(0);
    if (number(&p, &seq) && number(&p, &x) && number(&p, &y) && !*p) {
        pt.x = x; pt.y = y;
        answer(seq, pt);
        return;
    }
    p = s;
    if (!number(&p, &seq)) seq = 0;
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

static HANDLE find_revit(void)
{
    PROCESSENTRY32W e = { .dwSize = sizeof e };
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0), p = NULL;
    if (snap == INVALID_HANDLE_VALUE) return NULL;
    for (BOOL ok = Process32FirstW(snap, &e); ok && !p; ok = Process32NextW(snap, &e))
        if (!_wcsicmp(e.szExeFile, L"Revit.exe")) p = OpenProcess(SYNCHRONIZE, FALSE, e.th32ProcessID);
    CloseHandle(snap);
    return p;
}

int wmain(int argc, WCHAR **argv)
{
    HANDLE revit, ready, waits[2];
    char hello[96];
    if (argc != 4 || wcscmp(argv[1], L"--ready") || wcslen(argv[3]) != 4) {
        fprintf(stderr, "usage: hittest.exe --ready <file> <year>\n");
        return 2;
    }
    if (!(revit = find_revit())) { fprintf(stderr, "hittest: no Revit.exe in this bottle\n"); return 3; }
    SetProcessDPIAware();
    out = GetStdHandle(STD_OUTPUT_HANDLE);
    ready = CreateFileW(argv[2], GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (ready == INVALID_HANDLE_VALUE) { fprintf(stderr, "hittest: cannot write the ready file\n"); return 4; }
    CloseHandle(ready);
    snprintf(hello, sizeof hello, "hello 1 %d %d %d %d\n", GetSystemMetrics(SM_XVIRTUALSCREEN),
             GetSystemMetrics(SM_YVIRTUALSCREEN), GetSystemMetrics(SM_CXVIRTUALSCREEN), GetSystemMetrics(SM_CYVIRTUALSCREEN));
    say(hello);
    waits[0] = revit;
    waits[1] = CreateThread(NULL, 0, reader, NULL, 0, NULL);
    if (!waits[1]) return 0;
    WaitForMultipleObjects(2, waits, FALSE, INFINITE);   /* Revit ended, or the input did */
    return 0;
}
