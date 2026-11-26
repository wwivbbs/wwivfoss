# Food Fight 2.00c, a WWIV 3 chain (Turbo Pascal 3), under WWIV4CHN.
#
# Uses DOS console I/O and heart codes, no FOSSIL; WWIV4CHN does WWIV's
# part. Not downloadable: point FOODFITE2_DIR at an installed copy
# (default /wwiv/doors/foodfite2). Run scripts/build.sh first. Sourced by
# scripts/test.sh.

DOOR_SRC="${FOODFITE2_DIR:-/wwiv/doors/foodfite2}"
DOOR_CMD="WWIV4CHN.EXE FOODFITE.COM CHAIN.TXT"

door_dropfiles() {
  cp "$root/tools/wwiv4chn/wwiv4chn.exe" "$1/WWIV4CHN.EXE"
  write_chain "$1"
  # CHAIN.TXT's gfiles and data directories (C:\WWIV\...): Food Fight
  # writes its sysop log there and quits if it can't.
  mkdir -p "$1/WWIV/GFILES" "$1/WWIV/DATA"
}

# Its title, with heart codes turned into ANSI colors.
DOOR_EXPECT="Food Fight|FOOD FIGHT"
DOOR_SCRIPT='
< \x1b[0;
'
