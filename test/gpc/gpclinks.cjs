
'use strict';

const path    = require('path');
const os      = require('os');
const fs      = require('fs');
const esbuild = require('esbuild');
const coffeePlugin = require('esbuild-coffeescript');

const SRC = path.resolve(__dirname, '..', '..');

process.env.NSTS_BASE_PORT =
    process.env.NSTS_TEST_BASE_PORT ?? String(20000 + (process.pid % 400) * 100);

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

async function bundle(entry) {
    const out = path.join(os.tmpdir(),
        `gpclinks.${path.basename(entry, '.coffee')}.${process.pid}.cjs`);
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
    return require(out);
}

let pass = 0, fail = 0;
function check(label, got, want) {
    if (got === want) { pass++; }
    else { fail++; console.log(`FAIL  ${label}: got ${got}, want ${want}`); }
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const hex = (v) => (v >>> 0).toString(16).padStart(8, '0');

(async () => {
    const L = await bundle('gpc/gpclinks.coffee');
    const D = await bundle('com/discretes.coffee');
    const { AP101 } = await bundle('gpc/ap101.coffee');
    const A = D.DISCRETE_BITS.A, OUT = D.DISCRETE_OUT_BITS;

    check('GPC 2 is GPC 1 N+1', L.ringOffset(1, 2), 1);
    check('GPC 1 is GPC 5 N+1', L.ringOffset(5, 1), 1);
    check('GPC 1 is GPC 2 N+4', L.ringOffset(2, 1), 4);
    check('a computer is at no offset from itself', L.ringOffset(3, 3), null);
    check('GPC 0 is off the ring', L.ringOffset(0, 1), null);
    check('...seen from either side', L.ringOffset(1, 0), null);

    check('SYNC 1 of N+1 lands at DI-20', L.inputBitFor(1, 2, OUT.stbyout), A.stbyn1);
    check('SYNC 2 of N+3 lands at DI-26', L.inputBitFor(1, 4, OUT.runout), A.runn3);
    check('SYNC 3 of N+4 lands at DI-31', L.inputBitFor(2, 1, OUT.syncout), A.syncn4);
    check('BFS RUN of N+2 lands at DI-9', L.inputBitFor(4, 1, OUT.bfsrunout), A.bfsrunn2);
    check('I/O ACTIVE goes nowhere', L.inputBitFor(1, 2, OUT.ioactivetb), null);
    check('an output of a computer off the ring goes nowhere',
          L.inputBitFor(1, 0, OUT.stbyout), null);
    check('the four lines from N+1',
          hex(L.inputMaskFor(1, 2)),
          hex(D.bitMask(A.stbyn1) | D.bitMask(A.runn1) | D.bitMask(A.syncn1) | D.bitMask(A.bfsrunn1)));
    const allOn = D.bitMask(OUT.stbyout) | D.bitMask(OUT.runout) | D.bitMask(OUT.syncout) |
                  D.bitMask(OUT.bfsrunout) | D.bitMask(OUT.ioactivetb) | D.bitMask(OUT.iplout);
    check('an output image keeps only the linked bits',
          hex(L.inputImageFor(1, 2, allOn)), hex(L.inputMaskFor(1, 2)));
    check('every input bit names its source',
          L.linksInto(3).map((l) => `${l.inBit}<${l.gpc}`).join(' '),
          '8<4 9<5 10<1 11<2 20<4 21<5 22<1 23<2 24<4 25<5 26<1 27<2 28<4 29<5 30<1 31<2');
    check('GPC 0 has no links', L.linksInto(0).length, 0);

    let clockUs = 1000;
    const landed = [];
    const links = new L.GpcLinks(1, (b, on) => landed.push(`${on ? '+' : '-'}${b}@${clockUs}`),
                                 () => clockUs);
    await links.ready();
    const sync = D.bitMask(OUT.syncout);
    const change = (op, t) => links.hear(4, { op, reg: D.REG_OUT, mask: sync, timeUs: t });
    change(D.SET, 500000);                        // GPC 4, at N+3 of GPC 1, raises SYNC 3
    check('the first change of a burst lands as it arrives', landed.join(' '), `+${A.syncn3}@1000`);
    change(D.RESET, 500450); change(D.SET, 500900);   // a 450 us pulse, both datagrams here
    check('the rest of the burst waits', landed.length, 1);
    clockUs = 1449; links.deliver(clockUs);
    check("...for this computer's clock", landed.length, 1);
    clockUs = 1450; links.deliver(clockUs);
    check("a change lands its sender's interval after the one before", landed[1], `-${A.syncn3}@1450`);
    clockUs = 1900; links.deliver(clockUs);
    check('...and the next likewise', landed[2], `+${A.syncn3}@1900`);
    change(D.RESET, 700000);
    check('a change stamped long after the last starts a burst of its own', landed[3], `-${A.syncn3}@1900`);
    change(D.SET, 700100);
    links.hear(4, { op: D.VALUE, reg: D.REG_OUT, mask: sync });
    check('a whole register lands at once, after what was queued ahead of it',
          landed.slice(4).join(' '), `+${A.syncn3}@1900`);
    check('nothing is left queued', links.queued, 0);
    links.close();
    check('a source knows its output', L.sourceOf(5, A.bfsrunn1).out, 'bfsrunout');
    check('...and the computer at N+1 of GPC 5 is GPC 1', L.sourceOf(5, A.bfsrunn1).gpc, 1);

    const g1 = new AP101({ machine: 'ap101s', gpc: 1 });
    const g2 = new AP101({ machine: 'ap101s', gpc: 2 });
    const connections = g1.controlBusMap();
    check('GPC advertises all 24 BCE buses',
          g1.iop.bce.filter(bce => connections[bce.mia.busName] === bce.mia.bus).length, 24);
    check('GPC 1 advertises its instrumentation bus', !!connections.IP1, true);
    check('GPC 2 advertises its instrumentation bus', !!g2.controlBusMap().IP2, true);
    check('GPC advertises all five discrete channels',
          Object.keys(connections).filter(name => name.startsWith('_gpcDiscretes')).length, 5);
    check('GPC advertises its power bus', !!connections._POWER, true);
    let announcement;
    const hub = g1.simControl.hub;
    const send = hub.send;
    hub.send = message => {
        if (message.id === g1.id) announcement = message;
        return Promise.resolve();
    };
    try {
        await g1.simControl.publish();
        check('GPC heartbeat includes its instrumentation bus',
              announcement.buses.some(bus => bus.name === 'IP1' && bus.traffic !== null), true);
        connections.IC1.monitor.note('rx', Buffer.from([2, 0, 0x12, 0x34]));
        await g1.simControl.publish();
        check('GPC heartbeat uses the BCE receive counter',
              announcement.buses.find(bus => bus.name === 'IC1').traffic.rx, 1);
    } finally {
        hub.send = send;
    }
    await Promise.all([g1.iop.gpcLinks.ready(), g2.iop.gpcLinks.ready(),
                       g1.iop.discreteBus.ready(), g2.iop.discreteBus.ready()]);
    const inA = (g) => g.iop.regDiscreteInA.get32() >>> 0;
    const bit = (g, b) => (inA(g) & D.bitMask(b)) !== 0;

    check('GPC 1 starts with no sync lines up', (inA(g1) & 0x00000fff) >>> 0, 0);
    g2.iop.setDiscreteOut(D.bitMask(OUT.stbyout), true);
    await sleep(100);
    check('GPC 2 SYNC 1 reaches GPC 1 at DI-20', bit(g1, A.stbyn1), true);
    check('...and nowhere else', (inA(g1) & 0x00000fff) >>> 0, D.bitMask(A.stbyn1) >>> 0);
    check('GPC 2 does not hear itself', bit(g2, A.stbyn1), false);

    g1.iop.setDiscreteOut(D.bitMask(OUT.syncout) | D.bitMask(OUT.bfsrunout), true);
    await sleep(100);
    check('GPC 1 SYNC 3 reaches GPC 2 at DI-31', bit(g2, A.syncn4), true);
    check('GPC 1 BFS RUN reaches GPC 2 at DI-11', bit(g2, A.bfsrunn4), true);

    g2.iop.setDiscreteOut(D.bitMask(OUT.stbyout), false);
    await sleep(100);
    check('a line dropped at the sender drops at the receiver', bit(g1, A.stbyn1), false);

    g1.iop.setDiscreteOut(D.bitMask(OUT.runout), true);
    const g3 = new AP101({ machine: 'ap101s', gpc: 3 });
    await g3.iop.gpcLinks.ready();
    g3.iop.gpcLinks.poll();
    await sleep(100);
    check('a late starter learns the lines already up: GPC 1 at N+3 of GPC 3',
          bit(g3, A.runn3), true);
    check('...and GPC 1 SYNC 3 with it', bit(g3, A.syncn3), true);

    g1.iop.discreteBus.close();
    g1.iop.discreteBus = null;
    for (let i = 0; i < L.LOST_AFTER; i++) { g2.iop.gpcLinks.poll(); await sleep(30); }
    check('a silent computer reads as powered off', bit(g2, A.syncn4), false);
    check('...on every line', (inA(g2) & 0x00000fff) >>> 0, 0);

    g1.iop.gpcLinks.close(); g2.iop.gpcLinks.close(); g3.iop.gpcLinks.close();
    g2.iop.discreteBus.close(); g3.iop.discreteBus.close();

    const { AGEHarness } = await bundle('gpc/ageharness.coffee');
    const h = new AGEHarness({ machine: 'ap101s', gpc: 0, mode: 'halt' });
    check('power-up at HALT makes the HALT line', bit(h.gpc, A.halt), true);
    check('...and holds the CPU in system reset', h.cpu.resetHeld, true);
    h.setModeSwitch('run');
    check('RUN breaks HALT', bit(h.gpc, A.halt), false);
    check('...makes RUN', bit(h.gpc, A.run), true);
    check('...and releases the CPU', h.cpu.resetHeld, false);
    let threw = null;
    try { h.setModeSwitch('sideways'); } catch (e) { threw = e.message; }
    check('an unknown position is refused', threw, "invalid mode 'sideways'");

    console.log(`${pass} passed, ${fail} failed`);
    process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
