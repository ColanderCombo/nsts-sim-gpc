// test_cpu_instr.cjs — CPU instruction semantics that the timing and
// interrupt suites don't reach: operand ordering within an instruction,
// and what an instruction leaves behind when it takes a program interrupt.
//
// Usage:  node test/test_cpu_instr.cjs
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

    console.log(`\n${pass} passed, ${fail} failed`);
    process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
