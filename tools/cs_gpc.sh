#!/bin/bash
# One GPC of the private session under dbg-serve: IPL from MM1 with the mode
# switch held at RUN, discrete monitor, the PASS symbols and logpoints at
# FCMASYNC, FCMSMASK and FCMSFAIL, a record log, and ITEM 1 EXEC at the
# GPCIPL menu (IDP 1 LOAD pressed if the menu does not come by itself).
#   tools/cs_gpc.sh <gpc> <dbgport> <tag> [base-port]
# CS_TAP=1 also taps the IC busses into <tag>bus.ndjson once the PASS is up,
# and CS_TRACE_BCE=<n> traces that BCE's state to the GPC's log (GPC_IOP_BCE).
cd "$(dirname "$0")/.." || exit 1
S=${CS_DIR:-/tmp/cs}; mkdir -p $S/logs
G=$1; DBG=$2; TAG=$3; BASE=${4:-7950}
export NSTS_BASE_PORT=$BASE
node build/dist/gpc.js discretes mode run --gpc $G > $S/logs/mode$G$TAG.log 2>&1 &
echo "$! mode$G$TAG" >> $S/cs.pids
sleep 2
[ -n "$CS_TRACE_BCE" ] && export GPC_IOP_BCE=$CS_TRACE_BCE
NSTS_BUS_TIMEOUT_TRACE=1 NSTS_RECV_TIMEOUT_FLOOR_MS=10 \
  node build/dist/gpc.js dbg-serve --ipl --gpc $G --real-time --rt-idle-timeout 900 --port $DBG \
  --name cs$G --max-steps 4000000000 > $S/logs/gpc$G$TAG.log 2>&1 &
echo "$! gpc$G$TAG" >> $S/cs.pids
until grep -q "listening on" $S/logs/gpc$G$TAG.log; do sleep 1; done
printf 'busmon on --limit 1000\ndiscmon on --limit 4000\nsymload ../../build/OI340700/phase/PHASE02/PHASE02.sym.json --name pass\nlogpoint 18052 FCMASYNC\nlogpoint 19694 FCMSMASK\nlogpoint 1948c FCMSFAIL\nlog %s/gpc%s%s.ndjson --kinds stopped,discrete,logpoint,trace\n' $S $G $TAG \
  | node build/dist/gpc.js dbg-client --port $DBG
(echo continue | node build/dist/gpc.js dbg-client --port $DBG --timeout 3000 > /dev/null 2>&1 &)
echo "GPC $G running on $DBG at $(date +%T)"
node build/dist/gpc.js dbg-client --port $DBG --wait-for 'DK1  BCE 6 tx' buslog 300 > /dev/null
echo "GPC $G GPCIPL on DK1 at $(date +%T)"
sleep 8
if ! printf 'buslog 300\n' | node build/dist/gpc.js dbg-client --port $DBG 2>/dev/null | grep -q "DK1  BCE 6 tx cmd 5700"; then
  node build/dist/gpcmd.js idpload 1
  echo "IDP 1 LOAD pressed at $(date +%T)"
fi
node build/dist/gpc.js dbg-client --port $DBG --wait-for 'DK1  BCE 6 tx cmd 5700' buslog 300 > /dev/null
sleep 3
node build/dist/gpcmd.js key --idp 1 ITEM 1 EXEC > /dev/null
if [ -n "$CS_TAP" ]; then
  printf 'busmon on --bus IC1,IC4 --limit 40000\nlog %s/gpc%s%sbus.ndjson --kinds bus\n' $S $G $TAG \
    | node build/dist/gpc.js dbg-client --port $DBG > /dev/null
else
  printf 'busmon off\n' | node build/dist/gpc.js dbg-client --port $DBG > /dev/null
fi
echo "GPC $G ITEM 1 EXEC sent at $(date +%T)"
