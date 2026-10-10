/*
 * SPDX-License-Identifier: MIT
 * tlbpin -- TOM type library (riched20) cache for Revit.exe; built as msls31.dll.
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
 * Loading: a Line Services shim that riched20 loads on its own (delay import); all 79 exports are
 * PE forwarders to the real msls31_ms.dll (msls31.def). AppInit_DLLs does not work in CrossOver 26.
 * Active only in Revit.exe or with the TLBPIN_FORCE=1 environment variable (for testing).
 * Diagnostics: OutputDebugString "[tlbpin]".
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <oleauto.h>

static const GUID LIBID_tom = {0x8cc497c9, 0xa1df, 0x11ce, {0x80, 0x98, 0x00, 0xaa, 0x00, 0x47, 0xbe, 0x5d}};

static ITypeLib *tom;            /* cached TOM, one permanent reference */
static WORD tom_maj, tom_min;
static LCID tom_lcid;
static SRWLOCK tom_lock = SRWLOCK_INIT;
static LONG hits;

static void trace(const char *fmt, ...)
{
    char buf[160];
    va_list ap;
    va_start(ap, fmt);
    wvsprintfA(buf, fmt, ap);
    va_end(ap);
    OutputDebugStringA(buf);
}

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
            trace("[tlbpin] LIBID_tom %u.%u lcid 0x%lx cached\n", maj, min, lcid);
        }
        ReleaseSRWLockExclusive(&tom_lock);
    }
    return hr;
}

static void install_hook(void)
{
    BYTE patch[12] = {0x48, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xe0}; /* mov rax, imm64; jmp rax */
    void *target = (void *)GetProcAddress(GetModuleHandleW(L"oleaut32.dll"), "LoadRegTypeLib");
    void *dest = (void *)hook_LoadRegTypeLib;
    DWORD old;
    if (!target) { trace("[tlbpin] oleaut32!LoadRegTypeLib not found\n"); return; }
    CopyMemory(patch + 2, &dest, sizeof(dest));
    if (!VirtualProtect(target, sizeof(patch), PAGE_EXECUTE_READWRITE, &old)) {
        trace("[tlbpin] VirtualProtect failed %lu\n", GetLastError());
        return;
    }
    CopyMemory(target, patch, sizeof(patch));
    VirtualProtect(target, sizeof(patch), old, &old);
    FlushInstructionCache(GetCurrentProcess(), target, sizeof(patch));
    trace("[tlbpin] oleaut32!LoadRegTypeLib %p -> hook %p\n", target, dest);
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
        }
    } else if (reason == DLL_PROCESS_DETACH && hits) {
        trace("[tlbpin] LIBID_tom cache hits: %ld\n", hits);
    }
    return TRUE;
}
