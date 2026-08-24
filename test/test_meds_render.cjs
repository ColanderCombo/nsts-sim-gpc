// test_meds_render.cjs — the DEU beam interpreter in `meds/mduScreen_DPS`.
//
// The renderer is a Three.js screen class, so it is driven here through a
// stub `@d` drawing surface that records what was drawn and where instead of
// building geometry.  What is under test is the beam arithmetic, not the
// scene.
//
// The X/Y reference registers (XTRN/YTRN) are held: every position word on
// the axis draws at reference + coordinate, and FCW2's AC5+AC4 gate whether
// they apply at all.  The GPCIPL menu exercises both -- page 2 gates them
// on, writes `YTRN 216`, and falls into the section both pages share,
// lifting it eight rows, then clears the gate before the title and counters,
// which sit on the same lines on both pages.
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
function hex(n) { return '0x' + (n & 0xffff).toString(16).padStart(4, '0'); }

// A drawing surface that records glyphs instead of drawing them.  `str` is
// called with the beam position already converted to character cells.
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

// Walk a word list through the real interpreter and return what it drew.
// `words` is either a word list drawn from index 0, or {memory, start} for a
// walk that follows branches through a memory image.
function render(mods, words) {
    const {Screen_DPS} = mods.dps;
    const THREE = mods.three;
    const drawn = [];
    const lines = [];
    const screen = Object.create(Screen_DPS.prototype);
    screen.fcw = new mods.fcw.FCW();
    screen.d = stubSurface(THREE, drawn, lines);
    screen.group = new THREE.Object3D();
    screen._blinkOn = true;
    const opts = Array.isArray(words) ? {} : words;
    screen.drawFCWS(opts.memory ?? words, new THREE.Object3D(), opts);
    drawn.lines = lines;
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

    // ---- the circle ------------------------------------------------------
    //
    // One word draws a circle about the beam and does not move it.  Beam
    // units are square, so in character cells it is an ellipse: 19 units
    // to the column, 27 to the row.
    const R = 54;                            // beam units = 2 rows, ~2.84 cols
    const circ = render(mods, [
        ...f.positionRun(20, 10),
        ...f.circleRun(R),
        f.glyphSingle(0x5a),                 // 'Z' -- the beam has not moved
        f.endOfRefresh(),
    ]);
    eq(circ.lines.length, 1, 'the circle word draws one closed figure');
    const pts = circ.lines[0].coords;
    ok(pts.length > 16, `the circle is polygonised (${pts.length} points)`);
    const xs = pts.map((p) => p[0]), ys = pts.map((p) => p[1]);
    const mid = (v) => (Math.min(...v) + Math.max(...v)) / 2;
    const half = (v) => (Math.max(...v) - Math.min(...v)) / 2;
    eq(`${mid(xs).toFixed(2)},${mid(ys).toFixed(2)}`, '21.00,11.00',
        'the circle is centred on the beam');
    eq(half(xs).toFixed(3), (R / 19).toFixed(3), 'and is R/19 cells wide');
    eq(half(ys).toFixed(3), (R / 27).toFixed(3), '... and R/27 cells tall');
    eq(at(circ, 'Z'), '21,11', 'the circle leaves the beam where it was');

    // ---- the land-site label ---------------------------------------------
    //
    // Three characters from an op 6 pair, drawn at the beam one column
    // apart.
    const ls = render(mods, [
        ...f.positionRun(4, 6),
        ...f.lsiteWords('EDW'),
        f.endOfRefresh(),
    ]);
    eq(ls.map((d) => d.ch).join(''), 'EDW', 'the land-site label draws');
    eq(at(ls, 'E'), '5,7', 'at the beam');
    eq(at(ls, 'W'), '7,7', 'three columns of it');

    // ---- rotation turns the advance too ----------------------------------
    //
    // A quarter turn stands the string up: the second glyph is a major
    // step above the first, not to its right.
    const rot = render(mods, [
        ...f.positionRun(10, 20),
        f.rotation(90),
        f.charMode({rotated: true}),
        f.glyphPair(0x41, 0x42),             // 'A' then 'B'
        f.endOfRefresh(),
    ]);
    const [ra, rb] = ['A', 'B'].map((c) => rot.find((d) => d.ch === c));
    ok(Math.abs(rb.x - ra.x) < 1e-6, 'a rotated string does not walk sideways');
    ok(rb.y < ra.y, 'it walks up the screen');
    eq((ra.y - rb.y).toFixed(3), (19 / 27).toFixed(3), 'by one major step');

    // ---- the angle increment ----------------------------------------------
    //
    // With FCW2's increment bit set, an op 5 word writes the angle
    // increment rather than the character advance, and the rotation walks
    // on per glyph.  The first advance is square; the second is turned by
    // the increment.
    const STEP = 4095;                       // 4095 * 360/32768 = 45 degrees
    const inc = render(mods, [
        ...f.positionRun(10, 20),
        f.charMode({rotated: true}) | 0x0100,   // FCW2 with the increment bit
        f.angleInc(STEP),
        f.glyphPair(0x41, 0x42),
        f.glyphSingle(0x43),
        f.endOfRefresh(),
    ]);
    const [ia, ib, ic] = ['A', 'B', 'C'].map((c) => inc.find((d) => d.ch === c));
    eq((ib.x - ia.x).toFixed(3), '1.000', 'the first glyph advances square');
    eq((ib.y - ia.y).toFixed(3), '0.000', '... with no rise');
    const th = 2 * Math.PI * STEP / 32768;
    eq((ic.x - ib.x).toFixed(3), Math.cos(th).toFixed(3),
        'the second advance is turned by the increment');
    eq((ib.y - ic.y).toFixed(3), (Math.sin(th) * 19 / 27).toFixed(3),
        '... and rises by its sine');

    // ---- SUBLIST ----------------------------------------------------------
    //
    // `SUBLIST count` + a branch word: draw `count` words from the target,
    // then resume after the branch word.  Drawn with the registers the
    // surrounding text left set, so the run continues the line it sits in.
    const mem = new Array(0x2000).fill(0);
    let q = 0x1040;
    for (const w of f.positionRun(1, 1)) mem[q++] = w;
    mem[q++] = f.glyphPair(0x41, 0x42);             // AB
    const [slw, slb] = f.subList(2, 0x1810);
    mem[q++] = slw;
    mem[q++] = slb;
    mem[q++] = f.glyphPair(0x59, 0x5a);             // YZ, after the return
    mem[q++] = f.endOfRefresh();
    mem[0x1810] = f.glyphPair(0x43, 0x44);          // CD
    mem[0x1811] = f.glyphPair(0x45, 0x46);          // EF
    mem[0x1812] = f.glyphPair(0x47, 0x48);          // GH, past the count

    eq(hex(slw), '0x2102', 'the splice word carries sector 1 and a count of 2');
    const spliced = render(mods, {memory: mem, start: 0x1040});
    eq(spliced.map((d) => d.ch).join(''), 'ABCDEFYZ',
        'the run is drawn inline and execution resumes after the branch');
    eq(at(spliced, 'C'), '4,2', 'the spliced run continues the line');
    eq(at(spliced, 'Y'), '8,2', 'and the beam carries on past it');

    // ---- intensity comes from either feature control word ------------------
    //
    // FCW1 bit 3 and FCW3 bit 6 both mean double intensity.
    const lineAt = (words) => render(mods, [...words,
        ...f.vector(1, 1, 10, 1), f.endOfRefresh()]).lines[0].intensity;
    ok(lineAt([]) < 1.0, 'a plain line is not overbright');
    eq(lineAt([f.attrMode({intensity: true})]), 1.0, 'FCW1 bit 3 is overbright');
    eq(lineAt([f.intensityMode(true)]), 1.0, 'so is FCW3 bit 6');

    console.log(`test_meds_render: ${pass} passed, ${fail} failed`);
    process.exit(fail ? 1 : 0);
}

main().catch((e) => { console.error(e); process.exit(1); });
