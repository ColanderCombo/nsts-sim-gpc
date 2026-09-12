// cpu_instr.cjs — CPU instruction semantics that the timing and
// interrupt suites don't reach: operand ordering within an instruction,
// and what an instruction leaves behind when it takes a program interrupt.
//
// Usage:  node test/gpc/cpu_instr.cjs
//
// Exit status is 1 iff any assertion fails.

'use strict';

const path    = require('path');
const os      = require('os');
const esbuild = require('esbuild');
const coffeePlugin = require('esbuild-coffeescript');

const SRC = path.resolve(__dirname, '..', '..', 'src', 'gpc');

async function bundle(entry) {
    const out = path.join(os.tmpdir(),
        `cpuinstr.${path.basename(entry, '.coffee')}.${process.pid}.cjs`);
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

    // Run one instruction at 0x800.
    function exec(cpu, hw1, hw2 = 0) {
        cpu.psw.setNIA(0x800);
        cpu.ram.set16(0x800, hw1);
        cpu.ram.set16(0x801, hw2);
        cpu.exec1();
    }

    // BRANCH ON COUNT: the branch address, then the count
    //
    // "First, the branch address is computed. ... Then, the contents of
    // bits 0 through 15 of general register R1 are reduced by one."  R1 is
    // three bits and B2 is two, so R1 can name the base register, and X2
    // is three bits, so it can name the index register.  Either way the
    // address is formed from the count as it stands on entry.
    //
    // 11010 R1 11110 A BB, hw2 = 16-bit displacement when A = 0.
    const BCT = (r1, am, b2) => 0xD0F0 | (r1 << 8) | (am << 2) | b2;

    // R1 = B2 = 1: base is the count halfword itself.
    let cpu = new CPU();
    cpu.r(1).set32((2 << 16) | 0x0055);
    exec(cpu, BCT(1, 0, 1), 0x0900);
    check('BCT takes its base before the count', cpu.psw.getNIA(), 0x0902);
    check('...and still counts down', cpu.r(1).get32() >>> 16, 1);
    check('...leaving the low halfword alone', cpu.r(1).get32() & 0xffff, 0x0055);

    // R1 = X2 = 2, B2 = 3 (no base addressing), displacement 0x100.
    cpu = new CPU();
    cpu.r(2).set32((5 << 16) | 0);
    exec(cpu, BCT(2, 1, 3), (2 << 13) | 0x100);
    check('BCT takes its index before the count', cpu.psw.getNIA(), 0x0105);
    check('...and counts that register down', cpu.r(2).get32() >>> 16, 4);

    // A count that reaches zero does not branch, and the address is still
    // computed -- an automatic-modification address would be modified.
    cpu = new CPU();
    cpu.r(1).set32((1 << 16) | 0);
    exec(cpu, BCT(1, 0, 1), 0x0900);
    check('a BCT count of one does not branch', cpu.psw.getNIA(), 0x802);
    check('...and leaves the count at zero', cpu.r(1).get32() >>> 16, 0);

    // BCTR, same ordering with the branch address in R2.
    cpu = new CPU();
    cpu.r(1).set32((2 << 16) | 0);
    exec(cpu, 0xD0E0 | (1 << 8) | 1);       // BCTR R1=1,R2=1
    check('BCTR takes its branch address before the count',
          cpu.psw.getNIA(), 0x0002);

    // CONVERT TO FIXED POINT: a convert overflow stores nothing
    //
    // IBM-6246156B/8-12: "A convert overflow occurs when a floating-point
    // second operand is not properly converted to fixed-point.  This occurs
    // when the characteristic is larger than 44 hexadecimal 1000100 (2) or
    // when bit 8 of the intermediate value is a 1 unless the number is
    // negative and bits 9 through 31 are zero.  The value of R1 is
    // unchanged."  The condition code is defined over the result in R1, and
    // there is no result.
    //
    // 00111 R1 11100 R2
    const CVFX = (r1, r2) => 0x38E0 | (r1 << 8) | r2;

    // Characteristic 4A, well past 44: convert overflow.
    cpu = new CPU();
    cpu.r(1).set32(0xDEADBEEF);
    cpu.psw.setCC(2);
    cpu.f(2).set32(0x4A100000);
    exec(cpu, CVFX(1, 2));
    check('a convert overflow leaves R1 unchanged',
          cpu.r(1).get32() >>> 0, 0xDEADBEEF);
    check('...and the condition code unchanged', cpu.psw.getCC(), 2);

    // In range, so the result is stored and the code set from bits 0-15.
    cpu = new CPU();
    cpu.r(1).set32(0xDEADBEEF);
    cpu.f(2).set32(0x44123400);
    exec(cpu, CVFX(1, 2));
    check('a convert in range stores its result',
          cpu.r(1).get32() >>> 0, 0x12340000);
    check('...and sets the code positive', cpu.psw.getCC(), 1);

    // A short-format fullword operand is addressed by halfword, and an odd
    // base is not rounded down.  Software relies on it: a record of an odd
    // number of halfwords puts every second instance on an odd boundary,
    // and its leading address/sector pair is still read as one fullword.
    // 00011 R1 dddddd BB  =  L R1,D2(B2)
    const L = (r1, d2, b2) => 0x1800 | (r1 << 8) | (d2 << 2) | b2;
    cpu = new CPU();
    cpu.ram.set16(0x900, 0x1111);
    cpu.ram.set16(0x901, 0x2222);
    cpu.ram.set16(0x902, 0x3333);
    cpu.r(1).set32(0x09010000);            // odd base
    exec(cpu, L(3, 0, 1));
    check('L takes its fullword from an odd base',
          cpu.r(3).get32() >>> 0, 0x22223333);
    cpu.r(1).set32(0x09000000);            // even base, displacement 1
    exec(cpu, L(3, 1, 1));
    check('...and a fullword displacement still counts fullwords',
          cpu.r(3).get32() >>> 0, 0x33330000);

    // MOVE HALFWORD OPERANDS: what R1 keeps.
    //
    // R1 carries the destination as a 16-bit field whose bit 0 chooses
    // between the PSW's DSR and R1's own DSE, and a count.  The move
    // zeroes the count and leaves the address field as it was -- not the
    // expanded address, whose bit 15 is the low bit of the sector.
    // Software moves two buffers to one destination by adding the first
    // count to R1 and moving again; write the expanded address back and an
    // odd sector turns the second move into a DSR move, which lands it
    // 8 sectors away.
    // 01101 R1 11101 R2
    const MVH = (r1, r2) => 0x68E8 | (r1 << 8) | r2;
    cpu = new CPU();
    // Store protection defaults on, and a refused store ends the move
    // before R1 is updated at all.
    for (let a = 0; a < 0xa000; a++) cpu.mainStorage.setStoreProtect(a, false);
    cpu.regFiles[cpu.psw.getRegSet()].setDSE(3, 1);   // an ODD sector
    cpu.psw.setDSR(0);
    for (let i = 0; i < 4; i++) cpu.ram.set16(0x900 + i, 0xA000 + i);
    cpu.r(3).set32(0x02980004);          // offset 0x298, bit 0 clear, 4 hw
    cpu.r(5).set32(0x09000000);          // source 0x900, sector 0
    exec(cpu, MVH(3, 5));
    check('MVH moves to the sector its DSE names',
          cpu.ram.get16((1 << 15) | 0x298) >>> 0, 0xA000);
    check('...and R1 keeps the address field it was given, count zeroed',
          cpu.r(3).get32() >>> 0, 0x02980000);
    // The second move of the pair, built the way software builds it: take
    // R1 as the move left it, add the first count, put a new count in.
    cpu.r(3).set32((((cpu.r(3).get32() >>> 16) + 4) << 16 | 4) >>> 0);
    exec(cpu, MVH(3, 5));
    check('...so a second move lands in the same sector',
          cpu.ram.get16((1 << 15) | 0x29c) >>> 0, 0xA000);
    check('...and not in the one the PSW names',
          cpu.ram.get16(0x29c) >>> 0, 0);

    // BRANCH AND LINK through a cross-sector linkage word
    //
    // Effective-address generation is not side-effect free.  A fullword
    // indirect pointer with C=1 replaces the PSW's BSR and/or DSR from the
    // pointer -- that is what a cross-sector call is -- and the link a BAL
    // leaves must still describe the caller, or the return puts the caller
    // back with the callee's sector registers and every short-format
    // operand after it reads from the wrong sector.
    //
    // The programming note under BALR is the wording that settles it: what
    // is stored is "the address (instruction counter and BSR) of the next
    // sequential instruction" -- an instruction of the caller.
    //
    // Encoding taken from a flight member: BAL 7,@@X'000c'(7) = e7f7 f80c.
    // B2 = 11 so no base is added, the displacement is the pointer address;
    // X = 7, IA = 1, II = 1 -> the double-indirect form.
    {
        const cpu = new CPU();
        cpu.psw.setBSR(0);
        cpu.psw.setDSR(1);                 // the CALLER's data sector
        // The linkage word: address 0x9000 (bit 0 set for expansion),
        // XC = 1 (no post-indexing), C = 1, CB = 0, CD = 1, BSR 0, DSR 3.
        cpu.ram.set32(0x00c, 0x90000D03);
        cpu.r(7).set32(0);                 // index contributes nothing
        exec(cpu, 0xe7f7, 0xf80c);

        check('BAL through a linkage word takes the branch it names',
              cpu.psw.getNIA() >>> 0, 0x1000);
        check('...and the pointer replaces the PSW DSR for the callee',
              cpu.psw.getDSR(), 3);
        check('...while the link keeps the CALLER\'s DSR, not the callee\'s',
              cpu.r(7).get32() & 0x0f, 1);
        check('...and the caller\'s BSR',
              (cpu.r(7).get32() >>> 4) & 0x0f, 0);
        check('...addressing the next sequential instruction',
              (cpu.r(7).get32() >>> 16) & 0xffff, 0x802);
    }

    // SUPERVISOR CALL: the sector of the parameter list
    //
    // The interrupt code the call leaves in the old PSW is 16 bits and the
    // effective address is 19, so the sector has to travel separately or a
    // handler cannot reach a parameter list outside sector 0.  It goes in
    // PSW bits 40-43, which the documentation to hand lists as reserved --
    // flight software reads exactly those bits, shifting the old PSW's
    // third halfword right by four and masking to four bits.
    //
    // Encoding from a flight member: SVC X'0058'(R1) = c9f9 0058.
    {
        const cpu = new CPU();
        cpu.psw.setDSR(1);
        cpu.ram.set32(0x5c, 0x00000000);      // a new PSW to swap to
        cpu.ram.set32(0x5e, 0x00000000);
        cpu.r(1).set32(0x87000000);           // base: sector 1, offset 0x700
        exec(cpu, 0xc9f9, 0x0058);            // -> EA 0x8758

        const hw3 = cpu.ram.get16(0x5b) >>> 0;   // old PSW halfword 3
        const hw2 = cpu.ram.get16(0x5a) >>> 0;   // old PSW halfword 2
        check('a supervisor call leaves its effective address in the code',
              hw3, 0x8758);
        check('...and the sector of that address in PSW 40:43',
              (hw2 >> 4) & 0xf, 1);
    }

    // FULLWORD INDIRECT ADDRESS POINTER: the sector is a replacement,
    // not an extension
    //
    // A pointer carries a sector beside its address, and Figure 2-17 draws
    // the address' high-order bit as a literal 1 -- a pointer into the
    // upper sectors always has it set.  It is still the sect. 2.2.9 gate:
    // with the bit clear the address is in sector 0 whatever the pointer's
    // sector says.  Software depends on it -- a display builds its field
    // pointers by storing the address alone over one shared control
    // halfword, so a compool below 32K and one above it are reached
    // through the same pointer.
    //
    // LH R7,@@X'0036'(3,1) = 9ff5 7836: X=3, IA=1, I=1.
    {
        const lo = () => {
            const cpu = new CPU();
            cpu.r(1).set32(0x19dc0000);        // base -> the pointer at 0x1a12
            cpu.r(3).set32(0x00000000);        // index 0
            cpu.psw.setDSR(5);
            cpu.ram.set32(0x1a12, 0x2f900801); // address 0x2f90, XC=1 C=0 DSR=1
            cpu.ram.set16(0x2f90, 0x3000);     // what is really there
            cpu.ram.set16(0xaf90, 0xc6c6);     // ...and one sector up
            exec(cpu, 0x9ff5, 0x7836);
            return (cpu.r(7).get32() >>> 16) & 0xffff;
        };
        check('a pointer whose address is below 32K reads sector 0',
              lo(), 0x3000);

        const hi = () => {
            const cpu = new CPU();
            cpu.r(1).set32(0x19dc0000);
            cpu.r(3).set32(0x00000000);
            cpu.psw.setDSR(5);
            cpu.ram.set32(0x1a12, 0xaf900801); // the same address, bit 0 set
            cpu.ram.set16(0x2f90, 0x3000);
            cpu.ram.set16(0xaf90, 0xc6c6);
            exec(cpu, 0x9ff5, 0x7836);
            return (cpu.r(7).get32() >>> 16) & 0xffff;
        };
        check('...and with that bit set, the pointer\'s own sector',
              hi(), 0xc6c6);
    }

    // HAL/S-FC places -4095 in R1+1 and +4095 in main storage for
    // MIDVAL(x, -4095, +4095), so exercise both operand orderings.
    // MVS 0,X'000a'(1) = 60f9 000a.  The main storage displacement is in
    // halfwords.
    {
        const mvs = (input, reg, mem) => {
            const cpu = new CPU();
            cpu.r(1).set32(0x20000000);
            cpu.f(0).set32(input);
            cpu.f(1).set32(reg);
            cpu.ram.set32(0x200a, mem);
            exec(cpu, 0x60f9, 0x000a);
            return { f0: cpu.f(0).get32() >>> 0, cc: cpu.psw.getCC() };
        };
        const P4095 = 0x43fff000, N4095 = 0xc3fff000;
        const P2000 = 0x437d0000, P8000 = 0x441f4000, N8000 = 0xc41f4000;

        // Register operand above memory operand.
        check('within limits leaves R1 alone',
              mvs(P2000, P4095, N4095).f0, P2000);
        check('...and sets CC 0',
              mvs(P2000, P4095, N4095).cc, 0);
        check('above the upper limit takes R1+1',
              mvs(P8000, P4095, N4095).f0, P4095);
        check('...and sets CC 1',
              mvs(P8000, P4095, N4095).cc, 1);
        check('below the lower limit takes main storage',
              mvs(N8000, P4095, N4095).f0, N4095);
        check('...and sets CC 3',
              mvs(N8000, P4095, N4095).cc, 3);

        // Register operand below memory operand.
        check('the limits reversed still select the mid value',
              mvs(P2000, N4095, P4095).f0, P2000);
        check('...and above both operands takes the larger',
              mvs(P8000, N4095, P4095).f0, P4095);
        check('...and below both takes the smaller',
              mvs(N8000, N4095, P4095).f0, N4095);
    }

    console.log(`\n${pass} passed, ${fail} failed`);
    process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
