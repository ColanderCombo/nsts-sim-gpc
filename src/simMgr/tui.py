"""sim mgr terminal interface"""

from __future__ import annotations

import curses
import os
import time
from typing import Dict, List, Optional

from .config import DEFAULT_BASE_PORT, Lru
from .gpclink import GpcLink
from .gpcview import GpcView
from .idplink import IdpLinks
from .panel.catalog import CatalogError, Panel
from .panel.catalog import load as load_panels
from .panel.link import PanelLink
from .panel.view import PanelView
from .process import LIVE
from .screen import Screen
from .supervisor import Supervisor
from .views import DetailView, MainView
from .summary import OperationsView, SummaryView
from .overview import Overview
from .simview import SimulationView

REDRAW_MS = 150
SPINNER = "|/-\\"


class App:
    def __init__(self, sup: Supervisor, ascii_only: bool = False,
                 base_port: int = DEFAULT_BASE_PORT, hardware_views: bool = True,
                 combined_summary: bool = True):
        self.sup = sup
        self.ascii = ascii_only
        self.base_port = base_port
        self.hardware_views = hardware_views
        self.combined_summary = combined_summary
        self.screen: Optional[Screen] = None
        self.view = None
        self.main = None
        self.pages = []                  # (name, view), in tab order
        self.return_views = []
        self.page = 0
        self.links: Dict[str, GpcLink] = {}
        self._idp_links: Optional[IdpLinks] = None
        self._panel_link: Optional[PanelLink] = None
        self._detail: Optional[DetailView] = None
        self._done = False

    # ------------------------------------------------------------- running

    def run(self) -> None:
        # Without this a lone Escape waits a second before curses gives it up.
        os.environ.setdefault("ESCDELAY", "25")
        try:
            curses.wrapper(self._main)
        finally:
            while self.return_views:
                self.close_view()
            if isinstance(self.main, Overview):
                self.main.close()
            for link in self.links.values():
                link.close()
            if self._idp_links is not None:
                self._idp_links.close()
            if self._panel_link is not None:
                self._panel_link.close()

    def _main(self, stdscr) -> None:
        curses.curs_set(0)
        stdscr.keypad(True)
        stdscr.timeout(REDRAW_MS)
        self.screen = Screen(stdscr, self.ascii)
        self.main = Overview(self) if self.hardware_views and self.combined_summary else SummaryView(self)
        self.pages = [("SUMMARY", self.main), ("LRU", MainView(self)), ("SIMULATION", SimulationView(self))]
        if self.hardware_views and not self.combined_summary:
            self.pages.append(("GPC STATUS", GpcView(self)))
        panels = self.panels() if self.hardware_views else []
        if panels:
            self._panel_link = PanelLink(self.base_port, panels)
            self.pages.append(("PANEL", PanelView(self, self._panel_link, panels,
                                                  title=self.sup.config.name)))
        if isinstance(self.main, Overview):
            self.main.add_pages(self.pages[1:])
            self.pages = [("SUMMARY", self.main)]
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
            if ch == curses.KEY_F6:
                if isinstance(self.main, Overview):
                    while self.return_views:
                        self.close_view()
                    self.main.handle(ch)
                else:
                    self.next_page()
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

    def page_bar(self, screen: Screen) -> None:
        """Line 1: the top-level pages, the current one marked."""
        x = 2
        for i, (name, _) in enumerate(self.pages):
            chosen = i == self.page
            x = screen.put(1, x, " %s " % name,
                           screen.attr("title" if chosen else "dim", reverse=chosen,
                                       bold=chosen))
            x += 2
        if not isinstance(self.main, Overview):
            screen.put(1, x, "F6 next view", screen.attr("dim"))

    def message_line(self, screen: Screen, y: int) -> None:
        if self.sup.busy():
            spin = SPINNER[int(time.time() * 6) % len(SPINNER)]
            screen.put(y, 2, "%s %s" % (spin, self.sup.activity), screen.attr("warn"))
        elif self.sup.message:
            screen.put(y, 2, screen.clip(self.sup.message, screen.w - 4),
                       screen.attr("note"))

    def hint_line(self, screen: Screen, y: int, text: str) -> None:
        screen.put(y, 2, screen.clip(text, screen.w - 4), screen.attr("dim"))

    def text_input(self, prompt):
        """Editable text on the status line; Escape cancels."""
        value = ""
        while True:
            self.draw()
            screen = self.screen
            screen.fill(screen.h - 1)
            screen.put(screen.h - 1, 2, screen.clip(prompt + ": " + value + "_", screen.w - 4), screen.attr("warn"))
            screen.win.refresh()
            key = screen.win.getch()
            if key == 27: return None
            if key in (10, 13, curses.KEY_ENTER): return value.strip()
            if key in (curses.KEY_BACKSPACE, 127, 8): value = value[:-1]
            elif 32 <= key < 127 and len(value) < 80: value += chr(key)

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
        self.open_view(self._detail)

    def close_detail(self) -> None:
        self.close_view()

    def open_view(self, view) -> None:
        if isinstance(self.main, Overview) and not isinstance(view, OperationsView):
            self.main.open_detail(view)
            return
        self.return_views.append(self.view)
        self.view = view

    def close_view(self) -> None:
        close = getattr(self.view, "close", None)
        if close:
            close()
        self.view = self.return_views.pop() if self.return_views else self.main

    def next_page(self) -> None:
        while self.return_views:
            self.close_view()
        self.page = (self.page + 1) % len(self.pages)
        self.view = self.pages[self.page][1]

    def link(self, lru: Lru) -> GpcLink:
        """The debug session of a GPC LRU, opened the first time it is asked for."""
        link = self.links.get(lru.key)
        if link is None or link.port != lru.debug_port:
            if link is not None:
                link.close()
            link = self.links[lru.key] = GpcLink("127.0.0.1", int(lru.debug_port or 0))
        return link

    def panels(self) -> List[Panel]:
        """The panels config/panels describes; none, and there is no page."""
        try:
            return list(load_panels().values())
        except CatalogError as exc:
            self.sup.message = "panels: %s" % exc
            return []

    @property
    def idp_links(self) -> IdpLinks:
        """The IDPs' discrete channels, joined the first time they are asked for."""
        if self._idp_links is None:
            self._idp_links = IdpLinks(self.base_port)
        return self._idp_links

    def command_enabled(self, label: str) -> bool:
        live = any(p.state in LIVE for p in self.sup.procs.values())
        if label == "AUTOSTART":
            return not self.sup.busy()
        if label == "TERMINATE":
            return live
        return True

    def quit(self) -> None:
        if getattr(self.sup, "attached", False):
            self._done = True
            return
        live = [k for k, p in self.sup.procs.items() if p.state in LIVE]
        if live and not self.confirm("quit and stop %d running LRU%s?"
                                     % (len(live), "" if len(live) == 1 else "s")):
            return
        self._done = True
