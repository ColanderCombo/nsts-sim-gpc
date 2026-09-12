"""Scrollable text view of configured crew panels.

Groups wrap left to right; unanswered indicators are dark. The cursor visits
crew controls and remains visible as the page scrolls. Drawing primitives are
shared with the GPC STATUS page through ``simMgr.controls``.
"""

from __future__ import annotations

import curses
from typing import Dict, List, Optional, Sequence, Tuple

from ..controls import (Cell, Control as Drawn, Cursor, Group, Label, Lines,
                        Pushbutton, Stack, Switch, Talkback)
from ..screen import Screen
from .bus import BARBERPOLE, GRAY
from .catalog import Control, Panel
from .link import PanelLink

GAP = 2

#: The first line the panels are drawn on, under the title and page bars.
TOP = 3


def talkback_show(value) -> Optional[str]:
    """What a talkback's drum reads: a legend, blank, or the diagonals."""
    text = str(value or "").strip().lower()
    if text == BARBERPOLE:
        return Talkback.BARBERPOLE
    if text in (GRAY, ""):
        return Talkback.GRAY
    return text.upper()


class PanelView:
    """One page: the panels this frontend holds."""

    def __init__(self, app, link: PanelLink, panels: Sequence[Panel], title: str = ""):
        self.app = app
        self.link = link
        self.panels = list(panels)
        self.title = title
        self.cursor = Cursor()
        self.where: Dict[int, Control] = {}      # id(cell) -> the control on it
        self.top = 0                             # content lines above the window
        self.height = 0                          # lines the panels take
        self.view = 1                            # lines the window shows
        self.follow = True                       # scroll to the cursor this draw


    def draw(self, screen: Screen) -> None:
        app = self.app
        g = screen.g
        what = (self.panels[0].title if len(self.panels) == 1
                else "%d panels" % len(self.panels))
        app.title_bar(screen, "%s%s" % ("%s  %s " % (self.title, g.dot) if self.title else "", what))
        app.page_bar(screen)

        self.where = {}
        columns: List[List[Group]] = []
        items: List[Tuple[str, int, int, object]] = []
        y = 0
        for panel in self.panels:
            items.append(("rule", y, 0, "%s  %s" % (panel.name, panel.title)))
            y += 1
            for group in panel.groups:
                if group.title:
                    items.append(("hdr", y, 2, group.title))
                    y += 1
                y = self._flow(screen, group.controls, y, items, columns)
                y += 1
        self.height = y
        self.cursor.take(columns)

        view = self.view = max(1, screen.h - TOP - 3)
        top = self._scroll(view)
        for kind, iy, ix, what in items:
            row = TOP + iy - top
            if kind == "rule":
                if TOP <= row < TOP + view:
                    screen.rule(row, what)
            elif kind == "hdr":
                if TOP <= row < TOP + view:
                    screen.put(row, ix, what, screen.attr("hdr"))
            else:
                what.place(ix, row)
                if row + what.height > TOP and row < TOP + view:
                    what.draw(screen)
        if not self.follow:
            self._take_visible(view)
            self.follow = True
        self.cursor.draw(screen)

        y = screen.h - 3
        screen.rule(y, self._off_screen(screen, top, view), right=self._state_of_link())
        screen.put(y + 1, 2, screen.clip(self._under_cursor(), screen.w - 4),
                   screen.attr("note"))
        app.hint_line(screen, y + 2,
                      "arrows move   enter throw   tab next control   "
                      "+/- turn a wheel   pgup/pgdn scroll   F6 view   q quit")

    def _flow(self, screen: Screen, controls: Sequence[Control], y: int,
              items: List[Tuple[str, int, int, object]],
              columns: List[List[Group]]) -> int:
        """The controls left to right, wrapped; returns the line after them."""
        x = 4
        tall = 0
        for control in controls:
            drawn = self._drawn(control)
            if x > 4 and x + drawn.width > screen.w - 2:
                y += tall + 1
                x, tall = 4, 0
            drawn.place(x, y)
            items.append(("control", y, x, drawn))
            columns.append(drawn.groups())
            for cell in drawn.cells():
                self.where[id(cell)] = control
            x += drawn.width + GAP
            tall = max(tall, drawn.height)
        return y + tall


    def _scroll(self, view: int) -> int:
        """Choose the first content line; cells still use content coordinates."""
        top = self.top
        cell = self.cursor.current
        if self.follow and cell is not None:
            if cell.y - 1 < top:
                top = max(0, cell.y - 1)
            elif cell.y >= top + view:
                top = cell.y - view + 1
        self.top = max(0, min(top, max(0, self.height - view)))
        return self.top

    def _take_visible(self, view: int) -> None:
        """Move the cursor to a visible control after coordinates become screen-relative."""
        best = None
        for col, column in enumerate(self.cursor.columns):
            for grp, group in enumerate(column):
                for idx, cell in enumerate(group.cells):
                    if not TOP <= cell.y < TOP + view:
                        continue
                    key = (cell.y, cell.x)
                    if best is None or key < best[0]:
                        best = (key, col, grp, idx)
        if best is not None:
            _, self.cursor.col, self.cursor.grp, self.cursor.idx = best

    def _off_screen(self, screen: Screen, top: int, view: int) -> str:
        g = screen.g
        parts = []
        if top > 0:
            parts.append("%s %d" % (g.up, top))
        below = self.height - top - view
        if below > 0:
            parts.append("%s %d" % (g.down, below))
        return "  ".join(parts)

    def _drawn(self, control: Control) -> Drawn:
        """The control as something the screen can put down."""
        link = self.link
        value = link.at(control)
        heard = link.heard(control)
        title = control.title
        if control.amps is not None:
            title = "%s %gA" % (title, control.amps)
        label = Label(title, "plain" if heard else "dark")

        if control.kind in ("switch", "breaker", "rotary", "momentary"):
            body: Drawn = Switch(control.positions, str(value),
                                 lambda p, c=control: link.put(c, p),
                                 active=True, momentary=control.spring)
        elif control.kind == "pushbutton":
            body = Pushbutton(control.face or control.title,
                              lambda c=control: link.press(c))
            body.cell.lit = bool(value)
        elif control.kind == "thumbwheel":
            low, high = (control.range or [0, 0xFFFF])[:2]
            text = "%*d" % (len("%d" % int(high)), int(value or 0))
            body = Lines([
                Cell("[-]", action=lambda c=control: link.step(c, -1), kind="button"),
                Cell(text, action=lambda c=control: None),
                Cell("[+]", action=lambda c=control: link.step(c, 1), kind="button"),
            ])
        elif control.kind == "talkback":
            body = Talkback(talkback_show(value), active=heard)
        elif control.kind == "light":
            legend = (control.positions[0] if control.positions else control.id).upper()
            body = Lines([Cell(" %s " % legend, lit=bool(value) and heard, active=heard)])
        else:                                   # meter
            body = Lines([Cell(self._meter(control, value, heard), active=heard)])
        return Stack([label, body])

    def _meter(self, control: Control, value, heard: bool) -> str:
        if not heard:
            return "  --  %s" % control.units
        return "%6.2f %s" % (float(value or 0.0), control.units)

    def _state_of_link(self) -> str:
        if self.link.error:
            return "panel bus: %s" % self.link.error
        waiting = [c for p in self.panels for c in p.indicators
                   if not self.link.heard(c)]
        if waiting:
            return "%d indicator%s unanswered" % (len(waiting), "" if len(waiting) == 1 else "s")
        return "%d control%s" % (len(self.link.controls),
                                 "" if len(self.link.controls) == 1 else "s")

    def _under_cursor(self) -> str:
        cell = self.cursor.current
        if cell is None:
            return ""
        control = self.where.get(id(cell))
        if control is None:
            return ""
        return "%s   %s   %s" % (control.key, control.title, self.link.at(control))


    def handle(self, ch: int) -> None:
        if ch in (curses.KEY_NPAGE, curses.KEY_PPAGE):
            self.follow = False
            step = max(1, self.view - 2)
            self.top += step if ch == curses.KEY_NPAGE else -step
            self.top = max(0, min(self.top, max(0, self.height - self.view)))
            return
        if self.cursor.handle(ch):
            self.follow = True
            return
        cell = self.cursor.current
        control = self.where.get(id(cell)) if cell is not None else None
        if control is not None and control.kind == "thumbwheel":
            if ch in (ord("+"), ord("=")):
                self.link.step(control, 1)
                return
            if ch in (ord("-"), ord("_")):
                self.link.step(control, -1)
                return
        if ch in (ord("q"), ord("Q")):
            self.app.quit()
