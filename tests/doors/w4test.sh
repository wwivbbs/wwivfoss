# W4TEST under WWIV4CHN: every WWIV 4 chain function and DOS console call.
#
# W4TEST (tools/wwiv4chn/w4test) is our own WWIV 4.07+ style chain: it
# finds the function table as SKELETON.C does and calls each function; the
# script below answers it and checks what comes back. Run scripts/build.sh
# first. Sourced by scripts/test.sh.

DOOR_SRC="$root/tools/wwiv4chn/w4test"
DOOR_CMD="WWIV4CHN.EXE W4TEST.EXE CHAIN.TXT"

# Per run, so a rebuild is picked up: DOORDIR DROPDIR DRIVE.
door_dropfiles() {
  cp "$root/tools/wwiv4chn/wwiv4chn.exe" "$1/WWIV4CHN.EXE"
  cp "$root/tools/wwiv4chn/w4test/w4test.exe" "$1/W4TEST.EXE"
  write_chain "$1"
}

DOOR_EXPECT="W4TEST ready"
DOOR_SCRIPT='
< VERSION 430 6A same
< OUTSTR ok
< OUTCHR ok
< \x1b[0;32;40mHEART\x1b[0;37;40m
< \x1b[0;1;33;40mPRT ok\x1b[0;37;40m
< \x1b[0;35;40mANSIC\x1b[0;37;40m
< MPL\x1b[0;1;37;44m     \x1b[5D\x1b[0;37;40m\r\n
< PLA ok
< ABORT=0
< NAME=RUSH FAN SL=100
< TAB[    ]
< EMPTY=1
< INPUT?
> hello\r
< GOT [HELLO]
< INPUTL?
> Mixed Case\r
< GOT [Mixed Case]
< YN?
> y
< Yes
< YN=1
< NY?
> \r
< Yes
< NY=1
< ONEK?
> xb
< ONEK=B
< GETKEY?
> k
< GETKEY=107
< INLI?
> abcde abcde abcde abcde abcde abcde abcde abcde abcde abcde abcde abcde abcde a
< INLI len=79 end=1 ROLL [a]
> fter\r
< INLI2 [after]
< DOS0A?
> dos line\r
< DOS0A [dos line]
< DOS01?
> z
< DOS01=z
< HANGUP?
'

# After the hang-up, WWIV4CHN returned into W4TEST's hang-up handler.
door_check() {
  local f
  f="$(find "$1" -maxdepth 1 -iname W4HUP.TXT | head -1)"
  if [ -z "$f" ]; then
    echo "W4HUP.TXT missing: the hang-up handler (slot 20) didn't run" >&2
    return 1
  fi
  echo "ok - the chain's hang-up handler ran"
}
