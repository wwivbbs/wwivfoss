# Food Fight 4.6 with a dead BBS: heartbeats stop and the socket stays open.
#
# Food Fight checks carrier by reading the UART's modem status register,
# never FOSSIL status, so only WWIVFOSS -H's timer path (no data for 3
# heartbeats -> loopback, DCD reads low) can tell it the caller is gone.
# Needs in-band framing, so QEMU only (directly and through qemudoor.sh). Sourced by scripts/test.sh.

. "$(dirname "${BASH_SOURCE[0]}")/foodfite.sh"
DOOR_HANGUP=silent
DOOR_EMUS="qemu qemudoor"
