// adc.cjs — the MEDS ADC on its IDP busses
//
// Usage:
//   cd ext/sim && node test/lru/adc.cjs
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
        `adc.test.${path.basename(rel).replace(/\W/g, '_')}.${process.pid}.cjs`);
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
    const C = await bundle('lru/adc/adcConf.coffee');
    const F = await bundle('lru/adc/adcChannels.coffee');
    const B = await bundle('com/bus.civet');
    const A = await bundle('lru/adc/adc.coffee');
    const I = await bundle('meds/idp/idpAdc.coffee');

    section('converter');
    eq(C.CHANNELS, 32, '32 input channels');
    eq(C.LSB_VOLTS, 0.0025, '2.5 mV per LSB (dwg 8.3 sheet 3 note 2)');
    eq(C.SAMPLE_HZ, 25, '25 Hz sampling (USA-005350 sect.2.5.4.1)');
    eq([C.COUNT_MIN, C.COUNT_MAX], [-2048, 2047], '12-bit two\'s complement counts');
    eq(C.voltsToWord(0), 0x000, '0 V is count 0');
    eq(C.voltsToWord(2.5), 0x3e8, '2.5 V is count 1000');
    eq(C.voltsToWord(-2.0), 0xce0, '-2 V is count -800, 0xce0 in 12 bits');
    eq(C.voltsToWord(5.6), 0x7ff, '+5.6 V clips at +2047');
    eq(C.voltsToWord(-5.6), 0x800, '-5.6 V clips at -2048');
    near(C.wordToVolts(C.voltsToWord(3.3)), 3.3, C.LSB_VOLTS / 2, '3.3 V round trips within half an LSB');
    near(C.wordToVolts(0xce0), -2.0, 1e-9, '0xce0 reads back as -2 V');
    eq(C.REFERENCE_VOLTS, [-5.6, -2.0, 0.0, 2.0, 5.6], 'the five reference voltages');

    // bias pattern, note 1
    const plus = [], minus = [];
    for (let i = 0; i < 32; i++) (C.biasVoltsOf(i) > 0 ? plus : minus).push(i);
    eq(plus, [0, 3, 5, 6, 9, 10, 12, 15, 17, 18, 20, 23, 24, 27, 29, 30], '+2 V bias channels');
    eq(minus, [1, 2, 4, 7, 8, 11, 13, 14, 16, 19, 21, 22, 25, 26, 28, 31], '-2 V bias channels');

    section('wiring');
    eq(C.UNITS, ['1A', '1B', '2A', '2B'], 'four units');
    eq(C.unitsOfIdp(1), ['1A', '2A'], 'IDP 1 commands the A units');
    eq(C.unitsOfIdp(2), ['1A', '2A'], 'IDP 2 commands the A units');
    eq(C.unitsOfIdp(3), ['1B', '2B'], 'IDP 3 commands the B units');
    eq(C.unitsOfIdp(4), ['1B', '2B'], 'IDP 4 commands the B units');
    eq(C.idpBussesOf('1A'), ['_IDP1', '_IDP2'], 'ADC 1A sits on the IDP 1 and IDP 2 busses');
    eq(C.idpBussesOf('2B'), ['_IDP3', '_IDP4'], 'ADC 2B sits on the IDP 3 and IDP 4 busses');
    eq([C.rtAddressOf('1A'), C.rtAddressOf('1B'), C.rtAddressOf('2A'), C.rtAddressOf('2B')],
       [0x18, 0x12, 0x14, 0x11], 'RT addresses from MEDSConf');
    eq([C.analogBusOf('1A'), C.analogBusOf('1B'), C.analogBusOf('2A'), C.analogBusOf('2B')],
       ['_ADC1_analogs', '_ADC1_analogs', '_ADC2_analogs', '_ADC2_analogs'],
       'both units of a pair sample the same analog bus');
    ok(B.busConfig['_ADC1_analogs'] && B.busConfig['_ADC2_analogs'], 'the analog busses are in the bus table');

    section('1553B words');
    const cw = C.commandWord({rt: 0x18, tr: 1, sa: 1, wc: 0});
    eq(cw, 0xc420, 'RT 24 transmit sa 1 wc 32 is c420');
    eq(C.decodeCommand(cw), {rt: 24, tr: 1, sa: 1, wc: 32}, 'and decodes, wc 0 meaning 32');
    eq(C.commandWord({rt: 0x11, tr: 0, sa: 3, wc: 1}), 0x8861, 'RT 17 receive sa 3 wc 1 is 8861');
    const sw = C.statusWord(0x14, C.STATUS.BUSY | C.STATUS.SUBSYSTEM_FLAG);
    eq(sw, 0xa00c, 'RT 20 busy with subsystem flag is a00c');
    eq(C.decodeStatus(sw).names.sort(), ['BUSY', 'SUBSYSTEM_FLAG'], 'the flags decode by name');
    const bcd = C.encodeBC({rt: 0x18, tr: 0, sa: 3, wc: 1}, [C.COMMAND.START_CST]);
    eq(bcd, [C.SYNC_COMMAND, 0xc061, 1], 'a BC datagram: command sync, command word, data');
    eq(C.decode1553(bcd), {kind: 'command', data: [1], rt: 24, tr: 0, sa: 3, wc: 1}, 'decodes as a command');
    const rt = C.encodeRT(0x18, 0, [1, 2, 3]);
    eq(rt[0], C.SYNC_STATUS, 'an RT datagram opens with the status sync');
    eq(C.decode1553(rt).kind, 'status', 'and decodes as a status');
    ok(C.decode1553([0xff00, 0x19ee, 0]) === null, 'an MDU message is not a 1553B datagram');
    ok(C.fmt1553(C.decode1553(bcd)).startsWith('CMD rt 24 receive sa 3 wc 1'), 'the command formats');

    section('analog bus');
    const am = C.encodeAnalog(C.ANALOG_OP.VALUE, 5, [2.5]);
    eq(am, [4, 5, 2500], 'VALUE channel 5 at 2.5 V');
    eq(C.decodeAnalog(am), {op: 4, channel: 5, volts: [2.5]}, 'decodes');
    eq(C.decodeAnalog(C.encodeAnalog(C.ANALOG_OP.VALUE, 0, [-1.25])).volts, [-1.25], 'negative volts round trip');
    eq(C.decodeAnalog(C.encodeAnalog(C.ANALOG_OP.REQUEST, C.ANALOG_ALL)), {op: 3, channel: 0xff, volts: []}, 'REQUEST all');

    section('channel table');
    for (const pair of [1, 2]) {
        const chans = F.channelsOfPair(pair);
        const nums = chans.map((c) => c.channel);
        eq(nums, nums.slice().sort((a, b) => a - b), `pair ${pair} channels are in order`);
        ok(new Set(nums).size === nums.length, `pair ${pair} channels are unique`);
        ok(nums.every((n) => n >= 0 && n < 32), `pair ${pair} channels are 0-31`);
        const fields = chans.map((c) => c.field).filter(Boolean);
        ok(new Set(fields).size === fields.length, `pair ${pair} fields are unique`);
    }
    eq(F.channelsOfPair(1).length, 29, 'pair 1 carries 29 signals (JSC-18819 SCP 4.9 item 8: channels 1-8, 10-30)');
    eq(F.channelsOfPair(2).length, 21, 'pair 2 carries 21 signals (channels 1-21)');
    ok(F.channelOf(1, 8) === null, 'the handbook leaves pair 1 channel 9 blank');
    eq([...new Set(F.channelsOfPair(1).filter((c) => c.field).map((c) => c.screen))].sort(), ['OMS_MPS', 'SPI'], 'pair 1 feeds OMS/MPS and SPI');
    eq([...new Set(F.channelsOfPair(2).filter((c) => c.field).map((c) => c.screen))], ['HYD_APU'], 'pair 2 feeds HYD/APU');
    eq(F.channelsOfPair(1).filter((c) => !c.field).map((c) => c.msid), ['V43T4111C'], 'one pair 1 signal is wired and not displayed');
    eq(F.channelsOfPair(2).filter((c) => !c.field).map((c) => c.msid), ['V46T0142A', 'V46T0242A', 'V46T0342A'], 'the three EGTs are wired and not displayed');
    // the handbook's table, spot checks (its channel numbers less one)
    const t = (pair, n) => { const c = F.channelOf(pair, n); return [c.msid, c.source, c.tap && `${c.tap.mdm} ${c.tap.card}/${c.tap.channel}`]; };
    eq(t(1, 0), ['V72H5130C', 'MDM FF2', 'FF2 8/8'], 'channel 1: body flap, the GPC through FF2');
    eq(t(1, 9), ['V72H5106C', 'MDM FF1', 'FF1 8/7'], 'channel 10: speedbrake command, the first word of the SPI block');
    eq(t(1, 2), ['V72H5110C', 'MDM FF1', 'FF1 8/10'], 'channel 3: left inboard elevon');
    eq(t(1, 10), ['V41P0040C', 'MDM FF1', 'FF1 8/0'], 'channel 11: center engine Pc, FF1 card 8 channel 0');
    eq(t(1, 12), ['V41P0042C', 'MDM FF3', 'FF3 8/0'], 'channel 13: right engine Pc through FF3');
    eq(t(1, 23), ['V43P4121C', 'DSC OL1', 'FA1 6/17'], 'channel 24: left OMS He tank pressure, sampled by FA1 too');
    eq(t(1, 24), ['V43P4547C', 'DSC OL2', null], 'channel 25: left OMS N2 tank pressure has no MDM tap');
    eq(t(2, 0), ['V72Q6001V', 'MDM PL2', 'PF2 12/0'], 'pair 2 channel 1: APU 1 fuel quantity from the SM through PF2');
    eq(t(2, 9), ['V58P0114C', 'DSC OA1', 'FF1 7/1'], 'pair 2 channel 10: hydraulic system 1 pressure, sensor A on FF1');
    eq(t(2, 20), ['V58Q0302A', 'DSC OA3', 'OA3 6/26'], 'pair 2 channel 21: hydraulic system 3 quantity on OA3');
    // every tap names an analog card in the catalog
    {
        const K = await bundle('lru/mdm/mdmConfig.coffee');
        const D = await bundle('lru/mdm/mdmConf.coffee');
        for (const pair of [1, 2]) for (const c of F.channelsOfPair(pair)) {
            if (!c.tap) continue;
            const cat = K.MDM_CATALOG[c.tap.mdm];
            const type = cat && D.IOM[cat.iom[c.tap.card]];
            ok(type && type.kind === 'analog' && c.tap.channel < type.channels,
               `${c.msid} tap ${c.tap.mdm} ${c.tap.card}/${c.tap.channel} is an analog channel (${type && type.name})`);
        }
        const taps1 = F.tapsOfPair(1);
        eq(Object.keys(taps1).sort(), ['FA1', 'FA2', 'FA3', 'FF1', 'FF2', 'FF3', 'OA1', 'OF1'], 'pair 1 taps eight MDMs');
        eq(taps1.FF1.length, 8, 'eight of them on FF1');
    }
    const pc = F.channelByField(1, 'mpsPc_C');
    eq(F.euToVolts(pc, 0), 0, '0 % is 0 V');
    eq(F.euToVolts(pc, 115), 5, 'full scale is 5 V');
    near(F.voltsToEu(pc, F.euToVolts(pc, 104)), 104, 1e-9, '104 % round trips');
    const el = F.channelByField(1, 'elevonDeg_LL');
    near(F.voltsToEu(el, 2.5), -7.5, 1e-9, 'mid scale on the elevon is -7.5 deg');
    eq(F.parseChannel(1, 'omsPcL'), 25, 'a field name parses to its channel');
    eq(F.parseChannel(1, 'v72h5106c'), 9, 'so does an MSID');
    eq(F.parseChannel(1, '17'), 17, 'a number parses');
    ok(F.parseChannel(1, 'nosuch') === null, 'an unknown name does not');
    {
        const volts = new Array(32).fill(0);
        volts[10] = F.euToVolts(pc, 104);
        const f = F.fieldsOfPair(1, volts, true);
        near(f.OMS_MPS.mpsPc_C, 104, 1e-9, 'a frame maps channel 11 (index 10) to mpsPc_C');
        eq(f.SPI.adcValid, true, 'the SPI carries the validity');
        const g = F.fieldsOfPair(1, volts, false);
        eq(g.OMS_MPS.mpsPc_C, -1, 'an invalid frame gives the gauges -1');
        ok(g.SPI.elevonDeg_LL === null && g.SPI.adcValid === false, 'and the SPI null with adcValid false');
    }

    section('through the bus');
    // ADC 1A alone, an IDP 1 bus controller on _IDP1, an MDU-like listener
    // that ignores the 1553B words, and a signal source on _ADC1_analogs.
    const idpBus = new B.Bus('_IDP1', B.busConfig['_IDP1']);
    const analogBus = new B.Bus('_ADC1_analogs', B.busConfig['_ADC1_analogs']);
    const analogHeard = [];
    analogBus.onReceive((_, id, msg) => { const m = C.decodeAnalog(msg.data16); if (m) analogHeard.push(m); }, null);
    const updates = [];
    const bc = new I.IDPAdcBC(1, {
        send: (words) => { const m = new B.BusMsg(words.length); words.forEach((w, i) => m.data16[i] = w); idpBus.sendMsg(m); },
        onUpdate: (u) => updates.push({id: u.id, valid: u.valid}),
    });
    const unhandled = [];
    idpBus.onReceive((_, id, msg) => { if (!bc.recv(msg.data16)) unhandled.push(Array.from(msg.data16)); }, null);

    const adc = new A.ADC({units: ['1A'], sampleMs: 20, cstMs: 200});
    await settle(250);
    ok(analogHeard.some((m) => m.op === C.ANALOG_OP.REQUEST && m.channel === 0xff),
       'the unit asks the signal sources for every channel when it starts');
    eq(Object.keys(bc.units), ['1A', '2A'], 'IDP 1\'s controller has units 1A and 2A');

    const sendAnalog = (channel, volts) => {
        const w = C.encodeAnalog(C.ANALOG_OP.VALUE, channel, volts);
        const m = new B.BusMsg(w.length); w.forEach((x, i) => m.data16[i] = x); analogBus.sendMsg(m);
    };

    bc.tick();
    await settle(100);
    let u = bc.units['1A'];
    eq([u.polls, u.replies], [1, 1], 'ADC 1A answered its first command');
    eq(u.valid, true, 'and the frame is valid');
    eq(u.data.length, 32, 'with 32 data words');
    ok(u.data.every((w) => w === 0), 'all zero with nothing on the inputs');
    eq(bc.units['2A'].replies, 0, 'ADC 2A is not running and did not answer');
    eq(unhandled.filter((w) => w[0] === C.SYNC_COMMAND).length, 0,
       'the controller\'s own commands are not echoed back to it');

    sendAnalog(10, [F.euToVolts(pc, 104)]);
    await settle(80);
    bc.tick();
    await settle(80);
    u = bc.units['1A'];
    near(C.wordToVolts(u.data[10]), F.euToVolts(pc, 104), C.LSB_VOLTS / 2, 'channel 11 carries the signal to within half an LSB');
    near(F.fieldsOfPair(1, u.data.map(C.wordToVolts), u.valid).OMS_MPS.mpsPc_C, 104, 0.1, 'which reads back as 104 % Pc');
    ok(u.data.filter((w, i) => i !== 10).every((w) => w === 0), 'the other channels stayed at 0');

    const all = Array.from({length: 32}, (_, i) => (i - 16) * 0.3);
    sendAnalog(C.ANALOG_ALL, all);
    await settle(80);
    bc.tick();
    await settle(80);
    u = bc.units['1A'];
    ok(u.data.every((w, i) => Math.abs(C.wordToVolts(w) - all[i]) <= C.LSB_VOLTS / 2 + 1e-9),
       'a VALUE for all 32 channels lands on all 32, negatives included');

    for (let i = 0; i < 22; i++) bc.tick();
    await settle(100);
    u = bc.units['1A'];
    eq(u.ticks, 25, 'twenty-five ticks');
    eq(u.replies, 25, 'twenty-five answers');
    eq(u.version, C.SOFTWARE_VERSION, 'the 25th read the status block: software version');
    eq(u.cstState, C.CST_STATE.NONE, 'no CST run yet');
    ok(u.samples > 0, 'the unit has sampled frames');
    eq(u.bite, 0, 'BITE summary clear');

    const readStatus = async () => {
        do { bc.tick(); } while (bc.units['1A'].ticks % 25 !== 0);
        await settle(100);
    };

    bc.startCst('1A');
    await settle(60);
    bc.tick();
    await settle(60);
    u = bc.units['1A'];
    ok(u.statusFlags & C.STATUS.BUSY, 'the status word says busy during the CST');
    eq(u.valid, false, 'and the frame is invalid');
    eq(u.data.map(C.wordToVolts).slice(0, 4), [2.0, -2.0, -2.0, 2.0],
       'the frame holds the BITE bias pattern');
    await settle(300);
    bc.tick();
    await settle(60);
    u = bc.units['1A'];
    eq(u.valid, true, 'valid again once the CST is done');
    await readStatus();
    u = bc.units['1A'];
    eq(u.cstState, C.CST_STATE.DONE, 'the status block says CST done');
    eq(u.cst, 0, 'and it passed');

    adc.setCstResult('1A', C.CST.REF_P5V6);
    bc.startCst('1A');
    await settle(350);
    await readStatus();
    u = bc.units['1A'];
    eq(u.cst, C.CST.REF_P5V6, 'the injected result comes back');
    eq(u.bite, C.BITE.REFERENCE, 'and the BITE summary shows the reference voltage');
    ok(u.statusFlags & C.STATUS.SUBSYSTEM_FLAG, 'the status word carries the subsystem flag');
    eq(C.fmtBite(u.bite), 'REFERENCE', 'named');

    bc.reset('1A');
    await settle(60);
    await readStatus();
    u = bc.units['1A'];
    eq([u.bite, u.cst, u.cstState], [0, 0, C.CST_STATE.NONE], 'reset clears BITE and the CST');

    updates.length = 0;
    adc.setAnswers('1A', false);
    bc.tick(); await settle(40);
    bc.tick(); await settle(40);
    eq(bc.units['1A'].valid, true, 'still valid after two misses');
    bc.tick(); await settle(40);
    eq(bc.units['1A'].valid, true, 'and after three sends (the third is still owed)');
    bc.tick(); await settle(40);
    eq(bc.units['1A'].valid, false, 'invalid once three went unanswered');
    ok(updates.some((x) => x.id === '1A' && x.valid === false), 'the controller reported the change');
    adc.setAnswers('1A', true);
    bc.tick(); await settle(60);
    eq(bc.units['1A'].valid, true, 'valid again on the first answer');

    // through an MDM: the GPC's writes and a device's signals reach the frame
    section('through MDM FF1');
    {
        const D = await bundle('lru/mdm/mdmConf.coffee');
        const X = await bundle('lru/mdm/mdm.coffee');
        const gpc = new B.Bus('FC1', B.busConfig['FC1']);
        gpc.onReceive((() => {}), null);
        const io = new B.Bus(D.ioBusName('FF1'), B.busConfig[D.ioBusName('FF1')]);
        io.onReceive((() => {}), null);
        const mdm = new X.MDM({id: 'FF1'});
        await settle(200);
        const word = (w) => { const m = new B.BusMsg(1); m.data16[0] = w & 0xffff; gpc.sendMsg(m); };
        const write = (card, ch, words) => {
            const cmd = D.encodeDirect(10, D.MODE.OUTPUT, card, ch, words.length);
            gpc.sendMsg(B.BusMsg.Command(cmd));
            for (const w of words) word(w);
        };
        // written before the unit starts: the unit asks the MDM and gets it
        write(8, 0, [D.voltsToAodWord(1.0)]);
        await settle(100);
        const adc2 = new A.ADC({units: ['1B', '2B'], sampleMs: 20});
        const idp3 = new B.Bus('_IDP3', B.busConfig['_IDP3']);
        const bc3 = new I.IDPAdcBC(3, {send: (words) => { const m = new B.BusMsg(words.length); words.forEach((w, i) => m.data16[i] = w); idp3.sendMsg(m); }});
        idp3.onReceive((_, id, msg) => { bc3.recv(msg.data16); }, null);
        await settle(300);
        ok(Object.keys(adc2.taps).includes(D.ioBusName('FF1')), 'the unit listens on FF1\'s hardware side bus');
        bc3.tick(); await settle(80);
        near(C.wordToVolts(bc3.units['1B'].data[10]), 1.0, 0.0125, 'a value the GPC wrote before the unit started reaches channel 11 (center Pc)');
        // the SPI block: nine words from channel 7
        const block = [0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5];
        write(8, 7, block.map(D.voltsToAodWord));
        await settle(120);
        bc3.tick(); await settle(80);
        let d = bc3.units['1B'].data.map(C.wordToVolts);
        near(d[9], 0.5, 0.0125, 'word 1 (speedbrake command) lands on channel 10');
        near(d[7], 1.0, 0.0125, 'word 2 (rudder) on channel 8');
        near(d[6], 1.5, 0.0125, 'word 3 (speedbrake position) on channel 7');
        near(d[2], 2.0, 0.0125, 'word 4 (left inboard elevon) on channel 3');
        near(d[3], 2.5, 0.0125, 'word 5 (left outboard) on channel 4');
        near(d[4], 3.0, 0.0125, 'word 6 (right inboard) on channel 5');
        near(d[5], 3.5, 0.0125, 'word 7 (right outboard) on channel 6');
        eq(d[8], 0, 'channel 9 stays blank');
        near(F.fieldsOfPair(1, d, true).SPI.speedbrakePc_CMD, 10, 0.3, 'which the SPI reads as 10 % commanded');
        // a device on FF1 card 7 channel 1: hydraulic system 1 pressure, sensor A
        const dev = D.encodeIO({op: D.IO_OP.VALUE, type: D.IOM.AIS.code, card: 7, channel: 1, words: [D.voltsToWord(3.0)]});
        const dm = new B.BusMsg(dev.length); dm.data16.set(dev); io.sendMsg(dm);
        await settle(120);
        bc3.tick(); await settle(80);
        d = bc3.units['2B'].data.map(C.wordToVolts);
        near(d[9], 3.0, 0.006, 'a device value on FF1 7/1 reaches pair 2 channel 10');
        near(F.fieldsOfPair(2, d, true).HYD_APU.hydPress_1, 2400, 5, 'which the HYD/APU display reads as 2400 psia');
        ok(adc2.tapHeard >= 3, 'the unit counted the taps it heard');
        await adc2.stop();
        await mdm.stop?.();
        gpc.close(); io.close(); idp3.close();
    }

    section('MDU message');
    u = bc.units['1A'];
    const mm = I.encodeMduAdc(0xff08, u);
    eq(mm.length, I.MDU_ADC_WORDS, '36 words');
    eq(mm.slice(0, 4), [0xff08, 1, 1, 0], 'tag, pair 1, valid, BITE');
    const dm = I.decodeMduAdc(mm);
    eq([dm.pair, dm.valid, dm.bite], [1, true, 0], 'decodes');
    eq(dm.data, u.data, 'with the frame');

    section('errors');
    {
        const heard = [];
        const probe = new B.Bus('_IDP2', B.busConfig['_IDP2']);
        probe.onReceive((_, id, msg) => { const m = C.decode1553(msg.data16); if (m?.kind === 'status') heard.push(m); }, null);
        await settle(150);
        const w = C.encodeBC({rt: 0x18, tr: 1, sa: 9, wc: 4});
        const m = new B.BusMsg(w.length); w.forEach((x, i) => m.data16[i] = x); probe.sendMsg(m);
        await settle(100);
        eq(heard.length, 1, 'ADC 1A answers on its second bus too');
        ok(heard[0].flags & C.STATUS.MESSAGE_ERROR, 'an unknown subaddress gets message error');
        eq(heard[0].data.length, 0, 'and no data');
        probe.close();
    }

    await adc.stop();
    idpBus.close();
    analogBus.close();

    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
