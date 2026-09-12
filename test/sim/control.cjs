'use strict';

const path = require('path');
const os = require('os');
const fs = require('fs');
const esbuild = require('esbuild');
const coffeePlugin = require('esbuild-coffeescript');

const SIM = path.resolve(__dirname, '..', '..');

const civetPlugin = {
    name: 'civet',
    setup(build) {
        const { compile } = require(path.join(SIM, 'node_modules/@danielx/civet'));
        build.onResolve({ filter: /\.civet\.jsx$/ }, (a) => ({
            path: path.resolve(path.dirname(a.importer), a.path.replace(/\.jsx$/, '')),
        }));
        build.onLoad({ filter: /\.civet$/ }, async (a) => ({
            contents: compile(fs.readFileSync(a.path, 'utf8'), { filename: a.path, js: true }),
            loader: 'js',
        }));
    },
};


const { spawn } = require('node:child_process');

(async () => {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'sim-control-'));
    const fixture = path.join(directory, 'unit.cjs');
    try {
        await esbuild.build({
            absWorkingDir: SIM,
            stdin: {
                contents: `
                    import { LRU } from './src/com/lru.civet';
                    import * as runtime from './src/com/simRuntime.coffee';
                    const unit = new LRU({ id: 'FIXTURE', busses: ['IC1'], value: 42, payload: 'x'.repeat(20000) });
                    unit.ticks = 0;
                    unit.report = () => ({ticks: unit.ticks});
                    const hold = setInterval(() => {}, 60000);
                    unit.tick = () => {
                        unit.ticks++;
                        unit.send(unit.bus.IC1, [0x1234, 0x5678]);
                        console.log('packet sent');
                    };
                    const packets = runtime.setInterval(runtime.call(unit, 'tick'), 200);
                    unit.bus.IC1.onReceive(() => {});
                    unit.ready().then(async () => {
                        await unit.reportError(new Error('fixture diagnostic'));
                        console.log('fixture ready');
                    });
                    process.on('SIGTERM', async () => {
                        clearInterval(hold);
                        runtime.clearInterval(packets);
                        await unit.stop();
                        process.exit(0);
                    });
                `,
                resolveDir: SIM, loader: 'js',
            },
            bundle: true, platform: 'node', format: 'cjs', outfile: fixture,
            plugins: [civetPlugin, coffeePlugin({})],
            resolveExtensions: ['.coffee', '.js', '.ts', '.civet', '.json'],
            logLevel: 'error',
        });
        const child = spawn(process.env.NSTS_SIM_PYTHON || 'python3',
            [path.join(__dirname, '_control.py')], {
                stdio: 'inherit',
                env: { ...process.env, PYTHONPATH: path.join(SIM, 'src'),
                    NSTS_CONTROL_FIXTURE: fixture, NSTS_CONTROL_NODE: process.execPath,
                    NSTS_BASE_PORT: String(20000 + (process.pid % 350) * 100),
                    NSTS_SIM_DISCOVERY_PORT: String(20050 + (process.pid % 350) * 100),
                    NSTS_BUS_IFACE: '127.0.0.1', NSTS_BUS_SHM: 'off' },
            });
        const code = await new Promise((resolve, reject) => {
            child.once('error', reject);
            child.once('exit', resolve);
        });
        if (code !== 0) throw new Error('control tests failed; NSTS_SIM_PYTHON must have pyyaml and typer installed');
    } finally {
        fs.rmSync(directory, { recursive: true, force: true });
    }
})().catch((error) => { console.error(error); process.exitCode = 1; });
