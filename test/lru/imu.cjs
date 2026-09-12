// imu.cjs — the Inertial Measurement Units behind their MDMs
//
// Usage:
//   cd ext/sim && node test/lru/imu.cjs
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
        `imu.test.${path.basename(rel).replace(/\W/g, '_')}.${process.pid}.cjs`);
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
function section(name) { console.log(`\n--- ${name} ---`); }

(async () => {
    const C = await bundle('lru/imu/imuConf.coffee');
    const D = await bundle('lru/mdm/mdmConf.coffee');
    const B = await bundle('com/bus.civet');
    const M = await bundle('lru/imu/imu.coffee');
    const X = await bundle('lru/mdm/mdm.coffee');

    section('command words');
    eq(C.CMD_READ.toString(16),  '524c0d', 'read is 524C0D');
    eq(C.CMD_WRITE.toString(16), '520c01', 'write is 520C01');
    for (const [name, cmd, mode, count] of [
        ['read',  C.CMD_READ,  D.MODE.INPUT,  14],
        ['write', C.CMD_WRITE, D.MODE.OUTPUT, 2],
    ]) {
        const c = D.decodeCommand(cmd);
        eq([c.iua, c.mode, c.card, c.channel, c.count], [10, mode, 3, 0, count],
           `${name} is IUA 10, card 3, channel 0, ${count} words`);
    }
    eq([C.UNIT_MDM[1], C.UNIT_MDM[2], C.UNIT_MDM[3]], ['FF1', 'FF2', 'FF3'],
       'IMU 1, 2 and 3 hang on FF1, FF2 and FF3');
    eq([C.OUT_WORDS, C.READ_WORDS], [16, 14],
       'the unit outputs sixteen data words and the GPC reads fourteen');

    section('mode status');
    eq(C.NOMINAL_STATUS, 0x8000, 'the nominal word is 8000');
    eq(C.STATUS.HAINS_GOOD, 0x8000, 'bit 0 is HAINS good');
    eq(C.STATUS.MUX_FAIL, 0x4000, 'bit 1 is MUX fail');
    eq(C.STATUS.TRANS_WD1_FAIL, 0x0040, 'bit 9 is transmission word 1 fail');
    eq(C.STATUS.D5_SEQUENCE, 0x0001, 'bit 15 is the D5 sequence discrete');
    eq(C.fmtStatus(0x8000 | C.STATUS.PLATFORM_FAIL), 'HAINS_GOOD PLATFORM_FAIL',
       'the named bits come out bit 0 first');

    section('torque command');
    eq(C.torques(0x0000), [0, 0, 0], 'a zero command torques nothing');
    eq(C.torqueOf(0x8000, 0), 0, 'the X sign bit alone is zero magnitude');
    eq(C.torqueOf(0xc000, 0), 4, 'X sign with the magnitude MSB is +4 arcsec');
    eq(C.torqueOf(0x4000, 0), -4, 'without the sign bit it is -4 arcsec');
    eq(C.torqueOf(0x8800, 0), 0.5, 'the magnitude LSB is 0.5 arcsec');
    eq(C.torqueOf(0xf800, 0), 7.5, 'all four magnitude bits are +7.5 arcsec, the largest an axis holds');
    eq(C.torques(0xb27e), [3, -4.5, 7.5], 'the three axes sit at bits 0-4, 5-9 and 10-14');
    eq(C.fmtSlew(C.SLEW.CAPRI_SF | C.SLEW.Z_NEG), 'CAPRI_SF Z_NEG',
       'command word 2 names the slew bits');

    section('through the MDM');

    const heard = [];
    const meta = [];        // each transmission's SEV flags and reply delay
    const gpc = new B.Bus('FC1', B.busConfig['FC1']);
    gpc.onReceive((_, id, msg) => {
        heard.push(Array.from(msg.data16));
        meta.push({sev: msg.sev, delayUs: msg.delayUs});
    }, null);
    const ioHeard = [];
    const ioName = D.ioBusName('FF1');
    const io = new B.Bus(ioName, B.busConfig[ioName]);
    io.onReceive((_, id, msg) => { const d = D.decodeIO(msg.data16); if (d) ioHeard.push(d); }, null);

    const mdm = new X.MDM({id: 'FF1'});
    const imu = new M.IMU({units: [1]});

    const sendCmd = (cmd) => gpc.sendMsg(B.BusMsg.Command(cmd));
    const sendData = (words) => {
        for (const w of words) {
            const mm = new B.BusMsg(1);
            mm.data16[0] = w & 0xffff;
            gpc.sendMsg(mm);
        }
    };
    const settle = (msec = 120) => new Promise((r) => setTimeout(r, msec));
    const read = async () => {
        heard.length = 0; meta.length = 0; ioHeard.length = 0;
        sendCmd(C.CMD_READ);
        await settle();
        return heard.splice(0);
    };

    await settle(200);
    ok(ioHeard.some((d) => d.opName === 'CONNECT' && d.card === 3 && d.channel === 0),
       'the unit says CONNECT on card 3 channel 0 when it starts');
    eq(mdm.cards[3].link[0], true, 'so the MDM has the channel connected');

    let reply = await read();
    eq(reply.length, 1, 'a read through the MDM is answered by one transmission');
    eq(reply[0].length, 14, 'of fourteen halfwords');
    eq(meta.splice(0), [{sev: null, delayUs: 469}],
       'valid, on the bus 14 x 33.5 us after the command');
    eq(ioHeard.map((d) => [d.opName, d.card, d.channel, d.count || d.words.length]),
       [['POLL', 3, 0, 14], ['VALUE', 3, 0, 14]],
       'the MDM polled card 3 channel 0 and the unit answered');
    eq(reply[0][0], 0x8000, 'data word 1 is the mode status, HAINS good');
    eq(reply[0].slice(1, 12), new Array(11).fill(0), 'data words 2 to 12 read zero');
    eq([reply[0][12], reply[0][13]], [0, 0], 'and the echo words start clear');

    section('command echo');
    sendCmd(C.CMD_WRITE);
    sendData([0xb27e, C.SLEW.CAPRI_SF | C.SLEW.X_POS]);
    await settle();
    reply = await read();
    eq(reply[0][12], 0xb27e, 'data word 13 echoes command word 1');
    eq(reply[0][13], C.SLEW.CAPRI_SF | C.SLEW.X_POS, 'data word 14 echoes command word 2');
    eq(imu.units[1].writes, 1, 'as one write to the unit');

    section('short and long reads');
    heard.length = 0; meta.length = 0;
    sendCmd(D.encodeDirect(D.IUA.FF, D.MODE.INPUT, C.CARD, C.CHANNEL, 6));
    await settle();
    eq(heard[0].length, 6, 'a six word read is answered with six');
    eq(meta[0].sev, null, 'and is valid');

    section('mode status BITE');
    imu.setFault(1, C.STATUS.PLATFORM_FAIL);
    reply = await read();
    eq(reply[0][0], 0x8000 | C.STATUS.PLATFORM_FAIL, 'the injected bit reads back in word 1');
    imu.setFault(1, C.STATUS.PLATFORM_FAIL, false);
    reply = await read();
    eq(reply[0][0], 0x8000, 'and clears again');

    section('a silent unit');
    imu.setAnswers(1, false);
    heard.length = 0; meta.length = 0;
    sendCmd(C.CMD_READ);
    await settle(300);
    ok(meta.length > 0 && meta[0].sev !== null, 'an unanswered poll comes back flagged');
    ok(meta[0].sev.every((s) => (s & D.SEV.E) !== 0), 'with E set on every word');
    imu.setAnswers(1, true);

    section('disconnect');
    imu.setConnected(1, false);
    await settle();
    eq(mdm.cards[3].link[0], false, 'the MDM has the channel down');
    imu.setConnected(1, true);
    await settle();
    eq(mdm.cards[3].link[0], true, 'and up again');

    await imu.stop();
    await settle();
    gpc.close(); io.close(); mdm.stop?.();

    section('three units');
    {
        const three = new M.IMU({units: [1, 2, 3]});
        eq(three.report().units.map((u) => [u.num, u.mdm, u.status]),
           [[1, 'FF1', '8000'], [2, 'FF2', '8000'], [3, 'FF3', '8000']],
           'the report names all three, each on its own MDM');
        three.setFault(2, C.STATUS.MUX_FAIL);
        eq(three.statusOf(three.units[2]), 0x8000 | C.STATUS.MUX_FAIL, 'a BITE reaches the unit named');
        eq(three.statusOf(three.units[1]), 0x8000, 'and leaves the others alone');
        three._doWrite(three.units[3], [0x1234, 0x5678]);
        eq(three.units[3].out[12], 0x1234, 'a write reaches the unit whose MDM carried it');
        eq(three.units[1].out[12], 0, 'and no other');
        await three.stop();
        await settle();
    }

    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
