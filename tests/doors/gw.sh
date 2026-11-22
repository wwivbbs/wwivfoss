# Global War 2.7 (John Dailey), from a local install.
#
# A FOSSIL/UART door that reads WWIV's CHAIN.TXT or takes the caller on the
# command line (/C).
#
# Sourced by scripts/test.sh. Point WWIVFOSS_DOORS at a directory holding
# gw/ as shipped (gw.exe is a self-extracting ARJ archive; default
# /wwiv/doors).

DOOR_SRC="${WWIVFOSS_DOORS:-/wwiv/doors}/gw"
DOOR_CMD="WAR.EXE /C 9600 1 60 Rush Fan"
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
