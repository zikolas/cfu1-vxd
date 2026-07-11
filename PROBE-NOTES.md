# RATOC REX-CFU1 — hardware probe notes (PC110, 2026-07-11)

CF+ USB 1.1 host card, designed for Pocket PC (RATOC only ever shipped WinCE
drivers). Target: Windows 95/98 driver. All findings below verified on real
hardware via COMrade on the IBM PC110, socket 0.

## Identity

* CIS MANFID: **0xC015 / 0x0001** (matches Linux `sl811_cs` binding)
* VERS_1: "RATOC" / "USB HOST CF+ Card", FUNCID 0x0B (vendor-specific)
* Controller: **Cypress/ScanLogic SL811HS, hwrev reg 0x0E = 0x20 → rev 1.5**
* 48 MHz clock (full-feature mode); 256-byte internal RAM verified good
  (2-pass pattern test over 0x10–0xFF via auto-increment)

## CIS / configuration — THE BIG QUIRK

CONFIG tuple (1A): `00 06 F8 01` → declares COR at attribute **0xF8**, RMSK=COR only.

**The CONFIG tuple lies. The real (and only) config register is at attribute
0xFC.** Verified:

* attr 0xF8 reads 0xFF, writes never latch, writes there do NOT enable I/O
* attr 0xFC powers up as 0x40 (bit6 reads back stuck-high), latches writes
* any non-zero config index written to 0xFC enables I/O decode (0x01, 0x02,
  0x03 all equivalent); 0x00 disables. Index bits are NOT decoded.
* Consequence: **a standards-following host stack (incl. Win9x PCCARD.VXD
  RequestConfiguration) cannot enable this card** — our driver must map an
  attribute window and poke 0xFC itself. Likely why no PC driver ever shipped.
* Note: mainline Linux `sl811_cs` would hit the same wall (it uses the CIS
  RADR); the community stack it was ported from presumably poked the right
  address. Untested claim; do not rely on Linux behavior.

## Address decode

* CFTABLE entries 2/3/5/6 offer 8-port I/O at 0x260/0x280/0x2A0/0x2C0 — but
  the card **ignores A5–A7**: all four bases alias the same chip. The socket
  controller's I/O window provides the real decode granularity.
* Within the 8-port window: **A0 selects SL811 address(0)/data(1); A1=1
  selects an unknown 8-bit R/W latch (base+2/+3); A2 ignored** (base+4/+5
  mirrors base+0/+1).
* The +2/+3 latch: powers up unknown, latches anything written (tested 0x00,
  0x0E, 0x0F). Writing it had no observable effect on chip operation, clock,
  or detect. Suspected VBUS switch / LED control — **test when a USB device
  is available**: if /DETECT shows no device with one plugged in, walk latch
  bits. RATOC FAQ calls +2/+3 "SL811 register", +4..7 "not used".

## SL811HS operational findings (match datasheet 38-08008 Rev *A)

* Register semantics confirmed: 0x0E read=hwrev/write=SOF-low;
  0x0F write=CTL2 (bits5:0 SOF-high, bit6 DSWAP, bit7 Master),
  read=**live frame-time-remaining/64** (NOT CTL2 readback!)
* **SOF timer only runs when INTENA bit4 is set** (datasheet 5.3.5) — this
  gates the timer itself, not merely the interrupt. Without it the SOF
  counter freezes and nothing transmits.
* SOF start additionally needs the Linux kickstart: arm EP A once with
  buflen=0, PID=SOF(0x50)+ep0, devaddr=0, HOSTCTL=ARM, then CTL1=0x01.
  ARM auto-clears after first transmit (observed reg0: 0x01→0x0E leftovers).
* Detect (INTSTAT 0x0D): bit6=1 no device / 0 present (only while CTL1
  suspend=0); bit5 latches on SE0↔idle transitions (insert AND remove);
  bit7 = live D+ (1=full-speed device, 0=low-speed, once present).
* DSWAP (CTL2 bit6) + LSPD (CTL1 bit5) are for LOW-SPEED devices directly
  attached, not board wiring.
* Force-J/SE0 via CTL1 bits 4/3 works; transceiver drives lines and detect
  logic follows (verified without any device attached).
* **IRQ delivery verified**: card IREQ# → PCIC IRQ5 → 8259, SOF interrupts
  received by DOS ISR (292/s measured; shortfall vs 1000/s blamed on the
  COMrade 115200-baud serial ISR at higher PIC priority — retest sometime
  without the link active).
* Chip is NOT reset by our enable path (PCIC never asserts card RESET;
  state persists across CFUPROBE runs). Win98 driver should do a proper
  USB-engine reset (CTL1 bit3) or force-SE0 cycle at init.

## PC110 socket recipe (works, in CFUPROBE.C)

PCIC 0x3E0 socket 0: power 0x02=0x95, wait, 0x03=0x40, wait READY (reg1
bit5); attr window 0 → seg 0xD000 (regs 10/11/12/13 = D0 00 D3 00, offset
14/15 = 30 7F); **write 0x02 to window offset 0x1F8 (= attr 0xFC)**;
0x03=0x60 (I/O mode); I/O win0 0x260–0x267 (8-bit, reg 07=0); reg 06=0x41.

## Tools

* `CFUPROBE.C` (this repo + C:\CFUPROBE.C on the PC110, Watcom
  `C:\WATCOM\BLD.BAT CFUPROBE`):
  `CFUPROBE [/SOF] [/SWAP] [/DETECT] [/IRQ n] [/OFF]` — enable+ID+regdump+
  RAM test+mirror check+line state; SOF start; detect+speed; IRQ count; off.
* `ref/`: Linux sl811-hcd.c / sl811.h / sl811_cs.c, SL811HS datasheet PDF.

## Open questions

1. +2/+3 latch function (VBUS?) — needs a USB device plugged in.
2. SOF interrupt rate shortfall under COMrade (likely measurement artifact).
3. Win98 PnP hardware ID CRC for the INF (compute from CIS strings).

## Windows 95/98 driver — status (2026-07-11)

Deliverables built and statically verified in `win/dist/`:

* **CFU1.VXD** (2.2KB, LE) — dynamically loadable VxD: does the whole enable
  (socket power → READY → attr window → **COR@0xFC** → I/O window) in ring 0,
  exposes ioctls (see win/diag/CFU1.H): ENABLE/DISABLE, SL811 reg r/w, attr
  r/w, VPICD IRQ hook + counter. LE header, DDB (name "CFU1", control proc),
  ordinal-1 export, and all int-20h dynalinks (VMM _MapPhysToLinear 0x6C,
  VPICD 01/04/09/11) verified by parsing the binary.
* **CFUDIAG.EXE** (Win32 console) — CFUPROBE port; uses the VxD, or /RAW
  (ring-3 port I/O + linear attr window — works on 9x, no IRQ test).
  /IDS lists HKLM\Enum\PCMCIA so we learn the card's true PnP ID + CRC.
* **CFU1.INF** — null-driver placeholder until /IDS gives the real ID.
* **TEST-ON-98.md** — the test script for the Win98 box.

Build rig (Mac-native): Open Watcom v2 snapshot at `~/tools/ow2` (armo64
binaries) + JWasm v2.21 built from source (malloc.h + link flag patches),
installed at `~/tools/ow2/armo64/jwasm`. 98 DDK from archive.org extracted
at `~/tools/98ddk/x`. `win/build.sh` builds everything.

**DDK includes are patched for JWasm** (win/ddkinc, original kept as
vmm.inc.orig): (1) MakeCodeSeg factory invocations commented out (nested
macro-name generation JWasm can't parse; VxD_LOCKED_* segs are defined
elsewhere and unaffected), (2) all `@@`-prefixed symbols renamed `JWS_`/`JW_`
(JWasm reserves @@ for anonymous labels), (3) `&&`→`&` and `&macro`/`&endm`→
`macro`/`endm` (OLDMACROS-era escaping; VMM.INC's `OPTION OLDMACROS` is
ignored by JWasm). Assemble flags: `-coff -D BLD_COFF -D IS_32 -D MASM6
-D DEBLEVEL=0`. Link: `wlink system win_vxd ... export CFU1_DDB.1`.

Next steps: (1) run TEST-ON-98 on the Win98 box → true PnP ID, VBUS/latch answer,
IRQ delivery on real Win98; (2) finalize INF; (3) USB transaction engine
(control transfers + enumeration) in the VxD, prototyped first on DOS via
CFUPROBE-style tool with a device attached; (4) the moonshot: mass-storage
class + IOS port driver = drive letter from a USB stick.

Card was left ENABLED at 0x260 on the PC110 (socket 0 powered, SOF off).

## FIRST USB TRANSACTIONS — 2026-07-11 (CFUENUM.C)

With a HID device attached: full control transfer to addr 0 succeeded —
SETUP ACK, IN ACK+SEQ(DATA1), STATUS ACK. GET_DESCRIPTOR(device,8) returned
`12 01 00 02 00 00 00 08` = USB 2.0 full-speed device, bMaxPacketSize0=8.
VBUS is powered without touching the +2/+3 latch (open question 1 CLOSED).
INSRMV latched on physical hot-plug.

Hard-won rules for the transfer engine:
* **AFTERSOF (HOSTCTL bit5) hangs transfers except on confirmed full-speed**
  (Linux sl811-hcd "erratum 2"). Plain ARM|ENABLE works.
* **INTSTAT bit7 (D+) speed detect is NOT trustworthy**: read "low-speed"
  repeatedly on a device that then ACKed full-speed packets with straight
  polarity. Presence (bit6) is reliable; speed is not. Driver enumeration
  must PROBE: try FS config (no LSPD/DSWAP), on SETUP timeout retry LS
  config (CTL1 bit5 + CTL2 bit6). CFUPROBE/CFUDIAG "/DETECT" speed labels
  carry this caveat.
* Working FS recipe: reset SE0 30ms → SOFLOW=0xE0, CTL2=0xAE, SOF kickstart
  (EP A: len 0, PIDEP=0x50, addr 0, ARM), CTL1=0x01, INTENA=0x10 → ~60ms
  settle → transactions with ARM|ENABLE(|OUT|DATA1 as appropriate), poll
  INTSTAT bit0, status in reg 3, remaining count in reg 4.
* Tool: CFUENUM.C (repo + C:\CFUENUM.EXE on box).

## WINDOWS 98 VALIDATION — 2026-07-11 evening (ThinkPad 235)

**USB control transfer succeeded through CFU1.VXD on Win98**: /ENUM read the
device descriptor (12 01 00 02 00 00 00 08, full-speed) — SETUP/IN/STATUS
all ACKed, speed-probe (FS first, LS+DSWAP fallback) landed FS first try.
Verified PnP hardware ID: **PCMCIA\RATOC-USB_HOST_CF+_CARD-57DD** (from
HKLM\Enum via CFUDIAG /IDS); CFU1.INF updated with it.

Hard-won Win98 lessons (all encoded in the tools):
* **VxD must be linked `format windows vxd DYNAMIC`** — without the flag,
  CreateFile dynamic load fails GetLastError=2 on every path form. (wlink's
  canned `system win_vxd` does NOT include it.)
* **/RAW mode silently reads fake hardware under Win98**: PCIC ports are
  virtualized per-VM and linear D0000 is per-VM memory; COR "readback" was
  our own RAM write echoing. V86 io_in/io_out from COMrade's DOS box are
  equally untrustworthy on this machine.
* **OS PCMCIA layer races our enable** after each socket power-on
  (insertion event → its own CIS pass reprograms windows): fixed by
  verify-COR-and-retry in enable_vxd (a second ENABLE doesn't power-cycle,
  so no new event).
* **Leaving INTENA set with no handler kills the socket**: the wedged level
  IREQ# makes the OS PCMCIA layer power the socket down (status reads 00);
  recover with /OFF + re-enable. CFUDIAG now quiesces (INTENA=0, INTSTAT
  clear) before exit.
* **IRQ delivery blocked on the 235 under Win98**: steering reg holds, PCIC
  sees IREQ# asserted (ifstat bit5=0), but no ISA IRQ fires on 5/7/11/15
  (3/9/10/12 refused by VPICD as owned). The OPTi FireStar router has the
  PCMCIA IRQ routes parked (IRQHOLDER "PROBLEM 22" nodes). Under DOS the
  CD-20X used IRQ7 fine → DOS-mode routing works; Windows reprograms it.
  Fix path: proper INF+CONFIGMG devnode so Windows assigns/routes the IRQ.
  Meanwhile POLLED transfers work perfectly (~0.3ms/ioctl via VxD).
* 235 PCIC: id 0x83, CSC IRQ not programmed (management is polled), vendor
  regs 0x16-0x1F all zero. Card in socket 0; sockets read via V86 lie.
* CFUDIAG switches now: /IDS /LIVE /PCIC /ENUM /DETECT /SOF /SWAP /IRQ n
  /SOCKET /BASE /WIN /RAW /OFF. VxD 1.01 adds CFU_PCICRD/CFU_PCICWR.

Next milestones: (1) INF + CONFIGMG-integrated VxD → Windows-assigned IRQ +
auto-enable on insertion; (2) transfer engine (control/interrupt/bulk) in
the VxD proper; (3) HID interrupt polling demo (mouse moves a Win98 cursor
via our card?); (4) mass storage → drive letter.

## PNP / CONFIGMG MILESTONE — 2026-07-11 late (ThinkPad 235)

**Full PnP chain works**: INF (DevLoader=CFU1.vxd) + VxD 1.10 with
PNP_NEW_DEVNODE -> CM_Register_Device_Driver -> CONFIG_START ->
CM_Get_Alloc_Log_Conf. On insertion Windows installed the INF (user had
to point the wizard at C:\WINDOWS\INF once), created devnode
PCMCIA\RATOC-USB_HOST_CF+_CARD-57DD\0 (no problem flags), assigned
**I/O 0x280 (CFTABLE entry 3!) + IRQ 15**, PCCARD programmed the socket
(power 0xF5, steering 0x6F), and our config handler's cor_fix found the
socket by matching the enabled I/O window, applied COR@0xFC (readback
0x42), all automatically. /ENUM then read the device descriptor at the
Windows-assigned base. CFUDIAG /CONF shows the PnP state and skips
re-enable when the PnP path already enabled the card.

New findings:
* **Deviceless SOF does not start on the 235** (any init path, any COR
  value, latch written or not, native-speed or ioctl timing): frame timer
  frozen, kickstart ARM never clears. With a device attached SOF runs
  immediately. The PC110 runs SOF deviceless fine -- host-environment
  interaction (socket power margins? osc start-up?), not chip logic.
  Irrelevant operationally (host mode always has a device) but diag
  expectations must account for it.
* **IRQ 15 assigned by Windows still delivers nothing** (IREQ# asserted
  at PCIC, steering correct). Hypothesis: the 235 only wires a subset of
  PCIC IRQ pins (only IRQ7 is DOS-proven, owned by LPT under Windows);
  CONFIGMG assigned 15 = the disabled secondary IDE's line, likely
  unwired from the PCIC. Test plan: INF LogConfig override (documented
  MS mechanism "INF Override for Configuring PC Card Interrupts") to
  constrain the IRQ list + free IRQ7 by disabling LPT in Device Manager.
  Until then: POLLED operation, which the whole transfer path uses anyway.
* Card I/O ports are NOT virtualized for V86/DOS boxes (unlike the PCIC
  index/data ports and low linear memory) -- direct port pokes at the
  card's I/O base from a Win98 DOS box reach real hardware. CFUSOF.C
  (dos/) exploits this for native-timing SOF tests inside Windows.
* VxD 1.10 adds: PNP_NEW_DEVNODE + config handler + cor_fix (socket scan
  by I/O window match, PCIC reg save/restore around the attr poke),
  CFU_GETCONF ioctl. CFUDIAG adds /CONF /CLEANID /RD /WR.
* Deploy layout: CFU1.VXD in C:\WINDOWS\SYSTEM, CFU1.INF in
  C:\WINDOWS\INF, diag kit in C:\CFU1.

Next: transfer engine inside the VxD (single-ioctl transactions; polled
first, IRQ when the routing puzzle is solved) -> SET_ADDRESS + full
enumeration -> HID interrupt-IN polling demo -> mass storage.

## RING-0 TRANSFER ENGINE + LIVE HID — 2026-07-11 night

VxD 1.20 moves USB transactions into ring 0 (native port speed, no more
~1ms-per-register ioctl tax): CFU_USBINIT (bus reset + host init + SOF
kickstart, LS/FS), CFU_XACT (raw EP A transaction, 50ms completion poll),
CFU_CTRL (complete control transfer: SETUP/DATA/STATUS with NAK retry
(~250x1ms), data toggles, mps-chunked IN stage, short-packet handling).

Verified on the 235 (Win98, PnP-enabled card, boot-time auto-start with
VxD 1.20 confirmed — Windows re-arbitrated the base to 0x260 this boot):

* CFUDIAG /ENUM2 = full enumeration: speed probe -> GET_DESCRIPTOR(8) ->
  mps discovery -> SET_ADDRESS 1 -> full 18-byte device descriptor ->
  config descriptor parse (interfaces/endpoints/HID detect) ->
  SET_CONFIGURATION 1. Test device identified: Logitech receiver
  VID 046D PID C52F, 2 HID interfaces (boot mouse ep81 int 2ms mps 8;
  consumer ep82 int 2ms mps 32).
* CFUDIAG /HID 1 = live interrupt-IN polling at ~100Hz from ring 3
  (Sleep(10) pacing): 164 mouse reports in 8s, correct boot-mouse format
  (buttons + 16-bit dX + 16-bit dY), toggle tracking across reports.

Notes: interrupt-IN polling from ring 3 via CFU_XACT is fine for a demo
(NAK costs one ioctl round trip); a real HID driver wants the poll loop
in the VxD on a timer. OUT data stages not implemented yet (nothing
needed them). The /CONF /ENUM2 first run exposed that CFUDIAG's /CONF
early-exit must enumerate every action flag - fixed.

Milestone status: enumeration + control + interrupt transfers DONE.
Remaining on the roadmap: bulk transfers + mass storage (BOT + drive
letter integration), IRQ routing archaeology (LogConfig override), HID
poll loop in the VxD, multi-device support if a hub ever matters.

## HID POLISH: THE MOUSE MOVES THE WINDOWS POINTER — 2026-07-11/12

**CFUMOUSE.EXE drives the real Windows 98 cursor from a USB mouse plugged
into the REX-CFU1** — enumerate (address 1, config 1, SET_PROTOCOL boot
accepted by the Logitech receiver), start the in-VxD poll loop, drain
reports, inject via mouse_event() (movement + 3 buttons with edge
handling). Measured: 1324 reports / 1322 movements in 20s (66 rps at an
8ms ring-0 poll).

VxD 1.31 additions:
* CFU_HIDSTART/HIDSTOP/HIDREAD: self-rescheduling Set_Global_Time_Out
  poll loop at event time (short 3ms transaction budget), 32-slot ring
  buffer (len+8 bytes/slot), toggle tracking, drop-oldest overflow.
* xbusy guard: ioctl transaction paths (XACT/CTRL) own EP A and the
  timer tick skips; timer owns EP A only within one tick.
* hid_stop on DIOC_CLOSEHANDLE, SYS_DYNAMIC_DEVICE_EXIT, and before any
  CFU_USBINIT (bus reset invalidates the poll target).

**VxD lesson that cost a bluescreen (GPF 0D at teardown): VMM
Set_Global_Time_Out RETURNS THE HANDLE IN ESI, and Cancel_Time_Out TAKES
IT IN ESI — not EAX.** Confirmed from the DDK's own VXDWRAPS sources
(SRC_BASE_VXDWRAPS_VMM_VMM15Z/16Z.ASM); scheduling works no matter where
you think the handle is, so the bug only detonates at cancel time with
whatever ESI held (the DIOCParams pointer). v1.30 -> v1.31. Also added
hid_run flag so an in-flight tick can't re-arm after cancel.

Win9x console gotcha: GetAsyncKeyState does not see keys focused into a
DOS box, and unconsumed keys REPLAY at the DOS prompt on exit (ESC echoes
a backslash at COMMAND.COM - hence a staircase of \ after the run).
CFUMOUSE now uses kbhit/getch which both detects ESC and drains the queue.

Remaining roadmap: mass storage (bulk + BOT + drive letter), IRQ
LogConfig experiment, real VMD/VMOUSE integration (mouse_event is a demo
vehicle; a proper mouse driver would feed VMOUSE at ring 0).

## PROPER VMOUSE INTEGRATION — 2026-07-12

**The pointer now runs entirely at ring 0.** VxD 1.40: CFU_HIDSTART takes
an optional 5th byte (mode bit0 = VMOUSE). In that mode the HID tick
parses each boot-protocol report and calls **VMD_Post_Pointer_Message**
(VMOUSE device 0x0C, service 3): ESI = delta X (sign-extended),
EDI = delta Y, AL = buttons in the serial-mouse format VMOUSE expects
(bit5=L, bit4=R, bit3=M; HID bits translated via btntab). Calling
convention lifted from the DDK's own serial mouse sample
(SRC_MOUSE_SERMOU_SERIAL.ASM), which posts from its COM-port interrupt
handler — same context class as our timeout tick. No VMD_Set_Mouse_Data
registration was needed; posts are accepted and merged with the PS/2
TrackPoint stream, and the HID->serial button remap comes out the right
way round.

DIOC_CLOSEHANDLE keeps the poll loop alive in VMOUSE mode, so
`CFUMOUSE /VMOUSE` enumerates, arms the feed, and EXITS — the mouse
keeps working with no process running (the VxD stays resident because
CONFIGMG loaded it as the devnode's DevLoader). `CFUMOUSE /STOP` cancels
(hid_stop also clears hid_mode so later mode-0 sessions clean up
normally). Verified on the 235: feed survives app exit and DOS-window
close; buttons correct; /STOP works.

This is, in effect, a working USB mouse driver for Windows 98 via the
REX-CFU1. Remaining gap to "true" driver polish: auto-enumerate + auto-
start the feed from CONFIG_START at boot (today it needs one CFUMOUSE
/VMOUSE run per session), and wheel support (needs the HID report
descriptor or Logitech's 16-bit report format instead of boot protocol).
