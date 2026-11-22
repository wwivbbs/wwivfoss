#!/bin/sh
# Build WWIVFOSS.EXE and FOSTEST.EXE with the Open Watcom from .devenv/
# (run scripts/setup-dev.sh first), or with one already on PATH/WATCOM.
#
#   scripts/build.sh          build
#   scripts/build.sh clean    clean
set -eu

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
