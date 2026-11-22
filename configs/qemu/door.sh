#!/bin/sh
# WWIVFOSS door template for QEMU.  UNTESTED.
#
# Usage: door.sh PORT DISK_IMAGE
#
#   PORT        TCP port the BBS is listening on (WWIV: %Z)
#   DISK_IMAGE  FreeDOS disk image whose AUTOEXEC.BAT runs
#               WWIVFOSS -P1 <door command> and then powers off
#
# Door files and drop files must be visible inside the image. See
# docs/design.md ("Open questions") for the options.
set -eu

port="$1"
image="$2"

exec qemu-system-i386 \
  -m 16 \
  -display none \
  -drive "file=${image},format=raw,if=ide" \
  -chardev "socket,id=bbs,host=127.0.0.1,port=${port}" \
  -serial chardev:bbs \
  -no-reboot
