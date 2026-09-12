"""Panel-control layout and cursor navigation.

Pages rebuild controls from current machine state; cursors retain row and
column across rebuilds.
"""

from __future__ import annotations

import curses
from dataclasses import dataclass
from typing import Callable, Dict, List, Optional, Sequence, Tuple

from .screen import Screen


@dataclass
class Cell:
    """One thing the cursor can stand on, or a light it passes over."""

    text: str
    x: int = 0
    y: int = 0
    lit: bool = False              # drawn reversed
    action: Optional[Callable[[], None]] = None
    digits: Optional[Callable[[int], None]] = None   # a 0-7 key sets a code
    driven: bool = False           # set from this page
    active: bool = True            # something is behind it
    kind: str = "bit"              # bit | code | radio | button

    @property
    def width(self) -> int:
        return len(self.text)

    @property
    def live(self) -> bool:
        return bool(self.action or self.digits)

    def draw(self, screen: Screen, cursor: bool = False) -> None:
        if cursor and self.kind in ("radio", "button"):
            screen.put(self.y, self.x, self.text, screen.attr("warn", bold=True, reverse=True))
            return
        colour = "warn" if cursor else ("plain" if self.active else "dark")
        if self.kind == "code":
            # Each set bit of the code reversed.
            x = self.x
            for ch in self.text:
                x = screen.put(self.y, x, ch, screen.attr(
                    colour, reverse=ch != "0", bold=cursor, underline=self.driven))
        else:
            screen.put(self.y, self.x, self.text, screen.attr(
                colour, reverse=self.lit, bold=cursor, underline=self.driven))


class Control:
    """Placed before drawing so off-screen cells retain content coordinates."""

    width = 0
    height = 1

    def __init__(self) -> None:
        self.x = 0
        self.y = 0

    def place(self, x: int, y: int) -> "Control":
        self.x, self.y = x, y
        return self

    def draw(self, screen: Screen) -> None:
        pass

    def cells(self) -> List[Cell]:
        return []

    def groups(self) -> List["Group"]:
        """The cells as the cursor walks them: one group, stacked."""
        cells = self.cells()
        return [Group(cells)] if cells else []


class Label(Control):
    def __init__(self, text: str, colour: str = "plain", bold: bool = False):
        super().__init__()
        self.text = text
        self.colour = colour
        self.bold = bold
        self.width = len(text)

    def draw(self, screen: Screen) -> None:
        screen.put(self.y, self.x, self.text, screen.attr(self.colour, bold=self.bold))


class Talkback(Control):

    GRAY = ""
    BARBERPOLE = None
    width = 8
    height = 3

    def __init__(self, show: Optional[str], active: bool = True):
        super().__init__()
        self.show = show
        self.active = active

    def draw(self, screen: Screen) -> None:
        g = screen.g
        x, y = self.x, self.y
        frame = screen.attr("dim" if self.active else "dark")
        screen.put(y, x, "+------+" if g.ascii else "┌──────┐", frame)
        screen.put(y + 1, x, g.vline, frame)
        screen.put(y + 1, x + 7, g.vline, frame)
        screen.put(y + 2, x, "+------+" if g.ascii else "└──────┘", frame)
        if not self.active:
            return
        if self.show is Talkback.BARBERPOLE:
            screen.put(y + 1, x + 1, "//////", screen.attr("warn"))
        elif self.show == Talkback.GRAY:
            screen.put(y + 1, x + 1, "      ", screen.attr("gray", reverse=True))
        else:
            screen.put(y + 1, x + 1, self.show.center(6), screen.attr("plain", reverse=True))


class Pushbutton(Control):
    def __init__(self, label: str, action: Optional[Callable[[], None]], active: bool = True):
        super().__init__()
        self.cell = Cell("[ %s ]" % label, action=action if active else None,
                         active=active, kind="button")
        self.width = self.cell.width

    def place(self, x: int, y: int) -> "Pushbutton":
        super().place(x, y)
        self.cell.x, self.cell.y = x, y
        return self

    def draw(self, screen: Screen) -> None:
        self.cell.draw(screen)

    def cells(self) -> List[Cell]:
        return [self.cell]


class Switch(Control):

    def __init__(self, positions: Sequence[str], made: Optional[str],
                 select: Optional[Callable[[str], None]], active: bool = True,
                 momentary: Sequence[str] = ()):
        super().__init__()
        inner = max(len(p) for p in positions)
        self._cells = []
        for label in positions:
            if label in momentary:
                text = ("/>%s<\\" if label == made else "/ %s \\") % label.center(inner)
            else:
                text = ("|>%s<|" if label == made else "| %s |") % label.center(inner)
            action = (lambda label=label: select(label)) if active and select else None
            self._cells.append(Cell(text, action=action, active=active, kind="radio"))
        self.width = inner + 4
        self.height = len(positions)

    def place(self, x: int, y: int) -> "Switch":
        super().place(x, y)
        for i, cell in enumerate(self._cells):
            cell.x, cell.y = x, y + i
        return self

    def draw(self, screen: Screen) -> None:
        for cell in self._cells:
            cell.draw(screen)

    def cells(self) -> List[Cell]:
        return self._cells


class Lines(Control):
    """Cells side by side, a space between: the lines of one field."""

    def __init__(self, cells: Sequence[Cell]):
        super().__init__()
        self._cells = list(cells)
        self.width = sum(c.width for c in self._cells) + max(0, len(self._cells) - 1)

    def place(self, x: int, y: int) -> "Lines":
        super().place(x, y)
        for cell in self._cells:
            cell.x, cell.y = x, y
            x += cell.width + 1
        return self

    def draw(self, screen: Screen) -> None:
        for cell in self._cells:
            cell.draw(screen)

    def cells(self) -> List[Cell]:
        return self._cells

    def groups(self) -> List["Group"]:
        return [Group(self._cells, vertical=False)] if self._cells else []


class Matrix(Control):

    width = 12
    height = 6

    def __init__(self, lit: Dict[Tuple[int, int], bool]):
        super().__init__()
        self.lit = lit

    def draw(self, screen: Screen) -> None:
        dim = screen.attr("dim")
        g = screen.g
        x, y = self.x, self.y
        screen.put(y, x + 3, "1 2 3 4 5", dim)
        for i in range(1, 6):
            screen.put(y + i, x, "%d " % i, dim)
            for j in range(1, 6):
                state = self.lit.get((i, j))
                if state:
                    attr = screen.attr("warn" if i == j else "plain", reverse=True, bold=True)
                    char = "%d" % i if i == j else "*"
                elif state is None:
                    attr, char = dim, g.dot
                else:
                    attr, char = screen.attr("plain"), "o"
                screen.put(y + i, x + 3 + (j - 1) * 2, char, attr)


class Stack(Control):
    """Controls one above another, each centred on the widest."""

    def __init__(self, children: Sequence[Control], gap: int = 0, align: str = "center"):
        super().__init__()
        self.children = list(children)
        self.gap = gap
        self.align = align
        self.width = max((c.width for c in self.children), default=0)
        self.height = sum(c.height for c in self.children) + gap * max(0, len(self.children) - 1)

    def place(self, x: int, y: int) -> "Stack":
        super().place(x, y)
        for child in self.children:
            dx = (self.width - child.width) // 2 if self.align == "center" else 0
            child.place(x + dx, y)
            y += child.height + self.gap
        return self

    def draw(self, screen: Screen) -> None:
        for child in self.children:
            child.draw(screen)

    def cells(self) -> List[Cell]:
        return [cell for child in self.children for cell in child.cells()]

    def groups(self) -> List["Group"]:
        return [group for child in self.children for group in child.groups()]


class Row(Control):
    """Controls side by side, tops aligned, a gap between."""

    def __init__(self, children: Sequence[Control], gap: int = 1):
        super().__init__()
        self.children = list(children)
        self.gap = gap
        self.width = sum(c.width for c in self.children) + gap * max(0, len(self.children) - 1)
        self.height = max((c.height for c in self.children), default=1)

    def place(self, x: int, y: int) -> "Row":
        super().place(x, y)
        for child in self.children:
            child.place(x, y)
            x += child.width + self.gap
        return self

    def draw(self, screen: Screen) -> None:
        for child in self.children:
            child.draw(screen)

    def cells(self) -> List[Cell]:
        return [cell for child in self.children for cell in child.cells()]

    def groups(self) -> List["Group"]:
        return [group for child in self.children for group in child.groups()]


@dataclass
class Group:
    """The cells of one control, stacked or side by side."""

    cells: List[Cell]
    vertical: bool = True


class Cursor:
    """Navigate cells by column (left/right), row (up/down), or group (tab)."""

    ENTER = (curses.KEY_ENTER, 10, 13, ord(" "))

    def __init__(self) -> None:
        self.col = 0
        self.grp = 0
        self.idx = 0
        self.columns: List[List[Group]] = []

    def take(self, columns: Sequence[Sequence[Group]]) -> None:
        """The cells of a fresh redraw; the cursor keeps its place."""
        self.columns = []
        for column in columns:
            groups = [Group([c for c in g.cells if c.live], g.vertical) for g in column]
            groups = [g for g in groups if g.cells]
            if groups:
                self.columns.append(groups)
        self._clamp()

    def _clamp(self) -> None:
        if not self.columns:
            self.col = self.grp = self.idx = 0
            return
        self.col = max(0, min(self.col, len(self.columns) - 1))
        self.grp = max(0, min(self.grp, len(self.columns[self.col]) - 1))
        self.idx = max(0, min(self.idx, len(self.group.cells) - 1))

    @property
    def group(self) -> Group:
        return self.columns[self.col][self.grp]

    @property
    def current(self) -> Optional[Cell]:
        if not self.columns:
            return None
        return self.group.cells[self.idx]

    def draw(self, screen: Screen) -> None:
        cell = self.current
        if cell is not None:
            cell.draw(screen, cursor=True)

    def _nearest(self, col: int, y: int, x: int) -> None:
        """Into column `col`, at the cell nearest (y, x)."""
        best = None
        for g, group in enumerate(self.columns[col]):
            for i, cell in enumerate(group.cells):
                key = (abs(cell.y - y), abs(cell.x - x))
                if best is None or key < best[0]:
                    best = (key, g, i)
        self.col, self.grp, self.idx = col, best[1], best[2]

    def move_v(self, delta: int) -> None:
        here = self.current
        if here is None:
            return
        group = self.group
        if group.vertical and 0 <= self.idx + delta < len(group.cells):
            self.idx += delta
            return
        grp = self.grp + delta
        if not 0 <= grp < len(self.columns[self.col]):
            return
        self.grp = grp
        cells = self.group.cells
        if self.group.vertical:
            self.idx = 0 if delta > 0 else len(cells) - 1
        else:
            self.idx = min(range(len(cells)), key=lambda i: abs(cells[i].x - here.x))

    def move_h(self, delta: int) -> None:
        here = self.current
        if here is None:
            return
        group = self.group
        if not group.vertical and 0 <= self.idx + delta < len(group.cells):
            self.idx += delta
            return
        col = self.col + delta
        if 0 <= col < len(self.columns):
            self._nearest(col, here.y, here.x)

    def tab(self, delta: int) -> None:
        if not self.columns:
            return
        grp = self.grp + delta
        if grp >= len(self.columns[self.col]):
            self.col = (self.col + 1) % len(self.columns)
            grp = 0
        elif grp < 0:
            self.col = (self.col - 1) % len(self.columns)
            grp = len(self.columns[self.col]) - 1
        self.grp, self.idx = grp, 0

    def home(self) -> None:
        self.col = self.grp = self.idx = 0

    def handle(self, ch: int) -> bool:
        """A key that moves the cursor or acts on its cell; False if not one."""
        if ch in (curses.KEY_DOWN, ord("j")):
            self.move_v(1)
        elif ch in (curses.KEY_UP, ord("k")):
            self.move_v(-1)
        elif ch in (curses.KEY_LEFT, ord("h")):
            self.move_h(-1)
        elif ch in (curses.KEY_RIGHT, ord("l")):
            self.move_h(1)
        elif ch == ord("\t"):
            self.tab(1)
        elif ch == curses.KEY_BTAB:
            self.tab(-1)
        elif ch == curses.KEY_HOME:
            self.home()
        elif ch in self.ENTER:
            cell = self.current
            if cell is not None and cell.action:
                cell.action()
        elif ord("0") <= ch <= ord("7"):
            cell = self.current
            if cell is not None and cell.digits:
                cell.digits(ch - ord("0"))
        else:
            return False
        return True
