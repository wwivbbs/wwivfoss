# Legend of the Red Dragon 4.06 (Seth Able Robinson / Metropolis).
# Configured for node 1 as WWIV (CHAIN.TXT) with the FOSSIL.
# Sourced by scripts/test.sh.

DOOR_URL="https://mirrors.archeobits.com/bbs/archives.thebbs.org/files/door_games/doors_l-o/lord406.zip"
# START.BAT passes /DREW; without it LORD refuses to run.
DOOR_CMD="LORD.EXE 1 /DREW"
DOOR_EXPECT="LOADING THE REALM"
DOOR_HANGUP_ERRORLEVEL=0

door_prepare() {
  unzip -q -o "$1/LORD.ZIP" -d "$1"
}

# Per run: DOORDIR DROPDIR DRIVE (DROPDIR is DRIVE inside DOS).
door_dropfiles() {
  local dir="$1" drop="$2" drive="$3" n
  # NODEn.DAT is what LORDCFG's "Configure Nodes" writes; written directly
  # here: BBS type WWIV (CHAIN.TXT), drop file on DRIVE, FOSSIL on.
  for n in 1 2; do
    printf '%s\r\n' "**Seth Able's Node Data System, for node $n" \
      "BBSNAME WWIVFOSS Test BBS" "BBSTYPE WWIV" ";COMPORT 0" "FOSSIL" \
      "LOCKBAUD 0" "STATUS ON" "STATFORE 15" "STATBACK 1" ";NODE$n" "NODIRECT" \
      ";UNUSED" "BBSDROP $drive\\" "NOOPEN" "NORESET" ";UNUSED" > "$dir/NODE$n.DAT"
  done
  write_chain "$drop"
}
