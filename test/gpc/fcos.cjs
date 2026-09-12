
'use strict';

const path    = require('path');
const os      = require('os');
const fs      = require('fs');
const esbuild = require('esbuild');
const coffeePlugin = require('esbuild-coffeescript');

const SRC = path.resolve(__dirname, '..', '..');

async function bundle(entry) {
    const out = path.join(os.tmpdir(),
        `fcos.${path.basename(entry, '.coffee')}.${process.pid}.cjs`);
    await esbuild.build({
        absWorkingDir: SRC,
        entryPoints: [path.join(SRC, 'src', 'gpc', entry)],
        bundle:   true,
        platform: 'node',
        format:   'cjs',
        outfile:  out,
        plugins:  [coffeePlugin()],
        resolveExtensions: ['.coffee', '.js', '.json'],
        external: ['electron', 'dgram'],
        logLevel: 'error',
    });
    return require(out);
}

let pass = 0, fail = 0;
function check(label, got, want) {
    if (got === want) { pass++; }
    else { fail++; console.log(`FAIL  ${label}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`); }
}
function ok(label, cond, why) {
    if (cond) { pass++; }
    else { fail++; console.log(`FAIL  ${label}${why ? `: ${why}` : ''}`); }
}

const CVT   = 0x0140;          // as FCMCVT sits in the PSA
const PDE_A = 0x0700, PDE_B = 0x0706, PDE_C = 0x070c, PDE_D = 0x0712;
const PCT_A = 0x2000, PCT_B = 0x2032, PCT_C = 0x2064;
const FREE  = 0x2096;          // two PCTs on the free chain
const TQE_1 = 0x2200, TQE_2 = 0x2206, EQE_1 = 0x2300;
const EV_C  = 0x0800, EV_D = 0x0802;   // process event variables
const ENTRY_A = 0x40000, ENTRY_B = 0x40100;
const HALFHOUR = 0x8100;       // where FPM30MIN sits

const MEM = new Map();
const put = (a, ...hw) => hw.forEach((v, i) => MEM.set(a + i, v));
const putFw = (a, v) => put(a, (v >>> 16) & 0xffff, v & 0xffff);

put(CVT + 0, PCT_A);           // TCVTPCT
put(CVT + 1, PCT_A);           // TCVTOLD  (active)
put(CVT + 2, PCT_A);           // TCVTNEW
put(CVT + 3, TQE_1);           // TCVTTTQE
put(CVT + 10, FREE);           // TCVTPCTP
put(CVT + 12, 0);              // TCVTTQEP
put(CVT + 11, 0);              // TCVTEQEP
put(CVT + 15, EQE_1);          // TCVTTEQE
putFw(HALFHOUR, 1800000000);

put(PDE_A, 0, PCT_A, 0x8000, 0x0080, 0x1000, 0x8000);
put(PDE_B, 0, PCT_B, 0x8100, 0x0080, 0x1100, 0x8000);
put(PDE_C, EV_C, PCT_C, 0x8200, 0x0080, 0x1200, 0x8000);
put(PDE_D, EV_D, 0,     0x8300, 0x0080, 0x0040, 0x0000);   // never scheduled
put(EV_C, 0);
put(EV_D, 1);

function pct(a, next, pri, pde, flags, wait, nia) {
    put(a + 0x00, next, pri, 0x3000, pde);
    put(a + 0x04, 0, 0, 0, nia);          // PSW, NIA in its last halfword
    put(a + 0x2c, pri, 0, 0);
    put(a + 0x2f, flags, wait, 0);
}
pct(PCT_A, PCT_B, 60, PDE_A, 0xc000, 0x0000, 0x40012);  // FCOS, ready
pct(PCT_B, PCT_C, 40, PDE_B, 0x8080, 0x0002, 0x40110);  // REPEAT EVERY, delta time
pct(PCT_C, 0,     20, PDE_C, 0x8001, 0x0004, 0x40210);  // task, event wait
pct(FREE,  FREE + 0x32, 0, 0, 0, 0, 0);
pct(FREE + 0x32, 0, 0, 0, 0, 0, 0);

put(TQE_1 + 0, TQE_2, PCT_B);
putFw(TQE_1 + 2, 1500000);
put(TQE_1 + 4, 2, 0x2008);      // initial + REPEAT EVERY
put(TQE_2 + 0, 0, PCT_A);       // the queue's permanent end marker
putFw(TQE_2 + 2, 10000000);
put(TQE_2 + 4, 0x7fff, 0);

put(EQE_1 + 0, 0, PCT_C);
putFw(EQE_1 + 2, 1);
put(EQE_1 + 4, EV_C, 0, 0, 0, 0);
put(EQE_1 + 9, 0x8000);

const SECTIONS = [
    { name: '#EALPHA', addr: PDE_A, size: 6 },
    { name: '#EBETA',  addr: PDE_B, size: 6 },
    { name: '#EGAMMA', addr: PDE_C, size: 6 },
    { name: '#EDELTA', addr: PDE_D, size: 6 },
    { name: '$0ALPHA', addr: ENTRY_A, size: 0x100 },
];
const SYMS = {
    TCVTPCT: CVT + 0, TCVTOLD: CVT + 1, TCVTNEW: CVT + 2, TCVTTTQE: CVT + 3,
    TCVTEQEP: CVT + 11, TCVTPCTP: CVT + 10, TCVTTQEP: CVT + 12,
    TCVTTEQE: CVT + 15, FPM30MIN: HALFHOUR,
};
const session = {
    readHw: (a) => MEM.get(a) ?? 0,
    syms: {
        addressOf: (n) => SYMS[n] ?? null,
        sections: () => SECTIONS,
    },
    sectionOf: (a) => {
        for (const s of SECTIONS)
            if (a >= s.addr && a < s.addr + s.size) return s.name;
        return null;
    },
    labelAt: (a) => {
        if (a === EV_C) return 'GAMMA_EVENT';
        const s = SECTIONS.find((x) => x.addr === a);
        return s ? s.name : null;
    },
    sdl: {
        unitByStem: new Map([['ALPHA', 0], ['BETA', 1]]),
        unitName: (i) => ['ALPHA_PROCESS', 'BETA_PROCESS'][i] ?? null,
    },
};

(async () => {
    const { FcosView, PCT, PDE, TQE, EQE, flagText, waitText } =
        await bundle('dbg/fcos/fcos.coffee');

    check('PCT length',        PCT.LEN,  0x32);
    check('PCT wait word',     PCT.WAIT, 0x30);
    check('PCT flags',         PCT.FLGS, 0x2f);
    check('PCT directory ptr', PCT.PDE,  0x03);
    check('PDE length',        PDE.LEN,  6);
    check('PDE pct field',     PDE.PCT,  1);
    check('TQE length',        TQE.LEN,  6);
    check('EQE length',        EQE.LEN,  0xa);
    check('EQE first variable', EQE.VAR, 4);

    const v = new FcosView(session);
    ok('the CVT is found by symbol', v.cvt() !== null);

    const run = v.runQueue();
    check('three PCTs are chained', run.pcts.length, 3);
    check('the head is the CVT run queue', run.head, PCT_A);
    check('the active PCT is marked', run.pcts[0].active, true);
    check('priority order is kept',
          run.pcts.map((p) => p.priority).join(','), '60,40,20');
    check('a zero wait word is ready',  run.pcts[0].state, 'ready');
    check('a non-zero one is waiting',  run.pcts[1].state, 'waiting');
    check('the wait word decodes',      run.pcts[1].waitText, 'delta time');
    check('and so does an event wait',  run.pcts[2].waitText, 'event');
    check('flags decode',               run.pcts[0].flagText, 'FCOS');
    check('a repeat option decodes',    run.pcts[1].flagText, 'REPEAT EVERY');
    check('a task says so',             run.pcts[2].flagText, 'task');
    check('the PDE names the process',  run.pcts[0].process, 'ALPHA_PROCESS');
    check('and falls back to the csect stem when the index has no unit',
          run.pcts[2].process, 'GAMMA');

    MEM.set(PCT_B + PCT.FLGS, 0x0080);
    check('clearing the live bit is what cancels',
          v.runQueue().pcts[1].state, 'cancelled');
    MEM.set(PCT_B + PCT.FLGS, 0x8080);
    MEM.set(PCT_C + PCT.FLGS, 0x8801);
    check('the terminated bit outranks the wait word',
          v.runQueue().pcts[2].state, 'terminated');
    MEM.set(PCT_C + PCT.FLGS, 0x8001);

    put(0x2400, 0, 0, 0, 0);
    MEM.set(PCT_C + PCT.NXT, 0x2400);
    const withIdle = v.runQueue();
    check('a PCT with no PDE is the idle process',
          withIdle.pcts[3].state, 'idle');
    check('and is named as such', withIdle.pcts[3].process, 'FCOS idle');
    check('and is not an orphan', v.processes().orphans.length, 0);
    MEM.set(PCT_C + PCT.NXT, 0);

    const tq = v.timeQueue();
    check('two TQEs',          tq.tqes.length, 2);
    check('the last is the queue end marker', tq.tqes[1].sentinel, true);
    check('and says so',       tq.tqes[1].type, 'end of queue');
    check('its type decodes',  tq.tqes[0].type, 'REPEAT EVERY');
    check('an initial TQE says so', tq.tqes[0].initial, true);
    check('the half hours and microseconds add up',
          tq.tqes[0].micros, 2 * 1800000000 + 1500000);
    check('and it names its process', tq.tqes[0].process, 'BETA_PROCESS');

    const eq = v.eventQueue();
    check('one EQE',                eq.eqes.length, 1);
    check('its option decodes',     eq.eqes[0].typeText, 'ON');
    check('one event variable',     eq.eqes[0].vars.length, 1);
    check('read at its address',    eq.eqes[0].vars[0].value, 0);
    check('and named',              eq.eqes[0].vars[0].name, 'GAMMA_EVENT');

    const pools = v.pools();
    check('the PCT pool is counted',
          pools.find((p) => p.pool === 'PCT').free, 2);
    check('an empty pool reads zero',
          pools.find((p) => p.pool === 'TQE').free, 0);

    const dir = v.directory();
    check('every #E csect is a process', dir.length, 4);
    check('a PDE with no PCT is unscheduled',
          dir.find((p) => p.csect === '#EDELTA').scheduled, false);
    check('and one with a PCT is not',
          dir.find((p) => p.csect === '#EALPHA').scheduled, true);
    check('the entry ZCON resolves through its BSR',
          dir.find((p) => p.csect === '#EALPHA').entry.addr, ENTRY_A);
    check('and is labelled',
          dir.find((p) => p.csect === '#EALPHA').entry.label, '$0ALPHA');
    check('a preallocated stack is an address',
          dir.find((p) => p.csect === '#EALPHA').stack, 0x1000);
    check('and a size when the flag is clear',
          dir.find((p) => p.csect === '#EDELTA').stackSize, 0x40);
    check('the event variable field is read',
          dir.find((p) => p.csect === '#EDELTA').event, EV_D);
    check('a directory entry the load placed is resident',
          dir.find((p) => p.csect === '#EDELTA').resident, true);

    const st = v.processes();
    check('the join covers the directory', st.processes.length, 4);
    const beta = st.processes.find((p) => p.csect === '#EBETA');
    check('a scheduled process carries its PCT row', beta.pctRow.addr, PCT_B);
    check('and the TQE holding it', beta.pctRow.tqes.length, 1);
    const gamma = st.processes.find((p) => p.csect === '#EGAMMA');
    check('an event waiter carries its EQE', gamma.pctRow.eqes.length, 1);
    const delta = st.processes.find((p) => p.csect === '#EDELTA');
    check('an unscheduled one carries no PCT row', delta.pctRow, null);
    check('and says so',              delta.state, 'unscheduled');

    MEM.set(PDE_D + PDE.PCT, 0x9999);
    check('a PCT that is not on the run queue is stale',
          v.processes().processes.find((p) => p.csect === '#EDELTA').state,
          'stale PCT');
    MEM.set(PDE_D + PDE.PCT, 0);
    for (const fill of [0xc9fb, 0xc6c6]) {
        for (let i = 0; i < PDE.LEN; i++) MEM.set(PDE_D + i, fill);
        const gone = v.processes().processes.find((p) => p.csect === '#EDELTA');
        check(`an entry reading ${fill.toString(16)} is not resident`,
              gone.resident, false);
        check(`and says so for ${fill.toString(16)}`, gone.state, 'not resident');
    }
    put(PDE_D, EV_D, 0, 0x8300, 0x0080, 0x0040, 0x0000);
    check('nothing is orphaned here', st.orphans.length, 0);

    MEM.set(PCT_C + PCT.PDE, 0x7ffe);
    const orphaned = v.processes();
    check('the stray PCT is an orphan', orphaned.orphans.length, 1);
    check('and the directory still has four', orphaned.processes.length, 4);
    MEM.set(PCT_C + PCT.PDE, PDE_C);

    MEM.set(PCT_C + PCT.NXT, PCT_A);
    const looped = v.runQueue();
    check('a cycle stops at the repeat', looped.pcts.length, 3);
    MEM.set(PCT_C + PCT.NXT, 0);

    check('flagText on nothing', flagText(0), '');
    check('waitText on nothing', waitText(0), 'ready');
    check('several wait bits join', waitText(0x06), 'delta time+event');

    console.log(`\n${pass} passed, ${fail} failed`);
    process.exit(fail ? 1 : 0);
})().catch((e) => {
    console.error(e);
    process.exit(1);
});
