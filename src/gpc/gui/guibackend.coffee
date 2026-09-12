# The GUI's execution backend
#
# The debugger window draws a mirror of a `DebugSession` reached over the
# socket protocol (gpc/gui.coffee).  Two entry points start that session:
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
import {IOHost} from 'gpc/iohost'
import {DebugSession} from 'gpc/dbgsession'
import {DebugServer, sessionFileFor} from 'gpc/dbgserver'

# The options both entry points offer.  Registered from here so the two
# cannot drift apart: the packaged app and the CLI take the same command
# line.
export addGUIOptions = (cmd) ->
  AGEHarness.addOptions(cmd)
  IOHost.addOptions(cmd, 3)
  cmd
    .option('--real-time', 'start with real-time pacing on (toggleable from the toolbar)')
    .option('--rt-factor <x>', 'real-time speed multiplier (2 = 2x real speed)')
    .option('--rt-idle-timeout <s>', 'stop after this many wall seconds in wait state with no wakeup')
    .option('--max-steps <n>', 'step budget for one Run (default: 10000000)', '10000000')
    .option('--attach', 'do not start a session; join one already running')
    .option('--port <n>', 'TCP port: of the session to attach to, or to listen on (default: an ephemeral one)')
    .option('--host <addr>', 'host of the session (default: 127.0.0.1)', '127.0.0.1')
    .option('--socket <path>', 'unix socket of the session to attach to')
    .option('--name <name>', 'session name, used for the session file')
    .option('--no-session-file', 'do not record the endpoint anywhere')

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
  session = new DebugSession(Object.assign({}, o, {
    fcmPath: if fcmPath then path.resolve(fcmPath) else null
    symbols: if o.symbols then path.resolve(o.symbols) else null
    maxSteps: parseInt(o.maxSteps ? '10000000', 10)
  }))

  if fcmPath?
    info = session.load(session.fcmPath, session.opts)
    for w in [info.entryWarning, info.protectWarning] when w?
      log("gpc gui: warning: #{w}\n")

  # Named apart from a headless session's, so opening a window does not
  # stand on `gpc dbg-serve`'s session file -- and `gpc dbg-client` with no
  # arguments still finds whichever started last.
  base = if fcmPath then path.basename(fcmPath).replace(/\.fcm$/i, '') else 'gpc'
  name = o.name ? "#{base}-gui"
  sessionFile = if o.sessionFile == false then null else sessionFileFor(name)

  server = new DebugServer(session, {
    host: o.host ? '127.0.0.1'
    # Port 0 asks the OS for a free one: a window must not fail to open
    # because a headless session already holds the default port.
    port: if o.port? then parseInt(o.port, 10) else 0
    sessionFile: sessionFile
  })

  server.listen().then (endpoints) ->
    tcp = (e for e in endpoints when e.kind == 'tcp')[0]
    log("gpc gui: session on #{tcp.host}:#{tcp.port}" +
        "#{if sessionFile then " (#{sessionFile})" else ''}\n")
    { session, server, sessionFile, endpoint: { host: tcp.host, port: tcp.port } }
