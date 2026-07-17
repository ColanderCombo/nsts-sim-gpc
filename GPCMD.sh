#!/bin/bash
#
# gpcmd — simulate GPC command traffic to a MEDS IDP (DK bus).
#   - also automatically builds the js
#
# Usage:
#   GPCMD.sh fill <file.dfb> [--idp N]   — DATA FILL: display format to an IDP
#   GPCMD.sh time [--interval 1]         — TIME FILL: drive the DPS time header
#   GPCMD.sh resetspl                    — RESET SPL: clear the scratch pad line
#   GPCMD.sh raw <op> [hexwords...]      — arbitrary opcode
#   GPCMD.sh watch [bus]                 — print bus traffic
#
DIR="$(cd "$(dirname "$0")" && pwd)"

node "${DIR}/esbuild/esbuild.gpcmd.config.js" || exit $?
exec node "${DIR}/dist/gpcmd.js" "$@"
