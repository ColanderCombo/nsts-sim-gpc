# DebugServer: the debug session on a socket
#
# Framing is one JSON object per line, both ways.  A request is
#
#   { "id": 1, "cmd": "step", "args": { "count": 10 }, "text": true }
#
# and its reply is
#
#   { "id": 1, "ok": true, "result": { ... }, "text": "..." }
#   { "id": 1, "ok": false, "error": { "code": "badArgs", "message": "..." } }
#
# `text` in the request asks for the rendered form beside the structured
# result.  A line that is not JSON is taken as a command line -- `step 10` --
# parsed against the same parameter table, and answered with `text` filled
# in.  A command line carries no id, so its reply has `id: null`; a client
# issuing more than one command at a time sends JSON and gets its id back.
# `mode text` switches a connection to plain-text replies, each closed by a
# blank line, for use from `nc`.
#
# Events are pushed to every subscribed connection, unsolicited and without
# an id:
#
#   { "event": "stopped", "seq": 12, "body": { "reason": "breakpoint", ... } }
#
# Execution commands reply when the machine stops, so replies can arrive out
# of order; every reply carries the id of its request.  Queries are answered
# while a run is in progress.

net = require 'net'
fs = require 'fs'
os = require 'os'
path = require 'path'

import {COMMANDS, lookupCommand, coerceArgs, parseArgLine, cmdError,
        PROTOCOL_VERSION} from 'gpc/dbgcmds'

# Bound on one request line, so a client that sends no newline cannot grow
# the buffer without limit.
MAX_LINE = 1 << 20

export DEFAULT_PORT = 4444

# Where a server records its endpoint and a client looks for one.
export sessionDir = () -> path.join(os.tmpdir(), 'gpc-dbg')

export sessionFileFor = (name) ->
  base = (name ? 'default').replace(/[^A-Za-z0-9._-]/g, '_')
  path.join(sessionDir(), "#{base}.json")

# The most recently written session file, for a client given no endpoint.
export latestSession = () ->
  try
    files = for f in fs.readdirSync(sessionDir()) when f.endsWith('.json')
      p = path.join(sessionDir(), f)
      { path: p, mtime: fs.statSync(p).mtimeMs }
    return null if files.length == 0
    files.sort (a, b) -> b.mtime - a.mtime
    JSON.parse(fs.readFileSync(files[0].path, 'utf8'))
  catch e
    null

class Connection
  constructor: (@server, @socket, @id) ->
    @buf = ''
    @mode = 'json'
    @subscribed = true
    @closed = false

  send: (obj) ->
    return if @closed
    try
      @socket.write(JSON.stringify(obj) + '\n')
    catch e
      @close()

  # A blank line closes a plain-text reply.
  sendText: (s) ->
    return if @closed
    try
      @socket.write((s ? '') + '\n\n')
    catch e
      @close()

  reply: (id, obj) ->
    if @mode == 'text'
      return @sendText(if obj.ok then (obj.text ? '') else "*** #{obj.error.code}: #{obj.error.message}")
    @send(Object.assign({ id }, obj))

  event: (msg) ->
    return unless @subscribed
    if @mode == 'text'
      return unless msg.event in ['stopped', 'output', 'input']
      switch msg.event
        when 'output' then @sendText("[output] #{msg.body.text.trimEnd()}")
        when 'input'  then @sendText("[input] program is waiting for #{msg.body.type} input")
        else @sendText("[#{msg.event}] #{msg.body.reason}: #{msg.body.location.hex}")
      return
    @send(msg)

  close: () ->
    return if @closed
    @closed = true
    try
      @socket.end()
    catch e
      null

export class DebugServer
  constructor: (@session, opts = {}) ->
    @host = opts.host ? '127.0.0.1'
    @port = opts.port ? DEFAULT_PORT
    @tcp = opts.tcp ? true
    @socketPath = opts.socketPath ? null
    @sessionFile = opts.sessionFile ? null
    @log = opts.log ? (msg) -> process.stderr.write("gpc-dbg: #{msg}\n")
    @connections = new Set()
    @servers = []
    @nextConnId = 0
    @endpoints = []
    @onShutdown = opts.onShutdown ? null
    @_unsubscribe = @session.on (msg) => @broadcast(msg)

  broadcast: (msg) ->
    c.event(msg) for c in Array.from(@connections)
    return

  listen: () ->
    started = []
    if @tcp
      started.push(@_listenOn({ host: @host, port: @port }, (srv) =>
        a = srv.address()
        { kind: 'tcp', host: a.address, port: a.port }))
    if @socketPath?
      try
        fs.unlinkSync(@socketPath) if fs.existsSync(@socketPath)
      catch e
        null
      fs.mkdirSync(path.dirname(@socketPath), { recursive: true })
      started.push(@_listenOn({ path: @socketPath }, => { kind: 'unix', path: @socketPath }))
    Promise.all(started).then (endpoints) =>
      @endpoints = endpoints
      @_writeSessionFile()
      endpoints

  _listenOn: (where, describe) ->
    new Promise (resolve, reject) =>
      srv = net.createServer (sock) => @_accept(sock)
      srv.on 'error', (e) -> reject(e)
      srv.listen where, =>
        @servers.push(srv)
        resolve(describe(srv))

  _writeSessionFile: () ->
    return unless @sessionFile?
    fs.mkdirSync(path.dirname(@sessionFile), { recursive: true })
    fs.writeFileSync(@sessionFile, JSON.stringify({
      pid: process.pid
      protocol: PROTOCOL_VERSION
      fcm: @session.fcmPath
      endpoints: @endpoints
      started: new Date().toISOString()
    }, null, 2) + '\n')

  _accept: (sock) ->
    sock.setNoDelay(true)
    conn = new Connection(@, sock, @nextConnId++)
    @connections.add(conn)
    sock.setEncoding('utf8')
    sock.on 'data', (chunk) => @_data(conn, chunk)
    sock.on 'error', => @_drop(conn)
    sock.on 'close', => @_drop(conn)
    conn.send({
      event: 'welcome'
      seq: 0
      body: {
        protocol: PROTOCOL_VERSION
        fcm: @session.fcmPath
        machine: @session.gpc.machine.name
        commands: Object.keys(COMMANDS).sort()
        status: @session.stopBody()
      }
    })
    return

  _drop: (conn) ->
    conn.closed = true
    @connections.delete(conn)

  _data: (conn, chunk) ->
    conn.buf += chunk
    if conn.buf.length > MAX_LINE
      conn.reply(null, { ok: false, error: { code: 'lineTooLong', message: "request line over #{MAX_LINE} bytes" } })
      conn.buf = ''
      return conn.close()
    loop
      nl = conn.buf.indexOf('\n')
      break if nl < 0
      line = conn.buf.slice(0, nl).replace(/\r$/, '')
      conn.buf = conn.buf.slice(nl + 1)
      @_line(conn, line) if line.trim().length > 0
    return

  _line: (conn, line) ->
    req = null
    if line.trimStart().startsWith('{')
      try
        req = JSON.parse(line)
      catch e
        return conn.reply(null, { ok: false, error: { code: 'badJSON', message: e.message } })
      req.wantText = req.text ? false
    else
      tokens = line.trim().split(/\s+/)
      req = { cmd: tokens[0], argv: tokens.slice(1), wantText: true }
    @dispatch(conn, req)

  # Connection-local commands are handled before the session table, because
  # they change how this connection is answered and not what the machine does.
  _local: (conn, req) ->
    switch String(req.cmd).toLowerCase()
      when 'mode'
        want = req.args?.mode ? req.argv?[0] ? 'json'
        return { ok: false, error: { code: 'badArgs', message: "mode: expected 'json' or 'text'" } } unless want in ['json', 'text']
        conn.mode = want
        { ok: true, result: { mode: want }, text: "mode #{want}" }
      when 'subscribe'
        want = req.args?.enabled ? req.argv?[0] ? true
        conn.subscribed = want not in ['off', 'no', 'false', '0', false]
        { ok: true, result: { subscribed: conn.subscribed }, text: "events #{if conn.subscribed then 'on' else 'off'}" }
      when 'quit', 'disconnect'
        conn.close()
        { ok: true, result: {}, text: 'bye' }
      when 'shutdown'
        setTimeout((=> @shutdown()), 10)
        { ok: true, result: {}, text: 'shutting down' }
      else null

  dispatch: (conn, req) ->
    id = req.id ? null
    local = @_local(conn, req)
    return conn.reply(id, local) if local?

    spec = lookupCommand(req.cmd)
    unless spec?
      return conn.reply(id, { ok: false, error: {
        code: 'unknownCommand', message: "no such command: #{req.cmd} (try 'help')" } })

    try
      raw = if req.argv? then parseArgLine(spec, req.argv) else (req.args ? {})
      args = coerceArgs(@session, spec, raw)
    catch e
      return conn.reply(id, { ok: false, error: {
        code: e.code ? 'badArgs', message: e.message } })

    finish = (result) =>
      reply = { ok: true, result }
      if req.wantText
        try
          reply.text = spec.render?(result, @session) ? ''
        catch e
          reply.text = "(render failed: #{e.message})"
      conn.reply(id, reply)

    fail = (e) =>
      conn.reply(id, { ok: false, error: {
        code: e.code ? 'commandFailed', message: e.message ? String(e) } })

    try
      out = spec.exec(@session, args)
    catch e
      return fail(e)
    if out?.then?
      out.then(finish, fail)
    else
      finish(out)
    return

  shutdown: () ->
    @_unsubscribe?()
    c.close() for c in Array.from(@connections)
    @connections.clear()
    for srv in @servers
      try
        srv.close()
      catch e
        null
    @servers = []
    if @socketPath?
      try
        fs.unlinkSync(@socketPath)
      catch e
        null
    if @sessionFile?
      try
        fs.unlinkSync(@sessionFile)
      catch e
        null
    @onShutdown?()
    return
