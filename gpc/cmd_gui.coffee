# gpc gui cmd
# run gui debugger
#
path = require 'path'
{spawn} = require 'child_process'

import {addGUIOptions, guiCliOpts, startGUISession} from 'gpc/guibackend'
import {resolveEndpoint, describeEndpoint} from 'gpc/dbgclient'
import {checkFCMFits} from 'gpc/machine'

export addCommand = (program) ->
  cmd = program.command('gui')
    .description('Electron GUI debugger')
    .argument('[fcm-file]', 'FCM memory image to load (optional; GUI can also load later)')

  addGUIOptions(cmd)

  cmd
    .option('--no-sandbox', 'pass --no-sandbox to Electron (required on some Linux systems)')
    .action (fcmPath, o) ->
      checkFCMFits(fcmPath, o.machine) if fcmPath? and not o.attach

      # Resolve Electron binary and main.js relative to this bundle's
      # location.  gpc.js lives at ext/sim/dist/gpc.js, so __dirname is
      # ext/sim/dist/.
      simDir = path.resolve(__dirname, '..')
      electron = path.join(simDir, 'node_modules', '.bin', 'electron')
      mainJs = path.join(simDir, 'dist', 'main', 'main.js')

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
