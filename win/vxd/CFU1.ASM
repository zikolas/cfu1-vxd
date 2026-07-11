;****************************************************************************
; CFU1.ASM - RATOC REX-CFU1 (SL811HS USB 1.1 host) PC Card enabler VxD
;            for Windows 95/98.
;
; The REX-CFU1's CIS CONFIG tuple points at attribute 0xF8, but the card's
; real (and only) configuration register is at attribute 0xFC - so the OS
; PCMCIA stack can never enable it.  This VxD enables the card by hand:
; socket power via the 82365-compatible PCIC, a temporary attribute-memory
; window for the COR-at-0xFC poke, then an I/O window for the SL811HS.
;
; Dynamically loadable: CFUDIAG.EXE loads it with
;   CreateFile("\\\\.\\<path>\\CFU1.VXD", ..., FILE_FLAG_DELETE_ON_CLOSE)
; and drives it through DeviceIoControl.  See CFU1.H for the ioctl ABI.
;
; Hardware findings this encodes are documented in PROBE-NOTES.md (repo
; root); verified on real hardware (IBM PC110) 2026-07-11.
;
; Build (Open Watcom wlink + JWasm):
;   jwasm -q -Iddkinc win/vxd/CFU1.ASM
;   wlink system win_vxd name CFU1.VXD file CFU1.obj export CFU1_DDB.1
;****************************************************************************
        .386p
        include vmm.inc
        include vwin32.inc
        include vpicd.inc

;----------------------------------------------------------------------------
; ioctl codes (keep in sync with win/diag/CFU1.H)
;----------------------------------------------------------------------------
CFU_GETVER      equ 1000h       ; out: DWORD version
CFU_ENABLE      equ 1001h       ; in: CFU_SETUP, out: CFU_RESULT
CFU_DISABLE     equ 1002h       ; power socket down
CFU_RDREG       equ 1003h       ; in: BYTE reg          out: BYTE val
CFU_WRREG       equ 1004h       ; in: BYTE reg,BYTE val
CFU_RDATTR      equ 1005h       ; in: WORD offset       out: BYTE val
CFU_WRATTR      equ 1006h       ; in: WORD offset,BYTE val
CFU_IRQHOOK     equ 1007h       ; in: BYTE irq
CFU_IRQCOUNT    equ 1008h       ; out: DWORD count (does not clear)
CFU_IRQUNHOOK   equ 1009h
CFU_PCICRD      equ 100Ah       ; in: BYTE reg (socket bank added) out: DWORD
CFU_PCICWR      equ 100Bh       ; in: BYTE reg, BYTE val

VXD_VERSION     equ 00010001h   ; 1.01

; CFU_SETUP input structure offsets
CS_IOBASE       equ 0           ; WORD  I/O base (0 = default 0x260)
CS_PCIC         equ 2           ; WORD  PCIC index port (0 = default 0x3E0)
CS_SOCKET       equ 4           ; BYTE  socket number 0..3
CS_COR          equ 5           ; BYTE  config index (0 = default 0x02)
CS_ATTRSEG      equ 6           ; WORD  attr window real-mode segment
                                ;       (0 = default 0xD000)
CFU_SETUP_SIZE  equ 8

; CFU_RESULT output structure offsets
CR_ERR          equ 0           ; DWORD 0=ok else CFUERR_*
CR_CORRB        equ 4           ; BYTE  COR readback (expect index|0x40)
CR_HWREV        equ 5           ; BYTE  SL811 reg 0x0E (0x20 = HS rev 1.5)
CR_PCICSTAT     equ 6           ; BYTE  PCIC interface status
CR_RSVD         equ 7           ; BYTE
CFU_RESULT_SIZE equ 8

CFUERR_NOCARD   equ 1           ; card-detect bits absent
CFUERR_NOREADY  equ 2           ; card never signalled READY
CFUERR_NOMAP    equ 3           ; _MapPhysToLinear failed
CFUERR_BUFFER   equ 4           ; ioctl buffer missing/too small
CFUERR_NOTENAB  equ 5           ; operation needs a prior CFU_ENABLE
CFUERR_BADIOCTL equ 6

;----------------------------------------------------------------------------
DECLARE_VIRTUAL_DEVICE CFU1, 1, 0, CFU1_Control, UNDEFINED_DEVICE_ID, \
                       UNDEFINED_INIT_ORDER

VxD_LOCKED_DATA_SEG
iobase          dw      260h            ; SL811 addr port; data = +1
pcicidx         dw      3E0h
sockoff         db      0               ; socket * 40h
enabled         db      0
attrseg         dw      0D000h
                dw      0
attrlin         dd      0               ; mapped linear addr of attr window
irqhandle       dd      0
irqcount        dd      0
vid             VPICD_IRQ_Descriptor    <>
VxD_LOCKED_DATA_ENDS

VxD_LOCKED_CODE_SEG

;----------------------------------------------------------------------------
; helpers: PCIC index/data access.  in: AH=reg (bank offset added), AL=value
;----------------------------------------------------------------------------
BeginProc pcic_wr
        push    edx
        push    eax
        movzx   edx, [pcicidx]
        mov     al, ah
        add     al, [sockoff]
        out     dx, al
        pop     eax
        inc     edx
        out     dx, al                  ; data
        pop     edx
        ret
EndProc pcic_wr

BeginProc pcic_rd                       ; in: AH=reg  out: AL=value
        push    edx
        movzx   edx, [pcicidx]
        mov     al, ah
        add     al, [sockoff]
        out     dx, al
        inc     edx
        in      al, dx
        pop     edx
        ret
EndProc pcic_rd

BeginProc iodelay                       ; in: ECX = ~microseconds
@@:     in      al, 80h
        loop    @B
        ret
EndProc iodelay

;----------------------------------------------------------------------------
; control dispatch
;----------------------------------------------------------------------------
BeginProc CFU1_Control
        Control_Dispatch SYS_DYNAMIC_DEVICE_INIT, CFU1_Init
        Control_Dispatch SYS_DYNAMIC_DEVICE_EXIT, CFU1_Exit
        Control_Dispatch W32_DEVICEIOCONTROL,     CFU1_Ioctl
        clc
        ret
EndProc CFU1_Control

BeginProc CFU1_Init
        clc
        ret
EndProc CFU1_Init

BeginProc CFU1_Exit
        cmp     [irqhandle], 0
        jz      @F
        mov     eax, [irqhandle]
        VxDCall VPICD_Force_Default_Behavior
        mov     [irqhandle], 0
@@:     clc
        ret
EndProc CFU1_Exit

;----------------------------------------------------------------------------
; W32_DEVICEIOCONTROL:  ESI -> DIOCParams.  Return status in EAX (0 = ok).
;----------------------------------------------------------------------------
BeginProc CFU1_Ioctl
        mov     eax, [esi.dwIoControlCode]
        cmp     eax, DIOC_OPEN                  ; 0: CreateFile handshake
        jne     @F
        xor     eax, eax
        ret
@@:     cmp     eax, DIOC_CLOSEHANDLE           ; -1: cleanup on CloseHandle
        jne     @F
        call    ioc_unhook
        xor     eax, eax
        ret
@@:
        cmp     eax, CFU_GETVER
        je      ioc_getver
        cmp     eax, CFU_ENABLE
        je      ioc_enable
        cmp     eax, CFU_DISABLE
        je      ioc_disable
        cmp     eax, CFU_RDREG
        je      ioc_rdreg
        cmp     eax, CFU_WRREG
        je      ioc_wrreg
        cmp     eax, CFU_RDATTR
        je      ioc_rdattr
        cmp     eax, CFU_WRATTR
        je      ioc_wrattr
        cmp     eax, CFU_IRQHOOK
        je      ioc_irqhook
        cmp     eax, CFU_IRQCOUNT
        je      ioc_irqcount
        cmp     eax, CFU_IRQUNHOOK
        je      ioc_irqunhook2
        cmp     eax, CFU_PCICRD
        je      ioc_pcicrd
        cmp     eax, CFU_PCICWR
        je      ioc_pcicwr
        mov     eax, CFUERR_BADIOCTL
        ret
EndProc CFU1_Ioctl

; --- return dword in EAX through lpvOutBuffer, set bytes-returned = 4 -----
BeginProc ret_dword                     ; in: EAX=value  uses EDX
        mov     edx, [esi.lpvOutBuffer]
        test    edx, edx
        jz      @F
        cmp     [esi.cbOutBuffer], 4
        jb      @F
        mov     [edx], eax
        mov     edx, [esi.lpcbBytesReturned]
        test    edx, edx
        jz      @F
        mov     dword ptr [edx], 4
@@:     xor     eax, eax
        ret
EndProc ret_dword

ioc_getver:
        mov     eax, VXD_VERSION
        jmp     ret_dword

;----------------------------------------------------------------------------
; CFU_ENABLE
;----------------------------------------------------------------------------
ioc_enable:
        ; defaults already in globals; override from input buffer if present
        mov     edx, [esi.lpvInBuffer]
        test    edx, edx
        jz      ena_defaults
        cmp     [esi.cbInBuffer], CFU_SETUP_SIZE
        jb      ena_defaults
        mov     ax, [edx+CS_IOBASE]
        test    ax, ax
        jz      @F
        mov     [iobase], ax
@@:     mov     ax, [edx+CS_PCIC]
        test    ax, ax
        jz      @F
        mov     [pcicidx], ax
@@:     mov     al, [edx+CS_SOCKET]
        shl     al, 6                   ; * 40h
        mov     [sockoff], al
        mov     ax, [edx+CS_ATTRSEG]
        test    ax, ax
        jz      ena_defaults
        mov     [attrseg], ax
ena_defaults:

        ; card present?
        mov     ah, 01h
        call    pcic_rd
        and     al, 0Ch
        cmp     al, 0Ch
        je      @F
        mov     eax, CFUERR_NOCARD
        jmp     ena_fail
@@:
        ; power on 5V, deassert reset, wait READY
        mov     ah, 02h
        mov     al, 95h
        call    pcic_wr
        mov     ecx, 50000
        call    iodelay
        mov     ah, 03h
        mov     al, 40h
        call    pcic_wr
        mov     ecx, 20000
        call    iodelay
        mov     ecx, 100                ; up to ~100ms more
ena_rdywait:
        push    ecx
        mov     ah, 01h
        call    pcic_rd
        test    al, 20h
        pop     ecx
        jnz     ena_ready
        push    ecx
        mov     ecx, 1000
        call    iodelay
        pop     ecx
        loop    ena_rdywait
        mov     eax, CFUERR_NOREADY
        jmp     ena_fail
ena_ready:

        ; map the attribute window physical page so we can poke the COR
        movzx   eax, [attrseg]
        shl     eax, 4                  ; phys = seg << 4
        VMMCall _MapPhysToLinear, <eax, 1000h, 0>
        mov     [attrlin], eax
        cmp     eax, 0FFFFFFFFh
        jne     @F
        mov     eax, CFUERR_NOMAP
        jmp     ena_fail
@@:
        ; program attribute memory window 0 -> attrseg, card offset 0, REG
        movzx   ebx, [attrseg]
        shr     ebx, 8                  ; window start in 4K pages (e.g. 0D0h)
        mov     ah, 10h
        mov     al, bl
        call    pcic_wr                 ; start low
        mov     ah, 11h
        mov     al, bh
        and     al, 3Fh
        call    pcic_wr                 ; start high
        lea     ecx, [ebx+3]
        mov     ah, 12h
        mov     al, cl
        call    pcic_wr                 ; stop low
        mov     ah, 13h
        mov     al, ch
        and     al, 3Fh
        call    pcic_wr                 ; stop high
        mov     eax, 0
        sub     eax, ebx
        and     eax, 3FFFh
        or      eax, 4000h              ; REG = attribute space
        push    eax
        mov     ah, 14h
        call    pcic_wr                 ; offset low (AL already low byte)
        pop     eax
        mov     al, ah
        push    eax
        mov     ah, 15h
        call    pcic_wr                 ; offset high
        pop     eax
        mov     ah, 06h
        call    pcic_rd
        or      al, 01h
        mov     ah, 06h
        call    pcic_wr                 ; enable memory window 0
        mov     ecx, 2000
        call    iodelay

        ; *** the quirk: write the config index to attribute 0xFC ***
        ; (window offset 0x1F8; the CIS says 0xF8 and the CIS is wrong)
        mov     edx, [attrlin]
        mov     al, 02h                 ; default config index
        mov     [edx+1F8h], al
        mov     ecx, 2000
        call    iodelay
        mov     al, [edx+1F8h]          ; readback (expect index | 40h)
        push    eax                     ; save COR readback

        ; socket to I/O mode, map I/O window 0 over the SL811
        mov     ah, 03h
        mov     al, 60h
        call    pcic_wr
        mov     bx, [iobase]
        mov     ah, 08h
        mov     al, bl
        call    pcic_wr
        mov     ah, 09h
        mov     al, bh
        call    pcic_wr
        add     bx, 7
        mov     ah, 0Ah
        mov     al, bl
        call    pcic_wr
        mov     ah, 0Bh
        mov     al, bh
        call    pcic_wr
        mov     ah, 07h
        mov     al, 00h                 ; 8-bit timing
        call    pcic_wr
        mov     ah, 06h
        mov     al, 41h                 ; attr window + I/O window 0
        call    pcic_wr
        mov     ecx, 1000
        call    iodelay
        mov     [enabled], 1

        ; read SL811 hwrev (reg 0x0E)
        movzx   edx, [iobase]
        mov     al, 0Eh
        out     dx, al
        inc     edx
        in      al, dx
        mov     bl, al                  ; BL = hwrev
        mov     ah, 01h
        call    pcic_rd
        mov     bh, al                  ; BH = PCIC status
        pop     ecx                     ; CL = COR readback

        ; fill CFU_RESULT
        mov     edx, [esi.lpvOutBuffer]
        test    edx, edx
        jz      ena_oknobuf
        cmp     [esi.cbOutBuffer], CFU_RESULT_SIZE
        jb      ena_oknobuf
        mov     dword ptr [edx+CR_ERR], 0
        mov     [edx+CR_CORRB], cl
        mov     [edx+CR_HWREV], bl
        mov     [edx+CR_PCICSTAT], bh
        mov     byte ptr [edx+CR_RSVD], 0
        mov     edx, [esi.lpcbBytesReturned]
        test    edx, edx
        jz      ena_oknobuf
        mov     dword ptr [edx], CFU_RESULT_SIZE
ena_oknobuf:
        xor     eax, eax
        ret

ena_fail:                               ; EAX = CFUERR_*
        mov     edx, [esi.lpvOutBuffer]
        test    edx, edx
        jz      @F
        cmp     [esi.cbOutBuffer], CFU_RESULT_SIZE
        jb      @F
        mov     [edx+CR_ERR], eax
        mov     edx, [esi.lpcbBytesReturned]
        test    edx, edx
        jz      @F
        mov     dword ptr [edx], CFU_RESULT_SIZE
@@:     xor     eax, eax                ; ioctl itself succeeded; err in struct
        ret

;----------------------------------------------------------------------------
ioc_disable:
        call    ioc_unhook
        mov     ah, 06h
        mov     al, 00h
        call    pcic_wr
        mov     ah, 03h
        mov     al, 00h
        call    pcic_wr
        mov     ah, 02h
        mov     al, 00h
        call    pcic_wr
        mov     [enabled], 0
        xor     eax, eax
        ret

;----------------------------------------------------------------------------
ioc_rdreg:
        cmp     [enabled], 0
        je      ioc_notena
        mov     edx, [esi.lpvInBuffer]
        test    edx, edx
        jz      ioc_badbuf
        mov     al, [edx]               ; reg
        movzx   edx, [iobase]
        out     dx, al
        inc     edx
        in      al, dx
        movzx   eax, al
        jmp     ret_dword

ioc_wrreg:
        cmp     [enabled], 0
        je      ioc_notena
        mov     edx, [esi.lpvInBuffer]
        test    edx, edx
        jz      ioc_badbuf
        cmp     [esi.cbInBuffer], 2
        jb      ioc_badbuf
        mov     ax, [edx]               ; AL=reg AH=val
        movzx   edx, [iobase]
        out     dx, al
        inc     edx
        mov     al, ah
        out     dx, al
        xor     eax, eax
        ret

ioc_rdattr:
        cmp     [enabled], 0
        je      ioc_notena
        mov     edx, [esi.lpvInBuffer]
        test    edx, edx
        jz      ioc_badbuf
        movzx   eax, word ptr [edx]     ; offset within window
        and     eax, 0FFFh
        mov     edx, [attrlin]
        movzx   eax, byte ptr [edx+eax]
        jmp     ret_dword

ioc_wrattr:
        cmp     [enabled], 0
        je      ioc_notena
        mov     edx, [esi.lpvInBuffer]
        test    edx, edx
        jz      ioc_badbuf
        cmp     [esi.cbInBuffer], 3
        jb      ioc_badbuf
        movzx   eax, word ptr [edx]
        and     eax, 0FFFh
        mov     cl, [edx+2]
        mov     edx, [attrlin]
        mov     [edx+eax], cl
        xor     eax, eax
        ret

ioc_pcicrd:
        mov     edx, [esi.lpvInBuffer]
        test    edx, edx
        jz      ioc_badbuf
        mov     ah, [edx]               ; PCIC register
        call    pcic_rd
        movzx   eax, al
        jmp     ret_dword

ioc_pcicwr:
        mov     edx, [esi.lpvInBuffer]
        test    edx, edx
        jz      ioc_badbuf
        cmp     [esi.cbInBuffer], 2
        jb      ioc_badbuf
        mov     ax, [edx]               ; AL=reg AH=val
        xchg    al, ah
        call    pcic_wr
        xor     eax, eax
        ret

ioc_notena:
        mov     eax, CFUERR_NOTENAB
        ret
ioc_badbuf:
        mov     eax, CFUERR_BUFFER
        ret

;----------------------------------------------------------------------------
; IRQ: virtualize, steer the PCIC, count SOF/any SL811 interrupts
;----------------------------------------------------------------------------
ioc_irqhook:
        cmp     [enabled], 0
        je      ioc_notena
        cmp     [irqhandle], 0
        jnz     ioc_badbuf              ; already hooked
        mov     edx, [esi.lpvInBuffer]
        test    edx, edx
        jz      ioc_badbuf
        movzx   ecx, byte ptr [edx]     ; irq number

        mov     [vid.VID_IRQ_Number], cx
        mov     [vid.VID_Options], 0
        mov     [vid.VID_Hw_Int_Proc], OFFSET32 CFU1_HwInt
        mov     [vid.VID_Virt_Int_Proc], 0
        mov     [vid.VID_EOI_Proc], 0
        mov     [vid.VID_Mask_Change_Proc], 0
        mov     [vid.VID_IRET_Proc], 0
        mov     [vid.VID_IRET_Time_Out], 500
        push    ecx
        mov     edi, OFFSET32 vid
        VxDCall VPICD_Virtualize_IRQ
        pop     ecx
        jc      ioc_badbuf
        mov     [irqhandle], eax
        mov     [irqcount], 0

        ; steer the card IRQ at the PCIC (keep I/O mode + reset deasserted)
        mov     al, cl
        and     al, 0Fh
        or      al, 60h
        mov     ah, 03h
        call    pcic_wr

        mov     eax, [irqhandle]
        VxDCall VPICD_Physically_Unmask
        xor     eax, eax
        ret

ioc_irqcount:
        mov     eax, [irqcount]
        jmp     ret_dword

ioc_irqunhook2:
        call    ioc_unhook
        xor     eax, eax
        ret

BeginProc ioc_unhook
        cmp     [irqhandle], 0
        jz      @F
        mov     eax, [irqhandle]
        VxDCall VPICD_Force_Default_Behavior
        mov     [irqhandle], 0
@@:     ret
EndProc ioc_unhook

;----------------------------------------------------------------------------
; hardware interrupt handler: ack the SL811, count, EOI
;----------------------------------------------------------------------------
BeginProc CFU1_HwInt, High_Freq
        push    edx
        movzx   edx, [iobase]
        mov     al, 0Dh                 ; SL811 interrupt status
        out     dx, al
        inc     edx
        mov     al, 0FFh
        out     dx, al                  ; ack everything
        inc     [irqcount]
        pop     edx
        mov     eax, [irqhandle]        ; Phys_EOI wants the IRQ handle
        VxDCall VPICD_Phys_EOI
        clc
        ret
EndProc CFU1_HwInt

VxD_LOCKED_CODE_ENDS
        end
