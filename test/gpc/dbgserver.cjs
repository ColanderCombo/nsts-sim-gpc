// test_dbgserver.cjs — the socket debugger: DebugSession's execution and
// stop classification, the command table's argument coercion and rendering,
// and DebugServer's framing, dispatch and event broadcast.
//
// Usage:  node test/test_dbgserver.cjs
//
// The image is synthesized here (LHI/STH pairs storing 1, 2, 3 into 0x0200),
// so the test carries no dependency on a built FCM corpus.
//
// Exit status is 1 iff any assertion fails.

'use strict';

const path    = require('path');
const os      = require('os');
const fs      = require('fs');
const net     = require('net');
const esbuild = require('esbuild');
const coffeePlugin = require('esbuild-coffeescript');

const SRC = path.resolve(__dirname, '..');

// DebugSession reaches com/lru, which is Civet — same plugin the gpc bundle
// uses (esbuild/esbuild.gpc.config.js).
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
        `dbgserver.${path.basename(entry, '.coffee')}.${process.pid}.cjs`);
    await esbuild.build({
        absWorkingDir: SRC,
        entryPoints: [path.join(SRC, 'gpc', entry)],
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

// assertion harness
//
let pass = 0, fail = 0;
function check(label, got, want) {
    if (got === want) { pass++; }
    else { fail++; console.log(`FAIL  ${label}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`); }
}
function ok(label, cond, why) {
    if (cond) { pass++; }
    else { fail++; console.log(`FAIL  ${label}${why ? `: ${why}` : ''}`); }
}

// ENTRY stores 1, 2 then 3 into WATCH, and runs into halfwords of zero,
// which decode as A 0,X'0000'(0) and go on forever.
const ENTRY = 0x0100;
const WATCH = 0x0200;
const PROGRAM = [0xeef3, 0x0001, 0xbef3, WATCH,
                 0xeef3, 0x0002, 0xbef3, WATCH,
                 0xeef3, 0x0003, 0xbef3, WATCH];

function writeImage(file) {
    const img = Buffer.alloc(0x400 * 2);
    PROGRAM.forEach((hw, i) => img.writeUInt16BE(hw, (ENTRY + i) * 2));
    fs.writeFileSync(file, img);
}

// A symbol table naming ENTRY and WATCH, as an overlay would.
function writeSymbols(file, tag) {
    fs.writeFileSync(file, JSON.stringify({
        version: 'test', imageSize: 0x800, entryPoint: ENTRY,
        sections: [{ name: `#${tag}`, address: ENTRY, size: 16, module: tag }],
        symbols: [
            { name: `${tag}_ENTRY`, address: ENTRY, type: 'code', module: tag },
            { name: `${tag}_WATCH`, address: WATCH, type: 'data', module: tag },
        ],
        relocations: [],
    }));
}

// A client speaking the line protocol, with the replies keyed by id and the
// events collected as they arrive.
class Client {
    constructor(port) {
        this.sock = net.connect({ host: '127.0.0.1', port });
        this.sock.setEncoding('utf8');
        this.buf = '';
        this.pending = new Map();
        this.anon = [];
        this.anonSeen = [];
        this.events = [];
        this.nextId = 1;
        this.sock.on('data', (chunk) => {
            this.buf += chunk;
            for (;;) {
                const nl = this.buf.indexOf('\n');
                if (nl < 0) break;
                const line = this.buf.slice(0, nl);
                this.buf = this.buf.slice(nl + 1);
                if (!line.trim()) continue;
                let msg;
                try { msg = JSON.parse(line); } catch (e) { this.events.push({ event: 'unparsed', line }); continue; }
                if (msg.event) { this.events.push(msg); continue; }
                if (msg.id === null || msg.id === undefined) {
                    const w = this.anon.shift();
                    if (w) w(msg); else this.anonSeen.push(msg);
                    continue;
                }
                const r = this.pending.get(msg.id);
                if (r) { this.pending.delete(msg.id); r(msg); }
            }
        });
        this.ready = new Promise((res, rej) => {
            this.sock.once('connect', res);
            this.sock.once('error', rej);
        });
    }
    send(cmd, args, wantText = true) {
        const id = this.nextId++;
        return new Promise((res) => {
            this.pending.set(id, res);
            this.sock.write(JSON.stringify({ id, cmd, args, text: wantText }) + '\n');
        });
    }
    // A bare command line gets an id-less reply, so it is matched by order.
    line(text) {
        return new Promise((res) => {
            const seen = this.anonSeen.shift();
            if (seen) return res(seen);
            this.anon.push(res);
            this.sock.write(text + '\n');
        });
    }
    raw(text) { this.sock.write(text + '\n'); }
    eventsOf(name) { return this.events.filter((e) => e.event === name); }
    close() { this.sock.destroy(); }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
    const { DebugSession } = await bundle('dbgsession.coffee');
    const { DebugServer }  = await bundle('dbgserver.coffee');
    const cmds             = await bundle('dbgcmds.coffee');

    const tmp  = fs.mkdtempSync(path.join(os.tmpdir(), 'gpc-dbgtest-'));
    const fcm  = path.join(tmp, 'tiny.fcm');
    writeImage(fcm);

    // Address resolution, off the session directly
    //
    let s = new DebugSession({ fcmPath: fcm, start: ENTRY.toString(16) });
    s.load(fcm, { start: ENTRY.toString(16) });
    check('resolve bare hex',      s.resolveAddr('100'),      0x100);
    check('resolve 0x hex',        s.resolveAddr('0x100'),    0x100);
    check('resolve with offset',   s.resolveAddr('0x100+10'), 0x110);
    check('resolve minus offset',  s.resolveAddr('0x110-10'), 0x100);
    check('resolve a number',      s.resolveAddr(0x100),      0x100);
    check('resolve rejects junk',  s.resolveAddr('zzz'),      null);
    check('entry is the NIA',      s.gpc.cpu.psw.getNIA(),    ENTRY);

    // Argument coercion against the command table
    //
    const stepSpec = cmds.lookupCommand('step');
    check('alias resolves',   cmds.lookupCommand('si').name, 'step');
    check('unknown is null',  cmds.lookupCommand('nope'),    null);
    check('count from a line', cmds.coerceArgs(s, stepSpec, cmds.parseArgLine(stepSpec, ['7'])).count, 7);
    check('count defaults',    cmds.coerceArgs(s, stepSpec, {}).count, 1);
    let threw = null;
    try { cmds.coerceArgs(s, cmds.lookupCommand('break'), {}); } catch (e) { threw = e.code; }
    check('a required arg is enforced', threw, 'badArgs');
    threw = null;
    try { cmds.coerceArgs(s, cmds.lookupCommand('break'), { addr: 'nosuch' }); } catch (e) { threw = e.code; }
    check('an unresolvable addr is rejected', threw, 'badArgs');
    const memSpec = cmds.lookupCommand('mem');
    const memArgs = cmds.coerceArgs(s, memSpec, cmds.parseArgLine(memSpec, ['0x200', '4', '--unit', 'fw']));
    check('flag after positionals', memArgs.unit, 'fw');
    check('positionals beside a flag', memArgs.count, 4);

    // Execution and stop classification
    //
    let stop = await s.stepInstr(1);
    check('one step runs one instruction', stop.steps, 1);
    check('one step stops for step',       stop.reason, 'step');
    check('the NIA advanced',              stop.location.addr, ENTRY + 2);

    stop = await s.stepInstr(3);
    check('step N runs N',                 stop.steps, 4);
    check('step N stops for step',         stop.reason, 'step');

    s.reset();
    s.setBreakpoint(ENTRY + 8);
    stop = await s.continueRun(1000);
    check('continue stops at a breakpoint', stop.reason, 'breakpoint');
    check('the breakpoint address',         stop.location.addr, ENTRY + 8);
    check('the store ran',                  s.ram.get16(WATCH, false), 2);

    s.clearBreakpoints();
    stop = await s.continueRun(20);
    check('continue honours its budget',    stop.reason, 'step budget');

    // Data breakpoints
    //
    s.reset();
    s.clearBreakpoints();
    s.setDataBreakpoint(WATCH, { on: 'change' });
    stop = await s.continueRun(1000);
    check('a change stops the run',    stop.reason, 'data breakpoint');
    check('the old value is reported', stop.dataBreakpoint.old, 0);
    check('the new value is reported', stop.dataBreakpoint.new, 1);
    stop = await s.continueRun(1000);
    check('the next change stops again', stop.dataBreakpoint.new, 2);

    // A store of the same value is a write but not a change
    s.reset();
    s.clearDataBreakpoints();
    s.ram.set16(WATCH, 1, false);
    s.setDataBreakpoint(WATCH, { on: 'change' });
    stop = await s.continueRun(1000);
    check('an unchanged store is not a change', stop.dataBreakpoint.new, 2);
    s.reset();
    s.clearDataBreakpoints();
    s.ram.set16(WATCH, 1, false);
    s.setDataBreakpoint(WATCH, { on: 'write' });
    stop = await s.continueRun(1000);
    check('a write stops whatever it stores', stop.dataBreakpoint.new, 1);

    // The trace ring
    //
    s.reset();
    s.clearDataBreakpoints();
    s.setTrace(true, 4);
    await s.stepInstr(6);
    const log = s.traceLog(10);
    check('the ring holds its limit', log.length, 4);
    check('the ring keeps the newest', log[3].addr, ENTRY + 10);
    ok('the ring disassembles', /STH/.test(log[3].text), log[3].text);
    s.setTrace(false);
    check('turning it off empties it', s.traceRing.length, 0);

    // Symbol layers
    //
    const symA = path.join(tmp, 'ovlA.sym.json');
    const symB = path.join(tmp, 'ovlB.sym.json');
    writeSymbols(symA, 'AAA');
    writeSymbols(symB, 'BBB');

    check('nothing named before a layer', s.labelAt(ENTRY), null);
    const la = s.syms.load(symA, { name: 'ovlA', lo: ENTRY, hi: ENTRY + 0xff });
    check('the layer took its name',   la.name, 'ovlA');
    check('a layer names an address',  s.labelAt(ENTRY), 'AAA_ENTRY');
    check('and reports its source',    s.syms.sourceAt(ENTRY), 'ovlA');
    check('a name resolves through it', s.resolveAddr('AAA_ENTRY'), ENTRY);
    check('outside its range, nothing', s.labelAt(0x900), null);

    s.syms.load(symB, { name: 'ovlB', lo: ENTRY, hi: ENTRY + 0xff });
    check('the topmost layer wins',     s.labelAt(ENTRY), 'BBB_ENTRY');
    s.syms.switchTo('ovlA');
    check('switchTo stands down the overlap', s.syms.find('ovlB').enabled, false);
    check('and puts its own back',            s.labelAt(ENTRY), 'AAA_ENTRY');
    s.syms.switchTo('ovlB');
    check('switching back',                   s.labelAt(ENTRY), 'BBB_ENTRY');
    check('a disabled layer names nothing',   s.syms.find('ovlA').enabled, false);
    check('sections merge across layers',
          s.syms.sections().some((x) => x.name === '#BBB' && x.source === 'ovlB'), true);
    check('search tags the layer',
          s.syms.search('WATCH')[0].source, 'ovlB');
    check('unload drops one',                 s.syms.unload('ovlB'), 1);
    // Unloading does not re-enable what it displaced; switching does.
    check('the displaced layer stays down',   s.syms.layerAt(ENTRY), null);
    s.syms.switchTo('ovlA');
    check('switching brings it back',         s.syms.layerAt(ENTRY).name, 'ovlA');
    s.syms.unloadAll();
    check('unloadAll leaves the base',        s.labelAt(ENTRY), null);

    // Memory search
    //
    s.reset();
    s.clearBreakpoints();
    let found = s.findMemory([0xeef3, 0x0001]);
    check('find locates a halfword run', found.matches[0]?.addr, ENTRY);
    check('find reports the values',     found.matches[0]?.values[1], 0x0001);
    found = s.findMemory([0xdead]);
    check('find reports no match',       found.matches.length, 0);
    s.ram.set16(0x300, 0x4142, false);      // 'AB'
    found = s.findMemory([0x4142], { start: 0x280, end: 0x380 });
    check('find honours its range',      found.matches[0]?.addr, 0x300);
    found = s.findMemory([0x4142], { start: 0x310, end: 0x380 });
    check('and searches only in it',     found.matches.length, 0);

    // Logpoints record and let the run carry on
    //
    s.reset();
    s.clearBreakpoints();
    s.clearDataBreakpoints();
    let logged = [];
    const unsub = s.on((m) => { if (m.event === 'logpoint') logged.push(m.body); });
    s.setLogpoint(ENTRY + 4, { message: 'third store', events: true });
    stop = await s.continueRun(200);
    check('a logpoint did not stop the run', stop.reason, 'step budget');
    check('the logpoint fired',              logged.length, 1);
    check('it carried its message',          logged[0].message, 'third store');
    check('and its location',                logged[0].location.addr, ENTRY + 4);
    check('the hit count is kept',           s.logpointAt(ENTRY + 4).hits, 1);
    unsub();
    s.clearLogpoints();

    // Breakpoint hit counts, ignore counts and once
    //
    s.reset();
    s.clearBreakpoints();
    s.setBreakpoint(ENTRY + 4, { ignore: 1 });
    stop = await s.continueRun(400);
    check('an ignored arrival does not stop', stop.reason, 'step budget');
    check('but it is counted',                s.breakpointAt(ENTRY + 4).hits, 1);
    check('and the breakpoint is armed again', s.breakpointAt(ENTRY + 4).enabled, true);
    s.reset();
    stop = await s.continueRun(400);
    check('the next arrival stops',           stop.reason, 'breakpoint');
    check('at the breakpoint',                stop.location.addr, ENTRY + 4);

    s.reset();
    s.clearBreakpoints();
    s.setBreakpoint(ENTRY + 4, { once: true });
    stop = await s.continueRun(400);
    check('a once breakpoint stops',          stop.reason, 'breakpoint');
    check('and is gone afterwards',           s.breakpointAt(ENTRY + 4), null);
    s.clearBreakpoints();

    // Bus monitoring, off the MIA tap
    //
    s.reset();
    const mias = s.gpc.iop.bce.filter((b) => b && b.mia && b.mia.busName).map((b) => b.mia);
    ok('the IOP has busses attached', mias.length > 0, `${mias.length} MIAs`);
    const mm1 = mias.filter((m) => m.busName === 'MM1')[0];
    ok('MM1 is one of them', !!mm1);

    s.busMon.start({ limit: 100 });
    mm1.deliver([0x7000, 0x0100, 0x1234]);
    check('the tap recorded the words',  s.busMon.ring.length, 3);
    check('with the bus name',           s.busMon.ring[0].bus, 'MM1');
    check('and the direction',           s.busMon.ring[0].dir, 'rx');
    check('and the value',               s.busMon.ring[2].value, 0x1234);
    check('counted per bus',             s.busMon.describe().counts['MM1.rx'], 3);
    let tx = s.busMon.transactions(10);
    check('grouped into one transaction', tx.length, 1);
    check('carrying its words',           tx[0].words.length, 3);

    s.busMon.start({ busses: ['DK1'], limit: 100 });
    mm1.deliver([0x9999]);
    check('a bus filter excludes the rest', s.busMon.ring.length, 0);
    s.busMon.stop();
    mm1.deliver([0x8888]);
    check('a stopped monitor records nothing', s.busMon.ring.length, 0);

    // Discrete monitoring
    //
    s.discMon.start({ limit: 100 });
    s.gpc.iop.setDiscreteInput(1, 0, true);      // register A (1), IBM bit 0 = halt
    check('a discrete change is recorded', s.discMon.ring.length >= 1, true);
    const dchg = s.discMon.ring[s.discMon.ring.length - 1];
    check('naming the register',           dchg.register, 'DISCINA');
    check('and the bit that moved',        dchg.changed[0], '+halt');
    s.gpc.iop.setDiscreteInput(1, 0, false);
    check('clearing it is recorded too',
          s.discMon.ring[s.discMon.ring.length - 1].changed[0], '-halt');
    const dstate = s.discMon.state();
    ok('the state names the set bits',
       dstate.registers.some((r) => r.name === 'DISCINA'), JSON.stringify(dstate).slice(0, 80));
    s.discMon.stop();

    // The record log
    //
    const logFile = path.join(tmp, 'rec.ndjson');
    const rec = s.openLog(logFile, { kinds: ['discrete'] });
    s.discMon.start({ limit: 100 });
    s.gpc.iop.setDiscreteInput(1, 1, true);      // standby
    await s.stepInstr(1);                        // a stop, which the log filters out
    await sleep(50);
    s.closeLog();
    await sleep(50);
    const recLines = fs.readFileSync(logFile, 'utf8').trim().split('\n').filter((l) => l);
    ok('the log wrote a record', recLines.length >= 1, `${recLines.length} lines`);
    const rec0 = JSON.parse(recLines[0]);
    check('of the kind asked for',   rec0.kind, 'discrete');
    ok('stamped with the wall clock', /^\d{4}-/.test(rec0.stamp.wall), rec0.stamp.wall);
    ok('and with simulated time',     typeof rec0.stamp.simSec === 'number');
    check('kinds not asked for are left out',
          recLines.filter((l) => JSON.parse(l).kind === 'stopped').length, 0);
    s.discMon.stop();

    // The server: framing, dispatch, events
    //
    s.reset();
    const server = new DebugServer(s, { port: 0, sessionFile: path.join(tmp, 'session.json') });
    const [ep] = await server.listen();
    const port = ep.port;
    ok('the session file was written', fs.existsSync(path.join(tmp, 'session.json')));

    const c = new Client(port);
    await c.ready;
    await sleep(100);
    check('a welcome is sent on connect', c.eventsOf('welcome').length, 1);

    let r = await c.send('capabilities', {});
    check('capabilities replies ok', r.ok, true);
    check('the protocol is reported', r.result.protocol, cmds.PROTOCOL_VERSION);

    r = await c.send('regs', { name: 'NIA' });
    check('a register reads back', r.result.value, ENTRY);
    ok('text is rendered when asked', (r.text || '').includes('NIA'), r.text);

    r = await c.send('regs', { name: 'NIA' }, false);
    check('no text when not asked', r.text, undefined);

    r = await c.line('step 2');
    check('a bare command line dispatches', r.ok, true);
    check('the line carried its count', r.result.steps, 2);
    ok('a bare line always renders', (r.text || '').length > 0);

    r = await c.send('bogus', {});
    check('an unknown command fails',   r.ok, false);
    check('with a code',                r.error.code, 'unknownCommand');

    r = await c.send('break', { addr: 'nosuch' });
    check('a bad argument fails',       r.ok, false);
    check('with a code',                r.error.code, 'badArgs');

    const badJson = c.line('{not json');
    check('unparsable JSON is refused', (await badJson).error.code, 'badJSON');

    r = await c.send('writemem', { addr: '0x300', values: ['dead', 'beef'] });
    check('a write reports what it wrote', r.result.written.length, 2);
    r = await c.send('mem', { addr: '0x300', count: 2 });
    check('the write reads back',          r.result.values[0], 0xdead);
    check('and the second halfword',       r.result.values[1], 0xbeef);
    ok('the dump renders as hex',          /dead beef/.test(r.text), r.text);

    // Events reach a client that asked for nothing
    //
    const obs = new Client(port);
    await obs.ready;
    await sleep(50);
    await c.send('reset', {});
    await c.send('setbreakpoints', { addrs: ['0x108'] });
    r = await c.send('continue', {});
    check('the run stopped at the breakpoint', r.result.reason, 'breakpoint');
    await sleep(100);
    check('the observer saw it continue', obs.eventsOf('continued').length >= 1, true);
    const stops = obs.eventsOf('stopped');
    ok('the observer saw the stop', stops.length >= 1, `${stops.length} stopped events`);
    ok('the stop carried its reason',
       stops[stops.length - 1].body.reason === 'breakpoint',
       stops[stops.length - 1].body.reason);

    // Pause interrupts a run that would not otherwise stop
    //
    await c.send('bclear', { addr: '*' });
    await c.send('reset', {});
    const running = c.send('continue', { maxsteps: 2000000000 });
    await sleep(300);
    const dur = await c.send('regs', { name: 'NIA' });
    check('a query is answered during a run', dur.ok, true);
    await c.send('pause', {});
    r = await running;
    check('pause stops the run',  r.result.reason, 'pause');
    ok('the run got somewhere',   r.result.steps > 1000, `${r.result.steps} steps`);

    // Plain-text mode, which is what makes nc usable
    //
    const t = new Client(port);
    await t.ready;
    await sleep(50);
    t.raw('mode text');
    t.raw('status');
    await sleep(150);
    // Text-mode replies are not JSON, so the client files them as unparsed.
    const plain = t.eventsOf('unparsed').map((e) => e.line).join('\n');
    ok('text mode answers in text', /^mode text/m.test(plain), JSON.stringify(plain.slice(0, 160)));
    ok('and renders the stop',      /---/.test(plain),         JSON.stringify(plain.slice(0, 160)));

    c.close(); obs.close(); t.close();
    server.shutdown();
    ok('shutdown removed the session file', !fs.existsSync(path.join(tmp, 'session.json')));

    fs.rmSync(tmp, { recursive: true, force: true });

    console.log(`\n${pass} passed, ${fail} failed`);
    process.exit(fail ? 1 : 0);
})().catch((e) => {
    console.error(e);
    process.exit(1);
});
