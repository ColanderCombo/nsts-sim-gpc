"""The two configuration files, resolved into what the supervisor runs.

  sim.yml        the catalog.  What kinds of LRU exist, the command that
                 runs one, and where on this machine its files live.

  runConfig.yml  the configuration being managed.  Which LRUs are in it,
                 in what order they come up, and what each one is given.

Every ${variable} is expanded and every path made absolute here, so
nothing below this module reads YAML.
"""

from __future__ import annotations

import os
import re
import shlex
import signal as signalmod
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional

import yaml


class ConfigError(Exception):
    """A configuration file is wrong.  The message names the file and key."""


# ---------------------------------------------------------------- variables

_VAR = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_.:/-]*)\}")


def _expand_str(text: str, vars: Dict[str, Any], where: str) -> str:
    def sub(m: "re.Match[str]") -> str:
        name = m.group(1)
        if name.startswith("env:"):
            value = os.environ.get(name[4:])
            if value is None:
                raise ConfigError(
                    "%s: ${%s} -- not set in the environment" % (where, name))
            return value
        if name not in vars:
            known = ", ".join(sorted(k for k in vars if not k.startswith("_")))
            raise ConfigError(
                "%s: ${%s} is not defined (defined here: %s)" % (where, name, known))
        return str(vars[name])

    # A path may be built from another path, so expand until it settles.
    out = text
    for _ in range(8):
        new = _VAR.sub(sub, out)
        if new == out:
            return new
        out = new
    raise ConfigError("%s: ${} expansion does not settle -- a cycle?" % where)


def _expand(obj: Any, vars: Dict[str, Any], where: str) -> Any:
    if isinstance(obj, str):
        return _expand_str(obj, vars, where)
    if isinstance(obj, list):
        return [_expand(v, vars, "%s[%d]" % (where, i)) for i, v in enumerate(obj)]
    if isinstance(obj, dict):
        return {k: _expand(v, vars, "%s.%s" % (where, k)) for k, v in obj.items()}
    return obj


def _merge(base: Dict[str, Any], over: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    """Overlay `over` on `base`; nested dicts merge, everything else replaces."""
    out = dict(base)
    for key, value in (over or {}).items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = _merge(out[key], value)
        else:
            out[key] = value
    return out


def _argv(value: Any, where: str) -> List[str]:
    """A command is a list of words, or a string this splits like a shell."""
    if value is None:
        return []
    if isinstance(value, str):
        return shlex.split(value)
    if isinstance(value, list):
        return [str(v) for v in value]
    raise ConfigError("%s: expected a command line, got %s" % (where, type(value).__name__))


# -------------------------------------------------------------------- model

@dataclass
class Health:
    """How to decide whether a running LRU is well.

    process  alive is well.  The default.
    port     something answers a TCP connect (a dbg-serve session, say).
    log      a line matching `up` has been printed, and none matching
             `down` since.
    command  a command exits zero.
    none     do not judge; running is reported as up.
    """

    type: str = "process"
    host: str = "127.0.0.1"
    port: Optional[int] = None
    up: Optional[str] = None
    down: Optional[str] = None
    command: List[str] = field(default_factory=list)
    interval: float = 2.0
    # How long after a start the LRU is allowed to be neither up nor down.
    grace: float = 1.0
    # A pattern in the output that means broken, whatever the probe says.
    fault: Optional[str] = None

    TYPES = ("none", "process", "port", "log", "command")

    @classmethod
    def parse(cls, raw: Dict[str, Any], where: str) -> "Health":
        raw = dict(raw or {})
        kind = str(raw.pop("type", "process"))
        if kind not in cls.TYPES:
            raise ConfigError("%s: health type '%s' is not one of %s"
                              % (where, kind, ", ".join(cls.TYPES)))
        health = cls(type=kind)
        for key, value in raw.items():
            if not hasattr(health, key):
                raise ConfigError("%s: no health setting '%s'" % (where, key))
            if key == "command":
                value = _argv(value, where + ".command")
            elif key in ("interval", "grace"):
                value = float(value)
            elif key == "port":
                value = int(value)
            setattr(health, key, value)
        for key in ("up", "down", "fault"):
            pattern = getattr(health, key)
            if pattern:
                try:
                    re.compile(pattern)
                except re.error as exc:
                    raise ConfigError("%s.%s: bad regular expression: %s"
                                      % (where, key, exc))
        if kind == "port" and health.port is None:
            raise ConfigError("%s: health type 'port' needs a port" % where)
        if kind == "log" and not (health.up or health.down):
            raise ConfigError("%s: health type 'log' needs an up or down pattern" % where)
        if kind == "command" and not health.command:
            raise ConfigError("%s: health type 'command' needs a command" % where)
        return health

    def describe(self) -> str:
        if self.type == "port":
            return "port %s:%d" % (self.host, self.port or 0)
        if self.type == "log":
            parts = []
            if self.up:
                parts.append("up=/%s/" % self.up)
            if self.down:
                parts.append("down=/%s/" % self.down)
            return "log " + " ".join(parts)
        if self.type == "command":
            return "command " + " ".join(self.command)
        return self.type


@dataclass
class Lru:
    """One LRU in the run configuration, with everything resolved."""

    key: str                                    # instance name -- gpc4
    lru: str                                    # catalog entry -- gpc
    name: str = ""                              # what to call it on screen
    kind: str = ""
    description: str = ""
    argv: List[str] = field(default_factory=list)
    cwd: Path = field(default_factory=Path)
    env: Dict[str, str] = field(default_factory=dict)
    params: Dict[str, Any] = field(default_factory=dict)
    build: List[str] = field(default_factory=list)
    tty: bool = False
    health: Health = field(default_factory=Health)
    restart: str = "never"                      # never | on-failure | always
    max_restarts: int = 3
    stop_signal: str = "TERM"
    stop_timeout: float = 5.0
    start_delay: float = 0.0
    ready_timeout: float = 20.0
    log_lines: int = 5000
    order: int = 0
    depends: List[str] = field(default_factory=list)
    autostart: bool = True

    @property
    def command_line(self) -> str:
        return " ".join(shlex.quote(a) for a in self.argv)

    @property
    def signal(self) -> int:
        return getattr(signalmod, "SIG" + self.stop_signal)


@dataclass
class SimConfig:
    sim_file: Path
    run_file: Path
    name: str
    description: str
    paths: Dict[str, Path]
    lrus: List[Lru]
    log_dir: Optional[Path] = None

    def get(self, key: str) -> Optional[Lru]:
        for lru in self.lrus:
            if lru.key == key:
                return lru
        return None


# ------------------------------------------------------------------ loading

# The settings an LRU inherits when neither file says otherwise.
DEFAULTS: Dict[str, Any] = {
    "cwd": "${root}",
    "env": {},
    "tty": False,
    "restart": "never",
    "maxRestarts": 3,
    "stopSignal": "TERM",
    "stopTimeout": 5.0,
    "startDelay": 0.0,
    "readyTimeout": 20.0,
    "logLines": 5000,
    "health": {"type": "process"},
}

_RESTART = ("never", "on-failure", "always")

# Settings, as spelled in YAML, that are not part of an LRU's own identity.
_POLICY = {
    "cwd": "cwd", "env": "env", "tty": "tty", "restart": "restart",
    "maxRestarts": "max_restarts", "stopSignal": "stop_signal",
    "stopTimeout": "stop_timeout", "startDelay": "start_delay",
    "readyTimeout": "ready_timeout", "logLines": "log_lines",
}


def _read(path: Path) -> Dict[str, Any]:
    try:
        text = path.read_text()
    except OSError as exc:
        raise ConfigError("cannot read %s: %s" % (path, exc.strerror or exc))
    try:
        doc = yaml.safe_load(text)
    except yaml.YAMLError as exc:
        raise ConfigError("%s: %s" % (path, exc))
    if doc is None:
        return {}
    if not isinstance(doc, dict):
        raise ConfigError("%s: the file must be a mapping" % path)
    return doc


def _resolve_paths(raw: Dict[str, Any], anchor: Path, where: str) -> Dict[str, Path]:
    """Expand each path against the ones before it, then anchor it.

    Paths are written relative to the file that declares them.
    """
    out: Dict[str, Path] = {}
    seen: Dict[str, Any] = {}
    for key, value in (raw or {}).items():
        text = _expand_str(str(value), seen, "%s.paths.%s" % (where, key))
        path = Path(text)
        if not path.is_absolute():
            path = anchor / path
        out[key] = Path(os.path.normpath(str(path)))
        seen[key] = str(out[key])
    return out


def load(sim_file: Path, run_file: Path) -> SimConfig:
    """Read both files and resolve them into one runnable configuration."""
    sim_file = Path(sim_file).expanduser().resolve()
    run_file = Path(run_file).expanduser().resolve()
    sim_doc = _read(sim_file)
    run_doc = _read(run_file)

    paths = _resolve_paths(sim_doc.get("paths") or {}, sim_file.parent, "sim.yml")
    paths.update(_resolve_paths(run_doc.get("paths") or {}, run_file.parent, "runConfig.yml"))
    if "root" not in paths:
        paths["root"] = sim_file.parent.parent

    defaults = _merge(_merge(DEFAULTS, sim_doc.get("defaults")),
                      run_doc.get("defaults"))
    catalog = sim_doc.get("lrus") or {}
    if not isinstance(catalog, dict):
        raise ConfigError("sim.yml: lrus: must be a mapping of name to definition")

    run_params = run_doc.get("params") or {}
    instances = run_doc.get("lrus") or {}
    if not isinstance(instances, dict):
        raise ConfigError("runConfig.yml: lrus: must be a mapping of name to entry")

    listed = run_doc.get("autostart")
    if listed is not None and not isinstance(listed, list):
        raise ConfigError("runConfig.yml: autostart: must be a list of LRU names")

    lrus: List[Lru] = []
    for position, (key, raw) in enumerate(instances.items()):
        raw = dict(raw or {})
        where = "runConfig.yml: lrus.%s" % key
        def_key = str(raw.pop("lru", key))
        if def_key not in catalog:
            raise ConfigError("%s: no LRU '%s' in sim.yml (it defines: %s)"
                              % (where, def_key, ", ".join(sorted(catalog)) or "nothing"))
        definition = dict(catalog[def_key] or {})

        # Later files win: sim.yml defaults, then the catalog entry, then
        # this instance.
        merged = _merge(_merge(defaults, definition), raw)

        vars: Dict[str, Any] = {k: str(v) for k, v in paths.items()}
        vars.update(run_params)
        vars.update(definition.get("params") or {})
        vars.update(raw.get("params") or {})
        vars["name"] = key
        vars["lru"] = def_key
        # A param may be written in terms of a path or another param.
        for pkey, pval in list(vars.items()):
            if isinstance(pval, str):
                vars[pkey] = _expand_str(pval, vars, "%s.params.%s" % (where, pkey))
        merged = _expand(merged, vars, where)

        cwd = Path(str(merged.get("cwd") or paths["root"]))
        if not cwd.is_absolute():
            cwd = paths["root"] / cwd

        argv = _argv(merged.get("command"), where + ".command")
        argv += _argv(merged.get("args"), where + ".args")
        if not argv:
            raise ConfigError("%s: no command -- nothing to run" % where)

        restart = str(merged.get("restart"))
        if restart not in _RESTART:
            raise ConfigError("%s: restart '%s' is not one of %s"
                              % (where, restart, ", ".join(_RESTART)))
        stop_signal = str(merged.get("stopSignal")).upper().replace("SIG", "", 1)
        if not hasattr(signalmod, "SIG" + stop_signal):
            raise ConfigError("%s: no signal named '%s'" % (where, stop_signal))

        lru = Lru(
            key=key,
            lru=def_key,
            name=str(merged.get("name") or key),
            kind=str(merged.get("kind") or def_key),
            description=str(merged.get("description") or ""),
            argv=argv,
            cwd=Path(os.path.normpath(str(cwd))),
            env={str(k): str(v) for k, v in (merged.get("env") or {}).items()},
            params={k: v for k, v in vars.items()
                    if k not in paths and k not in ("name", "lru")},
            build=_argv(merged.get("build"), where + ".build"),
            tty=bool(merged.get("tty")),
            health=Health.parse(merged.get("health") or {}, where + ".health"),
            restart=restart,
            max_restarts=int(merged.get("maxRestarts")),
            stop_signal=stop_signal,
            stop_timeout=float(merged.get("stopTimeout")),
            start_delay=float(merged.get("startDelay")),
            ready_timeout=float(merged.get("readyTimeout")),
            log_lines=int(merged.get("logLines")),
            order=int(merged.get("order", (position + 1) * 10)),
            depends=[str(d) for d in (merged.get("depends") or [])],
            autostart=bool(merged.get("autostart", True)),
        )
        if listed is not None:
            lru.autostart = key in listed
        lrus.append(lru)

    known = {lru.key for lru in lrus}
    for lru in lrus:
        for dep in lru.depends:
            if dep not in known:
                raise ConfigError("runConfig.yml: lrus.%s depends on '%s', "
                                  "which is not in this configuration" % (lru.key, dep))
    for key in (listed or []):
        if key not in known:
            raise ConfigError("runConfig.yml: autostart names '%s', "
                              "which is not in this configuration" % key)

    lrus.sort(key=lambda l: (l.order, l.key))
    return SimConfig(
        sim_file=sim_file,
        run_file=run_file,
        name=str(run_doc.get("name") or run_file.stem),
        description=str(run_doc.get("description") or ""),
        paths=paths,
        lrus=lrus,
        log_dir=paths.get("logs"),
    )
