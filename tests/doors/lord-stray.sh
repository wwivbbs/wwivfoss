# LORD 4.06 with a stray CR NUL arriving as it starts (regression test).
#
# WWIV forwards the Enter typed after the chain number to the door
# (wwivbbs/wwiv#1737). That byte arriving during LORD's RIP detection made
# DOSBox-X drop a THRE interrupt, and WWIVFOSS's transmitter stalled for
# good: flush (08h) waited forever on a tx_busy flag nothing would clear.
#
# It takes slow UART interrupt service to lose that interrupt. dosdoor.sh
# originally left command echo on in autoexec, which slowed DOSBox-X down
# exactly that way; DOOR_DOSDOOR_ECHO=1 turns it back on so the test still
# exercises the lost-interrupt path. Reproduces with
# "scripts/test.sh dosdoor door:lord-stray"; the qemu/dosbox layouts don't.
# Sourced by scripts/test.sh.

. "$(dirname "${BASH_SOURCE[0]}")/lord.sh"
DOOR_STRAY='\r\x00'
# LORD shows random intro screens, so check volume instead of text: the
# stall stopped output at ~60 bytes; a healthy start sends well over 1 KB.
DOOR_EXPECT=
DOOR_MIN_BYTES=1000
# Run as node 2, as WWIV's first telnet node would (wwivd starts at 2).
DOOR_CMD="LORD.EXE 2 /DREW"
# Echo on in dosdoor mode: slow interrupt service, see above.
DOOR_DOSDOOR_ECHO=1
