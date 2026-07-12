/* CSTAT.C - raw CFU_AUTOSTAT: run/armed/state/hub_port/hub_naddr */
#include <windows.h>
#include <stdio.h>
#include "cfu1.h"
int main(void){
    HANDLE h; DWORD s=0,r=0; char p[]="\\\\.\\CFU1.VXD";
    h=CreateFile(p,0,0,NULL,0,0,NULL);
    if(h==INVALID_HANDLE_VALUE){printf("no vxd\n");return 1;}
    if(DeviceIoControl(h,CFU_AUTOSTAT,NULL,0,&s,4,&r,NULL))
        printf("raw=%08lX run=%lu armed=%lu state=%lu hub_port=%lu next_addr=%lu\n",
               s, s&1, (s>>1)&1, (s>>8)&255, (s>>16)&255, (s>>24)&255);
    else printf("ioctl failed\n");
    CloseHandle(h); return 0;
}
