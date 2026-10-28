/*
 * SPDX-License-Identifier: MIT
 * dpapi -- decrypts a file the bottle's Windows user protected with DPAPI, for the Mac side of ./revit mcp --server
 * python. The MCP server for Revit (Python) keeps its pairing secret DPAPI-encrypted in
 * %LOCALAPPDATA%\RevitMCPPython\pairing.dpapi; its Python client needs Windows to read it, and on the Mac it runs
 * outside Wine. The launcher copies this program into the bottle (C:\ProgramData\revit-macos\dpapi\dpapi.exe), runs it
 * once under the project lock and hands the plaintext to the client over a pipe; nothing is written to disk.
 *
 *   dpapi.exe unprotect <file>         the plaintext to stdout, nothing else
 *   dpapi.exe protect <in> <out>       for the tests only: <out> = DPAPI(<in>)
 *
 * CRYPTPROTECT_UI_FORBIDDEN: never a prompt. Exit code: 0 done; 1 a file could not be read or written; 2 usage, or
 * DPAPI refused (a file of another user, or not DPAPI). On failure one line on stderr and nothing on stdout.
 */
#include <windows.h>
#include <wincrypt.h>
#include <stdio.h>
#include <fcntl.h>
#include <io.h>

#define MAX_IN (64 * 1024)

static BYTE buf[MAX_IN];

static int read_all(const wchar_t *path, DWORD *n) {
  FILE *f = _wfopen(path, L"rb");
  if (!f) return 0;
  size_t got = fread(buf, 1, sizeof buf, f);
  int ok = !ferror(f) && feof(f);
  fclose(f);
  *n = (DWORD)got;
  return ok;
}

int wmain(int argc, wchar_t **argv) {
  DATA_BLOB in, out = { 0, NULL };
  DWORD n = 0;
  int protect;
  if (argc == 3 && !wcscmp(argv[1], L"unprotect")) protect = 0;
  else if (argc == 4 && !wcscmp(argv[1], L"protect")) protect = 1;
  else { fputs("usage: dpapi.exe unprotect <file> | protect <in> <out>\n", stderr); return 2; }
  if (!read_all(argv[2], &n)) { fputs("cannot read the file\n", stderr); return 1; }
  in.cbData = n; in.pbData = buf;
  if (!(protect ? CryptProtectData(&in, NULL, NULL, NULL, NULL, CRYPTPROTECT_UI_FORBIDDEN, &out)
                : CryptUnprotectData(&in, NULL, NULL, NULL, NULL, CRYPTPROTECT_UI_FORBIDDEN, &out))) {
    fprintf(stderr, "DPAPI refused (error %lu)\n", GetLastError());
    return 2;
  }
  int rc = 0;
  if (protect) {
    FILE *f = _wfopen(argv[3], L"wb");
    if (!f || fwrite(out.pbData, 1, out.cbData, f) != out.cbData) { fputs("cannot write the file\n", stderr); rc = 1; }
    if (f && fclose(f)) rc = 1;
  } else {
    _setmode(_fileno(stdout), _O_BINARY);
    if (fwrite(out.pbData, 1, out.cbData, stdout) != out.cbData || fflush(stdout)) rc = 1;
  }
  SecureZeroMemory(out.pbData, out.cbData);
  LocalFree(out.pbData);
  return rc;
}
