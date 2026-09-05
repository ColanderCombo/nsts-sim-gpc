// test_meds_idpsel.cjs — the IDP/CRT SEL switches and the keyboards they route.
//
// JSC-11174,Vol.1,Rev.F dwg 8.3 wires the left keyboard to IDP 1 and IDP 3,
// the right to IDP 3 and IDP 2, the aft to IDP 4; the two panel C2 switches
// pick which of its two IDPs each forward keyboard reaches.  This drives
// meds/idpSel with no bus underneath: the routing table, the switch object,
// and the words it puts on the _IDPSW bus.
//
// Usage:
//   cd ext/sim && node test/test_meds_idpsel.cjs
//
// Exit status is 1 iff any test failed.
'use strict';

const path = require('path');
const os = require('os');
const fs = require('fs');
const esbuild = require('esbuild');
const coffeePlugin = require('esbuild-coffeescript');

const SIM = path.resolve(__dirname, '..');

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
    const out = path.join(os.tmpdir(),
        `idpsel.test.${path.basename(rel).replace(/\W/g, '_')}.${process.pid}.cjs`);
    await esbuild.build({
        absWorkingDir: SIM,
        entryPoints: [path.join(SIM, rel)],
        bundle: true, platform: 'node', format: 'cjs', target: 'node20',
        outfile: out,
        plugins: [civetPlugin, coffeePlugin({})],
        resolveExtensions: ['.coffee', '.js', '.ts', '.civet', '.json'],
        nodePaths: [path.join(SIM, 'node_modules')],
        external: ['dgram', 'electron'],
        logLevel: 'error',
    });
    return require(out);
}

let pass = 0, fail = 0;
function ok(cond, what) {
    if (cond) { pass++; } else { fail++; console.log('FAIL: ' + what); }
}
function eq(a, b, what) { ok(a === b, `${what}: got ${a}, want ${b}`); }

async function main() {
    const { IDPSel, TAG, LEFT, RIGHT, AFT } = await bundle('meds/idpSel.coffee');

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

    // the switch object: toggles, notification, and what it refuses
    const sel = new IDPSel(null);
    const seen = [];
    sel.onChange((s) => seen.push(`${s.left}/${s.right}`));
    eq(sel.state().left, 1, 'LEFT starts at 1');
    eq(sel.state().right, 2, 'RIGHT starts at 2');
    ok(sel.toggleLeft(), '[ throws LEFT');
    eq(sel.state().left, 3, '...to 3');
    ok(sel.toggleRight(), '] throws RIGHT');
    eq(sel.state().right, 3, '...to 3');
    ok(sel.toggleLeft() && sel.state().left === 1, '...and back');
    ok(!sel.set(2, 2), 'LEFT cannot be 2');
    ok(!sel.set(1, 1), 'RIGHT cannot be 1');
    ok(!sel.set(1, 3), 'setting the standing positions is not a change');
    eq(seen.join(' '), '3/2 3/3 1/3', 'each change notified once');

    // the words on the bus
    const msg = IDPSel.encode(TAG.STATE, { left: 3, right: 2 });
    eq(msg.data16.length, 3, 'STATE is three words');
    const back = IDPSel.decode(Array.from(msg.data16));
    eq(back.tag, TAG.STATE, 'STATE decodes');
    eq(back.left, 3, '...with LEFT');
    eq(back.right, 2, '...and RIGHT');
    eq(IDPSel.decode([0x1234, 0, 0]), null, 'an unknown tag is nothing');
    eq(IDPSel.decode([TAG.STATE]), null, 'a short message is nothing');

    // a STATE off the bus is adopted; a bad one is not; a QUERY is answered
    // only by an IDP
    const mdu = new IDPSel(null);
    const idp = new IDPSel(null, { answers: true });
    let sent = [];
    idp.bus = { sendMsg: (m) => sent.push(Array.from(m.data16)) };
    mdu._onMsg([TAG.STATE, 3, 3]);
    eq(`${mdu.state().left}/${mdu.state().right}`, '3/3', 'an MDU adopts a STATE');
    mdu._onMsg([TAG.STATE, 2, 3]);
    eq(mdu.state().left, 3, '...and ignores an impossible one');
    mdu._onMsg([TAG.QUERY, 0, 0]);
    idp._onMsg([TAG.QUERY, 0, 0]);
    eq(sent.length, 1, 'the IDP answers a QUERY');
    eq(sent[0].join(','), `${TAG.STATE},1,2`, '...with its positions');

    console.log(`test_meds_idpsel: ${pass} passed, ${fail} failed`);
    process.exit(fail ? 1 : 0);
}

main().catch((e) => { console.error(e); process.exit(1); });
