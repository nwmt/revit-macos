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
 * 7. Maximize on a secondary monitor: Revit answers WM_GETMINMAXINFO with its monitor's work area and the work area's
 *    origin relative to that monitor (e.g. 0,33). Windows moves such an answer onto the monitor the window maximizes
 *    on; Wine (get_min_max_info) moves only its own defaults and takes the answer as absolute -> Revit lands at the
 *    main monitor's origin with the other monitor's size. Fix: when a top-level window with a maximize box is shown
 *    (WinEvent hook in the window's thread, after MFC/WPF have put their procedures), put our window procedure in
 *    front; after the original answers on a secondary monitor, an answer of exactly that form (position = work area
 *    relative to the monitor, size = work area) gets the work area's absolute origin. Other answers stay as they are.
 *    Only in Revit.exe. The first show of an already maximized window comes before the hook: not fixed.
 *    RVTFIX_MAXPOS set and empty disables.
 *
 * 8. Web panels go blank (Project Browser 2027: one row left in an empty panel, all of it back when the mouse passes):
 *    Revit puts the WebView2 host window (Chrome_WidgetWin_0) into a Static with WS_EX_TRANSPARENT. Wine does not clip
 *    such a child out of its parent's drawing (WS_CLIPCHILDREN skips it), so when the WPF pane or the docking windows
 *    above it repaint (a theme change does), they paint over the browser's area. The browser window belongs to another
 *    process and gets no WM_PAINT; CrossOver shows only what the browser draws again by itself.
 *    Fix: when a Chrome_WidgetWin_* window of ours is created, shown or gets a new parent (WinEvent hook in its thread),
 *    clear WS_EX_TRANSPARENT on its ancestors of this process. WindowFromPoint still finds the browser's window.
 *    Only in Revit.exe. RVTFIX_WV2_OPAQUE set and empty disables.
 * 9. Status bar in the dark theme (2027): Revit's status bar is a msctls_statusbar32 whose parts it draws itself
 *    (SBT_OWNERDRAW), text only, on a background it leaves to the control. Wine's comctl32 fills that background with
 *    the visual style (light.msstyles, class Status) in both themes -> a light text area and light gaps between the
 *    controls. Fix: replace uxtheme's DrawThemeBackground for comctl32 (its export, and the delay import slots of the
 *    comctl32 already loaded); on a status bar's window, while the bottle's Windows theme is dark (Personalize
 *    AppsUseLightTheme = 0, which the step theme keeps equal to Revit's theme), fill with Revit's dark status bar color
 *    instead. The size grip and every other window are drawn as before. Only in Revit.exe. RVTFIX_STATUSBAR set and
 *    empty disables.
 *
 * 10. Orbiting in the Textures visual style (2027): for every textured material, on every frame, Revit asks
 *    OGS::Devices::OIIOImageHandler::GetImageDesc (OGSOIIOIntegration.dll) for the texture's size and format, and
 *    OpenImageIO opens the image file to read its header. Under Wine each open, stat and read costs much more than on
 *    Windows: about a fifth of the orbit time on the Snowdon Towers sample. Fix: a jump at the start of the function
 *    (12 bytes of prologue, checked before the patch) to a cache: the 0x30-byte ImageDesc it returns (a vtable,
 *    numbers only) is kept per path for 2 s, and the caller gets a new copy from the allocator the function itself
 *    uses (it deletes the result through the vtable). Only in Revit.exe. RVTFIX_IMGCACHE set and empty disables.
 *
 * 4, 5 and 10 run when the DLL loads (LdrRegisterDllNotification), or at once if it is already loaded.
 *
 * Diagnostics: OutputDebugString with the "[rvtfix]" prefix (CX_DEBUGMSG=+debugstr).
 */
#include <windows.h>
#include <ole2.h>
#include <winternl.h>
#include <psapi.h>
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

/* --- 10. Textures: cache of OIIOImageHandler::GetImageDesc --- */
#define IMGDESC_SIZE 0x30
#define IMGDESC_TTL 2000   /* ms: a texture file changed on disk is read again after this */
#define IMGDESC_SLOTS 4096
typedef void *(*get_image_desc_fn)(void *self, const void *path);
typedef const WCHAR *(*kstring_wcs_fn)(const void *str);
typedef void *(*heap_new_fn)(size_t);
static BOOL imgcache_on;
static get_image_desc_fn orig_get_image_desc;   /* the moved prologue, then a jump back */
static kstring_wcs_fn kstring_wcs;              /* OGSObjects!KString::operator const wchar_t * */
static heap_new_fn *imgdesc_new_slot;           /* the import slot of the function's own operator new */
static SRWLOCK imgdesc_lock = SRWLOCK_INIT;
static struct { WCHAR *path; ULONGLONG time; BOOL none; BYTE desc[IMGDESC_SIZE]; } imgdesc[IMGDESC_SLOTS];

static unsigned imgdesc_hash(const WCHAR *s)
{
    unsigned h = 2166136261u;
    for (; *s; s++) h = (h ^ (*s | 0x20)) * 16777619u;   /* paths compare without case */
    return h;
}

static void *hook_get_image_desc(void *self, const void *str)
{
    const WCHAR *path = kstring_wcs(str);
    ULONGLONG now = GetTickCount64();
    unsigned h, i;
    void *desc;
    if (!path || !*path) return orig_get_image_desc(self, str);
    h = imgdesc_hash(path);
    AcquireSRWLockShared(&imgdesc_lock);
    for (i = 0; i < 8; i++) {
        unsigned k = (h + i) % IMGDESC_SLOTS;
        if (!imgdesc[k].path || now - imgdesc[k].time >= IMGDESC_TTL || lstrcmpiW(imgdesc[k].path, path)) continue;
        if (imgdesc[k].none) { ReleaseSRWLockShared(&imgdesc_lock); return NULL; }
        if ((desc = (*imgdesc_new_slot)(IMGDESC_SIZE))) CopyMemory(desc, imgdesc[k].desc, IMGDESC_SIZE);
        ReleaseSRWLockShared(&imgdesc_lock);
        return desc ? desc : orig_get_image_desc(self, str);
    }
    ReleaseSRWLockShared(&imgdesc_lock);
    desc = orig_get_image_desc(self, str);
    AcquireSRWLockExclusive(&imgdesc_lock);
    for (i = 0; i < 8; i++) {   /* a free, stale or same-path slot; all 8 fresh: not cached */
        unsigned k = (h + i) % IMGDESC_SLOTS;
        if (imgdesc[k].path && now - imgdesc[k].time < IMGDESC_TTL && lstrcmpiW(imgdesc[k].path, path)) continue;
        SIZE_T n = (lstrlenW(path) + 1) * sizeof(WCHAR);
        WCHAR *copy = HeapAlloc(GetProcessHeap(), 0, n);
        if (!copy) break;
        CopyMemory(copy, path, n);
        if (imgdesc[k].path) HeapFree(GetProcessHeap(), 0, imgdesc[k].path);
        imgdesc[k].path = copy; imgdesc[k].time = now; imgdesc[k].none = !desc;
        if (desc) CopyMemory(imgdesc[k].desc, desc, IMGDESC_SIZE);
        break;
    }
    ReleaseSRWLockExclusive(&imgdesc_lock);
    return desc;
}

static void patch_imagedesc(HMODULE mod)
{
    /* movq %rbx,0x18(%rsp); push rbp, rsi, rdi, r12, r13: whole instructions, nothing relative to rip */
    static const BYTE prologue[12] = {0x48, 0x89, 0x5c, 0x24, 0x18, 0x55, 0x56, 0x57, 0x41, 0x54, 0x41, 0x55};
    HMODULE objects = GetModuleHandleW(L"OGSObjects.dll");   /* imported by OGSOIIOIntegration: already mapped */
    BYTE *f = (BYTE *)GetProcAddress(mod, "?GetImageDesc@OIIOImageHandler@Devices@OGS@@UEAAPEAUImageDesc@23@AEBVKString@Objects@3@@Z");
    BYTE *tramp, back[12] = {0x48, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xe0};
    if (objects) kstring_wcs = (kstring_wcs_fn)GetProcAddress(objects, "??BKString@Objects@OGS@@QEBAPEB_WXZ");
    /* +0x3b: "mov ecx, 30h; call [rip+disp]": the ImageDesc's allocation, through OGSObjects!HeapOperators::operator new */
    if (!f || !kstring_wcs || memcmp(f, prologue, sizeof(prologue)) || f[0x3b] != 0xb9 ||
        *(DWORD *)(f + 0x3c) != IMGDESC_SIZE || f[0x40] != 0xff || f[0x41] != 0x15) {
        trace("OGSOIIOIntegration.dll: GetImageDesc not as expected: no texture cache\n");
        return;
    }
    imgdesc_new_slot = (heap_new_fn *)(f + 0x46 + *(INT32 *)(f + 0x42));   /* read at each call: bound by then */
    if (!(tramp = alloc_near(f, 0x1000))) { trace("OGSOIIOIntegration.dll: no memory for the trampoline\n"); return; }
    BYTE *cont = f + sizeof(prologue);
    CopyMemory(tramp, prologue, sizeof(prologue));
    CopyMemory(back + 2, &cont, sizeof(cont));   /* rax is free at a call's start: not an argument */
    CopyMemory(tramp + sizeof(prologue), back, sizeof(back));
    FlushInstructionCache(GetCurrentProcess(), tramp, sizeof(prologue) + sizeof(back));
    orig_get_image_desc = (get_image_desc_fn)tramp;
    if (write_jump(f, (void *)hook_get_image_desc)) trace("OGSOIIOIntegration.dll: GetImageDesc cached for %d ms\n", IMGDESC_TTL);
}

static void patch_autodesk(HMODULE mod, const WCHAR *name)
{
    if (!lstrcmpiW(name, L"OGSDeviceDX11.dll")) {
        if (have_d3dwp) patch_ogs((BYTE *)mod);
        else trace("OGSDeviceDX11.dll: no d3dwp.dll next to Revit.exe, left as is\n");
    } else if (!lstrcmpiW(name, L"DesktopMFC.dll")) patch_mfc((BYTE *)mod);
    else if (imgcache_on && !lstrcmpiW(name, L"OGSOIIOIntegration.dll")) patch_imagedesc(mod);
}

static void fix_autodesk(void)
{
    WCHAR path[MAX_PATH], *slash;
    HMODULE m;
    if (GetModuleFileNameW(NULL, path, MAX_PATH) && (slash = wcsrchr(path, L'\\'))) {
        WCHAR env[2];
        imgcache_on = !lstrcmpiW(slash + 1, L"Revit.exe");
        if (imgcache_on && !GetEnvironmentVariableW(L"RVTFIX_IMGCACHE", env, 2) && GetLastError() != ERROR_ENVVAR_NOT_FOUND) {
            imgcache_on = FALSE;
            trace("texture cache: disabled (RVTFIX_IMGCACHE is empty)\n");
        }
        lstrcpyW(slash + 1, L"d3dwp.dll");
        have_d3dwp = GetFileAttributesW(path) != INVALID_FILE_ATTRIBUTES;
    }
    if ((m = GetModuleHandleW(L"OGSDeviceDX11.dll"))) patch_autodesk(m, L"OGSDeviceDX11.dll");
    if ((m = GetModuleHandleW(L"DesktopMFC.dll"))) patch_autodesk(m, L"DesktopMFC.dll");
    if ((m = GetModuleHandleW(L"OGSOIIOIntegration.dll"))) patch_autodesk(m, L"OGSOIIOIntegration.dll");
}

/* DLLs loaded later: WebView2Loader.dll (2), OGSDeviceDX11.dll, DesktopMFC.dll and OGSOIIOIntegration.dll (4, 5, 10). */
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

/* --- 7. maximize on a secondary monitor --- */
#define MAXPOS_PROP L"rvtfix.maxpos"   /* the original window procedure */
static int maxpos_traces;
static LRESULT CALLBACK maxpos_proc_w(HWND, UINT, WPARAM, LPARAM);
static LRESULT CALLBACK maxpos_proc_a(HWND, UINT, WPARAM, LPARAM);

static void maxpos_adjust(HWND hwnd, MINMAXINFO *m) /* Revit's answer for this monitor, relative to it -> absolute */
{
    MONITORINFO mi = { sizeof(mi) };
    if (!GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &mi) || (mi.dwFlags & MONITORINFOF_PRIMARY))
        return;   /* on the main monitor relative and absolute are the same */
    if (m->ptMaxPosition.x != mi.rcWork.left - mi.rcMonitor.left || m->ptMaxPosition.y != mi.rcWork.top - mi.rcMonitor.top ||
        m->ptMaxSize.x != mi.rcWork.right - mi.rcWork.left || m->ptMaxSize.y != mi.rcWork.bottom - mi.rcWork.top)
        return;   /* absolute, Wine's defaults (it moves them after us) or another form: not guessed */
    m->ptMaxPosition.x = mi.rcWork.left;
    m->ptMaxPosition.y = mi.rcWork.top;
    if (maxpos_traces++ < 16)
        trace("maximize %p: position moved to %ld,%ld (secondary monitor)\n", hwnd, m->ptMaxPosition.x, m->ptMaxPosition.y);
}

static LRESULT maxpos_common(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp, BOOL unicode)
{
    WNDPROC orig = (WNDPROC)GetPropW(hwnd, MAXPOS_PROP), ours = unicode ? maxpos_proc_w : maxpos_proc_a;
    LRESULT r;
    if (!orig) return unicode ? DefWindowProcW(hwnd, msg, wp, lp) : DefWindowProcA(hwnd, msg, wp, lp);
    if (msg == WM_NCDESTROY) { /* the original goes back first: a procedure below that unhooks itself sees its own */
        RemovePropW(hwnd, MAXPOS_PROP);
        if (unicode && (WNDPROC)GetWindowLongPtrW(hwnd, GWLP_WNDPROC) == ours) SetWindowLongPtrW(hwnd, GWLP_WNDPROC, (LONG_PTR)orig);
        if (!unicode && (WNDPROC)GetWindowLongPtrA(hwnd, GWLP_WNDPROC) == ours) SetWindowLongPtrA(hwnd, GWLP_WNDPROC, (LONG_PTR)orig);
    }
    r = unicode ? CallWindowProcW(orig, hwnd, msg, wp, lp) : CallWindowProcA(orig, hwnd, msg, wp, lp);
    if (msg == WM_GETMINMAXINFO && lp) maxpos_adjust(hwnd, (MINMAXINFO *)lp);
    return r;
}
static LRESULT CALLBACK maxpos_proc_w(HWND h, UINT m, WPARAM w, LPARAM l) { return maxpos_common(h, m, w, l, TRUE); }
static LRESULT CALLBACK maxpos_proc_a(HWND h, UINT m, WPARAM w, LPARAM l) { return maxpos_common(h, m, w, l, FALSE); }

/* a window is shown (in its own thread): after its own subclassing, so ours sees the final answer. Of the same type
 * (ANSI or Unicode) as the window: SetWindowLongPtrW would make an ANSI window Unicode */
static void CALLBACK maxpos_on_show(HWINEVENTHOOK hook, DWORD ev, HWND hwnd, LONG obj, LONG child, DWORD tid, DWORD time)
{
    WNDPROC orig;
    BOOL unicode;
    if (obj != OBJID_WINDOW || child != CHILDID_SELF || !hwnd || GetPropW(hwnd, MAXPOS_PROP)) return;
    if (GetAncestor(hwnd, GA_PARENT) != GetDesktopWindow() || !(GetWindowLongW(hwnd, GWL_STYLE) & WS_MAXIMIZEBOX)) return;
    if (GetWindowThreadProcessId(hwnd, NULL) != GetCurrentThreadId()) return;
    unicode = IsWindowUnicode(hwnd);
    orig = (WNDPROC)(unicode ? GetWindowLongPtrW(hwnd, GWLP_WNDPROC) : GetWindowLongPtrA(hwnd, GWLP_WNDPROC));
    if (!orig || orig == maxpos_proc_w || orig == maxpos_proc_a) return;
    if (!SetPropW(hwnd, MAXPOS_PROP, (HANDLE)orig)) return;   /* without it our procedure could not pass anything on */
    SetLastError(0);
    if (!(unicode ? SetWindowLongPtrW(hwnd, GWLP_WNDPROC, (LONG_PTR)maxpos_proc_w)
                  : SetWindowLongPtrA(hwnd, GWLP_WNDPROC, (LONG_PTR)maxpos_proc_a)) && GetLastError())
        RemovePropW(hwnd, MAXPOS_PROP);   /* refused: the window stays as it was, the next show tries again */
}

static void fix_maxpos(HINSTANCE inst)
{
    WCHAR path[MAX_PATH], *slash, env[8];
    if (!GetModuleFileNameW(NULL, path, MAX_PATH) || !(slash = wcsrchr(path, L'\\')) || lstrcmpiW(slash + 1, L"Revit.exe"))
        return;
    SetLastError(0);   /* an empty variable leaves the last error as it was */
    if (!GetEnvironmentVariableW(L"RVTFIX_MAXPOS", env, 8) && GetLastError() != ERROR_ENVVAR_NOT_FOUND) {
        trace("maximize: disabled (RVTFIX_MAXPOS is empty)\n");
        return;
    }
    if (SetWinEventHook(EVENT_OBJECT_SHOW, EVENT_OBJECT_SHOW, inst, maxpos_on_show, GetCurrentProcessId(), 0, WINEVENT_INCONTEXT))
        trace("maximize: windows on a secondary monitor get its origin\n");
    else
        trace("maximize: no WinEvent hook (%lu)\n", GetLastError());
}

/* --- 8. WebView2 host window: no WS_EX_TRANSPARENT above it --- */
static int opaque_traces;

static void CALLBACK opaque_on_event(HWINEVENTHOOK hook, DWORD ev, HWND hwnd, LONG obj, LONG child, DWORD tid, DWORD time)
{
    char cls[32];
    HWND p, desk = GetDesktopWindow();
    int depth = 0;
    if (ev == EVENT_OBJECT_DESTROY || obj != OBJID_WINDOW || child != CHILDID_SELF || !hwnd || foreign(hwnd)) return;
    if (!GetClassNameA(hwnd, cls, sizeof(cls))) return;
    cls[17] = 0;   /* the prefix: "Chrome_WidgetWin_" is 17 characters */
    if (lstrcmpA(cls, "Chrome_WidgetWin_")) return;
    for (p = GetAncestor(hwnd, GA_PARENT); p && p != desk && depth++ < 32 && !foreign(p); p = GetAncestor(p, GA_PARENT)) {
        LONG_PTR ex = GetWindowLongPtrW(p, GWL_EXSTYLE);
        if (!(ex & WS_EX_TRANSPARENT)) continue;
        SetWindowLongPtrW(p, GWL_EXSTYLE, ex & ~WS_EX_TRANSPARENT);
        if (opaque_traces++ < 16) trace("WebView2 host %p: WS_EX_TRANSPARENT cleared on its ancestor %p\n", hwnd, p);
    }
}

static void fix_opaque(HINSTANCE inst)
{
    WCHAR path[MAX_PATH], *slash, env[8];
    HWINEVENTHOOK shown;
    if (!GetModuleFileNameW(NULL, path, MAX_PATH) || !(slash = wcsrchr(path, L'\\')) || lstrcmpiW(slash + 1, L"Revit.exe"))
        return;
    SetLastError(0);   /* an empty variable leaves the last error as it was */
    if (!GetEnvironmentVariableW(L"RVTFIX_WV2_OPAQUE", env, 8) && GetLastError() != ERROR_ENVVAR_NOT_FOUND) {
        trace("WebView2 host: disabled (RVTFIX_WV2_OPAQUE is empty)\n");
        return;
    }
    /* both hooks or none: without the parent change a host moved under a new transparent ancestor goes blank again */
    if (!(shown = SetWinEventHook(EVENT_OBJECT_CREATE, EVENT_OBJECT_SHOW, inst, opaque_on_event, GetCurrentProcessId(), 0,
                                  WINEVENT_INCONTEXT))) {
        trace("WebView2 host: no WinEvent hook (%lu)\n", GetLastError());
        return;
    }
    if (!SetWinEventHook(EVENT_OBJECT_PARENTCHANGE, EVENT_OBJECT_PARENTCHANGE, inst, opaque_on_event, GetCurrentProcessId(), 0,
                         WINEVENT_INCONTEXT)) {
        trace("WebView2 host: no WinEvent hook for parent changes (%lu)\n", GetLastError());
        UnhookWinEvent(shown);
        return;
    }
    trace("WebView2 host: no WS_EX_TRANSPARENT above it\n");
}

/* --- 9. status bar in the dark theme --- */
typedef HRESULT (WINAPI *draw_theme_bg_fn)(HANDLE, HDC, int, int, const RECT *, const RECT *);
static draw_theme_bg_fn orig_draw_theme_bg;
#define SB_DARK RGB(59, 68, 83)   /* Revit 2027's own status bar panes in the dark theme */
#define SP_GRIPPER 3              /* vssym32.h: the size grip keeps its look */

static BOOL bottle_dark(void) /* AppsUseLightTheme = 0, read at every paint: a cached value could miss a theme change */
{
    DWORD v = 1, size = sizeof(v);
    if (RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                     L"AppsUseLightTheme", RRF_RT_REG_DWORD, NULL, &v, &size)) v = 1;
    return !v;
}

static BOOL is_statusbar(HWND hwnd)
{
    WCHAR cls[32];
    return GetClassNameW(hwnd, cls, 32) && !lstrcmpiW(cls, L"msctls_statusbar32");
}

static HRESULT WINAPI hook_draw_theme_bg(HANDLE theme, HDC hdc, int part, int state, const RECT *rc, const RECT *clip)
{
    HWND hwnd;
    RECT r;
    if (part != SP_GRIPPER && rc && (hwnd = WindowFromDC(hdc)) && is_statusbar(hwnd) && bottle_dark()) {
        if (!clip || IntersectRect(&r, rc, clip)) {
            if (!clip) r = *rc;
            COLORREF old = SetDCBrushColor(hdc, SB_DARK);
            FillRect(hdc, &r, GetStockObject(DC_BRUSH));
            SetDCBrushColor(hdc, old);
        }
        return S_OK;
    }
    return orig_draw_theme_bg(theme, hdc, part, state, rc, clip);
}

static int replace_pointer(HMODULE mod, void *from, void *to) /* in the module's writable sections: its import slots */
{
    BYTE *base = (BYTE *)mod;
    IMAGE_NT_HEADERS *nt = (IMAGE_NT_HEADERS *)(base + ((IMAGE_DOS_HEADER *)base)->e_lfanew);
    IMAGE_SECTION_HEADER *s = IMAGE_FIRST_SECTION(nt);
    int i, n = 0;
    for (i = 0; i < nt->FileHeader.NumberOfSections; i++, s++) {
        if (!(s->Characteristics & IMAGE_SCN_MEM_WRITE)) continue;
        void **p = (void **)(base + s->VirtualAddress), **end = (void **)((BYTE *)p + s->Misc.VirtualSize);
        for (; p < end; p++)
            if (*p == from && write_mem(p, &to, sizeof(to))) n++;
    }
    return n;
}

static void fix_statusbar(void)
{
    WCHAR path[MAX_PATH], *slash, env[8];
    HMODULE ux, mods[512];
    DWORD need = 0, i;
    BYTE *thunk;
    int n = 0;
    if (!GetModuleFileNameW(NULL, path, MAX_PATH) || !(slash = wcsrchr(path, L'\\')) || lstrcmpiW(slash + 1, L"Revit.exe"))
        return;
    SetLastError(0);
    if (!GetEnvironmentVariableW(L"RVTFIX_STATUSBAR", env, 8) && GetLastError() != ERROR_ENVVAR_NOT_FOUND) {
        trace("status bar: disabled (RVTFIX_STATUSBAR is empty)\n");
        return;
    }
    if (!(ux = LoadLibraryW(L"uxtheme.dll")) || !(thunk = alloc_near((BYTE *)ux, 0x1000))) { trace("uxtheme: no thunk\n"); return; }
    if (!patch_export(ux, "DrawThemeBackground", (void *)hook_draw_theme_bg, (void **)&orig_draw_theme_bg, thunk)) {
        trace("uxtheme: DrawThemeBackground not found\n");
        return;
    }
    FlushInstructionCache(GetCurrentProcess(), thunk, 16);
    /* a comctl32 that has already called it keeps the resolved address in its delay import slot */
    if (K32EnumProcessModules(GetCurrentProcess(), mods, sizeof(mods), &need))
        for (i = 0; i < need / sizeof(HMODULE) && i < 512; i++)
            if (GetModuleFileNameW(mods[i], path, MAX_PATH) && (slash = wcsrchr(path, L'\\')) &&
                !lstrcmpiW(slash + 1, L"comctl32.dll"))
                n += replace_pointer(mods[i], (void *)orig_draw_theme_bg, (void *)hook_draw_theme_bg);
    trace("status bar: DrawThemeBackground hooked (%d resolved slots in comctl32 replaced)\n", n);
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
        fix_maxpos(inst);
        fix_opaque(inst);
        fix_statusbar();
        watch_dlls(); /* under the loader lock: no DLL loads between the checks above and this */
    }
    return TRUE;
}
