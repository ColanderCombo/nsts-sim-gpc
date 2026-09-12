import json
import fcntl
import os
import pty
import select
import signal
import subprocess
import struct
import sys
import tempfile
import termios
import threading
import time
import unittest
from pathlib import Path
from dataclasses import replace
from types import SimpleNamespace
from unittest import mock

from typer.main import get_command
from typer.testing import CliRunner
from typer import BadParameter

from simMgr.config import Health, Lru, SimConfig, load
from simMgr.cli import app, manager_client
from simMgr.controlbus import Channel, LEASE, MAX_DATAGRAM, Reassembler, decode, packets
from simMgr.master import Master, _Handler
from simMgr.remote import Client, RemoteSupervisor, discover
from simMgr.supervisor import Supervisor
from simMgr.startup import StartupRestore
from simMgr.tui import App
from _summary import SummaryTest


def wait_for(predicate, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.05)
    raise AssertionError("state did not arrive before deadline")


class ControlTest(unittest.TestCase):
    def test_startup_restore_cli(self):
        runner = CliRunner()
        for command in ('run', 'start'):
            with mock.patch('simMgr.cli.resolve', return_value='config'), mock.patch('simMgr.cli.cmd_run', return_value=0) as run:
                result = runner.invoke(app, [command, '--restore', 'IPL GPC 1', '--resume'])
                self.assertEqual(result.exit_code, 0, result.output)
                self.assertIn('IPL GPC 1', str(run.call_args))
        result = runner.invoke(app, ['start', 'fixture', '--restore', 'saved'])
        self.assertNotEqual(result.exit_code, 0)

    def test_fragmented_messages(self):
        message = dict(v=1, type="component", config={"text": "λ" * 20000})
        encoded = packets(message)
        self.assertGreater(len(encoded), 1)
        self.assertTrue(all(len(packet) <= MAX_DATAGRAM for packet in encoded))
        receiver = Reassembler()
        source = ("127.0.0.1", 6900)
        self.assertIsNone(receiver.receive(decode(encoded[-1]), source))
        result = None
        for packet in reversed(encoded):
            result = receiver.receive(decode(packet), source)
        self.assertEqual(result, message)
        self.assertEqual(receiver.pending, {})
        receiver.receive(decode(encoded[0]), source)
        with mock.patch("simMgr.controlbus.time.monotonic", return_value=time.monotonic() + LEASE + 1):
            self.assertIsNone(receiver.receive(decode(encoded[-1]), source))
        self.assertEqual(len(next(iter(receiver.pending.values()))["chunks"]), 1)
        for invalid in (dict(index=-1), dict(count=100000), dict(data="!"), dict(index=True)):
            self.assertIsNone(receiver.receive(dict(decode(encoded[0]), **invalid), source))
        with self.assertRaises(ValueError):
            packets(dict(v=1, text="x" * 262144))

    def test_service_components(self):
        root = Path(__file__).resolve().parents[2]
        config = load(root / "config/sim.yml", root / "config/runConfig.yml")
        keys = {"ratsnest", "adc", "adcsig1", "adcsig2"}
        stores = tempfile.TemporaryDirectory()
        self.addCleanup(stores.cleanup)
        config = replace(config, paths=dict(config.paths, dstore=Path(stores.name)))
        config = replace(config, lrus=[replace(lru, depends=[], health=Health(grace=0))
                                      for lru in config.lrus if lru.key in keys], log_dir=None)
        master = Master(Supervisor(config, build=False), int(os.environ["NSTS_BASE_PORT"]) + 600)
        master.start()
        try:
            client = Client("127.0.0.1", master.port)
            for key in keys:
                client.call("start", key)
            def advertised():
                state = client.call("snapshot")
                records = {record["key"]: record for record in state["components"] if record["available"]}
                return (state, records) if records.keys() == keys else None
            state, records = wait_for(advertised, timeout=15)
            for key, record in records.items():
                self.assertEqual(record["launch"], state["processes"][key]["launch_id"])
                self.assertGreater(len(record["buses"]), 1)
            self.assertIn("_POWER", [bus["name"] for bus in records["ratsnest"]["buses"]])
            time.sleep(2)
            state, records = advertised()
            self.assertTrue(all(record["age"] < 2 for record in records.values()))
            self.assertFalse(any("EMSGSIZE" in error.get("message", "") for error in client.call("snapshot")["errors"]))
            def command(operation, **kwargs):
                wait_for(lambda: not client.call('snapshot')['activity'])
                client.call(operation, **kwargs)
                result = wait_for(lambda: (tx if tx and tx['status'] != 'pending' else None)
                                  if (tx := client.call('snapshot')['simulation']['transaction']) else None)
                self.assertEqual(result['status'], 'completed', result)
            command('freeze')
            command('dstore', name='services')
            port = master.port
            master.close()
            master = Master(Supervisor(config, build=False), port)
            master.start()
            client = Client('127.0.0.1', port)
            for key in keys:
                client.call('start', key)
            wait_for(advertised, timeout=15)
            command('freeze')
            command('restore', name='services')
            command('run')
            time.sleep(.3)
            self.assertIsNotNone(advertised(), client.call('snapshot'))
            client.call("terminate")
            wait_for(lambda: all(proc["state"] in ("stopped", "exited")
                                 for proc in client.call("snapshot")["processes"].values()))
            for key in keys:
                self.assertEqual(client.call("snapshot")["processes"][key]["exit_code"], 0, key)
            wait_for(lambda: all(record["state"] == "stopped" for record in client.call("snapshot")["components"]))
        finally:
            master.close()

    def test_cli_defaults(self):
        runner = CliRunner()
        for arguments in ([], ["mgr"], ["--base-port", "7100", "mgr"]):
            with mock.patch.dict(os.environ), runner.isolation(), \
                    mock.patch.object(sys.stdout, "isatty", return_value=True):
                with mock.patch("simMgr.cli.manager_client") as attach, \
                        mock.patch("simMgr.cli.cmd_mgr", return_value=0) as frontend:
                    self.assertEqual(get_command(app).main(args=arguments, standalone_mode=False), 0)
                    frontend.assert_called_once()
                    self.assertEqual(attach.call_args.args[0].obj["attach"], "--base-port" in arguments)
        with mock.patch.dict(os.environ), mock.patch("simMgr.cli.manager_client") as attach:
            self.assertEqual(runner.invoke(app, []).exit_code, 2)
            attach.assert_not_called()
        with mock.patch.dict(os.environ), mock.patch("simMgr.cli.remote_call", return_value="accepted") as command:
            result = runner.invoke(app, ["start", "fixture"])
            self.assertEqual(result.exit_code, 0, result.output)
            self.assertEqual(command.call_args.args[1:], ("start", "fixture"))

    def test_manager_launch(self):
        port = int(os.environ["NSTS_BASE_PORT"]) + 600
        directory = Path(__file__).parent
        config = load(directory / "selftest.yml", directory / "selftest-run.yml")
        context = SimpleNamespace(obj={"attach": False, "host": "127.0.0.1", "build": False})
        with tempfile.TemporaryDirectory() as logs, \
                mock.patch.dict(os.environ, {"NSTS_BASE_PORT": str(port)}), \
                mock.patch("simMgr.cli.resolve", return_value=replace(config, log_dir=Path(logs))):
            client = manager_client(context)
            pid = client.call("identify")["pid"]
            try:
                self.assertNotEqual(pid, os.getpid())
                self.assertEqual(manager_client(context).master, client.master)
                context.obj["attach"] = True
                self.assertEqual(manager_client(context).master, client.master)
                self.assertTrue(all(not proc["alive"] for proc in client.call("snapshot")["processes"].values()))
            finally:
                os.kill(pid, signal.SIGTERM)

                def gone():
                    try:
                        os.kill(pid, 0)
                        return False
                    except ProcessLookupError:
                        return True

                wait_for(gone)
            with mock.patch("simMgr.cli.subprocess.Popen") as spawn:
                with self.assertRaises(BadParameter):
                    manager_client(context)
                spawn.assert_not_called()

    def test_cli_master(self):
        port = int(os.environ["NSTS_BASE_PORT"]) + 400
        directory = Path(__file__).parent
        process = subprocess.Popen([
            sys.executable, "-m", "simMgr", "--base-port", str(port),
            "-c", str(directory / "selftest.yml"),
            "-r", str(directory / "selftest-run.yml"), "start",
        ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

        def attached():
            try:
                return Client("127.0.0.1", port)
            except OSError:
                return None

        try:
            client = wait_for(attached)
            self.assertTrue(all(not proc["alive"] for proc in client.call("snapshot")["processes"].values()))
            terminal, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 54, 186, 0, 0))
            frontend = subprocess.Popen([sys.executable, "-m", "simMgr", "--base-port", str(port), "mgr"],
                                        stdin=slave, stdout=slave, stderr=slave,
                                        env=dict(os.environ, TERM="xterm-256color"))
            os.close(slave)
            output = bytearray()

            def rendered(expected=(b"SUMMARY", b"tick1", b"GPC STATUS")):
                ready, _, _ = select.select([terminal], [], [], 0.1)
                if ready:
                    output.extend(os.read(terminal, 65536))
                return all(text in output for text in expected)

            try:
                wait_for(rendered)
                output.clear()
                os.write(terminal, b"\x1b[17~")
                wait_for(lambda: rendered((b"UPTIME",)))
                output.clear()
                os.write(terminal, b"\r")
                wait_for(lambda: rendered((b"CLEAR",)))
                output.clear()
                os.write(terminal, b"\x1b")
                wait_for(lambda: rendered((b"UPTIME",)))
                os.write(terminal, b"q")

                def detached():
                    ready, _, _ = select.select([terminal], [], [], 0.1)
                    if ready:
                        try:
                            output.extend(os.read(terminal, 65536))
                        except OSError:
                            pass
                    return frontend.poll() is not None

                wait_for(detached)
                self.assertEqual(frontend.returncode, 0, output.decode(errors="replace"))
                self.assertEqual(client.call("identify")["pid"], process.pid)
            finally:
                if frontend.poll() is None:
                    frontend.kill()
                    frontend.wait(timeout=3)
                os.close(terminal)
            process.terminate()
            stdout, stderr = process.communicate(timeout=8)
            self.assertEqual(process.returncode, 0, stdout + stderr)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=3)

    def test_freeze_and_dstore(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            unit = Lru(key="fixture", lru="test", cwd=root,
                       argv=[os.environ["NSTS_CONTROL_NODE"], os.environ["NSTS_CONTROL_FIXTURE"]],
                       health=Health(grace=0))
            config = SimConfig(root / "sim.yml", root / "run.yml", "checkpoint test", "", {}, [unit])
            master = Master(Supervisor(config, build=False), int(os.environ["NSTS_BASE_PORT"]) + 800)
            master.start()
            try:
                client = Client("127.0.0.1", master.port)
                client.call("start", "fixture")
                wait_for(lambda: any(r['available'] for r in client.call('snapshot')['components']))
                def simulation(): return client.call('snapshot')['simulation']
                def done(): return simulation()['transaction']['status'] != 'pending'
                with self.assertRaisesRegex(ValueError, 'FREEZE'):
                    client.call('dstore', name='early')
                client.call('FRZ')
                wait_for(done)
                self.assertEqual(simulation()['mode'], 'frozen')
                time.sleep(1.1)
                count = client.call('snapshot')['components'][0]['report']['ticks']
                time.sleep(.5)
                self.assertEqual(client.call('snapshot')['components'][0]['report']['ticks'], count)
                with self.assertRaisesRegex(ValueError, 'RUN'):
                    client.call('restart', 'fixture')
                accepted = client.call('dstore', name='first', request_id='store-first')
                self.assertEqual(client.call('dstore', name='first', request_id='store-first'), accepted)
                wait_for(done)
                self.assertEqual(simulation()['transaction']['status'], 'completed', simulation())
                self.assertEqual(simulation()['stores'][0]['name'], 'first')
                self.assertTrue((root / 'run/dstore/first.dstore/fixture/state.json').is_file())
                with self.assertRaises(ValueError): client.call('dstore', name='../escape')
                with self.assertRaises(ValueError): client.call('dstore', name='first')
                client.call('run')
                wait_for(done)
                time.sleep(.6)
                target = simulation()['time'] + .3
                client.call('freeze', at=target)
                wait_for(lambda: simulation()['mode'] == 'frozen')
                client.call('dstore', name='second')
                wait_for(done)
                self.assertEqual(len(simulation()['stores']), 2)
                client.call('rename_dstore', name='first', new_name='baseline')
                client.call('restore', name='baseline')
                wait_for(done)
                self.assertEqual(simulation()['transaction']['status'], 'completed', simulation())
                time.sleep(1.1)
                self.assertEqual(client.call('snapshot')['components'][0]['report']['ticks'], count)
                self.assertEqual(simulation()['mode'], 'frozen')
                client.call('run')
                wait_for(done)
                time.sleep(1.1)
                self.assertGreater(client.call('snapshot')['components'][0]['report']['ticks'], count)
                client.call('freeze')
                wait_for(done)
                client.call('restore', name='baseline')
                wait_for(done)
                self.assertEqual(simulation()['transaction']['status'], 'completed', simulation())
                # Preflight must reject corrupt input before applying any state.
                state_path = root / 'run/dstore/baseline.dstore/fixture/state.json'
                state_path.write_text('{bad')
                client.call('restore', name='baseline')
                wait_for(done)
                self.assertEqual(simulation()['transaction']['status'], 'failed')
                # Stopping the frozen membership must not trap the manager in FRZ.
                client.call('stop', 'fixture')
                wait_for(lambda: not client.call('snapshot')['processes']['fixture']['alive'])
                wait_for(lambda: not client.call('snapshot')['activity'])
                client.call('autostart')
                wait_for(lambda: any(r['available'] for r in client.call('snapshot')['components']))
                wait_for(lambda: not client.call('snapshot')['activity'])
                self.assertEqual(simulation()['mode'], 'running')
                self.assertIsNone(simulation()['transaction'])
                self.assertFalse(master.sup.simulation_frozen)
                client.call('freeze')
                wait_for(done)
                with self.assertRaisesRegex(ValueError, 'RUN'):
                    client.call('autostart')
                # Recreate the manager as well: only the directory survives.
                old_master = master.id
                port = master.port
                master.close()
                master = Master(Supervisor(config, build=False), port)
                master.start()
                client = Client('127.0.0.1', port)
                self.assertNotEqual(client.master, old_master)
                self.assertEqual(simulation()['mode'], 'running')
                self.assertEqual({s['name'] for s in simulation()['stores']}, {'baseline', 'second'})
                with self.assertRaises(OSError): StartupRestore(master, 'missing')
                with self.assertRaisesRegex(ValueError, 'timed out'):
                    StartupRestore(master, 'second', timeout=-1).tick()
                startup = StartupRestore(master, 'second')
                master.sup.autostart(startup.keys)
                wait_for(startup.tick)
                self.assertEqual(simulation()['mode'], 'frozen')
                self.assertEqual(simulation()['transaction']['status'], 'completed', simulation())
                client.call('rename_dstore', name='second', new_name='IPL GPC 1')
                client.call('run')
                wait_for(done)
                startup = StartupRestore(master, 'IPL GPC 1', resume=True)
                wait_for(startup.tick)
                self.assertEqual(simulation()['mode'], 'running')
                startup = StartupRestore(master, 'baseline')
                with self.assertRaisesRegex(ValueError, 'validate failed|restore failed'):
                    wait_for(startup.tick)
                self.assertTrue((root / 'run/dstore/IPL GPC 1.dstore/manifest.json').is_file())
                client.call('restore', name='IPL GPC 1')
                wait_for(done)
                self.assertEqual(simulation()['transaction']['status'], 'completed', simulation())
            finally:
                master.close()

    def test_master_and_components(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            unit = Lru(key="fixture", lru="test", cwd=root,
                       argv=[sys.executable, "-c",
                             "import subprocess,sys; sys.exit(subprocess.call(sys.argv[1:]))",
                             os.environ["NSTS_CONTROL_NODE"], os.environ["NSTS_CONTROL_FIXTURE"]],
                       env={"NSTS_BASE_PORT": "12345"}, params={"payload": "x" * 100000},
                       health=Health(grace=0), stop_timeout=1)
            failure = Lru(key="failure", lru="test", cwd=root, argv=[sys.executable, "-c",
                          "import sys; print('failure diagnostic', flush=True); sys.exit(7)"],
                          health=Health(grace=0))
            config = SimConfig(root / "sim.yml", root / "run.yml", "test one", "", {}, [unit, failure])
            second_config = SimConfig(root / "sim.yml", root / "run.yml", "test two", "", {}, [])
            port = int(os.environ["NSTS_BASE_PORT"])
            master = Master(Supervisor(config, build=False), port)
            second = Master(Supervisor(second_config, build=False), port + 200)
            master.start()
            second.start()
            try:
                with self.assertRaises(OSError):
                    Master(Supervisor(config), port)
                client = Client("127.0.0.1", port)
                observer = Client("127.0.0.1", port)
                other = Client("127.0.0.1", port + 200)
                self.assertEqual(client.master, observer.master)
                self.assertNotEqual(client.master, other.master)
                self.assertEqual({record["master"] for record in discover()}, {master.id, second.id})
                self.assertEqual(client.call("snapshot")["processes"]["fixture"]["state"], "stopped")
                self.assertEqual(len(client.call("snapshot")["config"]["lrus"][0]["params"]["payload"]), 100000)
                self.assertIsNone(decode(b"[]"))
                self.assertIsNone(decode(b'{"v":2}'))
                self.assertIsNone(decode(b"not json"))
                with self.assertRaisesRegex(ValueError, "unknown"):
                    client.call("start", "missing")
                with self.assertRaisesRegex(ValueError, "unknown operation"):
                    client.call("execute")
                class DropReply(_Handler):
                    dropped = False

                    def handle(self):
                        if not DropReply.dropped:
                            DropReply.dropped = True
                            self.server.master.request(decode(self.rfile.readline()))
                            return
                        super().handle()

                master.server.RequestHandlerClass = DropReply
                try:
                    self.assertEqual(client.call("start", "fixture", "start-id"), "accepted")
                finally:
                    master.server.RequestHandlerClass = _Handler
                self.assertTrue(DropReply.dropped)
                self.assertEqual(observer.call("start", "fixture", "start-id"), "accepted")
                with self.assertRaisesRegex(ValueError, "reused"):
                    observer.call("stop", "fixture", "start-id")
                state = wait_for(lambda: self.running(observer))
                component = state["components"][0]
                self.assertEqual(component["config"]["value"], 42)
                self.assertEqual(component["config"]["payload"], "x" * 20000)
                self.assertEqual(component["launch"], state["processes"]["fixture"]["launch_id"])
                self.assertNotEqual(component["pid"], state["processes"]["fixture"]["pid"])
                self.assertEqual(component["key"], "fixture")
                self.assertEqual(component["master"], master.id)
                buses = {bus["name"]: bus for bus in component["buses"]}
                self.assertEqual(buses["IC1"]["port"], port + 1)
                self.assertEqual(buses["_simControl"]["port"], port)
                self.assertEqual(buses["_simControl"]["transport"], "udp")
                def traffic():
                    records = observer.call("snapshot")["components"]
                    for record in records:
                        for bus in record.get("buses", []):
                            if bus["name"] == "IC1" and (bus.get("traffic") or {}).get("tx", 0):
                                return bus["traffic"]

                samples = wait_for(traffic)
                self.assertLessEqual(len(samples["recent"]), 4)
                sender = Channel(port + 1)
                try:
                    sender.sock.sendto(b"\x02\x00\xab\xcd", ("239.255.1.1", port + 1))
                    wait_for(lambda: traffic().get("rx", 0))
                finally:
                    sender.close()
                self.assertGreater(observer.call("snapshot")["processes"]["fixture"]["log_seq"], 0)
                self.assertTrue(component["available"])
                with master._lock:
                    renderer = dict(component, instance="renderer", pid=component["pid"] + 100000, seq=1)
                    master._receive(renderer)
                    self.assertTrue(next(record for record in master.snapshot()["components"]
                                         if record["instance"] == "renderer")["available"])
                    master._receive(dict(renderer, seq=2, launch="previous-launch"))
                    self.assertFalse(next(record for record in master.snapshot()["components"]
                                          if record["instance"] == "renderer")["available"])
                wait_for(lambda: observer.call("snapshot")["errors"])
                self.assertIn("fixture diagnostic", observer.call("snapshot")["errors"][0]["message"])
                self.assertEqual(other.call("snapshot")["components"], [])
                client.call("start", "failure")
                wait_for(lambda: any(record.get("key") == "failure" for record in client.call("snapshot")["errors"]))
                self.assertEqual(client.call("snapshot")["processes"]["failure"]["exit_code"], 7)
                self.assertTrue(any("failure diagnostic" in record.get("message", "")
                                    for record in client.call("snapshot")["errors"]))
                master.sup.report_error("worker diagnostic")
                wait_for(lambda: any(record.get("message") == "worker diagnostic"
                                     for record in client.call("snapshot")["errors"]))
                self.assertTrue(any("fixture ready" in line["text"] for line in client.call("logs", "fixture")))

                frontend = RemoteSupervisor(observer)
                try:
                    self.assertEqual(frontend.procs["fixture"].lru.key, "fixture")
                    app = App(frontend)
                    app.quit()
                    self.assertTrue(app._done)
                    self.assertTrue(client.call("snapshot")["processes"]["fixture"]["alive"])
                finally:
                    frontend.shutdown()

                channel = Channel(port)
                try:
                    channel.send(dict(v=1, type="query", master=master.id))
                    messages = []
                    deadline = time.monotonic() + 1
                    while time.monotonic() < deadline:
                        ready, _, _ = select.select([channel.sock], [], [], 0.1)
                        if ready:
                            messages.append(channel.recv())
                    self.assertTrue(any(record and record.get("type") == "process" for record in messages))
                    self.assertTrue(any(record and record.get("type") == "component" for record in messages))
                finally:
                    channel.close()

                previous_pid = state["processes"]["fixture"]["pid"]
                client.call("restart", "fixture", "restart-id")
                observer.call("restart", "fixture", "restart-id")
                wait_for(lambda: self.running(client, previous_pid))
                client.call("stop", "fixture")
                wait_for(lambda: not client.call("snapshot")["processes"]["fixture"]["alive"])
                self.assertEqual(client.call("identify")["master"], master.id)
                client.call("start", "fixture")
                state = wait_for(lambda: self.running(client))
                previous_pid = state["processes"]["fixture"]["pid"]
                gate = threading.Event()
                master.sup._submit("test barrier", lambda: gate.wait(timeout=3))
                wait_for(lambda: master.sup.activity == "test barrier")
                try:
                    client.call("stop", "fixture")
                    client.call("start", "fixture")
                finally:
                    gate.set()
                wait_for(lambda: self.running(client, previous_pid))
                client.call("terminate")
                wait_for(lambda: not client.call("snapshot")["processes"]["fixture"]["alive"])

                with master._lock:
                    identity = next(iter(master.components))
                    entry = master.components[identity]
                    entry["seen"] = time.monotonic() - LEASE - 1
                    sequence = entry["record"]["seq"]
                    master._receive(dict(entry["record"], seq=sequence - 1))
                    self.assertEqual(entry["record"]["seq"], sequence)
                    unavailable = [record for record in master.snapshot()["components"]
                                   if record["instance"] == identity][0]
                    self.assertFalse(unavailable["available"])
                    master._receive(dict(v=1, type="component", instance="external", seq=1,
                                         master="previous-master", key="fixture", state="running"))
                    external = [record for record in master.snapshot()["components"]
                                if record["instance"] == "external"][0]
                    self.assertTrue(external["available"])
                    self.assertFalse(external["managed"])
                with self.assertRaisesRegex(ValueError, "unowned"):
                    client.call("start", "fixture")

                response = subprocess.run([sys.executable, "-m", "simMgr", "list", "--json"],
                                          capture_output=True, text=True, check=True)
                self.assertEqual(len(json.loads(response.stdout)), 2)
                response = subprocess.run([sys.executable, "-m", "simMgr", "status"],
                                          capture_output=True, text=True, check=True)
                self.assertIn("fixture", response.stdout)
                self.assertFalse(master.request(dict(v=1, id="bad-master", master="old", op="start",
                                                     key="fixture"))["ok"])
            finally:
                master.close()
                second.close()
            replacement = Master(Supervisor(config, build=False), port)
            replacement.start()
            try:
                with self.assertRaisesRegex(ValueError, "master changed"):
                    client.call("snapshot")
            finally:
                replacement.close()

    def running(self, client, previous_pid=None):
        state = client.call("snapshot")
        proc = state["processes"]["fixture"]
        if (proc["state"] == "running" and proc["pid"] != previous_pid
                and any(record["available"] and record.get("launch") == proc["launch_id"]
                        for record in state["components"])):
            return state


if __name__ == "__main__":
    unittest.main()
