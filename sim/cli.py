"""The `sim` command."""

from __future__ import annotations

import argparse
import os
import shlex
import signal
import sys
import time
from pathlib import Path
from typing import List, Optional

from . import __version__
from .config import ConfigError, SimConfig, load
from .process import LIVE, State
from .supervisor import Supervisor

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent                              # the simulator tree


def default_sim_file() -> Path:
    return Path(os.environ.get("NSTS_SIM_CONFIG") or ROOT / "config" / "sim.yml")


def default_run_file() -> Path:
    return Path(os.environ.get("NSTS_SIM_RUNCONFIG") or ROOT / "config" / "runConfig.yml")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="sim",
        description="Start, watch and stop the processes that make up a "
                    "simulated orbiter.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="With no command, sim opens the terminal interface.")
    parser.add_argument("-c", "--config", type=Path, default=None, metavar="FILE",
                        help="the LRU catalog (default: config/sim.yml)")
    parser.add_argument("-r", "--run-config", type=Path, default=None, metavar="FILE",
                        help="the configuration to manage (default: config/runConfig.yml)")
    parser.add_argument("--no-build", action="store_true",
                        help="do not run any LRU's build command before starting it")
    parser.add_argument("--ascii", action="store_true",
                        help="draw with ASCII instead of line and arrow characters")
    parser.add_argument("--version", action="version", version="sim " + __version__)

    subs = parser.add_subparsers(dest="command")
    subs.add_parser("tui", help="the terminal interface (the default)")
    run = subs.add_parser("run", help="start the configuration without a "
                                      "terminal interface and follow its output")
    run.add_argument("lru", nargs="*", help="start only these LRUs")
    subs.add_parser("list", help="the LRUs in this configuration")
    subs.add_parser("config", help="the configuration as sim resolved it")
    return parser


def resolve(args) -> SimConfig:
    sim_file = args.config or default_sim_file()
    run_file = args.run_config or default_run_file()
    return load(sim_file, run_file)


# ------------------------------------------------------------------ reports

def cmd_list(config: SimConfig) -> int:
    width = max([len(l.key) for l in config.lrus] + [3])
    print("%-*s  %-10s %-5s %s" % (width, "LRU", "KIND", "AUTO", "COMMAND"))
    for lru in config.lrus:
        print("%-*s  %-10s %-5s %s" % (
            width, lru.key, lru.lru, "yes" if lru.autostart else "no",
            lru.command_line))
    return 0


def cmd_config(config: SimConfig) -> int:
    print("# %s" % config.name)
    if config.description:
        print("# %s" % config.description)
    print("catalog:   %s" % config.sim_file)
    print("configured %s" % config.run_file)
    print("paths:")
    for name, path in sorted(config.paths.items()):
        print("  %-10s %s" % (name + ":", path))
    print("lrus:")
    for lru in config.lrus:
        print("  %s:" % lru.key)
        print("    lru:       %s  (%s)" % (lru.lru, lru.kind))
        if lru.description:
            print("    about:     %s" % lru.description)
        print("    command:   %s" % lru.command_line)
        print("    cwd:       %s" % lru.cwd)
        if lru.build:
            print("    build:     %s" % " ".join(shlex.quote(a) for a in lru.build))
        if lru.env:
            print("    env:       %s" % "  ".join(
                "%s=%s" % (k, v) for k, v in sorted(lru.env.items())))
        if lru.params:
            print("    params:    %s" % "  ".join(
                "%s=%s" % (k, v) for k, v in sorted(lru.params.items())))
        print("    health:    %s (grace %.0fs, ready %.0fs)"
              % (lru.health.describe(), lru.health.grace, lru.ready_timeout))
        if lru.health.fault:
            print("    fault:     /%s/" % lru.health.fault)
        print("    order:     %d%s%s" % (
            lru.order,
            "  depends " + ",".join(lru.depends) if lru.depends else "",
            "" if lru.autostart else "  (not autostarted)"))
        print("    restart:   %s (up to %d)   stop SIG%s within %.0fs"
              % (lru.restart, lru.max_restarts, lru.stop_signal, lru.stop_timeout))
    return 0


# ------------------------------------------------------------------ running

def cmd_run(config: SimConfig, wanted: List[str], build: bool) -> int:
    """The same supervisor with the terminal in place of the interface."""
    sup = Supervisor(config, build=build)
    unknown = [k for k in wanted if k not in sup.procs]
    if unknown:
        print("sim: not in this configuration: %s" % ", ".join(unknown), file=sys.stderr)
        return 2
    sup.start_threads()

    stopping = {"now": False}

    def bye(signum, frame):
        if stopping["now"]:
            return
        stopping["now"] = True
        print("\nsim: stopping", flush=True)
        sup.terminate()

    signal.signal(signal.SIGINT, bye)
    signal.signal(signal.SIGTERM, bye)

    if wanted:
        for key in wanted:
            sup.start(key)
    else:
        sup.autostart()

    width = max([len(l.key) for l in config.lrus] + [3])
    seen = {key: 0 for key in sup.procs}
    try:
        while True:
            for key in sup.order:
                proc = sup.procs[key]
                lines, seen[key] = proc.since(seen.get(key, 0))
                for line in lines:
                    print("%-*s | %s" % (width, key, line.text), flush=True)
            if stopping["now"] and not any(p.state in LIVE for p in sup.procs.values()):
                break
            if not stopping["now"] and not sup.busy():
                alive = any(p.state in LIVE for p in sup.procs.values())
                started = any(p.state is not State.STOPPED for p in sup.procs.values())
                if started and not alive:
                    print("sim: nothing is running", flush=True)
                    break
            time.sleep(0.1)
    finally:
        sup.shutdown()
    return 0


def cmd_tui(config: SimConfig, build: bool, ascii_only: bool) -> int:
    from .tui import App

    if not sys.stdout.isatty():
        print("sim: there is no terminal here -- try `sim run` instead",
              file=sys.stderr)
        return 2

    sup = Supervisor(config, build=build)
    sup.start_threads()
    try:
        App(sup, ascii_only=ascii_only).run()
    finally:
        # The busses are fixed ports, so an LRU left behind answers the
        # next session.
        if any(p.state in LIVE for p in sup.procs.values()):
            print("sim: stopping the LRUs still running")
            sup.terminate_now()
        sup.shutdown()
    return 0


def main(argv: Optional[List[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        config = resolve(args)
    except ConfigError as exc:
        print("sim: %s" % exc, file=sys.stderr)
        return 2

    command = args.command or "tui"
    if command == "list":
        return cmd_list(config)
    if command == "config":
        return cmd_config(config)
    if command == "run":
        return cmd_run(config, args.lru, not args.no_build)
    return cmd_tui(config, not args.no_build, args.ascii)


if __name__ == "__main__":
    sys.exit(main())
