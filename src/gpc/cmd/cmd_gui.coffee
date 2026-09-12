# gpc gui cmd
# run gui debugger
#
fs = require 'fs'
path = require 'path'
{spawn} = require 'child_process'

import {addGUIOptions, guiCliOpts, startGUISession} from 'gpc/gui/guibackend'
import {resolveEndpoint, describeEndpoint} from 'gpc/dbg/dbgclient'
import {checkFCMFits} from 'gpc/machine'

export addCommand = (program) ->
  cmd = program.command('gui')
    .description('Electron GUI debugger')
    .argument('[fcm-file]', 'FCM image')

  addGUIOptions(cmd)

  cmd
    .option('--no-sandbox', 'disable the Electron sandbox')
    .action (fcmPath, o) ->
      checkFCMFits(fcmPath, o.machine) if fcmPath? and not o.attach

      mainJs = path.join(__dirname, 'main', 'main.js')
      electron = process.env.NSTS_ELECTRON
      unless electron
        candidates = [
          path.resolve(__dirname, '..', '..', 'node_modules', '.bin', 'electron')
          path.resolve(__dirname, '..', 'node_modules', '.bin', 'electron')
        ]
        electron = (c for c in candidates when fs.existsSync(c))[0] ? candidates[0]

      opts = guiCliOpts(fcmPath, o)

      startWindow = (endpoint) ->
        opts.endpoint = endpoint
        encoded = Buffer.from(JSON.stringify(opts)).toString('base64')
        args = [mainJs, "--cli-opts=#{encoded}"]
        args.push('--no-sandbox') if o.sandbox is false
        child = spawn(electron, args, { stdio: 'inherit' })
        child.on 'exit', (code, signal) ->
          if signal
            process.kill(process.pid, signal)
          else
            process.exit(code ? 0)
        child

      # Attaching: the window is the only thing this process starts, and
      # the session outlives it.
      if o.attach
        ep = resolveEndpoint(o)
        process.stderr.write("gpc gui: attaching to #{describeEndpoint(ep)}\n")
        return startWindow(ep)

      startGUISession(fcmPath, o).then((backend) ->
        gui = startWindow(backend.endpoint)
        gui.on 'exit', -> backend.server.shutdown()
        for sig in ['SIGINT', 'SIGTERM']
          process.on sig, ->
            backend.server.shutdown()
            process.exit(0)
      , (e) ->
        process.stderr.write("FATAL: cannot start a session: #{e.message}\n")
        process.exit(1))
