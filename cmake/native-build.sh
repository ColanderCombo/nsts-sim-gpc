#!/bin/bash
# Build the addons against the running Node's headers: machrt.c, the Mach
# thread policy, and shmring.c, the shared-memory segment.  Compile directly:
# each addon is one file of Node-API and needs no gyp.
#   cmake/native-build.sh <source-dir> <output-dir> [machrt|shmring ...]
set -e
SRC="$1"; OUT="$2"; shift 2
mkdir -p "$OUT"
INC=$(node -p "require('path').join(require('path').dirname(process.execPath),'..','include','node')")
if [ -n "${CC:-}" ]; then
  command -v "$CC" >/dev/null 2>&1 || {
    echo "C compiler not found: $CC" >&2
    exit 1
  }
else
  for candidate in clang gcc cc; do
    if command -v "$candidate" >/dev/null 2>&1; then
      CC="$candidate"
      break
    fi
  done
  if [ -z "${CC:-}" ]; then
    echo "No C compiler found; set CC to clang or gcc" >&2
    exit 1
  fi
fi
case "$(uname -s)" in
  Darwin) LDFLAGS="-dynamiclib -undefined dynamic_lookup" ;;
  *)      LDFLAGS="-shared" ;;
esac
MODS=${*:-machrt shmring}
for mod in $MODS; do
  "$CC" -O2 -fPIC -Wall -Wextra -I"$INC" -DNODE_GYP_MODULE_NAME="$mod" \
        $LDFLAGS -o "$OUT/$mod.node" "$SRC/$mod.c"
  echo "built $OUT/$mod.node"
done
