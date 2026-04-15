#!/bin/bash
#
# runs the AP-101 simulator.
#   - also automatically builds the js 
#
# Usage:
#   GPC.sh run <fcm>       — batch execution
#   GPC.sh debug <fcm>     — interactive REPL debugger
#   GPC.sh gui [fcm]       — Electron GUI debugger
#   GPC.sh dump <fcm>      — FCM dump report
#   GPC.sh disasm <fcm>    — disassembly listing
#
DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "$1" = "gui" ]; then
    "${DIR}/node_modules/.bin/electron-esbuild" build || exit $?
fi
node "${DIR}/esbuild/esbuild.gpc.config.js" || exit $?
exec node "${DIR}/dist/gpc.js" "$@"
