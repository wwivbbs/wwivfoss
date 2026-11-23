#!/bin/sh
# Download the local development environment into .devenv/ (gitignored).
#
#   scripts/setup-dev.sh          fetch Open Watcom and FreeDOS (once)
#   SKIP_OW=1 scripts/setup-dev.sh   FreeDOS only (CI gets Open Watcom from
#                                    the setup-watcom action)
#   scripts/setup-dev.sh --help   this help
#
#   .devenv/ow2/       Open Watcom v2 snapshot (Linux x64 host tools; on an
#                      arm64 Linux host this needs Rosetta or qemu-user binfmt)
#   .devenv/freedos/   FreeDOS 1.4 boot floppy (boot.img), and an empty 32 MB
#                      FAT16 hard disk (c.img) that QEMU door tests and
#                      scripts/shell.sh copy for their C: drive
#
# Also needed from the system for testing (see scripts/test.sh --help):
#   sudo apt-get install -y qemu-system-x86 mtools dosbox-x python3 lrzsz
set -eu

case "${1:-}" in
  -h|--help)
    # Print the header comment above as help.
    awk 'NR > 1 && /^#/ {sub(/^# ?/, ""); print; next} NR > 1 {exit}' "$0"
    exit 0
    ;;
esac

root="$(cd "$(dirname "$0")/.." && pwd)"
dev="$root/.devenv"
mkdir -p "$dev/downloads"

OW_URL="https://github.com/open-watcom/open-watcom-v2/releases/download/Current-build/ow-snapshot.tar.xz"
FD_URL="https://www.ibiblio.org/pub/micro/pc-stuff/freedos/files/distributions/1.4/FD14-FloppyEdition.zip"

fetch() {
  out="$dev/downloads/$(basename "$1")"
  if [ ! -s "$out" ]; then
    echo "Downloading $1" >&2
    curl -fL --retry 3 -o "$out.part" "$1"
    mv "$out.part" "$out"
  fi
  echo "$out"
}

# SKIP_OW=1: only fetch FreeDOS (CI gets Open Watcom from setup-watcom).
if [ -z "${SKIP_OW:-}" ] && [ ! -x "$dev/ow2/binl64/wcc" ]; then
  ow="$(fetch "$OW_URL")"
  rm -rf "$dev/ow2"
  mkdir -p "$dev/ow2"
  tar -xJf "$ow" -C "$dev/ow2"
fi

if [ ! -f "$dev/freedos/boot.img" ]; then
  fd="$(fetch "$FD_URL")"
  rm -rf "$dev/freedos"
  mkdir -p "$dev/freedos/zip"
  unzip -q -o "$fd" -d "$dev/freedos/zip"
  img="$(find "$dev/freedos/zip" -iname 'x86boot.img' -path '*144*' | head -1)"
  if [ -z "$img" ]; then
    img="$(find "$dev/freedos/zip" -iname '*boot*.img' | head -1)"
  fi
  if [ -z "$img" ]; then
    echo "Could not find a boot floppy image in $fd" >&2
    exit 1
  fi
  cp "$img" "$dev/freedos/boot.img"
fi

if [ ! -f "$dev/freedos/c.img" ]; then
  if command -v mformat >/dev/null 2>&1; then
    python3 "$root/scripts/mkdisk.py" "$dev/freedos/c.img"
  else
    echo "Skipping .devenv/freedos/c.img: needs mtools (sudo apt-get install -y mtools)" >&2
  fi
fi

echo "Development environment ready in $dev"
echo "Build:  scripts/build.sh"
echo "Test:   scripts/test.sh   (needs qemu-system-i386 and mtools)"
