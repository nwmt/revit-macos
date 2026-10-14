/*
 * SPDX-License-Identifier: MIT
 * tlbpin -- Revit.exe speedups: TOM type library (riched20) cache and cursor position cache; built as msls31.dll.
 *
 * Problem: native riched20 calls LoadRegTypeLib(LIBID_tom) for every text element and releases the
 * ITypeLib right away. Wine's typelib cache only lives while a reference is held, so the .tlb from
 * riched20's resources is parsed again each time (~0.7 ms). With a held reference only the registry lookup
 * (QueryPathOfRegTypeLib) and the cache search remain, ~145 us. Profiling "creating area plans":
 * most main-thread samples are riched20 -> oleaut32 LoadRegTypeLib -> LoadTypeLibEx.
 *
 * Fix: a jump (mov rax, imm64; jmp rax) to hook_LoadRegTypeLib is written at the start of oleaut32!LoadRegTypeLib.
 * LIBID_tom with the same version/lcid is served from the cache (AddRef); other calls behave as in Wine:
 * QueryPathOfRegTypeLib + LoadTypeLib (neither is hooked). riched20 gets LoadRegTypeLib via
 * GetProcAddress, so the hook patches the function itself rather than the import table.
 *
 * Cursor position cache (Revit 2027): revitmfc polls the mouse during long edits (GetWindowRect, GetCursorPos,
 * GetAsyncKeyState, PtInRect) -- ~21 % of "modifying the group by adding a curtain wall". While the mouse is still,
 * Wine asks the macOS driver on every GetCursorPos (~12 us; on Windows < 1 us). win32u!NtUserGetCursorPos is
 * hooked the same way (its 32-byte syscall stub is position-independent and is copied to a trampoline); a position
 * is reused for CURSOR_TTL_MS. When the mouse moves, Wine updates the position from events anyway.
 *
 * Loading: a Line Services shim that riched20 loads on its own (delay import); all 79 exports are
 * PE forwarders to the real msls31_ms.dll (msls31.def). AppInit_DLLs does not work in CrossOver 26.
 * Active only in Revit.exe or with the TLBPIN_FORCE=1 environment variable (for testing).
 * Diagnostics: OutputDebugString "[tlbpin]".
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <oleauto.h>
#define SHIM_NAME "tlbpin"
#include "hook.h"

static const GUID LIBID_tom = {0x8cc497c9, 0xa1df, 0x11ce, {0x80, 0x98, 0x00, 0xaa, 0x00, 0x47, 0xbe, 0x5d}};

static ITypeLib *tom;            /* cached TOM, one permanent reference */
static WORD tom_maj, tom_min;
static LCID tom_lcid;
static SRWLOCK tom_lock = SRWLOCK_INIT;
static LONG hits;

/* like Wine's LoadRegTypeLib, but via unhooked exports */
static HRESULT load_reg_typelib(REFGUID guid, WORD maj, WORD min, LCID lcid, ITypeLib **out)
{
    BSTR path = NULL;
    HRESULT hr = QueryPathOfRegTypeLib(guid, maj, min, lcid, &path);
    if (SUCCEEDED(hr)) {
        hr = LoadTypeLib(path, out);
        SysFreeString(path);
    }
    return hr;
}

static HRESULT WINAPI hook_LoadRegTypeLib(REFGUID guid, WORD maj, WORD min, LCID lcid, ITypeLib **out)
{
    HRESULT hr;
    if (!out) return E_INVALIDARG;
    if (!IsEqualGUID(guid, &LIBID_tom)) return load_reg_typelib(guid, maj, min, lcid, out);

    AcquireSRWLockShared(&tom_lock);
    if (tom && tom_maj == maj && tom_min == min && tom_lcid == lcid) {
        tom->lpVtbl->AddRef(tom);
        *out = tom;
        ReleaseSRWLockShared(&tom_lock);
        InterlockedIncrement(&hits);
        return S_OK;
    }
    ReleaseSRWLockShared(&tom_lock);

    hr = load_reg_typelib(guid, maj, min, lcid, out);
    if (SUCCEEDED(hr)) {
        AcquireSRWLockExclusive(&tom_lock);
        if (!tom) {
            tom = *out;
            tom->lpVtbl->AddRef(tom);
            tom_maj = maj; tom_min = min; tom_lcid = lcid;
            trace("LIBID_tom %u.%u lcid 0x%lx cached\n", maj, min, lcid);
        }
        ReleaseSRWLockExclusive(&tom_lock);
    }
    return hr;
}

#define CURSOR_TTL_MS 10
static BYTE *cursor_tramp;                 /* copy of the original win32u!NtUserGetCursorPos stub */
static volatile LONG64 cursor_xy;          /* x in the low half, y in the high half */
static volatile ULONGLONG cursor_at;       /* GetTickCount64 of the last real query */
static LONG cursor_hits;

static BOOL WINAPI hook_NtUserGetCursorPos(POINT *pt)
{
    ULONGLONG now = GetTickCount64();
    BOOL ret;
    if (pt && now - cursor_at < CURSOR_TTL_MS) {
        LONG64 v = cursor_xy;
        pt->x = (LONG)v;
        pt->y = (LONG)(v >> 32);
        InterlockedIncrement(&cursor_hits);
        return TRUE;
    }
    ret = ((BOOL (WINAPI *)(POINT *))cursor_tramp)(pt);
    if (ret && pt) {
        cursor_xy = (LONG64)(ULONG)pt->x | ((LONG64)pt->y << 32);
        cursor_at = now;
    }
    return ret;
}

/* mov r10, rcx; mov eax, <n>; then Wine's fixed syscall tail (no RIP-relative addressing) */
static const BYTE stub_tail[24] = {0xf6, 0x04, 0x25, 0x08, 0x03, 0xfe, 0x7f, 0x01, 0x75, 0x03, 0x0f, 0x05,
                                   0xc3, 0xeb, 0x01, 0xc3, 0xff, 0x14, 0x25, 0x00, 0x10, 0xfe, 0x7f, 0xc3};

static void install_cursor_hook(void)
{
    BYTE *stub = (BYTE *)GetProcAddress(GetModuleHandleW(L"win32u.dll"), "NtUserGetCursorPos");
    DWORD old;
    if (!stub || stub[0] != 0x4c || stub[1] != 0x8b || stub[2] != 0xd1 || stub[3] != 0xb8 ||
        memcmp(stub + 8, stub_tail, sizeof(stub_tail))) {
        trace("win32u!NtUserGetCursorPos: unknown stub, not hooked\n");
        return;
    }
    cursor_tramp = VirtualAlloc(NULL, 4096, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!cursor_tramp) return;
    CopyMemory(cursor_tramp, stub, 32);
    VirtualProtect(cursor_tramp, 4096, PAGE_EXECUTE_READ, &old);
    FlushInstructionCache(GetCurrentProcess(), cursor_tramp, 32);
    write_jump(stub, (void *)hook_NtUserGetCursorPos);
    trace("win32u!NtUserGetCursorPos %p -> hook %p (cache %u ms)\n", stub, (void *)hook_NtUserGetCursorPos,
          CURSOR_TTL_MS);
}

static void install_hook(void)
{
    void *target = (void *)GetProcAddress(GetModuleHandleW(L"oleaut32.dll"), "LoadRegTypeLib");
    if (!target) { trace("oleaut32!LoadRegTypeLib not found\n"); return; }
    if (write_jump(target, (void *)hook_LoadRegTypeLib))
        trace("oleaut32!LoadRegTypeLib %p -> hook %p\n", target, (void *)hook_LoadRegTypeLib);
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, void *reserved)
{
    if (reason == DLL_PROCESS_ATTACH) {
        WCHAR exe[MAX_PATH], *base;
        DisableThreadLibraryCalls(inst);
        GetModuleFileNameW(NULL, exe, MAX_PATH);
        base = wcsrchr(exe, L'\\');
        if ((base && !lstrcmpiW(base + 1, L"Revit.exe")) || GetEnvironmentVariableW(L"TLBPIN_FORCE", NULL, 0)) {
            /* oleaut32 is our static import and already loaded; patching loads no DLL, so it's safe under loader lock */
            GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_PIN | GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
                               (LPCWSTR)DllMain, &(HMODULE){0}); /* the hook code must never be unloaded */
            install_hook();
            install_cursor_hook();
        }
    } else if (reason == DLL_PROCESS_DETACH && (hits || cursor_hits)) {
        trace("LIBID_tom cache hits: %ld, cursor cache hits: %ld\n", hits, cursor_hits);
    }
    return TRUE;
}
