// ddu.cjs — the GPC's flight instrument output on the FC busses:
// the DDU words, the MEDS transfer, the IDP's receiver and the MDU's fields
//
// Usage:
//   cd ext/sim && node test/lru/ddu.cjs
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

// A bus domain for this test (com/bus.civet: every port is an offset from
// NSTS_BASE_PORT): a base drawn from the process id, 20000 to 59900 by 100,
// or NSTS_TEST_BASE_PORT.  It is printed first.
process.env.NSTS_BASE_PORT =
    process.env.NSTS_TEST_BASE_PORT ?? String(20000 + (process.pid % 400) * 100);
console.log(`bus base port ${process.env.NSTS_BASE_PORT}`);

async function bundle(rel) {
    const out = path.join(os.tmpdir(),
        `ddu.test.${path.basename(rel).replace(/\W/g, '_')}.${process.pid}.cjs`);
    await esbuild.build({
        absWorkingDir: SIM,
        entryPoints: [path.join(SIM, 'src', rel)],
        bundle: true, platform: 'node', format: 'cjs', target: 'node20',
        outfile: out,
        plugins: [civetPlugin, coffeePlugin({})],
        resolveExtensions: ['.coffee', '.js', '.ts', '.civet', '.json'],
        external: ['dgram', 'electron'],
        logLevel: 'error',
    });
    return require(out);
}

let passed = 0, failed = 0;
function ok(cond, what) {
    if (cond) { passed++; }
    else { failed++; console.log(`FAIL  ${what}`); }
}
function eq(got, want, what) {
    const g = JSON.stringify(got), w = JSON.stringify(want);
    if (g === w) { passed++; }
    else { failed++; console.log(`FAIL  ${what}\n        got  ${g}\n        want ${w}`); }
}
function near(got, want, tol, what) {
    if (Math.abs(got - want) <= tol) { passed++; }
    else { failed++; console.log(`FAIL  ${what}\n        got  ${got}\n        want ${want} +/- ${tol}`); }
}
function section(name) { console.log(`\n--- ${name} ---`); }
const settle = (msec = 120) => new Promise((r) => setTimeout(r, msec));

(async () => {
    const C = await bundle('lru/ddu/dduConf.coffee');
    const D = await bundle('lru/ddu/dduDrive.coffee');
    const F = await bundle('lru/ddu/dduFields.coffee');
    const R = await bundle('meds/idp/idpFc.coffee');
    const B = await bundle('com/bus.civet');
    const M = await bundle('meds/medsConf.coffee');

    section('command words');
    eq([C.IUA.DDU1, C.IUA.DDU2, C.IUA.DDU3, C.IUA.MEDS], [6, 9, 15, 15], 'IUAs 6, 9, 15 (FIOPRMPG BCEEQU) and 15 for the MEDS transfer');
    eq(C.payloadOf('ADI'), 0x4002e, 'FIOADIC1 X\'0004002E\'');
    eq(C.payloadOf('HSI'), 0x4004a, 'FIOHSIC1 X\'0004004A\'');
    eq(C.payloadOf('AVVI'), 0x40086, 'FIOAVIC1 X\'00040086\'');
    eq(C.payloadOf('AMI'), 0x40106, 'FIOAMIC1 X\'00040106\'');
    eq(C.payloadOf('MEDS1'), 0x4081e, 'FIOMDSM1 X\'0004081E\'');
    eq(C.payloadOf('MEDS2'), 0x4101e, 'FIOMDSM2 X\'0004101E\'');
    eq(C.payloadOf('MEDS3'), 0x4201e, 'FIOMDSM3 X\'0004201E\'');
    eq(C.payloadOf('MEDS4'), 0x4400a, 'FIOMDSM4 X\'0004400A\'');
    eq(C.commandWord(6, 'ADI'), 0x34002e, 'DDU 1 ADI is 34002E on the bus (FIOHFEPG "0034 002E")');
    eq(C.commandWord(15, 'MEDS1'), 0x7c081e, 'MEDS message 1 is 7C081E ("007C 081E")');
    eq(C.decodeCommand(0x4c004a), {iua: 9, msg: 'HSI', wc: 10, ddu: 2}, 'DDU 2 HSI decodes');
    eq(C.decodeCommand(0x7c400a), {iua: 15, msg: 'MEDS4', wc: 10, ddu: null}, 'MEDS message 4 decodes');
    eq(C.decodeCommand(0x7c002e), {iua: 15, msg: 'ADI', wc: 14, ddu: 3}, 'IUA 15 with the ADI select is DDU 3');
    ok(C.decodeCommand(0x30021f) === null, 'the left HUD message (FIOHMSG1, bit 18 clear) is not a DDU write');
    ok(C.decodeCommand(0x5238a0) === null, 'an FF MDM output command is not');
    eq(C.HFE_SEQUENCE.length, 13, 'the HFE writes 13 messages a bus a cycle');
    eq(C.HFE_SEQUENCE.map((e) => e.msg).join(' '), 'MEDS1 MEDS2 MEDS3 MEDS4 ADI ADI ADI HSI HSI AVVI AVVI AMI AMI', 'in the listing\'s order');
    eq(C.HFE_SEQUENCE.filter((e) => e.iua === 15 && e.msg === 'ADI').length, 1, 'DDU 3 gets the ADI only');

    section('control and test words');
    eq(C.controlWord(14), 0xfff8, 'C2 to C14 all set is fff8 (table F.4.103.0-1 bits 1-13)');
    eq(C.controlWord(10), 0xff80, 'the HSI\'s C2 to C10 is ff80');
    eq(C.controlWord(6), 0xf800, 'the AMI\'s and AVVI\'s C2 to C6 is f800');
    eq(C.controlWord(14, {8: false}), 0xfff8 & ~0x0100, 'C9 (the roll rate, word 9) is bit 8');
    ok(C.wordValid(0x0008, 13) && !C.wordValid(0x0008, 12), 'bit 13 is C14');
    ok(C.wordValid(0x8000, 1) && !C.wordValid(0x4000, 1), 'bit 1 is C2');
    eq([C.TEST_WORD.ADI, C.TEST_WORD.HSI, C.TEST_WORD.AMI, C.TEST_WORD.AVVI], [0x7ff8, 0x7fc0, 0xaaa9, 0xaaa9], 'the fixed test words');

    section('ADI words');
    eq(C.fracToWord(1), 0x7ff8, '+1 is 8*4095 = 32760, "the integer +32760 corresponds to full-scale"');
    eq(C.fracToWord(-1), 0x8008, '-1 is -32760');
    eq(C.fracToWord(0), 0, '0 is 0');
    near(C.wordToFrac(C.fracToWord(0.5)), 0.5, 1 / 4095, '0.5 round trips within a count');
    near(C.wordToFrac(C.fracToWord(-0.25)), -0.25, 1 / 4095, '-0.25 round trips');
    eq(C.fracToWord(0.5) & 7, 0, 'the low three bits are zero');

    section('HSI words');
    eq(C.angleToWord(180), 16384, '180 degrees is 16384 (HLWORD5 in MM 101)');
    eq(C.angleToWord(0), 0, '0 degrees is 0');
    eq(C.angleToWord(359.9), 16 * 2047, '359.9 degrees is the top count');
    near(C.wordToAngle(C.angleToWord(123.4)), 123.4, 180 / 1024, '123.4 degrees round trips within a count');
    eq(C.angleToWord(360 + 90), C.angleToWord(90), 'angles wrap');
    eq(C.bcdToWord(1234), (1 << 13) | (2 << 9) | (3 << 5) | (4 << 1), '1234 NM as BCD, bits 2-15');
    eq(C.bcdToWord(2000), 0x4000, '2000 NM is bit 2');
    eq(C.bcdToWord(1), 0x0002, '1 NM is bit 15');
    eq(C.wordToBcd(C.bcdToWord(3999)), 3999, '3999 NM, the largest, round trips');
    eq(C.wordToBcd(C.bcdToWord(45)), 45, '45 NM round trips');
    eq(C.devToWord(511), 511 << 6, '+511 counts, full scale, is 64*511');
    eq(C.devToWord(-512), (-512 << 6) & 0xffff, '-512 counts');
    eq(C.wordToDev(C.devToWord(-100)), -100, '-100 counts round trip');
    near(C.wordToCdiDeg(C.cdiDegToWord(1.25)), 1.25, 0.01, '1.25 degrees, one dot in autoland, round trips');
    near(C.devToDots(C.wordToDev(C.cdiDegToWord(3.75))), 3, 0.02, '3.75 degrees is three dots, full scale');
    near(C.wordToGsiFt(C.gsiFtToWord(500)), 500, 3, '500 ft, one dot in autoland, round trips');
    near(C.devToDots(C.wordToDev(C.gsiFtToWord(1500))), 3, 0.02, '1500 ft is three dots');

    section('AMI words');
    eq(C.machToWord(4), 8 * Math.floor(4 / 0.0075), 'mach 4 is 8*INTEGER(4/0.0075)');
    near(C.wordToMach(C.machToWord(0.85)), 0.85, 0.0075, 'mach 0.85 round trips within a count');
    near(C.wordToMach(C.machToWord(24.5)), 24.5, 0.0075, '24500 ft/s round trips');
    eq(C.machToWord(30), C.machToWord(27), 'limited to 27');
    eq(C.alphaToWord(-1.5), (2 * Math.floor(-1.5 / 0.015)) & 0xffff, '-1.5 degrees of alpha');
    near(C.wordToAlpha(C.alphaToWord(12.3)), 12.3, 0.015, 'alpha 12.3 round trips');
    near(C.wordToAlpha(C.alphaToWord(-8)), -8, 0.015, 'alpha -8 round trips');
    eq(C.easToWord(250), 8 * 2000, '250 knots is 8*2000');
    near(C.wordToEas(C.easToWord(333.3)), 333.3, 0.125, 'EAS round trips');
    eq(C.accelToWord(-1), (8 * Math.floor(-1 / 0.00125)) & 0xffff, '-1 g is 8*INTEGER(-1/0.00125)');
    eq(C.accelToWord(2), 8 * 800, '+2 g is 8*800');
    near(C.wordToAccel(C.accelToWord(1.5)), 1.5, 0.0025, '1.5 g round trips');
    near(C.wordToAccel(C.accelToWord(-2.5)), -2.5, 0.00125, '-2.5 g round trips');

    section('AVVI words');
    eq(C.altToWord(-1100), 0, '-1100 ft is count 0');
    eq(C.altToWord(-100), 8 * 200, '-100 ft is count 200, the end of the 5 ft range');
    eq(C.altToWord(0), 8 * 280, '0 ft is count 280');
    eq(C.altToWord(500), 8 * 480, '500 ft is count 480 from both sides of the break');
    eq(C.altToWord(1e5), 8 * 2470, '100000 ft is count 2470');
    for (const a of [-1000, -50, 10, 250, 499, 501, 5000, 25000, 99999, 150000, 900000])
        near(C.wordToAlt(C.altToWord(a)), a, Math.max(2, a / 100), `altitude ${a} ft round trips`);
    eq(C.hdotToWord(100), 8 * 500, '+100 ft/s is count 500');
    eq(C.hdotToWord(-100), (8 * -500) & 0xffff, '-100 ft/s is count -500');
    eq(C.hdotToWord(740), 8 * 2500, '740 ft/s is count 2500');
    eq(C.hdotToWord(2940), 8 * 3380, '2940 ft/s is count 3380');
    for (const v of [-2900, -740, -300, -60, 0, 25, 99, 150, 700, 800, 2000])
        near(C.wordToHdot(C.hdotToWord(v)), v, Math.max(1, Math.abs(v) / 200), `hdot ${v} round trips`);
    eq(C.radarAltToWord(500), 16 * 1000, '500 ft of radar altitude is count 1000');
    eq(C.radarAltToWord(9000), 16 * 1850, '9000 ft is count 1850');
    for (const r of [0, 20, 250, 499, 600, 4000, 8999])
        near(C.wordToRadarAlt(C.radarAltToWord(r)), r, Math.max(1, r / 100), `radar altitude ${r} round trips`);
    eq(C.vertAccelToWord(-0.5), (128 * -10) & 0xffff, '-0.5 ft/s2 is 128*-10');
    near(C.wordToVertAccel(C.vertAccelToWord(3.3)), 3.3, 0.05, 'vertical acceleration round trips');

    section('messages');
    const adi = C.encodeADI({rollSin: 0.5, rollCos: Math.sqrt(3) / 2, pitchSin: 0, pitchCos: 1, yawSin: -1, yawCos: 0, rollRate: 0.2, yawErr: -0.4});
    eq(adi.length, 14, 'an ADI message is 14 words');
    eq([adi[0], adi[1]], [0xfff8, 0x7ff8], 'control and test words');
    const da = C.decodeADI(adi);
    near(Math.atan2(da.rollSin, da.rollCos) * 180 / Math.PI, 30, 0.05, 'roll 30 degrees comes back from its sine and cosine');
    near(da.rollRate, 0.2, 1 / 4095, 'the roll rate fraction');
    near(da.yawErr, -0.4, 1 / 4095, 'the yaw error fraction');
    const hsi = C.encodeHSI({course: 150, heading: 180, priBearing: 200, secBearing: 90, priRange: 45, secRange: 12, cdi: -85, gsi: 51});
    eq(hsi.length, 10, 'an HSI message is 10 words');
    const dh = C.decodeHSI(hsi);
    eq([Math.round(dh.course), Math.round(dh.heading), dh.priRange, dh.secRange, dh.cdi, dh.gsi], [150, 180, 45, 12, -85, 51], 'the HSI fields round trip');
    const ami = C.encodeAMI({mach: 0.8, alpha: 8, eas: 250, accel: 1.2}, {3: false});
    eq(ami[0], 0xf800 & ~C.controlBit(3), 'the alpha word\'s bit off');
    ok(!C.wordValid(ami[0], 3) && C.wordValid(ami[0], 2), 'and only that one');
    const avvi = C.encodeAVVI({altitude: 25000, hdot: -150, radarAlt: 0, vertAccel: 0});
    near(C.decodeAVVI(avvi).altitude, 25000, 50, 'altitude through the AVVI message');
    near(C.decodeAVVI(avvi).hdot, -150, 0.32, 'hdot through the AVVI message');

    section('MEDS transfer');
    const m1 = C.encodeMEDS1({majorMode: 305, abortMode: 'TAL', ppa: true, iphase: 2, islect: 3, tgEnd: false, wowlon: true,
                              hsiModeL: 1, hsiModeR: 2, thetaMaxDelta: 0.25, thetaMinDelta: -0.5,
                              scale: {pitchRateL: 5, pitchRateR: 10, yawRateL: 5, yawRateR: 1, rollRateL: 5, rollRateR: 10, pitchErrL: 5, pitchErrR: 2.5, rollRateTgoL: true},
                              attSelL: 1, attSelR: 2, sbAuto: true, throtAuto: true, dapAuto: false,
                              cdiScale: 50, dAz: -7, dAzWarn: true, hVr: 180, siteId: 'KSC15', targetNz: 1.8, beta: -2.3, dIncl: 1.25});
    eq(m1.length, 30, 'message 1 is 30 words');
    eq(m1[7], 305, 'word 8 carries the major mode in bits 7-16');
    eq(m1[8] & 1, 1, 'TAL is bit 16 of word 9');
    eq((m1[8] >> 5) & 1, 1, 'PPA is bit 11');
    eq(m1[6], 1, 'word 7 bit 16 says PFS');
    eq(m1[0], 0xffff, 'validity word 1: words 7 to 22 valid');
    eq(m1[1], 0xff00, 'validity word 2: words 23 to 30 valid, message 2 not');
    const d1 = C.decodeMEDS1(m1);
    eq([d1.majorMode, d1.abortMode, d1.ppa, d1.iphase, d1.islect, d1.tgEnd, d1.wowlon], [305, 'TAL', true, 2, 3, false, true], 'the mode fields');
    eq([d1.hsiModeL, d1.hsiModeR, d1.attSelL, d1.attSelR], [1, 2, 1, 2], 'the left and right indicators');
    eq([d1.scale.pitchRateL, d1.scale.pitchRateR, d1.scale.yawRateR, d1.scale.rollRateL, d1.scale.rollRateR, d1.scale.pitchErrR, d1.scale.rollRateTgoL, d1.scale.rollRateTgoR],
       [5, 10, 1, 5, 10, 2.5, true, false], 'the scale labels');
    eq([d1.sbAuto, d1.throtAuto, d1.dapAuto, d1.throtBlank], [true, true, false, false], 'the auto indicators');
    eq([d1.cdiScale, d1.dAz, d1.dAzWarn, Math.round(d1.hVr), d1.siteId], [50, -7, true, 180, 'KSC15'], 'CDI scale, delta azimuth, H_VR, site');
    near(d1.targetNz, 1.8, 0.0025, 'target Nz');
    near(d1.beta, -2.3, 0.1, 'beta');
    near(d1.dIncl, 1.25, 0.005, 'delta inclination');
    near(d1.thetaMaxDelta, 0.25, 1 / 4095, 'theta max delta');
    ok(d1.valid[8] && d1.valid[30] && !d1.valid['M2.1'], 'the validity bits decode');
    const m1p = C.encodeMEDS1({majorMode: 101}, [7, 8]);
    eq([m1p[0], m1p[1]], [0xc000, 0], 'validity given by hand: words 7 and 8');
    ok(!C.decodeMEDS1(m1p).valid[9], 'word 9 is then invalid');
    const m2 = C.encodeMEDS2({xtrk: -12.3, xtrkDev: -200, tgtIncl: 51.6});
    const d2 = C.decodeMEDS2(m2);
    eq([d2.xtrk, d2.xtrkDev, d2.tgtIncl], [-12.3, -200, 51.6], 'message 2 round trips');

    section('receiver');
    const got = [];
    const rx = new R.IDPFcRx(3, {onMessage: (m) => got.push(m)});
    const cmd = (c) => [(c >>> 8) & 0xffff, (c & 0xff) << 8];
    ok(rx.recv(cmd(C.commandWord(6, 'AMI')), true), 'a DDU 1 AMI command opens a transfer');
    for (const w of ami) rx.recv([w]);
    eq(got.length, 1, 'six words complete it');
    eq([got[0].bus, got[0].iua, got[0].ddu, got[0].msg, got[0].words], [3, 6, 1, 'AMI', ami], 'delivered with the bus, IUA, DDU and words');
    ok(!rx.recv([0x1234]), 'a data word outside a transfer is nothing');
    rx.recv(cmd(C.commandWord(9, 'HSI')), true);
    for (const w of hsi.slice(0, 4)) rx.recv([w]);
    rx.recv(cmd(0x5238a0), true);
    for (const w of [1, 2, 3, 4, 5, 6]) rx.recv([w]);
    eq(got.length, 1, 'a command to another unit ends a transfer short and its words go nowhere');
    eq(rx.stats.dropped, 1, 'counted as dropped');
    rx.recv(cmd(C.commandWord(15, 'MEDS1')), true);
    for (const w of m1) rx.recv([w]);
    eq(got.length, 2, 'the MEDS message arrives');
    eq([got[1].iua, got[1].ddu, got[1].msg], [15, null, 'MEDS1'], 'as IUA 15 with no DDU');
    const enc = R.encodeMduFc(M.MDUMsg.FC, got[1]);
    eq(enc.slice(0, 4), [0xff09, 3, 15, C.MSG_CODE.MEDS1], 'the MDU message header');
    eq(R.decodeMduFc(enc), {bus: 3, iua: 15, msg: 'MEDS1', words: m1}, 'and it decodes');
    ok(R.decodeMduFc([0xff09, 3, 6, 99]) === null, 'an unknown message code does not');
    ok(M.MDUMsgName[M.MDUMsg.FC] === 'FC', 'the tag is in the MDU message table');

    section('display fields');
    eq(F.STATION_DDU, {L: 1, R: 2, A: 3}, 'the stations follow DDU 1, 2 and 3');
    const stations = Object.fromEntries(Object.entries(M.MEDSConf.mdus).map(([k, v]) => [k, v.station]));
    eq(stations, {CRT1: 'L', CRT2: 'R', CRT3: 'L', CRT4: 'A', CDR1: 'L', CDR2: 'L', PLT1: 'R', PLT2: 'R', MFD1: 'L', MFD2: 'R', AFD1: 'A'},
       'every MDU has its crew station (USA-005350 sect.2.5.4)');
    const st = D.defaultState();
    st.adiRol = 30; st.adiPch = 350; st.adiYaw = 5;
    st.rolRate = 2.5; st.pchRate = -5; st.rolErr = 1.25; st.yawErr = -5;
    st.altitude = 3000; st.radarAlt = 2800; st.hdot = -80; st.mach = 0.7; st.keas = 260; st.alpha = 9; st.accel = 1.1;
    st.majorMode = 305; st.abortMode = null; st.dapAuto = false;
    const msgs = D.messagesOf(st);
    eq(msgs.length, 13, 'the drive gives the HFE\'s 13 messages');
    eq(msgs.map((m) => `${m.iua}:${m.msg}`).join(' '), '15:MEDS1 15:MEDS2 15:MEDS3 15:MEDS4 6:ADI 9:ADI 15:ADI 6:HSI 9:HSI 6:AVVI 9:AVVI 6:AMI 9:AMI', 'in order');
    const feed = {};
    for (const m of msgs) if (m.iua === 6 || m.msg.startsWith('MEDS')) feed[m.msg] = m.words;
    const f = F.fieldsOfFeed('L', feed, true).AE_PFD;
    ok(f.adiValid, 'the ADI is valid');
    near(f.adiRol, 30, 0.05, 'roll 30');
    near(f.adiPch, 350, 0.05, 'pitch 350');
    near(f.adiYaw, 5, 0.05, 'yaw 5');
    near(f.adiRolRate, 2.5, 0.01, 'roll rate 2.5 deg/s on the 5 deg/s scale is a pointer at +2.5');
    near(f.adiPchRate, -5, 0.01, 'pitch rate -5 is the pointer at full scale');
    near(f.adiRolErr, 1.25, 0.01, 'roll error 1.25 deg on the 5 deg scale');
    near(f.adiYawErr, -5, 0.01, 'yaw error at full scale');
    eq(f.adiYawRate, 0, 'yaw rate 0');
    ok(f.altValid && f.hdotValid && f.radarValid, 'altitude, hdot and radar valid below 5000 ft');
    near(f.altitude, 3000, 50, 'altitude 3000');
    near(f.hdot, -80, 1, 'hdot -80');
    near(f.radarAlt, 2800, 10, 'radar altitude 2800');
    near(f.mach, 0.7, 0.0075, 'mach 0.7');
    near(f.vel, 700, 7.5, 'and 700 ft/s');
    near(f.keas, 260, 0.125, 'KEAS 260');
    near(f.alpha, 9, 0.015, 'alpha 9');
    near(f.vehicleAcceleration, 1.1, 0.0025, 'acceleration 1.1 g');
    near(f.hsiHeading, 180, 0.2, 'heading 180');
    near(f.hsiCourse, 150, 0.2, 'course 150');
    eq([f.hsiPriRange, f.hsiSecRange], [45, 12], 'the ranges');
    near(f.hsiCdi, -0.5, 0.01, 'CDI -0.5 dots');
    near(f.hsiGsi, 0.3, 0.01, 'GSI 0.3 dots');
    eq([f.majorMode, f.abortMode, f.fcsConfDAPAuto, f.fcsConfThrotAuto, f.siteId], [305, null, false, true, 'KSC15'], 'the MEDS fields');
    eq([f.fcsConfPitchAuto, f.fcsConfRYAuto], [false, true], 'the same indicators under the gliding-flight names');
    {
        const st2 = Object.assign(D.defaultState(), {altitude: 3000});
        const g = F.fieldsOfFeed('L', Object.fromEntries(D.messagesOf(st2, {ddus: [1]}).map((m) => [m.msg, m.words])), true).AE_PFD;
        near(g.radarAlt, 2960, 10, 'the drive derives the radar altitude from the altitude');
    }
    eq(f.adiRateScale, {roll: 5, pitch: 5, yaw: 5, rollTgo: false, rollZeroOnRight: false}, 'the rate scale labels');
    eq(f.adiPchErrScale, 5, 'the pitch error scale label');
    near(f.targetNZ, 1.5, 0.0025, 'target Nz');
    const fr = F.fieldsOfFeed('R', {MEDS1: feed.MEDS1, MEDS2: feed.MEDS2}, true).AE_PFD;
    ok(fr.adiValid === false && fr.altValid === false, 'a station with no DDU words has invalid instruments');
    eq(fr.majorMode, 305, 'and the MEDS transfer\'s fields');
    const fs_ = F.fieldsOfFeed('L', feed, false).AE_PFD;
    ok(fs_.adiValid === false && fs_.altValid === false && fs_.adiRolRate === null && fs_.majorMode === null, 'a stale bus invalidates everything');
    {
        // "If a validity bit is off, the contents of the corresponding buffer
        // word will be indeterminate and should not be used by the MEDS
        // software" (F.4.128.1.2): the field goes null, it does not hold.
        const m1 = C.encodeMEDS1({majorMode: 304, hsiModeL: 2, cdiScale: 50, dAz: 7, beta: -2.3,
                                  siteId: 'KSC15', scale: {pitchRateL: 5}}, [8]);
        const b = F.medsFields(m1, null, true, 'L');
        eq(b.majorMode, 304, 'the one valid word carries its field');
        eq([b.hsiMode, b.cdiScale, b.dAz, b.beta, b.siteId, b.adiRateScale, b.adiPchErrScale,
            b.attSel, b.fcsConfDAPAuto, b.targetNZ, b.xtrk, b.thetaMaxDelta],
           [null, null, null, null, null, null, null, null, null, null, null, null],
           'and every word the GPC is not marking valid blanks its field');
    }
    const off = D.messagesOf(st, {offWords: ['ADI.rollRate', 'AVVI.altitude'], ddus: [1], meds: false});
    eq(off.length, 4, 'DDU 1 alone without the MEDS transfer is four messages');
    const feed2 = {}; for (const m of off) feed2[m.msg] = m.words;
    const f2 = F.fieldsOfFeed('L', feed2, true).AE_PFD;
    ok(f2.adiRolRate === null && f2.adiPchRate !== null, 'a rate word with its bit off stows the pointer');
    ok(f2.altValid === false && f2.hdotValid === true, 'the altitude word with its bit off is invalid');
    st.altitude = 25000;
    const f3 = F.fieldsOfFeed('L', Object.fromEntries(D.messagesOf(st, {ddus: [1]}).map((m) => [m.msg, m.words])), true).AE_PFD;
    ok(f3.radarValid === false, 'the drive marks radar altitude invalid above 5000 ft');
    const ramp = D.rampState(7, 60, D.defaultState());
    ok(ramp.adiRol >= 0 && ramp.adiRol <= 360 && ramp.altitude >= -1000, 'a ramp state is in range');

    section('bus');
    const tx = new B.Bus('FC3', B.busConfig.FC3);
    tx.onReceive(() => {}, null);
    const rxBus = new B.Bus('FC3', B.busConfig.FC3);
    const heard = [];
    const rx3 = new R.IDPFcRx(3, {onMessage: (m) => heard.push(m)});
    rxBus.onReceive((_, id, msg) => rx3.recv(msg.data16, msg.cmd), null);
    await Promise.all([tx.ready, rxBus.ready]);
    await settle(150);
    const send = (words) => { const bm = new B.BusMsg(words.length); words.forEach((w, i) => bm.data16[i] = w & 0xffff); tx.sendMsg(bm); };
    for (const m of msgs) {
        tx.sendMsg(B.BusMsg.Command(C.commandWord(m.iua, m.msg)));
        send(m.words);
    }
    await settle(200);
    eq(heard.length, 13, 'all 13 messages of a cycle arrive');
    eq(heard.map((m) => m.msg).join(' '), msgs.map((m) => m.msg).join(' '), 'in order');
    eq(heard[4].words, msgs[4].words, 'the DDU 1 ADI words intact');
    eq(rx3.stats.dropped, 0, 'none dropped');
    tx.close(); rxBus.close();

    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
