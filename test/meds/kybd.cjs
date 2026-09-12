// test_meds_kybd.cjs — which keystrokes the DEU keyboard is entitled to take.
//
// A browser keydown reaches the orbiter keyboard only when it is a bare
// press of a mapped key outside a text widget.  KYBD.deuKeyFor is that
// decision with no DOM around it, so this drives it with plain
// event-shaped objects.
//
// Usage:
//   cd ext/sim && node test/test_meds_kybd.cjs
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
        `kybd.test.${path.basename(rel).replace(/\W/g, '_')}.${process.pid}.cjs`);
    await esbuild.build({
        absWorkingDir: SIM,
        entryPoints: [path.isAbsolute(rel) ? rel : path.join(SIM, rel)],
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

const ev = (keyCode, extra) => Object.assign({keyCode, target: null}, extra);
const el = (tagName, extra) => Object.assign({tagName, isContentEditable: false}, extra);

async function main() {
    const {KYBD} = await bundle('meds/kybd.coffee');
    const name = (k) => (k == null ? null : k.ascii);

    // --- the keyboard's own keys still arrive ------------------------------
    eq(name(KYBD.deuKeyFor(ev(65))), 'A', 'a bare A is a DEU A');
    eq(name(KYBD.deuKeyFor(ev(53))), '5', 'a bare 5 is a DEU 5');
    eq(name(KYBD.deuKeyFor(ev(13))), 'EXEC', 'Enter is EXEC');
    eq(name(KYBD.deuKeyFor(ev(27))), 'MSG RESET', 'Escape is MSG RESET');
    eq(name(KYBD.deuKeyFor(ev(83))), 'SPEC', 'S is SPEC');
    // Shift is the one modifier the DEU may see -- the host needs it for
    // '+' and for the Shift+S screenshot.
    eq(name(KYBD.deuKeyFor(ev(65, {shiftKey: true}))), 'A', 'Shift+A is still A');

    // --- unmapped keys are nobody's ----------------------------------------
    eq(KYBD.deuKeyFor(ev(90)), null, 'Z is not on the DEU keyboard');
    eq(KYBD.deuKeyFor(ev(112)), null, 'F1 belongs to the edge keys');
    eq(KYBD.deuKeyFor(null), null, 'a missing event is not a keystroke');

    // --- modifier chords belong to the application -------------------------
    eq(KYBD.deuKeyFor(ev(82, {ctrlKey: true})), null,
       'Ctrl+R reloads the window, it does not send RESUME');
    eq(KYBD.deuKeyFor(ev(68, {ctrlKey: true, shiftKey: true})), null,
       'Ctrl+Shift+D toggles DevTools, it does not send D');
    eq(KYBD.deuKeyFor(ev(65, {metaKey: true})), null,
       'Cmd+A selects all, it does not send A');
    eq(KYBD.deuKeyFor(ev(67, {metaKey: true})), null,
       'Cmd+C copies, it does not send C');
    eq(KYBD.deuKeyFor(ev(51, {altKey: true})), null,
       'Alt+3 is not a DEU 3');

    // --- text widgets keep their own keystrokes ----------------------------
    // The param editor and the nudge boxes stopPropagation() as well; this
    // is the backstop for anything that forgets to.
    eq(KYBD.deuKeyFor(ev(65, {target: el('INPUT')})), null,
       'typing A in a text box is not a DEU A');
    eq(KYBD.deuKeyFor(ev(53, {target: el('TEXTAREA')})), null,
       'typing 5 in a textarea is not a DEU 5');
    eq(KYBD.deuKeyFor(ev(13, {target: el('SELECT')})), null,
       'Enter in a select is not EXEC');
    eq(KYBD.deuKeyFor(ev(66, {target: el('DIV', {isContentEditable: true})})), null,
       'B in a contenteditable is not a DEU B');
    eq(name(KYBD.deuKeyFor(ev(66, {target: el('CANVAS')}))), 'B',
       'B over the MDU canvas IS a DEU B');

    ok(KYBD.isEditable(el('input')) === true, 'lower-case tagName counts');
    ok(KYBD.isEditable(el('DIV')) === false, 'a plain div is not editable');
    ok(KYBD.isEditable(null) === false, 'a null target is not editable');
    ok(KYBD.isEditable({}) === false, 'a target with no tagName is not editable');

    // --- the major function switch ------------------------------------------
    // `<` `>` `?` are shifted keys, so ev.key carries the character.
    const mf = (key, extra) => Object.assign({key, target: null}, extra);
    eq(KYBD.majorFuncFor(mf('<')), 'GNC', '< is GNC');
    eq(KYBD.majorFuncFor(mf('>')), 'SM', '> is SM');
    eq(KYBD.majorFuncFor(mf('?')), 'PL', '? is PL');
    eq(KYBD.majorFuncFor(mf('<', {shiftKey: true})), 'GNC', 'Shift+, is still <');
    eq(KYBD.majorFuncFor(mf(',')), null, 'a bare comma moves nothing');
    eq(KYBD.majorFuncFor(mf('<', {metaKey: true})), null, 'Cmd+< is the application\'s');
    eq(KYBD.majorFuncFor(mf('?', {target: el('INPUT')})), null,
       'a ? typed in a text box moves nothing');
    eq(KYBD.majorFuncFor(null), null, 'a missing event moves nothing');

    // The word on the bus decodes back to the position, and a keyswitch
    // pattern still decodes as a key.
    const {KYBDMsg, KYBD_MSG_MASK} = await bundle('meds/medsConf.coffee');
    const DEU = await bundle('meds/deuProto.coffee');
    for (const name of ['PL', 'GNC', 'SM']) {
        const w = KYBD.majorFuncWord(name);
        eq(w & KYBD_MSG_MASK, KYBDMsg.MAJOR_FUNC, `${name} is a MAJOR_FUNC word`);
        eq(KYBD.decode(w).majorFunc, DEU.MAJOR_FUNC_CODE[name], `${name} decodes to its code`);
        eq(KYBD.decode(w).key, undefined, `${name} is not a key`);
    }
    eq(KYBD.decode(KYBD.DEUKey.keys.EXEC.deuCode).key, KYBD.DEUKey.keys.EXEC,
       'a scan pattern decodes as its key');
    eq(KYBD.decode(KYBDMsg.MAJOR_FUNC | 3), null, 'code 3 is no switch position');
    eq(KYBD.decode(0x0200), null, 'an unassigned discrete word decodes to nothing');
    eq(KYBD.decode(0x1234), null, 'a stray word decodes to nothing');

    // --- the scan-code table round-trips -----------------------------------
    // byScan is the IDP's direction: what keyPress puts on the bus must come
    // back as the same key.
    for (const k of Object.values(KYBD.DEUKey.keys)) {
        ok(KYBD.byScan(k.deuCode) === k, `byScan round-trips ${k.ascii}`);
    }

    console.log(`test_meds_kybd: ${pass} passed, ${fail} failed`);
    process.exit(fail ? 1 : 0);
}

main().catch((e) => { console.error(e); process.exit(1); });
