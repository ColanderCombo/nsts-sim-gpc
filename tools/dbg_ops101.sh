#!/bin/bash
DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR" || exit 1
BASE="${1:-7700}"
DBG="${2:-4477}"
export NSTS_BASE_PORT="$BASE"

dbg() { printf "$1" | node build/dist/gpc.js dbg-client --port "$DBG" > /dev/null 2>&1; }
key() { node build/dist/gpcmd.js key --idp 1 "$@" > /dev/null 2>&1; sleep 3; }
ops() { key "$@"; key "$@"; }
mm() {
    w=$(timeout 3 node build/dist/ddu.js watch FC1 --raw --msg MEDS1 2>/dev/null | grep MEDS1 | head -1 | awk '{print $12}')
    if [ -n "$w" ]; then printf '%d' "0x$w"; else echo none; fi
}

dbg 'realtime on --idletimeout 900\ndiscset crta on --b\n'
(echo continue | node build/dist/gpc.js dbg-client --port "$DBG" --timeout 3000 > /dev/null 2>&1 &)
sleep 30
dbg 'discset mm1src off\n'
ops OPS 9 0 1 PRO
sleep 60
echo "OPS 901; editing the G1 NBAT"
key SPEC 0 PRO
for e in "1 PLUS 1" "7 PLUS 4" "8 PLUS 4" "9 PLUS 4" "10 PLUS 4"; do key ITEM $e EXEC; done
ops OPS 1 0 1 PRO
sleep 90
echo "MEDS message 1 word 8 on FC1: major mode $(mm)"
