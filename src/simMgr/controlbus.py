"""Simulation control protocol, version 1.

Transport   Endpoint                         Payload
UDP         239.255.1.2:6899                 global discovery
UDP         239.255.1.1:<base port>          local records and components
TCP         <master>:<base port>             newline-delimited requests/replies

All records are UTF-8 JSON with ``v: 1``. UDP datagrams are limited to
8000 bytes; messages to 262144 bytes use ``id/index/count/data`` fragments.
Components advertise every second and expire after five seconds. TCP requests
carry ``v/id/master/op/key``; replies carry ``v/id/ok/result|error``. The
master replays its latest 1024 request IDs, and clients retry once with the
same ID.

The protocol is unauthenticated and defaults to loopback. Version 1 reserves
launcher authority to the master and launches processes on its host.
"""

import json
import base64
import os
import socket
import time
import uuid

GROUP = "239.255.1.1"
DISCOVERY_GROUP = "239.255.1.2"
LEASE = 5.0
MAX_DATAGRAM = 8000
MAX_MESSAGE = 262144
CHUNK_BYTES = 5600
MAX_REQUEST = 65536


def interface():
    return os.environ.get("NSTS_BUS_IFACE", "127.0.0.1")


def discovery_port():
    return int(os.environ.get("NSTS_SIM_DISCOVERY_PORT", "6899"))


def encode(message):
    return json.dumps(message, separators=(",", ":"), default=str).encode("utf8")


def decode(data):
    try:
        message = json.loads(data)
    except (ValueError, UnicodeError, RecursionError):
        return None
    return message if isinstance(message, dict) and message.get("v") == 1 else None


def packets(message):
    data = encode(message)
    if len(data) > MAX_MESSAGE:
        raise ValueError("control message exceeds 262144 bytes")
    if len(data) <= MAX_DATAGRAM:
        return [data]
    identity = uuid.uuid4().hex
    count = (len(data) + CHUNK_BYTES - 1) // CHUNK_BYTES
    return [encode(dict(v=1, type="fragment", id=identity, index=index, count=count,
                        data=base64.b64encode(data[index * CHUNK_BYTES:(index + 1) * CHUNK_BYTES]).decode("ascii")))
            for index in range(count)]


class Reassembler:
    def __init__(self):
        self.pending = {}

    def receive(self, message, source):
        now = time.monotonic()
        self.pending = {key: value for key, value in self.pending.items() if now - value["time"] < LEASE}
        if not message or message.get("type") != "fragment":
            return message
        identity, index, count = message.get("id"), message.get("index"), message.get("count")
        if (not isinstance(identity, str) or len(identity) > 300 or
                type(index) is not int or type(count) is not int or
                not 0 <= index < count <= (MAX_MESSAGE + CHUNK_BYTES - 1) // CHUNK_BYTES):
            return None
        try:
            data = base64.b64decode(message["data"], validate=True)
        except (KeyError, ValueError, TypeError):
            return None
        if len(data) > CHUNK_BYTES:
            return None
        key = (source, identity)
        if key not in self.pending:
            if len(self.pending) >= 64:
                return None
            self.pending[key] = dict(time=now, count=count, chunks={})
        entry = self.pending[key]
        if entry["count"] != count:
            return None
        entry["chunks"][index] = data
        if len(entry["chunks"]) != count:
            return None
        del self.pending[key]
        data = b"".join(entry["chunks"][index] for index in range(count))
        return decode(data) if len(data) <= MAX_MESSAGE else None


class Channel:
    def __init__(self, port, group=GROUP):
        self.port, self.group = port, group
        self.reassembler = Reassembler()
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            if hasattr(socket, "SO_REUSEPORT"):
                self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
            self.sock.bind(("", port))
            self.sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF,
                                 socket.inet_aton(interface()))
            self.sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_LOOP, 1)
            self.sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 1)
            self.sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
                                 socket.inet_aton(group) + socket.inet_aton(interface()))
            self.sock.setblocking(False)
        except Exception:
            self.sock.close()
            raise

    def send(self, message):
        for data in packets(message):
            self.sock.sendto(data, (self.group, self.port))

    def recv(self):
        data, source = self.sock.recvfrom(65536)
        return self.reassembler.receive(decode(data), source)

    def close(self):
        self.sock.close()
