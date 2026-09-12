// Paced-machine barrier tests.

'use strict';

const path    = require('path');
const os      = require('os');
const fs      = require('fs');
const { execFileSync } = require('child_process');
const esbuild = require('esbuild');
const coffeePlugin = require('esbuild-coffeescript');

const SRC = path.resolve(__dirname, '..', '..');

const BASE = process.env.NSTS_TEST_BASE_PORT ?? String(20000 + (process.pid % 400) * 100);
process.env.NSTS_BASE_PORT = BASE;
process.env.NSTS_BUS_SHM = 'off';

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

async function bundle(entry, out) {
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
    return out;
}

let pass = 0, fail = 0;
function check(label, got, want) {
    if (got === want) { pass++; }
    else { fail++; console.log(`FAIL  ${label}: got ${got}, want ${want}`); }
}
function ok(label, cond) { check(label, !!cond, true); }

const MS = 1e6;   // nanoseconds of simulated time

async function main() {
    const modPath = path.join(os.tmpdir(), `barrier.${process.pid}.cjs`);
    await bundle('com/simbarrier.coffee', modPath);
    const shm = require(path.join(process.env.NSTS_NATIVE || path.join(SRC, 'build', 'native'), 'shmring.node'));

    const M = require(modPath);
    M.configureBarrier({ barrier: 'off' });
    check('the barrier is off unless it is asked for', M.deltaUs(), 0);
    ok('and a machine does not join one', !new M.Barrier(1).join(0));

    M.configureBarrier({ barrier: '50' });
    check('delta is what it is set to', M.deltaUs(), 50);

    const one = new M.Barrier(4);
    ok('the first machine joins', one.join(10 * MS));
    ok('and is alone', one.allowanceUs() === Infinity);
    ok('so it is never held', !one.step(1000 * MS));

    const two = new M.Barrier(1);
    ok('the second machine joins', two.join(500 * MS));
    check('and starts where the first stands', two.simUs, one.simUs);

    one.scan();
    ok('the machine ahead is held', one.step(1000 * MS + 200000));
    ok('the machine behind is free', !two.step(500 * MS + 10000));
    ok('a partner ahead does not hold this one',
       two.allowanceUs() === Infinity || two.allowanceUs() > 0);

    ok('inside delta nothing is held', !one.step(1000 * MS + 10000 + 40000));
    ok('past it the machine stops', one.step(1000 * MS + 10000 + 60000));
    check('and the stop is counted', one.holds, 2);

    two.step(500 * MS + 60000);
    ok('the partner catching up releases it', !one.step(1000 * MS + 10000 + 60000));

    two.leave();
    one.scan();
    ok('a machine that has left holds nobody', !one.step(2000 * MS));
    ok('and its slot is off the table', M.describe(one.hdr).length === 1);

    const three = new M.Barrier(2);
    three.join(2000 * MS);
    one.scan();
    ok('a silent partner holds this machine at first', one.step(2000 * MS + 200000));
    Atomics.store(three.hdr, three.word + 2, (three.hdr[three.word + 2] - 600000) | 0);
    ok('and is passed over once it has gone quiet', !one.step(2000 * MS + 200000));
    three.leave();

    const child = `
        process.env.NSTS_BASE_PORT = ${JSON.stringify(BASE)};
        process.env.NSTS_SIM_BARRIER = '50';
        const M = require(${JSON.stringify(modPath)});
        const b = new M.Barrier(3);
        b.join(0);
        process.stdout.write(String(b.word));
        process.exit(0);
    `;
    const word = Number(execFileSync(process.execPath, ['-e', child], { encoding: 'utf8' }));
    ok('the child took a slot', word > 0);
    const four = new M.Barrier(5);
    four.join(3000 * MS);
    check("and a dead machine's slot is reused", four.word, word);
    four.leave();
    one.leave();

    shm.unlink(`/nsts2.${BASE}`);
    fs.rmSync(modPath, { force: true });

    console.log(`\n${pass} passed, ${fail} failed`);
    process.exit(fail ? 1 : 0);
}

main().catch((e) => { console.error(e); process.exit(1); });
