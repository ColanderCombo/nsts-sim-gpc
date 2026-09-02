// test_guimirror.cjs — the GUI's execution backend
//
// The window draws a mirror (gpc/guimirror) of a `DebugSession` reached
// over the socket protocol, refilled by the `guisnap` command.  The claim
// this file tests:
//
//   for everything a pane reads, the mirror answers what the machine's
//   objects would.
//
// So each assertion compares the mirror against the live session beside it,
// not against a constant -- memory values, store protection, the
// access and protection colours, both register banks, the DSE bits, the
// change-tracking steps, the PSW's unpacked fields, the interrupt
// repertoire, the timers and the IOP.
//
// Also here: the window discovery (a pane cannot say what memory it wants
// until it has read it, so the mirror records the reads and asks next
// time), and the write-through path for a register edited in a pane.
//
// Usage:  node test/test_guimirror.cjs
//
// Exit status is 1 iff any assertion fails.

'use strict';

const path    = require('path');
const os      = require('os');
const fs      = require('fs');
const esbuild = require('esbuild');
const coffeePlugin = require('esbuild-coffeescript');

const SRC = path.resolve(__dirname, '..');

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
    const out = path.join(os.tmpdir(), `guimirror.${path.basename(entry)}.${process.pid}.cjs`);
    await esbuild.build({
        absWorkingDir: SRC,
        entryPoints: [entry],
        bundle: true, platform: 'node', format: 'cjs',
        outfile: out,
        plugins: [civetPlugin, coffeePlugin()],
        resolveExtensions: ['.coffee', '.js', '.ts', '.civet', '.json'],
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
function deep(label, got, want) {
    check(label, JSON.stringify(got), JSON.stringify(want));
}

// ENTRY stores 1, 2 then 3 into WATCH and runs on into halfwords of zero,
// which decode as A 0,X'0000'(0) and never end.  The stores are what give
// the access-tracking arrays something to say.
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

function writeSymbols(file) {
    fs.writeFileSync(file, JSON.stringify({
        version: 'test', imageSize: 0x800, entryPoint: ENTRY,
        sections: [{ name: '#TEST', address: ENTRY, size: 16, module: 'TEST' }],
        symbols: [
            { name: 'ENTRY', address: ENTRY, type: 'code', module: 'TEST' },
            { name: 'WATCH', address: WATCH, type: 'data', module: 'TEST' },
        ],
        relocations: [],
        // A protected run, so getStoreProtect and getProtColor have both
        // answers to give.
        storeProtect: { unit: 'halfword', ranges: [[ENTRY, ENTRY + 12]] },
    }));
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
    const { DebugSession } = await bundle(path.join(SRC, 'gpc/dbgsession.coffee'));
    const { DebugServer }  = await bundle(path.join(SRC, 'gpc/dbgserver.coffee'));
    const { DebugClient }  = await bundle(path.join(SRC, 'gpc/dbgclient.coffee'));
    const mirrorMod        = await bundle(path.join(SRC, 'gpc/guimirror.coffee'));
    const { GUIMirror, coalesce } = mirrorMod;

    // Window coalescing, on its own
    //
    deep('one run coalesces to one window',
         coalesce([5, 6, 7, 8]), [{ addr: 5, count: 4 }]);
    deep('a small gap is bridged',
         coalesce([5, 6, 20, 21]), [{ addr: 5, count: 17 }]);
    deep('a wide gap splits',
         coalesce([5, 6, 500, 501]), [{ addr: 5, count: 2 }, { addr: 500, count: 2 }]);
    deep('out of order still coalesces',
         coalesce([8, 5, 7, 6]), [{ addr: 5, count: 4 }]);
    deep('nothing read asks for nothing', coalesce([]), []);
    check('a window is capped', coalesce([0, 5000], 8192, 4096, 16384)[0].count, 4096);
    const run = Array.from({ length: 20000 }, (_, i) => i);
    const capped = coalesce(run, 32, 4096, 8192);
    check('the total is capped too',
          capped.reduce((a, w) => a + w.count, 0), 8192);
    check('and what was dropped is reported, not swallowed',
          capped.truncated, 20000 - 8192);
    check('a request that fits drops nothing', coalesce([1, 2, 3]).truncated, 0);

    // A live session on a socket, and a client of it
    //
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'gpc-guimirror-'));
    const fcm = path.join(tmp, 'tiny.fcm');
    const sym = path.join(tmp, 'tiny.sym.json');
    writeImage(fcm);
    writeSymbols(sym);

    const session = new DebugSession({ fcmPath: fcm, symbols: sym });
    session.load(fcm, { symbols: sym });
    const server = new DebugServer(session, { port: 0, sessionFile: null });
    const [ep] = await server.listen();

    const written = [];
    const client = new DebugClient({ host: ep.host, port: ep.port });
    await client.connect();

    const machine = session.gpc.machine;
    const totalHW = (machine.cpuWords + machine.iopWords) * 2;
    const mirror = new GUIMirror({
        totalHW,
        write: (cmd, args) => { written.push([cmd, args]); client.post(cmd, args); },
    });

    check('the mirror is sized to the machine',
          mirror.cpu.mainStorage.wordCount * 2, totalHW);

    // Run a little, so registers, memory and the access arrays all differ
    // from their power-on state.
    await client.send('step', { count: 6 });

    // A pane's draw: read, then ask for what was read
    //
    // The memory pane spans the end of the protected run, so both answers
    // to getStoreProtect are in the window.
    const draw = () => {
        mirror.beginTrack();
        // What the disassembly and instruction panes do: values only.
        for (let a = ENTRY; a < ENTRY + 12; a++) mirror.cpu.mainStorage.get16(a, false);
        // What the memory pane does: values, protection and colours.
        for (const base of [ENTRY, WATCH]) {
            for (let a = base; a < base + 16; a++) {
                mirror.cpu.mainStorage.get16(a, false);
                mirror.cpu.mainStorage.getStoreProtect(a);
                mirror.cpu.mainStorage.getAccessColor(a);
            }
        }
        return mirror.endTrack();
    };

    let windows = draw();
    ok('the first draw asks for what it read', windows.length >= 1);
    ok('the memory pane\'s window carries the access arrays',
       windows.some((w) => w.access && w.prot));
    ok('nothing is covered before the first snapshot', mirror.stale());

    // The access arrays are marked per window from the addresses that
    // actually wanted them.  A bracket around the memory pane's extremes
    // would mark everything in between, which for a real image is the
    // watch pane's several hundred scattered windows.
    mirror.beginTrack();
    mirror.cpu.mainStorage.getStoreProtect(0x100);      // a memory pane, low
    mirror.cpu.mainStorage.get16(0x4000, false);        // a watch symbol, between
    mirror.cpu.mainStorage.getStoreProtect(0x8000);     // a memory pane, high
    const marked = mirror.endTrack();
    check('three reads, three windows', marked.length, 3);
    deep('and only the two that asked carry the arrays',
         marked.map((w) => !!w.access), [true, false, true]);
    draw();   // put the real draw's windows back

    const snapReq = () => ({ windows: mirror.windows(), want: ['regs', 'ints', 'intlog', 'iop', 'breakpoints', 'halucp'] });
    let snap = await client.send('guisnap', snapReq());
    mirror.apply(snap);
    draw();
    ok('a settled view is not stale', !mirror.stale());

    // Memory: values, protection, and the two colour scales
    //
    const mem = mirror.cpu.mainStorage;
    let same = true, wrong = null;
    for (let a = ENTRY; a < ENTRY + 12; a++) {
        if (mem.get16(a, false) !== session.ram.get16(a, false)) { same = false; wrong = a; break; }
    }
    ok('every halfword in the window matches the session', same, wrong && wrong.toString(16));
    check('a protected halfword reads protected',
          !!mem.getStoreProtect(ENTRY), !!session.ram.getStoreProtect(ENTRY));
    check('an unprotected one does not',
          !!mem.getStoreProtect(WATCH), !!session.ram.getStoreProtect(WATCH));
    check('the step the highlights are measured against',
          mem.step, session.gpc.cpu.mainStorage.step);
    check('a recently written cell gets the session\'s colour',
          mem.getAccessColor(WATCH), session.ram.getAccessColor(WATCH));
    check('an untouched cell gets the steady colour',
          mem.getAccessColor(WATCH + 6), session.ram.getAccessColor(WATCH + 6));
    check('and the halfword past the protected run is unprotected',
          !!mem.getStoreProtect(ENTRY + 12), !!session.ram.getStoreProtect(ENTRY + 12));
    check('the protection colour matches too',
          mem.getProtColor(ENTRY, true), session.ram.getProtColor(ENTRY, true));
    ok('the store WAS seen', session.ram.getLastWritten(WATCH) > 0);
    check('and the mirror knows when it happened',
          mem.getLastWritten(WATCH), session.ram.getLastWritten(WATCH));

    // Reading the mirror must not look like the machine having read it: the
    // access arrays are the session's, not this window's.
    const readMark = mem.getLastRead(ENTRY);
    mem.get16(ENTRY, true);
    check('a pane\'s read does not disturb the access tracking',
          mem.getLastRead(ENTRY), readMark);

    // Registers, both banks, the DSE bits and the PSW
    //
    const cpu = session.gpc.cpu;
    const mcpu = mirror.cpu;
    for (const bank of [0, 1, 2]) {
        let bankOk = true;
        for (let i = 0; i <= 7; i++) {
            if ((mcpu.regFiles[bank].r(i).get32() >>> 0) !== (cpu.regFiles[bank].r(i).get32() >>> 0)) bankOk = false;
            if (mcpu.regFiles[bank].getDSE(i) !== cpu.regFiles[bank].getDSE(i)) bankOk = false;
            if (mcpu.regFiles[bank].getLastWritten(i) !== cpu.regFiles[bank].getLastWritten(i)) bankOk = false;
        }
        ok(`bank ${bank} matches, values, DSE and write marks`, bankOk);
    }
    check('the current register set',  mcpu.psw.getRegSet(), cpu.psw.getRegSet());
    check('r() follows the set',       mcpu.r(3).get32() >>> 0, cpu.r(3).get32() >>> 0);
    check('PSW1',  mcpu.psw.psw1.get32() >>> 0, cpu.psw.psw1.get32() >>> 0);
    check('PSW2',  mcpu.psw.psw2.get32() >>> 0, cpu.psw.psw2.get32() >>> 0);
    check('the NIA, expanded through the BSR', mcpu.psw.getNIA(), cpu.psw.getNIA());
    check('the condition code', mcpu.psw.getCC(), cpu.psw.getCC());
    check('the system interrupt mask', mcpu.psw.getIntMask(), cpu.psw.getIntMask());
    check('the wait bit', !!mcpu.psw.getWaitState(), !!cpu.psw.getWaitState());
    check('the PSW write mark', mcpu.psw.lastWritten1, cpu.psw.lastWritten1);

    // Interrupts, timers and the IOP
    //
    check('the interrupt repertoire is the whole list',
          mcpu.intStatus().length, cpu.intStatus().length);
    deep('and it is the session\'s', mcpu.intStatus(), cpu.intStatus());
    check('timer 1 value',     mcpu.timerValue(1), cpu.timerValue(1) >>> 0);
    check('timer 2 value',     mcpu.timerValue(2), cpu.timerValue(2) >>> 0);
    check('timer 1 high half', mcpu.TIMER_HI(1),   cpu.TIMER_HI(1));
    check('timer 2 high half', mcpu.TIMER_HI(2),   cpu.TIMER_HI(2));
    check('nothing held yet',  mcpu.heldInterrupt(), null);
    check('the IOP slice',     mirror.iop.ls.slice, session.gpc.iop.ls.slice);
    check('the current page',  mirror.iop.ls.curPage, session.gpc.iop.ls.curPage);
    check('every processor is listed',
          mirror.iop.procStates().length,
          session.gpc.iop.procStates().filter((p) => p).length);
    check('the global registers',
          mirror.iop.globalRegs().length, session.gpc.iop.globalRegs().length);

    // An accepted interrupt reaches the log with its code named
    //
    await client.send('intraise', { key: 'clk1' });
    snap = await client.send('guisnap', snapReq());
    mirror.apply(snap);
    check('the accepted count', mirror.cpu.intCount, cpu.intCount);
    ok('the log carries the acceptance', mirror.cpu.intLog.length === cpu.intLog.length);

    // The IOP pane's per-processor disassembly: asked for on one draw,
    // answered on the next.
    //
    mirror.beginTrack();
    check('a processor just unfolded has no rows yet',
          mirror.iop.procDisasm(0, 4).length, 0);
    mirror.endTrack();
    deep('and the request goes out with the next snapshot',
         mirror.iopDisasmWanted(), [{ proc: 0, count: 4 }]);
    snap = await client.send('guisnap',
        Object.assign(snapReq(), { iopdisasm: mirror.iopDisasmWanted() }));
    mirror.apply(snap);
    check('which fills them in',
          mirror.iop.procDisasm(0, 4).length,
          session.gpc.iop.procDisasm(0, 4).length);

    // Breakpoints arrive as the Map the panes were handed
    //
    const bpMap = mirror.breakpoints;
    await client.send('break', { addr: ENTRY + 4 });
    mirror.apply(await client.send('guisnap', snapReq()));
    ok('a breakpoint reaches the mirror', bpMap.get(ENTRY + 4)?.enabled === true);
    ok('the same Map object, not a new one', bpMap === mirror.breakpoints);
    await client.send('bdisable', { addr: ENTRY + 4 });
    mirror.apply(await client.send('guisnap', snapReq()));
    check('and follows it being disabled', bpMap.get(ENTRY + 4).enabled, false);
    // `bclear` takes a string so that `*` can clear them all, and a bare
    // decimal would be read as hex: the GUI sends 0x-prefixed.
    await client.send('bclear', { addr: `0x${(ENTRY + 4).toString(16)}` });
    mirror.apply(await client.send('guisnap', snapReq()));
    check('and it being cleared', bpMap.has(ENTRY + 4), false);

    // Write-through: a register edited in a pane
    //
    written.length = 0;
    mirror.cpu.regFiles[1].r(5).set32(0xdeadbeef);
    deep('a bank 1 edit names its bank',
         written[0], ['setreg', { name: 'R5', value: 0xdeadbeef, bank: 1 }]);
    check('and shows at once in the pane it was typed in',
          mirror.cpu.regFiles[1].r(5).get32() >>> 0, 0xdeadbeef);
    await sleep(50);
    check('and reaches the machine',
          cpu.regFiles[1].r(5).get32() >>> 0, 0xdeadbeef);

    written.length = 0;
    mirror.cpu.regFiles[2].r(1).set32(0x11223344);
    check('a float register is named FP', written[0][1].name, 'FP1');
    await sleep(50);
    check('and reaches the float bank',
          cpu.regFiles[2].r(1).get32() >>> 0, 0x11223344);

    written.length = 0;
    mirror.cpu.regFiles[0].setDSE(3, 0xa);
    deep('a DSE edit', written[0], ['setreg', { name: 'DSE3', value: 0xa, bank: 0 }]);
    await sleep(50);
    check('reaches the machine\'s DSE', cpu.regFiles[0].getDSE(3), 0xa);

    // setNIA reaches PSW1 through the register the pane also edits
    // directly, so the inner write must not go out as well.
    written.length = 0;
    mirror.cpu.psw.setNIA(ENTRY + 8);
    check('setting the NIA sends one command', written.length, 1);
    check('and names the field the pane edited', written[0][1].name, 'NIA');
    await sleep(50);
    check('the machine moved', cpu.psw.getNIA(), ENTRY + 8);

    written.length = 0;
    mirror.cpu.psw.setCC(2);
    check('setting CC sends one command', written.length, 1);
    check('named CC', written[0][1].name, 'CC');
    await sleep(50);
    check('the machine took it', cpu.psw.getCC(), 2);

    // Filling the mirror from a snapshot must not look like a pane edit.
    written.length = 0;
    mirror.apply(await client.send('guisnap', snapReq()));
    check('a refresh sends nothing back', written.length, 0);

    // A view that moves: the draw reads memory the snapshot did not carry,
    // which is what `stale()` is for.
    //
    mirror.beginTrack();
    for (let a = 0x1000; a < 0x1010; a++) mirror.cpu.mainStorage.get16(a, false);
    mirror.endTrack();
    ok('a moved view is stale', mirror.stale());
    mirror.apply(await client.send('guisnap', snapReq()));
    mirror.beginTrack();
    for (let a = 0x1000; a < 0x1010; a++) mirror.cpu.mainStorage.get16(a, false);
    mirror.endTrack();
    ok('and one more fetch settles it', !mirror.stale());

    // sysreset, and the event it publishes
    //
    let stoppedSeen = 0;
    client.on('stopped', () => { stoppedSeen++; });
    await client.send('sysreset');
    await sleep(50);
    ok('a system reset publishes a stop', stoppedSeen >= 1);
    check('and the PSW came from the PSA',
          (await client.send('regs')).nia, cpu.psw.getNIA());

    client.close();
    server.shutdown();
    await sleep(50);

    console.log(`test_guimirror: ${pass} passed, ${fail} failed`);
    process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
