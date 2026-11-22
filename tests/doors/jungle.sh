# JUNGLE, an example door from DoorDriver 5.00 (Scott Baker's Turbo Pascal
# door kit). DoorDriver uses a FOSSIL when one is loaded.
# Sourced by scripts/test.sh.

DOOR_URL="https://mirrors.archeobits.com/bbs/archives.thebbs.org/files/door_developer_kits/doordr50.zip"
DOOR_CMD="JUNGLE.EXE"
DOOR_EXPECT="Welcome to The Jungle!"
DOOR_HANGUP_ERRORLEVEL=0

door_prepare() {
  write_dorinfo "$1"
}
