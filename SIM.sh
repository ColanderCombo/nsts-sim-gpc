#!/bin/bash
#
# runs the simulation supervisor: starts, watches and stops the LRU
# processes that make up a configuration.
#
# Usage:
#   SIM.sh                      — the terminal interface
#   SIM.sh run [lru...]         — start a configuration with no interface
#   SIM.sh list                 — the LRUs in the configuration
#   SIM.sh config               — the configuration as sim resolved it
#   SIM.sh -r config/entry.yml  — manage a different configuration
#
# config/sim.yml is the LRU catalog (what kinds there are, how one is
# run); config/runConfig.yml is the configuration being managed.
#
# This wrapper builds nothing.  Each LRU carries a build command, which
# sim runs before starting it; --no-build skips them.
#
DIR="$(cd "$(dirname "$0")" && pwd)"
PYTHON="${NSTS_SIM_PYTHON:-python3}"

if ! "${PYTHON}" -c 'import yaml' >/dev/null 2>&1; then
    echo "SIM.sh: ${PYTHON} cannot import yaml -- try 'pip install pyyaml'" >&2
    exit 1
fi

exec env PYTHONPATH="${DIR}${PYTHONPATH:+:${PYTHONPATH}}" "${PYTHON}" -m sim "$@"
