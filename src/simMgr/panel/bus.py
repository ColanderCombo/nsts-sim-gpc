"""Panel-bus datagrams for in-process frontends.

After the bus header, five big-endian halfwords carry operation, kind,
key length, text length, and value-word count, followed by key, text, and
value words. Operations are SET=1, REQUEST=3, VALUE=4; kinds are NONE=0,
LOGIC=1, ENUM=2, WORD=3, REAL=4. Text packs two characters per halfword,
high byte first. ``_PANEL`` is base-port offset 130. See
``panel/panelBus.coffee`` and ``com/bus.civet``.
"""

from __future__ import annotations

import select
import socket
import struct
from dataclasses import dataclass
from typing import List, Optional, Union

MULTICAST_GROUP = "239.255.1.1"
IFACE = "127.0.0.1"
BUS_OFFSET = 130

SET, REQUEST, VALUE = 1, 3, 4
NONE, LOGIC, ENUM, WORD, REAL = 0, 1, 2, 3, 4

HEADER = b"\x02\x00"
HEADER_WORDS = 5

OP_NAME = {SET: "SET", REQUEST: "REQUEST", VALUE: "VALUE"}
KIND_NAME = {NONE: "none", LOGIC: "logic", ENUM: "enum", WORD: "word", REAL: "real"}

#: The two legends every talkback drum carries besides its words.
GRAY = "gray"
BARBERPOLE = "barberpole"

Value = Union[bool, int, float, str, None]


@dataclass
class Message:
    op: int
    kind: int
    key: str
    value: Value = None

    @property
    def panel(self) -> str:
        return self.key.split("/", 1)[0] if self.key else ""

    @property
    def control(self) -> str:
        return self.key.split("/", 1)[1] if "/" in self.key else ""


def _text_words(n: int) -> int:
    return (n + 1) // 2


def _put_text(out: List[int], text: str) -> None:
    for i in range(_text_words(len(text))):
        hi = ord(text[2 * i]) & 0xFF
        lo = ord(text[2 * i + 1]) & 0xFF if 2 * i + 1 < len(text) else 0
        out.append((hi << 8) | lo)


def _get_text(words: List[int], at: int, length: int) -> str:
    out = []
    for i in range(length):
        w = words[at + (i >> 1)]
        out.append(chr((w >> 8) & 0xFF if i % 2 == 0 else w & 0xFF))
    return "".join(out)


def encode(op: int, kind: int, key: str, value: Value = None) -> bytes:
    text = ""
    words: List[int] = []
    if kind == LOGIC:
        words = [1 if value else 0]
    elif kind == WORD:
        words = [int(value or 0) & 0xFFFF]
    elif kind == ENUM:
        text = str(value or "")
    elif kind == REAL:
        words = list(struct.unpack(">HH", struct.pack(">f", float(value or 0.0))))
    body = [op & 0xFFFF, kind & 0xFFFF, len(key), len(text), len(words)]
    _put_text(body, key)
    _put_text(body, text)
    body.extend(words)
    return HEADER + struct.pack(">%dH" % len(body), *body)


def decode(data: bytes) -> Optional[Message]:
    """The message, or None for a datagram that is not a panel message."""
    if not data:
        return None
    hlen = max(data[0] or 2, 2)
    body = data[hlen:]
    if len(body) < HEADER_WORDS * 2:
        return None
    words = list(struct.unpack(">%dH" % (len(body) // 2), body[:len(body) // 2 * 2]))
    op, kind, key_len, val_len, n_words = words[:HEADER_WORDS]
    if op not in OP_NAME or kind not in KIND_NAME:
        return None
    need = HEADER_WORDS + _text_words(key_len) + _text_words(val_len) + n_words
    if len(words) < need:
        return None
    at = HEADER_WORDS
    key = _get_text(words, at, key_len)
    at += _text_words(key_len)
    text = _get_text(words, at, val_len)
    at += _text_words(val_len)
    value: Value = None
    if kind == LOGIC:
        value = bool(words[at])
    elif kind == WORD:
        value = words[at]
    elif kind == ENUM:
        value = text
    elif kind == REAL:
        value = struct.unpack(">f", struct.pack(">HH", words[at], words[at + 1]))[0]
    return Message(op=op, kind=kind, key=key, value=value)


class Channel:
    """The panel bus: one socket in the group on its port."""

    def __init__(self, base_port: int):
        self.port = base_port + BUS_OFFSET
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        if hasattr(socket, "SO_REUSEPORT"):
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        sock.bind(("", self.port))
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(IFACE))
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_LOOP, 1)
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
                        socket.inet_aton(MULTICAST_GROUP) + socket.inet_aton(IFACE))
        sock.setblocking(False)
        self.sock = sock

    def fileno(self) -> int:
        return self.sock.fileno()

    def send(self, op: int, kind: int, key: str, value: Value = None) -> None:
        self.sock.sendto(encode(op, kind, key, value), (MULTICAST_GROUP, self.port))

    def report(self, key: str, kind: int, value: Value) -> None:
        self.send(VALUE, kind, key, value)

    def request(self, key: str = "") -> None:
        self.send(REQUEST, NONE, key)

    def recv(self) -> List[Message]:
        """Every panel message waiting at the socket."""
        out = []
        while True:
            try:
                data, _ = self.sock.recvfrom(4096)
            except (BlockingIOError, InterruptedError):
                return out
            except OSError:
                return out
            m = decode(data)
            if m is not None:
                out.append(m)

    def close(self) -> None:
        try:
            self.sock.close()
        except OSError:
            pass


def wait(channels: List[Channel], timeout: float) -> List[Channel]:
    """The channels with a datagram waiting, within `timeout` seconds."""
    if not channels:
        select.select([], [], [], timeout)
        return []
    ready, _, _ = select.select(channels, [], [], timeout)
    return ready
