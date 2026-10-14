/*
 * SPDX-License-Identifier: MIT
 * hook.h -- what our in-memory hooks share (rvtfix, wv2fix, tlbpin). Header only: every function is static inline, each
 * shim gets its own copy. Define SHIM_NAME (a string) before including it.
 *
 * trace       OutputDebugString of one line that starts with "[SHIM_NAME] " (CX_DEBUGMSG=+debugstr shows it)
 * alloc_near  executable memory within 4 GB above a module: an export entry is a 32-bit RVA from the module's base
 * write_jump  "mov rax, <dest>; jmp rax" (12 bytes) over code, with the page made writable for the moment (tlbpin)
 * patch_export  points one export of a loaded module at a hook through a jump written into memory from alloc_near;
 *             the caller flushes the instruction cache over its thunks once they are all written
 */
#ifndef SHIM_HOOK_H
#define SHIM_HOOK_H
#include <windows.h>
#include <stdarg.h>

#ifndef SHIM_NAME
#error "define SHIM_NAME before including hook.h"
#endif

static inline void trace(const char *fmt, ...)
{
    char buf[1100];   /* wvsprintfA writes at most 1024 characters */
    va_list ap;
    int n = wsprintfA(buf, "[%s] ", SHIM_NAME);
    va_start(ap, fmt);
    wvsprintfA(buf + n, fmt, ap);
    va_end(ap);
    OutputDebugStringA(buf);
}

static inline BYTE *alloc_near(BYTE *base, SIZE_T size)
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

static inline BOOL write_jump(void *at, void *dest)
{
    BYTE jmp[12] = {0x48, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xe0}; /* mov rax, imm64; jmp rax */
    DWORD old;
    CopyMemory(jmp + 2, &dest, sizeof(dest));
    if (!VirtualProtect(at, sizeof(jmp), PAGE_EXECUTE_READWRITE, &old)) {
        trace("VirtualProtect failed %lu\n", GetLastError());
        return FALSE;
    }
    CopyMemory(at, jmp, sizeof(jmp));
    VirtualProtect(at, sizeof(jmp), old, &old);
    FlushInstructionCache(GetCurrentProcess(), at, sizeof(jmp));
    return TRUE;
}

/* GetProcAddress (and .NET P/Invoke through it) sees the new entry; imports other modules have bound already keep the
 * original. thunk: 16 bytes per hook in memory from alloc_near(mod, …), which is already writable and executable;
 * *orig gets the original function */
static inline BOOL patch_export(HMODULE mod, const char *name, void *hook, void **orig, BYTE *thunk)
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

#endif
