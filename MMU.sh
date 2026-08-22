#!/bin/bash
#
# runs a Mass Memory Unit on the simulated mass memory bus.
#   - also automatically builds the js
#
# Usage:
#   MMU.sh run --unit 1 --volume tape.mmv   — serve a tape to a GPC
#   MMU.sh create tape.mmv                  — make an empty volume
#   MMU.sh put tape.mmv 0/0/0/0 data.bin    — lay data on the tape
#   MMU.sh ls tape.mmv                      — what a volume holds
#   MMU.sh watch MM1 --decode               — see the bus traffic
#
DIR="$(cd "$(dirname "$0")" && pwd)"

node "${DIR}/esbuild/esbuild.mmu.config.js" || exit $?
exec node "${DIR}/dist/mmu.js" "$@"
