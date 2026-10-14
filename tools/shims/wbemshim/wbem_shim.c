/*
 * SPDX-License-Identifier: MIT
 * wbemshim.dll -- COM shim over Wine's wbemprox (WMI) for Revit 2020.
 *
 * Problem: in Wine, IWbemServices has a single async request slot, and it is freed only by
 * CancelAsyncCall, not when the request completes. A second ExecQueryAsync on the same object is rejected
 * ("fixme:wbemprox:wbem_services_ExecQueryAsync handle more than one pending async"). Revit's System Inventory
 * issues two in a row (Win32_OperatingSystem, Win32_Processor), doesn't survive the rejection and crashes
 * (jump into the heap at startup, 0xc0000005 on New Project and when opening Options).
 *
 * Fix: CLSID_WbemLocator is registered to this DLL. It hands out IWbemLocator/IWbemServices wrappers,
 * and runs the async methods (ExecQueryAsync, CreateInstanceEnumAsync, GetObjectAsync, ExecMethodAsync)
 * as synchronous calls to the real wbemprox on a separate thread, delivering results to the sink
 * (Indicate + SetStatus). Everything else, including ExecNotificationQueryAsync, is passed through as is.
 * The real wbemprox is loaded by full path system32\wbem\wbemprox.dll (Wine substitutes the builtin one).
 *
 * Diagnostics: OutputDebugString with the "[wbem-shim]" prefix (CX_DEBUGMSG=+debugstr).
 */
#define COBJMACROS
#include <windows.h>
#include <wbemidl.h>

static HMODULE real_mod;
static HRESULT (WINAPI *real_DllGetClassObject)(REFCLSID, REFIID, void **);
static LONG module_locks;

static void trace(const char *fmt, ...)
{
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    wvsprintfA(buf, fmt, ap);
    va_end(ap);
    OutputDebugStringA(buf);
}

static BOOL load_real(void)
{
    WCHAR path[MAX_PATH];
    if (real_mod) return TRUE;
    GetSystemDirectoryW(path, MAX_PATH);
    lstrcatW(path, L"\\wbem\\wbemprox.dll");
    real_mod = LoadLibraryW(path);
    if (real_mod) real_DllGetClassObject = (void *)GetProcAddress(real_mod, "DllGetClassObject");
    trace("[wbem-shim] real wbemprox %ls -> %p\n", path, real_mod);
    return real_DllGetClassObject != NULL;
}

/* ================= async operations via synchronous calls ================= */

enum op { OP_QUERY, OP_ENUM, OP_GET, OP_METHOD };

typedef struct pending {
    struct pending *next;
    IWbemObjectSink *sink;
    volatile LONG cancelled;
} pending;

static pending *pending_list;
static CRITICAL_SECTION pending_cs;

typedef struct {
    enum op op;
    IWbemServices *real;
    IWbemObjectSink *sink;
    IWbemContext *ctx;
    IWbemClassObject *in_params;
    BSTR a, b;          /* QUERY: language, query; ENUM: class; GET: path; METHOD: path, method */
    LONG flags;
    pending *p;
} async_job;

static pending *pending_add(IWbemObjectSink *sink)
{
    pending *p = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(*p));
    if (!p) return NULL;
    p->sink = sink;
    EnterCriticalSection(&pending_cs);
    p->next = pending_list; pending_list = p;
    LeaveCriticalSection(&pending_cs);
    return p;
}

static void pending_remove(pending *p)
{
    pending **pp;
    EnterCriticalSection(&pending_cs);
    for (pp = &pending_list; *pp; pp = &(*pp)->next) if (*pp == p) { *pp = p->next; break; }
    LeaveCriticalSection(&pending_cs);
    HeapFree(GetProcessHeap(), 0, p);
}

static BOOL pending_cancel(IWbemObjectSink *sink)
{
    BOOL found = FALSE;
    EnterCriticalSection(&pending_cs);
    for (pending *p = pending_list; p; p = p->next)
        if (p->sink == sink) { InterlockedExchange(&p->cancelled, 1); found = TRUE; }
    LeaveCriticalSection(&pending_cs);
    return found;
}

static HRESULT drain_enum(async_job *j, IEnumWbemClassObject *en, LONG *count)
{
    HRESULT hr = S_OK;
    while (!j->p->cancelled) {
        IWbemClassObject *obj = NULL;
        ULONG got = 0;
        hr = IEnumWbemClassObject_Next(en, WBEM_INFINITE, 1, &obj, &got);
        if (FAILED(hr) || !got) break;
        IWbemObjectSink_Indicate(j->sink, 1, &obj);
        IWbemClassObject_Release(obj);
        (*count)++;
    }
    return (hr == WBEM_S_FALSE || hr == WBEM_S_NO_ERROR) ? S_OK : hr;
}

static DWORD WINAPI async_thread(void *arg)
{
    async_job *j = arg;
    HRESULT hr;
    LONG count = 0;
    LONG sync_flags = j->flags & ~(WBEM_FLAG_SEND_STATUS | WBEM_FLAG_USE_AMENDED_QUALIFIERS);
    IEnumWbemClassObject *en = NULL;
    IWbemClassObject *obj = NULL;

    CoInitializeEx(NULL, COINIT_MULTITHREADED);
    switch (j->op) {
    case OP_QUERY:
        hr = IWbemServices_ExecQuery(j->real, j->a, j->b, sync_flags | WBEM_FLAG_FORWARD_ONLY, j->ctx, &en);
        if (SUCCEEDED(hr)) hr = drain_enum(j, en, &count);
        break;
    case OP_ENUM:
        hr = IWbemServices_CreateInstanceEnum(j->real, j->a, sync_flags | WBEM_FLAG_FORWARD_ONLY, j->ctx, &en);
        if (SUCCEEDED(hr)) hr = drain_enum(j, en, &count);
        break;
    case OP_GET:
        hr = IWbemServices_GetObject(j->real, j->a, sync_flags, j->ctx, &obj, NULL);
        if (SUCCEEDED(hr) && obj && !j->p->cancelled) { IWbemObjectSink_Indicate(j->sink, 1, &obj); count = 1; }
        break;
    case OP_METHOD:
        hr = IWbemServices_ExecMethod(j->real, j->a, j->b, sync_flags, j->ctx, j->in_params, &obj, NULL);
        if (SUCCEEDED(hr) && obj && !j->p->cancelled) { IWbemObjectSink_Indicate(j->sink, 1, &obj); count = 1; }
        break;
    default:
        hr = WBEM_E_FAILED;
    }
    if (j->p->cancelled) hr = WBEM_E_CALL_CANCELLED;
    trace("[wbem-shim] async op %d '%ls' done: hr=0x%lx objects=%ld\n", j->op, j->b ? j->b : (j->a ? j->a : L""), hr, count);
    IWbemObjectSink_SetStatus(j->sink, WBEM_STATUS_COMPLETE, hr, NULL, NULL);

    if (en) IEnumWbemClassObject_Release(en);
    if (obj) IWbemClassObject_Release(obj);
    pending_remove(j->p);
    IWbemObjectSink_Release(j->sink);
    IWbemServices_Release(j->real);
    if (j->ctx) IWbemContext_Release(j->ctx);
    if (j->in_params) IWbemClassObject_Release(j->in_params);
    SysFreeString(j->a); SysFreeString(j->b);
    HeapFree(GetProcessHeap(), 0, j);
    CoUninitialize();
    InterlockedDecrement(&module_locks);
    return 0;
}

static HRESULT start_async(enum op op, IWbemServices *real, const BSTR a, const BSTR b, LONG flags,
                           IWbemContext *ctx, IWbemClassObject *in_params, IWbemObjectSink *sink)
{
    async_job *j;
    HANDLE th;
    if (!sink) return WBEM_E_INVALID_PARAMETER;
    if (!(j = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(*j)))) return WBEM_E_OUT_OF_MEMORY;
    if (!(j->p = pending_add(sink))) { HeapFree(GetProcessHeap(), 0, j); return WBEM_E_OUT_OF_MEMORY; }
    j->op = op; j->real = real; j->sink = sink; j->ctx = ctx; j->in_params = in_params; j->flags = flags;
    j->a = a ? SysAllocString(a) : NULL; j->b = b ? SysAllocString(b) : NULL;
    IWbemServices_AddRef(real); IWbemObjectSink_AddRef(sink);
    if (ctx) IWbemContext_AddRef(ctx);
    if (in_params) IWbemClassObject_AddRef(in_params);
    InterlockedIncrement(&module_locks);
    trace("[wbem-shim] async op %d '%ls' started\n", op, b ? b : (a ? a : L""));
    th = CreateThread(NULL, 0, async_thread, j, 0, NULL);
    if (!th) {
        /* failed to start the thread: roll back (async_thread normally frees everything; do it by hand here) */
        pending_remove(j->p);
        IWbemObjectSink_Release(sink); IWbemServices_Release(real);
        if (ctx) IWbemContext_Release(ctx);
        if (in_params) IWbemClassObject_Release(in_params);
        SysFreeString(j->a); SysFreeString(j->b); HeapFree(GetProcessHeap(), 0, j);
        InterlockedDecrement(&module_locks);
        return WBEM_E_FAILED;
    }
    CloseHandle(th);
    return WBEM_S_NO_ERROR;
}

/* ================= IWbemServices wrapper ================= */

typedef struct {
    IWbemServices IWbemServices_iface;
    LONG ref;
    IWbemServices *real;
} services;

static inline services *impl_svc(IWbemServices *iface) { return CONTAINING_RECORD(iface, services, IWbemServices_iface); }
static HRESULT wrap_services(IWbemServices *real, IWbemServices **out);

static HRESULT WINAPI svc_QueryInterface(IWbemServices *iface, REFIID riid, void **ppv)
{
    services *s = impl_svc(iface);
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_IWbemServices)) {
        *ppv = iface; IWbemServices_AddRef(iface); return S_OK;
    }
    /* IClientSecurity (CoSetProxyBlanket) and the rest come from the real object */
    return IWbemServices_QueryInterface(s->real, riid, ppv);
}
static ULONG WINAPI svc_AddRef(IWbemServices *iface) { return InterlockedIncrement(&impl_svc(iface)->ref); }
static ULONG WINAPI svc_Release(IWbemServices *iface)
{
    services *s = impl_svc(iface);
    LONG r = InterlockedDecrement(&s->ref);
    if (!r) { IWbemServices_Release(s->real); HeapFree(GetProcessHeap(), 0, s); InterlockedDecrement(&module_locks); }
    return r;
}
static HRESULT WINAPI svc_OpenNamespace(IWbemServices *iface, const BSTR ns, LONG flags, IWbemContext *ctx,
                                        IWbemServices **out, IWbemCallResult **res)
{
    IWbemServices *real = NULL;
    HRESULT hr = IWbemServices_OpenNamespace(impl_svc(iface)->real, ns, flags, ctx, out ? &real : NULL, res);
    if (SUCCEEDED(hr) && out && real) { hr = wrap_services(real, out); IWbemServices_Release(real); }
    return hr;
}
static HRESULT WINAPI svc_CancelAsyncCall(IWbemServices *iface, IWbemObjectSink *sink)
{
    if (pending_cancel(sink)) return WBEM_S_NO_ERROR;
    return IWbemServices_CancelAsyncCall(impl_svc(iface)->real, sink);
}
static HRESULT WINAPI svc_QueryObjectSink(IWbemServices *iface, LONG f, IWbemObjectSink **s)
{ return IWbemServices_QueryObjectSink(impl_svc(iface)->real, f, s); }
static HRESULT WINAPI svc_GetObject(IWbemServices *iface, const BSTR p, LONG f, IWbemContext *c, IWbemClassObject **o, IWbemCallResult **r)
{ return IWbemServices_GetObject(impl_svc(iface)->real, p, f, c, o, r); }
static HRESULT WINAPI svc_GetObjectAsync(IWbemServices *iface, const BSTR p, LONG f, IWbemContext *c, IWbemObjectSink *s)
{ return start_async(OP_GET, impl_svc(iface)->real, p, NULL, f, c, NULL, s); }
static HRESULT WINAPI svc_PutClass(IWbemServices *iface, IWbemClassObject *o, LONG f, IWbemContext *c, IWbemCallResult **r)
{ return IWbemServices_PutClass(impl_svc(iface)->real, o, f, c, r); }
static HRESULT WINAPI svc_PutClassAsync(IWbemServices *iface, IWbemClassObject *o, LONG f, IWbemContext *c, IWbemObjectSink *s)
{ return IWbemServices_PutClassAsync(impl_svc(iface)->real, o, f, c, s); }
static HRESULT WINAPI svc_DeleteClass(IWbemServices *iface, const BSTR cl, LONG f, IWbemContext *c, IWbemCallResult **r)
{ return IWbemServices_DeleteClass(impl_svc(iface)->real, cl, f, c, r); }
static HRESULT WINAPI svc_DeleteClassAsync(IWbemServices *iface, const BSTR cl, LONG f, IWbemContext *c, IWbemObjectSink *s)
{ return IWbemServices_DeleteClassAsync(impl_svc(iface)->real, cl, f, c, s); }
static HRESULT WINAPI svc_CreateClassEnum(IWbemServices *iface, const BSTR sc, LONG f, IWbemContext *c, IEnumWbemClassObject **e)
{ return IWbemServices_CreateClassEnum(impl_svc(iface)->real, sc, f, c, e); }
static HRESULT WINAPI svc_CreateClassEnumAsync(IWbemServices *iface, const BSTR sc, LONG f, IWbemContext *c, IWbemObjectSink *s)
{ return IWbemServices_CreateClassEnumAsync(impl_svc(iface)->real, sc, f, c, s); }
static HRESULT WINAPI svc_PutInstance(IWbemServices *iface, IWbemClassObject *o, LONG f, IWbemContext *c, IWbemCallResult **r)
{ return IWbemServices_PutInstance(impl_svc(iface)->real, o, f, c, r); }
static HRESULT WINAPI svc_PutInstanceAsync(IWbemServices *iface, IWbemClassObject *o, LONG f, IWbemContext *c, IWbemObjectSink *s)
{ return IWbemServices_PutInstanceAsync(impl_svc(iface)->real, o, f, c, s); }
static HRESULT WINAPI svc_DeleteInstance(IWbemServices *iface, const BSTR p, LONG f, IWbemContext *c, IWbemCallResult **r)
{ return IWbemServices_DeleteInstance(impl_svc(iface)->real, p, f, c, r); }
static HRESULT WINAPI svc_DeleteInstanceAsync(IWbemServices *iface, const BSTR p, LONG f, IWbemContext *c, IWbemObjectSink *s)
{ return IWbemServices_DeleteInstanceAsync(impl_svc(iface)->real, p, f, c, s); }
static HRESULT WINAPI svc_CreateInstanceEnum(IWbemServices *iface, const BSTR cl, LONG f, IWbemContext *c, IEnumWbemClassObject **e)
{ return IWbemServices_CreateInstanceEnum(impl_svc(iface)->real, cl, f, c, e); }
static HRESULT WINAPI svc_CreateInstanceEnumAsync(IWbemServices *iface, const BSTR cl, LONG f, IWbemContext *c, IWbemObjectSink *s)
{ return start_async(OP_ENUM, impl_svc(iface)->real, cl, NULL, f, c, NULL, s); }
static HRESULT WINAPI svc_ExecQuery(IWbemServices *iface, const BSTR l, const BSTR q, LONG f, IWbemContext *c, IEnumWbemClassObject **e)
{ return IWbemServices_ExecQuery(impl_svc(iface)->real, l, q, f, c, e); }
static HRESULT WINAPI svc_ExecQueryAsync(IWbemServices *iface, const BSTR l, const BSTR q, LONG f, IWbemContext *c, IWbemObjectSink *s)
{ return start_async(OP_QUERY, impl_svc(iface)->real, l, q, f, c, NULL, s); }
static HRESULT WINAPI svc_ExecNotificationQuery(IWbemServices *iface, const BSTR l, const BSTR q, LONG f, IWbemContext *c, IEnumWbemClassObject **e)
{ return IWbemServices_ExecNotificationQuery(impl_svc(iface)->real, l, q, f, c, e); }
static HRESULT WINAPI svc_ExecNotificationQueryAsync(IWbemServices *iface, const BSTR l, const BSTR q, LONG f, IWbemContext *c, IWbemObjectSink *s)
{
    trace("[wbem-shim] ExecNotificationQueryAsync '%ls' forwarded\n", q ? q : L"");
    return IWbemServices_ExecNotificationQueryAsync(impl_svc(iface)->real, l, q, f, c, s);
}
static HRESULT WINAPI svc_ExecMethod(IWbemServices *iface, const BSTR p, const BSTR m, LONG f, IWbemContext *c,
                                     IWbemClassObject *in, IWbemClassObject **out, IWbemCallResult **r)
{ return IWbemServices_ExecMethod(impl_svc(iface)->real, p, m, f, c, in, out, r); }
static HRESULT WINAPI svc_ExecMethodAsync(IWbemServices *iface, const BSTR p, const BSTR m, LONG f, IWbemContext *c,
                                          IWbemClassObject *in, IWbemObjectSink *s)
{ return start_async(OP_METHOD, impl_svc(iface)->real, p, m, f, c, in, s); }

static IWbemServicesVtbl svc_vtbl = {
    svc_QueryInterface, svc_AddRef, svc_Release,
    svc_OpenNamespace, svc_CancelAsyncCall, svc_QueryObjectSink,
    svc_GetObject, svc_GetObjectAsync, svc_PutClass, svc_PutClassAsync, svc_DeleteClass, svc_DeleteClassAsync,
    svc_CreateClassEnum, svc_CreateClassEnumAsync, svc_PutInstance, svc_PutInstanceAsync,
    svc_DeleteInstance, svc_DeleteInstanceAsync, svc_CreateInstanceEnum, svc_CreateInstanceEnumAsync,
    svc_ExecQuery, svc_ExecQueryAsync, svc_ExecNotificationQuery, svc_ExecNotificationQueryAsync,
    svc_ExecMethod, svc_ExecMethodAsync,
};

static HRESULT wrap_services(IWbemServices *real, IWbemServices **out)
{
    services *s = HeapAlloc(GetProcessHeap(), 0, sizeof(*s));
    if (!s) return E_OUTOFMEMORY;
    s->IWbemServices_iface.lpVtbl = &svc_vtbl; s->ref = 1; s->real = real;
    IWbemServices_AddRef(real);
    InterlockedIncrement(&module_locks);
    *out = &s->IWbemServices_iface;
    return S_OK;
}

/* ================= IWbemLocator wrapper ================= */

typedef struct {
    IWbemLocator IWbemLocator_iface;
    LONG ref;
    IWbemLocator *real;
} locator;

static inline locator *impl_loc(IWbemLocator *iface) { return CONTAINING_RECORD(iface, locator, IWbemLocator_iface); }

static HRESULT WINAPI loc_QueryInterface(IWbemLocator *iface, REFIID riid, void **ppv)
{
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_IWbemLocator)) {
        *ppv = iface; IWbemLocator_AddRef(iface); return S_OK;
    }
    return IWbemLocator_QueryInterface(impl_loc(iface)->real, riid, ppv);
}
static ULONG WINAPI loc_AddRef(IWbemLocator *iface) { return InterlockedIncrement(&impl_loc(iface)->ref); }
static ULONG WINAPI loc_Release(IWbemLocator *iface)
{
    locator *l = impl_loc(iface);
    LONG r = InterlockedDecrement(&l->ref);
    if (!r) { IWbemLocator_Release(l->real); HeapFree(GetProcessHeap(), 0, l); InterlockedDecrement(&module_locks); }
    return r;
}
static HRESULT WINAPI loc_ConnectServer(IWbemLocator *iface, const BSTR res, const BSTR user, const BSTR pass,
                                        const BSTR locale, LONG flags, const BSTR auth, IWbemContext *ctx, IWbemServices **out)
{
    IWbemServices *real = NULL;
    HRESULT hr = IWbemLocator_ConnectServer(impl_loc(iface)->real, res, user, pass, locale, flags, auth, ctx, &real);
    trace("[wbem-shim] ConnectServer(%ls) -> 0x%lx\n", res ? res : L"", hr);
    if (FAILED(hr)) return hr;
    hr = wrap_services(real, out);
    IWbemServices_Release(real);
    return hr;
}
static IWbemLocatorVtbl loc_vtbl = { loc_QueryInterface, loc_AddRef, loc_Release, loc_ConnectServer };

/* ================= WbemLocator class factory ================= */

static HRESULT WINAPI cf_QueryInterface(IClassFactory *iface, REFIID riid, void **ppv)
{
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_IClassFactory)) { *ppv = iface; return S_OK; }
    *ppv = NULL; return E_NOINTERFACE;
}
static ULONG WINAPI cf_AddRef(IClassFactory *iface) { return 2; }
static ULONG WINAPI cf_Release(IClassFactory *iface) { return 1; }
static HRESULT WINAPI cf_CreateInstance(IClassFactory *iface, IUnknown *outer, REFIID riid, void **ppv)
{
    IClassFactory *real_cf = NULL;
    IWbemLocator *real_loc = NULL;
    locator *l;
    HRESULT hr;
    *ppv = NULL;
    if (outer) return CLASS_E_NOAGGREGATION;
    if (!load_real()) return E_FAIL;
    if (FAILED(hr = real_DllGetClassObject(&CLSID_WbemLocator, &IID_IClassFactory, (void **)&real_cf))) return hr;
    hr = IClassFactory_CreateInstance(real_cf, NULL, &IID_IWbemLocator, (void **)&real_loc);
    IClassFactory_Release(real_cf);
    if (FAILED(hr)) return hr;
    if (!(l = HeapAlloc(GetProcessHeap(), 0, sizeof(*l)))) { IWbemLocator_Release(real_loc); return E_OUTOFMEMORY; }
    l->IWbemLocator_iface.lpVtbl = &loc_vtbl; l->ref = 1; l->real = real_loc;
    InterlockedIncrement(&module_locks);
    hr = IWbemLocator_QueryInterface(&l->IWbemLocator_iface, riid, ppv);
    IWbemLocator_Release(&l->IWbemLocator_iface);
    return hr;
}
static HRESULT WINAPI cf_LockServer(IClassFactory *iface, BOOL lock)
{
    if (lock) InterlockedIncrement(&module_locks); else InterlockedDecrement(&module_locks);
    return S_OK;
}
static IClassFactoryVtbl cf_vtbl = { cf_QueryInterface, cf_AddRef, cf_Release, cf_CreateInstance, cf_LockServer };
static IClassFactory locator_cf = { &cf_vtbl };

/* ================= exports ================= */

HRESULT WINAPI DllGetClassObject(REFCLSID rclsid, REFIID riid, void **ppv)
{
    if (IsEqualCLSID(rclsid, &CLSID_WbemLocator)) return IClassFactory_QueryInterface(&locator_cf, riid, ppv);
    if (!load_real()) return CLASS_E_CLASSNOTAVAILABLE;
    return real_DllGetClassObject(rclsid, riid, ppv);
}

HRESULT WINAPI DllCanUnloadNow(void)
{
    return S_FALSE; /* keep the DLL loaded: async threads may outlive the objects */
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved)
{
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(inst);
        InitializeCriticalSection(&pending_cs);
    }
    return TRUE;
}
