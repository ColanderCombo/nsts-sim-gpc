# Batch console over a debug session.

fs = require 'fs'
readline = require 'readline'

require 'com/util'
import {P as noColor, formatRegVal, formatTraceLine, formatRegDump} from 'gpc/dbg/trace'
import {addSessionOptions, openSession} from 'gpc/dbg/session'
import {HalUCP} from 'gpc/halUCP'
import {MSCInstruction} from 'gpc/iop_msc_instr'
import {BCEInstruction} from 'gpc/iop_bce_instr'

# NSTS_PC_TRACE: addresses to count arrivals at, as hex halfword addresses.
PC_TRACE = null
if process.env.NSTS_PC_TRACE
  PC_TRACE = {}
  for t in process.env.NSTS_PC_TRACE.split(',')
    a = parseInt(t.trim(), 16)
    PC_TRACE[a] = 0 unless isNaN(a)

parseHex = (s) -> parseInt(s.replace(/^0x/i, ''), 16)

sectionOffset = (session, addr) ->
  sym = session.sym
  return "" unless sym.symbols?
  sect = sym.getSectionAt(addr)
  if sect?
    for s in sym.sectionsByAddr
      if s.name == sect
        offset = addr - s.address
        sectName = sect.slice(0, 8).toUpperCase().rpad(' ', 8)
        return "#{sectName}+#{offset.asHex(4)}"
  return "        +    "

startIOPTrace = (session, procs) ->
  iop = session.gpc.iop
  iop.traceProcs = {}
  iop.traceProcs[p] = true for p in procs
  msc = new MSCInstruction()
  bce = new BCEInstruction()
  last = {}
  traceWall0 = Date.now()

  regs = (page) ->
    r16 = (bank, word) -> iop.ls.at(page, bank, word)?.get16() ? 0
    r32 = (bank, word) -> iop.ls.at(page, bank, word)?.get32() ? 0
    hex = (v, n) -> (v >>> 0).toString(16).padStart(n, '0')
    if page == 0
      "A=#{hex((r16(1,3) << 16 >>> 0) + r16(2,3), 8)} X=#{hex(r32(0,3), 5)}" +
      " MST=#{hex(r16(2,7), 4)}"
    else
      "D=#{hex((r16(1,0) << 16 >>> 0) + r16(2,0), 8)} BASE=#{hex(r32(2,3), 5)}" +
      " IUA=#{hex(r32(2,5), 2)} BST=#{hex((r16(2,6) << 16 >>> 0) + r16(2,7), 8)}"
  iop.onProcStep = (page, pc, hw1, hw2) =>
    d = if page == 0 then msc.toStr(hw1, hw2) else bce.toStr(hw1, hw2)
    name = if page == 0 then 'MSC ' else "BCE#{page}"
    k = "#{page}:#{pc}"
    if last.key == k
      last.n += 1
      return
    if last.key? and last.n > 1
      ms = (Date.now() - last.wall)
      process.stderr.write "        #{last.name} #{last.pc}  " +
        "... #{last.n} times (#{ms} ms wall)\n"
    last = {key: k, n: 1, name: name, pc: pc.toString(16).padStart(5, '0'),
            wall: Date.now()}
    us = (session.gpc.cpu.timeNs / 1000).toFixed(1).padStart(11)
    w = ((Date.now() - traceWall0) / 1000).toFixed(3).padStart(8)
    process.stderr.write "#{us} us #{w} w  #{name} #{pc.toString(16).padStart(5,'0')}  " +
      "#{hw1.toString(16).padStart(4,'0')} #{hw2.toString(16).padStart(4,'0')}  " +
      "#{sectionOffset(session, pc)}  #{d.text.padEnd(22)}  #{regs(page)}\n"
    return


class BatchConsole
  constructor: (@session, @opts) ->
    @lines = if @opts.output? then [] else null
    @traceEnabled = @opts.trace ? false
    @dumpInterval = parseInt(@opts.dumpInterval ? '100', 10)
    @lastSection = null
    @wall0 = Date.now()
    @pending = null
    @pcWall = Date.now()

  write: (s) ->
    if @lines? then @lines.push(s) else process.stdout.write(s + '\n')

  info: (s) -> @write(s) if @opts.verbose or @traceEnabled or not @lines?

  flush: ->
    fs.writeFileSync(@opts.output, @lines.join('\n') + '\n') if @lines?

  closeIO: ->
    streams = (st for own ch, st of (@session.iohost?.outStreams ? {}) when st?)
    return Promise.resolve() unless streams.length
    Promise.all(streams.map (st) -> new Promise (resolve) ->
      st.end(resolve))

  attachOutput: ->
    @session.on (msg) =>
      return unless msg.event == 'output'
      text = msg.body.text
      if msg.body.category == 'stderr'
        process.stderr.write(text)
      else if @lines?
        @lines.push(text.replace(/\n$/, ''))
      else
        process.stdout.write(text)

  attachTrace: ->
    return unless @traceEnabled
    @traceOpts =
      color: noColor
      stepWidth: 5
      niaWidth: 6
      sym: { formatCSect: (a) => sectionOffset(@session, a) }
    @session.traceSink = (rec, changes) =>
      if @session.sym.symbols?
        sect = @session.sym.getSectionAt(rec.addr)
        if sect? and sect != @lastSection
          @write "--- ENTERING: #{sect} ---"
          @lastSection = sect
      @write formatTraceLine(rec.step, rec.addr, rec.hw1, rec.hw2, rec.text,
                             rec.len, changes, @traceOpts)
      if @dumpInterval > 0 and (rec.step + 1) % @dumpInterval == 0
        @write line for line in formatRegDump(@session.gpc.cpu, rec.step + 1, { color: noColor })
        @write ""
      return

  attachPCTrace: ->
    return unless PC_TRACE?
    prev = @session.traceSink
    @session.traceSink = (rec, changes) =>
      if PC_TRACE[rec.addr]?
        PC_TRACE[rec.addr] += 1
        process.stderr.write "PC #{rec.addr.toString(16).padStart(5,'0')} hit " +
          "##{PC_TRACE[rec.addr]}  #{(@session.gpc.cpu.timeNs / 1e6).toFixed(1)} ms sim" +
          "  #{((Date.now() - @pcWall) / 1000).toFixed(1)} s wall\n"
      prev?(rec, changes)
      return

  pendingInput: ->
    return null unless @session.halUCP.waitingForInput
    { channel: @session.halUCP.channel ? 0
      type: HalUCP.iocodeTypeName(@session.halUCP.pendingIocode) }

  answerInput: (pending) ->
    ch = pending.channel
    if @session.iohost.hasFileInput(ch)
      line = @session.iohost.readInputLine(ch)
      if line?
        @session.provideInput(line)
      else
        @session.halUCP.provideEof()
      return Promise.resolve()
    unless @opts.interactive
      @session.halUCP.provideEof()
      return Promise.resolve()
    new Promise (resolve) =>
      rl = readline.createInterface({ input: process.stdin, output: process.stdout })
      rl.question "[#{pending.type} on #{ch}] ? ", (answer) =>
        rl.close()
        @session.provideInput(answer)
        resolve()

  banner: (info) ->
    @info "=== GPC #{if @opts.interactive then 'Interactive' else 'Batch'} Simulator ==="
    @info "FCM: #{@session.fcmPath ? '(none -- the IPL loads the machine)'} (#{info.byteCount} bytes)"
    entry = @session.gpc.cpu.psw.getNIA()
    @info "Entry: 0x#{entry.asHex(4)}"
    @info "Max steps: #{@opts.maxSteps}" unless @opts.interactive
    @info "Trace: #{if @traceEnabled then 'on' else 'off'}"
    @info "Real-time: on (factor #{@opts.rtFactor ? 1})" if @opts.realTime
    @info "Breakpoint: #{b.hex}" for b in @session.breakpointList()
    @info "(Ctrl-C to halt)" if @opts.interactive
    @info ""
    if @session.sym.symbols?
      @info "=== SECTION MAP ==="
      for sect in @session.sym.sectionsByAddr
        @info "  0x#{sect.address.asHex(4)} - 0x#{(sect.address + sect.size - 1).asHex(4)}  " +
              "#{sect.name.rpad(' ', 12)} (#{sect.module})"
      @info "  Start: 0x#{entry.asHex(4)} (#{sectionOffset(@session, entry)})"
      @info ""

  summary: (body, steps) ->
    why = body?.description ? body?.reason ? 'unknown'
    @info "--- STOPPED after #{steps} steps (reason: #{why}) ---"
    simUs = @session.gpc.cpu.timeNs / 1000
    @info "--- simulated CPU time: #{(simUs / 1000).toFixed(3)} ms ---"
    if @opts.realTime
      wallMs = Date.now() - @wall0
      ratio = if wallMs > 0 then (simUs / 1000) / wallMs else 0
      @info "--- wall time: #{wallMs.toFixed(0)} ms (#{ratio.toFixed(2)}x real speed) ---"
    @info "--- FINAL REGISTERS ---"
    @info line for line in formatRegDump(@session.gpc.cpu, steps, { color: noColor })
    @flush()
    why

# `gpc run` subcommand registration
export addCommand = (program) ->
  cmd = program.command('run')
    .description('run an AP-101 program')
    .argument('[fcm-file]', 'FCM memory image to load')

  addSessionOptions(cmd, { maxSteps: 100000 })

  cmd
    .option('--cpu-model <model>', 'timing model: ap101s or ap101b')
    .option('--watch <spec>', 'memory watchpoint: addr[:count] in hex', (v, prev) ->
      prev ?= []
      [a, c] = v.split(':')
      prev.push { addr: parseHex(a), count: parseInt(c or '1', 10) }
      prev
    )
    .option('--watch-log', 'log every watchpoint change instead of breaking', false)
    .option('--output <file>', 'write trace/verbose output to file instead of stdout')
    .option('--dump-interval <n>', 'register dump interval', '100')
    .option('--no-trace', 'disable instruction trace')
    .option('--verbose', 'print informational messages', false)
    .option('--no-verbose', 'suppress informational messages')
    .option('--interactive', 'interactive terminal I/O')
    .option('--iop-trace <procs>', 'trace MSC 0 or BCEs 1-24', ((v) -> (parseInt(x, 10) for x in v.split(',') when x.trim() != '')))
    .action (fcmPath, o) ->
      unless fcmPath? or o.ipl
        process.stderr.write("FATAL: no image given\n")
        process.exit(1)

      say = (m) -> process.stderr.write("gpc run: #{m}\n")
      maxSteps = parseInt(o.maxSteps, 10)
      maxSteps = Infinity if maxSteps <= 0

      openSession(fcmPath, o, say).then (({session, info}) ->
        session.cpu.model = o.cpuModel if o.cpuModel?
        session.halUCP.verbose = o.verbose

        for wp in (o.watch ? [])
          session.setDataBreakpoint(wp.addr + i) for i in [0...wp.count]

        con = new BatchConsole(session, Object.assign({}, o, { maxSteps }))
        con.attachOutput()
        con.attachTrace()
        con.attachPCTrace()
        startIOPTrace(session, o.iopTrace) if o.iopTrace?

        con.banner(info)

        process.on 'SIGINT', ->
          con.info "\n--- INTERRUPTED after #{session.stepCount} steps ---"
          con.info "--- FINAL REGISTERS ---"
          con.info line for line in formatRegDump(session.gpc.cpu, session.stepCount, { color: noColor })
          con.flush()
          con.closeIO().then -> process.exit(0)

        drive = ->
          session.continueRun(maxSteps - session.stepCount).then (body) ->
            pending = con.pendingInput()
            if pending?
              return con.answerInput(pending).then -> drive()
            if o.watchLog and body?.reason == 'data breakpoint'
              con.write("memory watchpoint: #{body.description}")
              return drive() if session.stepCount < maxSteps
            why = con.summary(body, session.stepCount)
            code = if (body?.reason ? '') == 'halt' then 0 else 1
            process.stderr.write("ERROR: #{why}\n") if code != 0
            con.closeIO().then -> process.exit(code)
        drive()
      ), (e) ->
        process.stderr.write("FATAL: #{e.message}\n")
        process.exit(1)
