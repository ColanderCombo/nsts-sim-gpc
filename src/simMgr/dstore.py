"""Named simulation stores and acknowledged, retried LRU transactions."""
import json
import math
import re
import time
import uuid
from pathlib import Path

_STORE_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_. -]{0,79}\Z")
_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,79}\Z")


class SimulationControl:
    def __init__(self, master):
        self.master = master
        config = master.sup.config
        self.root = Path(config.paths.get("dstore", config.run_file.parent / config.run_file.stem / "dstore"))
        self.mode = "running"
        self.started = time.monotonic()
        self.elapsed = 0.0
        self.at = None
        self.transaction = None

    def seconds(self):
        return self.elapsed + (time.monotonic() - self.started if self.mode == "running" else 0)

    def reset_empty_session(self):
        """Allow a fresh process session after all frozen LRUs have stopped."""
        if self.master.sup.busy() or (self.transaction and self.transaction['status'] == 'pending'):
            return False
        state = self.master.snapshot(include_simulation=False)
        if any(p['alive'] for p in state['processes'].values()) or any(r['available'] for r in state['components']):
            return False
        self.mode = 'running'
        self.started = time.monotonic()
        self.elapsed = 0.0
        self.at = None
        self.transaction = None
        self.master.sup.simulation_frozen = False
        return True

    def path(self, name):
        if not isinstance(name, str) or not _STORE_NAME.fullmatch(name) or name != name.strip() or name.endswith('.dstore'):
            raise ValueError("use a store name of 1–80 letters, digits, spaces, '.', '_' or '-' (without .dstore or leading/trailing spaces)")
        path = self.root / (name + '.dstore')
        if path.is_symlink():
            raise ValueError("store must not be a symbolic link")
        return path

    def stores(self):
        result = []
        for path in sorted(self.root.glob('*.dstore')):
            if path.is_symlink() or not path.is_dir():
                continue
            try:
                manifest = json.loads((path / 'manifest.json').read_text())
                result.append(dict(name=path.name[:-7], complete=manifest.get('complete', False),
                                   time=manifest.get('time'), created=manifest.get('created')))
            except (OSError, ValueError):
                result.append(dict(name=path.name[:-7], complete=False))
        return result

    def restore_manifest(self, name):
        manifest = json.loads((self.path(name) / 'manifest.json').read_text())
        if manifest.get('version') != 2: raise ValueError('unsupported store version')
        if not manifest.get('complete'): raise ValueError('store is incomplete')
        directories = manifest.get('directories')
        if (not isinstance(directories, list) or not directories or
                any(not isinstance(d, str) or any(not _NAME.fullmatch(p) for p in d.split('/')) for d in directories) or
                len(set(directories)) != len(directories)):
            raise ValueError('invalid store LRU directories')
        if not isinstance(manifest.get('time'), (int, float)) or not math.isfinite(manifest['time']):
            raise ValueError('invalid store simulation time')
        return manifest

    def snapshot(self):
        return dict(mode=self.mode, time=self.seconds(), freezeAt=self.at, root=str(self.root),
                    stores=self.stores(), transaction=self.transaction)

    def members(self, allow_empty=False):
        state = self.master.snapshot(include_simulation=False)
        if any(r['available'] and not r['managed'] for r in state['components']):
            raise ValueError('unowned components are active on this simulation bus')
        records = [r for r in state['components'] if r['managed'] and r['available']]
        covered = {r['key'] for r in records}
        missing = [k for k,p in state['processes'].items() if p['alive'] and k not in covered]
        if missing:
            raise ValueError('LRUs have not announced: ' + ', '.join(missing))
        if not records and not allow_empty:
            raise ValueError('no running LRUs')
        if any('freeze' not in r.get('capabilities', []) for r in records):
            raise ValueError('rebuild/restart LRUs to enable simulation control')
        return records

    def command(self, operation, message):
        operation = operation.lower()
        if operation == 'frz': operation = 'freeze'
        if self.transaction and self.transaction['status'] == 'pending':
            raise ValueError('a simulation command is in progress')
        if operation == 'rename_dstore':
            old, new = self.path(message.get('name')), self.path(message.get('new_name'))
            if new.exists(): raise ValueError('store already exists')
            if not old.is_dir(): raise ValueError('unknown store')
            old.rename(new)
            return 'renamed'
        if operation == 'freeze' and message.get('at') is not None:
            at = float(message['at'])
            if self.mode != 'running' or not math.isfinite(at) or at < self.seconds():
                raise ValueError('freeze time must be a future simulation time in seconds')
            self.members()
            self.at = at
            return 'scheduled'
        if operation == 'run' and self.mode == 'running':
            self.at = None
            return 'running'
        if operation == 'freeze' and self.mode == 'frozen': return 'frozen'
        if operation in ('dstore', 'restore') and self.mode != 'frozen':
            raise ValueError('FREEZE the simulation before saving or restoring')
        if operation == 'run' and self.mode not in ('frozen', 'error'):
            raise ValueError('simulation is not frozen')
        if self.master.sup.busy():
            raise ValueError('wait for the current process operation to finish')
        records = self.members(allow_empty=operation == 'run')
        tx = dict(id=uuid.uuid4().hex, operation=operation, phase=operation, status='pending',
                  started=time.time(), deadline=time.monotonic() + 30, sent=0, members={})
        keys = set()
        for record in records:
            key = record['key']
            # A process may embed multiple units. Each still owns a directory.
            directory = key if sum(r['key'] == key for r in records) == 1 else key + '/' + record['id'].lower()
            if any(not _NAME.fullmatch(part) for part in directory.split('/')) or directory in keys:
                raise ValueError('LRU directory identity is invalid or duplicated')
            keys.add(directory)
            tx['members'][record['instance']] = dict(key=key, lru=record['id'], directory=directory, status='pending')
        if operation in ('dstore', 'restore'):
            if any(r.get('checkpointVersion') != 2 for r in records):
                raise ValueError('rebuild/restart LRUs for portable version 2 checkpoints')
            path = self.path(message.get('name'))
            tx.update(name=message['name'], path=str(path), time=self.seconds())
            if operation == 'dstore':
                path.mkdir(parents=True, exist_ok=False)
                self.write_manifest(tx, False)
            else:
                manifest = self.restore_manifest(message['name'])
                if sorted(manifest['directories']) != sorted(keys): raise ValueError('store LRU configuration differs')
                tx['time'] = manifest['time']
                tx['phase'] = 'validate'
        if operation == 'freeze':
            self.elapsed = self.seconds()
            self.mode = 'freezing'
            self.master.sup.simulation_frozen = True
            self.at = None
        elif operation == 'run': self.mode = 'resuming'
        self.transaction = tx
        self.tick()
        return dict(accepted=tx['id'])

    def write_manifest(self, tx, complete):
        path = Path(tx['path'])
        data = dict(version=2, complete=complete, time=tx['time'], created=tx['started'],
                    directories=sorted(m['directory'] for m in tx['members'].values()), members=tx['members'])
        temporary = path / 'manifest.json.tmp'
        temporary.write_text(json.dumps(data, indent=2))
        temporary.replace(path / 'manifest.json')

    def receive(self, message):
        tx = self.transaction
        if not tx or tx['status'] != 'pending' or message.get('master') != self.master.id: return
        if message.get('command') != tx['id'] + ':' + tx['phase']: return
        member = tx['members'].get(message.get('instance'))
        if not member or message.get('status') not in ('received', 'completed', 'failed'): return
        if member['status'] in ('completed', 'failed'): return
        member.update(status=message['status'], error=message.get('error'), acknowledged=True)
        if message['status'] == 'received': member['acknowledged'] = True
        self.tick()

    def tick(self):
        if self.at is not None and self.seconds() >= self.at:
            self.at = None
            try: self.command('freeze', {})
            except Exception as exc:
                self.master.sup.say('scheduled FREEZE failed: ' + str(exc))
        tx = self.transaction
        if not tx or tx['status'] != 'pending': return
        now = time.monotonic()
        if now >= tx['deadline']:
            for member in tx['members'].values():
                if member['status'] not in ('completed', 'failed'):
                    member.update(status='failed', error='LRU command timed out')
        if (all(m['status'] in ('completed', 'failed') for m in tx['members'].values())
                and any(m['status'] == 'failed' for m in tx['members'].values())):
            tx['status'] = 'failed'
            if tx['operation'] in ('freeze', 'run') or tx['phase'] == 'restore': self.mode = 'error'
            if tx['operation'] == 'dstore': self.write_manifest(tx, False)
            self.master.sup.say('%s failed; inspect the SIMULATION pane' % tx['operation'].upper())
            return
        if all(m['status'] == 'completed' for m in tx['members'].values()):
            if tx['phase'] == 'validate':
                tx.update(phase='restore', sent=0, deadline=now + 30)
                for member in tx['members'].values(): member['status'] = 'pending'
            else:
                tx['status'] = 'completed'
                if tx['operation'] == 'freeze': self.mode = 'frozen'
                elif tx['operation'] == 'run':
                    self.started = now
                    self.mode = 'running'
                    self.master.sup.simulation_frozen = False
                elif tx['operation'] == 'restore': self.elapsed = tx['time']
                elif tx['operation'] == 'dstore':
                    try:
                        self.write_manifest(tx, True)
                    except OSError as exc:
                        tx.update(status='failed', error='cannot complete store manifest: ' + str(exc))
                        self.master.sup.say(tx['error'])
                        return
                self.master.sup.say('%s completed' % tx['operation'].upper())
                return
        if now - tx['sent'] < 0.5: return
        tx['sent'] = now
        for instance, member in tx['members'].items():
            if member['status'] in ('completed', 'failed'): continue
            self.master.local.send(dict(v=1, type='command', master=self.master.id,
                instance=instance, command=tx['id'] + ':' + tx['phase'], operation=tx['phase'],
                snapshot=tx['id'], directory=str(Path(tx.get('path', '.')) / member['directory'])))
