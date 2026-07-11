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
        include configmg.inc

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
CFU_GETCONF     equ 100Ch       ; out: CFU_CONF (PnP-assigned resources)
CFU_USBINIT     equ 100Dh       ; in: BYTE lowspeed   out: DWORD INTSTAT
CFU_XACT        equ 100Eh       ; in: CFU_XREQ        out: CFU_XRSP
CFU_CTRL        equ 100Fh       ; in: CFU_CREQ        out: CFU_CRSP

VXD_VERSION     equ 00010200h   ; 1.20 - ring-0 USB transfer engine

; CFU_XREQ offsets (one raw transaction on EP A)
XQ_PIDEP        equ 0           ; BYTE  PID<<4 | endpoint
XQ_DEVADDR      equ 1           ; BYTE
XQ_CTL          equ 2           ; BYTE  EP A host control bits
XQ_LEN          equ 3           ; BYTE  transfer length (<= 120)
XQ_DATA         equ 4           ; BYTE[len] for OUT/SETUP payloads
; CFU_XRSP offsets
XR_STATUS       equ 0           ; DWORD SL811 packet status (FFFFFFFF timeout)
XR_GOT          equ 4           ; DWORD bytes received (IN)
XR_DATA         equ 8           ; BYTE[got]

; CFU_CREQ offsets (complete control transfer)
CQ_DEVADDR      equ 0           ; BYTE
CQ_MPS          equ 1           ; BYTE  max packet size of ep0 (8..64)
CQ_WLEN         equ 2           ; WORD  data stage length
CQ_SETUP        equ 4           ; BYTE[8] the SETUP packet
CFU_CREQ_SIZE   equ 12
; CFU_CRSP offsets
CR2_ERR         equ 0           ; DWORD 0 ok; low byte stage 1/2/3,
                                ;       byte1 = SL811 status (FF timeout)
CR2_GOT         equ 4           ; DWORD data-stage bytes transferred
CR2_DATA        equ 8           ; BYTE[wlen] for IN transfers
CFU_CRSP_HDR    equ 8

; CFU_CONF output structure offsets
CC_IOBASE       equ 0           ; WORD  Windows-assigned I/O base (0 = none)
CC_IRQ          equ 2           ; BYTE  Windows-assigned IRQ (FF = none)
CC_SOCKET       equ 3           ; BYTE  socket the card was found in (FF=?)
CC_FLAGS        equ 4           ; BYTE  bit0 devnode seen, bit1 started,
                                ;       bit2 COR fix applied
CC_CORRB        equ 5           ; BYTE  COR readback at CONFIG_START
CC_RSVD         equ 6           ; WORD
CFU_CONF_SIZE   equ 8

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

; PnP state (filled by the CONFIGMG path)
pnp_devnode     dd      0
pnp_iobase      dw      0
pnp_irq         db      0FFh
pnp_socket      db      0FFh
pnp_flags       db      0               ; bit0 devnode, bit1 started, bit2 COR
pnp_corrb       db      0
                dw      0
savregs         db      8 dup (0)       ; cor_fix PCIC reg save area
xa_pidep        db      0               ; do_xact arguments
xa_addr         db      0
xa_ctl          db      0
xa_len          db      0
ct_toggle       db      0               ; control-transfer data toggle
                db      3 dup (0)
cmconfig        Config_Buff_s <>
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
        Control_Dispatch PNP_NEW_DEVNODE,         CFU1_NewDevnode
        clc
        ret
EndProc CFU1_Control

;----------------------------------------------------------------------------
; PNP_NEW_DEVNODE: EBX = devnode, EDX = load type.  Register our config
; handler so CONFIGMG tells us when the card's resources are assigned.
;----------------------------------------------------------------------------
BeginProc CFU1_NewDevnode
        cmp     edx, DLVXD_LOAD_DEVLOADER
        je      @F
        cmp     edx, DLVXD_LOAD_DRIVER
        jne     nd_ok                   ; not for us; report success anyway
@@:
        mov     [pnp_devnode], ebx
        or      [pnp_flags], 1
        VxDCall _CONFIGMG_Register_Device_Driver, <ebx, <OFFSET32 CFU1_ConfigHandler>, 0, <CM_REGISTER_DEVICE_DRIVER_DISABLEABLE OR CM_REGISTER_DEVICE_DRIVER_REMOVABLE>>
        ; EAX = CR_* result; pass it back
        clc
        ret
nd_ok:
        mov     eax, CR_SUCCESS
        clc
        ret
EndProc CFU1_NewDevnode

;----------------------------------------------------------------------------
; CONFIGMG config handler (C convention):
;   CONFIGRET handler(func, subfunc, devnode, refdata, flags)
;   [ebp+8]=func [ebp+12]=subfunc [ebp+16]=devnode [ebp+20]=ref [ebp+24]=flags
;----------------------------------------------------------------------------
BeginProc CFU1_ConfigHandler
        push    ebp
        mov     ebp, esp
        push    ebx
        push    esi
        push    edi

        mov     eax, [ebp+8]
        cmp     eax, CONFIG_START
        je      ch_start
        cmp     eax, CONFIG_STOP
        je      ch_stop
        cmp     eax, CONFIG_REMOVE
        je      ch_stop
        mov     eax, CR_DEFAULT
        jmp     ch_done

ch_start:
        ; fetch the resources Windows assigned to the card
        mov     ebx, [ebp+16]           ; devnode
        VxDCall _CONFIGMG_Get_Alloc_Log_Conf, <<OFFSET32 cmconfig>, ebx, CM_GET_ALLOC_LOG_CONF_ALLOC>
        test    eax, eax                ; CR_SUCCESS = 0
        jnz     ch_start_noconf
        cmp     [cmconfig.wNumIOPorts], 0
        je      @F
        mov     ax, word ptr [cmconfig.wIOPortBase]
        mov     [pnp_iobase], ax
        mov     [iobase], ax            ; adopt as the active I/O base
@@:     cmp     [cmconfig.wNumIRQs], 0
        je      @F
        mov     al, byte ptr [cmconfig.bIRQRegisters]
        mov     [pnp_irq], al
@@:
ch_start_noconf:
        or      [pnp_flags], 2          ; started
        call    cor_fix                 ; the reason this driver exists
        mov     eax, CR_SUCCESS
        jmp     ch_done

ch_stop:
        and     [pnp_flags], NOT 2
        mov     eax, CR_SUCCESS

ch_done:
        pop     edi
        pop     esi
        pop     ebx
        pop     ebp
        ret
EndProc CFU1_ConfigHandler

;----------------------------------------------------------------------------
; cor_fix: find which socket carries an enabled I/O window covering our
; assigned iobase, then briefly borrow memory window 0 on that socket to
; write the REAL configuration register at attribute 0xFC (the CIS lies
; and says 0xF8, so the OS-written COR never landed).  PCIC window regs
; are saved and restored around the poke.
;----------------------------------------------------------------------------
BeginProc cor_fix
        push    ebx
        push    ecx
        push    edx
        push    esi

        ; --- find the socket: banks 0..3 ---
        xor     ecx, ecx
cf_scan:
        mov     al, cl
        shl     al, 6
        mov     [sockoff], al
        mov     ah, 01h
        call    pcic_rd
        and     al, 0Ch
        cmp     al, 0Ch                 ; card present?
        jne     cf_next
        mov     ah, 06h
        call    pcic_rd
        test    al, 40h                 ; I/O window 0 enabled?
        jz      cf_next
        mov     ah, 08h
        call    pcic_rd
        mov     bl, al
        mov     ah, 09h
        call    pcic_rd
        mov     bh, al                  ; BX = window start
        mov     dx, [pnp_iobase]
        test    dx, dx
        jnz     @F
        mov     dx, [iobase]
@@:     cmp     bx, dx
        jne     cf_next
        jmp     cf_found
cf_next:
        inc     ecx
        cmp     ecx, 4
        jb      cf_scan
        jmp     cf_out                  ; no socket found; leave flags unset

cf_found:
        mov     al, cl
        mov     [pnp_socket], al

        ; --- save PCIC regs 06,10-15 into savregs ---
        mov     ah, 06h
        call    pcic_rd
        mov     [savregs+0], al
        mov     ah, 10h
cf_save:
        call    pcic_rd
        movzx   ebx, ah
        mov     [savregs+ebx-0Fh], al   ; 10h -> +1 ... 15h -> +6
        inc     ah
        cmp     ah, 16h
        jb      cf_save

        ; --- map attribute window at attrseg, poke COR, restore ---
        movzx   ebx, [attrseg]
        shr     ebx, 8
        mov     ah, 10h
        mov     al, bl
        call    pcic_wr
        mov     ah, 11h
        mov     al, bh
        and     al, 3Fh
        call    pcic_wr
        lea     ecx, [ebx+3]
        mov     ah, 12h
        mov     al, cl
        call    pcic_wr
        mov     ah, 13h
        mov     al, ch
        and     al, 3Fh
        call    pcic_wr
        mov     eax, 0
        sub     eax, ebx
        and     eax, 3FFFh
        or      eax, 4000h
        push    eax
        mov     ah, 14h
        call    pcic_wr
        pop     eax
        mov     al, ah
        mov     ah, 15h
        call    pcic_wr
        mov     ah, 06h
        call    pcic_rd
        or      al, 01h
        mov     ah, 06h
        call    pcic_wr
        mov     ecx, 2000
        call    iodelay

        movzx   eax, [attrseg]
        shl     eax, 4
        VMMCall _MapPhysToLinear, <eax, 1000h, 0>
        cmp     eax, 0FFFFFFFFh
        je      cf_restore
        mov     [attrlin], eax
        mov     edx, eax
        mov     byte ptr [edx+1F8h], 42h    ; REAL COR: attr 0xFC
        mov     ecx, 2000
        call    iodelay
        mov     al, [edx+1F8h]
        mov     [pnp_corrb], al
        cmp     al, 42h
        jne     cf_restore
        or      [pnp_flags], 4          ; COR fix confirmed
        mov     [enabled], 1

cf_restore:
        ; --- restore PCIC regs 10-15 then 06 ---
        mov     ah, 10h
cf_rest:
        movzx   ebx, ah
        mov     al, [savregs+ebx-0Fh]
        call    pcic_wr
        inc     ah
        cmp     ah, 16h
        jb      cf_rest
        mov     ah, 06h
        mov     al, [savregs+0]
        call    pcic_wr

cf_out:
        pop     esi
        pop     edx
        pop     ecx
        pop     ebx
        ret
EndProc cor_fix

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
        cmp     eax, CFU_GETCONF
        je      ioc_getconf
        cmp     eax, CFU_USBINIT
        je      ioc_usbinit
        cmp     eax, CFU_XACT
        je      ioc_xact
        cmp     eax, CFU_CTRL
        je      ioc_ctrl
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

ioc_getconf:
        mov     edx, [esi.lpvOutBuffer]
        test    edx, edx
        jz      ioc_badbuf
        cmp     [esi.cbOutBuffer], CFU_CONF_SIZE
        jb      ioc_badbuf
        mov     ax, [pnp_iobase]
        mov     [edx+CC_IOBASE], ax
        mov     al, [pnp_irq]
        mov     [edx+CC_IRQ], al
        mov     al, [pnp_socket]
        mov     [edx+CC_SOCKET], al
        mov     al, [pnp_flags]
        mov     [edx+CC_FLAGS], al
        mov     al, [pnp_corrb]
        mov     [edx+CC_CORRB], al
        mov     word ptr [edx+CC_RSVD], 0
        mov     edx, [esi.lpcbBytesReturned]
        test    edx, edx
        jz      @F
        mov     dword ptr [edx], CFU_CONF_SIZE
@@:     xor     eax, eax
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

;----------------------------------------------------------------------------
; CFU_USBINIT: bus reset (SE0 ~30ms) -> host mode (DSWAP+LSPD if lowspeed)
; -> SOF counters + kickstart -> INTENA SOF-timer gate.  Returns INTSTAT.
;----------------------------------------------------------------------------
ioc_usbinit:
        cmp     [enabled], 0
        je      ioc_notena
        mov     edx, [esi.lpvInBuffer]
        xor     ecx, ecx                ; CL = lowspeed flag
        test    edx, edx
        jz      @F
        mov     cl, [edx]
@@:
        mov     al, 06h                 ; INTENA off
        mov     ah, 00h
        call    sl_wr
        mov     al, 05h                 ; CTL1: force SE0 (USB reset)
        mov     ah, 08h
        call    sl_wr
        push    ecx
        mov     ecx, 30000              ; ~30ms
        call    iodelay
        pop     ecx
        mov     al, 05h
        mov     ah, 00h
        call    sl_wr
        push    ecx
        mov     ecx, 3000
        call    iodelay
        pop     ecx
        mov     al, 0Eh                 ; SOF counter low
        mov     ah, 0E0h
        call    sl_wr
        mov     ah, 0AEh                ; CTL2: HOST | SOF-high
        test    cl, cl
        jz      @F
        or      ah, 40h                 ; + DSWAP for low speed
@@:     mov     al, 0Fh
        call    sl_wr
        mov     al, 02h                 ; SOF kickstart: EP A len 0
        mov     ah, 00h
        call    sl_wr
        mov     al, 03h                 ; PID=SOF ep0
        mov     ah, 50h
        call    sl_wr
        mov     al, 04h
        mov     ah, 00h
        call    sl_wr
        mov     al, 00h                 ; ARM
        mov     ah, 01h
        call    sl_wr
        mov     ah, 01h                 ; CTL1: SOF_ENA (+LSPD if LS)
        test    cl, cl
        jz      @F
        or      ah, 20h
@@:     mov     al, 05h
        call    sl_wr
        mov     al, 0Dh
        mov     ah, 0FFh
        call    sl_wr
        mov     al, 06h                 ; INTENA bit4 gates the SOF timer
        mov     ah, 10h
        call    sl_wr
        mov     ecx, 100000             ; ~100ms post-reset recovery
        call    iodelay
        mov     al, 0Dh
        call    sl_rd
        movzx   eax, al
        jmp     ret_dword

;----------------------------------------------------------------------------
; CFU_XACT: one raw transaction.  Payload (OUT/SETUP) copied to chip RAM
; 0x10 first; IN data copied back to the response.
;----------------------------------------------------------------------------
ioc_xact:
        cmp     [enabled], 0
        je      ioc_notena
        mov     edx, [esi.lpvInBuffer]
        test    edx, edx
        jz      ioc_badbuf
        cmp     [esi.cbInBuffer], 4
        jb      ioc_badbuf
        mov     al, [edx+XQ_PIDEP]
        mov     [xa_pidep], al
        mov     al, [edx+XQ_DEVADDR]
        mov     [xa_addr], al
        mov     al, [edx+XQ_CTL]
        mov     [xa_ctl], al
        mov     al, [edx+XQ_LEN]
        mov     [xa_len], al
        ; copy any outbound payload into chip RAM
        push    esi                     ; preserve DIOCParams ptr
        test    byte ptr [xa_ctl], 04h
        jz      @F
        movzx   ecx, [xa_len]
        jecxz   @F
        lea     esi, [edx+XQ_DATA]
        mov     al, 10h
        call    buf_to_chip
@@:
        call    do_xact
        pop     esi
        jnc     @F
        mov     eax, 0FFFFFFFFh         ; timeout marker
        jmp     xact_status
@@:     movzx   eax, al
xact_status:
        mov     edx, [esi.lpvOutBuffer]
        test    edx, edx
        jz      ioc_badbuf
        cmp     [esi.cbOutBuffer], XR_DATA + 120
        jb      ioc_badbuf
        mov     [edx+XR_STATUS], eax
        mov     dword ptr [edx+XR_GOT], 0
        ; IN transaction that ACKed: pull the data back
        cmp     eax, 0FFFFFFFFh
        je      xact_ret
        test    al, 01h                 ; ACK?
        jz      xact_ret
        test    byte ptr [xa_ctl], 04h  ; only for IN
        jnz     xact_ret
        push    eax
        mov     al, 04h                 ; remaining count
        call    sl_rd
        mov     cl, [xa_len]
        sub     cl, al                  ; got = len - remaining
        movzx   ecx, cl
        mov     [edx+XR_GOT], ecx
        jecxz   xact_pop
        push    edi
        lea     edi, [edx+XR_DATA]
        mov     al, 10h
        call    buf_from_chip
        pop     edi
xact_pop:
        pop     eax
xact_ret:
        mov     edx, [esi.lpcbBytesReturned]
        test    edx, edx
        jz      @F
        mov     dword ptr [edx], XR_DATA + 120
@@:     xor     eax, eax
        ret

;----------------------------------------------------------------------------
; CFU_CTRL: complete control transfer with NAK retry and data toggles.
;----------------------------------------------------------------------------
ioc_ctrl:
        cmp     [enabled], 0
        je      ioc_notena
        push    ebx
        push    edi
        mov     edx, [esi.lpvInBuffer]
        test    edx, edx
        jz      ctrl_badbuf
        cmp     [esi.cbInBuffer], CFU_CREQ_SIZE
        jb      ctrl_badbuf
        mov     edi, [esi.lpvOutBuffer]
        test    edi, edi
        jz      ctrl_badbuf
        mov     eax, [esi.cbOutBuffer]
        sub     eax, CFU_CRSP_HDR
        jb      ctrl_badbuf
        movzx   ecx, word ptr [edx+CQ_WLEN]
        cmp     eax, ecx                ; room for the whole data stage?
        jb      ctrl_badbuf
        mov     dword ptr [edi+CR2_ERR], 0
        mov     dword ptr [edi+CR2_GOT], 0

        mov     al, [edx+CQ_DEVADDR]
        mov     [xa_addr], al

        ; ---- SETUP stage: 8 bytes, DATA0, OUT ----
        push    esi
        push    edx
        lea     esi, [edx+CQ_SETUP]
        mov     al, 10h
        mov     ecx, 8
        call    buf_to_chip
        pop     edx
        pop     esi
        mov     [xa_pidep], 0D0h
        mov     [xa_len], 8
        mov     [xa_ctl], 07h           ; ARM|ENABLE|OUT, DATA0
        call    do_xact_retry
        jc      ctrl_setup_tmo
        test    al, 01h
        jnz     ctrl_data
ctrl_setup_tmo:
        mov     ah, al
        jnc     @F
        mov     ah, 0FFh
@@:     mov     al, 1                   ; stage 1 failed
        jmp     ctrl_fail

        ; ---- DATA stage (IN only; OUT data stage not needed yet) ----
ctrl_data:
        movzx   ebx, word ptr [edx+CQ_WLEN]
        test    ebx, ebx
        jz      ctrl_status
        test    byte ptr [edx+CQ_SETUP], 80h
        jz      ctrl_status
        mov     [ct_toggle], 40h        ; DATA1 first
ctrl_data_loop:
        mov     al, [edx+CQ_MPS]        ; always request a full packet;
        mov     [xa_len], al            ; the device short-terminates
        mov     [xa_pidep], 90h         ; IN, ep 0
        mov     al, [ct_toggle]
        or      al, 03h                 ; ARM|ENABLE
        mov     [xa_ctl], al
        call    do_xact_retry
        jc      ctrl_data_tmo
        test    al, 01h                 ; ACK?
        jz      ctrl_data_bad
        mov     al, 04h                 ; remaining count
        call    sl_rd
        mov     ah, [xa_len]
        sub     ah, al
        movzx   ecx, ah                 ; ECX = got this chunk
        push    esi
        push    edi
        push    ecx
        mov     eax, [edi+CR2_GOT]
        lea     edi, [edi+CR2_DATA+eax]
        mov     al, 10h
        call    buf_from_chip
        pop     ecx
        pop     edi
        pop     esi
        add     [edi+CR2_GOT], ecx
        xor     [ct_toggle], 40h
        cmp     ecx, ebx
        jae     ctrl_data_done          ; got everything requested
        sub     ebx, ecx
        movzx   eax, byte ptr [edx+CQ_MPS]
        cmp     ecx, eax
        jb      ctrl_data_done          ; short packet = device done early
        jmp     ctrl_data_loop
ctrl_data_tmo:
        mov     ah, 0FFh
        mov     al, 2
        jmp     ctrl_fail
ctrl_data_bad:
        mov     ah, al
        mov     al, 2
        jmp     ctrl_fail
ctrl_data_done:

        ; ---- STATUS stage: opposite direction, DATA1, zero length ----
ctrl_status:
        mov     [xa_len], 0
        test    byte ptr [edx+CQ_SETUP], 80h
        jz      ctrl_status_in
        mov     [xa_pidep], 10h         ; OUT status after IN data
        mov     [xa_ctl], 47h           ; ARM|ENABLE|OUT|DATA1
        jmp     @F
ctrl_status_in:
        mov     [xa_pidep], 90h         ; IN status after OUT/no data
        mov     [xa_ctl], 43h           ; ARM|ENABLE|DATA1
@@:     call    do_xact_retry
        jc      ctrl_status_tmo
        test    al, 01h
        jnz     ctrl_ok
        mov     ah, al
        mov     al, 3
        jmp     ctrl_fail
ctrl_status_tmo:
        mov     ah, 0FFh
        mov     al, 3
        jmp     ctrl_fail

ctrl_ok:
        xor     eax, eax
        jmp     ctrl_out
ctrl_fail:
        movzx   eax, ax                 ; AL=stage AH=status
        mov     [edi+CR2_ERR], eax
        xor     eax, eax
ctrl_out:
        mov     edx, [esi.lpcbBytesReturned]
        test    edx, edx
        jz      @F
        mov     ecx, [edi+CR2_GOT]
        add     ecx, CFU_CRSP_HDR
        mov     [edx], ecx
@@:     pop     edi
        pop     ebx
        xor     eax, eax
        ret
ctrl_badbuf:
        pop     edi
        pop     ebx
        mov     eax, CFUERR_BUFFER
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
; ring-0 USB transfer engine.
; SL811 access at native port speed: address port = iobase, data = iobase+1.
;----------------------------------------------------------------------------
BeginProc sl_rd                         ; in: AL=reg  out: AL=val
        push    edx
        movzx   edx, [iobase]
        out     dx, al
        inc     edx
        in      al, dx
        pop     edx
        ret
EndProc sl_rd

BeginProc sl_wr                         ; in: AL=reg AH=val
        push    edx
        movzx   edx, [iobase]
        out     dx, al
        inc     edx
        mov     al, ah
        out     dx, al
        pop     edx
        ret
EndProc sl_wr

BeginProc buf_to_chip                   ; ESI=src, AL=chip addr, ECX=count
        push    edx
        movzx   edx, [iobase]
        out     dx, al                  ; set address (autoincrement follows)
        inc     edx
        jecxz   btc_done
btc_loop:
        lodsb
        out     dx, al
        loop    btc_loop
btc_done:
        pop     edx
        ret
EndProc buf_to_chip

BeginProc buf_from_chip                 ; EDI=dst, AL=chip addr, ECX=count
        push    edx
        movzx   edx, [iobase]
        out     dx, al
        inc     edx
        jecxz   bfc_done
bfc_loop:
        in      al, dx
        stosb
        loop    bfc_loop
bfc_done:
        pop     edx
        ret
EndProc buf_from_chip

;----------------------------------------------------------------------------
; do_xact: run one transaction on EP A using xa_* globals; the payload must
; already be in chip RAM at 0x10.  Returns AL = SL811 packet status, or
; carry set on completion timeout (~50ms).
;----------------------------------------------------------------------------
BeginProc do_xact
        push    ecx
        mov     al, 01h                 ; EP A buffer address
        mov     ah, 10h
        call    sl_wr
        mov     al, 02h                 ; EP A buffer length
        mov     ah, [xa_len]
        call    sl_wr
        mov     al, 03h                 ; PID | endpoint
        mov     ah, [xa_pidep]
        call    sl_wr
        mov     al, 04h                 ; device address
        mov     ah, [xa_addr]
        call    sl_wr
        mov     al, 0Dh                 ; clear interrupt status
        mov     ah, 0FFh
        call    sl_wr
        mov     al, 00h                 ; EP A host control: go
        mov     ah, [xa_ctl]
        call    sl_wr
        mov     ecx, 50000              ; ~50ms completion budget
dx_poll:
        mov     al, 0Dh
        call    sl_rd
        test    al, 01h                 ; DONE_A
        jnz     dx_done
        in      al, 80h                 ; ~1us
        loop    dx_poll
        pop     ecx
        stc
        ret
dx_done:
        mov     al, 03h                 ; packet status
        call    sl_rd
        pop     ecx
        clc
        ret
EndProc do_xact

;----------------------------------------------------------------------------
; do_xact_retry: do_xact, retrying while the device NAKs (busy), up to
; ~250 attempts with ~1ms spacing.  Same returns as do_xact.
;----------------------------------------------------------------------------
BeginProc do_xact_retry
        push    ebx
        push    ecx
        mov     ebx, 250
dxr_try:
        call    do_xact
        jc      dxr_out                 ; timeout
        test    al, 40h                 ; NAK?
        jz      dxr_out
        mov     ecx, 1000               ; ~1ms then retry
dxr_dly:
        push    eax
        in      al, 80h
        pop     eax
        loop    dxr_dly
        dec     ebx
        jnz     dxr_try
        clc                             ; give up: return the NAK status
dxr_out:
        pop     ecx
        pop     ebx
        ret
EndProc do_xact_retry

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
