// adta.cjs — the Air Data Transducer Assemblies behind their MDMs
//
// Usage:
//   cd ext/sim && node test/lru/adta.cjs
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
        `adta.test.${path.basename(rel).replace(/\W/g, '_')}.${process.pid}.cjs`);
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
    const C = await bundle('lru/adta/adtaConf.coffee');
    const D = await bundle('lru/mdm/mdmConf.coffee');
    const B = await bundle('com/bus.civet');
    const M = await bundle('lru/adta/adta.coffee');
    const X = await bundle('lru/mdm/mdm.coffee');

    section('command word');
    eq(C.CMD_READ.toString(16), '526c22', 'read is 526C22');
    const c = D.decodeCommand(C.CMD_READ);
    eq([c.iua, c.mode, c.card, c.channel, c.count], [10, D.MODE.INPUT, 11, 1, 3],
       'read is IUA 10, card 11, channel 1, 3 words');
    eq([C.UNIT_MDM[1], C.UNIT_MDM[2], C.UNIT_MDM[3], C.UNIT_MDM[4]],
       ['FF1', 'FF2', 'FF3', 'FF4'], 'ADTA 1 to 4 hang on FF1 to FF4');
    eq([C.PROBE[1], C.PROBE[2], C.PROBE[3], C.PROBE[4]],
       ['left', 'right', 'left', 'right'], '1 and 3 are behind the left probe, 2 and 4 the right');

    section('mode status');
    eq(C.NOMINAL_STATUS, 0x8ffc, 'the nominal word is 8FFC');
    eq(C.STATUS.ADTA_GOOD, 0x8000, 'bit 0 is ADTA good');
    eq(C.STATUS.HIGH_TEST, 0x2000, 'bit 2 is the high test mode');
    eq(C.STATUS.LOW_TEST, 0x1000, 'bit 3 is the low test mode');
    eq(C.STATUS.PS_GOOD, 0x0100, 'bit 7 is static pressure good');
    eq(C.STATUS.FD_FAIL, 0x0001, 'bit 15 is the frequency divider');
    eq(C.FAIL_BITS, 0x4003, 'bits 1, 14 and 15 read 1 failed');
    eq(C.MODE_BITS, 0x3000, 'bits 2 and 3 report the self test in force');
    eq(C.FAKE_DATA_NAME.length, C.OUT_WORDS - 1,
       'the fitted layout names the five words after the status');

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
    const adta = new M.ADTA({units: [1]});

    const sendCmd = (cmd) => gpc.sendMsg(B.BusMsg.Command(cmd));
    const settle = (msec = 120) => new Promise((r) => setTimeout(r, msec));
    const read = async () => {
        heard.length = 0; meta.length = 0; ioHeard.length = 0;
        sendCmd(C.CMD_READ);
        await settle();
        return heard.splice(0);
    };

    await settle(200);
    ok(ioHeard.some((d) => d.opName === 'CONNECT' && d.card === 11 && d.channel === 1),
       'the unit says CONNECT on card 11 channel 1 when it starts');
    eq(mdm.cards[11].link[1], true, 'so the MDM has the channel connected');

    let reply = await read();
    eq(reply.length, 1, 'a read through the MDM is answered by one transmission');
    eq(reply[0].length, 3, 'of three halfwords');
    eq(meta.splice(0), [{sev: null, delayUs: 101}],
       'valid, on the bus 3 x 33.5 us after the command');
    eq(ioHeard.map((d) => [d.opName, d.card, d.channel, d.count || d.words.length]),
       [['POLL', 11, 1, 3], ['VALUE', 11, 1, 3]],
       'the MDM polled card 11 channel 1 and the unit answered');
    eq(reply[0][0], 0x8ffc, 'data word 1 is the mode status, everything good');
    eq(reply[0].slice(1), [0, 0], 'the pressures and the total temperature read zero');

    section('self test');
    adta.setSelfTest(1, 'high');
    reply = await read();
    eq(reply[0][0], 0x8ffc | C.STATUS.HIGH_TEST, 'a high self test sets bit 2');
    adta.setSelfTest(1, 'low');
    reply = await read();
    eq(reply[0][0], 0x8ffc | C.STATUS.LOW_TEST, 'a low self test sets bit 3');
    adta.setSelfTest(1, null);
    reply = await read();
    eq(reply[0][0], 0x8ffc, 'and off clears them');

    section('mode status BITE');
    adta.setFault(1, C.STATUS.PS_GOOD);
    reply = await read();
    eq(reply[0][0], 0x8ffc & ~C.STATUS.PS_GOOD, 'a fault on a good bit clears it');
    adta.setFault(1, C.STATUS.PS_GOOD, false);
    adta.setFault(1, C.STATUS.RAM_FAIL);
    reply = await read();
    eq(reply[0][0], 0x8ffc | C.STATUS.RAM_FAIL, 'a fault on a fail bit sets it');
    adta.setFault(1, C.STATUS.RAM_FAIL, false);

    section('short and long reads');
    heard.length = 0; meta.length = 0;
    sendCmd(D.encodeDirect(D.IUA.FF, D.MODE.INPUT, C.CARD, C.CHANNEL, 6));
    await settle();
    eq(heard[0].length, 6, 'a six word read is answered with all six the unit has');
    eq(meta[0].sev, null, 'and is valid');

    heard.length = 0; meta.length = 0;
    sendCmd(D.encodeDirect(D.IUA.FF, D.MODE.INPUT, C.CARD, C.CHANNEL, 8));
    await settle();
    eq(heard[0].length, 8, 'an eight word read comes back with eight');
    ok(meta[0].sev !== null && meta[0].sev.slice(0, 6).every((s) => s === D.SEV.VALID),
       'the six the unit answered are valid');
    ok(meta[0].sev.slice(6).every((s) => (s & D.SEV.E) !== 0),
       'and the card flags the two it heard nothing for');

    section('a silent unit');
    adta.setAnswers(1, false);
    heard.length = 0; meta.length = 0;
    sendCmd(C.CMD_READ);
    await settle(300);
    ok(meta.length > 0 && meta[0].sev !== null, 'an unanswered poll comes back flagged');
    ok(meta[0].sev.every((s) => (s & D.SEV.E) !== 0), 'with E set on every word');
    adta.setAnswers(1, true);

    section('disconnect');
    adta.setConnected(1, false);
    await settle();
    eq(mdm.cards[11].link[1], false, 'the MDM has the channel down');
    adta.setConnected(1, true);
    await settle();
    eq(mdm.cards[11].link[1], true, 'and up again');

    await adta.stop();
    await settle();
    gpc.close(); io.close(); mdm.stop?.();

    section('four units');
    {
        const four = new M.ADTA({units: [1, 2, 3, 4]});
        eq(four.report().units.map((u) => [u.num, u.mdm, u.probe, u.status]),
           [[1, 'FF1', 'left', '8ffc'], [2, 'FF2', 'right', '8ffc'],
            [3, 'FF3', 'left', '8ffc'], [4, 'FF4', 'right', '8ffc']],
           'the report names all four, each on its own MDM');
        four.setFault(3, C.STATUS.ELEC_GOOD);
        eq(four.statusOf(four.units[3]), 0x8ffc & ~C.STATUS.ELEC_GOOD, 'a BITE reaches the unit named');
        eq(four.statusOf(four.units[1]), 0x8ffc, 'and leaves the others alone');
        await four.stop();
        await settle();
    }

    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
