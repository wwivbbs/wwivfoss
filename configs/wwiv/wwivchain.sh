#!/usr/bin/env bash
# Runs an old WWIV 4.x DOS chain under DOSBox-X: a program that talks to the
# caller through DOS standard input and output (WWIV 4 ran these with "DOS
# interrupts" on) and colors its text with WWIV heart codes (^C0-^C9).
#
#   wwivchain.sh PORT TEMPDIR DOORDIR COMMAND [ARGS...]
#
# Chain exec mode: "Listen Socket Port". No FOSSIL is involved: DOS's
# console is redirected to COM1 (CTTY COM1), and heartrelay.py, between
# DOSBox-X and WWIV, turns heart codes into ANSI colors and
# ^L into a screen clear. CTTYFIX.COM (tools/cttyfix) is loaded first:
# DOSBox-X's COM1 always reports a key waiting, which hangs chains that
# flush the keyboard (Food Fight at its first screen clear).
#
# Example chain command line (Food Fight 2.00c, given CHAIN.TXT):
#
#   /wwiv/doors/wwivchain.sh %Z %I /wwiv/doors/foodfite2 FOODFITE.COM T:\CHAIN.TXT
#
# Inside DOS, as with dosdoor.sh:
#   C:  the chain's directory (DOORDIR); COMMAND runs from C:\
#   T:  this node's WWIV temp directory (%I), with CHAIN.TXT. Its two
#       directory lines (17, 18: gfiles and data) are pointed at T:\, since
#       WWIV 4 chains write there (the sysop log) and WWIV's own are Unix
#       paths.
#   W:  the directory holding this script and CTTYFIX.COM
#
# The caller's hang-up isn't passed on (chains like these don't check for
# it): WWIV stops DOSBox-X after DOOR_EXIT_GRACE seconds (wwiv.ini).
#
# Only under DOSBox-X: FreeDOS's COM driver under QEMU doesn't pass the
# caller's keys to a program through CTTY.
#
# Needs dosbox-x and python3, and CTTYFIX.COM next to this script.
#
# Environment:
#   DOSDOOR_DOSBOX   DOSBox-X binary (default: dosbox-x)
set -euo pipefail

usage() {
  awk 'NR > 1 && /^#/ {sub(/^# ?/, ""); print; next} NR > 1 {exit}' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
if [ $# -lt 4 ]; then
  usage
  exit 2
fi

port="$1"
temp="$2"
dir="$3"
shift 3
here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

[ -f "$here/CTTYFIX.COM" ] || { echo "wwivchain: missing $here/CTTYFIX.COM" >&2; exit 1; }
for d in "$temp" "$dir"; do
  [ -n "$d" ] && [ -d "$d" ] || { echo "wwivchain: not a directory: '$d'" >&2; exit 1; }
done

chain="$(find "$temp" -maxdepth 1 -iname chain.txt -print -quit)"
if [ -n "$chain" ]; then
  sed -i '17s/.*/T:\\\r/; 18s/.*/T:\\\r/' "$chain"
fi

portfile="$temp/wwivchain.port"
rm -f "$portfile"
python3 "$here/heartrelay.py" "$port" "$portfile" &
relay=$!
trap 'kill $relay 2>/dev/null || true' EXIT
for _ in $(seq 50); do
  [ -s "$portfile" ] && break
  sleep 0.1
done
[ -s "$portfile" ] || { echo "wwivchain: heartrelay.py didn't start" >&2; exit 1; }
relay_port="$(cat "$portfile")"

conf="$temp/wwivchain.conf"
cat > "$conf" <<CONF
[dosbox]
quit warning = false

[cpu]
cycles = max

[serial]
serial1 = nullmodem server:127.0.0.1 port:$relay_port transparent:1

[autoexec]
@echo off
mount c "$dir"
mount t "$temp"
mount w "$here"
c:
cd \\
W:\\CTTYFIX.COM
ctty com1
$*
ctty con
exit
CONF

export SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy
"${DOSDOOR_DOSBOX:-dosbox-x}" -conf "$conf" -nogui -nomenu -fastlaunch \
  > /dev/null 2>&1 || true
