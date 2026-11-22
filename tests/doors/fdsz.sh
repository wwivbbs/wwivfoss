# FDSZ, the FOSSIL build of Omen Technology's DSZ (Zmodem), 05-97.
# Round trip: the BBS (lrzsz) sends a file, FDSZ receives it and sends it
# back; it must come back identical. Uses only FOSSIL functions 00h-03h.
# Sourced by scripts/test.sh.

DOOR_URL="https://mirrors.archeobits.com/bbs/archives.thebbs.org/files/file_transfer_protocols/fdsz0597.zip"
DOOR_CMD="ZM.BAT"
DOOR_SCENARIO=zmodem

door_prepare() {
  printf '%s\r\n' "@echo off" "FDSZ 1 rz" "FDSZ 1 sz DOWN.BIN" > "$1/ZM.BAT"
}
