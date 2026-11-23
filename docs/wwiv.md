# Running DOS doors on WWIV with WWIVFOSS

This guide is for WWIV sysops who want to run classic DOS door games
(LORD, Global War, Food Fight, OpenDoors and DoorDriver doors, ...) on a
WWIV BBS running on Linux. The door runs inside a DOS emulator, and
WWIVFOSS gives it a FOSSIL driver whose serial port is connected back to
the caller through WWIV.

```
caller --telnet--> wwivd --> bbs --listen socket (%Z)--> emulator COM1
                                                          |
                                         WWIVFOSS (FOSSIL, INT 14h)
                                                          |
                                                        the door
```

WWIV opens a local listening socket for the door and passes its port as
`%Z`. The emulator connects its COM1 to that port, WWIVFOSS turns the
door's FOSSIL calls into COM1 traffic, and WWIV passes everything between
the socket and the caller.

## Choose an emulator

| | **DOSBox-X** (recommended) | **QEMU** |
|---|---|---|
| WWIV chain exec mode | "Listen Socket Port" | "WWIVFOSS (Socket Port)" |
| Door files | a normal directory on Linux | a DOS disk image |
| Drop files reach DOS | the node's temp dir is mounted as T: | must be copied into an image |
| Caller hang-up | the emulated carrier (DCD) drops when the socket closes | carried in-band (`WWIVFOSS -E`), with heartbeats |
| Ready-made launcher | `dosdoor.sh` | not yet (see [QEMU](#qemu)) |

Use DOSBox-X unless you have a reason not to. Everything below except the
QEMU section assumes it. Both emulators are tested end to end with every
door in [`tests/doors/`](../tests/doors).

## Install

1. Install DOSBox-X:

   ```
   sudo apt-get install -y dosbox-x
   ```

2. Put `WWIVFOSS.EXE` and `dosdoor.sh` together in your doors directory,
   for example `/wwiv/doors`:

   ```
   cp dos/wwivfoss.exe /wwiv/doors/WWIVFOSS.EXE
   cp configs/wwiv/dosdoor.sh /wwiv/doors/dosdoor.sh
   chmod +x /wwiv/doors/dosdoor.sh
   ```

   `dosdoor.sh` mounts its own directory as W: and runs `W:\WWIVFOSS.EXE`,
   so the two must stay side by side. It runs WWIVFOSS with `-E-`: the
   DOSBox-X path is a raw stream (DOSBox-X drops carrier itself, and WWIV
   doesn't escape `FF` bytes in "Listen Socket Port" mode), while WWIVFOSS
   defaults to the in-band line control that QEMU needs.

## Add a door

### 1. Unpack the door

Unpack each door into its own directory, e.g. `/wwiv/doors/lord`. Some doors
ship as a self-extracting archive; run it once in DOSBox-X to unpack it
(Global War: `GW.EXE -y`).

### 2. Configure the door

Every door needs three things set in its own configuration:

- **Use a FOSSIL driver**, not its built-in serial (UART) code. Many doors
  default to the UART. Under an emulator the UART code may even seem to
  work, but it bypasses WWIVFOSS.
- **COM port 1** (FOSSIL port 0), usually read from the drop file.
- **Where the drop file is: `T:\`**. WWIV writes the drop files into the
  node's temp directory (`%I`), which `dosdoor.sh` mounts as T:. If a door
  can only read its drop file from its own directory, see
  [Doors that read drop files from their own directory](#doors-that-read-drop-files-from-their-own-directory).

WWIV writes all the common drop files for every chain:

| File | Format |
|---|---|
| `CHAIN.TXT` | WWIV |
| `DOOR.SYS` | 52-line DOOR.SYS |
| `DORINFO1.DEF` | RBBS/QuickBBS |
| `DOOR32.SYS` | DOOR32 |
| `CALLINFO.BBS` | Wildcat 2.x |
| `PCBOARD.SYS` | PCBoard |

On Linux WWIV writes them with LF line endings
([wwivbbs/wwiv#1738](https://github.com/wwivbbs/wwiv/issues/1738)); DOS
doors need CR LF. `dosdoor.sh` converts them before starting the door.

See [Door recipes](#door-recipes) for doors we've tested.

### 3. Add the chain

From the BBS doors menu (`.`), press `*` for ChainEdit (or use the sysop
`CE` command), add a chain, and set:

| Field | Value |
|---|---|
| A) Description | what callers see, e.g. `Legend of the Red Dragon` |
| B) Filename | `/wwiv/doors/dosdoor.sh %Z %I /wwiv/doors/lord LORD.EXE %N /DREW` |
| E) Exec Mode | **Listen Socket Port** |
| H) Multi user | Yes only if the door supports several nodes at once |

The Filename is the command line: `dosdoor.sh PORT TEMPDIR DOORDIR
COMMAND...`. `%Z` is the listening port and `%I` the node's temp directory;
everything after the door directory is the DOS command, run from `C:\`
(the door directory). ChainEdit lists all the macros when you edit the
Filename, for example `%N` (node number). Inside DOS the drop files are on
T:, so pass `T:\CHAIN.TXT` rather than `%C` (which is the Linux path).

The Filename holds at most 79 characters. If a command line doesn't fit,
use shorter paths (a symlink such as `/d` for `/wwiv/doors`) or put the DOS
command in a batch file in the door directory.

## Door recipes

Tested with WWIV's drop files through `dosdoor.sh`
(`scripts/test.sh dosdoor door:NAME`).

### Legend of the Red Dragon 4.06

LORD keeps per-node settings in `NODE<n>.DAT`, a text file (LORDCFG's
"Configure Nodes" writes it). For each node, set:

```
BBSTYPE WWIV
FOSSIL
BBSDROP T:\
```

(`BBSTYPE WWIV` reads `CHAIN.TXT`; `FOSSIL` replaces the default
`;FOSSIL`, which means "internal COM routines".)

Filename: `/wwiv/doors/dosdoor.sh %Z %I /wwiv/doors/lord LORD.EXE %N /DREW`

LORD refuses to start without `/DREW`, which its `START.BAT` normally adds.

### Global War 2.7

Set line 9 of `WAR.CFG` (comm driver) to `F` (FOSSIL); the default `U`
drives the UART directly. Global War reads `CHAIN.TXT` given with `/W`:

Filename: `/wwiv/doors/dosdoor.sh %Z %I /wwiv/doors/gw WAR.EXE /W T:\CHAIN.TXT`

### Food Fight 4.6

In `FOODFITE.CFG`, line 1 is the drop file's full path and line 17 the
port: set them to `T:\DOOR.SYS` and `PORT:F:1` (FOSSIL, port 1).

Filename: `/wwiv/doors/dosdoor.sh %Z %I /wwiv/doors/foodfite FOODFITE.EXE FOODFITE.CFG`

### OpenDoors doors

OpenDoors-based doors read `DOOR.CFG`. Set the drop file directory with
`BBSDir T:\` (remove the `;` in front of it). OpenDoors uses a FOSSIL
automatically when one is loaded.

Example (VOTEDOS from the OpenDoors 6.00 kit):
`/wwiv/doors/dosdoor.sh %Z %I /wwiv/doors/votedos VOTEDOS.EXE`

### Doors that read drop files from their own directory

Some doors (for example DoorDriver doors such as Jungle) only look in their
current directory. Give them a small batch file in the door directory that
copies the drop file in first, and run that:

```
@echo off
copy T:\DORINFO1.DEF . > NUL
JUNGLE.EXE
```

Filename: `/wwiv/doors/dosdoor.sh %Z %I /wwiv/doors/jungle JUNGLE.BAT`

The copy picks up the CR LF version, since `dosdoor.sh` converts the files
in T: before DOS starts.

## Troubleshooting

Set `DOSDOOR_LOG` in the environment wwivd runs in (for example in its
systemd unit) to a directory, and `dosdoor.sh` saves the drop files exactly
as the door saw them, the generated DOSBox-X config, and DOSBox-X's output
(`dosbox.log`). `DOSDOOR_FLAGS=-ST:\STATS.TXT` makes WWIVFOSS write its
FOSSIL call counts to the node temp directory when the door exits.

| Symptom | Likely cause |
|---|---|
| "Please wait..." and straight back to the menu | The door exited at once. Check the drop file path (T:\), the door's FOSSIL setting, and `dosbox.log`: `BIOS INT14: Unhandled call ... DX=ffff` means the door asked for port -1 (it couldn't read the COM port from the drop file). |
| The door runs but the caller sees nothing | The door uses its own UART code instead of the FOSSIL, or a different COM port. With `DOSDOOR_FLAGS=-S...`, a STATS.TXT showing no `01`/`0B`/`19` (transmit) calls confirms it. |
| Garbage or a skipped prompt as the door starts | The Enter typed after picking the door is forwarded to it ([#1737](https://github.com/wwivbbs/wwiv/issues/1737)). Mostly harmless. |
| Typing feels laggy, transfers are slow | WWIV's socket bridge polls every 100 ms ([#1736](https://github.com/wwivbbs/wwiv/issues/1736)). |
| A caller who drops loses progress | With "Listen Socket Port", WWIV kills the emulator the moment the caller hangs up, before the door can save ([#1735](https://github.com/wwivbbs/wwiv/issues/1735)). Ask callers to quit doors normally until that's fixed. |

`DOSDOOR_ECHO=1` echoes the commands on the DOSBox-X screen. Leave it off
in production: with echo on, DOSBox-X services the serial port late enough
to lose incoming data during fast transfers.

## QEMU

QEMU runs DOS faster than DOSBox-X but holds DCD high when the socket
closes, so a door can't see a hang-up on its own. WWIV's
**"WWIVFOSS (Socket Port)"** exec mode solves that: like "Listen Socket
Port" (WWIV listens on `%Z` and QEMU connects COM1 to it), but carrier and
DTR travel in the byte stream:

- WWIV sends `FF 03` (DTR up) first, then heartbeats every
  `WWIVFOSS_HEARTBEAT` seconds (`wwiv.ini`, default 10), and `FF 01` when
  the caller hangs up, giving the door 10 seconds to exit.
- A door that lowers DTR returns the caller to the BBS.

Run the door with `WWIVFOSS -H10`: in-band line control (`-E`) is the
default, and `-H10` tells WWIVFOSS to expect WWIV's heartbeats (it's off by
default, since without a BBS sending them it would drop every caller after
30 seconds). `-H` must be at least `WWIVFOSS_HEARTBEAT`.
WWIVFOSS then reports a hang-up to the door both through FOSSIL status and
by switching the UART into loopback so doors that read the UART directly
(Food Fight, for one) see carrier drop. Three missed heartbeats count as a
hang-up too, so the door notices if WWIV dies. The protocol is in
[`include/foss_protocol.h`](../include/foss_protocol.h).

QEMU's COM1 is a socket, either way round:

- **Connecting to WWIV** (what WWIV chains need):
  `-chardev socket,id=bbs,host=127.0.0.1,port=%Z -serial chardev:bbs`
- **Listening** (`server=on`), for testing a door by hand
  (`scripts/shell.sh` does this; connect with `nc localhost 2323`) or for
  software that connects out to the door. WWIV chains always listen
  themselves, so this isn't used with WWIV.

What's missing is a ready-made launcher like `dosdoor.sh`. One would boot
FreeDOS, attach the door's disk image (`scripts/mkdisk.py` makes one; see
"Disk images" in the README for copying files in and out), copy the node's
drop files from `%I` into a small image for DOS, and run `WWIVFOSS -P1 -H10`
with the door. Keep in mind a disk image can only be used by one QEMU at a
time, so a door shared by several nodes needs one image per node or `Multi
user` off. See `scripts/test.sh` (QEMU door runs) for a working example of
all the pieces.

You can also run a classic FOSSIL (BNU, X00) under either emulator. It
works for play, but under QEMU it never sees a hang-up. Likewise WWIVFOSS
with `-E-`, under QEMU, behaves like a classic FOSSIL.

## Status of WWIV's side

| Issue | State |
|---|---|
| [#1752](https://github.com/wwivbbs/wwiv/issues/1752) in-band line control, [#1753](https://github.com/wwivbbs/wwiv/issues/1753) heartbeats | Implemented as "WWIVFOSS (Socket Port)" (commits 699e771, fcd9072) |
| [#1735](https://github.com/wwivbbs/wwiv/issues/1735) doors killed on hang-up | Fixed for "WWIVFOSS (Socket Port)" (10 s grace); "Listen Socket Port" still kills at once |
| [#1736](https://github.com/wwivbbs/wwiv/issues/1736) bridge latency | Open |
| [#1737](https://github.com/wwivbbs/wwiv/issues/1737) leftover input forwarded to doors | Open |
| [#1738](https://github.com/wwivbbs/wwiv/issues/1738) LF drop files | Open; `dosdoor.sh` works around it |
