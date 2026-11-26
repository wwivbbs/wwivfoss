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
| WWIV chain exec mode | "WWIVFOSS (Socket Port)" (or "Listen Socket Port" with `dosdoor.sh -r`) | "WWIVFOSS (Socket Port)" |
| Door files | a normal directory on Linux | a normal directory, copied onto a disk image for each call and changes copied back |
| Drop files reach DOS | the node's temp dir is mounted as T: | copied onto a floppy shown as T: |
| Nodes in one door at once | as many as the door supports | one (others are told it's in use) |
| Caller hang-up | in-band, and DCD drops when the socket closes | in-band only (`WWIVFOSS -E`), with heartbeats |
| Ready-made launcher | `dosdoor.sh` | `qemudoor.sh` (see [QEMU](#qemu)) |

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
   so the two must stay side by side. Update them together.

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

DOS doors need CR LF line endings. WWIV writes them that way since 5.10
build 3814 ([wwivbbs/wwiv#1738](https://github.com/wwivbbs/wwiv/issues/1738));
`DOOR32.SYS`, which only 32-bit doors read, keeps the platform's line
endings. Older WWIV on Linux writes LF: uncomment the conversion in
`dosdoor.sh` (and `qemudoor.sh`), or doors like LORD can't read their drop
file.

See [Door recipes](#door-recipes) for doors we've tested.

### 3. Add the chain

From the BBS doors menu (`.`), press `*` for ChainEdit (or use the sysop
`CE` command), add a chain, and set:

| Field | Value |
|---|---|
| A) Description | what callers see, e.g. `Legend of the Red Dragon` |
| B) Filename | `/wwiv/doors/dosdoor.sh %Z %I /wwiv/doors/lord LORD.EXE %N /DREW` |
| E) Exec Mode | **WWIVFOSS (Socket Port)** |
| H) Multi user | Yes only if the door supports several nodes at once |

**Match the exec mode and `dosdoor.sh`:**

| Exec mode | Filename starts | What WWIV sends the door |
|---|---|---|
| **WWIVFOSS (Socket Port)** (recommended) | `dosdoor.sh %Z ...` | `FF` escaped, line state and a heartbeat (`FF 03`) every 10 s mixed in; on hang-up the door is told in-band and gets `DOOR_EXIT_GRACE` seconds (wwiv.ini, default 10) to exit |
| Listen Socket Port | `dosdoor.sh -r %Z ...` | a plain byte stream; on hang-up WWIV closes the socket (DOSBox-X drops carrier) and the door gets `DOOR_EXIT_GRACE` seconds to exit ([#1735](https://github.com/wwivbbs/wwiv/issues/1735); before 5.10 build 3815 WWIV kills the emulator at once) |

Use "Listen Socket Port" with `-r` (or `--raw`) only on WWIV versions
without the WWIVFOSS mode (5.9 and older). Mixing them up breaks things:
without `-r`, a raw stream's `FF` bytes are taken as line state (a stray
hang-up); with `-r`, the WWIVFOSS mode's heartbeats reach the door as data,
and `03` is Ctrl-C.

The Filename is the command line: `dosdoor.sh PORT TEMPDIR DOORDIR
COMMAND...`. `%Z` is the listening port and `%I` the node's temp directory;
everything after the door directory is the DOS command, run from `C:\`
(the door directory). ChainEdit lists all the macros when you edit the
Filename, for example `%N` (node number). Inside DOS the drop files are on
T:, so pass `T:\CHAIN.TXT` rather than `%C` (which is the Linux path).

The Filename holds at most 79 characters (160 once WWIV
[#1764](https://github.com/wwivbbs/wwiv/pull/1764) is merged). If a command
line doesn't fit,
use shorter paths (a symlink such as `/d` for `/wwiv/doors`) or put the DOS
command in a batch file in the door directory.

## Door recipes

Tested with WWIV-style drop files through `dosdoor.sh` in both modes
(`scripts/test.sh dosdoor door:NAME` and `dosdoor-raw door:NAME`). The
command lines below are for "WWIVFOSS (Socket Port)"; add `-r` after
`dosdoor.sh` for "Listen Socket Port".

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

### WWIV 3 and 4 chains (Food Fight 2.00c)

Chains written for WWIV 3.x and 4.x (`.CHN` or `.COM` files, often Turbo
Pascal 3) don't use a FOSSIL: WWIV ran them with "DOS interrupts" on and
sent their DOS console I/O to the modem, and they color their text with
WWIV heart codes (^C0-^C9). Run them under `WWIV4CHN.EXE`
(`tools/wwiv4chn`, built by `scripts/build.sh`), which does WWIV's part on
WWIVFOSS:

- DOS console output goes to the caller through WWIV 4.30's output code:
  heart codes become ANSI colors (WWIV's default colors), ^O^O codes print
  the caller's name and the other user fields `CHAIN.TXT` has, tabs
  expand, and ^L clears the screen. When `CHAIN.TXT` says the caller has
  no ANSI (line 14 is `0`), heart codes are dropped instead.
- DOS console input comes from the caller, and "is a key waiting?" calls
  answer truthfully.
- Chains for WWIV 4.07 and later that call the BBS's functions (`outstr`,
  `input`, `yn`, `inli` and the rest, found through `WWIV_FP` or INT 6Ah
  as in WWIV's SKELETON.C) get a working table of them.
- When the caller hangs up, the chain's next console call ends it, or runs
  the chain's hang-up handler if it set one, as under WWIV 4.
- If an argument is a file named `CHAIN.TXT`, its gfiles and data
  directory lines (17, 18) are pointed at that file's directory (T:\) when
  they hold Unix paths: WWIV 4 chains write there (Food Fight writes its
  sysop log).

Put `WWIV4CHN.EXE` next to `dosdoor.sh`/`qemudoor.sh` (both put their own
directory on the DOS PATH), use the "WWIVFOSS (Socket Port)" exec mode, and
pass the chain `CHAIN.TXT` the way WWIV 4 did:

Filename: `/wwiv/doors/dosdoor.sh %Z %I /wwiv/doors/foodfite2 WWIV4CHN.EXE FOODFITE.COM T:\CHAIN.TXT`

The same with `qemudoor.sh` runs it under QEMU. Only programs that use DOS
for the screen and keyboard work, which was also true under WWIV 4.

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

WWIV writes `DORINFO1.DEF` with CR LF, so the copy is ready to use (on
older WWIV, see [the note on line endings](#2-configure-the-door)).

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
| Garbage or a skipped prompt as the door starts | WWIV before 5.10 build 3812 forwards the Enter typed after picking the door to it ([#1737](https://github.com/wwivbbs/wwiv/issues/1737)). Mostly harmless. |
| Typing feels laggy, transfers are slow | WWIV's socket bridge polls every 100 ms ([#1736](https://github.com/wwivbbs/wwiv/issues/1736)). |
| A caller who drops loses progress | The door didn't exit within `DOOR_EXIT_GRACE` seconds (wwiv.ini, default 10), and WWIV stopped it; raise it for doors that save slowly. WWIV before 5.10 build 3815 kills a "Listen Socket Port" door the moment the caller hangs up ([#1735](https://github.com/wwivbbs/wwiv/issues/1735)); use "WWIVFOSS (Socket Port)" there. Under QEMU, "Listen Socket Port" doors never see the hang-up, so they're always stopped. |
| The door acts as if Ctrl-C or stray keys were pressed every 10 seconds | `dosdoor.sh -r` with the "WWIVFOSS (Socket Port)" mode: drop the `-r`. |
| Random hang-ups, or garbage after a `ÿ` (character 255) | "Listen Socket Port" without `-r`: add `-r`, or switch the chain to "WWIVFOSS (Socket Port)". |

To see exactly what WWIV and the door send each other, set
`DOSDOOR_DOSBOX` (or `QEMUDOOR_QEMU`) to
[`scripts/doortap.py`](../scripts/doortap.py) in wwivd's environment. It
sits between the two and logs every byte both ways with timestamps (to
`DOORTAP_LOG`, default `/tmp/doortap-<pid>.log`): heartbeats show as
`ff 03`, and a hang-up as a 0-byte read.

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

### qemudoor.sh

`configs/wwiv/qemudoor.sh` is the QEMU launcher. It takes the same
arguments as `dosdoor.sh`, and the door sees the same drives (C: the door,
T: the drop files), so a door set up for one works with the other.

1. Install QEMU and mtools:

   ```
   sudo apt-get install -y qemu-system-x86 mtools
   ```

2. Put `qemudoor.sh` next to `WWIVFOSS.EXE`, with its two disk images from
   `scripts/setup-dev.sh`: a FreeDOS boot floppy with SWSUBST (which maps
   T:), and an empty 32 MB hard disk.

   ```
   cp configs/wwiv/qemudoor.sh /wwiv/doors/
   cp .devenv/freedos/qemudoor-boot.img /wwiv/doors/
   cp .devenv/freedos/c.img /wwiv/doors/qemudoor-c.img
   ```

3. Add the chain with exec mode **WWIVFOSS (Socket Port)** and Multi user
   **No**:

   ```
   /wwiv/doors/qemudoor.sh %Z %I /wwiv/doors/lord LORD.EXE %N /DREW
   ```

For each call, `qemudoor.sh` copies the door's directory onto a fresh copy
of the empty disk (C:) and the drop files onto a floppy (B:, mapped to T:),
boots FreeDOS, and runs `WWIVFOSS -P1 -E -H10` with the door. When QEMU
exits, files the door created or changed are copied back into the door's
directory, and changed drop files into `%I`. That happens even when WWIV
kills the launcher on hang-up. Files the door deleted stay on Linux.

Because of that copy back, only one node can be in a door at a time. Set
the chain's Multi user to **No** and WWIV enforces that itself: a second
caller is told the chain is in use on another instance. WWIV checks per
chain, though, so `qemudoor.sh` also locks the door directory: if two
chains share it (say the same door under both launchers), the second
caller gets "This door is in use on another node". The door has to fit on
the 32 MB disk. `-r` is accepted for "Listen Socket Port", but under
QEMU the door then never sees a hang-up: WWIV stops QEMU after
`DOOR_EXIT_GRACE` seconds instead (and before 5.10 build 3815, kills it at
once); the door's files are still copied back. `qemudoor.sh --help` lists its environment
variables (`QEMUDOOR_LOG`, `QEMUDOOR_FLAGS`, ...).

You can also run a classic FOSSIL (BNU, X00) under either emulator. It
works for play, but under QEMU it never sees a hang-up. Likewise WWIVFOSS
with `-E-`, under QEMU, behaves like a classic FOSSIL.

## Status of WWIV's side

| Issue | State |
|---|---|
| [#1752](https://github.com/wwivbbs/wwiv/issues/1752) in-band line control, [#1753](https://github.com/wwivbbs/wwiv/issues/1753) heartbeats | Implemented as "WWIVFOSS (Socket Port)" (commits 699e771, fcd9072) |
| [#1735](https://github.com/wwivbbs/wwiv/issues/1735) doors killed on hang-up | Fixed in 5.10 build 3815: every socket door gets `DOOR_EXIT_GRACE` seconds (default 10) to exit, then SIGTERM to its process group |
| [#1736](https://github.com/wwivbbs/wwiv/issues/1736) bridge latency | Open |
| [#1737](https://github.com/wwivbbs/wwiv/issues/1737) leftover input forwarded to doors | Fixed in 5.10 build 3812 (Linux; Windows: [#1775](https://github.com/wwivbbs/wwiv/issues/1775)) |
| [#1738](https://github.com/wwivbbs/wwiv/issues/1738) LF drop files | Fixed in 5.10 build 3814 |
