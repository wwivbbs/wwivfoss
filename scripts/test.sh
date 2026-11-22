#!/usr/bin/env bash
# End-to-end test: run "WWIVFOSS -P1 FOSTEST" in an emulator whose COM1 is
# connected to a TCP socket, with scripts/bbs.py playing the BBS.
#
#   scripts/test.sh [EMULATOR] [SCENARIO] [MODE]
#   scripts/test.sh all
#
#   EMULATOR  qemu    FreeDOS 1.4 floppy; WWIVFOSS -E (in-band line control,
#                     QEMU doesn't drop DCD when the socket closes)
#             dosbox  DOSBox-X; raw stream, DCD follows the socket
#   SCENARIO  echo    type text, Q quits; expect errorlevel 0 (default)
#             hangup  caller drops mid-door; expect errorlevel 2
#             dtr     door hangs up via FOSSIL 06h; expect errorlevel 3
#                     (qemu only: needs in-band framing to observe DTR)
#   MODE      runner    WWIVFOSS [opts] FOSTEST (default)
#             resident  WWIVFOSS -L, FOSTEST, WWIVFOSS -U, then FOSTEST
#                       again, which must find no FOSSIL
#
#   KEEP=1     keep .devenv/test/ for inspection
#   TIMEOUT=n  seconds per step (default 120)
#
# Needs: scripts/setup-dev.sh, scripts/build.sh, python3, and qemu-system-i386 +
# mtools (qemu) or dosbox-x (dosbox).
set -euo pipefail

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
    for combo in qemu:echo qemu:hangup qemu:dtr dosbox:echo dosbox:hangup; do
      e="${combo%%:*}"
      s="${combo##*:}"
      echo "=== $e / $s / $m"
      if ! "$0" "$e" "$s" "$m"; then
        rc=1
        failed="$failed $e/$s/$m"
      fi
    done
  done
  if [ "$rc" = 0 ]; then
    echo "ALL PASSED"
  else
    echo "FAILED:$failed"
  fi
  exit $rc
fi

case "$scenario" in
  echo) want_errorlevel=0 ;;
  hangup) want_errorlevel=2 ;;
  dtr) want_errorlevel=3 ;;
  *) echo "Unknown scenario: $scenario" >&2; exit 1 ;;
esac
case "$mode" in
  runner|resident) ;;
  *) echo "Unknown mode: $mode" >&2; exit 1 ;;
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
  *) echo "Unknown emulator: $emu" >&2; exit 1 ;;
esac
for f in "$root/dos/wwivfoss.exe" "$root/tools/fostest/fostest.exe"; do
  [ -f "$f" ] || { echo "Missing $f (run scripts/build.sh)" >&2; exit 1; }
done

work="$dev/test/$emu-$scenario-$mode"
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
  exit 1
}

# Copies the result files out of the QEMU floppy image (DOSBox-X writes
# them straight to $work).
fetch_results() {
  if [ "$emu" = qemu ] && [ -n "${img:-}" ]; then
    for f in LOG.TXT RESULT.TXT UNLOAD.TXT AFTER.TXT LOADLOG.TXT UNLOG.TXT; do
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
    if [ "$mode" = resident ]; then
      echo "${d}\\WWIVFOSS.EXE -L $flags > ${d}\\LOADLOG.TXT"
      echo "if errorlevel 1 goto loadfail"
      echo "${d}\\FOSTEST.EXE > ${d}\\LOG.TXT"
    else
      echo "${d}\\WWIVFOSS.EXE $flags ${d}\\FOSTEST.EXE > ${d}\\LOG.TXT"
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
      echo "${d}\\WWIVFOSS.EXE -U > ${d}\\UNLOG.TXT"
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
python3 "$root/scripts/bbs.py" "$port" "$scenario" "$framing" "$timeout_secs" "$work/ready" &
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
    write_test_bat "A:" 1
    mcopy -o -i "$img" "$work/FDCONFIG.SYS" "$work/TEST.BAT" \
      "$work/QEXIT.COM" "$root/dos/wwivfoss.exe" \
      "$root/tools/fostest/fostest.exe" ::/
    qemu-system-i386 \
      -M pc -m 16 \
      -drive "file=$img,format=raw,if=floppy" -boot a \
      -display none \
      -chardev "socket,id=bbs,host=127.0.0.1,port=$port" \
      -serial chardev:bbs \
      -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
      -monitor "tcp:127.0.0.1:$monitor_port,server=on,wait=off" \
      -no-reboot > "$work/emulator.log" 2>&1 &
    emu_pid=$!
    ;;
  dosbox)
    cp "$root/dos/wwivfoss.exe" "$root/tools/fostest/fostest.exe" "$work/"
    write_test_bat "C:" 0
    cat > "$work/dosbox.conf" <<EOF
[dosbox]
quit warning = false

[cpu]
cycles = max

[serial]
serial1 = nullmodem server:127.0.0.1 port:$port transparent:1

[autoexec]
mount c "$work"
c:
call C:\\TEST.BAT
exit
EOF
    SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
      dosbox-x -conf "$work/dosbox.conf" -nogui -nomenu -fastlaunch \
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
if [ "$mode" = resident ]; then
  unload="$(tr -d '\r\n ' < "$work/UNLOAD.TXT" 2>/dev/null || echo missing)"
  [ "$unload" = ok ] || fail "resident mode: $unload"
fi
[ -f "$work/RESULT.TXT" ] || fail "no RESULT.TXT; the test batch file did not finish"
errorlevel="$(tr -dc '0-9' < "$work/RESULT.TXT")"
if [ "$errorlevel" != "$want_errorlevel" ]; then
  fail "errorlevel $errorlevel, wanted $want_errorlevel"
fi
echo "ok - door exited with errorlevel $errorlevel"
if [ "$mode" = resident ]; then
  echo "ok - WWIVFOSS -U unloaded; FOSTEST then found no FOSSIL"
fi
passed=1
echo "PASS ($emu/$scenario/$mode)"
