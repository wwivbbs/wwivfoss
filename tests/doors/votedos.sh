# VOTEDOS, the voting booth example door from OpenDoors 6.00 (Brian Pirie).
# OpenDoors uses a FOSSIL when one is loaded, else its own serial code.
# Sourced by scripts/test.sh.

DOOR_URL="https://mirrors.archeobits.com/bbs/archives.thebbs.org/files/door_developer_kits/odoors60.zip"
DOOR_CMD="VOTEDOS.EXE"
DOOR_EXPECT="Vote - OpenDoors 6.00 example program"

door_prepare() {
  write_dorinfo "$1"
}
