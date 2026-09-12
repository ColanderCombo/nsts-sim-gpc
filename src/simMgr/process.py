"""One managed LRU process: start it, watch it, keep what it printed.

Nothing here knows what an LRU is written in.  A process is a command
line, a working directory, an environment and two things to watch: does
it still exist, and what has it said.
"""

from __future__ import annotations

import errno
import os
import re
import signal
import subprocess
import threading
import time
import uuid
from collections import deque
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Deque, List, Optional, Tuple

from .config import Lru


class State(Enum):
    STOPPED = "stopped"      # never started, or stopped when asked to
    BUILDING = "building"    # running the LRU's build command
    STARTING = "starting"    # spawned, not yet judged well
    RUNNING = "running"      # up, and the health probe agrees or has no view
    STOPPING = "stopping"    # signalled, has not gone yet
    EXITED = "exited"        # gone by itself, cleanly
    FAILED = "failed"        # gone with a bad status, or a probe says broken


#: States in which a process occupies a pid.
LIVE = (State.BUILDING, State.STARTING, State.RUNNING, State.STOPPING)


@dataclass
class LogLine:
    when: float
    text: str
    stream: str              # "out" from the process, "sim" from the supervisor


# A child that thinks it is talking to a terminal colours its output; the
# escapes are stripped before they reach a curses window.
_ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b[@-Z\\-_]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)")
_CTRL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")


def _clean(text: str) -> str:
    return _CTRL.sub("", _ANSI.sub("", text)).rstrip()


class ManagedProcess:
    """The supervisor's handle on one LRU."""

    def __init__(self, lru: Lru, log_dir: Optional[Path] = None):
        self.lru = lru
        self.state = State.STOPPED
        self.pid: Optional[int] = None
        self.exit_code: Optional[int] = None
        self.exit_signal: Optional[int] = None
        self.started_at: Optional[float] = None
        self.state_since: float = time.time()
        self.restarts = 0
        self.health = "unknown"          # unknown | up | down
        self.health_note = ""
        self.built = False
        self.control_environment = {}
        self.launch_id = None

        self._proc: Optional[subprocess.Popen] = None
        self._log: Deque[LogLine] = deque(maxlen=max(200, lru.log_lines))
        self._seq = 0                    # lines ever appended, for the probes
        self._lock = threading.RLock()
        self._readers: List[threading.Thread] = []
        self._stop_at: Optional[float] = None
        self._logfile = None
        self._log_dir = log_dir

    # ------------------------------------------------------------ the log

    def note(self, text: str) -> None:
        """Record something the supervisor did, in the LRU's own log."""
        self._append(text, "sim")

    def _append(self, text: str, stream: str) -> None:
        line = LogLine(time.time(), _clean(text), stream)
        with self._lock:
            self._log.append(line)
            self._seq += 1
            if self._logfile is not None:
                try:
                    self._logfile.write("%s %s\n" % (
                        time.strftime("%H:%M:%S", time.localtime(line.when)), line.text))
                    self._logfile.flush()
                except OSError:
                    self._logfile = None

    def log_lines(self) -> List[LogLine]:
        with self._lock:
            return list(self._log)

    def log_count(self) -> int:
        with self._lock:
            return len(self._log)

    def since(self, seq: int) -> Tuple[List[LogLine], int]:
        """Lines appended since `seq`, and the sequence number to ask next."""
        with self._lock:
            fresh = self._seq - seq
            if fresh <= 0:
                return [], self._seq
            lines = list(self._log)[-min(fresh, len(self._log)):]
            return lines, self._seq

    def seq(self) -> int:
        with self._lock:
            return self._seq

    def clear_log(self) -> None:
        with self._lock:
            self._log.clear()

    # --------------------------------------------------------- the process

    @property
    def alive(self) -> bool:
        return self._proc is not None and self._proc.poll() is None

    @property
    def uptime(self) -> Optional[float]:
        if self.started_at is None or not self.alive:
            return None
        return time.time() - self.started_at

    def set_state(self, state: State) -> None:
        if state is not self.state:
            self.state = state
            self.state_since = time.time()

    def _environment(self) -> dict:
        env = dict(os.environ)
        env.update(self.lru.env)
        env.update(self.control_environment)
        env["NSTS_SIM_LRU"] = self.lru.key
        if self.launch_id:
            env["NSTS_SIM_LAUNCH"] = self.launch_id
        # A model written in Python block-buffers its output down a pipe.
        env.setdefault("PYTHONUNBUFFERED", "1")
        return env

    def build(self) -> bool:
        """Run the LRU's build command.  True if there is nothing to do or it worked."""
        if not self.lru.build or self.built:
            return True
        self.set_state(State.BUILDING)
        self.note("build: " + " ".join(self.lru.build))
        try:
            done = subprocess.run(
                self.lru.build, cwd=str(self.lru.cwd), env=self._environment(),
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                stdin=subprocess.DEVNULL, text=True, errors="replace")
        except OSError as exc:
            self.note("build failed: %s" % exc)
            self._fail()
            return False
        for line in (done.stdout or "").splitlines():
            self._append(line, "out")
        if done.returncode != 0:
            self.note("build failed: exit %d" % done.returncode)
            self._fail()
            return False
        self.built = True
        return True

    def start(self) -> bool:
        if self.alive:
            return True
        if not self.build():
            return False

        if self._log_dir is not None and self._logfile is None:
            try:
                self._log_dir.mkdir(parents=True, exist_ok=True)
                self._logfile = open(self._log_dir / ("%s.log" % self.lru.key), "a")
            except OSError:
                self._logfile = None

        self.exit_code = None
        self.exit_signal = None
        self._stop_at = None
        self.health = "unknown"
        self.health_note = ""
        self.note("start: " + self.lru.command_line)
        self.launch_id = uuid.uuid4().hex

        stdout, keep = self._open_output()
        try:
            self._proc = subprocess.Popen(
                self.lru.argv,
                cwd=str(self.lru.cwd),
                env=self._environment(),
                stdin=subprocess.DEVNULL,
                stdout=stdout,
                stderr=subprocess.STDOUT,
                close_fds=True,
                # A separate process group: the wrappers here are shells
                # that exec node, so a signal has to reach the whole tree,
                # and a ^C in the supervisor must not.
                start_new_session=True,
            )
        except OSError as exc:
            if keep is not None:
                os.close(keep)
            if stdout not in (None, subprocess.PIPE):
                os.close(stdout)
            self.note("cannot start: %s" % _spawn_error(exc, self.lru.argv[0]))
            self._fail()
            return False

        if stdout is not subprocess.PIPE:
            os.close(stdout)           # the child holds the other end now

        self.pid = self._proc.pid
        self.started_at = time.time()
        self.set_state(State.STARTING)
        self.note("running as pid %d" % self.pid)

        if keep is not None:
            fd, closer = keep, lambda: os.close(keep)
        else:
            pipe = self._proc.stdout
            fd, closer = pipe.fileno(), pipe.close
        reader = threading.Thread(target=self._pump, args=(fd, closer),
                                  name="log-%s" % self.lru.key, daemon=True)
        reader.start()
        self._readers = [t for t in self._readers if t.is_alive()]
        self._readers.append(reader)
        return True

    def _open_output(self):
        """(what the child writes to, what we read from).

        A pty, so a model that block-buffers on a pipe writes lines.
        """
        if not self.lru.tty:
            return subprocess.PIPE, None
        import pty
        master, slave = pty.openpty()
        return slave, master

    def _pump(self, fd: int, closer) -> None:
        """Read the child's output until it ends.

        Unbuffered, so a line reaches the log as it is written.
        """
        buffer = b""
        try:
            while True:
                try:
                    chunk = os.read(fd, 4096)
                except OSError as exc:
                    # A pty master reads EIO when the last slave closes.
                    if exc.errno not in (errno.EIO, errno.EBADF):
                        self._append("read error: %s" % exc, "sim")
                    break
                if not chunk:
                    break
                buffer += chunk
                # A \r alone ends a line for a progress meter, and for us.
                buffer = buffer.replace(b"\r\n", b"\n")
                while True:
                    cuts = [i for i in (buffer.find(b"\n"), buffer.find(b"\r")) if i >= 0]
                    if not cuts:
                        break
                    cut = min(cuts)
                    self._append(buffer[:cut].decode("utf-8", "replace"), "out")
                    buffer = buffer[cut + 1:]
        finally:
            if buffer:
                self._append(buffer.decode("utf-8", "replace"), "out")
            try:
                closer()
            except Exception:
                pass

    def poll(self) -> None:
        """Reap the child if it has gone, and settle the state."""
        proc = self._proc
        if proc is None:
            return
        code = proc.poll()
        if code is None:
            return
        if self.state in (State.EXITED, State.FAILED, State.STOPPED):
            return
        self.pid = None
        if code < 0:
            self.exit_signal = -code
            self.exit_code = None
            name = signal.Signals(-code).name
            self.note("exited on %s" % name)
        else:
            self.exit_code = code
            self.note("exited with status %d" % code)
        self.health = "unknown"
        asked = self.state is State.STOPPING
        clean = code == 0 or (asked and code in (-self.lru.signal, 128 + self.lru.signal))
        self.set_state(State.EXITED if (asked or clean) else State.FAILED)
        self.started_at = None

    def _fail(self) -> None:
        self.pid = None
        self.started_at = None
        self.health = "down"
        self.set_state(State.FAILED)

    def stop(self) -> None:
        if not self.alive:
            self.set_state(State.STOPPED)
            return
        self._stop_at = time.time()
        self.set_state(State.STOPPING)
        self.note("stop: SIG%s to the process group" % self.lru.stop_signal)
        self._signal(self.lru.signal)

    def kill(self) -> None:
        if not self.alive:
            self.set_state(State.STOPPED)
            return
        self.note("kill: SIGKILL to the process group")
        self._signal(signal.SIGKILL)

    def _signal(self, sig: int) -> None:
        proc = self._proc
        if proc is None:
            return
        try:
            os.killpg(os.getpgid(proc.pid), sig)
        except (ProcessLookupError, PermissionError):
            try:
                proc.send_signal(sig)
            except (ProcessLookupError, OSError):
                pass

    def overdue(self) -> bool:
        """A stop that has been ignored for longer than the LRU allows."""
        return (self.state is State.STOPPING and self._stop_at is not None
                and time.time() - self._stop_at > self.lru.stop_timeout)

    def forget(self) -> None:
        """Return to the state a never-started LRU is in."""
        self.pid = None
        self.started_at = None
        self.health = "unknown"
        self.health_note = ""
        self.set_state(State.STOPPED)

    def close(self) -> None:
        if self._logfile is not None:
            try:
                self._logfile.close()
            except OSError:
                pass
            self._logfile = None


def _spawn_error(exc: OSError, program: str) -> str:
    if exc.errno == errno.ENOENT:
        return "%s: no such file" % program
    if exc.errno == errno.EACCES:
        return "%s: not executable" % program
    return str(exc)
