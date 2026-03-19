#!/bin/bash
#
# run AP-101 simulator in batch mode, emitting an instruction trace,
# similar to the original IBM HALUCP ('HAL User Control Program').
#
# There are some arguments for limiting the run (--max-steps) and
# simple debugging (--break), but generally if you're trying to debug
# something the interactive debugger will be more useful to you.
#
DIR="$(cd "$(dirname "$0")" && pwd)"
node "${DIR}/esbuild/esbuild.batch.config.js" && exec node "${DIR}/dist/gpc-batch.js" "$@"
