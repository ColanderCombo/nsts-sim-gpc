# DebugSession: the debugger under a protocol
#
# The session holds the machine and the debugger state: breakpoints, data
# breakpoints, the watch list, the I/O channels, the trace ring and the step
# budget.  It renders nothing.  Execution commands return a promise that
# settles when the machine stops.  Every stop, every character of program
# output and every request for input is published as an event.
#
# The run loop is GUIHarness's, reached through its `_afterStep`,
# `onRunStart` and `onRunStop` hooks.
#
# Stop reasons take DAP's `stopped` vocabulary where one applies: 'entry',
# 'step', 'breakpoint', 'data breakpoint', 'pause', 'exception'.  'halt',
# 'interrupt', 'interrupt held', 'input' and 'step budget' cover the rest of
# the AP-101 states.

require 'com/util'
import {GUIHarness} from 'gpc/guiharness'
import {IOHost} from 'gpc/iohost'
import {HalUCP} from 'gpc/halUCP'
import Instruction from 'gpc/cpu_instr'
import {SymbolStack} from 'gpc/symbolStack'
import {BusMonitor, DiscreteMonitor, EventLog, stampOf} from 'gpc/dbgmonitor'

# Program output kept for a client that connects after it was written.
OUTPUT_LOG_MAX = 4096

export class DebugSession extends GUIHarness
  constructor: (opts = {}) ->
    super(opts)
    @opts = opts
    @fcmPath = opts.fcmPath ? null
    @maxSteps = opts.maxSteps ? 10000000

    @listeners = []
    @eventSeq = 0

    # Data breakpoints: addr -> { enabled, name, on, last }.  `last` is the
    # value the watch was armed with, which is what 'change' compares to.
    @dataBreaks = new Map()
    @_dataHit = null

    # Watch list: reported with every stop.
    @watches = new Map()

    @outputLog = []
    @outputDropped = 0

    @stopReason = 'entry'
    @stopDescription = null
    @lastError = null

    @_execActive = false
    @_stopWaiters = []
    @_stepBudget = null
    @_runStartSteps = 0
    @_budgetHit = false
    @_pauseRequested = false
    @_execKind = 'continue'
    @_intStop = null
    @_runToAddr = null
    @_runToTemp = false

    # Symbol layers over the image's table, for overlays.
    @syms = new SymbolStack(@sym)

    # Logpoints record and carry on; breakpoints stop.
    @logpoints = new Map()
    @_reenable = null

    @busMon = new BusMonitor(@)
    @discMon = new DiscreteMonitor(@)
    @logs = []

    # Instruction trace: a ring of what executed, off by default.
    @traceEnabled = false
    @traceLimit = 1024
    @traceRing = []

    @iohost = null

  # Capture the acceptance that armed a break, for the stop classification.
  _wireInterruptHook: () ->
    @gpc.cpu.onInterrupt = (entry) =>
      @lastInterrupt = entry
      if @breakOnInterrupt
        @_intBreak = entry
        @_intStop = entry
    return

  #
  # Events
  #
  on: (fn) ->
    @listeners.push(fn)
    => @listeners = (l for l in @listeners when l != fn)

  emit: (event, body = {}) ->
    @eventSeq++
    msg = { event, seq: @eventSeq, body }
    @toLogs(event, body)
    for fn in @listeners.slice()
      try
        fn(msg)
      catch e
        process.stderr.write("DebugSession: listener failed: #{e.message}\n")
    return msg

  # A record always reaches the logs; it reaches connected clients only when
  # the monitor that produced it was asked to broadcast.
  publish: (kind, body, broadcast = false) ->
    return @emit(kind, body) if broadcast
    @toLogs(kind, body)
    return null

  toLogs: (kind, body) ->
    return unless @logs.length
    stamp = stampOf(@)
    log.write(kind, body, stamp) for log in @logs when log.wants(kind)
    return

  openLog: (filePath, opts = {}) ->
    log = new EventLog(filePath, opts)
    @logs.push(log)
    log

  closeLog: (filePath = null) ->
    keep = []
    closed = 0
    for log in @logs
      if not filePath? or log.filePath == filePath
        log.close()
        closed++
      else
        keep.push(log)
    @logs = keep
    closed

  # GUIHarness posts its refusals and its reasons for stopping here.
  notify: (msg) ->
    @statusNote = msg
    return

  #
  # Startup
  #
  load: (fcmPath = @fcmPath, opts = @opts) ->
    @fcmPath = fcmPath
    info = @configureFromOpts(fcmPath, opts)
    @configureRunOpts(opts)
    @syms.rebase()
    @_initIO()
    @stopReason = 'entry'
    @stopDescription = null
    return info

  _initIO: () ->
    @iohost ?= IOHost.fromOpts(@halUCP, @opts)
    @iohost.init(@sym.symbols, @sym.symTypes)
    @iohost.outputCallback = (text, channel) => @_output(text, channel)
    @iohost.errorCallback = (msg) => @_output("*** #{msg}\n", 0, 'stderr')
    @halUCP.errorCallback = (msg) => @_output("*** #{msg}\n", 0, 'stderr')
    @halUCP.controlCallback = (iocode, param, channel) =>
      @_output(@_controlText(iocode, param), channel)
    @halUCP.inputCallback = () =>
      @emit('input', {
        iocode: @halUCP.pendingIocode
        type: HalUCP.iocodeTypeName(@halUCP.pendingIocode)
        channel: 0
      })
    return

  # HAL/S I/O control codes as the spacing they stand for.
  _controlText: (iocode, param) ->
    switch iocode
      when 0, 1, 2, 3, 4 then '\n'.repeat(if iocode == 4 then Math.max(1, param) else 1)
      when 5 then ' '.repeat(Math.max(0, param))
      when 6 then ' '.repeat(Math.max(1, param) * 5)
      when 7 then '\n--- PAGE ---\n'
      when 8 then '\n'.repeat(Math.max(1, param))
      else ''

  _output: (text, channel = 0, category = 'stdout') ->
    return unless text? and text.length > 0
    @outputLog.push({ category, channel, text })
    while @outputLog.length > OUTPUT_LOG_MAX
      @outputLog.shift()
      @outputDropped++
    @emit('output', { category, channel, text })
    return

  provideInput: (text) ->
    return false unless @halUCP.waitingForInput
    wasRunning = @halUCP.wasRunning
    @halUCP.provideInput(text)
    @halUCP.wasRunning = false
    return wasRunning

  #
  # Address resolution
  #
  # An explicit 0x prefix is always hex; a bare token is a symbol when one
  # carries that name and hex otherwise.  A trailing +/- offset is taken in
  # the same base as the token that carries it.
  #
  resolveAddr: (spec) ->
    return null unless spec?
    return (spec & 0x7ffff) if typeof spec == 'number'
    s = String(spec).trim()
    return null if s.length == 0
    offset = 0
    m = s.match(/^(.*[^+\-\s])\s*([+\-])\s*(\S+)$/)
    if m? and not m[1].match(/^0[xX]$/)
      s = m[1].trim()
      delta = @_parseNum(m[3])
      return null unless delta?
      offset = if m[2] == '-' then -delta else delta
    base = @_parseBase(s)
    return null unless base?
    return (base + offset) & 0x7ffff

  _parseBase: (s) ->
    return parseInt(s.slice(2), 16) if s.match(/^0[xX][0-9a-fA-F]+$/)
    a = @syms.addressOf(s)
    return a if a?
    return parseInt(s, 16) if s.match(/^[0-9a-fA-F]+$/)
    return null

  _parseNum: (s) ->
    s = String(s).trim()
    v =
      if s.match(/^0[xX][0-9a-fA-F]+$/) then parseInt(s.slice(2), 16)
      else if s.match(/^[0-9a-fA-F]+$/) then parseInt(s, 16)
      else NaN
    return if isNaN(v) then null else v

  labelAt: (addr) -> @syms.getLabelAt(addr) ? null
  sectionOf: (addr) -> @syms.getSectionAt(addr) ? null
  formatCSect: (addr) -> @syms.formatCSect(addr) ? ''
  relocAt: (addr, len = 1) -> @syms.getRelocAt(addr, len) ? null
  hasSymbols: () -> @sym.symbols? or @syms.layers.length > 0

  # The location fields every stop and every location-bearing result carries.
  location: (addr = @gpc.cpu.psw.getNIA()) ->
    {
      addr: addr
      hex: addr.asHex(5)
      label: @labelAt(addr)
      section: @sectionOf(addr)
    }

  #
  # Breakpoints
  #
  setBreakpoint: (addr, opts = {}) ->
    prev = @breakpoints.get(addr)
    @breakpoints.set(addr, {
      enabled: true
      name: opts.name ? @labelAt(addr)
      hits: prev?.hits ? 0
      ignore: opts.ignore ? 0
      once: !!opts.once
    })
    @saveBreakpoints()
    @breakpointAt(addr)

  clearBreakpoint: (addr) ->
    had = @breakpoints.delete(addr)
    @saveBreakpoints()
    return had

  clearBreakpoints: () ->
    n = @breakpoints.size
    @breakpoints.clear()
    @saveBreakpoints()
    return n

  setBreakpointEnabled: (addr, enabled) ->
    bp = @breakpoints.get(addr)
    return null unless bp?
    bp.enabled = !!enabled
    @saveBreakpoints()
    @breakpointAt(addr)

  breakpointAt: (addr) ->
    bp = @breakpoints.get(addr)
    return null unless bp?
    Object.assign(@location(addr), {
      # Still enabled as far as a client is concerned while it is stepped
      # past under its ignore count.
      enabled: bp.enabled or @_reenable == addr
      name: bp.name ? null, hits: bp.hits ? 0
      ignore: bp.ignore ? 0, once: !!bp.once
    })

  breakpointList: () ->
    out = []
    @breakpoints.forEach (bp, addr) => out.push(@breakpointAt(addr))
    out.sort (a, b) -> a.addr - b.addr

  #
  # Logpoints
  #
  # A logpoint records an arrival and lets the run carry on.  It is kept out
  # of the breakpoint map so the run loop's check never sees it.
  #
  setLogpoint: (addr, opts = {}) ->
    @logpoints.set(addr, {
      enabled: true, name: opts.name ? @labelAt(addr)
      message: opts.message ? null, hits: 0
      events: opts.events ? false
    })
    @logpointAt(addr)

  clearLogpoint: (addr) -> @logpoints.delete(addr)

  clearLogpoints: () ->
    n = @logpoints.size
    @logpoints.clear()
    n

  logpointAt: (addr) ->
    lp = @logpoints.get(addr)
    return null unless lp?
    Object.assign(@location(addr), {
      enabled: lp.enabled, name: lp.name ? null
      message: lp.message ? null, hits: lp.hits
    })

  logpointList: () ->
    out = []
    @logpoints.forEach (lp, addr) => out.push(@logpointAt(addr))
    out.sort (a, b) -> a.addr - b.addr

  _checkLogpoint: (addr) ->
    lp = @logpoints.get(addr)
    return unless lp?.enabled
    lp.hits++
    @publish('logpoint', {
      location: @location(addr), name: lp.name ? null
      message: lp.message ? null, hits: lp.hits
      steps: @stepCount, timeNs: @gpc.cpu.timeNs
      registers: (@gpc.cpu.regFiles[@gpc.cpu.psw.getRegSet()].r(i).get32() >>> 0 for i in [0..7])
    }, lp.events)
    return

  #
  # Memory search
  #
  # `values` is a list of halfwords; every address in [start, end] whose run
  # of halfwords matches is reported.
  findMemory: (values, opts = {}) ->
    return { matches: [], searched: 0 } unless values?.length
    start = opts.start ? 0
    end = opts.end ? (@gpc.ram.totalHWCount ? 0x80000) - 1
    limit = opts.limit ? 32
    matches = []
    a = start
    last = end - values.length + 1
    while a <= last
      hit = true
      for v, i in values
        if @ram.get16(a + i, false) != (v & 0xffff)
          hit = false
          break
      if hit
        matches.push(Object.assign(@location(a), {
          values: (@ram.get16(a + i, false) for i in [0...values.length])
        }))
        break if matches.length >= limit
      a++
    { matches, searched: Math.max(0, last - start + 1), start, end,
      truncated: matches.length >= limit }

  #
  # Data breakpoints
  #
  # 'change' stops when the halfword holds a different value than it did at
  # the end of the previous instruction; 'write' stops on any store to it,
  # which the MCM records as the step number of the last write.
  #
  setDataBreakpoint: (addr, opts = {}) ->
    name = opts.name ? @labelAt(addr)
    on_ = if opts.on == 'write' then 'write' else 'change'
    @dataBreaks.set(addr, {
      enabled: true, name: name, on: on_, last: @ram.get16(addr, false)
    })
    @dataBreakpointAt(addr)

  clearDataBreakpoint: (addr) -> @dataBreaks.delete(addr)

  clearDataBreakpoints: () ->
    n = @dataBreaks.size
    @dataBreaks.clear()
    return n

  dataBreakpointAt: (addr) ->
    wp = @dataBreaks.get(addr)
    return null unless wp?
    Object.assign(@location(addr), {
      enabled: wp.enabled, name: wp.name ? null, on: wp.on
      value: @ram.get16(addr, false)
    })

  dataBreakpointList: () ->
    out = []
    @dataBreaks.forEach (wp, addr) => out.push(@dataBreakpointAt(addr))
    out.sort (a, b) -> a.addr - b.addr

  _checkDataBreaks: (nia) ->
    step = @stepCount
    hit = null
    @dataBreaks.forEach (wp, addr) =>
      return unless wp.enabled
      now = @ram.get16(addr, false)
      changed = now != wp.last
      written = @ram.getLastWritten(addr) == step
      old = wp.last
      wp.last = now
      return if hit?
      return unless (if wp.on == 'write' then written else changed)
      hit = {
        addr: addr, name: wp.name ? null, on: wp.on
        old: old, new: now
        at: @location(nia)
        step: @stepCount - 1
      }
    return null unless hit?
    @_dataHit = hit
    name = if hit.name then " (#{hit.name})" else ""
    "data breakpoint: #{hit.addr.asHex(5)}#{name} #{hit.old.asHex(4)} -> #{hit.new.asHex(4)}"

  #
  # Watch list
  #
  setWatch: (addr, size = 2, name = null) ->
    @watches.set(addr, { name: name ? @labelAt(addr) ? addr.asHex(5), size })
    @watchAt(addr)

  clearWatch: (addr) -> @watches.delete(addr)

  clearWatches: () ->
    n = @watches.size
    @watches.clear()
    return n

  watchAt: (addr) ->
    w = @watches.get(addr)
    return null unless w?
    v = { name: w.name, size: w.size, hw: @ram.get16(addr, false) }
    v.fw = @ram.get32(addr, false) >>> 0 if w.size >= 2
    Object.assign(@location(addr), v)

  watchList: () ->
    out = []
    @watches.forEach (w, addr) => out.push(@watchAt(addr))
    out.sort (a, b) -> a.addr - b.addr

  #
  # Instruction trace
  #
  # The ring holds the address and the halfwords as fetched; the mnemonic is
  # produced when the trace is read, so an entry whose memory has since been
  # rewritten still disassembles as what ran.
  #
  setTrace: (enabled, limit = null) ->
    @traceEnabled = !!enabled
    if limit? and limit > 0
      @traceLimit = limit
      @traceRing.shift() while @traceRing.length > @traceLimit
    @traceRing = [] unless @traceEnabled
    { enabled: @traceEnabled, limit: @traceLimit, entries: @traceRing.length }

  traceLog: (count = 50) ->
    for e in @traceRing.slice(-count)
      [d, v] = Instruction.decode(e.hw1, e.hw2)
      len = if d? then d.len else 1
      Object.assign(@location(e.addr), {
        step: e.step, hw1: e.hw1, hw2: (if len > 1 then e.hw2 else null)
        len: len
        text: if d? then Instruction.toStr(e.hw1, e.hw2) else "DC    X'#{e.hw1.asHex(4)}'"
        reloc: @relocAt(e.addr, len)
      })

  clearTrace: () ->
    n = @traceRing.length
    @traceRing = []
    return n

  #
  # Execution
  #
  # Every entry point here settles when the machine stops.  GUIHarness
  # refuses some requests outright -- a step while waiting for input, a run
  # in the wait state without real-time pacing -- and returns without
  # entering the loop, leaving its hooks unfired; _finishExec settles those
  # here, and is guarded so the two paths cannot both report the stop.
  #
  _afterStep: (nia) ->
    # A breakpoint stepped past under its ignore count comes back once
    # the machine has moved off it.
    if @_reenable?
      bp = @breakpoints.get(@_reenable)
      bp.enabled = true if bp?
      @_reenable = null
    next = @gpc.cpu.psw.getNIA()
    @_checkLogpoint(next) if @logpoints.size > 0
    if @breakpoints.size > 0
      bp = @breakpoints.get(next)
      if bp?.enabled and (bp.ignore ? 0) > 0
        bp.ignore--
        bp.hits = (bp.hits ? 0) + 1
        bp.enabled = false
        @_reenable = next
    @discMon.sample() if @discMon.enabled
    if @traceEnabled
      @traceRing.push({
        step: @stepCount - 1, addr: nia
        hw1: @ram.get16(nia, false), hw2: @ram.get16(nia + 1, false)
      })
      @traceRing.shift() while @traceRing.length > @traceLimit
    if @dataBreaks.size > 0
      note = @_checkDataBreaks(nia)
      return note if note?
    if @_stepBudget? and (@stepCount - @_runStartSteps) >= @_stepBudget
      @_budgetHit = true
      return "step budget reached (#{@_stepBudget} instructions)"
    return null

  onRunStart: () ->
    @emit('continued', { location: @location(), steps: @stepCount })

  onRunStop: (note) -> @_finishExec(note)

  _beginExec: (budget, kind = 'continue') ->
    @_execActive = true
    @_execKind = kind
    @_stepBudget = budget
    @_runStartSteps = @stepCount
    @_budgetHit = false
    @_pauseRequested = false
    @_dataHit = null
    @_intStop = null
    @lastError = null
    @statusNote = null
    return new Promise (resolve) => @_stopWaiters.push(resolve)

  _finishExec: (note) ->
    return unless @_execActive
    @_execActive = false
    @_stepBudget = null
    kind = @_execKind
    if @_runToTemp and @_runToAddr?
      @breakpoints.delete(@_runToAddr)
    reachedRunTo = @_runToAddr? and @gpc.cpu.psw.getNIA() == @_runToAddr
    @_runToAddr = null
    @_runToTemp = false
    if @_reenable?
      held = @breakpoints.get(@_reenable)
      held.enabled = true if held?
      @_reenable = null
    @stopReason = @_classifyStop(reachedRunTo)
    @stopDescription = if kind == 'step' and @_budgetHit then null else (note ? @statusNote ? null)
    if @stopReason == 'breakpoint'
      bp = @breakpoints.get(@gpc.cpu.psw.getNIA())
      if bp?
        bp.hits = (bp.hits ? 0) + 1
        @breakpoints.delete(@gpc.cpu.psw.getNIA()) if bp.once
    @discMon.sample() if @discMon.enabled
    body = @stopBody()
    @emit('stopped', body)
    waiters = @_stopWaiters
    @_stopWaiters = []
    w(body) for w in waiters
    return

  _classifyStop: (reachedRunTo) ->
    return 'exception' if @lastError?
    return 'data breakpoint' if @_dataHit?
    return 'input' if @halUCP.waitingForInput
    return 'pause' if @_pauseRequested
    return (if @_execKind == 'step' then 'step' else 'step budget') if @_budgetHit
    return 'interrupt held' if @gpc.cpu.intArmed?
    return 'interrupt' if @_intStop?
    return 'halt' if @gpc.cpu.psw.getWaitState()
    return 'breakpoint' if reachedRunTo
    nia = @gpc.cpu.psw.getNIA()
    return 'breakpoint' if @breakpoints.get(nia)?.enabled
    return 'step'

  stopBody: () ->
    body = {
      reason: @stopReason
      description: @stopDescription
      location: @location()
      steps: @stepCount
      running: @running
      simTimeSec: @simTimeSec()
      waitState: !!@gpc.cpu.psw.getWaitState()
      waitingForInput: !!@halUCP.waitingForInput
    }
    body.dataBreakpoint = @_dataHit if @_dataHit?
    body.interrupt = @_intStop if @_intStop?
    held = @gpc.cpu.heldInterrupt()
    body.heldInterrupt = held if held?
    body.error = @lastError if @lastError?
    body.watches = @watchList() if @watches.size > 0
    return body

  # GUIHarness reports a simulator fault through notify() and stops the run.
  _exec1: (nia) ->
    try
      @gpc.exec1()
      return true
    catch e
      @running = false
      @lastError = { message: e.message, location: @location(nia) }
      @notify("simulator error at #{nia.asHex(5)}: #{e.message}")
      return false

  # `step` with a count of one takes GUIHarness's single-instruction path,
  # which also handles the held-interrupt swap and a wait-state step; a
  # larger count is the run loop under a budget, so breakpoints still apply.
  stepInstr: (count = 1) ->
    return @_refuse('already running') if @running
    if count <= 1
      p = @_beginExec(null)
      super.step()
      @_finishExec(null)
      return p
    p = @_beginExec(count, 'step')
    super.run()
    @_finishExec(null) unless @running
    return p

  # Step over: a temporary breakpoint after the instruction at the NIA.
  stepOver: () ->
    return @_refuse('already running') if @running
    nia = @gpc.cpu.psw.getNIA()
    [d, v] = Instruction.decode(@ram.get16(nia, false), @ram.get16(nia + 1, false))
    len = if d? then d.origLen else 1
    return @runTo(nia + len)

  continueRun: (budget = @maxSteps) ->
    return @_refuse('already running') if @running
    p = @_beginExec(budget)
    super.run()
    @_finishExec(null) unless @running
    return p

  runTo: (addr, budget = @maxSteps) ->
    return @_refuse('already running') if @running
    @_runToTemp = not @breakpoints.has(addr)
    @breakpoints.set(addr, { enabled: true, name: '__runto__', hits: 0, ignore: 0 }) if @_runToTemp
    @_runToAddr = addr
    p = @_beginExec(budget)
    super.run()
    @_finishExec(null) unless @running
    return p

  pause: () ->
    return Promise.resolve(@stopBody()) unless @running
    @_pauseRequested = true
    @stop()
    return new Promise (resolve) => @_stopWaiters.push(resolve)

  _refuse: (why) ->
    body = @stopBody()
    body.refused = why
    Promise.resolve(body)

  # A read that interrupted a run resumes it; one from a stop stays stopped.
  resumeAfterInput: (wasRunning) ->
    return Promise.resolve(@stopBody()) unless wasRunning
    return @continueRun()

  reset: () ->
    @stop() if @running
    @_execActive = false
    @_stopWaiters = []
    @outputLog = []
    @outputDropped = 0
    @lastError = null
    @_dataHit = null
    @_intStop = null
    super()
    @_initIO()
    @dataBreaks.forEach (wp, addr) => wp.last = @ram.get16(addr, false)
    @logpoints.forEach (lp) -> lp.hits = 0
    @breakpoints.forEach (bp) -> bp.hits = 0
    @_reenable = null
    @busMon.start(@busMon.describe()) if @busMon.enabled
    @discMon._snapshot()
    @stopReason = 'entry'
    @stopDescription = null
    @emit('stopped', @stopBody())
    return

  # A progress event per display refresh: one per chunk of a run.
  updateDisplay: () ->
    @emit('running', {
      location: @location()
      steps: @stepCount
      simTimeSec: @simTimeSec()
      speedRatio: @speedRatio
    }) if @running
    return

  updateToolbar: () -> return
