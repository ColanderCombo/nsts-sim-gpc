// test_meds_fcw.cjs — the DEU Format Control Word codec.
//
// Every word here is built from the encoding rules, not lifted from any
// display: the point is that encode and decode agree with each other and
// with the arithmetic in the specification (screen geometry, the
// subtractive REPEAT count, the two's-complement step words, the vector
// slope quantisation).
//
// Usage:
//   cd ext/sim && node test/test_meds_fcw.cjs
//
// Exit status is 1 iff any test failed.
'use strict';

const path = require('path');
const os = require('os');
const fs = require('fs');
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
function eq(a, b, what) {
    ok(a === b, `${what}: got ${a}, want ${b}`);
}
function hex(n) { return '0x' + (n & 0xffff).toString(16).padStart(4, '0'); }

async function main() {
    const M = await bundle('meds/deuFCW.coffee');
    const f = new M.FCW();

    // screen geometry
    //
    // Cell column c sits at 1573 + 19c, row r at 364 - 27r on a 2048-unit
    // modular grid, and the normalising transforms take those back to cell
    // units.  Calibrated against live flight output: all 28 coordinate
    // words in a running GPCIPL menu land exactly on a cell boundary.
    eq(f.cellX(0), 1573, 'cell column 0');
    eq(f.cellX(19), 1573 + 19 * 19, 'cell column 19');
    eq(f.cellY(0), 364, 'cell row 0');
    eq(f.cellY(1), 364 - 27, 'cell row 1');
    // Column 51 is the right-hand edge of the format area; column 25 is the
    // beam origin, so the low columns are the ones that wrap.
    eq(f.cellX(51), (1573 + 19 * 51) % 2048, 'cell column 51 wraps');
    eq(f.cellX(25), 0, 'cell column 25 is beam zero');
    for (const c of [0, 5, 19, 35, 50]) {
        eq(Math.round(M.screenX(f.cellX(c)) - M.screenX(f.cellX(0))), c,
            `screenX round-trips cell column ${c}`);
    }
    for (const r of [0, 1, 13, 25]) {
        eq(Math.round(M.screenY(f.cellY(r))), r, `screenY round-trips cell row ${r}`);
    }
    // The absolute (`nnnA`) form and the cell form share one origin: cell
    // column 0 is absolute X 18, cell row 0 absolute Y 0.
    eq(f.absX(18), f.cellX(0), 'absolute X 18 is cell column 0');
    eq(f.absY(0), f.cellY(0), 'absolute Y 0 is cell row 0');

    // op 0: the no-op and REPEAT share the opcode
    //
    const noop = f.decodeFCW(f.noop());
    eq(noop.nm, 'NOOP', 'the all-zero word is the no-op');
    // the mask ordering has to put the whole-word no-op ahead of REPEAT,
    // which shares op 0 -- a lexicographic sort of the masks does not.
    for (const n of [1, 7, 63, 64]) {
        const w = f.repeat(n);
        const d = f.decodeFCW(w);
        eq(d.nm, 'REPT', `repeat ${n} decodes as REPT`);
        eq(d.v.count, n, `repeat ${n} count`);
        eq(w, (0x0841 - n) & 0xffff, `repeat ${n} is subtractive`);
    }
    eq(f.encodeFCW({nm: 'REPT', count: 7}), 0x083a, 'REPEAT 7 encodes');

    // op 1: branch
    //
    // The target is THIRTEEN bits: op 1's bottom bit is address bit 12, so
    // the branch word and the fill-address header are the same encoding.
    // Measured on a live GPCIPL display -- all 55 branch words in DEU memory
    // point inside the two written regions read as 13 bits and every one of
    // them lands on empty memory read as 12.
    const br = f.decodeFCW(f.branch(0x111e));
    eq(br.nm, 'BRANCH', 'branch decodes');
    eq(br.v.addr, 0x111e, 'branch target is the whole 13-bit address');
    eq(br.v.addr12, 0x11e, 'the raw 12-bit field is kept for the record');
    eq(f.branch(0x19ee), 0x19ee, 'a branch to the display header is 0x19EE');
    eq(f.branch(0x9ee), 0x19ee, 'and bit 12 cannot be cleared: 0x9EE reads the same');
    eq(f.deuReturn(), 0x19ee, 'deuReturn');

    // op 2: SUBLIST, the variable-field splice
    //
    // `SUBLIST count` + `BRANCH addr`: draw `count` words from `addr`, then
    // carry on after the branch word.  Taken from a live GPCIPL display,
    // where 0x2107 + 0x1AAA splices the seven words at 0x1AAA into the menu
    // line to give " MEMORY PURGE".  The count is literal, not less one.
    const sl = f.decodeFCW(0x2107);
    eq(sl.nm, 'SUBLIST', 'op 2 decodes');
    eq(sl.v.count, 7, 'the count is literal');
    eq(f.decodeFCW(f.subList(7, 0x1aaa)[1]).v.addr, 0x1aaa, 'its branch word');
    eq(f.subList(7, 0x1aaa)[0], 0x2107, 'and the pair round-trips');

    // op 3: the four mode registers
    //
    // All four share the op nibble and are told apart by bits 11-10, so a
    // decode that got the selector wrong would show up here.
    const attrs = f.decodeFCW(f.attrMode({}));
    eq(attrs.nm, 'FCW1', 'plain attribute word is FCW1');
    eq(f.attrMode({}), 0x3800, 'attributes all off');
    for (const [k, bit] of [['dash', 0x200], ['blink', 0x100],
                            ['axisY', 0x020], ['intensity', 0x008]]) {
        const w = f.attrMode({[k]: true});
        eq(w, 0x3800 | bit, `attribute ${k} bit`);
        const d = f.decodeFCW(w);
        eq(d.nm, 'FCW1', `attribute ${k} still decodes as FCW1`);
        eq(d.v[k], 1, `attribute ${k} reads back`);
    }

    eq(f.charMode({}), 0x3006, 'small upright characters');
    eq(f.charMode({large: true}), 0x3007, 'large upright characters');
    // Rotation clears the upright bit, so rotated modes read 2 and 3.
    eq(f.charMode({rotated: true}), 0x3002, 'small rotated characters');
    eq(f.charMode({large: true, rotated: true}), 0x3003, 'large rotated characters');
    eq(f.charMode({alt: true}), 0x3046, 'alternate character set');
    eq(f.charMode({alt: true, rotated: true}), 0x3062, 'alternate set, rotated');
    const cm = f.decodeFCW(f.charMode({large: true}));
    eq(cm.nm, 'FCW2', 'character mode is FCW2');
    eq(cm.v.mode, 7, 'large character mode code');
    eq(f.decodeFCW(f.vectorBegin()).v.mode, 5, 'vector mode code');

    // FCW2's ten bits are EOR, INCR, DLY, POLRX, POLRY, AC5..AC1, and AC5
    // with AC4 gate the X/Y REFERENCE registers -- `XTRN`/`YTRN` warn "X-Y
    // REFRENCES NOT GATED IN FCW2" without them.  Both words below are
    // lifted from the GPCIPL menu, which gates them on to write the
    // registers and off again where the offset must stop.
    const gateOn = f.decodeFCW(0x301e);
    eq(gateOn.nm, 'FCW2', 'the gating word is an FCW2');
    eq(gateOn.v.xyRef, 3, 'AC5 and AC4 set -- the X/Y reference applies');
    eq(gateOn.v.mode, 6, 'and it still selects small characters');
    const gateOff = f.decodeFCW(0x3002);
    eq(gateOff.v.xyRef, 0, 'AC5 and AC4 clear -- the reference is ignored');
    eq(f.decodeFCW(f.charMode({})).v.xyRef, 0,
        'a plain character mode word does not gate the reference');

    const col = f.decodeFCW(f.colorMode(31));
    eq(col.nm, 'FCW3', 'colour word is FCW3');
    eq(col.v.select, 1, 'an explicit colour sets select');
    eq(col.v.color, 31, 'colour code');
    // COLOR=DEU restores the DEU default: select off, and the default word
    // carries code 40 rather than zero.
    const cdeu = f.decodeFCW(f.colorMode(null));
    eq(cdeu.v.select, 0, 'the DEU default clears select');
    eq(cdeu.v.color, 40, 'the DEU default carries code 40');
    eq(f.colorClear(), 0x3400, 'the static preamble colour word is bare');

    const vd = f.decodeFCW(f.valueDisplay(0x2a5));
    eq(vd.nm, 'VDISP', 'value display');
    eq(vd.v.vdisp, 0x2a5, 'value display code');

    // op 4: character rotation
    //
    for (let q = 0; q < 4; q++) {
        const d = f.decodeFCW(f.rotation(q));
        eq(d.nm, 'ROT', `rotation ${q * 90} degrees decodes`);
        eq(d.v.quarterTurns, q, `rotation ${q * 90} degrees`);
    }

    // op 5 / 7: the spacing steps, two's complement
    //
    // These are register writes, not motion: MAJINC is the per-glyph
    // advance, MININC the carriage-return step.  Both are signed and the
    // negative ones are the common case (rows run downward).
    for (const s of [19, 24, -19, -27, -32, 1023, -1024]) {
        const d = f.decodeFCW(f.majorInc(s));
        eq(d.nm, 'MAJINC', `major increment ${s} decodes`);
        eq(d.v.step, s, `major increment ${s} sign-extends`);
    }
    for (const s of [19, -27, -32, 127, -128]) {
        const d = f.decodeFCW(f.minorInc(s));
        eq(d.nm, 'MININC', `minor increment ${s} decodes`);
        eq(d.v.step, s, `minor increment ${s} sign-extends`);
    }
    // bit 11 is set in every minor-increment word the DFG emits; without
    // it the word is not a minor increment we know how to draw.
    ok((f.minorInc(-27) & 0x0800) !== 0, 'minor increment sets bit 11');
    eq(f.minorInc(-27), 0x78e5, 'the small-character row step');
    eq(f.majorInc(19), 0x5013, 'the small-character column step');

    // op 8 / 9: beam position and the translate registers
    //
    const xp = f.decodeFCW(f.xPosition(f.cellX(19)));
    eq(xp.nm, 'XPOS', 'X position');
    eq(xp.v.x, 1573 + 19 * 19, 'X position value');
    eq(xp.v.translate, 0, 'a beam move is not a translate');
    const yp = f.decodeFCW(f.yPosition(f.cellY(1)));
    eq(yp.nm, 'YPOS', 'Y position');
    eq(yp.v.y, 364 - 27, 'Y position value');
    // Coordinates never reach bit 11, which is what frees it to redirect
    // the write to the TRANSLATE register.
    ok(f.cellX(50) < 0x800 || f.cellX(50) >= 1536 - 0x800,
        'cell coordinates stay inside 11 bits');
    eq(f.translateX(), 0x8800, 'zeroing the X translate register');
    eq(f.translateY(), 0x9800, 'zeroing the Y translate register');
    eq(f.decodeFCW(f.translateX()).v.translate, 1, 'translate bit reads back');
    // Bit 11 is really the low bit of a five-bit opcode: `XPOS`/`YPOS` are
    // 10000/10010 and `XTRN`/`YTRN` -- the reference registers -- 10001 and
    // 10011.  GPCIPL page 2 lifts the shared section eight rows with
    // `YTRN 216`, one row pitch short of nine.
    eq(f.translateY(8 * 27), 0x98d8, "page 2's eight-row Y reference");
    eq(f.decodeFCW(0x98d8).v.y, 216, 'and it reads back as 8 x ROW_PITCH');

    // op A / B: vectors
    //
    // The pair encodes the major-axis extent and the minor/major slope at
    // 9-bit resolution inside a 10-bit field, so the low bit is always zero
    // and a 45 degree line stores 1022.
    const veca = f.decodeFCW(0xa000 | (1 << 11) | (1 << 10) | 1022);
    eq(veca.nm, 'VECA', 'vector slope word');
    eq(veca.v.yMajor, 1, 'Y is the major axis');
    eq(veca.v.signDiffer, 1, 'the deltas differ in sign');
    eq(veca.v.slope, 1022, '45 degrees');
    const vecb = f.decodeFCW(0xb000 | (1 << 11) | 540);
    eq(vecb.nm, 'VECB', 'vector extent word');
    eq(vecb.v.negative, 1, 'the major delta is negative');
    eq(vecb.v.len, 540, 'major extent');

    // op C: glyphs
    //
    eq(f.glyphPair(0x41, 0x42), 0xe0c2, 'a glyph pair');
    eq(f.glyphSingle(0x41), 0xc041, 'a lone glyph rides in the low slot');
    eq(f.carrtn(), 0xc00d, 'carriage return is glyph 0x0D');
    const gp = f.decodeFCW(f.glyphPair(0x41, 0x42));
    eq(gp.nm, 'CHAR2', 'a glyph pair decodes');
    eq(gp.v.g1, 0x41, 'first glyph code');
    eq(gp.v.g2, 0x42, 'second glyph code');
    eq(gp.v.char1, 'A', 'first character');
    eq(gp.v.char2, 'B', 'second character');
    // The whole top quadrant is glyphs, not just 0xC000..0xCFFF.
    for (const w of [0xc000, 0xd234, 0xe0c2, 0xffff]) {
        eq(f.decodeFCW(w).nm, 'CHAR2', `${hex(w)} is a glyph pair`);
    }
    // Characters that sit somewhere other than their ASCII code.
    eq(f.toGlyph('_'), 0x16, "'_' is glyph 0x16");
    eq(f.toGlyph(']'), 0x01, "']' is glyph 0x01");
    eq(f.toGlyph('['), 0x02, "'[' is glyph 0x02");
    eq(f.toGlyph('A'), 0x41, "'A' is glyph 0x41");
    // Text packs two glyphs to a word, the odd one alone.
    const packed = f.chars('ABC');
    eq(packed.length, 2, 'three characters pack into two words');
    eq(packed[0], f.glyphPair(0x41, 0x42), 'first pair');
    eq(packed[1], f.glyphSingle(0x43), 'trailing single');
    eq(f.encodeFCW({nm: 'CHAR2', char1: 'A', char2: 'B'}), 0xe0c2,
        'encodeFCW translates characters');

    // decode is not aliased
    //
    // `PackedBits.decode` writes into the shared descriptor; two decoded
    // words held at once must not be the same object.
    const d1 = f.decodeFCW(f.xPosition(100));
    const d2 = f.decodeFCW(f.xPosition(200));
    eq(d1.v.x, 100, 'the first decode survives the second');
    eq(d2.v.x, 200, 'the second decode');

    // end of refresh, special type mode, land site
    //
    // The interpreter keeps a running copy of each feature-control word,
    // so end-of-refresh is FCW2 with one more bit set, not its own opcode.
    const eor = f.decodeFCW(f.endOfRefresh());
    eq(eor.nm, 'FCW2', 'end of refresh is an FCW2');
    eq(eor.v.eor, 1, 'the end-of-refresh bit');
    eq(f.decodeFCW(f.charMode({})).v.eor, 0, 'a plain mode word does not end the refresh');
    // Bits 11-10 of op 7 pick the line spacing register: 10 normal, 11
    // the special type generator.
    const sp = f.decodeFCW(f.specialType(-27));
    eq(sp.nm, 'SPTYPE', 'special type mode');
    eq(sp.v.step, -27, 'special type step sign-extends');
    ok(f.specialType(-27) !== f.minorInc(-27), 'the two spacings are distinct words');
    const ls = f.decodeFCW(0x6800 | 123);
    eq(ls.nm, 'LSITE', 'land-site word');
    eq(ls.v.second, 1, 'the second land-site opcode');
    eq(ls.v.value, 123, 'land-site payload carried opaquely');

    // a 12-bit angle, of which the decks use the top two bits
    //
    eq(f.rotation(2), f.angle(2 << 10), 'a quarter turn is the top of the angle field');
    eq(f.decodeFCW(f.angle(0x123)).v.angle, 0x123, 'a fine angle survives');

    // unknown words
    //
    // Op 7 sub-selectors 00 and 01 -- the circle -- are not modelled, so an
    // unrecognised word must be reported rather than drawn as something
    // else.  (Op 2 was left out on the same grounds and that was WRONG: it
    // is SUBLIST.  No deck carries one because a compiled deck is a single
    // flat static section; it appears only in live DEU memory, which is why
    // a corpus of decks was the wrong thing to conclude absence from.)
    for (const w of [0x7000, 0x74ff]) {
        eq(f.decodeFCW(w), undefined, `${hex(w)} is unknown`);
    }

    // every op is distinguishable
    //
    const built = {
        NOOP: f.noop(), REPT: f.repeat(3), BRANCH: f.branch(0x1123),
        SUBLIST: f.subList(4, 0x1a22)[0],
        FCW1: f.attrMode({blink: true}), FCW2: f.charMode({}),
        FCW3: f.colorMode(7), VDISP: f.valueDisplay(9),
        ROT: f.rotation(1), MAJINC: f.majorInc(19), MININC: f.minorInc(-27),
        XPOS: f.xPosition(500), YPOS: f.yPosition(300),
        VECA: 0xa100, VECB: 0xb100, CHAR2: f.glyphPair(1, 2),
    };
    for (const [nm, w] of Object.entries(built)) {
        eq(f.decodeFCW(w).nm, nm, `${hex(w)} decodes as ${nm}`);
    }

    console.log(`test_meds_fcw: ${pass} passed, ${fail} failed`);
    process.exit(fail ? 1 : 0);
}

main().catch((e) => { console.error(e); process.exit(1); });
