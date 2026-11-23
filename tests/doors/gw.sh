# Global War 2.7 (John Dailey), from a local install.
#
# A FOSSIL/UART door that reads WWIV's CHAIN.TXT or takes the caller on the
# command line (/C).
#
# Sourced by scripts/test.sh. Point WWIVFOSS_DOORS at a directory holding
# gw/ as shipped (gw.exe is a self-extracting ARJ archive; default
# /wwiv/doors).

DOOR_SRC="${WWIVFOSS_DOORS:-/wwiv/doors}/gw"
# Reads WWIV's CHAIN.TXT (/W path), as on a WWIV BBS. The drop drive
# differs by mode, so door_dropfiles writes GWAR.BAT with the right path.
DOOR_CMD="GWAR.BAT"
DOOR_EXPECT="Global War v2.7"
# Global War exits 0 after the caller drops carrier.
DOOR_HANGUP_ERRORLEVEL=0

# Prepares a copy of the door in $1 (run once; the result is cached).
door_prepare() {
  local dir="$1"
  if ! ls "$dir" | grep -qi '^war\.exe$'; then
    # Unpack the ARJ self-extractor unattended (-y) in DOSBox-X.
    dos_run "$dir" "GW.EXE -y > NUL"
  fi
  ls "$dir" | grep -qi '^war\.exe$' || { echo "gw: extraction failed" >&2; return 1; }
  # Line 9 of WAR.CFG picks the comm driver: force F(OSSIL).
  local cfg
  cfg="$(ls "$dir" | grep -i '^war\.cfg$')"
  sed -i '9s/^[ADFU] /F /' "$dir/$cfg"
}

# Per run: DOORDIR DROPDIR DRIVE.
door_dropfiles() {
  local dir="$1" drop="$2" drive="$3"
  write_chain "$drop"
  printf '%s\r\n' "@echo off" "WAR.EXE /W $drive\\CHAIN.TXT" > "$dir/GWAR.BAT"
}
