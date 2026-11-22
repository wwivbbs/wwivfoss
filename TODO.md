# TODO

What's left before WWIVFOSS is ready for real use with QEMU and DOSBox-X,
roughly in the order it should be done. See `docs/design.md` for the
architecture and `docs/todo-shrink.md` for the resident-size plan.

Done so far: FOSSIL rev 5 dispatcher, uart transport with interrupt-driven
rings, runner and resident (`-L`/`-U`) modes, in-band line control (`-E`),
DCD carrier on DOSBox-X, and an emulator test matrix (QEMU and DOSBox-X ×
runner and resident × echo/hangup/dtr) that runs in CI.

## Harden the driver (testable today)

- [ ] **Extend FOSTEST** to exercise the functions nothing tests yet: peek
      (0Ch), block read (18h), keyboard (0Dh/0Eh), cursor and video
      (11h–15h), flow control (0Fh), purge (09h/0Ah), and 1Bh buffer
      free counts. Add matching scenarios to `scripts/test.sh`.
- [ ] **8-bit clean test**: send all 256 byte values in both directions,
      with and without `-E` (FF escaping is the risky part).
- [ ] **File transfer test**: a real Zmodem transfer (e.g. DSZ) through the
      FOSSIL, under both emulators.
- [ ] **Real doors**: try a handful covering the common door libraries
      (OpenDoors, DoorDriver/RAD, LORD, TW2002) and fix what they expose.

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
