# Debug-session terminal, one-shot, and script client. The endpoint comes
# from --socket/--port or the most recently started session's record.

net = require 'net'
readline = require 'readline'

# Endpoint resolution is shared with the GUI's client.  The socket loop
# below is separate: this is a one-shot with exit codes to set.
import {resolveEndpoint, describeEndpoint} from 'gpc/dbg/dbgclient'
import {addSessionOptions, openSession, serveSession} from 'gpc/dbg/session'

IMAGE_RE = /\.fcm$/i

export addCommand = (program) ->
  cmd = program.command('dbg')
    .aliases(['debug', 'dbg-client', 'dbgc', 'client'])
    .description('use a debug session')
    .argument('[command...]', 'command, script, or *.fcm image')
    .passThroughOptions()

  addSessionOptions(cmd)

  cmd
    .option('--image <fcm-file>', 'open this image locally')
    .option('--port <n>', 'TCP port of the session')
    .option('--host <addr>', 'host of the session (default: 127.0.0.1)')
    .option('--socket <path>', 'unix socket of the session')
    .option('--name <name>', 'session name')
    .option('--json', 'print structured output')
    .option('--events', 'print events while waiting')
    .option('--no-prompt', 'read commands from stdin')
    .option('--timeout <s>', 'timeout in seconds', '300')
    .option('--wait-for <pattern>', 'repeat until output matches')
    .option('--every <s>', '--wait-for interval', '3')
    .action (argv, o) ->
      image = o.image ? null
      if not image? and argv.length > 0 and IMAGE_RE.test(argv[0])
        image = argv[0]
        argv = argv.slice(1)
      local = null          # {session, server} when this process holds it

      ep = if image? then null else resolveEndpoint(o)
      timeoutMs = Math.max(1, parseFloat(o.timeout) * 1000)
      exitCode = 0

      sock = null
      pending = new Map()    # id -> resolve
      nextId = 1
      buf = ''
      everyMs = Math.max(100, parseFloat(o.every) * 1000)

      leave = (code) ->
        local?.server?.shutdown()
        process.exit(code)

      fail = (msg, code = 2) ->
        process.stderr.write("gpc-dbg: #{msg}\n")
        leave(code)

      timer = setTimeout((->
        fail("timed out after #{o.timeout}s waiting for a reply", 3)), timeoutMs)
      timer.unref?()

      send = (line) ->
        id = nextId++
        new Promise (resolve) ->
          pending.set(id, resolve)
          sock.write(JSON.stringify({ id, cmd: line[0], argv: line.slice(1), text: true }) + '\n')

      onEventHook = null     # the prompt's event printer, when there is one

      handle = (msg) ->
        if msg.event?
          return if msg.event == 'welcome'
          return onEventHook(msg) if onEventHook?
          if o.events
            process.stderr.write("[#{msg.event}] #{JSON.stringify(msg.body)}\n")
          return
        resolve = pending.get(msg.id)
        return unless resolve?
        pending.delete(msg.id)
        resolve(msg)

      onData = (chunk) ->
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

      sink = null
      capture = (into) -> sink = into
      out = (text) -> if sink? then sink.push(text) else process.stdout.write(text + '\n')
      err = (text) -> if sink? then sink.push(text) else process.stderr.write(text + '\n')

      report = (reply) ->
        if reply.ok
          if o.json
            out(JSON.stringify(reply.result, null, 2))
          else if (reply.text ? '').length > 0
            out(reply.text)
        else
          exitCode = 1
          err("*** #{reply.error.code}: #{reply.error.message}")
        return

      runAll = (lines, done = null) ->
        lines = (l for l in lines when l.trim().length > 0 and not l.trim().startsWith('#'))
        text = []
        step = (i) ->
          if i >= lines.length
            return done(text.join('\n')) if done?
            clearTimeout(timer)
            sock.end()
            return leave(exitCode)
          send(lines[i].trim().split(/\s+/)).then (reply) ->
            if done? then text.push(reply.text ? '') else report(reply)
            step(i + 1)
        step(0)

      poll = (lines) ->
        re = new RegExp(o.waitFor)
        round = ->
          runAll lines, (out) ->
            unless re.test(out)
              return setTimeout(round, everyMs)
            process.stdout.write(out + '\n') if out.length
            clearTimeout(timer)
            sock.end()
            leave(0)
        round()

      start = (lines) ->
        (if o.waitFor? then poll else runAll)(lines)

      connect = (lines) ->
        pending.clear()
        buf = ''
        sock = net.connect(ep)
        sock.setEncoding('utf8')
        sock.setNoDelay(true)
        sock.on 'data', onData
        sock.on 'error', (e) ->
          sock.destroy()
          return setTimeout((-> connect(lines)), everyMs) if o.waitFor?
          fail("cannot reach a session at #{describeEndpoint(ep)}: #{e.message}\n" +
               "        start one with: gpc dbg-serve <fcm-file>")
        sock.on 'connect', -> start(lines)

      names = []              # command names, for completion

      repl = ->
        clearTimeout(timer)
        rl = readline.createInterface({
          input: process.stdin
          output: process.stdout
          terminal: true
          prompt: "#{o.name ? 'gpc'}> "
          completer: (line) ->
            hits = (n for n in names when n.indexOf(line) == 0)
            [(if hits.length then hits else names), line]
        })
        emit = (text) ->
          readline.cursorTo(process.stdout, 0)
          readline.clearLine(process.stdout, 0)
          process.stdout.write(text + '\n') if text.length
          rl.prompt(true)
        onEventHook = (msg) ->
          return unless o.events or msg.event == 'stopped'
          emit("[#{msg.event}] #{msg.body?.reason ? JSON.stringify(msg.body)}")
        sock.on 'close', ->
          emit('gpc-dbg: the session closed the connection')
          leave(exitCode)
        rl.on 'line', (raw) ->
          line = raw.trim()
          return rl.prompt() if line.length == 0 or line.startsWith('#')
          return rl.close() if line in ['quit', 'exit']
          armTimeout()
          send(line.split(/\s+/)).then (reply) ->
            clearTimeout(timer)
            code = exitCode
            shown = []
            capture(shown)
            report(reply)
            capture(null)
            exitCode = code
            emit(shown.join('\n'))
        rl.on 'close', ->
          sock.end()
          leave(exitCode)
        process.stdout.write(
          "gpc dbg-client: #{describeEndpoint(ep)}" +
          "#{if o.name? then " (#{o.name})" else ''} -- " +
          "`help` lists the commands, Ctrl-D or `quit` to leave\n")
        rl.prompt()

      armTimeout = ->
        timer = setTimeout((->
          fail("timed out after #{o.timeout}s waiting for a reply", 3)), timeoutMs)
        timer.unref?()

      startRepl = ->
        send(['help']).then (reply) ->
          names = (c.name for c in (reply.result?.commands ? []))
          repl()

      interactive = argv.length == 0 and process.stdin.isTTY and
                    o.prompt != false and not o.waitFor?

      dispatch = ->
        if argv.length > 0
          connect([argv.join(' ')])
        else if interactive
          start = startRepl
          connect([])
        else
          chunks = []
          rl = readline.createInterface({ input: process.stdin, terminal: false })
          rl.on 'line', (l) -> chunks.push(l)
          rl.on 'close', -> connect(chunks)

      unless image?
        return dispatch()

      say = (m) -> process.stderr.write("gpc-dbg: #{m}\n")
      openSession(image, o, say)
        .then ({session}) ->
          serveSession(session, Object.assign({}, o, {
            defaultPort: 0
            port: null
            nameSuffix: '-dbg'
          }), (->)).then (served) ->
            local = { session, server: served.server }
            ep = served.endpoint
            say("session on #{ep.host}:#{ep.port}")
            dispatch()
        .catch (e) ->
          process.stderr.write("FATAL: #{e.message}\n")
          process.exit(1)
