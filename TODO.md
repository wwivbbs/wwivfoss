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
- [ ] **File transfer test**: a real Zmodem transfer through the FOSSIL,
      under both emulators: FDSZ (the FOSSIL build of DSZ, `fdsz0597.zip`
      in the archive) on the DOS side, lrzsz on the BBS side.
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
  - [ ] Editors: TIDE, OEdit, WWIVEdit (need WWIV editor drop files).
  - [ ] TW2002 1.03 (archive has it; v2 isn't there).

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
