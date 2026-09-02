# DebugClient: the other end of `gpc dbg-serve`
#
# One socket, JSON per line, replies matched to requests by id.  Execution
# commands reply only when the machine stops and queries are answered while
# it runs, so replies arrive out of order and every request must carry an
# id -- there is no request/reply lockstep to fall back on.
#
# Events (`stopped`, `running`, `output`, `input`, ...) arrive unsolicited
# and without an id; `on(event, fn)` subscribes, and `on('*', fn)` sees them
# all.
#
# The GUI is the client this exists for; `gpc dbg-client` is a one-shot
# stdin/stdout program that sets exit codes and runs a separate loop.  The
# endpoint resolution below is shared with it.

fs = require 'fs'
path = require 'path'

import {latestSession, sessionFileFor, DEFAULT_PORT} from 'gpc/dbgserver'

# Where to connect: an explicit endpoint wins, then a named session file,
# then whichever session started last.
export resolveEndpoint = (o = {}) ->
  return { path: path.resolve(o.socket) } if o.socket
  return { host: o.host ? '127.0.0.1', port: parseInt(o.port, 10) } if o.port
  info =
    if o.name?
      try
        JSON.parse(fs.readFileSync(sessionFileFor(o.name), 'utf8'))
      catch e
        null
    else
      latestSession()
  unless info?
    return { host: o.host ? '127.0.0.1', port: DEFAULT_PORT }
  unix = (e for e in (info.endpoints ? []) when e.kind == 'unix')[0]
  return { path: unix.path } if unix? and process.platform != 'win32'
  tcp = (e for e in (info.endpoints ? []) when e.kind == 'tcp')[0]
  return { host: tcp.host, port: tcp.port } if tcp?
  { host: o.host ? '127.0.0.1', port: DEFAULT_PORT }

export describeEndpoint = (ep) ->
  if ep.path then ep.path else "#{ep.host}:#{ep.port}"

export class DebugClient
  constructor: (@endpoint, opts = {}) ->
    @net = opts.net ? require('net')
    @sock = null
    @buf = ''
    @nextId = 1
    @pending = new Map()       # id -> { resolve, reject }
    @handlers = {}             # event name (or '*') -> [fn]
    @welcome = null
    @connected = false

  on: (event, fn) ->
    (@handlers[event] ?= []).push(fn)
    => @handlers[event] = (f for f in @handlers[event] when f != fn)

  _fire: (msg) ->
    for fn in ((@handlers[msg.event] ? []).concat(@handlers['*'] ? []))
      try
        fn(msg.body, msg)
      catch e
        console.error("DebugClient: #{msg.event} handler failed:", e)
    return

  # Settles on the welcome event, which carries the protocol version, the
  # image and the machine's current stop -- everything a client needs before
  # it asks its first question.
  connect: () ->
    new Promise (resolve, reject) =>
      done = false
      @sock = @net.connect(@endpoint)
      @sock.setEncoding('utf8')
      @sock.setNoDelay(true)
      @sock.on 'error', (e) =>
        @connected = false
        return reject(e) if not done
        done = true
        @_failAll("connection lost: #{e.message}")
        @_fire({ event: 'error', body: { message: e.message } })
      @sock.on 'close', =>
        @connected = false
        @_failAll('connection closed')
        @_fire({ event: 'closed', body: {} })
      @sock.on 'data', (chunk) => @_data(chunk)
      @on 'welcome', (body) =>
        @welcome = body
        @connected = true
        return if done
        done = true
        resolve(body)

  _data: (chunk) ->
    @buf += chunk
    loop
      nl = @buf.indexOf('\n')
      break if nl < 0
      line = @buf.slice(0, nl).replace(/\r$/, '')
      @buf = @buf.slice(nl + 1)
      continue if line.trim().length == 0
      try
        msg = JSON.parse(line)
      catch e
        console.error("DebugClient: unreadable reply: #{line}")
        continue
      @_message(msg)
    return

  _message: (msg) ->
    return @_fire(msg) if msg.event?
    p = @pending.get(msg.id)
    return unless p?
    @pending.delete(msg.id)
    if msg.ok
      p.resolve(msg.result)
    else
      err = new Error(msg.error?.message ? 'command failed')
      err.code = msg.error?.code ? 'commandFailed'
      p.reject(err)
    return

  _failAll: (why) ->
    waiting = Array.from(@pending.values())
    @pending.clear()
    for p in waiting
      err = new Error(why)
      err.code = 'disconnected'
      p.reject(err)
    return

  # `send('step', {count: 10})`.  Resolves with the command's structured
  # result; `text: true` also asks the server to render it.
  send: (cmd, args = {}, opts = {}) ->
    return Promise.reject(new Error('not connected')) unless @sock?
    id = @nextId++
    req = { id, cmd, args }
    req.text = true if opts.text
    new Promise (resolve, reject) =>
      @pending.set(id, { resolve, reject })
      try
        @sock.write(JSON.stringify(req) + '\n')
      catch e
        @pending.delete(id)
        reject(e)

  # Fire and forget, for a command whose answer nothing waits on.  A
  # rejection would otherwise become an unhandled promise.
  post: (cmd, args = {}) ->
    @send(cmd, args).catch (e) ->
      console.warn("DebugClient: #{cmd} failed: #{e.message}")
    return

  close: () ->
    try
      @sock?.end()
    catch e
      null
    @sock = null
    @connected = false
    return
