// test_iop_decode.cjs — decode round-trip for the IOP (MSC + BCE) instruction
// tables.  
//
// Usage:  node test/test_iop_decode.cjs
//
// Exit status is 1 iff any assertion fails.

'use strict';

const path    = require('path');
const os      = require('os');
const esbuild = require('esbuild');
const coffeePlugin = require('esbuild-coffeescript');

const SRC = path.resolve(__dirname, '..', 'gpc');

async function bundle(entry) {
    const out = path.join(os.tmpdir(),
        `iop.${path.basename(entry, '.coffee')}.${process.pid}.cjs`);
    await esbuild.build({
        entryPoints: [path.join(SRC, entry)],
        bundle:   true,
        platform: 'node',
        format:   'cjs',
        outfile:  out,
        plugins:  [coffeePlugin()],
        resolveExtensions: ['.coffee', '.js', '.ts', '.json'],
        logLevel: 'error',
    });
    return require(out);
}

// ---- assertion harness ----
let pass = 0, fail = 0;
const hx = (n) => '0x' + (n >>> 0).toString(16).toUpperCase();
function check(label, got, want) {
    if (got === want) { pass++; }
    else { fail++; console.log(`FAIL  ${label}: got ${got}, want ${want}`); }
}

(async () => {
    const { MSCInstruction } = await bundle('iop_msc_instr.coffee');
    const { BCEInstruction } = await bundle('iop_bce_instr.coffee');
    const msc = new MSCInstruction();
    const bce = new BCEInstruction();

    // ---- MSC decode ----
    function decMSC(word) {
        const long = (word > 0xffff);
        const entry = long ? msc._matchLong(word >>> 0)
                           : msc._matchShort(word & 0xffff);
        if (!entry) return null;
        return msc._decodeFields(word >>> 0, entry);
    }

    // ---- BCE decode ----
    function decBCE(hw1, hw2 = 0) {
        const combined = ((hw1 << 16) | hw2) >>> 0;
        for (const mask of bce.orderedMasks) {
            if (mask > 0xffff) {
                const mv = (combined & mask) >>> 0;
                const d = bce.opByMask[mask] && bce.opByMask[mask][mv];
                if (d) return bce.decode(combined, d);
            }
        }
        for (const mask of bce.orderedMasks) {
            if (mask <= 0xffff) {
                const mv = (hw1 & mask) >>> 0;
                const d = bce.opByMask[mask] && bce.opByMask[mask][mv];
                if (d) return bce.decode(hw1 & 0xffff, d);
            }
        }
        return null;
    }

    // ===== MSC: handoff evidence words =====
    // @RBI: BCE number immediate in bits 8-12.
    let v = decMSC(0xE770); check('@RBI 0xE770 nm', v && v.nm, '@RBI'); check('@RBI 0xE770 b', v && v.b, 14);
    v = decMSC(0xE778);     check('@RBI 0xE778 b', v && v.b, 15);
    // @LAR: selector in DATA byte.
    v = decMSC(0xE000); check('@LAR 0xE000 nm', v && v.nm, '@LAR'); check('@LAR 0xE000 sel', v && (v.d & 3), 0);
    v = decMSC(0xE003); check('@LAR 0xE003 sel', v && (v.d & 3), 3);
    // Repeat family: opcode 1101, i (bit4), selector (bits5-7), count.
    v = decMSC(0xD800); check('@RAW 0xD800 nm', v && v.nm, '@RAW'); check('@RAW 0xD800 i', v && v.i, 1);
    v = decMSC(0xD101); check('@RNW 0xD101 nm', v && v.nm, '@RNW'); check('@RNW 0xD101 d', v && v.d, 1);
    v = decMSC(0xD599); check('@RNI 0xD599 nm', v && v.nm, '@RNI'); check('@RNI 0xD599 d', v && v.d, 153);
    v = decMSC(0xDD00); check('@RNI 0xDD00 nm', v && v.nm, '@RNI'); check('@RNI 0xDD00 i', v && v.i, 1);
    v = decMSC(0xD400); check('@RAI 0xD400 nm', v && v.nm, '@RAI');
    // @DLY: opcode 1100.
    v = decMSC(0xC2A8); check('@DLY 0xC2A8 nm', v && v.nm, '@DLY'); check('@DLY 0xC2A8 d', v && v.d, 680);
    v = decMSC(0xC0D3); check('@DLY 0xC0D3 d', v && v.d, 211);
    v = decMSC(0xC800); check('@DLY 0xC800 nm', v && v.nm, '@DLY'); check('@DLY 0xC800 i', v && v.i, 1);
    // @WAT: opcode 00001 (0x0800), same as #WAT.
    v = decMSC(0x0800); check('@WAT 0x0800 nm', v && v.nm, '@WAT');

    // ===== BCE: handoff evidence words =====
    v = decBCE(0xF1DF, 0x0005); check('#MIN F1DF0005 nm', v && v.nm, '#MIN');
    check('#MIN F1DF0005 d', v && v.d, 0xDF); check('#MIN F1DF0005 c', v && v.c, 5);
    v = decBCE(0xF53C, 0x001D); check('#MOUT F53C001D nm', v && v.nm, '#MOUT');
    check('#MOUT F53C001D d', v && v.d, 0x3C); check('#MOUT F53C001D c', v && v.c, 29);
    // #MINC: companion command word.  It is mask-0 (indistinguishable from
    // #MOUTC by bits — never independently dispatched; the parent #MIN/#MOUT
    // skips it via incrNIA(3)), so decode its descriptor directly to confirm
    // the 33->32 char trim restored the field positions: IUA in bits 8-12,
    // command in bits 13-31.  #MINC 17,X'04005' -> 0x00884005 (IUA 17).
    v = bce.decode(0x00884005, bce.descByOp['#MINC']);
    check('#MINC 00884005 IUA', v && v.u, 17);
    check('#MINC 00884005 cmd', v && v.c, 0x04005);

    // ===== Shared-mask survival (the desc.make typo dropped all but the last) =====
    // Three ops share mask 0xFF000000:
    check('#MIN  survives', (decBCE(0xF100, 0x0000) || {}).nm, '#MIN');
    check('#MOUT survives', (decBCE(0xF500, 0x0000) || {}).nm, '#MOUT');
    check('#CMDI survives', (decBCE(0xF600, 0x0000) || {}).nm, '#CMDI');
    // Several long ops share mask 0xFFFFC000:
    check('#BU   survives', (decBCE(0xF000, 0x0000) || {}).nm, '#BU');
    check('#CMD  survives', (decBCE(0xFE00, 0x0000) || {}).nm, '#CMD');
    check('#TDL  survives', (decBCE(0xFC00, 0x0000) || {}).nm, '#TDL');
    check('#MIN@ survives', (decBCE(0xF900, 0x0000) || {}).nm, '#MIN@');

    // ===== #DLY / #DLYI disambiguation (share mask 0xF800) =====
    check('#DLYI 0xC000', (decBCE(0xC000) || {}).nm, '#DLYI');
    check('#DLY  0xC800', (decBCE(0xC800) || {}).nm, '#DLY');

    // ===== Exec-path checks for the two changed MSC exec bodies =====
    // (decode alone can't catch a register mix-up in setbit32(v.b,0) / v.d&3).
    // Minimal register stub mirroring regmem get32/set32/setbit32/getbit32.
    function Reg(v = 0) { this.v = v >>> 0; }
    Reg.prototype.get32 = function () { return this.v >>> 0; };
    Reg.prototype.set32 = function (x) { this.v = x >>> 0; };
    Reg.prototype.getbit32 = function (b) { return (this.v >>> b) & 1; };
    Reg.prototype.setbit32 = function (b, val = 1) {
        this.v = ((this.v & (0xffffffff ^ (1 << b))) | (val << b)) >>> 0;
    };
    function mkT() {
        const acc = new Reg();
        return {
            nia: 0,
            regIndicator: new Reg(),
            regProgExcept: new Reg(),
            regBusyWait:  new Reg(),
            msc: { regFailDisc: new Reg() },
            ls: { setACC: (x) => acc.set32(x), getACC: () => acc.get32() },
            incrNIA(n) { this.nia += n; },
        };
    }
    // @RBI 14 (0xE770): clears regIndicator bit 14 only.
    let t = mkT(); t.regIndicator.set32(0xFFFFFFFF); msc.exec(t, 0xE770, 0);
    check('@RBI 14 clears bit14', t.regIndicator.getbit32(14), 0);
    check('@RBI 14 leaves bit13', t.regIndicator.getbit32(13), 1);
    check('@RBI 14 advances NIA', t.nia, 1);
    // @LAR 1 (0xE001): selector 1 -> ACC := BCE indicators.
    t = mkT(); t.regIndicator.set32(0xABCD); msc.exec(t, 0xE001, 0);
    check('@LAR 1 loads indicators', t.ls.getACC(), 0xABCD);
    // @LAR 3 (0xE003): selector 3 -> ACC := busy/wait.
    t = mkT(); t.regBusyWait.set32(0x1234); msc.exec(t, 0xE003, 0);
    check('@LAR 3 loads busy/wait', t.ls.getACC(), 0x1234);

    console.log(`\n${pass} passed, ${fail} failed`);
    process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
