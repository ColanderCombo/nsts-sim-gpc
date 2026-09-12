"""Discovery and attached views of a master's supervisor state."""

import select
import socket
import threading
import time
import uuid
from pathlib import Path

from .config import Health, Lru, SimConfig
from .controlbus import Channel, DISCOVERY_GROUP, LEASE, decode, discovery_port, encode
from .process import LogLine, State


def discover(timeout=1.2):
    channel = Channel(discovery_port(), DISCOVERY_GROUP)
    found = {}
    deadline = time.monotonic() + timeout
    try:
        while time.monotonic() < deadline:
            channel.send(dict(v=1, type="discover"))
            until = min(deadline, time.monotonic() + 0.3)
            while time.monotonic() < until:
                ready, _, _ = select.select([channel.sock], [], [], max(0, until - time.monotonic()))
                if not ready:
                    break
                record = channel.recv()
                if (record and record.get("type") == "master"
                        and all(isinstance(record.get(name), str)
                                for name in ("master", "name", "host", "address"))
                        and isinstance(record.get("basePort"), int)
                        and 1024 <= record["basePort"] <= 65400):
                    found[record["master"]] = record
    finally:
        channel.close()
    return sorted(found.values(), key=lambda record: (record.get("name", ""), record["master"]))


class Client:
    def __init__(self, host, port):
        self.host, self.port = host, port
        self.master = None
        self.master = self.call("identify")["master"]

    def call(self, operation, key=None, request_id=None, **parameters):
        message = dict(v=1, id=request_id or str(uuid.uuid4()), master=self.master,
                       op=operation, key=key, **parameters)
        for attempt in range(2):
            try:
                with socket.create_connection((self.host, self.port), timeout=3) as connection:
                    connection.sendall(encode(message) + b"\n")
                    with connection.makefile("rb") as reader:
                        data = reader.readline(16 * 1024 * 1024 + 1)
                if len(data) > 16 * 1024 * 1024:
                    raise ValueError("invalid master response size")
                if not data.endswith(b"\n"):
                    raise ConnectionError("incomplete master response")
                break
            except OSError as exc:
                if attempt == 1:
                    raise ConnectionError("request %s unconfirmed: %s" % (message["id"], exc)) from exc
        response = decode(data)
        if not response or response.get("id") != message["id"]:
            raise ValueError("invalid master response")
        if not response.get("ok"):
            raise ValueError(response.get("error", "control request failed"))
        return response.get("result")


def _lru(record):
    fields = dict(record)
    fields["cwd"] = Path(fields["cwd"])
    fields["health"] = Health(**fields["health"])
    return Lru(**fields)


class RemoteProcess:
    def __init__(self, client, record):
        self.client = client
        self._logs = []
        self.watch_logs = False
        self.update(record)

    def update(self, record):
        fields = dict(record, lru=_lru(record["lru"]), state=State(record["state"]),
                      log_seq=record.get("log_seq"))
        self.__dict__.update(fields)

    @property
    def uptime(self):
        return time.time() - self.started_at if self.alive and self.started_at else None

    def log_lines(self):
        self.watch_logs = True
        return list(self._logs)

    def log_count(self):
        return len(self._logs)

    def clear_log(self):
        self.client.call("clear_log", self.lru.key)
        self._logs = []


class RemoteSupervisor:
    attached = True

    def __init__(self, client):
        self.client = client
        self.procs = {}
        self.components = []
        self.simulation_error = None
        self.last_update = 0
        self._quit = threading.Event()
        self._refresh()
        self._thread = threading.Thread(target=self._poll, daemon=True)
        self._thread.start()

    def _refresh(self):
        state = self.client.call("snapshot")
        received_at = time.monotonic()
        config = dict(state["config"])
        config["lrus"] = [_lru(record) for record in config["lrus"]]
        for name in ("run_file", "sim_file", "log_dir"):
            config[name] = Path(config[name]) if config[name] else None
        config["paths"] = {name: Path(value) for name, value in config["paths"].items()}
        procs = {}
        for key, record in state["processes"].items():
            proc = self.procs.get(key)
            if proc is None:
                proc = RemoteProcess(self.client, record)
            else:
                proc.update(record)
            if proc.watch_logs:
                proc._logs = [LogLine(**line) for line in self.client.call("logs", key)]
            procs[key] = proc
        self.config = SimConfig(**config)
        self.procs = procs
        self.stale = set(state["stale"])
        self.activity, self.message = state["activity"], state["message"]
        self.components = state["components"]
        self.simulation = state.get("simulation") or {}
        self.master_info = state["master"]
        self.last_update = received_at

    def _poll(self):
        while not self._quit.wait(0.5):
            try:
                self._refresh()
            except (OSError, ValueError) as exc:
                self.last_update = 0
                self.message = "master unavailable: %s" % exc

    @property
    def connected(self):
        return time.monotonic() - self.last_update < LEASE

    @property
    def order(self):
        return list(self.procs)

    def lru(self, key):
        return self.procs[key].lru

    def busy(self):
        return bool(self.activity)

    def say(self, text):
        self.message = text

    def _command(self, operation, key=None):
        try:
            return self.client.call(operation, key)
        except (OSError, ValueError) as exc:
            self.say(str(exc))

    def sim_command(self, operation, **parameters):
        self.simulation_error = None
        if not self.simulation:
            self.simulation_error = "Restart the background manager to enable simulation control"
            self.say(self.simulation_error)
            return
        try:
            return self.client.call(operation, **parameters)
        except (OSError, ValueError) as exc:
            self.simulation_error = str(exc)
            self.say(self.simulation_error)

    def start(self, key):
        return self._command("start", key)

    def stop(self, key):
        return self._command("stop", key)

    def restart(self, key):
        return self._command("restart", key)

    def kill(self, key):
        return self._command("kill", key)

    def autostart(self):
        return self._command("autostart")

    def terminate(self):
        return self._command("terminate")

    def restart_all(self):
        return self._command("restart_all")

    def reload(self):
        return self._command("reload")

    def shutdown(self):
        self._quit.set()
        self._thread.join(timeout=4)
