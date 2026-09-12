// deu.cjs — the DEU / IDP display-keyboard bus protocol.
//
// Command encode and decode, the memory-fill message, the poll response and
// its checksum, and a round trip over a real bus in the framing a GPC's bus
// control element uses (a command is two halfwords, a data word is
// one).
//
// Usage:
//   cd ext/sim && node test/meds/deu.cjs
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
        `deu.test.${path.basename(rel).replace(/\W/g, '_')}.${process.pid}.cjs`);
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

let pass = 0, fail = 0;
function ok(cond, what) {
    if (cond) { pass++; } else { fail++; console.log('FAIL: ' + what); }
}
function eq(a, b, what) { ok(a === b, `${what}: got ${a}, want ${b}`); }
// The sixteen halfwords of a poll response sum to zero.
function sum16(p) { let s = 0; for (const w of p) s = (s + w) & 0xffff; return s; }
const settle = (ms = 120) => new Promise((r) => setTimeout(r, ms));

async function main() {
    const DEU = await bundle('meds/deu/deuProto.coffee');
    const B = await bundle('com/bus.civet');

    // the command word
    //
    // 5-bit interface unit address, then a 10-bit function and a 9-bit
    // halfword count.  These are the commands the flight software's bus
    // programs issue; the values are what its own constants assemble to.
    eq(DEU.IUA, 10, 'the display units answer at interface unit address 10');
    const cases = [
        ['TIME_FILL', 7, 0x570007],      // the header clock: 7 halfwords out
        ['DISPLAY_FILL', 511, 0x5719ff], // a full display fill
        ['DISPLAY_FILL', 8, 0x571808],
        ['FORMAT_FILL', 96, 0x572860],   // a critical-format background
        ['MEDS_XFER', 100, 0x573064],    // always 100 halfwords
        ['DUMP', 2, 0x574002],
        ['POLL', 0, 0x502000],
        ['BITE', 0, 0x508000],
        ['RESET_SPL', 0, 0x510000],
    ];
    for (const [name, count, want] of cases) {
        const w = DEU.encodeCommand(DEU.FUNC[name], count);
        eq(w, want, `${name} count ${count} encodes`);
        const c = DEU.decodeCommand(w);
        eq(c.iua, 10, `${name} addresses a display unit`);
        eq(c.name, name, `${name} decodes back`);
        eq(c.count, count, `${name} count decodes back`);
    }
    // A command for somebody else on the same bus must be ignorable.
    eq(DEU.decodeCommand((11 << 19) | 0x02000).iua, 11, 'another unit address');
    eq(DEU.decodeCommand(0x0057ffff & 0xffffff).iua, 10, 'the address survives a full count');

    // the memory-fill message
    //
    // Word 1 is the count, word 2 the DEU address with the branch bit set,
    // and the transfer is the payload plus those two.
    const payload = [0x1234, 0x5678, 0x9abc];
    const hdr = DEU.fillHeader(0x19ee, payload.length);
    eq(hdr.length, 2, 'the fill header is two halfwords');
    eq(hdr[0], 3, 'word 1 is the count');
    eq(hdr[1], 0x19ee, 'word 2 is the address');
    // the address is plain: the DEU loader's fill table
    // holds addresses with bit 12 both set and clear.
    eq(DEU.fillHeader(0x0f49, 1)[1], 0x0f49, 'an address below 0x1000 is left alone');
    eq(DEU.fillHeader(0x1fe4, 1)[1], 0x1fe4, 'and one above keeps its top bit');
    const f = DEU.parseFill(hdr.concat(payload));
    eq(f.addr, 0x19ee, 'the fill address comes back');
    eq(f.count, 3, 'the count comes back');
    eq(f.payload.join(','), payload.join(','), 'the payload comes back');
    eq(f.short, false, 'a complete message is not short');
    eq(DEU.parseFill(hdr.concat([0x1234])).short, true, 'a truncated message is short');
    eq(DEU.parseFill([1]), null, 'a message with no room for a header is refused');

    // The transfer count is NINE bits.  A fill carries at most 509
    // format control words, and content longer than that MUST be split --
    // handing a whole display to one fill loses all but `length & 0x1ff`
    // of it, silently, because the count wraps.
    eq(DEU.MAX_TRANSFER_WORDS, 511, 'a transfer is at most 511 halfwords');
    eq(DEU.MAX_FILL_PAYLOAD, 509, '...so a fill carries at most 509 words');
    eq(DEU.encodeCommand(DEU.FUNC.DISPLAY_FILL, 1067) & DEU.COUNT_MASK, 43,
       'a count that does not fit wraps -- hence the split');
    const one = DEU.fillMessages(DEU.FUNC.DISPLAY_FILL, 0x19ee, new Array(100).fill(7));
    eq(one.length, 1, 'content that fits is one transfer');
    eq(one[0].count, 102, '...counting its header');
    const split = DEU.fillMessages(DEU.FUNC.DISPLAY_FILL, 0x19ee,
                                   Array.from({length: 1065}, (_, i) => i + 1));
    eq(split.length, 3, '1065 words take three transfers');
    ok(split.every((m) => m.count <= DEU.MAX_TRANSFER_WORDS),
       'every transfer is within the count');
    eq(split[0].addr, 0x19ee, 'the first loads at the address given');
    eq(split[1].addr, 0x19ee + 509, '...and each next carries on from it');
    eq(split[2].count, 1065 - 2 * 509 + 2, 'the last carries what is left');
    // Reassembling the transfers reproduces the content exactly, in place.
    const mem = new Uint16Array(DEU.DEU_MEMORY_WORDS);
    for (const m of split) {
        const g = DEU.parseFill(m.body);
        eq(g.short, false, `transfer at 0x${g.addr.toString(16)} is complete`);
        for (let i = 0; i < g.payload.length; i++) mem[g.addr + i] = g.payload[i];
    }
    let intact = true;
    for (let i = 0; i < 1065; i++) if (mem[0x19ee + i] !== i + 1) intact = false;
    ok(intact, 'and the reassembled content is the content');
    // The addresses the flight software fills at.
    eq(DEU.ADDR.DISPLAY_HEADER, 0x19ee, 'the display header');
    eq(DEU.ADDR.CRITICAL_FORMAT, 0x0100, 'the critical-format area');
    eq(DEU.ADDR.DYNAMIC, 0x1a0e, 'the dynamic portion');

    // the poll response
    //
    // Sixteen halfwords: header, key count, ten key words, three BITE
    // registers, checksum.
    const p = DEU.pollResponse({});
    eq(p.length, 16, 'a poll response is 16 halfwords');
    eq(DEU.POLL_WORDS, 16, '...which is what the bus program asks for');
    let sum = 0;
    for (const w of p) sum = (sum + w) & 0xffff;
    eq(sum, 0, 'the checksum makes the response sum to zero');
    // the poll analyser calls a response with a ZERO first BITE register
    // no response at all -- that is where "NO DEU POLL RESPONSE" comes from,
    // so a healthy unit must never send one.
    ok(p[12] !== 0, 'a healthy unit answers with a non-zero BITE register 1');
    eq(p[12] & DEU.BITE1.ALWAYS_ONE, DEU.BITE1.ALWAYS_ONE, 'the always-one bit');
    eq(p[12] & DEU.BITE1.IPL_DONE, DEU.BITE1.IPL_DONE, 'IPL performed');
    eq(p[12] & DEU.BITE1.IPL_ERROR, 0, 'no IPL error');
    eq(p[12] & DEU.BITE1.IPL_CIRCUIT_ERROR, 0, 'no IPL circuit error');

    // keystrokes
    //
    // THREE keystrokes to a halfword, FIVE bits each, most significant
    // first: the IPL monitor unpacks them with a shift-left-double of 5.
    // And the count word is `0xFF00 | count` -- the monitor recovers it
    // with an XOR of 0xFF00 and then rejects anything over 6, while the
    // application masks the same word with 0x003F.  A bare count makes the
    // monitor read 0xFF00+n and call every entry illegal.
    eq(DEU.KEYS_PER_WORD, 3, 'three keystrokes to a halfword');
    eq(DEU.KEY_BITS, 5, 'five bits each');
    eq(DEU.MAX_KEYS_IPL, 6, 'the IPL monitor takes at most six');
    // The key codes are the monitor's own dispatch table.
    eq(DEU.KEY.SYS_SUMM, 0x10, 'SYS SUMM');
    eq(DEU.KEY.ITEM, 0x14, 'ITEM');
    eq(DEU.KEY.GPC_CRT, 0x19, 'GPC/CRT');
    eq(DEU.KEY.RESUME, 0x1b, 'RESUME');
    eq(DEU.KEY.EXEC, 0x1e, 'EXEC');
    eq(DEU.KEY.PRO, 0x1f, 'PRO');
    eq(DEU.KEY['0'], 0x00, 'the digits start at zero');
    eq(DEU.KEY.F, 0x0f, '...and the hex letters run to F');

    // These two words were taken off the wire, from the GPC IPL monitor
    // receiving `ITEM 2 7 + 1 EXEC` -- the exact packing it accepted.
    const entry = [DEU.KEY.ITEM, DEU.KEY['2'], DEU.KEY['7'],
                   DEU.KEY.PLUS, DEU.KEY['1'], DEU.KEY.EXEC];
    const pk = DEU.pollResponse({header: DEU.HDR.KYBD_MSG, keys: entry});
    eq(pk[0], DEU.HDR.KYBD_MSG, 'the header says a keyboard message is ready');
    eq(pk[1], 0xff06, 'the count word is 0xFF00 | 6');
    eq(pk[1] & DEU.KEY_COUNT_MASK, 6, '...and masks to the count');
    eq(pk[1] ^ DEU.KEY_COUNT_HIGH, 6, '...and XORs to it, which is what the monitor does');
    eq(pk[2], 0xa08e, 'ITEM, 2, 7 pack into one halfword');
    eq(pk[3], 0xb07c, '+, 1, EXEC into the next');
    eq(DEU.unpackKeys(pk.slice(2), 6).join(','), entry.join(','),
       'and they unpack to the keys that were pressed');
    let sk = 0;
    for (const w of pk) sk = (sk + w) & 0xffff;
    eq(sk, 0, 'the checksum still closes with keys in it');
    // A single key sits at the top of its halfword and leaves the rest zero.
    const one1 = DEU.pollResponse({keys: [DEU.KEY.SYS_SUMM]});
    eq(one1[1], 0xff01, 'one key');
    eq(one1[2], 0x8000, '...at the top of the first key halfword');
    // More keys than the buffer holds are dropped.
    const many = DEU.pollResponse({keys: new Array(40).fill(DEU.KEY['1'])});
    eq(many.length, 16, 'an over-full keyboard still gives 16 halfwords');
    eq(many[1] & DEU.KEY_COUNT_MASK, DEU.MAX_KEYS,
       '...and reports the 30 the buffer can carry');

    // the unit assembles an ENTRY before it sends anything
    //
    // A keyboard message carries a WHOLE entry.  `CM4KYBD` dispatches
    // once per message, on KEY1 through KEY1TBL, so an entry split across
    // polls arrives as several entries each dispatched on its own first key
    // and thrown away.  Typed at human speed, "ITEM 18 EXEC" went out as
    // ITEM / 1 / 8 EXEC over three polls and the monitor ignored all three;
    // only an entry fast enough to land inside one 40 ms poll ever worked.
    const U = await bundle('meds/deu/deuUnit.coffee');
    const mkUnit = () => new U.DEUUnit({name: 'T', send: () => {}, fill: () => {},
                                        reset: () => {}, log: () => {}});
    const u = mkUnit();
    for (const k of ['ITEM', '1', '8']) u.pressKey(DEU.KEY[k]);
    eq(u.pollResponse()[0] & DEU.HDR.KYBD_MSG, 0,
       'a half-typed entry sends nothing at all');
    u.pressKey(DEU.KEY.EXEC);
    const done = u.pollResponse();
    eq(done[0] & DEU.HDR.KYBD_MSG, DEU.HDR.KYBD_MSG, 'EXEC completes the entry');
    eq(DEU.unpackKeys(done.slice(2), done[1] & DEU.KEY_COUNT_MASK).join(','),
       [DEU.KEY.ITEM, DEU.KEY['1'], DEU.KEY['8'], DEU.KEY.EXEC].join(','),
       '...and all four keys ride out together, in order');
    eq(u.pollResponse()[0] & DEU.HDR.KYBD_MSG, 0, 'and only once');

    // CLEAR wipes the scratch pad in the unit and is not sent.
    const uc = mkUnit();
    for (const k of ['ITEM', '1', 'CLEAR']) uc.pressKey(DEU.KEY[k]);
    eq(uc.pollResponse()[0] & DEU.HDR.KYBD_MSG, 0, 'CLEAR discards the entry');

    // A key that completes an entry by itself goes on its own.
    const us = mkUnit();
    us.pressKey(DEU.KEY.SYS_SUMM);
    eq(DEU.unpackKeys(us.pollResponse().slice(2), 1).join(','),
       String(DEU.KEY.SYS_SUMM), 'a single command key needs no EXEC');

    // Two entries never share a message: the second would be read as the
    // first one's arguments.  The queued one waits for the next poll.
    const u2 = mkUnit();
    u2.pressKey(DEU.KEY.SYS_SUMM);
    u2.pressKey(DEU.KEY.RESUME);
    eq(u2.pollResponse()[1] & DEU.KEY_COUNT_MASK, 1, 'one entry per message');
    eq(u2.pollResponse()[1] & DEU.KEY_COUNT_MASK, 1, '...and the next follows');
    eq(u2.pollResponse()[0] & DEU.HDR.KYBD_MSG, 0, '...and then no more');

    // The major function switch rides in the header, GNC until it is read.
    const usw = mkUnit();
    const mfOf = (u) => (u.pollResponse()[0] & DEU.HDR.MAJOR_FUNC) >>> DEU.MAJOR_FUNC_SHIFT;
    eq(mfOf(usw), DEU.MAJOR_FUNC_CODE.GNC, 'a unit reports GNC before the switch is read');
    usw.majorFunc = DEU.MAJOR_FUNC_CODE.SM;
    eq(mfOf(usw), DEU.MAJOR_FUNC_CODE.SM, 'SM once the switch says so');
    usw.majorFunc = DEU.MAJOR_FUNC_CODE.PL;
    eq(mfOf(usw), DEU.MAJOR_FUNC_CODE.PL, '...and PL');

    // MSG RESET and ACK are header bits
    //
    // The IPL monitor reads both out of the poll response header in
    // POLLRSP (bits 4 and 10, numbered from the most significant), and
    // CM4KYBD says so itself.  Both are in KEY1TBL as well and both point
    // at STMWAIT, so a unit that sent them as keystrokes would press a key
    // that does nothing: MSG RESET would never pop a message off the error
    // list and ACK would never stop the message line flashing.
    const um = mkUnit();
    um.pressKey(DEU.KEY.MSG_RESET);
    const mr = um.pollResponse();
    eq(mr[0] & DEU.HDR.MSG_RESET, DEU.HDR.MSG_RESET,
       'MSG RESET rides out in the header');
    eq(mr[1] & DEU.KEY_COUNT_MASK, 0, '...and not as a keystroke');
    eq(mr[0] & DEU.HDR.KYBD_MSG, 0, '...with no keyboard message');
    eq(um.pollResponse()[0] & DEU.HDR.MSG_RESET, 0,
       '...reported once, then cleared -- one press, one message popped');
    eq(sum16(mr), 0, '...and the response still closes');

    // ACK likewise, and neither disturbs a half-typed entry.
    const ua = mkUnit();
    for (const k of ['ITEM', '1']) ua.pressKey(DEU.KEY[k]);
    ua.pressKey(DEU.KEY.ACK);
    const ak = ua.pollResponse();
    eq(ak[0] & DEU.HDR.ACK, DEU.HDR.ACK, 'ACK rides out in the header');
    eq(ak[0] & DEU.HDR.KYBD_MSG, 0, '...leaving the entry on the scratch pad');
    eq(ua.pollResponse()[0] & DEU.HDR.ACK, 0, '...once');
    ua.pressKey(DEU.KEY.EXEC);
    const ae = ua.pollResponse();
    eq(DEU.unpackKeys(ae.slice(2), ae[1] & DEU.KEY_COUNT_MASK).join(','),
       [DEU.KEY.ITEM, DEU.KEY['1'], DEU.KEY.EXEC].join(','),
       '...and the entry completes intact afterwards');

    // A response carrying MSG RESET or ACK carries no keyboard message:
    // when either bit is set, KYBD MSG PRESENT is clear.
    const uq = mkUnit();
    for (const k of ['ITEM', '1', '8', 'EXEC']) uq.pressKey(DEU.KEY[k]);
    uq.pressKey(DEU.KEY.MSG_RESET);
    const both = uq.pollResponse();
    eq(both[0] & DEU.HDR.MSG_RESET, DEU.HDR.MSG_RESET, 'MSG RESET goes out');
    eq(both[0] & DEU.HDR.KYBD_MSG, 0, '...and suppresses the keyboard message');
    eq(both[1] & DEU.KEY_COUNT_MASK, 0, '...which is not packed either');
    const after = uq.pollResponse();
    eq(after[0] & DEU.HDR.KYBD_MSG, DEU.HDR.KYBD_MSG,
       '...the entry is not lost, it rides the next poll');
    eq(after[1] & DEU.KEY_COUNT_MASK, 4, '...all four keystrokes of it');

    // A unit without its control program reports mode status as ONE word
    // -- the header -- so the bits are spent there too, or a press during
    // a DEU load would be reported twice.
    const ul = mkUnit();
    ul.ipled = false;
    ul.pressKey(DEU.KEY.MSG_RESET);
    eq(ul.takeHeader() & DEU.HDR.MSG_RESET, DEU.HDR.MSG_RESET,
       'the mode-status word carries it');
    eq(ul.takeHeader() & DEU.HDR.MSG_RESET, 0, '...and spends it');

    // The load, as the DEU loader in the PASS drives it: a BITE status
    // request, eight memory-fill blocks of which the last is 250 halfwords
    // at DEU address 2 carrying the unit's id at 0x1D, a poll, a
    // critical-format fill, a poll.
    const sent = [];
    const un = new U.DEUUnit({name: 'T', ipled: false, send: (w) => sent.push(w),
                              fill: () => {}, reset: () => {}, log: () => {}});
    const ask = (func) => {
        sent.length = 0;
        un.onCommand(DEU.encodeCommand(func, 0));
        return sent[0];
    };
    const fill = (func, addr, payload) => {
        un.onCommand(DEU.encodeCommand(func, payload.length + 2));
        for (const w of [payload.length, addr, ...payload]) un.onData(w);
    };
    let r = ask(DEU.FUNC.POLL);
    eq(r.length, DEU.MODE_STATUS_WORDS, 'unloaded, a poll gets the header alone');
    eq(r[0] & DEU.HDR.IPL_REQUIRED, DEU.HDR.IPL_REQUIRED, '...asking for a load');
    r = ask(DEU.FUNC.BITE);
    eq(r.length, DEU.BITE_WORDS, 'the BITE request is answered in full');
    eq(r[0] & DEU.HDR.IPL_REQUIRED, DEU.HDR.IPL_REQUIRED, '...the header leads it');
    eq(r[1] & 0xf000, DEU.BITE1.ALWAYS_ONE | DEU.BITE1.IPL_DONE,
       '...hardware register 1 follows: IPL performed, no IPL error, no IPL ' +
       'circuit error, the loader\'s precondition');
    eq(r[3], DEU.SWSTATUS_HEALTHY, '...then register 2 and the software status');
    // The eight fill blocks go out under the IPL fill command word
    // 0x570000, whose function code is the one the header clock also uses;
    // a headered payload marks these as memory fills.
    const blocks = [[0x0f49, 508], [0x1145, 508], [0x1341, 508], [0x153d, 508],
                    [0x1739, 508], [0x1935, 200], [0x1fe4, 1]];
    for (const [addr, n] of blocks) fill(DEU.FUNC.TIME_FILL, addr, new Array(n).fill(0x5a5a));
    eq(ask(DEU.FUNC.POLL).length, DEU.MODE_STATUS_WORDS,
       'seven blocks in, the poll still gets the header alone');
    const low = new Array(250).fill(0);
    low[DEU.DEU_ID_ADDR - 2] = 2;
    fill(DEU.FUNC.TIME_FILL, 0x0002, low);
    eq(un.ipled, true, 'the 250-halfword block at address 2 completes the load');
    eq(un.deuId, 2, '...carrying the unit id the loader patched in at 0x1D');
    r = ask(DEU.FUNC.POLL);
    eq(r.length, DEU.POLL_WORDS, 'loaded, a poll gets the full response');
    eq(r[0] & (DEU.HDR.BITE_CRITICAL | DEU.HDR.IPL_REQUIRED), DEU.HDR.BITE_CRITICAL,
       '...header bits 15-16 read 10: critical BITE present, IPL not required');
    eq(r[14] & (DEU.SWSTATUS.INITIALIZED | DEU.SWSTATUS.CHECKSUM_ERROR), DEU.SWSTATUS.INITIALIZED,
       '...initialized, no checksum error');
    fill(DEU.FUNC.FORMAT_FILL, DEU.ADDR.CRITICAL_FORMAT, new Array(100).fill(0x1234));
    r = ask(DEU.FUNC.POLL);
    eq(r[0] & DEU.HDR.BITE_CRITICAL, 0, 'the critical BITE was reported once');
    eq(r[14] & DEU.SWSTATUS.CHECKSUM_ERROR, 0, '...and the critical formats checksum');

    // The seven-halfword header clock rides the same command word as the IPL
    // fill, and the loaded unit still reads it as time, not as a fill.
    const clk = DEU.timeFillWords({mission: 3661, event: 12, conv: 1});
    un.onCommand(DEU.encodeCommand(DEU.FUNC.TIME_FILL, clk.length));
    for (const w of clk) un.onData(w);
    eq(un.time && un.time.conv, 1, 'a seven-word payload updates the clock');
    ok(un.ipled, '...and does not disturb the loaded state');

    // the scratch pad line, per the spec
    //
    const S = await bundle('meds/deu/deuSPL.coffee');
    const type = (spl, ...names) => {
        for (const n of names) spl.press(typeof n === 'number' ? n : DEU.KEY[n]);
        return spl;
    };
    const line = (...names) => type(new S.SPL(), ...names).text();
    const digits = (s) => [...s].map((c) => DEU.KEY[c]);

    // Position 0 is always a space, and a delimiter generates FIVE things:
    // a blank, an open parenthesis, the two-space item number, a close
    // parenthesis and the sign.
    eq(line('ITEM', '1', '4', 'PLUS'), ' ITEM (14)+',
       'a delimiter generates " (nn)+" out of the digits typed');
    eq(line('ITEM', '1', 'PLUS'), ' ITEM ( 1)+',
       '...with the number in two spaces');
    eq(line('ITEM', '1', '4', 'MINUS'), ' ITEM (14)-', '...and either sign');
    eq(line('ITEM', '1', '8', 'EXEC'), ' ITEM 18 EXEC ',
       'a terminator takes a blank either side');
    eq(line('OPS', '2', '0', '1', 'PRO'), ' OPS 201 PRO ', 'OPS 201 PRO');
    // The hex digits are single upper-case letters, like the key names.
    eq(line('ITEM', 'D', 'PLUS', 'A', 'B', 'EXEC'), ' ITEM ( D)+AB EXEC ',
       'hex digits do not get spaced apart');

    // The item number is the LAST TWO DIGITS on the line -- which is how
    // a second item can follow a four-digit value with no separator typed.
    eq(line('ITEM', '1', '1', 'PLUS', ...digits('123412'), 'PLUS'),
       ' ITEM (11)+1234 (12)+',
       'a second delimiter takes the last two digits and leaves the value');

    // The spec's three worked examples, character for character.
    const long = (...tail) => line('ITEM', '1', '1', 'PLUS', ...digits('1234'),
        '1', '2', 'PLUS', ...digits('1234'), '1', '3', 'PLUS', ...tail);

    const errCase = long(...digits('123456789'));
    eq(errCase, ' ITEM (11)+1234 (12)+1234 (13)+123456789 ERR ',
       'the 40th character raises ERR');
    eq(errCase.length, 45, '...and ERR\'s own characters count: 45');

    const execCase = long(...digits('12345678'), 'EXEC');
    eq(execCase, ' ITEM (11)+1234 (12)+1234 (13)+12345678 EXEC ',
       'a terminator just past the 39th character is the one exception');
    eq(execCase.length, 45, '...also 45, and no ERR');

    const biggest = long(...digits('12345678'), '1', '4', 'PLUS');
    eq(biggest, ' ITEM (11)+1234 (12)+1234 (13)+12345678 (14)+ ERR ',
       'a delimiter passes the limit by six at once');
    eq(biggest.length, 50, '...the largest entry the line can ever hold');

    // ...and it cannot grow past that: the last position is never filled.
    const more = new S.SPL();
    type(more, 'ITEM', '1', '1', 'PLUS', ...digits('1234'), '1', '2', 'PLUS',
         ...digits('1234'), '1', '3', 'PLUS', ...digits('12345678'), '1', '4',
         'PLUS');
    eq(more.press(DEU.KEY['5']), 'full', 'a keystroke that will not fit is refused');
    eq(more.text().length, 50, '...leaving the line as it was');
    eq(S.SPL_LENGTH, 51, 'the line is 51 characters');

    // POLL FAIL shares the line and takes ten characters off the limit.
    const splPF = new S.SPL({pollFail: true});
    eq(splPF.limit(), 29, 'POLL FAIL drops the limit to 29');
    type(splPF, 'ITEM', '1', '1', 'PLUS', ...digits('1234'), '1', '2', 'PLUS',
         ...digits('12345678'));
    eq(splPF.line.length, 29, 'a 29-character line is still legal');
    ok(!splPF.err, '...with no ERR');
    splPF.press(DEU.KEY['9']);
    ok(splPF.err, '...and the 30th raises it');

    // The three keys that never appear on the line.
    const sp = new S.SPL();
    type(sp, 'ITEM', '1');
    eq(sp.press(DEU.KEY.ACK), 'silent', 'ACK never reaches the line');
    eq(sp.press(DEU.KEY.MSG_RESET), 'silent', '...nor MSG RESET');
    eq(sp.text(), ' ITEM 1', '...and neither disturbs the entry');
    eq(sp.press(DEU.KEY.CLEAR), 'cleared', 'CLEAR is the third');
    eq(sp.text(), ' ITEM', '...and it takes back one keystroke, not the line');
    sp.press(DEU.KEY.CLEAR);
    eq(sp.text(), ' ', '...so a second CLEAR reaches the leading space');
    sp.press(DEU.KEY.CLEAR);
    eq(sp.text(), ' ', '...and further ones have nothing left to take');

    // The line is the whole of the entry: a keystroke that wipes it leaves
    // nothing for CLEAR to reach back to.
    const spw = new S.SPL();
    type(spw, 'OPS', '1', '0', '1', 'PRO');
    eq(spw.text(), ' OPS 101 PRO ', 'a completed entry stays to be read back');
    spw.press(DEU.KEY['2']);
    eq(spw.text(), ' 2 ERR ', '...and the next keystroke wipes it');
    spw.press(DEU.KEY.CLEAR);
    eq(spw.text(), ' ', '...which CLEAR cannot bring back');

    const spr = new S.SPL();
    type(spr, 'ITEM', '1', '2', 'SPEC');
    eq(spr.text(), ' SPEC', 'an initiator restarts the entry');
    spr.press(DEU.KEY.CLEAR);
    eq(spr.text(), ' ', '...and CLEAR cannot bring the abandoned one back');

    // A keystroke is not a character: a delimiter draws ` (12)+` in one
    // press and comes off in one.
    const spd = new S.SPL();
    type(spd, 'ITEM', '1', '2', 'PLUS', '3');
    eq(spd.text(), ' ITEM (12)+3', 'a delimiter entry');
    spd.press(DEU.KEY.CLEAR);
    eq(spd.text(), ' ITEM (12)+', '...CLEAR takes the data digit');
    spd.press(DEU.KEY.CLEAR);
    eq(spd.text(), ' ITEM 12', '...and the next takes the whole delimiter');

    // A completed entry stays up to be read back; the next keystroke wipes it.
    const rb = type(new S.SPL(), 'ITEM', '1', '8', 'EXEC');
    eq(rb.text(), ' ITEM 18 EXEC ', 'a completed entry stays on the line');
    rb.press(DEU.KEY.ITEM);
    eq(rb.text(), ' ITEM', '...until the next keystroke starts a new one');

    // the grammar
    //
    //   single keystrokes: MSG RESET, ACK, RESUME, SYS SUMM, FAULT SUMM,
    //                      EXEC, CLEAR
    //   I/O RESET EXEC | OPS b b b PRO | SPEC [[b]b]b PRO
    //   GPC/CRT b b EXEC
    //   ITEM [b]b [(+|-) [data] [(+|-)] [data] ...] EXEC
    //   ITEM a [(+|-) data] EXEC
    eq(line('OPS', '2', '0', '1', 'PRO'), ' OPS 201 PRO ', 'OPS takes three digits');
    eq(line('OPS', '2', '0', 'PRO'), ' OPS 20 PRO ERR ', '...exactly three');
    eq(line('SPEC', '9', 'PRO'), ' SPEC 9 PRO ', 'SPEC takes one to three');
    eq(line('SPEC', '1', '2', '3', 'PRO'), ' SPEC 123 PRO ', '...three of them');
    eq(line('SPEC', '1', '2', '3', '4'), ' SPEC 1234 ERR ', '...and no more');
    eq(line('GPC_CRT', '1', '4', 'EXEC'), ' GPC/CRT 14 EXEC ', 'GPC/CRT b b EXEC');
    eq(line('IO_RESET', 'EXEC'), ' I/O RESET EXEC ', 'I/O RESET EXEC');
    eq(line('EXEC'), ' EXEC ', 'EXEC on its own IS an entry');
    eq(line('PRO'), ' PRO ERR ', '...but PRO is not');
    eq(line('RESUME'), ' RESUME ', 'and RESUME is a single keystroke');
    eq(line('1'), ' 1 ERR ', 'a digit cannot begin an entry');
    eq(line('DECIMAL'), ' . ERR ', 'nor a decimal point');
    // ...but a decimal IS data, so it is legal inside a value run -- and
    // only there: `b` and `a` do not take it, so it can never appear in an
    // item number, an OPS/SPEC number or a GPC/CRT id.
    eq(line('ITEM', '1', '1', 'PLUS', '1', 'DECIMAL', '5', 'EXEC'),
       ' ITEM (11)+1.5 EXEC ', 'a decimal point is legal in a data run');
    eq(line('ITEM', 'D', 'PLUS', 'DECIMAL', '5', 'EXEC'), ' ITEM ( D)+.5 EXEC ',
       '...in the ITEM a form too');
    eq(line('ITEM', '1', 'DECIMAL'), ' ITEM 1. ERR ',
       '...but not in an item number');
    eq(line('SPEC', '9', 'DECIMAL'), ' SPEC 9. ERR ', '...nor a SPEC number');
    eq(line('ITEM', 'PLUS'), ' ITEM + ERR ',
       'a delimiter needs an item number in front of it');
    eq(line('ITEM', '1', '1', 'PLUS', 'EXEC'), ' ITEM (11)+ EXEC ',
       'the data after a delimiter is optional');
    // Two delimiters running ARE legal in the numeric form -- `[data]` is
    // optional between them -- which had been guessed the other way.
    eq(line('ITEM', '1', '1', 'PLUS', 'PLUS'), ' ITEM (11)+ (  )+',
       'two delimiters running are legal');
    // ITEM a is the other form, and there the data is REQUIRED.
    eq(line('ITEM', 'D', 'PLUS', 'A', 'B', 'EXEC'), ' ITEM ( D)+AB EXEC ',
       'ITEM a (+|-) data EXEC');
    // No delimiter, no parentheses: the group is generated BY the
    // delimiter key, so an item with no value shows as it was typed.
    eq(line('ITEM', 'D', 'EXEC'), ' ITEM D EXEC ', '...the delimiter is optional');
    eq(line('ITEM', 'D', 'PLUS', 'EXEC'), ' ITEM ( D)+ EXEC ERR ',
       '...but not the data behind one');
    eq(line('ITEM', '1', 'A'), ' ITEM 1A ERR ',
       'a letter cannot follow a digit in an item number');

    // what happens to an illegal keystroke
    //
    const ill = type(new S.SPL(), 'SPEC', '1', '2', '3', '4');
    eq(ill.err, 'syntax', 'a fourth SPEC digit raises a syntax ERR');
    eq(ill.text(), ' SPEC 1234 ERR ', '...drawn, with ERR to the right of it');

    // Nothing else is accepted while it is up.
    eq(ill.press(DEU.KEY['5']), 'blocked', 'no further keystroke is taken');
    eq(ill.text(), ' SPEC 1234 ERR ', '...and the line does not move');

    // CLEAR takes back the ERR and THAT KEYSTROKE, not the whole entry.
    eq(ill.press(DEU.KEY.CLEAR), 'cleared', 'CLEAR removes it');
    eq(ill.text(), ' SPEC 123', '...and the rest of the entry stands');
    ok(!ill.err, '...with the ERR gone');
    eq(ill.press(DEU.KEY.PRO), 'complete', '...and the entry can be finished');

    // The other way out: reinitiate the sequence.
    const re = type(new S.SPL(), 'ITEM', 'PLUS');
    eq(re.err, 'syntax', 'an illegal keystroke');
    re.press(DEU.KEY.ITEM);
    eq(re.text(), ' ITEM', 'a key that can begin an entry reinitiates');
    ok(!re.err, '...clearing the ERR');

    // A command key is an entry on its own, so it starts one.
    const cmd = type(new S.SPL(), 'ITEM', '1', 'SYS_SUMM');
    eq(cmd.text(), ' SYS SUMM ', 'a command key does not ride behind an ITEM');
    eq(cmd.keys.join(','), String(DEU.KEY.SYS_SUMM), '...and goes out alone');

    // A syntax error is not transmitted either.
    const usyn = mkUnit();
    for (const k of ['ITEM', 'PLUS']) usyn.pressKey(DEU.KEY[k]);
    usyn.pressKey(DEU.KEY.EXEC);
    eq(usyn.pollResponse()[0] & DEU.HDR.KYBD_MSG, 0,
       'an entry with a syntax ERR sends nothing');

    // An entry that raised ERR is not transmitted at all.
    const ue = mkUnit();
    for (const k of ['ITEM', '1', '1', 'PLUS']) ue.pressKey(DEU.KEY[k]);
    for (const c of digits('12345678901234567890123456789012345678901234'))
        ue.pressKey(c);
    ok(ue.spl.err, 'the entry ran past the limit');
    ue.pressKey(DEU.KEY.EXEC);
    eq(ue.pollResponse()[0] & DEU.HDR.KYBD_MSG, 0,
       '...so EXEC sends nothing to the GPC');

    // the time fill
    //
    // It is its OWN function, not an unheadered memory fill.  Read out of
    // the built image: every fill in the monitor's bus programs is 0x38c
    // (BCEMF/BCEMF1/BCELMF, the IPL memory blocks; BCEDPLYF; BCEDPY2) or
    // 0x394 (BCEFMATF/BCEFMT2F).  0x380 appears exactly once, in BCETMS,
    // with a count of 7.
    eq(DEU.FUNC.TIME_FILL, 0x380, 'the time fill has its own function code');
    eq(DEU.encodeCommand(DEU.FUNC.TIME_FILL, 7), 0x570007,
       "...and BCETMS's own command word");

    // POLLCON's buffer: mission time, event time, conversion word.  The two
    // times are 48-bit IBM extended floats holding SECONDS -- POLL105 keeps
    // the clock as a double and adds half a second per poll.
    const zero = DEU.parseTimeFill([0x4100, 0, 0, 0x4100, 0, 0, 1]);
    eq(zero.mission, 0, "the monitor's initial X'41000000' reads as zero");
    eq(zero.conv, 1, '...with the conversion word carried opaquely');
    eq(DEU.ibmFloat48(0x4110, 0x0000, 0x0000), 1, '1/16 x 16^1 is 1.0');
    eq(DEU.ibmFloat48(0x4220, 0x0000, 0x0000), 32, 'and 2/16 x 16^2 is 32');
    for (const secs of [0, 1, 0.5, 59, 86399, 86400, 1234567, 31536000]) {
        const w = DEU.encodeIbmFloat48(secs);
        eq(DEU.ibmFloat48(w[0], w[1], w[2]), secs, `${secs}s round trips`);
    }
    const tf = DEU.timeFillWords({mission: 3661, event: 12, conv: 1});
    eq(tf.length, DEU.TIME_FILL_WORDS, 'a time fill is seven halfwords');
    const rt = DEU.parseTimeFill(tf);
    eq(rt.mission, 3661, '...mission time survives');
    eq(rt.event, 12, '...and event time');

    // The unit routes it by COMMAND and keeps it out of display memory.
    const ut = mkUnit();
    let heardTime = null;
    ut.onTime = (t) => { heardTime = t; };
    ut.onCommand(DEU.encodeCommand(DEU.FUNC.TIME_FILL, DEU.TIME_FILL_WORDS));
    for (const w of tf) ut.onData(w);
    eq(ut.stats.timeFills, 1, 'the unit counts a time fill');
    eq(ut.stats.headerless, 0, '...and does NOT take the header-less path');
    eq(heardTime?.mission, 3661, '...and reports the decoded seconds');
    eq(ut.mem[DEU.ADDR.VAR_DATA_HDR], 0,
       '...leaving display memory alone -- the GPC fills that region itself');

    // Header flags.
    const ph = DEU.pollResponse({header: DEU.HDR.IPL_REQUIRED | DEU.HDR.ACK});
    eq(ph[0] & DEU.HDR.IPL_REQUIRED, DEU.HDR.IPL_REQUIRED, 'IPL required');
    eq(ph[0] & DEU.HDR.ACK, DEU.HDR.ACK, 'the ACK key');
    eq(ph[0] & DEU.HDR.KYBD_MSG, 0, 'no keyboard message');
    // The major function switch is a two-bit field, not a flag.
    const pm = DEU.pollResponse({header: 2 << DEU.MAJOR_FUNC_SHIFT});
    eq((pm[0] & DEU.HDR.MAJOR_FUNC) >> DEU.MAJOR_FUNC_SHIFT, 2, 'the major function');

    // BITE status is five halfwords and closes the same way.
    const b = DEU.biteResponse({});
    eq(b.length, 5, 'a BITE response is 5 halfwords');
    eq(DEU.BITE_WORDS, 5, '...which is what the bus program asks for');
    let sb = 0;
    for (const w of b) sb = (sb + w) & 0xffff;
    eq(sb, 0, 'its checksum closes too');

    // A fault the unit reports rather than hides.
    const pf = DEU.pollResponse({bite1: DEU.BITE1.ALWAYS_ONE | DEU.BITE1.IPL_ERROR});
    eq(pf[12] & DEU.BITE1.IPL_DONE, 0, 'a failed IPL does not claim to have loaded');
    ok(pf[12] !== 0, '...but still answers, so it reads as a fault not a silence');

    // over a real bus
    //
    // The wire framing is the one the interface adapter uses: a command is
    // two halfwords with the 24 command bits left justified, a data word is
    // one halfword on its own, and the two are told apart by length.
    const bus = new B.Bus('DK1', B.busConfig['DK1']);
    const heard = [];
    bus.onReceive((_, id, msg) => {
        const w = [];
        for (let i = 0; i < msg.data16.length; i++) w.push(msg.data16[i]);
        heard.push(w);
    }, null);
    await settle(200);                 // let the socket join the group

    const sendCmd = (c24) => bus.sendMsg(B.BusMsg.Command(c24));
    // A second endpoint, so the loopback suppression does not eat our own.
    const peer = new B.Bus('DK1', B.busConfig['DK1']);
    await settle(200);
    const sendFromPeer = (c24) => peer.sendMsg(B.BusMsg.Command(c24));
    sendFromPeer(DEU.encodeCommand(DEU.FUNC.DISPLAY_FILL, 5));
    for (const w of DEU.fillHeader(0x19ee, 3).concat([0xaaaa, 0xbbbb, 0xcccc])) {
        const m = new B.BusMsg(1);
        m.data16[0] = w;
        peer.sendMsg(m);
    }
    await settle(300);

    ok(heard.length >= 6, `the whole transaction arrived (${heard.length} datagrams)`);
    eq(heard[0].length, 2, 'the command is two halfwords');
    const got = DEU.decodeCommand(((heard[0][0] & 0xffff) << 8) | ((heard[0][1] >> 8) & 0xff));
    eq(got.iua, DEU.IUA, 'the address survived the wire');
    eq(got.name, 'DISPLAY_FILL', 'the function survived the wire');
    eq(got.count, 5, 'the count survived the wire');
    const data = heard.slice(1, 6);
    ok(data.every((d) => d.length === 1), 'every data word is its own datagram');
    const body = data.map((d) => d[0]);
    const rf = DEU.parseFill(body);
    eq(rf.addr, 0x19ee, 'the fill address survived the wire');
    eq(rf.payload.join(','), '43690,48059,52428', 'the payload survived the wire');
    // Quieten these two for the rest of the run: the bus logs a datagram
    // nobody claimed, and the section below puts plenty on this port.
    peer.onReceive((() => {}), null);
    bus.onReceive((() => {}), null);

    // a real GPC polling a real display unit
    //
    // The whole path at once: a bus control element running the poll program
    // the flight software runs, on the bus its display unit listens to, with
    // the unit answering out of `deuProto`.  The poll is a time fill out
    // then sixteen halfwords in.
    //
    // This is what "no DEU poll response" was: the two halves of a #MOUT /
    // #MIN -- the transfer word and the companion word that carries the
    // command -- were separate table entries, so the command was never
    // transmitted and the unit had nothing to answer.
    const { AP101 } = await bundle('gpc/ap101.coffee');
    const { IOP_SLICE_NS } = await bundle('gpc/cpu.coffee');
    const gpc = new AP101({machine: 'ap101s'});
    for (let a = 0; a < 0x2000; a++) gpc.cpu.mainStorage.setStoreProtect(a, false);
    const iop = gpc.iop;
    const BCE = 6;                                  // BCE 6 owns DK1
    const poke = (a, v) => gpc.cpu.mainStorage.set16(a, v, false);

    iop.recvFromCPU(0x84400000, 0);                 // master reset
    const bit6 = (0x80000000 >>> BCE) >>> 0;        // just this one processor
    iop.recvFromCPU(0x87200000, bit6);              // enable it
    iop.recvFromCPU(0x85040000, bit6);              // MIA transmitter on
    iop.regBusyWait.set32(bit6);                    // ...and busy
    iop.ls.at(BCE, 0, 2).set32(0x400);              // the program counter
    iop.ls.at(BCE, 1, 3).set32(0x3ffff);            // a long maximum time out
    iop.ls.at(BCE, 2, 3).set32(0x1000);             // BASE = the buffers

    // The poll: seven halfwords of time data out under a memory fill, then
    // sixteen halfwords in under a mode status request.
    poke(0x400, 0xf500); poke(0x401, 6);            // #MOUT 0,6
    poke(0x402, 0x0057); poke(0x403, 0x0007);       // #MOUTC 10, memory fill 7
    poke(0x404, 0xf100); poke(0x405, 15);           // #MIN 0,15
    poke(0x406, 0x0050); poke(0x407, 0x2000);       // #MINC 10, poll
    poke(0x408, 0x0800);                            // #WAT
    for (let i = 0; i < 7; i++) poke(0x1000 + i, 0x1100 + i);   // the time data

    // The display unit: decode, and answer a poll the way an IDP does.
    const unit = new B.Bus('DK1', B.busConfig['DK1']);
    const seen = {cmds: [], data: []};
    const expectedPoll = DEU.pollResponse({header: DEU.HDR.KYBD_MSG, keys: [0x41]});
    unit.onReceive((_, id, msg) => {
        if (msg.cmd) {
            const c = DEU.decodeCommand(((msg.data16[0] & 0xffff) << 8) |
                                        ((msg.data16[1] >> 8) & 0xff));
            if (c.iua !== DEU.IUA) return;
            seen.cmds.push(c);
            if (c.func !== DEU.FUNC.POLL) return;
            const m = new B.BusMsg(expectedPoll.length);
            for (let i = 0; i < expectedPoll.length; i++) m.data16[i] = expectedPoll[i];
            unit.sendMsg(m);
        } else {
            for (let i = 0; i < msg.data16.length; i++) seen.data.push(msg.data16[i]);
        }
    }, null);
    await settle(250);

    // Each IOP slice advances simulated time; it stands still between bursts
    // while the host delivers datagrams.
    for (let burst = 0; burst < 12; burst++) {
        for (let i = 0; i < 400; i++) {
            gpc.cpu.timeNs += IOP_SLICE_NS;
            iop.exec();
        }
        await settle(60);
    }

    eq(seen.cmds.length, 2, 'the GPC issued both commands');
    eq(seen.cmds[0]?.name, 'TIME_FILL', 'first the time fill');
    eq(seen.cmds[0]?.count, 7, '...of seven halfwords');
    eq(seen.cmds[1]?.name, 'POLL', 'then the poll');
    eq(seen.data.length, 7, 'and it sent seven data words');
    eq(seen.data[0], 0x1100, '...from its own buffer');
    eq(seen.data[6], 0x1106, '...all of them');

    // The response landed in main storage, in order, and closes.
    const receivedPoll = Array.from({length: DEU.POLL_WORDS},
        (_, index) => gpc.cpu.mainStorage.get16(0x1000 + index));
    eq(receivedPoll.join(','), expectedPoll.join(','),
       'every poll response word reached storage in order');
    let rsum = 0;
    for (let i = 0; i < DEU.POLL_WORDS; i++)
        rsum = (rsum + gpc.cpu.mainStorage.get16(0x1000 + i)) & 0xffff;
    eq(rsum, 0, 'the poll response reached storage with its checksum intact');
    eq(gpc.cpu.mainStorage.get16(0x1000) & DEU.HDR.KYBD_MSG, DEU.HDR.KYBD_MSG,
       '...header and all');
    ok(gpc.cpu.mainStorage.get16(0x100c) !== 0,
       '...with a BITE register the poll analyser will not read as silence');
    // Both are four halfwords, so the program reaches its wait at 0x408 and
    // the wait then takes the bus control element out of the busy state.
    ok(iop.ls.at(BCE, 0, 2).get32() >= 0x408,
       'and the bus program stepped past both four-halfword instructions');
    eq(iop.procState(BCE).busy, false, '...and ran on to its wait');

    console.log(`test_meds_deu: ${pass} passed, ${fail} failed`);
    process.exit(fail ? 1 : 0);
}

main().catch((e) => { console.error(e); process.exit(1); });
