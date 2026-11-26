#!/bin/sh
# Build WWIVFOSS.EXE, FOSTEST.EXE, WWIV4CHN.EXE and W4TEST.EXE with the Open Watcom from
# .devenv/ (run scripts/setup-dev.sh first), or with one already on
# PATH/WATCOM.
#
#   scripts/build.sh          build them
#   scripts/build.sh clean    remove build outputs
#   scripts/build.sh --help   this help
#
# Outputs: dos/wwivfoss.exe (+ .map), tools/fostest/fostest.exe,
#          tools/wwiv4chn/wwiv4chn.exe, tools/wwiv4chn/w4test/w4test.exe
set -eu

case "${1:-}" in
  -h|--help)
    # Print the header comment above as help.
    awk 'NR > 1 && /^#/ {sub(/^# ?/, ""); print; next} NR > 1 {exit}' "$0"
    exit 0
    ;;
esac

root="$(cd "$(dirname "$0")/.." && pwd)"
if [ -x "$root/.devenv/ow2/binl64/wcc" ]; then
  export WATCOM="$root/.devenv/ow2"
  export PATH="$WATCOM/binl64:$WATCOM/binl:$PATH"
fi
# Target headers are DOS, whatever the host is (CI's setup-watcom points
# INCLUDE at the Linux headers in lh/).
if [ -n "${WATCOM:-}" ]; then
  export INCLUDE="$WATCOM/h"
fi
if ! command -v wcc >/dev/null 2>&1; then
  echo "Open Watcom not found; run scripts/setup-dev.sh" >&2
  exit 1
fi

target="${1:-}"
(cd "$root/dos" && wmake -h $target)
(cd "$root/tools/fostest" && wmake -h $target)
(cd "$root/tools/wwiv4chn" && wmake -h $target)
(cd "$root/tools/wwiv4chn/w4test" && wmake -h $target)
