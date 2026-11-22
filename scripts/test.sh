#!/usr/bin/env bash
# End-to-end test: run "WWIVFOSS -P1 FOSTEST" in an emulator whose COM1 is
# connected to a TCP socket, with scripts/bbs.py playing the BBS.
#
#   scripts/test.sh [EMULATOR] [SCENARIO]
#
#   EMULATOR  qemu (FreeDOS 1.4 floppy, default) or dosbox (DOSBox-X)
#   SCENARIO  echo    type text, Q quits; expect errorlevel 0 (default)
#             hangup  caller drops mid-door; expect errorlevel 2 (carrier lost)
#             all     every scenario on every emulator
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

if [ "$emu" = all ] || [ "$scenario" = all ]; then
  rc=0
  for e in qemu dosbox; do
    for s in echo hangup; do
      echo "=== $e / $s"
      "$0" "$e" "$s" || rc=1
    done
  done
  exit $rc
fi

case "$scenario" in
  echo) want_errorlevel=0 ;;
  hangup) want_errorlevel=2 ;;
  *) echo "Unknown scenario: $scenario" >&2; exit 1 ;;
esac

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing $1: sudo apt-get install -y $2" >&2
    exit 1
  fi
}
need python3 python3
case "$emu" in
  qemu) need qemu-system-i386 qemu-system-x86; need mcopy mtools ;;
  dosbox) need dosbox-x dosbox-x ;;
  *) echo "Unknown emulator: $emu" >&2; exit 1 ;;
esac
for f in "$root/dos/wwivfoss.exe" "$root/tools/fostest/fostest.exe"; do
  [ -f "$f" ] || { echo "Missing $f (run scripts/build.sh)" >&2; exit 1; }
done

work="$dev/test/$emu-$scenario"
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
  echo "FAIL ($emu/$scenario): $*" >&2
  screenshot
  if [ "$emu" = qemu ] && [ -n "${img:-}" ]; then
    mcopy -o -i "$img" ::/LOG.TXT "$work/" 2>/dev/null || true
  fi
  if [ -f "$work/LOG.TXT" ]; then
    echo "--- door console (LOG.TXT) ---" >&2
    tr -d '\r' < "$work/LOG.TXT" >&2
  fi
  [ -f "$work/screen.png" ] && echo "Screenshot: $work/screen.png" >&2
  exit 1
}

# The batch file both emulators run. It records the errorlevel in
# RESULT.TXT, and under QEMU also runs QEXITn.COM, which writes n to the
# isa-debug-exit port so QEMU powers off.
write_test_bat() {
  local drive="$1" qexit="$2"
  {
    echo "@echo off"
    if [ "$qexit" = 1 ]; then
      # FreeCOM needs COMSPEC to find itself for COMMAND /C.
      echo "set COMSPEC=A:\\FREEDOS\\BIN\\COMMAND.COM"
    fi
    echo "${drive}\\WWIVFOSS.EXE -P1 ${drive}\\FOSTEST.EXE > ${drive}\\LOG.TXT"
    for n in 3 2 1; do
      echo "if errorlevel $n goto e$n"
    done
    for n in 0 1 2 3; do
      echo ":e$n"
      echo "echo $n > ${drive}\\RESULT.TXT"
      if [ "$qexit" = 1 ]; then
        echo "${drive}\\QEXIT$n.COM"
      fi
      echo "goto done"
    done
    echo ":done"
  } | sed 's/$/\r/' > "$work/TEST.BAT"
}

# Start the BBS side first; the emulator connects to it, as with WWIV's
# listen-socket exec mode.
python3 "$root/scripts/bbs.py" "$port" "$scenario" "$timeout_secs" "$work/ready" &
bbs_pid=$!
for _ in $(seq 1 50); do
  [ -f "$work/ready" ] && break
  sleep 0.1
done
[ -f "$work/ready" ] || fail "BBS harness did not start"

echo "Running $emu / $scenario (BBS listening on 127.0.0.1:$port)"
case "$emu" in
  qemu)
    img="$work/test.img"
    cp "$dev/freedos/boot.img" "$img"
    printf 'FILES=20\r\nBUFFERS=10\r\nSHELL=\\FREEDOS\\BIN\\COMMAND.COM \\FREEDOS\\BIN /E:1024 /P=\\TEST.BAT\r\n' \
      > "$work/FDCONFIG.SYS"
    for n in 0 1 2 3; do
      printf "\\xb0\\x0${n}\\xe6\\xf4\\xcd\\x20" > "$work/QEXIT${n}.COM"
    done
    write_test_bat "A:" 1
    mcopy -o -i "$img" "$work/FDCONFIG.SYS" "$work/TEST.BAT" \
      "$work"/QEXIT?.COM "$root/dos/wwivfoss.exe" \
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

if [ "$emu" = qemu ]; then
  mcopy -o -i "$img" ::/LOG.TXT ::/RESULT.TXT "$work/" 2>/dev/null || true
fi
[ -f "$work/RESULT.TXT" ] || fail "no RESULT.TXT; the test batch file did not finish"
errorlevel="$(tr -dc '0-9' < "$work/RESULT.TXT")"
if [ "$errorlevel" != "$want_errorlevel" ]; then
  fail "errorlevel $errorlevel, wanted $want_errorlevel"
fi
echo "ok - door exited with errorlevel $errorlevel"
passed=1
echo "PASS ($emu/$scenario)"
