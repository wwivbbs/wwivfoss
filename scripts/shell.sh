#!/usr/bin/env bash
# Interactive FreeDOS shell in QEMU, with the latest WWIVFOSS build on A:
# and a persistent hard disk as C:.
#
#   scripts/shell.sh                  boot to an A:\> prompt
#   scripts/shell.sh --door lord      ...after copying a prepared door to
#                                     C:\LORD (repeatable; see below)
#   scripts/shell.sh --help           this help
#
# Drives:
#   A:  FreeDOS boot floppy (.devenv/shell.img) with WWIVFOSS.EXE and
#       FOSTEST.EXE, refreshed from the build on every start
#   C:  .devenv/shell-c.img, a 32 MB FAT16 disk that persists between runs
#       (created from .devenv/freedos/c.img, the same base the QEMU door
#       tests use)
#
# --door NAME copies .devenv/doors/NAME (prepared by the door tests; run
# "scripts/test.sh dosbox door:NAME" once first) into C:\NAME, with the
# drop file and door configuration from tests/doors/NAME.sh pointing at
# C:\NAME. In DOS:
#   C:
#   CD \NAME
#   WWIVFOSS -P1 -E <door command>     (see tests/doors/NAME.sh)
# and connect as the caller with "nc localhost 2323". In-band framing (-E)
# isn't decoded by nc; leave -E off and use -C to force carrier instead.
#
# Getting files in and out of C: from Linux (with QEMU stopped):
#   mdir  -i .devenv/shell-c.img@@32256 ::/
#   mcopy -i .devenv/shell-c.img@@32256 file.zip ::/       (in)
#   mcopy -i .devenv/shell-c.img@@32256 ::/FILE.TXT .      (out)
# or mount it (root):
#   sudo mount -o loop,offset=32256 .devenv/shell-c.img /mnt
#
# Environment:
#   DISPLAY_MODE  QEMU display (default: curses, runs in this terminal;
#                 gtk or sdl for a window)
#   PORT          TCP port for COM1 (default 2323). Connect to it to be the
#                 "caller", e.g.  nc localhost 2323  or  telnet localhost 2323
#   MONITOR_PORT  optional TCP port for the QEMU monitor (screendump, quit)
#   FRESH=1       recreate the floppy and the C: disk (your files are lost)
#
# In DOS, type QUIT to power off. With the curses display you can also press
# Esc then 2 for the QEMU monitor and type "quit".
set -euo pipefail

doors=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      # Print the header comment above as help.
      awk 'NR > 1 && /^#/ {sub(/^# ?/, ""); print; next} NR > 1 {exit}' "$0"
      exit 0
      ;;
    --door)
      [ $# -ge 2 ] || { echo "--door needs a name" >&2; exit 2; }
      doors+=("$2")
      shift 2
      ;;
    *)
      echo "Unknown argument: $1 (see $0 --help)" >&2
      exit 2
      ;;
  esac
done

root="$(cd "$(dirname "$0")/.." && pwd)"
dev="$root/.devenv"
img="$dev/shell.img"
disk="$dev/shell-c.img"
port="${PORT:-2323}"
display="${DISPLAY_MODE:-curses}"

for tool in qemu-system-i386 mcopy; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing $tool: sudo apt-get install -y qemu-system-x86 mtools" >&2
    exit 1
  fi
done
for f in "$dev/freedos/boot.img" "$dev/freedos/c.img"; do
  [ -f "$f" ] || { echo "Missing $f: run scripts/setup-dev.sh first" >&2; exit 1; }
done

if [ ! -f "$img" ] || [ -n "${FRESH:-}" ]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  cp "$dev/freedos/boot.img" "$img"
  # Skip the installer: boot to a prompt with the FreeDOS environment set.
  printf 'FILES=30\r\nBUFFERS=20\r\nLASTDRIVE=Z\r\nSHELL=\\FREEDOS\\BIN\\COMMAND.COM \\FREEDOS\\BIN /E:2048 /P=\\SHELL.BAT\r\n' \
    > "$tmp/FDCONFIG.SYS"
  printf '@echo off\r\ncall \\FDAUTO.BAT ENV_ONLY\r\nset COMSPEC=A:\\FREEDOS\\BIN\\COMMAND.COM\r\nset PATH=A:\\;%%PATH%%\r\necho.\r\necho WWIVFOSS dev shell. COM1 is on host port '"$port"'. Type QUIT to power off.\r\necho Try: WWIVFOSS -P1 FOSTEST\r\necho.\r\n' \
    > "$tmp/SHELL.BAT"
  # QUIT.COM: write to QEMU's isa-debug-exit port to power off.
  printf '\xb0\x00\xe6\xf4\xcd\x20' > "$tmp/QUIT.COM"
  mcopy -o -i "$img" "$tmp/FDCONFIG.SYS" "$tmp/SHELL.BAT" "$tmp/QUIT.COM" ::/
fi
if [ ! -f "$disk" ] || [ -n "${FRESH:-}" ]; then
  cp "$dev/freedos/c.img" "$disk"
fi

# Refresh the binaries from the current build.
for f in "$root/dos/wwivfoss.exe" "$root/tools/fostest/fostest.exe"; do
  if [ -f "$f" ]; then
    mcopy -o -i "$img" "$f" ::/
  else
    echo "Note: $f not built yet (scripts/build.sh)" >&2
  fi
done

# Copy prepared doors onto C:, with their drop files and configuration.
. "$root/scripts/doorlib.sh"
for name in "${doors[@]}"; do
  src="$dev/doors/$name"
  def="$root/tests/doors/$name.sh"
  if [ ! -f "$src/.prepared" ] || [ ! -f "$def" ]; then
    echo "Door $name isn't prepared; run: scripts/test.sh dosbox door:$name" >&2
    exit 1
  fi
  dosname="$(echo "$name" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z0-9_' | cut -c1-8)"
  stage="$(mktemp -d)"
  cp -r "$src"/. "$stage"/
  (
    unset -f door_prepare door_dropfiles
    DOOR_CMD=""
    . "$def"
    if declare -F door_dropfiles >/dev/null; then
      door_dropfiles "$stage" "$stage" "C:\\$dosname"
    fi
    echo "Door $name: in DOS, C: then CD \\$dosname, then WWIVFOSS -P1 -C $DOOR_CMD"
  )
  mmd -i "$disk@@32256" "::/$dosname" 2>/dev/null || true
  mcopy -o -s -i "$disk@@32256" "$stage"/* "::/$dosname/"
  rm -rf "$stage"
  echo "Copied door $name to C:\\$dosname"
done

echo "COM1 <-> tcp 127.0.0.1:$port (connect any time to act as the caller)"
echo "C: is $disk (mcopy -i $disk@@32256 ... ; see --help)"
exec qemu-system-i386 \
  -M pc -m 16 \
  -drive "file=$img,format=raw,if=floppy" -boot a \
  -drive "file=$disk,format=raw,if=ide,index=0" \
  -display "$display" \
  -chardev "socket,id=bbs,host=127.0.0.1,port=$port,server=on,wait=off" \
  -serial chardev:bbs \
  -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
  ${MONITOR_PORT:+-monitor "tcp:127.0.0.1:$MONITOR_PORT,server=on,wait=off"} \
  -no-reboot
