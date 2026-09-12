// (IBM-85-C67-001 Figure 2-20), the interval-timer interface, the
// stop-before-swap hold, and the IOP registers that feed External 0.
//
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
        `interrupts.${path.basename(entry, '.coffee')}.${process.pid}.cjs`);
    await esbuild.build({
        absWorkingDir: SRC,
        entryPoints: [path.join(SRC, 'src', 'gpc', entry)],
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

(async () => {
    const { CPU }             = await bundle('cpu.coffee');
    // The repertoire and the interrupt codes are gpc/cpu_intr's; the CPU
    // mixes its methods in.  Only values are read from here, so this
    // bundle's copy of the table being a different object than the one
    // inside the CPU bundle does not matter.
    const intrMod             = await bundle('cpu_intr.coffee');
    const { INTERRUPTS }      = intrMod;
    const { RunHarness }      = await bundle('runharness.coffee');
    const { AP101 }           = await bundle('ap101.coffee');

    // Main store comes up store-protected; load it the way the FCM loader does.
    const poke16 = (c, a, v) => c.ram.set16(a, v, false);
    const poke32 = (c, a, v) => c.ram.set32(a, v, false);
    const mkCPU = () => {
        const c = new CPU({ cpuWords: 64 * 1024 });
        // "The following PSA locations must not be store protected ... all
        // old PSW locations" (POO 2.5.2.4) — the swap's own store is
        // protect-checked, so a fully protected PSA would drop it.
        for (let a = 0; a < 0x200; a++) c.mainStorage.setStoreProtect(a, false);
        return c;
    };

    // Put a recognisable new PSW at `newAddr` so an acceptance is visible
    // as an NIA: process state, everything masked.
    const handler = (c, newAddr, nia) => {
        poke32(c, newAddr, nia << 16);
        poke32(c, newAddr + 2, 0x00000000);
    };
    const setMask = (c, v) => c.psw._setField2(c.psw.pack2.desc.f.m, v);

    // The table matches Figure 2-20
    //
    const byKey = {};
    for (const spec of INTERRUPTS) byKey[spec.key] = spec;
    check('table has 12 interrupts', INTERRUPTS.length, 12);
    check('clk1 PSA', `${byKey.clk1.old.toString(16)}/${byKey.clk1.new.toString(16)}`, '60/64');
    check('clk2 PSA', `${byKey.clk2.old.toString(16)}/${byKey.clk2.new.toString(16)}`, '68/6c');
    check('ext0 PSA', `${byKey.ext0.old.toString(16)}/${byKey.ext0.new.toString(16)}`, '78/7c');
    check('ext1 PSA', `${byKey.ext1.old.toString(16)}/${byKey.ext1.new.toString(16)}`, '80/84');
    check('ext2 PSA', `${byKey.ext2.old.toString(16)}/${byKey.ext2.new.toString(16)}`, '88/8c');
    check('ext3 PSA', `${byKey.ext3.old.toString(16)}/${byKey.ext3.new.toString(16)}`, '90/94');
    check('ext4 PSA', `${byKey.ext4.old.toString(16)}/${byKey.ext4.new.toString(16)}`, '98/9c');
    check('instruction monitor is not a program check',
          `${byKey.instrMonitor.old.toString(16)}/${byKey.instrMonitor.new.toString(16)}`, '70/74');
    // AGE shares External 1's PSW pair and mask bit and trails the whole
    // system class -- it is the lowest priority of the twelve.
    check('mask bits 32..39 in order, AGE sharing External 1\'s',
          INTERRUPTS.filter(s => s.cls === 'SYS').map(s => s.maskBit).join(','),
          '32,33,35,36,37,38,39,36');
    check('AGE PSA', `${byKey.age.old.toString(16)}/${byKey.age.new.toString(16)}`, '80/84');
    check('AGE carries interrupt code 0006', byKey.age.code, 0x0006);
    check('system class stays pending when masked',
          INTERRUPTS.filter(s => s.cls === 'SYS').every(s => s.pends), true);
    check('machine check does not stay pending', byKey.machineCheck.pends, false);

    // Mask-bit gating: each system interrupt answers to its own bit
    //
    for (const spec of INTERRUPTS.filter(s => s.cls === 'SYS')) {
        const bit = 1 << (39 - spec.maskBit);
        const c = mkCPU();
        c.psw.setNIA(0x800);
        handler(c, spec.new, 0x900);
        setMask(c, bit);
        c.raiseInterrupt(spec.key);
        c.checkInterrupts();
        check(`${spec.key} taken with mask bit ${spec.maskBit}`, c.psw.getNIA(), 0x900);

        const m = mkCPU();
        m.psw.setNIA(0x800);
        handler(m, spec.new, 0x900);
        setMask(m, bit ^ 0xff);          // every other bit set
        m.raiseInterrupt(spec.key);
        m.checkInterrupts();
        check(`${spec.key} blocked by its own bit only`, m.psw.getNIA(), 0x800);
        check(`${spec.key} still pending while masked`, m.intPending[spec.key], true);
    }

    // The pending register and its enable mask
    //
    // Bit order is priority order: machine check in the top bit of the
    // 12-bit register, AGE in bit 0 below External 4.
    let reg = mkCPU();
    check('register starts clear', reg.intPendingReg, 0);
    reg.raiseInterrupt('machineCheck');
    check('machine check is the top bit', reg.intPendingReg, 1 << 11);
    reg.clearInterrupt('machineCheck');
    reg.raiseInterrupt('age');
    check('AGE is bit 0', reg.intPendingReg, 1);
    reg.clearInterrupt('age');
    reg.raiseInterrupt('ext4');
    check('External 4 is bit 1', reg.intPendingReg, 2);
    check('bits descend in priority order',
          INTERRUPTS.map(s => s.bit).join(','),
          [2048, 1024, 512, 256, 128, 64, 32, 16, 8, 4, 2, 1].join(','));

    // The name-addressable view is the same latches.
    reg.intPending.clk1 = true;
    check('view sets the register bit', (reg.intPendingReg & byKey.clk1.bit) !== 0, true);
    check('view reads back', reg.intPending.clk1, true);
    reg.intPending.clk1 = false;
    check('view clears the register bit', reg.intPendingReg, 2);

    // The enable mask is the PSW's masks permuted into register bits.
    reg = mkCPU();
    setMask(reg, 0x00);
    reg.psw.setMachCheckMask(0);
    check('nothing enabled but the non-maskable pair', reg.intEnableMask(),
          byKey.programCheck.bit | byKey.svc.bit);
    setMask(reg, 0xff);
    reg.psw.setMachCheckMask(1);
    check('everything enabled', reg.intEnableMask(),
          INTERRUPTS.reduce((a, s) => a | s.bit, 0));
    setMask(reg, 0x80);                              // PSW bit 32 only
    reg.psw.setMachCheckMask(0);
    check('mask bit 32 enables timer 1 alone', reg.intEnableMask(),
          byKey.programCheck.bit | byKey.svc.bit | byKey.clk1.bit);
    setMask(reg, 0x20);                              // PSW bit 34 only
    check('mask bit 34 enables the instruction monitor alone', reg.intEnableMask(),
          byKey.programCheck.bit | byKey.svc.bit | byKey.instrMonitor.bit);

    // Search under mask: several pending, the first bit through the mask
    // is the one taken.
    reg = mkCPU();
    reg.psw.setNIA(0x800);
    handler(reg, byKey.clk2.new, 0x900);
    handler(reg, byKey.ext2.new, 0xa00);
    setMask(reg, 0xff ^ 0x40);                       // everything but clk2
    reg.raiseInterrupt('clk2');
    reg.raiseInterrupt('ext2');
    reg.checkInterrupts();
    check('masked bit is searched past', reg.psw.getNIA(), 0xa00);
    check('the masked latch is still set', reg.intPending.clk2, true);

    // Every interrupt in the table is serviced
    //
    // Also the guard on checkInterrupts's fast path: a key missing from it
    // would show up here as an interrupt that is never taken.
    for (const spec of INTERRUPTS) {
        const c = mkCPU();
        c.psw.setNIA(0x800);
        handler(c, spec.new, 0x900);
        setMask(c, 0xff);                // every system interrupt unmasked
        c.psw.setMachCheckMask(1);
        c.raiseInterrupt(spec.key);
        c.checkInterrupts();
        check(`${spec.key} is serviced`, c.psw.getNIA(), 0x900);
        check(`${spec.key} is logged`, c.intCount, 1);
        check(`${spec.key} latch cleared`, c.intPending[spec.key], false);
    }

    // A program check with no handler installed does not swap into a zero
    // PSW — it reports and carries on at the offending instruction's NIA.
    let pc = mkCPU();
    pc.psw.setNIA(0x800);
    pc.raiseInterrupt('programCheck', { code: 0x0002 });
    pc.checkInterrupts();
    check('program check with no handler does not swap', pc.psw.getNIA(), 0x800);
    check('program check with no handler is not logged', pc.intCount, 0);
    check('program check code left in the PSW', pc.psw.getIntCode(), 0x0002);

    // Priority: lowest mask bit first (POO 2.5.2)
    //
    let cpu = mkCPU();
    cpu.psw.setNIA(0x800);
    handler(cpu, 0x0064, 0x900);         // clk1
    handler(cpu, 0x009c, 0xa00);         // ext4
    setMask(cpu, 0xff);
    cpu.raiseInterrupt('ext4');
    cpu.raiseInterrupt('clk1');
    cpu.checkInterrupts();
    check('clk1 outranks ext4', cpu.psw.getNIA(), 0x900);
    check('ext4 held for the next check', cpu.intPending.ext4, true);
    // The handler's own PSW masks everything, which is what holds ext4 off
    // — the chain continues only once the handler unmasks.
    cpu.checkInterrupts();
    check('ext4 held by the handler PSW mask', cpu.psw.getNIA(), 0x900);
    setMask(cpu, 0xff);
    cpu.checkInterrupts();
    check('ext4 taken once unmasked', cpu.psw.getNIA(), 0xa00);

    // Machine check: masked means dropped, not held (2.5.2.3)
    //
    cpu = mkCPU();
    cpu.psw.setNIA(0x800);
    handler(cpu, 0x0044, 0xb00);
    cpu.psw.setMachCheckMask(0);
    cpu.raiseInterrupt('machineCheck');
    cpu.checkInterrupts();
    check('masked machine check not taken', cpu.psw.getNIA(), 0x800);
    check('masked machine check dropped', cpu.intPending.machineCheck, false);
    cpu.psw.setMachCheckMask(1);
    cpu.raiseInterrupt('machineCheck', { code: 0x0003 });
    cpu.checkInterrupts();
    check('machine check taken', cpu.psw.getNIA(), 0xb00);
    check('machine check code in the old PSW',
          cpu.ram.get32(0x0042, false) & 0xffff, 0x0003);

    // Unknown interrupt names are an error, not a silent no-op
    //
    let threw = false;
    try { cpu.raiseInterrupt('iopGrp1'); } catch (e) { threw = true; }
    check('raiseInterrupt rejects an unknown key', threw, true);

    // The log
    //
    cpu = mkCPU();
    cpu.psw.setNIA(0x800);
    handler(cpu, 0x0064, 0x900);
    setMask(cpu, 0x80);
    let hooked = null;
    cpu.onInterrupt = (e) => { hooked = e; };
    cpu.advanceTimeNs(3000);             // 3 us of CPU time
    cpu.raiseInterrupt('clk1');
    cpu.checkInterrupts();
    check('log has one entry', cpu.intLog.length, 1);
    check('log counts acceptances', cpu.intCount, 1);
    check('log entry key', cpu.intLog[0].key, 'clk1');
    check('log entry records the interrupted NIA', cpu.intLog[0].fromNIA, 0x800);
    check('log entry records the handler NIA', cpu.intLog[0].toNIA, 0x900);
    check('log entry records simulated time', cpu.intLog[0].timeNs, 3000);
    check('hook saw the same entry', hooked && hooked.seq, 1);

    cpu.intLogMax = 3;
    for (let i = 0; i < 6; i++) {
        cpu.psw.setNIA(0x800);
        cpu.psw.setIntMask(0x80);
        cpu.raiseInterrupt('clk1');
        cpu.checkInterrupts();
    }
    check('log is a ring', cpu.intLog.length, 3);
    check('ring keeps the newest', cpu.intLog[2].seq, 7);

    // Interval timers
    //
    cpu = mkCPU();
    cpu.loadTimer(1, 0x00021388);        // hi=2, lo=5000
    check('loadTimer sets the PSA half', cpu.ram.get16(0x00B0, false), 2);
    check('loadTimer sets the hardware half', cpu.counter1, 0x1388);
    check('timerValue reads both halves', cpu.timerValue(1), 0x00021388);
    check('timerRemainingUs', cpu.timerRemainingUs(1), 5001 + 2 * 65536);
    cpu.intPending.clk1 = true;
    cpu.loadTimer(1, 100);
    check('loadTimer clears the interrupt latch', cpu.intPending.clk1, false);
    check('nextTimerNs picks the sooner timer', cpu.nextTimerNs(), 101 * 1000);

    // ...and ICR (command 01000 = write counter 1, 00000 = read) goes
    // through the same path.
    cpu = mkCPU();
    cpu.psw.setNIA(0x800);
    cpu.r(1).set32(0x00010064);          // value to load
    cpu.r(2).set32(0b01000 << 27);       // ICR command: write counter 1
    poke16(cpu, 0x800, 0xD9E2);          // ICR R1,R2
    cpu.exec1();
    // The ICR's own 5.5 us of execution time ticks the counter it just
    // loaded, so check the high half exactly and the low half loosely.
    const afterWrite = cpu.timerValue(1);
    check('ICR write loads the high half', afterWrite >>> 16, 1);
    check('ICR write loads the low half', (0x64 - (afterWrite & 0xffff)) <= 8, true);
    cpu.psw.setNIA(0x800);
    cpu.r(2).set32(0b00000 << 27);       // ICR command: read counter 1
    cpu.r(1).set32(0);
    cpu.exec1();
    // The hardware adds two to a counter read (POO sect.10 programming
    // notes), so the register lands two counts above the true value.
    check('ICR read returns both halves, plus the read bias',
          cpu.r(1).get32() >>> 0, (afterWrite + 2) >>> 0);
    // ...and the read does not disturb the count: it only keeps ticking
    // down by the ICR's own 5.5 us of execution time.
    check('ICR read does not reload the counter',
          (afterWrite - cpu.timerValue(1)) > 0 && (afterWrite - cpu.timerValue(1)) <= 10, true);

    // Instruction monitor (mask bit 34)
    //
    cpu = mkCPU();
    cpu.psw.setNIA(0x800);
    poke16(cpu, 0x800, 0x01E2);          // AR R1,R2
    cpu.mainStorage.setStoreProtect(0x800, false);   // monitor watches unprotected code
    handler(cpu, 0x0074, 0xc00);
    handler(cpu, 0x004c, 0xd00);         // program-check handler, to catch a mis-route
    setMask(cpu, 0x20);                  // bit 34 on
    cpu.exec1();
    check('instruction monitor uses its own PSA pair', cpu.psw.getNIA(), 0xc00);

    // System reset (POO 2.5.3.2)
    //
    cpu = mkCPU();
    cpu.raiseInterrupt('ext3');
    cpu.loadTimer(1, 0x1234);
    poke32(cpu, 0x0014, 0x0e000000);
    poke32(cpu, 0x0016, 0x00000000);
    cpu.systemReset();
    check('system reset clears pending', cpu.intPending.ext3, false);
    // "Internal timers are reset to all ones" (2.5.3.2) — the internal
    // (hardware) timer is the low halfword; the high half lives in main
    // store and a reset does not write it.
    check('system reset restores the hardware counters', cpu.counter1, 0xffff);
    check('system reset loads the reset PSW', cpu.psw.getNIA(), 0xe00);

    //
    // A loop at 0x800 with timer 1 due in 2 ms, its handler at 0x900.
    const mkHarness = () => {
        const h = new RunHarness({ machine: 'ap101s' });
        for (const at of [0x800, 0x900]) {
            poke16(h.cpu, at,     0x01E2);           // AR   R1,R2
            poke16(h.cpu, at + 1, 0xC7F0);           // BC   7,at
            poke16(h.cpu, at + 2, at);
        }
        h.cpu.psw.setNIA(0x800);
        setMask(h.cpu, 0x80);
        h.cpu.loadTimer(1, 2000);                    // 2 ms
        handler(h.cpu, 0x0064, 0x900);
        h.cpu.psw.setIntMask(0x80);                  // handler() cleared nothing, be explicit
        return h;
    };
    const runFor = (h, ms) => new Promise((res) => {
        h.onProgress = () => {};
        h.run();
        setTimeout(() => { const running = h.running; h.stop(); res(running); }, ms);
    });

    let h = mkHarness();
    h.setBreakOnInterrupt(true);
    let stillRunning = await runFor(h, 250);
    check('break on interrupt stopped the run', stillRunning, false);
    check('break stopped at the handler', h.cpu.psw.getNIA(), 0x900);
    check('break reported the interrupt', /Interval Timer 1/.test(h.statusNote || ''), true);
    check('break recorded one acceptance', h.cpu.intCount, 1);

    // ...and without it armed, the run carries on through the interrupt.
    h = mkHarness();
    stillRunning = await runFor(h, 250);
    check('unarmed run continues past the interrupt', stillRunning, true);
    check('unarmed run took the interrupt', h.cpu.intCount >= 1, true);

    //
    h = mkHarness();
    h.raiseInterrupt('clk1');
    check('raise while stopped is serviced now', h.cpu.psw.getNIA(), 0x900);
    check('raise while stopped logged it', h.cpu.intCount, 1);
    h.clearInterruptLog();
    check('log cleared', h.cpu.intLog.length, 0);

    // Stop before the PSW swap (the hold)
    //
    // The decision is made in the ordinary way, but nothing of the
    // interrupted state moves until the hold is released.
    cpu = mkCPU();
    cpu.psw.setNIA(0x800);
    handler(cpu, byKey.clk1.new, 0x900);
    setMask(cpu, 0x80);
    poke32(cpu, byKey.clk1.old, 0xdeadbeef);   // old-PSW slot, to watch for a swap
    cpu.setInterruptHold(true);
    cpu.raiseInterrupt('clk1');
    cpu.checkInterrupts();
    check('hold does not swap', cpu.psw.getNIA(), 0x800);
    check('hold does not write the old PSW', cpu.ram.get32(byKey.clk1.old, false) >>> 0, 0xdeadbeef);
    check('hold does not log an acceptance', cpu.intCount, 0);
    check('hold leaves the latch set', cpu.intPending.clk1, true);
    check('hold is visible in intStatus',
          cpu.intStatus().filter(s => s.held).map(s => s.key).join(','), 'clk1');
    let held = cpu.heldInterrupt();
    check('held names the interrupt', held.key, 'clk1');
    check('held records where the machine is', held.fromNIA, 0x800);
    check('held records where the swap would go', held.toNIA, 0x900);
    // A second check makes no new decision: the machine is stopped.
    cpu.raiseInterrupt('ext0');
    cpu.checkInterrupts();
    check('a held machine decides nothing further', cpu.heldInterrupt().key, 'clk1');
    check('...and still has not swapped', cpu.psw.getNIA(), 0x800);

    // Releasing it completes the swap, and only then.
    let entry = cpu.releaseInterrupt();
    check('release takes the interrupt', cpu.psw.getNIA(), 0x900);
    check('release returns the log entry', entry && entry.key, 'clk1');
    check('release writes the old PSW',
          (cpu.ram.get32(byKey.clk1.old, false) >>> 16) & 0xffff, 0x800);
    check('release clears the hold', cpu.intArmed, null);
    check('release logs the acceptance', cpu.intCount, 1);
    check('release clears the latch', cpu.intPending.clk1, false);

    // The hold stays armed for the next one.  (The handler PSW loaded by
    // the swap masks everything, so unmask before looking.)
    setMask(cpu, 0xff);
    cpu.checkInterrupts();
    check('the hold is not one-shot', cpu.heldInterrupt() && cpu.heldInterrupt().key, 'ext0');

    // A decision the operator undoes while the machine sits in front of the
    // swap is re-derived at release, not replayed.
    cpu.clearInterrupt('ext0');
    check('release of a cleared latch takes nothing', cpu.releaseInterrupt(), null);
    check('...and does not swap', cpu.psw.getNIA(), 0x900);
    check('...and discharges the hold', cpu.intArmed, null);

    // exec1 completes a held interrupt itself, so a caller that knows
    // nothing about the hold cannot wedge: the swap happens, then the
    // handler's first instruction runs.
    cpu = mkCPU();
    cpu.psw.setNIA(0x800);
    poke16(cpu, 0x800, 0x01E2);                // AR R1,R2 (at the interrupted program)
    poke16(cpu, 0x900, 0x01E2);                // ...and at the handler
    handler(cpu, byKey.clk1.new, 0x900);
    setMask(cpu, 0x80);
    cpu.setInterruptHold(true);
    cpu.raiseInterrupt('clk1');
    cpu.checkInterrupts();
    check('exec1 starts held', cpu.psw.getNIA(), 0x800);
    cpu.exec1();
    check('exec1 releases the hold', cpu.intArmed, null);
    check('exec1 swaps and runs the handler instruction', cpu.psw.getNIA(), 0x901);

    // A program check is held the same way -- it is decided at the end of
    // the instruction that caused it, so the hold stops with that
    // instruction's NIA still showing.
    cpu = mkCPU();
    cpu.psw.setNIA(0x800);
    handler(cpu, byKey.programCheck.new, 0xd00);
    cpu.setInterruptHold(true);
    cpu.raiseInterrupt('programCheck', { code: 0x0002 });
    cpu.checkInterrupts();
    check('program check is held too', cpu.heldInterrupt().key, 'programCheck');
    check('...with its interrupt code', cpu.heldInterrupt().code, 0x0002);
    check('...and no swap', cpu.psw.getNIA(), 0x800);
    cpu.releaseInterrupt();
    check('released program check swaps', cpu.psw.getNIA(), 0xd00);
    // The code goes where the hardware puts it: the old PSW's low halfword
    // (0x0048 + 2), stored by the swap the hold was standing in front of.
    check('released program check carries its code',
          cpu.ram.get32(byKey.programCheck.old + 2, false) & 0xffff, 0x0002);

    // A vector in another sector: the new PSW's own BSR supplies it, and
    // the held display must expand the NIA the same way a swap does.
    cpu = mkCPU();
    cpu.psw.setNIA(0x800);
    poke32(cpu, byKey.ext1.new, (0x8123 << 16) | 0x0020);   // NIA bit 15 set, BSR = 2
    poke32(cpu, byKey.ext1.new + 2, 0);
    setMask(cpu, 0xff);
    cpu.setInterruptHold(true);
    cpu.raiseInterrupt('ext1');
    cpu.checkInterrupts();
    const predicted = cpu.heldInterrupt().toNIA;
    cpu.releaseInterrupt();
    check('held toNIA matches the swap, expanded sector and all',
          predicted, cpu.psw.getNIA());
    check('...which is the sector-2 address', predicted, (2 << 15) | 0x0123);

    //
    h = mkHarness();
    check('the pane reads the hold off the CPU', h.holdInterrupt, false);
    h.setHoldInterrupt(true);
    check('...and sees it armed', h.holdInterrupt, true);
    stillRunning = await runFor(h, 250);
    check('hold stopped the run', stillRunning, false);
    check('hold stopped before the swap', h.cpu.intCount, 0);
    check('hold left the NIA in the interrupted program',
          h.cpu.psw.getNIA() >= 0x800 && h.cpu.psw.getNIA() <= 0x803, true);
    check('hold reported what it is holding',
          /Interval Timer 1 held before PSW swap/.test(h.statusNote || ''), true);
    check('the pane can see it', h.cpu.heldInterrupt().key, 'clk1');

    // Step from there is the swap itself: it lands on the handler without
    // executing an instruction.
    let stepsBefore = h.stepCount;
    h.step();
    check('step performs the swap', h.cpu.psw.getNIA(), 0x900);
    check('step counted no instruction', h.stepCount, stepsBefore);
    check('step logged the acceptance', h.cpu.intCount, 1);
    check('nothing held after the swap', h.cpu.intArmed, null);

    // ...and run from a hold carries on through the swap instead.
    h = mkHarness();
    h.setHoldInterrupt(true);
    await runFor(h, 250);
    check('run stopped at the hold again', h.cpu.intCount, 0);
    h.setHoldInterrupt(false);
    stillRunning = await runFor(h, 250);
    check('run resumed through the swap', h.cpu.intCount, 1);
    check('run kept running afterwards', stillRunning, true);
    h.stop();

    //
    h = mkHarness();
    let refreshes = 0;
    h.onProgress = () => { refreshes++; };
    h.gpc.exec1 = () => { throw new Error('boom'); };
    h.step();
    check('a step that throws still reports progress', refreshes > 0, true);
    check('...and reports the error', /simulator error/.test(h.statusNote || ''), true);
    check('...naming the instruction it died on', /0x00800/.test(h.statusNote || ''), true);

    //
    h = mkHarness();
    check('mask bit 32 starts enabled', (h.cpu.psw.getIntMask() & 0x80) !== 0, true);
    h.toggleInterruptMask(32);
    check('toggle clears mask bit 32', (h.cpu.psw.getIntMask() & 0x80) !== 0, false);
    h.toggleInterruptMask(32);
    check('toggle restores mask bit 32', (h.cpu.psw.getIntMask() & 0x80) !== 0, true);
    h.toggleInterruptMask(45);
    check('toggle flips the machine-check mask', !!h.cpu.psw.getMachCheckMask(), true);

    // Program check codes are Figure 2-20's, not each other's
    //
    // 0004 and 0007 are the pair worth being sure about: 0004 is FIXED
    // POINT OVERFLOW (and, on the system side of the figure, the Ext 1 DMA
    // store protect violation), 0007 is the CPU's own store protect
    // violation.
    check('illegal operation code',      intrMod.PC_ILLEGAL_OP,       0x0000);
    check('privileged instruction code', intrMod.PC_PRIVILEGED_OP,    0x0001);
    check('address specification code',  intrMod.PC_ADDRESS_SPEC,     0x0002);
    check('fixed point overflow code',   intrMod.PC_FIXED_OVERFLOW,   0x0004);
    check('significance code',           intrMod.PC_SIGNIFICANCE,     0x0005);
    check('store protect violation code',intrMod.PC_STORE_PROTECT,    0x0007);
    check('fp underflow code',           intrMod.PC_FP_UNDERFLOW,     0x0009);
    check('convert overflow code',       intrMod.PC_CONVERT_OVERFLOW, 0x000A);
    check('fp overflow code',            intrMod.PC_FP_OVERFLOW,      0x000B);
    check('fp divide code',              intrMod.PC_FP_DIVIDE,        0x000C);
    check('ext 1 DMA store protect code',intrMod.EXT1_DMA_PROTECT,    0x0004);

    // A store to a protected halfword
    //
    // The store does not happen (POO 2.4), and the program check carries
    // 0007 into the old PSW.
    cpu = mkCPU();
    cpu.psw.setNIA(0x800);
    handler(cpu, byKey.programCheck.new, 0xd00);
    poke16(cpu, 0x2000, 0x1234);
    cpu.mainStorage.setStoreProtect(0x2000, true);
    check('store to a protected halfword is refused', cpu.storeHW(0x2000, 0xbeef), false);
    check('...and does not happen', cpu.ram.get16(0x2000, false), 0x1234);
    check('...and raises a program check', cpu.intPending.programCheck, true);
    check('...with the store protect code', cpu.intCode, 0x0007);
    cpu.psw.setCC(1);
    cpu.psw.setCarry(1);
    cpu.psw.setOverflow(1);
    cpu.checkInterrupts();
    check('the violation is taken', cpu.psw.getNIA(), 0xd00);
    check('the old PSW carries the code',
          cpu.ram.get32(byKey.programCheck.old + 2, false) & 0xffff, 0x0007);
    // Figure 2-20 note '#': CC forced to binary 10, carry and overflow
    // cleared, in the old PSW.
    const oldPSW1 = cpu.ram.get32(byKey.programCheck.old, false);
    check('note # forces CC to 10 in the old PSW', (oldPSW1 >>> 14) & 3, 2);
    check('note # clears carry in the old PSW',    (oldPSW1 >>> 13) & 1, 0);
    check('note # clears overflow in the old PSW', (oldPSW1 >>> 12) & 1, 0);

    // ...and an unprotected store still works, with no interrupt.
    cpu = mkCPU();
    cpu.mainStorage.setStoreProtect(0x2000, false);
    check('an unprotected store happens', cpu.storeHW(0x2000, 0xbeef), true);
    check('...and writes', cpu.ram.get16(0x2000, false), 0xbeef);
    check('...and raises nothing', cpu.intPendingReg, 0);

    // An undecodable halfword is an operation exception
    //
    // The CPU does not stop: it takes a program check with PC_ILLEGAL_OP,
    // skips the halfword, and the handler decides what happens next.
    // C6C6 is the mass memory fill pattern, which is what a CPU that has
    // branched into unloaded storage actually walks through.
    cpu = mkCPU();
    cpu.psw.setNIA(0x800);
    handler(cpu, byKey.programCheck.new, 0xd00);
    poke16(cpu, 0x800, 0xc6c6);
    poke16(cpu, 0x801, 0xc6c6);
    cpu.exec1();
    check('an undecodable halfword is taken as a program check',
          cpu.psw.getNIA(), 0xd00);
    check('...with the illegal operation code',
          cpu.ram.get32(byKey.programCheck.old + 2, false) & 0xffff,
          intrMod.PC_ILLEGAL_OP);
    // NIA is bits 0:15 of PSW1, so the old PSW's copy is its high halfword.
    check('...and the old PSW points past the halfword, not at it',
          (cpu.ram.get32(byKey.programCheck.old, false) >>> 16) & 0xffff, 0x801);

    // A fullword store tests both halves before writing either.
    cpu = mkCPU();
    cpu.mainStorage.setStoreProtect(0x2000, false);
    cpu.mainStorage.setStoreProtect(0x2001, true);
    check('fullword store refused on the odd half', cpu.storeFW(0x2000, 0x11112222), false);
    check('...leaves the even half alone', cpu.ram.get16(0x2000, false), 0);
    check('...and the odd half alone', cpu.ram.get16(0x2001, false), 0);

    // The CC anomaly is per-event, not per-latch
    //
    // An interval timer is not marked '#', so it leaves the CC alone.
    cpu = mkCPU();
    cpu.psw.setNIA(0x800);
    handler(cpu, byKey.clk1.new, 0x900);
    setMask(cpu, 0x80);
    cpu.psw.setCC(1);
    cpu.psw.setCarry(1);
    cpu.raiseInterrupt('clk1');
    cpu.checkInterrupts();
    const timerOld = cpu.ram.get32(byKey.clk1.old, false);
    check('a timer interrupt does not touch the CC', (timerOld >>> 14) & 3, 1);
    check('...or the carry bit', (timerOld >>> 13) & 1, 1);
    // Every machine check is marked '#'.
    cpu = mkCPU();
    cpu.psw.setNIA(0x800);
    handler(cpu, byKey.machineCheck.new, 0xb00);
    cpu.psw.setMachCheckMask(1);
    cpu.psw.setCC(1);
    cpu.psw.setCarry(1);
    cpu.raiseInterrupt('machineCheck');
    cpu.checkInterrupts();
    const mcOld = cpu.ram.get32(byKey.machineCheck.old, false);
    check('a machine check forces CC to 10', (mcOld >>> 14) & 3, 2);
    check('...and clears carry', (mcOld >>> 13) & 1, 0);

    // The storage protect override (ISPB with an illegal M1)
    //
    // "The illegal M1 field patterns leave the storage protect override bit
    // set on ... The condition will occur until the next valid ISPB is
    // executed" (POO 9.2).
    cpu = mkCPU();
    cpu.psw.setNIA(0x800);
    poke16(cpu, 0x800, 0xECFB);           // ISPB 4,X'2000'  (illegal M1)
    poke16(cpu, 0x801, 0x2000);
    poke16(cpu, 0x802, 0xE8FB);           // ISPB 0,X'2000'  (valid: reset the bit)
    poke16(cpu, 0x803, 0x2000);
    cpu.mainStorage.setStoreProtect(0x2000, true);
    cpu.mainStorage.setStoreProtect(0x800, false);
    cpu.mainStorage.setStoreProtect(0x802, false);
    check('override starts off', cpu.storeProtectOverride, false);
    cpu.exec1();                          // the illegal ISPB
    check('an illegal M1 sets the override', cpu.storeProtectOverride, true);
    check('a protected store now happens', cpu.storeHW(0x2000, 0xcafe), true);
    check('...and writes', cpu.ram.get16(0x2000, false), 0xcafe);
    check('...with no violation', cpu.intPending.programCheck, false);
    cpu.exec1();                          // the valid ISPB
    check('a valid ISPB clears the override', cpu.storeProtectOverride, false);
    // (that ISPB also reset 0x2000's protect bit, so protect it again)
    cpu.mainStorage.setStoreProtect(0x2000, true);
    check('and protection is back', cpu.storeHW(0x2000, 0xdead), false);
    check('the violation is the store protect one', cpu.intCode, 0x0007);

    // A fullword ISPB must not lose the top of the address.  An indirect
    // fullword pointer (ZCON) carries all 19 bits of an expanded address,
    // so an ISPB reached through one can name a halfword anywhere in
    // store -- including the last halfword of a high page.  Masking the
    // effective address to 16 bits unprotected a pair down in low memory
    // and left the real target protected, so a store through the same
    // pointer took 0007 immediately afterwards.
    cpu = mkCPU();
    cpu.psw.setNIA(0x800);
    for (let a = 0x800; a < 0x804; a++) cpu.mainStorage.setStoreProtect(a, false);
    cpu.mainStorage.setStoreProtect(0x100, false);
    cpu.mainStorage.setStoreProtect(0x101, false);
    poke32(cpu, 0x100, 0xFFFE0803);        // ZCON: addr15 7FFE, XC=1, C=0, DSR=3
    const zconTarget = (3 << 15) + 0x7FFE; // = 0x1FFFE
    poke16(cpu, 0x800, 0xE9FF);            // ISPB 1,@@X'0100'(1)  (M1 = 001)
    poke16(cpu, 0x801, 0x3900);            // X=1, A=1, I=1, disp = 0x100
    cpu.r(1).set32(0);                     // index contributes nothing
    // Store powers up UNPROTECTED (protection is what a loader asserts over
    // what it loaded), so this test protects its own target and the
    // truncated address it must not touch.
    cpu.mainStorage.setStoreProtect(zconTarget, true);
    cpu.mainStorage.setStoreProtect(zconTarget + 1, true);
    cpu.mainStorage.setStoreProtect(zconTarget & 0xffff, true);
    check('the target starts protected', cpu.ram.getStoreProtect(zconTarget), true);
    cpu.exec1();
    check('a fullword ISPB reaches above 64K',
          cpu.ram.getStoreProtect(zconTarget), false);
    check('...and takes both halfwords of the fullword',
          cpu.ram.getStoreProtect(zconTarget + 1), false);
    check('...without touching the 16-bit truncation of that address',
          cpu.ram.getStoreProtect(zconTarget & 0xffff), true);
    check('...so the store that follows does not fault',
          cpu.storeFW(zconTarget & ~1, 0xffffffff), true);
    check('...and lands where the pointer said',
          cpu.ram.get32(zconTarget & ~1, false) >>> 0, 0xffffffff);
    check('the ISPB raised nothing', cpu.intPending.programCheck, false);

    // A fullword ISPB on an ODD effective address pairs UPWARD
    //
    // POO 9.2's note says the low-order bit "should be 0 and will be
    // ignored".  Read as "mask it off", the pair is (EA-1, EA) and the
    // instruction cannot cover a buffer that begins on an odd halfword.
    // Flight code unprotects a destination with ISPB 1 stepping its index
    // by two from an odd base, and the downward reading leaves one halfword
    // inside the buffer protected, which the MVH two instructions later
    // faults on.  Pairing (EA, EA+1) covers the buffer exactly.
    cpu = mkCPU();
    cpu.psw.setNIA(0x800);
    for (let a = 0x800; a < 0x802; a++) cpu.mainStorage.setStoreProtect(a, false);
    poke16(cpu, 0x800, 0xE9FB);            // ISPB 1,X'2001'  (M1 = 001, odd EA)
    poke16(cpu, 0x801, 0x2001);
    for (const a of [0x2000, 0x2001, 0x2002]) cpu.mainStorage.setStoreProtect(a, true);
    cpu.exec1();
    check('an odd fullword ISPB takes the halfword at the EA',
          cpu.ram.getStoreProtect(0x2001), false);
    check('...and the one above it',
          cpu.ram.getStoreProtect(0x2002), false);
    check('...and not the one below, which is outside the buffer',
          cpu.ram.getStoreProtect(0x2000), true);

    // Instructions that store more than one halfword
    //
    // STM stops at the halfword that faults rather than storing through it.
    cpu = mkCPU();
    cpu.psw.setNIA(0x800);
    poke16(cpu, 0x800, 0xC8FB);           // STM X'2000'
    poke16(cpu, 0x801, 0x2000);
    cpu.mainStorage.setStoreProtect(0x800, false);
    for (let a = 0x2000; a < 0x2010; a++) cpu.mainStorage.setStoreProtect(a, false);
    cpu.mainStorage.setStoreProtect(0x2004, true);      // R2's high half
    for (let i = 0; i < 8; i++) cpu.r(i).set32(0x1000 + i);
    cpu.exec1();
    check('STM stored R0', cpu.ram.get16(0x2001, false), 0x1000);
    check('STM stored R1', cpu.ram.get16(0x2003, false), 0x1001);
    check('STM stopped at the protected halfword', cpu.ram.get16(0x2005, false), 0);
    check('STM did not store past it', cpu.ram.get16(0x2007, false), 0);
    check('STM raised the violation', cpu.intCode, 0x0007);

    // TS reads-and-writes one halfword; the write is protect-checked too.
    cpu = mkCPU();
    cpu.psw.setNIA(0x800);
    poke16(cpu, 0x800, 0xB8FB);           // TS X'2000'
    poke16(cpu, 0x801, 0x2000);
    cpu.mainStorage.setStoreProtect(0x800, false);
    poke16(cpu, 0x2000, 0x0000);
    cpu.mainStorage.setStoreProtect(0x2000, true);
    cpu.exec1();
    check('TS left the protected halfword alone', cpu.ram.get16(0x2000, false), 0x0000);
    check('TS raised the violation', cpu.intCode, 0x0007);

    // Note 1: fixed point overflow status is held in PSW bit 19
    //
    // "If a PSW with both Fixed Point Overflow Indicator and mask (bits 19
    // and 20) set is used, the interrupt will occur" (POO 2.5.2.3).
    cpu = mkCPU();
    cpu.loadPSW(0x00000000 | (1 << 12) | (1 << 11), 0);   // bits 19 and 20
    check('a PSW with bits 19+20 set raises fixed point overflow',
          cpu.intPending.programCheck, true);
    check('...with the fixed point overflow code', cpu.intCode, 0x0004);
    cpu = mkCPU();
    cpu.loadPSW(1 << 12, 0);                              // indicator, no mask
    check('the indicator alone raises nothing', cpu.intPending.programCheck, false);
    cpu = mkCPU();
    cpu.loadPSW(1 << 11, 0);                              // mask, no indicator
    check('the mask alone raises nothing', cpu.intPending.programCheck, false);

    // The indicator is set whether or not the interrupt is enabled -- it is
    // the latch, not a by-product of taking the interrupt.
    cpu = mkCPU();
    cpu.psw.setFixedPtOverflow(0);
    cpu.signalFixedOverflow();
    check('an overflow sets the indicator with the mask off', cpu.psw.getOverflow(), 1);
    check('...and raises nothing', cpu.intPending.programCheck, false);
    cpu = mkCPU();
    cpu.psw.setFixedPtOverflow(1);
    cpu.signalFixedOverflow();
    check('an overflow with the mask on raises it', cpu.intPending.programCheck, true);
    check('...with code 0004', cpu.intCode, 0x0004);

    // SPM sets the indicator and its mask together, which is the same case.
    // (with a handler armed, since exec1 services the interrupt it raises)
    cpu = mkCPU();
    cpu.psw.setNIA(0x800);
    handler(cpu, byKey.programCheck.new, 0xd00);
    poke16(cpu, 0x800, 0xC8E9);           // SPM 1
    cpu.r(1).set32(0x00001800);           // bits 16-23 = 0x18: overflow + mask
    cpu.exec1();
    check('SPM raised fixed point overflow', cpu.psw.getNIA(), 0xd00);
    check('...with code 0004',
          cpu.ram.get32(byKey.programCheck.old + 2, false) & 0xffff, 0x0004);
    const spmOld = cpu.ram.get32(byKey.programCheck.old, false);
    check('SPM set the overflow indicator', (spmOld >>> 12) & 1, 1);
    check('SPM set the overflow mask', (spmOld >>> 11) & 1, 1);
    // ...and this one is not marked '#', so the CC survives into the old PSW.
    check('a fixed point overflow leaves the CC alone', (spmOld >>> 14) & 3, 0);

    // Fixed point add/subtract indicators
    //
    // The POO says the same two things under every one of these: "the
    // carry indicator is set to indicate whether or not there is a carry
    // out of the high-order bit position", and the overflow indicator "is
    // not altered by this instruction" once it contains a one.  So carry
    // is written every time and overflow only ever set.  The case that
    // separates the two is FFFF + 2 with overflow already primed: it
    // carries out, does not signed-overflow, and must leave the primed
    // overflow indicator alone -- so BOV, BOC and BP all branch.
    const AR  = (r1, r2) => (0b00000 << 11) | (r1 << 8) | (0b11100 << 3) | r2;
    const SR  = (r1, r2) => (0b00001 << 11) | (r1 << 8) | (0b11100 << 3) | r2;
    const LCR = (r1, r2) => (0b11101 << 11) | (r1 << 8) | (0b11101 << 3) | r2;
    const AHI = (r2)     => (0b10110 << 11) | (0b000 << 8) | (0b11100 << 3) | r2;

    cpu = mkCPU();
    cpu.psw.setNIA(0x10);
    poke16(cpu, 0x10, AHI(3));
    poke16(cpu, 0x11, 0x0002);
    cpu.r(3).set32(0xffff0000);
    cpu.psw.setOverflow(1);                  // "OFLOW SET AT ENTRY"
    cpu.psw.setCarry(0);
    cpu.exec1();
    check('AHI adds the immediate as the upper halfword',
          cpu.r(3).get32() >>> 0, 0x00010000);
    check('...leaves an overflow indicator it did not set', cpu.psw.getOverflow(), 1);
    check('...sets carry from the carry out', cpu.psw.getCarry(), 1);
    check('...and the result is positive', cpu.psw.getCC(), 1);

    // Carry is written every time, so an add without a carry out clears it.
    cpu.psw.setNIA(0x10);
    cpu.r(3).set32(0x00010000);
    cpu.exec1();
    check('an add with no carry out clears carry', cpu.psw.getCarry(), 0);
    check('...and overflow is still where it was', cpu.psw.getOverflow(), 1);

    // A real signed overflow sets the indicator (and, masked on, interrupts).
    cpu = mkCPU();
    cpu.psw.setNIA(0x10);
    poke16(cpu, 0x10, AR(1, 2));
    cpu.r(1).set32(0x7fffffff);
    cpu.r(2).set32(0x00000001);
    cpu.psw.setOverflow(0);
    cpu.psw.setFixedPtOverflow(1);           // mask on: the interrupt is enabled
    cpu.exec1();
    check('AR into the sign bit is an overflow', cpu.psw.getOverflow(), 1);
    check('...with no carry out of the top', cpu.psw.getCarry(), 0);
    check('...and raises the program check', cpu.intCode, 0x0004);

    // Subtraction runs through the same adder: a + ~b + 1, so the carry
    // out is the borrow's complement -- set when no borrow was needed.
    cpu = mkCPU();
    cpu.psw.setNIA(0x10);
    poke16(cpu, 0x10, SR(1, 2));
    cpu.r(1).set32(0x00005000);
    cpu.r(2).set32(0x00001000);
    cpu.exec1();
    check('SR subtracts', cpu.r(1).get32() >>> 0, 0x00004000);
    check('...with carry set when nothing was borrowed', cpu.psw.getCarry(), 1);
    cpu.psw.setNIA(0x10);
    cpu.r(1).set32(0x00001000);
    cpu.r(2).set32(0x00005000);
    cpu.exec1();
    check('...and clear when a borrow was', cpu.psw.getCarry(), 0);
    check('...leaving a negative result', cpu.psw.getCC(), 3);

    // LCR negates, and is documented with the same indicator rules.
    cpu = mkCPU();
    cpu.psw.setNIA(0x10);
    poke16(cpu, 0x10, LCR(1, 2));
    cpu.r(2).set32(0x00000001);
    cpu.exec1();
    check('LCR negates', cpu.r(1).get32() >>> 0, 0xffffffff);
    check('...and writes carry', cpu.psw.getCarry(), 0);

    // Extended-precision multiply and divide differ by machine
    //
    // The AP-101B forms "quasi-extended" operands before an extended
    // multiply OR an extended divide, "truncating the fraction portion to
    // 31 bits and then rounding into the 31st bit based upon the 32nd bit"
    // (IBM-6246156B 8-25).  The AP-101S does neither: its multiply sums
    // "the three most significant fullword partial sum pairs" of the full
    // 56-bit fractions (IBM-85-C67-001 8.x) -- i.e. every partial product
    // but the least significant -- and its divide keeps all 56 quotient
    // bits.  Short multiply and short divide are the same on both.
    //
    // Both are checked against references written here from those
    // descriptions alone, in BigInt, so a bug would have to be made twice
    // in two different styles to pass.  Operands are chosen to exercise
    // the interesting paths: a product needing postnormalization, and a
    // fraction whose rounding carries out of the 56-bit field.
    const M56 = (1n << 56n) - 1n;
    const unpack = (w) => ({
        sign: w[0] >>> 31,
        ch:   (w[0] >>> 24) & 0x7f,
        frac: (BigInt(w[0] & 0xffffff) << 32n) | BigInt(w[1] >>> 0),
    });
    const pack = (sign, ch, frac) => [
        ((sign << 31) | ((ch & 0x7f) << 24) | Number(frac >> 32n)) >>> 0,
        Number(frac & 0xffffffffn) >>> 0,
    ];
    const fmt = (w) => `${(w[0] >>> 0).toString(16).toUpperCase().padStart(8, '0')} ` +
                       `${(w[1] >>> 0).toString(16).toUpperCase().padStart(8, '0')}`;

    // The AP-101B's quasi-extended operand: 31 bits, rounded in from the 32nd.
    const qe31 = (frac, ch) => {
        let r = frac + (1n << 24n);
        if (r >> 56n) { r >>= 4n; ch += 1; }        // carry renormalizes
        return [r & M56 & ~((1n << 25n) - 1n), ch];
    };
    // Exact 112-bit fraction product, for reference and for error bounds.
    const exactProd = (x, y) => {
        let ch = x.ch + y.ch - 64, p = x.frac * y.frac;
        let frac = p >> 56n;
        if (!(frac >> 52n)) { frac = p >> 52n; ch -= 1; }   // postnormalize
        return { ch, frac: frac & M56 };
    };
    const refMulB = (xw, yw) => {          // AP-101B: quasi-extended operands
        const x = unpack(xw), y = unpack(yw);
        const [xf, xc] = qe31(x.frac, x.ch), [yf, yc] = qe31(y.frac, y.ch);
        let ch = xc + yc - 64;
        let t = ((xf >> 25n) * (yf >> 25n)) >> 6n;
        if (!(t >> 52n)) { t = t << 4n; ch -= 1; }   // postnormalize, zero fill
        return pack(x.sign ^ y.sign, ch, t & M56);
    };
    const refMulS = (xw, yw) => {          // S: all partial products but BD
        const x = unpack(xw), y = unpack(yw);
        const a = x.frac >> 28n, b = x.frac & ((1n << 28n) - 1n);
        const c = y.frac >> 28n, d = y.frac & ((1n << 28n) - 1n);
        const p = ((a * c) << 56n) + ((a * d + b * c) << 28n);
        let ch = x.ch + y.ch - 64, frac = p >> 56n;
        if (!(frac >> 52n)) { frac = p >> 52n; ch -= 1; }
        return pack(x.sign ^ y.sign, ch, frac & M56);
    };
    const refDiv = (xw, yw, qe) => {
        const x = unpack(xw), y = unpack(yw);
        let [xf, xc] = qe ? qe31(x.frac, x.ch) : [x.frac, x.ch];
        let [yf, yc] = qe ? qe31(y.frac, y.ch) : [y.frac, y.ch];
        // One truncating division, positioned so the quotient is 14 digits.
        let ch, q;
        if (xf < yf) { ch = xc - yc + 64; q = (xf << 56n) / yf; }
        else         { ch = xc - yc + 65; q = (xf << 52n) / yf; }
        // The AP-101B's quotient register holds 31 bits; the rest reads zero.
        if (qe) q &= ~((1n << 25n) - 1n);
        return pack(x.sign ^ y.sign, ch, q & M56);
    };

    const OPA = [0x41A3B5C7, 0xD9E1F204];   // 0.A3B5C7D9E1F204 x 16^1
    const OPB = [0x40B1C2D3, 0xE4F50617];
    const OPC = [0x412A3B4C, 0x5D6E7F81];   // small enough that OPC x OPD
    const OPD = [0x403C4D5E, 0x6F708192];   //   needs postnormalizing
    const OPE = [0x40FFFFFF, 0xFF800000];   // rounding carries out of 56 bits

    // RX forms with dddddd=111110, bb=11 -- an address halfword follows.
    const LEDw  = (f) => (0b01111 << 11) | (f << 8) | (0b11111 << 3) | 0b11;
    const MEDw  = (f) => (0b00110 << 11) | (f << 8) | (0b11111 << 3) | 0b11;
    const LERw  = (a, b) => (0b01111 << 11) | (a << 8) | (0b11100 << 3) | b;
    const MERw  = (a, b) => (0b01100 << 11) | (a << 8) | (0b11100 << 3) | b;
    const DEDRw = (a, b) => (0b00010 << 11) | (a << 8) | (0b11101 << 3) | b;

    // Run MED and DEDR on the CPU itself, so the per-machine dispatch is
    // covered and not just the arithmetic underneath it.
    const fpRun = (fpModel, x, y) => {
        const c = mkCPU();
        c.fpModel = fpModel;
        poke32(c, 0x40, x[0]); poke32(c, 0x42, x[1]);
        poke32(c, 0x44, y[0]); poke32(c, 0x46, y[1]);
        let pc = 0x10;
        const emit = (w, h2) => { poke16(c, pc++, w); if (h2 !== undefined) poke16(c, pc++, h2); };
        emit(LEDw(0), 0x40); emit(MEDw(0), 0x44);        // F0 = x * y
        emit(LEDw(2), 0x40); emit(LEDw(4), 0x44);
        emit(DEDRw(2, 4));                               // F2 = x / y
        emit(LERw(6, 0)); emit(MERw(6, 6));              // F6,7 = short square
        c.psw.setNIA(0x10);
        const pair = (f) => [c.f(f).get32() >>> 0, c.f(f + 1).get32() >>> 0];
        for (let i = 0; i < 7; i++) c.exec1();
        return { med: pair(0), dedr: pair(2), mer: pair(6) };
    };

    const runB = fpRun('B', OPA, OPB), runS = fpRun('S', OPA, OPB);
    check('AP-101B extended multiply is quasi-extended',
          fmt(runB.med), fmt(refMulB(OPA, OPB)));
    check('S extended multiply keeps the upper partial products',
          fmt(runS.med), fmt(refMulS(OPA, OPB)));
    check('AP-101B extended divide is quasi-extended too',
          fmt(runB.dedr), fmt(refDiv(OPA, OPB, true)));
    check('S extended divide keeps all 56 quotient bits',
          fmt(runS.dedr), fmt(refDiv(OPA, OPB, false)));
    check('...and the AP-101B quotient really is only 31 bits wide',
          (runB.dedr[1] & 0x01ffffff) >>> 0, 0);
    check('the two machines really do differ', fmt(runB.med) === fmt(runS.med), false);
    check('...on the divide as well', fmt(runB.dedr) === fmt(runS.dedr), false);

    // Truncating each operand to 31 bits costs far more than dropping one
    // partial product does: the S lands within an ulp of the exact
    // product, the AP-101B is millions of ulps away.  That asymmetry is the
    // whole reason the two machines disagree.
    const exact = exactProd(unpack(OPA), unpack(OPB));
    const errOf = (w) => {
        const g = unpack(w);
        return g.ch === exact.ch ? (exact.frac > g.frac ? exact.frac - g.frac
                                                        : g.frac - exact.frac) : -1n;
    };
    check('S multiply is within an ulp of the exact product',
          errOf(runS.med) <= 1n, true);
    check('...and the AP-101B is millions of ulps out',
          errOf(runB.med) > 0x100000n, true);

    // A product below 1/16 postnormalizes, and the vacated low-order
    // digit is filled with ZEROS -- the AP-101B does not reach back into the
    // discarded part of the product for four more bits.
    const post = fpRun('B', OPC, OPD);
    check('a postnormalizing product still matches the AP-101B reference',
          fmt(post.med), fmt(refMulB(OPC, OPD)));
    check('...and it really did postnormalize',
          unpack(post.med).ch, unpack(OPC).ch + unpack(OPD).ch - 64 - 1);

    // Rounding an operand into bit 31 can carry out of the fraction, and
    // that renormalizes: the fraction becomes 0.1 and the characteristic
    // steps up (POO programming note).
    const carry = fpRun('B', OPE, OPE);
    check('an operand whose rounding carries out renormalizes',
          fmt(carry.med), fmt(refMulB(OPE, OPE)));
    check('...to exactly one', fmt(carry.med), '41100000 00000000');

    // MULTIPLY (SHORT OPERANDS): "the product fraction has the full 14
    // digits of the long format ... If R1 is even, the least significant
    // part of the product fraction replaces the contents of floating
    // point register R1+001" (POO 8.25).  An odd R1 keeps only the short
    // result -- which is why R1 parity shows up in the instruction timing.
    check('short multiply into an even register writes the pair',
          runB.mer[1] !== 0, true);
    // There is no F8 to spill into, so an odd R1 that tried to write the
    // pair would fault the simulator rather than the guest.
    const oddC = mkCPU();
    poke16(oddC, 0x10, LERw(7, 0)); poke16(oddC, 0x11, MERw(7, 7));
    oddC.f(0).set32(OPA[0]);
    oddC.psw.setNIA(0x10);
    let oddErr = null;
    try { oddC.exec1(); oddC.exec1(); } catch (e) { oddErr = e; }
    check('...and into an odd register writes only the short result', oddErr, null);
    check('...which is the product, not the multiplicand',
          oddC.f(7).get32() >>> 0, refMulS([OPA[0], 0], [OPA[0], 0])[0]);

    // A CPU's arithmetic comes from the machine it is part of.
    check('an AP-101S does the S arithmetic',
          new CPU({ cpuWords: 1024, model: 'S' }).fpModel, 'S');
    check('an AP-101B does the B arithmetic',
          new CPU({ cpuWords: 1024, model: 'B' }).fpModel, 'B');
    check('and a bare CPU is the machine this simulator exists to run',
          new CPU({ cpuWords: 1024 }).fpModel, 'S');

    // Shifts: carry, and the (R1+1) mod 8 register pair
    //
    // "The carry indicator is set to one for each one, and to zero for
    // each zero, shifted left from the high-order bit position", so carry
    // ends up holding the last bit to leave bit 0.  The condition code and
    // the overflow indicator are not touched.
    const SLL  = (r1, n) => (0b11110 << 11) | (r1 << 8) | (n << 2);
    const SLDL = (r1, n) => (0b11111 << 11) | (r1 << 8) | (n << 2);
    const SRDL = (r1, n) => (0b11111 << 11) | (r1 << 8) | (n << 2) | 0b10;
    const SRDR = (r1, n) => (0b11111 << 11) | (r1 << 8) | (n << 2) | 0b11;

    const shift = (word, setup) => {
        const c = mkCPU();
        c.psw.setNIA(0x10);
        poke16(c, 0x10, word);
        setup(c);
        c.exec1();
        return c;
    };

    let sh = shift(SLL(5, 31), (c) => { c.r(5).set32(0xffffffff); c.psw.setCarry(0); c.psw.setCC(2); });
    check('SLL 31 leaves the sign bit', sh.r(5).get32() >>> 0, 0x80000000);
    check('...with carry from the last bit out', sh.psw.getCarry(), 1);
    check('...and the condition code untouched', sh.psw.getCC(), 2);
    sh = shift(SLL(5, 1), (c) => { c.r(5).set32(0x40000000); c.psw.setCarry(1); });
    check('a zero shifted out clears carry', sh.psw.getCarry(), 0);
    sh = shift(SLL(5, 32), (c) => { c.r(5).set32(0x00000001); c.psw.setCarry(0); });
    check('a shift of 32 empties the register', sh.r(5).get32() >>> 0, 0);
    check('...with carry from the last bit, the low one', sh.psw.getCarry(), 1);
    sh = shift(SLL(5, 33), (c) => { c.r(5).set32(0xffffffff); c.psw.setCarry(1); });
    check('past 32 only zeros are left to shift out', sh.psw.getCarry(), 0);
    sh = shift(SLL(5, 0), (c) => { c.r(5).set32(0x12345678); c.psw.setCarry(1); });
    check('a shift of zero moves nothing', sh.r(5).get32() >>> 0, 0x12345678);
    check('...and leaves carry alone', sh.psw.getCarry(), 1);

    // The pair, shifted as one 64-bit register: a rotate right 21
    // followed by a double shift left 1, which walks bits across the
    // register boundary in both directions.
    const c2 = mkCPU();
    c2.psw.setNIA(0x10);
    poke16(c2, 0x10, SRDR(4, 21));
    poke16(c2, 0x11, SLDL(4, 1));
    c2.r(4).set32(0x01234567);            // 0123456789ABCDEF as one pair
    c2.r(5).set32(0x89ABCDEF);
    c2.exec1();
    check('SRDR rotates the pair as 64 bits', c2.r(4).get32() >>> 0, 0x5E6F7809);
    check('...both halves', c2.r(5).get32() >>> 0, 0x1A2B3C4D);
    c2.exec1();
    check('SLDL shifts the pair as 64 bits', c2.r(4).get32() >>> 0, 0xBCDEF012);
    check('...carrying the top of the low register into the high one',
          c2.r(5).get32() >>> 0, 0x3456789A);

    // "(R1 and (R1+1) mod 8)": R7 pairs with R0, not with a ninth register.
    sh = shift(SLDL(7, 1), (c) => { c.r(7).set32(0); c.r(0).set32(0x80000000); });
    check('SLDL R7 takes its partner from R0', sh.r(7).get32() >>> 0, 1);
    check('...and shifts it', sh.r(0).get32() >>> 0, 0);
    sh = shift(SRDL(7, 1), (c) => { c.r(7).set32(1); c.r(0).set32(0); });
    check('SRDL R7 pairs with R0 too', sh.r(0).get32() >>> 0, 0x80000000);
    sh = shift(SRDR(7, 1), (c) => { c.r(7).set32(1); c.r(0).set32(0); });
    check('...as does the rotate', sh.r(0).get32() >>> 0, 0x80000000);

    // XUL exchanges halfwords; it is not an exclusive-OR
    //
    // "The upper halfword of general register R1 is exchanged with the lower
    // halfword of general register R2 ... while simultaneously bits 16
    // through 31 of general register R2 replace bits 0 through 15 of general
    // register R1" (POO 4.11).  Naming one register twice therefore swaps
    // its own halves -- which is how software moves a halfword immediate,
    // loaded into the upper half, down to where a fullword consumer wants
    // it.  Getting this wrong loads such a consumer with the value in BOTH
    // halves, which for an interval timer is a wait of about 213 seconds
    // instead of a few milliseconds.
    const XUL = (r1, r2) => (0b00000 << 11) | (r1 << 8) | (0b11101 << 3) | r2;
    const xul = (r1, r2, v1, v2) => {
        const c = mkCPU();
        c.psw.setNIA(0x10);
        poke16(c, 0x10, XUL(r1, r2));
        c.r(r1).set32(v1); c.r(r2).set32(v2);
        c.exec1();
        return [c.r(r1).get32() >>> 0, c.r(r2).get32() >>> 0];
    };
    check('XUL Rn,Rn swaps that register\'s halves',
          xul(2, 2, 0x0cb60000, 0x0cb60000)[0], 0x00000cb6);
    check('...and the other way round',
          xul(2, 2, 0x00000cb6, 0x00000cb6)[0], 0x0cb60000);
    const [x1, x2] = xul(1, 2, 0x11112222, 0x33334444);
    check('XUL R1,R2 gives R1 the low half of R2', x1, 0x44442222);
    check('...and R2 the high half of R1', x2, 0x33331111);

    // LDM/STDM carry one DSE per byte
    //
    // The fullword the four Data Sector Extensions travel in puts each one
    // in the LOW half of its own byte -- R0's in bits 4-7, R1's in 12-15,
    // R2's in 20-23, R3's in 28-31 -- with the high half of each byte an
    // op-code extension that "should be set to zero" (POO 9.13/9.15).  Read
    // as four nibbles running along the top halfword instead, R0 and R1 come
    // out of the padding and R2 and R3 land on the wrong registers entirely.
    const LDMw  = (0b01101 << 11) | (0b11111 << 3) | 0b11;
    const STDMw = (0b10010 << 11) | (0b11111 << 3) | 0b11;
    const dse = mkCPU();
    // Padding set to ones: it must be ignored going in, and zero coming out.
    poke32(dse, 0x40, 0xfafbfcfd);
    poke16(dse, 0x10, LDMw);  poke16(dse, 0x11, 0x40);
    poke16(dse, 0x12, STDMw); poke16(dse, 0x13, 0x44);
    dse.psw.setNIA(0x10);
    dse.psw.setCC(2);
    dse.exec1();
    const dseRegs = dse.regFiles[dse.psw.getRegSet()];
    check('LDM takes R0\'s DSE from bits 4-7',   dseRegs.getDSE(0), 0xa);
    check('...R1\'s from bits 12-15',            dseRegs.getDSE(1), 0xb);
    check('...R2\'s from bits 20-23',            dseRegs.getDSE(2), 0xc);
    check('...R3\'s from bits 28-31',            dseRegs.getDSE(3), 0xd);
    check('...and leaves the condition code alone', dse.psw.getCC(), 2);
    dse.exec1();
    check('STDM writes the same layout back, padding zeroed',
          dse.ram.get32(0x44) >>> 0, 0x0a0b0c0d);
    check('...without touching the condition code either', dse.psw.getCC(), 2);

    // Bits 5-7 of LDM/STDM carry whatever register the source named
    //
    // The flight assembler encodes the R1 operand into the op-code
    // extension the POO fixes at zero: GPCIPL's self-test has `LDM
    // R3,EXTDATA3` as 6BF8 and `STDM R1,EXTTEMP` as 91F8 (the OI301700
    // build listing of BILDNEW5).  Both decode as the two-halfword LDM and
    // STDM; a decoder that insists on the zeros runs 6BF8 as a
    // one-halfword L R3 and then executes the displacement.  B2=3 here
    // (no base), so the DSE the LDM loads into R0 does not enter the
    // STDM's address.
    const fl = mkCPU();
    poke32(fl, 0x40, 0x0a0b0c0d);
    poke16(fl, 0x10, 0x6bfb);  poke16(fl, 0x11, 0x40);
    poke16(fl, 0x12, 0x91fb);  poke16(fl, 0x13, 0x44);
    fl.psw.setNIA(0x10);
    fl.exec1();
    const flRegs = fl.regFiles[fl.psw.getRegSet()];
    check('6BFB is LDM: two halfwords',            fl.psw.getNIA(), 0x12);
    check('...and loads the DSEs',                 flRegs.getDSE(3), 0xd);
    fl.exec1();
    check('91FB is STDM: two halfwords',           fl.psw.getNIA(), 0x14);
    check('...and stores them',                    fl.ram.get32(0x44) >>> 0, 0x0a0b0c0d);

    // ...but there is a DSE for every register, not just those four
    //
    // LDM/STDM carry four because only R0-R3 can be base registers; LXA
    // loads "the DSE associated with R1" for whichever register it names,
    // and STXA reads it back.  So an LXA into R4-R7 must leave the four
    // that STDM stores completely alone -- folding its register number
    // down onto R0-R3 would silently rewrite a sector extension the
    // program is still addressing through.
    const LXAw = (r) => (0b01000 << 11) | (r << 8) | (0b11111 << 3) | 0b11;
    const hi = mkCPU();
    poke32(hi, 0x40, 0x0a0b0c0d);          // the four DSEs LDM loads
    poke32(hi, 0x48, 0x12340006);          // address constant, DSE field 6
    poke16(hi, 0x10, LDMw);     poke16(hi, 0x11, 0x40);
    poke16(hi, 0x12, LXAw(6));  poke16(hi, 0x13, 0x48);
    poke16(hi, 0x14, STDMw);    poke16(hi, 0x15, 0x44);
    hi.psw.setNIA(0x10);
    hi.exec1(); hi.exec1(); hi.exec1();
    const hiRegs = hi.regFiles[hi.psw.getRegSet()];
    check('LXA R6 loads R6 from bits 1-15', hi.r(6).get32() >>> 0, 0x12340000);
    check('...and R6 gets its own DSE', hiRegs.getDSE(6), 6);
    check('...while the four STDM stores are untouched',
          hi.ram.get32(0x44) >>> 0, 0x0a0b0c0d);
    check('...R2\'s in particular, which 6 & 3 would have hit', hiRegs.getDSE(2), 0xc);
    // An LXA into one of the four does show up there, so the check above
    // is not just measuring an LXA that never wrote anything.
    poke16(hi, 0x16, LXAw(2));  poke16(hi, 0x17, 0x48);
    poke16(hi, 0x18, STDMw);    poke16(hi, 0x19, 0x4c);
    hi.exec1(); hi.exec1();
    check('LXA R2 does reach the stored word', hi.ram.get32(0x4c) >>> 0, 0x0a0b060d);

    // STXA/STXAR build a fullword address constant
    //
    // "Bit 0 of the second operand is set to one, bits 1 through 15 are
    // replaced by bits 1 through 15 of R1, bits 28 through 31 are replaced
    // by the contents of R1 DSE, bits 16 through 19 are set to zero, and
    // bits 20 through 27 are unchanged and ignored" (POO 9.14).  That last
    // clause makes it a read-modify-write: the flag bits an address
    // constant carries in 20-27 belong to the destination and survive.
    const STXARw = (r1, r2) => (0b10100 << 11) | (r1 << 8) | (0b11101 << 3) | r2;
    const STXAw  = (r1)     => (0b10100 << 11) | (r1 << 8) | (0b11111 << 3) | 0b11;
    const sx = mkCPU();
    poke32(sx, 0x40, 0x2468000a);          // LXA source: address 2468, DSE a
    poke16(sx, 0x10, LXAw(7)); poke16(sx, 0x11, 0x40);
    poke16(sx, 0x12, STXARw(7, 6));
    sx.psw.setNIA(0x10);
    sx.exec1();                            // LXA R7 -> DSE7 = a
    sx.r(7).set32(0x12345678);
    sx.r(6).set32(0x0f0f0f0f);
    sx.psw.setCC(1);
    sx.exec1();                            // STXAR R7,R6
    check('STXAR sets bit 0, takes the address from R1, keeps 20-27, adds the DSE',
          sx.r(6).get32() >>> 0, 0x92340f0a);
    check('...and does not touch the condition code', sx.psw.getCC(), 1);

    // The memory form does the same, reading the destination for 20-27.
    const sm = mkCPU();
    poke32(sm, 0x40, 0x2468000a);
    poke32(sm, 0x44, 0x0f0f0f0f);          // destination, for its bits 20-27
    poke16(sm, 0x10, LXAw(7)); poke16(sm, 0x11, 0x40);
    poke16(sm, 0x12, STXAw(7)); poke16(sm, 0x13, 0x44);
    sm.psw.setNIA(0x10);
    sm.exec1();
    sm.r(7).set32(0x12345678);
    sm.exec1();
    check('STXA writes the same constant to storage',
          sm.ram.get32(0x44) >>> 0, 0x92340f0a);

    // An STXA naming R2 has the same 16 bits as an indexed SHW, whose R1
    // field is really an opcode extension of 010.  The escape (11111) is
    // what tells them apart, and the decoder has to prefer the pattern
    // that pins more bits down -- otherwise this stores FFFF somewhere.
    const amb = mkCPU();
    poke32(amb, 0x40, 0x2468000a);
    poke32(amb, 0x44, 0x00000000);
    poke16(amb, 0x10, LXAw(2)); poke16(amb, 0x11, 0x40);
    poke16(amb, 0x12, STXAw(2)); poke16(amb, 0x13, 0x44);
    amb.psw.setNIA(0x10);
    amb.exec1();
    amb.r(2).set32(0x12345678);
    amb.exec1();
    check('STXA R2 decodes as STXA, not as the SHW sharing its opcode',
          amb.ram.get32(0x44) >>> 0, 0x9234000a);
    check('...and consumed both halfwords', amb.psw.getNIA(), 0x14);

    // The IOP's store protect violation is a different interrupt
    //
    // Figure 2-20 priority 51: External 1, code 0004, raised by the CPU for
    // the IOP's access.  The store does not happen.
    const mkGPC = () => {
        const g = new AP101({ machine: 'ap101s' });
        for (let a = 0; a < 0x200; a++) g.cpu.mainStorage.setStoreProtect(a, false);
        return g;
    };
    let gpc = mkGPC();
    gpc.cpu.psw.setNIA(0x800);
    handler(gpc.cpu, byKey.ext1.new, 0xe00);
    setMask(gpc.cpu, 0x08);                    // mask bit 36 = External 1
    gpc.cpu.mainStorage.setStoreProtect(0x2000, true);
    check('an IOP store to a protected halfword is refused',
          gpc.iop.writeMain16(0x2000, 0x1234), false);
    check('...and does not happen', gpc.cpu.mainStorage.get16(0x2000, false), 0);
    check('...and raises External 1', gpc.cpu.intPending.ext1, true);
    check('...not a program check', gpc.cpu.intPending.programCheck, false);
    gpc.cpu.checkInterrupts();
    check('the DMA violation is taken', gpc.cpu.psw.getNIA(), 0xe00);
    check('...with code 0004',
          gpc.cpu.ram.get32(byKey.ext1.old + 2, false) & 0xffff, 0x0004);
    check('...and note # damage in the old PSW',
          (gpc.cpu.ram.get32(byKey.ext1.old, false) >>> 14) & 3, 2);

    // Masked, note '##': the interrupt waits, but the CC damage lands now
    // and any pending arithmetic program check is lost.
    gpc = mkGPC();
    gpc.cpu.psw.setNIA(0x800);
    setMask(gpc.cpu, 0x00);                    // External 1 masked off
    gpc.cpu.psw.setCC(1);
    gpc.cpu.psw.setCarry(1);
    gpc.cpu.psw.setFixedPtOverflow(1);
    gpc.cpu.signalFixedOverflow();
    check('an arithmetic check is pending first', gpc.cpu.intPending.programCheck, true);
    gpc.cpu.mainStorage.setStoreProtect(0x2000, true);
    gpc.iop.writeMain16(0x2000, 0x1234);
    check('a masked DMA violation still latches', gpc.cpu.intPending.ext1, true);
    check('...damages the CC anyway', gpc.cpu.psw.getCC(), 2);
    check('...clears the carry bit', gpc.cpu.psw.getCarry(), 0);
    check('...and loses the arithmetic interrupt', gpc.cpu.intPending.programCheck, false);

    // External 0 is the IOP's Group 1 level (interrupt register A)
    //
    // Five sources share it; the handler reads register A with PCI
    // 08000000 to find out which, and the read clears it.
    const INTA_GO_NOGO = 0x80000000;   // bit 0  watchdog timeout
    const INTA_CM_IDLE = 0x20000000;   // bit 2  C/M idle
    const PCO_MASTER_RESET = 0x84400000;
    const PCI_READ_INT_A   = 0x08000000;
    const PCO_LOAD_WATCHDOG = 0x88040000;
    const PCI_READ_RM      = 0x08140000;

    // A C/M master reset ends with the C/M announcing itself idle, which
    // is an External 0 (POO Appendix I master reset table).  Software
    // tests exactly this bit to prove the reset happened.
    gpc = mkGPC();
    gpc.cpu.psw.setNIA(0x800);
    gpc.iop.setIntReg(1, 0x1234);                    // register B, to be cleared
    gpc.iop.recvFromCPU(PCO_MASTER_RESET, 0);
    check('master reset sets C/M idle',
          (gpc.iop.intReg(0) & INTA_CM_IDLE) !== 0, true);
    check('master reset raises External 0', gpc.cpu.intPending.ext0, true);
    check('master reset clears register B', gpc.iop.intReg(1), 0);
    check('master reset inhibits the watchdog', gpc.iop.wdRunning, false);

    // Reading register A returns the bits and clears the register.
    gpc.iop.recvFromCPU(PCI_READ_INT_A, 0);
    check('the handler reads C/M idle out of register A',
          (gpc.cpu.recvFromIOP() & INTA_CM_IDLE) !== 0, true);
    check('...and the read clears the register', gpc.iop.intReg(0), 0);

    // ...and it is deliverable: mask bit 35, PSA 0078/007C, code 0000.
    gpc = mkGPC();
    gpc.cpu.psw.setNIA(0x800);
    handler(gpc.cpu, byKey.ext0.new, 0xf00);
    setMask(gpc.cpu, 0x10);                          // mask bit 35 = External 0
    gpc.iop.recvFromCPU(PCO_MASTER_RESET, 0);
    gpc.cpu.checkInterrupts();
    check('External 0 vectors through 007C', gpc.cpu.psw.getNIA(), 0xf00);
    check('...with interrupt code 0000',
          gpc.cpu.ram.get32(byKey.ext0.old + 2, false) & 0xffff, 0x0000);

    // An ICR channel reset zeroes the interrupt registers -- which is why
    // the programming note says to read register A first.
    gpc = mkGPC();
    gpc.iop.recvFromCPU(PCO_MASTER_RESET, 0);
    gpc.iop.channelReset();
    check('channel reset clears register A', gpc.iop.intReg(0), 0);

    // The TEST INTERRUPTS PCO forces the registers so the software can
    // check that the interrupts really reach the CPU, and holds them
    // through a read until ENABLE is issued.
    gpc = mkGPC();
    gpc.iop.recvFromCPU(0x88180000, 0);              // TEST INTERRUPTS
    check('test forces register A bits 0-5', gpc.iop.intReg(0), 0xfc000000);
    check('test forces register B bits 4-5', gpc.iop.intReg(1), 0x0c000000);
    check('test forces register D bit 0', gpc.iop.intReg(3), 0x80000000);
    check('test raises External 0', gpc.cpu.intPending.ext0, true);
    check('test raises External 1', gpc.cpu.intPending.ext1, true);
    check('test raises External 4', gpc.cpu.intPending.ext4, true);
    check('test leaves External 2 alone', gpc.cpu.intPending.ext2, false);
    gpc.iop.recvFromCPU(PCI_READ_INT_A, 0);
    check('a read does not clear a forced register', gpc.iop.intReg(0), 0xfc000000);
    gpc.iop.recvFromCPU(0x88140000, 0);              // ENABLE INTERRUPTS
    gpc.iop.recvFromCPU(PCI_READ_INT_A, 0);
    check('after ENABLE the read clears it', gpc.iop.intReg(0), 0);

    // ...and the whole chain from an instruction: PC R1,R2 with the master
    // reset command word in R2, then a PC that reads register A back into
    // R1 -- the way software confirms the reset from the macrocode side.
    // (R1 is the data, R2 the command word: POO PROGRAM CONTROLLED I/O.)
    gpc = mkGPC();
    gpc.cpu.psw.setNIA(0x800);
    for (let a = 0x800; a < 0x808; a++) gpc.cpu.mainStorage.setStoreProtect(a, false);
    gpc.cpu.ram.set16(0x800, 0xD9EA, false);         // PC R1,R2
    gpc.cpu.ram.set16(0x801, 0xD9EA, false);         // PC R1,R2
    gpc.cpu.r(2).set32(PCO_MASTER_RESET);
    gpc.exec1();
    check('PC issued the master reset', gpc.cpu.intPending.ext0, true);
    gpc.cpu.r(2).set32(PCI_READ_INT_A);
    gpc.exec1();
    check('PC read register A into R1', gpc.cpu.r(1).get32() >>> 0, INTA_CM_IDLE);
    check('...leaving the command word alone', gpc.cpu.r(2).get32() >>> 0, PCI_READ_INT_A);
    check('...and the register cleared', gpc.iop.intReg(0), 0);

    // The per-processor status registers
    //
    // One bit per processor, MSB first: bit 0 is the MSC, bits 1-24 the
    // BCEs, bit 25 the self-test processor.  Processor p is
    // 0x80000000 >>> p, so "all 25" is 0xffffff80 -- 0xfffff800 is that
    // constant four processors short, which is what a hand-typed mask
    // buys you.
    gpc = mkGPC();
    check('the MSC is the top bit', gpc.iop.procBit(0) >>> 0, 0x80000000);
    check('BCE 1 is next', gpc.iop.procBit(1) >>> 0, 0x40000000);
    check('BCE 24 is the last one', gpc.iop.procBit(24) >>> 0, 0x00000080);
    check('the self-test processor follows it', gpc.iop.procBit(25) >>> 0, 0x00000040);
    check('all 25 processors', gpc.iop.PROC_ALL >>> 0, 0xffffff80);
    check('the 24 BCEs alone', gpc.iop.PROC_ALL_BCE >>> 0, 0x7fffff80);

    // Master reset: STAT1 = GO for everything, STAT4 = WAIT, STAT5 = halt.
    gpc.iop.recvFromCPU(PCO_MASTER_RESET, 0);
    check('master reset sets every processor GO',
          gpc.iop.regProgExcept.get32() >>> 0, 0xffffff80);
    check('master reset puts every processor in WAIT',
          gpc.iop.regBusyWait.get32() >>> 0, 0);
    check('master reset halts every processor',
          gpc.iop.regProcEnable.get32() >>> 0, 0);
    check('master reset disables the transmitters',
          gpc.iop.regXmitEna.get32() >>> 0, 0);

    // ...and the halt status reads back that way through its PCI.
    gpc.iop.recvFromCPU(0x040c0000, 0);              // READ PROCESSOR HALT STATUS
    check('halt status reads all disabled', gpc.cpu.recvFromIOP() >>> 0, 0);

    // CONFIGURE PROCESSORS uses the data word as a mask: 1 = act on that
    // processor, 0 = leave it alone.  Enable the MSC and BCE 1.
    gpc.iop.recvFromCPU(0x87200000, (0x80000000 | 0x40000000) >>> 0);
    gpc.iop.recvFromCPU(0x040c0000, 0);
    check('enable set the MSC and BCE 1 bits',
          gpc.cpu.recvFromIOP() >>> 0, 0xc0000000);
    check('the MSC reads enabled', gpc.iop.procGet(gpc.iop.regProcEnable, 0), 1);
    check('BCE 2 is still halted', gpc.iop.procGet(gpc.iop.regProcEnable, 2), 0);
    // ...and halting BCE 1 leaves the MSC alone.
    gpc.iop.recvFromCPU(0x86200000, 0x40000000);
    check('halt cleared BCE 1 only',
          gpc.iop.regProcEnable.get32() >>> 0, 0x80000000);

    // The GO/NO-GO (watchdog) timer
    //
    // A 12-bit count-up device at 0.768 ms a tick, loaded with the two's
    // complement of the interval wanted; the count reaching zero again is
    // the timeout, and it raises External 0 through Group 1 bit 0.
    gpc = mkGPC();
    gpc.iop.recvFromCPU(PCO_LOAD_WATCHDOG, 0xffe);   // two ticks to timeout
    check('the load starts the counter', gpc.iop.wdRunning, true);
    gpc.iop.recvFromCPU(PCI_READ_RM, 0);
    check('the count reads back in RM status bits 20-31',
          gpc.cpu.recvFromIOP() & 0xfff, 0xffe);
    gpc.cpu.advanceTimeNs(768000);                   // one tick
    gpc.iop.exec();
    check('one tick advances the count', gpc.iop.wdCount, 0xfff);
    check('...and does not time out yet', gpc.cpu.intPending.ext0, false);
    gpc.cpu.advanceTimeNs(768000);                   // the tick that wraps it
    gpc.iop.exec();
    check('the full count times out', gpc.iop.wdTimeout, true);
    check('...sets Group 1 bit 0',
          (gpc.iop.intReg(0) & INTA_GO_NOGO) !== 0, true);
    check('...raises External 0', gpc.cpu.intPending.ext0, true);
    check('...and stops the counter until it is loaded again',
          gpc.iop.wdRunning, false);
    gpc.iop.recvFromCPU(PCI_READ_RM, 0);
    const rm = gpc.cpu.recvFromIOP() >>> 0;
    check('the timeout latch shows in RM status bit 16', (rm & 0x8000) !== 0, true);
    check('...and the fail-or-timeout latch in bit 0', (rm >>> 31) & 1, 1);
    // Loading it again resets the timeout latch and restarts it.
    gpc.iop.recvFromCPU(PCO_LOAD_WATCHDOG, 0x800);
    check('a reload clears the timeout latch', gpc.iop.wdTimeout, false);
    check('...and restarts the counter', gpc.iop.wdRunning, true);
    // It also runs through the wait state -- a machine that has stopped
    // servicing the watchdog is the case the watchdog exists for.
    gpc = mkGPC();
    handler(gpc.cpu, byKey.ext0.new, 0xf00);
    setMask(gpc.cpu, 0x10);                          // External 0 unmasked
    gpc.cpu.psw.setWaitState(true);
    gpc.iop.recvFromCPU(PCO_LOAD_WATCHDOG, 0xfff);   // one tick to timeout
    gpc.cpu.advanceIdleNs(5e6);                      // 5 ms of idle
    check('the watchdog times out in the wait state', gpc.iop.wdTimeout, true);
    check('...and the wakeup is External 0', gpc.cpu.psw.getNIA(), 0xf00);
    check('...which took the CPU out of the wait state',
          gpc.cpu.psw.getWaitState(), false);

    // A master reset zeroes it and inhibits counting.
    gpc.iop.recvFromCPU(PCO_MASTER_RESET, 0);
    gpc.cpu.advanceTimeNs(768000 * 10);
    gpc.iop.exec();
    check('a master reset leaves the counter stopped at zero',
          gpc.iop.wdCount, 0);

    // The PCI/PCO command word, and local store
    //
    // Command word: bit 0 output/input, bits 1-5 subsystem select (01000 =
    // local store), bit 6 handshake, bits 7-16 data select.  Read one bit
    // out of place and a Data Flow command (00100) reads as local store.
    gpc = mkGPC();
    gpc.iop.recvFromCPU(PCO_MASTER_RESET, 0);
    const lsWord = gpc.iop.ls.at(0, 0, 0).get32();
    gpc.iop.recvFromCPU(0x10000000, 0);              // READ STATUS 1, a DF command
    check('READ STATUS 1 returns STAT1', gpc.cpu.recvFromIOP() >>> 0, 0xffffff80);
    check('...and does not touch local store', gpc.iop.ls.at(0, 0, 0).get32(), lsWord);
    gpc.iop.recvFromCPU(0x10040000, 0);              // READ STATUS 4
    check('READ STATUS 4 returns STAT4', gpc.cpu.recvFromIOP() >>> 0, 0);

    // A PC instruction issuing that command completes -- it used to throw
    // out of exec1 (local store's cp() was called as a property), which in
    // the GUI looked like a step that did nothing and then skipped one.
    gpc.cpu.psw.setNIA(0x800);
    gpc.cpu.mainStorage.setStoreProtect(0x800, false);
    gpc.cpu.ram.set16(0x800, 0xD9EB, false);         // PC R1,R3
    gpc.cpu.r(3).set32(0x10000000);
    let threwPC = false;
    try { gpc.exec1(); } catch (e) { threwPC = true; }
    check('PC with a Data Flow command does not throw', threwPC, false);
    check('...leaves the NIA one instruction on', gpc.cpu.psw.getNIA(), 0x801);
    check('...and delivers the status word', gpc.cpu.r(1).get32() >>> 0, 0xffffff80);

    // LOAD LOCAL STORE / READ LOCAL STORE: data select is region (bits
    // 7-11), bank (12-13), word (14-16), and the word itself is 18 bits.
    const lsCmd = (out, region, bank, word) =>
        (((out ? 1 : 0) << 31) | (0x08 << 26) | (((region << 5) | (bank << 3) | word) << 15)) >>> 0;
    gpc = mkGPC();
    gpc.iop.recvFromCPU(lsCmd(true, 3, 2, 5), 0x0002abcd);   // BCE 3, bank C, word 5
    check('load local store writes the addressed word',
          gpc.iop.ls.at(3, 2, 5).get32() >>> 0, 0x0002abcd);
    check('...and only that region', gpc.iop.ls.at(0, 2, 5).get32() >>> 0, 0);
    gpc.iop.recvFromCPU(lsCmd(false, 3, 2, 5), 0);
    // A local store word is 18 bits "scaled to the LSB portion of the 32-bit
    // data word"; the table calls bits 0-13 UNDEFINED, and the hardware has
    // nothing driving them, so they read back as ones.
    const lsRead = gpc.cpu.recvFromIOP() >>> 0;
    check('read local store returns the word', lsRead & 0x3ffff, 0x0002abcd);
    check('...with the undefined high bits set', lsRead >>> 18, 0x3fff);
    gpc.iop.recvFromCPU(lsCmd(true, 3, 2, 5), 0xffffffff);
    check('a local store word is 18 bits',
          gpc.iop.ls.at(3, 2, 5).get32() >>> 0, 0x0003ffff);
    // The self-test region has no page in this model; addressing it is a
    // no-op rather than a crash.
    let threwLS = false;
    try { gpc.iop.recvFromCPU(lsCmd(true, 25, 0, 0), 1); } catch (e) { threwLS = true; }
    check('the self-test region does not throw', threwLS, false);

    // Codes have names, so 0004 and 0007 are told apart on sight
    //
    cpu = mkCPU();
    check('program check code 0007 is named',
          cpu.intCodeLabel('programCheck', 0x0007), 'store protect violation');
    check('program check code 0004 is named',
          cpu.intCodeLabel('programCheck', 0x0004), 'fixed point overflow');
    check('ext 1 code 0004 is a different name',
          cpu.intCodeLabel('ext1', 0x0004), 'DMA store protect violation');
    check('a code-less interrupt has no name', cpu.intCodeLabel('clk1', null), null);

    console.log(`\n${pass} passed, ${fail} failed`);
    process.exit(fail ? 1 : 0);
})();
