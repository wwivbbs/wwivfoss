# TODO

What's left before WWIVFOSS is ready for real use with QEMU and DOSBox-X,
roughly in the order it should be done. See `docs/design.md` for the
architecture and `docs/todo-shrink.md` for the resident-size plan.

Done so far: FOSSIL rev 5 dispatcher, uart transport with interrupt-driven
rings, runner and resident (`-L`/`-U`) modes, in-band line control (`-E`),
DCD carrier on DOSBox-X, and an emulator test matrix (QEMU and DOSBox-X ×
runner and resident × echo/hangup/dtr) that runs in CI.

## Harden the driver (testable today)

- [x] **Extend FOSTEST**: `F` (00h 03h 06h 07h 0Bh 0Dh 0Fh 10h 11h–13h
      15h 1Bh), `P` peek, `X` purge in/out, `K` keyboard (QEMU, typed via
      the monitor); `funcs` scenario in `scripts/test.sh`. Found and fixed:
      keyboard/screen functions were chained to the BIOS when DX (a cursor
      position, not a port) didn't match our port.
- [x] **8-bit clean test**: `B` sends 00–FF with 19h and receives 00–FF
      with 18h, raw (DOSBox-X) and with `-E` FF escaping (QEMU).
- [x] **File transfer test**: `tests/doors/fdsz.sh` round-trips a 32 KB
      file holding every byte value through FDSZ (the FOSSIL build of DSZ)
      with lrzsz on the BBS side; passes under both emulators and modes.
- [ ] **FDSZ receive speed under QEMU**: BBS→DOS runs at ~1.4 KB/s under
      QEMU (TCG on arm64) vs ~33 KB/s DOS→BBS and ~6 KB/s both ways under
      DOSBox-X. Raw FOSSIL block reads under QEMU do 278 KB/s
      (`scripts/test.sh qemu speed`), so the driver's receive path is fine;
      the cost is FDSZ's byte-at-a-time 03h/02h loop (~20,000 waits on an
      empty buffer per 32 KB) against QEMU's slow refill of its UART FIFO.
      Halting or spinning while waiting doesn't change it. Next: try QEMU
      with KVM on an x86 host, and other FOSSIL Zmodems (GSZ, CEXYZ).
- [ ] **Real doors**: `scripts/test.sh doors` runs every door defined in
      `tests/doors/` that's installed locally (`WWIVFOSS_DOORS`, default
      `/wwiv/doors`): prepare a cached copy, expect its banner, hang up, and
      check the door notices and exits, under both emulators in runner and
      resident mode.
  - [x] Global War 2.7 (`gw.sh`, from the local install).
  - [x] LORD 4.06 (`lord.sh`), VOTEDOS from OpenDoors 6.00 (`votedos.sh`),
        Jungle from DoorDriver 5.00 (`jungle.sh`): downloaded from the
        archive at https://mirrors.archeobits.com/bbs/archives.thebbs.org/.
        All doors pass under both emulators in both modes, and `-S` call
        counts prove each one used the FOSSIL rather than its own UART code.
  - [x] Food Fight 4.6 (`foodfite.sh`, DOOR.SYS). It checks carrier by
        reading the UART directly, so under QEMU it never saw an in-band
        hangup; WWIVFOSS -E now signals hangups through UART loopback mode
        (DCD reads low), which fixed it.
  - [ ] Editors: TIDE, OEdit, WWIVEdit (need WWIV editor drop files).
  - [ ] TW2002 1.03 (archive has it; v2 isn't there).

## WWIV end-to-end (in progress)

- [x] `configs/wwiv/dosdoor.sh`: runs a DOS door in DOSBox-X with WWIVFOSS
      from a WWIV socket chain; `DOSDOOR_LOG` for troubleshooting. (It
      converted WWIV's LF drop files to CR LF until WWIV fixed #1738; the
      conversion is commented out for older WWIV.)
- [x] `scripts/wwivsess.py`: scripted telnet session against a local WWIV
      without wwivd. LORD plays end to end through WWIV on Linux.
- [x] Fixed: transmitter stall when a byte arrives as a door starts (lost
      THRE interrupt under DOSBox-X; flush waited forever on tx_busy).
- [x] Door tests run through `dosdoor.sh` too (`dosdoor` mode). With it,
      `lord-stray` fails on the old build and passes on the fix. Findings
      along the way: command echo in the autoexec made DOSBox-X service the
      UART late (hundreds of RX overruns per Zmodem run; `dosdoor.sh` now
      uses `@echo off`), and QEMU's `fat:rw:` drive lost a file's last
      sector (QEMU door runs now use a FAT floppy image as B:).
- [ ] `lord-stray` failed once in 24 runs with the fix (dosdoor mode, echo
      on); not reproduced since. Watch for it.
- [x] `-I0` (no idling) stalled with a stray byte at door start: DOSBox-X's
      IIR kept reporting received data that LSR didn't have, the ISR gave
      up with the IRQ line high, and no UART IRQ came again. The ISR now
      reads RBR to clear it, and re-arms IER if its loop gives up. (The
      `lord-stray` flake below may have been the same thing.)
- [x] Sysop guide (`docs/wwiv.md`): DOSBox-X setup, chains, per-door
      recipes, troubleshooting, QEMU and WWIV's "WWIVFOSS (Socket Port)"
      mode, and the QEMU launcher (`configs/wwiv/qemudoor.sh`).
- WWIV issues filed: wwivbbs/wwiv#1752 (in-band line control for -E doors)
  and #1753 (heartbeats), done as the "WWIVFOSS (Socket Port)" mode (#1760);
  #1735 (doors SIGKILLed on hangup; fixed in 5.10 build 3815, #1776), #1737
  (leftover input forwarded to doors; build 3812, #1773), #1738 (LF drop
  files on Linux; build 3814, #1771). Still open: #1736 (bridge
  latency/throughput) and #1775 (Windows: drain the caller's socket before
  socket-handle doors, and Windows exec tests).

## Emulator setup

- [ ] **Fix `configs/` templates** to match what `scripts/test.sh` runs: the
      QEMU template still uses server-mode sockets and lacks `-E`; neither
      template has been tested.
- [ ] **Door file sharing**: decide how drop files and door data reach DOS.
      DOSBox-X mounts host directories (default). For QEMU: disk image,
      `fat:rw:`, or copy in/out (open question 2 in `docs/design.md`).

## WWIV integration (in the wwiv repo)

- [ ] **Exec mode** that launches the emulator against the `ExecSocket`
      listen port (`%Z`) with a per-door config generated from a template.
- [x] **`-E` framing on the BBS side** for QEMU: the "WWIVFOSS (Socket
      Port)" exec mode (wwivbbs/wwiv#1760) doubles FF to the door, decodes
      `FF nn` from it, tells the door when the caller drops, returns the
      caller when the door lowers DTR, and sends heartbeats.
- [ ] **Ship WWIVFOSS** with WWIV the way `NETF125.ZIP` is shipped today.
- [ ] **Remove SyncFoss** (`exec_cmdline_sync`, sbbsexec files) once the new
      driver covers its users; keep the "FOSSIL" exec mode name working.

## Robustness

- [x] **Heartbeat (`-H#`)**: no bytes from the BBS for 3 heartbeats (FF 03)
      count as a hangup; an INT 1Ch timer checks, so doors that read the
      UART directly see it too. Tests: `deadbbs` (hangs up after ~6 s with
      -H2), `hbidle` (not dropped while idle), `door:foodfite-dead`.
      wwivbbs/wwivfoss#1. BBS side: wwivbbs/wwiv#1753.
- [x] **`FF 03` on every connection (`-E`)**: documented as required in
      `foss_protocol.h`; `bbs.py` sends it on every in-band connection; the
      `twocalls` test (qemu, resident: call, hang up, call again) passes,
      and fails as it should when call 2 omits `FF 03` (FOSTEST /W times
      out waiting for a caller). WWIV side: noted on wwivbbs/wwiv#1752.
- [ ] **Stray 03 at startup (QEMU, in-band)**: the BBS sends FF 03 as
      soon as QEMU connects, before DOS boots. `uart_open()` clears the
      FIFO (`FCR_ENABLE_CLEAR`); if the FF is in the UART then and the 03
      not yet, the FF is lost and the 03 reaches the door as data (^C).
      Seen twice in ~10 `door:w4test` runs under qemu/qemudoor (W4TEST's
      `pla()` aborted); not reproduced on purpose yet. Likely fix: drain
      RBR through the in-band decoder before clearing the FIFO.
- [ ] **Measure idle CPU**: confirm the `HLT` / INT 2Fh idling keeps host
      CPU low while a door waits for input, in both emulators.
- [ ] **Report the DOSBox-X bug** upstream: `~CNullModem` never calls
      `FlushBuffer()`, dropping up to 256 bytes of output on exit (we work
      around it with a two-tick delay in `uart_close`).

## WWIV 4 chain emulation (WWIV4CHN)

`tools/wwiv4chn` runs WWIV 3.x/4.x chains on WWIVFOSS. Reference: the WWIV
4.24 source (EXTRN.C/RETURN.C `newintr1`, RETURN.C `funcs[]` and `init_r`,
SKELETON.C, VARDEC.H `EFLAG_*`); 4.07-4.30 are in wwiv-private. The chain
interface is the same from 4.24 through 4.30 (the last release): same
function table and entry code, same EFLAG bits; 4.30 only added the 2Ch
idle. WWIV Software Services owns the WWIV 4 copyright, so its code
can be reused here.

- [x] **DOS intercepts**: INT 21h console I/O (01h 02h 06h 07h 08h 09h
      0Ah 0Bh 0Ch, 3Fh/40h on the console) and INT 29h go to the FOSSIL;
      hang-up ends the chain; CHAIN.TXT Unix paths (lines 17, 18) point at
      T:\. Food Fight 2.00c (a WWIV 3 chain) runs under DOSBox-X and QEMU.
- [x] **WWIV 4.30's `outchr()`**: heart codes, ^O^O<letter> user fields
      (the ones CHAIN.TXT has: N R I A X g L S; the rest print empty, ^O^O!
      pauses), tabs to 8 columns, ANSI passed through and followed for the
      color and column; `nl()` goes back to color 0 after `ansic()`.
- [x] **Idle on 2Ch (get time)**: with no key waiting, a FOSSIL status
      poll first, so WWIVFOSS idles as for any polling door.
- [x] **Hang-up details**: 01h returns ^C, 0Ah returns `EXIT\r`, 3Fh
      returns 0 bytes.
- [x] **Callable BBS functions** (WWIV 4.07+ chains, SKELETON.C style):
      `BBS=WWIV v4.30`, `WWIV_FP=SSSS:OOOO`, and INT 6Ah for 4.07-4.20;
      all 18 functions in slots 0-19, ported from RETURN.C (slot 10, inkey,
      returns empty() as WWIV 4 did). Entries (`api.asm`) take Turbo C
      `far interrupt` calls and switch to WWIV4CHN's own stack.
- [x] **Hang-up handler (slot 20)**: the next console call returns into
      it; 4Ch after 36 ticks or what the chain stores there (up to 500).
      A chain that only calls the table is ended 10 s after the hang-up.
- [x] **Tests**: `scripts/test.sh EMU door:w4test` runs W4TEST
      (`tools/wwiv4chn/w4test`, our own large-model chain calling every
      function as Turbo C did, and the DOS calls) through a scripted
      conversation (`DOOR_SCRIPT`), and checks that its hang-up handler ran.
- [ ] **Paging**: WWIV 4 paused each screenful when the user had "pause
      on screen" on. WWIV 5 doesn't pass that setting in CHAIN.TXT; add it
      (or a WWIV4CHN option) if a chain needs it.
- [ ] **Abort keys in DOS output**: WWIV 4 checked only the local keyboard
      (`checka2()`, INT 16h) for ^C and ^S during DOS output; callers
      could abort only where a chain used `checka()`/`pla()` (done). An
      option to let callers ^C out of DOS output, if wanted.
- [x] **Food Fight 2.00c** as `tests/doors/foodfite2.sh` (local only:
      not downloadable; `FOODFITE2_DIR`, default /wwiv/doors/foodfite2).
- [ ] **More tests**: real WWIV 4.07+ chains that use the table.

## Packaging

- [ ] **First release**: version tag, and a CI-built zip with WWIVFOSS.EXE,
      FOSTEST.EXE, README, docs and configs.

## Later

- [ ] **Shrink the resident footprint** from 37 KB to ~6.5 KB (0 KB
      conventional with UMBs): `docs/todo-shrink.md`.
- [ ] **dosemu2** support and tests (needs its PPA on Debian).
- [ ] **OS/2 pipe transport**: port the old `wwiv/dos/wwivfoss` pipe code
      into the new backend, then remove `dos/wwivfoss` from the wwiv repo.
- [ ] **NTVDM VDD transport** for 32-bit Windows and NTVDMx64 (`vdd/`).
- [ ] **QEMU upstream**: revive the 2020 `modemctl` chardev patch so DCD
      follows the socket, for doors that read the UART directly.
