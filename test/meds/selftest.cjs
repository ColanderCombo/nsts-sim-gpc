// test_meds_selftest.cjs — the DEU stand-alone self test.
//
// The specification (STS-83-0020V2-34/sect.4.6.8) gives the display in
// inches and degrees per second.  These tests assert the two properties
// that let it be built at all: at 7/1024 inch to the addressable unit every
// DIMENSION is a whole number of units, and at 55 Hz every RATE is a whole
// number of steps per refresh frame.  If either fails, the model of the
// machine is wrong -- so this is a check on the model, not on the drawing
// code.
//
// Usage:
//   cd ext/sim && node test/test_meds_selftest.cjs
//
// Exit status is 1 iff any test failed.
'use strict';

const path = require('path');
const os = require('os');
const esbuild = require('esbuild');
const coffeePlugin = require('esbuild-coffeescript');

const SIM = path.resolve(__dirname, '..');

async function bundle(rel) {
    const out = path.join(os.tmpdir(),
        `meds.test.${path.basename(rel).replace(/\W/g, '_')}.${process.pid}.cjs`);
    await esbuild.build({
        absWorkingDir: SIM,
        entryPoints: [path.join(SIM, rel)],
        bundle: true, platform: 'node', format: 'cjs', target: 'node20',
        outfile: out,
        plugins: [coffeePlugin({})],
        loader: {'.asm': 'text'},   // meds/asm: SP-0 assembly source
        resolveExtensions: ['.coffee', '.js', '.ts', '.civet', '.json'],
        external: ['dgram', 'three', 'react', 'electron'],
        logLevel: 'error',
    });
    return require(out);
}

let pass = 0, fail = 0;
function ok(cond, what) {
    if (cond) { pass++; } else { fail++; console.log('FAIL: ' + what); }
}
function eq(a, b, what) { ok(a === b, `${what}: got ${a}, want ${b}`); }
function near(a, b, tol, what) {
    ok(Math.abs(a - b) <= tol, `${what}: got ${a}, want ${b} +/- ${tol}`);
}

async function main() {
    const FCWM = await bundle('meds/deuFCW.coffee');
    const ST = await bundle('meds/deuSelfTest.coffee');
    const f = new FCWM.FCW();
    const st = new ST.SelfTest(f);

    // --- the scale ------------------------------------------------------
    //
    // Every length the specification gives in inches has to land on a whole
    // addressable unit.  These are its numbers, verbatim.
    const AU = FCWM.AU_INCH;
    eq(AU, 7 / 1024, 'one addressable unit is 7/1024 inch');
    eq(Math.round(1024 * AU), 7, 'the grid is seven inches wide');
    const dims = [
        [0.2872 / 2, 21, 'the smallest circle radius'],
        [0.8204 / 2, 60, 'the dashed circle radius'],
        [1.7364 / 2, 127, 'the third circle radius'],
        [2.1876 / 2, 160, 'the largest circle radius'],
        [0.7383, 108, "the windmill square's side"],
        [3.5000, 512, 'the longest brightness line'],
        [0.0068, 1, '...and the shortest'],
        [0.2051, 30, "the bug's inner radius"],
        [0.4102, 60, '...and its outer'],
        [3.3975, 497, 'the horizontal travel'],
        [0.8613, 126, '...and the vertical'],
        [0.0273, 4, 'the resolution tick spacing'],
    ];
    for (const [inches, units, what] of dims) {
        near(inches / AU, units, 0.05, what + ' in units');
    }
    // ...and the module has to be using those numbers.
    eq(ST.CIRCLE_R.join(','), '21,60,127,160', 'the four circle radii');
    eq(ST.BOX, 108, 'the square');
    eq(ST.RAMP_LEN.join(','), '1,2,4,8,16,32,64,128,256,512',
       'the brightness lines double');
    // The squares are the one place the specification contradicts itself:
    // the stated travels are 497 and 126 units, the stated cycles 512 and
    // 128.  The cycles win, because only they make the stated "coincide
    // every fourth cycle" exactly true.
    eq(ST.SQ_H_TRAVEL, 512, 'the horizontal travel follows the stated cycle');
    eq(ST.SQ_V_TRAVEL, 128, '...and so does the vertical');
    eq(ST.BUG_R0, 30, "the bug's hole");
    eq(ST.BUG_R1, 60, '...and its reach');

    // --- the rates ------------------------------------------------------
    //
    // At 55 frames a second each of these is a whole number of steps a
    // frame, and the cycle that falls out is the one the specification
    // quotes.  Getting all of them from integers is the evidence that the
    // refresh rate, the angle field and the intensity register are right.
    eq(ST.FRAME_HZ, 55, 'the refresh rate');

    // The beam grid is modular and the renderer works in character cells, so
    // a column past the format area wraps through zero.  `cellCol` folds the
    // far end of that wrap back to a small negative column, which is what
    // lets anything sit against the left edge of the screen at all.
    eq(ST.X_MIN, 0, 'the drawable area starts at the left of the grid');
    // Unit 0 sits just under one column left of character column 0, so it
    // reads as a small negative -- not as column 107, which is where it used
    // to come out and which is off the right of a 52-column display.
    near(FCWM.cellCol(f.absX(0)), -18 / 19, 0.01, 'unit 0 is just left of column 0');
    near(FCWM.cellCol(f.absX(18)), 0, 0.01, '...and unit 18 is column 0');
    near(FCWM.cellCol(f.absX(18 + 19 * 51)), 51, 0.01, '...and the format area still ends at 51');
    for (const d of [-ST.DIAGONAL_OFFSET, ST.DIAGONAL_OFFSET]) {
        const [a, b] = st._diagonal(d);
        for (const [x, y] of [a, b]) {
            ok(x >= ST.X_MIN - 0.5 && x <= ST.X_MAX + 0.5,
               `diagonal ${d} endpoint x ${x.toFixed(1)} is drawable`);
            ok(y >= -0.5 && y <= ST.Y_MAX + 0.5,
               `diagonal ${d} endpoint y ${y.toFixed(1)} is on the screen`);
        }
    }
    // (14) the revolving letters: 33.84 deg/s, cycle 10.64 s
    near(ST.LETTER_SPIN * 360 / FCWM.ANGLE_UNITS * ST.FRAME_HZ, 33.84, 0.05,
         'the letters revolve at the specified rate');
    near(FCWM.ANGLE_UNITS / ST.LETTER_SPIN / ST.FRAME_HZ, 10.64, 0.02,
         '...and come round in the specified time');
    // (13) the bug: 53.17 deg/s
    near(ST.BUG_SPIN * 360 / FCWM.ANGLE_UNITS * ST.FRAME_HZ, 53.17, 0.05,
         'the bug spins at the specified rate');
    // (11)(12) the squares: 0.374 in/s, cycles 18.62 s and 4.63 s
    near(1 * AU * ST.FRAME_HZ, 0.374, 0.002,
         'a unit a frame is the specified square speed');
    near(ST.SQ_H_CYCLE / ST.FRAME_HZ, 18.62, 0.05,
         'the horizontal square cycles in the specified time');
    near(ST.SQ_V_CYCLE / ST.FRAME_HZ, 4.63, 0.05,
         '...and the vertical one in a quarter of it');
    eq(ST.SQ_H_CYCLE % ST.SQ_V_CYCLE, 0,
       'the two square cycles divide, so they meet at the corner');
    eq(ST.SQ_H_CYCLE / ST.SQ_V_CYCLE, 4, '...every fourth cycle, as specified');
    // (10) the intensity ramp: 2.33 s, and 128 levels in the register
    near(ST.RAMP_PERIOD / ST.FRAME_HZ, 2.33, 0.02,
         'the intensity ramp takes the specified time');
    eq(ST.RAMP_PERIOD, 128, '...one frame per level of a seven-bit register');
    // (15) the windmill: 90 degrees in ~18.2 s off a 10-bit slope field
    near(ST.WINDMILL_CYCLE / ST.FRAME_HZ, 18.2, 0.5,
         'the windmill turns 90 degrees in the specified time');
    eq(ST.WINDMILL_STEPS, 512, '...at one step of a nine-bit slope a frame');

    // The windmill's rate is SPECIFIED as variable, 3.15 deg/s near the
    // diagonals and 6.30 near the perpendicular.  That 2:1 is the signature
    // of stepping a tangent rather than an angle: d(atan m)/dm is 1 at m=0
    // and 1/2 at m=1.  Measure it off the words the module actually emits.
    const eorIndex = (w) => {
        for (let i = w.length - 1; i >= 0; i--) {
            const d = f.decodeFCW(w[i]);
            if (d && d.nm === 'FCW2' && d.v.eor) return i;
        }
        return -1;
    };
    const armAngle = (n) => {
        const w = st.frameWords(n);
        // the windmill's four arms are the last thing drawn, so they sit in
        // the six words each before the end-of-refresh word
        const i = eorIndex(w) - 4 * 6;
        const a = f.decodeFCW(w[i + 3]), b = f.decodeFCW(w[i + 4]);
        eq(a.nm, 'VECA', 'the windmill arm is a vector');
        const major = b.v.negative ? -b.v.len : b.v.len;
        const minor = (a.v.slope / 2) * b.v.len / 512;
        const dx = a.v.yMajor ? minor : major;
        const dy = a.v.yMajor ? major : minor;
        return Math.atan2(Math.abs(dy), Math.abs(dx)) * 180 / Math.PI;
    };
    const RUN = 64;   // one step is below the quantisation of a 54-unit arm
    const perp = Math.abs(armAngle(RUN) - armAngle(0)) / RUN;     // near m = 0
    const diag = Math.abs(armAngle(ST.WINDMILL_STEPS - 1) -
                          armAngle(ST.WINDMILL_STEPS - 1 - RUN)) / RUN;
    near(perp / diag, 2.0, 0.15,
         'the windmill turns twice as fast at the perpendicular as at the diagonal');
    near(perp * ST.FRAME_HZ, 6.30, 0.6, '...6.30 deg/s at the perpendicular');
    near(diag * ST.FRAME_HZ, 3.15, 0.6, '...and 3.15 at the diagonal');

    // ...and it must get there without a seam.  A slope field only carries a
    // ratio up to 1, so the second 45 degrees come from the same field
    // stepped back DOWN with the major axis swapped.  Stepping it up again
    // instead throws the arm back to the perpendicular -- a 45 degree jump
    // at every boundary, which reads as the windmill popping.  The pattern
    // repeats every 90 degrees, so fold the difference into that.
    let worst = 0, worstAt = -1;
    let prev = armAngle(0);
    for (let n = 1; n <= ST.WINDMILL_CYCLE; n++) {
        const a = armAngle(n % ST.WINDMILL_CYCLE);
        let d = (a - prev) % 90;
        if (d > 45) d -= 90;
        if (d < -45) d += 90;
        if (Math.abs(d) > worst) { worst = Math.abs(d); worstAt = n; }
        prev = a;
    }
    // The floor is one unit of quantisation at the arm's tip, atan(1/54) =
    // 1.06 degrees; the seam this catches was 45.
    ok(worst < 3.0,
       `the windmill sweeps continuously: worst step ${worst.toFixed(2)} ` +
       `degrees at frame ${worstAt}, want under 3`);

    // (13) the bug's cycle.  Its stated speed and its stated cycle differ by
    // a factor of four; the cycle is the one taken, so check it holds.
    near(ST.BUG_CYCLE / ST.FRAME_HZ, 26.48, 0.05,
         "the bug's cycle is the specified 26.48 seconds");
    eq(ST.BUG_STEP, 1, '...at one unit a frame');

    // --- what actually gets drawn -----------------------------------------
    //
    // Checking the position words is not enough: a vector's slope is
    // quantised to nine bits, so the beam can finish a long line a unit or
    // two off where it was aimed.  One unit past the edge does not clamp,
    // it wraps to the far side of the modular grid -- a line aimed at the
    // top of the screen came out at cell row 75.  So walk the words the way
    // the renderer does and check every point the beam actually visits.
    const walk = (words, label) => {
        let bx = 0, by = 0, slope = null;
        // Signed: a beam may sit a glyph's width left of the screen edge,
        // because a glyph is drawn to the RIGHT of the position word.
        // The fold is the SCREEN's, not the beam register's: `absX`/`absY`
        // wrap a position round the 1536-unit screen, so the inverse has to
        // as well or a beam past the wrap reads as a large negative.
        const W = FCWM.SCREEN_WRAP;
        // The addressable grid is 1024 x 731 inside a 1536-unit screen, so
        // the fold is at the grid's own extent, not at half the screen:
        // everything above it is a small negative, a glyph's width at most.
        const sign = (v, ext) => (v > ext ? v - W : v);
        const auX = (x) => sign(((x - FCWM.ABS_X_ORIGIN) % W + W) % W,
                                FCWM.AU_WIDTH);
        const auY = (y) => sign(((FCWM.ABS_Y_ORIGIN - y) % W + W) % W,
                                FCWM.AU_HEIGHT);
        // A character's beam position is the middle of its cell, so half a
        // cell of it may hang past the edge of the grid.
        const MX = FCWM.COL_PITCH / 2, MY = FCWM.ROW_PITCH / 2;
        const check = (where) => {
            const x = auX(bx), y = auY(by);
            ok(x >= -MX && x <= ST.X_MAX + MX,
               `${label}: ${where} x ${x} is drawable`);
            ok(y >= -MY && y <= ST.Y_MAX + MY,
               `${label}: ${where} y ${y} is on the screen`);
        };
        for (const w of words) {
            const d = f.decodeFCW(w);
            if (!d) continue;
            const v = d.v;
            if (d.nm === 'XPOS' && !v.translate) { bx = v.x % FCWM.SCREEN_WRAP; check('position'); }
            else if (d.nm === 'YPOS' && !v.translate) { by = v.y % FCWM.SCREEN_WRAP; check('position'); }
            else if (d.nm === 'VECA') slope = v;
            else if (d.nm === 'VECB' && slope) {
                const major = v.negative ? -v.len : v.len;
                const minor = Math.round((slope.slope / 2) * v.len / 512);
                let dx, dy;
                if (slope.yMajor) {
                    dy = major;
                    dx = minor * (slope.signDiffer ? -1 : 1) * (dy < 0 ? -1 : 1);
                } else {
                    dx = major;
                    dy = minor * (slope.signDiffer ? -1 : 1) * (dx < 0 ? -1 : 1);
                }
                bx = (bx + dx + FCWM.SCREEN_WRAP) % FCWM.SCREEN_WRAP;
                by = (by + dy + FCWM.SCREEN_WRAP) % FCWM.SCREEN_WRAP;
                check('vector end');
                slope = null;
            }
        }
    };
    walk(st.staticWords(), 'static');
    for (const n of [0, 137, 512, 728, 1000, 1455]) {
        walk(st.frameWords(n), `frame ${n}`);
    }

    // --- the words --------------------------------------------------------
    const stat = st.staticWords();
    ok(stat.length > 200, 'the static format is a real display');
    ok(stat.length < FCWM.AU_WIDTH * 4, '...that fits the format buffer');
    const kinds = {};
    for (const w of stat) {
        const d = f.decodeFCW(w);
        if (d) kinds[d.nm] = (kinds[d.nm] || 0) + 1;
    }
    eq(kinds.CIRCLE, 4, 'four circles, drawn as circles and not as polygons');
    ok(kinds.CHAR2 > 60, 'and the text');
    // Every position word has to be inside the grid: a coordinate that
    // wrapped would draw on the far side of the screen.  The wrap is the
    // SCREEN's 1536, not the beam register's 2048.
    for (const w of stat.concat(st.frameWords(0), st.frameWords(700))) {
        const d = f.decodeFCW(w);
        if (!d || d.v.translate) continue;
        if (d.nm === 'XPOS') {
            const x = (d.v.x - FCWM.ABS_X_ORIGIN + FCWM.SCREEN_WRAP)
                      % FCWM.SCREEN_WRAP;
            ok(x < FCWM.AU_WIDTH, `X position ${x} is on the screen`);
        } else if (d.nm === 'YPOS') {
            const y = (FCWM.ABS_Y_ORIGIN - d.v.y + FCWM.SCREEN_WRAP)
                      % FCWM.SCREEN_WRAP;
            ok(y < FCWM.AU_HEIGHT, `Y position ${y} is on the screen`);
        }
    }
    // A frame is a fixed shape, so it can be written straight over the last
    // one, and it ends the refresh.
    const n0 = st.frameWords(0).length;
    for (const n of [1, 137, 512, 1023, 4096]) {
        eq(st.frameWords(n).length, n0, `frame ${n} is the same length`);
        ok(eorIndex(st.frameWords(n)) > 0, `frame ${n} ends the refresh`);
    }
    eq(n0, ST.FRAME_WORDS, 'a frame is a fixed number of halfwords');
    // Everything past the end-of-refresh word is padding, so a frame can be
    // written straight over the last one.
    const f0 = st.frameWords(0);
    for (let i = eorIndex(f0) + 1; i < f0.length; i++) {
        eq(f0[i], 0, `halfword ${i} past the end of refresh is a no-op`);
    }
    ok(n0 < 1527, '...that fits the display buffer');

    // --- the character set ------------------------------------------------
    //
    // "All 128 defined symbol elements of the DEU are displayed"
    // (STS-83-0020V2-34/sect.4.6.8 para 9).  USA-003090/Table 8-2 names four
    // of the 128 instead of drawing them -- NULL, SELF TEST, BACKSPACE and
    // CARRIAGE RETURN -- so the display can carry at most 124 shapes, and it
    // carries all of them.  BACKSPACE is on it too, in the plus-or-minus.
    {
        const seen = new Set();
        const scan = (w) => {
            for (const x of w) {
                if ((x & 0xc000) !== 0xc000) continue;
                const g1 = (x >> 7) & 0x7f, g2 = x & 0x7f;
                if (g1) seen.add(g1);
                if (g2) seen.add(g2);
            }
        };
        scan(st.staticWords());
        for (let n = 0; n < 8; n++) scan(st.frameWords(n));
        const absent = [];
        for (let c = 0; c < 128; c++) if (!seen.has(c)) absent.push(c);
        // 0x09 is the one shape the specification's own enumeration of the
        // display leaves out: it is not Greek, not del, not the TACAN
        // symbol, not the diamond and not a Shuttle outline, so it is not
        // among paragraph 9's twenty, and no other paragraph names it.
        eq(absent.map((c) => c.toString(16)).join(' '), '0 3 9 d',
           'only NULL, SELF TEST, CARRIAGE RETURN and 0x09 are absent');
        eq(seen.size, 124, 'every other code is on the display');
        ok(seen.has(0x08), 'BACKSPACE is on it, and draws nothing');
        ok(seen.has(0x7d), '...with the UNDERSCORE it strikes through');
    }

    // The plus-or-minus is not a character.  The set has no glyph for it, it
    // has a BACKSPACE and it has a full-cell UNDERSCORE, and the figure
    // draws a `+` with a rule under it.
    {
        eq(ST.PLUS, 0x2b, 'the plus');
        eq(ST.BACKSPACE, 0x08, 'the backspace');
        eq(ST.UNDERSCORE, 0x7d, 'and the full-cell underscore');
        const w = st.staticWords();
        const want = [ST.PLUS, ST.BACKSPACE, ST.UNDERSCORE];
        let found = false;
        for (let i = 0; i < w.length - 1; i++) {
            if ((w[i] & 0xc000) !== 0xc000) continue;
            const g = [(w[i] >> 7) & 0x7f, w[i] & 0x7f,
                       (w[i + 1] >> 7) & 0x7f, w[i + 1] & 0x7f];
            for (let k = 0; k + 3 <= g.length; k++) {
                if (g.slice(k, k + 3).join() === want.join()) found = true;
            }
        }
        ok(found, 'the bottom line strikes a plus-or-minus from three codes');
    }

    // --- (8) the resolution ticks are characters ---------------------------
    //
    // "The tick marks are short, straight line segments from the symbol
    // generator character matrix", so the character generator's own advance
    // spaces them: MAJOR INCREMENT carries the four-unit pitch, and FCW1's
    // axis bit turns the advance down the screen for the vertical array.
    {
        const n = ST.TICK_BEFORE + ST.TICK_AFTER + 1;
        eq(n, 68, 'sixty-eight positions, the middle one a gap');
        for (const down of [false, true]) {
            const w = st.tickArray(down ? ST.TICK_HORIZONTAL : ST.TICK_VERTICAL,
                                   down);
            const d0 = f.decodeFCW(w[0]);
            eq(d0.nm, 'MAJINC', 'the array sets the character advance');
            eq(d0.v.step, down ? -ST.TICK_STEP : ST.TICK_STEP,
               'to the tick pitch, down the screen or across it');
            eq(f.decodeFCW(w[1]).v.axisY, down ? 1 : 0,
               'and turns the advance onto the other axis to run down');
            let ticks = 0, spaces = 0;
            for (const x of w) {
                if ((x & 0xc000) !== 0xc000) continue;
                for (const g of [(x >> 7) & 0x7f, x & 0x7f]) {
                    if (g === 0x20) spaces++;
                    else if (g) ticks++;
                }
            }
            eq(ticks, n - 1, `${n - 1} marks`);
            eq(spaces, 1, '...and a gap at the centre where they cross');
            ok(w.length < 45, `the array is ${w.length} halfwords`);
        }
        // Drawn as vectors the two arrays cost 804 halfwords, a fifth of the
        // 3657 the format buffer holds.
        const both = st.tickArray(ST.TICK_VERTICAL, false).length +
                     st.tickArray(ST.TICK_HORIZONTAL, true).length;
        ok(both < 100, `both arrays are ${both} halfwords, against 804 as vectors`);
    }

    // The animation repeats: every cycle divides the whole, so the display
    // returns to its starting state.
    const whole = ST.WINDMILL_CYCLE * ST.SQ_H_CYCLE;
    for (const c of [ST.SQ_H_CYCLE, ST.SQ_V_CYCLE, ST.WINDMILL_CYCLE,
                     2 * ST.RAMP_PERIOD]) {
        eq(whole % c, 0, `the ${c}-frame cycle divides the whole`);
    }

    console.log(`test_meds_selftest: ${pass} passed, ${fail} failed`);
    process.exit(fail ? 1 : 0);
}

main().catch((e) => { console.error(e); process.exit(1); });
