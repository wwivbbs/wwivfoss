# Legend of the Red Dragon 4.06 (Seth Able Robinson / Metropolis).
# Configured for node 1 as WWIV (CHAIN.TXT) with the FOSSIL.
# Sourced by scripts/test.sh.

DOOR_URL="https://mirrors.archeobits.com/bbs/archives.thebbs.org/files/door_games/doors_l-o/lord406.zip"
# START.BAT passes /DREW; without it LORD refuses to run.
DOOR_CMD="LORD.EXE 1 /DREW"
DOOR_EXPECT="LOADING THE REALM"
DOOR_HANGUP_ERRORLEVEL=0

door_prepare() {
  local dir="$1"
  unzip -q -o "$dir/LORD.ZIP" -d "$dir"
  # NODE1.DAT is what LORDCFG's "Configure Nodes" writes; written directly
  # here with: BBS type WWIV (CHAIN.TXT), drop file in C:\, FOSSIL on.
  printf '%s\r\n' "**Seth Able's Node Data System, for node 1" \
    "BBSNAME WWIVFOSS Test BBS" "BBSTYPE WWIV" ";COMPORT 0" "FOSSIL" \
    "LOCKBAUD 0" "STATUS ON" "STATFORE 15" "STATBACK 1" ";NODE1" "NODIRECT" \
    ";UNUSED" "BBSDROP C:\\" "NOOPEN" "NORESET" ";UNUSED" > "$dir/NODE1.DAT"
  write_chain "$dir"
}
