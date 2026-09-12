'use strict';
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const esbuild = require('esbuild');
const coffeePlugin = require('esbuild-coffeescript');
const SIM = path.resolve(__dirname, '../..');
// Keep the parent fixture off the live simulation's default control bus.
process.env.NSTS_BASE_PORT = String(40000 + (process.pid % 150) * 100);
process.env.NSTS_BUS_SHM = 'off';
const civetPlugin = {name: 'civet', setup(build) {
  const {compile} = require('@danielx/civet');
  build.onResolve({filter: /\.civet\.jsx$/}, a => ({path:path.resolve(path.dirname(a.importer),a.path.replace(/\.jsx$/, ''))}));
  build.onLoad({filter:/\.civet$/}, a => ({contents:compile(fs.readFileSync(a.path,'utf8'),{filename:a.path,js:true}),loader:'js'}));
}};
(async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'sim-dstore-'));
  try {
    const out = path.join(dir, 'fixture.cjs');
    await esbuild.build({absWorkingDir: SIM, stdin: {contents: `
      export * as runtime from './src/com/simRuntime.coffee';
      export {StateStore, saveRuntime, prepareRuntime} from './src/com/stateStore.coffee';
      export {Bus, BusMsg, busConfig} from './src/com/bus.civet';
      export {LRU} from './src/com/lru.civet';
      export {RunHarness} from './src/gpc/runharness.coffee';
      export {AP101} from './src/gpc/ap101.coffee';
      export {MMU} from './src/lru/mmu/mmu.coffee';
      export {ADC} from './src/lru/adc/adc.coffee';
      export {ADTA} from './src/lru/adta/adta.coffee';
      export {MTU} from './src/lru/mtu/mtu.coffee';
      export {MDM} from './src/lru/mdm/mdm.coffee';
      export {NSP} from './src/lru/nsp/nsp.coffee';
      export {PCMMU} from './src/lru/pcmmu/pcmmu.coffee';
      export {IDP} from './src/meds/idp/idp.coffee';
      export {IMU} from './src/lru/imu/imu.coffee';
    `, resolveDir:SIM,loader:'js'}, bundle:true,platform:'node',format:'cjs',outfile:out,
      plugins:[civetPlugin,coffeePlugin()],resolveExtensions:['.coffee','.js','.civet','.ts','.json'],logLevel:'error'});
    const models = require(out);
    const {runtime:rt, StateStore, LRU, AP101, MMU, IMU} = models;
    const sleep = ms => new Promise(resolve => setTimeout(resolve,ms));
    let ticks=0;
    const counter = {tick() { ticks++; }, delayed() { delayed++; }};
    const repeating = rt.setInterval(rt.call(counter, "tick"),10);
    let delayed=0;
    rt.setTimeout(rt.call(counter, "delayed"),80);
    await sleep(25);
    rt.freeze();
    const anonymous = rt.setTimeout(() => {}, 1000);
    assert.throws(() => rt.checkpoint(), /anonymous timer/);
    rt.clearTimeout(anonymous);
    const count=ticks, time=rt.now();
    const checkpoint=rt.checkpoint('first');
    await sleep(110);
    assert.equal(ticks,count); assert.equal(delayed,0); assert.equal(rt.now(),time);
    rt.run(); await sleep(90); rt.freeze();
    assert(ticks>count); assert.equal(delayed,1);
    rt.restoreCheckpoint(checkpoint); rt.run(); await sleep(90); rt.freeze();
    assert.equal(delayed,2,'pending timeout replays on restore');
    rt.clearInterval(repeating);
    const unit = new LRU({id:'test',busses:[]});
    unit.config.scale=3;
    unit.value={answer:42,unset:undefined,large:123n,nan:NaN};
    unit.storage=new Uint16Array([1,2,65535]);
    unit.alias=unit.storage;
    unit.self=unit;
    unit.blocks=new Map([[4,new Uint16Array([22])]]);
    unit.savedFn=()=>42;
    await unit.ready();
    unit.saveDstore(dir+'/simple');
    unit.value.answer=0; unit.storage.fill(0); unit.blocks.clear(); unit.config.scale=9;
    unit.restoreDstore(dir+'/simple');
    assert.equal(unit.value.answer,42); assert.equal(unit.value.large,123n); assert(Number.isNaN(unit.value.nan));
    assert.deepEqual([...unit.storage],[1,2,65535]); assert.equal(unit.alias,unit.storage);
    assert.equal(unit.blocks.get(4)[0],22); assert.equal(unit.self,unit); assert.equal(unit.config.scale,3);
    assert.equal(unit.savedFn(),42);
    unit.value={answer:99};
    unit.restoreDstore(dir+'/simple'); assert.equal(unit.value.answer,42,'restore original object held by callbacks');
    // Rebuilt display storage may have a new size, offset, or alias layout.
    const storageModel = {id:'dynamic', data:new Uint16Array([10,20,30])};
    storageModel.alias = storageModel.data;
    storageModel.view = new DataView(storageModel.data.buffer,2,2);
    storageModel.other = new Uint16Array([40,50,60]);
    const storageStore = new StateStore(storageModel);
    storageStore.save(dir+'/dynamic');
    storageModel.data = new Uint16Array(100);
    storageModel.alias = storageModel.data;
    storageModel.view = new DataView(storageModel.data.buffer,0,4);
    storageModel.other = storageModel.data;
    const live = storageModel.data;
    storageStore.validate(dir+'/dynamic');
    assert.equal(storageModel.data,live,'validation does not replace live storage');
    storageStore.restore(dir+'/dynamic');
    assert.deepEqual([...storageModel.data],[10,20,30]);
    assert.equal(storageModel.alias,storageModel.data);
    assert.equal(storageModel.view.buffer,storageModel.data.buffer);
    assert.equal(storageModel.view.byteOffset,2);
    assert.equal(storageModel.view.byteLength,2);
    assert.deepEqual([...storageModel.other],[40,50,60]);
    assert.notEqual(storageModel.other.buffer,storageModel.data.buffer);
    const small={id:'small',scale:3,count:9};
    const fields=new StateStore(small); fields.mark('config',['scale']); fields.mark('state',['count']);
    fields.save(dir+'/fields'); small.count=0;small.scale=0;fields.restore(dir+'/fields');
    assert.equal(small.count,9);assert.equal(small.scale,3);
    const invalid=JSON.parse(fs.readFileSync(dir+'/fields/state.json'));
    invalid.lru='other'; fs.writeFileSync(dir+'/fields/state.json',JSON.stringify(invalid));
    assert.throws(()=>fields.restore(dir+'/fields'),/incompatible/);
    const gpc = new AP101({gpc:0});
    gpc.cpu.mainStorage.set16(0x100,0x1234,false,false);
    gpc.cpu.timeNs=123456;
    gpc.saveDstore(dir+'/gpc');
    gpc.cpu.mainStorage.set16(0x100,0,false,false);gpc.cpu.timeNs=0;
    gpc.restoreDstore(dir+'/gpc');
    assert.equal(gpc.cpu.mainStorage.get16(0x100,false),0x1234);assert.equal(gpc.cpu.timeNs,123456);
    assert.equal(gpc.cpu.ram.cpuMCM,gpc.cpu.mainStorage); // backing store aliases survive
    const fcm = fs.readFileSync(dir+'/gpc/memory.fcm');
    assert.equal(fcm.length, gpc.ram.totalHWCount*2);
    assert.equal(fcm.readUInt16BE(0x100*2),0x1234);
    const stateGraph=JSON.parse(fs.readFileSync(dir+'/gpc/state.json'));
    assert.equal(stateGraph.version,3);
    assert(!stateGraph.nodes.some(n => n.bytes?.length > 65536),'large GPC storage leaves JSON');
    fs.writeFileSync(dir+'/gpc/memory.fcm',fcm.subarray(0,fcm.length-1));
    const beforeValidation=gpc.cpu.timeNs;
    assert.throws(()=>gpc.validateDstore(dir+'/gpc'),/checkpoint file size changed/);
    assert.equal(gpc.cpu.timeNs,beforeValidation);
    fs.writeFileSync(dir+'/gpc/memory.fcm',fcm);
    const trackingFile = dir+'/gpc/cpu-lastRead.bin.gz';
    const compressed = fs.readFileSync(trackingFile);
    const tracking = require('node:zlib').gunzipSync(compressed);
    assert.deepEqual(tracking, Buffer.from(gpc.cpu.mainStorage.lastRead.buffer));
    assert(compressed.length < tracking.length / 100, 'sparse tracking data compresses well');
    fs.writeFileSync(trackingFile, compressed.subarray(0, compressed.length - 1));
    assert.throws(()=>gpc.validateDstore(dir+'/gpc'), /cannot decompress checkpoint file cpu-lastRead.bin.gz/);
    assert.equal(gpc.cpu.timeNs,beforeValidation);
    fs.writeFileSync(trackingFile, compressed);
    // Version 3 stores written before compression still restore raw sidecars.
    fs.cpSync(dir+'/gpc', dir+'/raw', {recursive:true});
    const rawGraph = JSON.parse(JSON.stringify(stateGraph));
    for (const node of rawGraph.nodes) {
      const ref = node.block;
      if (ref?.compression !== 'gzip') continue;
      const raw = require('node:zlib').gunzipSync(fs.readFileSync(dir+'/raw/'+ref.file));
      fs.unlinkSync(dir+'/raw/'+ref.file);
      ref.file = ref.file.replace(/\.gz$/, '');
      delete ref.compression;
      fs.writeFileSync(dir+'/raw/'+ref.file, raw);
    }
    fs.writeFileSync(dir+'/raw/state.json', JSON.stringify(rawGraph));
    gpc.cpu.mainStorage.lastRead.fill(99);
    gpc.restoreDstore(dir+'/raw');
    assert.deepEqual(Buffer.from(gpc.cpu.mainStorage.lastRead.buffer), tracking);
    // Existing JSON-only checkpoints remain loadable without binary files.
    fs.mkdirSync(dir+'/legacy');
    fs.writeFileSync(dir+'/legacy/state.json',JSON.stringify(gpc.dstore.encode()));
    gpc.cpu.mainStorage.set16(0x100,0,false,false);
    gpc.restoreDstore(dir+'/legacy');
    assert.equal(gpc.cpu.mainStorage.get16(0x100,false),0x1234);

    rt.run();
    const harness = new models.RunHarness({machine:'ap101s'});
    harness.cpu.mainStorage.set16(0x800,0x01E2,false,false);
    harness.cpu.mainStorage.set16(0x801,0xC7F0,false,false);
    harness.cpu.mainStorage.set16(0x802,0x800,false,false);
    harness.cpu.psw.setNIA(0x800);
    harness.setRealTime(true);
    harness.run(); await sleep(30); rt.freeze();
    const cpuTime = harness.cpu.timeNs, steps = harness.stepCount;
    const execution = rt.checkpoint('execution');
    harness.gpc.saveDstore(dir+'/execution');
    await sleep(40);
    assert.equal(harness.cpu.timeNs,cpuTime); assert.equal(harness.stepCount,steps);
    rt.run(); await sleep(30); rt.freeze();
    assert(harness.cpu.timeNs>cpuTime);
    harness.stop();
    rt.restoreCheckpoint(execution); harness.gpc.restoreDstore(dir+'/execution');
    assert.equal(harness.cpu.timeNs,cpuTime); assert.equal(harness.stepCount,steps);
    assert.equal(harness.running,true);
    rt.run(); await sleep(30); harness.stop(); rt.freeze();
    assert(harness.cpu.timeNs>cpuTime,'restored execution continues');
    await harness.gpc.stop();
    const mmu = new MMU({unit:1,power:[],discretes:false});
    mmu.volume.write(4,[123,456]);mmu.position.track=2;
    mmu.saveDstore(dir+'/mmu');mmu.volume.blocks.clear();mmu.position.track=0;
    mmu.restoreDstore(dir+'/mmu'); assert.equal(mmu.volume.read(4)[1],456);assert.equal(mmu.position.track,2);
    const imu=new IMU({units:[1],outputs:[],power:[]});
    imu.setFault(1,1,true);imu.saveDstore(dir+'/imu');imu.setFault(1,1,false);
    imu.restoreDstore(dir+'/imu');assert.equal(imu.units[1].fault,1);
    for (const name of ['ADC','ADTA','MTU','MDM','NSP','PCMMU','IDP']) {
      const model = new models[name]({power:[],powerFeeds:[],quiet:true});
      await model.ready();
      const directory = dir+'/'+name;
      model.saveDstore(directory);
      model.validateDstore(directory);
      model.restoreDstore(directory);
      await model.stop();
    }
    await Promise.all([unit.stop(),gpc.stop(),mmu.stop(),imu.stop()]);
    rt.run();
    const {execFileSync} = require('node:child_process');
    for (const kind of ['GPC','GPC_B','GPC_SHM','MMU','MDM','ADC','ADTA','MTU','NSP','PCMMU','IDP','IMU','TRANSPORT_UDP','TRANSPORT_SHM']) {
      const directory=dir+'/restart-'+kind;
      for (const mode of ['save','restore']) {
        if (kind.endsWith('_SHM') && mode === 'restore') {
          // Destroy the writer's entire native segment before the new process.
          require(path.join(process.env.NSTS_NATIVE || path.join(SIM,'build/native'), 'shmring.node'))
            .unlink(`/nsts2.${56000+(process.pid%40)*100}`);
        }
        execFileSync(process.execPath,
        ['--max-old-space-size=2048',path.join(__dirname,'_restart.cjs'),out,directory,mode,kind],
        {stdio:'inherit',timeout:30000,env:{...process.env,NSTS_BUS_SHM:kind.endsWith('_SHM')?'ic':'off',NSTS_SIM_BARRIER:kind==='GPC_SHM'?'50':'off',NSTS_BASE_PORT:String(56000+(process.pid%40)*100)}});
      }
    }
    console.log('dstore: freeze, timers, typed state, aliases, MMU media, GPC and declarative fields passed');
  } finally {fs.rmSync(dir,{recursive:true,force:true});}
})().catch(e=>{console.error(e);process.exit(1)});
