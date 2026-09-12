"""The `sim` command.

Start, watch and stop the processes that make up a simulated orbiter:
    sim start                   a headless master
    sim mgr                     attach a terminal frontend
    sim run [lru...]             a master that starts LRUs immediately
    sim list                    discover running simulations
    sim catalog                 the LRUs in this configuration
    sim config                  the configuration as sim resolved it
    sim doctor                  every simulator process on this machine

With no command, sim runs mgr.
"""

from __future__ import annotations

import os
import json
import shlex
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Annotated, List, Optional

import typer

from . import __version__
from . import doctor
from .config import DEFAULT_BASE_PORT, ConfigError, SimConfig, load
from .process import LIVE, State
from .supervisor import Supervisor
from .master import Master
from .remote import Client, RemoteSupervisor, discover
from .controlbus import interface
from .startup import StartupRestore

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent                       # the simulator tree


def default_sim_file() -> Path:
    return Path(os.environ.get("NSTS_SIM_CONFIG") or ROOT / "config" / "sim.yml")


def default_run_file() -> Path:
    return Path(os.environ.get("NSTS_SIM_RUNCONFIG") or ROOT / "config" / "runConfig.yml")


def base_port(value) -> int:
    try:
        port = int(value, 10) if isinstance(value, str) else int(value)
    except (TypeError, ValueError):
        port = -1
    if not 1024 <= port <= 65400:
        raise typer.BadParameter(
            "base port must be an integer from 1024 to 65400, got '%s'" % value)
    return port


def settle_base_port(given: Optional[int]) -> int:
    given = base_port(given if given is not None
                      else os.environ.get("NSTS_BASE_PORT") or DEFAULT_BASE_PORT)
    os.environ["NSTS_BASE_PORT"] = str(given)
    return given


app = typer.Typer(add_completion=False, invoke_without_command=True,
                  help=__doc__.splitlines()[0])

ConfigOpt = Annotated[Optional[Path], typer.Option(
    "--config", "-c", metavar="FILE",
    help="the LRU catalog (default: config/sim.yml)")]
RunConfigOpt = Annotated[Optional[Path], typer.Option(
    "--run-config", "-r", metavar="FILE",
    help="the configuration to manage (default: config/runConfig.yml)")]
NoBuildOpt = Annotated[bool, typer.Option(
    "--no-build", help="do not run any LRU's build command before starting it")]
AsciiOpt = Annotated[bool, typer.Option(
    "--ascii", help="draw with ASCII instead of line and arrow characters")]
BasePortOpt = Annotated[Optional[int], typer.Option(
    "--base-port", metavar="N",
    help="base of the bus port block every LRU is given "
         "(default: NSTS_BASE_PORT, or %d)" % DEFAULT_BASE_PORT)]


def _version(show: bool) -> None:
    if show:
        print("sim " + __version__)
        raise typer.Exit()


# The options are the command's, not a subcommand's, and the state they
# settle is read by whichever subcommand runs.  `mgr` runs when none does.
@app.callback()
def cli(ctx: typer.Context,
        config: ConfigOpt = None,
        run_config: RunConfigOpt = None,
        no_build: NoBuildOpt = False,
        ascii_only: AsciiOpt = False,
        base_port_: BasePortOpt = None,
        host: Annotated[Optional[str], typer.Option(
            "--host", help="master address (default: NSTS_BUS_IFACE, or loopback)")] = None,
        version: Annotated[bool, typer.Option(
            "--version", callback=_version, is_eager=True,
            help="print the version and exit")] = False) -> None:
    settle_base_port(base_port_)
    ctx.obj = {"config": config, "run_config": run_config,
               "build": not no_build, "ascii": ascii_only, "host": host or interface(),
               "attach": host is not None or base_port_ is not None}
    if ctx.invoked_subcommand is None:
        mgr(ctx)


def resolve(ctx: typer.Context) -> SimConfig:
    """The catalog and the configuration, or a message and exit status 2."""
    try:
        return load(ctx.obj["config"] or default_sim_file(),
                    ctx.obj["run_config"] or default_run_file())
    except ConfigError as exc:
        print("sim: %s" % exc, file=sys.stderr)
        raise typer.Exit(2)


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
    print("base port: %s" % os.environ["NSTS_BASE_PORT"])
    print("concurrency: %d" % config.concurrency)
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
        if lru.debug_port:
            print("    debug:     port %d" % lru.debug_port)
        print("    order:     %d%s%s" % (
            lru.order,
            "  depends " + ",".join(lru.depends) if lru.depends else "",
            "" if lru.autostart else "  (not autostarted)"))
        print("    restart:   %s (up to %d)   stop SIG%s within %.0fs"
              % (lru.restart, lru.max_restarts, lru.stop_signal, lru.stop_timeout))
    return 0


# ------------------------------------------------------------------ running

def cmd_run(config: SimConfig, wanted: List[str], build: bool, autostart=True,
            restore=None, resume=False) -> int:
    """Run the master until a termination signal, following child output."""
    sup = Supervisor(config, build=build)
    if (restore is not None and wanted) or (resume and restore is None):
        print('sim: --restore cannot select individual LRUs; --resume requires --restore', file=sys.stderr)
        return 2
    unknown = [k for k in wanted if k not in sup.procs]
    if unknown:
        print("sim: not in this configuration: %s" % ", ".join(unknown), file=sys.stderr)
        return 2
    try:
        master = Master(sup, int(os.environ["NSTS_BASE_PORT"]))
    except OSError as exc:
        print("sim: cannot start master: %s" % exc, file=sys.stderr)
        return 2
    try:
        startup = StartupRestore(master, restore, resume) if restore is not None else None
    except (OSError, ValueError) as exc:
        master.close()
        print('sim: cannot restore at startup: ' + str(exc), file=sys.stderr)
        return 2
    master.start()
    print("sim: master %s at %s:%d" % (master.id, interface(), master.port), flush=True)

    stopping = {"now": False}

    def bye(signum, frame):
        if stopping["now"]:
            return
        stopping["now"] = True
        print("\nsim: stopping", flush=True)
        sup.terminate()

    signal.signal(signal.SIGINT, bye)
    signal.signal(signal.SIGTERM, bye)

    if startup:
        print('sim: starting checkpoint LRUs for ' + restore, flush=True)
        sup.autostart(startup.keys)
    elif wanted:
        for key in wanted:
            sup.start(key)
    elif autostart:
        sup.autostart()

    width = max([len(l.key) for l in config.lrus] + [3])
    seen = {key: 0 for key in sup.procs}
    try:
        while True:
            if startup and not stopping['now']:
                try:
                    if startup.tick():
                        print('sim: restored %s (%s)' % (restore, 'running' if resume else 'frozen'), flush=True)
                        startup = None
                except (OSError, ValueError) as exc:
                    print('sim: startup restore failed: ' + str(exc), file=sys.stderr, flush=True)
                    return 1
            for key in sup.order:
                proc = sup.procs[key]
                lines, seen[key] = proc.since(seen.get(key, 0))
                for line in lines:
                    print("%-*s | %s" % (width, key, line.text), flush=True)
            if stopping["now"] and not any(p.state in LIVE for p in sup.procs.values()):
                break
            time.sleep(0.1)
    finally:
        master.close()
    return 0


def cmd_mgr(client: Client, ascii_only: bool) -> int:
    from .tui import App

    sup = RemoteSupervisor(client)
    try:
        App(sup, ascii_only=ascii_only,
            base_port=int(os.environ["NSTS_BASE_PORT"]),
            hardware_views=client.host in ("127.0.0.1", "localhost")).run()
    finally:
        sup.shutdown()
    return 0


# ----------------------------------------------------------------- commands

@app.command()
def mgr(ctx: typer.Context) -> None:
    """Open a frontend, starting a master when the default endpoint is idle."""
    if not sys.stdout.isatty():
        print("sim: no terminal", file=sys.stderr)
        raise typer.Exit(2)
    try:
        result = cmd_mgr(manager_client(ctx), ctx.obj["ascii"])
    except (OSError, ValueError) as exc:
        raise typer.BadParameter(str(exc))
    raise typer.Exit(result)


def connect(ctx: typer.Context) -> Client:
    try:
        return Client(ctx.obj["host"], int(os.environ["NSTS_BASE_PORT"]))
    except (OSError, ValueError) as exc:
        raise typer.BadParameter("cannot attach to master: %s; start `sim start` first" % exc)


def manager_client(ctx: typer.Context) -> Client:
    if ctx.obj["attach"]:
        return connect(ctx)
    port = int(os.environ["NSTS_BASE_PORT"])
    try:
        return Client(ctx.obj["host"], port)
    except ConnectionError as exc:
        if not isinstance(exc.__cause__ or exc, ConnectionRefusedError):
            raise
    config = resolve(ctx)
    log_dir = config.log_dir or ROOT / "run" / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    log_path = log_dir / ("master-%d.log" % port)
    argv = [sys.executable, "-m", "simMgr", "--base-port", str(port),
            "--config", str(config.sim_file), "--run-config", str(config.run_file)]
    if not ctx.obj["build"]:
        argv.append("--no-build")
    argv.append("start")
    env = dict(os.environ)
    env["PYTHONPATH"] = str(ROOT / "src") + os.pathsep + env.get("PYTHONPATH", "")
    with log_path.open("a") as output:
        child = subprocess.Popen(argv, env=env, stdin=subprocess.DEVNULL,
                                 stdout=output, stderr=subprocess.STDOUT,
                                 start_new_session=True)
    deadline = time.monotonic() + 10
    try:
        while time.monotonic() < deadline:
            try:
                client = Client(ctx.obj["host"], port)
                threading.Thread(target=child.wait, daemon=True).start()
                return client
            except OSError:
                if child.poll() is not None:
                    raise ValueError("master exited with status %s; see %s" % (child.returncode, log_path))
                time.sleep(0.1)
        raise ValueError("master startup timed out; see %s" % log_path)
    except BaseException:
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        raise


@app.command()
def run(ctx: typer.Context,
        lru: Annotated[Optional[List[str]], typer.Argument(
            help="start only these LRUs")] = None,
        restore: Annotated[Optional[str], typer.Option('--restore', metavar='NAME', help='Start checkpoint LRUs and restore NAME, leaving them frozen')] = None,
        resume: Annotated[bool, typer.Option('--resume', help='RUN after startup restore succeeds')] = False) -> None:
    """Start the configuration without a terminal interface and follow its output."""
    raise typer.Exit(cmd_run(resolve(ctx), lru or [], ctx.obj["build"], restore=restore, resume=resume))


@app.command("catalog")
def catalog(ctx: typer.Context) -> None:
    """The LRUs in this configuration."""
    raise typer.Exit(cmd_list(resolve(ctx)))


@app.command("list")
def list_(json_output: Annotated[bool, typer.Option("--json")] = False) -> None:
    """Discover running simulations on the global control channel."""
    records = discover()
    if json_output:
        print(json.dumps(records, indent=2))
    else:
        print("SIMULATION  HOST  BASE PORT  MASTER")
        for record in records:
            print("%s  %s  %s  %s" % (record.get("name"), record.get("host"),
                                      record.get("basePort"), record.get("master")))


def remote_call(ctx, operation, key=None):
    try:
        return connect(ctx).call(operation, key)
    except (OSError, ValueError) as exc:
        raise typer.BadParameter(str(exc))


@app.command()
def status(ctx: typer.Context) -> None:
    """Show the master's process and health state."""
    state = remote_call(ctx, "snapshot")
    print("LRU  STATE  HEALTH  PID")
    for key, proc in state["processes"].items():
        print("%s  %s  %s  %s" % (key, proc["state"], proc["health"], proc["pid"] or "--"))


@app.command()
def inspect(ctx: typer.Context,
            key: Annotated[Optional[str], typer.Argument()] = None) -> None:
    """Query configuration, component buses, availability and recent errors as JSON."""
    state = remote_call(ctx, "snapshot")
    if key is not None:
        if key not in state["processes"]:
            raise typer.BadParameter("unknown configured LRU: %s" % key)
        state = dict(process=state["processes"][key],
                     components=[record for record in state["components"] if record.get("key") == key],
                     errors=[record for record in state["errors"] if record.get("key") == key])
    print(json.dumps(state, indent=2))


@app.command()
def start(ctx: typer.Context,
          key: Annotated[Optional[str], typer.Argument()] = None,
          autostart: Annotated[bool, typer.Option("--autostart")] = False,
          restore: Annotated[Optional[str], typer.Option('--restore', metavar='NAME', help='Start checkpoint LRUs and restore NAME, leaving them frozen')] = None,
          resume: Annotated[bool, typer.Option('--resume', help='RUN after startup restore succeeds')] = False) -> None:
    """Run the headless master, or start one LRU in an existing simulation."""
    if key is not None:
        if autostart or restore is not None or resume:
            raise typer.BadParameter("--autostart, --restore and --resume apply to starting a master")
        print(remote_call(ctx, "start", key))
    else:
        raise typer.Exit(cmd_run(resolve(ctx), [], ctx.obj["build"], autostart, restore, resume))


@app.command()
def stop(ctx: typer.Context, key: str) -> None:
    """Ask the master to stop a configured LRU process."""
    print(remote_call(ctx, "stop", key))


@app.command()
def restart(ctx: typer.Context, key: str) -> None:
    """Ask the master to restart a configured LRU process."""
    print(remote_call(ctx, "restart", key))


@app.command()
def terminate(ctx: typer.Context) -> None:
    """Stop all configured LRUs; leave the master serving clients."""
    print(remote_call(ctx, "terminate"))


@app.command()
def logs(ctx: typer.Context, key: str) -> None:
    """Read the latest 500 log lines from a configured LRU process."""
    for line in remote_call(ctx, "logs", key):
        print(line["text"])


@app.command("config")
def config_(ctx: typer.Context) -> None:
    """The configuration as sim resolved it."""
    raise typer.Exit(cmd_config(resolve(ctx)))


@app.command("doctor")
def doctor_() -> None:
    """Every simulator process on this machine, by base port, duplicates flagged."""
    raise typer.Exit(doctor.report())


@app.command("freeze")
@app.command("frz")
def freeze(ctx: typer.Context, at: Annotated[Optional[float], typer.Option("--at", help="Simulation seconds")] = None):
    """Freeze all LRUs now or at a simulation time."""
    print(connect(ctx).call("freeze", at=at))


@app.command("resume")
def resume(ctx: typer.Context):
    """RUN a frozen simulation (the run command launches a configuration)."""
    print(remote_call(ctx, "run"))


@app.command("dstore")
def dstore(ctx: typer.Context, name: str):
    """Save every frozen LRU into NAME.dstore."""
    print(connect(ctx).call("dstore", name=name))


@app.command("restore")
def restore(ctx: typer.Context, name: str):
    """Restore a named store, leaving the simulation frozen."""
    print(connect(ctx).call("restore", name=name))


@app.command("dstores")
def dstores(ctx: typer.Context):
    """List saved stores and their completion status."""
    print(json.dumps(remote_call(ctx, "snapshot")["simulation"], indent=2))


@app.command("rename-dstore")
def rename_dstore(ctx: typer.Context, name: str, new_name: str):
    """Rename a saved store."""
    print(connect(ctx).call("rename_dstore", name=name, new_name=new_name))


if __name__ == "__main__":
    app()
