#!/usr/bin/env python3
"""Plays the BBS side of a door session for scripts/test.sh.

    bbs.py PORT SCENARIO TIMEOUT READY_FILE

Listens on 127.0.0.1:PORT (like WWIV's listen-socket exec mode), creates
READY_FILE once listening, accepts the emulator's connection to COM1 and runs
SCENARIO against FOSTEST:

    echo    wait for the banner, check the echo, send Q, expect BYE
    hangup  wait for the banner, check the echo, then close the socket

Exits 0 when the BBS side of the scenario completed.
"""
import socket
import sys
import time

port, scenario, timeout, ready_file = sys.argv[1:5]
deadline = time.monotonic() + int(timeout)
received = b""


def fail(msg):
    shown = received.decode("cp437").replace("\r", "")
    sys.exit(f"FAIL: {msg}\n--- received from DOS ---\n{shown}\n"
             "-------------------------")


def expect(conn, want):
    global received
    while want.encode() not in received:
        if time.monotonic() > deadline:
            fail(f"timed out waiting for {want!r}")
        try:
            data = conn.recv(4096)
        except socket.timeout:
            continue
        if not data:
            fail(f"connection closed while waiting for {want!r}")
        received += data


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

expect(conn, "FOSTEST ready")
print("ok - banner received via FOSSIL block write")

conn.sendall(b"hello\r")
expect(conn, "hello")
print("ok - echo via FOSSIL receive/transmit")

if scenario == "echo":
    conn.sendall(b"Q")
    expect(conn, "BYE")
    print("ok - BYE received")
    time.sleep(1)  # let the door finish before the socket goes away
elif scenario == "hangup":
    conn.close()
    print("ok - closed the BBS end of the socket (caller hung up)")
else:
    fail(f"unknown scenario: {scenario}")
