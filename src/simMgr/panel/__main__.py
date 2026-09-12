"""The panel frontend as a command: `python3 -m simMgr.panel`.

    python3 -m simMgr.panel                       every panel in config/panels
    python3 -m simMgr.panel F6 O6                 two of them
    python3 -m simMgr.panel --list                what there is
    python3 -m simMgr.panel --dir /some/panels    somewhere else

The same page the sim manager carries; `--base-port` puts it on another
session's busses.
"""

from __future__ import annotations

import argparse
import curses
import os
import sys
import time
from pathlib import Path
from typing import List, Optional

from ..cli import base_port
from ..config import DEFAULT_BASE_PORT
from ..screen import Screen
from .catalog import CatalogError, Panel, default_dir, load
from .link import PanelLink
from .view import PanelView

REDRAW_MS = 150


class PanelApp:
    """The chrome a view draws into: a title bar, a page bar and a hint line."""

    def __init__(self, panels: List[Panel], base: int, ascii_only: bool = False):
        self.panels = panels
        self.base_port = base
        self.ascii = ascii_only
        self.link: Optional[PanelLink] = None
        self.view: Optional[PanelView] = None
        self._done = False

    def run(self) -> int:
        os.environ.setdefault("ESCDELAY", "25")
        self.link = PanelLink(self.base_port, self.panels)
        try:
            curses.wrapper(self._main)
        finally:
            self.link.close()
        return 0

    def _main(self, stdscr) -> None:
        curses.curs_set(0)
        stdscr.keypad(True)
        stdscr.timeout(REDRAW_MS)
        screen = Screen(stdscr, self.ascii)
        self.view = PanelView(self, self.link, self.panels, title="")
        while not self._done:
            stdscr.erase()
            self.view.draw(screen)
            stdscr.noutrefresh()
            curses.doupdate()
            try:
                ch = stdscr.getch()
            except KeyboardInterrupt:
                self.quit()
                continue
            if ch in (-1, curses.KEY_RESIZE):
                continue
            self.view.handle(ch)


    def title_bar(self, screen: Screen, text: str) -> None:
        bar = screen.attr("plain", reverse=True, bold=True)
        screen.fill(0, bar)
        screen.put(0, 1, " PANEL ", screen.attr("title", reverse=True, bold=True))
        right = time.strftime("%H:%M:%S")
        if self.base_port != DEFAULT_BASE_PORT:
            right = "base:%d  %s" % (self.base_port, right)
        screen.put(0, 9, screen.clip(text, screen.w - len(right) - 12), bar)
        screen.put(0, max(0, screen.w - len(right) - 2), right, bar)

    def page_bar(self, screen: Screen) -> None:
        names = "  ".join(p.name for p in self.panels)
        screen.put(1, 2, screen.clip(names, screen.w - 4), screen.attr("dim"))

    def hint_line(self, screen: Screen, y: int, text: str) -> None:
        screen.put(y, 2, screen.clip(text, screen.w - 4), screen.attr("dim"))

    def quit(self) -> None:
        self._done = True


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        prog="simMgr.panel", description="The crew panels, as text.")
    parser.add_argument("panel", nargs="*", help="the panels to show (default: all of them)")
    parser.add_argument("--dir", type=Path, default=None, metavar="DIR",
                        help="where the panel files are (default: config/panels)")
    parser.add_argument("--list", action="store_true", help="the panels there are")
    parser.add_argument("--ascii", action="store_true",
                        help="draw with ASCII instead of line characters")
    parser.add_argument("--base-port", type=base_port, default=None, metavar="N",
                        help="base of the bus port block "
                             "(default: NSTS_BASE_PORT, or %d)" % DEFAULT_BASE_PORT)
    args = parser.parse_args(argv)

    try:
        catalog = load(args.dir)
    except CatalogError as exc:
        print("simMgr.panel: %s" % exc, file=sys.stderr)
        return 2
    if not catalog:
        print("simMgr.panel: no panels in %s" % (args.dir or default_dir()), file=sys.stderr)
        return 2

    if args.list:
        for name, panel in catalog.items():
            print("%-6s %-44s %d controls" % (name, panel.title, len(panel.controls)))
        return 0

    wanted = args.panel or list(catalog)
    panels = []
    for name in wanted:
        if name not in catalog:
            print("simMgr.panel: there is no panel %s; there are %s"
                  % (name, ", ".join(catalog)), file=sys.stderr)
            return 2
        panels.append(catalog[name])

    base = args.base_port
    if base is None:
        base = int(os.environ.get("NSTS_BASE_PORT") or DEFAULT_BASE_PORT)
    return PanelApp(panels, base, args.ascii).run()


if __name__ == "__main__":
    sys.exit(main())
