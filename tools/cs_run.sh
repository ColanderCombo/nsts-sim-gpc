#!/bin/bash
# One two-GPC run: GPC 4 to OPS 0 on port 4484, GPC 1 IPLed beside it on
# 4481, WAIT seconds of observation, then each GPC's set mask (TFCMCSM at
# 0x9d58: 0x10 GPC 1, 0x02 GPC 4, 0x12 both), IC bus counts, pacing report
# and the logpoints hit.  tools/cs_lrus.sh first.
#   tools/cs_run.sh <tag> [wait-seconds] [base-port]
# CS_TAP and CS_TRACE_BCE pass through to tools/cs_gpc.sh.
cd "$(dirname "$0")/.." || exit 1
S=${CS_DIR:-/tmp/cs}; mkdir -p $S/logs
T=$1; WAIT=${2:-150}; export BASE=${3:-7950}
dbg() { printf "$2" | timeout 10 node build/dist/gpc.js dbg-client --port $1 2>&1; }
nohup tools/cs_gpc.sh 4 4484 $T > $S/logs/drv4$T.log 2>&1 &
node build/dist/gpc.js dbg-client --port 4484 --wait-for 'runout, syncout' --timeout 240 discretes > /dev/null
echo "GPC 4 OPS 0 at $(date +%T)"; sleep 20
nohup tools/cs_gpc.sh 1 4481 $T > $S/logs/drv1$T.log 2>&1 &
node build/dist/gpc.js dbg-client --port 4481 --wait-for 'runout, syncout' --timeout 300 discretes > /dev/null
echo "GPC 1 PASS up at $(date +%T)"; grep 'ITEM\|LOAD' $S/logs/drv1$T.log
sleep $WAIT
for p in 4481 4484; do echo "=== $(date +%T) port $p"; dbg $p 'mem 0x9caa 4\nmem 0x9d58 1\nbus\nrealtime\n' | grep -v 'DK\|PL\|LB\|FC\|MM\|IP\|monitor\|IC[235]'; done
echo '--- logpoints:'; grep -h '"logpoint"' $S/gpc1$T.ndjson $S/gpc4$T.ndjson | python3 -c "
import sys,json
for l in sys.stdin:
    r=json.loads(l); print(r['stamp']['wall'][11:23], r['stamp']['simSec'], r['body']['name'])" | sort | head -40
