// Replay captured DK fills through the real beam interpreter and report what
// each frame drew.  A corrupted frame stands out in the per-frame stats.
const path=require('path'), os=require('os'), fs=require('fs');
const esbuild=require('esbuild'), coffeePlugin=require('esbuild-coffeescript');
const SIM=path.resolve(__dirname, '..', '..');
const civetPlugin={name:'civet',setup(build){
  const {compile}=require(path.join(SIM,'node_modules/@danielx/civet'));
  build.onResolve({filter:/\.civet\.jsx$/},(a)=>({path:path.resolve(path.dirname(a.importer),a.path.replace(/\.jsx$/,''))}));
  build.onLoad({filter:/\.civet$/},async(a)=>({contents:compile(fs.readFileSync(a.path,'utf8'),{filename:a.path,js:true}),loader:'js'}));
}};
(async()=>{
  const shim=path.join(os.tmpdir(),`rp.${process.pid}.js`);
  fs.writeFileSync(shim,
    "export * as three from 'three'\n"+
    `export * as dps from ${JSON.stringify(path.join(SIM,'src/meds/mdu/mduScreen_DPS.coffee'))}\n`+
    `export * as fcw from ${JSON.stringify(path.join(SIM,'src/meds/deu/deuFCW.coffee'))}\n`+
    `export * as deu from ${JSON.stringify(path.join(SIM,'src/meds/deu/deuProto.coffee'))}\n`);
  const out=path.join(os.tmpdir(),`rp.out.${process.pid}.cjs`);
  global.window={fs};
  await esbuild.build({absWorkingDir:SIM,entryPoints:[shim],bundle:true,platform:'node',
    format:'cjs',target:'node20',outfile:out,plugins:[civetPlugin,coffeePlugin({})],
    loader:{'.asm':'text','.css':'text','.svg':'text','.png':'dataurl'},resolveExtensions:['.coffee','.js','.ts','.civet','.json'],
    nodePaths:[path.join(SIM,'node_modules')],external:['dgram','electron'],logLevel:'error'});
  const m=require(out), THREE=m.three, DEU=m.deu;

  const mem=new Uint16Array(DEU.DEU_MEMORY_WORDS);
  const gen=new Uint32Array(DEU.DEU_MEMORY_WORDS);
  const screen=Object.create(m.dps.Screen_DPS.prototype);
  screen.fcw=new m.fcw.FCW();
  screen.group=new THREE.Object3D(); screen.fmt=new THREE.Object3D();
  screen.group.add(screen.fmt); screen._blinkOn=true; screen.bgFCWS=mem; screen.fillGen=gen; screen.fillSeq=0;
  screen.geo_dps_fcws=new THREE.Object3D(); screen.geo_dps_vdisp=new THREE.Object3D();
  screen.vdispBG={};
  for(const f of fs.readdirSync(path.join(SIM,'data'))){
    const mm=/^VDISP-(\d+)-.*\.dfb$/i.exec(f); if(!mm) continue;
    const b=fs.readFileSync(path.join(SIM,'data',f));
    const a=[]; for(let i=0;i+1<b.length;i+=2) a.push((b[i]<<8)|b[i+1]);
    screen.vdispBG[Number(mm[1])]=a;
  }
  var quiet=console.log; console.log=(...a)=>{ if(!/no resident background/.test(String(a[0]))) quiet(...a); };
  let drawn=[],lines=[];
  screen.d={c2h:{green:0x48f500},deuFont:null,dirty:false,
    str(x,y,ch,color){drawn.push({x,y,ch,color});return new THREE.Object3D();},
    filledPoly(){return new THREE.Object3D();},
    line(c,color,i){lines.push(c);return new THREE.Object3D();},
    dashedLine(c,color){lines.push(c);return new THREE.Object3D();}};

  const recs=fs.readFileSync(process.argv[2],'utf8').trim().split('\n').map(JSON.parse);
  const seg=(c)=>Math.hypot(c[c.length-1][0]-c[0][0], c[c.length-1][1]-c[0][1]);
  let prev=null; const maxExt={};
  for(const r of recs){
    if(r.kind!=='fill') continue;
    const w=r.words.slice(2);
    screen.fillSeq++;
    for(let i=0;i<w.length;i++){const j=(r.addr+i)&(mem.length-1); mem[j]=w[i]&0xffff; gen[j]=screen.fillSeq;}
    drawn=[];lines=[];
    screen.d.str=(x,y,ch,color)=>{drawn.push({x,y,ch,color});return new THREE.Object3D();};
    screen.d.line=(c)=>{lines.push(c);return new THREE.Object3D();};
    screen.d.dashedLine=(c)=>{lines.push(c);return new THREE.Object3D();};
    try{ screen.refresh(); }catch(e){ console.log(`t=${(r.t/1000).toFixed(3)} THREW ${e.message}`); continue; }
    // Does this frame depend on words left behind by a longer earlier fill
    // at the same address?  Zero that tail and see if the picture changes.
    const ext=(maxExt[r.addr]||0), end=r.addr+w.length;
    if(ext>end){
      const save=mem.slice(end,ext); mem.fill(0,end,ext);
      const keepD=drawn, keepL=lines; drawn=[];lines=[];
      screen.d.str=(x,y,ch,color)=>{drawn.push({x,y,ch,color});return new THREE.Object3D();};
      screen.d.line=(c)=>{lines.push(c);return new THREE.Object3D();};
      screen.d.dashedLine=(c)=>{lines.push(c);return new THREE.Object3D();};
      try{ screen.refresh(); }catch(e){}
      if(drawn.length!==keepD.length || lines.length!==keepL.length)
        console.log(`t=${(r.t/1000).toFixed(3).padStart(8)}  STALE TAIL 0x${end.toString(16)}..0x${ext.toString(16)} `+
                    `changes the frame: ${keepD.length}g ${keepL.length}v -> ${drawn.length}g ${lines.length}v`);
      mem.set(save,end); drawn=keepD; lines=keepL;
    }
    maxExt[r.addr]=Math.max(ext,end);
    if(process.env.REPORT_AT && Math.abs(r.t/1000-Number(process.env.REPORT_AT))<0.05){
      quiet(`--- walkReport at t=${(r.t/1000).toFixed(3)} ---`); screen.walkReport();
    }
    const rows=drawn.map(d=>Math.round(d.y));
    const off=drawn.filter(d=>d.y<0||d.y>28||d.x<0||d.x>54).length;
    const longest=lines.length?Math.max(...lines.map(seg)):0;
    const sig=`${drawn.length}g ${lines.length}v`;
    const flag=(off>0?' OFFSCREEN='+off:'')+(longest>30?` LONGVEC=${longest.toFixed(1)}`:'');
    if(flag || sig!==prev){
      console.log(`t=${(r.t/1000).toFixed(3).padStart(8)}  fill 0x${r.addr.toString(16)} ${String(r.count).padStart(3)}hw  `+
                  `${sig.padEnd(12)} rows ${Math.min(...rows,99)}..${Math.max(...rows,-9)}${flag}`);
    }
    prev=sig;
  }
})();
