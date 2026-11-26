#!/usr/bin/env python3
"""Relays a DOS program's serial port to WWIV, turning WWIV 4.x output
codes into ANSI on the way to the caller. Used by wwivchain.sh.

    heartrelay.py BBS_PORT PORT_FILE

Listens on a free local port and writes its number to PORT_FILE. When the
emulator connects there, connects to WWIV on BBS_PORT (the chain's %Z) and
relays both ways until either side closes. From the program to the caller:

    ^C0-^C9   WWIV heart codes: ANSI colors (WWIV's default color set)
    ^L        clear screen

The caller's keys go to the program unchanged.

Set HEARTRELAY_LOG to a file to log the bytes each way (troubleshooting).
"""
import os
import select
import socket
import sys

# WWIV's default colors for ^C0-^C9 (PC attributes).
COLORS = [7, 11, 14, 5, 31, 2, 12, 9, 6, 3]
PC_TO_ANSI = [0, 4, 2, 6, 1, 5, 3, 7]


def ansi(attr):
    parts = ["0"]
    if attr & 0x08:
        parts.append("1")
    if attr & 0x80:
        parts.append("5")
    parts.append("3%d" % PC_TO_ANSI[attr & 7])
    parts.append("4%d" % PC_TO_ANSI[(attr >> 4) & 7])
    return ("\x1b[" + ";".join(parts) + "m").encode()


HEART = {ord("0") + i: ansi(a) for i, a in enumerate(COLORS)}


class Translator:
    def __init__(self):
        self.after_heart = False

    def __call__(self, data):
        out = bytearray()
        for b in data:
            if self.after_heart:
                self.after_heart = False
                out += HEART.get(b, b"")
                continue
            if b == 0x03:
                self.after_heart = True
            elif b == 0x0C:
                out += b"\x1b[2J\x1b[H"
            else:
                out.append(b)
        return bytes(out)


def main():
    bbs_port, port_file = int(sys.argv[1]), sys.argv[2]
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    with open(port_file, "w") as f:
        f.write("%d\n" % listener.getsockname()[1])
    listener.settimeout(120)
    door, _ = listener.accept()
    listener.close()
    bbs = socket.create_connection(("127.0.0.1", bbs_port))
    for s in (door, bbs):
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    translate = Translator()
    log = open(os.environ["HEARTRELAY_LOG"], "a") if os.environ.get("HEARTRELAY_LOG") else None
    while True:
        ready, _, _ = select.select([door, bbs], [], [])
        if door in ready:
            data = door.recv(4096)
            if log:
                log.write("door> %r\n" % data)
                log.flush()
            if not data:
                break
            bbs.sendall(translate(data))
        if bbs in ready:
            data = bbs.recv(4096)
            if log:
                log.write("bbs>  %r\n" % data)
                log.flush()
            if not data:
                break
            door.sendall(data)
    door.close()
    bbs.close()


if __name__ == "__main__":
    main()
