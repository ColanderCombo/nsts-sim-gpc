// Shared-memory bus tests.

'use strict';

const path    = require('path');
const os      = require('os');
const fs      = require('fs');
const { execFileSync } = require('child_process');
const esbuild = require('esbuild');
const coffeePlugin = require('esbuild-coffeescript');

const SRC = path.resolve(__dirname, '..', '..');

const BASE = process.env.NSTS_TEST_BASE_PORT ?? String(20000 + (process.pid % 400) * 100);
process.env.NSTS_BASE_PORT = BASE;
process.env.NSTS_BUS_SHM = 'ic';

const civetPlugin = {
    name: 'civet',
    setup(build) {
        const { compile } = require('@danielx/civet');
        build.onResolve({ filter: /\.civet\.jsx$/ }, (args) => ({
            path: path.resolve(path.dirname(args.importer), args.path.replace(/\.jsx$/, '')),
        }));
        build.onLoad({ filter: /\.civet$/ }, async (args) => {
            const source = await fs.promises.readFile(args.path, 'utf8');
            return { contents: compile(source, { filename: args.path, js: true }), loader: 'js' };
        });
    },
};

async function bundle(entry, out) {
    await esbuild.build({
        absWorkingDir: SRC,
        entryPoints: [path.join(SRC, 'src', entry)],
        bundle:   true,
        platform: 'node',
        format:   'cjs',
        outfile:  out,
        plugins:  [civetPlugin, coffeePlugin()],
        resolveExtensions: ['.coffee', '.js', '.ts', '.civet', '.json'],
        external: ['electron', 'dgram'],
        logLevel: 'error',
    });
    return out;
}

let pass = 0, fail = 0;
function check(label, got, want) {
    if (got === want) { pass++; }
    else { fail++; console.log(`FAIL  ${label}: got ${got}, want ${want}`); }
}
function ok(label, cond) { check(label, !!cond, true); }

const words = (msg) => Array.from(msg.data16);

async function main() {
    const busPath = path.join(os.tmpdir(), `busshm.bus.${process.pid}.cjs`);
    await bundle('com/bus.civet', busPath);
    const B = require(busPath);
    const shm = require(path.join(process.env.NSTS_NATIVE || path.join(SRC, 'build', 'native'), 'shmring.node'));

    ok('IC1 is a shared-memory bus', B.shmNames.has('IC1'));
    ok('the mass memory bus is not', !B.shmNames.has('MM1'));

    const a  = new B.Bus('IC1', B.busConfig.IC1);
    const b  = new B.Bus('IC1', B.busConfig.IC1);
    const c  = new B.Bus('IC2', B.busConfig.IC2);
    const mm = new B.Bus('MM1', B.busConfig.MM1);
    await Promise.all([a.ready, b.ready, c.ready, mm.ready]);
    ok('a shared-memory bus opens a ring', a.ring != null);
    ok('a UDP bus does not', mm.ring == null);
    a.traffic();
    b.traffic();

    const got = [], echoed = [], wrongBus = [];
    b.onReceive((_, id, msg) => got.push(msg), null);
    a.onReceive((_, id, msg) => echoed.push(msg), null);
    c.onReceive((_, id, msg) => wrongBus.push(msg), null);

    a.sendMsg(B.BusMsg.Command(0x123456));
    const m = new B.BusMsg(3);
    m.data16[0] = 0xdead; m.data16[1] = 0xbeef; m.data16[2] = 0x0001;
    m.sev = [B.SEV_VALID, 0b100, B.SEV_VALID];
    m.delayUs = 335;
    m.wallUs = 12345678;
    a.sendMsg(m);

    check('nothing arrives before the ring is read', got.length, 0);
    B.pollShmRings();
    check('both datagrams arrive', got.length, 2);
    check('shared-memory sends are counted', a.traffic().tx, 2);
    check('shared-memory receives are counted', b.traffic().rx, 2);
    check('packet prefix survives the shared-memory view',
          b.traffic().recent[1].hex.endsWith('de ad be ef 00 01'), true);
    check('the command is flagged', got[0].cmd, true);
    check('the command word', words(got[0]).join(','), '4660,22016');
    check('the data is not flagged', got[1].cmd, false);
    check('the data words', words(got[1]).join(','), '57005,48879,1');
    check('the SEV bytes', (got[1].sev ?? []).join(','), '5,4,5');
    check('the delay', got[1].delayUs, 335);
    check("the sender's clock", got[1].wallUs, 12345678);
    check('a sender does not hear itself', echoed.length, 0);
    check('self echoes are absent from telemetry', a.traffic().rx, 0);
    check('another bus hears nothing', wrongBus.length, 0);
    const sampleBuffer = Buffer.alloc(80, 0x77);
    for (let sampleIndex = 0; sampleIndex < 6; sampleIndex++) {
        a.monitor.note('tx', sampleBuffer);
    }
    sampleBuffer.fill(0);
    const traffic = a.traffic();
    check('packet history is bounded', traffic.recent.length, 4);
    check('packet size is retained', traffic.recent[3].length, 80);
    check('packet prefix is bounded', traffic.recent[3].hex.split(' ').length, 24);
    check('packet prefixes are copied', traffic.recent[3].hex.startsWith('77 77'), true);

    const busshmPath = path.join(os.tmpdir(), `busshm.mod.${process.pid}.cjs`);
    await bundle('com/busshm.coffee', busshmPath);
    const S = require(busshmPath);
    const lapped = [];
    const reader = S.openRing(Number(BASE), B.busConfig.IC3.offset);
    const writer = S.openRing(Number(BASE), B.busConfig.IC3.offset);
    reader.onData = (buf) => lapped.push(buf[0]);
    const one = Buffer.from([0x02, 0x00, 0x11, 0x22]);
    for (let i = 0; i < S.SLOTS + 100; i++) { one[2] = i & 0xff; writer.push(one, one.length); }
    reader.drain();
    check('the words that went by are counted', reader.drops, 101);
    check('and the rest are read', lapped.length, S.SLOTS - 1);

    check('an oversize datagram is refused',
          writer.push(Buffer.alloc(S.SLOT_BYTES + 1), S.SLOT_BYTES + 1), false);
    check('and counted', writer.oversize, 1);
    reader.close(); writer.close();

    check('this process is on the ring', S.members().includes(process.pid), true);

    const child = `
        process.env.NSTS_BASE_PORT = ${JSON.stringify(BASE)};
        process.env.NSTS_BUS_SHM = 'ic';
        const B = require(${JSON.stringify(busPath)});
        const bus = new B.Bus('IC4', B.busConfig.IC4);
        const m = new B.BusMsg(2);
        m.data16[0] = 0x4321; m.data16[1] = process.pid & 0xffff;
        bus.sendMsg(m);
        setTimeout(() => process.exit(0), 50);
    `;
    const crossed = [];
    const d = new B.Bus('IC4', B.busConfig.IC4);
    d.onReceive((_, id, msg) => crossed.push(words(msg)), null);
    await d.ready;
    const childOut = execFileSync(process.execPath, ['-e', child], { encoding: 'utf8' });
    B.pollShmRings();
    check('a process that has gone is off the ring',
          S.members().join(','), String(process.pid));
    check("another process's datagram crosses", crossed.length, 1);
    check('with its words', crossed[0]?.[0], 0x4321);
    if (childOut.trim()) console.log(`  child said: ${childOut.trim()}`);

    a.close(); b.close(); c.close(); mm.close(); d.close();
    shm.unlink(`/nsts2.${BASE}`);
    fs.rmSync(busPath, { force: true });
    fs.rmSync(busshmPath, { force: true });

    console.log(`\n${pass} passed, ${fail} failed`);
    process.exit(fail ? 1 : 0);
}

main().catch((e) => { console.error(e); process.exit(1); });
