/* CFU1.H - shared ioctl ABI between CFU1.VXD and CFUDIAG.EXE.
 * Keep in sync with the equates at the top of win/vxd/CFU1.ASM.
 */
#ifndef CFU1_H
#define CFU1_H

#define CFU_GETVER      0x1000  /* out: DWORD version (0x00010000)          */
#define CFU_ENABLE      0x1001  /* in: CFU_SETUP  out: CFU_RESULT           */
#define CFU_DISABLE     0x1002
#define CFU_RDREG       0x1003  /* in: BYTE reg              out: DWORD val */
#define CFU_WRREG       0x1004  /* in: BYTE reg, BYTE val                   */
#define CFU_RDATTR      0x1005  /* in: WORD offset           out: DWORD val */
#define CFU_WRATTR      0x1006  /* in: WORD offset, BYTE val                */
#define CFU_IRQHOOK     0x1007  /* in: BYTE irq                             */
#define CFU_IRQCOUNT    0x1008  /* out: DWORD count                         */
#define CFU_IRQUNHOOK   0x1009
#define CFU_PCICRD      0x100A  /* in: BYTE reg (socket-relative) out: DWORD*/
#define CFU_PCICWR      0x100B  /* in: BYTE reg, BYTE val                   */

#pragma pack(push, 1)
typedef struct {
    unsigned short  iobase;     /* 0 = default 0x260                        */
    unsigned short  pcic;       /* 0 = default 0x3E0                        */
    unsigned char   socket;     /* 0..3                                     */
    unsigned char   cor;        /* reserved; VxD writes 0x02                */
    unsigned short  attrseg;    /* 0 = default 0xD000                       */
} CFU_SETUP;

typedef struct {
    unsigned long   err;        /* 0 ok, else CFUERR_*                      */
    unsigned char   corrb;      /* COR readback, expect 0x42                */
    unsigned char   hwrev;      /* SL811 reg 0x0E, expect 0x20 (HS v1.5)    */
    unsigned char   pcicstat;   /* PCIC interface status register           */
    unsigned char   rsvd;
} CFU_RESULT;
#pragma pack(pop)

#define CFUERR_NOCARD   1
#define CFUERR_NOREADY  2
#define CFUERR_NOMAP    3
#define CFUERR_BUFFER   4
#define CFUERR_NOTENAB  5
#define CFUERR_BADIOCTL 6

#endif
