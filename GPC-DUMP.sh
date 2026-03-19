#!/bin/bash
#
# fcmdump does a simple dump of fcm ('flight computer memory') files,
# disassembling the contents with some csect/symbol annotation.
# It doesn't yet know the difference between code and data, and there's
# a lot to be improved in formatting.  With some additional work this
# should provide most of the same data the original IBM DASS tool did.
#
DIR="$(cd "$(dirname "$0")" && pwd)"
node "${DIR}/esbuild/esbuild.fcmdump.config.js" && exec node "${DIR}/dist/gpc-dump.js" "$@"
