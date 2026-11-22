#!/usr/bin/env python3
"""Plays the BBS side of a door session for scripts/test.sh.

    bbs.py PORT SCENARIO FRAMING TIMEOUT READY_FILE [MONITOR_PORT]

Listens on 127.0.0.1:PORT (like WWIV's listen-socket exec mode), creates
READY_FILE once listening, accepts the emulator's connection to COM1 and runs
SCENARIO against FOSTEST:

    echo    banner, echo, send Q, expect BYE
    hangup  banner, echo, then the caller drops
    dtr     banner, echo, send H; the door lowers DTR and we must see it
    funcs   FOSTEST's self-tests: F (local functions), P (peek), X (purge),
            B (all 256 byte values both ways), K (keyboard, only with a
            QEMU MONITOR_PORT to type the key), then Q

FRAMING is "raw" (carrier is the TCP connection itself, as with DOSBox-X) or
"inband" (WWIVFOSS -E: FF escapes carry line state; see foss_protocol.h).

Exits 0 when the BBS side of the scenario completed.
"""
import re
import socket
import sys
import time

ESC = 0xFF
LINE_RTS, LINE_DTR = 0x01, 0x02

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
        if not inband:
            self.data += chunk
            return
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
        self.data += bytes(out)

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

    def expect(self, text):
        if isinstance(text, str):
            text = text.encode()
        self.wait_for(lambda: text in self.data, repr(text))

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
