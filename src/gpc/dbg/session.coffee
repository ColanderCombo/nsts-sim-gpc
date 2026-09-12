# Shared construction and serving for every GPC run mode.

fs = require 'fs'
path = require 'path'

import {AGEHarness} from 'gpc/ageharness'
import {IOHost} from 'gpc/iohost'
import {addBusOptions} from 'com/busCli'
import {DebugSession} from 'gpc/dbg/dbgsession'
import {DebugServer, DEFAULT_PORT, sessionFileFor} from 'gpc/dbg/dbgserver'
import {checkFCMFits} from 'gpc/machine'

collect = (v, prev) -> prev.concat([v])

DEFAULT_MAX_STEPS = 10000000

export addSessionOptions = (cmd, opts = {}) ->
  AGEHarness.addOptions(cmd)
  IOHost.addOptions(cmd)      # every channel: a batch run writes --outfile6
  addBusOptions(cmd)
  cmd
    .option('--max-steps <n>', 'continue step budget',
            String(opts.maxSteps ? DEFAULT_MAX_STEPS))
    .option('--break <addr>', 'set a breakpoint before starting (repeatable)', collect, [])
    .option('--trace', 'start with the instruction trace ring on')
    .option('--trace-limit <n>', 'trace capacity', '1024')
    .option('--break-on-interrupt', 'stop on accepted interrupt', false)
    .option('--hold-interrupt', 'stop before interrupt PSW swap', false)
    .option('--real-time', 'pace execution at AP-101 speed')
    .option('--rt-factor <x>', 'real-time speed factor')
    .option('--rt-idle-timeout <s>', 'wait-state timeout')

export addEndpointOptions = (cmd, opts = {}) ->
  cmd
    .option('--port <n>', opts.portHelp ? "TCP port to listen on (default: #{DEFAULT_PORT})",
            if opts.defaultPort is false then undefined else String(DEFAULT_PORT))
    .option('--host <addr>', 'address to bind (default: 127.0.0.1)', '127.0.0.1')
    .option('--no-tcp', 'disable TCP')
    .option('--socket <path>', 'unix listen socket')
    .option('--name <name>', 'session name')
    .option('--session-file <path>', 'endpoint record path')
    .option('--no-session-file', 'do not record the endpoint')

export sessionOptsFrom = (fcmPath, o) ->
  Object.assign({}, o, {
    fcmPath:    if fcmPath then path.resolve(fcmPath) else null
    symbols:    if o.symbols then path.resolve(o.symbols) else null
    sdl:        if o.sdl then path.resolve(o.sdl) else null
    configRoot: if o.configRoot then path.resolve(o.configRoot) else null
    maxSteps:   parseInt(o.maxSteps ? String(DEFAULT_MAX_STEPS), 10)
  })

export openSession = (fcmPath, o, log = ->) ->
  checkFCMFits(fcmPath, o.machine) if fcmPath?
  session = new DebugSession(sessionOptsFrom(fcmPath, o))

  info = session.load(session.fcmPath, session.opts)
  if fcmPath? or o.ipl
    for w in [info.entryWarning, info.protectWarning, info.sdlWarning] when w?
      log("warning: #{w}")
    log("SDL index #{info.sdlPath}") if info.sdlPath?

  start = Promise.resolve()
  if o.ipl
    start = session.iplFromMassMemory(session.opts, session.pacer,
                                      ((m) -> log("ipl: #{m}")))

  start.then ->
    session.setBreakOnInterrupt(true) if o.breakOnInterrupt
    session.setHoldInterrupt(true) if o.holdInterrupt
    session.setTrace(true, parseInt(o.traceLimit ? '1024', 10)) if o.trace
    for spec in (o.break ? [])
      addr = session.resolveAddr(spec)
      if addr?
        session.setBreakpoint(addr)
      else
        log("cannot resolve breakpoint '#{spec}'")
    { session, info }

export sessionName = (fcmPath, o, suffix = '') ->
  return o.name if o.name?
  base = if fcmPath then path.basename(fcmPath).replace(/\.fcm$/i, '') else 'gpc'
  base + suffix

export serveSession = (session, o, log = ->) ->
  name = sessionName(session.fcmPath, o, o.nameSuffix ? '')
  sessionFile =
    if o.sessionFile == false then null
    else if typeof o.sessionFile == 'string' then path.resolve(o.sessionFile)
    else sessionFileFor(name)

  server = new DebugServer(session, {
    host: o.host ? '127.0.0.1'
    port: if o.port? then parseInt(o.port, 10) else (o.defaultPort ? DEFAULT_PORT)
    tcp: o.tcp ? true
    socketPath: if o.socket then path.resolve(o.socket) else null
    sessionFile: sessionFile
    onShutdown: o.onShutdown
  })

  server.listen().then (endpoints) ->
    for e in endpoints
      if e.kind == 'tcp' then log("listening on #{e.host}:#{e.port}")
      else log("listening on #{e.path}")
    log("session file #{sessionFile}") if sessionFile?
    tcp = (e for e in endpoints when e.kind == 'tcp')[0]
    { server, sessionFile, endpoints,
      endpoint: if tcp then { host: tcp.host, port: tcp.port } else null }

export {DEFAULT_MAX_STEPS, DEFAULT_PORT}
