/*
 * SPDX-License-Identifier: MIT
 * Adds a printer on the Wine PostScript driver (wineps.drv) with our PPD to the bottle and makes it the default.
 * Usage: add_printer.exe <name> <path to .ppd> <port>
 * Print processor is "wineps" (as for printers Wine imports from CUPS): gdi32 spools "NT EMF 1.003",
 * while WinPrint in CrossOver only understands RAW/TEXT ("datatype not supported"). regsvr32 wineps.drv registers it.
 * An existing printer with the same name is recreated.
 * The bottle has no printers at all (no CUPS queues on the Mac), and Revit won't open Print/Page Setup without one.
 */
#include <windows.h>
#include <winspool.h>
#include <stdio.h>

int wmain(int argc, WCHAR **argv)
{
    DRIVER_INFO_3W di = {0};
    PRINTER_INFO_2W pi = {0};
    WCHAR drv[] = L"Wine PostScript Driver", env[] = L"Windows x64", ps[] = L"wineps.drv", raw[] = L"RAW",
          proc[] = L"wineps";
    HANDLE h;
    if (argc < 4) { fwprintf(stderr, L"usage: add_printer <name> <ppd> <port>\n"); return 2; }

    di.cVersion = 3; di.pName = drv; di.pEnvironment = env; di.pDriverPath = ps; di.pConfigFile = ps;
    di.pDataFile = argv[2]; di.pDefaultDataType = raw;
    if (!AddPrinterDriverExW(NULL, 3, (BYTE *)&di, APD_COPY_NEW_FILES) && GetLastError() != ERROR_PRINTER_DRIVER_ALREADY_INSTALLED)
        wprintf(L"AddPrinterDriverExW: error %lu\n", GetLastError());
    else
        wprintf(L"AddPrinterDriverExW: ok\n");

    {
        PRINTER_DEFAULTSW pd = { NULL, NULL, PRINTER_ALL_ACCESS };
        if (OpenPrinterW(argv[1], &h, &pd)) {
            wprintf(L"DeletePrinter (old): %ls\n", DeletePrinter(h) ? L"ok" : L"fail");
            ClosePrinter(h);
        }
    }
    {
        pi.pPrinterName = argv[1]; pi.pPortName = argv[3]; pi.pDriverName = drv; pi.pPrintProcessor = proc;
        pi.pDatatype = raw; pi.Attributes = PRINTER_ATTRIBUTE_LOCAL; pi.Priority = 1;
        h = AddPrinterW(NULL, 2, (BYTE *)&pi);
        if (!h) { wprintf(L"AddPrinterW: error %lu\n", GetLastError()); return 1; }
        ClosePrinter(h); wprintf(L"AddPrinterW: ok %ls on %ls\n", argv[1], argv[3]);
    }
    wprintf(L"SetDefaultPrinterW: %ls\n", SetDefaultPrinterW(argv[1]) ? L"ok" : L"fail");
    return 0;
}
