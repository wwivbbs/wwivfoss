#!/usr/bin/env bash
# Runs a DOS program from a door's directory in this terminal, for setting
# up doors (LORDCFG.EXE, a door's install or config program). Works over
# ssh: QEMU (FreeDOS) draws the DOS text screen with curses, no X needed.
#
#   dosrun.sh DOORDIR [COMMAND [ARGS...]]
#
# Examples:
#
#   /wwiv/doors/dosrun.sh /wwiv/doors/lord LORDCFG.EXE
#   /wwiv/doors/dosrun.sh /wwiv/doors/lord          (a DOS prompt; EXIT quits)
#
# Inside DOS, C: is a copy of DOORDIR and COMMAND runs from C:\. When the
# program exits, QEMU powers off and files it created or changed are copied
# back to DOORDIR. Files it deleted are not deleted.
#
# Takes the same lock on DOORDIR as qemudoor.sh, so it won't run while a
# caller is in the door under qemudoor.sh. dosdoor.sh doesn't lock: make sure
# nobody is in the door, since the copy back would undo their changes.
#
# If the program hangs: press Esc then 2 for the QEMU monitor, type quit and
# Enter. Changed files are still copied back.
#
# Uses the same files as qemudoor.sh, next to this script (or see
# QEMUDOOR_BOOT / QEMUDOOR_DISK): qemudoor-boot.img and qemudoor-c.img.
# Needs qemu-system-i386 and mtools. The terminal should be at least 80x25.
set -euo pipefail

usage() {
  awk 'NR > 1 && /^#/ {sub(/^# ?/, ""); print; next} NR > 1 {exit}' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") usage; exit 2 ;;
esac
dir="$1"
shift
here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
boot="${QEMUDOOR_BOOT:-$here/qemudoor-boot.img}"
base="${QEMUDOOR_DISK:-$here/qemudoor-c.img}"
part=32256   # byte offset of the FAT16 partition in the C: image

[ -d "$dir" ] || { echo "dosrun: not a directory: '$dir'" >&2; exit 1; }
for f in "$boot" "$base"; do
  [ -f "$f" ] || { echo "dosrun: missing $f (see $0 --help)" >&2; exit 1; }
done
[ -t 0 ] && [ -t 1 ] || { echo "dosrun: needs a terminal" >&2; exit 1; }

exec 9<"$dir"
if ! flock -n 9; then
  echo "dosrun: $dir is in use by a caller" >&2
  exit 1
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/dosrun.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# C: the door directory on a copy of the empty disk.
cp "$base" "$work/c.img"
if [ -n "$(ls -A "$dir")" ]; then
  mcopy -s -m -i "$work/c.img@@$part" "$dir"/* ::/
fi

# A: FreeDOS boots straight into DOOR.BAT, which powers QEMU off at the end
# (QEXIT.COM: mov al,0 / out 0F4h,al / int 20h, to isa-debug-exit).
cp "$boot" "$work/boot.img"
printf 'FILES=30\r\nBUFFERS=20\r\nLASTDRIVE=Z\r\nSHELL=A:\\FREEDOS\\BIN\\COMMAND.COM A:\\FREEDOS\\BIN /E:1024 /P=A:\\DOOR.BAT\r\n' \
  > "$work/FDCONFIG.SYS"
printf '\xb0\x00\xe6\xf4\xcd\x20' > "$work/QEXIT.COM"
{
  echo "@echo off"
  echo "set COMSPEC=A:\\FREEDOS\\BIN\\COMMAND.COM"
  echo "C:"
  echo "cd \\"
  if [ $# -gt 0 ]; then
    echo "$*"
  else
    echo "echo Type EXIT to copy changes back and quit."
    echo "A:\\FREEDOS\\BIN\\COMMAND.COM"
  fi
  echo "A:\\QEXIT.COM"
} | sed 's/$/\r/' > "$work/DOOR.BAT"
mcopy -o -i "$work/boot.img" "$work/FDCONFIG.SYS" "$work/DOOR.BAT" \
  "$work/QEXIT.COM" ::/

qemu-system-i386 \
  -M pc -m 16 \
  -drive "file=$work/boot.img,format=raw,if=floppy,index=0" -boot a \
  -drive "file=$work/c.img,format=raw,if=ide,index=0" \
  -display curses \
  -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
  -no-reboot ${DOSRUN_ARGS:-} || true
clear 2>/dev/null || true

# Copies files that differ back into DOORDIR, matching existing names
# case-insensitively (DOS uppercases).
out="$work/back"
mkdir -p "$out"
mcopy -s -m -n -i "$work/c.img@@$part" '::/*' "$out/" 2>/dev/null || true
(cd "$out" && find . -type f) | while IFS= read -r f; do
  f="${f#./}"
  target="$(cd "$dir" && find . -ipath "./$f" -print -quit 2>/dev/null)"
  target="${target#./}"
  [ -n "$target" ] || target="$f"
  if ! cmp -s "$out/$f" "$dir/$target"; then
    mkdir -p "$(dirname "$dir/$target")"
    cp -p "$out/$f" "$dir/$target"
    echo "dosrun: updated $target"
  fi
done
