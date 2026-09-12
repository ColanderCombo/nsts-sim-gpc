// render.cjs — the DEU beam interpreter in `meds/mdu/mduScreen_DPS`.
//
// The renderer is a Three.js screen class, so it is driven here through a
// stub `@d` drawing surface that records what was drawn and where.  Under
// test is the beam arithmetic.
//
// The X/Y reference registers (XTRN/YTRN) are held: every position word on
// the axis draws at reference + coordinate, and FCW2's AC5+AC4 gate whether
// they apply at all.  The GPCIPL menu exercises both -- page 2 gates them
// on, writes `YTRN 216`, and falls into the section both pages share,
// lifting it eight rows, then clears the gate before the title and counters,
// which sit on the same lines on both pages.
//
// Usage:
//   cd ext/sim && node test/meds/render.cjs
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

async function bundle(rel) {
    const out = path.join(os.tmpdir(),
        `deu.test.${path.basename(rel).replace(/\W/g, '_')}.${process.pid}.cjs`);
    await esbuild.build({
        absWorkingDir: SIM,
        entryPoints: [path.isAbsolute(rel) ? rel : path.join(SIM, 'src', rel)],
        bundle: true, platform: 'node', format: 'cjs', target: 'node20',
        outfile: out,
        plugins: [civetPlugin, coffeePlugin({})],
        loader: {'.asm': 'text'},   // meds/asm: SP-0 assembly source
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

// A drawing surface that records glyphs.  `str` is
// called with the beam position already converted to character cells.
function stubSurface(THREE, drawn, lines, polys) {
    return {
        c2h: {green: 0x00ff00},
        deuFont: null,
        dirty: false,
        str(x, y, ch, color) { drawn.push({x, y, ch, color}); return new THREE.Object3D(); },
        filledPoly(pts, color) {
            polys.push({pts, color});
            return new THREE.Object3D();
        },
        line(coords, color, intensity) {
            lines.push({coords, color, intensity});
            return new THREE.Object3D();
        },
        dashedLine(coords, color) {
            lines.push({coords, color, dashed: true});
            return new THREE.Object3D();
        },
        flatten(g) { return g; },
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
    const polys = [];
    const screen = Object.create(Screen_DPS.prototype);
    screen.fcw = new mods.fcw.FCW();
    screen.d = stubSurface(THREE, drawn, lines, polys);
    screen.group = new THREE.Object3D();
    // `build` hangs everything drawn in the DEU's own coordinates off this
    // one and gives it the format area's horizontal centring; the geometry
    // below is measured in format-area cells, so the offset does not show
    // in it, but the group has to be there to draw into.
    screen.fmt = new THREE.Object3D();
    screen.group.add(screen.fmt);
    screen._blinkOn = true;
    const opts = Array.isArray(words) ? {} : words;
    screen.drawFCWS(opts.memory ?? words, new THREE.Object3D(), opts);
    drawn.lines = lines;
    drawn.polys = polys;
    return drawn;
}

// The cell a recorded glyph landed in.  `drawFCWS` draws in the DPS format
// area's coordinates, which are the DEU's character cells plus one on each
// axis.  A glyph is drawn from the cell's corner and the beam is the cell's
// middle, so the centre offset comes back off to name the cell.
let GLYPH_OFF = [0, 0];
const at = (drawn, ch) => {
    const g = drawn.find((d) => d.ch === ch);
    if (!g) return 'not drawn';
    return `${Math.round(g.x + GLYPH_OFF[0])},${Math.round(g.y + GLYPH_OFF[1])}`;
};

async function main() {
    global.window = {fs};
    // Three has to come through the same bundle as the renderer -- two
    // copies of it in one process is a warning and two incompatible
    // `Object3D`s.
    const shim = path.join(os.tmpdir(), `deu.test.shim.${process.pid}.js`);
    fs.writeFileSync(shim,
        "export * as three from 'three'\n" +
        `export * as dps from ${JSON.stringify(path.join(SIM, 'src/meds/mdu/mduScreen_DPS.coffee'))}\n` +
        `export * as fcw from ${JSON.stringify(path.join(SIM, 'src/meds/deu/deuFCW.coffee'))}\n` +
        `export * as deu from ${JSON.stringify(path.join(SIM, 'src/meds/deu/deuProto.coffee'))}\n`);
    const mods = await bundle(shim);
    const f = new mods.fcw.FCW();
    GLYPH_OFF = mods.fcw.glyphCentre();

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
    // Both position runs move, the reference being held across both, and
    // the ungated title stays put.
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

    // ---- a lone coordinate word re-homes the other axis --------------------
    //
    // A position word sets and homes the axis it names and returns the beam
    // to home on the other, so a bare YC starts at the block's column.
    // 1041 of the corpus's 3246 YC directives have no XC: SPEC 60
    // writes `XC=2,YC=2,CHAR=(SM COM BUFF),CARRTN,CHAR=(PARAM),
    // YC=9,CHAR=(<50 characters>)`, and that row fills columns 2-51 only
    // from the home column -- five right of it, it runs off the screen.
    const rehome = render(mods, [
        ...f.positionRun(2, 2),
        f.glyphSingle(0x48),                 // 'H' -- the block's home column
        f.carrtn(),
        f.glyphSingle(0x50), f.glyphSingle(0x51),   // 'P','Q' -- move the beam
        f.yPosition(f.cellY(9)),             // a bare YC
        f.glyphSingle(0x52),                 // 'R'
        f.endOfRefresh(),
    ]);
    eq(at(rehome, 'H'), '3,3', 'the block draws at its own column');
    eq(at(rehome, 'R'), '3,10', 'a bare YC returns to it, not the beam');

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
    // step above the first.
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
    // increment, and the rotation walks
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

    // ---- and the colour comes from the rest of that word -------------------
    //
    // FCW3's select bit gates its six-bit code: set, the code is the pen;
    // clear, the pen is the DEU's default.  SPEC 54
    // sends `select=1 color=7` for its target insertion line and
    // `select=1 color=56` for the inset, and `COLOR=DEU` between them.
    const colorAt = (words) => render(mods, [...words,
        ...f.vector(1, 1, 10, 1), f.endOfRefresh()]).lines[0].color;
    const deuColor = mods.dps.Screen_DPS.prototype._deuColor;
    // the default is the surface's own green -- `stubSurface`'s here
    const DEU_GREEN = colorAt([]);
    ok(DEU_GREEN != null, 'a pen with no colour word is the DEU default');
    for (const code of [7, 56, 29, 33]) {
        eq(colorAt([f.colorMode(code)]), deuColor(code),
           `FCW3 select=1 color=${code} sets the pen`);
        ok(colorAt([f.colorMode(code)]) !== DEU_GREEN,
           `... to something other than the default`);
    }
    eq(colorAt([f.colorMode(7), f.colorMode(null)]), DEU_GREEN,
       'COLOR=DEU -- select clear -- puts the default back');
    eq(colorAt([f.colorMode(7), f.colorClear()]), DEU_GREEN,
       '... and so does the static preamble\'s cleared word');

    // ---- double intensity is a colour on MEDS ------------------------------
    //
    // STS-83-0020V1-34/sect.3.1: overbright text is yellow on MEDS, a
    // selected colour stands, and overwrite alone is green.
    const YELLOW = deuColor(54);
    ok(YELLOW !== DEU_GREEN, 'default yellow is a colour of its own');
    eq(colorAt([f.attrMode({intensity: true})]), YELLOW,
       'FCW1 overbright draws default yellow');
    eq(colorAt([f.intensityMode(true)]), YELLOW, 'so does FCW3 bit 6');
    eq(colorAt([f.intensityMode(true, 40)]), YELLOW,
       '... with the default green selected outright too');
    eq(colorAt([f.intensityMode(true, 47)]), deuColor(47),
       'a selected colour is drawn as it is');
    eq(colorAt([f.attrMode({intensity: true}), f.attrMode({})]), DEU_GREEN,
       'and normal intensity is green again');
    // A status indicator: the glyph is yellow, and writing it twice at the
    // same beam leaves it yellow, no brighter.
    const twice = render(mods, [f.attrMode({intensity: true}), f.charMode({}),
        f.xPosition(f.cellX(3)), f.yPosition(f.cellY(3)),
        f.glyphSingle(0x4d), f.glyphSingle(0x08), f.glyphSingle(0x4d),
        f.endOfRefresh()]);
    const ms = twice.filter((d) => d.ch === 'M');
    ok(ms.length >= 1, 'the indicator is drawn');
    ok(ms.every((d) => d.color === YELLOW), 'every write of it is default yellow');

    // ---- the message line draws orange, the display behind it does not ----
    //
    // STS-83-0020V1-34/sect.3.1 makes the fault message line orange under
    // MEDS.  Nothing in the stream says so -- the GPC sends one FCW1 and the
    // text -- so `refresh` runs an FCW3 ahead of the walk, which begins at
    // the message line buffer.  Nothing puts the pen back either: the five
    // setup words every static section opens with do it, the fifth being
    // FCW3 with select clear.
    {
        const THREE = mods.three, DEU = mods.deu;
        const drawn = [], lines = [], polys = [];
        const screen = Object.create(mods.dps.Screen_DPS.prototype);
        screen.fcw = f;
        screen.d = stubSurface(THREE, drawn, lines, polys);
        screen.group = new THREE.Object3D();
        screen.fmt = new THREE.Object3D();
        screen.group.add(screen.fmt);
        screen._blinkOn = true;
        screen.bgFCWS = new Uint16Array(DEU.DEU_MEMORY_WORDS);
        screen.geo_dps_fcws = new THREE.Object3D();
        screen.geo_dps_vdisp = new THREE.Object3D();

        const put = (addr, words) => words.forEach((w, i) => {
            screen.bgFCWS[addr + i] = w & 0xffff;
        });
        // The message line: attributes, position, the position-run lead, a
        // glyph.  It runs out into the zero fill and falls through.
        put(DEU.ADDR.MESSAGE_LINE, [
            f.attrMode({}), f.xPosition(f.cellX(1)), f.yPosition(f.cellY(25)),
            f.noop(), f.glyphSingle(0x4d),               // 'M'
        ]);
        // The display, opening with the five words every static section does.
        put(DEU.ADDR.DISPLAY_HEADER, [
            f.majorInc(19), f.minorInc(-27), f.attrMode({}), f.charMode({}),
            f.colorClear(), f.noop(),
            f.xPosition(f.cellX(1)), f.yPosition(f.cellY(3)),
            f.glyphSingle(0x44),                          // 'D'
            f.endOfRefresh(),
        ]);
        screen.refresh();

        const deuColor = mods.dps.Screen_DPS.prototype._deuColor;
        const glyph = (ch) => drawn.find((d) => d.ch === ch);
        eq(glyph('M')?.color, deuColor(63),
           'the message line draws in the fault colour');
        eq(glyph('D')?.color, screen.d.c2h.green,
           'the display behind it does not');

        // The GPCIPL menu opens with no FCW3, so the colour ends at the
        // display header.
        drawn.length = 0;
        put(DEU.ADDR.DISPLAY_HEADER, [
            f.majorInc(19), f.minorInc(-27), f.attrMode({}), f.charMode({}),
            f.noop(), f.noop(),
            f.xPosition(f.cellX(1)), f.yPosition(f.cellY(3)),
            f.glyphSingle(0x44),                          // 'D'
            f.endOfRefresh(),
        ]);
        screen.refresh();
        eq(glyph('M')?.color, deuColor(63),
           'the message line still draws in the fault colour');
        eq(glyph('D')?.color, screen.d.c2h.green,
           '... and a display that clears no colour of its own is unstained');
    }

    // ---- the alternate character set's landing-site symbols ---------------
    //
    // STS-83-0020V1-34/sect.4.2.1.1 gives a shaded circle in white for
    // alternate landing site 1 and a shaded diamond in cyan for site 2;
    // sect.4.2.1.4 item N sends them as colours 29 and 47.  The circle is
    // drawn round, the diamond four-sided, and both advance the beam.
    {
        const symbol = (code, glyph) => render(mods, [
            f.charMode({alt: true}), f.colorMode(code),
            ...f.positionRun(4, 2),
            f.glyphSingle(glyph), f.glyphPair(0x41, 0x42), f.endOfRefresh(),
        ]);

        const circle = symbol(29, 0x14);
        eq(circle.polys.length, 1, 'symbol 14 draws one solid shape');
        eq(circle.polys[0].color, deuColor(29),
           '... in colour 29, which the FSSR calls white');
        ok(circle.polys[0].pts.length > 8, '... round');
        eq(at(circle, 'A'), '6,3', '... and the beam advanced one column');

        const diamond = symbol(47, 0x15);
        eq(diamond.polys.length, 1, 'symbol 15 draws one solid shape');
        eq(diamond.polys[0].color, deuColor(47),
           '... in colour 47, which the FSSR calls cyan');
        eq(diamond.polys[0].pts.length, 4, '... four-sided');
        eq(at(diamond, 'A'), '6,3', '... and the beam advanced one column');

        // The two are the only alternate symbols with geometry; the rest
        // fall through to their `DEUCharset` counterparts.
        const cross = symbol(29, 0x16);
        eq(cross.polys.length, 0, 'symbol 16 draws no solid shape');
        eq(cross.filter((g) => g.ch).length, 3, '... it draws a glyph');

        // Without ALTCHAR the same code is an ordinary glyph.
        const plain = render(mods, [
            f.charMode({}), ...f.positionRun(4, 2),
            f.glyphSingle(0x14), f.endOfRefresh(),
        ]);
        eq(plain.polys.length, 0, 'code 14 outside ALTCHAR draws no symbol');
    }

    // --- the self test's resolution ticks ---------------------------------
    //
    // "The tick marks are short, straight line segments from the symbol
    // generator character matrix" (STS-83-0020V2-34/sect.4.6.8 para 8), so
    // the spacing is the character generator's own advance: MAJOR INCREMENT
    // carries the four-unit pitch, and FCW1's axis bit turns the advance
    // down the screen for the vertical array.  This walks both through the
    // real interpreter and checks where the marks land.
    {
        const ST = await bundle(path.join(SIM, 'src/meds/deu/deuSelfTest.coffee'));
        const st = new ST.SelfTest(f);
        const COL = mods.fcw.COL_PITCH, ROW = mods.fcw.ROW_PITCH;
        for (const down of [false, true]) {
            const g = down ? ST.TICK_HORIZONTAL : ST.TICK_VERTICAL;
            const marks = render(mods, [...st.tickArray(g, down),
                                        f.endOfRefresh()])
                .filter((d) => d.ch === f.DEUCharset[g]);
            eq(marks.length, ST.TICK_BEFORE + ST.TICK_AFTER,
               `${down ? 'the vertical' : 'the horizontal'} array's marks`);
            // Consecutive marks are one tick pitch apart along the advance
            // axis and nowhere at all along the other.
            const axis = down ? 'y' : 'x';
            const other = down ? 'x' : 'y';
            const pitch = ST.TICK_STEP / (down ? ROW : COL);
            let steps = 0, drift = 0;
            for (let i = 1; i < marks.length; i++) {
                const d = marks[i][axis] - marks[i - 1][axis];
                // The gap at the centre is a space, so one step is double.
                if (Math.abs(d - pitch) < 1e-6 || Math.abs(d - 2 * pitch) < 1e-6) steps++;
                if (Math.abs(marks[i][other] - marks[0][other]) > 1e-6) drift++;
            }
            eq(steps, marks.length - 1, '...are one tick pitch apart');
            eq(drift, 0, '...and stay on one line');
            eq(marks.length - 1 - Math.round(
                 (marks[marks.length - 1][axis] - marks[0][axis]) / pitch), -1,
               '...with one double step, the gap where the arrays cross');
        }
    }

    // ---------------------------------------------------------------
    // A critical format, commanded the way a display commands one.
    //
    // A CRTFMT= background lives in the DEU's format buffer at 0x0100,
    // loaded once off mass memory, and a display selects it by branching
    // to its CFIT slot -- the display's own DEULOC=.  The slot holds a
    // branch to the body, so the picture the crew sees is the body drawn
    // from resident memory, followed by the display's dynamic fields.
    // Nothing but the branch crosses the bus for it.
    const cflm = path.join(SIM, '..', '..', 'build', 'OI340700',
                           'mmusrc', 'DEUCFLM.bin');
    if (fs.existsSync(cflm)) {
        const raw = fs.readFileSync(cflm);
        const CRIT = 0x0100, HDR = 0x19ee;
        const mem = new Array(8192).fill(0);
        for (let i = 0; i * 2 + 1 < raw.length; i++)
            mem[CRIT + i] = raw.readUInt16BE(i * 2);
        eq(mem.length - (CRIT + raw.length / 2) > 0, true,
           'the load module fits the format buffer');

        // Slot 0 is the fault-message background; its CFIT word branches
        // to the body, which is where 'FAULT' is written.
        const slot0 = mem[CRIT];
        eq((slot0 & 0xf000) >> 12, 1, 'a CFIT slot is a branch word');
        const body = slot0 & 0x1fff;
        ok(body > CRIT + 32, 'a CFIT slot branches past the table');

        // Every slot is a branch word, and the image's own branches are
        // self-consistent: a slot's word IS the body's address when the
        // image sits at 0x1100, i.e. slot n's word is 0x1000 + its offset
        // in the image + 0x100.
        //
        // The last two of the 32 CFIT halfwords are the exit stub every
        // background body branches to when it is done; they leave the format
        // buffer for the display header, which a branch word alone cannot.
        let bad = 0;
        for (let i = 0; i < 30; i++) {
            const w = mem[CRIT + i];
            if ((w & 0xf000) !== 0x1000) { bad++; continue; }
            const off = (w & 0x0fff) - 0x100;     // offset into the image
            if (off < 32 || off >= raw.length / 2) bad++;
        }
        eq(bad, 0, 'all 30 CFIT slots branch into the image');
        eq(mem[CRIT + 30], 0x2100,
           'the exit stub leads with a SUBLIST naming the display sector');
        eq(mem[CRIT + 31], 0x19ee, '...and branches to the display header');
        // 0x111E, the word each body ends on and the buffer is padded with,
        // is the branch to that stub.
        eq(0x1000 | ((CRIT + 30) & 0xfff), 0x111e,
           'the body terminator addresses the stub');

        // Read as the interpreter reads them -- a branch word carries the
        // whole 13-bit address -- the slots name 0x1120 and up, so the
        // image has to sit at 0x1100 for its own branches to resolve.
        const hi = new Array(8192).fill(0);
        for (let i = 0; i * 2 + 1 < raw.length; i++)
            hi[0x1100 + i] = raw.readUInt16BE(i * 2);
        hi[HDR] = f.branch(0x1100);
        const drawnHi = render(mods, {memory: hi, start: HDR});
        const textHi = drawnHi.map((d) => d.ch).join('');
        ok(drawnHi.length > 0, 'commanding a critical format draws something');
        ok(textHi.includes('FAULT'),
           `the format's own text is drawn (got ${JSON.stringify(textHi.slice(0, 40))})`);

        // ...and it is the RESIDENT copy drawing it: cleared, the same
        // command draws nothing.
        const empty = new Array(8192).fill(0);
        empty[HDR] = f.branch(0x1100);
        eq(render(mods, {memory: empty, start: HDR}).length, 0,
           'an unloaded format buffer draws nothing');

        // And at 0x0100, where the GPC IPL program loads it and
        // where every display's DEULOC= points (256..271, the sixteen
        // slots), commanded the way a display commands one: the pair
        // `[0x2000, Branch(DEULOC)]` that dfg emits for an external
        // background.  A branch word alone cannot reach the lower 4K --
        // the op-2 lead word's sector is what gets there.
        for (const [slot, want] of [[0, 'GPC'], [3, 'TGO'], [7, 'DESIRED']]) {
            mem[HDR] = 0x2000;                       // SUBLIST: sector 0
            mem[HDR + 1] = f.branch(CRIT + slot);    // ...of this slot
            const d = render(mods, {memory: mem, start: HDR});
            const t = d.map((g) => g.ch).join('');
            ok(t.includes(want),
               `slot ${slot} (DEULOC ${256 + slot}) draws its background `
               + `(want ${want}, got ${JSON.stringify(t.slice(0, 30))})`);
        }
        // A bare branch still cannot: it names the upper 4K only.
        mem[HDR] = f.branch(CRIT); mem[HDR + 1] = 0;
        eq(render(mods, {memory: mem, start: HDR}).length, 0,
           'a branch word alone does not reach the format buffer');
    } else {
        console.log('SKIP  build/OI340700/mmusrc/DEUCFLM.bin not built '
                    + "(con80build --critfmt)");
    }

    // ---- a background the display unit holds ----------------------------
    //
    // Some displays keep no background in the GPC at all: their whole static
    // section is one VDISP word naming a picture the unit already has.  The
    // interpreter cannot draw it inline -- it is a different word list -- so
    // it collects the code and `refresh` draws what it collected.
    {
        const collected = [];
        const drawn = render(mods, {
            memory: (() => {
                const m = new Array(8192).fill(0);
                m[0x19ee] = f.valueDisplay(158);
                m[0x19ef] = f.endOfRefresh();
                return m;
            })(),
            start: 0x19ee,
            vdisp: collected,
        });
        eq(collected.join(','), '158', 'a VDISP word yields its code');
        eq(drawn.length, 0, '...and draws nothing by itself');
    }

    // The pictures themselves ship beside the fonts, `dfg --dfb` having
    // recovered each from the release that last carried it inline.  A blank
    // draws nothing, so the title runs together here.
    for (const [file, want] of [['VDISP-158-DPS_UTILITY.dfb', 'DPSUTILITY'],
                                ['VDISP-153-HORIZ_SIT_COMMON.dfb', 'HORIZSIT']]) {
        const pth = path.join(SIM, 'data', file);
        if (!fs.existsSync(pth)) { console.log(`SKIP  data/${file}`); continue; }
        const words = mods.fcw.wordsFromBytes(fs.readFileSync(pth));
        const text = render(mods, words).map((d) => d.ch).join('');
        ok(text.includes(want),
           `data/${file} draws ${want} (got ${JSON.stringify(text.slice(0, 24))})`);
    }

    console.log(`test_meds_render: ${pass} passed, ${fail} failed`);
    process.exit(fail ? 1 : 0);
}

main().catch((e) => { console.error(e); process.exit(1); });
