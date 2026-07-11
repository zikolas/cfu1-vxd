/* CPEEK.C - hexdump arbitrary linear memory through CFU1.VXD's ring-0
 * CFU_PEEK ioctl.  Usage: CPEEK <hexaddr> [len]   (len <= 256, default 64)
 * Opens the already-resident VxD without DELETE_ON_CLOSE so the IOS
 * registration state is untouched.
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include "cfu1.h"

int main(int argc, char **argv)
{
    HANDLE h;
    DWORD pk[2], r = 0;
    static unsigned char buf[256];
    unsigned long addr;
    int len = 64, i, j;
    char path[] = "\\\\.\\CFU1.VXD";

    if (argc < 2) { printf("usage: CPEEK <hexaddr> [len<=256] | CPEEK E\n"); return 1; }

    h = CreateFile(path, 0, 0, NULL, 0, 0, NULL);
    if (h == INVALID_HANDLE_VALUE) { printf("no CFU1.VXD (%lu)\n", GetLastError()); return 1; }

    if (argv[1][0] == 'E' || argv[1][0] == 'e') {     /* enumerate DCBs */
        DWORD e[16];
        memset(e, 0, sizeof e);
        if (!DeviceIoControl(h, CFU_DCBENUM, NULL, 0, e, sizeof e, &r, NULL))
            printf("DCBENUM failed (%lu)\n", GetLastError());
        else {
            printf("%lu DCBs:\n", e[0]);
            for (i = 0; i < (int)e[0] && i < 15; i++)
                printf("  DCB %d @ %08lX\n", i, e[1 + i]);
        }
        CloseHandle(h);
        return 0;
    }
    addr = strtoul(argv[1], NULL, 16);
    if (argc > 2) len = atoi(argv[2]);
    if (len < 1 || len > 256) len = 64;
    pk[0] = addr;
    pk[1] = (DWORD)len;
    if (!DeviceIoControl(h, CFU_PEEK, pk, 8, buf, (DWORD)len, &r, NULL)) {
        printf("PEEK failed (%lu)\n", GetLastError());
        CloseHandle(h);
        return 1;
    }
    for (i = 0; i < len; i += 16) {
        printf("%08lX:", addr + i);
        for (j = 0; j < 16 && i + j < len; j++) printf(" %02X", buf[i + j]);
        printf("\n");
    }
    CloseHandle(h);
    return 0;
}
