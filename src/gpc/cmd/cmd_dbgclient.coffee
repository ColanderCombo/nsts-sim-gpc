# gpc dbg-client cmd
# one-shot client for a `gpc dbg-serve` session
#
# Connects, sends one command (or a command per line of stdin), prints what
# comes back, and exits.  The session outlives the client, so a debugging
# session is driven by a sequence of separate invocations.
#
# The endpoint comes from --socket/--port, or from the session file the
# server wrote.  With neither, the most recently started session is used.

net = require 'net'
readline = require 'readline'

# Endpoint resolution is shared with the GUI's client.  The socket loop
# below is separate: this is a one-shot with exit codes to set.
import {resolveEndpoint, describeEndpoint} from 'gpc/dbgclient'

export addCommand = (program) ->
  cmd = program.command('dbg-client')
    .aliases(['dbgc', 'client'])
    .description('Send a command to a running `gpc dbg-serve` session')
    .argument('[command...]', 'command and arguments; with none, read a command per line from stdin')
    .passThroughOptions()

  cmd
    .option('--port <n>', 'TCP port of the session')
    .option('--host <addr>', 'host of the session (default: 127.0.0.1)')
    .option('--socket <path>', 'unix socket of the session')
    .option('--name <name>', 'session name, to pick among several sessions')
    .option('--json', 'print the structured result instead of the rendered text')
    .option('--events', 'also print events that arrive while waiting')
    .option('--timeout <s>', 'give up after this many seconds (default: 300)', '300')
    .action (argv, o) ->
      ep = resolveEndpoint(o)
      timeoutMs = Math.max(1, parseFloat(o.timeout) * 1000)
      exitCode = 0

      sock = net.connect(ep)
      sock.setEncoding('utf8')
      sock.setNoDelay(true)

      pending = new Map()    # id -> resolve
      nextId = 1
      buf = ''

      fail = (msg, code = 2) ->
        process.stderr.write("gpc-dbg: #{msg}\n")
        process.exit(code)

      sock.on 'error', (e) ->
        fail("cannot reach a session at #{describeEndpoint(ep)}: #{e.message}\n" +
             "        start one with: gpc dbg-serve <fcm-file>")

      timer = setTimeout((->
        fail("timed out after #{o.timeout}s waiting for a reply", 3)), timeoutMs)
      timer.unref?()

      send = (line) ->
        id = nextId++
        new Promise (resolve) ->
          pending.set(id, resolve)
          sock.write(JSON.stringify({ id, cmd: line[0], argv: line.slice(1), text: true }) + '\n')

      handle = (msg) ->
        if msg.event?
          return if msg.event == 'welcome'
          if o.events
            process.stderr.write("[#{msg.event}] #{JSON.stringify(msg.body)}\n")
          return
        resolve = pending.get(msg.id)
        return unless resolve?
        pending.delete(msg.id)
        resolve(msg)

      sock.on 'data', (chunk) ->
        buf += chunk
        loop
          nl = buf.indexOf('\n')
          break if nl < 0
          line = buf.slice(0, nl)
          buf = buf.slice(nl + 1)
          continue if line.trim().length == 0
          try
            handle(JSON.parse(line))
          catch e
            process.stderr.write("gpc-dbg: unreadable reply: #{line}\n")

      report = (reply) ->
        if reply.ok
          if o.json
            process.stdout.write(JSON.stringify(reply.result, null, 2) + '\n')
          else if (reply.text ? '').length > 0
            process.stdout.write(reply.text + '\n')
        else
          exitCode = 1
          process.stderr.write("*** #{reply.error.code}: #{reply.error.message}\n")
        return

      runAll = (lines) ->
        lines = (l for l in lines when l.trim().length > 0 and not l.trim().startsWith('#'))
        step = (i) ->
          if i >= lines.length
            clearTimeout(timer)
            sock.end()
            return process.exit(exitCode)
          send(lines[i].trim().split(/\s+/)).then (reply) ->
            report(reply)
            step(i + 1)
        step(0)

      sock.on 'connect', ->
        if argv.length > 0
          return runAll([argv.join(' ')])
        chunks = []
        rl = readline.createInterface({ input: process.stdin, terminal: false })
        rl.on 'line', (l) -> chunks.push(l)
        rl.on 'close', -> runAll(chunks)
