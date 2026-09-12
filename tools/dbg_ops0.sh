#!/bin/bash
DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR" || exit 1
PIDS=/tmp/dbg_ops0.pids

if [ "$1" = "stop" ]; then
    [ -f "$PIDS" ] && while read -r p; do kill -INT "$p" 2>/dev/null; done < "$PIDS"
    sleep 2
    pkill -f "gpc.js dbg-serve --ipl --gpc 4 --real-time --port ${2:-4477}" 2>/dev/null
    rm -f "$PIDS"
    exit 0
fi

BASE="${1:-7700}"
DBG="${2:-4477}"
export NSTS_BASE_PORT="$BASE"
export NSTS_BUS_SHM="${NSTS_BUS_SHM:-gui}"
: > "$PIDS"

build/bin/sim --base-port "$BASE" --no-build run mmu1 mmu2 ff1 ff2 ff3 ff4 fa1 fa2 fa3 fa4 of1 of2 of3 of4 oa1 oa2 oa3 pf1 pf2 mtu nsp pcmmu adc \
    > /tmp/dbg_ops0_sim.log 2>&1 &
echo $! >> "$PIDS"
node build/dist/gpcmd.js unit --idp 1 $DBG_OPS0_DEU1 > /tmp/dbg_ops0_deu.log 2>&1 &
echo $! >> "$PIDS"
if [ -n "$DBG_OPS0_DEU2" ]; then
    node build/dist/gpcmd.js unit --idp 2 $DBG_OPS0_DEU2 > /tmp/dbg_ops0_deu2.log 2>&1 &
    echo $! >> "$PIDS"
fi
node build/dist/gpc.js discretes mode run --gpc 4 > /dev/null 2>&1 &
echo $! >> "$PIDS"
sleep 5
NSTS_BUS_TIMEOUT_TRACE=1 NSTS_RECV_TIMEOUT_FLOOR_MS=10 \
    node build/dist/gpc.js dbg-serve --ipl --gpc 4 --real-time --rt-idle-timeout 900 --port "$DBG" \
    --config-root "${DBG_OPS0_CONFIG_ROOT:-../../build/OI340700/fcm}" \
    --name ops0 --max-steps 4000000000 > /tmp/dbg_ops0_gpc.log 2>&1 &
echo $! >> "$PIDS"
until grep -q "listening on" /tmp/dbg_ops0_gpc.log; do sleep 1; done

printf 'busmon on --limit 8000\nlog /tmp/dbg_ops0_run.ndjson --kinds bus,stopped\n' \
    | node build/dist/gpc.js dbg-client --port "$DBG" > /dev/null 2>&1
(echo continue | node build/dist/gpc.js dbg-client --port "$DBG" --timeout 3000 > /dev/null 2>&1 &)
echo "GPC running under dbg-serve on port $DBG, busses at base $BASE"

until printf 'buslog 3\n' | node build/dist/gpc.js dbg-client --port "$DBG" 2>/dev/null \
        | grep -q "DK1  BCE 6 tx cmd 5700"; do sleep 5; done
sleep 3
node build/dist/gpcmd.js key --idp 1 ITEM 1 EXEC > /dev/null 2>&1
echo "IPL menu: ITEM 1 EXEC sent; the PASS loads and comes up in OPS 0"
