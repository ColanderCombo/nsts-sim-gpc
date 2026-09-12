
'use strict';

const path    = require('path');
const os      = require('os');
const fs      = require('fs');
const esbuild = require('esbuild');
const coffeePlugin = require('esbuild-coffeescript');

const SRC = path.resolve(__dirname, '..', '..');

async function bundle(entry) {
    const out = path.join(os.tmpdir(),
        `sdl.${path.basename(entry, '.coffee')}.${process.pid}.cjs`);
    await esbuild.build({
        absWorkingDir: SRC,
        entryPoints: [path.join(SRC, 'src', 'gpc', entry)],
        bundle:   true,
        platform: 'node',
        format:   'cjs',
        outfile:  out,
        plugins:  [coffeePlugin()],
        resolveExtensions: ['.coffee', '.js', '.json'],
        external: ['electron', 'dgram'],
        logLevel: 'error',
    });
    return require(out);
}

let pass = 0, fail = 0;
function check(label, got, want) {
    if (got === want) { pass++; }
    else { fail++; console.log(`FAIL  ${label}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`); }
}
function ok(label, cond, why) {
    if (cond) { pass++; }
    else { fail++; console.log(`FAIL  ${label}${why ? `: ${why}` : ''}`); }
}

const DATA = 0x1000;                   // #DTSTU
const CODE = 0x2000;                   // $0TSTU

const INDEX = {
    tool: 'sdlindex', format: 1, config: 'TEST',
    phases: ['PHASE02', 'PHASE06'],
    units: [['TSTU', 'TEST_UNIT', 'PROGRAM', 'PHASE02']],
    blocks: [[CODE, 0x40, '$0TSTU', 'PROGRAM', 'TEST_UNIT', 0]],
    tmpl: [['PAIR_STR', 0, 2, 2, [
        [0, 'FIRST',  'I', 1, 1, 1, 0, 0, 0, -1, []],
        [1, 'SECOND', 'I', 1, 1, 1, 0, 0, 0, -1, []],
    ]]],
    csects: [['#DTSTU', DATA, 0x40, 0, [
        [0x00, 'AN_INT',    'I',   1, 1, 1, 0,      0, 0, -1, []],
        [0x01, 'A_DINT',    'ID',  1, 2, 2, 0,      0, 0, -1, []],
        [0x03, 'A_SCALAR',  'S',   1, 2, 2, 0,      0, 0, -1, []],
        [0x05, 'A_DSCALAR', 'SD',  1, 4, 4, 0,      0, 0, -1, []],
        [0x09, 'A_BIT',     'B',   1, 1, 1, 0x0408, 4, 0, -1, []],
        [0x0a, 'A_CHAR',    'C',   1, 3, 3, 0x0004, 0, 0, -1, []],
        [0x0d, 'AN_EVENT',  'E',   1, 1, 1, 0,      0, 0, -1, []],
        [0x0e, 'A_VECTOR',  'V',   1, 6, 6, 0x0103, 0, 0, -1, []],
        [0x14, 'AN_ARRAY',  'I',   4, 1, 4, 0,      0, 0, -1, [4]],
        [0x18, 'A_STRUCT',  'STR', 2, 2, 4, 0,      0, 0,  0, [2]],
        [0x1c, 'A_NAME',    'I',   1, 1, 1, 0,      0, 1, -1, []],
        [0x1d, 'A_CONST',   'I',   1, 1, 1, 0,      0, 2, -1, []],
    ]]],
    stmts: [[0, [[10, CODE + 0x00, 'AA0010'], [11, CODE + 0x08, 'AA0011']]]],
};

const MEM = new Map();
function put(addr, ...hws) { hws.forEach((h, i) => MEM.set(addr + i, h)); }
put(DATA + 0x00, 0xfffe);                       // AN_INT     -2
put(DATA + 0x01, 0x0001, 0x0000);               // A_DINT     65536
put(DATA + 0x03, 0x4110, 0x0000);               // A_SCALAR   1.0
put(DATA + 0x05, 0xc120, 0x0000, 0, 0);         // A_DSCALAR  -2.0
put(DATA + 0x09, 0x0af0);                       // A_BIT      (>>4) & 0xff
put(DATA + 0x0a, 0x0304, 0x4142, 0x4300);       // A_CHAR     'ABC', max 4
put(DATA + 0x0d, 0x0001);                       // AN_EVENT   TRUE
put(DATA + 0x0e, 0x4110, 0, 0x4120, 0, 0x4130, 0);   // A_VECTOR  1,2,3
put(DATA + 0x14, 7, 8, 9, 10);                  // AN_ARRAY
put(DATA + 0x18, 1, 2, 3, 4);                   // A_STRUCT, two copies
put(DATA + 0x1c, 0x1234);                       // A_NAME
put(DATA + 0x1d, 42);                           // A_CONST
const readHw = (a) => MEM.get(a) ?? 0;

const IMG_HW = 64;
const P2 = [0, 16], P13 = [16, 24], P6 = [24, 32], DATA_RUN = [32, IMG_HW];

function image(withP6) {
    const buf = Buffer.alloc(IMG_HW * 2);
    for (let a = 0; a < IMG_HW; a++) buf.writeUInt16BE(0xc6c6, a * 2);
    for (let a = P2[0]; a < P2[1]; a++)  buf.writeUInt16BE(0x2000 + a, a * 2);
    for (let a = P13[0]; a < P13[1]; a++) buf.writeUInt16BE(0x1300 + a, a * 2);
    if (withP6) for (let a = P6[0]; a < P6[1]; a++) buf.writeUInt16BE(0x0600 + a, a * 2);
    for (let a = DATA_RUN[0]; a < DATA_RUN[1]; a++) buf.writeUInt16BE(0xdada, a * 2);
    return buf;
}

const PROTECT = { unit: 'halfword', ranges: [[0, DATA_RUN[0]]] };

function manifest(config, phases, mcfPhases, runs) {
    return {
        version: 'test', imageSize: IMG_HW, entryPoint: 0,
        sections: [], symbols: [], relocations: [],
        storeProtect: PROTECT,
        ownerPhaseRunsHW: runs,
        repro: { tool: 'mmu2fcm', config, phases, mcfPhases },
    };
}

function writeConfigs(root) {
    const base = [[P2[0], 2], [P13[0], 13], [P6[0], 0], [DATA_RUN[0], 0]];
    const wide = [[P2[0], 2], [P13[0], 13], [P6[0], 6], [DATA_RUN[0], 0]];
    for (const [name, withP6, mcf, runs] of [
        ['BASE', false, [2, 13], base],
        ['WIDE', true,  [2, 6, 13], wide]]) {
        const dir = path.join(root, name);
        fs.mkdirSync(dir, { recursive: true });
        fs.writeFileSync(path.join(dir, `${name}.fcm`), image(withP6));
        fs.writeFileSync(path.join(dir, `${name}.sym.json`),
            JSON.stringify(manifest(name, ['PHASE02', 'PHASE13'], mcf, runs)));
    }
}

(async () => {
    const { SdlIndex } = await bundle('dbg/sym/sdl.coffee');
    const { ConfigDetector, inRanges } = await bundle('dbg/fcos/configdetect.coffee');

    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'sdltest-'));
    const idxPath = path.join(tmp, 'TEST.sdl.json');
    fs.writeFileSync(idxPath, JSON.stringify(INDEX));
    const sdl = SdlIndex.load(idxPath);

    check('an index knows its config',   sdl.config, 'TEST');
    check('a name resolves',             sdl.addressOf('AN_INT'), DATA);
    check('lower case resolves too',     sdl.addressOf('an_int'), DATA);
    check('a block name resolves',       sdl.addressOf('TEST_UNIT'), CODE);
    check('a csect qualifier resolves',  sdl.addressOf('#DTSTU.AN_INT'), DATA);
    check('a unit qualifier resolves',   sdl.addressOf('TSTU.AN_INT'), DATA);
    check('a HAL unit name qualifies',   sdl.addressOf('TEST_UNIT.AN_INT'), DATA);
    check('an unknown qualifier does not',
          sdl.lookup('OTHER.AN_INT').length, 0);
    check('an unknown name resolves to nothing',
          sdl.addressOf('NOSUCHTHING'), null);

    check('search finds a variable',
          sdl.search('ARRAY').map((h) => h.name).join(','), 'AN_ARRAY');
    check('search finds a block first',
          sdl.search('TEST_UNIT')[0].what, 'block');
    check('units search finds the unit',
          sdl.searchUnits('TST').map((u) => u.name).join(','), 'TEST_UNIT');

    const decl = (n) => sdl.describe(sdl.lookup(n)[0]).type;
    check('INTEGER',        decl('AN_INT'),    'INTEGER');
    check('INTEGER DOUBLE', decl('A_DINT'),    'INTEGER DOUBLE');
    check('SCALAR DOUBLE',  decl('A_DSCALAR'), 'SCALAR DOUBLE');
    check('BIT carries its width',     decl('A_BIT'),  'BIT(8)');
    check('CHARACTER carries its max', decl('A_CHAR'), 'CHARACTER(4)');
    check('VECTOR carries its length', decl('A_VECTOR'), 'VECTOR(3)');
    check('an array says so',   decl('AN_ARRAY'), 'INTEGER ARRAY(4)');
    check('a structure names its template',
          decl('A_STRUCT'), 'PAIR_STR-STRUCTURE ARRAY(2)');
    check('a NAME says so',     decl('A_NAME'),  'NAME INTEGER');
    check('a CONSTANT says so', decl('A_CONST'), 'INTEGER CONSTANT');

    const val = (n, opts) => sdl.read(sdl.lookup(n)[0], readHw, opts || {});
    check('a negative INTEGER',   val('AN_INT').values[0].value, -2);
    check('an INTEGER DOUBLE',    val('A_DINT').values[0].value, 65536);
    check('an IBM single scalar', val('A_SCALAR').values[0].value, 1.0);
    check('an IBM double scalar', val('A_DSCALAR').values[0].value, -2.0);
    check('a shifted BIT field',  val('A_BIT').values[0].text, "BIN'10101111'");
    check('ASCII characters',     val('A_CHAR').values[0].text, "'ABC'");
    check('EBCDIC on request',
          val('A_CHAR', { encoding: 'ebcdic' }).values[0].text, "'...'");
    check('an EVENT',             val('AN_EVENT').values[0].text, 'TRUE');
    check('a VECTOR decodes each component',
          val('A_VECTOR').values[0].components.join(','), '1,2,3');
    check('an array decodes every element',
          val('AN_ARRAY').values.map((v) => v.value).join(','), '7,8,9,10');
    check('an array element is addressed',
          val('AN_ARRAY').values[3].addr, DATA + 0x17);
    check('a NAME reads its pointer', val('A_NAME').text, '1234');

    const st = val('A_STRUCT');
    check('a structure walks its copies', st.copies.length, 2);
    check('copy 1 field 1', st.copies[0].fields[0].values[0].value, 1);
    check('copy 2 field 2', st.copies[1].fields[1].values[0].value, 4);
    check('a copy is at its stride', st.copies[1].addr, DATA + 0x1a);

    check('a limit caps the elements read',
          val('AN_ARRAY', { limit: 2 }).values.length, 2);
    ok('and says it was capped', val('AN_ARRAY', { limit: 2 }).truncated);

    check('an address inside an array names it',
          sdl.varAt(DATA + 0x16).row[1], 'AN_ARRAY');
    check('an address past every variable names none',
          sdl.varAt(DATA + 0x3f), null);
    check('an address in the code names its block',
          sdl.blockAt(CODE + 4).name, 'TEST_UNIT');
    check('an address outside it names none', sdl.blockAt(CODE - 1), null);
    check('a statement is the last one at or before the address',
          sdl.stmtAt(CODE + 4).stmt, 10);
    check('and carries its SRN', sdl.stmtAt(CODE + 0x0a).srn, 'AA0011');

    ok('inRanges finds a protected halfword', inRanges(PROTECT.ranges, 0));
    ok('and rejects one past the end',
       !inRanges(PROTECT.ranges, DATA_RUN[0]));

    const root = path.join(tmp, 'oi');
    writeConfigs(root);
    const det = new ConfigDetector(root);
    check('both configurations are candidates', det.candidates().length, 2);

    const churned = image(false);
    for (let a = DATA_RUN[0]; a < DATA_RUN[1]; a++)
        churned.writeUInt16BE(0x5555, a * 2);
    let fp = det.fingerprint((a) => churned.readUInt16BE(a * 2));
    const res = {};
    fp.residency.forEach((r) => { res[r.phase] = r.score; });
    check('phase 2 is resident',   res[2], 1);
    check('phase 13 is resident',  res[13], 1);
    check('phase 6 is not',        res[6], 0);
    check('rewritten data is not probed',
          fp.residency.some((r) => r.phase === 0), false);
    check('the base configuration is chosen',
          det.choose(fp.configs, 0.9).config, 'BASE');

    fp = det.fingerprint((a) => image(true).readUInt16BE(a * 2));
    check('both hold', fp.configs.filter((c) => c.score === 1).length, 2);
    check('the deeper configuration is chosen',
          det.choose(fp.configs, 0.9).config, 'WIDE');

    const partial = image(true);
    for (let a = P6[0] + 4; a < P6[1]; a++) partial.writeUInt16BE(0xc6c6, a * 2);
    fp = det.fingerprint((a) => partial.readUInt16BE(a * 2));
    const p6 = fp.residency.find((r) => r.phase === 6);
    ok('a part-loaded phase reads between 0 and 1',
       p6.score > 0 && p6.score < 1, `${p6.score}`);
    check('and its configuration is not chosen',
          det.choose(fp.configs, 0.9).config, 'BASE');

    const FCOS = JSON.parse(JSON.stringify(INDEX));
    FCOS.tmpl.push(['GRT_STR', 0, 2, 2, [
        [0, 'CZ2V_GRT_MC_PHASES', 'I', 2, 1, 2, 0, 0, 0, -1, [2]]]]);
    FCOS.csects[0][4].push(
        [0x20, 'CDJV_SELF_RESIDENT_MC', 'I', 1, 1, 1, 0, 0, 0, -1, []],
        [0x21, 'CZ2V_GRT_PHASES', 'STR', 2, 2, 4, 0, 0, 0,  1, [2]],
        [0x25, 'CZ2V_OPS_MC',     'I',   1, 1, 1, 0, 0, 0, -1, []]);
    const fcosPath = path.join(tmp, 'FCOS.sdl.json');
    fs.writeFileSync(fcosPath, JSON.stringify(FCOS));
    const fsdl = SdlIndex.load(fcosPath);

    put(DATA + 0x20, 0);                        // not moded yet
    put(DATA + 0x25, 0);
    put(DATA + 0x21, 2, 13, 6, 13);             // MC 1 = (2,13), MC 2 = (6,13)
    check('an unmoded machine reports MC 0',
          det.fromFcos(fsdl, readHw).mc, 0);
    check('and names no configuration',
          det.fromFcos(fsdl, readHw).config, null);
    check('every variable it found is reported',
          det.fromFcos(fsdl, readHw).read.map((v) => v.variable).join(','),
          'CDJV_SELF_RESIDENT_MC,CZ2V_OPS_MC');

    put(DATA + 0x20, 2);
    const rec = det.fromFcos(fsdl, readHw);
    check('the record reads the MC',        rec.mc, 2);
    check('from the first variable that has one', rec.variable,
          'CDJV_SELF_RESIDENT_MC');
    check('and the GRT row for it',         rec.phases.join(','), '6,13');
    check('and names the configuration',    rec.config, 'WIDE');

    put(DATA + 0x20, 1);
    check('MC 1 names the other one', det.fromFcos(fsdl, readHw).config, 'BASE');

    put(DATA + 0x20, 0);
    put(DATA + 0x25, 2);
    const second = det.fromFcos(fsdl, readHw);
    check('a zero is passed over', second.variable, 'CZ2V_OPS_MC');
    check('and the configuration still follows', second.config, 'WIDE');

    put(DATA + 0x20, 9);
    check('an MC with no GRT row names nothing',
          det.fromFcos(fsdl, readHw).config, null);

    check('no index means no record', det.fromFcos(null, readHw), null);
    const bare = SdlIndex.load(idxPath);
    check('an index naming none of them reads nothing',
          det.fromFcos(bare, readHw), null);

    fs.rmSync(tmp, { recursive: true, force: true });
    console.log(`\n${pass} passed, ${fail} failed`);
    process.exit(fail ? 1 : 0);
})().catch((e) => {
    console.error(e);
    process.exit(1);
});
