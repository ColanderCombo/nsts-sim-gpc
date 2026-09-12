"""Panel-side access to IDP discrete channels.

``idpDiscretes.coffee`` defines registers and protocol; ``idpSel.coffee``
defines switch wiring. Unanswered channels expire after ``LOST_AFTER`` polls.
"""

from __future__ import annotations

import queue
import threading
import time
from typing import Dict, List, Optional, Set, Tuple

from .discretebus import (Channel, REG_A, REG_OUT, SET, RESET, VALUE, apply, bit_mask,
                          wait)

IDP_IDS = (1, 2, 3, 4)
BUS_OFFSET = 86            # com/bus.civet _idpDiscretes1
BITS_A: Dict[str, int] = {"kybdsela": 0, "kybdselb": 1, "load": 2}
BITS_STATUS: Dict[str, int] = {"loaded": 0, "loading": 1}
REG_STATUS = REG_OUT

POLL_S = 1.0
LOST_AFTER = 3
#: How long the LOAD momentary is held (meds/idp/idpDiscretes LOAD_PRESS_MS).
LOAD_PRESS_S = 0.3

LEFT_POSITIONS = (1, 3)
RIGHT_POSITIONS = (2, 3)
DEFAULT_POSITIONS = (1, 2)


def kybd_sel_lines(idp: int, left: int, right: int) -> Tuple[bool, bool]:
    """(A, B) at IDP `idp` with the switches at `left` and `right`."""
    if idp == 1:
        return False, left == 1
    if idp == 2:
        return right == 2, False
    if idp == 3:
        return left == 3, right == 3
    return True, False


def bit(value: Optional[int], n: int) -> int:
    if value is None:
        return 0
    return (value >> (31 - n)) & 1


class IdpLinks:
    """The four channels, served from one thread."""

    def __init__(self, base_port: int):
        self.base_port = base_port
        self.registers: Dict[int, Dict[int, Optional[int]]] = {
            n: {REG_A: None, REG_STATUS: None} for n in IDP_IDS}
        self.heard: Dict[int, bool] = {n: False for n in IDP_IDS}
        self.driven: Set[Tuple[int, int]] = set()      # (idp, bit) driven here
        self.error = ""
        self._release: List[Tuple[float, int, int]] = []   # (when, idp, bit) to drop
        self._missed: Dict[int, int] = {n: 0 for n in IDP_IDS}
        self._queue: "queue.Queue[tuple]" = queue.Queue()
        self._quit = threading.Event()
        self._thread = threading.Thread(target=self._run, name="idp-links", daemon=True)
        self._thread.start()

    def close(self) -> None:
        self._quit.set()
        self._queue.put(("quit",))


    def connected(self, n: int) -> bool:
        return self.heard.get(n, False)

    def lines(self, n: int) -> Tuple[bool, bool]:
        a = self.registers[n][REG_A]
        return bool(bit(a, BITS_A["kybdsela"])), bool(bit(a, BITS_A["kybdselb"]))

    def load_line(self, n: int) -> bool:
        return bool(bit(self.registers[n][REG_A], BITS_A["load"]))

    def loading(self, n: int) -> bool:
        return bool(bit(self.registers[n][REG_STATUS], BITS_STATUS["loading"]))

    def positions(self) -> Optional[Tuple[int, int]]:
        """(LEFT, RIGHT) from the lines the IDPs hold; None with no IDP heard."""
        l1, l2, l3 = self.lines(1), self.lines(2), self.lines(3)
        if self.heard[3]:
            left = 3 if l3[0] else 1
            right = 3 if l3[1] else 2
        elif self.heard[1] or self.heard[2]:
            left = (1 if l1[1] else 3) if self.heard[1] else DEFAULT_POSITIONS[0]
            right = (2 if l2[0] else 3) if self.heard[2] else DEFAULT_POSITIONS[1]
        else:
            return None
        return left, right


    def set(self, n: int, name: str, state: bool) -> None:
        """Drive one of IDP n's register A lines."""
        self._queue.put(("set", n, BITS_A[name], bool(state)))

    def set_sel(self, left: int, right: int) -> None:
        """Throw the IDP/CRT SEL switches: every line they make, on IDP 1, 2 and 3."""
        if left not in LEFT_POSITIONS or right not in RIGHT_POSITIONS:
            return
        for n in (1, 2, 3):
            a, b = kybd_sel_lines(n, left, right)
            self.set(n, "kybdsela", a)
            self.set(n, "kybdselb", b)

    def press_load(self, n: int) -> None:
        """The momentary made, and released LOAD_PRESS_S later."""
        self.set(n, "load", True)
        self._queue.put(("release", n, BITS_A["load"], time.time() + LOAD_PRESS_S))


    def _run(self) -> None:
        channels: Dict[int, Channel] = {}
        try:
            for n in IDP_IDS:
                channels[n] = Channel(self.base_port + BUS_OFFSET + n - 1)
        except OSError as exc:
            self.error = str(exc) or exc.__class__.__name__
            for ch in channels.values():
                ch.close()
            return
        by_fd = {ch.fileno(): n for n, ch in channels.items()}
        next_poll = 0.0
        while not self._quit.is_set():
            now = time.time()
            if now >= next_poll:
                next_poll = now + POLL_S
                for n, ch in channels.items():
                    self._missed[n] += 1
                    if self._missed[n] >= LOST_AFTER and self.heard[n]:
                        self.heard[n] = False
                        self.registers[n] = {REG_A: None, REG_STATUS: None}
                        self.driven = {d for d in self.driven if d[0] != n}
                    ch.request(REG_A)
                    ch.request(REG_STATUS)
            self._serve_queue(channels)
            due = [r for r in self._release if r[0] <= time.time()]
            for r in due:
                self._release.remove(r)
                channels[r[1]].set(REG_A, r[2], False)
            for ch in wait(list(channels.values()), 0.05):
                n = by_fd[ch.fileno()]
                for op, reg, mask in ch.recv():
                    if reg not in self.registers[n]:
                        continue
                    if op == VALUE:
                        self._missed[n] = 0
                        self.heard[n] = True
                    elif not self.heard[n]:
                        continue
                    self.registers[n][reg] = apply(self.registers[n][reg] or 0, op, mask)
        for ch in channels.values():
            ch.close()

    def _serve_queue(self, channels: Dict[int, Channel]) -> None:
        while True:
            try:
                item = self._queue.get_nowait()
            except queue.Empty:
                return
            if item[0] == "quit":
                return
            if item[0] == "release":
                self._release.append((item[3], item[1], item[2]))
                continue
            _, n, b, state = item
            channels[n].set(REG_A, b, state)
            self.driven.add((n, b))
