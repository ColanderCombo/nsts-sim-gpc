// ratsnest.cjs — the wiring language, the network it makes, and the
// busses the ports bind
//
// Usage:
//   cd ext/sim && node test/ratsnest/ratsnest.cjs
//
// Exit status is 1 iff any test failed.
'use strict';

const path = require('path');
const os = require('os');
const fs = require('fs');
const { execFileSync } = require('child_process');
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
        `ratsnest.test.${path.basename(rel).replace(/\W/g, '_')}.${process.pid}.cjs`);
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

let passed = 0, failed = 0;
function ok(cond, what) {
    if (cond) { passed++; }
    else { failed++; console.log(`FAIL  ${what}`); }
}
function eq(got, want, what) {
    const g = JSON.stringify(got), w = JSON.stringify(want);
    if (g === w) { passed++; }
    else { failed++; console.log(`FAIL  ${what}\n        got  ${g}\n        want ${w}`); }
}
function section(name) { console.log(`\n--- ${name} ---`); }
const settle = (msec = 120) => new Promise((r) => setTimeout(r, msec));

// The message a wiring text is refused with, or null when it is taken.
function refusal(W, N, text) {
    try {
        const net = new N.Netlist();
        net.elaborate(W.parse(text, 'test.wir'));
        return null;
    } catch (e) {
        return e.message;
    }
}

// A netlist from one wiring text, with the clock under this test's control.
function build(W, N, text, clock) {
    const net = new N.Netlist();
    net.elaborate(W.parse(text, 'test.wir'));
    if (clock) net.now = clock;
    net.settleAll();
    return net;
}

const ADI = `
wiring adi is
  type attitude is (INRTL, LVLH, REF);
  port (
    att     : in  attitude bind panel "F6/S3";
    pwr     : in  logic    bind mdm   "FF1/6/0.0";
    w_inrtl : out logic    bind mdm   "FF1/4/1.0";
    w_lvlh  : out logic    bind mdm   "FF1/4/1.1"
  );
  signal live : logic;
begin
  live    <= pwr;
  w_inrtl <= live and att = INRTL;
  w_lvlh  <= '1' when live = '1' and att = LVLH else '0';
end wiring;
`;

(async () => {
    const W = await bundle('ratsnest/wiring.coffee');
    const N = await bundle('ratsnest/netlist.coffee');
    const P = await bundle('panel/panelBus.coffee');
    const R = await bundle('ratsnest/ratsnest.coffee');
    const C = await bundle('lru/mdm/mdmConf.coffee');
    const M = await bundle('lru/mdm/mdm.coffee');
    const B = await bundle('com/bus.civet');
    const D = await bundle('com/discretes.coffee');

    section('lexing');
    const toks = W.lex("a <= b and not '1'; -- a comment\n c <= 16#ff# + 300 ms;", 't');
    eq(toks.slice(0, 5).map((t) => t.v), ['a', '<=', 'b', 'and', 'not'], 'words and symbols');
    eq(toks.filter((t) => t.t === 'logic').map((t) => t.v), [1], "'1' is a logic literal");
    eq(toks.filter((t) => t.t === 'int').map((t) => t.v), [255], '16#ff# is 255');
    eq(toks.filter((t) => t.t === 'time').map((t) => t.v), [300], '300 ms is 300 in milliseconds');
    eq(W.lex('x <= 1.5 s;', 't').filter((t) => t.t === 'time').map((t) => t.v), [1500],
       '1.5 s is 1500 ms');
    ok(W.lex('-- nothing but a comment', 't').length === 1, 'a comment carries no tokens');

    section('parsing');
    const [unit] = W.parse(ADI, 'adi.wir');
    eq(unit.name, 'adi', 'the unit is named');
    eq(Object.keys(unit.types), ['attitude'], 'the enumerated type is declared');
    eq(unit.types.attitude.literals, ['INRTL', 'LVLH', 'REF'], 'with its literals, as written');
    eq(unit.ports.map((p) => [p.name, p.dir, p.type, p.bind.scheme, p.bind.addr]),
       [['att', 'in', 'attitude', 'panel', 'F6/S3'],
        ['pwr', 'in', 'logic', 'mdm', 'FF1/6/0.0'],
        ['w_inrtl', 'out', 'logic', 'mdm', 'FF1/4/1.0'],
        ['w_lvlh', 'out', 'logic', 'mdm', 'FF1/4/1.1']], 'the ports and their bindings');
    eq(unit.signals.map((s) => s.name), ['live'], 'the internal signal');
    eq(unit.stmts.map((s) => s.target), ['live', 'w_inrtl', 'w_lvlh'], 'three drivers');
    eq(W.parse('WIRING X IS PORT ( A : IN LOGIC BIND PANEL "P/1" ); BEGIN END WIRING;', 't')[0].name,
       'x', 'keywords and names fold case');
    eq(W.parse(ADI + ADI.replace('wiring adi is', 'wiring adi2 is'), 't').length, 2,
       'a file may hold several units');

    section('what the language refuses');
    const bad = (text, why) => ok((refusal(W, N, text) || '').includes(why),
        `${why}: ${(refusal(W, N, text) || 'taken').slice(0, 70)}`);
    bad('wiring w is port (a : in logic bind panel "p/1"; b : out logic bind panel "p/2");' +
        ' begin b <= a and a or a; end wiring;', 'takes parentheses');
    bad('wiring w is port (b : out logic bind panel "p/2"); begin b <= nope; end wiring;',
        'not a signal, port or constant');
    bad('wiring w is port (a : in logic bind panel "p/1"); begin a <= \'1\'; end wiring;',
        'is an input');
    bad('wiring w is port (b : out logic bind panel "p/2");' +
        ' begin b <= \'1\'; b <= \'0\'; end wiring;', 'already driven');
    bad('wiring w is signal n : integer; port (b : out logic bind panel "p/2");' +
        ' begin n <= 3; b <= n; end wiring;', 'the expression is');
    bad('wiring w is port (b : out logic bind panel "p/2"); begin b <= nope(\'1\'); end wiring;',
        "no function 'nope'");
    bad('wiring w is type t is (A, B); port (c : in logic bind panel "p/1";' +
        ' y : out t bind panel "p/2"); begin y <= A when c else \'0\'; end wiring;',
        'the arms are');
    bad('wiring w is type t is (A, B); port (a : in logic bind panel "p/1");' +
        ' begin end wiring;', 'a signal cannot carry the same name');
    bad('wiring w is port (b : out logic bind panel "p/2"); begin b <= latch(set => \'1\');' +
        ' end wiring;', 'latch takes set and reset');
    bad('wiring w is port (b : out logic bind panel "p/2");' +
        ' begin b <= pulse(\'1\', 4); end wiring;', 'is a time');
    bad('wiring w is type t is (A, B); port (e : in t bind panel "p/1";' +
        ' q : out logic bind panel "p/2"); begin q <= e < B; end wiring;', 'has no order');
    eq(refusal(W, N, 'wiring w is port (a : in logic bind panel "p/1"; b : out logic' +
                     ' bind panel "p/2"); begin b <= (a and a) or a; end wiring;'), null,
       'parentheses settle the mixing');

    section('evaluation');
    let net = build(W, N, ADI);
    const at = (n) => net.net('adi', n).value;
    eq([at('live'), at('w_inrtl'), at('w_lvlh')], [0, 0, 0], 'nothing driven, nothing on');
    eq(at('att'), 'INRTL', 'an enumerated net rests at its first literal');
    net.put(net.net('adi', 'pwr'), 1);
    net.settle();
    eq([at('live'), at('w_inrtl'), at('w_lvlh')], [1, 1, 0], 'power reaches through the signal');
    net.put(net.net('adi', 'att'), 'LVLH');
    net.settle();
    eq([at('w_inrtl'), at('w_lvlh')], [0, 1], 'the rotary breaks one wire and makes another');
    eq(net.settle().length, 0, 'a settled network settles to nothing');
    net.put(net.net('adi', 'pwr'), 0);
    eq(net.settle().map((n) => n.name).sort(), ['live', 'w_lvlh'], 'and reports what moved');

    section('an input nothing has answered for');
    net = build(W, N, ADI);
    const driver = (n) => net.net('adi', n).driver;
    eq(driver('w_inrtl').sources.map((s) => s.name).sort(), ['att', 'pwr'],
       'a driver stands on the bound inputs behind it, through the signals');
    eq(driver('live').ready(), false, 'and is not ready while one is unheard');
    net.put(net.net('adi', 'pwr'), 1);
    eq(driver('live').ready(), true, 'the one it reads answers');
    eq(driver('w_inrtl').ready(), false, 'the other has not');
    net.put(net.net('adi', 'att'), 'INRTL');
    eq(driver('w_inrtl').ready(), true, 'and now both have');
    eq(net.net('adi', 'pwr').heard, true, 'a net put to what it already held is still heard');

    section('operators');
    const OPS = `
wiring ops is
  type t is (A, B, C);
  port (
    x : in logic bind panel "p/x";
    y : in logic bind panel "p/y";
    e : in t     bind panel "p/e";
    n : in word  bind panel "p/n";
    o_and : out logic bind panel "p/1";
    o_xor : out logic bind panel "p/2";
    o_not : out logic bind panel "p/3";
    o_cat : out word  bind panel "p/4";
    o_sel : out word  bind panel "p/5";
    o_add : out word  bind panel "p/6";
    o_cmp : out logic bind panel "p/7"
  );
begin
  o_and <= x and y;
  o_xor <= x xor y;
  o_not <= not x;
  o_cat <= x & y & '1';
  o_sel <= 16#10# when e = A else 16#20# when e = B else 16#30#;
  o_add <= n + 3;
  o_cmp <= n >= 100;
end wiring;
`;
    net = build(W, N, OPS);
    const put = (n, v) => { net.put(net.net('ops', n), v); net.settle(); };
    const val = (n) => net.net('ops', n).value;
    put('x', 1); put('y', 1);
    eq([val('o_and'), val('o_xor'), val('o_not')], [1, 0, 0], 'and, xor and not');
    put('y', 0);
    eq([val('o_and'), val('o_xor'), val('o_cat')], [0, 1, 0b101], "& builds a word, most significant first");
    eq(val('o_sel'), 0x10, 'the first arm of a conditional');
    put('e', 'B');
    eq(val('o_sel'), 0x20, 'the second');
    put('e', 'C');
    eq(val('o_sel'), 0x30, 'and the else');
    put('n', 40);
    eq([val('o_add'), val('o_cmp')], [43, 0], 'arithmetic and comparison');
    put('n', 100);
    eq(val('o_cmp'), 1, 'and the comparison again');

    section('the functions that hold state');
    let clock = 1000;
    const STATE = `
wiring st is
  port (
    s : in logic bind panel "p/s";
    r : in logic bind panel "p/r";
    t : in logic bind panel "p/t";
    q  : out logic bind panel "p/q";
    p  : out logic bind panel "p/p";
    f  : out logic bind panel "p/f";
    d  : out logic bind panel "p/d"
  );
begin
  q <= latch(set => s, reset => r);
  p <= pulse(t, 300 ms);
  f <= falling(t, 100 ms);
  d <= delay(t, 50 ms);
end wiring;
`;
    net = build(W, N, STATE, () => clock);
    const wakes = [];
    net.wakeAt = (w) => wakes.push(w);
    const step = (to) => { clock = to; for (const d of net.timed()) net.dirty.add(d); net.settle(); };
    const st = (n) => net.net('st', n).value;
    eq(st('q'), 0, 'a latch starts clear');
    put2('s', 1);
    eq(st('q'), 1, 'a set makes it');
    put2('s', 0);
    eq(st('q'), 1, 'and it holds with the set gone');
    put2('r', 1);
    eq(st('q'), 0, 'a reset breaks it');
    put2('r', 0); put2('s', 1); put2('r', 1);
    eq(st('q'), 0, 'reset wins over set');
    put2('r', 0); put2('s', 0);

    put2('t', 1);
    eq([st('p'), st('d')], [1, 0], 'a rising edge makes the pulse; the delay has not run');
    step(1120);
    eq([st('p'), st('d')], [1, 1], 'the delay lands 50 ms later, the pulse still made');
    step(1400);
    eq(st('p'), 0, 'and the pulse falls 300 ms after the edge');
    put2('t', 0);
    eq(st('f'), 1, 'a falling edge makes the other one-shot');
    step(1550);
    eq(st('f'), 0, 'which falls 100 ms later');
    ok(wakes.length > 0, 'a pulse asks for the clock');

    function put2(n, v) { net.put(net.net('st', n), v); net.settle(); }

    section('the panel bus message');
    const round = (kind, value) => P.decodePanel(P.encodePanel(
        { op: P.VALUE, kind, key: 'F6/S3', value }));
    eq(round(P.ENUM, 'LVLH').value, 'LVLH', 'an enumerated position round trips');
    eq(round(P.LOGIC, 1).value, true, 'a level');
    eq(round(P.WORD, 0x1234).value, 0x1234, 'a word');
    eq(round(P.REAL, 3.25).value, 3.25, 'a number');
    eq([round(P.ENUM, 'X').panel, round(P.ENUM, 'X').control], ['F6', 'S3'], 'the key splits');
    eq(P.splitKey('F6/'), { panel: 'F6', control: null }, 'a panel with no control');
    eq(P.splitKey(''), { panel: null, control: null }, 'and an empty key names every panel');
    eq(P.decodePanel(P.encodePanel({ op: P.REQUEST, key: '' })).opName, 'REQUEST', 'a request');
    eq(Array.from(P.encodePanel({ op: P.VALUE, kind: P.ENUM, key: 'F6/S3', value: 'LVLH' }).data16),
       [4, 2, 5, 4, 0, 0x4636, 0x2f53, 0x3300, 0x4c56, 0x4c48],
       'the halfwords of a VALUE, text two characters a halfword');
    eq(P.fmtPanel(P.decodePanel(P.encodePanel({ op: P.SET, kind: P.LOGIC, key: 'O6/S40', value: 1 }))),
       "SET O6/S40 '1'", 'and it formats');

    // Both ends of the bus build the same bytes.
    section('the python end of the panel bus');
    let python = null;
    try {
        python = execFileSync('python3', ['-c',
            'import sys; sys.path.insert(0, "src"); from simMgr.panel import bus; ' +
            'print(bus.encode(bus.VALUE, bus.ENUM, "F6/S3", "LVLH").hex()); ' +
            'print(bus.encode(bus.VALUE, bus.REAL, "F7/M1", 3.25).hex())'],
            { cwd: SIM, encoding: 'utf8' }).trim().split('\n');
    } catch (e) {
        console.log('      (python3 did not run; simMgr/panel/bus.py is not checked here)');
    }
    if (python) {
        const wire = (m) => m.getBytes().toString('hex');
        eq(python[0].slice(4), wire(P.encodePanel(
            { op: P.VALUE, kind: P.ENUM, key: 'F6/S3', value: 'LVLH' })),
           'python and coffee encode the same enumerated message');
        eq(python[1].slice(4), wire(P.encodePanel(
            { op: P.VALUE, kind: P.REAL, key: 'F7/M1', value: 3.25 })),
           'and the same number');
    }

    section('binding');
    const bind = (addr, type = 'logic', dir = 'out') => {
        const drive = { logic: "'1'", real: '0.0', word: '0' }[type];
        const text = `wiring b is port (x : ${dir} ${type} bind mdm "${addr}");` +
                     ` begin ${dir === 'out' ? `x <= ${drive};` : ''} end wiring;`;
        const rn = new R.Ratsnest();
        rn.netlist.elaborate(W.parse(text, 'b.wir'));
        try { rn.open(); rn.close(); return null; } catch (e) { rn.close(); return e.message; }
    };
    eq(bind('FF1/4/1.0'), null, 'a discrete bit of a discrete input card');
    ok((bind('FF1/4/1') || '').includes('name the bit'), 'a logic net on a discrete card wants one');
    ok((bind('ZZ9/4/1.0') || '').includes('there is no MDM ZZ9'), 'the unit is checked');
    ok((bind('FF1/99/1.0') || '').includes('cards are 0 to 15'), 'the card is checked');
    ok((bind('FF1/4/1.99') || '').includes('bits are 0 to 15'), 'the bit is checked');
    ok((bind('FF1/1/0.3') || '').includes('has no bits'), 'an analog card has no bits');
    eq(bind('FF1/1/0', 'real'), null, 'an analog channel is volts');

    const bindOne = (scheme, addr) => {
        const text = `wiring b is port (x : out logic bind ${scheme} "${addr}");` +
                     ` begin x <= '1'; end wiring;`;
        const rn = new R.Ratsnest();
        rn.netlist.elaborate(W.parse(text, 'b.wir'));
        try { rn.open(); rn.close(); return null; } catch (e) { rn.close(); return e.message; }
    };
    eq(bindOne('discrete', 'gpc4/A/mm1ready'), null, "a GPC's discrete by name");
    eq(bindOne('discrete', 'idp1/A/load'), null, "an IDP's");
    ok((bindOne('discrete', 'gpc9/A/halt') || '').includes('GPC ID'), 'the GPC number is checked');
    ok((bindOne('discrete', 'gpc4/Z/halt') || '').includes('registers are'), 'the register is checked');
    ok((bindOne('discrete', 'gpc4/A/nosuch') || '').includes('unknown discrete'), 'and the bit');
    eq(bindOne('adc', '1/12'), null, 'an ADC analog input');
    ok((bindOne('adc', '3/12') || '').includes('<pair>/<channel>'), 'the pair is checked');
    ok((bindOne('adc', '1/99') || '').includes('channels are 0 to 31'), 'and the channel');
    ok((bindOne('panel', 'F6') || '').includes('<panel>/<control>'), 'a control needs both parts');

    section('asking again for what has not answered');
    const asker = new R.Ratsnest();
    asker.netlist.elaborate(W.parse(ADI, 'adi.wir'));
    asker.open();
    await asker.ready();
    eq(asker.waiting().map((n) => n.name).sort(), ['att', 'pwr'],
       'the bound inputs nothing has answered for');
    ok(asker.asking !== null, 'and the busses are asked again while any is unheard');
    for (const net of asker.waiting()) asker.netlist.put(net, net.value);
    asker.reask();
    eq(asker.waiting(), [], 'once every one has answered');
    eq(asker.asking, null, 'the asking stops');
    asker.close();

    section('a panel through the wiring to an MDM');
    const mdm = new M.MDM({ id: 'FF1' });
    const rats = new R.Ratsnest();
    rats.load([path.join(SIM, 'config', 'wiring', 'adi.wir')]);
    rats.open();
    await rats.ready();
    await settle(200);
    rats.start();
    await settle(150);

    const panel = new P.PanelChannel();
    await panel.ready();

    const hw = new B.Bus('_FF1_mdmIO', B.busConfig._FF1_mdmIO);
    const seen = [];
    hw.onReceive((self, id, msg) => { const m = C.decodeIO(msg.data16); if (m) seen.push(m); }, null);
    await hw.ready;

    // The channel the wiring drives, read back from the unit.
    const channel = async () => {
        seen.length = 0;
        const words = C.encodeIO({ op: C.IO_OP.REQUEST, type: C.IOM.DIH.code, card: 4, channel: 1 });
        const msg = new B.BusMsg(words.length);
        msg.data16.set(words);
        hw.sendMsg(msg);
        await settle(150);
        const v = seen.filter((m) => m.op === C.IO_OP.VALUE && m.card === 4 && m.channel === 1);
        return v.length ? v[v.length - 1].words[0] : null;
    };

    // The DDU supplies the switch wafers hang on: FF1 card 6 channel 0.
    const power = C.encodeIO({ op: C.IO_OP.SET, type: C.IOM.DIL.code, card: 6, channel: 0,
                               words: [0xe000] });
    const pmsg = new B.BusMsg(power.length);
    pmsg.data16.set(power);
    hw.sendMsg(pmsg);
    await settle(200);

    panel.report('F6/S3', P.ENUM, 'REF');
    panel.report('F6/S4', P.ENUM, 'LOW');
    panel.report('F6/S5', P.ENUM, 'MED');
    await settle(250);
    eq(await channel(), 0x2880,
       'REF, ERROR LOW and RATE MED make FF1 card 4 channel 1 bits 2, 8 and 4');

    panel.report('F6/S3', P.ENUM, 'INRTL');
    await settle(250);
    eq(await channel(), 0x8880, 'INRTL moves the attitude wire to bit 0');

    // With the DDU supplies gone every wire the switches make goes dead.
    const off = C.encodeIO({ op: C.IO_OP.RESET, type: C.IOM.DIL.code, card: 6, channel: 0,
                             words: [0xe000] });
    const omsg = new B.BusMsg(off.length);
    omsg.data16.set(off);
    hw.sendMsg(omsg);
    await settle(250);
    eq(await channel(), 0x0000, 'and no supply leaves the channel clear');

    rats.close();
    panel.close();
    hw.close();
    await settle(100);

    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
