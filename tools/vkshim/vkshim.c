// vulkan-1.dll for Enscape 3.4.4 in Revit 2020 (the enscape step of scripts/d8-addins.sh; built by
// scripts/build-vkshim.sh). Every other export is forwarded to winevulkan (vulkan-1.def).
// Enscape rejects the Mac GPU: it requires VK_KHR_external_memory_win32 (used only for CUDA interop on NVIDIA) and
// the logicOp feature (shaderStorageImageMultisample is on its list too); MoltenVK has none of them. The shim
// reports them and drops what the driver lacks when the device is created. Win32 handle functions are stubs
// that fail. DXVK (Direct3D 9 for Revit's UI) loads the same DLL first; it sees the driver as it is.
// Log: stderr and %TEMP%\vkshim.log.
#define VK_USE_PLATFORM_WIN32_KHR
#define VK_NO_PROTOTYPES
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <vulkan/vulkan.h>

// Revit is a GUI process: under Wine its stderr is lost, so the log also goes to a file.
static void LOG(const char *fmt, ...) {
  char msg[512]; va_list a; va_start(a, fmt); vsnprintf(msg, sizeof msg, fmt, a); va_end(a);
  fprintf(stderr, "[vkshim] %s\n", msg); fflush(stderr);
  char path[MAX_PATH]; DWORD n = GetTempPathA(MAX_PATH, path);
  if (n && n < MAX_PATH - 16) {
    strcat(path, "vkshim.log");
    FILE *f = fopen(path, "a");
    if (f) { SYSTEMTIME t; GetLocalTime(&t);
             fprintf(f, "%02d:%02d:%02d.%03d %5lu %s\n", t.wHour, t.wMinute, t.wSecond, t.wMilliseconds,
                     GetCurrentProcessId(), msg); fclose(f); }
  }
}

// Only what Enscape requires; it lists the semaphore and fence variants as optional.
static const char *fake_exts[] = {
  VK_KHR_EXTERNAL_MEMORY_WIN32_EXTENSION_NAME,
};
#define NFAKE (sizeof fake_exts / sizeof *fake_exts)

static void *real(const char *name) {
  static HMODULE wv;
  if (!wv) wv = LoadLibraryA("winevulkan.dll");
  return wv ? (void *)GetProcAddress(wv, name) : NULL;
}
#define REAL(n) ((PFN_##n)real(#n))

static PFN_vkGetPhysicalDeviceFeatures2 real_features2khr;   // from vkGetInstanceProcAddr, when Wine has it

// Lets a test tell this DLL from Wine's vulkan-1.dll wherever it was loaded from.
__declspec(dllexport) int revit_macos_vkshim = 1;

// DXVK instances (engine name "DXVK") and their physical devices (Wine has a set per instance) get no fakes.
#define MAXH 64
static SRWLOCK lock = SRWLOCK_INIT;
static VkInstance dxvk_inst[MAXH]; static int n_inst;
static VkPhysicalDevice dxvk_pd[MAXH]; static int n_pd;

static int is_dxvk_inst(VkInstance inst) {
  int r = 0;
  AcquireSRWLockShared(&lock);
  for (int i = 0; i < n_inst && !r; i++) r = dxvk_inst[i] == inst;
  ReleaseSRWLockShared(&lock);
  return r;
}

static int is_dxvk_pd(VkPhysicalDevice pd) {
  int r = 0;
  AcquireSRWLockShared(&lock);
  for (int i = 0; i < n_pd && !r; i++) r = dxvk_pd[i] == pd;
  ReleaseSRWLockShared(&lock);
  return r;
}

VkResult vkCreateInstance(const VkInstanceCreateInfo *ci, const VkAllocationCallbacks *alloc, VkInstance *inst) {
  VkResult r = REAL(vkCreateInstance)(ci, alloc, inst);
  const VkApplicationInfo *app = ci->pApplicationInfo;
  if (r == VK_SUCCESS && app && app->pEngineName && !strcmp(app->pEngineName, "DXVK")) {
    AcquireSRWLockExclusive(&lock);
    if (n_inst < MAXH) dxvk_inst[n_inst++] = *inst;
    ReleaseSRWLockExclusive(&lock);
    LOG("DXVK instance: no fakes");
  }
  return r;
}

VkResult vkEnumeratePhysicalDevices(VkInstance inst, uint32_t *count, VkPhysicalDevice *pds) {
  VkResult r = REAL(vkEnumeratePhysicalDevices)(inst, count, pds);
  if (r >= 0 && pds) {
    AcquireSRWLockExclusive(&lock);
    int dxvk = 0;
    for (int i = 0; i < n_inst && !dxvk; i++) dxvk = dxvk_inst[i] == inst;
    for (uint32_t i = 0; dxvk && i < *count; i++) {
      int known = 0;
      for (int j = 0; j < n_pd && !known; j++) known = dxvk_pd[j] == pds[i];
      if (!known && n_pd < MAXH) dxvk_pd[n_pd++] = pds[i];
    }
    ReleaseSRWLockExclusive(&lock);
  }
  return r;
}

BOOL WINAPI DllMain(HINSTANCE h, DWORD reason, void *reserved) {
  if (reason == DLL_PROCESS_ATTACH) {   // which copy was loaded
    char path[MAX_PATH]; GetModuleFileNameA(h, path, sizeof path);
    LOG("loaded: %s", path);
  }
  return TRUE;
}

// 1 if the real driver has the extension.
static int has_ext(VkPhysicalDevice pd, const char *name) {
  uint32_t n = 0; int found = 0;
  REAL(vkEnumerateDeviceExtensionProperties)(pd, NULL, &n, NULL);
  VkExtensionProperties *p = calloc(n ? n : 1, sizeof *p);
  if (p && REAL(vkEnumerateDeviceExtensionProperties)(pd, NULL, &n, p) >= 0)
    for (uint32_t i = 0; i < n && !found; i++) found = !strcmp(p[i].extensionName, name);
  free(p);
  return found;
}

static void fake_features(VkPhysicalDevice pd, VkPhysicalDeviceFeatures *f) {
  if (is_dxvk_pd(pd)) return;
  f->logicOp = VK_TRUE;
  f->shaderStorageImageMultisample = VK_TRUE;
}

VkResult vkEnumerateDeviceExtensionProperties(VkPhysicalDevice pd, const char *layer, uint32_t *count,
                                              VkExtensionProperties *props) {
  PFN_vkEnumerateDeviceExtensionProperties enumerate = REAL(vkEnumerateDeviceExtensionProperties);
  if (layer || is_dxvk_pd(pd)) return enumerate(pd, layer, count, props);
  uint32_t n = 0;
  VkResult r = enumerate(pd, NULL, &n, NULL);
  if (r < 0) return r;
  VkExtensionProperties *all = calloc(n + NFAKE, sizeof *all);
  if (!all) return VK_ERROR_OUT_OF_HOST_MEMORY;
  r = enumerate(pd, NULL, &n, all);
  if (r < 0) { free(all); return r; }
  uint32_t total = n;
  for (size_t i = 0; i < NFAKE; i++) {
    int found = 0;
    for (uint32_t j = 0; j < n && !found; j++) found = !strcmp(all[j].extensionName, fake_exts[i]);
    if (!found) { strcpy(all[total].extensionName, fake_exts[i]); all[total++].specVersion = 1; }
  }
  if (!props) { *count = total; free(all); return VK_SUCCESS; }
  uint32_t k = *count < total ? *count : total;
  memcpy(props, all, k * sizeof *all);
  *count = k; free(all);
  return k < total ? VK_INCOMPLETE : VK_SUCCESS;
}

void vkGetPhysicalDeviceFeatures(VkPhysicalDevice pd, VkPhysicalDeviceFeatures *f) {
  REAL(vkGetPhysicalDeviceFeatures)(pd, f);
  fake_features(pd, f);
}

void vkGetPhysicalDeviceFeatures2(VkPhysicalDevice pd, VkPhysicalDeviceFeatures2 *f) {
  REAL(vkGetPhysicalDeviceFeatures2)(pd, f);
  fake_features(pd, &f->features);
}

static void VKAPI_CALL features2khr(VkPhysicalDevice pd, VkPhysicalDeviceFeatures2 *f) {
  real_features2khr(pd, f);
  fake_features(pd, &f->features);
}

// Turns off requested features the driver lacks. Returns the old values, to restore them.
static VkPhysicalDeviceFeatures strip_features(VkPhysicalDeviceFeatures *f, const VkPhysicalDeviceFeatures *have) {
  VkPhysicalDeviceFeatures was = *f;
  if (!have->logicOp) f->logicOp = VK_FALSE;
  if (!have->shaderStorageImageMultisample) f->shaderStorageImageMultisample = VK_FALSE;
  return was;
}

VkResult vkCreateDevice(VkPhysicalDevice pd, const VkDeviceCreateInfo *ci, const VkAllocationCallbacks *alloc,
                        VkDevice *dev) {
  VkPhysicalDeviceFeatures have;
  REAL(vkGetPhysicalDeviceFeatures)(pd, &have);
  VkDeviceCreateInfo c = *ci;
  const char **exts = calloc(ci->enabledExtensionCount + 1, sizeof *exts);
  if (!exts) return VK_ERROR_OUT_OF_HOST_MEMORY;
  c.enabledExtensionCount = 0;
  for (uint32_t i = 0; i < ci->enabledExtensionCount; i++) {
    const char *e = ci->ppEnabledExtensionNames[i];
    int fake = 0;
    for (size_t j = 0; j < NFAKE && !fake; j++) fake = !strcmp(e, fake_exts[j]) && !has_ext(pd, e);
    if (fake) LOG("vkCreateDevice: drop %s", e);
    else exts[c.enabledExtensionCount++] = e;
  }
  c.ppEnabledExtensionNames = exts;
  VkPhysicalDeviceFeatures feat;
  if (ci->pEnabledFeatures) { feat = *ci->pEnabledFeatures; strip_features(&feat, &have); c.pEnabledFeatures = &feat; }
  // A VkPhysicalDeviceFeatures2 in the pNext chain belongs to the app: change it for the call, then restore it.
  VkPhysicalDeviceFeatures2 *f2 = NULL;
  for (VkBaseOutStructure *s = (VkBaseOutStructure *)ci->pNext; s; s = s->pNext)
    if (s->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2) f2 = (VkPhysicalDeviceFeatures2 *)s;
  VkPhysicalDeviceFeatures was;
  if (f2) was = strip_features(&f2->features, &have);
  VkResult r = REAL(vkCreateDevice)(pd, &c, alloc, dev);
  if (f2) f2->features = was;
  free(exts);
  LOG("vkCreateDevice = %d", r);
  return r;
}

// Right after the swap chain Enscape creates TRANSFORM_FEEDBACK_STREAM_EXT query pools without enabling
// VK_EXT_transform_feedback (Windows drivers allow it); MoltenVK refuses. Then give it an occlusion pool of the
// same size: reset, begin, end and reading results work, with one value per query instead of two.
VkResult vkCreateQueryPool(VkDevice dev, const VkQueryPoolCreateInfo *ci, const VkAllocationCallbacks *alloc,
                           VkQueryPool *pool) {
  PFN_vkCreateQueryPool create = REAL(vkCreateQueryPool);
  VkResult r = create(dev, ci, alloc, pool);
  if (r < 0 && ci->queryType == VK_QUERY_TYPE_TRANSFORM_FEEDBACK_STREAM_EXT) {
    VkQueryPoolCreateInfo c = *ci;
    c.queryType = VK_QUERY_TYPE_OCCLUSION; c.pipelineStatistics = 0;
    r = create(dev, &c, alloc, pool);
    LOG("vkCreateQueryPool: TRANSFORM_FEEDBACK_STREAM_EXT x%u -> OCCLUSION = %d", ci->queryCount, r);
  }
  return r;
}

// Enscape's render window is a WS_POPUP without WS_CHILD, put into a WPF window with SetParent. On a click Windows
// activates the first window up the chain without WS_CHILD, the render window itself, so it gets the keyboard
// focus that its navigation (keys, mouse look) needs. Wine activates the root (GA_ROOT in win32u's
// process_mouse_message), so the focus stays in WPF. The shim subclasses the window of each non-DXVK surface: on
// WM_MOUSEACTIVATE such a window activates itself and answers MA_NOACTIVATE, so Wine does not activate the root.
static const WCHAR prop_wndproc[] = L"revit-macos.vkshim.wndproc";

static int is_parented_popup(HWND h) {
  HWND parent = GetAncestor(h, GA_PARENT);
  return !(GetWindowLongW(h, GWL_STYLE) & WS_CHILD) && parent && parent != GetDesktopWindow();
}

static LRESULT CALLBACK render_wndproc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
  WNDPROC orig = (WNDPROC)GetPropW(h, prop_wndproc);
  if (msg == WM_NCDESTROY) { SetWindowLongPtrW(h, GWLP_WNDPROC, (LONG_PTR)orig); RemovePropW(h, prop_wndproc); }
  LRESULT r = CallWindowProcW(orig, h, msg, wp, lp);
  if (msg == WM_MOUSEACTIVATE && (r == MA_ACTIVATE || r == MA_ACTIVATEANDEAT || r == 0) && is_parented_popup(h)) {
    if (GetForegroundWindow() != h) SetForegroundWindow(h);
    SetFocus(h);
    LOG("WM_MOUSEACTIVATE %p: activated itself (foreground %p, focus %p)", h, GetForegroundWindow(), GetFocus());
    return r == MA_ACTIVATEANDEAT ? MA_NOACTIVATEANDEAT : MA_NOACTIVATE;
  }
  return r;
}

VkResult vkCreateWin32SurfaceKHR(VkInstance inst, const VkWin32SurfaceCreateInfoKHR *ci, const VkAllocationCallbacks *alloc,
                                 VkSurfaceKHR *surf) {
  VkResult r = REAL(vkCreateWin32SurfaceKHR)(inst, ci, alloc, surf);
  HWND h = ci->hwnd;
  if (r == VK_SUCCESS && h && !is_dxvk_inst(inst) && !GetPropW(h, prop_wndproc)) {
    SetPropW(h, prop_wndproc, (HANDLE)GetWindowLongPtrW(h, GWLP_WNDPROC));
    SetWindowLongPtrW(h, GWLP_WNDPROC, (LONG_PTR)render_wndproc);
    LOG("vkCreateWin32SurfaceKHR: hooked window %p (style %08lx)", h, GetWindowLongW(h, GWL_STYLE));
  }
  return r;
}

// Win32 handle stubs: MoltenVK has no external memory, so there is no real handle to give.
static VkResult VKAPI_CALL get_win32_handle(VkDevice d, const void *info, HANDLE *h) {
  LOG("Win32 handle export requested: not supported"); return VK_ERROR_OUT_OF_HOST_MEMORY;
}
static VkResult VKAPI_CALL import_win32_handle(VkDevice d, const void *info) {
  LOG("Win32 handle import requested: not supported"); return VK_ERROR_INVALID_EXTERNAL_HANDLE;
}
static VkResult VKAPI_CALL win32_handle_props(VkDevice d, VkExternalMemoryHandleTypeFlagBits t, HANDLE h, void *p) {
  LOG("Win32 handle properties requested: not supported"); return VK_ERROR_INVALID_EXTERNAL_HANDLE;
}

static PFN_vkVoidFunction device_stub(const char *name) {
  if (!strcmp(name, "vkGetMemoryWin32HandleKHR") || !strcmp(name, "vkGetSemaphoreWin32HandleKHR") ||
      !strcmp(name, "vkGetFenceWin32HandleKHR")) return (PFN_vkVoidFunction)get_win32_handle;
  if (!strcmp(name, "vkImportSemaphoreWin32HandleKHR") || !strcmp(name, "vkImportFenceWin32HandleKHR"))
    return (PFN_vkVoidFunction)import_win32_handle;
  if (!strcmp(name, "vkGetMemoryWin32HandlePropertiesKHR")) return (PFN_vkVoidFunction)win32_handle_props;
  return NULL;
}

PFN_vkVoidFunction vkGetDeviceProcAddr(VkDevice dev, const char *name);

PFN_vkVoidFunction vkGetInstanceProcAddr(VkInstance inst, const char *name) {
  PFN_vkVoidFunction p = REAL(vkGetInstanceProcAddr)(inst, name);
  if (!name) return p;
  if (!strcmp(name, "vkGetInstanceProcAddr")) return (PFN_vkVoidFunction)vkGetInstanceProcAddr;
  if (!strcmp(name, "vkCreateInstance")) return (PFN_vkVoidFunction)vkCreateInstance;
  if (!strcmp(name, "vkEnumeratePhysicalDevices")) return (PFN_vkVoidFunction)vkEnumeratePhysicalDevices;
  if (!strcmp(name, "vkGetDeviceProcAddr")) return (PFN_vkVoidFunction)vkGetDeviceProcAddr;
  if (!strcmp(name, "vkEnumerateDeviceExtensionProperties")) return (PFN_vkVoidFunction)vkEnumerateDeviceExtensionProperties;
  if (!strcmp(name, "vkGetPhysicalDeviceFeatures")) return (PFN_vkVoidFunction)vkGetPhysicalDeviceFeatures;
  if (!strcmp(name, "vkGetPhysicalDeviceFeatures2")) return (PFN_vkVoidFunction)vkGetPhysicalDeviceFeatures2;
  if (!strcmp(name, "vkGetPhysicalDeviceFeatures2KHR")) {
    if (!p) return NULL;
    real_features2khr = (PFN_vkGetPhysicalDeviceFeatures2)p;
    return (PFN_vkVoidFunction)features2khr;
  }
  if (!strcmp(name, "vkCreateDevice")) return (PFN_vkVoidFunction)vkCreateDevice;
  if (!strcmp(name, "vkCreateQueryPool")) return (PFN_vkVoidFunction)vkCreateQueryPool;
  if (!strcmp(name, "vkCreateWin32SurfaceKHR")) return (PFN_vkVoidFunction)vkCreateWin32SurfaceKHR;
  if (!p && inst) p = device_stub(name);
  return p;
}

PFN_vkVoidFunction vkGetDeviceProcAddr(VkDevice dev, const char *name) {
  if (name && !strcmp(name, "vkGetDeviceProcAddr")) return (PFN_vkVoidFunction)vkGetDeviceProcAddr;
  if (name && !strcmp(name, "vkCreateQueryPool")) return (PFN_vkVoidFunction)vkCreateQueryPool;
  PFN_vkVoidFunction p = REAL(vkGetDeviceProcAddr)(dev, name);
  if (!p && name) p = device_stub(name);
  return p;
}
