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
        (default; what WWIV's "WWIVFOSS (Socket Port)" mode speaks, needed
        for QEMU). -E- turns it off for a raw stream: DOSBox-X through
        dosdoor.sh, a real modem, telnet/nc
  -H#   With -E: expect a heartbeat (FF 03) from the BBS every # seconds;
        3 missed heartbeats count as a hangup. Off by default; use -H10
        with WWIV's "WWIVFOSS (Socket Port)" mode
  -C    Force carrier detect on
  -T?   Transport: U=uart (default), V=vdd, O=OS/2 pipe
  -N#   Node number (used by the vdd and pipe transports)
  -I0   Disable idle/timeslice release while doors poll
  -?    Help
```

Examples:

```
WWIVFOSS -P1 -E- C:\DOORS\LORD\START.BAT 1  DOSBox-X, one door
WWIVFOSS -P1 -H10 C:\DOORS\LORD\LORD.EXE    QEMU, one door
WWIVFOSS -L -P1 -E-                          resident, for a DOS BBS
```

`-U` refuses to unload if another program hooked INT 14h or the UART IRQ
after WWIVFOSS loaded, and leaves the memory allocated if any other vector
still points into it.

Carrier: under DOSBox-X, DCD follows the TCP connection, so the BBS just
closes the socket when the caller hangs up; run WWIVFOSS with `-E-` there.
QEMU never drops DCD, so the default in-band line control (`-E`, with
heartbeats) carries carrier and DTR instead. See `include/foss_protocol.h`.

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
scripts/setup-dev.sh     # Open Watcom v2, FreeDOS boot floppy, base C: disk
scripts/build.sh         # dos/wwivfoss.exe, tools/fostest/fostest.exe,
                         # tools/wwiv4chn/wwiv4chn.exe, .../w4test/w4test.exe
```

### 3. Run the tests

`scripts/test.sh` runs WWIVFOSS in an emulator whose COM1 is connected to a
TCP socket, with `scripts/bbs.py` playing the BBS on the other end.

```
scripts/test.sh all      # FOSTEST matrix: 19 runs, ~6 minutes (what CI runs)
scripts/test.sh doors    # every real door: 51 runs, ~35 minutes
```

`all` covers echo, hangup, DTR hangup and the FOSSIL self-tests (local
functions, peek, purge, all 256 byte values, keyboard) under QEMU (`-E`
in-band line control) and DOSBox-X, each with WWIVFOSS as a runner and as a
resident TSR (`-L` then `-U`), plus a two-calls test (resident under QEMU:
call, hang up, call again) proving the port recovers after a hangup, and
heartbeat tests (`-H`): a BBS that goes silent gets the caller dropped, an
idle caller with heartbeats running doesn't.

`doors` runs each definition in `tests/doors/` under both emulators and both
modes, and through `configs/wwiv/dosdoor.sh` exactly as a WWIV chain runs
it, once for each exec mode (`dosdoor`: "WWIVFOSS (Socket Port)", in-band
with heartbeats; `dosdoor-raw`: "Listen Socket Port", `dosdoor.sh -r`) and
through `configs/wwiv/qemudoor.sh` (`qemudoor`), with drop files in a node
temp directory mounted as T:): Global War,
LORD 4.06 (also with stray input at startup), OpenDoors' VOTEDOS,
DoorDriver's Jungle, Food Fight 4.6, and a Zmodem round trip through FDSZ.
Each run checks the door's output arrives, that it notices the hangup and
exits, and (via `WWIVFOSS -S` call counts) that it really used the FOSSIL.
Doors are downloaded from a BBS archive mirror into `.devenv/` on first use;
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
latest build on A:, a persistent hard disk as C:, and COM1 on
`localhost:2323` (connect with `nc localhost 2323` to be the caller).

```
scripts/shell.sh                 # FreeDOS prompt
scripts/shell.sh --door lord     # ...with LORD copied to C:\LORD, ready to run
```

`--door NAME` copies a door the tests have prepared (run
`scripts/test.sh dosbox door:NAME` once first) along with its drop file and
configuration, and prints the command to start it. Type `QUIT` in DOS to
power off.

### Disk images

The DOS hard disks are ordinary raw images with an MBR and one FAT16
partition starting at **byte offset 32256** (sector 63):

| Image | Used by |
|---|---|
| `.devenv/freedos/c.img` | pristine 32 MB base, made by `scripts/setup-dev.sh` (`scripts/mkdisk.py`) |
| `.devenv/shell-c.img` | `scripts/shell.sh`'s C:, kept between runs (`FRESH=1` resets it) |
| `.devenv/test/qemu-*/c.img` | each QEMU door test's C:, a fresh copy of the base (`KEEP=1` keeps it) |

Copy files in and out with mtools (no root needed), always with QEMU
stopped, since two writers corrupt the file system:

```
mdir  -i .devenv/shell-c.img@@32256 ::/                 # list
mdir  -i .devenv/shell-c.img@@32256 ::/LORD             # list a directory
mcopy -i .devenv/shell-c.img@@32256 mydoor.zip ::/      # copy in
mcopy -s -i .devenv/shell-c.img@@32256 mydoor ::/       # copy a directory in
mcopy -i .devenv/shell-c.img@@32256 ::/LORD/LORD.DAT .  # copy out
mmd   -i .devenv/shell-c.img@@32256 ::/NEWDIR           # make a directory
mdel  -i .devenv/shell-c.img@@32256 ::/OLD.TXT          # delete
```

Or mount it as a regular file system (needs root):

```
sudo mount -o loop,offset=32256,uid=$(id -u),gid=$(id -g) .devenv/shell-c.img /mnt
cp -r mydoor /mnt/           # ...work with /mnt as usual...
sudo umount /mnt
```

`scripts/mkdisk.py IMAGE [SIZE_MB]` makes a new empty disk (up to 504 MB).

### With WWIV

**Sysop guide: [docs/wwiv.md](docs/wwiv.md)**: installing, adding doors as
WWIV chains, per-door recipes (LORD, Global War, Food Fight, OpenDoors and
DoorDriver doors), troubleshooting, and QEMU.

`configs/wwiv/dosdoor.sh` runs a DOS door under DOSBox-X with WWIVFOSS from
a WWIV chain whose exec mode is "WWIVFOSS (Socket Port)" (or, with `-r`,
"Listen Socket Port"), and `configs/wwiv/qemudoor.sh` does the same under
QEMU, for example:

```
/wwiv/doors/dosdoor.sh %Z %I /wwiv/doors/lord LORD.EXE %N /DREW
/wwiv/doors/qemudoor.sh %Z %I /wwiv/doors/lord LORD.EXE %N /DREW
```

`scripts/doortap.py` logs every byte between WWIV and the door: set
`DOSDOOR_DOSBOX` or `QEMUDOOR_QEMU` to it.

`scripts/wwivsess.py` drives a scripted telnet session against a local WWIV
install without wwivd (it starts `bbs -XT` itself), to test doors end to
end. See `scripts/wwivsess.py --help` for an example that logs on and runs
a chain.

## Layout

```
include/        FOSSIL constants and the host <-> DOS protocol header
dos/            The driver/runner (WWIVFOSS.EXE)
tools/fostest/  FOSTEST.EXE, a FOSSIL exerciser used as a test door
tools/wwiv4chn/ WWIV4CHN.EXE, runs WWIV 3/4 chains (DOS console I/O, heart
                codes, WWIV 4's function table) on the FOSSIL; w4test/ is
                its test chain
vdd/            Win32 NTVDM Virtual Device Driver (planned)
configs/        Emulator templates (DOSBox-X, QEMU); wwiv/ has the WWIV
                launchers dosdoor.sh (DOSBox-X) and qemudoor.sh (QEMU)
scripts/        Dev environment, build, test harness, FreeDOS shell,
                WWIV session script
tests/doors/    Real-door test definitions
docs/           Design notes (TODO.md at the root lists what's left)
```
