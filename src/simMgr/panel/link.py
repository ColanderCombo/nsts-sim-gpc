"""Threaded panel-bus link for controls held and indicators displayed here."""

from __future__ import annotations

import queue
import threading
import time
from typing import Dict, List, Optional, Tuple

from .bus import ENUM, REQUEST, SET, VALUE, Channel, Message, wait
from .catalog import Control, Panel

#: How often the indicators this frontend draws are asked for again while
#: nothing has answered.
POLL_S = 2.0


class PanelLink:
    """The panels held here, on one channel."""

    def __init__(self, base_port: int, panels: List[Panel]):
        self.base_port = base_port
        self.panels = {p.name: p for p in panels}
        self.controls: Dict[str, Control] = {}
        self.state: Dict[str, object] = {}
        self._heard: Dict[str, bool] = {}
        for panel in panels:
            for control in panel.controls.values():
                self.controls[control.key] = control
                self.state[control.key] = control.rest
                self._heard[control.key] = control.crew
        self.error = ""
        self._release: List[Tuple[float, str]] = []     # (when, key) to let go
        self._queue: "queue.Queue[tuple]" = queue.Queue()
        self._quit = threading.Event()
        self._thread = threading.Thread(target=self._run, name="panel-link", daemon=True)
        self._thread.start()

    def close(self) -> None:
        self._quit.set()
        self._queue.put(("quit",))


    def at(self, control: Control):
        """Where the control stands."""
        return self.state.get(control.key, control.rest)

    def heard(self, control: Control) -> bool:
        return self._heard.get(control.key, False)


    def put(self, control: Control, value) -> None:
        """Put a crew control where the message says, and publish it."""
        if not control.crew:
            return
        self._queue.put(("put", control.key, value))
        self.state[control.key] = value
        if control.kind == "momentary" and value in control.spring:
            self._queue.put(("release", control.key, time.time() + control.hold))
        return

    def press(self, control: Control) -> None:
        """A pushbutton made, and released after its hold."""
        if control.kind != "pushbutton":
            return
        self.put(control, True)
        self._queue.put(("release", control.key, time.time() + control.hold))

    def step(self, control: Control, delta: int) -> None:
        """A thumbwheel turned."""
        if control.kind != "thumbwheel":
            return
        low, high = (control.range or [0, 0xFFFF])[:2]
        value = int(self.state.get(control.key, 0)) + delta
        self.put(control, max(int(low), min(int(high), value)))


    def _run(self) -> None:
        try:
            channel = Channel(self.base_port)
        except OSError as exc:
            self.error = str(exc) or exc.__class__.__name__
            return
        for key, control in self.controls.items():
            if control.crew:
                channel.report(key, control.value_kind, self.state[key])
        next_poll = 0.0
        while not self._quit.is_set():
            now = time.time()
            if now >= next_poll:
                next_poll = now + POLL_S
                for key, control in self.controls.items():
                    if not control.crew and not self._heard[key]:
                        channel.request(key)
            self._serve_queue(channel)
            for when, key in [r for r in self._release if r[0] <= time.time()]:
                self._release.remove((when, key))
                self._let_go(channel, key)
            for _ in wait([channel], 0.05):
                for m in channel.recv():
                    self._recv(channel, m)
        channel.close()

    def _let_go(self, channel: Channel, key: str) -> None:
        control = self.controls[key]
        self.state[key] = control.rest
        channel.report(key, control.value_kind, control.rest)

    def _serve_queue(self, channel: Channel) -> None:
        while True:
            try:
                item = self._queue.get_nowait()
            except queue.Empty:
                return
            if item[0] == "quit":
                return
            if item[0] == "release":
                self._release.append((item[2], item[1]))
                continue
            _, key, value = item
            channel.report(key, self.controls[key].value_kind, value)

    def _recv(self, channel: Channel, m: Message) -> None:
        control = self.controls.get(m.key)
        if m.op == REQUEST:
            for key, held in self.controls.items():
                if held.crew and (not m.key or key.startswith(m.key)):
                    channel.report(key, held.value_kind, self.state[key])
            return
        if control is None:
            return
        value = m.value
        if control.value_kind == ENUM:
            value = control.position(value)
            if value is None:
                return
        if m.op == VALUE and not control.crew:
            self.state[m.key] = value
            self._heard[m.key] = True
            return
        if m.op == SET and control.crew:
            self.state[m.key] = value
            channel.report(m.key, control.value_kind, value)
        return
