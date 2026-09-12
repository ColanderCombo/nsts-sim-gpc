"""Discrete-bus datagrams for in-process panels.

After the bus header, four big-endian halfwords carry operation, register,
mask-high, and mask-low. Operations are SET=1, RESET=2, REQUEST=3, VALUE=4;
registers are A=1, B=2, OUT=3; bit 0 is mask 0x80000000. See
``com/discretes.coffee`` and ``com/bus.civet``.
"""

from __future__ import annotations

import select
import socket
import struct
from typing import List, Optional, Tuple

MULTICAST_GROUP = "239.255.1.1"
IFACE = "127.0.0.1"

SET, RESET, REQUEST, VALUE = 1, 2, 3, 4
REG_A, REG_B, REG_OUT = 1, 2, 3
HEADER = b"\x02\x00"


def bit_mask(n: int) -> int:
    return 1 << (31 - n)


def encode(op: int, reg: int, mask: int) -> bytes:
    return HEADER + struct.pack(">HHHH", op & 0xFFFF, reg & 0xFFFF,
                                (mask >> 16) & 0xFFFF, mask & 0xFFFF)


def decode(data: bytes) -> Optional[Tuple[int, int, int]]:
    """(op, reg, mask), or None for a datagram that is not a discrete message."""
    if not data:
        return None
    hlen = data[0] or 2
    hlen = max(hlen, 2)
    body = data[hlen:]
    if len(body) < 8:
        return None
    op, reg, hi, lo = struct.unpack(">HHHH", body[:8])
    if op not in (SET, RESET, REQUEST, VALUE) or reg not in (REG_A, REG_B, REG_OUT):
        return None
    return op, reg, (hi << 16) | lo


def apply(value: int, op: int, mask: int) -> int:
    if op == SET:
        return (value | mask) & 0xFFFFFFFF
    if op == RESET:
        return (value & ~mask) & 0xFFFFFFFF
    if op == VALUE:
        return mask & 0xFFFFFFFF
    return value


class Channel:
    """One channel: a socket in the group on its port."""

    def __init__(self, port: int):
        self.port = port
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        if hasattr(socket, "SO_REUSEPORT"):
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        sock.bind(("", port))
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(IFACE))
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_LOOP, 1)
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
                        socket.inet_aton(MULTICAST_GROUP) + socket.inet_aton(IFACE))
        sock.setblocking(False)
        self.sock = sock

    def fileno(self) -> int:
        return self.sock.fileno()

    def send(self, op: int, reg: int, mask: int) -> None:
        self.sock.sendto(encode(op, reg, mask), (MULTICAST_GROUP, self.port))

    def set(self, reg: int, n: int, state: bool) -> None:
        self.send(SET if state else RESET, reg, bit_mask(n))

    def request(self, reg: int) -> None:
        self.send(REQUEST, reg, 0)

    def recv(self) -> List[Tuple[int, int, int]]:
        """Every discrete message waiting at the socket."""
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
