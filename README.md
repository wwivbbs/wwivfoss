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

Status: **early development.** The `uart` transport and FOSSIL dispatcher
work under QEMU and DOSBox-X (see Testing). Carrier loss is detected under
DOSBox-X; QEMU needs the planned in-band control mode. See `docs/design.md`.

## Usage

```
WWIVFOSS [options] COMMAND [ARGS...]

  -P#   COM port for the uart transport (1-4, default 1)
  -T?   Transport: U=uart (default), V=vdd, O=OS/2 pipe
  -N#   Node number (used by the vdd and pipe transports)
  -C    Force carrier detect on (for emulators that don't drive DCD)
  -I0   Disable idle/timeslice release while doors poll
  -?    Help
```

Example (inside DOSBox-X or QEMU):

```
WWIVFOSS -P1 C:\DOORS\LORD\START.BAT 1
```

## Building

Requires [Open Watcom v2](https://github.com/open-watcom/open-watcom-v2).
`scripts/setup-dev.sh` downloads it (and a FreeDOS boot floppy) into
`.devenv/`; on an arm64 Linux host the x64 tools run under Rosetta or
qemu-user.

```
scripts/setup-dev.sh
scripts/build.sh
```

## Testing

`scripts/test.sh` runs `WWIVFOSS -P1 FOSTEST` in an emulator whose COM1 is
connected to a socket, with `scripts/bbs.py` playing the BBS.

```
sudo apt-get install -y qemu-system-x86 mtools dosbox-x python3
scripts/test.sh all              # qemu and dosbox, echo and hangup
scripts/test.sh dosbox hangup    # one combination
```

`scripts/shell.sh` boots an interactive FreeDOS shell in QEMU with the latest
build on A: and COM1 on `localhost:2323`.

## Layout

```
include/        FOSSIL constants and the host <-> DOS protocol header
dos/            The driver/runner (WWIVFOSS.EXE)
tools/fostest/  FOSTEST.EXE, a FOSSIL exerciser used as a test door
vdd/            Win32 NTVDM Virtual Device Driver (planned)
configs/        Emulator templates (DOSBox-X, QEMU)
scripts/        Dev environment, build, test harness, FreeDOS shell
docs/           Design notes
```
