#!/usr/bin/env python3
"""What became of one common set run.

Reads the record logs of a run (tools/cs_run.sh) and answers the questions
every run raises: did the joiner find the set, did the member add it, how
long did the set hold, which computer failed the sync first, and how the
inter-computer exchanges were timed.

    tools/cs_report.py <tag> [--dir /tmp/cs]

The exchange figures need the trace records a run makes with
CS_TRACE_BCE=<n> (tools/cs_gpc.sh); without them the join and the failure
are still reported.
"""
import argparse
import glob
import json
import os
import re
import sys

ARM = re.compile(r'receive of (?P<words>\d+) words begins')
ARRIVE = re.compile(r'(?P<words>\d+) words arrive (?P<age>-?\d+) us old')
DONE = re.compile(r'receive complete in (?P<ms>[\d.]+) ms')
WAIT = re.compile(r'#WAT  starved=(?P<starved>\d+) paced=(?P<paced>\d+)')


def read(path):
    out = []
    with open(path) as fh:
        for line in fh:
            try:
                out.append(json.loads(line))
            except ValueError:
                pass
    return out


def quantiles(xs):
    s = sorted(xs)
    return s[0], s[len(s) // 2], s[-1]


def exchanges(records):
    """Every ICC receive, as a dict: when it armed, how old the arrival was,
    how long it waited for the words, how long it took to complete, and the
    turns the wait spent starved and paced from the #WAT that follows."""
    out = []
    open_at = None
    arrived = None
    pending = None
    for rec in records:
        if rec['kind'] != 'trace':
            continue
        text = rec['body'].get('text', '')
        sim = rec['stamp']['simSec'] * 1000.0
        if ARM.search(text):
            open_at, arrived = sim, None
            continue
        if ARRIVE.search(text) and open_at is not None:
            arrived = (sim, int(ARRIVE.search(text).group('age')))
            continue
        m = WAIT.search(text)
        if m and pending is not None:
            pending['starved'] = int(m.group('starved'))
            pending['paced'] = int(m.group('paced'))
            pending = None
            continue
        m = DONE.search(text)
        if m and open_at is not None:
            pending = {'arm': open_at,
                       'age': arrived[1] if arrived else None,
                       'gap': (arrived[0] - open_at) if arrived else None,
                       'done': float(m.group('ms')),
                       'starved': None, 'paced': None}
            out.append(pending)
            open_at, arrived = None, None
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('tag')
    ap.add_argument('--dir', default=os.environ.get('CS_DIR', '/tmp/cs'))
    args = ap.parse_args(argv)

    paths = sorted(glob.glob(os.path.join(args.dir, 'gpc*%s.ndjson' % args.tag)))
    paths = [p for p in paths if not p.endswith('%sbus.ndjson' % args.tag)]
    if not paths:
        sys.stderr.write('cs_report: no logs matching %s/gpc*%s.ndjson\n'
                         % (args.dir, args.tag))
        return 2

    marks = []
    per_gpc = {}
    for path in paths:
        name = 'GPC ' + re.match(r'gpc(\d+)', os.path.basename(path)).group(1)
        recs = read(path)
        per_gpc[name] = recs
        for rec in recs:
            if rec['kind'] == 'logpoint':
                marks.append((rec['stamp']['wallMs'], name, rec['body']['name']))
    marks.sort()
    # The last record of any kind, which is where the run stopped
    # observing: the logpoints end at the add for a set that holds.
    last_wall = max((r['stamp']['wallMs'] for recs in per_gpc.values() for r in recs),
                    default=0)

    print('run %s: %s' % (args.tag, ', '.join(sorted(per_gpc))))

    searches = [m for m in marks if m[2] == 'FCMASYNC']
    adds = [m for m in marks if m[2] == 'FCMSMASK']
    fails = [m for m in marks if m[2] == 'FCMSFAIL']

    if not searches:
        print('  no join attempted: FCMASYNC never reached')
    else:
        w, who, _ = searches[-1]
        print('  %s searched for a set at %s' % (who, when(w)))
        joined = [m for m in adds if m[0] > w and m[1] != who]
        if not joined:
            print('  never added: no partner reached FCMSMASK after the search')
        else:
            aw, awho, _ = joined[0]
            print('  %s added it %.0f ms later' % (awho, aw - w))
            after = [m for m in fails if m[0] >= aw]
            if not after:
                print('  the set was still up when the log ended, %.1f s after the add'
                      % ((last_wall - aw) / 1000.0))
            else:
                fw, fwho, _ = after[0]
                print('  %s failed the sync %.0f ms after the add, about %d cycles'
                      % (fwho, fw - aw, round((fw - aw) / 160.0)))
                rest = [m for m in after[1:] if m[1] != fwho]
                if rest:
                    print('  %s followed %.0f ms later' % (rest[0][1], rest[0][0] - fw))

    for name in sorted(per_gpc):
        rounds = exchanges(per_gpc[name])
        if not rounds:
            continue
        done = [r['done'] for r in rounds]
        gaps = [r['gap'] for r in rounds if r['gap'] is not None]
        ages = [r['age'] for r in rounds if r['age'] is not None]
        starved = [r['starved'] for r in rounds if r['starved'] is not None]
        paced = [r['paced'] for r in rounds if r['paced'] is not None]
        lo, mid, hi = quantiles(done)
        print('  %s: %d ICC receives, complete in %.2f/%.2f/%.2f ms (low/mid/high)'
              % (name, len(done), lo, mid, hi))
        if gaps:
            lo, mid, hi = quantiles(gaps)
            print('       armed %.2f/%.2f/%.2f ms before the words landed' % (lo, mid, hi))
        if ages:
            lo, mid, hi = quantiles(ages)
            print('       arrivals %d/%d/%d us old' % (lo, mid, hi))
        if starved:
            lo, mid, hi = quantiles(starved)
            print('       %d/%d/%d turns with nothing on the bus' % (lo, mid, hi))
        if paced:
            lo, mid, hi = quantiles(paced)
            print('       %d/%d/%d turns paced by the bus rate' % (lo, mid, hi))
    return 0


def when(wall_ms):
    import datetime
    return datetime.datetime.fromtimestamp(wall_ms / 1000.0).strftime('%H:%M:%S.%f')[:-3]


if __name__ == '__main__':
    sys.exit(main())
