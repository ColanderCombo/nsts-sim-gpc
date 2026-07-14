//
// Extracts the instruction definitions from the GPC simulator's tables 
// and dumps a json that asm101 reads to generate its encoder.
// for the CPU, MSC & BCE we dump:
//
//     mnemonic -> {          d: <descriptor>, 
//		           fmt: [<operand formats>],
//                        name: <full name>, 
//                      opType: <DATA|BRCH|SHFT>,
//                   addrWidth: <HALFWORD|FULLWORD|DBLEWORD>, 
//		            fp: <SP|DP>,
//		         pcrel: true    ('d' is a PC-relative displacement)
//		   }
//
// <descriptor> is a string where each character is a bit:
//	0/1: literal, _: don't-care, letter:name field
//
// Usage:  node tools/extract_instr_defs.cjs [output.json]

'use strict';

const path    = require('path');
const os      = require('os');
const fs      = require('fs');
const esbuild = require('esbuild');
const coffeePlugin = require('esbuild-coffeescript');

const SRC = path.resolve(__dirname, '..', 'gpc');

const OP_TYPE = { 1: 'DATA', 2: 'BRCH', 4: 'SHFT' };
const ADDR_WIDTH = { 1: 'HALFWORD', 2: 'FULLWORD', 3: 'DBLEWORD' };

async function bundle(entry) {
    const out = path.join(os.tmpdir(),
        `extract.${path.basename(entry, '.coffee')}.${process.pid}.cjs`);
    await esbuild.build({
        entryPoints: [path.join(SRC, entry)],
        bundle:   true,
        platform: 'node',
        format:   'cjs',
        outfile:  out,
        plugins:  [coffeePlugin()],
        resolveExtensions: ['.coffee', '.js', '.ts', '.json'],
        logLevel: 'error',
    });
    return require(out);
}

function record(op) {
    const r = { d: op.d };
    if (op.f != null) r.fmt = op.f;
    if (op.n != null) r.name = op.n;
    if (op.t != null) r.opType = OP_TYPE[op.t] ?? op.t;
    if (op.a != null) r.addrWidth = ADDR_WIDTH[op.a] ?? op.a;
    if (op.fp != null) r.fp = op.fp;
    if (op.pr != null) r.pcrel = !!op.pr;
    return r;
}

function extract(instance) {
    const out = {};
    for (const name of Object.keys(instance.ops)) {
        const op = instance.ops[name];
        if (!op || !op.d || op.d.length === 0) continue;
        out[name] = record(op);
    }
    return out;
}

(async () => {
    const { Instruction }    = await bundle('cpu_instr.coffee');
    const { MSCInstruction } = await bundle('iop_msc_instr.coffee');
    const { BCEInstruction } = await bundle('iop_bce_instr.coffee');

    const doc = {
        _comment: 'Auto-extracted from ext/sim/gpc/*_instr.coffee by '
                + 'tools/extract_instr_defs.cjs; do not hand-edit.',
        cpu: extract(new Instruction()),
        msc: extract(new MSCInstruction()),
        bce: extract(new BCEInstruction()),
    };

    const json = JSON.stringify(doc, null, 2) + '\n';
    const dest = process.argv[2];
    if (dest) {
        fs.writeFileSync(dest, json);
        const n = (k) => Object.keys(doc[k]).length;
        console.error(`wrote ${dest}: cpu=${n('cpu')} msc=${n('msc')} bce=${n('bce')}`);
    } else {
        process.stdout.write(json);
    }
})().catch((e) => { console.error(e); process.exit(1); });
