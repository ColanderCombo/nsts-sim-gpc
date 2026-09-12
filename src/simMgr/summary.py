"""Grouped simulation status and field-specific operations, bus and log views."""

import curses
import time
from collections import OrderedDict, deque

from .controlbus import LEASE
from .process import LIVE, State
from .screen import Buttons, fmt_duration
from .views import ENTER, ESCAPE, MainView, run_command, state_colour

SPINNER = "|/-\\"
CHANGING = (State.BUILDING, State.STARTING, State.STOPPING)
GLOBAL_BUSES = {"_POWER", "_PANEL"}


def components(sup, key, last_known=False):
    proc = sup.procs.get(key)
    if proc is None:
        return []
    records = [record for record in sup.components if record.get("key") == key and record.get("managed")]
    launch = getattr(proc, "launch_id", None)
    if launch:
        return [record for record in records if record.get("launch") == launch or
                (not record.get("launch") and record.get("pid") == proc.pid)]
    pid = proc.pid
    if pid is None and last_known and records:
        pid = min(records, key=lambda record: record.get("age", float("inf"))).get("pid")
    return [record for record in records if record.get("pid") == pid]


def communicating(sup, key):
    age = time.monotonic() - sup.last_update
    return sup.connected and any(record.get("available") and record.get("age", 0) + age < LEASE
                                 for record in components(sup, key))


def communication_glyph(sup, key, glyphs):
    if communicating(sup, key):
        return glyphs.up
    proc = sup.procs.get(key)
    if proc is None or proc.state in (State.STOPPED, State.EXITED):
        return glyphs.dot
    return glyphs.down


def simulation_status(sup):
    procs = list(sup.procs.values())
    if not sup.connected:
        return "unavailable", "unknown", "warn"
    if sup.busy() or any(proc.state in CHANGING for proc in procs):
        state = "changing"
    elif any(proc.state is State.FAILED for proc in procs):
        state = "failed"
    elif any(proc.state is State.RUNNING for proc in procs):
        state = "running"
    else:
        state = "stopped"
    active = [proc for proc in procs if proc.state in LIVE or proc.state is State.FAILED]
    if any(proc.state is State.FAILED or proc.health == "down" for proc in active):
        return state, "degraded", "down"
    if active and all(proc.state is State.RUNNING and proc.health == "up" for proc in active):
        return state, "healthy", "up"
    return state, "unknown" if active else "idle", "warn" if active else "dim"


def grouped_columns(sup, height):
    groups = OrderedDict()
    for key in sup.order:
        proc = sup.procs.get(key)
        if proc:
            lru = proc.lru
            groups.setdefault(lru.kind or lru.lru, []).append(key)
    columns, column = [], []
    height = max(3, height)
    for kind, keys in groups.items():
        if column and (height - len(column) < 3 or
                       (len(keys) + 1 <= height and len(column) + len(keys) + 2 > height)):
            columns.append(column)
            column = []
        if column:
            column.append(("", None))
        column.append((kind, None))
        for key in keys:
            if len(column) >= height:
                columns.append(column)
                column = [(kind, None)]
            column.append((kind, key))
    if column:
        columns.append(column)
    return columns


class SummaryView:
    def __init__(self, app):
        self.app = app
        self.selected = None
        self.field = 0
        self.traffic = {}
        self.focus = "lrus"
        self.buttons = Buttons(MainView.COMMANDS)

    def geometry(self, screen):
        sup = self.app.sup
        columns = grouped_columns(sup, screen.h - 7)
        positions = {key: (column, row) for column, rows in enumerate(columns)
                     for row, (_, key) in enumerate(rows) if key is not None}
        if self.selected not in positions:
            self.selected = next(iter(positions), None)
        self.traffic = {key: frame for key, frame in self.traffic.items() if key in positions}
        name_width = min(16, max([len(key) for key in positions] + [8]))
        width = name_width + 12
        visible = max(1, screen.w // width)
        return columns, positions, name_width, width, visible

    def spinner(self, proc):
        sequence = proc.log_seq
        if sequence is None:
            return "?"
        return SPINNER[(sequence - 1) % len(SPINNER)] if sequence else self.app.screen.g.dot

    def bus_glyph(self, key, glyphs):
        previous, direction, colour = self.traffic.get(key, ({}, None, "title"))
        current, changed = {}, {}
        for record in components(self.app.sup, key):
            for bus in record.get("buses", []):
                if bus["name"] == "_simControl":
                    continue
                traffic = bus.get("traffic") or {}
                identity = (record["instance"], bus["name"])
                counts = tuple(traffic.get(name, 0) for name in ("rx", "tx"))
                current[identity] = counts
                old = previous.get(identity, (0, 0))
                for index, name in enumerate(("rx", "tx")):
                    if counts[index] > old[index]:
                        changed.setdefault(name, set()).add(bus["name"] in GLOBAL_BUSES)
        if changed:
            directions = {name for name, scopes in changed.items() if False in scopes} or set(changed)
            direction = ("rx" if direction == "tx" else "tx") if len(directions) == 2 else next(iter(directions))
            colour = "bus_global" if all(changed[direction]) else "title"
        elif not current or current.keys() != previous.keys():
            direction = None
        self.traffic[key] = current, direction, colour
        return {"rx": glyphs.left, "tx": glyphs.right}.get(direction, glyphs.dot)

    def cursor_position(self, screen):
        _, positions, _, width, visible = self.geometry(screen)
        column, row = positions.get(self.selected, (0, 0))
        return row + 5, (column % visible) * width + 2

    def draw(self, screen, embedded=False, focused=True, header_screen=None):
        sup = self.app.sup
        header = header_screen or screen
        if not embedded:
            self.app.title_bar(screen, sup.config.name)
            self.app.page_bar(screen)
        self.buttons.draw(header, 2, 2, focused and self.focus == "cmds", self.app.command_enabled)
        state, health, colour = simulation_status(sup)
        header.put(3, 2, "state: %s   health: %s   control: %d/%d" % (
            state, health, sum(communicating(sup, key) for key in sup.procs), len(sup.procs)),
            screen.attr(colour))
        started = sup.master_info.get("startedAt")
        elapsed = fmt_duration(max(0, time.time() - started) if started else None)
        header.put(4, 2, "elapsed %s   name: operations   %s: control   %s/%s: buses   spinner: log" %
                   (elapsed, screen.g.up, screen.g.left, screen.g.right),
                   screen.attr("dim"))
        if any(proc.log_seq is None for proc in sup.procs.values()):
            header.fill(4)
            header.put(4, 2, "Log counts unavailable: restart the headless master, not just the LRUs.",
                       screen.attr("warn"))
        if screen.h < 9 or screen.w < 28:
            screen.put(5, 0, "Enlarge terminal", screen.attr("warn"))
            return
        columns, positions, name_width, width, visible = self.geometry(screen)
        if not positions:
            screen.put(5, 2, "No LRUs configured", screen.attr("dim"))
        current = positions.get(self.selected, (0, 0))[0]
        first = current // visible * visible
        for column in range(first, min(first + visible, len(columns))):
            left = (column - first) * width + 2
            for row, (kind, key) in enumerate(columns[column]):
                top = row + 5
                if key is None:
                    screen.put(top, left, kind.upper(), screen.attr("hdr"), width - 4)
                    continue
                proc = sup.procs.get(key)
                if proc is None:
                    continue
                chosen = focused and key == self.selected and self.focus == "lrus"
                screen.put(top, left, screen.clip(key, name_width).ljust(name_width),
                           screen.attr(state_colour(proc), reverse=chosen and self.field == 0), name_width)
                glyph = communication_glyph(sup, key, screen.g)
                screen.put(top, left + name_width + 1, glyph,
                           screen.attr("gray" if glyph == screen.g.dot else "up" if communicating(sup, key) else "down",
                                       reverse=chosen and self.field == 1))
                for field, glyph in ((2, self.bus_glyph(key, screen.g)), (3, self.spinner(proc))):
                    colour = self.traffic[key][2] if field == 2 else "title"
                    if glyph == "?":
                        colour = "warn"
                    screen.put(top, left + name_width + field * 2 - 1, glyph,
                               screen.attr("gray" if glyph == screen.g.dot else colour,
                                           reverse=chosen and self.field == field))
        if not embedded:
            self.app.message_line(screen, screen.h - 2)
            self.app.hint_line(screen, screen.h - 1, self.HINT)

    HINT = "arrows select  tab commands/LRUs  enter open  pgup/pgdn columns  F6 view  q quit"

    def handle(self, key, screen=None):
        if key in (ord("q"), ESCAPE):
            self.app.quit()
            return
        if key == 9:
            self.focus = "cmds" if self.focus == "lrus" else "lrus"
            return
        if self.focus == "cmds":
            if key in (curses.KEY_LEFT, curses.KEY_RIGHT):
                self.buttons.move(-1 if key == curses.KEY_LEFT else 1)
            elif key == curses.KEY_DOWN:
                self.focus = "lrus"
            elif key in ENTER and self.app.command_enabled(self.buttons.current):
                run_command(self.app, self.buttons.current)
            return
        columns, positions, _, _, visible = self.geometry(screen or self.app.screen)
        if self.selected is None:
            return
        column, row = positions[self.selected]
        if key in ENTER:
            view = (OperationsView, None, BusView, LogView)[self.field]
            if view:
                self.app.open_view(view(self.app, self.selected))
        elif key in (curses.KEY_UP, curses.KEY_DOWN):
            step = -1 if key == curses.KEY_UP else 1
            choices = [(place[1], name) for name, place in positions.items()
                       if place[0] == column and (place[1] - row) * step > 0]
            if choices:
                self.selected = min(choices, key=lambda item: abs(item[0] - row))[1]
            elif key == curses.KEY_UP:
                self.focus = "cmds"
        elif key in (curses.KEY_LEFT, curses.KEY_RIGHT, curses.KEY_PPAGE, curses.KEY_NPAGE):
            step = -1 if key in (curses.KEY_LEFT, curses.KEY_PPAGE) else 1
            if key in (curses.KEY_PPAGE, curses.KEY_NPAGE):
                column += step * visible
            else:
                self.field += step
                if 0 <= self.field <= 3:
                    return
                self.field %= 4
                column += step
            column = max(0, min(column, len(columns) - 1))
            choices = [(abs(place[1] - row), name) for name, place in positions.items() if place[0] == column]
            if choices:
                self.selected = min(choices)[1]


class OperationsView:
    labels = ("START", "STOP", "RESTART", "KILL", "CANCEL")

    def __init__(self, app, key):
        self.app, self.key = app, key
        self.index = next(index for index, label in enumerate(self.labels) if self.enabled(label))

    def enabled(self, operation):
        proc = self.app.sup.procs.get(self.key)
        if proc is None:
            return operation == "CANCEL"
        if operation == "START":
            return proc.state not in LIVE
        if operation in ("STOP", "KILL"):
            return proc.state in LIVE
        return True

    def draw(self, screen):
        parent = self.app.return_views[-1]
        parent.draw(screen)
        width = min(32, screen.w)
        row, column = parent.cursor_position(screen)
        left = max(0, min(column, screen.w - width))
        top = row + 1 if row + 10 <= screen.h else max(0, row - 9)
        for row in range(9):
            text = screen.g.hline * width if row in (0, 8) else screen.g.vline + " " * max(0, width - 2) + screen.g.vline
            screen.put(top + row, left, text, screen.attr("popup"), width)
        screen.put(top + 1, left + 2, screen.clip(self.key, width - 4), screen.attr("popup_title"))
        for index, label in enumerate(self.labels):
            screen.put(top + 3 + index, left + 2, label.ljust(max(0, width - 4)),
                       screen.attr("popup_dim" if not self.enabled(label) else
                                   "popup_selected" if index == self.index else "popup",
                                   underline=index == self.index), width - 4)

    def handle(self, key):
        if key in (ESCAPE, ord("q")):
            self.app.close_view()
        elif key in (curses.KEY_UP, curses.KEY_DOWN, 9):
            self.index = (self.index + (-1 if key == curses.KEY_UP else 1)) % len(self.labels)
        elif key in ENTER:
            operation = self.labels[self.index]
            if not self.enabled(operation):
                return
            if operation == "KILL" and not self.app.confirm("SIGKILL %s?" % self.key):
                return
            if operation != "CANCEL":
                getattr(self.app.sup, operation.lower())(self.key)
            self.app.close_view()


class LogView:
    def __init__(self, app, key):
        self.app, self.key = app, key
        self.offset = 0

    def draw(self, screen):
        self.app.title_bar(screen, "%s / %s / log" % (self.app.sup.config.name, self.key))
        proc = self.app.sup.procs.get(self.key)
        lines = proc.log_lines() if proc else []
        height = max(1, screen.h - 4)
        self.offset = min(self.offset, max(0, len(lines) - height))
        end = len(lines) - self.offset
        for row, line in enumerate(lines[max(0, end - height):end], start=2):
            text = time.strftime("%H:%M:%S", time.localtime(line.when)) + " " + line.text
            screen.put(row, 1, text, screen.attr("value"), screen.w - 2)
        self.app.hint_line(screen, screen.h - 1, "up/down scroll  end follow  esc return")

    def handle(self, key):
        if key in (ESCAPE, ord("q")):
            self.app.close_view()
        elif key in (curses.KEY_UP, curses.KEY_PPAGE):
            self.offset += 1 if key == curses.KEY_UP else max(1, self.app.screen.h - 4)
        elif key in (curses.KEY_DOWN, curses.KEY_NPAGE):
            self.offset = max(0, self.offset - (1 if key == curses.KEY_DOWN else max(1, self.app.screen.h - 4)))
        elif key == curses.KEY_END:
            self.offset = 0

    def close(self):
        proc = self.app.sup.procs.get(self.key)
        if proc:
            proc.watch_logs = False


class BusView:
    def __init__(self, app, key):
        self.app, self.key = app, key
        self.offset = 0
        self.feeds = {}

    def lines(self):
        active = set()
        for component in components(self.app.sup, self.key, last_known=True):
            for bus in component.get("buses", []):
                if bus["name"] == "_simControl":
                    continue
                identity = (component["instance"], bus["name"])
                active.add(identity)
                feed = self.feeds.setdefault(identity, {"last": 0, "samples": deque(maxlen=20)})
                feed["bus"] = bus
                traffic = bus.get("traffic") or {}
                if traffic.get("seq", 0) < feed["last"]:
                    feed["last"] = 0
                    feed["samples"].clear()
                for sample in traffic.get("recent", []):
                    if sample["seq"] > feed["last"]:
                        feed["samples"].append(dict(sample))
                        feed["last"] = sample["seq"]
        self.feeds = {identity: feed for identity, feed in self.feeds.items() if identity in active}
        lines = []
        for (instance, name), feed in sorted(self.feeds.items(), key=lambda item: (item[0][1], item[0][0])):
            bus = feed["bus"]
            traffic = bus.get("traffic")
            counters = "RX %d TX %d" % (traffic["rx"], traffic["tx"]) if traffic else "telemetry unavailable"
            colour = "bus_global" if name in GLOBAL_BUSES else "hdr"
            lines.append(("%s  %s:%s  %s" % (name, bus.get("transport", "?"), bus.get("port", "?"), counters), colour))
            for sample in list(feed["samples"])[-4:]:
                stamp = time.strftime("%H:%M:%S", time.localtime(sample["time"]))
                lines.append(("  %s %s %dB  %s%s" % (stamp, sample["direction"].upper(), sample["length"],
                              sample["hex"], " ..." if sample["length"] > 24 else ""), "value"))
            if not feed["samples"]:
                lines.append(("  waiting for packets" if traffic else "  no packet samples", "dim"))
            lines.append(("", "dim"))
        return lines

    def draw(self, screen):
        self.app.title_bar(screen, "%s / %s / buses" % (self.app.sup.config.name, self.key))
        live = communicating(self.app.sup, self.key)
        screen.put(2, 1, "control %s; sampled packet prefixes, local RX/TX" % ("up" if live else "down; last received data"),
                   screen.attr("up" if live else "warn"))
        lines = self.lines() or [("No buses advertised for this process", "dim")]
        height = max(1, screen.h - 5)
        self.offset = min(self.offset, max(0, len(lines) - height))
        for row, (text, colour) in enumerate(lines[self.offset:self.offset + height], start=4):
            screen.put(row, 1, text, screen.attr(colour), screen.w - 2)
        self.app.hint_line(screen, screen.h - 1, "up/down scroll  pgup/pgdn page  esc return")

    def handle(self, key):
        if key in (ESCAPE, ord("q")):
            self.app.close_view()
        elif key in (curses.KEY_UP, curses.KEY_PPAGE):
            self.offset = max(0, self.offset - (1 if key == curses.KEY_UP else max(1, self.app.screen.h - 5)))
        elif key in (curses.KEY_DOWN, curses.KEY_NPAGE):
            self.offset += 1 if key == curses.KEY_DOWN else max(1, self.app.screen.h - 5)
