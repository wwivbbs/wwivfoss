# Shared helpers for door definitions (tests/doors/*.sh), sourced by
# scripts/test.sh and scripts/shell.sh.

# Runs COMMAND in a throwaway DOSBox-X session with DIR as C: (door setup).
dos_run() {
  local dir="$1" cmd="$2" conf
  conf="$(mktemp)"
  printf '[dosbox]\nquit warning = false\n[cpu]\ncycles = max\n[autoexec]\nmount c "%s"\nc:\n%s\nexit\n' \
    "$dir" "$cmd" > "$conf"
  SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
    timeout 120 dosbox-x -conf "$conf" -nogui -nomenu -fastlaunch >/dev/null 2>&1 || true
  rm -f "$conf"
}

# Drop files for door definitions. The caller is Rush Fan on COM1 at 19200.
# Lines end in CR LF, or LF when DROP_EOL=lf (what WWIV before 5.10 build
# 3814 writes on Linux, wwivbbs/wwiv#1738).
drop_fmt() {
  # Literal escapes (echo doesn't expand them): $(...) would strip a real
  # trailing newline, so let the caller's printf turn these into line ends.
  if [ "${DROP_EOL:-crlf}" = lf ]; then echo '%s\n'; else echo '%s\r\n'; fi
}

# DORINFO1.DEF (RBBS/QuickBBS; OpenDoors, DoorDriver and most others).
write_dorinfo() {
  printf "$(drop_fmt)" "WWIVFOSS TEST BBS" "THE" "SYSOP" "COM1" "19200 BAUD,N,8,1" "0" \
    "RUSH" "FAN" "TESTVILLE" "1" "100" "60" > "$1/DORINFO1.DEF"
}

# CHAIN.TXT in WWIV's field order (bbs/dropfile.cpp create_chain_file).
write_chain() {
  printf "$(drop_fmt)" "1" "RUSH FAN" "Rush Fan" "" "30" "M" "      0.00" "11/22/26" \
    "80" "25" "100" "0" "0" "1" "1" "   3600.00" "C:\\WWIV\\GFILES\\" \
    "C:\\WWIV\\DATA\\" "NODE1.LOG" "19200" "1" "WWIVFOSS Test BBS" "The Sysop" \
    "43200" "10" "0" "0" "0" "0" "8N1" "19200" "1" "N" "N" "N" "0" "0" > "$1/CHAIN.TXT"
}

# DOOR.SYS (52 lines) in WWIV's field order (bbs/dropfile.cpp
# CreateDoorSysDropFile).
write_doorsys() {
  printf "$(drop_fmt)" "COM1" "19200" "8" "1" "19200" "Y" "N" "N" "N" \
    "Rush Fan" "Testville, CA" "555-555-1212" "Rush Fan" "X" "100" "10" \
    "11/22/26" "3600" "60" "GR" "25" "N" "1,2,3" "0" "12/31/99" "1" "Y" \
    "0" "0" "0" "0" "01/01/80" "C:\\WWIV\\DATA\\" "C:\\WWIV\\GFILES\\" \
    "The Sysop" "RUSH FAN" "00:01" "Y" "N" "N" "7" "0" "11/22/26" "12:00" \
    "00:01" "99" "0" "0" "0" "" "0" "0" > "$1/DOOR.SYS"
}
