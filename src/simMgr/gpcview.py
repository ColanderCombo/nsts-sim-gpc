"""GPC STATUS, GPC controls, and IDP controls in one page.

GPC data comes from ``gpclink`` debug sessions at 4 Hz; IDP data comes from
``idplink`` discrete channels. Unavailable units are dark. Input lines are
interactive; output lines are read-only.

JSC-11174 Vol.1 drawing 8.1 sheet 1 and JSC-18819 SCP 5.11 mappings::

    control             discrete
    OUTPUT talkback     DO-07 I/O ACTIVE
    MODE talkback       DO-31 IPL, DO-09 RUN
    IPL pushbutton      DI-03
    MODE switch         DI-00 HALT, DI-01 STANDBY, DI-02 RUN
    OUTPUT switch       DI-13 I/O TERM B
    IPL SOURCE          DI-04 MMU 1, DI-05 MMU 2
    BFC CRT             DI-38..39: 0 none, 1 DK1, 2 DK2, 3 DK3

USA-005350 sections 2.5.7.1/2.5.9 and USA-007587 section 2.6 specify the
IDP/CRT SEL and IDP LOAD controls.

The GPC STATUS matrix is "a 5-by-5 matrix of lights.  Each light corresponds
to a GPC's fail vote against another GPC or itself" (SCOM USA-007587 p. 2.6-4).
Rows are voters; columns are voted-against GPCs. NASA-CR-147827 Table 3 sync
codes are 000 halt/off/failed, 010/011 I/O complete with/without error,
100 SSIP, 101 timer, 110 SVC, and 111 null/run.
"""

from __future__ import annotations

from typing import Callable, Dict, List, Optional, Sequence, Tuple

from .config import Lru
from .controls import (Cell, Control, Cursor, Group, Label, Lines, Matrix, Pushbutton,
                       Row, Stack, Switch, Talkback)
from .gpclink import (BITS_A, BITS_B, BITS_OUT, REG_A, REG_B, REG_FAIL, REG_OUT,
                      REG_RM, GpcLink, bit, field as bits_field)
from .idplink import BITS_A as IDP_BITS_A, IDP_IDS, IdpLinks
from .screen import Screen

#: The three sync lines from each other station, most significant first.
SYNC_IN = {k: [BITS_A["stbyn%d" % k], BITS_A["runn%d" % k], BITS_A["syncn%d" % k]]
           for k in (1, 2, 3, 4)}
SYNC_OUT = [BITS_OUT["stbyout"], BITS_OUT["runout"], BITS_OUT["syncout"]]
GPC_ID = [BITS_B["gpcid0"], BITS_B["gpcid1"], BITS_B["gpcid2"]]
CRT_SEL = [BITS_B["crta"], BITS_B["crtb"]]
MODES = {"RUN": "run", "STBY": "standby", "HALT": "halt"}
OUTPUT_POSITIONS = ("BACKUP", "NORMAL", "TERMINATE")
IPL_SOURCES = {"MMU 1": (1, 0), "OFF": (0, 0), "MMU 2": (0, 1)}
CRT_POSITIONS = ("OFF", "1+2", "2+3", "3+1")
REG_BITS = {REG_A: BITS_A, REG_B: BITS_B, REG_OUT: BITS_OUT}

#: Column geometry: the matrix and row labels to the left, then the five
#: GPC columns packed to their widest control, the switches to the right
#: in what remains.
LEFT = 16
COL = 16
END = LEFT + 5 * COL                            # the GPC block's right edge


def station(own: int, k: int) -> Optional[int]:
    """GPC number of station N+k as seen from GPC `own`, 1 to 5."""
    if not 1 <= own <= 5:
        return None
    return (own - 1 + k) % 5 + 1


class GpcView:
    HINT = ("left/right column   up/down within it   tab next control   "
            "enter toggle / select / press   0-7 set a code   F6 view   q quit")

    def __init__(self, app):
        self.app = app
        self.cursor = Cursor()
        self.output_pos: Dict[int, str] = {}   # per GPC, which position last held I/O TERM B


    @property
    def gpcs(self) -> List[Lru]:
        return [lru for lru in self.app.sup.config.lrus if lru.debug_port]

    def links_by_id(self) -> Dict[int, GpcLink]:
        """The GPCs answering, by the number their ID lines give, 1 to 5."""
        out: Dict[int, GpcLink] = {}
        for lru in self.gpcs:
            link = self.app.link(lru)
            b = link.registers.get(REG_B)
            if link.connected and b is not None:
                out.setdefault(bits_field(b, GPC_ID), link)
        return {n: link for n, link in out.items() if 1 <= n <= 5}


    def draw(self, screen: Screen, embedded=False, focused=True) -> None:
        app = self.app
        g = screen.g
        if not embedded:
            app.title_bar(screen, "%s  %s GPC STATUS" % (app.sup.config.name, g.dot))
            app.page_bar(screen)
        self._draw_sessions(screen, 2)
        screen.rule(3)

        links = self.links_by_id()
        footer = screen.h - 3
        y0 = 4
        controls: List[Control] = []

        # The cursor's columns: the five GPCs, each from its switches down
        # through its lines of the table, then the switches at the right.
        walk: List[List[Group]] = [[] for _ in range(6)]

        controls.append(self.matrix(links).place(2, y0 + 1))
        columns = []
        for n in range(1, 6):
            column = self.column(n, links.get(n))
            column.place(LEFT + 1 + (n - 1) * COL + (COL - 1 - column.width) // 2, y0)
            columns.append(column)
            walk[n - 1].extend(column.groups())
        controls.extend(columns)
        switches = self.switches(links)
        controls.append(switches.place(screen.w - 2 - switches.width, y0))
        walk[5].extend(switches.groups())
        idp = self.idp_block()
        if screen.w - 2 - idp.width > END + 2:
            controls.append(idp.place(screen.w - 2 - idp.width, y0 + switches.height + 1))
            walk[5].extend(idp.groups())

        y = y0 + columns[0].height
        screen.rule(y, "discretes", width=END)
        table = self.table(screen, y + 1, footer, links, walk)
        controls.extend(table)

        # The rules before and between the columns, from the headers to the
        # last row of the table, over the two rules that cross them.
        last = max((c.y for c in table), default=y)
        for i in range(5):
            for y in range(y0, last + 1):
                screen.put(y, LEFT + i * COL, g.vline, screen.attr("dim"))

        for control in controls:
            control.draw(screen)
        self.cursor.take(walk)

        screen.rule(footer)
        if not embedded:
            app.message_line(screen, footer + 1)
            app.hint_line(screen, footer + 2, self.HINT)
        if self.app.idp_links.error:
            screen.put(footer + 1, screen.w // 2, "IDP channels: %s" % self.app.idp_links.error,
                       screen.attr("warn"))
        if focused:
            self.cursor.draw(screen)

    def _draw_sessions(self, screen: Screen, y: int) -> None:
        """Line 2: each GPC LRU's session and where its machine is."""
        g = screen.g
        x = 2
        if not self.gpcs:
            screen.put(y, x, "no LRU in this configuration declares debugPort",
                       screen.attr("warn"))
            return
        for lru in self.gpcs:
            link = self.app.link(lru)
            if link.connected:
                status = link.status
                what = "running" if status.get("running") else (
                    "stopped: %s" % (status.get("reason") or "?"))
                colour = "up" if status.get("running") else "warn"
            else:
                what, colour = link.error or "connecting", "dim"
            x = screen.put(y, x, "%s %s " % (lru.key, link.where), screen.attr("plain", bold=True))
            x = screen.put(y, x, screen.clip(what, screen.w - x - 1), screen.attr(colour))
            x = screen.put(y, x, "  %s  " % g.dot, screen.attr("dim"))


    def matrix(self, links: Dict[int, GpcLink]) -> Matrix:
        lit: Dict[Tuple[int, int], bool] = {}
        for own, link in links.items():
            rm, fail = link.registers.get(REG_RM), link.registers.get(REG_FAIL)
            if rm is None:
                continue
            lit[(own, own)] = bool(bit(rm, 0))
            for k in (1, 2, 3, 4):
                other = station(own, k)
                votes = fail is not None and not (fail & 0x10) and bool(fail & (0x10 >> k))
                lit[(own, other)] = lit.get((own, other)) or votes
                lit[(other, own)] = lit.get((other, own)) or bool(bit(rm, 10 + k))
        return Matrix(lit)

    def column(self, n: int, link: Optional[GpcLink]) -> Stack:
        """One GPC's panel O6 controls, top to bottom."""
        regs = link.registers if link else {}
        a, out = regs.get(REG_A), regs.get(REG_OUT)
        active = link is not None

        # OUTPUT switch: NORMAL releases I/O TERM B, the other two hold it.
        termb = bool(bit(a, BITS_A["iotermb"])) if a is not None else None
        if termb is False:
            output_made = "NORMAL"
        elif termb:
            output_made = self.output_pos.get(n, "TERMINATE")
        else:
            output_made = None

        def select_output(label: str) -> None:
            if label != "NORMAL":
                self.output_pos[n] = label
            link.set(REG_A, BITS_A["iotermb"], label != "NORMAL")

        # MODE talkback: IPL over RUN, barberpole with neither.
        if bit(out, BITS_OUT["iplout"]):
            mode_tb = "IPL"
        elif bit(out, BITS_OUT["readytb"]):
            mode_tb = "RUN"
        else:
            mode_tb = Talkback.BARBERPOLE

        # MODE switch: one position made, the other two broken.
        mode_made = None
        for label, name in MODES.items():
            if bit(a, BITS_A[name]):
                mode_made = label

        def select_mode(label: str) -> None:
            for other in MODES.values():
                link.set(REG_A, BITS_A[other], other == MODES[label])

        return Stack([
            Label("%d" % n, bold=active) if active else Label("%d" % n, "dark"),
            Talkback(Talkback.GRAY if bit(out, BITS_OUT["ioactivetb"]) else Talkback.BARBERPOLE,
                     active),
            Switch(OUTPUT_POSITIONS, output_made, select_output, active),
            Pushbutton("IPL", (lambda: link.press_ipl()) if active else None, active),
            Talkback(mode_tb, active),
            Switch(tuple(MODES), mode_made, select_mode, active),
        ])

    def switches(self, links: Dict[int, GpcLink]) -> Stack:
        regs = [link.registers.get(REG_A) for link in links.values()]
        regs_b = [link.registers.get(REG_B) for link in links.values()]
        active = bool(links) and all(r is not None for r in regs + regs_b)

        source_made = None
        for label, (mm1, mm2) in IPL_SOURCES.items():
            if active and all(bit(r, BITS_A["mm1src"]) == mm1 and bit(r, BITS_A["mm2src"]) == mm2
                              for r in regs):
                source_made = label

        def select_source(label: str) -> None:
            mm1, mm2 = IPL_SOURCES[label]
            for link in links.values():
                link.set(REG_A, BITS_A["mm1src"], bool(mm1))
                link.set(REG_A, BITS_A["mm2src"], bool(mm2))

        crt_made = None
        for code, label in enumerate(CRT_POSITIONS):
            if active and all(bits_field(r, CRT_SEL) == code for r in regs_b):
                crt_made = label

        def select_crt(label: str) -> None:
            for link in links.values():
                link.set_field(REG_B, CRT_SEL, CRT_POSITIONS.index(label))

        head = "plain" if active else "dark"
        return Stack([
            Label("IPL SOURCE", head, bold=active),
            Switch(tuple(IPL_SOURCES), source_made, select_source, active),
            Label(""),
            Label("BFC CRT", head, bold=active),
            Switch(CRT_POSITIONS, crt_made, select_crt, active),
        ])

    def idp_block(self) -> Stack:
        links: IdpLinks = self.app.idp_links
        up = [n for n in IDP_IDS if links.connected(n)]
        positions = links.positions()
        sel_active = positions is not None
        left, right = positions or (None, None)
        head = "plain" if up else "dark"

        def select_left(label: str) -> None:
            links.set_sel(int(label), right or 2)

        def select_right(label: str) -> None:
            links.set_sel(left or 1, int(label))

        sel = Row([
            Stack([Label("LEFT", head),
                   Switch(("1", "3"), str(left) if left else None, select_left, sel_active)]),
            Stack([Label("RIGHT", head),
                   Switch(("2", "3"), str(right) if right else None, select_right, sel_active)]),
        ], gap=2)

        loads = []
        for n in IDP_IDS:
            active = links.connected(n)
            made = "LOAD" if links.load_line(n) else "OFF"

            def press(label: str, n: int = n) -> None:
                if label == "LOAD":
                    links.press_load(n)

            loads.append(Stack([
                Label("%d" % n, "plain" if active else "dark", bold=active),
                Switch(("LOAD", "OFF"), made if active else None, press, active,
                       momentary=("LOAD",)),
            ]))

        def line(label: str, get: Callable[[int], bool], name: Optional[str]) -> Row:
            cells = []
            for n in IDP_IDS:
                active = links.connected(n)
                action = None
                if name is not None and active:
                    def action(n: int = n, name: str = name, get=get) -> None:
                        links.set(n, name, not get(n))
                driven = name is not None and (n, IDP_BITS_A[name]) in links.driven
                cells.append(Cell("%d" % n, lit=active and get(n), action=action,
                                  driven=driven, active=active))
            return Row([Label(label.ljust(11), "dim"), Lines(cells)], gap=0)

        return Stack([
            Label("IDP/CRT SEL", head, bold=bool(up)),
            sel,
            Label(""),
            Label("IDP LOAD", head, bold=bool(up)),
            Row(loads, gap=1),
            Label(""),
            line("KYBD SEL A", lambda n: links.lines(n)[0], "kybdsela"),
            line("KYBD SEL B", lambda n: links.lines(n)[1], "kybdselb"),
            line("LOAD", links.load_line, "load"),
            line("LOADING", links.loading, None),
        ], align="left")


    def table(self, screen: Screen, y0: int, bottom: int, links: Dict[int, GpcLink],
              walk: List[List[Group]]) -> List[Control]:
        def bits(reg: str, names: Sequence[Tuple[str, str]]) -> Callable[[Optional[GpcLink]], Lines]:
            def make(link: Optional[GpcLink]) -> Lines:
                value = link.registers.get(reg) if link else None
                cells = []
                for text, name in names:
                    n = REG_BITS[reg][name]
                    action = None
                    if link and reg != REG_OUT:
                        def action(link=link, n=n, value=value):
                            link.set(reg, n, not bit(value, n))
                    cells.append(Cell(text, lit=bool(bit(value, n)), action=action,
                                      driven=bool(link) and (reg, n) in link.driven,
                                      active=link is not None))
                return Lines(cells)
            return make

        def codes(reg: str, fields: Sequence[List[int]],
                  numeric: bool = False) -> Callable[[Optional[GpcLink]], Lines]:
            def make(link: Optional[GpcLink]) -> Lines:
                value = link.registers.get(reg) if link else None
                cells = []
                for field_bits in fields:
                    code = bits_field(value, field_bits)
                    action = digits = None
                    if link and reg != REG_OUT:
                        def action(link=link, fb=field_bits, code=code):
                            link.set_field(reg, fb, (code + 1) % 8)
                        def digits(v, link=link, fb=field_bits):
                            link.set_field(reg, fb, v)
                    cells.append(Cell(str(code) if numeric else format(code, "03b"),
                                      lit=code != 0, action=action, digits=digits,
                                      driven=bool(link) and any((reg, n) in link.driven
                                                                for n in field_bits),
                                      active=link is not None, kind="code"))
                return Lines(cells)
            return make

        layout = [
            ("MODE", bits(REG_A, [("halt", "halt"), ("stby", "standby"), ("run", "run")])),
            ("IPL", bits(REG_A, [("ipl", "ipl")])),
            ("MM SOURCE", bits(REG_A, [("mm1", "mm1src"), ("mm2", "mm2src")])),
            ("MM READY", bits(REG_A, [("mm1", "mm1ready"), ("mm2", "mm2ready")])),
            ("BFS RUN N+", bits(REG_A, [(str(k), "bfsrunn%d" % k) for k in (1, 2, 3, 4)])),
            ("I/O TERM", bits(REG_A, [("a", "ioterma"), ("b", "iotermb")])),
            ("DUMP", bits(REG_A, [("dump", "dumpreq")])),
            ("SYNC N+1,2", codes(REG_A, [SYNC_IN[1], SYNC_IN[2]])),
            ("SYNC N+3,4", codes(REG_A, [SYNC_IN[3], SYNC_IN[4]])),
            ("GPC ID", codes(REG_B, [GPC_ID], numeric=True)),
            ("BFS ENGAGE", bits(REG_B, [("1", "bfs1"), ("2", "bfs2"), ("3", "bfs3")])),
            ("CRT SEL", bits(REG_B, [("a", "crta"), ("b", "crtb")])),
            None,
            ("I/O ACTIVE", bits(REG_OUT, [("active", "ioactivetb")])),
            ("READY", bits(REG_OUT, [("ready", "readytb")])),
            ("MM RESET", bits(REG_OUT, [("mm1", "mm1reset"), ("mm2", "mm2reset")])),
            ("BFS RUN", bits(REG_OUT, [("bfsrun", "bfsrunout")])),
            ("SYNC", codes(REG_OUT, [SYNC_OUT])),
            ("ID SOURCE", bits(REG_OUT, [("idsrc", "idsource")])),
            ("IPL", bits(REG_OUT, [("ipl", "iplout")])),
        ]
        controls: List[Control] = []
        y = y0
        for entry in layout:
            if y >= bottom:
                break
            if entry is None:
                screen.rule(y, "outputs", width=END)
                y += 1
                continue
            label, make = entry
            controls.append(Label(label, "dim").place(2, y))
            for n in range(1, 6):
                lines = make(links.get(n))
                controls.append(lines.place(LEFT + 1 + (n - 1) * COL + (COL - 1 - lines.width) // 2, y))
                walk[n - 1].extend(lines.groups())
            y += 1
        return controls


    def handle(self, ch: int) -> None:
        if self.cursor.handle(ch):
            return
        if ch == ord("q"):
            self.app.quit()
