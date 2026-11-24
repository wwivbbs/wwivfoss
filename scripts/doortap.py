#!/usr/bin/env python3
"""Logs every byte between the BBS and a door's emulator.

Stands in for the emulator binary of dosdoor.sh or qemudoor.sh: it moves the
emulator's COM1 connection to a port of its own, relays it to the BBS's port,
and logs both directions with timestamps.

    DOSDOOR_DOSBOX=/path/to/doortap.py  dosdoor.sh ...
    QEMUDOOR_QEMU=/path/to/doortap.py   qemudoor.sh ...

With WWIV, set the variable in the environment wwivd (or bbs) runs with; it
reaches the launcher through the chain. The emulator is found from its
arguments: -conf (DOSBox-X, runs dosbox-x) or -chardev (QEMU, runs
qemu-system-i386); DOORTAP_EMU overrides the binary.

Environment:
  DOORTAP_LOG   log file (default: doortap-<pid>.log in $TMPDIR or /tmp)

Log lines: seconds since connect, direction, byte count, the first 64 bytes
in hex. BBS>door is what the BBS sent (heartbeats show as ff 03); a count
of 0 is that side closing the connection.
"""
import ctypes
import os
import re
import signal
import socket
import subprocess
import sys
import threading
import time


def main():
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help") and len(args) == 1:
        print(__doc__.strip())
        return 0
    log_path = os.environ.get("DOORTAP_LOG") or os.path.join(
        os.environ.get("TMPDIR", "/tmp"), f"doortap-{os.getpid()}.log")

    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)
    mine = srv.getsockname()[1]

    if "-chardev" in args:
        emu = os.environ.get("DOORTAP_EMU", "qemu-system-i386")
        i = args.index("-chardev") + 1
        m = re.search(r"port=(\d+)", args[i])
        bbs_port = int(m.group(1))
        args[i] = args[i].replace(m.group(0), f"port={mine}")
    elif "-conf" in args:
        emu = os.environ.get("DOORTAP_EMU", "dosbox-x")
        conf = args[args.index("-conf") + 1]
        text = open(conf).read()
        m = re.search(r"(serial1\s*=.*?port:)(\d+)", text)
        bbs_port = int(m.group(2))
        open(conf, "w").write(text[:m.start(2)] + str(mine) + text[m.end(2):])
    else:
        sys.exit("doortap: can't tell the emulator from its arguments")

    log = open(log_path, "w", buffering=1)
    log.write(f"# BBS port {bbs_port}, emulator on {mine}: {emu}\n")

    def relay():
        door, _ = srv.accept()
        bbs = socket.create_connection(("127.0.0.1", bbs_port))
        t0 = time.time()
        lock = threading.Lock()

        def pump(src, dst, tag):
            while True:
                try:
                    data = src.recv(4096)
                except OSError:
                    data = b""
                with lock:
                    log.write(f"{time.time() - t0:8.2f} {tag} {len(data):5} "
                              f"{data[:64].hex(' ')}\n")
                if not data:
                    try:
                        dst.shutdown(socket.SHUT_WR)
                    except OSError:
                        pass
                    return
                try:
                    dst.sendall(data)
                except OSError:
                    return

        threading.Thread(target=pump, args=(bbs, door, "BBS>door"), daemon=True).start()
        pump(door, bbs, "door>BBS")

    threading.Thread(target=relay, daemon=True).start()

    def die_with_parent():
        # dosdoor.sh execs us, so WWIV's SIGKILL on hang-up lands here; take
        # the emulator down with us as it would have been.
        libc = ctypes.CDLL(None, use_errno=True)
        libc.prctl(1, signal.SIGTERM)  # PR_SET_PDEATHSIG

    proc = subprocess.Popen([emu] + args, preexec_fn=die_with_parent)
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, lambda s, f: proc.send_signal(signal.SIGTERM))
    rc = proc.wait()
    time.sleep(0.5)  # let the relay log the closes
    log.write(f"# emulator exited with {rc}\n")
    return rc


if __name__ == "__main__":
    sys.exit(main())
