// test_realtime.cjs — real-time execution: the wait-state idle model
// (CPU.nextTimerNs/advanceIdleNs/canWake), the RTPacer slice API that the
// GUI drives from its own loop, and the GUIHarness run loop's 200 ms
// chunking, pacing and wait-state handling.
//
// Usage:  node test/test_realtime.cjs
//
// The pacing checks are wall-clock measurements, so they carry tolerances
// and the ones that need the host to outrun the AP-101S are skipped (with
// a note) when it doesn't.
//
// Exit status is 1 iff any assertion fails.

'use strict';

const path    = require('path');
const os      = require('os');
const fs      = require('fs');
const esbuild = require('esbuild');
const coffeePlugin = require('esbuild-coffeescript');

const SRC = path.resolve(__dirname, '..');

// GUIHarness reaches com/lru, which is Civet — same plugin the gpc bundle
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
        `realtime.${path.basename(entry, '.coffee')}.${process.pid}.cjs`);
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
let pass = 0, fail = 0, skip = 0;
function check(label, got, want) {
    if (got === want) { pass++; }
    else { fail++; console.log(`FAIL  ${label}: got ${got}, want ${want}`); }
}
function skipped(label, why) {
    skip++; console.log(`SKIP  ${label} (${why})`);
}
function note(s) { console.log(`      ${s}`); }

(async () => {
    const { CPU }        = await bundle('cpu.coffee');
    const { RTPacer }    = await bundle('rtpacer.coffee');
    const { GUIHarness } = await bundle('guiharness.coffee');

    const poke16 = (c, a, v) => c.ram.set16(a, v, false);
    const poke32 = (c, a, v) => c.ram.set32(a, v, false);

    // A CPU waiting on interval timer 1, with CLK1 unmasked and its new PSW
    // pointing at `handler` in the process state.
    function makeWaitingCPU(counter1, handler = 0x500) {
        const c = new CPU({ cpuWords: 64 * 1024 });
        c.psw.setNIA(0x800);
        c.psw.setWaitState(true);
        c.psw._setField2(c.psw.pack2.desc.f.m, 0x80);   // system mask bit 32
        c.counter1 = counter1;
        poke16(c, 0x00B0, 0);
        poke32(c, 0x0064, handler << 16);
        poke32(c, 0x0066, 0x00000000);
        return c;
    }

    // CPU: time to the next interval-timer expiry
    //
    let cpu = new CPU({ cpuWords: 64 * 1024 });
    cpu.counter1 = 5000;  poke16(cpu, 0x00B0, 0);
    cpu.counter2 = 0xffff; poke16(cpu, 0x00B1, 0xffff);
    check('nextTimerNs = (count+1) us', cpu.nextTimerNs(), 5001 * 1000);
    cpu.advanceTimeNs(1500);                            // 1.5 us in
    check('nextTimerNs after 1.5us', cpu.nextTimerNs(), 5001 * 1000 - 1500);

    // CPU.advanceIdleNs: lands exactly on the wakeup
    //
    cpu = makeWaitingCPU(5000);
    check('advanceIdleNs stops at the interrupt', cpu.advanceIdleNs(1e9), 5001 * 1000);
    check('advanceIdleNs left the wait state', cpu.psw.getWaitState(), false);
    check('advanceIdleNs entered the handler', cpu.psw.getNIA(), 0x500);

    cpu = makeWaitingCPU(5000);
    cpu.advanceIdleNs(2e6);                             // 2 ms: not enough
    check('advanceIdleNs partial stays in wait', cpu.psw.getWaitState(), true);
    check('advanceIdleNs partial advance', cpu.timeNs, 2e6);

    // CPU.canWake
    //
    check('canWake with CLK1 unmasked', cpu.canWake(), true);
    cpu.psw._setField2(cpu.psw.pack2.desc.f.m, 0x00);
    check('canWake with everything masked', cpu.canWake(), false);
    cpu.intPending.svc = true;
    check('canWake with a pending SVC', cpu.canWake(), true);

    // RTPacer: caller-driven idle slices
    //
    cpu = makeWaitingCPU(5000);
    let pacer = new RTPacer(cpu, 1.0, 2000);
    pacer.enterIdle();
    check('advanceIdle waits at idle entry', pacer.advanceIdle(), 'waiting');
    check('advanceIdle bought no time yet', cpu.timeNs, 0);
    // One call carries the wait state forward by at most
    // IDLE_CATCHUP_MAX_NS (5 ms of simulated time), however long the host
    // was away -- see the note on it: an unbounded catch-up is what let a
    // stalled host dump tens of milliseconds of simulated time into a
    // single call, past the window a bus receive gets, with no turn of the
    // event loop anywhere inside it.  So an 8 ms absence buys 5 ms and the
    // 5.001 ms wakeup lands on the call after it.
    await new Promise(r => setTimeout(r, 8));
    check('advanceIdle still waiting after one capped slice',
          pacer.advanceIdle(), 'waiting');
    check('advanceIdle capped at 5 ms', cpu.execTimeUs(), 5000);
    await new Promise(r => setTimeout(r, 3));
    check('advanceIdle resumes on the next slice', pacer.advanceIdle(), 'resumed');
    check('advanceIdle sim time ~5 ms', cpu.execTimeUs() >= 5000 && cpu.execTimeUs() < 9000, true);

    // The excess is dropped, not owed: after the cap the idle baseline is
    // re-taken, so the next slice asks only for the time since it.
    cpu = makeWaitingCPU(0xFFFF); poke16(cpu, 0x00B0, 0xFFFF);
    pacer = new RTPacer(cpu, 1.0, 2000);
    pacer.enterIdle();
    await new Promise(r => setTimeout(r, 40));
    pacer.advanceIdle();
    check('capped slice bought 5 ms of a 40 ms absence', cpu.execTimeUs(), 5000);
    pacer.advanceIdle();
    check('the other 35 ms are not owed', cpu.execTimeUs() < 7000, true);

    cpu = makeWaitingCPU(5000);
    cpu.psw._setField2(cpu.psw.pack2.desc.f.m, 0x00);
    pacer = new RTPacer(cpu, 1.0, 2000);
    pacer.enterIdle();
    check('advanceIdle masked', pacer.advanceIdle(), 'masked');

    // RTPacer.idleWait: the blocking form still behaves
    //
    cpu = makeWaitingCPU(0xFFFF); poke16(cpu, 0x00B0, 0xFFFF);
    check('idleWait timeout', await new RTPacer(cpu, 1.0, 30).idleWait(), 'timeout');
    cpu = makeWaitingCPU(3000);
    check('idleWait resumed', await new RTPacer(cpu, 1.0, 2000).idleWait(), 'resumed');
    check('idleWait entered the handler', cpu.psw.getNIA(), 0x500);

    // GUIHarness run loop
    //
    // Two-instruction loop: AR R1,R2 (0.25 us) + BC 7 back to it (1.25 us
    // taken) = 1.5 us of simulated time per iteration.
    function loopAt(h, addr) {
        poke16(h.cpu, addr,     0x01E2);                // AR   R1,R2
        poke16(h.cpu, addr + 1, 0xC7F0);                // BC   7,D2
        poke16(h.cpu, addr + 2, addr);
    }
    function mkHarness() {
        const h = new GUIHarness({ machine: 'ap101s' });
        loopAt(h, 0x800);
        h.cpu.psw.setNIA(0x800);
        return h;
    }
    // Run for `ms` of wall time, counting display refreshes.
    const runFor = (h, ms) => new Promise((res) => {
        let refreshes = 0;
        h.updateDisplay = () => { refreshes++; };
        h.run();
        setTimeout(() => { h.stop(); res(refreshes); }, ms);
    });
    const simMs = (h) => h.cpu.timeNs / 1e6;

    // Free run: flat out, refreshed once a chunk (5/s at CHUNK_MS = 200).
    let h = mkHarness();
    let refreshes = await runFor(h, 1000);
    const freeSteps = h.stepCount, freeSim = simMs(h);
    note(`free run: ${freeSteps} steps, ${freeSim.toFixed(1)} ms simulated, ${refreshes} refreshes`);
    check('free run advances simulated time', freeSim > 0, true);
    check('free run refreshes ~5/s', refreshes >= 3 && refreshes <= 8, true);

    // An expensive refresh throttles itself rather than stealing the
    // machine -- see REFRESH_DUTY.  
    h = mkHarness();
    const costly = await (new Promise((res) => {
        let n = 0, spent = 0;
        h.updateDisplay = () => {
            const until = Date.now() + 100;             // 100 ms of redraw
            while (Date.now() < until) { /* block, as the panes do */ }
            if (h.running) { n++; spent += 100; }       // not the stop()
        };
        const t0 = Date.now();
        h.run();
        setTimeout(() => {
            const wall = Date.now() - t0;
            h.stop();
            res({ n, spent, wall });
        }, 2000);
    }));
    note(`costly refresh: ${costly.n} refreshes, ` +
         `${(100 * costly.spent / costly.wall).toFixed(0)}% of the wall clock`);
    check('a 100 ms refresh is held near the duty budget',
          costly.spent / costly.wall < 0.30, true);
    check('and still refreshes', costly.n >= 2, true);

    // Pacing can only be observed on a host that can outrun the AP-101S.
    const canPace = freeSim > 1300;

    if (!canPace) {
        skipped('real-time pacing', `host runs at ${(freeSim / 1000).toFixed(2)}x real time`);
    } else {
        h = mkHarness();
        h.setRealTime(true);
        refreshes = await runFor(h, 1000);
        note(`real time: ${h.stepCount} steps, ${simMs(h).toFixed(1)} ms simulated, ${refreshes} refreshes`);
        check('real time buys ~1 s of simulated time per second',
              simMs(h) > 850 && simMs(h) < 1150, true);
        check('real time is slower than a free run', h.stepCount < freeSteps, true);
        check('real time refreshes ~5/s', refreshes >= 3 && refreshes <= 8, true);

        h = mkHarness();
        h.setRealTime(true);
        h.setRTFactor(0.5);
        await runFor(h, 1000);
        note(`factor 0.5: ${h.stepCount} steps, ${simMs(h).toFixed(1)} ms simulated`);
        check('factor 0.5 halves the simulated time',
              simMs(h) > 400 && simMs(h) < 650, true);
    }

    // Wait state under real time: time keeps running, the interval timer
    // expires, and the run continues into the handler.
    h = mkHarness();
    loopAt(h, 0x900);                                   // CLK1 handler
    h.cpu.psw.setWaitState(true);
    h.cpu.psw._setField2(h.cpu.psw.pack2.desc.f.m, 0x80);
    h.cpu.counter1 = 20000;                             // expires in 20 ms
    poke16(h.cpu, 0x00B0, 0);
    poke32(h.cpu, 0x0064, 0x09000000);
    poke32(h.cpu, 0x0066, 0x00000000);
    h.setRealTime(true);
    await runFor(h, 300);
    note(`wait state: ${h.stepCount} steps, ${simMs(h).toFixed(1)} ms simulated, ` +
         `NIA=${h.cpu.psw.getNIA().toString(16)}`);
    check('wait state woke and ran the handler', h.stepCount > 0, true);
    check('wait state kept simulated time running', simMs(h) > 200, true);

    // ...and without real time the wait state still ends (refuses) the run.
    h = mkHarness();
    h.cpu.psw.setWaitState(true);
    h.run();
    check('wait state refuses a free run', h.running, false);
    check('wait state refusal is reported', /wait state/.test(h.statusNote || ''), true);

    // Stepping in the wait state
    //
    h = mkHarness();
    loopAt(h, 0x900);
    h.cpu.psw.setWaitState(true);
    h.cpu.psw._setField2(h.cpu.psw.pack2.desc.f.m, 0x80);
    h.cpu.counter1 = 7000;
    poke16(h.cpu, 0x00B0, 0);
    poke32(h.cpu, 0x0064, 0x09000000);
    poke32(h.cpu, 0x0066, 0x00000000);
    h.step();
    check('step in wait refused without real time', h.cpu.psw.getWaitState(), true);
    h.setRealTime(true);
    h.step();
    check('step in wait reaches the handler', h.cpu.psw.getNIA(), 0x900);
    check('step in wait advances to the expiry', h.cpu.timeNs, 7001 * 1000);

    console.log(`\n${pass} passed, ${fail} failed${skip ? `, ${skip} skipped` : ''}`);
    process.exit(fail ? 1 : 0);
})();
