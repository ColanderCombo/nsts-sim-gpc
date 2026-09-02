# gpc dbg-serve cmd
# headless debugger driven over a socket
#
# Wraps the same AGEHarness the GUI and the REPL debugger wrap, with no
# terminal attached.  The process stays up until a client sends `shutdown`
# or it is signalled.

fs = require 'fs'
path = require 'path'

import {AGEHarness} from 'gpc/ageharness'
import {IOHost} from 'gpc/iohost'
import {DebugSession} from 'gpc/dbgsession'
import {DebugServer, DEFAULT_PORT, sessionFileFor, sessionDir} from 'gpc/dbgserver'
import {checkFCMFits} from 'gpc/machine'

collect = (v, prev) -> prev.concat([v])

export addCommand = (program) ->
  cmd = program.command('dbg-serve')
    .aliases(['serve', 'dbgd'])
    .description('Headless AP-101 debugger on a socket')
    .argument('[fcm-file]', 'FCM memory image to load')

  AGEHarness.addOptions(cmd)
  IOHost.addOptions(cmd, 3)

  cmd
    .option('--port <n>', "TCP port to listen on (default: #{DEFAULT_PORT})", String(DEFAULT_PORT))
    .option('--host <addr>', 'address to bind (default: 127.0.0.1)', '127.0.0.1')
    .option('--no-tcp', 'do not listen on TCP; requires --socket')
    .option('--socket <path>', 'also listen on a unix socket at this path')
    .option('--name <name>', 'session name, used for the session file (default: the FCM basename)')
    .option('--session-file <path>', 'where to record the endpoint (default: <tmpdir>/gpc-dbg/<name>.json)')
    .option('--no-session-file', 'do not record the endpoint anywhere')
    .option('--max-steps <n>', 'step budget for one continue (default: 10000000)', '10000000')
    .option('--break <addr>', 'set a breakpoint before starting (repeatable)', collect, [])
    .option('--trace', 'start with the instruction trace ring on')
    .option('--trace-limit <n>', 'instructions the trace ring holds (default: 1024)', '1024')
    .option('--break-on-interrupt', 'stop when an interrupt is accepted', false)
    .option('--hold-interrupt', 'stop just before an interrupt swaps PSWs', false)
    .option('--real-time', 'pace execution at AP-101 speed')
    .option('--rt-factor <x>', 'real-time speed multiplier (2 = 2x real speed)')
    .option('--rt-idle-timeout <s>', 'stop after this long in the wait state with no wakeup')
    .option('--quiet', 'do not report stops on stderr')
    .action (fcmPath, o) ->
      unless o.tcp or o.socket
        process.stderr.write("FATAL: --no-tcp needs --socket\n")
        process.exit(1)
      checkFCMFits(fcmPath, o.machine) if fcmPath?

      session = new DebugSession(Object.assign({}, o, {
        fcmPath: if fcmPath then path.resolve(fcmPath) else null
        symbols: if o.symbols then path.resolve(o.symbols) else null
        maxSteps: parseInt(o.maxSteps, 10)
      }))

      if fcmPath? or o.ipl
        info = session.load(session.fcmPath, session.opts)
        for w in [info.entryWarning, info.protectWarning] when w?
          process.stderr.write("gpc-dbg: warning: #{w}\n")

      # The IPL runs before the server listens: it is what puts a
      # program in storage.  The read is over a bus, so the unit
      # answering has to be up already.
      if o.ipl
        note = (m) -> process.stderr.write("gpc-dbg: ipl: #{m}\n")
        try
          await session.iplFromMassMemory(session.opts, session.pacer, note)
        catch e
          process.stderr.write("FATAL: IPL failed: #{e.message}\n")
          process.exit(1)

      session.setBreakOnInterrupt(true) if o.breakOnInterrupt
      session.setHoldInterrupt(true) if o.holdInterrupt
      session.setTrace(true, parseInt(o.traceLimit, 10)) if o.trace

      for spec in (o.break ? [])
        addr = session.resolveAddr(spec)
        if addr?
          session.setBreakpoint(addr)
        else
          process.stderr.write("gpc-dbg: cannot resolve breakpoint '#{spec}'\n")

      name = o.name ? (if fcmPath then path.basename(fcmPath).replace(/\.fcm$/i, '') else 'default')
      sessionFile =
        if o.sessionFile == false then null
        else if typeof o.sessionFile == 'string' then path.resolve(o.sessionFile)
        else sessionFileFor(name)

      server = new DebugServer(session, {
        host: o.host
        port: parseInt(o.port, 10)
        tcp: o.tcp
        socketPath: if o.socket then path.resolve(o.socket) else null
        sessionFile: sessionFile
        onShutdown: -> process.exit(0)
      })

      unless o.quiet
        session.on (msg) ->
          switch msg.event
            when 'stopped'
              b = msg.body
              where = b.location.hex + (if b.location.label then " <#{b.location.label}>" else '')
              why = b.reason + (if b.description then ": #{b.description}" else '')
              process.stderr.write("gpc-dbg: #{why} at #{where} (#{b.steps} steps)\n")
            when 'input'
              process.stderr.write("gpc-dbg: waiting for #{msg.body.type} input\n")

      server.listen().then (endpoints) ->
        for e in endpoints
          if e.kind == 'tcp'
            process.stderr.write("gpc-dbg: listening on #{e.host}:#{e.port}\n")
          else
            process.stderr.write("gpc-dbg: listening on #{e.path}\n")
        process.stderr.write("gpc-dbg: session file #{sessionFile}\n") if sessionFile?
        process.stderr.write("gpc-dbg: #{session.fcmPath ? 'no image loaded'}\n")
      , (e) ->
        process.stderr.write("FATAL: cannot listen: #{e.message}\n")
        process.exit(1)

      for sig in ['SIGINT', 'SIGTERM']
        process.on sig, ->
          process.stderr.write("\ngpc-dbg: shutting down\n")
          server.shutdown()
          process.exit(0)
