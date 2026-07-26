#!/bin/bash
# run_matrix.sh — exercises compare.sh across the .fcm fixture corpus and
# a representative option matrix (Phase 11 validation). compare.sh itself
# cd's to the repo root before running both the Node reference and
# yaGPC, so all paths here (including the .fcm arguments) are relative to
# the repo root, not to this script's location.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPARE="$SCRIPT_DIR/compare.sh"

FCMS="gpc/gen/SIMPLE.fcm gpc/gen/TEST.fcm gpc/gen/TESTSET.fcm gpc/gen/SS.fcm gpc/gen/asm.fcm gpc/gen/A3GRESCH.fcm"

fail=0

for fcm in $FCMS; do
    name=$(basename "$fcm" .fcm)
    bash "$COMPARE" "$name/default" "$fcm" --start 0 --max-steps 2000 || fail=1
    bash "$COMPARE" "$name/verbose" "$fcm" --start 0 --verbose --max-steps 2000 || fail=1
    bash "$COMPARE" "$name/trace" "$fcm" --start 0 --trace --verbose --max-steps 500 || fail=1
    bash "$COMPARE" "$name/trace-dump" "$fcm" --start 0 --trace --verbose --max-steps 500 --dump-interval 50 || fail=1
    bash "$COMPARE" "$name/no-verbose" "$fcm" --start 0 --no-verbose --max-steps 500 || fail=1
    bash "$COMPARE" "$name/max-steps-small" "$fcm" --start 0 --max-steps 3 || fail=1
done

echo "--- watch/break matrix ---"
bash "$COMPARE" "TEST/watch" gpc/gen/TEST.fcm --start 0 --verbose --max-steps 2000 --watch 0x10:4 || fail=1
bash "$COMPARE" "TEST/watch-log" gpc/gen/TEST.fcm --start 0 --verbose --max-steps 500 --watch 0x10:4 --watch-log || fail=1
bash "$COMPARE" "TEST/break" gpc/gen/TEST.fcm --start 0 --verbose --max-steps 2000 --break 0x40 || fail=1

echo "--- previously-uncovered CLI option matrix ---"
bash "$COMPARE" "TEST/ebcdic" gpc/gen/TEST.fcm --start 0 --verbose --max-steps 500 --ebcdic || fail=1
bash "$COMPARE" "TEST/trap-svc-error" gpc/gen/TEST.fcm --start 0 --verbose --max-steps 500 --trap-svc-error || fail=1
bash "$COMPARE" "TEST/no-trap-svc-error" gpc/gen/TEST.fcm --start 0 --verbose --max-steps 500 --no-trap-svc-error || fail=1
bash "$COMPARE" "TEST/halucp-blanks" gpc/gen/TEST.fcm --start 0 --verbose --max-steps 500 --halucp-format-num-blanks 3 || fail=1
bash "$COMPARE" "TEST/line-width" gpc/gen/TEST.fcm --start 0 --verbose --max-steps 500 --line-width 80 || fail=1

echo "--- HAL/S SVC trap matrix (hand-assembled fixtures, see test/fixtures/gen_svc_fcms.cjs) ---"
SVC_FCMS="yaGPC/test/fixtures/svc_halt.fcm yaGPC/test/fixtures/svc_senderror.fcm yaGPC/test/fixtures/svc_unknown.fcm"
for fcm in $SVC_FCMS; do
    name=$(basename "$fcm" .fcm)
    bash "$COMPARE" "$name/default" "$fcm" --start 0 --max-steps 10 || fail=1
    bash "$COMPARE" "$name/verbose-trace" "$fcm" --start 0 --verbose --trace --max-steps 10 || fail=1
    bash "$COMPARE" "$name/no-trap-svc-error" "$fcm" --start 0 --verbose --trace --no-trap-svc-error --max-steps 10 || fail=1
done

if [ "$fail" = 0 ]; then
    echo "=== ALL MATRIX RUNS PASS ==="
else
    echo "=== SOME MATRIX RUNS FAILED ==="
fi
exit $fail
