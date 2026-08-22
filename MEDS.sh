#!/bin/bash
#
# runs the MEDS glass-cockpit simulator (MDU displays + IDPs).
#   - also automatically builds the js
#
# Usage:
#   MEDS.sh <lru...>            — launch LRUs, e.g. MEDS.sh crt1 idp1
#   MEDS.sh --list              — list available LRU names
#   MEDS.sh --display AE_PFD crt1
#
# LRU definitions live in config/meds.json (override with --config or
# the NSTS_SIM_CONFIG env var).
#
DIR="$(cd "$(dirname "$0")" && pwd)"

"${DIR}/node_modules/.bin/electron-esbuild" build || exit $?

# electron-esbuild CLEANS dist/, which takes the node bundles with it, so
# rebuild them here -- otherwise the next `node dist/gpcmd.js` after a MEDS
# launch fails with MODULE_NOT_FOUND.
for cfg in gpc gpcmd mmu; do
    node "${DIR}/esbuild/esbuild.${cfg}.config.js" >/dev/null || exit $?
done

exec "${DIR}/node_modules/.bin/electron" "${DIR}/dist/main/main.js" meds "$@"
