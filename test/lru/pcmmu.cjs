// pcmmu.cjs — the PCM Master Unit: the GPC interface, the toggle
// buffers, the fetch, the formatters and the streams
//
// Usage:
//   cd ext/sim && node test/lru/pcmmu.cjs
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

// A bus domain for this test (com/bus.civet): a base drawn from the
// process id, or NSTS_TEST_BASE_PORT.
process.env.NSTS_BASE_PORT =
    process.env.NSTS_TEST_BASE_PORT ?? String(20000 + (process.pid % 400) * 100);
console.log(`bus base port ${process.env.NSTS_BASE_PORT}`);

async function bundle(rel) {
    const out = path.join(os.tmpdir(),
        `pcmmu.test.${path.basename(rel).replace(/\W/g, '_')}.${process.pid}.cjs`);
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
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
    const C = await bundle('lru/pcmmu/pcmmuConf.coffee');
    const F = await bundle('lru/pcmmu/fetch.coffee');
    const M = await bundle('lru/pcmmu/tlmFormat.coffee');
    const B = await bundle('com/bus.civet');
    const P = await bundle('lru/pcmmu/pcmmu.coffee');
    const D = await bundle('lru/mdm/mdmConf.coffee');
    const X = await bundle('lru/mdm/mdm.coffee');

    section('partial TFL tape payloads');
    {
        const root = path.resolve(SIM, '../..');
        const python = fs.existsSync(path.join(root, 'build/venv/bin/python'))
            ? path.join(root, 'build/venv/bin/python') : 'python3';
        const memories = JSON.parse(require('child_process').execFileSync(python, ['-c',
            'import json; from tools.partial_tfl import format_memory; print(json.dumps({i:format_memory(i) for i in (103,161,163)}))'],
            {cwd: root, env: {...process.env, PYTHONPATH: path.join(root, 'src')}, encoding: 'utf8'}));
        for (const [id, windows] of [[103, [[1,56],[2,28]]], [161, [[1,112],[2,48]]],
                                      [163, [[1,112],[2,48],[4,32]]]]) {
            const rate = id === 103 ? 64 : 128;
            const word = (tb, n) => (tb << 12) | (n * 17);
            const u = {frame: 0, counters: {[rate]: Array(8).fill(0)},
                tb: Array.from({length: 5}, (_, i) => ({fmt: {len: 128,
                    words: Array.from({length:128}, (_, n) => word(i + 1, n)),
                    read: Array(128).fill(0), readCount: 0}}))};
            const reader = {_dataByte: P.PCMMU.prototype._dataByte, _trySwitch() {}};
            let matches = true;
            for (let frame = 0; frame < 200; frame++) {
                u.frame = frame % 100;
                const actual = P.PCMMU.prototype._format.call(reader, u, rate, memories[id]);
                const expected = [0xfa, 0xf3, 0x20, frame % 100];
                for (const [tb, words] of windows) {
                    const width = words / 2;
                    for (let byte = (frame % 4) * width; byte < ((frame % 4) + 1) * width; byte++) {
                        const w = word(tb, Math.floor(byte / 2));
                        expected.push(byte % 2 ? w & 255 : w >>> 8);
                    }
                }
                while (expected.length < (rate === 64 ? 80 : 160)) expected.push(255);
                matches &&= JSON.stringify(actual) === JSON.stringify(expected);
            }
            ok(matches, `TFL ${id}: two major frames, GPC byte order, sync, counters and FF fill`);
            if (id === 161) {
                for (let i = 0; i < 5; i++) {
                    const tb = u.tb[i];
                    tb.switches = 0;
                    tb.fmt.read.fill(0);
                    tb.fmt.readCount = 0;
                    const words = windows.find(([n]) => n === i + 1)?.[1];
                    tb.fmt.len = words || 128;
                    tb.gpc = {words: Array(128).fill(0xabcd), read: Array(128).fill(0),
                        readCount: 0, eom: words ? {len: words} : null};
                }
                reader._trySwitch = P.PCMMU.prototype._trySwitch;
                let last;
                for (u.frame = 0; u.frame < 4; u.frame++)
                    last = P.PCMMU.prototype._format.call(reader, u, rate, memories[id]);
                eq([last[59], last[83]], [word(1,111) & 255, word(2,47) & 255],
                    'final low bytes come from the consumed buffers');
                eq([u.tb[0].switches, u.tb[1].switches], [1,1], 'both ready GPC buffers switch');
                const next = P.PCMMU.prototype._format.call(reader, u, rate, memories[id]);
                eq(next.slice(4,6), [0xab,0xcd], 'next frame reads the new buffer');
            }
        }
    }

    section('command words');
    {
        const c = C.decodeCommand(0x6a401f);
        eq([c.address, c.name, c.io, c.buffer, c.tbAddr, c.count, c.valid], [3, 'WRITE_TB', 1, 1, 0, 32, true], 'write buffer 1 at 0');
        eq(C.decodeCommand(0x6a4c1f).tbAddr, 96, 'write at 96');
        const e = C.decodeCommand(0x7c43e0);
        eq([e.name, e.buffer, e.tbAddr], ['EOM', 1, 31], 'EOM buffer 1 last 31');
        eq(C.decodeCommand(0x7c4fe0).tbAddr, 127, 'EOM last 127');
        const b = C.decodeCommand(0x780000);
        eq([b.name, b.count], ['READ_BITE', 1], 'BITE read');
        const r = C.decodeCommand(0x6d3a60);
        eq([r.name, r.start, r.count], ['READ_RAM', 2515, 1], 'RAM read 2515');
        eq(C.CMD_WRITE_TB(1, 0, 32), 0x6a401f, 'encode write');
        eq(C.CMD_WRITE_TB(1, 96, 32), 0x6a4c1f, 'encode write at 96');
        eq(C.CMD_EOM(1, 31), 0x7c43e0, 'encode EOM 31');
        eq(C.CMD_EOM(1, 127), 0x7c4fe0, 'encode EOM 127');
        eq(C.CMD_READ_BITE, 0x780000, 'encode BITE read');
        eq(C.CMD_READ_RAM(2515, 1), 0x6d3a60, 'encode RAM read');
        eq(C.decodeCommand(C.CMD_FMT_SELECT(true)).prgm, 1, 'format select PRGM');
        eq(C.decodeCommand(C.CMD_FMT_SELECT(false)).prgm, 0, 'format select FIXED');
        eq(C.decodeCommand(C.CMD_LOAD_FMT(64, 512, 32)).name, 'LOAD_FMT64', 'load 64');
        eq(C.decodeCommand(C.CMD_READ_FMT(128, 0, 32)).name, 'READ_FMT128', 'read 128');
        ok(!C.decodeCommand(0x000000).valid, 'zero is invalid');
        ok(!C.decodeCommand(0x2a401f).valid, 'address 001 is not this unit');
        eq(C.fmtCommand(0x7c43e0), 'EOM buffer 1 last 31', 'fmtCommand EOM');
        // the IUA on the bus: address plus the two high op bits
        for (const [cmd, iua] of [[0x6a401f, 13], [0x780000, 15], [0x6d3a60, 13], [0x7c43e0, 15]])
            eq((cmd >>> 19) & 0x1f, iua, `IUA of ${cmd.toString(16)}`);
    }

    section('downlist frame');
    {
        const f = [0xeb90, 0xc014, 0x1400, 0x2eb8, 0x0a7c, 0xee6c, 0x03ff];
        const d = C.decodeFrame(f);
        eq([d.step, d.frame, d.format], [3, 0, 20], 'frame 0 header');
        eq(d.gmtUs, 0x2eb8 * 0x100000000 + 0x0a7c * 0x10000 + 0xee6c, 'GMT microseconds');
        const d25 = C.decodeFrame([0xeb90, 0x1914, 0x1400, 0x2eb8, 0x0a8c, 0x30ac]);
        eq(d25.frame, 25, 'frame 25');
        eq(d25.gmtUs - d.gmtUs, 1000000, 'one second between frames 0 and 25');
        eq(C.decodeFrame([0xeb90, 0x6114]).frame, 33, 'frame 33');
        eq(C.decodeFrame([0x0000, 0x0000]), null, 'no sync');
    }

    section('BSR and streams');
    {
        eq(C.bsrBit(1), 0x8000, 'bit 1');
        eq(C.bsrBit(16), 0x0001, 'bit 16');
        eq(C.BSR.PRGM, 1, 'PRGM is bit 16');
        ok(C.fmtBSR(0xfffe).startsWith('FIXED, all good'), 'all good');
        ok(C.fmtBSR(0xbffe).includes('MTU'), 'MTU bad');
        const bytes = [0xfa, 0xf3, 0x20, 0x07, 0xeb, 0x90];
        const w = C.packStream(bytes);
        eq(w[0], 48, 'bit count');
        eq(C.unpackStream(w), bytes, 'round trip');
        const m = C.decodeMinorFrame(bytes);
        eq([m.sync, m.count, m.words], [true, 7, [0xeb90]], 'minor frame decode');
        eq(C.decodeEntry(C.fmtEntry(4096, true)), { fill: false, high: true, addr: 4096, byte: 0 }, 'entry');
        eq(C.decodeEntry(C.fillEntry(0xfa)).fill, true, 'fill entry');
    }

    section('fetch program');
    {
        const fetch = F.buildFetch();
        ok(fetch.entries.length > 0 && fetch.words <= C.RAM_WORDS, `fits: ${fetch.entries.length} commands, ${fetch.words} words`);
        const mtu = F.fetchAddress(fetch, 'OF1', 0, 1);
        ok(mtu !== null, 'the MTU channel has a slot');
        const e = F.fetchEntryAt(fetch, mtu);
        eq([e.mdm, e.card, e.channel, e.count, e.rate], ['OF1', 0, 1, 7, 10], 'the MTU entry');
        ok(fetch.entries.every((x) => x.count >= 1 && x.count <= 32), 'counts 1-32');
        const two = F.buildFetch({ mdms: ['OF1', 'OF2'] });
        ok(two.entries.every((x) => x.mdm === 'OF1' || x.mdm === 'OF2'), 'a subset');
    }

    section('format library');
    {
        const fetch = F.buildFetch();
        for (const id of [129, 161, 102, 103]) {
            const mem = M.buildTlmFormat(id, fetch);
            eq(mem.length, 2048, `${id}: 2048 words`);
            const rate = M.FORMATS[id].rate;
            const slots = C.slotsOf(rate);
            // every slot has a rate; the group starts are in order and inside the memory
            let last = 168;
            for (let g = 0; g < 8; g++) { ok(mem[g] >= last && mem[g] < 2048, `${id}: group ${g} start`); last = mem[g]; }
            eq(Array.from(mem.slice(8, 8 + 4)), [7, 7, 7, 7], `${id}: the sync slots are 100 s/s`);
            const lay = M.formatLayout(id);
            eq(lay[0], { name: 'sync', slot: 0, slots: 4 }, `${id}: layout sync`);
            eq(lay[lay.length - 1].slot + lay[lay.length - 1].slots, slots, `${id}: layout fills the frame`);
        }
        eq(M.formatLayout(129)[1], { name: 'TB1', slot: 4, slots: 64, buffer: 1, words: 128 }, '129 TB1 window');
        eq(M.formatLayout(129)[2].words, 32, '129 TB5 words');
        eq(M.formatLayout(102)[1].words, 64, '102 TB1 words');
        eq(M.formatLayout(103)[2], { name: 'TB2', slot: 32, slots: 14, buffer: 2, words: 28 }, '103 TB2 window');
    }

    section('unit on the busses');
    let pc = null, mdm = null, gpc = null, hdr = null, ldr = null;
    try {
        pc = new P.PCMMU({ power: 1, mdms: ['OF1'], verbose: false });
        gpc = new B.Bus('IP4', B.busConfig.IP4);
        hdr = new B.Bus(C.HDR_BUS, B.busConfig[C.HDR_BUS]);
        ldr = new B.Bus(C.LDR_BUS, B.busConfig[C.LDR_BUS]);
        await Promise.all([pc.ready(), gpc.ready, hdr.ready, ldr.ready]);

        const inbox = [];
        gpc.onReceive((_, busID, msg) => inbox.push({ words: Array.from(msg.data16), sev: msg.sev }), null);
        const frames = { hdr: [], ldr: [] };
        hdr.onReceive((_, busID, msg) => frames.hdr.push(C.unpackStream(msg.data16)), null);
        ldr.onReceive((_, busID, msg) => frames.ldr.push(C.unpackStream(msg.data16)), null);

        const sendCmd = (cmd) => gpc.sendMsg(B.BusMsg.Command(cmd));
        const sendWord = (w) => { const m = new B.BusMsg(1); m.data16[0] = w & 0xffff; gpc.sendMsg(m); };
        const transact = async (cmd, count) => {
            inbox.length = 0;
            sendCmd(cmd);
            for (let i = 0; i < 40 && inbox.reduce((n, m) => n + m.words.length, 0) < count; i++) await sleep(5);
            const words = [], sev = [];
            for (const m of inbox) { words.push(...m.words); sev.push(...(m.sev ?? m.words.map(() => D.SEV.VALID))); }
            return { words, sev };
        };

        let r = await transact(C.CMD_READ_BITE, 1);
        eq(r.words.length, 1, 'BITE read answered');
        eq(r.sev[0] & D.SEV.S, 0, 'S cleared before the first BITE read');
        r = await transact(C.CMD_READ_BITE, 1);
        eq(r.sev[0], D.SEV.VALID, 'status normal after the BITE read');
        ok((r.words[0] & 0x8000) !== 0, 'power status good');
        eq(r.words[0] & C.BSR.PRGM, 0, 'FIXED selected at power-up');

        const frame = [];
        for (let i = 0; i < 128; i++) frame.push(i < 32 ? (i === 0 ? 0xeb90 : i === 1 ? 0xc014 : 0x1000 + i) : 0xaaaa);
        const writeFrame = () => {
            for (let b = 0; b < 4; b++) {
                sendCmd(C.CMD_WRITE_TB(1, b * 32, 32));
                for (let i = 0; i < 32; i++) sendWord(frame[b * 32 + i]);
            }
            sendCmd(C.CMD_EOM(1, 31));
        };
        writeFrame();
        await sleep(30);
        const u = pc.units[1];
        for (let i = 0; i < 40 && u.stats.fetchErrors === 0; i++) await sleep(5);
        eq(u.tb[0].writes, 4, 'four writes counted');
        eq(u.tb[0].eoms, 1, 'one EOM');
        eq(u.tb[0].switches, 1, 'the first EOM switched sides');
        eq(u.tb[0].fmt.len, 32, 'the data set is 32 words');
        r = await transact(C.CMD_READ_TB(1, 0, 4), 4);
        eq(r.words, [0xeb90, 0xc014, 0x1002, 0x1003], "the formatter's side reads back");
        eq(r.sev, [4, 4, 4, 4], 'valid words, V clear while the BSR reads bad');
        r = await transact(C.CMD_READ_TB(2, 0, 2), 2);
        eq(r.words, [0, 0], 'buffer 2 is empty');
        ok(r.sev.every((x) => (x & D.SEV.E) !== 0), 'E set on words never written');

        writeFrame();
        await sleep(60);
        ok(u.tb[0].switches >= 2, `switched again once read (${u.tb[0].switches})`);

        // the streams: minor frames with sync and count, the downlist in TB1's window
        await sleep(120);
        ok(frames.hdr.length >= 10, `128 kbps minor frames arrive (${frames.hdr.length})`);
        ok(frames.ldr.length >= 10, `64 kbps minor frames arrive (${frames.ldr.length})`);
        eq(frames.hdr[0].length, 160, '160 bytes a 128-kbps minor frame');
        eq(frames.ldr[0].length, 80, '80 bytes a 64-kbps minor frame');
        const f0 = C.decodeMinorFrame(frames.hdr[0]);
        ok(f0.sync, 'sync bytes');
        const counts = frames.hdr.map((f) => f[3]);
        ok(counts.every((c, i) => i === 0 || c === (counts[i - 1] + 1) % 100), 'frame count increments');
        const withSync = frames.hdr.filter((f) => C.decodeMinorFrame(f).words[0] === 0xeb90);
        ok(withSync.length >= 1, `the downlist sync leads a TB1 window (${withSync.length} of ${frames.hdr.length})`);
        if (withSync.length) {
            const w = C.decodeMinorFrame(withSync[0]).words;
            eq(w.slice(0, 4), [0xeb90, 0xc014, 0x1002, 0x1003], 'the frame words in the stream');
        }
        const ldrSync = frames.ldr.filter((f) => C.decodeMinorFrame(f).words[0] === 0xeb90);
        ok(ldrSync.length >= 1, 'the downlist in the 64-kbps stream too');

        sendCmd(C.CMD_FMT_SELECT(true));
        await sleep(20);
        eq(u.fmtSelect, 'PRGM', 'PRGM selected');
        r = await transact(C.CMD_READ_BITE, 1);
        eq(r.words[0] & C.BSR.PRGM, 1, 'BSR bit 16 reads PRGM');
        sendCmd(C.CMD_FMT_SELECT(false));
        await sleep(20);
        eq(u.fmtSelect, 'FIXED', 'FIXED again');
        pc.setFormatSwitch('program');
        sendCmd(C.CMD_FMT_SELECT(false));
        await sleep(20);
        eq(u.fmtSelect, 'PRGM', 'the panel switch overrides the GPC');
        pc.setFormatSwitch('gpc');

        const load = [];
        for (let i = 0; i < 32; i++) load.push(0x1000 + i);
        sendCmd(C.CMD_LOAD_FMT(64, 100, 32));
        for (const w of load) sendWord(w);
        await sleep(20);
        r = await transact(C.CMD_READ_FMT(64, 100, 32), 32);
        eq(r.words, load, 'the 64-kbps RAM reads back');
        r = await transact(C.CMD_READ_FMT(128, 100, 4), 4);
        eq(r.words, [0, 0, 0, 0], 'the 128-kbps RAM is empty');

        sendCmd(C.CMD_WRITE_TB(1, 0, 32));
        sendWord(1); sendWord(2);
        sendCmd(C.CMD_READ_BITE);
        await sleep(20);
        r = await transact(C.CMD_READ_BITE, 1);
        eq(r.words[0] & C.BSR.GPC_RESPONSE, C.BSR.GPC_RESPONSE, 'bit 14 reset by the read');
        eq(u.stats.cut, 1, 'one transfer cut short');

        await sleep(30);
        ok(u.stats.fetches > 0, `fetch commands go out (${u.stats.fetches})`);
        ok(u.stats.fetchErrors > 0, `and time out with no MDM (${u.stats.fetchErrors})`);
        const fetch = pc.fetch;
        const mtuAddr = F.fetchAddress(fetch, 'OF1', 0, 1);
        r = await transact(C.CMD_READ_RAM(mtuAddr, 2), 2);
        eq(r.sev, [C.STATUS.NO_RESPONSE, C.STATUS.NO_RESPONSE].map((s) => s & ~D.SEV.V | D.SEV.V), 'no response: S cleared, V set');

        mdm = new X.MDM({ id: 'OF1', verbose: false });
        await mdm.ready();
        await sleep(1300);
        await transact(C.CMD_READ_BITE, 1);
        await sleep(200);
        r = await transact(C.CMD_READ_RAM(mtuAddr, 7), 7);
        eq(r.words.length, 7, 'seven MTU words');
        ok(r.sev.every((s) => (s & D.SEV.E) !== 0), 'E set: the serial channel has no device');
        ok(r.sev.every((s) => (s & D.SEV.S) !== 0), 'S set: the MDM answered');
        const disc = fetch.entries.find((e) => e.mdm === 'OF1' && e.type !== 'SIO');
        r = await transact(C.CMD_READ_RAM(disc.ram, 2), 2);
        ok(r.sev.every((x) => (x & (D.SEV.S | D.SEV.E)) === D.SEV.S), 'a card read is valid: S set, E clear');
        ok(u.stats.fetches > 40, `the fetch keeps cycling (${u.stats.fetches})`);
        r = await transact(C.CMD_READ_BITE, 1);
        eq((r.words[0] | C.BSR.INPUT_VALID) & 0xfffe, 0xfffe, 'the BSR good but for bit 10 with the MDM answering');
        eq(r.words[0] & C.BSR.MDM_RESPONSE, C.BSR.MDM_RESPONSE, 'bit 15 good: the MDM answers');

        pc.setPower(0);
        inbox.length = 0;
        sendCmd(C.CMD_READ_BITE);
        await sleep(40);
        eq(inbox.length, 0, 'no unit powered, no answer');
        pc.setPower(2);
        inbox.length = 0;
        sendCmd(C.CMD_READ_BITE);
        await sleep(40);
        eq(inbox.length, 1, 'unit 2 answers on the same GPC bus');
        eq(inbox[0].sev[0] & D.SEV.S, 0, 'fresh from power-up');
    } finally {
        if (pc) await pc.stop();
        if (mdm) await mdm.stop();
        gpc?.close(); hdr?.close(); ldr?.close();
    }

    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
