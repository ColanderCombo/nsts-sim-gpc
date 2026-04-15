
# gpc gui cmd
# run gui debugger
#
# This file lives in the CLI bundle (plain Node).  The actual renderer-side
# GUI implementation (DebugGUI extends GUIHarness, React/Lit components) is
# in gpc/gui.coffee, which is loaded only by the Electron renderer process.

path = require 'path'
{spawn} = require 'child_process'

import {AGEHarness} from 'gpc/ageharness'

export addCommand = (program) ->
  cmd = program.command('gui')
    .description('Electron GUI debugger')
    .argument('[fcm-file]', 'FCM memory image to load (optional; GUI can also load later)')

  AGEHarness.addOptions(cmd)

  cmd
    .option('--no-sandbox', 'pass --no-sandbox to Electron (required on some Linux systems)')
    .action (fcmPath, o) ->
      # Resolve Electron binary and main.js relative to this bundle's location.
      # gpc.js lives at ext/sim/dist/gpc.js, so __dirname = ext/sim/dist/.
      simDir = path.resolve(__dirname, '..')
      electron = path.join(simDir, 'node_modules', '.bin', 'electron')
      mainJs = path.join(simDir, 'dist', 'main', 'main.js')

      # Serialize the parsed CLI options for the Electron main process to
      # forward to the renderer via IPC. Paths are resolved to absolute 
      # here so the child doesn't need the parent's CWD.  Yes, this sucks.
      cliOpts = Object.assign(AGEHarness.optsFrom(o), {
        fcmPath: if fcmPath then path.resolve(fcmPath) else null
        symbols: if o.symbols then path.resolve(o.symbols) else null
      })
      encoded = Buffer.from(JSON.stringify(cliOpts)).toString('base64')

      args = [mainJs, "--cli-opts=#{encoded}"]
      args.push('--no-sandbox') if o.sandbox is false

      child = spawn(electron, args, { stdio: 'inherit' })
      child.on 'exit', (code, signal) ->
        if signal
          process.kill(process.pid, signal)
        else
          process.exit(code ? 0)
