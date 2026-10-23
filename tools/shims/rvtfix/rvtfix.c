/*
 * SPDX-License-Identifier: MIT
 * rvtfix -- fixes for Wine behavior inside the Revit process, made in memory: no Autodesk file is changed
 * (Autodesk assemblies are signed: Revit checks add-in .sig files and won't load modified ones -- "Verify failed!").
 * Loaded by our ncrypt.dll (tools/shims/ncryptshim) if it sits next to Revit.exe, and by our version.dll
 * (tools/shims/wv2fix) in AdPreviewGenerator.exe (material previews: fix 4) and in Enscape's renderer (fix 2).
 *
 * 1. RegisterDragDrop/RevokeDragDrop on a window of ANOTHER process.
 *    Revit 2026 start screen (ModelBrowser add-in): after WebView2 initializes,
 *    DragDropManager.RegisterDragDropHook calls RevokeDragDrop on the browser window (msedgewebview2.exe process).
 *    Windows returns DRAGDROP_E_INVALIDHWND; Wine's ole32 (CrossOver 26.3) reads the IDropTarget pointer from the
 *    foreign window's property and dereferences it locally -> AccessViolationException, Revit dies silently.
 *    Fix: replace the RegisterDragDrop/RevokeDragDrop entries in ole32's export table (GetProcAddress sees them,
 *    and .NET resolves P/Invoke through it). Already bound imports of other modules are left alone. Own windows get the original.
 *
 * 2. WebView2 browser arguments (start screen, Manage Links): CrossOver 26.3 (rule Hack 22330) appends
 *    "--in-process-gpu --use-gl=swiftshader" to msedgewebview2.exe -> the GPU thread keeps failing to create a GL
 *    context, the page stays white, ~60% CPU. Fixed by "--disable-gpu --disable-software-rasterizer
 *    --disable-features=ForceSWDCompWhenDCompFallbackRequired". Revit sets the arguments
 *    itself, so WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS never reaches the browser. Fix: in every loaded
 *    WebView2Loader.dll replace the CreateCoreWebView2EnvironmentWithOptions export and append the flags to
 *    AdditionalBrowserArguments of Revit's options. Custom flags: RVTFIX_WV2_ARGS; empty disables.
 *
 * 3. CefSharp browser (Revit 2023 start screen): Chromium's GPU process draws into Revit's window from another
 *    process, which winemac doesn't show -> the page loads (DevTools on port 8088 shows it) but the screen stays blank.
 *    "--in-process-gpu" keeps the GPU thread inside Revit. Revit sets CefSettings itself, but CEF also reads the
 *    browser process command line (GetCommandLineW), so give it ours plus the flag: replace the GetCommandLineW exports
 *    of kernelbase and kernel32 (Wine's returns its own copy, not the PEB string) before libcef.dll loads.
 *    Only in Revit.exe, and only if libcef.dll sits next to it (2025) or in its CefSharp folder (2023).
 *    2025 also gets "--disable-gpu": with only --in-process-gpu its start screen turns black after a few
 *    maximize/restore toggles (until the window is resized); software drawing keeps it right at the same speed.
 *    Not tried on 2023 yet, so 2023 keeps the flag it was tested with.
 *    Custom flags: RVTFIX_CEF_ARGS; empty disables.
 *
 * 4. Material browser: OGSDeviceDX11.dll asks D3D11 for a WARP device, which D3DMetal lacks -> "Can't get OGS device",
 *    the dialog does not open. Our d3dwp.dll (tools/shims/d3dwp) asks for HARDWARE instead. Fix: in the loaded
 *    OGSDeviceDX11.dll replace the name it loads, L"D3D11.dll", with L"d3dwp.dll" (same length).
 *    Only if d3dwp.dll sits next to Revit.exe.
 *
 * 5. DesktopMFC.dll imports USER32!SetDialogControlDpiChangeBehavior (Win10 1703+), missing in CrossOver 26.3 Wine ->
 *    the loader binds a stub; opening a view raises EXCEPTION_WINE_STUB, the project closes, Revit crashes.
 *    Fix: bind the import to USER32!IsWindow (same registers, no side effects, TRUE for a live window): rename it in
 *    the import table if the loader has not bound it yet, otherwise put IsWindow into its import address table slot.
 *
 * 6. WebView2 host window destroyed with the browser's window inside (Dynamo 4.2 in 2027: its splash screen closes):
 *    the browser (msedgewebview2.exe) puts its own top-level Chrome_WidgetWin_1 into the client's Chrome_WidgetWin_0
 *    with SetParent. When the WebView closes, the client destroys its host window; Wine destroys the browser's window
 *    with it, in the browser process, and Chromium frees its window objects. The "WebView closed" message that comes
 *    next makes Chromium hide or close those freed objects (aura::Window::Hide, HWNDMessageHandler::Close: IsWindow is
 *    TRUE, delegate_ is null) -> the browser crashes, every page it serves goes with it, Dynamo crashes.
 *    Fix: replace user32's DestroyWindow export; before a window of ours is destroyed, move the Chrome_WidgetWin_*
 *    windows of another process inside it to HWND_MESSAGE. The browser then closes them itself.
 *
 * 4 and 5 run when the DLL loads (LdrRegisterDllNotification), or at once if it is already loaded.
 *
 * Diagnostics: OutputDebugString with the "[rvtfix]" prefix (CX_DEBUGMSG=+debugstr).
 */
#include <windows.h>
#include <ole2.h>
#include <winternl.h>
#define SHIM_NAME "rvtfix"
#include "hook.h"

typedef HRESULT (WINAPI *revoke_fn)(HWND);
typedef HRESULT (WINAPI *register_fn)(HWND, IDropTarget *);
static revoke_fn orig_revoke;
static register_fn orig_register;

static BOOL foreign(HWND hwnd)
{
    DWORD pid = 0;
    if (!GetWindowThreadProcessId(hwnd, &pid)) return TRUE;   /* no such window: also INVALIDHWND, as on Windows */
    return pid != GetCurrentProcessId();
}

static HRESULT WINAPI hook_revoke(HWND hwnd)
{
    if (foreign(hwnd)) return DRAGDROP_E_INVALIDHWND;
    return orig_revoke(hwnd);
}

static HRESULT WINAPI hook_register(HWND hwnd, IDropTarget *target)
{
    if (foreign(hwnd)) return DRAGDROP_E_INVALIDHWND;
    return orig_register(hwnd, target);
}

/* --- 2. WebView2: browser arguments --- */
typedef struct opts_vtbl { /* ICoreWebView2EnvironmentOptions: IUnknown + get/put AdditionalBrowserArguments + ... */
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(void *, REFIID, void **);
    ULONG (STDMETHODCALLTYPE *AddRef)(void *);
    ULONG (STDMETHODCALLTYPE *Release)(void *);
    HRESULT (STDMETHODCALLTYPE *get_AdditionalBrowserArguments)(void *, LPWSTR *);
    HRESULT (STDMETHODCALLTYPE *put_AdditionalBrowserArguments)(void *, LPCWSTR);
} opts_vtbl;
typedef HRESULT (STDAPICALLTYPE *create_env_fn)(PCWSTR, PCWSTR, void *, void *);
#define MAX_LOADERS 8
static struct { HMODULE mod; create_env_fn orig; BYTE *thunk; } loaders[MAX_LOADERS];
static int nloaders;
static WCHAR wv2_args[1024] = L"--disable-gpu --disable-software-rasterizer --disable-features=ForceSWDCompWhenDCompFallbackRequired";

static HRESULT create_env_common(int i, PCWSTR folder, PCWSTR udf, void *options, void *handler)
{
    if (options && wv2_args[0]) {
        opts_vtbl *vt = *(opts_vtbl **)options;
        LPWSTR cur = NULL;
        if (SUCCEEDED(vt->get_AdditionalBrowserArguments(options, &cur))) {
            static WCHAR buf[4096];
            lstrcpynW(buf, cur ? cur : L"", 2048);
            if (buf[0]) lstrcatW(buf, L" ");
            lstrcatW(buf, wv2_args);
            HRESULT hr = vt->put_AdditionalBrowserArguments(options, buf);
            trace("WebView2 #%d: AdditionalBrowserArguments \"%ls\" -> \"%ls\" (hr=%08lx)\n", i, cur ? cur : L"", buf, hr);
            if (cur) CoTaskMemFree(cur);
        }
    } else {
        trace("WebView2 #%d: options=%p, arguments left unchanged\n", i, options);
    }
    return loaders[i].orig(folder, udf, options, handler);
}
#define CREATE_ENV(n) static HRESULT STDAPICALLTYPE create_env_##n(PCWSTR f, PCWSTR u, void *o, void *h) \
    { return create_env_common(n, f, u, o, h); }
CREATE_ENV(0) CREATE_ENV(1) CREATE_ENV(2) CREATE_ENV(3) CREATE_ENV(4) CREATE_ENV(5) CREATE_ENV(6) CREATE_ENV(7)
static void *create_env_hooks[MAX_LOADERS] = {create_env_0, create_env_1, create_env_2, create_env_3,
                                              create_env_4, create_env_5, create_env_6, create_env_7};

static void patch_loader(HMODULE mod, const WCHAR *path)
{
    int i;
    for (i = 0; i < nloaders; i++) if (loaders[i].mod == mod) return;
    if (nloaders == MAX_LOADERS) return;
    i = nloaders;
    BYTE *thunk = alloc_near((BYTE *)mod, 0x1000);
    if (thunk && patch_export(mod, "CreateCoreWebView2EnvironmentWithOptions", create_env_hooks[i], (void **)&loaders[i].orig, thunk)) {
        loaders[i].mod = mod; loaders[i].thunk = thunk; nloaders++;
        FlushInstructionCache(GetCurrentProcess(), thunk, 16);
        trace("WebView2 #%d: hooked %ls\n", i, path);
    } else trace("WebView2: failed to hook %ls\n", path);
}

typedef struct { ULONG Flags; const UNICODE_STRING *FullDllName, *BaseDllName; void *DllBase; ULONG SizeOfImage; } dll_notif_data;
typedef VOID (CALLBACK *dll_notif_fn)(ULONG reason, const dll_notif_data *data, void *ctx);
typedef NTSTATUS (NTAPI *ldr_register_fn)(ULONG, dll_notif_fn, void *, void **);

static void patch_autodesk(HMODULE mod, const WCHAR *name); /* 4, 5 */

static VOID CALLBACK on_dll(ULONG reason, const dll_notif_data *d, void *ctx)
{
    WCHAR name[64];
    if (reason != 1 /* LDR_DLL_NOTIFICATION_REASON_LOADED */ || !d->BaseDllName) return;
    lstrcpynW(name, d->BaseDllName->Buffer, min(64, d->BaseDllName->Length / 2 + 1));
    if (wv2_args[0] && !lstrcmpiW(name, L"WebView2Loader.dll")) {
        WCHAR full[MAX_PATH]; lstrcpynW(full, d->FullDllName->Buffer, min(MAX_PATH, d->FullDllName->Length / 2 + 1));
        patch_loader((HMODULE)d->DllBase, full);
    } else patch_autodesk((HMODULE)d->DllBase, name);
}

static void fix_webview2(void)
{
    WCHAR env[1024];
    DWORD n = GetEnvironmentVariableW(L"RVTFIX_WV2_ARGS", env, 1024);
    if (n && n < 1024) lstrcpyW(wv2_args, env);
    else if (!n && GetLastError() != ERROR_ENVVAR_NOT_FOUND) wv2_args[0] = 0;
    if (!wv2_args[0]) { trace("WebView2: disabled (RVTFIX_WV2_ARGS is empty)\n"); return; }
    HMODULE m = GetModuleHandleW(L"WebView2Loader.dll"); /* already loaded: patch it too; later ones in on_dll */
    if (m) patch_loader(m, L"(already loaded)");
}

/* --- 3. CefSharp: browser process command line --- */
static WCHAR *cef_cmdline;
static LPWSTR WINAPI hook_getcmdline(void) { return cef_cmdline; }

static void fix_cef(void)
{
    WCHAR args[1024], path[MAX_PATH], *slash;
    const WCHAR *def = L"--in-process-gpu";                  /* 2023: CefSharp\libcef.dll */
    if (!GetModuleFileNameW(NULL, path, MAX_PATH) || !(slash = wcsrchr(path, L'\\'))) return;
    if (lstrcmpiW(slash + 1, L"Revit.exe")) return; /* AdPreviewGenerator.exe sits in the same folder: not its flags */
    lstrcpyW(slash + 1, L"CefSharp\\libcef.dll");
    if (GetFileAttributesW(path) == INVALID_FILE_ATTRIBUTES) {
        lstrcpyW(slash + 1, L"libcef.dll");
        if (GetFileAttributesW(path) == INVALID_FILE_ATTRIBUTES) return; /* no CefSharp in this Revit */
        def = L"--in-process-gpu --disable-gpu";             /* 2025: libcef.dll next to Revit.exe */
    }
    DWORD n = GetEnvironmentVariableW(L"RVTFIX_CEF_ARGS", args, 1024);
    if (!n && GetLastError() != ERROR_ENVVAR_NOT_FOUND) args[0] = 0;
    else if (!n || n >= 1024) lstrcpyW(args, def);
    if (!args[0]) { trace("CefSharp: disabled (RVTFIX_CEF_ARGS is empty)\n"); return; }
    const WCHAR *cur = GetCommandLineW();
    cef_cmdline = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, (lstrlenW(cur) + 2 + lstrlenW(args)) * sizeof(WCHAR)); /* never freed */
    if (!cef_cmdline) return;
    lstrcpyW(cef_cmdline, cur); lstrcatW(cef_cmdline, L" "); lstrcatW(cef_cmdline, args);
    const WCHAR *dlls[] = {L"kernelbase.dll", L"kernel32.dll"};
    int i, ok = 0;
    for (i = 0; i < 2; i++) {
        HMODULE m = GetModuleHandleW(dlls[i]);
        BYTE *thunk = m ? alloc_near((BYTE *)m, 0x1000) : NULL;
        void *orig;
        if (thunk && patch_export(m, "GetCommandLineW", (void *)hook_getcmdline, &orig, thunk)) {
            FlushInstructionCache(GetCurrentProcess(), thunk, 16); ok++;
        }
    }
    trace("CefSharp: GetCommandLineW += \"%ls\" (%d of 2 exports)\n", args, ok);
}

/* --- 4, 5. Autodesk DLLs --- */
static BOOL have_d3dwp;

static BOOL write_mem(void *dst, const void *src, SIZE_T size)
{
    MEMORY_BASIC_INFORMATION mbi;
    DWORD old, rw = PAGE_READWRITE;
    if (VirtualQuery(dst, &mbi, sizeof(mbi)) && (mbi.Protect & 0xf0)) rw = PAGE_EXECUTE_READWRITE; /* keep code runnable */
    if (!VirtualProtect(dst, size, rw, &old)) return FALSE;
    CopyMemory(dst, src, size);
    VirtualProtect(dst, size, old, &old);
    return TRUE;
}

static void patch_ogs(BYTE *base)
{
    static const WCHAR from[] = L"D3D11.dll", to[] = L"d3dwp.dll"; /* with the terminating 0 */
    IMAGE_NT_HEADERS *nt = (IMAGE_NT_HEADERS *)(base + ((IMAGE_DOS_HEADER *)base)->e_lfanew);
    IMAGE_SECTION_HEADER *s = IMAGE_FIRST_SECTION(nt);
    BYTE *hit = NULL;
    int i, n = 0;
    for (i = 0; i < nt->FileHeader.NumberOfSections; i++, s++) {
        BYTE *p = base + s->VirtualAddress, *end = p + (s->Misc.VirtualSize ? s->Misc.VirtualSize : s->SizeOfRawData);
        for (; p + sizeof(from) <= end; p++)
            if (*p == 'D' && !memcmp(p, from, sizeof(from))) { hit = p; n++; }
    }
    if (n == 1 && write_mem(hit, to, sizeof(to)))
        trace("OGSDeviceDX11.dll: L\"D3D11.dll\" -> L\"d3dwp.dll\" at +0x%lx\n", (DWORD)(hit - base));
    else
        trace("OGSDeviceDX11.dll: %d L\"D3D11.dll\" found, expected 1: left as is\n", n);
}

static void patch_mfc(BYTE *base)
{
    static const char from[] = "SetDialogControlDpiChangeBehavior";
    IMAGE_NT_HEADERS *nt = (IMAGE_NT_HEADERS *)(base + ((IMAGE_DOS_HEADER *)base)->e_lfanew);
    IMAGE_DATA_DIRECTORY dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    IMAGE_IMPORT_DESCRIPTOR *imp;
    const char *how = "not imported";
    for (imp = (IMAGE_IMPORT_DESCRIPTOR *)(base + dir.VirtualAddress); dir.VirtualAddress && imp->Name; imp++) {
        if (lstrcmpiA((char *)(base + imp->Name), "user32.dll") || !imp->OriginalFirstThunk) continue;
        IMAGE_THUNK_DATA *names = (IMAGE_THUNK_DATA *)(base + imp->OriginalFirstThunk);
        IMAGE_THUNK_DATA *iat = (IMAGE_THUNK_DATA *)(base + imp->FirstThunk);
        for (; names->u1.AddressOfData; names++, iat++) {
            if (IMAGE_SNAP_BY_ORDINAL(names->u1.Ordinal)) continue;
            IMAGE_IMPORT_BY_NAME *ibn = (IMAGE_IMPORT_BY_NAME *)(base + names->u1.AddressOfData);
            if (lstrcmpA((char *)ibn->Name, from)) continue;
            if (iat->u1.Function == names->u1.Function) { /* not bound yet: the loader binds the new name */
                char to[sizeof(from)] = "IsWindow";
                how = write_mem(ibn->Name, to, sizeof(to)) ? "renamed to IsWindow before binding" : "rename failed";
            } else {
                ULONG_PTR fn = (ULONG_PTR)IsWindow;
                how = write_mem(&iat->u1.Function, &fn, sizeof(fn)) ? "bound stub replaced with IsWindow" : "IAT write failed";
            }
        }
    }
    trace("DesktopMFC.dll: USER32!%s: %s\n", from, how);
}

static void patch_autodesk(HMODULE mod, const WCHAR *name)
{
    if (!lstrcmpiW(name, L"OGSDeviceDX11.dll")) {
        if (have_d3dwp) patch_ogs((BYTE *)mod);
        else trace("OGSDeviceDX11.dll: no d3dwp.dll next to Revit.exe, left as is\n");
    } else if (!lstrcmpiW(name, L"DesktopMFC.dll")) patch_mfc((BYTE *)mod);
}

static void fix_autodesk(void)
{
    WCHAR path[MAX_PATH], *slash;
    HMODULE m;
    if (GetModuleFileNameW(NULL, path, MAX_PATH) && (slash = wcsrchr(path, L'\\'))) {
        lstrcpyW(slash + 1, L"d3dwp.dll");
        have_d3dwp = GetFileAttributesW(path) != INVALID_FILE_ATTRIBUTES;
    }
    if ((m = GetModuleHandleW(L"OGSDeviceDX11.dll"))) patch_autodesk(m, L"OGSDeviceDX11.dll");
    if ((m = GetModuleHandleW(L"DesktopMFC.dll"))) patch_autodesk(m, L"DesktopMFC.dll");
}

/* DLLs loaded later: WebView2Loader.dll (2), OGSDeviceDX11.dll and DesktopMFC.dll (4, 5). */
static void watch_dlls(void)
{
    ldr_register_fn reg = (ldr_register_fn)GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "LdrRegisterDllNotification");
    void *cookie;
    if (!reg || reg(0, on_dll, NULL, &cookie)) trace("no LdrRegisterDllNotification: DLLs loaded later are not fixed\n");
}

/* --- 6. WebView2 host window: the browser's window leaves before the host is destroyed --- */
typedef BOOL (WINAPI *destroy_fn)(HWND);
static destroy_fn orig_destroy;
#define MAX_RESCUE 64
struct rescue { HWND hwnd[MAX_RESCUE], parent[MAX_RESCUE]; int n, missed; };

static BOOL CALLBACK find_browser(HWND hwnd, LPARAM lp) /* the top Chrome_WidgetWin_* of another process */
{
    struct rescue *r = (struct rescue *)lp;
    char cls[32];
    HWND parent = GetAncestor(hwnd, GA_PARENT);
    if (foreign(hwnd) && parent && !foreign(parent) && GetClassNameA(hwnd, cls, sizeof(cls))) {
        cls[17] = 0;   /* the prefix: "Chrome_WidgetWin_" is 17 characters */
        if (lstrcmpA(cls, "Chrome_WidgetWin_")) return TRUE;
        if (r->n < MAX_RESCUE) r->hwnd[r->n++] = hwnd;
        else r->missed++;
    }
    return TRUE;
}

static BOOL WINAPI hook_destroy(HWND hwnd)
{
    struct rescue r = {0};
    DWORD err;
    BOOL ok;
    int i;
    /* only a window this thread may destroy: DestroyWindow fails on another thread's window */
    if (hwnd && GetWindowThreadProcessId(hwnd, NULL) == GetCurrentThreadId())
        EnumChildWindows(hwnd, find_browser, (LPARAM)&r);
    if (r.missed) trace("DestroyWindow %p: %d more browser windows left inside\n", hwnd, r.missed);
    for (i = 0; i < r.n; i++) {
        r.parent[i] = SetParent(r.hwnd[i], HWND_MESSAGE);
        trace("DestroyWindow %p: browser window %p from %p to HWND_MESSAGE%s\n", hwnd, r.hwnd[i], r.parent[i],
              r.parent[i] ? "" : " failed");
    }
    ok = orig_destroy(hwnd);
    if (!ok && r.n) { /* refused (a CBT hook): the host lives on, so its browser windows go back */
        err = GetLastError();
        for (i = 0; i < r.n; i++)
            if (r.parent[i] && IsWindow(r.hwnd[i]) && IsWindow(r.parent[i])) SetParent(r.hwnd[i], r.parent[i]);
        trace("DestroyWindow %p failed: browser windows put back\n", hwnd);
        SetLastError(err);
    }
    return ok;
}

static void fix_destroy(void)
{
    HMODULE user = GetModuleHandleW(L"user32.dll");
    BYTE *thunk;
    if (!user || !(thunk = alloc_near((BYTE *)user, 0x1000))) { trace("user32: no thunk\n"); return; }
    if (patch_export(user, "DestroyWindow", (void *)hook_destroy, (void **)&orig_destroy, thunk))
        trace("user32!DestroyWindow: browser windows of another process leave first\n");
    else
        trace("user32: DestroyWindow not found\n");
    FlushInstructionCache(GetCurrentProcess(), thunk, 16);
}

static void fix_dragdrop(void)
{
    HMODULE ole = LoadLibraryW(L"ole32.dll");
    BYTE *thunks;
    if (!ole || !(thunks = alloc_near((BYTE *)ole, 0x1000))) { trace("ole32: no thunk\n"); return; }
    if (patch_export(ole, "RevokeDragDrop", (void *)hook_revoke, (void **)&orig_revoke, thunks) &&
        patch_export(ole, "RegisterDragDrop", (void *)hook_register, (void **)&orig_register, thunks + 16))
        trace("ole32!RevokeDragDrop/RegisterDragDrop: foreign window check\n");
    else
        trace("ole32: export not found\n");
    FlushInstructionCache(GetCurrentProcess(), thunks, 32);
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, void *reserved)
{
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(inst);
        GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_PIN | GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
                           (LPCWSTR)DllMain, &(HMODULE){0}); /* thunks point here, so never unload */
        fix_dragdrop();
        fix_destroy();
        fix_webview2();
        fix_cef();
        fix_autodesk();
        watch_dlls(); /* under the loader lock: no DLL loads between the checks above and this */
    }
    return TRUE;
}
