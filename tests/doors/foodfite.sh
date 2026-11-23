# Food Fight 4.6 (Michael Wilson), a DOOR.SYS door with FOSSIL support.
#
# FOODFITE.CFG line 1 is the drop file's full path, line 17 the port:
# PORT:F:1 selects the FOSSIL. Sourced by scripts/test.sh.

DOOR_URL="https://mirrors.archeobits.com/bbs/archives.thebbs.org/files/door_games/doors_d-f/ffght461.zip"
DOOR_CMD="FOODFITE.EXE FOODFITE.CFG"

# Per run: DOORDIR DROPDIR DRIVE.
door_dropfiles() {
  local dir="$1" drop="$2" drive="$3"
  write_doorsys "$drop"
  awk -v dropfile="$drive\\DOOR.SYS" '
    NR == 1  { print dropfile "\r"; next }
    NR == 17 { print "PORT:F:1\r"; next }
    { print }' "$dir/FOODFITE.CFG" > "$dir/FOODFITE.CFG.new"
  mv "$dir/FOODFITE.CFG.new" "$dir/FOODFITE.CFG"
}

# The login prompt: the door initialized, read DOOR.SYS and drew its title.
DOOR_EXPECT="Press F for FAST login"
