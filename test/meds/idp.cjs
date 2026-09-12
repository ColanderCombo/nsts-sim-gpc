// idp.cjs — the IDP as a process of its own (meds/idp/idp.coffee):
// what it puts on its MDU bus, what reaches its DEU unit from the DK and
// keyboard busses, and the load the IDP LOAD switch starts.
//
// Usage:  node test/meds/idp.cjs
//
// Exit status is 1 iff any assertion fails.

'use strict';

const path    = require('path');
const os      = require('os');
const fs      = require('fs');
const esbuild = require('esbuild');
const coffeePlugin = require('esbuild-coffeescript');

const SRC = path.resolve(__dirname, '..', '..');

// A bus domain for this test (com/bus.civet: every port is an offset from
// NSTS_BASE_PORT): a base drawn from the process id, 20000 to 59900 by 100,
// or NSTS_TEST_BASE_PORT, so a session on the default base is not heard.
process.env.NSTS_BASE_PORT =
    process.env.NSTS_TEST_BASE_PORT ?? String(20000 + (process.pid % 400) * 100);

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
        `medsidp.${path.basename(entry, '.coffee')}.${process.pid}.cjs`);
    await esbuild.build({
        absWorkingDir: SRC,
        entryPoints: [path.join(SRC, 'src', entry)],
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
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
    const { IDP, UNITS, HEARTBEAT_MS } = await bundle('meds/idp/idp.coffee');
    const { Bus, BusMsg, busConfig } = await bundle('com/bus.civet');
    const { MDUMsg } = await bundle('meds/medsConf');
    const DEU = await bundle('meds/deu/deuProto');
    const { KYBD } = await bundle('meds/kybd');
    const { IDPPanel } = await bundle('meds/idp/idpDiscretes');

    const words = (msg) => Array.from(msg.data16);
    const send = (bus, list) => {
        const m = new BusMsg(list.length);
        list.forEach((w, i) => m.data16[i] = w & 0xffff);
        bus.sendMsg(m);
    };
    const sendCommand = (bus, cmd24) => bus.sendMsg(BusMsg.Command(cmd24));
    const open = (name) => new Bus(name, busConfig[name]);

    check('four units', UNITS.join(' '), 'IDP1 IDP2 IDP3 IDP4');
    let threw = null;
    try { new IDP({ unit: 'IDP9' }); } catch (e) { threw = e.message; }
    check('an unknown unit is refused', threw, "invalid IDP 'IDP9'");

    const heard = [];
    const mduBus = open('_IDP1');
    mduBus.onReceive((_, id, msg) => heard.push(words(msg)), null);
    const dk1 = open('DK1');
    const dkHeard = [];
    dk1.onReceive((_, id, msg) => dkHeard.push(words(msg)), null);
    const kybd1 = open('_KYBD1');
    const panel = new IDPPanel({ ids: [1] });

    const logged = [];
    const idp = new IDP({ unit: 'idp1', ipled: true, log: (t) => logged.push(t) });
    check('the unit is named', idp.id, 'IDP1');
    check('...and numbered', idp.idpNo, 1);
    check('the DK bus is DK1', idp.dkBus.busID, 'DK1');
    check('the MDU bus is _IDP1', idp.mduCmdBus.busID, '_IDP1');
    check('the four FC receivers', Object.keys(idp.fcRx).join(' '), 'FC1 FC2 FC3 FC4');
    check('a describe line names every bus and the discrete channel with its port',
          idp.busPorts().split(' ').length, idp.idpConfig.busses.length + 1);
    await Promise.all([idp.ready(), mduBus.ready, dk1.ready, kybd1.ready, panel.ready()]);

    idp.start();
    await sleep(HEARTBEAT_MS * 3);
    const tags = (t) => heard.filter((w) => w[0] === t);
    check('heartbeats reach the MDU bus', tags(MDUMsg.HEARTBEAT).length >= 2, true);
    check('...carrying the IDP number', tags(MDUMsg.HEARTBEAT)[0][1], 1);
    check('ADC frames reach the MDU bus', tags(MDUMsg.ADC).length >= 1, true);
    check('...for both units of the IDP',
          new Set(tags(MDUMsg.ADC).map((w) => w[1])).size, 2);
    check('...invalid with no converter answering', tags(MDUMsg.ADC)[0][2], 0);

    heard.length = 0;
    const fill = [0x1234, 0x5678, 0x9abc];
    const msgs = DEU.fillMessages(DEU.FUNC.DISPLAY_FILL,
                                  DEU.ADDR.DISPLAY_HEADER, fill);
    for (const m of msgs) {
        sendCommand(dk1, DEU.encodeCommand(m.func, m.count));
        for (const w of m.body) send(dk1, [w]);
    }
    await sleep(150);
    const fills = tags(MDUMsg.FILL);
    check('the fill reaches the MDU bus', fills.length >= 1, true);
    check('...at the display header', fills[0]?.[1], DEU.ADDR.DISPLAY_HEADER);
    check('...with its words', fills[0]?.slice(2, 5).join(','), fill.join(','));
    check('...and display memory holds it',
          idp.unit.mem[DEU.ADDR.DISPLAY_HEADER + 2], 0x9abc);

    const key = KYBD.DEUKey.keys.ITEM;
    send(kybd1, [key.deuCode]);
    await sleep(50);
    check('a keystroke on the left keyboard enters IDP 1', idp.stats.keys, 1);
    panel.setSel(3, 2);
    await sleep(50);
    check('LEFT to 3 drops IDP 1 KYBD SEL B', idp.discretes.input('kybdselb'), false);
    check('...with a line in the log', logged.some((t) => /KYBD SEL B off/.test(t)), true);
    send(kybd1, [key.deuCode]);
    await sleep(50);
    check('...and a keystroke is then dropped', idp.stats.keysDropped, 1);
    check('...saying so', logged.some((t) => /not selected/.test(t)), true);
    panel.query();
    await sleep(50);
    check('the IDP answers the panel', panel.heard[1], true);
    check('...with its lines', panel.lines(1).B, false);

    heard.length = 0;
    panel.pressLoad(1, 40);
    await sleep(100);
    check('LOAD asks for a load', idp.unit.ipled, false);
    check('...in the poll header', (idp.unit.takeHeader() & DEU.HDR.IPL_REQUIRED) !== 0, true);
    check('...told to the MDUs', tags(MDUMsg.LOAD).some((w) => w[1] === 1), true);
    check('...and on the status word', panel.loading(1), true);
    heard.length = 0;
    const last = DEU.fillMessages(DEU.FUNC.DISPLAY_FILL, 0x0100,
                                  new Array(DEU.LAST_FILL_WORDS).fill(0x1111));
    check('a load\'s last fill is one transfer', last.length, 1);
    for (const m of last) {
        sendCommand(dk1, DEU.encodeCommand(m.func, m.count));
        for (const w of m.body) send(dk1, [w]);
    }
    await sleep(200);
    check('the last fill completes the load', idp.unit.ipled, true);
    check('...told to the MDUs', tags(MDUMsg.LOAD).some((w) => w[1] === 0), true);
    check('...and on the status word', panel.loading(1), false);

    heard.length = 0;
    idp.loadFCWs([0x0001, 0x0002], 0x1000);
    await sleep(50);
    check('loadFCWs sends a fill', tags(MDUMsg.FILL).length, 1);
    check('...at the address given', tags(MDUMsg.FILL)[0][1], 0x1000);
    check('...and wrote memory', idp.unit.mem[0x1001], 2);

    idp.halt();
    check('stop ends the timers', idp.running, false);
    idp.close();
    panel.close();
    [mduBus, dk1, kybd1].forEach((b) => b.close());

    console.log(`${pass} passed, ${fail} failed`);
    process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
