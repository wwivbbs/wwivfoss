#!/usr/bin/env bash
# Runs a DOS door under QEMU (FreeDOS) with WWIVFOSS for a WWIV chain. WWIV
# listens on a local port (%Z) and QEMU connects its COM1 to it. The QEMU
# counterpart of dosdoor.sh, with the same arguments and drive letters.
#
#   qemudoor.sh [-r|--raw] PORT TEMPDIR DOORDIR COMMAND [ARGS...]
#
# Match the chain's exec mode (ChainEdit, E) Exec Mode):
#
#   "WWIVFOSS (Socket Port)"   (recommended) no option. WWIVFOSS runs with
#                              -E -H10: QEMU never drops carrier, so hang-ups
#                              come in-band, and WWIV's heartbeats catch a
#                              BBS that went away.
#   "Listen Socket Port"       -r / --raw. WWIVFOSS runs with -E-. The door
#                              never sees a hang-up; WWIV kills QEMU instead.
#
# Example chain command line:
#
#   /wwiv/doors/qemudoor.sh %Z %I /wwiv/doors/lord LORD.EXE %N /DREW
#
# Inside DOS:
#   C:  a copy of the door's directory (DOORDIR) on a fresh hard disk image;
#       COMMAND runs from C:\. When QEMU exits (or is killed), files the
#       door created or changed are copied back to DOORDIR. Files it deleted
#       are not deleted.
#   T:  the drop files from this node's WWIV temp directory (%I), on a
#       floppy in B: (SWSUBST T: B:\). Point the door's drop file path at
#       T:\, as with dosdoor.sh. Changed files are copied back to %I.
#   A:  the FreeDOS boot floppy, with WWIVFOSS.EXE
#
# One node at a time per door: the copy back would undo another node's
# changes. Set the chain's Multi user to No and WWIV enforces it per chain;
# a lock on DOORDIR also covers two chains sharing one door, telling the
# second caller the door is in use.
#
# Next to this script (or see QEMUDOOR_BOOT / QEMUDOOR_DISK):
#   WWIVFOSS.EXE
#   qemudoor-boot.img   .devenv/freedos/qemudoor-boot.img from setup-dev.sh
#   qemudoor-c.img      .devenv/freedos/c.img (empty 32 MB FAT16 disk)
#
# Needs qemu-system-i386 and mtools:
#   sudo apt-get install -y qemu-system-x86 mtools
#
# Environment:
#   QEMUDOOR_QEMU    QEMU binary (default: qemu-system-i386)
#   QEMUDOOR_BOOT    boot floppy (default: qemudoor-boot.img here)
#   QEMUDOOR_DISK    empty hard disk image for C: (default: qemudoor-c.img
#                    here); its FAT16 partition must start at byte 32256
#   QEMUDOOR_FLAGS   extra WWIVFOSS options (e.g. -S for call statistics,
#                    or -H<n> if WWIVFOSS_HEARTBEAT in wwiv.ini is over 10)
#   QEMUDOOR_ARGS    extra QEMU options
#   QEMUDOOR_LOG     troubleshooting: directory to save the drop files and
#                    DOOR.BAT as the door saw them, and QEMU's output
set -euo pipefail

usage() {
  awk 'NR > 1 && /^#/ {sub(/^# ?/, ""); print; next} NR > 1 {exit}' "$0"
}

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
boot="${QEMUDOOR_BOOT:-$here/qemudoor-boot.img}"
base="${QEMUDOOR_DISK:-$here/qemudoor-c.img}"
part=32256   # byte offset of the FAT16 partition in the C: image

for d in "$temp" "$dir"; do
  [ -n "$d" ] && [ -d "$d" ] || { echo "qemudoor: not a directory: '$d'" >&2; exit 1; }
done
for f in "$boot" "$base" "$here/WWIVFOSS.EXE"; do
  [ -f "$f" ] || { echo "qemudoor: missing $f (see $0 --help)" >&2; exit 1; }
done

# Tells the caller something went wrong, on the socket WWIV is waiting on.
tell_caller() {
  { exec 3<>"/dev/tcp/127.0.0.1/$port" && printf '\r\n%s\r\n' "$1" >&3 &&
    sleep 2 && exec 3>&-; } 2>/dev/null || true
}

# One node at a time: hold a lock on the door directory for the whole call.
exec 9<"$dir"
if ! flock -n 9; then
  echo "qemudoor: $dir is in use by another node" >&2
  tell_caller "This door is in use on another node. Please try again later."
  exit 1
fi

work="$temp/qemudoor"
rm -rf "$work"
mkdir -p "$work/drop"

# Drop files, as CR LF (WWIV on Linux writes LF; see dosdoor.sh).
for f in "$temp"/*; do
  [ -f "$f" ] || continue
  case "$(basename "$f" | tr '[:upper:]' '[:lower:]')" in
    chain.txt|dorinfo*.def|door.sys|callinfo.bbs|sfdoors.dat)
      sed 's/\r*$/\r/' "$f" > "$work/drop/$(basename "$f")" ;;
    *.txt|*.def|*.sys|*.bbs|*.dat|*.inf|msginf)
      cp "$f" "$work/drop/" ;;
  esac
done
mformat -i "$work/drop.img" -f 1440 -C ::
if [ -n "$(ls -A "$work/drop")" ]; then
  mcopy -i "$work/drop.img" "$work/drop"/* ::/
fi

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
  echo "A:\\SWSUBST T: B:\\ > NUL"
  echo "C:"
  echo "cd \\"
  echo "A:\\WWIVFOSS.EXE -P1 $line_flags ${QEMUDOOR_FLAGS:-} $*"
  echo "A:\\QEXIT.COM"
} | sed 's/$/\r/' > "$work/DOOR.BAT"
mcopy -o -i "$work/boot.img" "$work/FDCONFIG.SYS" "$work/DOOR.BAT" \
  "$work/QEXIT.COM" "$here/WWIVFOSS.EXE" ::/

log=/dev/null
if [ -n "${QEMUDOOR_LOG:-}" ]; then
  mkdir -p "$QEMUDOOR_LOG"
  cp "$work/drop"/* "$work/DOOR.BAT" "$QEMUDOOR_LOG"/ 2>/dev/null || true
  log="$QEMUDOOR_LOG/qemu.log"
fi

# Copies files from image $1 (mtools spec) that differ from directory $2
# back into it, matching existing names case-insensitively (DOS uppercases).
copy_back() {
  local img="$1" dest="$2" out f target
  out="$(mktemp -d "$work/back.XXXX")"
  mcopy -s -m -n -i "$img" '::/*' "$out/" 2>/dev/null || true
  (cd "$out" && find . -type f) | while IFS= read -r f; do
    f="${f#./}"
    target="$(cd "$dest" && find . -ipath "./$f" -print -quit 2>/dev/null)"
    target="${target#./}"
    [ -n "$target" ] || target="$f"
    if ! cmp -s "$out/$f" "$dest/$target"; then
      mkdir -p "$(dirname "$dest/$target")"
      cp -p "$out/$f" "$dest/$target"
    fi
  done
}

# QEMU and the copy back run in a subshell that outlives this script: WWIV
# SIGKILLs the door's process on hang-up, and the door's data must still be
# copied back. If this script dies, the subshell stops QEMU (SIGTERM, which
# QEMU handles cleanly) and finishes up.
main=$$
# Alive and not a zombie (a SIGKILLed script stays one until WWIV reaps it).
main_alive() {
  local st
  st="$(cat "/proc/$main/stat" 2>/dev/null)" || return 1
  st="${st##*) }"
  [ "${st%% *}" != Z ]
}
(
  trap '' HUP INT TERM
  # shellcheck disable=SC2086  # QEMUDOOR_ARGS is split into words
  "${QEMUDOOR_QEMU:-qemu-system-i386}" \
    -M pc -m 16 \
    -drive "file=$work/boot.img,format=raw,if=floppy,index=0" \
    -drive "file=$work/drop.img,format=raw,if=floppy,index=1" -boot a \
    -drive "file=$work/c.img,format=raw,if=ide,index=0" \
    -display none \
    -chardev "socket,id=bbs,host=127.0.0.1,port=$port" \
    -serial chardev:bbs \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
    -no-reboot ${QEMUDOOR_ARGS:-} > "$log" 2>&1 &
  qemu=$!
  while kill -0 "$qemu" 2>/dev/null; do
    if ! main_alive; then
      kill -TERM "$qemu" 2>/dev/null || true
    fi
    sleep 0.5
  done
  wait "$qemu" 2>/dev/null || true
  copy_back "$work/c.img@@$part" "$dir"
  copy_back "$work/drop.img" "$temp"
  rm -rf "$work"
) &
wait $!
