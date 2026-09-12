"""The simulation authority and its discovery, state and command endpoints."""

import os
import queue
import select
import socket
import socketserver
import threading
import time
import uuid
from collections import OrderedDict, deque
from dataclasses import asdict

from .controlbus import (Channel, DISCOVERY_GROUP, LEASE, MAX_REQUEST,
                         decode, discovery_port, encode, interface)
from .process import State
from .dstore import SimulationControl


class _Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


class _Handler(socketserver.StreamRequestHandler):
    def handle(self):
        self.connection.settimeout(3)
        try:
            data = self.rfile.readline(MAX_REQUEST + 1)
            if len(data) > MAX_REQUEST or not data.endswith(b"\n"):
                return
            message = decode(data)
            if message is None:
                return
            self.wfile.write(encode(self.server.master.request(message)) + b"\n")
        except (OSError, ValueError):
            return


class Master:
    def __init__(self, supervisor, port):
        self.sup, self.port = supervisor, port
        self.id = str(uuid.uuid4())
        self.started_at = time.time()
        self.host = socket.gethostname()
        self.components = {}
        self.simulation = SimulationControl(self)
        self.errors = deque(maxlen=200)
        self._replies = OrderedDict()
        self._lock = threading.RLock()
        self._quit = threading.Event()
        self._threads = []
        self._states = {}
        self._error_ids = deque(maxlen=1024)
        self._pending_errors = queue.SimpleQueue()
        self.server = _Server((interface(), port), _Handler)
        self.server.master = self
        try:
            self.local = Channel(port)
            try:
                self.global_bus = Channel(discovery_port(), DISCOVERY_GROUP)
            except Exception:
                self.local.close()
                raise
        except Exception:
            self.server.server_close()
            raise

    def announcement(self):
        return dict(v=1, type="master", master=self.id, name=self.sup.config.name,
                    host=self.host, address=interface(), basePort=self.port,
                    pid=os.getpid(), lease=LEASE, role="master", startedAt=self.started_at)

    def start(self):
        self.sup.on_error = self._pending_errors.put
        self.sup.control_environment = {
            "NSTS_SIM_ID": self.id, "NSTS_SIM_HOST": self.host,
            "NSTS_BASE_PORT": str(self.port), "NSTS_BUS_IFACE": interface(),
        }
        self.sup.start_threads()
        for target in (self.server.serve_forever, self._run):
            thread = threading.Thread(target=target, daemon=True)
            thread.start()
            self._threads.append(thread)

    def _error(self, key, text):
        record = dict(v=1, type="error", master=self.id, key=key,
                      host=self.host, time=time.time(), message=str(text)[:4000])
        self.errors.append(record)
        self.local.send(record)

    def _run(self):
        due = 0
        while not self._quit.is_set():
            try:
                timeout = 0.2
                if self.simulation.at is not None:
                    timeout = max(0, min(timeout, self.simulation.at - self.simulation.seconds()))
                readable, _, _ = select.select(
                    [self.local.sock, self.global_bus.sock], [], [], timeout)
                with self._lock:
                    while not self._pending_errors.empty():
                        self._error(None, self._pending_errors.get_nowait())
                    for sock in readable:
                        channel = self.local if sock is self.local.sock else self.global_bus
                        message = channel.recv()
                        if message is None:
                            continue
                        if channel is self.global_bus and message.get("type") == "discover":
                            channel.send(self.announcement())
                        elif channel is self.local:
                            self._receive(message)
                    self.simulation.tick()
                    if time.monotonic() >= due:
                        self.global_bus.send(self.announcement())
                        self.local.send(self.announcement())
                        self._publish_processes()
                        due = time.monotonic() + 1
            except (OSError, ValueError, TypeError) as exc:
                self.sup.say("control: %s" % exc)

    def _receive(self, message):
        kind = message.get("type")
        if kind == "command_status":
            self.simulation.receive(message)
        elif kind == "query" and message.get("master") in (None, self.id):
            self.local.send(self.announcement())
            self._publish_processes()
            for record in self.snapshot()["components"]:
                self.local.send(record)
        elif kind in ("component", "error"):
            identity = message.get("instance")
            if not isinstance(identity, str) or len(identity) > 200:
                return
            if kind == "component":
                previous = self.components.get(identity)
                sequence = message.get("seq")
                if not isinstance(sequence, int):
                    return
                if previous and sequence <= previous["record"].get("seq", -1):
                    return
                if previous is None and len(self.components) >= 4096:
                    return
                self.components[identity] = {"record": message, "seen": time.monotonic()}
                if isinstance(message.get("error"), dict):
                    self._component_error(message["error"])
            else:
                self._component_error(message)

    def _component_error(self, message):
        identity = (message.get("instance"), message.get("seq"))
        if identity not in self._error_ids:
            self._error_ids.append(identity)
            self.errors.append(message)

    def _publish_processes(self):
        with self.sup._lock:
            procs = list(self.sup.procs.items())
        for key, proc in procs:
            record = dict(v=1, type="process", master=self.id, key=key,
                          host=self.host, state=proc.state.value, pid=proc.pid,
                          health=proc.health, note=proc.health_note)
            self.local.send(record)
            state = (proc.state, proc.health, proc.health_note)
            if self._states.get(key) != state:
                if proc.state is State.FAILED or proc.health == "down":
                    lines = proc.log_lines()
                    self._error(key, proc.health_note or
                                ("\n".join(line.text for line in lines[-4:]) if lines else "process failed"))
                self._states[key] = state
        cutoff = time.monotonic() - 300
        self.components = {key: value for key, value in self.components.items()
                           if value["seen"] >= cutoff}

    def snapshot(self, include_simulation=True):
        with self.sup._lock:
            config = asdict(self.sup.config)
            procs = list(self.sup.procs.items())
            stale = list(self.sup.stale)
        processes = {}
        for key, proc in procs:
            fields = ("pid", "exit_code", "exit_signal", "started_at", "state_since",
                      "restarts", "health", "health_note", "built", "launch_id")
            processes[key] = {name: getattr(proc, name) for name in fields}
            processes[key].update(state=proc.state.value, alive=proc.alive,
                                  lru=asdict(proc.lru), log_seq=proc.seq())
        now = time.monotonic()
        components = []
        for value in self.components.values():
            record = value["record"]
            proc = processes.get(record.get("key")) if isinstance(record.get("key"), str) else None
            managed = bool(record.get("master") == self.id and proc)
            available = now - value["seen"] < LEASE and record.get("state") != "stopped"
            if managed:
                matches = (record["launch"] == proc["launch_id"] if record.get("launch")
                           else record.get("pid") == proc["pid"])
                available = available and proc["alive"] and matches
            components.append(dict(record, available=available, managed=managed,
                                   age=now - value["seen"]))
        return dict(master=self.announcement(), config=config, processes=processes,
                    components=components, errors=list(self.errors), stale=stale,
                    activity=self.sup.activity, message=self.sup.message,
                    simulation=self.simulation.snapshot() if include_simulation else None)

    def request(self, message):
        request_id = message.get("id")
        with self._lock:
            reply = dict(v=1, id=request_id, ok=False)
            if not isinstance(request_id, str) or not 1 <= len(request_id) <= 100:
                return dict(reply, error="request id required")
            if self._quit.is_set():
                return dict(reply, error="master is shutting down")
            if message.get("master") != self.id and message.get("op") != "identify":
                return dict(reply, error="master changed; attach again")
            fingerprint = encode(message)
            if request_id in self._replies:
                previous, response = self._replies[request_id]
                return response if previous == fingerprint else dict(reply, error="request id reused")
            try:
                result = self._dispatch(message)
                reply.update(ok=True, result=result)
            except Exception as exc:
                reply["error"] = str(exc)
            if message.get("op") not in ("snapshot", "logs", "identify"):
                self._replies[request_id] = (fingerprint, reply)
                while len(self._replies) > 1024:
                    self._replies.popitem(last=False)
            return reply

    def _dispatch(self, message):
        operation = message.get("op")
        if isinstance(operation, str) and operation.lower() in ("freeze", "frz", "run", "dstore", "restore", "rename_dstore"):
            return self.simulation.command(operation, message)
        if operation in ("start", "restart", "autostart", "restart_all", "reload") and self.simulation.mode != "running":
            if not self.simulation.reset_empty_session():
                raise ValueError("RUN the simulation before changing its process configuration")
        if operation == "identify":
            return self.announcement()
        if operation == "snapshot":
            return self.snapshot()
        if operation in ("start", "stop", "restart", "kill", "logs", "clear_log"):
            key = message.get("key")
            if not isinstance(key, str) or key not in self.sup.procs:
                raise ValueError("unknown configured LRU")
            if operation in ("start", "restart"):
                if any(record.get("key") == key and record["available"] and not record["managed"]
                       for record in self.snapshot()["components"]):
                    raise ValueError("an unowned component is running for this LRU")
            if operation == "logs":
                return [asdict(line) for line in self.sup.procs[key].log_lines()[-500:]]
            if operation == "clear_log":
                self.sup.procs[key].clear_log()
            else:
                getattr(self.sup, operation)(key)
        elif operation in ("autostart", "terminate", "restart_all"):
            getattr(self.sup, operation)()
        elif operation == "reload":
            self.sup._submit("reload", self.sup.reload)
        else:
            raise ValueError("unknown operation")
        return "accepted"

    def close(self):
        self._quit.set()
        if self._threads:
            self.server.shutdown()
        for thread in self._threads:
            thread.join(timeout=3)
        self.server.server_close()
        self.local.close()
        self.global_bus.close()
        if self._threads:
            finished = threading.Event()

            def stop():
                try:
                    self.sup._terminate_now()
                finally:
                    finished.set()

            self.sup._cancel.set()
            self.sup._held.update(self.sup.procs)
            self.sup._drain()
            self.sup._submit("shutdown", stop)
            finished.wait()
        self.sup.shutdown()
