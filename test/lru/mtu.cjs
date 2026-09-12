// mtu.cjs — the Master Timing Unit behind its MDM
//
// Usage:
//   cd ext/sim && node test/lru/mtu.cjs
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
        `mtu.test.${path.basename(rel).replace(/\W/g, '_')}.${process.pid}.cjs`);
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
    const C = await bundle('lru/mtu/mtuConf.coffee');
    const D = await bundle('lru/mdm/mdmConf.coffee');
    const B = await bundle('com/bus.civet');
    const M = await bundle('lru/mtu/mtu.coffee');
    const X = await bundle('lru/mdm/mdm.coffee');

    const HOUR = C.MS_PER_HOUR, DAY = C.MS_PER_DAY;

    section('command words');
    eq(C.CMD_READ.toString(16),   '524c26', 'read is 524C26');
    eq(C.CMD_UPDATE.toString(16), '520c23', 'update is 520C23');
    eq(C.CMD_RESET.toString(16),  '520c20', 'reset is 520C20');
    for (const [name, cmd, mode, count] of [
        ['read',   C.CMD_READ,   D.MODE.INPUT,  7],
        ['update', C.CMD_UPDATE, D.MODE.OUTPUT, 4],
        ['reset',  C.CMD_RESET,  D.MODE.OUTPUT, 1],
    ]) {
        const c = D.decodeCommand(cmd);
        eq([c.iua, c.mode, c.card, c.channel, c.count], [10, mode, 3, 1, count],
           `${name} is IUA 10, card 3, channel 1, ${count} words`);
    }
    eq([C.ACCUM_MDM[1], C.ACCUM_MDM[2], C.ACCUM_MDM[3]], ['FF1', 'FF2', 'FF3'],
       'accumulators 1, 2 and 3 hang on FF1, FF2 and FF3');

    section('time format');
    eq(C.packTime(C.RESET_GMT_MS), [0x0040, 0x0000, 0x0000], '001:00:00:00.000 packs to 0040 0000 0000');
    eq(C.packTime(C.RESET_MET_MS), [0x0000, 0x0000, 0x0000], '000:00:00:00.000 packs to zeros');

    const full = C.joinTime({days: 399, hours: 23, minutes: 59, seconds: 59, millis: 999.875});
    eq(C.packTime(full), [0xe663, 0xb364, 0x1f3f], '399:23:59:59.999875 is the largest value the fields hold');

    const t = C.packTime(C.joinTime({days: 52, hours: 14, minutes: 30, seconds: 0, millis: 125}));
    eq(t, [0x1494, 0x6000, 0x03e8], '052:14:30:00.125 packs to 1494 6000 03e8');
    eq((t[0] >> 6) & 0x3ff, 0x052, 'days are BCD in bits 15-6 of word 1');
    eq(t[0] & 0x3f, 0x14, 'hours are BCD in bits 5-0 of word 1');
    eq((t[1] >> 9) & 0x7f, 0x30, 'minutes are BCD in bits 15-9 of word 2');
    eq((t[1] >> 2) & 0x7f, 0x00, 'seconds are BCD in bits 8-2 of word 2');
    eq(t[2], 1000, 'milliseconds are binary 0.125 ms units in word 3');
    const s37 = C.packTime(C.joinTime({days: 0, hours: 0, minutes: 0, seconds: 37, millis: 0}));
    eq((s37[1] >> 6) & 0x7, 3, 'the tens of seconds sit in bits 8-6');
    eq((s37[1] >> 2) & 0xf, 7, 'and the units in bits 5-2');

    for (const ms of [0, DAY, C.joinTime({days: 300, hours: 9, minutes: 8, seconds: 7, millis: 375}), full]) {
        eq(C.unpackTimeMs(C.packTime(ms)), ms, `${C.fmtTime(ms)} round trips`);
    }

    eq(C.parseTime('052:14:30:00.125'), C.joinTime({days: 52, hours: 14, minutes: 30, seconds: 0, millis: 125}),
       'DDD:HH:MM:SS.sss parses');
    eq(C.parseTime('14:30:00'), 14 * HOUR + 30 * C.MS_PER_MINUTE, 'a time with no day is day zero');
    ok(C.parseTime('400:00:00:00') === null, 'day 400 is rejected');
    ok(C.parseTime('001:24:00:00') === null, 'hour 24 is rejected');

    section('mode word');
    eq(C.packMode(C.MODE.UPDATE_GMT), 0x3000, 'update GMT is 3000');
    eq(C.packMode(C.MODE.UPDATE_MET), 0x5000, 'update MET is 5000');
    eq(C.packMode(C.MODE.RESET_GMT),  0x6000, 'reset GMT is 6000');
    eq(C.packMode(C.MODE.RESET_MET),  0x9000, 'reset MET is 9000');
    eq(C.packMode(C.MODE.UPDATE_GMT, 1), 0x3020, 'a coincidence time of one minute is 0020');
    const m = C.unpackMode(C.packMode(C.MODE.UPDATE_MET, 47));
    eq([m.mode, m.name, m.coincidence], [C.MODE.UPDATE_MET, 'UPDATE_MET', 47], 'the mode word round trips');

    section('BITE status');
    eq(C.BITE.OSC1_DRIVES, 0x8000, 'bit 1 is the driving oscillator');
    eq(C.BITE.ACCUM1, 0x0080, 'bit 9 is accumulator 1');
    eq(C.BITE.IRIG_B, 0x0010, 'bit 12 is the IRIG B difference');
    eq(C.BITE.VALID_UPDATE, 0x0001, 'bit 16 is valid update received');
    eq(C.fmtBite(0), 'none', 'a clear status names nothing');
    eq(C.fmtBite(C.BITE.OSC1_DRIVES | C.BITE.VALID_UPDATE), 'OSC1_DRIVES VALID_UPDATE', 'set bits are named, bit 1 first');

    section('rollover');
    {
        const mtu = new M.MTU({accumulators: [1], rolloverDays: 365});
        eq(mtu._wrapGmt(365 * DAY), 365 * DAY, 'day 365 is inside the range');
        eq(mtu._wrapGmt(366 * DAY), DAY, 'GMT returns to day 1 at the end of the rollover day');
        eq(mtu._wrapGmt(366 * DAY + 5 * HOUR), DAY + 5 * HOUR, 'and carries the time of day across');
        eq(mtu._wrapMet(400 * DAY), 0, 'MET wraps to zero at the end of day 399');
        eq(mtu._wrapMet(400 * DAY + 7 * HOUR), 7 * HOUR, 'and carries the time of day');
        ok(mtu.accums[1].busName === D.ioBusName('FF1'), "accumulator 1 sits on FF1's hardware side bus");
        mtu.stop();
    }

    section('through the MDM');

    // A GPC on FC1, MDM FF1 on FC1 and FC5 with its hardware side bus, and
    // accumulator 1 on that bus.
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
    const gmt0 = C.joinTime({days: 52, hours: 14, minutes: 29, seconds: 57, millis: 0});
    const met0 = C.joinTime({days: 3, hours: 1, minutes: 2, seconds: 3, millis: 0});
    const mtu = new M.MTU({accumulators: [1], gmtMs: gmt0, metMs: met0});

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
        heard.length = 0;
        sendCmd(C.CMD_READ);
        await settle();
        return heard.splice(0);
    };

    await settle(200);
    ok(ioHeard.some((d) => d.opName === 'CONNECT' && d.card === 3 && d.channel === 1),
       'the accumulator says CONNECT on card 3 channel 1 when it starts');
    ok(ioHeard.some((d) => d.opName === 'REQUEST'), 'and the MDM asked who is on its channels');
    eq(mdm.cards[3].link[1], true, 'so the MDM has the channel connected');
    heard.length = 0; ioHeard.length = 0; meta.length = 0;

    let reply = await read();
    eq(reply.length, 1, 'a read through the MDM is answered by one transmission');
    eq(reply[0].length, 7, 'of seven halfwords');
    eq(meta.splice(0), [{sev: null, delayUs: 235}],
       'valid, on the bus 7 x 33.5 us after the command');
    eq(ioHeard.map((d) => [d.opName, d.card, d.channel, d.count || d.words.length]),
       [['POLL', 3, 1, 7], ['VALUE', 3, 1, 7]],
       'the MDM polled card 3 channel 1 and the accumulator answered');
    let gmt = C.unpackTimeMs(reply[0].slice(0, 3));
    let met = C.unpackTimeMs(reply[0].slice(3, 6));
    ok(gmt >= gmt0 && gmt < gmt0 + 5000, 'words 1-3 are GMT');
    ok(met >= met0 && met < met0 + 5000, 'words 4-6 are MET');
    eq(reply[0][6], C.BITE.OSC1_DRIVES, 'word 7 is BITE: oscillator 1 driving, no faults');

    await settle(500);
    const later = C.unpackTimeMs((await read())[0].slice(0, 3));
    ok(later - gmt > 450 && later - gmt < 1200, 'the accumulator keeps time between reads');

    sendCmd(C.CMD_RESET);
    sendData([C.packMode(C.MODE.RESET_GMT)]);
    await settle();
    reply = await read();
    ok(C.unpackTimeMs(reply[0].slice(0, 3)) < DAY + 5000, 'a GMT reset leaves the accumulator at day 1');
    ok(C.unpackTimeMs(reply[0].slice(3, 6)) > met0, 'and leaves MET running');
    eq(mtu.accums[1].writes, 1, 'as one write to the accumulator');

    sendCmd(C.CMD_RESET);
    sendData([C.packMode(C.MODE.RESET_MET)]);
    await settle();
    reply = await read();
    ok(C.unpackTimeMs(reply[0].slice(3, 6)) < 5000, 'a MET reset leaves the accumulator at zero');

    const target = C.joinTime({days: 100, hours: 5, minutes: 30, seconds: 0, millis: 0});
    sendCmd(C.CMD_UPDATE);
    sendData(C.packTime(target).concat([C.packMode(C.MODE.UPDATE_GMT, 30)]));
    await settle();
    reply = await read();
    ok((reply[0][6] & C.BITE.VALID_UPDATE) !== 0, 'a held update sets valid update received');
    ok(C.unpackTimeMs(reply[0].slice(0, 3)) < DAY + 5000, 'and the accumulator still reads the old time');

    mtu._applyPending(mtu.accums[1]);
    reply = await read();
    ok(Math.abs(C.unpackTimeMs(reply[0].slice(0, 3)) - target) < 5000, 'once executed the accumulator reads the loaded time');
    eq(reply[0][6] & C.BITE.VALID_UPDATE, 0, 'and the valid update bit clears');

    mtu.setAnswers(1, false);
    meta.length = 0;
    const stale = (await read())[0];
    eq(stale.length, 7, 'a silent accumulator still gets the GPC seven words from the MDM');
    ok(Math.abs(C.unpackTimeMs(stale.slice(0, 3)) - C.unpackTimeMs(reply[0].slice(0, 3))) < 1,
       'and they are the words of the last answered read');
    eq(meta.splice(0)[0].sev, [7, 7, 7, 7, 7, 7, 7], 'each with E set');
    mtu.setAnswers(1, true);

    ioHeard.length = 0;
    mtu.setConnected(1, false);
    await settle();
    ok(ioHeard.some((d) => d.opName === 'DISCONNECT' && d.card === 3 && d.channel === 1),
       'unplugging says DISCONNECT');
    eq(mdm.cards[3].link[1], false, 'and the MDM has the channel empty');
    ioHeard.length = 0; meta.length = 0;
    await read();
    eq(ioHeard.filter((d) => d.opName === 'POLL').length, 0, 'a read then polls nobody');
    eq(meta.splice(0)[0].sev, [7, 7, 7, 7, 7, 7, 7], 'and the GPC gets seven words with E set');
    eq(mtu.accums[1].reads, 7, 'the accumulator did not hear it');
    mtu.setConnected(1, true);
    await settle();
    eq(mdm.cards[3].link[1], true, 'plugging back in reconnects');

    ioHeard.length = 0;
    {
        const q = D.encodeIO({op: D.IO_OP.REQUEST, type: 0, card: D.IO_ALL, channel: D.IO_ALL, words: []});
        const mm = new B.BusMsg(q.length);
        mm.data16.set(q);
        io.sendMsg(mm);
    }
    await settle();
    ok(ioHeard.some((d) => d.opName === 'CONNECT' && d.card === 3 && d.channel === 1),
       'a REQUEST naming every channel is answered with CONNECT');

    const before = mtu.gmtOf(mtu.accums[1]);
    mtu.setSkew(1, 1000);
    const after = mtu.gmtOf(mtu.accums[1]);
    ok(after - before >= 995 && after - before <= 1005, 'skew moves an accumulator by the milliseconds given');
    const skewed = C.unpackTimeMs((await read())[0].slice(0, 3));
    ok(Math.abs(skewed - mtu.gmtOf(mtu.accums[1])) < 500, 'and the skewed time is what the GPC reads');

    ioHeard.length = 0;
    sendCmd(D.encodeDirect(10, D.MODE.INPUT, 3, 2, 3));
    await settle();
    eq(ioHeard.filter((d) => d.opName === 'VALUE').length, 0, 'a poll of channel 2 is not answered by the accumulator');
    eq(mtu.accums[1].reads, 8, 'which has heard its own polls only');

    ioHeard.length = 0;
    await mtu.stop();
    await settle();
    ok(ioHeard.some((d) => d.opName === 'DISCONNECT' && d.card === 3 && d.channel === 1),
       'stopping says DISCONNECT');

    // The instrumentation outputs behind OF1 and OF2, polled as a PCMMU's
    // OI MDM would poll them.
    section('instrumentation outputs');
    {
        const oiName1 = D.ioBusName('OF1'), oiName2 = D.ioBusName('OF2');
        const oi1 = new B.Bus(oiName1, B.busConfig[oiName1]);
        const oi2 = new B.Bus(oiName2, B.busConfig[oiName2]);
        const got1 = [], got2 = [];
        oi1.onReceive((_, id, msg) => { const d = D.decodeIO(msg.data16); if (d && d.op === D.IO_OP.VALUE) got1.push(d); }, null);
        oi2.onReceive((_, id, msg) => { const d = D.decodeIO(msg.data16); if (d && d.op === D.IO_OP.VALUE) got2.push(d); }, null);
        const three = new M.MTU({accumulators: [1, 2, 3], outputs: [1, 2], gmtMs: gmt0, metMs: met0});
        three.setSkew(2, 20000);
        three.setSkew(3, 40000);
        await settle(200);
        const poll = (bus, card = 0, channel = 1) => {
            const d = D.encodeIO({op: D.IO_OP.POLL, type: D.IOM.SIO.code, card, channel, count: 7});
            const mm = new B.BusMsg(d.length);
            mm.data16.set(d);
            bus.sendMsg(mm);
        };
        poll(oi1);
        poll(oi2);
        await settle();
        eq(got1.length, 1, 'a poll of OF1 card 0 channel 1 is answered');
        eq([got1[0].card, got1[0].channel, got1[0].words.length], [0, 1, 7], 'with seven words on that channel');
        const voted = C.unpackTimeMs(got1[0].words.slice(0, 3));
        ok(Math.abs(voted - three.gmtOf(three.accums[2])) < 500, 'the voted output is the middle accumulator');
        eq(got2.length, 1, 'a poll of OF2 is answered too');
        const nonvoted = C.unpackTimeMs(got2[0].words.slice(0, 3));
        ok(Math.abs(nonvoted - three.gmtOf(three.accums[1])) < 500, 'the non-voted output is accumulator 1');
        eq(got1[0].words[6], C.BITE.OSC1_DRIVES, 'and the BITE word rides along');
        got1.length = 0;
        poll(oi1, 0, 2);
        poll(oi1, 3, 1);
        await settle();
        eq(got1.length, 0, 'another channel or card of OF1 is not answered');
        three.setAnswers(2, false);
        got1.length = 0;
        poll(oi1);
        await settle();
        ok(Math.abs(C.unpackTimeMs(got1[0].words.slice(0, 3)) - three.gmtOf(three.accums[1])) < 500 ||
           Math.abs(C.unpackTimeMs(got1[0].words.slice(0, 3)) - three.gmtOf(three.accums[3])) < 500,
           'with an accumulator silent the vote is between the other two');
        eq(three.report().outputs.map((o) => [o.num, o.nom, o.mdm]), [[1, 'voted', 'OF1'], [2, 'non-voted', 'OF2']],
           'the report names both outputs');
        three.stop();
        oi1.close(); oi2.close();
        await settle();
    }

    section('one accumulator at a time');
    {
        const pair = new M.MTU({accumulators: [1, 2], gmtMs: gmt0, metMs: met0});
        pair._doWrite(pair.accums[1], [C.packMode(C.MODE.RESET_GMT)]);
        ok(pair.gmtOf(pair.accums[1]) < DAY + 5000, 'the accumulator addressed is reset');
        ok(pair.gmtOf(pair.accums[2]) >= gmt0, 'and the others keep running');
        pair.setSkew(2, 1000);
        pair._doWrite(pair.accums[2], [C.packMode(C.MODE.RESET_GMT)]);
        ok(pair.gmtOf(pair.accums[2]) - DAY >= 1000, 'a reset leaves the skew in place');
        pair.stop();
    }

    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
