// test_meds_pollfail.cjs — the big “X” and POLL FAIL, in `meds/mduScreen_DPS`.
//
//   Other indications of loss of communication between the IDP and GPC are
//   the big “X” and POLL FAIL (Figure 3-48).  Big “X” appears when the IDP
//   does not receive display update data for 3 seconds.  POLL FAIL appears
//   in the lower right-hand corner when the IDP does not receive poll or
//   time update commands for 3 seconds.  Although they normally serve to
//   indicate a problem, both of these are also displayed whenever a powered
//   IDP is not assigned to any GPC (not a failure indication).
//     -- USA005350 Rev.B, DPS Hardware and System Software Workbook, §3.2.15.2
//
// Under test: each is a separate beam program -- the “X” two vectors and no
// text, POLL FAIL nine glyphs in the lower right and no vector -- and each
// draws with the other absent.  The two three-second timers that raise them
// are in `meds/mdu.coffee`.
//
// Usage:
//   cd ext/sim && node test/test_meds_pollfail.cjs
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
        `deu.test.${path.basename(rel).replace(/\W/g, '_')}.${process.pid}.cjs`);
    await esbuild.build({
        absWorkingDir: SIM,
        entryPoints: [rel],
        bundle: true, platform: 'node', format: 'cjs', target: 'node20',
        outfile: out,
        plugins: [civetPlugin, coffeePlugin({})],
        loader: {'.asm': 'text'},
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

// The same recording surface `test_meds_render` uses: glyphs and vectors are
// noted with their beam position rather than turned into geometry.
function stubSurface(THREE, drawn, lines) {
    return {
        c2h: {green: 0x00ff00},
        deuFont: null,
        dirty: false,
        str(x, y, ch) { drawn.push({x, y, ch}); return new THREE.Object3D(); },
        line(coords, color, intensity) {
            lines.push({coords, color, intensity});
            return new THREE.Object3D();
        },
        dashedLine(coords, color) {
            lines.push({coords, color, dashed: true});
            return new THREE.Object3D();
        },
    };
}

function screenOf(mods) {
    const {Screen_DPS} = mods.dps;
    const THREE = mods.three;
    const drawn = [], lines = [];
    const screen = Object.create(Screen_DPS.prototype);
    screen.fcw = new mods.fcw.FCW();
    screen.d = stubSurface(THREE, drawn, lines);
    screen.group = new THREE.Object3D();
    // `build` hangs everything drawn in the DEU's own coordinates off this
    // one and gives it the format area's horizontal centring; the geometry
    // below is measured in format-area cells, so the offset does not show
    // in it, but the group has to be there to draw into.
    screen.fmt = new THREE.Object3D();
    screen.group.add(screen.fmt);
    screen._blinkOn = true;
    screen.drawn = drawn;
    screen.lines = lines;
    // `setBigX`/`setPollFail` draw into a group each and are otherwise
    // no-ops, so give each one to write over.
    screen.geo_bigX = new THREE.Object3D();
    screen.geo_pollFail = new THREE.Object3D();
    screen.curData = {bigX: false, pollFail: false};
    return screen;
}

// What a geometry group actually holds.  `drawFCWS` always nests one group
// for the blinking objects, so the group itself and that nest are subtracted:
// an indication that is down leaves 0.
const marks = (g) => { let n = 0; g.traverse(() => n++); return n - 2; };

const text = (drawn) => drawn.slice()
    .sort((a, b) => (a.y - b.y) || (a.x - b.x))
    .map((d) => d.ch).join('');

async function main() {
    global.window = {fs};
    const shim = path.join(os.tmpdir(), `deu.test.pf.shim.${process.pid}.js`);
    fs.writeFileSync(shim,
        "export * as three from 'three'\n" +
        `export * as dps from ${JSON.stringify(path.join(SIM, 'meds/mduScreen_DPS.coffee'))}\n` +
        `export * as fcw from ${JSON.stringify(path.join(SIM, 'meds/deuFCW.coffee'))}\n` +
        `export * as spl from ${JSON.stringify(path.join(SIM, 'meds/deuSPL.coffee'))}\n`);
    const mods = await bundle(shim);
    const GLYPH_OFF = mods.fcw.glyphCentre();
    const cell = (g) => `${Math.round(g.x + GLYPH_OFF[0])},${Math.round(g.y + GLYPH_OFF[1])}`;

    // The big “X” alone: two crossing vectors, corner to corner, and not a
    // character anywhere.
    const x = screenOf(mods);
    x.setBigX(true);
    eq(x.lines.length, 2, 'the big X is two vectors');
    eq(x.drawn.length, 0, 'the big X draws no text');
    // `drawFCWS` draws in the format area's coordinates, which are the DEU's
    // character cells plus one on each axis.  The top is the absolute top of
    // the format area; the bottom is the bottom of line 26, the last line,
    // which carries the scratch pad line and POLL FAIL.
    const ends = x.lines.map((l) => l.coords.map((c) => c.map(Math.round).join(',')).join(' -> '));
    eq(ends[0], '1,1 -> 53,27', 'the first stroke rises left to right');
    eq(ends[1], '53,1 -> 1,27', 'the second falls right to left');
    ok(x.lines.every((l) => l.intensity), 'both strokes are intensified');

    // POLL FAIL alone: nine glyphs on the scratch pad line's row, in the
    // lower right, and no vector.  The line is shortened to 29 characters
    // to leave room for it.
    const p = screenOf(mods);
    p.setPollFail(true);
    eq(p.lines.length, 0, 'POLL FAIL draws no vector');
    // A SPACE has no glyph -- it is a beam advance -- so eight are drawn.
    eq(text(p.drawn), 'POLLFAIL', 'POLL FAIL reads POLL FAIL');
    eq(cell(p.drawn[0]), '42,27', 'POLL FAIL starts in the lower right');

    // Neither is a precondition of the other: an IDP that is polled but not
    // filled shows the “X” with the corner clear, and one that is filled but
    // not polled shows the corner with no “X”.
    ok(!x.curData.pollFail, 'the big X leaves POLL FAIL alone');
    ok(!p.curData.bigX, 'POLL FAIL leaves the big X alone');

    // Each geometry group is its own, so either indication comes down while
    // the other stands.  A cleared group is empty; a standing one is not.
    const both = screenOf(mods);
    both.setBigX(true);
    both.setPollFail(true);
    eq(marks(both.geo_bigX), 2, 'an unassigned IDP shows the big X...');
    eq(marks(both.geo_pollFail), 8, '...and POLL FAIL at the same time');
    both.setBigX(false);
    eq(marks(both.geo_bigX), 0, 'the big X comes down on its own...');
    eq(marks(both.geo_pollFail), 8, '...leaving POLL FAIL standing');
    both.setBigX(true);
    both.setPollFail(false);
    eq(marks(both.geo_pollFail), 0, 'and POLL FAIL comes down on its own...');
    eq(marks(both.geo_bigX), 2, '...leaving the big X standing');

    // POLL FAIL shares the scratch pad line and shortens it; the big “X”
    // crosses the whole screen and does not.
    const spl = new mods.spl.SPL({pollFail: false});
    eq(spl.limit(), mods.spl.SPL_MAX, 'a clear line takes 39 characters');
    spl.pollFail = true;
    eq(spl.limit(), mods.spl.SPL_MAX_POLL_FAIL,
       'POLL FAIL takes ten of them off');

    // "the DEU will reset the SPL and display POLL FAIL", and on the first
    // valid chained time-fill and poll "the POLL FAIL message will be
    // removed from the display and the DEU will reset the SPL"
    // (USA005350 Rev.B §3.2.15.2).  So an entry does not survive either
    // edge, and keystrokes taken while POLL FAIL stood never reach the GPC.
    const ITEM = 0x14, D1 = 0x01, D2 = 0x02, D3 = 0x03;
    const pf = screenOf(mods);
    pf.spl = new mods.spl.SPL({pollFail: false});
    for (const c of [ITEM, D1, D2]) pf.spl.press(c);
    eq(pf.spl.line, ' ITEM 12', 'an entry stands on the line');
    pf.setPollFail(true);
    eq(pf.spl.line, ' ', 'POLL FAIL coming up resets it');
    for (const c of [ITEM, D3]) pf.spl.press(c);            // typed while down
    eq(pf.spl.line, ' ITEM 3', '...a fresh entry is still accepted');
    pf.setPollFail(false);
    eq(pf.spl.line, ' ', '...and POLL FAIL going away resets it again');
    pf.spl.press(ITEM);
    pf.setPollFail(false);
    eq(pf.spl.line, ' ITEM', 'an unchanged POLL FAIL leaves the line alone');

    console.log(`test_meds_pollfail: ${pass} passed, ${fail} failed`);
    process.exit(fail ? 1 : 0);
}

main().catch((e) => { console.error(e); process.exit(1); });
