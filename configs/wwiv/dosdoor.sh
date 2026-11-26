#!/usr/bin/env bash
# Runs a DOS door under DOSBox-X with WWIVFOSS for a WWIV chain. WWIV
# listens on a local port (%Z) and DOSBox-X connects its COM1 to it.
#
#   dosdoor.sh [-r|--raw] PORT TEMPDIR DOORDIR COMMAND [ARGS...]
#
# Match the chain's exec mode (ChainEdit, E) Exec Mode):
#
#   "WWIVFOSS (Socket Port)"   (recommended) no option. WWIV escapes FF bytes,
#                              sends line state and heartbeats in-band, and
#                              gives the door time to exit when the caller
#                              hangs up. WWIVFOSS runs with -E -H10.
#   "Listen Socket Port"       -r / --raw. A plain byte stream (also for older
#                              WWIV, or other BBS software). WWIVFOSS runs
#                              with -E-; carrier comes from DOSBox-X dropping
#                              DCD when the socket closes.
#
# Using the wrong one breaks things: without -r on a raw stream, an FF byte
# from the caller is taken as line state (a stray hang-up); with -r on the
# WWIVFOSS mode, its heartbeats (FF 03) reach the door as data (03 is
# Ctrl-C).
#
# Example chain command lines:
#
#   /wwiv/doors/dosdoor.sh %Z %I /wwiv/doors/lord LORD.EXE %N /DREW
#   /wwiv/doors/dosdoor.sh -r %Z %I /wwiv/doors/lord LORD.EXE %N /DREW
#
# Inside DOS:
#   C:  the door's directory (DOORDIR); COMMAND runs from C:\
#   T:  this node's WWIV temp directory (%I), holding the drop files WWIV
#       writes: CHAIN.TXT, DORINFO1.DEF, DOOR.SYS, DOOR32.SYS, ...
#       Point the door's drop file path at T:\
#   W:  the directory holding this script, WWIVFOSS.EXE and WWIV4CHN.EXE;
#       on PATH, so a WWIV 3/4 chain runs as WWIV4CHN.EXE CHAIN.COM ...
#       (see docs/wwiv.md)
#
# Environment:
#   DOSDOOR_DOSBOX   DOSBox-X binary (default: dosbox-x)
#   DOSDOOR_FLAGS    extra WWIVFOSS options (e.g. -S for call statistics,
#                    or -H<n> if WWIVFOSS_HEARTBEAT in wwiv.ini is over 10)
#   DOSDOOR_CONF     extra DOSBox-X config file merged in (e.g. [cpu] cycles)
#   DOSDOOR_ECHO=1   echo the commands on the DOSBox-X screen (debugging;
#                    note it makes DOSBox-X service the UART more slowly)
#   DOSDOOR_LOG      troubleshooting: directory to save a copy of the drop
#                    files and DOSBox-X config as the door saw them, and
#                    DOSBox-X's output (dosbox.log)
set -euo pipefail

usage() {
  awk 'NR > 1 && /^#/ {sub(/^# ?/, ""); print; next} NR > 1 {exit}' "$0"
}

# In-band line control and WWIV's heartbeats unless -r.
line_flags="-E -H10"
while [ $# -gt 0 ]; do
  case "$1" in
    -r|--raw) line_flags="-E-"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) break ;;
  esac
done
if [ $# -lt 4 ]; then
  usage
  exit 2
fi

port="$1"
temp="$2"
dir="$3"
shift 3
here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

# WWIV writes the DOS drop files with CR LF since 5.10 build 3814
# (wwivbbs/wwiv#1738). Older WWIV on Linux writes LF, which DOS doors
# misread (Turbo Pascal doors like LORD read the whole file as one line);
# for those, uncomment this to convert them. DOOR32.SYS (32-bit doors only)
# and PCBOARD.SYS (binary) are left alone either way.
# for f in "$temp"/*; do
#   case "$(basename "$f" | tr '[:upper:]' '[:lower:]')" in
#     chain.txt|dorinfo*.def|door.sys|callinfo.bbs|sfdoors.dat)
#       sed -i 's/\r*$/\r/' "$f" ;;
#   esac
# done

# "@echo off" matters beyond tidiness: with command echo on in autoexec,
# DOSBox-X 2025.02 delayed the UART interrupt enough to overrun the receive
# FIFO during fast transfers (hundreds of lost bytes per Zmodem run).
conf="$temp/dosdoor.conf"
echo_cmd="@echo off"
[ "${DOSDOOR_ECHO:-}" = 1 ] && echo_cmd="@echo on"
cat > "$conf" <<CONF
[dosbox]
quit warning = false

[cpu]
cycles = max

[serial]
serial1 = nullmodem server:127.0.0.1 port:$port transparent:1

[autoexec]
$echo_cmd
mount c "$dir"
mount t "$temp"
mount w "$here"
set PATH=%PATH%;W:\\
c:
cd \\
W:\\WWIVFOSS.EXE -P1 $line_flags ${DOSDOOR_FLAGS:-} $*
exit
CONF

log=/dev/null
if [ -n "${DOSDOOR_LOG:-}" ]; then
  mkdir -p "$DOSDOOR_LOG"
  cp "$temp"/* "$DOSDOOR_LOG"/ 2>/dev/null || true
  log="$DOSDOOR_LOG/dosbox.log"
fi

args=(-conf "$conf")
if [ -n "${DOSDOOR_CONF:-}" ]; then
  args+=(-conf "$DOSDOOR_CONF")
fi

# DOSBox-X needs no window: the caller sees the door through COM1.
export SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy
exec "${DOSDOOR_DOSBOX:-dosbox-x}" "${args[@]}" -nogui -nomenu -fastlaunch \
  > "$log" 2>&1
