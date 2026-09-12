#!/usr/bin/env python3
"""Merge two computers' logs by host time around an anchor event.

    tools/timeline.py <tag> [--dir /tmp/cs] [--anchor TEXT] [--gpc 4]
                            [--before 400] [--after 200] [--kinds ...]

Input names are gpc<n><tag>.ndjson and gpc<n><tag>bus.ndjson.
"""
import argparse
import glob
import json
import os
import re
import sys

KINDS = ('discrete', 'logpoint', 'trace', 'bus')


def logs(directory, tag):
    out = []
    for path in sorted(glob.glob(os.path.join(directory, 'gpc*%s.ndjson' % tag))):
        m = re.match(r'gpc(\d+)%s\.ndjson$' % re.escape(tag), os.path.basename(path))
        if m:
            out.append(('G' + m.group(1), path))
    for path in sorted(glob.glob(os.path.join(directory, 'gpc*%sbus.ndjson' % tag))):
        m = re.match(r'gpc(\d+)%sbus\.ndjson$' % re.escape(tag), os.path.basename(path))
        if m:
            out.append(('G' + m.group(1), path))
    return out


def rows(name, path, kinds):
    out = []
    burst = None

    def flush():
        if burst:
            out.append((burst['w0'], name,
                        '%10.4f-%.4f BUS %s %s %d words over %d ms wall'
                        % (burst['s0'], burst['s1'], burst['bus'], burst['dir'],
                           burst['n'], burst['w1'] - burst['w0'])))

    with open(path) as fh:
        for line in fh:
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            kind, stamp, body = rec['kind'], rec['stamp'], rec.get('body', {})
            if kind not in kinds:
                continue
            wall, sim = stamp['wallMs'], stamp['simSec']
            if kind == 'bus':
                key = (body['bus'], body['dir'])
                if burst and (burst['bus'], burst['dir']) == key and wall - burst['w1'] <= 6:
                    burst['n'] += 1
                    burst['w1'], burst['s1'] = wall, sim
                    continue
                flush()
                burst = {'bus': body['bus'], 'dir': body['dir'], 'n': 1,
                         'w0': wall, 'w1': wall, 's0': sim, 's1': sim}
                continue
            if kind == 'discrete':
                what = '%s %s' % (body['register'], ' '.join(body['changed']))
                if body.get('sync'):
                    what += '   [%s]' % body['sync']
            elif kind == 'logpoint':
                what = 'LOGPOINT ' + body['name']
            else:
                what = body.get('text', json.dumps(body))
            out.append((wall, name, '%10.4f %s' % (sim, what)))
    flush()
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('tag', help='the run tag the logs are named for')
    ap.add_argument('--dir', default=os.environ.get('CS_DIR', '/tmp/cs'))
    ap.add_argument('--anchor', default='FCMSFAIL',
                    help='logpoint or trace text the window is centred on (default: FCMSFAIL)')
    ap.add_argument('--gpc', help='which computer the anchor is taken from')
    ap.add_argument('--nth', type=int, default=1, help='which occurrence of the anchor (default: 1)')
    ap.add_argument('--before', type=float, default=400, help='milliseconds before it')
    ap.add_argument('--after', type=float, default=200, help='milliseconds after it')
    ap.add_argument('--kinds', default=','.join(KINDS))
    args = ap.parse_args(argv)

    kinds = tuple(k for k in args.kinds.split(',') if k)
    found = logs(args.dir, args.tag)
    if not found:
        sys.stderr.write('timeline: no logs matching %s/gpc*%s.ndjson\n' % (args.dir, args.tag))
        return 2

    merged = []
    for name, path in found:
        merged.extend(rows(name, path, kinds))
    merged.sort()

    want = 'G' + str(args.gpc) if args.gpc else None
    hits = [w for w, g, t in merged
            if args.anchor in t and (want is None or g == want)]
    if not hits:
        sys.stderr.write('timeline: %s never appears%s\n'
                         % (args.anchor, ' on ' + want if want else ''))
        return 1
    t0 = hits[min(args.nth, len(hits)) - 1]

    for wall, name, text in merged:
        if t0 - args.before <= wall <= t0 + args.after:
            print('%7.3fs %s %s' % ((wall - t0) / 1000.0, name, text))
    return 0


if __name__ == '__main__':
    sys.exit(main())
