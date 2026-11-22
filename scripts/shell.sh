#!/usr/bin/env bash
# Interactive FreeDOS shell in QEMU, with the latest WWIVFOSS build on A:.
#
#   scripts/shell.sh          boot to an A:\> prompt
#   scripts/shell.sh --help   this help
#
# Environment:
#   DISPLAY_MODE  QEMU display (default: curses, runs in this terminal;
#                 gtk or sdl for a window)
#   PORT          TCP port for COM1 (default 2323). Connect to it to be the
#                 "caller", e.g.  nc localhost 2323  or  telnet localhost 2323
#   MONITOR_PORT  optional TCP port for the QEMU monitor (screendump, quit)
#   FRESH=1       recreate the floppy image (otherwise your files persist)
#
# In DOS, type QUIT to power off. With the curses display you can also press
# Esc then 2 for the QEMU monitor and type "quit".
#
# The floppy image lives at .devenv/shell.img; the binaries in it are
# refreshed from the build on every start.
set -euo pipefail

case "${1:-}" in
  -h|--help)
    # Print the header comment above as help.
    awk 'NR > 1 && /^#/ {sub(/^# ?/, ""); print; next} NR > 1 {exit}' "$0"
    exit 0
    ;;
esac

root="$(cd "$(dirname "$0")/.." && pwd)"
dev="$root/.devenv"
img="$dev/shell.img"
port="${PORT:-2323}"
display="${DISPLAY_MODE:-curses}"

for tool in qemu-system-i386 mcopy; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing $tool: sudo apt-get install -y qemu-system-x86 mtools" >&2
    exit 1
  fi
done
if [ ! -f "$dev/freedos/boot.img" ]; then
  echo "Run scripts/setup-dev.sh first" >&2
  exit 1
fi

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

# Refresh the binaries from the current build.
for f in "$root/dos/wwivfoss.exe" "$root/tools/fostest/fostest.exe"; do
  if [ -f "$f" ]; then
    mcopy -o -i "$img" "$f" ::/
  else
    echo "Note: $f not built yet (scripts/build.sh)" >&2
  fi
done

echo "COM1 <-> tcp 127.0.0.1:$port (connect any time to act as the caller)"
exec qemu-system-i386 \
  -M pc -m 16 \
  -drive "file=$img,format=raw,if=floppy" -boot a \
  -display "$display" \
  -chardev "socket,id=bbs,host=127.0.0.1,port=$port,server=on,wait=off" \
  -serial chardev:bbs \
  -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
  ${MONITOR_PORT:+-monitor "tcp:127.0.0.1:$MONITOR_PORT,server=on,wait=off"} \
  -no-reboot
