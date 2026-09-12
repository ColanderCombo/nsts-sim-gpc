"""Survey simulator processes by base port and flag duplicate identities.

Process-table inspection also finds manually started and orphaned sessions
outside the supervisor's state.
"""

from __future__ import annotations

import os
import re
import subprocess
from collections import defaultdict
from typing import Dict, List, NamedTuple, Optional

from .config import DEFAULT_BASE_PORT

#: The bundles esbuild builds, which is what a simulator process runs.
BUNDLES = ('gpc', 'gpcmd', 'mmu', 'mdm', 'mtu', 'nsp', 'pcmmu', 'adc', 'ddu', 'idp')
BUNDLE = re.compile(r'dist/(%s)\.js\b' % '|'.join(BUNDLES))
BASE_PORT_ARG = re.compile(r'--base-port[= ](\d+)')
BASE_PORT_ENV = re.compile(r'\bNSTS_BASE_PORT=(\d+)')
#: What distinguishes two processes of the same bundle.
SELECTOR = re.compile(r'--(?:unit|units|gpc)[= ](\S+)')
#: `ps -E` runs the environment on after the arguments with no separator;
#: the first NAME=value word is where the arguments end.
ENV_WORD = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*=')
#: Subcommands that open a connection and answer nothing.  A run has one
#: of these per computer it drives, and they share an identity.
CLIENTS = ('dbg-client',)


class Process(NamedTuple):
    pid: int
    started: str
    base: int
    ident: str
    args: str


def _ps() -> List[str]:
    """One line a process: pid, start time, arguments and environment."""
    out = subprocess.run(['ps', '-eEwwo', 'pid=,lstart=,args='],
                         capture_output=True, text=True)
    return out.stdout.splitlines()


def identity(args: str, bundle: str) -> str:
    tail = []
    for word in args.split('dist/%s.js' % bundle, 1)[1].split():
        break_ = ENV_WORD.match(word)
        if break_:
            break
        tail.append(word)
    words = []
    previous = ''
    for word in tail:
        # A word after an option is that option's value, not a name.
        if not word.startswith('-') and not previous.startswith('-'):
            words.append(word)
        previous = word
    sel = SELECTOR.search(args)
    unit = sel.group(1) if sel else (words[1] if len(words) > 1 else '')
    return ' '.join(x for x in (bundle, words[0] if words else '', unit) if x)


def survey(lines: Optional[List[str]] = None) -> List[Process]:
    found = []
    for line in (lines if lines is not None else _ps()):
        fields = line.split(None, 6)
        if len(fields) < 7:
            continue
        pid, started, args = int(fields[0]), ' '.join(fields[1:6]), fields[6]
        if os.path.basename(args.split()[0]) not in ('node', 'electron'):
            continue
        m = BUNDLE.search(args)
        if not m:
            continue
        port = BASE_PORT_ARG.search(args) or BASE_PORT_ENV.search(args)
        base = int(port.group(1)) if port else DEFAULT_BASE_PORT
        found.append(Process(pid, started, base, identity(args, m.group(1)), args))
    return found


def duplicates(procs: List[Process]) -> Dict[tuple, List[Process]]:
    """Identities more than one process answers to, by (base port, identity)."""
    byname: Dict[tuple, List[Process]] = defaultdict(list)
    for p in procs:
        words = p.ident.split()
        if len(words) > 1 and words[1] in CLIENTS:
            continue
        byname[(p.base, p.ident)].append(p)
    return {k: v for k, v in byname.items() if len(v) > 1}


def report(procs: Optional[List[Process]] = None) -> int:
    """Print the survey; the status is the number of duplicated identities."""
    procs = survey() if procs is None else procs
    if not procs:
        print('no simulator processes running')
        return 0
    dups = duplicates(procs)
    bases = sorted({p.base for p in procs})
    for base in bases:
        here = sorted((p for p in procs if p.base == base), key=lambda p: p.ident)
        print('base port %d: %d process(es)' % (base, len(here)))
        width = max(len(p.ident) for p in here)
        for p in here:
            mark = '**' if (base, p.ident) in dups else '  '
            print('  %s %-*s  pid %-7d %s' % (mark, width, p.ident, p.pid, p.started))
    for (base, ident), group in sorted(dups.items()):
        print('** %d processes answer as %s on base %d: %s'
              % (len(group), ident, base,
                 ', '.join('%d (%s)' % (p.pid, p.started) for p in group)))
    return len(dups)
