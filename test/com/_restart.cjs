// Launched twice by dstore.cjs: never shares a module cache or heap with the writer.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const [bundle, directory, mode, kind] = process.argv.slice(2);
const models = require(bundle);
const rt = models.runtime;
const sleep = ms => new Promise(resolve => setTimeout(resolve,ms));
(async () => {
  let unit, harness, sender;
  const transport = kind.startsWith('TRANSPORT_');
  if (kind.startsWith('GPC')) {
    harness = new models.RunHarness({machine:kind==='GPC_B'?'ap101b':'ap101s',gpc:kind==='GPC_SHM'?1:0,mode:'RUN'});
    unit = harness.gpc;
  } else if (transport) {
    unit = new models.LRU({id:'transport',busses:['IC1']});
    sender = new models.Bus('IC1',models.busConfig.IC1);
    await sender.ready;
    if (kind === 'TRANSPORT_SHM') assert(sender.ring, 'native SHM must be available');
    unit.packets = [];
    unit.bus.IC1.onReceive((self,id,msg) => self.packets.push([...msg.data16]),unit);
    sender.onReceive(() => {});
  } else unit = new models[kind]({power:[],powerFeeds:[],quiet:true,discretes:false});
  await unit.ready();
  await sleep(40);
  unit.checkpointReply = function(words) { this.receivedCheckpointWords = words; };
  if (mode === 'save') {
    unit.checkpointSentinel = 123;
    if (harness) {
      for (const [address,value] of [[0x800,0x01E2],[0x801,0xC7F0],[0x802,0x800]])
        harness.cpu.mainStorage.set16(address,value,false,false);
      harness.cpu.psw.setNIA(0x800);
      harness.setRealTime(true);harness.run();await sleep(35);
    }
    if (kind === 'MMU') {
      unit.volume.write(12,[1234,5678]);unit._hold(250,'checkpoint test');
      unit._send([123,456],180);
    }
    if (kind === 'MDM') {
      const card = unit.cards.find(c => c && c.type.kind === 'serial');
      assert(card,'fixture needs serial card');card.link[0]=true;
      unit.serialAnswerMs=180;
      unit._pollSerial(card,0,3,rt.call(unit,'checkpointReply'));
      unit.pending={expected:3,got:[42],done:rt.call(unit,'checkpointReply')};
    }
    if (kind === 'PCMMU') {
      const u = Object.values(unit.units)[0];
      u.pending={bus:unit.config.busses[0],count:3,got:[42],done:rt.call(unit,'checkpointReply')};
    }
    if (transport) {
      const packet = new models.BusMsg(1);packet.data16[0]=333;sender.sendMsg(packet);
    }
    rt.freeze();
    if (transport) {
      const packet = new models.BusMsg(1);packet.data16[0]=444;sender.sendMsg(packet);
      await sleep(40);
      assert.deepEqual(unit.packets,[]);
    }
    if (harness) {
      unit.cpu.mainStorage.set16(0x100,0xCAFE,false,false);
      unit.cpu.mainStorage.protData[0x100]=true;
      unit.cpu.mainStorage.lastRead[0x100]=0x12345678;
      unit.cpu.mainStorage.lastWritten[0x100]=0xABCDEF01;
      unit.cpu.mainStorage.protLastWritten[0x100]=0xFEDCBA98;
      if (kind==='GPC_B') unit.iop.mainStorage.set16(1,0xBEEF,false,false);
    }
    unit.saveDstore(directory);
    models.saveRuntime(directory,'cross-process');
    fs.writeFileSync(directory+'/expected.json',JSON.stringify({time:rt.now(), microTime:rt.nowMicros().toString(), cpuTime:harness?.cpu.timeNs,steps:harness?.stepCount,barrierOffset:unit.iop?.barrierOffsetUs}));
  } else {
    rt.freeze();
    const expected=JSON.parse(fs.readFileSync(directory+'/expected.json','utf8'));
    // Both validation passes must work before either model is modified.
    const apply=models.prepareRuntime(directory);
    unit.validateDstore(directory);
    assert.equal(unit.checkpointSentinel,undefined);
    unit.beforeRestoreDstore?.();unit.restoreDstore(directory);apply();unit.afterRestoreDstore?.();
    assert.equal(unit.checkpointSentinel,123);
    assert.equal(rt.now(),expected.time);
    assert.equal(rt.nowMicros().toString(),expected.microTime);
    if (harness) {
      assert.equal(unit.cpu.mainStorage.get16(0x100,false),0xCAFE);
      assert.equal(unit.cpu.mainStorage.protData[0x100],true);
      assert.equal(unit.cpu.mainStorage.lastRead[0x100],0x12345678);
      assert.equal(unit.cpu.mainStorage.lastWritten[0x100],0xABCDEF01);
      assert.equal(unit.cpu.mainStorage.protLastWritten[0x100],0xFEDCBA98);
      const image=fs.readFileSync(directory+'/memory.fcm');
      assert.equal(image.length,unit.ram.totalHWCount*2);
      assert.equal(image.readUInt16BE(0x200),0xCAFE);
      if (kind==='GPC_B') {
        assert.equal(image.readUInt16BE(unit.cpu.mainStorage.rawData.byteLength+2),0xBEEF);
        assert.equal(unit.ram.get16(unit.ram.cpuHWCount+1,false),0xBEEF);
      }
      assert.equal(harness.cpu.timeNs,expected.cpuTime);
      assert.equal(harness.stepCount,expected.steps);assert(harness.running);
      if (kind === 'GPC_SHM') {
        assert(unit.iop.barrier?.word >= 0, 'fresh GPC rejoins native barrier');
        assert.equal(unit.iop.barrier.offsetUs,expected.barrierOffset);
      }
    }
    if (kind === 'MMU') {assert.equal(unit.volume.read(12)[1],5678);assert(unit.busy);}
    if (kind === 'MDM') {
      unit._onDataWord(43,unit.busPri);unit._onDataWord(44,unit.busPri);
      assert.deepEqual(unit.receivedCheckpointWords,[42,43,44]);
      unit.receivedCheckpointWords=null;
    }
    if (kind === 'PCMMU') {
      const u=Object.values(unit.units)[0]; const bus=u.pending.bus;
      unit._onDataWord(u,bus,43);unit._onDataWord(u,bus,44);
      assert.deepEqual(unit.receivedCheckpointWords,[42,43,44]);
    }
    rt.run();await sleep(300);rt.freeze();
    if (transport) assert.deepEqual(unit.packets,[[333],[444]],'queued receive and send replay once on fresh transports');
    if (harness) {assert(harness.stepCount>expected.steps);assert(harness.cpu.timeNs>expected.cpuTime);}
    if (kind === 'MMU') assert.equal(unit.busy,false,'saved busy timer expires in new process');
    if (kind === 'MDM') assert(Array.isArray(unit.receivedCheckpointWords),'saved serial timeout invokes fresh continuation');
  }
  console.log(`${kind} ${mode} passed`);
  process.exit(0);
})().catch(error=>{console.error(error.stack);process.exit(1)});
