// test_meds_render.cjs — the DEU beam interpreter in `meds/mduScreen_DPS`.
//
// The renderer is a Three.js screen class, so it is driven here through a
// stub `@d` drawing surface that records what was drawn and where instead of
// building geometry.  What is under test is the beam arithmetic, not the
// scene.
//
// The case that matters is the X/Y REFERENCE registers (the flight macros'
// `XTRN`/`YTRN`).  They are HELD -- every position word on the axis draws at
// reference + coordinate -- and FCW2's AC5+AC4 gate whether they apply at
// all.  GPCIPL page 2 uses both facts at once: it gates them on, writes
// `YTRN 216`, and falls into the section both menu pages share, which lifts
// that whole section eight rows -- item text and the item asterisks spliced
// into it alike -- and then clears the gate before the title and the
// counters, which sit on the same lines on both pages.
//
// Getting either half wrong is visible on the screen: a reference spent by
// the next position word moves the item text and leaves the asterisks
// behind, and one with no gate drags the title off the top.
//
// Usage:
//   cd ext/sim && node test/test_meds_render.cjs
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

// A drawing surface that records glyphs instead of drawing them.  `str` is
// called with the beam position already converted to character cells.
function stubSurface(THREE, drawn) {
    return {
        c2h: {green: 0x00ff00},
        deuFont: null,
        dirty: false,
        str(x, y, ch) { drawn.push({x, y, ch}); return new THREE.Object3D(); },
        line() { return new THREE.Object3D(); },
        dashedLine() { return new THREE.Object3D(); },
    };
}

// Walk a word list through the real interpreter and return what it drew.
function render(mods, words) {
    const {Screen_DPS} = mods.dps;
    const THREE = mods.three;
    const drawn = [];
    const screen = Object.create(Screen_DPS.prototype);
    screen.fcw = new mods.fcw.FCW();
    screen.d = stubSurface(THREE, drawn);
    screen.group = new THREE.Object3D();
    screen._blinkOn = true;
    screen.drawFCWS(words, new THREE.Object3D());
    return drawn;
}

// The cell a recorded glyph landed in.  `drawFCWS` draws in the DPS format
// area's coordinates, which are the DEU's character cells plus one on each
// axis.
const at = (drawn, ch) => {
    const g = drawn.find((d) => d.ch === ch);
    return g ? `${Math.round(g.x)},${Math.round(g.y)}` : 'not drawn';
};

async function main() {
    global.window = {fs};
    // Three has to come through the same bundle as the renderer -- two
    // copies of it in one process is a warning and two incompatible
    // `Object3D`s.
    const shim = path.join(os.tmpdir(), `deu.test.shim.${process.pid}.js`);
    fs.writeFileSync(shim,
        "export * as three from 'three'\n" +
        `export * as dps from ${JSON.stringify(path.join(SIM, 'meds/mduScreen_DPS.coffee'))}\n` +
        `export * as fcw from ${JSON.stringify(path.join(SIM, 'meds/deuFCW.coffee'))}\n`);
    const mods = await bundle(shim);
    const f = new mods.fcw.FCW();

    // A miniature of the GPCIPL menu's shared section: a gated Y reference,
    // two separate position runs under it, then the gate cleared and a third
    // run that must not move.  `A` stands for the item text, `*` for the
    // asterisk spliced in beside it, `T` for the page title.
    const list = (yref) => [
        0x301e,                              // FCW2: AC5+AC4 -- gate the reference
        f.translateY(yref),                  // YTRN
        f.xPosition(f.cellX(1)),
        f.yPosition(f.cellY(11)),
        f.glyphSingle(0x41),                 // 'A' -- the item line
        f.xPosition(f.cellX(23)),
        f.yPosition(f.cellY(13)),
        f.glyphSingle(0x2a),                 // '*' -- ASTERISK, its own YPOS
        0x3002,                              // FCW2: AC5+AC4 clear -- ungated
        f.xPosition(f.cellX(30)),
        f.yPosition(f.cellY(1)),
        f.glyphSingle(0x54),                 // 'T' -- the shared title
        f.endOfRefresh(),
    ];

    // Page 1: the reference is zero, so everything draws where it is written.
    const p1 = render(mods, list(0));
    eq(at(p1, 'A'), '2,12', 'page 1 item text on its own row');
    eq(at(p1, '*'), '24,14', 'page 1 asterisk on its own row');
    eq(at(p1, 'T'), '31,2', 'page 1 title');

    // Page 2: `YTRN 216` = 8 x ROW_PITCH lifts the gated block eight rows.
    // Both position runs move -- the reference is held, not spent by the
    // first of them -- and the ungated title stays put.
    const p2 = render(mods, list(8 * 27));
    eq(at(p2, 'A'), '2,4', 'page 2 lifts the item text eight rows');
    eq(at(p2, '*'), '24,6', 'page 2 lifts the asterisk with it');
    eq(at(p2, 'T'), '31,2', 'page 2 leaves the ungated title alone');

    // The same reference value with the gate never set changes nothing.
    const ungated = render(mods, [
        0x3002,
        f.translateY(8 * 27),
        f.xPosition(f.cellX(1)),
        f.yPosition(f.cellY(11)),
        f.glyphSingle(0x41),
        f.endOfRefresh(),
    ]);
    eq(at(ungated, 'A'), '2,12', 'an ungated reference does not move the beam');

    console.log(`test_meds_render: ${pass} passed, ${fail} failed`);
    process.exit(fail ? 1 : 0);
}

main().catch((e) => { console.error(e); process.exit(1); });
