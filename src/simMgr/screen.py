"""Drawing primitives for the curses interface."""

from __future__ import annotations

import curses
import locale
import sys
from typing import Optional, Tuple

#: Colour names used by the views, and the (foreground, attributes) each
#: resolves to.  A view names a colour; it never mentions a pair id.
_PALETTE = [
    ("plain", -1, 0),
    ("dim", curses.COLOR_BLACK, curses.A_BOLD),      # the terminal's grey
    ("title", curses.COLOR_CYAN, curses.A_BOLD),
    ("hdr", curses.COLOR_CYAN, 0),
    ("up", curses.COLOR_GREEN, curses.A_BOLD),
    ("down", curses.COLOR_RED, curses.A_BOLD),
    ("warn", curses.COLOR_YELLOW, curses.A_BOLD),
    ("key", curses.COLOR_YELLOW, 0),
    ("note", curses.COLOR_BLUE, curses.A_BOLD),
    ("value", -1, 0),
    ("bus_global", curses.COLOR_CYAN, curses.A_DIM),
]


class Glyphs:
    """Unicode where the terminal can take it, ASCII where it cannot."""

    def __init__(self, ascii_only: bool = False):
        if not ascii_only:
            encoding = (getattr(sys.stdout, "encoding", None)
                        or locale.getpreferredencoding(False) or "")
            ascii_only = "utf" not in encoding.lower()
        self.ascii = ascii_only
        self.up = "^" if ascii_only else "↑"
        self.down = "v" if ascii_only else "↓"
        self.left = "<" if ascii_only else "←"
        self.right = ">" if ascii_only else "→"
        self.sel = ">" if ascii_only else "▸"
        self.hline = "-" if ascii_only else "─"
        self.vline = "|" if ascii_only else "│"
        self.dot = "." if ascii_only else "·"
        self.ell = "~" if ascii_only else "…"
        self.arrow = "->" if ascii_only else "▸"


class Screen:
    def __init__(self, stdscr, ascii_only: bool = False):
        self.win = stdscr
        self.g = Glyphs(ascii_only)
        self._attr = {}
        self._colour = False
        try:
            curses.start_color()
            curses.use_default_colors()
            self._colour = curses.has_colors()
        except curses.error:
            self._colour = False
        for index, (name, fg, extra) in enumerate(_PALETTE, start=1):
            if self._colour and fg >= 0:
                try:
                    curses.init_pair(index, fg, -1)
                    self._attr[name] = curses.color_pair(index) | extra
                    continue
                except curses.error:
                    pass
            self._attr[name] = extra if name != "dim" else curses.A_DIM
        self._attr["dark"] = curses.A_DIM
        self._attr["gray"] = self._attr["dim"]
        if self._colour and curses.COLORS >= 256:
            try:
                curses.init_pair(len(_PALETTE) + 1, 240, -1)
                self._attr["dark"] = curses.color_pair(len(_PALETTE) + 1)
                curses.init_pair(len(_PALETTE) + 2, 244, -1)
                self._attr["gray"] = curses.color_pair(len(_PALETTE) + 2)
            except curses.error:
                pass

        for index, (name, foreground, extra) in enumerate((
                ("popup", curses.COLOR_WHITE, 0),
                ("popup_title", curses.COLOR_CYAN, curses.A_BOLD),
                ("popup_dim", 244 if self._colour and curses.COLORS >= 256 else curses.COLOR_WHITE, curses.A_DIM),
                ("popup_selected", curses.COLOR_YELLOW, curses.A_BOLD)),
                start=len(_PALETTE) + 3):
            self._attr[name] = extra
            if self._colour:
                try:
                    curses.init_pair(index, foreground, curses.COLOR_BLACK)
                    self._attr[name] |= curses.color_pair(index)
                except curses.error:
                    pass

    # ----------------------------------------------------------- geometry

    @property
    def h(self) -> int:
        return self.win.getmaxyx()[0]

    @property
    def w(self) -> int:
        return self.win.getmaxyx()[1]

    def attr(self, name: str = "plain", bold: bool = False,
             reverse: bool = False, underline: bool = False) -> int:
        a = self._attr.get(name, 0)
        if bold:
            a |= curses.A_BOLD
        if reverse:
            a |= curses.A_REVERSE
        if underline:
            a |= curses.A_UNDERLINE
        return a

    # ------------------------------------------------------------ writing

    def put(self, y: int, x: int, text: str, attr: int = 0,
            width: Optional[int] = None) -> int:
        """Write clipped to the window; returns the column after the text."""
        if y < 0 or y >= self.h or x >= self.w:
            return x
        if x < 0:
            text, x = text[-x:], 0
        room = self.w - x
        if width is not None:
            room = min(room, width)
        if room <= 0:
            return x
        text = text[:room]
        # The bottom right cell cannot be written without scrolling.
        if y == self.h - 1 and x + len(text) >= self.w:
            text = text[:self.w - x - 1]
        try:
            self.win.addstr(y, x, text, attr)
        except curses.error:
            pass
        return x + len(text)

    def fill(self, y: int, attr: int = 0, char: str = " ") -> None:
        self.put(y, 0, char * self.w, attr)

    def rule(self, y: int, title: str = "", attr: Optional[int] = None,
             right: str = "", width: Optional[int] = None) -> None:
        attr = self.attr("dim") if attr is None else attr
        width = self.w if width is None else min(width, self.w)
        self.put(y, 0, self.g.hline * width, attr)
        if title:
            self.put(y, 2, " %s " % title, self.attr("hdr"))
        if right:
            self.put(y, max(0, width - len(right) - 3), " %s " % right, attr)

    def clip(self, text: str, width: int) -> str:
        if width <= 0:
            return ""
        if len(text) <= width:
            return text
        return text[:max(0, width - 1)] + self.g.ell


class ScreenRegion(Screen):
    """A clipped drawing surface with coordinates relative to its parent."""

    def __init__(self, parent, top, left, height, width):
        self.parent = parent
        self.top, self.left = top, left
        self.height = max(0, min(height, parent.h - top))
        self.width = max(0, min(width, parent.w - left))
        self.g = parent.g

    @property
    def h(self):
        return self.height

    @property
    def w(self):
        return self.width

    def attr(self, *args, **kwargs):
        return self.parent.attr(*args, **kwargs)

    def put(self, y, x, text, attr=0, width=None):
        if y < 0 or y >= self.h or x >= self.w:
            return x
        if x < 0:
            text, x = text[-x:], 0
        room = self.w - x
        if width is not None:
            room = min(room, width)
        if room <= 0:
            return x
        end = self.parent.put(self.top + y, self.left + x, text[:room], attr)
        return end - self.left


def fmt_duration(seconds: Optional[float]) -> str:
    if seconds is None:
        return "--"
    seconds = int(seconds)
    hours, rest = divmod(seconds, 3600)
    minutes, secs = divmod(rest, 60)
    if hours:
        return "%d:%02d:%02d" % (hours, minutes, secs)
    return "%02d:%02d" % (minutes, secs)


class Buttons:
    """A row of labelled fields, one of which is selected."""

    def __init__(self, labels: Tuple[str, ...]):
        self.labels = list(labels)
        self.index = 0

    def move(self, delta: int) -> None:
        if self.labels:
            self.index = (self.index + delta) % len(self.labels)

    @property
    def current(self) -> str:
        return self.labels[self.index] if self.labels else ""

    def draw(self, screen: Screen, y: int, x: int, focused: bool,
             enabled=None) -> None:
        for i, label in enumerate(self.labels):
            live = True if enabled is None else enabled(label)
            text = " %s " % label
            if focused and i == self.index:
                attr = screen.attr("plain", reverse=True, bold=True)
            elif not live:
                attr = screen.attr("dim")
            else:
                attr = screen.attr("value")
            x = screen.put(y, x, "[", screen.attr("dim"))
            x = screen.put(y, x, text, attr)
            x = screen.put(y, x, "]", screen.attr("dim"))
            x += 2
