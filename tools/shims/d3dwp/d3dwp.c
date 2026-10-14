/*
 * SPDX-License-Identifier: MIT
 * d3dwp.dll -- D3D11CreateDevice shim for Revit 2020 OGS under CrossOver.
 *
 * Problem: the material browser (RevitMaterialUI3 -> DisplayUtil::getCMUIDevice) renders previews on a separate
 * "Dx11_WARP" device, i.e. D3D11CreateDevice(D3D_DRIVER_TYPE_WARP). D3DMetal can't do WARP:
 * the Revit journal shows "WARP device could not be initialized" -> "Can't get OGS device" -> Materials won't open.
 *
 * Fix: OGSDeviceDX11.dll loads L"D3D11.dll" via LoadLibraryW and gets D3D11CreateDevice via GetProcAddress.
 * tools/shims/rvtfix replaces that name with L"d3dwp.dll" in the loaded OGSDeviceDX11.dll; this DLL sits next to Revit.exe.
 * WARP/REFERENCE are replaced with HARDWARE (default adapter); everything else goes to the real d3d11 unchanged.
 * Diagnostics: OutputDebugString with the "[d3dwp]" prefix (CX_DEBUGMSG=+debugstr).
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>

typedef HRESULT (WINAPI *pD3D11CreateDevice)(IDXGIAdapter *, D3D_DRIVER_TYPE, HMODULE, UINT, const D3D_FEATURE_LEVEL *,
                                             UINT, UINT, ID3D11Device **, D3D_FEATURE_LEVEL *, ID3D11DeviceContext **);

static void trace(const char *fmt, ...)
{
    char buf[256];
    va_list ap;
    va_start(ap, fmt);
    wvsprintfA(buf, fmt, ap);
    va_end(ap);
    OutputDebugStringA(buf);
}

HRESULT WINAPI shim_D3D11CreateDevice(IDXGIAdapter *adapter, D3D_DRIVER_TYPE type, HMODULE swrast, UINT flags,
                                      const D3D_FEATURE_LEVEL *levels, UINT nlevels, UINT sdk, ID3D11Device **dev,
                                      D3D_FEATURE_LEVEL *got, ID3D11DeviceContext **ctx)
{
    static pD3D11CreateDevice real;
    D3D_DRIVER_TYPE asked = type;
    HRESULT hr;
    if (!real) {
        HMODULE h = LoadLibraryW(L"d3d11.dll");
        real = h ? (pD3D11CreateDevice)GetProcAddress(h, "D3D11CreateDevice") : NULL;
        if (!real) { trace("[d3dwp] real d3d11!D3D11CreateDevice not found\n"); return E_FAIL; }
    }
    if (type == D3D_DRIVER_TYPE_WARP || type == D3D_DRIVER_TYPE_REFERENCE) {
        type = D3D_DRIVER_TYPE_HARDWARE;
        swrast = NULL;
    }
    hr = real(adapter, type, swrast, flags, levels, nlevels, sdk, dev, got, ctx);
    trace("[d3dwp] D3D11CreateDevice(type %d -> %d, flags 0x%x) -> 0x%08lx\n", asked, type, flags, hr);
    return hr;
}
