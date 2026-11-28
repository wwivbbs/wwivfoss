# Legend of the Red Dragon 4.06 (Seth Able Robinson / Metropolis).
# Configured for node 1 as WWIV (CHAIN.TXT) with the FOSSIL.
# Sourced by scripts/test.sh.

DOOR_URL="https://mirrors.archeobits.com/bbs/archives.thebbs.org/files/door_games/doors_l-o/lord406.zip"
# START.BAT passes /DREW; without it LORD refuses to run.
DOOR_CMD="LORD.EXE 1 /DREW"
DOOR_EXPECT="LOADING THE REALM"
# LORD reads LORD.DAT only after a key at its title screen. That screen
# is random, its prompt (if any) varies, and LORD drops keys sent before it
# waits for one, so press Enter every 3 seconds until the main menu, which
# shows LORD.DAT loaded.
DOOR_SCRIPT='
* 3 \r
< Your choice, warrior
'
DOOR_HANGUP_ERRORLEVEL=0

door_prepare() {
  unzip -q -o "$1/LORD.ZIP" -d "$1"
}

# LORD.DAT as LORDCFG's "(A) Create a NEW LORD.DAT file with defaults"
# writes it (629 bytes); LORD won't start without it. Written per run, so
# a door cache prepared before this existed still gets one.
lord_dat() {
  python3 - "$1" <<'PY'
import sys
d = bytearray(629)
def put(off, b): d[off:off + len(b)] = b
put(0x0e, b"\x09NO WINNER")
put(0xa1, b"\x01")
put(0xa6, b"\x01")
put(0xa7, (100000).to_bytes(4, "little") + b"\x03")
put(0xb3, b"\x0f")
put(0x16f, b"\x0f")
put(0x173, b"\x07NO NAME")
put(0x273, b"\x03")
open(sys.argv[1], "wb").write(d)
PY
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
  lord_dat "$dir/LORD.DAT"
  write_chain "$drop"
}
