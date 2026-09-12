"""Bringing a configuration up, keeping it up, and taking it down.

The supervisor owns one ManagedProcess per LRU and two threads: a worker
that performs the things that take time (a build, an ordered start, a
terminate), and a monitor that reaps children and runs the health probes.
Nothing in the user interface blocks on either.
"""

from __future__ import annotations

import queue
import threading
import time
from typing import Callable, Dict, List, Optional

from .config import Lru, SimConfig, load
from .health import FaultWatch, Probe, make_probe
from .process import LIVE, ManagedProcess, State

MONITOR_HZ = 4.0


class Supervisor:
    def __init__(self, config: SimConfig, build: bool = True):
        self.config = config
        self.build_enabled = build
        self.procs: Dict[str, ManagedProcess] = {}
        self.stale: set = set()          # spec changed under a running LRU
        self.activity = ""               # what the worker is doing
        self.message = ""                # the last thing worth saying
        self._held: set = set()          # stopped by hand; policy leaves them alone
        self._probe: Dict[str, Probe] = {}
        self._fault: Dict[str, FaultWatch] = {}
        self._retry_at: Dict[str, float] = {}
        self._lock = threading.RLock()
        self._tasks: "queue.Queue[Optional[tuple]]" = queue.Queue()
        self._cancel = threading.Event()
        self._quit = threading.Event()
        self._worker: Optional[threading.Thread] = None
        self._monitor: Optional[threading.Thread] = None
        for lru in config.lrus:
            self._install(lru)

    # ------------------------------------------------------------ plumbing

    def _install(self, lru: Lru) -> None:
        self.procs[lru.key] = ManagedProcess(lru, self.config.log_dir)
        self._probe[lru.key] = make_probe(lru.health)
        self._fault[lru.key] = FaultWatch(lru.health.fault)

    @property
    def order(self) -> List[str]:
        return [lru.key for lru in self.config.lrus]

    def lru(self, key: str) -> Lru:
        return self.procs[key].lru

    def say(self, text: str) -> None:
        self.message = text

    def start_threads(self) -> None:
        self._worker = threading.Thread(target=self._run_worker, name="sim-worker",
                                        daemon=True)
        self._monitor = threading.Thread(target=self._run_monitor, name="sim-monitor",
                                         daemon=True)
        self._worker.start()
        self._monitor.start()

    def shutdown(self) -> None:
        self._quit.set()
        self._cancel.set()
        self._tasks.put(None)
        for proc in self.procs.values():
            proc.close()

    # --------------------------------------------------------- the worker

    def _submit(self, label: str, fn: Callable[[], None]) -> None:
        self._tasks.put((label, fn))

    def _drain(self) -> None:
        """Abandon whatever was queued.

        A start still waiting its turn at a terminate does not run.
        """
        while True:
            try:
                task = self._tasks.get_nowait()
            except queue.Empty:
                return
            if task is None:
                self._tasks.put(None)
                return

    def _run_worker(self) -> None:
        while not self._quit.is_set():
            task = self._tasks.get()
            if task is None:
                break
            label, fn = task
            self.activity = label
            try:
                fn()
            except Exception as exc:                  # a task must not kill the thread
                self.say("%s: %s" % (label, exc))
            finally:
                self.activity = ""
                self._cancel.clear()

    def busy(self) -> bool:
        return bool(self.activity)

    # ---------------------------------------------------------- commands

    def start(self, key: str) -> None:
        """Start one LRU, building it first if it has a build command."""
        proc = self.procs[key]
        if proc.state in LIVE:
            self.say("%s is already running" % key)
            return
        self._retry_at.pop(key, None)
        self._held.discard(key)
        self._submit("starting %s" % key, lambda: self._start_now(proc))

    def _start_now(self, proc: ManagedProcess) -> bool:
        self._probe[proc.lru.key].reset()
        self._fault[proc.lru.key].reset()
        if not self.build_enabled:
            proc.built = True
        ok = proc.start()
        self.say("%s: %s" % (proc.lru.key, "started" if ok else "would not start"))
        return ok

    def stop(self, key: str) -> None:
        proc = self.procs[key]
        self._held.add(key)
        if proc.state not in LIVE:
            proc.forget()
            return
        self._retry_at.pop(key, None)
        self._submit("stopping %s" % key, lambda: self._stop_now(proc))

    def _stop_now(self, proc: ManagedProcess) -> None:
        proc.stop()
        self._await_gone(proc)

    def kill(self, key: str) -> None:
        proc = self.procs[key]
        self._held.add(key)
        self._retry_at.pop(key, None)
        self._submit("killing %s" % key, lambda: (proc.kill(), self._await_gone(proc)))

    def restart(self, key: str) -> None:
        proc = self.procs[key]
        self._retry_at.pop(key, None)
        self._held.discard(key)

        def work() -> None:
            if proc.state in LIVE:
                proc.stop()
                self._await_gone(proc)
            proc.restarts = 0
            self._start_now(proc)

        self._submit("restarting %s" % key, work)

    def autostart(self) -> None:
        """Start everything the run configuration asks for, in its order."""
        self._cancel.clear()
        self._held.clear()
        self._submit("autostart", self._autostart_now)

    def _autostart_now(self) -> None:
        wanted = [lru for lru in self.config.lrus if lru.autostart]
        if not wanted:
            self.say("no LRU in this configuration is set to autostart")
            return
        for lru in wanted:
            if self._cancel.is_set():
                self.say("autostart cancelled")
                return
            proc = self.procs[lru.key]
            if proc.state in LIVE:
                continue
            if not self._await_depends(lru):
                continue
            self.activity = "autostart: %s" % lru.key
            if not self._start_now(proc):
                self.say("autostart stopped: %s would not start" % lru.key)
                return
            if lru.start_delay:
                self._wait(lru.start_delay)
        self.say("autostart complete")

    def _await_depends(self, lru: Lru) -> bool:
        """Hold a dependent back until what it needs is up."""
        deadline = time.time() + lru.ready_timeout
        for dep in lru.depends:
            other = self.procs[dep]
            while time.time() < deadline:
                if self._cancel.is_set():
                    return False
                if other.health == "up":
                    break
                if other.state in (State.FAILED, State.EXITED, State.STOPPED):
                    self.say("%s: %s is not running -- starting anyway" % (lru.key, dep))
                    break
                self.activity = "%s: waiting for %s" % (lru.key, dep)
                self._wait(0.1)
            else:
                self.say("%s: %s never came up -- starting anyway" % (lru.key, dep))
        return True

    def terminate(self) -> None:
        """Stop everything, youngest first."""
        self._cancel.set()
        self._held.update(self.procs)
        self._drain()
        self._submit("terminate", self._terminate_now)

    def _terminate_now(self) -> None:
        for lru in reversed(self.config.lrus):
            proc = self.procs[lru.key]
            self._retry_at.pop(lru.key, None)
            if proc.state in LIVE:
                self.activity = "terminate: %s" % lru.key
                proc.stop()
        for lru in reversed(self.config.lrus):
            self._await_gone(self.procs[lru.key])
        for proc in self.procs.values():
            if proc.state is not State.FAILED:
                proc.forget()
        self.say("all LRUs stopped")

    def terminate_now(self) -> None:
        """Stop everything on the calling thread, and wait for it."""
        self._cancel.set()
        self._held.update(self.procs)
        self._drain()
        self._terminate_now()

    def restart_all(self) -> None:
        self._cancel.set()
        self._held.update(self.procs)
        self._drain()

        def work() -> None:
            self._terminate_now()
            self._cancel.clear()
            self._held.clear()
            self._autostart_now()

        self._submit("restart all", work)

    def reload(self) -> str:
        """Re-read the configuration files.

        A running LRU keeps the definition it was started with, and is
        marked as no longer matching what is on disk.
        """
        fresh = load(self.config.sim_file, self.config.run_file)
        running = {k for k, p in self.procs.items() if p.state in LIVE}
        procs, probes, faults, stale = {}, {}, {}, set()
        for lru in fresh.lrus:
            old = self.procs.get(lru.key)
            if lru.key in running and old is not None:
                procs[lru.key] = old
                probes[lru.key] = self._probe[lru.key]
                faults[lru.key] = self._fault[lru.key]
                if old.lru != lru:
                    stale.add(lru.key)
                continue
            procs[lru.key] = ManagedProcess(lru, fresh.log_dir)
            probes[lru.key] = make_probe(lru.health)
            faults[lru.key] = FaultWatch(lru.health.fault)
        for key in running - set(procs):
            # Dropped from the run configuration but still running: keep it
            # on the list so it can still be stopped.
            procs[key] = self.procs[key]
            probes[key] = self._probe[key]
            faults[key] = self._fault[key]
            fresh.lrus.append(self.procs[key].lru)
            stale.add(key)
        with self._lock:
            self.config = fresh
            self.procs, self._probe, self._fault = procs, probes, faults
            self.stale = stale
        note = "reloaded %s" % fresh.run_file.name
        if stale:
            note += " -- restart to apply: %s" % ", ".join(sorted(stale))
        self.say(note)
        return note

    # ---------------------------------------------------------- the monitor

    def _run_monitor(self) -> None:
        period = 1.0 / MONITOR_HZ
        while not self._quit.wait(period):
            try:
                self.tick()
            except Exception as exc:
                self.say("monitor: %s" % exc)

    def tick(self) -> None:
        now = time.time()
        with self._lock:
            procs = list(self.procs.values())
        for proc in procs:
            proc.poll()
            if proc.overdue():
                proc.note("stop timed out after %.0fs" % proc.lru.stop_timeout)
                proc.kill()
            self._evaluate(proc)
            self._maybe_restart(proc, now)

    def _evaluate(self, proc: ManagedProcess) -> None:
        if proc.state not in (State.STARTING, State.RUNNING):
            return
        lru = proc.lru
        verdict, note = self._probe[lru.key].check(proc)
        hit = self._fault[lru.key].check(proc)
        if hit:
            verdict, note = "down", hit
        age = time.time() - (proc.started_at or time.time())

        if proc.state is State.STARTING:
            # Nothing is held against it inside the grace window: a model
            # may not have opened its socket yet.
            if age < lru.health.grace:
                proc.health_note = note
                return
            if verdict == "up":
                proc.health, proc.health_note = "up", note
                proc.set_state(State.RUNNING)
                return
            # A probe that has seen neither an up nor a down still has
            # until the ready timeout to see one.
            if verdict == "unknown" and age < lru.ready_timeout:
                proc.health_note = note
                return
            proc.set_state(State.RUNNING)

        # Running and not up is down: past the ready window there is no
        # third answer.
        if verdict == "up":
            proc.health, proc.health_note = "up", note
        else:
            proc.health = "down"
            proc.health_note = note or (
                "nothing said it was up within %.0fs" % lru.ready_timeout)

    def _maybe_restart(self, proc: ManagedProcess, now: float) -> None:
        lru = proc.lru
        if lru.restart == "never" or lru.key in self._held:
            return
        if proc.state is State.FAILED:
            pass
        elif proc.state is State.EXITED and lru.restart == "always":
            pass
        else:
            self._retry_at.pop(lru.key, None)
            return
        if proc.restarts >= lru.max_restarts:
            return
        due = self._retry_at.get(lru.key)
        if due is None:
            # A model that fails at once should not be respawned in a loop.
            delay = min(1.0 * (proc.restarts + 1), 10.0)
            self._retry_at[lru.key] = now + delay
            proc.note("restarting in %.0fs (%d of %d)"
                      % (delay, proc.restarts + 1, lru.max_restarts))
            return
        if now < due:
            return
        self._retry_at.pop(lru.key, None)
        proc.restarts += 1
        self._submit("restarting %s" % lru.key, lambda p=proc: self._start_now(p))

    # ------------------------------------------------------------- waiting

    def _wait(self, seconds: float) -> None:
        self._quit.wait(seconds)

    def _await_gone(self, proc: ManagedProcess, limit: Optional[float] = None) -> None:
        limit = proc.lru.stop_timeout + 2.0 if limit is None else limit
        deadline = time.time() + limit
        while time.time() < deadline:
            proc.poll()
            if not proc.alive:
                return
            if proc.overdue():
                proc.kill()
            self._wait(0.05)
        proc.kill()
        self._wait(0.2)
        proc.poll()
