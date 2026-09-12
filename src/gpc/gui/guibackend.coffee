# The GUI's execution backend
#
# The debugger window draws a mirror of a `DebugSession` reached over the
#
#   * `gpc gui image.fcm`, where the CLI process spawns Electron;
#   * `electron dist/main/main.js gui image.fcm`, the packaged app and
#     `npm run gui:dev`, where there is no CLI process.
#
# Both host it in the process that opens the window, which is never the
# renderer, so the machine runs at full speed in a process that is not also
# laying out and painting a window.
#
# The session gets a session file, so `gpc dbg-client` can drive the
# window's machine from a terminal while the panes watch.

path = require 'path'

import {AGEHarness} from 'gpc/ageharness'
import {addSessionOptions, openSession, serveSession} from 'gpc/dbg/session'

# The options both entry points offer.  Registered from here so the two
# cannot drift apart: the packaged app and the CLI take the same command
# line.
export addGUIOptions = (cmd) ->
  addSessionOptions(cmd)
  cmd
    .option('--attach', 'do not start a session; join one already running')
    .option('--port <n>', 'session or listen port')
    .option('--host <addr>', 'host of the session (default: 127.0.0.1)', '127.0.0.1')
    .option('--socket <path>', 'session unix socket')
    .option('--name <name>', 'session name')
    .option('--no-session-file', 'do not record the endpoint')

# The options blob the renderer is handed.  Absolute paths, because the
# window does not inherit this process's working directory.
export guiCliOpts = (fcmPath, o) ->
  Object.assign(AGEHarness.optsFrom(o), {
    fcmPath: if fcmPath then path.resolve(fcmPath) else null
    symbols: if o.symbols then path.resolve(o.symbols) else null
    realTime: o.realTime
    rtFactor: o.rtFactor
    rtIdleTimeout: o.rtIdleTimeout
  })

# Start the session and put it on a socket.  Resolves with the endpoint the
# window should connect to and the server, whose `shutdown()` ends it.
export startGUISession = (fcmPath, o, log = (m) -> process.stderr.write(m)) ->
  say = (m) -> log("gpc gui: #{m}\n")
  openSession(fcmPath, o, say).then ({session}) ->
    serveSession(session, Object.assign({}, o, {
      defaultPort: 0
      nameSuffix: '-gui'
    }), (->)).then ({server, sessionFile, endpoint}) ->
      say("session on #{endpoint.host}:#{endpoint.port}" +
          "#{if sessionFile then " (#{sessionFile})" else ''}")
      { session, server, sessionFile, endpoint }
