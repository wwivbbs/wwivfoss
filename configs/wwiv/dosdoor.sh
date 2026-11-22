#!/usr/bin/env bash
# Runs a DOS door under DOSBox-X with WWIVFOSS, for a WWIV chain whose exec
# mode is SOCK_PORT (WWIV listens on a local port, passed as %Z, and DOSBox-X
# connects its COM1 to it).
#
#   dosdoor.sh PORT TEMPDIR DOORDIR COMMAND [ARGS...]
#
# Example chain command line (wwivconfig > Chains, exec mode SOCK_PORT):
#
#   /wwiv/doors/dosdoor.sh %Z %I /wwiv/doors/lord LORD.EXE %N /DREW
#
# Inside DOS:
#   C:  the door's directory (DOORDIR); COMMAND runs from C:\
#   T:  this node's WWIV temp directory (%I), holding the drop files WWIV
#       writes: CHAIN.TXT, DORINFO1.DEF, DOOR.SYS, DOOR32.SYS, ...
#       Point the door's drop file path at T:\
#   W:  the directory holding this script and WWIVFOSS.EXE
#
# Environment:
#   DOSDOOR_DOSBOX   DOSBox-X binary (default: dosbox-x)
#   DOSDOOR_FLAGS    extra WWIVFOSS options (e.g. -S for call statistics)
#   DOSDOOR_CONF     extra DOSBox-X config file merged in (e.g. [cpu] cycles)
#   DOSDOOR_LOG      troubleshooting: directory to save a copy of the drop
#                    files and DOSBox-X config as the door saw them, and
#                    DOSBox-X's output (dosbox.log)
set -euo pipefail

if [ $# -lt 4 ] || [ "$1" = -h ] || [ "$1" = --help ]; then
  awk 'NR > 1 && /^#/ {sub(/^# ?/, ""); print; next} NR > 1 {exit}' "$0"
  exit 2
fi

port="$1"
temp="$2"
dir="$3"
shift 3
here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

# WWIV on Linux writes drop files with LF line endings; DOS doors expect
# CR LF (Turbo Pascal doors like LORD read the whole file as one line).
for f in "$temp"/*; do
  case "$(basename "$f" | tr '[:upper:]' '[:lower:]')" in
    chain.txt|dorinfo*.def|door.sys|door32.sys|callinfo.bbs|pcboard.sys|sfdoors.dat)
      sed -i 's/\r*$/\r/' "$f" ;;
  esac
done

conf="$temp/dosdoor.conf"
cat > "$conf" <<CONF
[dosbox]
quit warning = false

[cpu]
cycles = max

[serial]
serial1 = nullmodem server:127.0.0.1 port:$port transparent:1

[autoexec]
mount c "$dir"
mount t "$temp"
mount w "$here"
c:
cd \\
W:\\WWIVFOSS.EXE -P1 ${DOSDOOR_FLAGS:-} $*
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
