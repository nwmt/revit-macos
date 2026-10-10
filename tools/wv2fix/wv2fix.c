/*
 * SPDX-License-Identifier: MIT
 * wv2fix -- CrossOver 26.3 Wine fix inside WebView2 browser processes (msedgewebview2.exe).
 * Gets into the process as version.dll from the WebView2 runtime folder (msedge.dll imports VERSION.dll; AppDefaults
 * msedgewebview2.exe version=native,builtin). All version.dll functions forward to version_orig.dll, a copy of
 * Wine's builtin version.dll (version.def). Installed by scripts/install-odis.sh, step wv2fix.
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
 */
#include <windows.h>

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

static void trace(const char *s) { OutputDebugStringA(s); }

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
    if (InterlockedIncrement(&peeked) == 1) trace("[wv2fix] PeekMessage before changing a window in another process\n");
}

static BOOL skip_style(HWND hwnd, int index, LONG_PTR value)
{
    DWORD pid;
    if (index != GWL_STYLE) return FALSE;
    if ((GetWindowLongPtrW(hwnd, GWL_STYLE) ^ value) != WS_VISIBLE) return FALSE; /* more than WS_VISIBLE changes */
    if (!(pid = foreign_parent(hwnd))) return FALSE;
    if (InterlockedIncrement(&skipped) <= 5) {
        char msg[200];
        wsprintfA(msg, "[wv2fix] skip SetWindowLong(GWL_STYLE) %p: WS_VISIBLE only, parent in process %lu\n", hwnd, pid);
        trace(msg);
    }
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
    if (InterlockedIncrement(&nooped) <= 5) {
        char msg[200];
        wsprintfA(msg, "[wv2fix] skip no-op SetWindowPos %p (%d,%d %dx%d)\n", hwnd, x, y, cx, cy);
        trace(msg);
    }
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

/* as in tools/rvtfix: an export entry is an RVA from the module base, so the thunk must be within 4 GB above it */
static BYTE *alloc_near(BYTE *base, SIZE_T size)
{
    MEMORY_BASIC_INFORMATION mbi;
    BYTE *p = base;
    while (p < base + 0x7fff0000 && VirtualQuery(p, &mbi, sizeof(mbi))) {
        if (mbi.State == MEM_FREE) {
            BYTE *a = (BYTE *)(((ULONG_PTR)mbi.BaseAddress + 0xffff) & ~(ULONG_PTR)0xffff);
            if (a + size <= (BYTE *)mbi.BaseAddress + mbi.RegionSize) {
                BYTE *r = VirtualAlloc(a, size, MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE);
                if (r) return r;
            }
        }
        p = (BYTE *)mbi.BaseAddress + mbi.RegionSize;
    }
    return NULL;
}

static BOOL patch_export(HMODULE mod, const char *name, void *hook, void **orig, BYTE *thunk)
{
    BYTE *base = (BYTE *)mod;
    IMAGE_NT_HEADERS *nt = (IMAGE_NT_HEADERS *)(base + ((IMAGE_DOS_HEADER *)base)->e_lfanew);
    IMAGE_DATA_DIRECTORY dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT];
    IMAGE_EXPORT_DIRECTORY *exp = (IMAGE_EXPORT_DIRECTORY *)(base + dir.VirtualAddress);
    DWORD *names = (DWORD *)(base + exp->AddressOfNames), *funcs = (DWORD *)(base + exp->AddressOfFunctions);
    WORD *ords = (WORD *)(base + exp->AddressOfNameOrdinals);
    DWORD i, old;
    for (i = 0; i < exp->NumberOfNames; i++) {
        if (lstrcmpA((char *)(base + names[i]), name)) continue;
        DWORD *slot = &funcs[ords[i]];
        *orig = base + *slot;
        BYTE jmp[12] = {0x48, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xe0}; /* mov rax, imm64; jmp rax */
        CopyMemory(jmp + 2, &hook, sizeof(hook));
        CopyMemory(thunk, jmp, sizeof(jmp));
        if (!VirtualProtect(slot, sizeof(*slot), PAGE_READWRITE, &old)) return FALSE;
        *slot = (DWORD)(thunk - base);
        VirtualProtect(slot, sizeof(*slot), old, &old);
        return TRUE;
    }
    return FALSE;
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, void *reserved)
{
    if (reason == DLL_PROCESS_ATTACH) {
        char v[8];
        DisableThreadLibraryCalls(inst);
        if (GetEnvironmentVariableA("WV2FIX", v, sizeof(v)) && v[0] == '0') return TRUE;
        GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_PIN | GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
                           (LPCWSTR)DllMain, &(HMODULE){0}); /* thunks point here, so never unload */
        HMODULE user = LoadLibraryW(L"user32.dll");
        BYTE *thunks = user ? alloc_near((BYTE *)user, 0x1000) : NULL;
        if (thunks && patch_export(user, "SetWindowLongW", (void *)hook_setlong, (void **)&orig_setlong, thunks) &&
            patch_export(user, "SetWindowLongPtrW", (void *)hook_setlongptr, (void **)&orig_setlongptr, thunks + 16) &&
            patch_export(user, "SetWindowPos", (void *)hook_setpos, (void **)&orig_setpos, thunks + 32) &&
            patch_export(user, "MoveWindow", (void *)hook_move, (void **)&orig_move, thunks + 48) &&
            patch_export(user, "ShowWindow", (void *)hook_show, (void **)&orig_show, thunks + 64) &&
            patch_export(user, "EndDeferWindowPos", (void *)hook_enddefer, (void **)&orig_enddefer, thunks + 80)) {
            FlushInstructionCache(GetCurrentProcess(), thunks, 96);
            trace("[wv2fix] user32: SetWindowPos/MoveWindow/ShowWindow/SetWindowLong*/EndDeferWindowPos -- PeekMessage for windows in another process\n");
        } else trace("[wv2fix] user32: hooking failed\n");
    }
    return TRUE;
}
