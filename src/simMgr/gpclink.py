"""A GPC's discrete registers, over its debug socket.

The GPC in a configuration runs under `gpc dbg-serve`, which answers one
JSON object per line on a TCP port.  The link keeps one connection open,
polls `discretes`, `iop` and `status` for the discrete registers, the
redundancy management registers and where the machine is, and sends
`discset` to drive an input line, as `gpc discretes set` does from the
discrete bus.  Queries are answered while
the machine runs, so nothing here waits on it.

The bit tables mirror com/discretes.coffee.  Bit 0 is the most
significant bit of the 32-bit register.
"""

from __future__ import annotations

import json
import queue
import socket
import threading
import time
from typing import Dict, List, Optional, Set, Tuple

BITS_A: Dict[str, int] = {
    "halt": 0, "standby": 1, "run": 2, "ipl": 3,
    "mm1src": 4, "mm2src": 5, "mm1ready": 6, "mm2ready": 7,
    "bfsrunn1": 8, "bfsrunn2": 9, "bfsrunn3": 10, "bfsrunn4": 11,
    "ioterma": 12, "iotermb": 13,
    "dumpreq": 15,
    "stbyn1": 20, "stbyn2": 21, "stbyn3": 22, "stbyn4": 23,
    "runn1": 24, "runn2": 25, "runn3": 26, "runn4": 27,
    "syncn1": 28, "syncn2": 29, "syncn3": 30, "syncn4": 31,
}
BITS_B: Dict[str, int] = {
    "gpcid0": 0, "gpcid1": 1, "gpcid2": 2,
    "bfs1": 3, "bfs2": 4, "bfs3": 5,
    "crta": 6, "crtb": 7,
}
BITS_OUT: Dict[str, int] = {
    "ioactivetb": 7, "readytb": 9,
    "mm1reset": 12, "mm2reset": 13,
    "stbyout": 20, "bfsrunout": 22, "runout": 24, "syncout": 28,
    "idsource": 30, "iplout": 31,
}

#: Register names as `discretes` and `iop` report them.
REG_A, REG_B, REG_OUT = "DISCINA", "DISCINB", "DISCOUT"
INPUT_REGS = (REG_A, REG_B)
#: RM status as READ RM STATUS returns it: bit 0 the fail latch (the
#: voter or the GO/NO-GO timer), bits 11-14 the voter's four inputs.
REG_RM = "RMSTAT"
#: The MSC fail discrete register, 5 bits: 0x10 inhibits the outputs,
#: 0x08 to 0x01 are the fail votes against GPC N+1 to N+4
#: (IBM-85-C67-001 II-54, @SFD).
REG_FAIL = "FAILDSC"

POLL_HZ = 4.0
RETRY_S = 2.0
#: How long the IPL pushbutton is held (com/discretes.coffee IPL_PRESS_MS).
IPL_PRESS_S = 0.3


def bit(value: Optional[int], n: int) -> int:
    if value is None:
        return 0
    return (value >> (31 - n)) & 1


def field(value: Optional[int], bits: List[int]) -> int:
    """The bits listed, first as the most significant."""
    out = 0
    for n in bits:
        out = (out << 1) | bit(value, n)
    return out


class GpcLink:
    """One debug session, polled from a thread of its own."""

    def __init__(self, host: str, port: int, mode_default: Optional[str] = "standby"):
        self.host = host
        self.port = port
        # The MODE switch position driven when a GPC first answers with
        # none of HALT, STANDBY and RUN set.
        self.mode_default = mode_default
        self._fresh = False
        self.registers: Dict[str, Optional[int]] = {
            REG_OUT: None, REG_A: None, REG_B: None, REG_RM: None, REG_FAIL: None}
        self.status: dict = {}
        self.connected = False
        self.error = ""                  # why the last connection ended
        self.driven: Set[Tuple[str, int]] = set()    # (register, bit) set here
        self._queue: "queue.Queue[tuple]" = queue.Queue()
        self._quit = threading.Event()
        self._sock: Optional[socket.socket] = None
        self._file = None
        self._id = 0
        self._thread = threading.Thread(target=self._run, name="gpc-link-%d" % port,
                                        daemon=True)
        self._thread.start()

    @property
    def where(self) -> str:
        return "%s:%d" % (self.host, self.port)

    def close(self) -> None:
        self._quit.set()
        self._queue.put(("quit",))


    def set(self, reg: str, n: int, state: bool) -> None:
        """Drive input bit `n` of register A or B to `state`."""
        self._queue.put(("set", reg, n, bool(state)))

    def set_field(self, reg: str, bits: List[int], value: int) -> None:
        """Drive the bits listed, first as the most significant, to `value`."""
        for i, n in enumerate(bits):
            self.set(reg, n, bool((value >> (len(bits) - 1 - i)) & 1))

    def press_ipl(self) -> None:
        self.set(REG_A, BITS_A["ipl"], True)
        self._queue.put(("hold", IPL_PRESS_S))
        self.set(REG_A, BITS_A["ipl"], False)


    def _run(self) -> None:
        period = 1.0 / POLL_HZ
        while not self._quit.is_set():
            try:
                self._connect()
                while not self._quit.is_set():
                    self._serve_queue(period)
                    self._poll()
            except (OSError, ValueError) as exc:
                self.error = str(exc) or exc.__class__.__name__
            finally:
                self._drop()
            self._quit.wait(RETRY_S)

    def _connect(self) -> None:
        sock = socket.create_connection((self.host, self.port), timeout=2.0)
        sock.settimeout(5.0)
        self._sock = sock
        self._file = sock.makefile("r", encoding="utf-8", errors="replace")
        self.error = ""
        self.connected = True
        self._fresh = True

    def _drop(self) -> None:
        self.connected = False
        for closer in (self._file, self._sock):
            if closer is not None:
                try:
                    closer.close()
                except OSError:
                    pass
        self._file = self._sock = None
        # A GPC that comes back starts from its defaults.
        self.driven.clear()

    def _serve_queue(self, period: float) -> None:
        """Send what the interface asked for, then let a poll interval pass."""
        deadline = time.time() + period
        while True:
            wait = deadline - time.time()
            if wait <= 0:
                return
            try:
                item = self._queue.get(timeout=wait)
            except queue.Empty:
                return
            if item[0] == "quit":
                return
            if item[0] == "hold":
                self._quit.wait(item[1])
                continue
            _, reg, n, state = item
            reply = self._call("discset", {"bit": str(n), "state": state, "b": reg == REG_B})
            if reply is not None:
                self.driven.add((reg, n))
                self._take_registers(reply)

    def _poll(self) -> None:
        reply = self._call("discretes")
        if reply is not None:
            self._take_registers(reply)
            if self._fresh:
                self._fresh = False
                self._rest_mode()
        reply = self._call("iop")
        if reply is not None:
            self._take_registers(reply)
        reply = self._call("status")
        if reply is not None:
            self.status = reply

    def _rest_mode(self) -> None:
        a = self.registers.get(REG_A)
        if a is None or not self.mode_default:
            return
        if any(bit(a, BITS_A[name]) for name in ("halt", "standby", "run")):
            return
        n = BITS_A[self.mode_default]
        if self._call("discset", {"bit": str(n), "state": True}) is not None:
            self.driven.add((REG_A, n))

    def _take_registers(self, result: dict) -> None:
        for reg in result.get("registers") or []:
            name = reg.get("name")
            if name in self.registers:
                self.registers[name] = int(reg.get("value") or 0)

    def _call(self, cmd: str, args: Optional[dict] = None) -> Optional[dict]:
        """One request, and its reply; events arriving meanwhile are skipped."""
        self._id += 1
        request = {"id": self._id, "cmd": cmd}
        if args:
            request["args"] = args
        self._sock.sendall((json.dumps(request) + "\n").encode("utf-8"))
        while True:
            line = self._file.readline()
            if not line:
                raise OSError("connection closed")
            try:
                message = json.loads(line)
            except ValueError:
                continue
            if message.get("id") != self._id:
                continue
            if message.get("ok"):
                return message.get("result") or {}
            error = message.get("error") or {}
            self.error = "%s: %s" % (cmd, error.get("message") or error.get("code") or "failed")
            return None
