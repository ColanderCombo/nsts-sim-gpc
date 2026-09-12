// power.cjs — the power bus, a unit's supply, and the distribution
// the ratsnest holds
//
// Usage:
//   cd ext/sim && node test/com/power.cjs
//
// Exit status is 1 iff any test failed.
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

process.env.NSTS_BASE_PORT =
    process.env.NSTS_TEST_BASE_PORT ?? String(20000 + (process.pid % 400) * 100);
console.log(`bus base port ${process.env.NSTS_BASE_PORT}`);

async function bundle(rel) {
    const out = path.join(os.tmpdir(),
        `power.test.${path.basename(rel).replace(/\W/g, '_')}.${process.pid}.cjs`);
    await esbuild.build({
        absWorkingDir: SIM,
        entryPoints: [path.join(SIM, 'src', rel)],
        bundle: true, platform: 'node', format: 'cjs', target: 'node20',
        outfile: out,
        plugins: [civetPlugin, coffeePlugin({})],
        resolveExtensions: ['.coffee', '.js', '.ts', '.civet', '.json'],
        external: ['dgram', 'electron'],
        logLevel: 'error',
    });
    return require(out);
}

let passed = 0, failed = 0;
function ok(cond, what) {
    if (cond) { passed++; }
    else { failed++; console.log(`FAIL  ${what}`); }
}
function eq(got, want, what) {
    const g = JSON.stringify(got), w = JSON.stringify(want);
    if (g === w) { passed++; }
    else { failed++; console.log(`FAIL  ${what}\n        got  ${g}\n        want ${w}`); }
}
function near(got, want, what, eps = 1e-3) {
    if (Math.abs(Number(got) - Number(want)) <= eps) { passed++; }
    else { failed++; console.log(`FAIL  ${what}\n        got  ${got}\n        want ${want}`); }
}
function section(name) { console.log(`\n--- ${name} ---`); }
const settle = (msec = 150) => new Promise((r) => setTimeout(r, msec));

// Every control of the panels wiring/eps.wir reads, where the panel
// files rest them.
const REST = {
    'R1/S1': 'ON', 'R1/S2': 'ON', 'R1/S3': 'ON',
    'R1/S4': 'ON', 'R1/S5': 'ON', 'R1/S6': 'ON',
    'R1/S7': 'OFF', 'R1/S8': 'OFF', 'R1/S9': 'OFF',
    'R1/S10': 'ON', 'R1/S11': 'ON', 'R1/S12': 'ON',
    'R1/S13': 'OFF', 'R1/S14': 'OFF', 'R1/S15': 'OFF',
    'O6/S30': 'ON', 'O6/S31': 'ON', 'O6/S32': 'ON', 'O6/S33': 'ON', 'O6/S34': 'ON',
    'O6/S20': 'ON', 'O6/S21': 'ON', 'O6/S22': 'ON', 'O6/S23': 'ON', 'O6/S24': 'ON',
    'O6/S26': 'ON', 'O6/S27': 'ON', 'O6/S28': 'ON', 'O6/S29': 'ON', 'O6/S52': 'ON',
    'O13/CB4': 'CLOSED', 'O13/CB12': 'CLOSED',
    'O14/S13': 'ON', 'O15/S12': 'ON',
};

(async () => {
    const W = await bundle('com/power.coffee');
    const P = await bundle('panel/panelBus.coffee');
    const R = await bundle('ratsnest/ratsnest.coffee');
    const L = await bundle('com/lru.civet');
    const B = await bundle('com/bus.civet');

    section('messages');
    const round = (m) => W.decodePower(W.encodePower(m));
    let m = round({ op: W.VALUE, name: 'MNA', value: 27.5 });
    eq([m.opName, m.name], ['VALUE', 'MNA'], 'a feed and its volts');
    near(m.value, 27.5, 'the volts come back');
    m = round({ op: W.DRAW, name: 'MNA/GPC4', value: 560 });
    eq([m.opName, m.feed, m.unit], ['DRAW', 'MNA', 'GPC4'], 'a draw names the feed and the unit');
    near(m.value, 560, 'and the watts');
    m = round({ op: W.REQUEST, name: '' });
    eq([m.opName, m.name, m.value], ['REQUEST', '', null], 'a request for everything');
    eq(W.splitDraw('ESS1BC/MTU'), { feed: 'ESS1BC', unit: 'MTU' }, 'a draw name splits at the slash');
    eq(W.splitDraw('MNB'), { feed: 'MNB', unit: null }, 'a feed name alone');
    eq(W.fmtPower(round({ op: W.VALUE, name: 'MNC', value: 28 })), 'VALUE MNC 28.00 V',
       'a value reads as volts');
    eq(W.decodePower({ data16: new Uint16Array([9, 0, 0]) }), null, 'an unknown operation is refused');

    section('the standard switch');
    eq(W.configurePower({ dflt: 'on' }).dflt, W.NOMINAL_VOLTS, "'on' is the nominal 28 V");
    eq(W.configurePower({ dflt: 'off' }).dflt, 0, "'off' is none");
    eq(W.configurePower({ dflt: '24.5' }).dflt, 24.5, 'a number is volts');
    let refused = null;
    try { W.configurePower({ dflt: 'maybe' }); } catch (e) { refused = e.message; }
    eq(refused, "invalid power default 'maybe'", 'anything else is refused');
    W.configurePower({ dflt: 'on' });

    section('a supply');
    const events = [];
    const gpc = new W.PowerSupply('GPC4', [
        { name: 'A', feed: 'GPC4_A' }, { name: 'B', feed: 'GPC4_B' }, { name: 'C', feed: 'GPC4_C' },
    ], { onPower: (on_) => events.push(on_) });
    ok(gpc.powered(), 'the standard switch on leaves a unit powered');
    eq(gpc.unheard(), ['GPC4_A', 'GPC4_B', 'GPC4_C'], 'and nothing has answered for its feeds');
    gpc.put('GPC4_A', 0);
    ok(gpc.powered(), 'one supply lost of three still runs it');
    eq(events, [], 'and the unit is not told');
    gpc.put('GPC4_B', 0);
    gpc.put('GPC4_C', 0);
    ok(!gpc.powered(), 'all three lost puts it out');
    eq(events, [false], 'and the unit is told once');
    gpc.put('GPC4_B', 28);
    eq(events, [false, true], 'one back brings it up');
    gpc.put('GPC4_B', 12);
    ok(!gpc.powered(), 'a brownout below the dropout voltage is not power');
    near(gpc.named('B').volts, 12, 'and the voltage is there to read');

    const both = new W.PowerSupply('IDP1', [
        { name: 'AB1', feed: 'CNTL_AB1' }, { name: 'MNA', feed: 'MNA' },
    ], { rule: 'all' });
    ok(both.powered(), 'a unit that needs every input starts powered');
    both.put('CNTL_AB1', 0);
    ok(!both.powered(), 'and loses power with one of them');

    eq(new W.PowerSupply('MTU').powered(), true, 'a unit that declares no input is powered');

    section('a supply on the bus');
    const heard = [];
    const draws = {};
    const feeds = new W.PowerChannel((mm) => {
        if (mm.op === W.REQUEST) heard.push(mm.name);
        if (mm.op === W.DRAW) draws[mm.name] = mm.value;
    });
    await feeds.ready();
    const mmu = new W.PowerSupply('MMU1', [{ feed: 'MMU1', watts: 83 }]);
    mmu.open();
    await mmu.ready();
    await settle();
    eq(heard, ['MMU1'], 'a unit asks for the feed nothing has answered for');
    near(draws['MMU1/MMU1'], 83, 'and reports the watts it takes');
    feeds.report('MMU1', 0);
    await settle();
    ok(!mmu.powered(), 'the bus puts the unit out');
    near(draws['MMU1/MMU1'], 0, 'and a dead unit draws nothing');
    eq(mmu.unheard(), [], 'the feed has answered');
    mmu.close();

    section('an LRU');
    const standalone = new L.LRU({ id: 'STANDALONE', busses: [] });
    await standalone.ready();
    ok(standalone.powered(), 'a unit without power feeds is powered');
    eq(standalone.describe(), ['STANDALONE on '], 'a unit can run without data buses');
    let stopped = false;
    standalone.onStop = () => { stopped = true; };
    await standalone.stop();
    ok(stopped, 'stop invokes the unit cleanup hook');
    class Box extends L.LRU {
        constructor() {
            super({ id: 'BOX', busses: [], power: [{ feed: 'MNA', watts: 40 }] });
            this.log = [];
        }
        onPowerOn() { this.log.push('on'); }
        onPowerOff() { this.log.push('off'); }
    }
    const box = new Box();
    await box.ready();
    await settle();
    ok(box.powered(), 'an LRU comes up on the standard switch');
    feeds.report('MNA', 0);
    await settle();
    eq(box.log, ['off'], 'and is told when its feed goes');
    feeds.report('MNA', 28);
    await settle();
    eq(box.log, ['off', 'on'], 'and when it comes back');
    near(draws['MNA/BOX'], 40, 'the LRU reports what it draws');
    await box.stop();

    section('panel R1 through the wiring');
    const at = Object.assign({}, REST);
    const panel = new P.PanelChannel((mm) => {
        if (mm.op === P.REQUEST) {
            for (const k of Object.keys(at)) {
                if (!mm.key || k.startsWith(mm.key)) panel.report(k, P.ENUM, at[k]);
            }
        }
    });
    const volts = {};
    const watch = new W.PowerChannel((mm) => { if (mm.op === W.VALUE) volts[mm.name] = mm.value; });
    const throwSwitch = async (key, position) => {
        at[key] = position;
        panel.set(key, P.ENUM, position);
        await settle();
    };

    const net = new R.Ratsnest();
    net.load([path.join(SIM, 'config/wiring/eps.wir')]);
    net.open();
    await Promise.all([net.ready(), panel.ready(), watch.ready()]);
    await settle();
    net.start();
    await settle();

    eq(net.waiting().length, 0, 'every bound input has answered');
    near(volts['MNA'], 28, 'the cell reaches main bus A');
    near(volts['ESS1BC'], 28, 'and the essential busses');
    near(volts['CNTL_AB1'], 28, 'and the control busses');
    near(volts['GPC1_A'], 28, "a computer's three controllers pass their busses");
    near(volts['GPC5_C'], 28, 'for all five computers');
    near(volts['MMU1'], 28, 'the mass memories');
    near(volts['MTU_A'], 28, 'the timing unit');
    near(volts['FF1'], 28, 'and the flight critical MDMs');

    await throwSwitch('O6/S30', 'OFF');
    eq([volts['GPC1_A'], volts['GPC1_B'], volts['GPC1_C']], [0, 0, 0],
       'GPC POWER off drops all three of that computer');
    near(volts['GPC2_A'], 28, 'and leaves the others');

    await throwSwitch('R1/S10', 'OFF');
    near(volts['MNA'], 0, 'FC/MAIN BUS A off drops main bus A');
    near(volts['GPC2_A'], 0, 'and the controller on it');
    near(volts['GPC2_B'], 28, 'while the other two carry the computer');
    near(volts['MMU1'], 0, 'MMU 1 is on main A alone and goes with it');
    near(volts['ESS2CA'], 28, 'ESS 2CA falls back on main C');
    near(volts['FF1'], 28, 'an MDM takes whichever main bus is up');

    await throwSwitch('R1/S13', 'ON');
    await throwSwitch('R1/S14', 'ON');
    near(volts['MNA'], 28, 'MN BUS TIE A and B bring main A back from B');
    near(volts['MMU1'], 28, 'and the mass memory with it');

    await throwSwitch('O13/CB4', 'OPEN');
    near(volts['MTU_A'], 0, 'the MTU A breaker pulled drops that supply');
    near(volts['MTU_B'], 28, 'and leaves the other');

    await throwSwitch('O6/S26', 'OFF');
    near(volts['FF1'], 0, 'the FLT CRIT FWD FF1 switch drops that MDM');
    near(volts['FF2'], 28, 'and no other');

    section('the load on a feed');
    const loads = new W.PowerChannel();
    await loads.ready();
    loads.draw('MNB', 'GPC2', 560);
    loads.draw('MNB', 'MMU2', 83);
    await settle();
    const adapter = net.adapters.find((a) => a.scheme === 'power');
    near(adapter.wattsOn('MNB'), 643, 'the watts on a feed are what its units report');
    loads.draw('MNB', 'GPC2', 0);
    await settle();
    near(adapter.wattsOn('MNB'), 83, 'and follow what each one says next');
    loads.close();

    net.close();
    panel.close();
    watch.close();
    feeds.close();

    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed ? 1 : 0);
})();
