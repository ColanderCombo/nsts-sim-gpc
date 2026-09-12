// nsp.cjs — the Network Signal Processors and the forward link
//
// Usage:
//   cd ext/sim && node test/lru/nsp.cjs
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
        `nsp.test.${path.basename(rel).replace(/\W/g, '_')}.${process.pid}.cjs`);
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

// A deterministic bit source.
function lcg(seed) {
    let s = seed >>> 0;
    return () => { s = (Math.imul(s, 1664525) + 1013904223) >>> 0; return (s >>> 16) & 1; };
}

(async () => {
    const C = await bundle('lru/nsp/nspConf.coffee');
    const D = await bundle('lru/mdm/mdmConf.coffee');
    const B = await bundle('com/bus.civet');
    const N = await bundle('lru/nsp/nsp.coffee');
    const U = await bundle('lru/nsp/uplink.coffee');
    const X = await bundle('lru/mdm/mdm.coffee');

    section('command words');
    eq(C.CMD_READ.toString(16), '526c7f', 'the message read is 526C7F');
    eq(C.CMD_POWER[1].toString(16), '526420', 'NSP 1 power discrete is 526420');
    eq(C.CMD_POWER[2].toString(16), '527020', 'NSP 2 power discrete is 527020');
    eq(C.CMD_BLOCK.toString(16), '525000', 'the uplink block discrete is 525000');
    for (const [name, cmd, card, ch, n] of [
        ['read', C.CMD_READ, 11, 3, 32], ['power 1', C.CMD_POWER[1], 9, 1, 1],
        ['power 2', C.CMD_POWER[2], 12, 1, 1], ['block', C.CMD_BLOCK, 4, 0, 1],
    ]) {
        const c = D.decodeCommand(cmd);
        eq([c.iua, c.mode, c.card, c.channel, c.count], [10, D.MODE.INPUT, card, ch, n],
           `${name} is IUA 10 INPUT card ${card} channel ${ch} x${n}`);
    }
    eq([C.UNIT[1].mdm, C.UNIT[2].mdm], ['FF1', 'FF3'], 'NSP 1 hangs on FF1, NSP 2 on FF3');

    section('command word');
    const h = {vehicle: 2, mf: C.MF.GNC, opcode: C.OPCODE.MDM_SINGLE, first: true, last: true};
    eq(C.packHeader(h), 0x4f17, 'vehicle 2, GNC, MDM single, single word packs to 4F17');
    eq(C.unpackHeader(0x4f17), {vehicle: 2, mf: 7, opcode: 69, first: true, last: true}, 'and unpacks');
    eq(C.packHeader({vehicle: 5, mf: C.MF.BFS, opcode: C.OPCODE.MDM_MULTIPLE, first: true, last: false}),
       0xb40e, 'vehicle 5, BFS, MDM multiple, first word packs to B40E');
    const rtc = {card: 10, set: true, channel: 0, mdm: C.MDM_NUMBER.FF1, mask: 0x0001};
    eq(C.packRtc(rtc).toString(16), 'a8010001', 'FF1 card 10 channel 0 set 0001 is A801 0001');
    eq(C.unpackRtc(C.packRtc(rtc)), rtc, 'and unpacks');
    eq(C.packCommand(h, C.packRtc(rtc)), [0x4f17, 0xa801, 0x0001], 'the three halfwords of the command');
    eq(C.fmtCommand([0x4f17, 0xa801, 0x0001]), 'veh 2 GNC MDM_SINGLE FL a801 0001', 'which format by name');
    eq(C.validityBit(0), 0x8000, 'validity bit 1 is command 1');
    eq(C.validityBit(9), 0x0040, 'and bit 10 is command 10');
    eq(C.STATUS.DATA_READY, 0x8000, 'data ready is status bit 1');
    eq(C.STATUS.DATA_INHIBIT, 0x4000, 'data inhibit is bit 2');
    eq(C.STATUS.NSP_FAIL, 0x0001, 'NSP status is bit 16');
    eq(C.fmtStatus(0xc001), 'DATA_READY DATA_INHIBIT NSP_FAIL', 'status bits format by name');

    section('BCH');
    const info = [0, 0].concat(C.wordsToBits([0x4a8b, 0x1234, 0x5678]));
    eq(info.length, 50, 'two dummy bits and 48 command bits are the 50 information bits');
    const par = C.bchParity(info);
    eq(par.length, 77, 'the parity is 77 bits');
    eq(BigInt('0b' + par.join('')).toString(16), '24e25d6c3ef9cbe4e0a',
       'the parity of 4A8B 1234 5678 is 024E25D6C3EF9CBE4E0A');
    ok(C.bchCheck(info, par), 'and checks');
    eq(C.bchParity(new Array(50).fill(0)), new Array(77).fill(0), 'the idle pattern has zero parity');
    let single = 0;
    for (let i = 0; i < 127; i++) {
        const cw = info.concat(par);
        cw[i] ^= 1;
        if (!C.bchCheck(cw.slice(0, 50), cw.slice(50))) single++;
    }
    eq(single, 127, 'every single bit error is caught');
    let triple = 0;
    const rnd = lcg(7);
    for (let t = 0; t < 200; t++) {
        const cw = info.concat(par);
        for (let k = 0; k < 13; k++) cw[(t * 37 + k * 11 + (rnd() ? 1 : 0)) % 127] ^= 1;
        if (!C.bchCheck(cw.slice(0, 50), cw.slice(50))) triple++;
    }
    eq(triple, 200, 'so is every pattern of up to thirteen errors tried');

    const up = C.encodeUplinkWord([0x4a8b, 0x1234, 0x5678]);
    eq(up.length, 128, 'the uplink word is 128 bits');
    eq(up.slice(0, 3), [0, 0, 0], 'three dummy bits first');
    eq(C.bitsToWords(up.slice(3, 51)), [0x4a8b, 0x1234, 0x5678], 'then the command');
    eq(up.slice(51), par, 'then the parity');
    eq(C.decodeUplinkWord(up), {words: [0x4a8b, 0x1234, 0x5678], ok: true}, 'and it decodes');
    const bad = up.slice(); bad[100] ^= 1;
    eq(C.decodeUplinkWord(bad), {words: [0x0a8b, 0x1234, 0x5678], ok: false},
       'a parity error clears the vehicle address');
    const bad2 = up.slice(); bad2[10] ^= 1;
    eq(C.decodeUplinkWord(bad2).ok, false, 'so does a command bit error');

    section('frames');
    eq(C.frameFields(C.RATE.LDR).length, 1 + 5 + 4, 'LDR: station, five voice blocks, four command blocks');
    eq(C.frameFields(C.RATE.HDR).length, 1 + 10 + 4, 'HDR: station, ten voice blocks, four command blocks');
    eq(C.frameFields(C.RATE.LDR).filter((f) => f.kind === 'command').map((f) => f.at),
       [24 + 8 + 96, 24 + 8 + 96 * 2 + 32, 24 + 8 + 96 * 3 + 64, 24 + 8 + 96 * 4 + 96],
       'the LDR command blocks follow each voice block');
    eq(C.frameFields(C.RATE.HDR).filter((f) => f.kind === 'command').map((f) => f.at),
       [24 + 8 + 256, 24 + 8 + 512 + 32, 24 + 8 + 768 + 64, 24 + 8 + 1024 + 96],
       'the HDR command blocks follow each pair of voice blocks');
    for (const r of ['LDR', 'HDR']) {
        const f = C.buildFrame(C.RATE[r], up, {stationId: 0xa5});
        eq(f.length, C.RATE[r].frameBits, `an ${r} frame is ${C.RATE[r].frameBits} bits`);
        eq(C.bitsToWord(f, 0, 24), 0xfaf320, 'starting with the sync pattern');
        eq(C.bitsToWord(f, 24, 8), 0xa5, 'then the station ID');
        eq(C.frameUplinkBits(C.RATE[r], f), up, 'and the uplink word comes back out');
    }
    eq(C.syncDistance(0xfaf320), 0, 'the sync pattern correlates with itself');
    eq(C.syncDistance(~0xfaf320), 24, 'and its complement is the negative correlation');
    const alt = C.syncDistance(0xaaaaaa);
    ok(alt > C.SYNC_CORRELATE && alt < C.SYNC_ANTI, `the alternating voice fill does not correlate (${alt})`);
    const packed = C.packStream(up);
    eq(packed[0], 128, 'a stream datagram starts with the bit count');
    eq(packed.length, 9, 'then the bits, sixteen a word');
    eq(C.unpackStream(Uint16Array.from(packed)), up, 'and unpacks');
    eq(C.unpackStream(Uint16Array.from(C.packStream(up.slice(0, 5)))), up.slice(0, 5), 'a run of five bits too');

    section('frame sync');
    const frames = [];
    const sync = new N.FrameSync(C.RATE.LDR, (bits) => frames.push(bits));
    const noise = lcg(3);
    const words1 = [0x4f17, 0xa801, 0x0001], words2 = [0x4f17, 0xa801, 0x0002];
    const f1 = C.buildFrame(C.RATE.LDR, C.encodeUplinkWord(words1));
    const f2 = C.buildFrame(C.RATE.LDR, C.encodeUplinkWord(words2));
    const idle = C.buildFrame(C.RATE.LDR, new Array(128).fill(0));
    let stream = [];
    for (let i = 0; i < 100; i++) stream.push(noise());
    stream = stream.concat(idle, f1, f2, idle);
    sync.feed(stream.slice(0, 100 + 640));
    eq(sync.state, 'ACQ', 'the first sync pattern starts acquisition');
    eq(frames.length, 0, 'with nothing delivered');
    sync.feed(stream.slice(100 + 640, 100 + 640 + 24));
    eq(sync.state, 'LOCK', 'the second gives lock');
    eq(frames.length, 1, 'and delivers the frame between them');
    eq(C.decodeUplinkWord(C.frameUplinkBits(C.RATE.LDR, frames[0])).words, [0, 0, 0], 'the idle frame');
    const rest = stream.slice(100 + 640 + 24);
    for (let at = 0; at < rest.length; at += 7) sync.feed(rest.slice(at, at + 7));
    eq(frames.length, 3, 'two more frames delivered from the pieces');
    eq(C.decodeUplinkWord(C.frameUplinkBits(C.RATE.LDR, frames[1])).words, words1, 'the first command');
    eq(C.decodeUplinkWord(C.frameUplinkBits(C.RATE.LDR, frames[2])).words, words2, 'and the second');
    ok(sync.bds, 'bracket data status is up');
    ok(!sync.invert, 'the data was not inverted');

    // The stream inverted: a negative correlation inverts the data.
    frames.length = 0;
    const inv = new N.FrameSync(C.RATE.LDR, (bits) => frames.push(bits));
    inv.feed(stream.map((b) => b ^ 1));
    eq(inv.invert, true, 'an inverted stream is inverted back');
    eq(frames.length, 3, 'and its frames come through');
    eq(C.decodeUplinkWord(C.frameUplinkBits(C.RATE.LDR, frames[1])).words, words1, 'as sent');

    // A corrupted sync pattern drops the frames on both sides of it, and
    // three in a row lose lock.
    frames.length = 0;
    const s2 = new N.FrameSync(C.RATE.LDR, (bits) => frames.push(bits));
    const run = [].concat(idle, idle, f1, f2, idle, idle, idle, idle, idle);
    for (let k = 0; k < 8; k++) run[2 * 640 + k] ^= 1;        // the sync in front of f1
    s2.feed(run);
    eq(s2.state, 'LOCK', 'one missed correlation keeps lock');
    eq(frames.map((f) => C.decodeUplinkWord(C.frameUplinkBits(C.RATE.LDR, f)).words[2]),
       [0, 2, 0, 0, 0, 0], 'the frames on either side of the miss are not delivered');
    eq(s2.misses, 0, 'the misses cleared with the next correlation');
    const run2 = [].concat(idle, idle, idle, idle, idle, idle, idle, idle);
    for (const at of [3 * 640, 4 * 640, 5 * 640]) for (let k = 0; k < 8; k++) run2[at + k] ^= 1;
    frames.length = 0;
    const s3 = new N.FrameSync(C.RATE.LDR, (bits) => frames.push(bits));
    s3.feed(run2.slice(0, 5 * 640 + 24));
    eq(s3.state, 'SEARCH', 'three missed correlations lose lock');
    eq(s3.losses, 1, 'counted as a loss');
    s3.feed(run2.slice(5 * 640 + 24));
    eq(s3.state, 'LOCK', 'and the next two syncs regain it');

    section('the unit');
    const nsp = new N.NSP({units: [1, 2], powered: [1]});
    const u1 = nsp.units[1], u2 = nsp.units[2];
    const settle = (msec = 120) => new Promise((r) => setTimeout(r, msec));
    await nsp.ready();
    eq(nsp.statusOf(u1) & 0xffff,
       C.STATUS.BIT_SYNC_LOSS | C.STATUS.BIT_SYNC_QUAL | C.STATUS.FRAME_SYNC_LOSS | C.STATUS.BRACKET_LOSS |
       C.STATUS.INTERNAL_MODE | C.STATUS.MODE_PARITY_EVEN,
       'with no stream the status shows bit, frame and bracket loss, internal mode, STDN parity');
    eq(nsp.messageOf(u1), new Array(31).fill(0), 'and the message is empty');

    const link = new U.Uplink({rate: 'LDR', frameMs: 5, chunkBits: 100});
    await link.ready;
    link.push(words1);
    link.push(words2, {errors: 1});
    await link.start(4 + 2 + 10);
    await settle(50);
    eq(u1.stats.datagrams > 0, true, 'the powered unit hears the stream');
    eq(u2.stats.datagrams, 0, 'the unpowered one does not');
    ok(u1.bitSync, 'bit sync is up');
    eq(u1.sync.state, 'LOCK', 'frame sync is locked');
    ok(u1.dataReady, 'data ready is set once ten frames filled a buffer');
    let st = nsp.statusOf(u1);
    ok((st & C.STATUS.DATA_READY) !== 0, 'and shows in the status word');
    ok((st & C.STATUS.BCH_VALID) !== 0, 'with BCH valid');
    ok((st & C.STATUS.BCH_INVALID) !== 0, 'and BCH invalid, one command of each');
    eq(st & (C.STATUS.BIT_SYNC_LOSS | C.STATUS.FRAME_SYNC_LOSS | C.STATUS.BRACKET_LOSS), 0, 'no losses');
    let msg = nsp.messageOf(u1);
    // The first frame delivered is the one between the first two syncs, so
    // the commands land in slots 3 and 4 of the first buffer.
    const slot = msg.findIndex((w) => w === 0x4f17) / 3;
    ok(slot >= 0, 'the good command is in the buffer');
    eq(msg.slice(slot * 3, slot * 3 + 3), words1, 'intact');
    eq(msg.slice(slot * 3 + 3, slot * 3 + 6), [0x0f17, 0xa801, 0x0002], 'the failed one has its vehicle address cleared');
    eq(msg[30], C.validityBit(slot), 'and only the good one is marked valid');

    const sent = [];
    nsp._send = (u, words) => sent.push(words);
    nsp._doRead(u1);
    eq(sent.length, 1, 'a poll is answered');
    eq(sent[0].length, 32, 'with 32 words');
    ok((sent[0][0] & C.STATUS.DATA_READY) !== 0, 'data ready in the status');
    eq(sent[0].slice(1), msg, 'and the message');
    nsp._doRead(u1);
    eq(sent[1].length, 32, 'a second poll of the same buffer is 32 words');
    eq(sent[1].slice(1), new Array(31).fill(0), 'of zeros after the status');
    eq(sent[1][0] & (C.STATUS.DATA_READY | C.STATUS.BCH_VALID | C.STATUS.BCH_INVALID), 0,
       'with data ready and the BCH bits cleared');
    ok(!u1.dataReady, 'data ready is down');

    u1.dataReady = true; u1.polled = false; u1.fillCount = 9;
    nsp._doRead(u1);
    eq(sent[2].slice(1), new Array(31).fill(0), 'a poll within a frame of the buffer switch gets zeros');
    ok(!u1.dataReady, 'and clears data ready');

    nsp.setUplinkSwitch('nsp-block');
    u1.dataReady = true; u1.polled = false; u1.fillCount = 0;
    nsp._doRead(u1);
    eq(sent[3].length, 1, 'at NSP BLOCK a poll is answered with one word');
    ok((sent[3][0] & C.STATUS.DATA_INHIBIT) !== 0, 'the status word with data inhibit');
    nsp.setUplinkSwitch('enable');

    await settle(300);
    ok(!u1.bitSync, 'bit sync is lost 200 ms after the last datagram');
    eq(u1.sync.state, 'SEARCH', 'and frame sync with it');
    st = nsp.statusOf(u1);
    ok((st & C.STATUS.BIT_SYNC_LOSS) !== 0 && (st & C.STATUS.FRAME_SYNC_LOSS) !== 0, 'both in the status');

    const nspH = new N.NSP({units: [1], powered: [1], rate: 'HDR', mode: 'TDRS', external: true});
    await nspH.ready();
    const linkH = new U.Uplink({rate: 'HDR', frameMs: 5});
    await linkH.ready;
    linkH.push(words1);
    await linkH.start(3 + 1 + 10);
    await settle(50);
    const uh = nspH.units[1];
    eq(uh.sync.state, 'LOCK', 'HDR locks');
    ok(uh.dataReady, 'and fills a buffer');
    ok(nspH.messageOf(uh).includes(0x4f17), 'with the command');
    eq(nspH.statusOf(uh) & (C.STATUS.INTERNAL_MODE | C.STATUS.MODE_PARITY_EVEN | C.STATUS.MODE_PARITY_ODD),
       C.STATUS.MODE_PARITY_ODD, 'external mode and TDRS parity');
    linkH.close();
    await nspH.stop();

    section('through the MDM');
    const heard = [];
    const meta = [];
    const gpc = new B.Bus('FC1', B.busConfig['FC1']);
    gpc.onReceive((_, id, m) => {
        heard.push(Array.from(m.data16));
        meta.push({sev: m.sev, delayUs: m.delayUs});
    }, null);
    const ioHeard = [];
    const ioName = D.ioBusName('FF1');
    const io = new B.Bus(ioName, B.busConfig[ioName]);
    io.onReceive((_, id, m) => { const d = D.decodeIO(m.data16); if (d) ioHeard.push(d); }, null);
    const io3Heard = [];
    const io3Name = D.ioBusName('FF3');
    const io3 = new B.Bus(io3Name, B.busConfig[io3Name]);
    io3.onReceive((_, id, m) => { const d = D.decodeIO(m.data16); if (d) io3Heard.push(d); }, null);

    await nsp.stop();
    const mdm = new X.MDM({id: 'FF1'});
    const mdm3 = new X.MDM({id: 'FF3'});
    const nsp2 = new N.NSP({units: [1, 2], powered: [1]});
    const sendCmd = (cmd) => gpc.sendMsg(B.BusMsg.Command(cmd));
    const read = async (cmd = C.CMD_READ) => {
        heard.length = 0; meta.length = 0;
        sendCmd(cmd);
        await settle();
        return heard.splice(0);
    };
    await settle(250);
    ok(ioHeard.some((d) => d.opName === 'CONNECT' && d.card === 11 && d.channel === 3),
       'NSP 1 says CONNECT on FF1 card 11 channel 3 when it starts');
    ok(ioHeard.some((d) => d.opName === 'SET' && d.card === 9 && d.channel === 1 && d.words[0] === 0x8000),
       'and sets its power discrete, card 9 channel 1 bit 1');
    ok(ioHeard.some((d) => d.opName === 'RESET' && d.card === 4 && d.channel === 0 && d.words[0] === 0x2000),
       'the uplink block discrete A is reset');
    ok(io3Heard.some((d) => d.opName === 'DISCONNECT' && d.card === 11 && d.channel === 3),
       'NSP 2 says DISCONNECT on FF3');
    ok(io3Heard.some((d) => d.opName === 'RESET' && d.card === 12 && d.channel === 1 && d.words[0] === 0x8000),
       'and its power discrete, card 12 channel 1, is reset');
    ok(io3Heard.some((d) => d.opName === 'RESET' && d.card === 4 && d.channel === 0 && d.words[0] === 0x2000),
       'the uplink block discrete B is reset');
    eq(mdm.cards[11].link[3], true, 'FF1 has the channel connected');
    eq(mdm3.cards[11].link[3], false, 'FF3 does not');
    eq(mdm.cards[9].words[1] & 0x8000, 0x8000, 'FF1 holds the power discrete high');
    eq(mdm3.cards[12].words[1] & 0x8000, 0, 'FF3 holds it low');

    ioHeard.length = 0;
    let reply = await read(C.CMD_POWER[1]);
    eq(reply, [[0x8000]], 'a GPC read of FF1 card 9 channel 1 sees the power discrete');
    reply = await read(C.CMD_BLOCK);
    eq(reply, [[0]], 'and of card 4 channel 0 the block discrete low');
    reply = await read();
    eq(reply.length, 1, 'a read of the message is answered by one transmission');
    eq(reply[0].length, 32, 'of 32 halfwords');
    eq(meta.splice(0), [{sev: null, delayUs: 1072}], 'valid, on the bus 32 x 33.5 us after the command');
    eq(ioHeard.filter((d) => d.card === 11).map((d) => [d.opName, d.channel, d.count || d.words.length]),
       [['POLL', 3, 32], ['VALUE', 3, 32]], 'the MDM polled card 11 channel 3 and the NSP answered');
    ok((reply[0][0] & C.STATUS.BIT_SYNC_LOSS) !== 0, 'the status shows the link down');
    eq(reply[0][0] & C.STATUS.DATA_READY, 0, 'and no data ready');
    eq(reply[0].slice(1), new Array(31).fill(0), 'the rest zeros');

    const link2 = new U.Uplink({rate: 'LDR', frameMs: 5});
    await link2.ready;
    link2.push([0x4f17, 0xa801, 0x0001]);
    await link2.start(4 + 1 + 10);
    await settle(50);
    reply = await read();
    ok((reply[0][0] & C.STATUS.DATA_READY) !== 0, 'after an uplink the read has data ready');
    const at = reply[0].indexOf(0x4f17);
    ok(at > 0, 'and the command');
    eq(reply[0].slice(at, at + 3), [0x4f17, 0xa801, 0x0001], 'intact');
    eq(reply[0][31], C.validityBit((at - 1) / 3), 'with its validity bit');
    reply = await read();
    eq(reply[0].slice(1), new Array(31).fill(0), 'the next read of the buffer is zeros');
    link2.close();

    nsp2.setUplinkSwitch('nsp-block');
    await settle(50);
    eq(mdm.cards[4].words[0] & 0x2000, 0, 'NSP BLOCK leaves the GPC block discrete low');
    reply = await read();
    eq(reply[0].length, 32, 'the MDM still returns 32 words');
    ok((reply[0][0] & C.STATUS.DATA_INHIBIT) !== 0, 'the first the status word with data inhibit');
    const sev = meta[0].sev;
    ok(sev && sev[0] === D.SEV.VALID && sev.slice(1).every((b) => b === D.SEV_E_SET),
       'and the other 31 with E set');
    nsp2.setUplinkSwitch('gpc-block');
    await settle(50);
    eq(mdm.cards[4].words[0] & 0x2000, 0x2000, 'GPC BLOCK sets block discrete A on FF1');
    eq(mdm3.cards[4].words[0] & 0x2000, 0x2000, 'and B on FF3');
    reply = await read();
    eq(meta[0].sev, null, 'and the message is whole again');
    nsp2.setUplinkSwitch('enable');

    ioHeard.length = 0; io3Heard.length = 0;
    nsp2.setPower(1, false);
    nsp2.setPower(2, true);
    await settle(50);
    ok(ioHeard.some((d) => d.opName === 'DISCONNECT' && d.card === 11), 'NSP 1 off says DISCONNECT');
    ok(ioHeard.some((d) => d.opName === 'RESET' && d.card === 9 && d.words[0] === 0x8000), 'and drops its power discrete');
    ok(io3Heard.some((d) => d.opName === 'CONNECT' && d.card === 11 && d.channel === 3), 'NSP 2 on says CONNECT on FF3');
    ok(io3Heard.some((d) => d.opName === 'SET' && d.card === 12 && d.channel === 1 && d.words[0] === 0x8000),
       'and raises its power discrete');
    eq(mdm.cards[11].link[3], false, 'FF1 has the channel unplugged');
    eq(mdm3.cards[11].link[3], true, 'FF3 connected');
    reply = await read();
    ok(meta[0].sev && meta[0].sev.every((b) => b === D.SEV_E_SET), 'a read of NSP 1 now comes back with E on every word');

    ioHeard.length = 0;
    {
        const q = D.encodeIO({op: D.IO_OP.REQUEST, type: 0, card: D.IO_ALL, channel: D.IO_ALL, words: []});
        const mm = new B.BusMsg(q.length);
        mm.data16.set(q);
        io3.sendMsg(mm);
    }
    await settle();
    ok(io3Heard.some((d) => d.opName === 'CONNECT' && d.card === 11 && d.channel === 3),
       'a REQUEST is answered with CONNECT by the powered unit');
    ok(io3Heard.some((d) => d.opName === 'SET' && d.card === 12 && d.channel === 1), 'and its power discrete');

    await nsp2.stop();
    await settle();
    gpc.close(); io.close(); io3.close();
    link.close();

    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
