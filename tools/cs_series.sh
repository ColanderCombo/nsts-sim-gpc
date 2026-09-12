#!/bin/bash
# One run of tools/cs_run.sh after another, each from a clean session: the
# set's life varies by two orders of magnitude between runs, so a series is
# what a change is judged on.
#   tools/cs_series.sh <tag-prefix> <count> [shm-setting] [base-port] [barrier-us]
# The shm setting goes to every process of every run (NSTS_BUS_SHM: ic,
# all, off, or a list of bus names), and the barrier delta to the GPCs
# (NSTS_SIM_BARRIER: microseconds, or off).  The report of each run goes
# to stdout; $CS_DIR holds the record logs.
cd "$(dirname "$0")/.." || exit 1
S=${CS_DIR:-/tmp/cs}
P=$1; N=$2; export NSTS_BUS_SHM=${3:-off}; BASE=${4:-7950}
export NSTS_SIM_BARRIER=${5:-off}
for i in $(seq 1 $N); do
  T=$P$i
  # Only the pids this tooling recorded: another session's processes have
  # the same command lines.
  while read pid name; do
    cmd=$(ps -o command= -p "$pid" 2>/dev/null); [ -z "$cmd" ] && continue
    case "$cmd" in *build/dist/*) kill "$pid";; esac
  done < $S/cs.pids
  sleep 3
  node build/dist/gpc.js shm --base-port $BASE --unlink > /dev/null
  tools/cs_lrus.sh $BASE > $S/logs/lrus_$T.log 2>&1
  sleep 3
  NSTS_SCHED=fixed CS_TAP=1 CS_TRACE_BCE=1,4 \
    tools/cs_run.sh $T 150 $BASE > $S/run_$T.log 2>&1
  echo "=== $T (shm $NSTS_BUS_SHM, barrier $NSTS_SIM_BARRIER)"
  tools/cs_report.py $T 2>&1 | sed -n '2,20p'
done
