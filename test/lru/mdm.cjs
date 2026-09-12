// mdm.cjs — the Multiplexer/Demultiplexer
//
// Usage:
//   cd ext/sim && node test/lru/mdm.cjs
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
        `mdm.test.${path.basename(rel).replace(/\W/g, '_')}.${process.pid}.cjs`);
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
    const C = await bundle('lru/mdm/mdmConf.coffee');
    const K = await bundle('lru/mdm/mdmConfig.coffee');
    const P = await bundle('lru/mdm/prom.coffee');
    const M = await bundle('lru/mdm/mdm.coffee');

    section('command word');
    let c = C.decodeCommand((10 << 19) | 0x24C26);
    eq({iua: c.iua, name: c.name, card: c.card, ch: c.channel, n: c.count},
       {iua: 10, name: 'INPUT', card: 3, ch: 1, n: 7},
       'MTU read: FF card 3 channel 1, 7 words');
    c = C.decodeCommand((10 << 19) | 0x20C23);
    eq([c.name, c.card, c.channel, c.count], ['OUTPUT', 3, 1, 4], 'MTU write: 4 words out');
    c = C.decodeCommand((12 << 19) | 0x25A40);
    eq([c.iua, c.card, c.channel, c.count], [12, 6, 18, 1], 'FA card 6 channel 18: OMS chamber pressure');
    c = C.decodeCommand((12 << 19) | 0x21E02);
    eq([c.name, c.card, c.channel & 0xf, !!(c.channel & C.DO_SET_BIT), c.count],
       ['OUTPUT', 7, 0, true, 3], 'DOH card 7 set discretes, 3 words');
    c = C.decodeCommand((12 << 19) | 0x21C02);
    eq(!!(c.channel & C.DO_SET_BIT), false, 'and the same with the high channel bit clear resets them');
    c = C.decodeCommand((10 << 19) | 0x31C20);
    eq([c.name, c.card, c.channel, c.count], ['RETURN_WORD', 7, 1, 1], 'the MDM return word command');
    eq(C.returnWord(c), 0x7080, 'is answered with card 7, channel 1, one word, two zeros');
    c = C.decodeCommand((12 << 19) | 0x0836E);
    eq([c.name, c.promAddr, c.nInstr], ['INDIRECT', 27, 15], 'FA PROM location 27 for 15 instructions');
    c = C.decodeCommand((10 << 19) | 0x082E8);
    eq([c.promAddr, c.nInstr], [23, 9], 'FF PROM location 23 for 9 instructions');
    c = C.decodeCommand((10 << 19) | 0x1C581);
    eq([c.name, c.card, c.channel, c.count], ['BITE_IOM', 1, 12, 2], 'IOM BITE on card 1 channels 12,13');
    eq(C.decodeCommand(C.encodeDirect(10, C.MODE.INPUT, 3, 1, 7)).raw, (10 << 19) | 0x24C26,
       'encodeDirect makes the MTU read word');
    eq(C.decodeCommand(C.encodeIndirect(12, 27, 15)).raw, (12 << 19) | 0x0836E,
       'encodeIndirect makes the FA PROM word');
    eq(C.modeName(0x3), 'SPARE3', 'mode 0011 is a spare');

    section('BITE status register');
    eq(C.bsrBit(1), 0x8000, 'bit 1 is the high bit');
    eq(C.bsrBit(11), 0x0020, 'bit 11 is 0x0020');
    eq(C.describeBSR(C.BSR.NO_SUCH_CHANNEL | C.BSR.IOM_TRANSFER), 'NO_SUCH_CHANNEL, IOM_TRANSFER',
       'bits decode by name');
    eq(C.describeBSR(0), 'clear', 'and a clear register says so');

    section('analog words');
    eq(C.voltsToWord(0), 0, '0 V is 0');
    eq(C.voltsToWord(5.11), 0x7fc0, '+5.11 V is the largest positive 10-bit value, left justified');
    eq(C.voltsToWord(-5.12), 0x8000, '-5.12 V is the most negative');
    eq(C.voltsToWord(9), 0x7fc0, 'and a voltage past full scale clamps');
    eq(C.voltsToWord(-0.01), 0xffc0, '-10 mV is all ones in the ten bits');
    ok(Math.abs(C.wordToVolts(C.voltsToWord(2.5)) - 2.5) < 1e-9, '2.5 V round trips');
    ok(Math.abs(C.wordToVolts(0xffc0) + 0.01) < 1e-9, '0xffc0 reads as -10 mV');

    section('PROM words');
    let p = C.decodePromWord(C.encodePromWord(C.PROM_MODE.INPUT, 13, 5, 4));
    eq([p.name, p.card, p.channel, p.count], ['INPUT', 13, 5, 4], 'a PROM word round trips');
    eq(C.promModuleField(1), 0x20, 'module address bit 0 sits in bit 11');
    eq(C.promModuleField(8), 0x10, 'and bit 3 in bit 12');
    eq(C.promModuleField(4), 0x80, 'bit 2 in bit 9');
    for (let card = 0; card < 16; card++) ok(C.promModuleOf(C.promModuleField(card)) === card, `card ${card} round trips`);
    let ones = 0;
    for (let x = C.encodePromWord(C.PROM_MODE.INPUT, 13, 5, 4); x; x >>>= 1) ones += x & 1;
    eq(ones % 2, 1, 'the word carries odd parity');
    eq(C.encodePromClass(0x2), 0x0040, 'class 0010 (a discrete input) has its bit 1 at bit 10');
    eq(C.encodePromClass(0x8), 0x0010, 'class 1000 (serial) has its high bit at bit 12');
    for (let k = 0; k < 16; k++) ok(C.promClassOf(C.encodePromClass(k)) === k, `class ${k} round trips`);
    eq(C.voltsToAodWord(5.1175), 0x7ff0, '+5.1175 V is the largest 12-bit analog output, left justified');
    eq(C.voltsToAodWord(-5.12), 0x8000, 'and -5.12 V the most negative');
    ok(Math.abs(C.aodWordToVolts(C.voltsToAodWord(1.2325)) - 1.2325) < 1e-9, 'an output voltage round trips');

    section('hardware side messages');
    let m = C.decodeIO(C.encodeIO({op: C.IO_OP.SET, type: C.IOM.DIH.code, card: 4, channel: 1, words: [0x8000, 1]}));
    eq([m.opName, m.type, m.card, m.channel, m.words], ['SET', 2, 4, 1, [0x8000, 1]], 'a SET round trips');
    m = C.decodeIO(C.encodeIO({op: C.IO_OP.REQUEST}));
    eq([m.opName, m.card, m.channel, m.words], ['REQUEST', 0xff, 0xff, []], 'a bare REQUEST names every card');
    const pm = C.decodeIO(C.encodeIO({op: C.IO_OP.POLL, type: 8, card: 3, channel: 1, count: 7}));
    eq([pm.opName, pm.card, pm.channel, pm.count, pm.words], ['POLL', 3, 1, 7, []], 'a POLL carries the word count and no payload');
    eq(C.fmtIO(pm), 'POLL SIO 3/1 x7', 'and formats with it');
    eq(C.decodeIO(new Uint16Array([9, 0, 0, 0])), null, 'an unknown operation is refused');
    eq(C.decodeIO(new Uint16Array([4, 0, 0, 3, 1])), null, 'a short payload is refused');
    eq(C.parseIOAddr('4/1'), {card: 4, channel: 1}, 'card/channel parses');
    eq(C.parseIOAddr('4'), {card: 4, channel: 0}, 'a bare card is channel 0');
    eq(C.parseIOAddr('*/*'), {card: 0xff, channel: 0xff}, '* is every');
    eq(C.parseIOAddr('x'), null, 'nonsense is refused');
    eq(C.fmtIO(m), 'REQUEST */*', 'and formats');

    section('catalog');
    const ids = Object.keys(K.MDM_CATALOG);
    eq(ids.length, 23, '23 units: 16 DPS and 7 OI');
    for (const id of ids) {
        const e = K.MDM_CATALOG[id];
        ok(e.id === id, `${id} names itself`);
        ok(Array.isArray(e.iom) && (e.iom.length === 16 || (e.iom.length === 8 && /^L[LR]/.test(id))),
           `${id} has 16 slots, or 8 for an SRB unit`);
        ok(e.iom.every((n) => C.iomType(n) !== null), `${id} has known card types`);
    }
    eq(K.MDM_CATALOG.FF1.iom[11], 'SIO', 'FF card 11 is the serial card the ADTA is read through');
    eq(K.MDM_CATALOG.FF1.iom[0], 'TAC', 'FF card 0 is the TACAN card');
    eq([K.MDM_CATALOG.FA1.iom[6], K.MDM_CATALOG.FA1.iom[14]], ['AIS', 'AIS'],
       'FA cards 6 and 14 are the single-ended analog cards');
    eq([K.MDM_CATALOG.FA1.iom[0], K.MDM_CATALOG.FA1.iom[4]], ['AOD', 'AOD'], 'FA cards 0 and 4 are analog outputs');
    eq(K.MDM_CATALOG.FA1.iom[7], 'DOH', 'FA card 7 is a high-level discrete output');
    eq([K.MDM_CATALOG.FF1.iua, K.MDM_CATALOG.FA1.iua, K.MDM_CATALOG.LL2.iua], [10, 12, 6], 'IUAs');
    eq([K.MDM_CATALOG.OF1.iua, K.MDM_CATALOG.OF2.iua, K.MDM_CATALOG.OA3.iua], [12, 15, 9], 'the OI units have theirs too');
    eq([K.MDM_CATALOG.OF1.iom[0], K.MDM_CATALOG.OF2.iom[0]], ['SIO', 'SIO'], 'OF1 and OF2 card 0 is the serial card the MTU outputs reach');
    eq([K.MDM_CATALOG.FF1.busPri, K.MDM_CATALOG.FF1.busSec], ['FC1', 'FC5'], 'FF1 ports');
    eq([K.MDM_CATALOG.FA1.busPri, K.MDM_CATALOG.FA1.busSec], ['FC5', 'FC1'].reverse(), 'FA1 shares them');

    section('fitted PROM');
    const words = (prom, loc, n) => {
        let t = 0;
        for (let a = loc; a < loc + n; a++) t += C.decodePromWord(prom[a]).count;
        return t;
    };
    const ff = P.buildProm(K.MDM_CATALOG.FF1).prom;
    eq(words(ff, 22, 6), 21, 'FF location 22 for 6 instructions is 21 words');
    eq(words(ff, 23, 9), 36, 'FF location 23 for 9 instructions is 36 words');
    const fa = P.buildProm(K.MDM_CATALOG.FA1).prom;
    eq(words(fa, 21, 6), 34, 'FA location 21 for 6 is 34 words');
    eq(words(fa, 27, 15), 54, 'FA location 27 for 15 is 54 words');
    const ll1 = P.buildProm(K.MDM_CATALOG.LL1).prom;
    eq([words(ll1, 20, 1), words(ll1, 28, 7), words(ll1, 35, 29)], [1, 7, 29], 'LL1 programs');
    eq(words(P.buildProm(K.MDM_CATALOG.LL2).prom, 100, 31), 31, 'LL2 program');
    const lr1 = P.buildProm(K.MDM_CATALOG.LR1).prom;
    eq([words(lr1, 160, 1), words(lr1, 168, 13), words(lr1, 181, 29)], [1, 13, 29], 'LR1 programs');
    eq(words(P.buildProm(K.MDM_CATALOG.LR2).prom, 245, 31), 31, 'LR2 program');
    for (let a = 16; a < 512; a++) {
        if (!ff[a]) continue;
        const d = C.decodePromWord(ff[a]);
        const t = C.iomType(K.MDM_CATALOG.FF1.iom[d.card]);
        ok(t && t.dir !== 'out' && d.channel + d.count <= t.channels,
           `FF PROM ${a} reads an input card within its channels`);
    }
    eq(C.promClassOf(ff[8]), C.IOM.AOD.cls, 'class word 8 says FF card 8 is an analog output');
    eq(C.promClassOf(ff[0]), C.IOM.TAC.cls, 'class word 0 says card 0 is the TACAN card');
    eq(C.cardChannels(C.IOM.AID, K.MDM_CATALOG.LL1), 32, 'an SRB differential analog card has 32 channels');
    eq(C.cardChannels(C.IOM.AID, K.MDM_CATALOG.FF1), 16, 'an orbiter one 16');
    eq(C.cardChannels(C.IOM.DOH, K.MDM_CATALOG.FF1), 9, 'an EMDM discrete output card answers to nine channels');
    eq(C.cardChannels(C.IOM.DOH, K.MDM_CATALOG.FF1, false), 3, 'an MDM one to three');
    for (let a = 16; a < 512; a++) {
        if (!ll1[a]) continue;
        const d = C.decodePromWord(ll1[a]);
        const t = C.iomType(K.MDM_CATALOG.LL1.iom[d.card]);
        ok(t && t.dir !== 'out' && d.channel + d.count <= C.cardChannels(t, K.MDM_CATALOG.LL1),
           `LL1 PROM ${a} reads an input card within its channels`);
    }

    section('device on the bus');
    const B = await bundle('com/bus.civet');
    const heard = [];
    const runs = [];
    const meta = [];        // the header of each transmission: SEV flags, reply delay
    const fc1 = new B.Bus('FC1', B.busConfig['FC1']);
    fc1.onReceive((_, id, msg) => {
        runs.push(msg.data16.length);
        meta.push({sev: msg.sev, delayUs: msg.delayUs});
        for (let i = 0; i < msg.data16.length; i++) heard.push(msg.data16[i]);
    }, null);
    const fc5 = new B.Bus('FC5', B.busConfig['FC5']);
    const heard5 = [];
    fc5.onReceive((_, id, msg) => { for (let i = 0; i < msg.data16.length; i++) heard5.push(msg.data16[i]); }, null);
    const ioHeard = [];
    const ioName = C.ioBusName('FF1');
    const io = new B.Bus(ioName, B.busConfig[ioName]);
    io.onReceive((_, id, msg) => { const d = C.decodeIO(msg.data16); if (d) ioHeard.push(d); }, null);

    const mdm = new M.MDM({id: 'FF1'});
    const IUA = 10;
    const send = (bus, c24) => bus.sendMsg(B.BusMsg.Command(c24));
    const data = (bus, w) => { const m1 = new B.BusMsg(1); m1.data16[0] = w & 0xffff; bus.sendMsg(m1); };
    const ioSend = (op, type, card, channel, ws) => {
        const d = C.encodeIO({op, type, card, channel, words: ws});
        const mm = new B.BusMsg(d.length);
        mm.data16.set(d);
        io.sendMsg(mm);
    };
    const settle = (msec = 120) => new Promise((r) => setTimeout(r, msec));
    const direct = (mode, card, ch, n) => C.encodeDirect(IUA, mode, card, ch, n);
    const readBSR = async (bus = fc1, h = heard) => {
        h.length = 0;
        send(bus, direct(C.MODE.BSR, 0, 0, 1));
        await settle();
        return h.splice(0)[0];
    };

    await settle(200);
    eq(ioHeard.map((d) => [d.opName, d.card, d.channel]), [['REQUEST', C.IO_ALL, C.IO_ALL]],
       'the unit asks who is on its channels when it starts');
    heard.length = 0; heard5.length = 0; ioHeard.length = 0;

    send(fc1, (IUA << 19) | 0x31C20);
    await settle();
    eq(heard.splice(0), [0x7080], 'the return word command is answered with the return word');
    ok(mdm.firstResponse === false, 'and it was the first response, with S cleared');

    let bsr = await readBSR();
    eq(bsr, C.BSR.POWER_INTERRUPT, 'the first BSR read after power-up shows the power interrupt');
    eq(await readBSR(), 0, 'and reading it cleared it');

    send(fc5, (IUA << 19) | 0x31C20);
    await settle();
    eq(heard5.splice(0), [0x7080], 'the secondary port answers on its own bus');
    eq(heard.length, 0, 'and not on the primary');

    send(fc1, ((12 << 19) | 0x31C20) >>> 0);
    await settle();
    eq(heard.length, 0, 'a command for the FA MDM on the same bus is ignored');

    ioSend(C.IO_OP.SET, C.IOM.DIH.code, 4, 0, [0x8001, 0x0002]);
    ioSend(C.IO_OP.RESET, C.IOM.DIH.code, 4, 0, [0x0001]);
    await settle();
    heard.length = 0;
    send(fc1, direct(C.MODE.INPUT, 4, 0, 3));
    await settle();
    eq(heard.splice(0), [0x8000, 0x0002, 0], 'a read of card 4 returns the discretes SET and RESET on the hardware side');
    ioSend(C.IO_OP.VALUE, C.IOM.DIH.code, 4, 2, [0x1234]);
    await settle();
    send(fc1, direct(C.MODE.INPUT, 4, 2, 1));
    await settle();
    eq(heard.splice(0), [0x1234], 'VALUE sets a channel outright');

    ioSend(C.IO_OP.SET, C.IOM.DIL.code, 4, 0, [0xffff]);
    await settle();
    send(fc1, direct(C.MODE.INPUT, 4, 0, 1));
    await settle();
    eq(heard.splice(0), [0x8000], 'a message tagged with the wrong card type is ignored');

    ioSend(C.IO_OP.VALUE, C.IOM.AID.code, 1, 3, [C.voltsToWord(2.5), C.voltsToWord(-1)]);
    await settle();
    send(fc1, direct(C.MODE.INPUT, 1, 3, 2));
    await settle();
    eq(heard.splice(0).map(C.wordToVolts), [2.5, -1], 'analog channels read back in volts');

    // the single-ended card wraps, the differential one does not
    ioSend(C.IO_OP.VALUE, C.IOM.AIS.code, 7, 31, [0x1000]);
    ioSend(C.IO_OP.VALUE, C.IOM.AIS.code, 7, 0, [0x2000]);
    await settle();
    send(fc1, direct(C.MODE.INPUT, 7, 31, 2));
    await settle();
    eq(heard.splice(0), [0x1000, 0x2000], 'a 32-channel read from channel 31 wraps to channel 0');
    eq(await readBSR(), 0, 'without a fault');
    send(fc1, direct(C.MODE.INPUT, 1, 15, 2));
    await settle();
    eq(heard.splice(0), [0, 0], 'channel 16 of a 16-channel card reads as zero');
    eq(await readBSR(), C.BSR.NO_SUCH_CHANNEL | C.BSR.IOM_TRANSFER, 'with BSR bits 3 and 4');

    send(fc1, direct(C.MODE.INPUT, 2, 0, 1));
    await settle();
    eq(heard.length, 0, 'a read of a discrete output card is not answered');
    eq(await readBSR(), C.BSR.ILLEGAL_MODE, 'and sets illegal mode');
    send(fc1, C.encodeDirect(IUA, 0x3, 0, 0, 1));
    await settle();
    eq(await readBSR(), C.BSR.ILLEGAL_MODE, 'as does a spare mode');

    ioHeard.length = 0;
    send(fc1, direct(C.MODE.OUTPUT, 2, C.DO_SET_BIT | 1, 2));
    data(fc1, 0x00f0);
    data(fc1, 0x8000);
    await settle();
    eq(Array.from(mdm.cards[2].words.slice(0, 3)), [0, 0x00f0, 0x8000], 'set masks OR into channels 1 and 2');
    eq(ioHeard.map((d) => [d.opName, d.card, d.channel, d.words]), [['SET', 2, 1, [0x00f0, 0x8000]]],
       'and the hardware side hears the SET as commanded');
    ioHeard.length = 0;
    send(fc1, direct(C.MODE.OUTPUT, 2, 1, 1));
    data(fc1, 0x0030);
    await settle();
    eq(Array.from(mdm.cards[2].words.slice(0, 3)), [0, 0x00c0, 0x8000], 'a reset mask clears its bits');
    eq(ioHeard.map((d) => [d.opName, d.channel, d.words]), [['RESET', 1, [0x0030]]], 'and is mirrored as RESET');
    eq(await readBSR(), 0, 'with no fault');

    ioHeard.length = 0;
    ioSend(C.IO_OP.REQUEST, 0, 2, C.IO_ALL, []);
    await settle();
    eq(ioHeard.map((d) => [d.opName, d.type, d.card, d.channel, d.words]),
       [['VALUE', C.IOM.DOH.code, 2, 0, [0, 0x00c0, 0x8000]]], 'REQUEST of a card answers with every channel');
    ioHeard.length = 0;
    ioSend(C.IO_OP.REQUEST, 0, 4, 2, []);
    await settle();
    eq(ioHeard.map((d) => [d.card, d.channel, d.words]), [[4, 2, [0x1234]]], 'and of one channel with that channel');

    send(fc1, direct(C.MODE.OUTPUT, 2, C.DO_SET_BIT, 1));
    data(fc1, 1);
    data(fc1, 2);
    await settle();
    eq(await readBSR(), C.BSR.TOO_MANY_WORDS, 'an extra data word is too many words');
    send(fc1, direct(C.MODE.OUTPUT, 2, C.DO_SET_BIT, 2));
    data(fc1, 1);
    send(fc1, direct(C.MODE.INPUT, 4, 0, 1));
    await settle();
    heard.length = 0;
    eq(await readBSR(), C.BSR.NOT_COMPLETED, 'a command before the words all arrived is last command not completed');

    ioHeard.length = 0;
    send(fc1, direct(C.MODE.OUTPUT, 8, 7, 1));
    data(fc1, C.voltsToWord(1.23));
    await settle();
    eq(ioHeard.map((d) => [d.opName, d.card, d.channel, d.words.map(C.wordToVolts)]),
       [['VALUE', 8, 7, [1.23]]], 'an analog output is mirrored as VALUE');

    // serial: two words out to the IMU channel.  A read of a channel with
    // no device connected polls nobody: the last words come back at once
    // with E set on each, due on the bus 33.5 us a word after the command.
    ioHeard.length = 0;
    send(fc1, direct(C.MODE.OUTPUT, 3, 0, 2));
    data(fc1, 0xaaaa);
    data(fc1, 0x5555);
    await settle();
    eq(ioHeard.map((d) => [d.opName, d.type, d.card, d.channel, d.words]),
       [['VALUE', C.IOM.SIO.code, 3, 0, [0xaaaa, 0x5555]]], 'serial output goes out as the words of the channel');
    ioSend(C.IO_OP.VALUE, C.IOM.SIO.code, 3, 0, [0x1111, 0x2222, 0x3333]);
    await settle();
    ioHeard.length = 0; meta.length = 0;
    send(fc1, direct(C.MODE.INPUT, 3, 0, 3));
    await settle();
    eq(ioHeard.length, 0, 'a read of a serial channel with nothing connected polls nobody');
    eq(heard.splice(0), [0x1111, 0x2222, 0x3333], 'and returns what the channel last received');
    eq(meta.splice(0), [{sev: [7, 7, 7], delayUs: 101}],
       'with E set on every word, on the bus 3 x 33.5 us after the command');
    send(fc1, direct(C.MODE.INPUT, 3, 0, 4));
    await settle();
    eq(heard.splice(0), [0x1111, 0x2222, 0x3333, 0], 'a longer read pads with zeros');
    eq(meta.splice(0)[0].delayUs, 134, 'and is a word later');
    eq(mdm.stats.serialErrors, 7, 'seven flagged words so far');

    // A device on the channel says CONNECT, is polled, and its answer is
    // what the GPC reads.
    let polls = 0;
    const device = new B.Bus(ioName, B.busConfig[ioName]);
    device.onReceive((_, id, msg) => {
        const d = C.decodeIO(msg.data16);
        if (!d || d.op !== C.IO_OP.POLL || d.card !== 3 || d.channel !== 0) return;
        polls++;
        const a = C.encodeIO({op: C.IO_OP.VALUE, type: C.IOM.SIO.code, card: 3, channel: 0,
                              words: [0xabcd, polls]});
        const mm = new B.BusMsg(a.length);
        mm.data16.set(a);
        device.sendMsg(mm);
    }, null);
    await settle(200);
    ioSend(C.IO_OP.CONNECT, C.IOM.SIO.code, 3, 0, []);
    await settle();
    eq(mdm.cards[3].link[0], true, 'CONNECT marks the channel');
    ioHeard.length = 0; meta.length = 0;
    send(fc1, direct(C.MODE.INPUT, 3, 0, 2));
    await settle();
    eq(ioHeard.filter((d) => d.opName === 'POLL').map((d) => [d.type, d.card, d.channel, d.count]),
       [[C.IOM.SIO.code, 3, 0, 2]], 'a read of a connected channel polls it for two words');
    eq(heard.splice(0), [0xabcd, 1], 'a device answering the poll is what the GPC reads');
    eq(meta.splice(0), [{sev: null, delayUs: 67}],
       'valid, on the bus 2 x 33.5 us after the command');
    send(fc1, direct(C.MODE.INPUT, 3, 0, 2));
    await settle();
    eq(heard.splice(0), [0xabcd, 2], 'freshly, each time');
    eq(mdm.cards[3].poll, null, 'and no poll is left open');

    // Connected and silent: the poll goes unanswered and the last words
    // come back with E set.
    device.close();
    await settle();
    meta.length = 0;
    send(fc1, direct(C.MODE.INPUT, 3, 0, 2));
    await settle();
    eq(heard.splice(0), [0xabcd, 2], 'a connected device that does not answer leaves the last words');
    eq(meta.splice(0).map((m) => m.sev), [[7, 7]], 'flagged');
    ioSend(C.IO_OP.DISCONNECT, C.IOM.SIO.code, 3, 0, []);
    await settle();
    eq(mdm.cards[3].link[0], false, 'DISCONNECT clears the channel');
    ok(mdm.report().cards.every((c) => !/connected/.test(c)), 'and the report shows nothing connected');

    send(fc1, C.encodeIndirect(IUA, 23, 9));
    await settle(200);
    eq(heard.splice(0).length, 36, 'PROM location 23 for 9 instructions returns 36 words');
    eq(runs.slice(-1)[0], 36, 'in one datagram');
    send(fc1, C.encodeIndirect(IUA, 22, 6));
    await settle(200);
    eq(heard.splice(0).length, 21, 'and location 22 for 6 returns 21');
    eq(await readBSR(), 0, 'without a fault');

    send(fc1, (IUA << 19) | 0x082E8);
    await settle(200);
    ok(heard.splice(0).length === 36, 'the flight software\'s own command word does the same');

    send(fc1, C.encodeDirect(IUA, C.MODE.PROM_WORD, 0, 0, 0) | (23 << 5));
    await settle();
    eq(heard.splice(0), [mdm.prom[23]], 'the PROM word at 23 reads back');

    runs.length = 0;
    ioSend(C.IO_OP.VALUE, C.IOM.AID.code, 1, 12, [C.voltsToWord(1.0)]);
    await settle();
    send(fc1, direct(C.MODE.BITE_IOM, 1, 12, 1));
    await settle();
    const bite = heard.splice(0);
    eq(bite.length, 2, 'IOM BITE of one analog channel is two words');
    eq(runs, [2], 'sent as one datagram');
    ok(Math.abs(C.wordToVolts(bite[0]) - (0.5 + C.BITE_REF_VOLTS)) < 0.011, 'the first is half the input plus the reference');
    ok(Math.abs(C.wordToVolts(bite[1]) - 1.0) < 1e-9, 'the second is the input');
    eq(await readBSR(), C.BSR.BITE_COMPLETE, 'and BITE completion is flagged');
    send(fc1, (IUA << 19) | 0x1C581);
    await settle();
    eq(heard.splice(0).length, 4, 'the flight software\'s BITE 4 test reads four words');
    send(fc1, direct(C.MODE.BITE_IOM, 3, 1, 1));
    await settle();
    eq(heard.splice(0), C.SIO_BITE_WORDS, 'a serial channel answers its BITE with AAAA and 5555');
    heard.length = 0;

    await readBSR();
    ioHeard.length = 0;
    send(fc1, direct(C.MODE.OUTPUT, 2, C.DO_SET_BIT | 2, 3));
    data(fc1, 0x0001);
    data(fc1, 0x0002);
    data(fc1, 0x0004);
    await settle();
    eq(await readBSR(), 0, 'channels 3 and 4 of a discrete output card exist on an EMDM');
    eq(ioHeard.map((d) => [d.opName, d.channel, d.words]), [['SET', 2, [0x0001]]],
       'and only the wired channel reaches the hardware side');
    eq(Array.from(mdm.cards[2].words.slice(3, 5)), [2, 4], 'though the transparent ones hold what was written');
    send(fc1, direct(C.MODE.BITE_IOM, 2, 3, 1));
    await settle();
    eq(heard.splice(0), [2, 2], 'and read back under BITE');
    heard.length = 0;

    send(fc1, direct(C.MODE.LOAD_BSR, 0, 0, 1));
    data(fc1, 0x0140);
    await settle();
    eq(await readBSR(), 0x0140, 'LOAD_BSR takes the word that follows');
    ioHeard.length = 0;
    send(fc1, direct(C.MODE.MASTER_RESET, 0, 0, 1));
    await settle();
    eq(Array.from(mdm.cards[2].words.slice(0, 3)), [0, 0, 0], 'master reset zeroes the discrete outputs');
    eq(mdm.cards[8].words[7], 0, 'and the analog outputs');
    ok(ioHeard.some((d) => d.card === 2 && d.opName === 'VALUE' && d.words.every((w) => w === 0)),
       'and the hardware side hears the zeros');
    eq(await readBSR(), 0, 'and clears the register');

    // a command word to the unit in the middle of another unit's transfer
    // is not mistaken for data: a 1-word datagram with nothing pending
    heard.length = 0;
    data(fc1, 0x1234);
    await settle();
    eq(await readBSR(), 0, 'a stray data word with no transfer and no output just completed is ignored');

    // an original MDM, on the secondary bus so the two do not both answer
    const old = new M.MDM({id: 'FF2', emdm: false, busPri: 'FC5', busSec: null});
    await settle(200);
    heard5.length = 0;
    send(fc5, direct(C.MODE.OUTPUT, 2, C.DO_SET_BIT | 2, 2));
    data(fc5, 1);
    data(fc5, 2);
    await settle();
    eq(await readBSR(fc5, heard5), C.BSR.POWER_INTERRUPT | C.BSR.NO_SUCH_CHANNEL | C.BSR.IOM_TRANSFER,
       'channel 3 of a discrete output card does not exist on an MDM');
    eq(old.report().unit, 'MDM', 'and it reports as one');

    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
