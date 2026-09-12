// idpsel.cjs — the IDP/CRT SEL switches and the IDP LOAD
// momentaries as discrete lines (meds/idp/idpSel.coffee,
// meds/idp/idpDiscretes.coffee): the wiring, an IDP's end of its channel,
// and the panel's end.
//
// Usage:
//   cd ext/sim && node test/meds/idpsel.cjs
//
// Exit status is 1 iff any test failed.
'use strict';

const path = require('path');
const os = require('os');
const fs = require('fs');
const esbuild = require('esbuild');
const coffeePlugin = require('esbuild-coffeescript');

const SIM = path.resolve(__dirname, '..', '..');

// A bus domain for this test (com/bus.civet: every port is an offset from
// NSTS_BASE_PORT): a base drawn from the process id, 20000 to 59900 by 100,
// or NSTS_TEST_BASE_PORT, so a session on the default base is not heard.
process.env.NSTS_BASE_PORT =
    process.env.NSTS_TEST_BASE_PORT ?? String(20000 + (process.pid % 400) * 100);

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

async function bundle(rel) {
    const out = path.join(os.tmpdir(), `idpsel.${path.basename(rel)}.${process.pid}.cjs`);
    await esbuild.build({
        absWorkingDir: SIM,
        entryPoints: [path.join(SIM, 'src', rel)],
        bundle: true, platform: 'node', format: 'cjs', outfile: out,
        plugins: [civetPlugin, coffeePlugin()],
        resolveExtensions: ['.coffee', '.js', '.ts', '.civet', '.json'],
        external: ['electron', 'dgram'],
        logLevel: 'error',
    });
    return require(out);
}

let pass = 0, fail = 0;
function ok(cond, what) {
    if (cond) { pass++; } else { fail++; console.log('FAIL: ' + what); }
}
function eq(a, b, what) { ok(a === b, `${what}: got ${a}, want ${b}`); }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function main() {
    const { IDPSel, LEFT, RIGHT, AFT } = await bundle('meds/idp/idpSel.coffee');
    const I = await bundle('meds/idp/idpDiscretes.coffee');
    const D = await bundle('com/discretes.coffee');

    // the wiring, switches at their usual positions
    const nominal = { left: 1, right: 2 };
    eq(IDPSel.keyboardFor(1, nominal), LEFT,  'IDP 1 takes the left keyboard at LEFT 1');
    eq(IDPSel.keyboardFor(2, nominal), RIGHT, 'IDP 2 takes the right keyboard at RIGHT 2');
    eq(IDPSel.keyboardFor(3, nominal), null,  'IDP 3 has no keyboard with both switches away');
    eq(IDPSel.keyboardFor(4, nominal), AFT,   'IDP 4 takes the aft keyboard, no switch');
    ok(!IDPSel.selected(2, AFT, nominal),     'the aft keyboard is not wired to IDP 2');
    ok(!IDPSel.selected(1, RIGHT, nominal),   'the right keyboard is not wired to IDP 1');

    // LEFT to 3: the left keyboard leaves IDP 1 for IDP 3
    const l3 = { left: 3, right: 2 };
    eq(IDPSel.keyboardFor(1, l3), null, 'IDP 1 loses its keyboard at LEFT 3');
    eq(IDPSel.keyboardFor(3, l3), LEFT, '...and IDP 3 gets it');
    eq(IDPSel.keyboardFor(2, l3), RIGHT, 'IDP 2 keeps the right keyboard');

    // both to 3: both keyboards on IDP 3, none on 1 or 2
    const both = { left: 3, right: 3 };
    ok(IDPSel.selected(3, LEFT, both) && IDPSel.selected(3, RIGHT, both),
       'both forward keyboards reach IDP 3 with both switches at 3');
    eq(IDPSel.keyboardFor(1, both), null, 'IDP 1 has none');
    eq(IDPSel.keyboardFor(2, both), null, 'IDP 2 has none');
    eq(IDPSel.keyboardFor(4, both), AFT,  'IDP 4 is unaffected');

    // the KYBD SEL discretes off the drawing
    let d = IDPSel.discretes(1, nominal);
    ok(d.B && !d.A, 'IDP 1 sees the left keyboard on KYBD SEL B');
    d = IDPSel.discretes(2, nominal);
    ok(d.A && !d.B, 'IDP 2 sees the right keyboard on KYBD SEL A');
    d = IDPSel.discretes(3, { left: 3, right: 2 });
    ok(d.A && !d.B, 'IDP 3 sees the left keyboard on KYBD SEL A');
    d = IDPSel.discretes(3, { left: 1, right: 3 });
    ok(d.B && !d.A, '...and the right keyboard on KYBD SEL B');
    eq(IDPSel.wiredTo(3).join(','), '1,2', 'IDP 3 is wired to the left and right keyboards');
    eq(IDPSel.wiredTo(4).join(','), '3',   'IDP 4 to the aft keyboard alone');

    // the same questions from an IDP's two lines
    eq(IDPSel.channelOf(1, LEFT), 'B', 'the left keyboard is IDP 1 channel B');
    eq(IDPSel.channelOf(3, RIGHT), 'B', '...and IDP 3 channel B');
    eq(IDPSel.channelOf(2, LEFT), null, 'the left keyboard is not wired to IDP 2');
    ok(IDPSel.selectedByLines(1, LEFT, { A: false, B: true }), 'IDP 1 B up takes the left keyboard');
    ok(!IDPSel.selectedByLines(1, LEFT, { A: true, B: false }), '...and A up does not');
    eq(IDPSel.keyboardForLines(3, { A: false, B: true }), RIGHT, 'IDP 3 B up is the right keyboard');
    eq(IDPSel.keyboardForLines(3, { A: true, B: true }), LEFT, '...both up, the left one');
    eq(IDPSel.keyboardForLines(4, { A: true, B: false }), AFT, 'IDP 4 A up is the aft keyboard');

    // the discrete spec: register A and the status word, by name
    eq(I.IDP_DISCRETES.busName(2), '_idpDiscretes2', 'IDP 2 has its channel');
    eq(I.IDP_DISCRETES.regName(I.REG_STATUS), 'STATUS', 'the status register is named');
    eq(I.IDP_DISCRETES.resolve(D.REG_A, 'load'), 2, 'LOAD is register A bit 2');
    eq(I.IDP_DISCRETES.describe(D.REG_A, D.bitMask(0) | D.bitMask(2)), 'kybdsela, load',
       'a mask is described by name');
    eq((I.defaultInputs(1) >>> 0).toString(16), (D.bitMask(1) >>> 0).toString(16),
       'IDP 1 powers up with KYBD SEL B, the switches at LEFT 1');
    eq(I.defaultInputs(2) >>> 0, D.bitMask(0) >>> 0, 'IDP 2 with KYBD SEL A, RIGHT 2');
    eq(I.defaultInputs(3) >>> 0, 0, 'IDP 3 with neither');
    eq(I.defaultInputs(4) >>> 0, D.bitMask(0) >>> 0, 'IDP 4 with KYBD SEL A, no switch');

    // An IDP's end of its channel, and the panel driving it over the bus.
    const inputs = { 1: [], 3: [] };
    const idp1 = new I.IDPDiscretes(1, { onInput: (b, on) => inputs[1].push([b, on]) });
    const idp3 = new I.IDPDiscretes(3, { onInput: (b, on) => inputs[3].push([b, on]) });
    const changes = [];
    const panel = new I.IDPPanel({ onChange: () => changes.push(1) });
    await Promise.all([idp1.ready(), idp3.ready(), panel.ready()]);

    ok(idp1.input('kybdselb') && !idp1.input('kybdsela'), 'IDP 1 starts with B up');
    eq(idp1.lines().B, true, '...as lines()');
    ok(!idp1.loading(), 'and reports loaded');

    panel.query();
    await sleep(100);
    ok(panel.heard[1] && panel.heard[3], 'the panel hears IDP 1 and 3 answer');
    ok(!panel.heard[2], '...and not IDP 2, which is not running');
    eq(JSON.stringify(panel.positions()), JSON.stringify({ left: 1, right: 2 }),
       'the positions read back from the lines are the power-up ones');

    ok(panel.setSel(3, 2), 'LEFT to 3');
    await sleep(100);
    ok(!idp1.input('kybdselb'), 'IDP 1 KYBD SEL B drops');
    ok(idp3.input('kybdsela'), 'IDP 3 KYBD SEL A rises');
    eq(inputs[1].filter(([b]) => b === I.IDP_BITS.A.kybdselb).length, 1, 'IDP 1 saw one change');
    eq(JSON.stringify(panel.positions()), JSON.stringify({ left: 3, right: 2 }),
       'the panel reads LEFT 3 back');
    ok(changes.length >= 1, '...and was told of the change');
    ok(!panel.setSel(2, 2), 'LEFT cannot be 2');
    ok(!panel.setSel(1, 1), 'RIGHT cannot be 1');

    ok(panel.toggleRight(), '] throws RIGHT');
    await sleep(100);
    ok(idp3.input('kybdselb'), 'IDP 3 KYBD SEL B rises at RIGHT 3');
    eq(panel.positions().right, 3, '...and the panel reads it');

    // The LOAD momentary: made, then released after LOAD_PRESS_MS.
    inputs[1].length = 0;
    ok(panel.pressLoad(1, 60), 'IDP 1 LOAD');
    await sleep(30);
    ok(idp1.input('load'), 'the line is up while the switch is held');
    await sleep(100);
    ok(!idp1.input('load'), '...and down after the hold');
    eq(inputs[1].map(([b, on]) => `${b}${on ? '+' : '-'}`).join(' '), '2+ 2-',
       'the IDP saw the make and the break');
    eq(panel.loading(1), false, 'the status word says loaded');
    idp1.setLoadState('requested');
    await sleep(60);
    eq(panel.loading(1), true, 'a load requested is published on the status word');
    idp1.setLoadState('complete');
    await sleep(60);
    eq(panel.loading(1), false, '...and its completion');

    // A request from a late panel gets the whole picture.
    const late = new I.IDPPanel();
    await late.ready();
    late.query();
    await sleep(100);
    eq(JSON.stringify(late.positions()), JSON.stringify({ left: 3, right: 3 }),
       'a late panel reads the standing positions');

    late.close(); panel.close(); idp1.close(); idp3.close();
    console.log(`test_meds_idpsel: ${pass} passed, ${fail} failed`);
    process.exit(fail ? 1 : 0);
}

main().catch((e) => { console.error(e); process.exit(1); });
