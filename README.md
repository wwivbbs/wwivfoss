# WWIVFOSS

An open source (Apache-2.0) FOSSIL driver for running DOS BBS doors from
modern BBS software, on modern machines.

WWIVFOSS is a small DOS program that installs a FOSSIL revision 5 compatible
INT 14h handler, runs a door, and removes itself when the door exits. The
FOSSIL side talks to the outside world through a pluggable *transport*:

| Transport | Where it runs | How it reaches the BBS |
|-----------|---------------|------------------------|
| `uart`    | QEMU, DOSBox-X, 86Box, dosemu2, real hardware (host: Linux, Windows x64, macOS) | Emulated COM port connected to a TCP socket the BBS listens on |
| `vdd`     | Windows NTVDM (32-bit), NTVDMx64 | BOP into a Win32 Virtual Device Driver DLL (planned) |
| `pipe`    | OS/2 VDM | OS/2 named pipes (planned; replaces the old `wwiv/dos/wwivfoss`) |

The BBS is responsible for the caller's connection (telnet, SSH, ...). It hands
the door a byte stream; WWIVFOSS only has to get those bytes in and out of DOS.

Status: **early development.** The `uart` transport, FOSSIL dispatcher,
runner and resident (`-L`/`-U`) modes pass end-to-end tests under QEMU and
DOSBox-X, including carrier loss and DTR hangup. See `docs/design.md`.

## Usage

```
WWIVFOSS [options] COMMAND [ARGS...]   run a door, then unload
WWIVFOSS -L [options]                  load resident (like BNU/X00)
WWIVFOSS -U                            unload the resident copy

  -P#   COM port for the uart transport (1-4, default 1)
  -E    In-band line control: carrier and DTR travel in the byte stream
        (needed for QEMU; same framing as DOSBox-X's nullmodem)
  -C    Force carrier detect on
  -T?   Transport: U=uart (default), V=vdd, O=OS/2 pipe
  -N#   Node number (used by the vdd and pipe transports)
  -I0   Disable idle/timeslice release while doors poll
  -?    Help
```

Examples:

```
WWIVFOSS -P1 C:\DOORS\LORD\START.BAT 1      DOSBox-X, one door
WWIVFOSS -P1 -E C:\DOORS\LORD\LORD.EXE      QEMU, one door
WWIVFOSS -L -P1                              resident, for a DOS BBS
```

`-U` refuses to unload if another program hooked INT 14h or the UART IRQ
after WWIVFOSS loaded, and leaves the memory allocated if any other vector
still points into it.

Carrier: under DOSBox-X, DCD follows the TCP connection, so the BBS just
closes the socket when the caller hangs up. QEMU never drops DCD, so use
`-E` there and have the BBS send `FF 00` before closing; the door lowering
DTR arrives at the BBS as `FF 01`. See `include/foss_protocol.h`.

## Building and testing

Everything below runs on Linux (Debian/Ubuntu commands shown). On an arm64
host the Open Watcom x64 tools run under Rosetta or qemu-user binfmt.
Every script takes `--help`.

### 1. Install the tools

```
sudo apt-get install -y qemu-system-x86 mtools dosbox-x python3 lrzsz
```

QEMU and mtools run the QEMU tests, DOSBox-X the DOSBox-X tests (and door
setup for both), python3 the BBS side of every test, lrzsz the Zmodem test.

### 2. Fetch the toolchain and build

```
scripts/setup-dev.sh     # Open Watcom v2 + FreeDOS boot floppy into .devenv/
scripts/build.sh         # dos/wwivfoss.exe, tools/fostest/fostest.exe
```

### 3. Run the tests

`scripts/test.sh` runs WWIVFOSS in an emulator whose COM1 is connected to a
TCP socket, with `scripts/bbs.py` playing the BBS on the other end.

```
scripts/test.sh all      # FOSTEST matrix: 14 runs, ~5 minutes (what CI runs)
scripts/test.sh doors    # every real door: 30 runs, ~20 minutes
```

`all` covers echo, hangup, DTR hangup and the FOSSIL self-tests (local
functions, peek, purge, all 256 byte values, keyboard) under QEMU (`-E`
in-band line control) and DOSBox-X, each with WWIVFOSS as a runner and as a
resident TSR (`-L` then `-U`).

`doors` runs each definition in `tests/doors/` under both emulators and both
modes, and once more through `configs/wwiv/dosdoor.sh` exactly as a WWIV
chain runs it (`dosdoor` mode: drop files written with LF line endings in a
node temp directory mounted as T:): Global War, LORD 4.06 (also with stray input at startup), OpenDoors'
VOTEDOS, DoorDriver's Jungle, and a Zmodem round trip through FDSZ. Each
run checks the door's output arrives, that it notices the hangup and exits,
and (via `WWIVFOSS -S` call counts) that it really used the FOSSIL. Doors
are downloaded from a BBS archive mirror into `.devenv/` on first use;
Global War comes from a local install (`WWIVFOSS_DOORS`, default
`/wwiv/doors`) and is skipped if it isn't there. Door binaries are never
committed, and CI runs only `all`.

Single runs and other options:

```
scripts/test.sh qemu dtr resident        # one combination
scripts/test.sh dosbox door:lord         # one door
scripts/test.sh qemu speed               # FOSSIL throughput, prints KB/s
KEEP=1 scripts/test.sh qemu funcs        # keep .devenv/test/ to inspect
scripts/test.sh --help                   # all scenarios, doors and options
```

On failure the test prints what the door sent and its logs, and saves a
screenshot under `.devenv/test/` (QEMU).

### Interactive DOS

`scripts/shell.sh` boots a FreeDOS shell in QEMU in your terminal, with the
latest build on A: and COM1 on `localhost:2323` (connect with
`nc localhost 2323` to be the caller).

### With WWIV

`configs/wwiv/dosdoor.sh` runs a DOS door under DOSBox-X with WWIVFOSS from
a WWIV chain whose exec mode is `SOCK_PORT`, for example:

```
/wwiv/doors/dosdoor.sh %Z %I /wwiv/doors/lord LORD.EXE %N /DREW
```

`scripts/wwivsess.py` drives a scripted telnet session against a local WWIV
install without wwivd (it starts `bbs -XT` itself), to test doors end to
end. See `scripts/wwivsess.py --help` for an example that logs on and runs
a chain.

## Layout

```
include/        FOSSIL constants and the host <-> DOS protocol header
dos/            The driver/runner (WWIVFOSS.EXE)
tools/fostest/  FOSTEST.EXE, a FOSSIL exerciser used as a test door
vdd/            Win32 NTVDM Virtual Device Driver (planned)
configs/        Emulator templates (DOSBox-X, QEMU); wwiv/dosdoor.sh for WWIV
scripts/        Dev environment, build, test harness, FreeDOS shell,
                WWIV session script
tests/doors/    Real-door test definitions
docs/           Design notes (TODO.md at the root lists what's left)
```
