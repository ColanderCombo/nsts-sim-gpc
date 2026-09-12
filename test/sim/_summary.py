import curses
import time
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

from simMgr.controlbus import LEASE
from simMgr.process import LogLine, State
from simMgr.screen import Glyphs, Screen, ScreenRegion
from simMgr.overview import Overview
from simMgr.gpcview import GpcView
from simMgr.summary import (BusView, LogView, OperationsView, SummaryView,
                            communicating, communication_glyph, grouped_columns,
                            simulation_status)
from simMgr.tui import App
from simMgr.simview import SimulationView


class Window:
    def __init__(self, height, width):
        self.height, self.width = height, width
        self.writes = []

    def getmaxyx(self):
        return self.height, self.width

    def addstr(self, row, column, text, attr):
        assert 0 <= row < self.height and 0 <= column < self.width
        assert column + len(text) <= self.width
        self.writes.append((row, column, text, attr))


class Display(Screen):
    def __init__(self, height=24, width=100, ascii_only=True):
        self.win = Window(height, width)
        self.g = Glyphs(ascii_only)

    def attr(self, name="plain", **flags):
        return name, flags


class Process:
    def __init__(self, kind, state=State.STOPPED, health="unknown"):
        self.lru = SimpleNamespace(lru=kind, kind=kind)
        self.state, self.health = state, health
        self.pid = 123 if state is State.RUNNING else None
        self.log_seq = 0
        self.watch_logs = False

    def log_lines(self):
        self.watch_logs = True
        return [LogLine(time.time(), "log line %d" % index, "out") for index in range(30)]


class SummaryTest(unittest.TestCase):
    def setUp(self):
        self.sup = SimpleNamespace(
            attached=True, config=SimpleNamespace(name="test orbiter"),
            procs={"gpc1": Process("gpc"), "imu1": Process("imu", State.RUNNING, "up"),
                   "gpc2": Process("gpc", State.FAILED, "down")},
            order=["gpc1", "imu1", "gpc2"], components=[], connected=True,
            master_info={"startedAt": time.time()},
            last_update=time.monotonic(), activity="", message="", busy=lambda: False,
            start=Mock(), stop=Mock(), restart=Mock(), kill=Mock())
        self.app = App(self.sup)
        self.app.screen = Display()
        self.app.main = self.app.view = SummaryView(self.app)
        self.app.pages = [("SUMMARY", self.app.main)]
        self.app.confirm = Mock(return_value=True)

    def record(self):
        return dict(key="imu1", pid=123, managed=True, available=True, age=0,
                    instance="imu-instance", buses=[])

    def test_screen_region_clipping(self):
        screen = Display(12, 30)
        region = ScreenRegion(screen, 2, 7, 5, 8)
        self.assertEqual(region.put(0, -2, "abcdefghijkl"), 8)
        self.assertEqual(screen.win.writes[-1][:3], (2, 7, "cdefghij"))
        region.fill(1, char=".")
        self.assertEqual(screen.win.writes[-1][:3], (3, 7, "........"))
        count = len(screen.win.writes)
        region.put(-1, 0, "hidden")
        region.put(5, 0, "hidden")
        region.put(0, 8, "hidden")
        self.assertEqual(len(screen.win.writes), count)

    def test_overview_navigation_and_resize(self):
        self.sup.config.lrus = []
        self.app._idp_links = Mock(driven=set(), error="")
        self.app._idp_links.connected.return_value = False
        self.app._idp_links.positions.return_value = None
        overview = Overview(self.app)
        self.app.main = self.app.view = overview
        self.app.pages = [("SUMMARY", overview)]
        self.app.screen = Display(42, 240)
        overview.draw(self.app.screen)
        divider = overview.regions(self.app.screen)[0].w
        writes = self.app.screen.win.writes
        self.assertEqual(sum(text == " SIM " for _, _, text, _ in writes), 1)
        self.assertTrue(any(text.strip() == "gpc1" and column < divider for _, column, text, _ in writes))
        self.assertTrue(any("IPL SOURCE" in text and column > divider for _, column, text, _ in writes))
        self.app.screen = Display(54, 186)
        overview.draw(self.app.screen)
        left, right = overview.regions(self.app.screen)
        self.assertIsNotNone(left)
        self.assertIsNotNone(right)
        self.assertEqual(left.w, 40)
        self.assertEqual(right.w, 145)
        writes = self.app.screen.win.writes
        self.assertTrue(any("QUIT" in text and row == 2 for row, _, text, _ in writes))
        self.assertTrue(any("IDP/CRT SEL" in text and column > left.w for _, column, text, _ in writes))
        overview.handle(curses.KEY_F7)
        self.assertTrue(all(region is not None for region in overview.regions(self.app.screen)))
        overview.handle(curses.KEY_F7)
        overview.handle(10)
        self.assertIsInstance(self.app.view, OperationsView)
        self.app.view.draw(self.app.screen)
        self.app.view.handle(27)
        self.assertIs(self.app.view, overview)
        overview.handle(curses.KEY_RIGHT)
        overview.handle(curses.KEY_RIGHT)
        overview.handle(10)
        self.assertIsInstance(overview.right_view, BusView)
        overview.draw(self.app.screen)
        overview.handle(27)
        self.assertIs(self.app.view, overview)
        overview.handle(curses.KEY_RIGHT)
        overview.handle(10)
        self.assertIsInstance(overview.right_view, LogView)
        overview.draw(self.app.screen)
        overview.handle(27)
        self.assertIs(overview.right_view, overview.gpc)
        self.assertFalse(self.sup.procs["gpc1"].watch_logs)
        with patch.object(overview.gpc, "handle") as handler:
            overview.handle(curses.KEY_F7)
            overview.handle(curses.KEY_DOWN)
            handler.assert_called_once_with(curses.KEY_DOWN)
        for height, width in ((24, 100), (8, 25), (2, 8), (54, 186), (42, 240)):
            self.app.screen = Display(height, width)
            overview.draw(self.app.screen)
            overview.handle(curses.KEY_F7)
            overview.draw(self.app.screen)
            overview.handle(curses.KEY_F7)
        overview.handle(curses.KEY_F7)
        self.assertEqual(overview.summary.selected, "gpc1")
        self.assertEqual(overview.summary.field, 3)

    def test_old_manager_simulation_controls(self):
        self.sup.simulation = None
        view = SimulationView(self.app)
        view.draw(self.app.screen)
        cells = [cell for column in view.cursor.columns for group in column for cell in group.cells]
        self.assertFalse(any(cell.live for cell in cells))
        from simMgr.remote import RemoteSupervisor
        remote = RemoteSupervisor.__new__(RemoteSupervisor)
        remote.simulation = {}
        remote.client = Mock()
        remote.sim_command('freeze')
        remote.client.call.assert_not_called()
        self.assertIn('Restart the background manager', remote.message)

    def test_restore_failure_shown_first(self):
        self.sup.simulation = dict(mode='frozen', stores=[], transaction=dict(
            operation='restore', phase='validate', status='failed', members={
                **{str(i): dict(lru='GPC%d' % i, status='completed') for i in range(45)},
                'crt': dict(lru='CRT1', status='failed', error='storage size changed')}))
        view = SimulationView(self.app)
        view.draw(self.app.screen)
        writes = self.app.screen.win.writes
        errors = [row for row, _, text, _ in writes if 'CRT1: storage size changed' in text]
        self.assertTrue(errors, 'failure must be visible without scrolling')
        self.assertLess(min(errors), 12)
        completed = [row for row, _, text, _ in writes if 'GPC0: completed' in text]
        if completed: self.assertLess(min(errors), min(completed))

    def test_save_feedback(self):
        from simMgr.remote import RemoteSupervisor
        remote = RemoteSupervisor.__new__(RemoteSupervisor)
        remote.simulation = {'mode': 'frozen'}
        remote.client = Mock()
        remote.client.call.side_effect = ValueError('store already exists')
        remote.sim_command('dstore', name='existing')
        remote.say('periodic status')
        self.assertEqual(remote.simulation_error, 'store already exists')
        remote.client.call.side_effect = None
        remote.sim_command('dstore', name='new')
        self.assertIsNone(remote.simulation_error)
        view = SimulationView(self.app)
        self.app.text_input = Mock(return_value='')
        self.sup.sim_command = Mock()
        view.save()
        self.sup.sim_command.assert_not_called()
        self.assertIn('Store not saved', self.sup.simulation_error)

    def test_simulation_controls(self):
        self.sup.sim_command = Mock()
        self.sup.simulation = dict(mode='frozen', time=3.5, root='/test/dstore',
            stores=[dict(name='baseline', complete=True), dict(name='broken', complete=False)],
            transaction=dict(operation='dstore', status='completed',
                             members={'gpc1': dict(lru='GPC1', status='completed')}))
        view = SimulationView(self.app)
        view.draw(self.app.screen)
        labels = [cell.text for column in view.cursor.columns for group in column for cell in group.cells]
        self.assertIn('[ FRZ ]', labels)
        self.assertIn('[ RUN ]', labels)
        self.assertIn('[ RESTORE ]', labels)
        view.select('broken')
        view.draw(self.app.screen)
        labels = [cell.text for column in view.cursor.columns for group in column for cell in group.cells]
        self.assertNotIn('[ RESTORE ]', labels)
        view.select('baseline')
        self.app.text_input = Mock(return_value='renamed')
        view.rename()
        self.sup.sim_command.assert_called_with('rename_dstore', name='baseline', new_name='renamed')
        for height, width in [(24, 80), (8, 25), (2, 8), (54, 132)]:
            self.app.screen = Display(height, width)
            view.draw(self.app.screen)
            view.handle(curses.KEY_NPAGE)
            view.draw(self.app.screen)
            view.handle(curses.KEY_PPAGE)

    def test_default_page_selection(self):
        self.app.panels = Mock(return_value=[])
        self.app._done = True
        with patch("simMgr.tui.curses.curs_set"), patch("simMgr.tui.Screen", return_value=self.app.screen):
            self.app._main(Mock())
            self.assertIsInstance(self.app.main, Overview)
            self.assertEqual([name for name, _ in self.app.pages], ["SUMMARY"])
            self.assertEqual([name for name, _ in self.app.main.pages], ["GPC STATUS", "LRU", "SIMULATION"])
            self.app.combined_summary = False
            self.app._main(Mock())
            self.assertIsInstance(self.app.main, SummaryView)
            self.assertIsInstance(self.app.pages[-1][1], GpcView)
            self.app.hardware_views = False
            self.app.combined_summary = True
            self.app._main(Mock())
            self.assertIsInstance(self.app.main, SummaryView)

    def test_right_view_cycle_and_detail_stack(self):
        overview = Overview(self.app)
        self.app.main = self.app.view = overview
        self.app.screen = Display(54, 186)
        table = Mock()
        panel = Mock()
        overview.add_pages([("LRU", table), ("PANEL", panel)])
        self.assertIs(overview.right_view, overview.gpc)
        overview.handle(curses.KEY_F6)
        self.assertIs(overview.right_view, table)
        overview.handle(curses.KEY_DOWN)
        table.handle.assert_called_once_with(curses.KEY_DOWN)
        self.assertEqual(table.app.screen.w, overview.regions(self.app.screen)[1].w)
        log = LogView(self.app, "gpc1")
        self.app.open_view(log)
        self.assertIs(self.app.view, overview)
        self.assertIs(overview.right_view, log)
        log.draw(log.app.screen)
        self.assertTrue(self.sup.procs["gpc1"].watch_logs)
        buses = BusView(self.app, "gpc1")
        self.app.open_view(buses)
        overview.handle(27)
        self.assertIs(overview.right_view, log)
        overview.handle(27)
        self.assertIs(overview.right_view, table)
        self.assertFalse(self.sup.procs["gpc1"].watch_logs)
        overview.handle(curses.KEY_F6)
        self.assertIs(overview.right_view, panel)
        self.app.open_view(LogView(self.app, "gpc1"))
        overview.handle(curses.KEY_F6)
        self.assertIs(overview.right_view, overview.gpc)
        self.assertEqual(overview.details, [])
        overview.handle(27)
        self.assertEqual(overview.focus, 0)

    def test_health_and_control(self):
        glyphs = Glyphs(True)
        self.assertEqual(communication_glyph(self.sup, "gpc1", glyphs), ".")
        self.assertEqual(communication_glyph(self.sup, "imu1", glyphs), "v")
        self.sup.components = [self.record()]
        self.assertEqual(communication_glyph(self.sup, "imu1", glyphs), "^")
        self.sup.components[0]["age"] = LEASE + 1
        self.assertFalse(communicating(self.sup, "imu1"))
        self.sup.components[0]["age"] = 0
        self.sup.components[0]["pid"] = 999
        self.assertFalse(communicating(self.sup, "imu1"))
        self.assertEqual(simulation_status(self.sup), ("failed", "degraded", "down"))
        self.sup.procs.pop("gpc2")
        self.assertEqual(simulation_status(self.sup), ("running", "healthy", "up"))
        self.sup.procs["gpc1"].state = State.STARTING
        self.assertEqual(simulation_status(self.sup)[0], "changing")
        self.sup.connected = False
        self.assertEqual(simulation_status(self.sup)[0], "unavailable")

    def test_grouping_and_resize(self):
        rows = grouped_columns(self.sup, 10)[0]
        self.assertEqual([key for _, key in rows if key], ["gpc1", "gpc2", "imu1"])
        for index in range(40):
            key = "mdu%02d" % index
            self.sup.procs[key] = Process("mdu")
            self.sup.order.append(key)
        for height in (3, 8, 18):
            columns = grouped_columns(self.sup, height)
            self.assertTrue(all(len(column) <= height for column in columns))
            self.assertEqual(sorted(key for column in columns for _, key in column if key), sorted(self.sup.procs))
        for height, width in ((24, 120), (12, 40), (8, 25), (2, 8)):
            self.app.screen = Display(height, width)
            self.app.view.draw(self.app.screen)
        self.app.screen = Display(12, 60)
        self.app.view.draw(self.app.screen)
        self.app.view.handle(curses.KEY_NPAGE)
        self.assertIsNotNone(self.app.view.selected)
        self.sup.procs.pop(self.app.view.selected)
        self.app.view.draw(self.app.screen)
        self.assertIn(self.app.view.selected, self.sup.procs)

    def test_renderer_launch_identity(self):
        proc = self.sup.procs["imu1"]
        proc.launch_id = "current-launch"
        record = dict(self.record(), pid=999, launch="current-launch")
        self.sup.components = [record]
        self.assertTrue(communicating(self.sup, "imu1"))
        record["launch"] = "previous-launch"
        self.assertFalse(communicating(self.sup, "imu1"))
        record["pid"] = proc.pid
        self.assertFalse(communicating(self.sup, "imu1"))
        del record["launch"]
        self.assertTrue(communicating(self.sup, "imu1"))

    def test_fields_popups_and_return(self):
        summary = self.app.view
        summary.draw(self.app.screen)
        self.assertEqual(summary.selected, "gpc1")
        summary.handle(10)
        self.assertIsInstance(self.app.view, OperationsView)
        self.app.view.draw(self.app.screen)
        self.app.view.handle(10)
        self.sup.start.assert_called_once_with("gpc1")
        self.assertIs(self.app.view, summary)
        summary.handle(curses.KEY_RIGHT)
        summary.handle(10)
        self.assertIs(self.app.view, summary)
        summary.handle(curses.KEY_RIGHT)
        summary.handle(10)
        self.assertIsInstance(self.app.view, BusView)
        self.app.view.draw(self.app.screen)
        self.app.view.handle(27)
        self.assertIs(self.app.view, summary)
        self.assertEqual(summary.field, 2)
        summary.handle(curses.KEY_RIGHT)
        summary.handle(10)
        self.assertIsInstance(self.app.view, LogView)
        self.app.view.draw(self.app.screen)
        self.assertTrue(self.sup.procs["gpc1"].watch_logs)
        self.app.view.handle(27)
        self.assertFalse(self.sup.procs["gpc1"].watch_logs)
        self.assertEqual(summary.field, 3)
        self.assertEqual(summary.selected, "gpc1")

    def test_log_spinner_and_colours(self):
        summary = self.app.view
        proc = self.sup.procs["imu1"]
        self.assertEqual(summary.spinner(proc), ".")
        proc.log_seq = 200
        first = summary.spinner(proc)
        self.assertEqual(summary.spinner(proc), first)
        proc.log_seq += 4
        self.assertEqual(summary.spinner(proc), first)
        for sequence, expected in ((1, "|"), (2, "/"), (3, "-"), (4, "\\"), (5, "|"),
                                   (8, "\\"), (10, "/"), (0, ".")):
            proc.log_seq = sequence
            self.assertEqual(summary.spinner(proc), expected)
        proc.log_seq = 10
        self.assertEqual(SummaryView(self.app).spinner(proc), "/")
        summary.draw(self.app.screen)
        labels = {text.strip(): attr[0] for _, _, text, attr in self.app.screen.win.writes
                  if text.strip() in self.sup.procs}
        self.assertEqual(labels, {"gpc1": "dim", "imu1": "up", "gpc2": "down"})
        _, positions, name_width, _, _ = summary.geometry(self.app.screen)
        row = positions["imu1"][1] + 5
        cells = {column: (text, attr[0]) for top, column, text, attr in self.app.screen.win.writes if top == row}
        self.assertEqual(cells[2 + name_width + 1], ("v", "down"))
        self.assertEqual(cells[2 + name_width + 3], (".", "gray"))
        self.assertEqual(cells[2 + name_width + 5], (summary.spinner(proc), "title"))
        self.assertFalse(any(text in ("up", "stopped") for _, _, text, _ in self.app.screen.win.writes))
        indicators = [(text, attr[0]) for _, _, text, attr in self.app.screen.win.writes if len(text) == 1]
        self.assertIn((".", "gray"), indicators)
        self.assertIn((summary.spinner(proc), "title"), indicators)

    def test_commands_and_popup_position(self):
        summary = self.app.view
        self.sup.autostart = Mock()
        summary.handle(9)
        summary.handle(10)
        self.sup.autostart.assert_called_once()
        for operation in ("terminate", "restart_all", "reload"):
            setattr(self.sup, operation, Mock())
            summary.handle(curses.KEY_RIGHT)
            summary.handle(10)
            getattr(self.sup, operation).assert_called_once()
        summary.buttons.index = 0
        self.sup.busy = lambda: True
        summary.handle(10)
        self.sup.autostart.assert_called_once()
        self.sup.busy = lambda: False
        summary.handle(curses.KEY_DOWN)
        summary.draw(self.app.screen)
        self.assertTrue(any("AUTOSTART" in text for _, _, text, _ in self.app.screen.win.writes))
        summary.handle(10)
        for height in (24, 14):
            self.app.screen = Display(height, 100)
            self.app.view.draw(self.app.screen)
            row, column = summary.cursor_position(self.app.screen)
            border = next((top, left) for top, left, _, attr in self.app.screen.win.writes
                          if attr[0] == "popup")
            self.assertEqual(border, (row + 1 if height == 24 else max(0, row - 9), column))
            self.assertTrue(all(not attr[1].get("reverse") for _, _, _, attr in self.app.screen.win.writes
                                if attr[0].startswith("popup")))

    def test_missing_log_counts(self):
        summary = self.app.view
        proc = self.sup.procs["imu1"]
        proc.log_seq = None
        self.assertEqual(summary.spinner(proc), "?")
        summary.draw(self.app.screen)
        self.assertTrue(any("restart the headless master" in text
                            for _, _, text, _ in self.app.screen.win.writes))
        self.assertTrue(any(text == "?" and attr[0] == "warn"
                            for _, _, text, attr in self.app.screen.win.writes))

    def test_bus_indicator(self):
        summary, glyphs = self.app.view, self.app.screen.g
        record = self.record()
        traffic = dict(rx=0, tx=0)
        record["buses"] = [dict(name="IC1", traffic=traffic),
                           dict(name="_simControl", traffic=dict(rx=100, tx=100))]
        self.sup.components = [record]
        self.assertEqual(summary.bus_glyph("imu1", glyphs), ".")
        traffic["tx"] = 1
        self.assertEqual(summary.bus_glyph("imu1", glyphs), ">")
        self.assertEqual(summary.bus_glyph("imu1", glyphs), ">")
        traffic["rx"] = 1
        self.assertEqual(summary.bus_glyph("imu1", glyphs), "<")
        for expected in (">", "<"):
            traffic["rx"] += 1
            traffic["tx"] += 1
            self.assertEqual(summary.bus_glyph("imu1", glyphs), expected)
        self.sup.procs["imu1"].pid = None
        self.assertEqual(summary.bus_glyph("imu1", glyphs), ".")

    def test_bus_samples(self):
        record = self.record()
        sample = dict(seq=1, time=time.time(), direction="rx", length=100, hex="02 00 12 34")
        record["buses"] = [dict(name="IC1", port=6901, transport="shm",
                                traffic=dict(seq=1, rx=1, tx=0, recent=[sample]))]
        self.sup.components = [record]
        view = BusView(self.app, "imu1")
        self.assertTrue(any("RX 1 TX 0" in text for text, _ in view.lines()))
        self.assertTrue(any("100B" in text and "..." in text for text, _ in view.lines()))
        view.lines()
        self.assertEqual(len(next(iter(view.feeds.values()))["samples"]), 1)
        for sequence in range(2, 40):
            sample["seq"] = sequence
            record["buses"][0]["traffic"]["seq"] = sequence
            view.lines()
        self.assertLessEqual(len(next(iter(view.feeds.values()))["samples"]), 20)
        self.sup.connected = False
        view.draw(self.app.screen)
        self.assertTrue(any("last received data" in text for _, _, text, _ in self.app.screen.win.writes))
        self.sup.procs["imu1"].pid = 456
        self.assertEqual(view.lines(), [])
        self.sup.procs["imu1"].pid = None
        self.sup.procs["imu1"].state = State.STOPPED
        self.assertTrue(view.lines())
        self.assertFalse(communicating(self.sup, "imu1"))

    def test_global_bus_colours_and_hidden_control(self):
        record = self.record()
        record["buses"] = [dict(name=name, traffic=dict(seq=0, rx=0, tx=0, recent=[]))
                           for name in ("_simControl", "_POWER", "_PANEL", "IC1", "_FF1_mdmIO")]
        self.sup.components = [record]
        view = BusView(self.app, "imu1")
        headers = {text.split()[0]: colour for text, colour in view.lines() if "RX" in text}
        self.assertEqual(headers, {"_POWER": "bus_global", "_PANEL": "bus_global",
                                   "IC1": "hdr", "_FF1_mdmIO": "hdr"})
        self.assertFalse(any("_simControl" in text for text, _ in view.lines()))
        summary = self.app.view
        for index, expected in ((0, "gray"), (1, "bus_global"), (2, "bus_global"),
                                (3, "title"), (4, "title")):
            record["buses"][index]["traffic"]["rx"] += 1
            self.app.screen.win.writes.clear()
            summary.draw(self.app.screen)
            _, positions, name_width, _, _ = summary.geometry(self.app.screen)
            row = positions["imu1"][1] + 5
            attr = next(attr for top, column, _, attr in self.app.screen.win.writes
                        if top == row and column == name_width + 5)
            self.assertEqual(attr[0], expected)
        record["buses"][1]["traffic"]["rx"] += 1
        record["buses"][3]["traffic"]["rx"] += 1
        summary.bus_glyph("imu1", self.app.screen.g)
        self.assertEqual(summary.traffic["imu1"][2], "title")
        record["buses"][1]["traffic"]["rx"] += 1
        record["buses"][3]["traffic"]["tx"] += 1
        self.assertEqual(summary.bus_glyph("imu1", self.app.screen.g), ">")
        self.assertEqual(summary.traffic["imu1"][2], "title")
        record["buses"] = record["buses"][:1]
        self.assertEqual(view.lines(), [])
        self.assertEqual(summary.bus_glyph("imu1", self.app.screen.g), ".")
