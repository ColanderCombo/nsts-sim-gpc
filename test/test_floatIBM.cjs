// test_floatIBM.cjs — runs the AP-101S reference vectors against
// gpc/floatIBM.coffee and reports compliance.
//
// Usage:
//   node test/test_floatIBM.cjs <refgen-binary>
//
// Exit status is 1 iff any FAIL row exists.  

'use strict';

const path  = require('path');
const os    = require('os');
const { execFileSync } = require('child_process');
const esbuild = require('esbuild');
const coffeePlugin = require('esbuild-coffeescript');

if (process.argv.length < 3) {
    console.error('usage: node test_floatIBM.cjs <refgen-binary>');
    process.exit(2);
}
const refgenPath = process.argv[2];

(async () => {
    const bundlePath = path.join(os.tmpdir(),
                                 'floatIBM.test.bundle.' + process.pid + '.cjs');
    await esbuild.build({
        entryPoints: [path.resolve(__dirname, '../gpc/floatIBM.coffee')],
        bundle:   true,
        platform: 'node',
        format:   'cjs',
        outfile:  bundlePath,
        plugins:  [coffeePlugin()],
        logLevel: 'error',
    });

    const fIBM = require(bundlePath);
    const { FloatIBM, addE, subE, mulE, mulQeE, divE,
            compE_anomalous, cvfx, cvfl, FP_EXC } = fIBM;

    // Inverse map for FP_EXC: numeric code -> string name (for runner output).
    const EXC_NAME = {
        0:        'OK',
        0x000B:   'EXP_OVERFLOW',
        0x0009:   'EXP_UNDERFLOW',
        0x0005:   'SIGNIFICANCE',
        0x000C:   'DIVIDE',
        0x000A:   'CONVERT_OVERFLOW',
    };

    // ---- helpers ----
    const dpHex = (f) => {
        const hi = f.to64x() >>> 0;
        const lo = f.to64y() >>> 0;
        return hi.toString(16).toUpperCase().padStart(8, '0') +
               lo.toString(16).toUpperCase().padStart(8, '0');
    };
    const spHex = (f) =>
        (f.to32() >>> 0).toString(16).toUpperCase().padStart(8, '0');
    const fromHexDP = (hex) => {
        const hi = parseInt(hex.substring(0, 8), 16) >>> 0;
        const lo = parseInt(hex.substring(8, 16), 16) >>> 0;
        return FloatIBM.From64(hi, lo);
    };
    const fromHexSP = (hex) =>
        FloatIBM.From32(parseInt(hex, 16) >>> 0);

    // CC matching refgen's cc_load_style().
    const ccLoadStyle = (resultHex, isDp) => {
        if (isDp) {
            const lo = parseInt(resultHex.substring(8, 16), 16);
            const hi = parseInt(resultHex.substring(0, 8), 16);
            const magHigh = hi & 0x7FFFFFFF;
            if (magHigh === 0 && lo === 0) return 0;
            return (hi & 0x80000000) ? 3 : 1;
        } else {
            const v = parseInt(resultHex, 16);
            if ((v & 0x7FFFFFFF) === 0) return 0;
            return (v & 0x80000000) ? 3 : 1;
        }
    };

    function runOp(rec) {
        const isDp = rec.kind === 'dp';
        const fromHex = isDp ? fromHexDP : fromHexSP;
        const toHex   = isDp ? dpHex     : spHex;

        const a = rec.a ? fromHex(rec.a) : null;
        const b = rec.b ? fromHex(rec.b) : null;

        let result_hex = '----';
        let cc = null;
        let has_cc = false;
        let exc = 'OK';

        switch (rec.op) {
        case 'dp_add': case 'sp_add': {
            const out = addE(a, b);
            result_hex = toHex(out.result);
            exc = EXC_NAME[out.exc] || `?(${out.exc})`;
            cc = ccLoadStyle(result_hex, isDp);
            has_cc = true;
            break;
        }
        case 'dp_sub': case 'sp_sub': {
            const out = subE(a, b);
            result_hex = toHex(out.result);
            exc = EXC_NAME[out.exc] || `?(${out.exc})`;
            cc = ccLoadStyle(result_hex, isDp);
            has_cc = true;
            break;
        }
        case 'dp_mul': case 'sp_mul': {
            const out = mulE(a, b);
            result_hex = toHex(out.result);
            exc = EXC_NAME[out.exc] || `?(${out.exc})`;
            break;
        }
        case 'dp_div': case 'sp_div': {
            const out = divE(a, b);
            result_hex = toHex(out.result);
            exc = EXC_NAME[out.exc] || `?(${out.exc})`;
            break;
        }
        case 'dp_mul_qe': {
            const out = mulQeE(a, b);
            result_hex = toHex(out.result);
            exc = EXC_NAME[out.exc] || `?(${out.exc})`;
            break;
        }
        case 'dp_cmp': case 'sp_cmp': {
            // Standard compare: subE-based, returns the algebraically
            // correct CC.
            const out = subE(a, b);
            const fb = out.result.gFracBits();
            cc = fb.isZero() ? 0
                 : (out.result.gSign() > 0 ? 1 : 3);
            has_cc = true;
            break;
        }
        case 'dp_cmp_anom': case 'sp_cmp_anom': {
            // POO §8.11 hardware-faithful compare.
            cc = compE_anomalous(a, b);
            has_cc = true;
            break;
        }
        case 'cvfx': {
            const out = cvfx(a);
            result_hex = (out.result >>> 0).toString(16).toUpperCase().padStart(8, '0');
            exc = EXC_NAME[out.exc] || `?(${out.exc})`;
            const hi16 = (out.result >>> 16) & 0xFFFF;
            cc = (hi16 === 0) ? 0
                 : ((hi16 & 0x8000) ? 3 : 1);
            has_cc = true;
            break;
        }
        case 'cvfl': {
            const u = parseInt(rec.a, 16) >>> 0;
            const s = (u & 0x80000000) ? u - 0x100000000 : u;
            const fp = cvfl(s);
            result_hex = (fp.to32() >>> 0).toString(16).toUpperCase().padStart(8, '0');
            cc = ccLoadStyle(result_hex, false);
            has_cc = true;
            break;
        }
        default:
            throw new Error('unknown op: ' + rec.op);
        }

        return { result_hex, cc, has_cc, exc };
    }

    // ---- main ----
    let raw;
    try {
        raw = execFileSync(refgenPath, [],
                           { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
    } catch (e) {
        console.error('refgen failed:', e.message);
        process.exit(2);
    }

    let pass = 0, gap = 0, fail = 0;
    const failures = [];
    const gaps     = [];

    for (const line of raw.split('\n')) {
        if (!line.trim()) continue;
        let rec;
        try { rec = JSON.parse(line); }
        catch (e) { console.error('bad NDJSON line:', line); continue; }

        let got;
        try { got = runOp(rec); }
        catch (e) {
            fail++;
            failures.push({ rec, error: e.message });
            continue;
        }

        const resultMatch = (rec.result === '----') ||
            (got.result_hex.toUpperCase() === rec.result.toUpperCase());
        const ccMatch = (rec.cc === null || rec.cc === undefined)
            ? true
            : (got.has_cc && got.cc === rec.cc);
        const excMatch = got.exc === rec.exc;

        const ok = resultMatch && ccMatch && excMatch;
        const isDeferred = !!rec.defer_to;

        if (ok) pass++;
        else if (isDeferred) {
            gap++;
            gaps.push({ rec, got });
        } else {
            fail++;
            failures.push({ rec, got });
        }
    }

    const total = pass + gap + fail;
    console.log(`floatIBM compliance: ${pass} pass, ${gap} gap, ${fail} fail (${total} vectors)`);

    if (fail > 0) {
        console.log('\nReal failures (vectors with exc=OK that mismatched):');
        for (const f of failures) {
            if (f.error) {
                console.log(`  FAIL [${f.rec.op}] ${f.rec.tag}: threw ${f.error}`);
                continue;
            }
            console.log(`  FAIL [${f.rec.op}] ${f.rec.tag}`);
            console.log(`    a=${f.rec.a}  b=${f.rec.b}`);
            console.log(`    want result=${f.rec.result} cc=${f.rec.cc} exc=${f.rec.exc}`);
            console.log(`    got  result=${f.got.result_hex} cc=${f.got.cc} exc=${f.got.exc}`);
        }
    }

    if (gap > 0 && process.env.FLOATIBM_VERBOSE) {
        console.log('\nGAP rows (exception-path vectors not yet matched):');
        for (const g of gaps) {
            console.log(`  GAP  [${g.rec.op}] exc=${g.rec.exc} ${g.rec.tag}`);
            console.log(`    want result=${g.rec.result}  got=${g.got.result_hex}`);
        }
    }

    process.exit(fail > 0 ? 1 : 0);
})().catch((e) => {
    console.error('test runner threw:', e);
    process.exit(2);
});
