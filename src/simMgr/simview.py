"""Simulation clock and named datastore controls in the manager's right pane."""
import curses
from .controls import Cursor, Label, Pushbutton, Stack
from .screen import ScreenRegion


class SimulationView:
    def __init__(self, app):
        self.app = app
        self.cursor = Cursor()
        self.selected = None
        self.scroll = 0

    def command(self, op, **parameters):
        self.app.sup.sim_command(op, **parameters)

    def save(self):
        name = self.app.text_input('DSTORE name')
        if name:
            self.command('dstore', name=name)
        elif name is not None:
            self.app.sup.simulation_error = 'Store not saved: enter a name.'

    def rename(self):
        name = self.app.text_input('Rename %s to' % self.selected)
        if name: self.command('rename_dstore', name=self.selected, new_name=name)

    def schedule(self):
        value = self.app.text_input('FREEZE at simulation seconds')
        if value:
            try: self.command('freeze', at=float(value))
            except ValueError: self.app.sup.say('enter simulation time in seconds')

    def select(self, name):
        self.selected = name

    def draw(self, screen):
        self.app.title_bar(screen, 'SIMULATION')
        state = getattr(self.app.sup, 'simulation', {}) or {}
        stores = state.get('stores', [])
        if self.selected not in [s['name'] for s in stores]:
            self.selected = stores[0]['name'] if stores else None
        mode = state.get('mode', 'unavailable')
        pending = state.get('transaction') or {}
        supported = bool(state)
        busy = not supported or pending.get('status') == 'pending'
        controls = [Label('%s   %.3f s' % (mode.upper(), state.get('time', 0)), bold=True),
                    Pushbutton('FRZ', lambda: self.command('freeze'), not busy),
                    Pushbutton('RUN', lambda: self.command('run'), not busy),
                    Pushbutton('FREEZE AT...', self.schedule, mode == 'running' and not busy),
                    Pushbutton('DSTORE...', self.save, mode == 'frozen' and not busy),
                    Pushbutton('RESTORE', lambda: self.command('restore', name=self.selected),
                               mode == 'frozen' and not busy and any(s['name'] == self.selected and s['complete'] for s in stores)),
                    Pushbutton('RENAME...', self.rename, bool(self.selected) and not busy)]
        error = getattr(self.app.sup, 'simulation_error', None)
        if error: controls.append(Label(error, colour='warn'))
        failures = [m for m in pending.get('members', {}).values() if m.get('status') == 'failed']
        if failures:
            controls.append(Label('%s failed (%s)' % (pending.get('operation', '').upper(), pending.get('phase', '')), colour='warn', bold=True))
            for member in failures:
                controls.append(Label('%s: %s' % (member['lru'], member.get('error') or 'command failed'), colour='warn'))
        if not supported:
            controls.append(Label('Restart the background manager', colour='warn'))
            controls.append(Label('to enable simulation control.', colour='warn'))
        if state.get('freezeAt') is not None: controls.append(Label('Freeze at %.3f s' % state['freezeAt']))
        divider = '-' * max(1, screen.w - 4)
        controls.extend([Label(''), Label(''), Label(divider, colour='dim'),
                         Label('Named stores', bold=True), Label('')])
        if supported and not stores:
            controls.append(Label('No saved stores. Use DSTORE to save one.'))
        elif stores and mode != 'frozen':
            controls.append(Label('FRZ to enable RESTORE.'))
        elif stores and not busy and not any(s['name'] == self.selected and s['complete'] for s in stores):
            controls.append(Label('RESTORE unavailable: selected save is incomplete.', colour='warn'))
        for store in stores:
            name = store['name']
            label = ('> ' if name == self.selected else '  ') + name + ('' if store['complete'] else ' (incomplete)')
            controls.append(Pushbutton(label, lambda name=name: self.select(name)))
        controls.extend([Label(divider, colour='dim'), Label(''), Label(''), Label(''),
                         Label('Command log', bold=True), Label('')])
        if pending:
            controls.append(Label('%s: %s' % (pending['operation'].upper(), pending['status']), bold=True))
            if pending.get('error'): controls.append(Label(pending['error'], colour='warn'))
            for member in sorted(pending['members'].values(), key=lambda m: (m['status'] != 'failed', m['status'] == 'completed')):
                controls.append(Label('%s: %s' % (member['lru'], member['status'])))
                if member.get('error'):
                    controls.append(Label(member['error'], colour='warn'))
        height = max(1, screen.h - 6)
        region = ScreenRegion(screen, 2, 0, height, screen.w)
        layout = Stack(controls, align='left').place(2, -self.scroll)
        self.cursor.take([layout.groups()])
        self.scroll = max(0, min(self.scroll, layout.height - height))
        layout.place(2, -self.scroll)
        layout.draw(region)
        self.cursor.draw(region)
        screen.put(screen.h - 3, 2, screen.clip(state.get('root', ''), screen.w - 4), screen.attr('dim'))
        screen.put(screen.h - 2, 2, 'PgUp/PgDn scroll', screen.attr('dim'))

    def handle(self, key):
        if key == ord('q'): self.app.quit()
        elif key == curses.KEY_NPAGE: self.scroll += 8
        elif key == curses.KEY_PPAGE: self.scroll = max(0, self.scroll - 8)
        else:
            self.cursor.handle(key)
            current = self.cursor.current
            if current:
                height = max(1, self.app.screen.h - 6)
                if current.y < 0: self.scroll = max(0, self.scroll + current.y)
                elif current.y >= height: self.scroll += current.y - height + 1
