"""Startup checkpoint restore, advanced by the CLI while it follows output."""
import time


class StartupRestore:
    def __init__(self, master, name, resume=False, timeout=300):
        self.master, self.name, self.resume = master, name, resume
        manifest = master.simulation.restore_manifest(name)
        self.directories = set(manifest['directories'])
        self.keys = {d.split('/')[0] for d in self.directories}
        missing = self.keys - master.sup.procs.keys()
        if missing:
            raise ValueError('store LRUs are not configured: ' + ', '.join(sorted(missing)))
        self.deadline = time.monotonic() + timeout
        self.phase = 'startup'
        self.command_id = None
        self.waiting = 'process startup'

    def tick(self):
        """Return True when restored; raise with diagnostics on failure."""
        with self.master._lock:
            control = self.master.simulation
            if time.monotonic() >= self.deadline:
                raise ValueError('startup restore timed out during %s: %s' % (self.phase, self.waiting))
            if self.phase == 'startup':
                if self.master.sup.busy(): return False
                state = self.master.snapshot(include_simulation=False)
                stopped = [k for k in self.keys if not state['processes'][k]['alive']]
                if stopped:
                    self.waiting = 'waiting for processes: ' + ', '.join(sorted(stopped))
                    failed = [k for k in stopped if state['processes'][k]['state'] in ('failed', 'exited')]
                    if failed:
                        raise ValueError('checkpoint LRUs failed to start: ' + ', '.join(sorted(failed)))
                    return False
                records = [r for r in state['components'] if r['managed'] and r['available']]
                directories = {r['key'] if sum(s['key'] == r['key'] for s in records) == 1
                               else r['key'] + '/' + r['id'].lower() for r in records}
                if directories != self.directories:
                    self.waiting = 'component mismatch; missing=%s, extra=%s' % (
                        sorted(self.directories - directories), sorted(directories - self.directories))
                    return False
                operation = 'freeze'
            else:
                tx = control.transaction
                if not tx or tx['id'] != self.command_id:
                    raise ValueError('startup restore interrupted by another simulation command')
                if tx['status'] == 'pending': return False
                if tx['status'] != 'completed':
                    errors = ['%s: %s' % (m['directory'], m.get('error', 'failed'))
                              for m in tx['members'].values() if m['status'] == 'failed']
                    raise ValueError(self.phase + ' failed: ' + '; '.join(errors))
                if self.phase == 'freeze': operation = 'restore'
                elif self.phase == 'restore' and self.resume: operation = 'run'
                else: return True
            result = control.command(operation, {'name': self.name})
            if not isinstance(result, dict) or 'accepted' not in result:
                raise ValueError('startup restore interrupted: ' + operation + ' was already applied')
            self.command_id = result['accepted']
            self.phase = operation
            self.waiting = 'waiting for LRU acknowledgements'
            return False
