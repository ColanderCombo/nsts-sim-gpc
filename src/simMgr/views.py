"""The two pages: the LRU table, and one LRU in detail."""

from __future__ import annotations

import curses
import time
from typing import List, Optional, Tuple

from .process import LIVE, ManagedProcess, State
from .screen import Buttons, Screen, fmt_duration

ENTER = (curses.KEY_ENTER, 10, 13)
ESCAPE = 27
BACKSPACE = (curses.KEY_BACKSPACE, 127, 8)

#: Four single-character status fields follow the LRU name.  The first is
#: the process; the other three are laid out and left blank.
STATUS_FIELDS = 4


def status_cells(proc: ManagedProcess) -> List[Tuple[str, str]]:
    """(glyph name, colour) for each of the four status fields.

    The glyph name is "up", "down" or "" -- Screen.g turns it into the
    character the terminal can draw.
    """
    state = proc.state
    if state in (State.STOPPED, State.EXITED):
        first = ("", "plain")
    elif state is State.FAILED:
        first = ("down", "down")
    elif state is State.STOPPING:
        first = ("down", "dim")
    elif state in (State.BUILDING, State.STARTING):
        first = ("up", "warn")
    elif proc.health == "up":
        first = ("up", "up")
    elif proc.health == "down":
        first = ("down", "down")
    else:
        first = ("up", "warn")
    return [first] + [("", "plain")] * (STATUS_FIELDS - 1)


def state_colour(proc: ManagedProcess) -> str:
    if proc.state is State.FAILED:
        return "down"
    if proc.state is State.RUNNING:
        return "up" if proc.health == "up" else ("down" if proc.health == "down" else "warn")
    if proc.state in (State.STARTING, State.BUILDING, State.STOPPING):
        return "warn"
    return "dim"


class MainView:
    """The table of LRUs, with the global commands beneath it."""

    COMMANDS = ("AUTOSTART", "TERMINATE", "RESTART", "RELOAD", "QUIT")

    def __init__(self, app):
        self.app = app
        self.row = 0
        self.top = 0
        self.focus = "lrus"
        self.buttons = Buttons(self.COMMANDS)

    # ------------------------------------------------------------- helpers

    @property
    def keys(self) -> List[str]:
        return self.app.sup.order

    @property
    def selected(self) -> Optional[str]:
        keys = self.keys
        if not keys:
            return None
        self.row = max(0, min(self.row, len(keys) - 1))
        return keys[self.row]

    # -------------------------------------------------------------- drawing

    def draw(self, screen: Screen) -> None:
        sup = self.app.sup
        keys = self.keys
        g = screen.g

        self.app.title_bar(screen, "%s  %s %s" % (
            sup.config.name, g.dot, sup.config.description or sup.config.run_file.name))

        name_w = max([len(k) for k in keys] + [8]) + 1
        name_w = min(name_w, 20)
        x_name = 2
        x_stat = x_name + name_w + 1
        x_state = x_stat + STATUS_FIELDS * 2 + 1
        x_pid = x_state + 10
        x_up = x_pid + 8
        x_rst = x_up + 9
        x_cmd = x_rst + 4

        head = screen.attr("hdr", underline=True)
        y = 2
        screen.fill(y, screen.attr("hdr", underline=True))
        screen.put(y, x_name, "LRU", head)
        screen.put(y, x_stat, "STAT", head)
        screen.put(y, x_state, "STATE", head)
        screen.put(y, x_pid, "PID", head)
        screen.put(y, x_up, "UPTIME", head)
        screen.put(y, x_rst, "RST", head)
        screen.put(y, x_cmd, "COMMAND", head)

        # The footer is four lines: a rule, the commands, a rule, a message.
        footer = 5
        first = 3
        rows = max(1, screen.h - first - footer)
        if self.row < self.top:
            self.top = self.row
        if self.row >= self.top + rows:
            self.top = self.row - rows + 1
        self.top = max(0, min(self.top, max(0, len(keys) - rows)))

        for i in range(rows):
            index = self.top + i
            y = first + i
            if index >= len(keys):
                break
            key = keys[index]
            proc = sup.procs[key]
            chosen = index == self.row
            marked = chosen and self.focus == "lrus"

            if marked:
                screen.fill(y, screen.attr("plain", reverse=True))
            name_attr = screen.attr("plain", reverse=marked, bold=chosen)
            screen.put(y, 0, g.sel if marked else " ", name_attr)
            label = key + ("*" if key in sup.stale else "")
            screen.put(y, x_name, screen.clip(label, name_w), name_attr, name_w)

            for f, (glyph, colour) in enumerate(status_cells(proc)):
                char = {"up": g.up, "down": g.down}.get(glyph, " ")
                screen.put(y, x_stat + f * 2, char,
                           screen.attr(colour, reverse=marked))

            dim = screen.attr("dim", reverse=marked)
            screen.put(y, x_state, proc.state.value.upper(),
                       screen.attr(state_colour(proc), reverse=marked), 9)
            screen.put(y, x_pid, str(proc.pid) if proc.pid else "--", dim, 7)
            screen.put(y, x_up, fmt_duration(proc.uptime), dim, 8)
            screen.put(y, x_rst, str(proc.restarts) if proc.restarts else "", dim, 3)
            screen.put(y, x_cmd,
                       screen.clip(proc.lru.command_line, screen.w - x_cmd - 1),
                       screen.attr("plain" if marked else "dim", reverse=marked))

        y = screen.h - footer
        screen.rule(y, right="%d LRU" % len(keys))
        self.buttons.draw(screen, y + 1, 2, self.focus == "cmds",
                          enabled=self.app.command_enabled)
        screen.rule(y + 2)
        self.app.message_line(screen, y + 3)
        self.app.hint_line(screen, y + 4,
                           "arrows select   enter open/run   s start   x stop   "
                           "r restart   tab commands   q quit")

    # -------------------------------------------------------------- keys

    def handle(self, ch: int) -> None:
        app, sup = self.app, self.app.sup
        keys = self.keys

        if ch in (curses.KEY_DOWN, ord("j")):
            if self.focus == "lrus" and self.row < len(keys) - 1:
                self.row += 1
            else:
                self.focus = "cmds"
        elif ch in (curses.KEY_UP, ord("k")):
            if self.focus == "cmds":
                self.focus = "lrus"
            elif self.row > 0:
                self.row -= 1
        elif ch == curses.KEY_LEFT:
            if self.focus == "cmds":
                self.buttons.move(-1)
        elif ch == curses.KEY_RIGHT:
            if self.focus == "cmds":
                self.buttons.move(1)
            else:
                self.focus = "cmds"
        elif ch == ord("\t"):
            self.focus = "cmds" if self.focus == "lrus" else "lrus"
        elif ch == curses.KEY_HOME:
            self.row, self.focus = 0, "lrus"
        elif ch == curses.KEY_END:
            self.row, self.focus = max(0, len(keys) - 1), "lrus"
        elif ch in ENTER:
            if self.focus == "cmds":
                self.run(self.buttons.current)
            elif self.selected:
                app.open_detail(self.selected)
        elif ch == ord("s") and self.selected:
            sup.start(self.selected)
        elif ch == ord("x") and self.selected:
            sup.stop(self.selected)
        elif ch == ord("r") and self.selected:
            sup.restart(self.selected)
        elif ch == ord("K") and self.selected:
            if app.confirm("SIGKILL %s?" % self.selected):
                sup.kill(self.selected)
        elif ch == ord("a"):
            sup.autostart()
        elif ch == ord("t"):
            self.run("TERMINATE")
        elif ch == ord("q"):
            self.run("QUIT")

    def run(self, command: str) -> None:
        app, sup = self.app, self.app.sup
        if command == "AUTOSTART":
            sup.autostart()
        elif command == "TERMINATE":
            if app.confirm("stop every LRU in this configuration?"):
                sup.terminate()
        elif command == "RESTART":
            if app.confirm("stop everything and start it again?"):
                sup.restart_all()
        elif command == "RELOAD":
            try:
                sup.reload()
            except Exception as exc:
                sup.say("reload failed: %s" % exc)
        elif command == "QUIT":
            app.quit()


class DetailView:
    """One LRU: what it is and what it is doing, over its log."""

    COMMANDS = ("START", "STOP", "RESTART", "KILL", "CLEAR", "FOLLOW", "BACK")

    def __init__(self, app, key: str):
        self.app = app
        self.key = key
        self.buttons = Buttons(self.COMMANDS)
        self.offset = 0                 # lines scrolled back from the tail
        self.follow = True
        self.stamps = True

    @property
    def proc(self) -> ManagedProcess:
        return self.app.sup.procs[self.key]

    # -------------------------------------------------------------- drawing

    def draw(self, screen: Screen) -> None:
        proc = self.proc
        lru = proc.lru
        g = screen.g

        self.app.title_bar(screen, "%s %s %s" % (
            self.app.sup.config.name, g.arrow, self.key))

        label = screen.attr("hdr")
        value = screen.attr("value")
        dim = screen.attr("dim")
        right = screen.w // 2 + 6

        y = 2
        screen.put(y, 2, lru.name, screen.attr("title"))
        if lru.description:
            screen.put(y, 2 + len(lru.name) + 2,
                       screen.clip(lru.description, right - len(lru.name) - 6), dim)
        self._field(screen, y, right, "state", self._state_text(proc),
                    screen.attr(state_colour(proc)))

        y += 1
        screen.put(y, 2, "lru", label, 8)
        screen.put(y, 10, "%s  %s" % (lru.lru, lru.kind), value)
        self._field(screen, y, right, "pid", str(proc.pid) if proc.pid else "--", value)

        y += 1
        screen.put(y, 2, "cwd", label, 8)
        screen.put(y, 10, screen.clip(str(lru.cwd), right - 12), value)
        self._field(screen, y, right, "uptime", fmt_duration(proc.uptime), value)

        y += 1
        screen.put(y, 2, "command", label, 8)
        screen.put(y, 10, screen.clip(lru.command_line, screen.w - 12), value)

        y += 1
        screen.put(y, 2, "health", label, 8)
        note = lru.health.describe()
        if proc.health_note:
            note += "  %s %s" % (g.dot, proc.health_note)
        screen.put(y, 10, screen.clip(note, right - 12), value)
        self._field(screen, y, right, "restarts",
                    "%d of %d" % (proc.restarts, lru.max_restarts), value)

        y += 1
        params = "  ".join("%s=%s" % (k, v) for k, v in sorted(lru.params.items()))
        if params:
            screen.put(y, 2, "params", label, 8)
            screen.put(y, 10, screen.clip(params, right - 12), value)
        exit_text = self._exit_text(proc)
        if exit_text:
            self._field(screen, y, right, "exit", exit_text,
                        screen.attr("down" if proc.state is State.FAILED else "dim"))

        y += 1
        policy = "restart %s   stop SIG%s in %.0fs   ready %.0fs" % (
            lru.restart, lru.stop_signal, lru.stop_timeout, lru.ready_timeout)
        if lru.build:
            policy += "   build %s" % ("done" if proc.built else "pending")
        screen.put(y, 10, screen.clip(policy, screen.w - 12), dim)

        y += 2
        self.buttons.draw(screen, y, 2, True, enabled=self._enabled)

        # Everything below the rule is log; it is what the page is for.
        y += 1
        total = proc.log_count()
        first = y + 1
        rows = max(1, screen.h - first - 2)
        self.offset = max(0, min(self.offset, max(0, total - rows)))
        if self.follow:
            self.offset = 0
        marker = "following" if self.follow else "%d back" % self.offset
        screen.rule(y, "log", right="%s  %s  %d lines" % (
            "stamps" if self.stamps else "", marker, total))

        lines = proc.log_lines()
        start = max(0, total - rows - self.offset)
        for i, line in enumerate(lines[start:start + rows]):
            row = first + i
            x = 1
            if self.stamps:
                x = screen.put(row, x, time.strftime(
                    "%H:%M:%S ", time.localtime(line.when)), dim)
            attr = screen.attr("note") if line.stream == "sim" else screen.attr("plain")
            screen.put(row, x, screen.clip(line.text, screen.w - x - 1), attr)

        self.app.message_line(screen, screen.h - 2)
        self.app.hint_line(screen, screen.h - 1,
                           "left/right command   enter run   up/down scroll log   "
                           "f follow   t stamps   esc back")

    def _field(self, screen: Screen, y: int, x: int, name: str,
               text: str, attr: int) -> None:
        x = screen.put(y, x, "%8s  " % name, screen.attr("hdr"))
        screen.put(y, x, text, attr)

    def _state_text(self, proc: ManagedProcess) -> str:
        text = proc.state.value.upper()
        if proc.state is State.RUNNING:
            text += " (%s)" % {"up": "healthy", "down": "unhealthy"}.get(
                proc.health, "unknown")
        return text

    def _exit_text(self, proc: ManagedProcess) -> str:
        if proc.exit_signal is not None:
            try:
                import signal
                return "signal %s" % signal.Signals(proc.exit_signal).name
            except ValueError:
                return "signal %d" % proc.exit_signal
        if proc.exit_code is not None:
            return "status %d" % proc.exit_code
        return ""

    def _enabled(self, label: str) -> bool:
        live = self.proc.state in LIVE
        if label == "START":
            return not live
        if label in ("STOP", "KILL"):
            return live
        return True

    # ----------------------------------------------------------------- keys

    def handle(self, ch: int) -> None:
        proc = self.proc
        rows = max(1, self.app.screen.h - 14)

        if ch == curses.KEY_LEFT:
            self.buttons.move(-1)
        elif ch == curses.KEY_RIGHT:
            self.buttons.move(1)
        elif ch in ENTER:
            self.run(self.buttons.current)
        elif ch in (curses.KEY_UP, ord("k")):
            self.follow = False
            self.offset += 1
        elif ch in (curses.KEY_DOWN, ord("j")):
            self.offset = max(0, self.offset - 1)
            if self.offset == 0:
                self.follow = True
        elif ch == curses.KEY_PPAGE:
            self.follow = False
            self.offset += rows
        elif ch == curses.KEY_NPAGE:
            self.offset = max(0, self.offset - rows)
        elif ch == curses.KEY_HOME:
            self.follow = False
            self.offset = max(0, proc.log_count() - rows)
        elif ch == curses.KEY_END:
            self.offset, self.follow = 0, True
        elif ch == ord("f"):
            self.follow = not self.follow
            if self.follow:
                self.offset = 0
        elif ch == ord("t"):
            self.stamps = not self.stamps
        elif ch == ord("s"):
            self.run("START")
        elif ch == ord("x"):
            self.run("STOP")
        elif ch == ord("r"):
            self.run("RESTART")
        elif ch == ord("K"):
            self.run("KILL")
        elif ch == ord("c"):
            self.run("CLEAR")
        elif ch in (ESCAPE, ord("q")) or ch in BACKSPACE:
            self.app.close_detail()

    def run(self, command: str) -> None:
        app, sup = self.app, self.app.sup
        if command == "START":
            sup.start(self.key)
        elif command == "STOP":
            sup.stop(self.key)
        elif command == "RESTART":
            sup.restart(self.key)
        elif command == "KILL":
            if app.confirm("SIGKILL %s?" % self.key):
                sup.kill(self.key)
        elif command == "CLEAR":
            self.proc.clear_log()
            self.offset = 0
        elif command == "FOLLOW":
            self.follow = not self.follow
            if self.follow:
                self.offset = 0
        elif command == "BACK":
            app.close_detail()
