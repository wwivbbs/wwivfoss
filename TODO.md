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
      from a WWIV `SOCK_PORT` chain; converts WWIV's LF drop files to CR LF;
      `DOSDOOR_LOG` for troubleshooting.
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
- [ ] `-I0` (no idling) still stalls with a stray byte at door start (RX
      overrun logged by DOSBox-X).
- [ ] Sysop guide (`docs/wwiv.md`): chain settings, `dosdoor.sh`, per-door
      setup (drop file on T:, FOSSIL on), troubleshooting.
- WWIV issues filed: wwivbbs/wwiv#1735 (doors SIGKILLed on hangup), #1736
  (bridge latency/throughput), #1737 (leftover input forwarded to doors),
  #1738 (LF drop files on Linux).

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
- [ ] **`-E` framing on the BBS side** for QEMU: double FF to the door,
      decode `FF nn` from it, send `FF 00` when the caller drops, hang up
      the caller on `FF 01`. DOSBox-X only needs the socket closed.
- [ ] **Ship WWIVFOSS** with WWIV the way `NETF125.ZIP` is shipped today.
- [ ] **Remove SyncFoss** (`exec_cmdline_sync`, sbbsexec files) once the new
      driver covers its users; keep the "FOSSIL" exec mode name working.

## Robustness

- [ ] **Heartbeat (`-H#`)** for QEMU: the BBS sends `FF 03` periodically and
      WWIVFOSS drops carrier if nothing arrives for a few periods, covering a
      BBS that dies without sending `FF 00`. Test by killing the harness.
- [ ] **Measure idle CPU**: confirm the `HLT` / INT 2Fh idling keeps host
      CPU low while a door waits for input, in both emulators.
- [ ] **Report the DOSBox-X bug** upstream: `~CNullModem` never calls
      `FlushBuffer()`, dropping up to 256 bytes of output on exit (we work
      around it with a two-tick delay in `uart_close`).

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
