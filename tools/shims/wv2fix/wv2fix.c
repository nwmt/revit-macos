/*
 * SPDX-License-Identifier: MIT
 * wv2fix -- CrossOver 26.3 Wine fix inside WebView2 browser processes (msedgewebview2.exe).
 * Gets into the process as version.dll from the WebView2 runtime folder (msedge.dll imports VERSION.dll; AppDefaults
 * msedgewebview2.exe version=native,builtin). All version.dll functions forward to version_orig.dll, a copy of
 * Wine's builtin version.dll (version.def). Installed by the step wv2fix (scripts/steps/fixes.sh).
 *
 * Browser crash inside Revit (start screen, Project Browser 2027): on click Chromium does a "redraw lock" --
 * clears and restores WS_VISIBLE on its window via SetWindowLong(GWL_STYLE). The window is a child of a window in ANOTHER
 * process (Revit); restoring WS_VISIBLE makes CrossOver create a shared surface (create_shm_surface) and flush it to the
 * screen while holding the USER lock -> "err:system:user_check_not_lock BUG: holding USER lock", assert, the browser
 * crashes and Revit recreates it ("reloads").
 * The same assert fires on other changes to such a window: SetWindowPos with the same coordinates (Chromium calls it
 * often), clip changes (shm_surface_set_clip). Common cause: CrossOver flushes a dirty shared surface under the lock.
 * Reproduced without Revit/Chromium with two plain processes: the second one crashes with 0x80000101;
 * with PeekMessage(PM_NOREMOVE) before the change it doesn't (the surface is flushed beforehand, outside the lock).
 * Fix: in user32's exports replace SetWindowPos, MoveWindow, ShowWindow, SetWindowLongW/SetWindowLongPtrW,
 * EndDeferWindowPos: for a window whose parent is in another process, call PeekMessage(PM_NOREMOVE) first. A style change
 * that only toggles WS_VISIBLE (Chromium's redraw lock) is skipped entirely for such a window (the old style is returned).
 * No-op SetWindowPos/MoveWindow (same position and size, no show/hide/frame change) is skipped for such a window too:
 * when "reusing" the surface CrossOver marks the whole window dirty and flushes it under the lock
 * (Manage Links: "NtUserSetWindowPos hwnd ..., 0,0 (1499x908)" with the same rect -> whole window dirty -> assert).
 * "Window in another process" means any window with an ancestor owned by another process (Collaborate -> Issues:
 * Chromium resizes the panel, CrossOver copies it into a new, fully dirty surface, then resizing the panel's child
 * window takes the parent's surface and flushes it under the lock). PeekMessage both before and after the change.
 * Disable: WV2FIX=0 environment variable.
 *
 * In a program that embeds WebView2 (AppDefaults <exe> version=native,builtin; Enscape.RendererHost.exe for its Asset
 * Library) this DLL also loads tools/shims/rvtfix if rvtfix.dll sits next to the exe: rvtfix gives the browser the same
 * arguments as in Revit, and it has to be in place before the program creates its WebView2 environment. The program
 * reads its own file version at startup, which loads version.dll early enough.
 *
 * Diagnostics: OutputDebugString with the "[wv2fix]" prefix (CX_DEBUGMSG=+debugstr).
 */
#include <windows.h>
#define SHIM_NAME "wv2fix"
#include "hook.h"

typedef LONG (WINAPI *setlong_fn)(HWND, int, LONG);
typedef LONG_PTR (WINAPI *setlongptr_fn)(HWND, int, LONG_PTR);
typedef BOOL (WINAPI *setpos_fn)(HWND, HWND, int, int, int, int, UINT);
typedef BOOL (WINAPI *move_fn)(HWND, int, int, int, int, BOOL);
typedef BOOL (WINAPI *show_fn)(HWND, int);
typedef BOOL (WINAPI *enddefer_fn)(HDWP);
static setlong_fn orig_setlong;
static setlongptr_fn orig_setlongptr;
static setpos_fn orig_setpos;
static move_fn orig_move;
static show_fn orig_show;
static enddefer_fn orig_enddefer;
static LONG skipped, peeked;

static DWORD foreign_parent(HWND hwnd) /* pid of the other process owning the nearest such ancestor, or 0 */
{
    DWORD pid;
    HWND desk = GetDesktopWindow(), parent;
    int depth = 0;
    while (hwnd && depth++ < 32 && (parent = GetAncestor(hwnd, GA_PARENT)) && parent != desk) {
        pid = 0; GetWindowThreadProcessId(parent, &pid);
        if (pid && pid != GetCurrentProcessId()) return pid;
        hwnd = parent;
    }
    return 0;
}

static void pre_flush(HWND hwnd) /* flush surfaces beforehand, outside the USER lock */
{
    MSG m;
    if (hwnd && !foreign_parent(hwnd)) return;
    PeekMessageW(&m, NULL, 0, 0, PM_NOREMOVE);
    if (InterlockedIncrement(&peeked) == 1) trace("PeekMessage before changing a window in another process\n");
}

static BOOL skip_style(HWND hwnd, int index, LONG_PTR value)
{
    DWORD pid;
    if (index != GWL_STYLE) return FALSE;
    if ((GetWindowLongPtrW(hwnd, GWL_STYLE) ^ value) != WS_VISIBLE) return FALSE; /* more than WS_VISIBLE changes */
    if (!(pid = foreign_parent(hwnd))) return FALSE;
    if (InterlockedIncrement(&skipped) <= 5)
        trace("skip SetWindowLong(GWL_STYLE) %p: WS_VISIBLE only, parent in process %lu\n", hwnd, pid);
    return TRUE;
}

static LONG WINAPI hook_setlong(HWND hwnd, int index, LONG value)
{
    if (skip_style(hwnd, index, value)) return (LONG)GetWindowLongPtrW(hwnd, GWL_STYLE);
    if (index != GWL_STYLE && index != GWL_EXSTYLE) return orig_setlong(hwnd, index, value);
    pre_flush(hwnd);
    LONG ret = orig_setlong(hwnd, index, value);
    pre_flush(hwnd);
    return ret;
}

static LONG_PTR WINAPI hook_setlongptr(HWND hwnd, int index, LONG_PTR value)
{
    if (skip_style(hwnd, index, value)) return GetWindowLongPtrW(hwnd, GWL_STYLE);
    if (index != GWL_STYLE && index != GWL_EXSTYLE) return orig_setlongptr(hwnd, index, value);
    pre_flush(hwnd);
    LONG_PTR ret = orig_setlongptr(hwnd, index, value);
    pre_flush(hwnd);
    return ret;
}

static LONG nooped;
static BOOL same_rect(HWND hwnd, int x, int y, int cx, int cy, UINT flags) /* would SetWindowPos change nothing? */
{
    RECT r;
    HWND parent;
    if (flags & (SWP_SHOWWINDOW | SWP_HIDEWINDOW | SWP_FRAMECHANGED)) return FALSE;
    if (!(flags & SWP_NOZORDER)) return FALSE;
    if (!foreign_parent(hwnd) || !GetWindowRect(hwnd, &r)) return FALSE;
    parent = GetAncestor(hwnd, GA_PARENT);
    MapWindowPoints(HWND_DESKTOP, parent, (POINT *)&r, 2);
    if (!(flags & SWP_NOMOVE) && (r.left != x || r.top != y)) return FALSE;
    if (!(flags & SWP_NOSIZE) && (r.right - r.left != cx || r.bottom - r.top != cy)) return FALSE;
    if (InterlockedIncrement(&nooped) <= 5)
        trace("skip no-op SetWindowPos %p (%d,%d %dx%d)\n", hwnd, x, y, cx, cy);
    return TRUE;
}

static BOOL WINAPI hook_setpos(HWND hwnd, HWND after, int x, int y, int cx, int cy, UINT flags)
{
    if (same_rect(hwnd, x, y, cx, cy, flags)) return TRUE;
    pre_flush(hwnd);
    BOOL ret = orig_setpos(hwnd, after, x, y, cx, cy, flags);
    pre_flush(hwnd); /* flush the fresh surface right away, outside the lock */
    return ret;
}

static BOOL WINAPI hook_move(HWND hwnd, int x, int y, int cx, int cy, BOOL repaint)
{
    if (same_rect(hwnd, x, y, cx, cy, SWP_NOZORDER)) return TRUE;
    pre_flush(hwnd);
    BOOL ret = orig_move(hwnd, x, y, cx, cy, repaint);
    pre_flush(hwnd); /* flush the fresh surface right away, outside the lock */
    return ret;
}

static BOOL WINAPI hook_show(HWND hwnd, int cmd)
{
    pre_flush(hwnd);
    BOOL ret = orig_show(hwnd, cmd);
    pre_flush(hwnd); /* flush the fresh surface right away, outside the lock */
    return ret;
}

static BOOL WINAPI hook_enddefer(HDWP hdwp) /* windows inside HDWP are not visible to us, so always flush */
{
    pre_flush(NULL);
    BOOL ret = orig_enddefer(hdwp);
    pre_flush(NULL);
    return ret;
}

static const struct { const char *name; void *hook; void **orig; } hooks[] = {
    {"SetWindowLongW", (void *)hook_setlong, (void **)&orig_setlong},
    {"SetWindowLongPtrW", (void *)hook_setlongptr, (void **)&orig_setlongptr},
    {"SetWindowPos", (void *)hook_setpos, (void **)&orig_setpos},
    {"MoveWindow", (void *)hook_move, (void **)&orig_move},
    {"ShowWindow", (void *)hook_show, (void **)&orig_show},
    {"EndDeferWindowPos", (void *)hook_enddefer, (void **)&orig_enddefer},
};

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, void *reserved)
{
    if (reason == DLL_PROCESS_ATTACH) {
        char v[8];
        WCHAR p[MAX_PATH], *slash;
        DisableThreadLibraryCalls(inst);
        if (GetModuleFileNameW(NULL, p, MAX_PATH) && (slash = wcsrchr(p, L'\\')) && slash - p < MAX_PATH - 12 &&
            lstrcmpiW(slash + 1, L"msedgewebview2.exe")) {
            lstrcpyW(slash + 1, L"rvtfix.dll");
            if (GetFileAttributesW(p) != INVALID_FILE_ATTRIBUTES)
                trace(LoadLibraryW(p) ? "rvtfix.dll next to the exe: loaded\n" : "rvtfix.dll next to the exe: failed\n");
        }
        if (GetEnvironmentVariableA("WV2FIX", v, sizeof(v)) && v[0] == '0') return TRUE;
        GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_PIN | GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
                           (LPCWSTR)DllMain, &(HMODULE){0}); /* thunks point here, so never unload */
        HMODULE user = LoadLibraryW(L"user32.dll");
        BYTE *thunks = user ? alloc_near((BYTE *)user, 0x1000) : NULL;
        int i, ok = 0, n = (int)(sizeof(hooks) / sizeof(hooks[0]));
        for (i = 0; thunks && i < n; i++) {
            if (patch_export(user, hooks[i].name, hooks[i].hook, hooks[i].orig, thunks + 16 * i)) ok++;
            else trace("user32!%s: not hooked\n", hooks[i].name);
        }
        if (thunks) FlushInstructionCache(GetCurrentProcess(), thunks, 16 * n);
        if (ok == n)
            trace("user32: SetWindowPos/MoveWindow/ShowWindow/SetWindowLong*/EndDeferWindowPos -- PeekMessage for windows in another process\n");
        else trace("user32: hooking failed\n");
    }
    return TRUE;
}
