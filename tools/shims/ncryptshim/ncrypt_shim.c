/*
 * SPDX-License-Identifier: MIT
 * ncrypt.dll shim for Revit 2020 under Wine/CrossOver.
 *
 * Problem: PersistenceDB.dll (Revit 2020 data integrity module) imports an ECDSA P-256 private key
 * via NCryptImportKey(L"ECCPRIVATEBLOB", magic ECS2). ncrypt in CrossOver 26.3 replies
 * "Unhandled key magic 0x32534345" and Revit dies on assert dataintegrity.cpp:52.
 * bcrypt in the same Wine imports this key and signs with it fine.
 *
 * Fix: own implementations of the five functions Revit calls:
 *   NCryptOpenStorageProvider, NCryptImportKey, NCryptSignHash, NCryptVerifySignature, NCryptFreeObject
 * ECC keys (ECCPUBLICBLOB/ECCPRIVATEBLOB) live in bcrypt; everything else goes to Wine's real ncrypt.
 * Other NCrypt* and Ssl* exports are generated thunks into the real ncrypt (forwards.S),
 * BCrypt* are PE forwarders to bcrypt.dll (ncrypt.def). Generator: gen_forwards.py.
 *
 * Enabled for Revit.exe only: DLL in the Revit folder + AppDefaults\Revit.exe\DllOverrides ncrypt=native,builtin.
 * Diagnostics: OutputDebugString with the "[ncrypt-shim]" prefix (CX_DEBUGMSG=+debugstr).
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <bcrypt.h>
#include <ncrypt.h>

#ifndef NCRYPT_SILENT_FLAG
#define NCRYPT_SILENT_FLAG 0x40
#endif

/* Thunk table into the real ncrypt (filled in shim_resolve, defined in forwards_table.c). */
struct shim_forward { const char *name; void **slot; };
extern struct shim_forward shim_forwards[];
extern void *shim_unresolved_ptr;

typedef SECURITY_STATUS (WINAPI *pOpenStorageProvider)(NCRYPT_PROV_HANDLE *, LPCWSTR, DWORD);
typedef SECURITY_STATUS (WINAPI *pImportKey)(NCRYPT_PROV_HANDLE, NCRYPT_KEY_HANDLE, LPCWSTR, NCryptBufferDesc *,
                                             NCRYPT_KEY_HANDLE *, PBYTE, DWORD, DWORD);
typedef SECURITY_STATUS (WINAPI *pSignHash)(NCRYPT_KEY_HANDLE, VOID *, PBYTE, DWORD, PBYTE, DWORD, DWORD *, DWORD);
typedef SECURITY_STATUS (WINAPI *pVerifySignature)(NCRYPT_KEY_HANDLE, VOID *, PBYTE, DWORD, PBYTE, DWORD, DWORD);
typedef SECURITY_STATUS (WINAPI *pFreeObject)(NCRYPT_HANDLE);

static HMODULE real_ncrypt;
static pOpenStorageProvider real_OpenStorageProvider;
static pImportKey real_ImportKey;
static pSignHash real_SignHash;
static pVerifySignature real_VerifySignature;
static pFreeObject real_FreeObject;

static void trace(const char *fmt, ...)
{
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    wvsprintfA(buf, fmt, ap);
    va_end(ap);
    OutputDebugStringA(buf);
}

/* ---- own objects: pointer registry, so foreign handles are never dereferenced ---- */

enum { OBJ_PROV = 1, OBJ_KEY = 2 };
typedef struct {
    DWORD kind;
    NCRYPT_PROV_HANDLE real_prov;   /* OBJ_PROV: lazily opened real provider */
    BCRYPT_ALG_HANDLE alg;          /* OBJ_KEY */
    BCRYPT_KEY_HANDLE key;          /* OBJ_KEY */
    DWORD ecdsa_bits;               /* OBJ_KEY: 256/384 for ECDSA P-256/P-384 (Wine doesn't return BCRYPT_KEY_LENGTH) */
} shim_obj;

#define MAX_OBJS 4096
static shim_obj *objs[MAX_OBJS];
static CRITICAL_SECTION objs_cs;

static BOOL reg_add(shim_obj *o)
{
    BOOL ok = FALSE;
    EnterCriticalSection(&objs_cs);
    for (int i = 0; i < MAX_OBJS; i++) if (!objs[i]) { objs[i] = o; ok = TRUE; break; }
    LeaveCriticalSection(&objs_cs);
    return ok;
}

static shim_obj *reg_find(ULONG_PTR h, DWORD kind)
{
    shim_obj *r = NULL;
    if (!h) return NULL;
    EnterCriticalSection(&objs_cs);
    for (int i = 0; i < MAX_OBJS; i++)
        if (objs[i] == (shim_obj *)h && (!kind || objs[i]->kind == kind)) { r = objs[i]; break; }
    LeaveCriticalSection(&objs_cs);
    return r;
}

static void reg_del(shim_obj *o)
{
    EnterCriticalSection(&objs_cs);
    for (int i = 0; i < MAX_OBJS; i++) if (objs[i] == o) { objs[i] = NULL; break; }
    LeaveCriticalSection(&objs_cs);
}

static shim_obj *obj_new(DWORD kind)
{
    shim_obj *o = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(*o));
    if (!o) return NULL;
    o->kind = kind;
    if (!reg_add(o)) { HeapFree(GetProcessHeap(), 0, o); return NULL; }
    return o;
}

static void obj_free(shim_obj *o)
{
    reg_del(o);
    if (o->key) BCryptDestroyKey(o->key);
    if (o->alg) BCryptCloseAlgorithmProvider(o->alg, 0);
    if (o->real_prov && real_FreeObject) real_FreeObject(o->real_prov);
    HeapFree(GetProcessHeap(), 0, o);
}

static SECURITY_STATUS map_status(NTSTATUS st)
{
    switch ((DWORD)st) {
    case 0:          return ERROR_SUCCESS;
    case 0xC000A000: return NTE_BAD_SIGNATURE;     /* STATUS_INVALID_SIGNATURE */
    case 0xC0000023: return NTE_BUFFER_TOO_SMALL;  /* STATUS_BUFFER_TOO_SMALL */
    case 0xC000000D: return NTE_INVALID_PARAMETER; /* STATUS_INVALID_PARAMETER */
    case 0xC00000BB: return NTE_NOT_SUPPORTED;     /* STATUS_NOT_SUPPORTED */
    case 0xC0000008: return NTE_INVALID_HANDLE;    /* STATUS_INVALID_HANDLE */
    case 0xC0000017: return NTE_NO_MEMORY;         /* STATUS_NO_MEMORY */
    case 0xC0000225: return NTE_NOT_FOUND;         /* STATUS_NOT_FOUND */
    default:         return NTE_FAIL;
    }
}

/* ECCKEY_BLOB.dwMagic -> bcrypt algorithm */
static LPCWSTR ecc_alg_for_magic(DWORD magic)
{
    switch (magic) {
    case BCRYPT_ECDSA_PUBLIC_P256_MAGIC: case BCRYPT_ECDSA_PRIVATE_P256_MAGIC: return BCRYPT_ECDSA_P256_ALGORITHM;
    case BCRYPT_ECDSA_PUBLIC_P384_MAGIC: case BCRYPT_ECDSA_PRIVATE_P384_MAGIC: return BCRYPT_ECDSA_P384_ALGORITHM;
    case BCRYPT_ECDSA_PUBLIC_P521_MAGIC: case BCRYPT_ECDSA_PRIVATE_P521_MAGIC: return BCRYPT_ECDSA_P521_ALGORITHM;
    case BCRYPT_ECDH_PUBLIC_P256_MAGIC:  case BCRYPT_ECDH_PRIVATE_P256_MAGIC:  return BCRYPT_ECDH_P256_ALGORITHM;
    case BCRYPT_ECDH_PUBLIC_P384_MAGIC:  case BCRYPT_ECDH_PRIVATE_P384_MAGIC:  return BCRYPT_ECDH_P384_ALGORITHM;
    case BCRYPT_ECDH_PUBLIC_P521_MAGIC:  case BCRYPT_ECDH_PRIVATE_P521_MAGIC:  return BCRYPT_ECDH_P521_ALGORITHM;
    default: return NULL;
    }
}

static SECURITY_STATUS ensure_real_prov(shim_obj *p)
{
    if (p->real_prov) return ERROR_SUCCESS;
    if (!real_OpenStorageProvider) return NTE_NOT_SUPPORTED;
    return real_OpenStorageProvider(&p->real_prov, MS_KEY_STORAGE_PROVIDER, 0);
}

/* ---- exported implementations ---- */

SECURITY_STATUS WINAPI NCryptOpenStorageProvider(NCRYPT_PROV_HANDLE *phProvider, LPCWSTR pszProviderName, DWORD dwFlags)
{
    shim_obj *p;
    if (!phProvider) return NTE_INVALID_PARAMETER;
    if (!(p = obj_new(OBJ_PROV))) return NTE_NO_MEMORY;
    *phProvider = (NCRYPT_PROV_HANDLE)p;
    trace("[ncrypt-shim] OpenStorageProvider(%ls, 0x%lx) -> %p\n", pszProviderName ? pszProviderName : L"(null)", dwFlags, p);
    return ERROR_SUCCESS;
}

SECURITY_STATUS WINAPI NCryptImportKey(NCRYPT_PROV_HANDLE hProvider, NCRYPT_KEY_HANDLE hImportKey, LPCWSTR pszBlobType,
                                       NCryptBufferDesc *pParameterList, NCRYPT_KEY_HANDLE *phKey,
                                       PBYTE pbData, DWORD cbData, DWORD dwFlags)
{
    shim_obj *p = reg_find(hProvider, OBJ_PROV);
    if (!p) return real_ImportKey ? real_ImportKey(hProvider, hImportKey, pszBlobType, pParameterList, phKey, pbData, cbData, dwFlags)
                                  : NTE_INVALID_HANDLE;
    if (!phKey || !pszBlobType) return NTE_INVALID_PARAMETER;

    if (!hImportKey && (!lstrcmpW(pszBlobType, BCRYPT_ECCPRIVATE_BLOB) || !lstrcmpW(pszBlobType, BCRYPT_ECCPUBLIC_BLOB))
        && pbData && cbData >= sizeof(BCRYPT_ECCKEY_BLOB))
    {
        DWORD magic = ((BCRYPT_ECCKEY_BLOB *)pbData)->dwMagic;
        LPCWSTR alg_id = ecc_alg_for_magic(magic);
        shim_obj *k;
        NTSTATUS st;
        if (!alg_id) { trace("[ncrypt-shim] ImportKey: unknown ECC magic 0x%lx\n", magic); return NTE_BAD_KEY; }
        if (!(k = obj_new(OBJ_KEY))) return NTE_NO_MEMORY;
        st = BCryptOpenAlgorithmProvider(&k->alg, alg_id, NULL, 0);
        if (!st) st = BCryptImportKeyPair(k->alg, NULL, pszBlobType, &k->key, pbData, cbData, 0);
        trace("[ncrypt-shim] ImportKey(%ls, magic 0x%lx, %lu bytes, flags 0x%lx) via bcrypt %ls -> 0x%lx\n",
              pszBlobType, magic, cbData, dwFlags, alg_id, (DWORD)st);
        if (st) { obj_free(k); return map_status(st); }
        if (!lstrcmpW(alg_id, BCRYPT_ECDSA_P256_ALGORITHM)) k->ecdsa_bits = 256;
        else if (!lstrcmpW(alg_id, BCRYPT_ECDSA_P384_ALGORITHM)) k->ecdsa_bits = 384;
        *phKey = (NCRYPT_KEY_HANDLE)k;
        return ERROR_SUCCESS;
    }

    /* not ECC: pass to the real ncrypt via a lazily opened real provider */
    {
        SECURITY_STATUS s = ensure_real_prov(p);
        if (s) return s;
        s = real_ImportKey ? real_ImportKey(p->real_prov, hImportKey, pszBlobType, pParameterList, phKey, pbData, cbData, dwFlags)
                           : NTE_NOT_SUPPORTED;
        trace("[ncrypt-shim] ImportKey(%ls) forwarded -> 0x%lx\n", pszBlobType, s);
        return s;
    }
}

/* ECDSA hash of non-standard length. Revit 2020 signs and verifies 16-byte hashes (MD5?), while Wine's bcrypt
 * only accepts 20/32/48/64 bytes ("key_asymmetric_sign hash size 16 not yet supported").
 * ECDSA turns the hash into the integer e = leftmost min(len*8, bits(n)) bits of the hash, so left zero-padding
 * to the key length and right truncation to it yield the same signature as on Windows. */
static const BYTE *ecdsa_norm_hash(shim_obj *k, const BYTE *hash, DWORD *cb, BYTE *buf)
{
    DWORD bits = k->ecdsa_bits, n;
    if (*cb == 20 || *cb == 32 || *cb == 48 || *cb == 64 || !bits) return hash;
    n = bits / 8;
    if (*cb < n) { ZeroMemory(buf, n - *cb); CopyMemory(buf + n - *cb, hash, *cb); }
    else CopyMemory(buf, hash, n);
    trace("[ncrypt-shim] hash %lu bytes -> %lu (ECDSA P-%lu)\n", *cb, n, bits);
    *cb = n;
    return buf;
}

SECURITY_STATUS WINAPI NCryptSignHash(NCRYPT_KEY_HANDLE hKey, VOID *pPaddingInfo, PBYTE pbHashValue, DWORD cbHashValue,
                                      PBYTE pbSignature, DWORD cbSignature, DWORD *pcbResult, DWORD dwFlags)
{
    shim_obj *k = reg_find(hKey, OBJ_KEY);
    NTSTATUS st;
    BYTE nb[48];
    if (!k) return real_SignHash ? real_SignHash(hKey, pPaddingInfo, pbHashValue, cbHashValue, pbSignature, cbSignature, pcbResult, dwFlags)
                                 : NTE_INVALID_HANDLE;
    /* Size query: for ECDSA Wine's bcrypt returns the key length (32), but the r||s signature is twice that (64).
     * Revit allocates the buffer from that answer and gets STATUS_BUFFER_TOO_SMALL on save. */
    if (!pbSignature && k->ecdsa_bits && pcbResult) {
        *pcbResult = 2 * (k->ecdsa_bits / 8);
        trace("[ncrypt-shim] SignHash size query -> %lu\n", *pcbResult);
        return ERROR_SUCCESS;
    }
    if (!pPaddingInfo && pbHashValue) pbHashValue = (PBYTE)ecdsa_norm_hash(k, pbHashValue, &cbHashValue, nb);
    st = BCryptSignHash(k->key, pPaddingInfo, pbHashValue, cbHashValue, pbSignature, cbSignature, pcbResult,
                        dwFlags & ~NCRYPT_SILENT_FLAG);
    trace("[ncrypt-shim] SignHash(%lu bytes, out %lu) -> 0x%lx\n", cbHashValue, pcbResult ? *pcbResult : 0, (DWORD)st);
    return map_status(st);
}

SECURITY_STATUS WINAPI NCryptVerifySignature(NCRYPT_KEY_HANDLE hKey, VOID *pPaddingInfo, PBYTE pbHashValue, DWORD cbHashValue,
                                             PBYTE pbSignature, DWORD cbSignature, DWORD dwFlags)
{
    shim_obj *k = reg_find(hKey, OBJ_KEY);
    NTSTATUS st;
    BYTE nb[48];
    if (!k) return real_VerifySignature ? real_VerifySignature(hKey, pPaddingInfo, pbHashValue, cbHashValue, pbSignature, cbSignature, dwFlags)
                                        : NTE_INVALID_HANDLE;
    if (!pPaddingInfo && pbHashValue) pbHashValue = (PBYTE)ecdsa_norm_hash(k, pbHashValue, &cbHashValue, nb);
    st = BCryptVerifySignature(k->key, pPaddingInfo, pbHashValue, cbHashValue, pbSignature, cbSignature,
                               dwFlags & ~NCRYPT_SILENT_FLAG);
    trace("[ncrypt-shim] VerifySignature(%lu bytes) -> 0x%lx\n", cbHashValue, (DWORD)st);
    return map_status(st);
}

SECURITY_STATUS WINAPI NCryptFreeObject(NCRYPT_HANDLE hObject)
{
    shim_obj *o = reg_find(hObject, 0);
    if (!o) return real_FreeObject ? real_FreeObject(hObject) : NTE_INVALID_HANDLE;
    obj_free(o);
    return ERROR_SUCCESS;
}

/* ---- loading the real ncrypt ---- */

static void shim_resolve(HMODULE self)
{
    WCHAR path[MAX_PATH];
    GetSystemDirectoryW(path, MAX_PATH);
    lstrcatW(path, L"\\ncrypt.dll");
    real_ncrypt = LoadLibraryW(path);
    if (real_ncrypt == self) { FreeLibrary(real_ncrypt); real_ncrypt = NULL; }
    trace("[ncrypt-shim] loaded, real ncrypt %ls -> %p (self %p)\n", path, real_ncrypt, self);
    if (!real_ncrypt) return;

    real_OpenStorageProvider = (pOpenStorageProvider)GetProcAddress(real_ncrypt, "NCryptOpenStorageProvider");
    real_ImportKey = (pImportKey)GetProcAddress(real_ncrypt, "NCryptImportKey");
    real_SignHash = (pSignHash)GetProcAddress(real_ncrypt, "NCryptSignHash");
    real_VerifySignature = (pVerifySignature)GetProcAddress(real_ncrypt, "NCryptVerifySignature");
    real_FreeObject = (pFreeObject)GetProcAddress(real_ncrypt, "NCryptFreeObject");

    for (struct shim_forward *f = shim_forwards; f->name; f++) {
        void *p = (void *)GetProcAddress(real_ncrypt, f->name);
        if (p) *f->slot = p;
    }
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved)
{
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(inst);
        InitializeCriticalSection(&objs_cs);
        shim_resolve(inst);
        /* Revit 2026: our ncrypt.dll loads early (imported by PersistenceDB), so it pulls in tools/shims/rvtfix
           (Wine fixes inside the Revit process) if rvtfix.dll sits next to Revit.exe. */
        WCHAR p[MAX_PATH], *slash;
        if (GetModuleFileNameW(NULL, p, MAX_PATH) && (slash = wcsrchr(p, L'\\')) && slash - p < MAX_PATH - 12) {
            lstrcpyW(slash + 1, L"rvtfix.dll");
            if (GetFileAttributesW(p) != INVALID_FILE_ATTRIBUTES) LoadLibraryW(p);
        }
    }
    return TRUE;
}
