#!/usr/bin/env python3
"""Scripted telnet session against a local WWIV BBS, without wwivd.

    scripts/wwivsess.py [options] STEP...

Does what wwivd does for one call: makes a TCP connection to itself, starts
"bbs -XT -H<socket> -N<node> -U<user>" in the BBS directory with one end as
the caller's socket, and plays the caller on the other end. To WWIV it's a
real telnet session, so doors run through the same exec code paths as a
wwivd call. Differences from a wwivd call: -U logs the user on without the
name/password prompt, and wwivd's own steps (ANSI check, blocking, node
semaphores) are skipped.

Steps run in order:
    wait:TEXT    wait (up to --wait-timeout seconds) for TEXT; keeps going
                 if it never appears
    send:KEYS    send KEYS; Python escapes work (\\r, \\x00, ...)
    sleep:SECS   keep reading for SECS seconds
    show         print what arrived since the last print
    hangup       drop the connection and report how long bbs takes to exit

Received text is printed after each wait/sleep with telnet commands and
ANSI codes removed.

Example: log on as user 1 on node 2, run chain 3, wait, hang up:

    scripts/wwivsess.py wait:More? send:n wait:auto-message send:n \\
        sleep:3 send:n "wait:Scan All" send:n sleep:3 send:. \\
        "wait:Which Chain" "send:3\\r" sleep:12 hangup

Options:
    --bbsdir DIR       WWIV directory containing ./bbs (default /wwiv)
    --node N           instance number, -N (default 2)
    --user N           user number logged on with -U (default 1)
    --logdir DIR       pass --v=4 --logdir=DIR to bbs for a verbose log
    --wait-timeout S   seconds a wait: step waits (default 40)
    -q, --quiet        only print step results, not received text

The environment is passed to bbs and on to doors, so for example
DOSDOOR_LOG=dir or DOSDOOR_FLAGS=-S... reach configs/wwiv/dosdoor.sh.
"""
import argparse
import re
import socket
import subprocess
import sys
import time


def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("-h", "--help", action="store_true")
    ap.add_argument("--bbsdir", default="/wwiv")
    ap.add_argument("--node", type=int, default=2)
    ap.add_argument("--user", type=int, default=1)
    ap.add_argument("--logdir")
    ap.add_argument("--wait-timeout", type=float, default=40)
    ap.add_argument("-q", "--quiet", action="store_true")
    ap.add_argument("steps", nargs="*")
    args = ap.parse_args()
    if args.help or not args.steps:
        print(__doc__.strip())
        return 0 if args.help else 2

    srv = socket.socket()
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)
    caller = socket.create_connection(srv.getsockname())
    conn, _ = srv.accept()
    srv.close()

    cmd = ["./bbs", "-XT", f"-H{conn.fileno()}", f"-N{args.node}", f"-U{args.user}"]
    if args.logdir:
        cmd += ["--v=4", f"--logdir={args.logdir}"]
    bbs = subprocess.Popen(cmd, cwd=args.bbsdir, pass_fds=(conn.fileno(),),
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    conn.close()
    caller.settimeout(0.3)

    raw = b""
    shown = 0
    start = time.time()

    def pump(seconds):
        nonlocal raw
        end = time.time() + seconds
        while time.time() < end:
            try:
                data = caller.recv(65536)
            except socket.timeout:
                continue
            if not data:
                return False
            raw += data
        return True

    def text(data):
        data = re.sub(rb"\xff[\xfb-\xfe].|\xff\xff", b"", data)     # telnet
        data = re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", data)        # ANSI
        lines = data.decode("cp437", "replace").replace("\r", "\n").split("\n")
        return "\n".join(line.rstrip() for line in lines if line.strip())

    def show(label=""):
        nonlocal shown
        print(f"--- [{time.time() - start:5.1f}s] {label}".rstrip())
        if not args.quiet:
            print(text(raw[shown:])[-3000:])
        shown = len(raw)

    for step in args.steps:
        kind, _, arg = step.partition(":")
        if kind == "wait":
            end = time.time() + args.wait_timeout
            while arg not in text(raw[shown:]) and time.time() < end:
                if not pump(0.5):
                    print("[connection closed by bbs]")
                    break
            found = arg in text(raw[shown:])
            show(f"{'got' if found else 'TIMED OUT waiting for'} {arg!r}")
        elif kind == "send":
            caller.sendall(arg.encode().decode("unicode_escape").encode("latin-1"))
        elif kind == "sleep":
            pump(float(arg))
            show(f"after {arg}s")
        elif kind == "show":
            pump(0.5)
            show()
        elif kind == "hangup":
            caller.close()
            hung = time.time()
            print(f"--- [{hung - start:5.1f}s] hung up")
            try:
                bbs.wait(60)
                print(f"bbs exited {time.time() - hung:.1f}s after hangup, rc={bbs.returncode}")
            except subprocess.TimeoutExpired:
                print("bbs still running 60s after hangup; killing it")
                bbs.kill()
            return 0
        else:
            print(f"unknown step: {step}", file=sys.stderr)
            return 2

    # Out of steps: log off by hanging up and let bbs clean up on its own.
    pump(1)
    show()
    caller.close()
    try:
        bbs.wait(60)
    except subprocess.TimeoutExpired:
        bbs.kill()
    return 0


if __name__ == "__main__":
    sys.exit(main())
