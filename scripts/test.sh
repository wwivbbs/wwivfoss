#!/usr/bin/env bash
# End-to-end test: run "WWIVFOSS -P1 FOSTEST" in an emulator whose COM1 is
# connected to a TCP socket, with scripts/bbs.py playing the BBS.
#
#   scripts/test.sh [EMULATOR] [SCENARIO] [MODE]
#   scripts/test.sh all      FOSTEST matrix, 14 runs (what CI runs)
#   scripts/test.sh doors    every door in tests/doors/: qemu and dosbox in
#                            both modes, plus dosdoor (local only; not in CI)
#   scripts/test.sh --help   this help
#
# Examples:
#   scripts/test.sh                           qemu, echo, runner
#   scripts/test.sh dosbox hangup resident
#   scripts/test.sh qemu speed                throughput, prints KB/s
#   scripts/test.sh dosbox door:lord          one door
#   KEEP=1 scripts/test.sh qemu funcs         keep .devenv/test/ afterwards
#
#   EMULATOR  qemu    FreeDOS 1.4 floppy; WWIVFOSS -E (in-band line control,
#                     QEMU doesn't drop DCD when the socket closes)
#             dosbox  DOSBox-X; raw stream, DCD follows the socket
#             dosdoor doors only: run through configs/wwiv/dosdoor.sh exactly
#                     as a WWIV SOCK_PORT chain does (drop files written
#                     with LF in a node temp dir mounted as T:; runner mode;
#                     the door's errorlevel isn't checked)
#   SCENARIO  echo    type text, Q quits; expect errorlevel 0 (default)
#             hangup  caller drops mid-door; expect errorlevel 2
#             dtr     door hangs up via FOSSIL 06h; expect errorlevel 3
#                     (qemu only: needs in-band framing to observe DTR)
#             speed   32 KB each way through FOSSIL block I/O; prints KB/s
#             twocalls  (qemu, resident) call, hang up, call again: the second
#                     call must work, i.e. the port recovers from a hangup
#             funcs   FOSTEST self-tests: local functions, peek, purge,
#                     all 256 byte values both ways, and (qemu) keyboard
#             door:NAME  a real door from tests/doors/NAME.sh: expect its
#                     banner, hang up, and the door must notice and exit
#   MODE      runner    WWIVFOSS [opts] FOSTEST (default)
#             resident  WWIVFOSS -L, FOSTEST, WWIVFOSS -U, then FOSTEST
#                       again, which must find no FOSSIL
#
# Environment:
#   WWIVFOSS_DOORS=dir  where door tests find installed doors (/wwiv/doors);
#                       other doors are downloaded from a BBS archive mirror
#   WWIVFOSS_FLAGS=...  extra WWIVFOSS options (e.g. -I0)
#   KEEP=1     keep .devenv/test/ for inspection
#   TIMEOUT=n  seconds per step (default 120)
#
# Needs scripts/setup-dev.sh and scripts/build.sh first, plus:
#   python3; qemu-system-x86 + mtools (qemu); dosbox-x (dosbox, and door
#   setup for both); lrzsz (door:fdsz). On Debian/Ubuntu:
#   sudo apt-get install -y qemu-system-x86 mtools dosbox-x python3 lrzsz
#
# On failure the door's console log, results and (qemu) a screenshot are
# printed or saved under .devenv/test/.
set -euo pipefail

case "${1:-}" in
  -h|--help)
    # Print the header comment above as help, then the defined doors.
    awk 'NR > 1 && /^#/ {sub(/^# ?/, ""); print; next} NR > 1 {exit}' "$0"
    echo
    echo "Doors defined in tests/doors/:"
    for def in "$(dirname "$0")"/../tests/doors/*.sh; do
      printf '  door:%-10s %s\n' "$(basename "$def" .sh)" "$(sed -n '1s/^# *//p' "$def")"
    done
    exit 0
    ;;
esac

root="$(cd "$(dirname "$0")/.." && pwd)"
dev="$root/.devenv"
timeout_secs="${TIMEOUT:-120}"
emu="${1:-qemu}"
scenario="${2:-echo}"
mode="${3:-runner}"

if [ "$emu" = all ]; then
  rc=0
  failed=""
  for m in runner resident; do
    for combo in qemu:echo qemu:hangup qemu:dtr qemu:funcs \
                 dosbox:echo dosbox:hangup dosbox:funcs; do
      e="${combo%%:*}"
      s="${combo##*:}"
      echo "=== $e / $s / $m"
      if ! "$0" "$e" "$s" "$m"; then
        rc=1
        failed="$failed $e/$s/$m"
      fi
    done
  done
  echo "=== qemu / twocalls / resident"
  if ! "$0" qemu twocalls resident; then
    rc=1
    failed="$failed qemu/twocalls/resident"
  fi
  if [ "$rc" = 0 ]; then
    echo "ALL PASSED"
  else
    echo "FAILED:$failed"
  fi
  exit $rc
fi

if [ "$emu" = doors ]; then
  rc=0
  failed=""
  for def in "$root"/tests/doors/*.sh; do
    name="$(basename "$def" .sh)"
    src="$(DOOR_SRC=; DOOR_URL=; . "$def"
           if [ -n "$DOOR_URL" ] || [ -d "$DOOR_SRC" ]; then echo ok; else echo "$DOOR_SRC"; fi)"
    if [ "$src" != ok ]; then
      echo "=== door:$name: skipped ($src not found)"
      continue
    fi
    for run in qemu:runner dosbox:runner qemu:resident dosbox:resident dosdoor:runner; do
      e="${run%%:*}"
      m="${run##*:}"
      echo "=== $e / door:$name / $m"
      if ! "$0" "$e" "door:$name" "$m"; then
        rc=1
        failed="$failed $e/door:$name/$m"
      fi
    done
  done
  if [ "$rc" = 0 ]; then echo "ALL DOORS PASSED"; else echo "FAILED:$failed"; fi
  exit $rc
fi

# dos_run, drop_fmt, write_dorinfo, write_chain for door definitions.
. "$root/scripts/doorlib.sh"

door=""
case "$scenario" in
  door:*)
    door="${scenario#door:}"
    def="$root/tests/doors/$door.sh"
    [ -f "$def" ] || { echo "No door definition: $def" >&2; exit 1; }
    DOOR_HANGUP_ERRORLEVEL=any
    . "$def"
    if [ -z "${DOOR_URL:-}" ] && [ ! -d "$DOOR_SRC" ]; then
      echo "Door not installed: $DOOR_SRC" >&2; exit 1
    fi
    need_dosbox_for_prep=1
    want_errorlevel="$DOOR_HANGUP_ERRORLEVEL"
    ;;
  echo|funcs|speed) want_errorlevel=0 ;;
  twocalls)
    want_errorlevel=0  # call 2; call 1 must end with 2 (carrier lost)
    if [ "$emu" != qemu ] || [ "${mode:-runner}" != resident ]; then
      echo "twocalls runs as: qemu twocalls resident" >&2; exit 1
    fi
    ;;
  hangup) want_errorlevel=2 ;;
  dtr) want_errorlevel=3 ;;
  *) echo "Unknown scenario: $scenario (see $0 --help)" >&2; exit 1 ;;
esac
case "$mode" in
  runner|resident) ;;
  *) echo "Unknown mode: $mode (see $0 --help)" >&2; exit 1 ;;
esac

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing $1: sudo apt-get install -y $2" >&2
    exit 1
  fi
}
need python3 python3
case "$emu" in
  qemu)
    need qemu-system-i386 qemu-system-x86; need mcopy mtools
    framing=inband
    flags="-P1 -E"
    ;;
  dosbox)
    need dosbox-x dosbox-x
    framing=raw
    flags="-P1"
    [ "$scenario" != dtr ] || { echo "dtr needs in-band framing (qemu)" >&2; exit 1; }
    ;;
  dosdoor)
    need dosbox-x dosbox-x
    framing=raw
    flags=""
    [ -n "$door" ] || { echo "dosdoor runs doors only (door:NAME)" >&2; exit 1; }
    [ "$mode" = runner ] || { echo "dosdoor runs doors as a runner only" >&2; exit 1; }
    ;;
  *) echo "Unknown emulator: $emu (see $0 --help)" >&2; exit 1 ;;
esac
# Extra WWIVFOSS options for experiments, e.g. WWIVFOSS_FLAGS=-I0.
flags="$flags ${WWIVFOSS_FLAGS:-}"
if [ -n "$door" ]; then
  need dosbox-x dosbox-x  # door_prepare runs setup steps in DOSBox-X
  # Prepare once into a cache; tests run on a fresh copy of it.
  cache="$dev/doors/$door"
  if [ ! -f "$cache/.prepared" ]; then
    rm -rf "$cache"
    mkdir -p "$cache"
    if [ -n "${DOOR_URL:-}" ]; then
      zip="$dev/downloads/archive/$(basename "$DOOR_URL")"
      if [ ! -s "$zip" ]; then
        mkdir -p "$(dirname "$zip")"
        curl -fsSL --retry 3 -o "$zip.part" "$DOOR_URL" && mv "$zip.part" "$zip"
      fi
      unzip -q -o "$zip" -d "$cache"
    else
      cp -r "$DOOR_SRC"/. "$cache"/
    fi
    if declare -F door_prepare >/dev/null; then
      door_prepare "$cache" || { echo "Preparing door $door failed" >&2; exit 1; }
    fi
    touch "$cache/.prepared"
  fi
fi
for f in "$root/dos/wwivfoss.exe" "$root/tools/fostest/fostest.exe"; do
  [ -f "$f" ] || { echo "Missing $f (run scripts/build.sh)" >&2; exit 1; }
done

work="$dev/test/$emu-${scenario/:/-}-$mode"
rm -rf "$work"
mkdir -p "$work"
port=$((20000 + RANDOM % 20000))
monitor_port=$((port + 1))
passed=0
emu_pid=""
bbs_pid=""

cleanup() {
  [ -n "$emu_pid" ] && kill "$emu_pid" 2>/dev/null || true
  [ -n "$bbs_pid" ] && kill "$bbs_pid" 2>/dev/null || true
  if [ -z "${KEEP:-}" ] && [ "$passed" = 1 ]; then
    rm -rf "$work"
  fi
}
trap cleanup EXIT

screenshot() {
  [ "$emu" = qemu ] || return 0
  { exec 4<>"/dev/tcp/127.0.0.1/$monitor_port" &&
    printf 'screendump %s -f png\n' "$work/screen.png" >&4 &&
    sleep 1; } 2>/dev/null || true
}

fail() {
  echo "FAIL ($emu/$scenario/$mode): $*" >&2
  screenshot
  fetch_results
  for f in LOADLOG.TXT LOG.TXT UNLOG.TXT UNLOAD.TXT AFTER.TXT; do
    if [ -f "$work/$f" ]; then
      echo "--- $f ---" >&2
      tr -d '\r' < "$work/$f" >&2
    fi
  done
  [ -f "$work/screen.png" ] && echo "Screenshot: $work/screen.png" >&2
  [ -f "$work/doslog/dosbox.log" ] && echo "DOSBox-X log: $work/doslog/dosbox.log" >&2
  exit 1
}

# Copies the result files out of the QEMU floppy image (DOSBox-X writes
# them straight to $work).
fetch_results() {
  if [ "$emu" = qemu ] && [ -n "${img:-}" ]; then
    for f in LOG.TXT RESULT.TXT UNLOAD.TXT AFTER.TXT LOADLOG.TXT UNLOG.TXT STATS.TXT LOG1.TXT RESULT1.TXT; do
      mcopy -o -i "$img" "::/$f" "$work/" 2>/dev/null || true
    done
  fi
}

# The batch file both emulators run. FOSTEST's errorlevel goes to
# RESULT.TXT; in resident mode the unload result goes to UNLOAD.TXT. Under
# QEMU, QEXIT.COM writes to the isa-debug-exit port to power off.
write_test_bat() {
  local d="$1" qemu="$2"
  {
    echo "@echo off"
    if [ "$qemu" = 1 ]; then
      # FreeCOM needs COMSPEC to find itself for COMMAND /C.
      echo "set COMSPEC=A:\\FREEDOS\\BIN\\COMMAND.COM"
    fi
    if [ -n "$door" ]; then
      # Real door: run it from its own drive and directory.
      echo "$door_drive"
      echo "cd \\"
      if [ "$mode" = resident ]; then
        echo "${d}\\WWIVFOSS.EXE -L $flags > ${d}\\LOADLOG.TXT"
        echo "if errorlevel 1 goto loadfail"
        case "$DOOR_CMD" in
          *.BAT*|*.bat*) echo "call $DOOR_CMD" ;;  # else control never returns
          *) echo "$DOOR_CMD" ;;
        esac
      else
        echo "${d}\\WWIVFOSS.EXE $flags -S${d}\\STATS.TXT $DOOR_CMD"
      fi
    elif [ "$mode" = resident ]; then
      echo "${d}\\WWIVFOSS.EXE -L $flags > ${d}\\LOADLOG.TXT"
      echo "if errorlevel 1 goto loadfail"
      if [ "$scenario" = twocalls ]; then
        echo "${d}\\FOSTEST.EXE > ${d}\\LOG1.TXT"
        for n in 3 2 1; do
          echo "if errorlevel $n goto c$n"
        done
        for n in 0 1 2 3; do
          echo ":c$n"
          echo "echo $n > ${d}\\RESULT1.TXT"
          echo "goto call2"
        done
        echo ":call2"
        echo "${d}\\FOSTEST.EXE 1 /W > ${d}\\LOG.TXT"
      else
        echo "${d}\\FOSTEST.EXE > ${d}\\LOG.TXT"
      fi
    else
      echo "${d}\\WWIVFOSS.EXE $flags -S${d}\\STATS.TXT ${d}\\FOSTEST.EXE > ${d}\\LOG.TXT"
    fi
    for n in 3 2 1; do
      echo "if errorlevel $n goto e$n"
    done
    for n in 0 1 2 3; do
      echo ":e$n"
      echo "echo $n > ${d}\\RESULT.TXT"
      echo "goto after"
    done
    echo ":after"
    if [ "$mode" = resident ]; then
      echo "${d}\\WWIVFOSS.EXE -U -S${d}\\STATS.TXT > ${d}\\UNLOG.TXT"
      echo "if errorlevel 1 goto unloadfail"
      # With the FOSSIL gone, FOSTEST must exit 1 ("no FOSSIL").
      echo "${d}\\FOSTEST.EXE > ${d}\\AFTER.TXT"
      echo "if errorlevel 2 goto stillthere"
      echo "if errorlevel 1 goto gone"
      echo ":stillthere"
      echo "echo still-resident > ${d}\\UNLOAD.TXT"
      echo "goto done"
      echo ":gone"
      echo "echo ok > ${d}\\UNLOAD.TXT"
      echo "goto done"
      echo ":unloadfail"
      echo "echo unload-failed > ${d}\\UNLOAD.TXT"
      echo "goto done"
      echo ":loadfail"
      echo "echo load-failed > ${d}\\UNLOAD.TXT"
    fi
    echo ":done"
    if [ "$qemu" = 1 ]; then
      echo "${d}\\QEXIT.COM"
    fi
  } | sed 's/$/\r/' > "$work/TEST.BAT"
}

# Start the BBS side first; the emulator connects to it, as with WWIV's
# listen-socket exec mode.
bbs_scenario="$scenario"
[ -n "$door" ] && bbs_scenario="${DOOR_SCENARIO:-door}"
# Zmodem doors: the host side's files (see door_prepare in tests/doors).
export ZM_DIR="$work/zm"
if [ "$bbs_scenario" = zmodem ]; then
  mkdir -p "$ZM_DIR"
  # 32 KB holding every byte value, in a scrambled but repeatable order.
  python3 -c 'import random,sys; r=random.Random(1954); b=bytearray(range(256))*128; r.shuffle(b); sys.stdout.buffer.write(b)' \
    > "$ZM_DIR/DOWN.BIN"
fi
export DOOR_EXPECT="${DOOR_EXPECT:-}"
export DOOR_STRAY="${DOOR_STRAY:-}"
export DOOR_STRAY_WHEN="${DOOR_STRAY_WHEN:-}"
export DOOR_MIN_BYTES="${DOOR_MIN_BYTES:-}"
bbs_args=("$port" "$bbs_scenario" "$framing" "$timeout_secs" "$work/ready")
[ "$emu" = qemu ] && bbs_args+=("$monitor_port")
python3 "$root/scripts/bbs.py" "${bbs_args[@]}" &
bbs_pid=$!
for _ in $(seq 1 50); do
  [ -f "$work/ready" ] && break
  sleep 0.1
done
[ -f "$work/ready" ] || fail "BBS harness did not start"

echo "Running $emu / $scenario / $mode (WWIVFOSS $flags; BBS on 127.0.0.1:$port)"
case "$emu" in
  qemu)
    img="$work/test.img"
    cp "$dev/freedos/boot.img" "$img"
    printf 'FILES=20\r\nBUFFERS=10\r\nSHELL=\\FREEDOS\\BIN\\COMMAND.COM \\FREEDOS\\BIN /E:1024 /P=\\TEST.BAT\r\n' \
      > "$work/FDCONFIG.SYS"
    # QEXIT.COM: mov al,0 / out 0F4h,al / int 20h -> QEMU powers off.
    printf '\xb0\x00\xe6\xf4\xcd\x20' > "$work/QEXIT.COM"
    door_drive=C:
    door_args=()
    # twocalls: reconnect to the BBS after the first call hangs up.
    reconnect=""
    [ "$scenario" = twocalls ] && reconnect=",reconnect-ms=500"
    if [ -n "$door" ]; then
      # The door goes on a fresh copy of the base hard disk image as C:
      # (scripts/mkdisk.py; FAT16 partition at byte offset 32256). Not
      # QEMU's fat:rw: folder drive: it's experimental and lost the last
      # sector of a file a door wrote and then read back (FDSZ round trip).
      [ -f "$dev/freedos/c.img" ] || { echo "Missing $dev/freedos/c.img (run scripts/setup-dev.sh)" >&2; exit 1; }
      mkdir -p "$work/c"
      cp -r "$cache"/. "$work/c"/
      if declare -F door_dropfiles >/dev/null; then
        door_dropfiles "$work/c" "$work/c" C:
      fi
      cp "$dev/freedos/c.img" "$work/c.img"
      mcopy -s -i "$work/c.img@@32256" "$work/c"/* ::/
      door_args=(-drive "file=$work/c.img,format=raw,if=ide,index=0")
    fi
    write_test_bat "A:" 1
    mcopy -o -i "$img" "$work/FDCONFIG.SYS" "$work/TEST.BAT" \
      "$work/QEXIT.COM" "$root/dos/wwivfoss.exe" \
      "$root/tools/fostest/fostest.exe" ::/
    qemu-system-i386 \
      -M pc -m 16 \
      -drive "file=$img,format=raw,if=floppy" -boot a \
      "${door_args[@]}" \
      -display none \
      -chardev "socket,id=bbs,host=127.0.0.1,port=$port${reconnect}" \
      -serial chardev:bbs \
      -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
      -monitor "tcp:127.0.0.1:$monitor_port,server=on,wait=off" \
      -no-reboot > "$work/emulator.log" 2>&1 &
    emu_pid=$!
    ;;
  dosbox)
    cp "$root/dos/wwivfoss.exe" "$root/tools/fostest/fostest.exe" "$work/"
    # Door files on C: as under QEMU, so paths in door configs match; the
    # test files and results then live on E:.
    door_drive=C:
    rd=C:
    mounts="mount c \"$work\""
    if [ -n "$door" ]; then
      mkdir -p "$work/d"
      cp -r "$cache"/. "$work/d"/
      if declare -F door_dropfiles >/dev/null; then
        door_dropfiles "$work/d" "$work/d" C:
      fi
      rd=E:
      mounts="mount c \"$work/d\"
mount e \"$work\""
    fi
    write_test_bat "$rd" 0
    cat > "$work/dosbox.conf" <<EOF
[dosbox]
quit warning = false

[cpu]
cycles = max

[serial]
serial1 = nullmodem server:127.0.0.1 port:$port transparent:1

[autoexec]
$mounts
$rd
call $rd\\TEST.BAT
exit
EOF
    SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
      dosbox-x -conf "$work/dosbox.conf" -nogui -nomenu -fastlaunch \
      > "$work/emulator.log" 2>&1 &
    emu_pid=$!
    ;;
  dosdoor)
    # Laid out like a WWIV install: dosdoor.sh and WWIVFOSS.EXE together
    # (mounted as W:), the door directory (C:), and a node temp directory
    # holding LF drop files (T:), which WWIV passes as %I.
    mkdir -p "$work/w" "$work/d" "$work/temp"
    cp "$root/configs/wwiv/dosdoor.sh" "$work/w/dosdoor.sh"
    cp "$root/dos/wwivfoss.exe" "$work/w/WWIVFOSS.EXE"
    cp -r "$cache"/. "$work/d"/
    if declare -F door_dropfiles >/dev/null; then
      DROP_EOL=lf door_dropfiles "$work/d" "$work/temp" T:
    fi
    # shellcheck disable=SC2086  # DOOR_CMD is split into words, as WWIV does
    DOSDOOR_ECHO="${DOOR_DOSDOOR_ECHO:-}" \
    DOSDOOR_FLAGS="-ST:\\STATS.TXT ${WWIVFOSS_FLAGS:-}" DOSDOOR_LOG="$work/doslog" \
      "$work/w/dosdoor.sh" "$port" "$work/temp" "$work/d" $DOOR_CMD \
      > "$work/emulator.log" 2>&1 &
    emu_pid=$!
    ;;
esac

if ! wait "$bbs_pid"; then
  bbs_pid=""
  fail "BBS side of the scenario failed"
fi
bbs_pid=""

# Wait for the door to finish and the emulator to exit.
for _ in $(seq 1 30); do
  kill -0 "$emu_pid" 2>/dev/null || break
  sleep 1
done
if kill -0 "$emu_pid" 2>/dev/null; then
  fail "the door did not exit within 30s (want errorlevel $want_errorlevel)"
fi
wait "$emu_pid" || true
emu_pid=""

fetch_results
if [ "$emu" = dosdoor ]; then
  # dosdoor.sh doesn't report the door's errorlevel; WWIVFOSS wrote its
  # call counts to T:\STATS.TXT.
  for f in "$work/temp"/*; do
    case "$(basename "$f" | tr '[:upper:]' '[:lower:]')" in
      stats.txt) cp "$f" "$work/STATS.TXT" ;;
    esac
  done
  echo "ok - door exited (dosdoor.sh, errorlevel not reported)"
else
  if [ "$mode" = resident ]; then
    unload="$(tr -d '\r\n ' < "$work/UNLOAD.TXT" 2>/dev/null || echo missing)"
    [ "$unload" = ok ] || fail "resident mode: $unload"
  fi
  [ -f "$work/RESULT.TXT" ] || fail "no RESULT.TXT; the test batch file did not finish"
  errorlevel="$(tr -dc '0-9' < "$work/RESULT.TXT")"
  if [ "$want_errorlevel" != any ] && [ "$errorlevel" != "$want_errorlevel" ]; then
    fail "errorlevel $errorlevel, wanted $want_errorlevel"
  fi
  echo "ok - door exited with errorlevel $errorlevel"
  if [ "$scenario" = twocalls ]; then
    first="$(tr -dc '0-9' < "$work/RESULT1.TXT" 2>/dev/null || echo missing)"
    [ "$first" = 2 ] || fail "call 1 ended with errorlevel $first, wanted 2 (carrier lost)"
    echo "ok - call 1 ended on carrier loss (errorlevel 2); call 2 quit normally"
  fi
fi
# Prove the door went through WWIVFOSS, not its own UART code.
[ -f "$work/STATS.TXT" ] || fail "no STATS.TXT from WWIVFOSS -S"
calls="$(awk '$1 == "total" {print $2}' "$work/STATS.TXT")"
tx="$(awk '$1 == "01" || $1 == "0B" || $1 == "19" {n += $2} END {print n + 0}' "$work/STATS.TXT")"
if [ "${tx:-0}" -eq 0 ]; then
  fail "WWIVFOSS handled no transmit calls ($calls calls total): door bypassed the FOSSIL?"
fi
echo "ok - $calls FOSSIL calls, $tx of them transmit"
if [ "$mode" = resident ]; then
  echo "ok - WWIVFOSS -U unloaded; FOSTEST then found no FOSSIL"
fi
passed=1
echo "PASS ($emu/$scenario/$mode)"
