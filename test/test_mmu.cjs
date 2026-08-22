// test_mmu.cjs — the Mass Memory Unit 
//
// Usage:
//   cd ext/sim && node test/test_mmu.cjs
//
// Exit status is 1 iff any test failed.
'use strict';

const path = require('path');
const os = require('os');
const fs = require('fs');
const esbuild = require('esbuild');
const coffeePlugin = require('esbuild-coffeescript');

const SIM = path.resolve(__dirname, '..');

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

async function bundle(rel) {
    const out = path.join(os.tmpdir(),
        `mmu.test.${path.basename(rel).replace(/\W/g, '_')}.${process.pid}.cjs`);
    await esbuild.build({
        absWorkingDir: SIM,
        entryPoints: [path.join(SIM, rel)],
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

const cmd = (op, operand = 0) => (((11 & 0x1f) << 19) | ((op & 0xf) << 15) | (operand & 0x7fff)) >>> 0;
const posOperand  = (t, s, bof, eof, f) =>
    ((t & 7) << 12) | ((s & 7) << 9) | ((bof ? 1 : 0) << 7) | ((eof ? 1 : 0) << 6) | ((f & 7) << 1);
const xferOperand = (t, s, blk, cnt) =>
    ((t & 7) << 12) | ((s & 7) << 9) | ((blk & 0x1f) << 4) | (cnt & 0xf);

(async () => {
    const C = await bundle('mmu/mmuConf.coffee');
    const V = await bundle('mmu/volume.coffee');
    const M = await bundle('mmu/mmu.coffee');

    // geometry
    //
    section('geometry');
    eq(C.BLOCKS_TOTAL, 8 * 8 * 8 * 32, 'a tape holds 16384 blocks');
    eq(C.BLOCKS_TOTAL * C.HALFWORDS_PER_BLOCK, 8388608,
       'which is 8.4 million halfwords of storage');

    // address algebra
    //
    section('address algebra');
    // Block varies fastest, then subfile, track, file
    eq(C.blockIndex({track: 0, file: 0, subfile: 0, block: 0}), 0, 'first block is index 0');
    eq(C.blockIndex({track: 0, file: 0, subfile: 1, block: 0}), 32, 'a subfile is 32 blocks');
    eq(C.blockIndex({track: 1, file: 0, subfile: 0, block: 0}), 256,
       'a file/track pair is 8 subfiles');
    eq(C.blockIndex({track: 0, file: 1, subfile: 0, block: 0}), 2048,
       'a file is that on all 8 tracks');
    for (const a of [{track: 5, file: 2, subfile: 6, block: 17},
                     {track: 0, file: 0, subfile: 0, block: 0},
                     {track: 7, file: 7, subfile: 7, block: 31}]) {
        eq(C.blockIndex(a), C.packTapeAddr(a),
           `${C.fmtAddr(a)} indexes the block its tape address names`);
    }
    for (const idx of [0, 1, 31, 32, 255, 256, 2047, 2048, 16383]) {
        eq(C.blockIndex(C.blockAddr(idx)), idx, `index ${idx} round trips through an address`);
    }

    const a = {track: 5, file: 2, subfile: 6, block: 17};
    const sameAddr = (x, y) => x.track === y.track && x.file === y.file &&
                               x.subfile === y.subfile && x.block === y.block;
    ok(sameAddr(C.unpackTapeAddr(C.packTapeAddr(a)), a), 'tape address halfword round trips');
    eq(C.packTapeAddr({track: 0, file: 7, subfile: 0, block: 0}) >> 11, 7,
       'file sits in bits 2-4 of a tape address');
    eq((C.packTapeAddr({track: 7, file: 0, subfile: 0, block: 0}) >> 8) & 7, 7,
       'track sits in bits 5-7 of a tape address');

    const p = {track: 5, file: 2, subfile: 6, bof: 0, eof: 1};
    const samePos = (x, y) => x.track === y.track && x.file === y.file &&
                              x.subfile === y.subfile && !!x.bof === !!y.bof && !!x.eof === !!y.eof;
    ok(samePos(C.unpackPosition(C.packPosition(p)), p), 'position word round trips');
    eq(C.packPosition({track: 7, file: 0, subfile: 0}) >> 11, 7,
       'track sits in bits 2-4 of a position');
    eq((C.packPosition({track: 0, file: 7, subfile: 0}) >> 8) & 7, 7,
       'file sits in bits 5-7 of a position');
    eq(C.packPosition({track: 0, file: 0, subfile: 0, bof: 1}), 0x0010, 'beginning of file is bit 11');
    eq(C.packPosition({track: 0, file: 0, subfile: 0, eof: 1}), 0x0008, 'end of file is bit 12');

    eq(C.parseAddr('3/1/4/9'), {track: 3, file: 1, subfile: 4, block: 9},
       'track/file/subfile/block parses');
    ok(sameAddr(C.parseAddr('0x' + C.packTapeAddr(a).toString(16)), a),
       'a bare number parses as a tape address');
    ok(C.parseAddr('8/0/0/0') === null, 'track 8 is rejected');
    ok(C.parseAddr('nonsense') === null, 'nonsense is rejected');

    // checksum
    //
    section('record checksum');
    const rec = new Uint16Array(C.HALFWORDS_PER_BLOCK);
    for (let i = 0; i < rec.length - 1; i++) rec[i] = (i * 7 + 1) & 0xffff;
    rec[rec.length - 1] = C.checksum(rec, 0, rec.length - 1);
    eq(C.checksum(rec, 0, rec.length - 1), rec[rec.length - 1],
       'the last halfword is the sum of the others');
    eq(C.checksum(new Uint16Array(512), 0, 511), 0,
       'a blank block checksums to zero, which is its own last halfword');

    // command decode
    //
    section('command decode');
    let c = C.decodeCommand(cmd(C.OP.POSITION, posOperand(4, 2, 0, 0, 4)));
    eq({iua: c.iua, op: c.opcode, track: c.track, subfile: c.subfile, file: c.file,
        bof: c.bof, eof: c.eof},
       {iua: 11, op: 0, track: 4, subfile: 2, file: 4, bof: 0, eof: 0},
       'a position command decodes track, subfile and file');
    c = C.decodeCommand(cmd(C.OP.POSITION, posOperand(0, 0, 1, 1, 0)));
    eq([c.bof, c.eof], [1, 1], 'the position command carries the file end flags');

    c = C.decodeCommand(cmd(C.OP.READ, xferOperand(4, 3, 8, 15)));
    eq({op: c.opcode, track: c.track, subfile: c.subfile, block: c.block, count: c.count},
       {op: 9, track: 4, subfile: 3, block: 8, count: 15},
       'a read command decodes track, subfile, block and count');
    ok(c.file === undefined, 'a transfer command carries no file');

    c = C.decodeCommand(cmd(C.OP.EXTENDED_BLOCK, 200));
    eq(c.count, 200, 'the extended block count is eight bits wide');

    eq(C.decodeCommand((7 << 19) | (1 << 15)).iua, 7, 'a command for another IUA decodes as such');

    // volume
    //
    section('tape volume');
    const vol = new V.Volume();
    ok(!vol.has(a), 'a fresh volume holds nothing');
    eq(Array.from(vol.read(a)).reduce((s, x) => s + x, 0), 0, 'and reads back as zeros');
    vol.write(a, rec);
    ok(vol.has(a), 'a written block is there');
    eq(Array.from(vol.read(a)), Array.from(rec), 'and reads back what was written');
    eq(vol.count(), 1, 'one block stored');

    // A short write is zero filled: the transport always lays a whole block.
    vol.write({track: 0, file: 0, subfile: 0, block: 0}, new Uint16Array([1, 2, 3]));
    eq(vol.read({track: 0, file: 0, subfile: 0, block: 0}).length, C.HALFWORDS_PER_BLOCK,
       'a short write still occupies a whole block');
    eq(Array.from(vol.read({track: 0, file: 0, subfile: 0, block: 0}).slice(0, 4)), [1, 2, 3, 0],
       'and is zero filled');

    // A stream spanning several blocks.
    const stream = new Uint16Array(C.HALFWORDS_PER_BLOCK * 2 + 5);
    for (let i = 0; i < stream.length; i++) stream[i] = (i ^ 0x5a5a) & 0xffff;
    eq(vol.writeStream({track: 1, file: 0, subfile: 0, block: 0}, stream), 3,
       'a 2.01 block stream lays down 3 blocks');
    eq(vol.read({track: 1, file: 0, subfile: 0, block: 2})[4], stream[2 * 512 + 4],
       'and the tail lands in the third');

    const volPath = path.join(os.tmpdir(), `mmu.test.${process.pid}.mmv`);
    vol.save(volPath);
    const back = V.Volume.load(volPath);
    eq(back.count(), vol.count(), 'a saved volume reloads with the same block count');
    eq(Array.from(back.read(a)), Array.from(rec), 'and the same contents');
    eq(back.entries().map((e) => e.index), vol.entries().map((e) => e.index),
       'and the same directory, in tape order');
    fs.unlinkSync(volPath);

    const wp = new V.Volume({writeProtect: true});
    let threw = false;
    try { wp.write(a, rec); } catch (e) { threw = true; }
    ok(threw, 'a write protected volume refuses a write');

    // the device on a bus
    //
    section('device on the bus');

    // Answers come back over the multicast bus, so the test listens the
    // way a GPC's MIA does: every halfword of every datagram, in order.
    const B = await bundle('com/bus.civet');
    const heard = [];
    const listener = new B.Bus('MM1', B.busConfig['MM1']);
    listener.onReceive((_, id, msg) => {
        for (let i = 0; i < msg.data16.length; i++) heard.push(msg.data16[i]);
    }, null);

    const tape = new V.Volume();
    tape.write({track: 4, file: 4, subfile: 3, block: 8}, rec);
    const mmu = new M.MMU({unit: 1, volume: tape, blockDelayMs: 0});

    const send = (c24) => {
        const m = new B.BusMsg(2);
        m.data16[0] = (c24 >>> 8) & 0xffff;
        m.data16[1] = (c24 & 0xff) << 8;
        listener.sendMsg(m);
    };
    const settle = (msec = 120) => new Promise((r) => setTimeout(r, msec));

    await settle(200);          // let the sockets join the group
    heard.length = 0;

    send(cmd(C.OP.BITE_STATUS));
    await settle();
    eq(heard.splice(0), [0, 0], 'a healthy unit reports both status registers clear');

    send(cmd(C.OP.POSITION, posOperand(4, 2, 0, 0, 4)));
    await settle();
    eq(heard.splice(0), [], 'a position command is answered with silence');
    send(cmd(C.OP.POSITION_REQ));
    await settle();
    ok(samePos(C.unpackPosition(heard.splice(0)[0]), {track: 4, file: 4, subfile: 2, bof: 0, eof: 0}),
       'and the transport reports where it was sent');

    // A read of one block, from where the tape actually has data.
    send(cmd(C.OP.READ, xferOperand(4, 3, 8, 0)));
    await settle();
    const block = heard.splice(0);
    eq(block.length, C.HALFWORDS_PER_BLOCK, 'a one block read sends 512 halfwords');
    eq(Array.from(block), Array.from(rec), 'and they are what is on the tape');

    send(cmd(C.OP.POSITION_REQ));
    await settle();
    ok(samePos(C.unpackPosition(heard.splice(0)[0]), {track: 4, file: 4, subfile: 4, bof: 0, eof: 0}),
       'a read leaves the head in the gap AFTER the blocks it read');

    // The block count is a count LESS ONE, and an extended block count
    // command overrides the four bits in the transfer command.
    send(cmd(C.OP.POSITION, posOperand(4, 2, 0, 0, 4)));
    send(cmd(C.OP.EXTENDED_BLOCK, 16));
    send(cmd(C.OP.READ, xferOperand(4, 3, 8, 15)));
    await settle(300);
    eq(heard.splice(0).length, 17 * C.HALFWORDS_PER_BLOCK,
       'an extended block count of 16 reads 17 blocks');
    send(cmd(C.OP.POSITION_REQ));
    await settle();
    ok(samePos(C.unpackPosition(heard.splice(0)[0]), {track: 4, file: 4, subfile: 4, bof: 0, eof: 0}),
       'blocks 8 through 24 of subfile 3 still end in the gap before subfile 4');

    // Running off the end of subfile 7 is an end-of-file block count error,
    // and the read is cut short rather than wrapping into the next file.
    send(cmd(C.OP.POSITION, posOperand(0, 6, 0, 0, 0)));
    send(cmd(C.OP.READ, xferOperand(0, 7, 30, 8)));
    await settle(200);
    eq(heard.splice(0).length, 2 * C.HALFWORDS_PER_BLOCK,
       'a read past the end of the file stops at the file boundary');
    send(cmd(C.OP.BITE_STATUS));
    await settle();
    const st = heard.splice(0);
    ok((st[1] & C.STAT_B.EOF_BLOCK_COUNT) !== 0, 'and reports an end of file block count error');
    send(cmd(C.OP.BITE_STATUS));
    await settle();
    eq(heard.splice(0), [0, 0], 'reading the status clears it');

    // An unknown opcode is a command error, and a command for another IUA
    // is not ours to complain about.
    send(cmd(0x7));
    send((7 << 19) | (0x7 << 15));
    await settle();
    heard.length = 0;
    send(cmd(C.OP.BITE_STATUS));
    await settle();
    const st2 = heard.splice(0);
    ok((st2[0] & C.STAT_A.INVALID_COMMAND) !== 0, 'an unknown opcode is an invalid command');

    // A write needs the track armed first.
    send(cmd(C.OP.POSITION, posOperand(2, 0, 0, 0, 1)));
    send(cmd(C.OP.WRITE, xferOperand(2, 0, 0, 0)));
    await settle();
    heard.length = 0;
    send(cmd(C.OP.BITE_STATUS));
    await settle();
    ok((heard.splice(0)[0] & C.STAT_A.WRITE_PROTECT) !== 0,
       'a write to a track that is not enabled is refused');

    heard.length = 0;
    send(cmd(C.OP.WRITE_ENABLE, (2 & 7) << 12));
    send(cmd(C.OP.WRITE, xferOperand(2, 0, 0, 0)));
    await settle();
    ok(heard.length >= 1, 'an enabled write answers with a search complete word');
    heard.length = 0;
    for (let i = 0; i < C.HALFWORDS_PER_BLOCK; i++) {
        const m = new B.BusMsg(1);
        m.data16[0] = rec[i];
        listener.sendMsg(m);
    }
    await settle(300);
    ok(tape.has({track: 2, file: 1, subfile: 0, block: 0}), 'and the block reaches the tape');
    eq(Array.from(tape.read({track: 2, file: 1, subfile: 0, block: 0})), Array.from(rec),
       'with the halfwords the GPC sent');

    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
