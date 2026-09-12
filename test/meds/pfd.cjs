// pfd.cjs — the A/E PFD's feed dependencies, in `meds/mdu/mduScreen_AE_PFD`.
//
// Verifies dependency-based PFD instrument rebuilds with a stub drawing surface.
//
// Usage:
//   cd ext/sim && node test/meds/pfd.cjs
//
// Exit status is 1 iff any test failed.
'use strict';

const path = require('path');
const os = require('os');
const fs = require('fs');
const esbuild = require('esbuild');
const coffeePlugin = require('esbuild-coffeescript');

const SIM = path.resolve(__dirname, '..', '..');

async function bundle(rel) {
    const out = path.join(os.tmpdir(),
        `pfd.test.${path.basename(rel).replace(/\W/g, '_')}.${process.pid}.cjs`);
    await esbuild.build({
        absWorkingDir: SIM,
        entryPoints: [rel],
        bundle: true, platform: 'node', format: 'cjs', target: 'node20',
        outfile: out,
        plugins: [coffeePlugin({})],
        resolveExtensions: ['.coffee', '.js', '.ts', '.json'],
        nodePaths: [path.join(SIM, 'node_modules')],
        logLevel: 'error',
    });
    return require(out);
}

let pass = 0, fail = 0;
function ok(cond, what) {
    if (cond) { pass++; } else { fail++; console.log('FAIL: ' + what); }
}
function eq(a, b, what) { ok(a === b, `${what}: got ${a}, want ${b}`); }

// Minimal drawing surface accepted by the screen's Three.js paths.
const stubGeom = () => ({attributes: {}, morphAttributes: {}, dispose() {}});

function stubSurface(THREE, sdf, drawn) {
    // What the screen does with what it is handed: reads `.material`, sets a
    // render order on `.children[0]` and `.children[1]` of a bordered stroke,
    // and walks for `.isMesh` / `.geometry`.  One shape covers all of it.
    const obj = () => {
        const g = new THREE.Object3D();
        g.isMesh = true;
        g.material = {};
        g.geometry = stubGeom();
        for (let i = 0; i < 2; i++) {
            const c = new THREE.Object3D();
            c.isMesh = true;
            c.material = {};
            c.geometry = stubGeom();
            g.add(c);
        }
        return g;
    };
    const note = (kind, args) => { drawn.push(kind + ' ' + JSON.stringify(args)); return obj(); };
    const d = {
        c2h: {black: 0x101336, white: 0xffffff, lightGray: 0x9999a0, darkGray: 0x777780,
              green: 0x48f500, lightGreen: 0x48f500, darkGreen: 0x368524, red: 0xff232b,
              yellow: 0xfff600, cyan: 0x2dfada, magenta: 0xff43de, orange: 0xff8c06,
              blue: 0x003ce0, pink: 0xfff9d4, brown: 0xff7049},
        LINE_PX: 2.2,
        NO_CLIP: new THREE.Vector4(0, 100, 0, 100),
        mats: [{}, {}],
        // the ball markings walk the meds font's glyph strokes; the shapes
        // are not what is under test, so every character is one stroke
        deuFont: {chars: {}},
        medsFont: {chars: new Proxy({}, {get: () => [[[0, 0], [1, 0]]]})},
        dirty: false,
        sdfOpt: (o) => Object.assign({resolution: {value: new THREE.Vector2(1, 1)},
                                      pxRatio: {value: 1}}, o),
        clipPlanes: () => [],
        _clipMat: (m) => m,
        flatten: (g) => g,
        str:       (...a) => note('str', a.slice(0, 4)),
        strMEDS:   (...a) => note('strMEDS', a.slice(0, 4)),
        line:      (...a) => note('line', a.slice(0, 2)),
        box:       (...a) => note('box', a.slice(0, 6)),
        tri:       (...a) => note('tri', a.slice(0, 8)),
        quad:      (...a) => note('quad', a.slice(0, 8)),
        polyFill:  (...a) => note('polyFill', a.slice(0, 2)),
        filledArc: (...a) => note('filledArc', a.slice(0, 6)),
        arc:       (...a) => note('arc', a.slice(0, 6)),
        arcTicks:  (...a) => note('arcTicks', a.slice(0, 7)),
    };
    return d;
}

// The fields a live A/E PFD carries before the GPC drives it: the ADI is
// invalid and there is no major mode (JSC-48017/6-22, the OPS 9 display).
const NO_DATA = {
    adiValid: false, majorMode: null,
    adiRol: 0, adiPch: 0, adiYaw: 0,
    adiRolRate: null, adiPchRate: null, adiYawRate: null,
    adiRolErr: null, adiPchErr: null, adiYawErr: null,
    machValid: false, alphaValid: false, keasValid: false,
    altValid: false, hdotValid: false, radarValid: false,
    hsiHeadingValid: false, hsiCourseValid: false, hsiCdiValid: false,
    hsiPriBearingValid: false, hsiSecBearingValid: false,
    hsiGsiValid: false, hsiPriRangeValid: false, hsiSecRangeValid: false,
};

function screenOf(mods) {
    const THREE = mods.three;
    const drawn = [];
    const scr = Object.create(mods.pfd.Screen_AE_PFD.prototype);
    scr.d = stubSurface(THREE, mods.sdf, drawn);
    scr.curData = Object.assign({}, NO_DATA);
    scr.build();
    scr.drawn = drawn;
    return scr;
}

// what the screen draws now, as a sorted digest: a gated rebuild has to
// leave the same picture as rebuilding everything
function picture(scr) {
    scr.drawn.length = 0;
    for (const name of scr.parts()) scr._part(name);
    const shot = scr.drawn.slice().sort();
    scr.drawn.length = 0;
    return shot.join('\n');
}

async function main() {
    global.window = {fs};
    const shim = path.join(os.tmpdir(), `pfd.test.shim.${process.pid}.js`);
    fs.writeFileSync(shim,
        "export * as three from 'three'\n" +
        `export * as pfd from ${JSON.stringify(path.join(SIM, 'src/meds/mdu/mduScreen_AE_PFD.coffee'))}\n` +
        `export * as sdf from ${JSON.stringify(path.join(SIM, 'src/meds/mdu/shader/sdfLine.coffee'))}\n`);
    const mods = await bundle(shim);

    // The ADI is the one instrument with a cheap update path, so a feed
    // change runs that and not a rebuild.  Built with adiValid false it has
    // never read an attitude field; when the GPC starts driving it, the
    // attitude has to reach it from then on.
    {
        const scr = screenOf(mods);
        const reads = (f) => scr._reads('adi', [f]);
        ok(reads('adiValid'), 'the ADI reads its validity with nothing to draw');
        ok(!reads('adiRol'), 'and has not read an attitude field yet');

        scr.curData.adiValid = true;
        scr.refreshFeed(['adiValid']);
        ok(reads('adiRol'), 'once it is driven, roll reaches the ADI');
        ok(reads('adiPch'), '...and pitch');
        ok(reads('adiYaw'), '...and yaw');

        // the sweep: attitude alone must turn the ball
        const before = scr.adiBallRot.rotation.z;
        scr.curData.adiRol = 45;
        scr.refreshFeed(['adiRol']);
        ok(scr.adiBallRot.rotation.z !== before, 'and an attitude change turns the ball');
    }

    {
        const scr = screenOf(mods);
        Object.assign(scr.curData, {
            adiValid: true, majorMode: 305, machValid: true, keasValid: true,
            alphaValid: true, altValid: true, hdotValid: true,
            hsiHeadingValid: true, mach: 2.0, keas: 250, alpha: 10,
            altitude: 90000, hdot: -200, hsiHeading: 90,
        });
        scr.refreshFeed();
        const reaches = (f) => scr.parts().filter((n) => scr._reads(n, [f]));
        eq(reaches('hsiHeading').join(','), 'hsi', 'heading reaches the HSI alone');
        eq(reaches('alpha').join(','), 'ami', 'alpha reaches the AMI alone');
        eq(reaches('hdot').join(','), 'avvi', 'hdot reaches the AVVI alone');
        eq(reaches('dAz').join(','), 'dAz', 'delta azimuth reaches its own readout');
        ok(reaches('majorMode').length > 4, 'the major mode reaches most of the display');
        eq(scr._reads('ami', ['hsiHeading']), false, 'the heading does not reach the AMI');
    }

    {
        const scr = screenOf(mods);
        const base = {
            adiValid: true, majorMode: 305, machValid: true, keasValid: true,
            alphaValid: true, altValid: true, hdotValid: true,
            hsiHeadingValid: true, hsiCourseValid: true, hsiCdiValid: true,
            mach: 2.0, keas: 250, alpha: 10, altitude: 90000, hdot: -200,
            hsiHeading: 90, hsiCourse: 30, hsiCdi: 1, adiRol: 5, adiPch: 3,
            adiYaw: 2, vehicleAcceleration: 1.5, hsiGsi: 0.5, dAz: 4,
        };
        const trials = {hsiHeading: 123.4, mach: 2.75, alpha: 17.5,
                        altitude: 82000, hdot: -310, adiRol: 42,
                        vehicleAcceleration: 2.2, dAz: 7, majorMode: 603};
        for (const [k, v] of Object.entries(trials)) {
            Object.assign(scr.curData, base);
            scr.refreshFeed();
            scr.curData[k] = v;
            scr.refreshFeed([k]);
            const gated = picture(scr);

            Object.assign(scr.curData, base);
            scr.refreshFeed();
            scr.curData[k] = v;
            scr.refreshFeed();
            const full = picture(scr);
            ok(gated === full, `a change of ${k} alone draws what a full rebuild draws`);
        }
    }

    console.log(`test_meds_pfd: ${pass} passed, ${fail} failed`);
    process.exit(fail ? 1 : 0);
}

main().catch((e) => { console.error(e); process.exit(1); });
