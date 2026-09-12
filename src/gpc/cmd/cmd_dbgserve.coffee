# gpc dbg-serve cmd
#

import {addSessionOptions, addEndpointOptions, openSession, serveSession} from 'gpc/dbg/session'

say = (m) -> process.stderr.write("gpc-dbg: #{m}\n")

die = (m) ->
  process.stderr.write("FATAL: #{m}\n")
  process.exit(1)

export addCommand = (program) ->
  cmd = program.command('dbg-serve')
    .aliases(['serve', 'dbgd'])
    .description('Headless AP-101 debugger on a socket')
    .argument('[fcm-file]', 'FCM memory image to load')

  addSessionOptions(cmd)
  addEndpointOptions(cmd)

  cmd
    .option('--autostart', 'start processor immediately')
    .option('--quiet', 'do not report stops on stderr')
    .action (fcmPath, o) ->
      die('--no-tcp needs --socket') unless o.tcp or o.socket

      autostart = (session) ->
        drive = ->
          session.continueRun(session.maxSteps).then (body) ->
            if body?.reason == 'step budget'
              setImmediate(drive)
            else
              say("autostart stopped: #{body?.reason}") unless o.quiet
        say('autostart') unless o.quiet
        drive()

      report = (session) ->
        session.on (msg) ->
          switch msg.event
            when 'stopped'
              b = msg.body
              where = b.location.hex + (if b.location.label then " <#{b.location.label}>" else '')
              why = b.reason + (if b.description then ": #{b.description}" else '')
              say("#{why} at #{where} (#{b.steps} steps)")
            when 'input'
              say("waiting for #{msg.body.type} input")

      serveOpts = Object.assign({}, o, { onShutdown: -> process.exit(0) })

      openSession(fcmPath, o, say)
        .then ({session}) ->
          report(session) unless o.quiet
          serveSession(session, serveOpts, say).then ({server}) ->
            say(session.fcmPath ? 'no image loaded')
            autostart(session) if o.autostart
            for sig in ['SIGINT', 'SIGTERM']
              process.on sig, ->
                process.stderr.write("\ngpc-dbg: shutting down\n")
                server.shutdown()
                process.exit(0)
        .catch (e) -> die(e.message)
