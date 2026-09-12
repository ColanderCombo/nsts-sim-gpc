#!/bin/bash
# The LRUs of a private two-GPC session, launched directly on a spare base
# port: no second sim supervisor beside a running one.
#   tools/cs_lrus.sh [base-port]          (default 7950)
# Pids go to $CS_DIR/cs.pids (default /tmp/cs), logs to $CS_DIR/logs.
cd "$(dirname "$0")/.." || exit 1
S=${CS_DIR:-/tmp/cs}; mkdir -p $S/logs
BASE=${1:-7950}
export NSTS_BASE_PORT=${BASE:-7950}
PIDS=$S/cs.pids
: > $PIDS
L=$S/logs
VOL=../../build/OI340700/mmu.mmv
start() { name=$1; shift; "$@" > $L/$name.log 2>&1 & echo "$! $name" >> $PIDS; }
start mmu1 node build/dist/mmu.js run --unit 1 --volume $VOL
start mmu2 node build/dist/mmu.js run --unit 2 --volume $VOL
for m in FF1 FF2 FF3 FF4 FA1 FA2 FA3 FA4 PF1 PF2 OF1 OF2 OF3 OF4 OA1 OA2 OA3; do
  start mdm_$m node build/dist/mdm.js run $m
done
sleep 1
start mtu node build/dist/mtu.js run -q
start nsp node build/dist/nsp.js run -q
start pcmmu node build/dist/pcmmu.js run -q --status-normal
start adc node build/dist/adc.js run -q
start idp node build/dist/idp.js run -q --units 1,2,3,4 --ipl-request 1
sleep 3
cat $PIDS
