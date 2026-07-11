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
        include vmd.inc
        include vkd.inc

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
CFU_HIDSTART    equ 1010h       ; in: BYTE ep,devaddr,mps,interval_ms
                                ;     [,BYTE mode: bit0 = post to VMOUSE]
CFU_HIDSTOP     equ 1011h
CFU_HIDREAD     equ 1012h       ; out: DWORD count + count*9 (len+8 data)
CFU_AUTOMOUSE   equ 1013h       ; in: BYTE 1=on/0=off  (hot-plug supervisor)
CFU_AUTOSTAT    equ 1014h       ; out: DWORD (b0 run, b1 armed, b8-15 state)
CFU_FORCEKEY    equ 1015h       ; in: raw scan bytes -> VKD_Force_Keys (test)
CFU_KBDSTART    equ 1016h       ; in: BYTE ep,devaddr,mps,interval_ms
CFU_KBDSTAT     equ 1017h       ; out: 6 DWORDs (pipeline counters, debug)
CFU_MSCSET      equ 1018h       ; in: BYTE addr, ep_in, ep_out (reset toggles)
CFU_MSCCMD      equ 1019h       ; in: BYTE cdblen,dir; WORD datalen; 16 cdb;
                                ;     [OUT data]  out: DWORD csw; [IN data]

VXD_VERSION     equ 00010701h   ; 1.71 - ring-0 mass storage (ESI-save fix)

HIDRING_SLOTS   equ 32
HIDSLOT_SIZE    equ 9

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
xbusy           db      0               ; EP A ownership guard (timer skips)
                db      2 dup (0)
xa_budget       dd      50000           ; do_xact completion poll budget
xr_tries        dd      250             ; do_xact_retry NAK budget

; do_control (internal control transfer) parameters/results
ct_addr         db      0
ct_mps          db      8
                dw      0
ct_wlen         dd      0               ; wanted IN data length (<= mps here)
ct_got          dd      0
ct_setup        db      8 dup (0)
ct_buf          db      16 dup (0)

; hot-plug supervisor state
sup_handle      dd      0
sup_run         db      0               ; auto-mouse enabled
sup_armed       db      0               ; poll currently armed by supervisor
sup_absent      db      0               ; consecutive "no device" ticks
sup_state       db      0               ; enumeration state machine
sup_mps         db      8
                dw      0

; HID poll loop state
hid_handle      dd      0               ; Set_Global_Time_Out handle (in ESI!)
hid_ep          db      0
hid_addr        db      0
hid_mps         db      0
hid_ivl         db      10
hid_tog         db      0
hid_run         db      0               ; 1 = keep polling (gate reschedule)
hid_mode        db      0               ; bit0 = post reports to VMOUSE
                db      1 dup (0)
hid_head        dd      0
hid_tail        dd      0
hidring         db      HIDRING_SLOTS*HIDSLOT_SIZE dup (0)
; HID boot buttons (b0=L b1=R b2=M) -> VMOUSE serial format (20h/10h/08h)
btntab          db      000h, 020h, 010h, 030h, 008h, 028h, 018h, 038h

;----------------------------------------------------------------------------
; keyboard state (mode bit1)
;----------------------------------------------------------------------------
kb_prev         db      8 dup (0)       ; previous boot-keyboard report
kb_held         db      0               ; HID usage of the repeating key
kb_ticks        dd      0               ; ticks the key has been held
; scan-code queue: tick (interrupt time) enqueues, a Schedule_Global_Event
; callback drains it at task time (VKD_Force_Keys is not IRQ-time safe).
kb_sbuf         db      128 dup (0)
kb_sh           dd      0               ; producer index (free-running)
kb_st           dd      0               ; consumer index
kb_sched        db      0               ; a drain event is pending
                db      3 dup (0)
kb_batch        db      128 dup (0)     ; contiguous drain buffer for VKD
; debug counters (CFU_KBDSTAT)
kb_dbg_reports  dd      0               ; keyboard reports processed
kb_dbg_enq      dd      0               ; scan bytes enqueued
kb_dbg_sched    dd      0               ; drain events scheduled
kb_dbg_drains   dd      0               ; drain callbacks fired
kb_dbg_forced   dd      0               ; scan bytes handed to VKD_Force_Keys

KB_DELAY        equ     60              ; typematic delay in ticks (~480ms)
KB_RATE         equ     4               ; repeat interval in ticks (~32ms)

; HID usage (keyboard page 07) -> PC scan code set 1.  Word entries:
; low byte = make code, bit 15 set = E0-prefixed, 0 = unmapped.
E0K             equ     8000h
kscan   dw      0, 0, 0, 0                              ; 00-03
        dw      1Eh,30h,2Eh,20h,12h,21h,22h,23h         ; 04-0B a-h
        dw      17h,24h,25h,26h,32h,31h,18h,19h         ; 0C-13 i-p
        dw      10h,13h,1Fh,14h,16h,2Fh,11h,2Dh         ; 14-1B q-x
        dw      15h,2Ch                                 ; 1C-1D y,z
        dw      02h,03h,04h,05h,06h,07h,08h,09h,0Ah,0Bh ; 1E-27 1-0
        dw      1Ch,01h,0Eh,0Fh,39h                     ; 28-2C enter esc bs tab spc
        dw      0Ch,0Dh,1Ah,1Bh,2Bh,2Bh                 ; 2D-32 - = [ ] \ #
        dw      27h,28h,29h,33h,34h,35h,3Ah             ; 33-39 ; ' ` , . / caps
        dw      3Bh,3Ch,3Dh,3Eh,3Fh,40h,41h,42h         ; 3A-41 F1-F8
        dw      43h,44h,57h,58h                         ; 42-45 F9-F12
        dw      37h+E0K,46h,0                           ; 46-48 prtsc scrlk pause(skip)
        dw      52h+E0K,47h+E0K,49h+E0K                 ; 49-4B ins home pgup
        dw      53h+E0K,4Fh+E0K,51h+E0K                 ; 4C-4E del end pgdn
        dw      4Dh+E0K,4Bh+E0K,50h+E0K,48h+E0K         ; 4F-52 right left down up
        dw      45h,35h+E0K,37h,4Ah,4Eh,1Ch+E0K         ; 53-58 numlk kp/ kp* kp- kp+ kpent
        dw      4Fh,50h,51h,4Bh,4Ch,4Dh,47h,48h,49h     ; 59-61 kp1-kp9
        dw      52h,53h,56h                             ; 62-64 kp0 kp. intl\
KSCAN_MAX equ   ($ - kscan) / 2

; HID modifier bits 0-7 -> scan codes (LCtrl LShift LAlt LGui RCtrl RShift RAlt RGui)
kmod    dw      1Dh, 2Ah, 38h, 5Bh+E0K, 1Dh+E0K, 36h, 38h+E0K, 5Ch+E0K
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
        cmp     [enabled], 0            ; if the card came up, watch for a mouse
        jz      @F
        call    sup_start
@@:     mov     eax, CR_SUCCESS
        jmp     ch_done

ch_stop:
        and     [pnp_flags], NOT 2
        call    sup_stop
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
        call    sup_stop
        call    hid_stop
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
        cmp     [hid_mode], 0           ; any persistent feed (mouse OR
        jne     close_keep              ; keyboard) survives app exit
        call    hid_stop
close_keep:
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
        cmp     eax, CFU_HIDSTART
        je      ioc_hidstart
        cmp     eax, CFU_HIDSTOP
        je      ioc_hidstop
        cmp     eax, CFU_HIDREAD
        je      ioc_hidread
        cmp     eax, CFU_AUTOMOUSE
        je      ioc_automouse
        cmp     eax, CFU_AUTOSTAT
        je      ioc_autostat
        cmp     eax, CFU_FORCEKEY
        je      ioc_forcekey
        cmp     eax, CFU_KBDSTART
        je      ioc_kbdstart
        cmp     eax, CFU_KBDSTAT
        je      ioc_kbdstat
        cmp     eax, CFU_MSCSET
        je      ioc_mscset
        cmp     eax, CFU_MSCCMD
        je      ioc_msccmd
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
        call    sup_stop                ; manual USB test takes over from auto
        call    hid_stop                ; a bus reset invalidates the poll
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
        mov     [xbusy], 1              ; keep the HID timer off EP A
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
        mov     [xbusy], 0
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
        mov     [xr_tries], 250         ; generous NAK budget for ring-3 path
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
        mov     [xbusy], 1              ; keep the HID timer off EP A

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
        mov     [xbusy], 0
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

;----------------------------------------------------------------------------
; HID poll loop control
;----------------------------------------------------------------------------
ioc_hidstart:
        cmp     [enabled], 0
        je      ioc_notena
        call    sup_stop                ; manual poll replaces the supervisor
        cmp     [hid_handle], 0
        jnz     ioc_badbuf              ; already running
        mov     edx, [esi.lpvInBuffer]
        test    edx, edx
        jz      ioc_badbuf
        cmp     [esi.cbInBuffer], 4
        jb      ioc_badbuf
        mov     al, [edx]
        mov     [hid_ep], al
        mov     al, [edx+1]
        mov     [hid_addr], al
        mov     al, [edx+2]
        mov     [hid_mps], al
        mov     al, [edx+3]
        test    al, al
        jnz     @F
        mov     al, 10                  ; default 10ms
@@:     mov     [hid_ivl], al
        mov     [hid_mode], 0
        cmp     [esi.cbInBuffer], 5     ; optional 5th byte: mode
        jb      @F
        mov     al, [edx+4]
        mov     [hid_mode], al
@@:     call    hid_arm
        xor     eax, eax
        ret

; hid_arm: start the poll loop from the hid_* globals (ep/addr/mps/ivl/mode)
BeginProc hid_arm
        mov     [hid_tog], 0
        mov     [hid_head], 0
        mov     [hid_tail], 0
        mov     [hid_run], 1
        push    esi
        movzx   eax, [hid_ivl]
        xor     edx, edx
        mov     esi, OFFSET32 CFU1_HidTick
        VMMCall Set_Global_Time_Out
        mov     [hid_handle], esi       ; handle returned in ESI
        pop     esi
        ret
EndProc hid_arm

ioc_hidstop:
        call    hid_stop
        xor     eax, eax
        ret

BeginProc hid_stop
        mov     [hid_run], 0            ; stray in-flight tick won't re-arm
        mov     [hid_mode], 0
        cmp     [hid_handle], 0
        jz      @F
        push    esi
        mov     esi, [hid_handle]       ; Cancel_Time_Out takes ESI
        mov     [hid_handle], 0
        VMMCall Cancel_Time_Out
        pop     esi
@@:     ret
EndProc hid_stop

ioc_hidread:
        mov     edx, [esi.lpvOutBuffer]
        test    edx, edx
        jz      ioc_badbuf
        cmp     [esi.cbOutBuffer], 4 + HIDRING_SLOTS*HIDSLOT_SIZE
        jb      ioc_badbuf
        push    ebx
        push    edi
        mov     edi, edx
        add     edi, 4                  ; reports start after the count
        xor     ebx, ebx                ; EBX = report count
        mov     ecx, [hid_head]         ; snapshot: timer only advances head
hr_loop:
        mov     eax, [hid_tail]
        cmp     eax, ecx
        je      hr_done
        push    ecx
        push    esi
        lea     esi, [eax+eax*8]
        add     esi, OFFSET32 hidring
        mov     ecx, HIDSLOT_SIZE
        rep     movsb                   ; copy len byte + 8 data bytes
        pop     esi
        pop     ecx
        inc     eax
        and     eax, HIDRING_SLOTS-1
        mov     [hid_tail], eax
        inc     ebx
        jmp     hr_loop
hr_done:
        mov     [edx], ebx              ; count
        mov     eax, [esi.lpcbBytesReturned]
        test    eax, eax
        jz      @F
        lea     ecx, [ebx+ebx*8]
        add     ecx, 4
        mov     [eax], ecx
@@:     pop     edi
        pop     ebx
        xor     eax, eax
        ret

ioc_automouse:
        mov     edx, [esi.lpvInBuffer]
        test    edx, edx
        jz      ioc_badbuf
        cmp     byte ptr [edx], 0
        jz      am_off
        cmp     [enabled], 0
        je      ioc_notena
        call    sup_start
        xor     eax, eax
        ret
am_off:
        call    sup_stop
        xor     eax, eax
        ret

ioc_autostat:
        movzx   eax, [sup_state]
        shl     eax, 8
        mov     al, 0
        cmp     [sup_run], 0
        jz      @F
        or      al, 1
@@:     cmp     [sup_armed], 0
        jz      @F
        or      al, 2
@@:     jmp     ret_dword

; CFU_FORCEKEY: bulk-inject the raw scan-code buffer via VKD_Force_Keys
; (VKD self-test: ESI = buffer, ECX = count).
ioc_forcekey:
        call    sup_stop                ; keep the cursor still during the test
        mov     ecx, [esi.lpvInBuffer]
        test    ecx, ecx
        jz      ioc_badbuf
        mov     eax, [esi.cbInBuffer]
        test    eax, eax
        jz      fk_done
        push    esi
        push    edi
        mov     esi, ecx                ; ESI = scan-code buffer
        mov     ecx, eax                ; ECX = count
        VxDCall  VKD_Force_Keys
        pop     edi
        pop     esi
fk_done:
        xor     eax, eax
        ret

; CFU_KBDSTART: arm the poll loop in keyboard mode (hid_mode bit1)
ioc_kbdstart:
        cmp     [enabled], 0
        je      ioc_notena
        call    sup_stop
        cmp     [hid_handle], 0
        jnz     ioc_badbuf
        mov     edx, [esi.lpvInBuffer]
        test    edx, edx
        jz      ioc_badbuf
        cmp     [esi.cbInBuffer], 4
        jb      ioc_badbuf
        mov     al, [edx]
        mov     [hid_ep], al
        mov     al, [edx+1]
        mov     [hid_addr], al
        mov     al, [edx+2]
        mov     [hid_mps], al
        mov     al, [edx+3]
        test    al, al
        jnz     @F
        mov     al, 8
@@:     mov     [hid_ivl], al
        mov     [hid_mode], 2           ; keyboard
        ; reset keyboard diff + scan-code queue state
        xor     eax, eax
        mov     dword ptr [kb_prev], eax
        mov     dword ptr [kb_prev+4], eax
        mov     [kb_held], al
        mov     [kb_ticks], eax
        mov     [kb_sh], eax
        mov     [kb_st], eax
        mov     [kb_sched], al
        call    hid_arm
        xor     eax, eax
        ret

; CFU_KBDSTAT: dump the keyboard pipeline counters for diagnosis
ioc_kbdstat:
        mov     edx, [esi.lpvOutBuffer]
        test    edx, edx
        jz      ioc_badbuf
        cmp     [esi.cbOutBuffer], 24
        jb      ioc_badbuf
        mov     eax, [kb_dbg_reports]
        mov     [edx+0], eax
        mov     eax, [kb_dbg_enq]
        mov     [edx+4], eax
        mov     eax, [kb_dbg_sched]
        mov     [edx+8], eax
        mov     eax, [kb_dbg_drains]
        mov     [edx+12], eax
        mov     eax, [kb_dbg_forced]
        mov     [edx+16], eax
        movzx   eax, [hid_mode]
        mov     [edx+20], eax
        mov     eax, [esi.lpcbBytesReturned]
        test    eax, eax
        jz      @F
        mov     dword ptr [eax], 24
@@:     xor     eax, eax
        ret

; CFU_MSCSET: set the mass-storage device address + bulk endpoints,
; reset data toggles (call after the ring-3 tool does SET_CONFIGURATION)
ioc_mscset:
        mov     edx, [esi.lpvInBuffer]
        test    edx, edx
        jz      ioc_badbuf
        cmp     [esi.cbInBuffer], 3
        jb      ioc_badbuf
        mov     al, [edx+0]
        mov     [msc_addr], al
        mov     al, [edx+1]
        mov     [msc_epin], al
        mov     al, [edx+2]
        mov     [msc_epout], al
        mov     byte ptr [msc_togin], 0
        mov     byte ptr [msc_togout], 0
        mov     dword ptr [msc_tag], 1
        xor     eax, eax
        ret

; CFU_MSCCMD: run one BOT command.  in: [0]=cdblen [1]=dir [2:2]=datalen
; [4:16]=cdb, then OUT data.  out: [0:4]=CSW status (FFFFFFFF=fail), IN data.
ioc_msccmd:
        cmp     [enabled], 0
        je      ioc_notena
        mov     edx, [esi.lpvInBuffer]
        test    edx, edx
        jz      ioc_badbuf
        cmp     [esi.cbInBuffer], 20
        jb      ioc_badbuf
        mov     [xbusy], 1
        mov     al, [edx+0]
        mov     [msc_cdblen], al
        mov     al, [edx+1]
        mov     [msc_dir], al
        movzx   eax, word ptr [edx+2]
        mov     [msc_datalen], eax
        push    esi
        push    edi
        cld
        lea     esi, [edx+4]
        mov     edi, OFFSET32 msc_cdb
        mov     ecx, 16
        rep     movsb
        pop     edi
        pop     esi
        cmp     byte ptr [msc_dir], 0
        jne     mcc_in
        mov     edx, [esi.lpvInBuffer]  ; OUT data follows the 20-byte header
        add     edx, 20
        mov     [msc_databuf], edx
        jmp     mcc_go
mcc_in:
        mov     edx, [esi.lpvOutBuffer] ; IN data lands after the 4-byte CSW
        test    edx, edx
        jz      mcc_bad
        add     edx, 4
        mov     [msc_databuf], edx
mcc_go:
        push    esi                     ; msc_bot trashes ESI (DIOCParams ptr)
        call    msc_bot
        mov     [xbusy], 0
        pop     esi
        jc      mcc_failw
        movzx   eax, al                 ; CSW status
        mov     edx, [esi.lpvOutBuffer]
        test    edx, edx
        jz      mcc_len
        mov     [edx], eax
        jmp     mcc_len
mcc_failw:
        mov     edx, [esi.lpvOutBuffer]
        test    edx, edx
        jz      mcc_len
        mov     dword ptr [edx], 0FFFFFFFFh
mcc_len:
        mov     ecx, [esi.lpcbBytesReturned]
        test    ecx, ecx
        jz      mcc_done
        mov     eax, [msc_datalen]
        add     eax, 4
        mov     [ecx], eax
mcc_done:
        xor     eax, eax
        ret
mcc_bad:
        mov     [xbusy], 0
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
        mov     ecx, [xa_budget]        ; completion budget (~us)
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
        mov     ebx, [xr_tries]
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
; do_control: internal control transfer used by the auto-mouse supervisor.
; Params in globals: ct_setup[8], ct_addr, ct_mps, ct_wlen (single IN packet,
; <= mps; enumeration never needs more).  IN data -> ct_buf, count -> ct_got.
; Returns CF clear on success, CF set on any stage failure.  Caller sets
; xr_tries to bound the event-time stall.
;----------------------------------------------------------------------------
BeginProc do_control
        mov     [xbusy], 1
        mov     al, [ct_addr]
        mov     [xa_addr], al
        mov     dword ptr [ct_got], 0

        ; SETUP: 8 bytes, DATA0, OUT
        push    esi
        mov     esi, OFFSET32 ct_setup
        mov     al, 10h
        mov     ecx, 8
        call    buf_to_chip
        pop     esi
        mov     [xa_pidep], 0D0h
        mov     [xa_len], 8
        mov     [xa_ctl], 07h
        call    do_xact_retry
        jc      dc_fail
        test    al, 01h
        jz      dc_fail

        ; DATA (IN only, single packet)
        mov     ecx, [ct_wlen]
        jecxz   dc_status
        test    byte ptr [ct_setup], 80h
        jz      dc_status
        mov     al, [ct_mps]
        mov     [xa_len], al
        mov     [xa_pidep], 90h         ; IN ep0
        mov     [xa_ctl], 43h           ; ARM|ENABLE|DATA1
        call    do_xact_retry
        jc      dc_fail
        test    al, 01h
        jz      dc_fail
        mov     al, 04h                 ; remaining
        call    sl_rd
        mov     ah, [xa_len]
        sub     ah, al
        movzx   ecx, ah                 ; ECX = got
        mov     [ct_got], ecx
        push    edi
        mov     edi, OFFSET32 ct_buf
        mov     al, 10h
        call    buf_from_chip
        pop     edi

dc_status:
        mov     [xa_len], 0
        test    byte ptr [ct_setup], 80h
        jz      dc_status_in
        mov     [xa_pidep], 10h         ; OUT status after IN data
        mov     [xa_ctl], 47h           ; ARM|ENABLE|OUT|DATA1
        jmp     dc_st_go
dc_status_in:
        mov     [xa_pidep], 90h         ; IN status after no data
        mov     [xa_ctl], 43h           ; ARM|ENABLE|DATA1
dc_st_go:
        call    do_xact_retry
        jc      dc_fail
        test    al, 01h
        jz      dc_fail
        mov     [xbusy], 0
        clc
        ret
dc_fail:
        mov     [xbusy], 0
        stc
        ret
EndProc do_control

;----------------------------------------------------------------------------
; ring-0 mass storage: Bulk-Only Transport + SCSI (Stage 1 of drive-letter).
; msc_bot runs one BOT command using the msc_* globals; the caller fills in
; msc_cdb/cdblen/dir/datalen/databuf and sets msc_addr/epin/epout first.
;----------------------------------------------------------------------------
VxD_LOCKED_DATA_SEG
msc_addr        db      1
msc_epin        db      81h
msc_epout       db      2
msc_togin       db      0
msc_togout      db      0
msc_cdblen      db      0
msc_dir         db      0               ; 1 = data IN, 0 = OUT/none
                db      1 dup (0)
msc_tag         dd      1
msc_datalen     dd      0
msc_databuf     dd      0               ; linear address of data buffer
msc_cdb         db      16 dup (0)
msc_cbw         db      31 dup (0)
msc_csw         db      16 dup (0)
VxD_LOCKED_DATA_ENDS

; msc_bulk_out: ESI = linear src, ECX = length.  CF set on failure.
BeginProc msc_bulk_out
        cld
        mov     [xr_tries], 500
mbo_l:
        test    ecx, ecx
        jz      mbo_ok
        mov     ebx, ecx
        cmp     ebx, 64
        jbe     @F
        mov     ebx, 64
@@:     push    ecx
        push    esi
        mov     ecx, ebx
        mov     al, 10h
        call    buf_to_chip
        pop     esi
        pop     ecx
        mov     al, [msc_epout]
        and     al, 0Fh
        or      al, 10h                 ; OUT PID
        mov     [xa_pidep], al
        mov     al, [msc_addr]
        mov     [xa_addr], al
        mov     al, bl
        mov     [xa_len], al
        mov     al, 07h                 ; ARM|ENABLE|OUT
        test    byte ptr [msc_togout], 1
        jz      @F
        or      al, 40h
@@:     mov     [xa_ctl], al
        call    do_xact_retry
        jc      mbo_err
        test    al, 01h
        jz      mbo_err
        xor     byte ptr [msc_togout], 1
        add     esi, ebx
        sub     ecx, ebx
        jmp     mbo_l
mbo_ok: clc
        ret
mbo_err:
        stc
        ret
EndProc msc_bulk_out

; msc_bulk_in: EDI = linear dst, ECX = length.  Stops on a short packet.
; CF set on failure.
BeginProc msc_bulk_in
        cld
        mov     [xr_tries], 500
mbi_l:
        test    ecx, ecx
        jz      mbi_ok
        mov     ebx, ecx
        cmp     ebx, 64
        jbe     @F
        mov     ebx, 64
@@:     mov     al, [msc_epin]
        and     al, 0Fh
        or      al, 90h                 ; IN PID
        mov     [xa_pidep], al
        mov     al, [msc_addr]
        mov     [xa_addr], al
        mov     al, bl
        mov     [xa_len], al
        mov     al, 03h                 ; ARM|ENABLE
        test    byte ptr [msc_togin], 1
        jz      @F
        or      al, 40h
@@:     mov     [xa_ctl], al
        call    do_xact_retry
        jc      mbi_err
        test    al, 01h
        jz      mbi_err
        xor     byte ptr [msc_togin], 1
        mov     al, 04h                 ; SL811 remaining-count register
        call    sl_rd
        mov     ah, bl                  ; AH = requested chunk
        sub     ah, al                  ; AH = got = requested - remaining
        movzx   edx, ah
        push    ecx
        mov     ecx, edx
        mov     al, 10h
        call    buf_from_chip           ; EDI += got
        pop     ecx
        sub     ecx, edx                ; remaining -= got
        cmp     edx, 64
        jb      mbi_ok                  ; short packet ends the transfer
        jmp     mbi_l
mbi_ok: clc
        ret
mbi_err:
        stc
        ret
EndProc msc_bulk_in

; msc_bot: one Bulk-Only Transport command.  AL = CSW status (0 = good) on
; success; CF set on transport failure.
BeginProc msc_bot
        cld
        mov     byte ptr [msc_cbw+0], 'U'
        mov     byte ptr [msc_cbw+1], 'S'
        mov     byte ptr [msc_cbw+2], 'B'
        mov     byte ptr [msc_cbw+3], 'C'
        mov     eax, [msc_tag]
        mov     dword ptr [msc_cbw+4], eax
        inc     dword ptr [msc_tag]
        mov     eax, [msc_datalen]
        mov     dword ptr [msc_cbw+8], eax
        mov     al, [msc_dir]
        test    al, al
        jz      @F
        mov     al, 80h
@@:     mov     [msc_cbw+12], al
        mov     byte ptr [msc_cbw+13], 0
        mov     al, [msc_cdblen]
        mov     [msc_cbw+14], al
        push    esi
        push    edi
        mov     esi, OFFSET32 msc_cdb
        mov     edi, OFFSET32 msc_cbw
        add     edi, 15
        mov     ecx, 16
        rep     movsb
        pop     edi
        pop     esi

        mov     esi, OFFSET32 msc_cbw   ; CBW out
        mov     ecx, 31
        call    msc_bulk_out
        jc      mbt_fail

        mov     ecx, [msc_datalen]      ; data phase
        test    ecx, ecx
        jz      mbt_csw
        cmp     byte ptr [msc_dir], 0
        je      mbt_dout
        mov     edi, [msc_databuf]
        mov     ecx, [msc_datalen]
        call    msc_bulk_in
        jmp     mbt_csw
mbt_dout:
        mov     esi, [msc_databuf]
        mov     ecx, [msc_datalen]
        call    msc_bulk_out

mbt_csw:
        mov     edi, OFFSET32 msc_csw   ; CSW in
        mov     ecx, 13
        call    msc_bulk_in
        jc      mbt_fail
        cmp     byte ptr [msc_csw+0], 'U'
        jne     mbt_fail
        cmp     byte ptr [msc_csw+3], 'S'
        jne     mbt_fail
        mov     al, [msc_csw+12]
        clc
        ret
mbt_fail:
        stc
        ret
EndProc msc_bot

;----------------------------------------------------------------------------
; setup_pkt: fill ct_setup with AL=bmRequestType AH=bRequest BX=wValue
;            CX=wIndex DX=wLength
;----------------------------------------------------------------------------
BeginProc setup_pkt
        mov     [ct_setup+0], al
        mov     [ct_setup+1], ah
        mov     [ct_setup+2], bl
        mov     [ct_setup+3], bh
        mov     [ct_setup+4], cl
        mov     [ct_setup+5], ch
        mov     [ct_setup+6], dl
        mov     [ct_setup+7], dh
        ret
EndProc setup_pkt

;----------------------------------------------------------------------------
; dev_present: quick attach check with the host idle.  AL=1 if attached.
;----------------------------------------------------------------------------
BeginProc dev_present
        mov     al, 05h                 ; CTL1 = 0 (normal, no force)
        mov     ah, 00h
        call    sl_wr
        mov     al, 0Dh                 ; clear INTSTAT
        mov     ah, 0FFh
        call    sl_wr
        push    ecx
        mov     ecx, 5000               ; ~5ms settle
        call    iodelay
        pop     ecx
        mov     al, 0Dh
        call    sl_rd
        test    al, 40h                 ; bit6 = 1 -> NO device
        jnz     dp_no
        mov     al, 1
        ret
dp_no:  xor     al, al
        ret
EndProc dev_present

;----------------------------------------------------------------------------
; hot-plug supervisor: a self-rescheduling 250ms timer that enumerates a
; boot mouse one short control transfer per tick (bounded event-time stall)
; and arms the VMOUSE poll.  States: 0 idle, 1 reset-release, 2 getdesc,
; 3 setaddr, 4 setconfig, 5 setproto+arm, 9 running.
;----------------------------------------------------------------------------
BeginProc CFU1_SupTick, High_Freq
        cmp     [sup_run], 0
        jz      sup_out                 ; disabled: don't re-arm

        mov     eax, 250                ; reschedule
        xor     edx, edx
        mov     esi, OFFSET32 CFU1_SupTick
        VMMCall Set_Global_Time_Out
        mov     [sup_handle], esi

        cmp     [enabled], 0
        jz      sup_out
        cmp     [xbusy], 0              ; a real transfer owns EP A: wait
        jnz     sup_out
        mov     [xr_tries], 10          ; tight NAK budget at event time

        movzx   eax, [sup_state]
        cmp     eax, 9
        je      sup_running
        cmp     eax, 0
        je      sup_idle
        cmp     eax, 1
        je      sup_reset
        cmp     eax, 2
        je      sup_getdesc
        cmp     eax, 3
        je      sup_setaddr
        cmp     eax, 4
        je      sup_setcfg
        cmp     eax, 5
        je      sup_setproto
        mov     [sup_state], 0
        jmp     sup_out

sup_idle:
        call    dev_present
        test    al, al
        jz      sup_out
        mov     al, 05h                 ; assert SE0 (start USB reset)
        mov     ah, 08h
        call    sl_wr
        mov     [sup_state], 1          ; hold SE0 until next tick (~250ms)
        jmp     sup_out

sup_reset:
        mov     al, 05h                 ; release SE0
        mov     ah, 00h
        call    sl_wr
        mov     al, 0Eh                 ; SOF counter low
        mov     ah, 0E0h
        call    sl_wr
        mov     al, 0Fh                 ; CTL2: HOST | SOF-high (full speed)
        mov     ah, 0AEh
        call    sl_wr
        mov     al, 02h                 ; SOF kickstart: EP A len 0
        mov     ah, 00h
        call    sl_wr
        mov     al, 03h
        mov     ah, 50h                 ; PID=SOF ep0
        call    sl_wr
        mov     al, 04h
        mov     ah, 00h
        call    sl_wr
        mov     al, 00h                 ; ARM
        mov     ah, 01h
        call    sl_wr
        mov     al, 05h                 ; CTL1: SOF_ENA
        mov     ah, 01h
        call    sl_wr
        mov     al, 0Dh
        mov     ah, 0FFh
        call    sl_wr
        mov     al, 06h                 ; INTENA bit4 gates SOF timer
        mov     ah, 10h
        call    sl_wr
        mov     ecx, 15000              ; ~15ms recovery (rest via next tick)
        call    iodelay
        mov     [sup_state], 2
        jmp     sup_out

sup_getdesc:
        mov     al, 80h                 ; GET_DESCRIPTOR(device,8) @ addr 0
        mov     ah, 06h
        mov     bx, 0100h               ; wValue = device desc, index 0
        xor     cx, cx
        mov     dx, 8
        call    setup_pkt
        mov     [ct_addr], 0
        mov     [ct_mps], 8
        mov     dword ptr [ct_wlen], 8
        call    do_control
        jc      sup_reidle
        cmp     dword ptr [ct_got], 8
        jb      sup_reidle
        mov     al, [ct_buf+7]          ; bMaxPacketSize0
        test    al, al
        jnz     @F
        mov     al, 8
@@:     mov     [sup_mps], al
        mov     [sup_state], 3
        jmp     sup_out

sup_setaddr:
        mov     al, 00h                 ; SET_ADDRESS 1 @ addr 0
        mov     ah, 05h
        mov     bx, 1
        xor     cx, cx
        xor     dx, dx
        call    setup_pkt
        mov     [ct_addr], 0
        mov     al, [sup_mps]
        mov     [ct_mps], al
        mov     dword ptr [ct_wlen], 0
        call    do_control
        jc      sup_reidle
        mov     [sup_state], 4
        jmp     sup_out

sup_setcfg:
        mov     al, 00h                 ; SET_CONFIGURATION 1 @ addr 1
        mov     ah, 09h
        mov     bx, 1
        xor     cx, cx
        xor     dx, dx
        call    setup_pkt
        mov     [ct_addr], 1
        mov     al, [sup_mps]
        mov     [ct_mps], al
        mov     dword ptr [ct_wlen], 0
        call    do_control
        jc      sup_reidle
        mov     [sup_state], 5
        jmp     sup_out

sup_setproto:
        mov     al, 21h                 ; SET_PROTOCOL(boot) @ addr 1, iface 0
        mov     ah, 0Bh
        xor     bx, bx                  ; wValue = 0 (boot)
        xor     cx, cx
        xor     dx, dx
        call    setup_pkt
        mov     [ct_addr], 1
        mov     al, [sup_mps]
        mov     [ct_mps], al
        mov     dword ptr [ct_wlen], 0
        call    do_control              ; ignore result (some mice STALL it)
        ; arm the VMOUSE poll: ep1, addr1, mps8 (boot report), 8ms
        mov     [hid_ep], 1
        mov     [hid_addr], 1
        mov     [hid_mps], 8
        mov     [hid_ivl], 8
        mov     [hid_mode], 1           ; post to VMOUSE
        call    hid_arm
        mov     [sup_armed], 1
        mov     [sup_absent], 0
        mov     [sup_state], 9
        jmp     sup_out

sup_running:
        mov     al, 0Dh                 ; live presence (SOF running)
        call    sl_rd
        test    al, 40h                 ; bit6 = no device
        jz      sup_still
        inc     [sup_absent]
        cmp     [sup_absent], 3
        jb      sup_out
        call    hid_stop
        mov     [sup_armed], 0
        mov     [sup_absent], 0
        mov     [sup_state], 0
        jmp     sup_out
sup_still:
        mov     [sup_absent], 0
        jmp     sup_out

sup_reidle:                             ; enumeration step failed: retry later
        mov     [sup_state], 0
sup_out:
        ret
EndProc CFU1_SupTick

; sup_start: begin the supervisor if not already running (ESI-safe)
BeginProc sup_start
        cmp     [sup_run], 0
        jnz     ss_done
        mov     [sup_run], 1
        mov     [sup_armed], 0
        mov     [sup_absent], 0
        mov     [sup_state], 0
        push    esi
        mov     eax, 250
        xor     edx, edx
        mov     esi, OFFSET32 CFU1_SupTick
        VMMCall Set_Global_Time_Out
        mov     [sup_handle], esi
        pop     esi
ss_done:
        ret
EndProc sup_start

BeginProc sup_stop
        mov     [sup_run], 0
        cmp     [sup_handle], 0
        jz      @F
        push    esi
        mov     esi, [sup_handle]
        mov     [sup_handle], 0
        VMMCall Cancel_Time_Out
        pop     esi
@@:     cmp     [sup_armed], 0
        jz      @F
        call    hid_stop
        mov     [sup_armed], 0
@@:     ret
EndProc sup_stop

;----------------------------------------------------------------------------
; HID poll timer: reschedules itself, then runs one interrupt-IN
; transaction; ACKed data goes into the ring buffer.
; Callback convention: EBX=VM, ECX=ms late, EDX=refdata.
;----------------------------------------------------------------------------
BeginProc CFU1_HidTick, High_Freq
        cmp     [hid_run], 0
        jz      ht_out                  ; stop requested: don't re-arm

        movzx   eax, [hid_ivl]          ; reschedule first: steady cadence
        xor     edx, edx
        mov     esi, OFFSET32 CFU1_HidTick
        VMMCall Set_Global_Time_Out
        mov     [hid_handle], esi       ; handle comes back in ESI

        cmp     [xbusy], 0              ; someone mid-transaction? skip tick
        jnz     ht_out
        mov     [xbusy], 1

        mov     al, [hid_ep]
        and     al, 0Fh
        or      al, 90h                 ; IN | endpoint
        mov     [xa_pidep], al
        mov     al, [hid_addr]
        mov     [xa_addr], al
        mov     al, [hid_mps]
        mov     [xa_len], al
        mov     al, [hid_tog]
        or      al, 03h                 ; ARM|ENABLE
        mov     [xa_ctl], al
        mov     [xa_budget], 3000       ; short budget at event time
        call    do_xact
        mov     [xa_budget], 50000
        jc      ht_noreport             ; timeout: no new report this tick
        test    al, 01h                 ; ACK?
        jz      ht_noreport             ; NAK/error: no data this tick
        xor     [hid_tog], 40h
        mov     al, 04h                 ; remaining
        call    sl_rd
        mov     ah, [hid_mps]
        sub     ah, al
        movzx   ecx, ah                 ; ECX = got
        test    ecx, ecx
        jz      ht_done
        cmp     ecx, 8
        jbe     @F
        mov     ecx, 8                  ; slot payload cap
@@:
        ; store into ring slot at head
        mov     eax, [hid_head]
        lea     edx, [eax+eax*8]        ; head * 9
        add     edx, OFFSET32 hidring
        mov     [edx], cl               ; slot: len byte first
        push    edi
        lea     edi, [edx+1]
        mov     al, 10h
        call    buf_from_chip
        pop     edi

        ; dispatch the report by mode
        test    [hid_mode], 2           ; keyboard?
        jz      ht_trymouse
        push    edx
        lea     esi, [edx+1]            ; report bytes
        call    hid_kbd_report
        call    kb_flush                ; schedule task-time injection
        pop     edx
        jmp     ht_nopost
ht_trymouse:
        ; ring-0 pointer: hand a boot-protocol report straight to VMOUSE
        test    [hid_mode], 1
        jz      ht_nopost
        cmp     byte ptr [edx], 3       ; need buttons+dx+dy at least
        jb      ht_nopost
        push    ebx
        push    esi
        push    edi
        push    edx
        movzx   ebx, byte ptr [edx+1]   ; HID buttons
        and     ebx, 7
        mov     al, [btntab+ebx]        ; AL = VMOUSE button format
        movsx   esi, byte ptr [edx+2]   ; ESI = delta X
        movsx   edi, byte ptr [edx+3]   ; EDI = delta Y
        VxDCall VMD_Post_Pointer_Message
        pop     edx
        pop     edi
        pop     esi
        pop     ebx
ht_nopost:
        mov     eax, [hid_head]
        inc     eax
        and     eax, HIDRING_SLOTS-1
        mov     [hid_head], eax
        cmp     eax, [hid_tail]         ; full? drop oldest
        jne     ht_done
        mov     eax, [hid_tail]
        inc     eax
        and     eax, HIDRING_SLOTS-1
        mov     [hid_tail], eax
ht_done:
        mov     [xbusy], 0
ht_out:
        ret

ht_noreport:                            ; NAK/timeout: no fresh report
        test    [hid_mode], 2           ; keyboard typematic repeat
        jz      ht_done
        call    hid_kbd_idle
        call    kb_flush
        jmp     ht_done
EndProc CFU1_HidTick

;----------------------------------------------------------------------------
; keyboard: HID boot report -> scan codes -> VKD_Force_Keys.
; Helpers preserve EBX/ECX/EDX/ESI/EDI so caller loops stay intact.
;----------------------------------------------------------------------------
; kb_force: enqueue one raw scan byte (AL) for task-time injection.
; The tick runs at interrupt time where VKD_Force_Keys is unsafe, so we
; queue here and drain from a Schedule_Global_Event callback (kb_drain).
BeginProc kb_force
        push    eax
        push    ebx
        push    edx
        mov     ebx, [kb_sh]
        mov     edx, ebx
        and     edx, 127
        mov     [kb_sbuf + edx], al
        inc     ebx
        mov     [kb_sh], ebx
        inc     dword ptr [kb_dbg_enq]
        pop     edx
        pop     ebx
        pop     eax
        ret
EndProc kb_force

; kb_flush: schedule a task-time drain if scan codes are queued
BeginProc kb_flush
        mov     eax, [kb_sh]
        cmp     eax, [kb_st]
        je      kf_done                 ; nothing queued
        cmp     [kb_sched], 0
        jne     kf_done                 ; drain already scheduled
        mov     [kb_sched], 1
        inc     dword ptr [kb_dbg_sched]
        push    esi
        push    edx
        xor     edx, edx
        mov     esi, OFFSET32 kb_drain
        VMMCall Schedule_Global_Event
        pop     edx
        pop     esi
kf_done:
        ret
EndProc kb_flush

; kb_drain: task-time global-event callback; batch-inject the queue via VKD
BeginProc kb_drain
        push    ebx
        push    ecx
        push    edx
        push    esi
        push    edi
        inc     dword ptr [kb_dbg_drains]
        xor     edx, edx                ; batch length
kd_loop:
        mov     eax, [kb_st]
        cmp     eax, [kb_sh]
        je      kd_send
        and     eax, 127
        mov     cl, [kb_sbuf + eax]
        mov     [kb_batch + edx], cl
        inc     edx
        inc     dword ptr [kb_st]
        cmp     edx, 120
        jb      kd_loop
kd_send:
        test    edx, edx
        jz      kd_done
        add     [kb_dbg_forced], edx
        mov     esi, OFFSET32 kb_batch
        mov     ecx, edx
        VxDCall  VKD_Force_Keys
kd_done:
        mov     [kb_sched], 0
        pop     edi
        pop     esi
        pop     edx
        pop     ecx
        pop     ebx
        ret
EndProc kb_drain

; kb_key: emit a HID keyboard usage (AL) as make (AH=0) or break (AH=80h)
BeginProc kb_key
        push    ebx
        push    edx
        movzx   ebx, al
        cmp     ebx, KSCAN_MAX
        jae     kk_done
        movzx   edx, word ptr [kscan + ebx*2]
        test    dx, dx
        jz      kk_done                 ; unmapped usage
        test    dh, 80h                 ; E0-prefixed?
        jz      @F
        push    eax
        mov     al, 0E0h
        call    kb_force
        pop     eax
@@:     mov     al, dl                  ; make code
        or      al, ah                  ; |80h for break
        call    kb_force
kk_done:
        pop     edx
        pop     ebx
        ret
EndProc kb_key

; kb_mod: emit a modifier (AL = bit index 0-7) make (AH=0) / break (AH=80h)
BeginProc kb_mod
        push    ebx
        push    edx
        movzx   ebx, al
        movzx   edx, word ptr [kmod + ebx*2]
        test    dh, 80h
        jz      @F
        push    eax
        mov     al, 0E0h
        call    kb_force
        pop     eax
@@:     mov     al, dl
        or      al, ah
        call    kb_force
        pop     edx
        pop     ebx
        ret
EndProc kb_mod

; kb_contains: is keycode AL present in the 6 keycodes at [EDI]?  ZF=1 if yes
BeginProc kb_contains
        push    ecx
        push    edi
        mov     ecx, 6
        repne   scasb
        pop     edi
        pop     ecx
        ret
EndProc kb_contains

;----------------------------------------------------------------------------
; hid_kbd_report: ESI -> fresh 8-byte boot report.  Diff against kb_prev,
; emit make/break for modifiers and keys, update the typematic target.
;----------------------------------------------------------------------------
BeginProc hid_kbd_report
        push    ebx
        push    ecx
        push    edx
        push    esi
        push    edi
        inc     dword ptr [kb_dbg_reports]

        ; ---- modifiers (byte 0) ----
        mov     cl, [esi]               ; new mod state (shifts down)
        mov     ch, [kb_prev]           ; old mod state (shifts down)
        mov     bl, cl
        xor     bl, ch                  ; changed bits
        xor     bh, bh                  ; bit index 0..7
km_loop:
        test    bl, 1
        jz      km_next
        mov     al, bh
        xor     ah, ah                  ; assume make
        test    cl, 1
        jnz     @F
        mov     ah, 80h                 ; now clear -> break
@@:     call    kb_mod
km_next:
        shr     bl, 1
        shr     cl, 1
        inc     bh
        cmp     bh, 8
        jb      km_loop

        ; ---- breaks: old keys no longer present ----
        mov     ecx, 6                  ; index 2..7
        mov     ebx, 2
kb_brk:
        mov     al, [kb_prev + ebx]
        test    al, al
        jz      kb_brk_next
        lea     edi, [esi + 2]          ; new keycodes
        call    kb_contains
        jz      kb_brk_next             ; still down
        mov     ah, 80h
        call    kb_key                  ; break
kb_brk_next:
        inc     ebx
        cmp     ebx, 8
        jb      kb_brk

        ; ---- makes: new keys not previously present; track last for repeat ----
        mov     [kb_held], 0
        mov     ebx, 2
kb_mk:
        mov     al, [esi + ebx]
        test    al, al
        jz      kb_mk_next
        cmp     al, 4                   ; usage < 4 = error/rollover, skip
        jb      kb_mk_next
        mov     [kb_held], al           ; last valid key = repeat target
        push    ebx
        lea     edi, [kb_prev + 2]      ; old keycodes
        call    kb_contains
        pop     ebx
        jz      kb_mk_next              ; was already down
        xor     ah, ah
        call    kb_key                  ; make
kb_mk_next:
        inc     ebx
        cmp     ebx, 8
        jb      kb_mk

        mov     [kb_ticks], 0           ; restart typematic delay

        ; ---- save report ----
        mov     eax, [esi]
        mov     dword ptr [kb_prev], eax
        mov     eax, [esi + 4]
        mov     dword ptr [kb_prev + 4], eax

        pop     edi
        pop     esi
        pop     edx
        pop     ecx
        pop     ebx
        ret
EndProc hid_kbd_report

;----------------------------------------------------------------------------
; hid_kbd_idle: no fresh report; synthesize typematic repeat for a held key.
;----------------------------------------------------------------------------
BeginProc hid_kbd_idle
        cmp     [kb_held], 0
        jz      ki_done
        mov     eax, [kb_ticks]
        inc     eax
        mov     [kb_ticks], eax
        cmp     eax, KB_DELAY
        jb      ki_done
        sub     eax, KB_DELAY
        test    eax, KB_RATE - 1        ; KB_RATE is a power of two
        jnz     ki_done
        mov     al, [kb_held]
        xor     ah, ah
        call    kb_key                  ; repeated make
ki_done:
        ret
EndProc hid_kbd_idle

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
