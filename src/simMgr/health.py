"""Health probes: is a running LRU actually well?

The others cost the LRU something -- a port to answer on, a line to print
-- so they are configured per LRU in sim.yml and a model with no way to
report keeps the default, which is that the process is alive.
"""

from __future__ import annotations

import re
import socket
import subprocess
from typing import Optional, Tuple

from .config import Health
from .process import ManagedProcess

#: What a probe answers: state and a short reason for the detail page.
Verdict = Tuple[str, str]                # ("up" | "down" | "unknown", note)


class Probe:
    """The `none` probe: running is as much as anyone claims to know."""

    def __init__(self, health: Health):
        self.health = health

    def check(self, proc: ManagedProcess) -> Verdict:
        return "up", "not checked"

    def reset(self) -> None:
        pass


class ProcessProbe(Probe):
    """Alive is well.  The default, and all an anonymous process supports."""

    def check(self, proc: ManagedProcess) -> Verdict:
        return ("up", "") if proc.alive else ("down", "not running")


class PortProbe(Probe):
    """Something answers a TCP connect -- a dbg-serve session, say."""

    def check(self, proc: ManagedProcess) -> Verdict:
        host, port = self.health.host, int(self.health.port or 0)
        try:
            with socket.create_connection((host, port), timeout=0.4):
                return "up", "%s:%d answers" % (host, port)
        except OSError as exc:
            return "down", "%s:%d %s" % (host, port, exc.strerror or "no answer")


class LogProbe(Probe):
    """The LRU says so itself.

    `up` is the line it prints when it is ready, `down` a line that means
    it is not.  Until one of them appears the verdict is unknown, which
    holds the LRU in STARTING until its ready timeout.
    """

    def __init__(self, health: Health):
        super().__init__(health)
        self._up = re.compile(health.up) if health.up else None
        self._down = re.compile(health.down) if health.down else None
        self._seq = 0
        self._verdict: Verdict = ("unknown", "")

    def reset(self) -> None:
        self._seq = 0
        self._verdict = ("unknown", "")

    def check(self, proc: ManagedProcess) -> Verdict:
        lines, self._seq = proc.since(self._seq)
        for line in lines:
            if line.stream != "out":
                continue
            if self._down is not None and self._down.search(line.text):
                self._verdict = ("down", "matched /%s/" % self.health.down)
            elif self._up is not None and self._up.search(line.text):
                self._verdict = ("up", "matched /%s/" % self.health.up)
        return self._verdict


class CommandProbe(Probe):
    """A command exits zero.  For an LRU that ships a status client."""

    def check(self, proc: ManagedProcess) -> Verdict:
        try:
            done = subprocess.run(
                self.health.command, cwd=str(proc.lru.cwd),
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                stdin=subprocess.DEVNULL, timeout=max(1.0, self.health.interval),
                text=True, errors="replace")
        except subprocess.TimeoutExpired:
            return "down", "probe timed out"
        except OSError as exc:
            return "down", "probe failed: %s" % exc
        first = (done.stdout or "").strip().splitlines()
        note = first[0][:60] if first else ""
        return ("up" if done.returncode == 0 else "down", note)


_PROBES = {
    "none": Probe,
    "process": ProcessProbe,
    "port": PortProbe,
    "log": LogProbe,
    "command": CommandProbe,
}


def make_probe(health: Health) -> Probe:
    return _PROBES[health.type](health)


class FaultWatch:
    """A pattern in the output that means broken, whatever the probe says.

    It applies to every kind: a GPC whose health is 'process' can still
    print BCE FAIL.
    """

    def __init__(self, pattern: Optional[str]):
        self._re = re.compile(pattern) if pattern else None
        self._seq = 0
        self.hit: Optional[str] = None

    def reset(self) -> None:
        self._seq = 0
        self.hit = None

    def check(self, proc: ManagedProcess) -> Optional[str]:
        if self._re is None:
            return None
        lines, self._seq = proc.since(self._seq)
        for line in lines:
            if line.stream == "out" and self._re.search(line.text):
                self.hit = line.text[:60]
        return self.hit
