// color.cjs — DEU colour, from the FCW3 code to the material the
// stroke is drawn with.
//
// The DEU's normal intensity is 0.72, so every coloured stroke a
// display draws goes down `line`'s reduced-intensity path, which holds a
// ramp per colour.  SPEC 54 sends its target insertion lines as FCW3
// `select=1 color=7` and `select=1 color=56` -- measured on DK1 -- and they
// draw in different colours.
//
// Usage:
//   cd ext/sim && node test/meds/color.cjs
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

// `mduVectorDisplay` reaches the DOM on the way in -- it parses the glyph
// fonts out of SVG at module scope.  None of that is under test here, so it
// is stubbed.
function stubDOM() {
    global.window = { fs, navigator: { userAgent: 'node' } };
    for (const n of ['Path', 'Rect', 'Circle', 'Ellipse', 'Line', 'Polyline',
                     'Polygon', 'Graphics', 'Geometry', 'Element']) {
        const k = `SVG${n}Element`;
        global[k] = function () {};
        global[k].prototype = {};
    }
    global.document = {
        createElementNS: () => ({ style: {} }),
        createElement: () => ({ style: {}, getContext: () => null }),
    };
}

async function bundle(entry) {
    const out = path.join(os.tmpdir(), `deu.color.${process.pid}.cjs`);
    await esbuild.build({
        absWorkingDir: SIM, entryPoints: [entry], bundle: true,
        platform: 'node', format: 'cjs', target: 'node20', outfile: out,
        plugins: [civetPlugin, coffeePlugin({})],
        loader: {'.asm': 'text', '.css': 'text', '.svg': 'text', '.png': 'dataurl'},
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
const hex = (n) => (n == null ? 'none' : '0x' + (n >>> 0).toString(16).padStart(6, '0'));

async function main() {
    stubDOM();
    const shim = path.join(os.tmpdir(), `deu.color.shim.${process.pid}.js`);
    fs.writeFileSync(shim,
        `export * as vd from ${JSON.stringify(path.join(SIM, 'src/meds/mdu/mduVectorDisplay.coffee'))}\n` +
        `export * as dps from ${JSON.stringify(path.join(SIM, 'src/meds/mdu/mduScreen_DPS.coffee'))}\n`);
    const m = await bundle(shim);

    // The display, far enough constructed to choose materials: the palette,
    // the shared uniforms and the caches, and nothing that needs a canvas.
    const d = Object.create(m.vd.VectorDisplay.prototype);
    d.CONFIG = {};
    d.makeConstants();
    const drawnColor = (mesh) => mesh.material._color;
    const coords = [[0, 0], [10, 10]];

    // ---- every code the six-bit field can hold ---------------------------
    //
    // `Screen_DPS._deuColor` answers the codes STS-83-0020V1-34 names and
    // reads the rest as two bits each of R, G and B.  What matters here is
    // that whatever it returns is what gets drawn.
    const deuColor = m.dps.Screen_DPS.prototype._deuColor;
    const NORMAL = 0.72;              // the DEU's undoubled intensity
    let wrong = 0;
    for (let code = 0; code < 64; code++) {
        const want = deuColor(code);
        if (drawnColor(d.line(coords, want, NORMAL)) !== want) wrong++;
    }
    eq(wrong, 0, 'every one of the 64 DEU colours draws in its own colour');

    // ---- the codes a display sends, by the colour the FSSR calls them ----
    //
    // Ten are named outright; 33 and 43 follow the main/inset pairing.  The
    // thirteen carry four colours between them.
    const NAMED = {
        4: 'green', 19: 'green', 40: 'green', 43: 'green',
        7: 'yellow', 21: 'yellow', 54: 'yellow', 56: 'yellow',
        29: 'white', 31: 'white', 33: 'white',
        47: 'cyan', 48: 'cyan',
    };
    for (const [code, name] of Object.entries(NAMED)) {
        eq(hex(deuColor(code)), hex(d.c2h[name]), `colour ${code} is ${name}`);
    }
    eq(new Set(Object.keys(NAMED).map(deuColor)).size, 4,
       'the thirteen flight codes carry four colours');

    // ---- the two SPEC 54 sends, by name ----------------------------------
    for (const code of [7, 56]) {
        const want = deuColor(code);
        eq(hex(drawnColor(d.line(coords, want, NORMAL))), hex(want),
           `SPEC 54's colour ${code} at normal intensity`);
        eq(hex(drawnColor(d.line(coords, want, 1.0))), hex(want),
           `... and doubled`);
    }
    ok(deuColor(7) !== d.c2h.green && deuColor(56) !== d.c2h.green,
       'neither of them is the default green, which is the whole point');

    // ---- intensity still fades, and green is unchanged -------------------
    const op = (mesh) => mesh.material.uniforms.opacity.value;
    ok(op(d.line(coords, deuColor(7), NORMAL)) < op(d.line(coords, deuColor(7), 1.0)),
       'a normal-intensity stroke is fainter than a doubled one');
    eq(op(d.line(coords, d.c2h.green, 1.0)), 1.0, 'a doubled stroke is opaque');
    eq(d.intMats[d.c2h.green].length, d.NINT,
       'the green ramp is still built up front, being most of what is drawn');

    // ---- dashed strokes keep both their colour and their dash ------------
    //
    // A colour outside the c2h palette gets a dash material built for it.
    // SPEC 54's launch window lines are `DASH=ON`.
    const fresh = 0x123456;          // never asked for as a solid stroke
    const dash = d.dashedLine(coords, fresh);
    eq(hex(drawnColor(dash)), hex(fresh), 'a dashed stroke keeps its colour');
    ok(dash.material.uniforms?.dashSize?.value > 0,
       '... and is still dashed');
    ok(d.dashedLine(coords, d.c2h.green).material === d.dashMats[d.c2h.green],
       'a palette colour still takes the material built up front');

    console.log(`test_meds_color: ${pass} passed, ${fail} failed`);
    process.exit(fail ? 1 : 0);
}

main().catch((e) => { console.error(e); process.exit(1); });
