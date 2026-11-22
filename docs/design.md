# WWIVFOSS Design

## Goals

1. Run FOSSIL DOS doors from a BBS on Linux, Windows x64, macOS, Windows x86
   (NTVDM) and OS/2.
2. Be maintainable: open source, built in CI with a freely available toolchain
   (Open Watcom v2), and tested automatically in an emulator.
3. Stay out of the BBS's way: the BBS owns the caller's connection and telnet
   handling. WWIVFOSS moves bytes and reports carrier.

Non-goals: being a telnet server, emulating a modem, or replacing a full
DOS emulator.

## Model: runner or resident

One binary, two ways to install the same handler:

* **Runner** (`WWIVFOSS [opts] COMMAND`): install, spawn the door, restore.
  Can't leave a stale handler behind when a door crashes, passes the door's
  exit code through (`.EXE`/`.COM` doors are spawned directly; only `.BAT`
  goes through `COMSPEC /C`), and matches the old OS/2 wwivfoss command
  line. Best for a modern BBS running one door per emulator session.
* **Resident** (`WWIVFOSS -L`, `WWIVFOSS -U`): load once, BNU/X00 style.
  Needed for a DOS BBS running inside the emulator. `-U` finds the resident
  copy through a private INT 14h call (`AH=7Eh`, `BX='WF'`, see
  `foss_protocol.h`), refuses if INT 14h or the UART IRQ was hooked after
  us, has the resident copy close its transport and restore its vectors,
  then scans the vector table and frees the memory only if nothing else
  still points into it.

The resident copy currently keeps the whole block the Open Watcom runtime
sized (about 37 KB). Trimming that is a TODO.

## Components

```
  door (DOS)
     | INT 14h (FOSSIL rev 5)
  dos/fossil.c      dispatcher: function table, port check, idle policy
     | struct transport
  dos/uart.c        16550 UART, IRQ-driven receive ring
  dos/stubs.c       vdd (NTVDM BOP into vdd/ DLL) and pipe (OS/2) placeholders
```

### FOSSIL entry and signature

FOSSIL detection requires the INT 14h vector to point at code with `0x1954` at
offset 6 and the highest supported function at offset 8. `dos/entry.asm` holds
that header and jumps to the C handler (`__interrupt` with `union INTPACK`).
Unsupported ports (DX not ours) are chained to the previous INT 14h owner.

### Interrupt safety rules (Open Watcom)

* ISR-reachable modules are built with `-s` (no stack checks) and `-zu`
  (SS != DGROUP). Never pass the address of a stack local to another function
  from ISR context; use statics.
* No C runtime calls from ISR context other than `inp`/`outp`/`int86` with
  static register blocks.
* The handler guards against re-entry.

### Idle

Doors poll status (03h) and peek (0Ch) in tight loops. After a number of empty
polls in a row the dispatcher releases the CPU: `INT 2Fh AX=1680h` (honoured
by NTVDM, OS/2, Windows, DOSBox-X), falling back to `STI; HLT` which lets
QEMU and other emulators idle until the next interrupt. Receive is
interrupt-driven, so a HLT wakes on incoming data. `-I0` disables this.

## uart transport

* COM1-4 standard bases/IRQs. 8N1, FIFO enabled, divisor ignored by emulators.
* Receive: IRQ handler drains the RBR into a 2 KB ring buffer; overflow sets
  the overrun status bit.
* Transmit: polled on THRE for now. TODO: TX ring + THRE interrupt for real
  hardware throughput.
* Carrier: MSR DCD. `-C` forces carrier on for emulators whose socket serial
  backend does not model DCD.
* On exit DTR is left **raised**: the BBS keeps the session after the door, so
  WWIVFOSS must not hang up the caller. FOSSIL 06h (lower DTR) from the door
  is the hangup path.

### Emulator wiring

The BBS listens on `127.0.0.1:<port>` (WWIV: listen-socket exec mode, `%Z`),
starts the emulator, and the emulator connects its COM1 to that port.

* DOSBox-X: `serial1=nullmodem server:127.0.0.1 port:%Z`
* QEMU: `-chardev socket,id=s0,host=127.0.0.1,port=%Z -serial chardev:s0`

Templates live in `configs/`.

## vdd transport (planned)

For 32-bit Windows NTVDM and NTVDMx64. The DOS side registers a VDD with a BOP
(`RegisterModule`/`DispatchCall`, see the Windows DDK `isvbop.h`/`vddsvc.h`);
the DLL maps a shared ring buffer and status block in DOS memory with
`MGetVdmPointer` so status and peek don't need a BOP, runs a reader thread,
and connects to the BBS with one named pipe per direction plus named events
for carrier and DTR. To be written from the public FOSSIL and VDD
documentation.

## pipe transport (planned)

OS/2 VDM named pipes, `\PIPE\WWIV<node>` (data) and `\PIPE\WWIV<node>C`
(control), the protocol wwivd already speaks. Port the old
`wwiv/dos/wwivfoss/pipe.cpp`, fixing its known bugs (non-blocking 02h, NULs
dropped, 1Bh size check).

## Testing

* `tools/fostest`: a door that initialises the FOSSIL, prints driver info,
  and echoes input until it receives `Q` or loses carrier. Exit code 0 on
  success.
* CI (planned): boot FreeDOS under QEMU on a Linux runner with COM1 on a
  socket, run `WWIVFOSS FOSTEST`, drive it from a script over the socket,
  and check the echo and exit code.

## Open questions

1. ~~Which emulators raise DCD on their socket serial backends?~~ Answered:
   DOSBox-X raises DCD on connect and drops it when the socket closes.
   QEMU (10.0) holds DCD high forever (a `modemctl` chardev option was
   proposed upstream in 2020 but never merged). For QEMU, `-E` carries
   line state in-band using DOSBox-X's nullmodem framing, so one BBS-side
   implementation covers both.
2. Sharing door files with QEMU (disk image vs `fat:rw:`); DOSBox-X and
   dosemu2 mount host directories directly.
3. Resident size (about 37 KB with the Open Watcom runtime and heap).
