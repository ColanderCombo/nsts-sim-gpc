#!/bin/bash
#
# Configures cmake into build/ and builds everything: the node bundles, the
# Electron main and renderer, and the two native addons.  The commands land
# in build/bin.
#
#   BUILD.sh                 configure and build
#   BUILD.sh <target>        configure and build one target
#   BUILD.sh check           build, then run the tests
#
# NSTS_BUILD_DIR may select another build directory, but it must remain under
# the repository root so electron-esbuild can find node_modules by searching
# its parent directories.
#
set -e
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${NSTS_BUILD_DIR:-$PROJECT_DIR/build}"

cmake -B "$BUILD_DIR" -S "$PROJECT_DIR" -G "Unix Makefiles"
cmake --build "$BUILD_DIR" ${1:+--target "$1"} -- -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

echo
echo "Commands are in $BUILD_DIR/bin -- gpc, sim, meds, mmu, mdm, ..."
