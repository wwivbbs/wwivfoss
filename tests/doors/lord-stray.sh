# LORD 4.06 with a stray CR NUL arriving as it starts (regression test).
#
# WWIV forwards the Enter typed after the chain number to the door
# (wwivbbs/wwiv#1737). That byte arriving during LORD's RIP detection made
# DOSBox-X drop a THRE interrupt, and WWIVFOSS's transmitter stalled for
# good: flush (08h) waited forever on a tx_busy flag nothing would clear.
#
# KNOWN GAP: this harness setup does not yet reproduce that stall; the old
# build passes too. It reproduces reliably when the door runs the way
# configs/wwiv/dosdoor.sh lays it out (drop files on T:, WWIVFOSS on W:,
# started from autoexec). TODO: run door tests through dosdoor.sh itself.
# Sourced by scripts/test.sh.

. "$(dirname "${BASH_SOURCE[0]}")/lord.sh"
DOOR_STRAY='\r\x00'
# LORD shows random intro screens, so check volume instead of text: the
# stall stopped output at ~60 bytes; a healthy start sends well over 1 KB.
DOOR_EXPECT=
DOOR_MIN_BYTES=1000

# Run as node 2, as WWIV's first telnet node would (wwivd starts at 2).
DOOR_CMD="LORD.EXE 2 /DREW"
eval "lord_prepare() $(declare -f door_prepare | tail -n +2)"
door_prepare() {
  lord_prepare "$1"
  sed 's/for node 1/for node 2/; s/;NODE1/;NODE2/' "$1/NODE1.DAT" > "$1/NODE2.DAT"
}
