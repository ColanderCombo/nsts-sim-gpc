#!/bin/bash
#
# runs the AP-101 simulator.
#   - also automatically builds the js 
#
# Usage:
#   GPC.sh run <fcm>       — batch execution
#   GPC.sh debug <fcm>     — interactive REPL debugger
#   GPC.sh dbg-serve <fcm> — headless debugger on a socket
#   GPC.sh dbg-client ...  — send a command to a dbg-serve session
#   GPC.sh gui [fcm]       — Electron GUI debugger
#   GPC.sh dump <fcm>      — FCM dump report
#   GPC.sh disasm <fcm>    — disassembly listing
#
DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "$1" = "gui" ]; then
    # electron-esbuild build cleans dist/, and the mmu and gpcmd bundles
    # live there too -- a GPC needs both beside it to have anything on its
    # busses to talk to, so put them back.
    "${DIR}/node_modules/.bin/electron-esbuild" build || exit $?
    node "${DIR}/esbuild/esbuild.mmu.config.js"   || exit $?
    node "${DIR}/esbuild/esbuild.gpcmd.config.js" || exit $?
fi
node "${DIR}/esbuild/esbuild.gpc.config.js" || exit $?
exec node "${DIR}/dist/gpc.js" "$@"
