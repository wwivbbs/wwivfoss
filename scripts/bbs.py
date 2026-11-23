#!/usr/bin/env python3
"""Plays the BBS side of a door session for scripts/test.sh.

    bbs.py PORT SCENARIO FRAMING TIMEOUT READY_FILE [MONITOR_PORT]

Listens on 127.0.0.1:PORT (like WWIV's listen-socket exec mode), creates
READY_FILE once listening, accepts the emulator's connection to COM1 and runs
SCENARIO against FOSTEST:

    echo    banner, echo, send Q, expect BYE
    hangup  banner, echo, then the caller drops
    dtr     banner, echo, send H; the door lowers DTR and we must see it
    door    a real door: wait for $DOOR_EXPECT, then hang up (the test
            checks that the door notices and exits). $DOOR_EXPECT may list
            alternatives separated by "|" and matches with ANSI codes
            removed too. $DOOR_MIN_BYTES waits for that much output
            instead of (or as well as) text. $DOOR_STRAY, if set,
            is sent when the door connects, as WWIV does (escapes like
            \\r ok; DOOR_STRAY_WHEN=output waits for its first output)
    zmodem  round trip with a Zmodem program in DOS (FDSZ): lrzsz sends
            $ZM_DIR/DOWN.BIN, DOS receives it and sends it back, and the
            copy that returns must match byte for byte
    twocalls  (resident WWIVFOSS -E) call 1: banner, echo, hang up; call 2
            on a new connection: FF 03, banner, echo, Q. Proves the port
            recovers after a hangup. TWOCALLS_SKIP_FF03=1 omits call 2's
            FF 03 (the test must then fail)
    speed   32 KB each way with FOSTEST R/T; prints the throughput
    funcs   FOSTEST's self-tests: F (local functions), P (peek), X (purge),
            B (all 256 byte values both ways), K (keyboard, only with a
            QEMU MONITOR_PORT to type the key), then Q

FRAMING is "raw" (carrier is the TCP connection itself, as with DOSBox-X) or
"inband" (WWIVFOSS -E: FF escapes carry line state; see foss_protocol.h).

Exits 0 when the BBS side of the scenario completed. Normally run by
scripts/test.sh, not by hand.
"""
import os
import re
import select
import shutil
import socket
import subprocess
import sys
import threading
import time

ESC = 0xFF
LINE_RTS, LINE_DTR = 0x01, 0x02

if len(sys.argv) < 6 or sys.argv[1] in ("-h", "--help"):
    print(__doc__.strip())
    sys.exit(0 if len(sys.argv) > 1 and sys.argv[1] in ("-h", "--help") else 2)

port, scenario, framing, timeout, ready_file = sys.argv[1:6]
monitor_port = int(sys.argv[6]) if len(sys.argv) > 6 else None
inband = framing == "inband"
deadline = time.monotonic() + int(timeout)


class Door:
    """The emulator's end of the socket, with optional in-band framing."""

    def __init__(self, conn):
        self.conn = conn
        self.data = b""
        self.lines = LINE_RTS | LINE_DTR   # door's line state (DTR up)
        self._escape = False

    def _feed(self, chunk):
        self.data += self.decode(chunk)

    def decode(self, chunk):
        """Strips in-band line state from chunk; returns the payload."""
        if not inband:
            return chunk
        out = bytearray()
        for b in chunk:
            if self._escape:
                self._escape = False
                if b == ESC:
                    out.append(b)
                else:
                    self.lines = b
            elif b == ESC:
                self._escape = True
            else:
                out.append(b)
        return bytes(out)

    def wait_for(self, done, what):
        while not done():
            if time.monotonic() > deadline:
                fail(f"timed out waiting for {what}")
            try:
                chunk = self.conn.recv(4096)
            except socket.timeout:
                continue
            if not chunk:
                fail(f"connection closed while waiting for {what}")
            self._feed(chunk)

    def plain(self):
        """The data received so far with ANSI escape sequences removed."""
        return re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", self.data)

    def expect(self, text):
        if isinstance(text, str):
            text = text.encode()
        self.wait_for(lambda: text in self.data, repr(text))

    def expect_any(self, alternatives):
        """Waits until any of the "|"-separated texts appears, in the raw
        data or with ANSI codes removed (doors color single letters)."""
        wants = [a.encode() for a in alternatives.split("|")]
        self.wait_for(lambda: any(w in self.data or w in self.plain() for w in wants),
                      " or ".join(repr(w) for w in wants))
        return next(w for w in wants if w in self.data or w in self.plain())

    def expect_ok(self, name):
        """Waits for FOSTEST's "<name> OK", failing on "<name> FAIL ..."."""
        ok, bad = f"{name} OK".encode(), f"{name} FAIL".encode()
        self.wait_for(lambda: ok in self.data or bad in self.data,
                      f"{name} result")
        m = re.search(rb"%s FAIL ([^\r\n]*)" % name.encode(), self.data)
        if m:
            fail(f"{name}: {m.group(1).decode('cp437')}")
        print(f"ok - {name}")

    def send(self, data):
        if inband:
            data = data.replace(b"\xff", b"\xff\xff")
        self.conn.sendall(data)

    def start_call(self):
        """With in-band framing, the BBS reports RTS|DTR up first on every
        connection (foss_protocol.h): after a hangup WWIVFOSS keeps the UART
        in loopback until it sees DTR again."""
        if inband:
            self.conn.sendall(bytes([ESC, LINE_RTS | LINE_DTR]))

    def hang_up(self):
        if inband:
            self.conn.sendall(bytes([ESC, LINE_RTS]))   # DTR low
        self.conn.close()


door = None


def qemu_sendkey(key):
    """Types a key on the emulated DOS console through the QEMU monitor."""
    with socket.create_connection(("127.0.0.1", monitor_port), timeout=5) as m:
        m.sendall(f"sendkey {key}\n".encode())
        time.sleep(0.5)


def zmodem(cmd, cwd):
    """Runs an lrzsz command with its stdio connected to the door."""
    log = open(os.path.join(cwd, f"{cmd[0]}.log"), "wb")
    proc = subprocess.Popen(cmd, cwd=cwd, stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=log)

    def to_door():
        while True:
            chunk = proc.stdout.read1(4096)
            if not chunk:
                return
            door.send(chunk)

    pump = threading.Thread(target=to_door, daemon=True)
    pump.start()
    first = None
    while proc.poll() is None:
        if time.monotonic() > deadline:
            proc.kill()
            fail(f"timed out during {' '.join(cmd)}")
        ready, _, _ = select.select([door.conn], [], [], 0.2)
        if not ready:
            continue
        chunk = door.conn.recv(4096)
        if not chunk:
            proc.kill()
            fail(f"connection closed during {' '.join(cmd)}")
        if first is None:
            first = time.monotonic()
        try:
            proc.stdin.write(door.decode(chunk))
            proc.stdin.flush()
        except BrokenPipeError:
            break
    pump.join(5)
    return proc.wait(), first


def lrzsz(name):
    """lrzsz installs as sz/rz on Debian and lsz/lrz on some systems."""
    for candidate in (name, "l" + name):
        if shutil.which(candidate):
            return candidate
    fail(f"{name} not found: sudo apt-get install -y lrzsz")


def fail(msg):
    shown = door.data.decode("cp437").replace("\r", "") if door else ""
    sys.exit(f"FAIL: {msg}\n--- received from DOS ---\n{shown}\n"
             "-------------------------")


server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", int(port)))
server.listen(1)
open(ready_file, "w").close()

server.settimeout(int(timeout))
try:
    conn, _ = server.accept()
except socket.timeout:
    fail("the emulator never connected")
conn.settimeout(1)
door = Door(conn)
door.start_call()

# Stray input as the door starts, e.g. the Enter a caller typed after
# picking the door, which WWIV forwards to it the moment the door connects
# (wwivbbs/wwiv#1737). DOOR_STRAY_WHEN=output waits for the door's first
# output instead.
if os.environ.get("DOOR_STRAY"):
    if os.environ.get("DOOR_STRAY_WHEN") == "output":
        door.wait_for(lambda: len(door.data) > 0, "the door's first output")
    door.send(os.environ["DOOR_STRAY"].encode().decode("unicode_escape").encode("latin-1"))

if scenario == "zmodem":
    zm = os.environ["ZM_DIR"]
    original = open(os.path.join(zm, "DOWN.BIN"), "rb").read()
    back = os.path.join(zm, "back")
    os.makedirs(back, exist_ok=True)

    # Time each transfer from the first byte FDSZ sends, so emulator boot
    # time doesn't count.
    rc, t0 = zmodem([lrzsz("sz"), "-b", "DOWN.BIN"], zm)
    if rc != 0:
        fail(f"sz exited {rc}; see {zm}/sz.log")
    t1 = time.monotonic()
    print(f"ok - sent {len(original)} bytes to FDSZ in {t1 - t0:.1f}s "
          f"({len(original) / (t1 - t0) / 1024:.1f} KB/s)")

    rc, _ = zmodem([lrzsz("rz"), "-b", "-y"], back)
    if rc != 0:
        fail(f"rz exited {rc}; see {back}/rz.log")
    t2 = time.monotonic()
    path = os.path.join(back, "DOWN.BIN")
    if not os.path.exists(path):
        path = os.path.join(back, "down.bin")
    got = open(path, "rb").read() if os.path.exists(path) else b""
    if got != original:
        fail(f"round trip mismatch: sent {len(original)} bytes, got back {len(got)}")
    print(f"ok - received it back intact in {t2 - t1:.1f}s "
          f"({len(got) / (t2 - t1) / 1024:.1f} KB/s)")
    time.sleep(1)
    sys.exit(0)

if scenario == "door":
    if os.environ.get("DOOR_EXPECT"):
        seen = door.expect_any(os.environ["DOOR_EXPECT"])
        print(f"ok - door sent {seen.decode()!r}")
    min_bytes = int(os.environ.get("DOOR_MIN_BYTES") or 0)
    if min_bytes:
        door.wait_for(lambda: len(door.data) >= min_bytes, f"{min_bytes} bytes")
        print(f"ok - door sent at least {min_bytes} bytes")
    door.hang_up()
    print(f"ok - caller hung up ({'DTR low in-band, ' if inband else ''}"
          "socket closed)")
    sys.exit(0)

door.expect("FOSTEST ready")
print("ok - banner received via FOSSIL block write")

door.send(b"hello\r")
door.expect("hello")
print("ok - echo via FOSSIL receive/transmit")

if scenario == "echo":
    door.send(b"Q")
    door.expect("BYE")
    print("ok - BYE received")
    time.sleep(1)  # let the door finish before the socket goes away
elif scenario == "hangup":
    door.hang_up()
    print(f"ok - caller hung up ({'DTR low in-band, ' if inband else ''}"
          "socket closed)")
elif scenario == "dtr":
    if not inband:
        fail("the dtr scenario needs inband framing to observe DTR")
    door.send(b"H")
    door.expect("HANGUP")
    door.wait_for(lambda: not door.lines & LINE_DTR, "DTR to drop")
    print("ok - door lowered DTR (seen in-band)")
    conn.close()
elif scenario == "twocalls":
    door.hang_up()
    print("ok - call 1: caller hung up")
    try:
        conn, _ = server.accept()
    except socket.timeout:
        fail("the emulator never reconnected for call 2")
    conn.settimeout(1)
    door = Door(conn)
    print("ok - call 2: the emulator reconnected")
    if os.environ.get("TWOCALLS_SKIP_FF03"):
        print("   (not sending FF 03 on call 2)")
    else:
        door.start_call()
    door.expect("FOSTEST ready")
    print("ok - call 2: banner received; the port recovered")
    door.send(b"hello\r")
    door.expect("hello")
    door.send(b"Q")
    door.expect("BYE")
    print("ok - call 2: echo and BYE")
    time.sleep(1)
elif scenario == "speed":
    door.send(b"R")
    door.expect("RX READY")
    t0 = time.monotonic()
    door.send(bytes(range(256)) * 128)
    door.expect_ok("RX")
    t1 = time.monotonic()
    ticks = re.search(rb"RX TICKS (\d+)", door.data)
    print(f"ok - door received 32 KB in {t1 - t0:.1f}s "
          f"({32 / (t1 - t0):.1f} KB/s; {ticks.group(1).decode() if ticks else '?'} DOS ticks)")
    door.send(b"T")
    door.expect("TX START")
    t0 = time.monotonic()
    door.expect_ok("TX")
    t1 = time.monotonic()
    print(f"ok - door sent 32 KB in {t1 - t0:.1f}s ({32 / (t1 - t0):.1f} KB/s)")
    door.send(b"Q")
    door.expect("BYE")
    time.sleep(1)
elif scenario == "funcs":
    door.send(b"F")
    door.expect_ok("FUNCS")

    door.send(b"P")
    door.expect("PEEK READY")
    door.send(b"x")
    door.expect_ok("PEEK")

    door.send(b"X")
    door.expect("PURGE READY")
    door.send(b"junkjunk")
    door.expect_ok("PURGE")

    door.send(b"B")
    door.expect(b"BIN START\r\n" + bytes(range(256)) + b"\r\nBIN SENT")
    print("ok - received all 256 byte values in order")
    door.send(bytes(range(256)))
    door.expect_ok("BIN")

    if monitor_port:
        door.send(b"K")
        door.expect("KEY READY")
        qemu_sendkey("k")
        door.expect("KEY GOT k")
        door.expect_ok("KEY")

    door.send(b"Q")
    door.expect("BYE")
    print("ok - BYE received")
    time.sleep(1)
else:
    fail(f"unknown scenario: {scenario}")
