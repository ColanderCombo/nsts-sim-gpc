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

process.env.NSTS_BASE_PORT =
    process.env.NSTS_TEST_BASE_PORT ?? String(20000 + (process.pid % 400) * 100);
console.log(`bus base port ${process.env.NSTS_BASE_PORT}`);

async function bundle(rel) {
    const out = path.join(os.tmpdir(),
        `cli.test.${path.basename(rel).replace(/\W/g, '_')}.${process.pid}.cjs`);
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


const assert = require('node:assert/strict');

(async () => {
    const { runCommand, unitProgram } = await bundle('lru/lruCli.coffee');
    const options = Object.freeze([
        'quiet',
        Object.freeze(['replyDelay', 'reply latency']),
        Object.freeze(['--label <text>', 'unit label', 'default']),
        Object.freeze({
            flag: '--fault <name>', help: 'inject a fault', many: true,
            apply(unit, value) { unit.faults.push(value); },
        }),
        Object.freeze({
            flag: '--enabled', help: 'enable the unit',
            apply(unit, value) { unit.enabled = value; },
        }),
    ]);
    const spec = Object.freeze({
        id: 'example', summary: 'Example unit',
        run: Object.freeze({
            summary: 'Run example', args: Object.freeze([['[id]', 'unit id', 'BOX']]),
            options,
            build(opts, id) { return { id, opts, faults: [], enabled: false }; },
        }),
    });
    const units = [];
    const first = runCommand(spec, (opened) => units.push(...opened));
    const second = runCommand(spec, (opened) => units.push(...opened));
    const program = unitProgram(spec);
    assert.equal(program.commands.length, 1);
    assert.equal(spec.run.options, options);
    assert.equal(first.options[1].description, 'reply latency');
    assert.equal(Object.hasOwn(options[3], 'key'), false);
    await first.parseAsync(['FIRST', '--quiet', '--fault', 'a', '--fault', 'b', '--enabled'], { from: 'user' });
    await second.parseAsync([], { from: 'user' });
    assert.deepEqual(units.map((unit) => [unit.id, unit.faults, unit.enabled]),
        [['FIRST', ['a', 'b'], true], ['BOX', [], false]]);
    assert.equal(units[0].opts.quiet, true);
    assert.equal(units[1].opts.quiet, undefined);
    assert.equal(units[1].opts.label, 'default');
    assert.equal(units[1].opts.replyDelay, '0');
    assert.equal(Object.hasOwn(options[3], 'key'), false);

    const pair = [{ id: 'ONE' }, { id: 'TWO' }];
    let opened;
    await runCommand({
        id: 'pair', run: { summary: 'Run pair', build: () => pair },
    }, (units) => { opened = units; }).parseAsync([], { from: 'user' });
    assert.equal(opened, pair);

    assert.throws(() => runCommand({
        id: 'invalid', run: { summary: 'Invalid', options: ['unknown'] },
    }), /no standard option 'unknown'/);
    console.log('CLI option isolation and unit construction passed');
})().catch((error) => { console.error(error); process.exitCode = 1; });
