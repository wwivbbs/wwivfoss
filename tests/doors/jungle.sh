# JUNGLE, an example door from DoorDriver 5.00 (Turbo Pascal door kit).
#
# By Scott Baker. DoorDriver uses a FOSSIL when one is loaded.
# Sourced by scripts/test.sh.

DOOR_URL="https://mirrors.archeobits.com/bbs/archives.thebbs.org/files/door_developer_kits/doordr50.zip"
# DoorDriver only reads DORINFO1.DEF from the door's own directory, so a
# batch file copies it in from the drop drive first (see door_dropfiles).
DOOR_CMD="JUNGLE.BAT"
DOOR_EXPECT="Welcome to The Jungle!"
DOOR_HANGUP_ERRORLEVEL=0

# Per run: DOORDIR DROPDIR DRIVE. Under WWIV the drop file is on T:, which
# DoorDriver can't be pointed at, so JUNGLE.BAT copies it into the door's
# directory first: the setup a sysop would use for doors like this.
door_dropfiles() {
  local dir="$1" drop="$2" drive="$3"
  write_dorinfo "$drop"
  {
    echo "@echo off"
    if [ "$drop" != "$dir" ]; then
      echo "copy $drive\\DORINFO1.DEF . > NUL"
    fi
    echo "JUNGLE.EXE"
  } | sed 's/$/\r/' > "$dir/JUNGLE.BAT"
}
