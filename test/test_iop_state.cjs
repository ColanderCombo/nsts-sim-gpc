// test_iop_state.cjs — the IOP state the ground equipment reads: the
// per-processor snapshots the <gpc-iop> pane renders, the MSC and BCE
// disassemblers behind its excerpt, and the MIA traffic rings.
//
// Usage:  node test/test_iop_state.cjs
//
// Exit status is 1 iff any assertion fails.

'use strict';

const path    = require('path');
const os      = require('os');
const fs      = require('fs');
const esbuild = require('esbuild');
const coffeePlugin = require('esbuild-coffeescript');

const SRC = path.resolve(__dirname, '..');

// AP101 reaches com/lru, which is Civet (see test_realtime.cjs).
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
        `iopstate.${path.basename(entry, '.coffee')}.${process.pid}.cjs`);
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

let pass = 0, fail = 0;
function check(label, got, want) {
    if (got === want) { pass++; }
    else { fail++; console.log(`FAIL  ${label}: got ${got}, want ${want}`); }
}

(async () => {
    const { AP101 }           = await bundle('ap101.coffee');
    const { MSCInstruction }  = await bundle('iop_msc_instr.coffee');
    const { BCEInstruction }  = await bundle('iop_bce_instr.coffee');

    const PCO_MASTER_RESET = 0x84400000;
    const PCI_READ_RM      = 0x08140000;
    const PCO_ENABLE       = 0x87200000;
    const PCO_HALT         = 0x86200000;

    const mkGPC = () => {
        const g = new AP101({ machine: 'ap101s' });
        for (let a = 0; a < 0x2000; a++) g.cpu.mainStorage.setStoreProtect(a, false);
        return g;
    };
    const poke = (g, a, v) => g.cpu.mainStorage.set16(a, v, false);

    // Disassembly: the excerpt under an unfolded processor
    //
    const msc = new MSCInstruction();
    check('MSC short form', msc.toStr(0x4123, 0).text, "@L  X'123'");
    check('MSC short form is one halfword', msc.toStr(0x4123, 0).len, 1);
    check('MSC names the operand it decoded', msc.toStr(0xE770, 0).text, "@RBI  X'E'");
    check('MSC long form is two halfwords', msc.toStr(0xF104, 0x0123).len, 2);
    check('MSC long form renders both operands',
          msc.toStr(0xF104, 0x0123).text, "@CALL@  X'0',X'123'");
    check('MSC condition and address', msc.toStr(0x2345, 0).text, "@BC  X'3',X'45'");
    check('an unknown word disassembles rather than throwing',
          msc.toStr(0x0002, 0).text.startsWith('???'), true);

    const bce = new BCEInstruction();
    check('BCE short form', bce.toStr(0xB123, 0).text, "#LTOI  X'123'");
    check('BCE operand-less form', bce.toStr(0xE000, 0).text, '#RIB');
    check('BCE long form', bce.toStr(0xF200, 0x0123).text, "#LBR  X'123'");
    check('BCE long form is two halfwords', bce.toStr(0xF200, 0x0123).len, 2);

    // procState: one snapshot per processor
    //
    let gpc = mkGPC();
    check('there are 25 processors', gpc.iop.procStates().length, 25);
    check('processor 0 is the MSC', gpc.iop.procState(0).name, 'MSC');
    check('processor 0 is an MSC kind', gpc.iop.procState(0).kind, 'MSC');
    check('processor 24 is BCE 24', gpc.iop.procState(24).name, 'BCE 24');
    // 25 is the diagnostic / self-test processor.  It runs no program of
    // its own, so procStates() -- which is "the processors you can watch
    // execute" -- stops at 24; but it HAS a local store page, because the
    // MSC and BCE self-test micro programs leave their signature there and
    // software reads it back through READ LOCAL STORE region 25.
    check('processor 25 has a local store page', gpc.iop.procState(25) !== null, true);
    check('processor 25 is not in the executable list',
          gpc.iop.procStates().some((p) => p.num === 25), false);
    check('the MSC has its own registers',
          gpc.iop.procState(0).regs.map((r) => r.name).join(','),
          'PC,IH,IL,X,AH,AL,ECR,MST');
    check('a BCE has its own',
          gpc.iop.procState(1).regs.map((r) => r.name).join(','),
          'PC,IH,IL,DH,DL,ID,MTO,BASE,IUAR,BSTH,BSTL');

    // The status lamps come off the per-processor registers.
    gpc.iop.recvFromCPU(PCO_MASTER_RESET, 0);
    check('after a master reset nothing is enabled', gpc.iop.procState(0).enabled, false);
    check('...and everything is GO', gpc.iop.procState(7).go, true);
    check('...and nothing is busy', gpc.iop.procState(7).busy, false);
    gpc.iop.recvFromCPU(PCO_ENABLE, (0x80000000 | 0x40000000) >>> 0);
    check('enabling the MSC shows on the MSC', gpc.iop.procState(0).enabled, true);
    check('...and on BCE 1', gpc.iop.procState(1).enabled, true);
    check('...but not on BCE 2', gpc.iop.procState(2).enabled, false);
    gpc.iop.recvFromCPU(PCO_HALT, 0x40000000);
    check('halting BCE 1 shows there too', gpc.iop.procState(1).enabled, false);
    check('...and leaves the MSC alone', gpc.iop.procState(0).enabled, true);

    // The MIA enables are per-BCE and read back the same way.
    gpc.iop.recvFromCPU(0x85040000, 0x40000000);     // MIA transmitter enable, BCE 1
    check('BCE 1 shows its transmitter enabled', gpc.iop.procState(1).xmitEna, true);
    check('BCE 2 does not', gpc.iop.procState(2).xmitEna, false);
    check('the MSC has no MIA of its own', gpc.iop.procState(0).tx.length, 0);

    // procDisasm: the excerpt walks from the processor's PC
    //
    gpc = mkGPC();
    gpc.iop.ls.at(0, 0, 2).set32(0x100);             // MSC PC
    poke(gpc, 0x100, 0x4123);                        // @L   X'123'
    poke(gpc, 0x101, 0xE770);                        // @RBI X'E'
    poke(gpc, 0x102, 0xF104);                        // @CALL@ (long)
    poke(gpc, 0x103, 0x0123);
    let rows = gpc.iop.procDisasm(0, 3);
    check('the excerpt starts at the PC', rows[0].addr, 0x100);
    check('...and disassembles it', rows[0].text, "@L  X'123'");
    check('...steps one halfword for a short form', rows[1].addr, 0x101);
    check('...and two for a long one', rows[2].addr, 0x102);
    check('...reporting its length', rows[2].len, 2);
    check('the excerpt is as long as asked', gpc.iop.procDisasm(0, 6).length, 6);

    // A BCE's program is disassembled with the BCE instruction set, not
    // the MSC's -- the same halfword means different things to each.
    gpc.iop.ls.at(3, 0, 2).set32(0x200);             // BCE 3 PC
    poke(gpc, 0x200, 0xB123);
    check('a BCE excerpt uses the BCE decoder',
          gpc.iop.procDisasm(3, 1)[0].text, "#LTOI  X'123'");
    check('the same word means something else to the MSC',
          gpc.iop.procDisasm(0, 1, 0x200)[0].text.startsWith('#'), false);

    // The MIA traffic rings
    //
    gpc = mkGPC();
    const mia = gpc.iop.bce[2].mia;                   // BCE 3
    check('a fresh MIA has sent nothing', gpc.iop.procState(3).tx.length, 0);
    mia._log(mia.txLog, 0x1234);
    mia._log(mia.txLog, 0x5678, true);
    mia._log(mia.rxLog, 0x9abc);
    let st = gpc.iop.procState(3);
    check('the sent ring records words', st.tx.length, 2);
    check('...in order', st.tx[0].value, 0x1234);
    check('...flagging command words', st.tx[1].cmd, true);
    check('...and numbering them', st.tx[1].seq, 2);
    check('the received ring is separate', st.rx.length, 1);
    check('...with its own word', st.rx[0].value, 0x9abc);
    check('a ring belongs to one BCE', gpc.iop.procState(4).tx.length, 0);

    // The rings are bounded: old traffic falls off the end, and the
    // sequence number keeps counting so the display can say how much.
    for (let i = 0; i < 200; i++) mia._log(mia.txLog, i & 0xffff);
    st = gpc.iop.procState(3);
    check('the ring is bounded', st.tx.length, 64);
    check('...keeping the newest', st.tx[st.tx.length - 1].value, 199 & 0xffff);
    check('...and counting what went through', st.tx[st.tx.length - 1].seq, 202);
    mia.clearLogs();
    check('the rings can be cleared', gpc.iop.procState(3).tx.length, 0);

    // The IOP's own registers, as the pane's REGISTERS fold shows
    //
    gpc = mkGPC();
    let names = gpc.iop.globalRegs().map((r) => r.name);
    check('every global register is listed', names.length, 20);
    check('the four per-processor status words come first',
          names.slice(0, 4).join(','), 'STAT1,STAT4,STAT5,INDIC');
    check('the interrupt registers are all there',
          names.filter((n) => n.startsWith('INTREG')).join(','),
          'INTREGA,INTREGB,INTREGC,INTREGD,INTREGE');
    const regOf = (g, n) => g.iop.globalRegs().find((r) => r.name === n).value >>> 0;
    gpc.iop.recvFromCPU(PCO_MASTER_RESET, 0);
    check('STAT1 reads what the master reset left', regOf(gpc, 'STAT1'), 0xffffff80);
    check('STAT5 too', regOf(gpc, 'STAT5'), 0);
    check('interrupt register A shows C/M idle', regOf(gpc, 'INTREGA'), 0x20000000);
    check('RM status is the composed word, not the latch word',
          regOf(gpc, 'RMSTAT'), 0);
    check('every value is a number',
          gpc.iop.globalRegs().every((r) => typeof r.value === 'number'), true);
    check('every register carries a note',
          gpc.iop.globalRegs().every((r) => typeof r.note === 'string' && r.note.length > 0), true);

    // The GO/NO-GO timer's test load
    //
    // "loaded with any chosen value which is incremented by one low order
    // bit and read with a PCI to determine the operating status of the
    // timer" — so loading a full count of X'FFF' must read back X'000'
    // and latch the timeout, which is the cheapest way to prove the
    // increment happened at all.
    gpc = mkGPC();
    gpc.iop.recvFromCPU(0x88048000, 0xfff);          // LOAD GO/NO-GO TIMER TEST
    check('the test load increments by one', gpc.iop.wdCount, 0);
    check('...wrapping past a full count latches the timeout', gpc.iop.wdTimeout, true);
    gpc.iop.recvFromCPU(PCI_READ_RM, 0);
    check('...so the count reads back zero', gpc.cpu.recvFromIOP() & 0xfff, 0);
    check('...and it is a diagnostic load, not a running timer',
          gpc.iop.wdRunning, false);
    gpc.iop.recvFromCPU(0x88048000, 0x100);
    check('a test load resets the timeout latch', gpc.iop.wdTimeout, false);
    check('...and increments its value too', gpc.iop.wdCount, 0x101);

    // A timeout is a timeout however the count got there, so the injected
    // increment must reach the CPU the same way a run-down does: External
    // 0, with the GO/NO-GO source in interrupt register A.
    gpc = mkGPC();
    gpc.iop.recvFromCPU(0x88048000, 0xfff);
    check('the test load\'s timeout raises External 0',
          ((gpc.iop.intReg(0) & 0x80000000) >>> 0), 0x80000000);
    check('...and names the timer as the source',
          gpc.iop.group1Sources().includes('GO/NO-GO timer timeout'), true);
    gpc.iop.recvFromCPU(0x88040000, 0x800);          // an operational load
    check('a later load resets the latch', gpc.iop.wdTimeout, false);
    check('...but not the interrupt register, which only a read clears',
          ((gpc.iop.intReg(0) & 0x80000000) >>> 0), 0x80000000);

    // Redundancy management: the voter, in self test
    //
    // LOAD TEST REGISTER (PCO 88100000) data bit 27 is VOTER TEST CONTROL,
    // which inhibits the real inputs from the other IOPs; bits 28-31 are
    // four test inputs into the voter.  They read back in RM status as
    // bit 1 and bits 11-14, and the voter's own output is bit 15: "also
    // set during test when the hardware voter receives at least two of
    // four inputs".  Bit 0 is the fail-or-timeout latch above it.
    const rm = (iop, data) => { iop.recvFromCPU(0x88100000, data); return iop.rmStatus() >>> 0; };
    gpc = mkGPC();
    check('the voter test control bit reads back',
          (rm(gpc.iop, 0x10) & 0x40000000) >>> 0, 0x40000000);
    check('...with no inputs, and no failure',
          (rm(gpc.iop, 0x10) & 0x8001f000) >>> 0, 0);
    // Each input lands in its own status bit, in order: input 1 is bit 11.
    for (const [input, bit] of [[0x8, 0x00100000], [0x4, 0x00080000],
                                [0x2, 0x00040000], [0x1, 0x00020000]]) {
        const v = rm(gpc.iop, 0x10 | input);
        check(`test input ${input.toString(16)} shows in its own status bit`,
              v & 0x001e0000, bit);
        check('...and one input alone never trips the voter',
              (v & 0x80010000) >>> 0, 0);
    }
    // Any two of the four is a majority, and that sets the voter fail
    // latch and the fail-or-timeout latch with it.
    for (const pair of [0x3, 0x5, 0x6, 0x9, 0xa, 0xc]) {
        const v = rm(gpc.iop, 0x10 | pair);
        check(`inputs ${pair.toString(16)} trip the voter`, v & 0x00010000, 0x00010000);
        check('...and the fail latch above it', (v & 0x80000000) >>> 0, 0x80000000);
    }
    check('loading zeros takes the RM logic back out of test mode',
          (rm(gpc.iop, 0) & 0xe01ff000) >>> 0, 0);

    // The termination control latches are software's own, and sit next to
    // the voter's bits without disturbing them (data bit 30 = timeout
    // termination, bit 31 = voter termination).
    gpc.iop.recvFromCPU(0x88080000, 3);
    check('both termination latches set',
          (gpc.iop.rmStatus() & 0xe01ff000) >>> 0, 0x00006000);
    gpc.iop.recvFromCPU(0x88080000, 0);
    check('...and clear again', (gpc.iop.rmStatus() & 0xe01ff000) >>> 0, 0);

    // RESET STATUS 1 puts the masked processors back to GO.
    gpc = mkGPC();
    gpc.iop.regProgExcept.set32(0);
    gpc.iop.recvFromCPU(0x92000000, 0xc0000000);     // MSC and BCE 1
    check('reset status 1 sets the masked processors GO',
          gpc.iop.regProgExcept.get32() >>> 0, 0xc0000000);
    check('...and leaves the rest alone', gpc.iop.procState(2).go, false);

    // What the pane reads off the IOP itself
    //
    gpc = mkGPC();
    check('the pane can see the slice', typeof gpc.iop.ls.slice, 'number');
    check('...the page being executed', gpc.iop.ls.curPage, 0);
    check('...the DMA queue', gpc.iop.dmaQueue.length, 0);
    gpc.iop.recvFromCPU(PCO_MASTER_RESET, 0);
    check('...and the External 0 sources',
          gpc.iop.group1Sources().join(','), 'C/M idle');
    check('the MSC is flagged as the current page', gpc.iop.procState(0).current, true);
    check('...and a BCE is not', gpc.iop.procState(5).current, false);

    // Reset puts the IOP back where a fresh load finds it
    //
    // Nothing in an FCM reloads the IOP, so anything reset skips is state
    // a restarted program inherits: enabled processors, program counters
    // mid-run, a latched watchdog, queued DMA.  That is the difference
    // between a restart and a cold load.
    gpc = mkGPC();
    const fresh = JSON.stringify(gpc.iop.globalRegs());
    // Dirty every corner of it.
    gpc.iop.recvFromCPU(PCO_MASTER_RESET, 0);
    gpc.iop.recvFromCPU(PCO_ENABLE, 0xffffff80);
    gpc.iop.recvFromCPU(0x85040000, 0x7fffff80);     // MIA transmitters on
    gpc.iop.recvFromCPU(0x88040000, 0x800);          // start the watchdog
    gpc.iop.ls.at(0, 0, 2).set32(0x1234);            // MSC PC
    gpc.iop.ls.at(5, 2, 3).set32(0x4321);            // BCE 5 BASE
    gpc.iop.ls.slice = 7;
    gpc.iop.ls.curPage = 5;
    gpc.iop.queueDMA(0x100, 'write');
    gpc.iop.bce[4].mia._log(gpc.iop.bce[4].mia.txLog, 0x1111);
    gpc.iop.msc.regIntProg.set32(0x55);
    gpc.cpu.mainStorage.setStoreProtect(0x4000, false);
    check('the IOP is dirty before the reset',
          gpc.iop.procState(0).enabled && gpc.iop.procState(0).pc === 0x1234, true);

    gpc.reset();

    check('reset clears the MSC program counter', gpc.iop.procState(0).pc, 0);
    check('...and a BCE base register', gpc.iop.ls.at(5, 2, 3).get32(), 0);
    check('...and disables every processor', gpc.iop.procState(0).enabled, false);
    check('...and the MIA enables', gpc.iop.procState(5).xmitEna, false);
    check('...and stops the watchdog', gpc.iop.wdRunning, false);
    check('...and empties the DMA queue', gpc.iop.dmaQueue.length, 0);
    check('...and the MIA traffic rings', gpc.iop.procState(5).tx.length, 0);
    check('...and the MSC registers', gpc.iop.msc.regIntProg.get32(), 0);
    check('...and the time slice', gpc.iop.ls.slice, 0);
    check('...and the page being executed', gpc.iop.ls.curPage, 0);
    check('...and every global register is back to the fresh values',
          JSON.stringify(gpc.iop.globalRegs()), fresh);
    // ...and the memory side, which belongs to the harness's reset (an LRU
    // reset does not clear core), is covered by ram.clear().
    gpc.cpu.mainStorage.set16(0x4000, 0x1234, false);
    gpc.cpu.mainStorage.setStoreProtect(0x4000, true);
    gpc.cpu.ram.clear();
    // A clear puts protection back to what the machine powers up with, which
    // is UNPROTECTED: protection is asserted by whatever loads the store, so
    // an unloaded machine has none.
    check('a clear puts store protection back to the power-on state',
          gpc.cpu.mainStorage.getStoreProtect(0x4000), false);
    check('...and zeroes what the last run left above the image',
          gpc.cpu.mainStorage.get16(0x4000, false), 0);

    // The ICR channel reset is a different, much smaller thing: the
    // interrupt registers only.
    gpc = mkGPC();
    gpc.iop.recvFromCPU(PCO_MASTER_RESET, 0);
    gpc.iop.recvFromCPU(PCO_ENABLE, 0xffffff80);
    gpc.iop.channelReset();
    check('a channel reset clears the interrupt registers',
          gpc.iop.intReg(0), 0);
    check('...and leaves the processors alone', gpc.iop.procState(0).enabled, true);

    // The processors actually execute
    //
    // Three things had to line up for this: the program counter is written
    // through set32 and so must be read that way (reading the first
    // halfword fetched from address 0 for any program below 64K); curPE
    // has to follow the slice, or every BCE instruction acts on the MSC's
    // bits; and the MSC's own bit in a status register is the top one.
    gpc = mkGPC();
    poke(gpc, 0x100, 0xE400);            // MSC: @SIO   start the BCEs named in ACC
    poke(gpc, 0x101, 0x0800);            // MSC: @WAT
    poke(gpc, 0x200, 0xE800);            // BCE: #SIB   set my indicator
    poke(gpc, 0x201, 0x0800);            // BCE: #WAT
    gpc.iop.recvFromCPU(PCO_MASTER_RESET, 0);
    gpc.iop.recvFromCPU(PCO_ENABLE, 0xffffff80);
    gpc.iop.recvFromCPU(0x92040000, 0);  // LOAD MSC BUSY
    gpc.iop.ls.at(0, 0, 2).set32(0x100);
    gpc.iop.ls.at(1, 0, 2).set32(0x200);
    gpc.iop.ls.at(5, 0, 2).set32(0x200);
    const bceBits = (gpc.iop.procBit(1) | gpc.iop.procBit(5)) >>> 0;
    gpc.iop.ls.setACC(bceBits);
    check('the MSC starts at its program counter', gpc.iop.procState(0).pc, 0x100);
    // The MSC owns every fourth slice, so its first one is four in.
    for (let i = 0; i < 4; i++) gpc.iop.exec();
    check('...and fetches from there, not from 0', gpc.iop.procState(0).pc, 0x101);

    for (let i = 0; i < 80; i++) gpc.iop.exec();
    check('@SIO started the BCEs the accumulator named',
          gpc.iop.procState(1).indicator && gpc.iop.procState(5).indicator, true);
    check('...and only those', gpc.iop.regIndicator.get32() >>> 0, bceBits);
    check('each BCE ran its own program', gpc.iop.procState(5).pc, 0x202);
    check('...and #WAT cleared its own busy bit, not the MSC\'s',
          gpc.iop.procState(5).busy, false);
    check('@WAT parked the MSC', gpc.iop.procState(0).busy, false);
    check('...leaving nothing busy', gpc.iop.regBusyWait.get32() >>> 0, 0);
    check('...and every processor still GO',
          gpc.iop.regProgExcept.get32() >>> 0, 0xffffff80);
    // A processor the accumulator did not name never ran.
    check('an unnamed BCE stayed put', gpc.iop.procState(2).pc, 0);
    check('...and never set its indicator', gpc.iop.procState(2).indicator, false);

    // PC-relative addressing is relative to the UPDATED PC
    //
    // "PC refers to the updated program counter value i.e., the address of
    // the next instruction" (IOP POO, under every short-format
    // instruction).  Off by one halfword, a fullword load reads the
    // fullword before the one the program meant -- which is how an
    // @L/@N/@SIO sequence ended up starting no BCEs at all.
    gpc = mkGPC();
    poke(gpc, 0x100, 0x401F);            // @L  KFSTRNG   EA = 0x101 + 1F = 0x120
    poke(gpc, 0x101, 0x6020);            // @N  KFIHIBIT  EA = 0x102 + 20 = 0x122
    poke(gpc, 0x102, 0xE400);            // @SIO
    poke(gpc, 0x103, 0x0800);            // @WAT
    gpc.cpu.mainStorage.set32(0x11E, 0xdeadbeef, false);   // the fullword before
    gpc.cpu.mainStorage.set32(0x120, 0xFFFFFF80, false);   // KFSTRNG: MSC + 24 BCEs
    gpc.cpu.mainStorage.set32(0x122, 0x7FFFFFFF, false);   // KFIHIBIT: all but the MSC
    poke(gpc, 0x200, 0x0800);            // every BCE: #WAT
    gpc.iop.recvFromCPU(PCO_MASTER_RESET, 0);
    gpc.iop.recvFromCPU(PCO_ENABLE, 0xffffff80);
    gpc.iop.recvFromCPU(0x92040000, 0);
    gpc.iop.ls.at(0, 0, 2).set32(0x100);
    for (let p = 1; p <= 24; p++) gpc.iop.ls.at(p, 0, 2).set32(0x200);
    for (let i = 0; i < 12; i++) gpc.iop.exec();
    check('@L read the fullword the displacement names',
          gpc.iop.ls.getACC() >>> 0, 0x7fffff80);
    check('@SIO started every BCE the accumulator named',
          gpc.iop.regBusyWait.get32() >>> 0, 0xffffff80);
    // Bit 17 of the MSC status register is the busy copy that LOAD MSC
    // BUSY raised above, not an error; bits 8-16 are the error catalogue.
    // Read it by region rather than through MST(), which follows whichever
    // page the IOP is slicing.
    check('...with no MSC error',
          gpc.iop.ls.at(0, 2, 7).get32() & ~1, 0);
    check('...and the busy copy the PCO set',
          gpc.iop.ls.at(0, 2, 7).get32() & 1, 1);

    // The BCE's own short forms say the same thing, and #SSC adds twice
    // its processor number so one program can serve every BCE.
    gpc = mkGPC();
    gpc.iop.recvFromCPU(PCO_MASTER_RESET, 0);
    gpc.iop.recvFromCPU(PCO_ENABLE, 0xffffff80);
    gpc.iop.ls.curPage = 3;
    gpc.iop.curPE = 3;
    gpc.iop.ls.PC().set32(0x300);
    check('#SSC is PC-relative to the next instruction',
          gpc.iop.bceEA(0x10, 0), 0x311);
    check('...and M=1 adds two per BCE number',
          gpc.iop.bceEA(0x10, 1), 0x311 + 6);
    check('...with a signed displacement',
          gpc.iop.bceEA(0x7ff, 0), 0x300);

    // A restart is a cold load
    //
    // The whole point of the reset button: run a program, reset, and the
    // machine is what it was when the image was loaded.  Compare every
    // piece of state that survives a reload -- registers, PSW, simulated
    // time, main storage and its protect bits, all 25 local store pages,
    // the IOP's registers, the DMA queue and the watchdog.
    const { AGEHarness } = await bundle('ageharness.coffee');
    const FCM = path.join(SRC, 'gpc', 'gen', 'SIMPLE.fcm');
    const snapshot = (h) => {
        const cpu = h.cpu, iop = h.gpc.iop, mem = [], prot = [], ls = [];
        for (let a = 0; a < 0x2000; a++) {
            mem.push(cpu.mainStorage.get16(a, false));
            prot.push(cpu.mainStorage.getStoreProtect(a) ? 1 : 0);
        }
        for (let p = 0; p < 25; p++)
            for (let r = 0; r <= 16; r++) ls.push(iop.ls.storePage[p].r(r).get32() >>> 0);
        return JSON.stringify({
            regs: [0, 1, 2].map((b) => [0,1,2,3,4,5,6,7].map((i) => cpu.regFiles[b].r(i).get32() >>> 0)),
            psw: [cpu.psw.psw1.get32() >>> 0, cpu.psw.psw2.get32() >>> 0],
            timeNs: cpu.timeNs, pending: cpu.intPendingReg,
            mem: mem.join(','), prot: prot.join(''), ls: ls.join(','),
            iop: iop.globalRegs().map((r) => `${r.name}=${r.value}`),
            slice: iop.ls.slice, page: iop.ls.curPage,
            dma: iop.dmaQueue.length,
            wd: [iop.wdCount, iop.wdRunning, iop.wdTimeout].join(','),
        });
    };
    const coldLoad = () => { const h = new AGEHarness(); h.configureFromOpts(FCM, {}); return h; };

    const ref = snapshot(coldLoad());
    const run = coldLoad();
    for (let i = 0; i < 5000 && !run.cpu.psw.getWaitState(); i++) run.gpc.exec1();
    // ...and dirty the IOP and memory the way a self-test would.
    run.gpc.iop.recvFromCPU(PCO_MASTER_RESET, 0);
    run.gpc.iop.recvFromCPU(PCO_ENABLE, 0xffffff80);
    run.gpc.iop.recvFromCPU(0x88040000, 0x800);
    run.gpc.iop.ls.at(0, 0, 2).set32(0x1234);
    run.gpc.iop.queueDMA(0x100, 'write');
    run.cpu.mainStorage.setStoreProtect(0x1500, false);
    run.cpu.mainStorage.set16(0x1500, 0xdead, false);
    check('a run changes the machine', snapshot(run) === ref, false);
    run.reset();
    check('...and a reset puts every piece of it back', snapshot(run), ref);

    // The BCE waits: max time out, delay, error termination
    //
    // A BCE that has commanded a subsystem sits at its receive instruction
    // until the words arrive or its maximum time out register runs out.
    // Both halves matter: without the wait the instruction queues its word
    // count and runs on, and without the time out a subsystem that stops
    // sending leaves the BCE going round its program for ever.
    const BCE = 3;
    const runBCE = (g, steps) => {
        // Slice the IOP until BCE `BCE` has had `steps` of its own.
        let seen = 0, guard = 0;
        while (seen < steps && guard++ < 100000) {
            const before = g.iop.ls.curPage;
            g.iop.exec();
            if (before !== BCE && g.iop.ls.curPage === BCE) { /* about to run */ }
            if (g.iop.ls.curPage === BCE) seen++;
        }
    };
    const armBCE = (g, pc) => {
        g.iop.recvFromCPU(PCO_MASTER_RESET, 0);
        g.iop.recvFromCPU(PCO_ENABLE, 0xffffff80);        // every processor
        g.iop.regBusyWait.set32(0xffffff80);              // ...and busy
        g.iop.ls.at(BCE, 0, 2).set32(pc);                 // its program counter
        g.iop.recvTimeoutFloorNs = 0;                     // exact hardware timing
        g.iop.recvFromCPU(0x85040000, 0xffffff80);        // MIA transmitters on
    };

    // #LTO takes the fullword at PC(updated) + displacement + 2 x BCE#.
    gpc = mkGPC();
    armBCE(gpc, 0x400);
    poke(gpc, 0x400, 0xb800);            // #LTO 0
    // PC(updated) + 2 x BCE#, as a fullword: 0x401 + 6 = 0x407, and the
    // low bit of a fullword address is ignored.
    poke(gpc, 0x406, 0x0003);
    poke(gpc, 0x407, 0xffff);
    runBCE(gpc, 1);
    check('#LTO loads the time out from PC(updated) + 2 x BCE#',
          gpc.iop.ls.at(BCE, 1, 3).get32() >>> 0, 0x3ffff);
    check('...and that is 4.325 seconds',
          Math.round(gpc.iop.recvTimeoutNs(BCE) / 1e6), 4325);

    // A delay holds the BCE at the instruction for count x 16.5 us.
    gpc = mkGPC();
    armBCE(gpc, 0x400);
    poke(gpc, 0x400, 0xc000 | 100);      // #DLYI 100 -> 1.65 ms
    poke(gpc, 0x401, 0xe800);            // #SIB
    gpc.cpu.timeNs = 0;
    runBCE(gpc, 4);
    check('a delay leaves the program counter where it is',
          gpc.iop.ls.at(BCE, 0, 2).get32(), 0x400);
    gpc.cpu.timeNs = 2e6;                // 2 ms later
    runBCE(gpc, 1);
    check('...and releases it when the count is up',
          gpc.iop.ls.at(BCE, 0, 2).get32() > 0x400, true);

    // A receive waits for its words, one at a time.
    gpc = mkGPC();
    armBCE(gpc, 0x400);
    gpc.iop.ls.at(BCE, 1, 3).set32(1000);          // MTO = 16.5 ms
    gpc.iop.ls.at(BCE, 2, 3).set32(0x1000);        // BASE
    poke(gpc, 0x400, 0xf300); poke(gpc, 0x401, 2); // #RDLI 2 -> 3 halfwords
    gpc.cpu.timeNs = 0;
    runBCE(gpc, 3);
    check('a receive with no words does not advance',
          gpc.iop.ls.at(BCE, 0, 2).get32(), 0x400);
    check('...and writes nothing', gpc.cpu.mainStorage.get16(0x1000), 0);
    gpc.iop.bce[BCE - 1].mia.recvQueue.push(0x1111, 0x2222);
    runBCE(gpc, 2);
    check('...takes the words that have arrived',
          gpc.cpu.mainStorage.get16(0x1001), 0x2222);
    check('...and still waits for the last one',
          gpc.iop.ls.at(BCE, 0, 2).get32(), 0x400);
    gpc.iop.bce[BCE - 1].mia.recvQueue.push(0x3333);
    runBCE(gpc, 2);
    check('...then completes and advances past the long format',
          gpc.iop.ls.at(BCE, 0, 2).get32(), 0x402);
    check('...having written every word',
          gpc.cpu.mainStorage.get16(0x1002), 0x3333);

    // #MOUT / #MIN carry their own command word
    //
    // Both are FOUR-halfword instructions: the transfer word, then a
    // companion fullword of eight zero bits, a 5-bit interface unit
    // address and a 19-bit command.  The companion has no opcode, so it
    // is never fetched and decoded -- the parent reads it and puts the
    // command on the bus.  While it was a table entry of its own, its
    // all-don't-care descriptor took the decoder's catch-all slot, no
    // command ever went out, and the program counter landed on the low
    // half of the companion word.
    const spyCmds = (g) => {
        const sent = [];
        for (const b of g.iop.bce) {
            b.mia.xmitCmd = (c) => sent.push(c >>> 0);
            b.mia.xmitWord = () => {};
        }
        return sent;
    };

    // #MOUT: the command goes out, then the data off the DMA queue.
    gpc = mkGPC();
    armBCE(gpc, 0x400);
    gpc.iop.ls.at(BCE, 2, 3).set32(0x1000);        // BASE
    let sent = spyCmds(gpc);
    poke(gpc, 0x400, 0xf500); poke(gpc, 0x401, 6);  // #MOUT 0,6 -> 7 halfwords
    poke(gpc, 0x402, 0x0057); poke(gpc, 0x403, 0x0007);  // IUA 10, command
    runBCE(gpc, 1);
    check('#MOUT transmits its companion command', sent.length, 1);
    check('...with the interface unit address in bits 23-19',
          (sent[0] >>> 19) & 0x1f, 10);
    check('...and the 19 command bits below it', sent[0] & 0x7ffff, 0x70007);
    check('...and records the address it addressed',
          gpc.iop.ls.at(BCE, 2, 5).get32(), 10);
    check('...and queues every data word',
          gpc.iop.dmaQueue.filter((r) => r.bce === gpc.iop.bce[BCE - 1]).length, 7);
    check('...then steps past all four halfwords',
          gpc.iop.ls.at(BCE, 0, 2).get32(), 0x404);

    // #MIN: the command asks for the data, and goes out ONCE however many
    // times the BCE re-fetches the instruction waiting for it.
    gpc = mkGPC();
    armBCE(gpc, 0x400);
    gpc.iop.ls.at(BCE, 1, 3).set32(1000);          // MTO = 16.5 ms
    gpc.iop.ls.at(BCE, 2, 3).set32(0x1000);        // BASE
    sent = spyCmds(gpc);
    poke(gpc, 0x400, 0xf100); poke(gpc, 0x401, 2);  // #MIN 0,2 -> 3 halfwords
    poke(gpc, 0x402, 0x0050); poke(gpc, 0x403, 0x2000);  // IUA 10, poll
    gpc.cpu.timeNs = 0;
    runBCE(gpc, 3);
    check('#MIN transmits its companion command', sent.length, 1);
    check('...the poll command', sent[0] & 0x7ffff, 0x02000);
    check('...and then waits', gpc.iop.ls.at(BCE, 0, 2).get32(), 0x400);
    check('...without asking again', sent.length, 1);
    gpc.iop.bce[BCE - 1].mia.recvQueue.push(0x1111, 0x2222, 0x3333);
    runBCE(gpc, 2);
    check('...takes the response', gpc.cpu.mainStorage.get16(0x1002), 0x3333);
    check('...and steps past all four halfwords',
          gpc.iop.ls.at(BCE, 0, 2).get32(), 0x404);
    check('...having asked exactly once', sent.length, 1);

    // A receive that runs out of time is an error termination.
    gpc = mkGPC();
    armBCE(gpc, 0x400);
    gpc.iop.ls.at(BCE, 1, 3).set32(1000);          // MTO = 16.5 ms
    gpc.iop.ls.at(BCE, 2, 3).set32(0x1000);
    poke(gpc, 0x400, 0xf300); poke(gpc, 0x401, 0);  // #RDLI 0 -> 1 halfword
    gpc.cpu.timeNs = 0;
    runBCE(gpc, 2);
    check('before the time out the BCE is still going', gpc.iop.procState(BCE).busy, true);
    gpc.cpu.timeNs = 20e6;                          // past 16.5 ms, still nothing
    runBCE(gpc, 2);
    check('a receive time out takes the BCE out of the busy state',
          gpc.iop.procState(BCE).busy, false);
    check('...sets its program exception bit to NO-GO',
          gpc.iop.procState(BCE).go, false);
    check('...sets its indicator bit', gpc.iop.procState(BCE).indicator, true);
    check('...and drops what the MIA had taken',
          gpc.iop.bce[BCE - 1].mia.recvQueue.length, 0);
    check('...and the transfer is over', gpc.iop.bce[BCE - 1].recv, null);

    // A BCE taken out of the busy state part way through a receive
    // abandons it: words left queued would be handed to the next
    // transaction and put every word of it one place out.
    gpc = mkGPC();
    armBCE(gpc, 0x400);
    gpc.iop.ls.at(BCE, 1, 3).set32(0x3ffff);
    gpc.iop.ls.at(BCE, 2, 3).set32(0x1000);
    poke(gpc, 0x400, 0xf300); poke(gpc, 0x401, 3);  // #RDLI 3 -> 4 halfwords
    gpc.iop.bce[BCE - 1].mia.recvQueue.push(0x1111, 0x2222);
    runBCE(gpc, 2);
    check('a part-finished receive is in progress',
          gpc.iop.bce[BCE - 1].recv !== null, true);
    gpc.iop.procSet(gpc.iop.regBusyWait, BCE, 0);   // the MSC stops it
    gpc.iop.bce[BCE - 1].mia.recvQueue.push(0x3333);
    runBCE(gpc, 2);
    check('stopping the BCE abandons it', gpc.iop.bce[BCE - 1].recv, null);
    check('...and drops the words nobody took',
          gpc.iop.bce[BCE - 1].mia.recvQueue.length, 0);

    // @RBI names its BCE by the accumulator, with the field as an addend.
    gpc = mkGPC();
    gpc.iop.recvFromCPU(PCO_MASTER_RESET, 0);
    gpc.iop.regIndicator.set32(0xffffffff);
    gpc.iop.ls.at(0, 1, 3).set16(0);                // ACC high
    gpc.iop.ls.at(0, 2, 3).set16(18);               // ACC low = BCE 18
    gpc.iop.recvFromCPU(PCO_ENABLE, 0xffffff80);
    gpc.iop.regBusyWait.set32(0xffffff80);
    gpc.iop.ls.at(0, 0, 2).set32(0x500);
    poke(gpc, 0x500, 0xe700);                       // @RBI 0
    while (gpc.iop.ls.curPage !== 0 || gpc.iop.ls.at(0, 0, 2).get32() === 0x500)
        gpc.iop.exec();
    check('@RBI resets the BCE the accumulator names',
          gpc.iop.procState(18).indicator, false);
    check('...and not processor 0', gpc.iop.procState(0).indicator, true);

    console.log(`\n${pass} passed, ${fail} failed`);
    process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
