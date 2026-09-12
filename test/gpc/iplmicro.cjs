// iplmicro.cjs — the IPL microcode's IOP programs, as asm101 assembled
// and lnk101 located them.
//
// The image in gpc/asm/fakeipl.json is planted at its origin and read back
// as machine words: the MSC program, the two BCE programs, the receive
// sequence, and the three mass memory command tables the loader fills in
// from the record address.
//
// Usage:  node test/gpc/iplmicro.cjs
//
// Exit status is 1 iff any assertion fails.

'use strict';

const path    = require('path');
const os      = require('os');
const fs      = require('fs');
const esbuild = require('esbuild');
const coffeePlugin = require('esbuild-coffeescript');

const SRC = path.resolve(__dirname, '..', '..');

const civetPlugin = {
    name: 'civet',
    setup(build) {
        const { compile } = require('@danielx/civet');
        build.onResolve({ filter: /\.civet\.jsx$/ }, (args) => ({
            path: path.resolve(path.dirname(args.importer), args.path.replace(/\.jsx$/, '')),
        }));
        build.onLoad({ filter: /\.civet$/ }, async (args) => {
            const source = await fs.promises.readFile(args.path, 'utf8');
            return { contents: compile(source, { filename: args.path, js: true }), loader: 'js' };
        });
    },
};

async function bundle(entry) {
    const out = path.join(os.tmpdir(),
        `iplmicro.${path.basename(entry, '.coffee')}.${process.pid}.cjs`);
    await esbuild.build({
        absWorkingDir: SRC,
        entryPoints: [path.join(SRC, 'src', entry)],
        bundle:   true,
        platform: 'node',
        format:   'cjs',
        outfile:  out,
        plugins:  [civetPlugin, coffeePlugin()],
        resolveExtensions: ['.coffee', '.js', '.ts', '.civet', '.json'],
        external: ['electron', 'dgram'],
        logLevel: 'error',
    });
    return require(out);
}

let pass = 0, fail = 0;
function check(label, got, want) {
    if (got === want) { pass++; }
    else { fail++; console.log(`FAIL  ${label}: got ${got}, want ${want}`); }
}
const hex = (v) => '0x' + (v >>> 0).toString(16);

(async () => {
    const { AP101 }     = await bundle('gpc/ap101.coffee');
    const { IPLLoader } = await bundle('gpc/iplloader.coffee');
    const IMAGE = require(path.join(SRC, 'src/gpc/asm/fakeipl.json'));

    const gpc = new AP101({ machine: 'ap101s' });
    const loader = new IPLLoader(gpc);
    const hw = (a) => gpc.ram.get16(a);
    // A fullword read aligns to an even halfword; a long IOP instruction
    // sits wherever the program put it.
    const fw = (a) => (((hw(a) << 16) | hw(a + 1)) >>> 0);

    // MM1 as the IPL source: discrete input A bit 4.
    gpc.iop.regDiscreteInA.set32(0x08000000);
    loader.load();
    const S = IMAGE.symbols;

    // The image lands where it was located, and nowhere else.
    check('origin is below the 18-bit IOP address field',
          IMAGE.origin + IMAGE.length <= 0x40000, true);
    check('the image reaches the last halfword it carries',
          hex(hw(IMAGE.origin + IMAGE.length - 1)),
          hex(parseInt(IMAGE.image[IMAGE.length - 1], 16)));

    // MSC: pick the element from the discretes, then run each bus
    // program -- the element's program counter, start, wait.
    const msc = (n) => S.IPLMSC + n;
    check('@LF the source discretes',
          hex(fw(msc(0))), hex(0xf4000000 | S.IPLSRC));
    check('@BZ neither made',   hex(hw(msc(2)) >>> 8), hex(0x24));
    check('@TI -2',             hex(hw(msc(3))), hex(0xedfe));
    check('@LF MM2\'s element', hex(fw(msc(5))), hex(0xf4000000 | S.IPLM2N));
    check('@LF MM1\'s element', hex(fw(msc(11))), hex(0xf4000000 | S.IPLM1N));
    check('the elements it chooses between', fw(S.IPLM1N), 18);
    check('...and the other',                fw(S.IPLM2N), 19);
    check('their processor masks', hex(fw(S.IPLM1M)), hex(0x00002000));
    check('...and the other',      hex(fw(S.IPLM2M)), hex(0x00001000));
    check('the repeat extension', fw(S.IPLRPTC), 0x3ffff);

    // The bits the loader dumps for it, and nothing more.
    check('the source discretes reach the program', fw(S.IPLSRC), 0b10);
    gpc.iop.regDiscreteInA.set32(0x04000000);
    loader.load();
    check('MM2 selected', fw(S.IPLSRC), 0b01);
    gpc.iop.regDiscreteInA.set32(0);
    loader.load();
    check('neither made is passed through as it stands', fw(S.IPLSRC), 0);

    // Position: settle, read the status registers, move.
    check('#DLYI alignment',  hex(hw(S.IPLPOS)),     hex(0xc000));
    check('#DLYI 1820',       hex(hw(S.IPLPOS + 1)), hex(0xc000 | 1820));
    check('#LBR the status reply',
          hex(fw(S.IPLPOS + 2)), hex(0xf2000000 | S.IPLPSTS));
    check('#CMDI 11,X\'8000\'',
          hex(fw(S.IPLPOS + 4)), hex(0xf6000000 | (11 << 19) | 0x8000));
    check('#RDLI 1',          hex(fw(S.IPLPOS + 6)), hex(0xf3000000 | 1));
    check('#CMD the position table',
          hex(fw(S.IPLPOS + 8)), hex(0xfe000000 | (S.IPLPTCW - 36)));
    check('#WAT',             hex(hw(S.IPLPOS + 10)), hex(0x0800));

    // Read: let the transport position, extend the block count, read,
    // branch to the receive sequence.
    check('#DLYI twice',      hex(hw(S.IPLREAD + 2)), hex(0xc000 | 1820));
    check('#CMD the extend table',
          hex(fw(S.IPLREAD + 3)), hex(0xfe000000 | (S.IPLEBCW - 36)));
    check('#CMD the read table',
          hex(fw(S.IPLREAD + 7)), hex(0xfe000000 | (S.IPLRDCW - 36)));
    check('#BU the receive sequence',
          hex(fw(S.IPLREAD + 9)), hex(0xf0000000 | S.IPLRECV));

    // Receive: one run into sector zero, then store the status.
    check('#LBR sector zero',  hex(fw(S.IPLRECV + 1)), hex(0xf2000000));
    check('#RDLI a sector less one',
          hex(fw(S.IPLRECV + 3)), hex(0xf3000000 | 0x7fff));
    check('#SST is displaced to the status cell',
          hex(hw(S.IPLRECV + 5)),
          hex(0x5000 | ((S.IPLSTAT - (S.IPLRECV + 5 + 1)) & 0x7ff)));
    check('#WAT',              hex(hw(S.IPLRECV + 6)), hex(0x0800));

    // The command words the assembly carries.  Tape 44500: file 4,
    // track 4, subfile 5, block 0, and 64 blocks to a sector.  Position
    // addresses the gap before the data, so it takes subfile 4.
    check('position tape',  hex(fw(S.IPLPTCW)), hex(0x584808));
    check('extend block',   hex(fw(S.IPLEBCW)), hex(0x59803f));
    check('read',           hex(fw(S.IPLRDCW)), hex(0x5cca00));
    // Either element commands the same unit: the bus selects it.
    check('element 19 positions too', hex(fw(S.IPLPTCW + 2)), hex(0x584808));
    check('element 19 extends too',   hex(fw(S.IPLEBCW + 2)), hex(0x59803f));
    check('element 19 reads too',     hex(fw(S.IPLRDCW + 2)), hex(0x5cca00));

    // Both status cells hold -1 until an element stores over them.
    check('the position status starts at -1', hex(fw(S.IPLPSTS)), hex(0xffffffff));
    check('the read status starts at -1',     hex(fw(S.IPLSTAT)), hex(0xffffffff));

    // What the loader leaves in the IOP: both mass memory elements and
    // the MSC enabled, their transmitters and receivers on, and their
    // time outs at the maximum a receive may wait.
    loader.configure();
    const mask = 0x00003000;
    check('both elements and the MSC are enabled',
          hex(gpc.iop.regProcEnable.get32()), hex(mask | 0x80000000));
    check('their transmitters are on', hex(gpc.iop.regXmitEna.get32()), hex(mask));
    check('their receivers are on',    hex(gpc.iop.regRecvEna.get32()), hex(mask));
    check('MM1\'s time out is the maximum', gpc.iop.ls.at(18, 1, 3).get32(), 0x3ffff);
    check('MM2\'s as well',                 gpc.iop.ls.at(19, 1, 3).get32(), 0x3ffff);
    check('IPL RUNNING is asserted',
          hex(gpc.iop.regDiscreteOut.get32()), hex(0x00000001));

    // The prologue chooses, with nothing on the bus to answer: run the
    // MSC far enough to see which element it picked.
    const pick = async (discretes) => {
        const g = new AP101({ machine: 'ap101s' });
        const l = new IPLLoader(g);
        g.iop.regDiscreteInA.set32(discretes);
        l.load();
        l.configure();
        l.setPC(0, S.IPLMSC);
        g.iop.procSet(g.iop.regBusyWait, 0, 1);
        for (let i = 0; i < 4000; i++) l.slice();
        return { bce: g.ram.get32(S.IPLBUSN), mask: g.ram.get32(S.IPLBUSM),
                 running: g.iop.procGet(g.iop.regBusyWait, 0) };
    };
    let p = await pick(0x08000000);
    check('bit 4 runs element 18', p.bce, 18);
    check('...on its mask',        hex(p.mask), hex(0x00002000));
    p = await pick(0x04000000);
    check('bit 5 runs element 19', p.bce, 19);
    check('...on its mask',        hex(p.mask), hex(0x00001000));
    p = await pick(0);
    check('neither made picks nothing', p.bce, 0);
    check('...and the MSC is back in the wait state', p.running, 0);

    // Nothing was read, so the status cell still holds -1 and the loader
    // says so rather than handing over.
    const g = new AP101({ machine: 'ap101s' });
    const l = new IPLLoader(g);
    g.iop.regDiscreteInA.set32(0);
    let said = '';
    try { await l.run(); } catch (e) { said = e.message; }
    check('an IPL with no source fails', said.includes('status 0xffffffff'), true);

    console.log(`\n${pass} passed, ${fail} failed`);
    process.exit(fail ? 1 : 0);
})();
