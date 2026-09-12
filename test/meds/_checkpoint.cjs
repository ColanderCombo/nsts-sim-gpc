// Real Electron restart test. Build target `electron`, then run this file.
// Kept separate from headless CTest: this opens and closes two MDU windows.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const {spawn} = require('node:child_process');
const root = path.resolve(__dirname, '../..');
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'mdu-checkpoint-'));
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
(async () => {
  try {
    const config = path.join(directory, 'config.json');
    fs.writeFileSync(config, JSON.stringify({lrus: {crt1: {supersample: 1, window: {width: 500, height: 500}}}}));
    for (const mode of ['save', 'restore']) {
      const result = path.join(directory, mode + '.result');
      const script = `(async () => {
        const errors = [];
        window.addEventListener('error', event => errors.push(event.message));
        try {
          const unit = window.lru, control = unit.simControl;
          const command = async operation => {
            const command = operation + Date.now();
            control.command({command, operation, directory: ${JSON.stringify(directory)}});
            for (let i = 0; i < 600; i++) {
              await new Promise(resolve => setTimeout(resolve, 50));
              const status = control.commands.get(command);
              if (status?.status === 'failed') throw Error(status.error);
              if (status?.status === 'completed') return;
            }
            throw Error('command timed out: ' + operation);
          };
          if (${JSON.stringify(mode)} === 'save') {
            for (const name of Object.keys(unit.screenMods)) unit.setCurrentDisplay(name);
            unit.setCurrentDisplay('AE_PFD');
            unit.screens.AE_PFD.enterTapeTest();
            unit.checkpointSentinel = 456;
            await command('freeze');
            await command('dstore');
          } else {
            // Evolve the new display before restore, changing geometry sizes.
            for (const name of Object.keys(unit.screenMods)) unit.setCurrentDisplay(name);
            unit.setCurrentDisplay('AE_PFD');
            unit.screens.AE_PFD.setData(unit.screens.AE_PFD.sampleData());
            await command('freeze');
            await command('validate');
            if (unit.checkpointSentinel !== undefined) throw Error('validation changed the model');
            await command('restore');
            if (unit.checkpointSentinel !== 456 || unit.curDisplay !== 'AE_PFD') throw Error('state differs');
            const before = unit.screens.AE_PFD.curData.hdot;
            await command('run');
            await new Promise(resolve => setTimeout(resolve, 300));
            if (unit.screens.AE_PFD.curData.hdot === before) throw Error('saved display timer did not run');
            for (const name of Object.keys(unit.screens)) unit.setCurrentDisplay(name);
            await new Promise(resolve => setTimeout(resolve, 100));
          }
          if (errors.length) throw Error(errors.join('; '));
          window.fs.writeFileSync(${JSON.stringify(result)}, 'passed');
        } catch (error) { window.fs.writeFileSync(${JSON.stringify(result)}, error.stack); }
      })()`;
      const log = fs.openSync(path.join(directory, mode + '.log'), 'w');
      const child = spawn(path.join(root, 'node_modules/.bin/electron'),
        [path.join(process.env.NSTS_DIST || path.join(root, 'build/dist'), 'main/main.js'), 'meds', 'crt1'], {
          cwd: root, stdio: ['ignore', log, log],
          env: {...process.env, NSTS_BUS_SHM: 'off', NSTS_BASE_PORT: String(56000 + (process.pid % 40) * 100),
            NSTS_EXEC: script, NSTS_SIM_CONFIG: config},
        });
      const exited = new Promise((resolve, reject) => { child.once('exit', resolve); child.once('error', reject); });
      try {
        for (let i = 0; i < 600 && !fs.existsSync(result) && child.exitCode === null; i++) await sleep(100);
        assert(fs.existsSync(result), `no ${mode} result; logs: ${directory}`);
        assert.equal(fs.readFileSync(result, 'utf8'), 'passed');
        console.log(`MDU ${mode}: all screens and pending display timer passed`);
      } finally {
        if (child.exitCode === null) child.kill('SIGTERM');
        const kill = setTimeout(() => child.kill('SIGKILL'), 3000);
        await exited;
        clearTimeout(kill);
        fs.closeSync(log);
      }
    }
  } finally { fs.rmSync(directory, {recursive: true, force: true}); }
})().catch(error => { console.error(error); process.exitCode = 1; });
