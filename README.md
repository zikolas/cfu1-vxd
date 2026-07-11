# cfu1-win9x

Windows 95/98 driver (and DOS tooling) for the **RATOC REX-CFU1 "USB HOST
CF+ Card"** — a CompactFlash-sized USB 1.1 host controller card built
around the Cypress/ScanLogic **SL811HS**. RATOC only ever shipped Windows
CE drivers for it; this project makes the card work on PCs.

<img src="docs/rex-cfu1.jpg" width="480"
     alt="The REX-CFU1 in an IBM CF-to-PC-Card adapter, with its USB-A
          dongle cable attached">

*The REX-CFU1 with its USB-A dongle, seated in an IBM Microdrive
CF-to-PC-Card adapter — as tested in a ThinkPad 235.*

Current state: **a working, installable USB mouse driver for Windows
98.** Insert the card and Windows PnP-installs it (INF + CONFIGMG-
integrated VxD, auto-enabled at boot); plug a USB mouse into the card at
any time and a ring-0 hot-plug supervisor enumerates it and feeds
Windows' pointer via VMOUSE — no commands, hot-unplug/replug safe. USB
keyboards work too (one CFUKBD command arms a ring-0 feed that types
into Windows via VKD, with typematic repeat). The
same VxD exposes a full polled USB transfer engine (control + interrupt
transfers, enumeration, HID streaming) over a simple ioctl API. Mass
storage reads work (Bulk-Only Transport + SCSI + FAT, ring-3 over the
VxD); a real drive letter and full hub support are the next steps.

## Why no driver ever existed: the card's CIS lies

The card's CIS CONFIG tuple declares its configuration register at
attribute address **0xF8**. The real (and only) configuration register is
at attribute **0xFC** — writes to 0xF8 never latch. Any
standards-following host stack (Windows 9x PCCARD, Card Services, etc.)
writes the COR at the address the CIS declares, the card ignores it, and
the card stays dead. Every tool and driver here maps an attribute-memory
window and pokes 0xFC directly.

More hardware findings (verified on real hardware — an IBM PC110 under DOS
and a ThinkPad 235 under Windows 98) are documented in
[PROBE-NOTES.md](PROBE-NOTES.md), including:

* full CIS dump and decode; MANFID C015/0001; PnP ID
  `PCMCIA\RATOC-USB_HOST_CF+_CARD-57DD`
* address decode map (A0 = SL811 addr/data select, A1 = an unidentified
  latch, A2/A5–A7 ignored)
* SL811HS gotchas: the SOF timer is gated by INTENA bit 4; SOF generation
  needs the EP-A kickstart; the AFTERSOF host-control bit hangs non-
  full-speed transfers; the D+ speed-detect status bit is unreliable
  (probe full-speed first, fall back to low-speed + DSWAP)
* Windows 98 gotchas: VxDs must be linked dynamically loadable; ring-3
  hardware access is silently virtualized; the OS PCMCIA layer races
  socket enables and shuts down sockets with unserviced interrupts

## Contents

```
dos/        DOS tools (build with Open Watcom 1.9+, 16-bit)
  CISDUMP.C   dump any PC Card's CIS via an 82365-compatible controller
  CFUPROBE.C  enable + identify + RAM test + detect + SOF + IRQ test
  CFUENUM.C   bus reset + GET_DESCRIPTOR control transfer (needs CFUPROBE)
win/        Windows 95/98 driver + diagnostic
  vxd/CFU1.ASM   dynamically loadable VxD: ring-0 socket enable (with the
                 COR-at-0xFC quirk), SL811 register/attr access ioctls,
                 VPICD IRQ hook
  diag/CFUDIAG.C Win32 console diagnostic: /ENUM /DETECT /SOF /IRQ /IDS
                 /LIVE /PCIC and more; loads the VxD from its own directory
  CFU1.INF       PnP install stub with the verified hardware ID
  build.sh       cross-build on macOS (Open Watcom v2 + JWasm)
  get-ddk.sh     fetch the Windows 98 DDK includes and patch them for JWasm
  dist/          ready-to-run binaries
```

## Building

The Windows binaries cross-build on a modern machine — no retro toolchain
required on the target:

1. Install [Open Watcom v2](https://github.com/open-watcom/open-watcom-v2)
   (the snapshot tarball includes native macOS/Linux binaries) and build
   [JWasm](https://github.com/Baron-von-Riedesel/JWasm).
2. `win/get-ddk.sh` — downloads the Windows 98 DDK from the Internet
   Archive and extracts + patches the VMM/VPICD/etc. includes for JWasm
   (they are Microsoft-copyrighted, so they are not in this repo; the
   patch pipeline is verified byte-reproducible).
3. `win/build.sh` — produces `CFU1.VXD` and `CFUDIAG.EXE`.

The DOS tools build on any DOS box with Open Watcom
(`wcc -ms` + `wlink system dos`).

## Using it on Windows 98

Copy `win/dist/CFU1.VXD` and `CFUDIAG.EXE` to the same directory on the
target machine, insert the card, and:

```
CFUMOUSE /AUTO       enable the hot-plug supervisor: any USB mouse
                     plugged into the card just works (this is also
                     armed automatically at boot once the INF-installed
                     driver starts, so normally you never run anything)
CFUMOUSE /NOAUTO     disable the supervisor
CFUMOUSE /VMOUSE     one-shot: enumerate + arm the ring-0 pointer feed
CFUMOUSE /STOP       stop the pointer feed

CFUDIAG /CONF        show the PnP state (assigned resources, COR fix)
CFUDIAG /DETECT      enable the card, identify the SL811, test its RAM,
                     report whether a USB device is attached
CFUDIAG /ENUM2       full enumeration: SET_ADDRESS, descriptors, VID/PID,
                     config parse, SET_CONFIGURATION
CFUDIAG /HID n       stream interrupt-IN reports from endpoint n
CFUDIAG /IDS         list the PC Card PnP IDs Windows has recorded
CFUDIAG /OFF         power the socket down
```

`CFUDIAG /SOCKET n`, `/BASE hex`, `/WIN hex` select other sockets, I/O
bases, and attribute-window addresses. See TEST-ON-98.md and the source
for the full switch list.

## Status / roadmap

- [x] Hardware reverse engineering (CIS quirk, decode map, SL811 errata)
- [x] DOS proof: enable, SOF, IRQ delivery, control transfers
- [x] Win98 VxD: ring-0 enable, register access, IRQ hook, ioctl API
- [x] Win98 proof: device descriptor read through the VxD
- [x] PnP INF + CONFIGMG integration: auto-install, auto-enable at boot,
      Windows-assigned resources (COR quirk applied in CONFIG_START)
- [x] Ring-0 transfer engine (control + interrupt transfers, NAK retry,
      data toggles, full enumeration, HID report streaming)
- [x] USB mouse driver: ring-0 VMOUSE injection, movement + 3 buttons,
      survives app exit
- [x] Hot-plug auto-mouse supervisor: works from boot with zero commands,
      unplug/replug safe
- [ ] Mouse wheel (report-protocol parse + ring-3 helper; Win98's VMOUSE
      service has no Z axis)
- [x] USB keyboard: ring-0 VKD_Force_Keys injection, HID→scan-code
      translation, report diffing, typematic synthesis (supervisor
      auto-detection of keyboard vs mouse still pending)
- [x] USB mass storage: Bulk-Only Transport + SCSI, reads a USB stick's
      sectors/partitions/FAT directory (CFUDISK, ring-3 over the VxD's
      bulk-transaction ioctl — verified reading files off a FAT32 drive)
- [~] USB hubs (hub descent implemented in CFUDISK: port power, reset,
      downstream re-address — not yet tested; also the road to mouse +
      keyboard at once)
- [ ] Mass storage → real drive letter (needs an IOS-layer block driver)
- [ ] Interrupt-driven operation (IRQ delivery is blocked by chipset IRQ
      routing on the test machine; INF LogConfig override experiment
      pending — everything currently runs polled and works)

### On not using Microsoft's USB stack

Windows 98 *does* have a full WDM USB stack (`USBD.SYS`, `USBHUB.SYS`,
the HID class drivers), and its HID input shims feed the very same
VMOUSE/VKD services this driver injects into. We can't ride it: the whole
stack sits on top of a host-controller driver (`OPENHCI.SYS` /
`UHCD.SYS`) bound to `USBD.SYS` through the undocumented, internal HCDI
interface, and there is no SL811 HCD nor a documented way to write one.
Period third-party USB stacks for 9x (e.g. OrangeWare's) shipped
parallel to Microsoft's for the same reason. So this driver is its own
small USB stack by necessity, not preference.

- [ ] **(research)** WDM HCD for the SL811: reverse the HCDI so the card
      plugs into Microsoft's own USB/HID/USBSTOR stack — would make hubs,
      device coexistence, and mass storage "free", but it's a hard RE
      project with real risk. The pragmatic hub + mass-storage work above
      reaches the same user-visible goals without it.

## References

* Cypress SL811HS datasheet (38-08008) and the Linux `sl811-hcd` /
  `sl811_cs` drivers — the reference implementations for this chip
* [RATOC's CFU1U FAQ](http://www.ratocsystems.com/english/support/faq/cfu1u.html)

## License

MIT — see [LICENSE](LICENSE).
