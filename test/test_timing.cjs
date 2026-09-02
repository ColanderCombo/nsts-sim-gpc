// test_timing.cjs — AP-101S instruction execution times (IBM-85-C67-001
// sect.17): xts addressing-mode case selection, xtbs branch taken/not-taken,
// e()-computed overrides, and the 1-MHz interval timers.
//
// Usage:  node test/test_timing.cjs
//
// Exit status is 1 iff any assertion fails.

'use strict';

const path    = require('path');
const os      = require('os');
const esbuild = require('esbuild');
const coffeePlugin = require('esbuild-coffeescript');

const SRC = path.resolve(__dirname, '..', 'gpc');

async function bundle(entry) {
    const out = path.join(os.tmpdir(),
        `timing.${path.basename(entry, '.coffee')}.${process.pid}.cjs`);
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

// assertion harness
//
let pass = 0, fail = 0;
function check(label, got, want) {
    if (got === want) { pass++; }
    else { fail++; console.log(`FAIL  ${label}: got ${got}, want ${want}`); }
}

(async () => {
    const { CPU } = await bundle('cpu.coffee');

    // Run one instruction at 0x800 and return elapsed ns.
    function execTime(cpu, hw1, hw2 = 0) {
        cpu.psw.setNIA(0x800);
        cpu.ram.set16(0x800, hw1);
        cpu.ram.set16(0x801, hw2);
        const t0 = cpu.timeNs;
        cpu.exec1();
        return cpu.timeNs - t0;
    }

    // RR: AR R1,R2 = .250 us
    //
    let cpu = new CPU();
    check('AR RR normal', execTime(cpu, 0x01E2), 250);

    // SRS short: A R1,D2(B2)  x=1 d=2 b=0 = .250 us
    //
    cpu = new CPU();
    cpu.r(0).set32(0x10000000);          // base 0x1000
    check('A SRS normal', execTime(cpu, 0x0108), 250);

    // RS indexed, X!=0 IA=0 I=0 (plain indexing): normal = .250 us
    //
    cpu = new CPU();
    cpu.r(2).set32(0);                   // index reg X=2 (value 0)
    check('A RS indexed normal', execTime(cpu, 0x04F7, 0x4100), 250);

    // RS indexed, X=0 IA=1 I=1: auto storage modification = 5.5 us
    //
    cpu = new CPU();
    cpu.ram.set32(0x100, 0x03000002);    // indirect fullword: addr 0x300, mod 2
    check('A auto storage mod', execTime(cpu, 0x04F7, 0x1900), 5500);

    // RS indexed, X!=0 IA=0 I=1: auto indexing = 7.25 us
    //
    cpu = new CPU();
    cpu.r(1).set32(0x00800005);          // index 0x80, modifier 5
    check('A auto indexing', execTime(cpu, 0x04F7, 0x2900), 7250);

    // RS indexed, X!=0 IA=1 I=1: double indirection by (XC,C)
    //
    // pointer fullword at 0x100: address 0x0300, XC=bit20, C=bit21
    const diCases = [
        [0, 0, 4500], [0, 1, 4250], [1, 0, 4250], [1, 1, 4250],
    ];
    for (const [xc, c, want] of diCases) {
        cpu = new CPU();
        cpu.r(1).set32(0);               // index reg X=1 (value 0)
        cpu.ram.set32(0x100, 0x03000000 | (xc << 11) | (c << 10));
        check(`A double indirection XC=${xc} C=${c}`,
              execTime(cpu, 0x04F7, 0x3900), want);
    }

    // BC: branch taken 1.25 us, not taken .250 us
    //
    cpu = new CPU();
    check('BC taken (M1=111)', execTime(cpu, 0xC7F3, 0x0200), 1250);
    check('BC NIA after taken', cpu.psw.getNIA(), 0x200);
    cpu = new CPU();
    check('BC not taken (M1=000)', execTime(cpu, 0xC0F3, 0x0200), 250);

    // BC with double indirection XC=0 C=0: 4.25 us regardless of BT
    //
    cpu = new CPU();
    cpu.r(1).set32(0);
    cpu.ram.set32(0x100, 0x03000000);
    check('BC double indirection', execTime(cpu, 0xC7F7, 0x3900), 4250);

    // BALR: taken 3.5 us, not taken (R2=0) 4.5 us
    //
    cpu = new CPU();
    cpu.r(2).set32(0x04000000);          // branch target 0x400
    check('BALR taken', execTime(cpu, 0xE1E2), 3500);
    cpu = new CPU();
    check('BALR not taken', execTime(cpu, 0xE1E0), 4500);

    // SLL R1,5: .675 + 0.1*5 = 1.175 us
    //
    cpu = new CPU();
    cpu.r(1).set32(1);
    check('SLL count 5', execTime(cpu, 0xF114), 1175);

    // MR R1 odd: 2.15 us (vs 2.40 even)
    //
    cpu = new CPU();
    cpu.r(2).set32(0);
    check('MR R1 even', execTime(cpu, 0x42E2), 2400);   // MR R2,R2 (x=2)
    cpu = new CPU();
    check('MR R1 odd', execTime(cpu, 0x43E2), 2150);    // MR R3,R2 (x=3)

    // MR/M with an ODD R1 keep the HIGH 32 BITS OF THE SAME PRODUCT
    //
    cpu = new CPU();
    cpu.r(3).set32(0x20000000);          // 0.25
    cpu.r(2).set32(0x40000000);          // 0.5
    execTime(cpu, 0x43E2);               // MR R3,R2 -- R1 = 3, ODD
    check('MR R1 odd keeps the product high half', cpu.r(3).get32() >>> 0, 0x10000000);

    // The even form puts the same product across the pair, which is the
    // reference the odd form's high half has to agree with.
    cpu = new CPU();
    cpu.r(2).set32(0x20000000);
    cpu.r(4).set32(0x40000000);
    execTime(cpu, 0x42E4);               // MR R2,R4 -- R1 = 2, EVEN
    check('MR R1 even high half', cpu.r(2).get32() >>> 0, 0x10000000);
    check('MR R1 even low half', cpu.r(3).get32() >>> 0, 0x00000000);

    // A small integer multiplier, whose top halfword is zero.  
    cpu = new CPU();
    cpu.r(3).set32(0x0CCCCCCD); // 1/10.
    cpu.r(2).set32(10);
    execTime(cpu, 0x43E2);               // MR R3,R2 -- R1 odd, multiplier 10
    check('MR R1 odd by a small integer is not zero (top halfword is zero)',
          cpu.r(3).get32() !== 0, true);

    // Interval timer: 1 tick per accumulated microsecond
    //
    cpu = new CPU();
    cpu.counter1 = 2;
    cpu.ram.set16(0x00B0, 0, false);
    for (let i = 0; i < 12; i++) execTime(cpu, 0x01E2);  // 12 x .25us = 3us
    check('counter1 low wrapped', cpu.counter1, 0xFFFF);
    check('counter1 high wrapped', cpu.ram.get16(0x00B0), 0xFFFF);
    check('clk1 interrupt pending', cpu.intPending.clk1, true);

    // high halfword decrements without interrupt when nonzero
    cpu = new CPU();
    cpu.counter2 = 1;
    cpu.ram.set16(0x00B1, 5, false);
    for (let i = 0; i < 8; i++) execTime(cpu, 0x01E2);   // 2us -> one borrow
    check('counter2 high decremented', cpu.ram.get16(0x00B1), 4);
    check('clk2 not pending', cpu.intPending.clk2, false);

    // ICR write counter 1 loads it and clears the pending latch
    //
    cpu = new CPU();
    cpu.intPending.clk1 = true;
    cpu.r(1).set32(0x00050010);          // hi=5, lo=0x10
    cpu.r(2).set32(0x40000000);          // cmd 01000 = write counter 1
    const dt = execTime(cpu, 0xD9E2);    // ICR R1,R2
    // Load counter 1 = 3.5 us.  This was 5.5 (a row of the p.10-3 table that
    // belongs to a different counter set; the counter rows are not legible in
    // our scan), and the flight self-test arbitrates: its interval timer
    // tolerance check writes a count, reads it straight back, and demands
    // 3-4 counts of decay.  At 5.5 the machine reads one count too few and
    // reports both clocks out of tolerance; at 3.5 the self-test passes
    // clean.  See the derivation at the ICR site in cpu_instr.coffee.
    check('ICR time', dt, 3500);
    check('ICR loads high halfword', cpu.ram.get16(0x00B0), 5);
    check('ICR loads low halfword', cpu.counter1, 0x10 - 3); // 3.5us elapsed
    check('ICR clears clk1 pending', cpu.intPending.clk1, false);

    // LXAR/LXA early out: equal new/current DSE -> -1.25 us
    //
    cpu = new CPU();
    cpu.r(2).set32(0x12340000);          // DSE 0 == current DSE(R1) 0
    check('LXAR early out', execTime(cpu, 0x41EA), 2250);
    cpu = new CPU();
    cpu.r(2).set32(0x12340003);          // DSE 3 != current 0
    check('LXAR no early out', execTime(cpu, 0x41EA), 3500);

    // MVH: PSW-DSR destination path runs 2.25 us faster
    //
    cpu = new CPU();
    cpu.r(1).set32(0x81000004);          // dest bit0=1 (DSR path), count 4
    cpu.r(2).set32(0x02000000);          // source 0x0200
    check('MVH DSR dest, count 4', execTime(cpu, 0x69EA), 11500);  // 10.25+3.5-2.25
    cpu = new CPU();
    cpu.r(1).set32(0x01000004);          // dest bit0=0 (DSE path), count 4
    cpu.r(2).set32(0x02000000);
    check('MVH DSE dest, count 4', execTime(cpu, 0x69EA), 13750);  // 10.25+3.5

    // ME short-SRS form: 5.75 us regardless of R1 parity
    //
    cpu = new CPU();
    cpu.r(0).set32(0x10000000);
    check('ME SRS even R1', execTime(cpu, 0x6208), 5750);

    // AP-101B model (xtc, IBM 75-A97-001 sect 2.4)
    //
    function bModel() { const c = new CPU(); c.model = 'B'; return c; }

    // AR: Even 1.2, Odd NOK 0.8, Odd ~NOK (after branch) 1.2
    cpu = bModel();
    check('B: AR even', execTime(cpu, 0x01E2), 1200);
    cpu = bModel();
    cpu.psw.setNIA(0x801);
    cpu.ram.set16(0x801, 0x01E2);
    let t0 = cpu.timeNs; cpu.exec1();
    check('B: AR odd NOK', cpu.timeNs - t0, 800);
    cpu = bModel();
    cpu.ram.set16(0x800, 0xC7F3);        // BC always -> 0x201 (odd)
    cpu.ram.set16(0x801, 0x0201);
    cpu.ram.set16(0x201, 0x01E2);
    cpu.psw.setNIA(0x800);
    cpu.exec1();                          // branch (discontinuity)
    t0 = cpu.timeNs; cpu.exec1();         // AR at odd, after branch
    check('B: AR odd ~NOK after branch', cpu.timeNs - t0, 1200);

    // A short SRS uses xtcs row (Even 1.8); RS indexed adds Note-4 adders
    cpu = bModel();
    cpu.r(0).set32(0x10000000);
    check('B: A SRS even', execTime(cpu, 0x0108), 1800);
    cpu = bModel();
    cpu.r(2).set32(0);
    check('B: A indexed +0.4', execTime(cpu, 0x04F7, 0x4100), 2200);
    cpu = bModel();
    cpu.ram.set32(0x100, 0x03000002);
    check('B: A indirect mod +2.8', execTime(cpu, 0x04F7, 0x1900), 4600);
    cpu = bModel();
    cpu.r(1).set32(0x00800005);
    check('B: A index mod +1.2', execTime(cpu, 0x04F7, 0x2900), 3000);
    cpu = bModel();
    cpu.r(1).set32(0);
    cpu.ram.set32(0x100, 0x03000000);
    check('B: A indirect post-indexed +1.6', execTime(cpu, 0x04F7, 0x3900), 3400);

    // op with no xtc (MVH: not on the AP-101B) falls back to the
    // S-model chain (here the opExecT override: negative count = 7.5us)
    cpu = bModel();
    cpu.r(1).set32(0x00008000);          // negative move count
    check('B: no-xtc fallback (MVH)', execTime(cpu, 0x69EA), 7500);

    // ICR command-specific row: write counter 1 = 3.2 us (Even)
    cpu = bModel();
    cpu.r(1).set32(0x00050010);
    cpu.r(2).set32(0x40000000);          // cmd 01000 = write counter 1
    check('B: ICR write counter', execTime(cpu, 0xD9E2), 3200);

    // SUM note 2: count=3 all-match -> 6.4 + 2.6*2 = 11.6 us (Even)
    cpu = bModel();
    cpu.r(1).set32(0x00030000);          // count 3 in R1(y) bits 0-15
    cpu.r(2).set32(0x02000000);          // array at 0x0200, modifier 0
    cpu.r(3).set32(0x00000000);          // mask 0 -> everything matches
    check('B: SUM count 3', execTime(cpu, 0x9AE9), 11600);
    // and on model S the 2.5us/element rule still applies
    cpu = new CPU();
    cpu.r(1).set32(0x00030000);
    cpu.r(2).set32(0x02000000);
    cpu.r(3).set32(0x00000000);
    check('S: SUM count 3', execTime(cpu, 0x9AE9), 7500);

    // RTPacer: wait-state wakeup via counter interrupt
    //
    const { RTPacer } = await bundle('rtpacer.coffee');

    function makeWaitingCPU(counter1) {
        const c = new CPU();
        c.psw.setNIA(0x800);
        c.psw.setWaitState(true);
        // enable CLK1 (system mask bit 32 = 0x80 of the 8-bit mask field)
        c.psw._setField2(c.psw.pack2.desc.f.m, 0x80);
        c.counter1 = counter1;
        c.ram.set16(0x00B0, 0, false);
        // CLK1 new PSW at 0x64: NIA=0x500, process state (bit 46 = 0), all masked
        c.ram.set32(0x0064, 0x05000000);
        c.ram.set32(0x0066, 0x00000000);
        return c;
    }

    // counter expires after 5ms of simulated time -> wakes at ~5ms wall
    cpu = makeWaitingCPU(5000);
    let pacer = new RTPacer(cpu, 1.0, 2000);
    let why = await pacer.idleWait();
    check('idleWait resumed', why, 'resumed');
    check('idleWait wake NIA', cpu.psw.getNIA(), 0x500);
    check('idleWait wait cleared', cpu.psw.getWaitState(), false);
    const wokeUs = cpu.execTimeUs();
    check('idleWait sim time ~5ms', wokeUs >= 5000 && wokeUs < 12000, true);

    // all interrupts masked -> can never wake
    cpu = makeWaitingCPU(5000);
    cpu.psw._setField2(cpu.psw.pack2.desc.f.m, 0x00);
    pacer = new RTPacer(cpu, 1.0, 2000);
    check('idleWait masked', await pacer.idleWait(), 'masked');

    // wakeup too far away -> idle timeout
    cpu = makeWaitingCPU(0xFFFF);
    cpu.ram.set16(0x00B0, 0xFFFF, false);
    pacer = new RTPacer(cpu, 1.0, 60);
    check('idleWait timeout', await pacer.idleWait(), 'timeout');

    // Host slower than real time must NOT dump its deficit into a wait
    // period: idle advance is measured from idle entry, so a 3ms counter
    // still takes ~3ms of wall time to fire even with 25ms of prior debt.
    cpu = makeWaitingCPU(3000);
    pacer = new RTPacer(cpu, 1.0, 2000);
    await new Promise(r => setTimeout(r, 25));   // build up wall-clock debt
    const idleWall0 = Date.now(), idleSim0 = cpu.timeNs;
    why = await pacer.idleWait();
    const idleWallMs = Date.now() - idleWall0;
    const idleSimMs = (cpu.timeNs - idleSim0) / 1e6;
    check('idleWait debt resumed', why, 'resumed');
    check('idleWait debt not instant', idleWallMs >= 2, true);
    check('idleWait debt sim ~3ms', idleSimMs >= 3 && idleSimMs < 12, true);

    // pace(): running 20ms of sim time at factor 4 should take ~5ms wall
    cpu = new CPU();
    pacer = new RTPacer(cpu, 4.0, 1000);
    const wall0 = Date.now();
    for (let i = 0; i < 80; i++) {          // 80 x .25us = 20us... use bigger
        cpu.advanceTimeNs(250000);          // 0.25ms sim per chunk, 20ms total
        await pacer.pace();
    }
    const wallTook = Date.now() - wall0;
    // target 5ms wall minus the pacer's 2ms deadband -> at least ~3ms; use
    // 2ms as the floor (no pacing at all completes in <1ms)
    check(`pace ~sim/factor wall time (took ${wallTook}ms)`, wallTook >= 2 && wallTook < 250, true);

    console.log(`\n${pass} passed, ${fail} failed`);
    process.exit(fail ? 1 : 0);
})();
