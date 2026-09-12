"""The panels, from config/panels.

One file a panel.  `panel` is the name the orbiter gives it, `controls`
maps each control ID to what it is, and `groups` says how the frontend
lays them out.

    panel: F6
    name: Commander's forward flight instruments
    groups:
      - title: ADI
        controls: [S3, S4, S5]
    controls:
      S3:
        kind: rotary
        label: ADI ATTITUDE
        positions: [INRTL, LVLH, REF]
        at: INRTL

KINDS

  switch      positions, held where it is put
  breaker     a circuit breaker: CLOSED or OPEN, with `amps` the rating
  rotary      the same, drawn as a stack of positions
  momentary   a switch that springs back to `at` from the positions in
              `spring`, `hold` seconds later
  pushbutton  a button: on while it is pressed, `hold` seconds; `face`
              is what is written on it
  thumbwheel  a number from `range`
  light       an indicator, on or off
  talkback    an indicator carrying a legend: the positions, with `gray`
              for the blank drum and `barberpole` for the diagonals
  meter       an indicator carrying a number, in `units` over `range`

The crew works the first six; the last three are driven from the busses
and the panel shows what it is told.  A control the panel holds publishes
its position and answers a REQUEST for it; an indicator is asked for once
at the start and then followed.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional

import yaml

from .bus import BARBERPOLE, ENUM, GRAY, LOGIC, REAL, WORD


class Loader(yaml.SafeLoader):
    """Preserve ON, OFF, YES, and NO as panel-label strings, not YAML booleans."""


Loader.yaml_implicit_resolvers = {
    first: [(tag, pattern) for tag, pattern in resolvers
            if tag != "tag:yaml.org,2002:bool"]
    for first, resolvers in yaml.SafeLoader.yaml_implicit_resolvers.items()
}
Loader.add_implicit_resolver(
    "tag:yaml.org,2002:bool",
    re.compile(r"^(?:true|True|TRUE|false|False|FALSE)$"), list("tTfF"))

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent.parent                # the simulator tree

CREW_KINDS = ("switch", "breaker", "rotary", "momentary", "pushbutton", "thumbwheel")
INDICATOR_KINDS = ("light", "talkback", "meter")
KINDS = CREW_KINDS + INDICATOR_KINDS

#: What each kind carries on the bus.
KIND_VALUE = {
    "switch": ENUM, "breaker": ENUM, "rotary": ENUM, "momentary": ENUM,
    "pushbutton": LOGIC, "thumbwheel": WORD,
    "light": LOGIC, "talkback": ENUM, "meter": REAL,
}

DEFAULT_HOLD = 0.3

#: A circuit breaker's two positions: pushed in and pulled out.
CLOSED = "CLOSED"
OPEN = "OPEN"
BREAKER_POSITIONS = [CLOSED, OPEN]


class CatalogError(Exception):
    """A panel file is wrong.  The message names the file and the key."""


@dataclass
class Control:
    id: str
    kind: str
    label: str = ""
    positions: List[str] = field(default_factory=list)
    at: Optional[str] = None                    # where it rests
    spring: List[str] = field(default_factory=list)
    hold: float = DEFAULT_HOLD
    face: str = ""                              # what a pushbutton reads
    amps: Optional[float] = None                # a breaker's rating
    units: str = ""
    range: Optional[List[float]] = None
    note: str = ""
    panel: str = ""

    @property
    def key(self) -> str:
        return "%s/%s" % (self.panel, self.id)

    @property
    def value_kind(self) -> int:
        return KIND_VALUE[self.kind]

    @property
    def crew(self) -> bool:
        """The crew works it, so this panel holds where it is."""
        return self.kind in CREW_KINDS

    @property
    def rest(self):
        """What it reads before anything says otherwise."""
        if self.value_kind == ENUM:
            if self.at:
                return self.at
            # An indicator with nothing behind it reads barberpole.
            if not self.crew and self.position(BARBERPOLE):
                return self.position(BARBERPOLE)
            return self.positions[0] if self.positions else GRAY
        if self.value_kind == LOGIC:
            return False
        if self.value_kind == REAL:
            return float(self.range[0]) if self.range else 0.0
        return int(self.at or 0)

    @property
    def title(self) -> str:
        return self.label or self.id

    def position(self, text) -> Optional[str]:
        want = str(text or "").strip().lower()
        for p in self.positions:
            if p.lower() == want:
                return p
        return None


@dataclass
class Group:
    title: str
    controls: List[Control]


@dataclass
class Panel:
    name: str                                   # F6, O6, C3
    title: str
    file: Path
    controls: Dict[str, Control]
    groups: List[Group]

    def control(self, cid: str) -> Optional[Control]:
        return self.controls.get(cid)

    @property
    def crew(self) -> List[Control]:
        return [c for c in self.controls.values() if c.crew]

    @property
    def indicators(self) -> List[Control]:
        return [c for c in self.controls.values() if not c.crew]


def default_dir() -> Path:
    return Path(os.environ.get("NSTS_PANEL_DIR") or ROOT / "config" / "panels")


def _read(path: Path) -> Panel:
    where = path.name
    try:
        doc = yaml.load(path.read_text(), Loader) or {}
    except yaml.YAMLError as exc:
        raise CatalogError("%s: %s" % (where, exc)) from None
    if not isinstance(doc, dict):
        raise CatalogError("%s: the file is not a mapping" % where)
    name = str(doc.get("panel") or "").strip()
    if not name:
        raise CatalogError("%s: no `panel` name" % where)

    controls: Dict[str, Control] = {}
    raw = doc.get("controls") or {}
    if not isinstance(raw, dict):
        raise CatalogError("%s: `controls` maps a number to a control" % where)
    for cid, spec in raw.items():
        cid = str(cid)
        spec = spec or {}
        kind = str(spec.get("kind") or "").lower()
        if kind not in KINDS:
            raise CatalogError("%s: %s is '%s'; the kinds are %s"
                               % (where, cid, kind, ", ".join(KINDS)))
        positions = [str(p) for p in (spec.get("positions") or [])]
        if KIND_VALUE[kind] == ENUM and not positions:
            if kind == "talkback":
                positions = [GRAY, BARBERPOLE]
            elif kind == "breaker":
                positions = list(BREAKER_POSITIONS)
            else:
                raise CatalogError("%s: %s is a %s with no positions" % (where, cid, kind))
        at = spec.get("at")
        at = str(at) if at is not None else None
        folded = {p.lower(): p for p in positions}
        if at is not None and positions and KIND_VALUE[kind] == ENUM:
            if at.lower() not in folded:
                raise CatalogError("%s: %s rests at '%s', which is not one of %s"
                                   % (where, cid, at, ", ".join(positions)))
            at = folded[at.lower()]
        spring = []
        for p in (spec.get("spring") or []):
            if str(p).lower() not in folded:
                raise CatalogError("%s: %s springs from '%s', which is not one of %s"
                                   % (where, cid, p, ", ".join(positions)))
            spring.append(folded[str(p).lower()])
        rng = spec.get("range")
        if rng is not None:
            try:
                rng = [float(rng[0]), float(rng[1])]
            except (TypeError, IndexError, ValueError):
                raise CatalogError("%s: %s has a range of two numbers" % (where, cid)) from None
        controls[cid] = Control(
            id=cid, kind=kind, label=str(spec.get("label") or ""),
            positions=positions, at=at, spring=spring,
            hold=float(spec.get("hold") or DEFAULT_HOLD),
            face=str(spec.get("face") or ""),
            amps=(float(spec["amps"]) if spec.get("amps") is not None else None),
            units=str(spec.get("units") or ""), range=rng,
            note=str(spec.get("note") or ""), panel=name)

    groups: List[Group] = []
    seen = set()
    for g in doc.get("groups") or []:
        ids = [str(c) for c in (g.get("controls") or [])]
        for cid in ids:
            if cid not in controls:
                raise CatalogError("%s: group '%s' names %s, which the panel has no control for"
                                   % (where, g.get("title", ""), cid))
        seen.update(ids)
        groups.append(Group(title=str(g.get("title") or ""),
                            controls=[controls[c] for c in ids]))
    rest = [c for cid, c in controls.items() if cid not in seen]
    if rest:
        groups.append(Group(title="", controls=rest))

    return Panel(name=name, title=str(doc.get("name") or ""), file=path,
                 controls=controls, groups=groups)


def load(where: Optional[Path] = None) -> Dict[str, Panel]:
    """Every panel in a directory, by name."""
    where = Path(where or default_dir())
    if not where.is_dir():
        raise CatalogError("%s is not a directory of panels" % where)
    out: Dict[str, Panel] = {}
    for path in sorted(where.glob("*.yml")) + sorted(where.glob("*.yaml")):
        panel = _read(path)
        if panel.name in out:
            raise CatalogError("%s: panel %s is also in %s"
                               % (path.name, panel.name, out[panel.name].file.name))
        out[panel.name] = panel
    return out
