"""The terminal interface: a table of LRUs, and a page for each one."""

from __future__ import annotations

import curses
import os
import time
from typing import Optional

from .config import DEFAULT_BASE_PORT
from .process import LIVE
from .screen import Screen
from .supervisor import Supervisor
from .views import DetailView, MainView

REDRAW_MS = 150
SPINNER = "|/-\\"


class App:
    def __init__(self, sup: Supervisor, ascii_only: bool = False,
                 base_port: int = DEFAULT_BASE_PORT):
        self.sup = sup
        self.ascii = ascii_only
        self.base_port = base_port
        self.screen: Optional[Screen] = None
        self.view = None
        self.main = None
        self._detail: Optional[DetailView] = None
        self._done = False

    # ------------------------------------------------------------- running

    def run(self) -> None:
        # Without this a lone Escape waits a second before curses gives it up.
        os.environ.setdefault("ESCDELAY", "25")
        curses.wrapper(self._main)

    def _main(self, stdscr) -> None:
        curses.curs_set(0)
        stdscr.keypad(True)
        stdscr.timeout(REDRAW_MS)
        self.screen = Screen(stdscr, self.ascii)
        self.main = MainView(self)
        self.view = self.main
        while not self._done:
            self.draw()
            try:
                ch = stdscr.getch()
            except KeyboardInterrupt:
                self.quit()
                continue
            if ch in (-1, curses.KEY_RESIZE):
                continue
            self.view.handle(ch)

    def draw(self) -> None:
        screen = self.screen
        screen.win.erase()
        self.view.draw(screen)
        screen.win.noutrefresh()
        curses.doupdate()

    # -------------------------------------------------------------- chrome

    def title_bar(self, screen: Screen, text: str) -> None:
        bar = screen.attr("plain", reverse=True, bold=True)
        screen.fill(0, bar)
        screen.put(0, 1, " SIM ", screen.attr("title", reverse=True, bold=True))
        right = time.strftime("%H:%M:%S")
        if self.base_port != DEFAULT_BASE_PORT:
            right = "base:%d  %s" % (self.base_port, right)
        screen.put(0, 7, screen.clip(text, screen.w - len(right) - 10), bar)
        screen.put(0, max(0, screen.w - len(right) - 2), right, bar)

    def message_line(self, screen: Screen, y: int) -> None:
        if self.sup.busy():
            spin = SPINNER[int(time.time() * 6) % len(SPINNER)]
            screen.put(y, 2, "%s %s" % (spin, self.sup.activity), screen.attr("warn"))
        elif self.sup.message:
            screen.put(y, 2, screen.clip(self.sup.message, screen.w - 4),
                       screen.attr("note"))

    def hint_line(self, screen: Screen, y: int, text: str) -> None:
        screen.put(y, 2, screen.clip(text, screen.w - 4), screen.attr("dim"))

    def confirm(self, prompt: str) -> bool:
        """A yes/no on the bottom line.  Anything but y is no."""
        screen = self.screen
        y = screen.h - 1
        while True:
            self.draw()
            screen.fill(y, screen.attr("warn", reverse=True))
            screen.put(y, 2, "%s   y / n " % prompt,
                       screen.attr("warn", reverse=True, bold=True))
            screen.win.noutrefresh()
            curses.doupdate()
            ch = screen.win.getch()
            if ch == -1:
                continue
            if ch in (ord("y"), ord("Y")):
                return True
            if ch == curses.KEY_RESIZE:
                y = screen.h - 1
                continue
            return False

    # --------------------------------------------------------------- views

    def open_detail(self, key: str) -> None:
        if self._detail is None or self._detail.key != key:
            self._detail = DetailView(self, key)
        self.view = self._detail

    def close_detail(self) -> None:
        self.view = self.main

    def command_enabled(self, label: str) -> bool:
        live = any(p.state in LIVE for p in self.sup.procs.values())
        if label == "AUTOSTART":
            return not self.sup.busy()
        if label == "TERMINATE":
            return live
        return True

    def quit(self) -> None:
        live = [k for k, p in self.sup.procs.items() if p.state in LIVE]
        if live and not self.confirm("quit and stop %d running LRU%s?"
                                     % (len(live), "" if len(live) == 1 else "s")):
            return
        self._done = True
