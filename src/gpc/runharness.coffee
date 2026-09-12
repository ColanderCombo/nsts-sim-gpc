import {now as simNow} from '../com/simRuntime.coffee'
import {call, registerExternal, setTimeout, setImmediate} from '../com/simRuntime.coffee'
# AGEHarness with paced execution, interrupt controls, and progress hooks.
import {AGEHarness} from 'gpc/ageharness'
import {RTPacer} from 'gpc/rtpacer'
import {CPU} from 'gpc/cpu'

CHUNK_MS = 200

POLL_STEPS = 64

# Bound chunks so socket callbacks and receive timeouts progress.
CHUNK_SIM_NS = 1000000            # 1 ms of simulated time

PROGRESS_DUTY = 0.2

export class RunHarness extends AGEHarness
  constructor: (opts = {}) ->
    super(opts)
    registerExternal("harness:#{@gpc.id}", @)
    @gpc.runState = {}
    for field in ['running', 'statusNote', 'realTime', 'rtFactor', 'rtIdleTimeoutMs',
                  'pacer', 'idling', 'speedRatio', 'breakOnInterrupt', 'lastInterrupt',
                  '_intBreak', 'heldInReset', 'stallStartWall', 'stepCount', 'halUCP',
                  'breakpoints', 'chunks', 'hotChunks', 'spinTurns', 'barrierTurns',
                  '_lastShown', '_lastShownSim', '_nextShow', '_execActive', '_stepBudget', '_runStartSteps', '_budgetHit',
                  '_pauseRequested', '_execKind', '_intStop', '_runToAddr', '_runToTemp']
      do (field) =>
        Object.defineProperty @gpc.runState, field, {
          enumerable: true, configurable: true,
          get: => @[field]
          set: (value) => @[field] = value
        }
    @running = false
    @statusNote = null # Why the last step/run refused or ended.

    @realTime = false
    @rtFactor = 1.0
    @rtIdleTimeoutMs = 1000
    @pacer = null       # live only running in real-time mode
    @idling = false     # inside a wait-state period of the run loop
    @speedRatio = null  # simulated/wall time over the last progress interval

    @breakOnInterrupt = false
    @lastInterrupt = null
    @_intBreak = null
    @_wireInterruptHook()
    @_wireTraceHook()

  _wireTraceHook: () -> return

  _wireInterruptHook: () ->
    @gpc.cpu.onInterrupt = (entry) =>
      @lastInterrupt = entry
      @_intBreak = entry if @breakOnInterrupt
    return

  setBreakOnInterrupt: (enabled) ->
    @breakOnInterrupt = !!enabled
    return

  setHoldInterrupt: (enabled) ->
    @gpc.cpu.setInterruptHold(enabled)
    return

  Object.defineProperty @prototype, 'holdInterrupt',
    get: -> @gpc.cpu.intHold

  _interruptNote: (entry) ->
    "#{entry.label} taken at 0x#{entry.fromNIA.toString(16).padStart(5, '0')}" +
      " -> 0x#{entry.toNIA.toString(16).padStart(5, '0')}"

  _heldNote: (held) ->
    "#{held.label} held before PSW swap at 0x#{held.fromNIA.toString(16).padStart(5, '0')}" +
      " (step or run to swap to 0x#{held.toNIA.toString(16).padStart(5, '0')})"

  raiseInterrupt: (key) ->
    @statusNote = null
    @gpc.cpu.raiseInterrupt(key)
    unless @running
      @gpc.cpu.checkInterrupts()
      held = @gpc.cpu.heldInterrupt()
      @notify(@_heldNote(held)) if held?
    @onProgress()

  clearInterrupt: (key) ->
    @gpc.cpu.clearInterrupt(key)
    @onProgress()

  toggleInterruptMask: (maskBit) ->
    psw = @gpc.cpu.psw
    if maskBit == 45
      psw.setMachCheckMask(if psw.getMachCheckMask() then 0 else 1)
    else if 32 <= maskBit <= 39
      bit = 1 << (39 - maskBit)
      psw.setIntMask(psw.getIntMask() ^ bit)
    @onProgress()

  loadTimer: (n, value) ->
    @gpc.cpu.loadTimer(n, value)
    @onProgress()

  clearInterruptLog: ->
    @gpc.cpu.intLog = []
    @lastInterrupt = null
    @onProgress()

  systemReset: ->
    @stop() if @running
    @gpc.cpu.systemReset()
    @notify("system reset: PSW loaded from PSA 0x#{CPU.SYSTEM_RESET_PSW.toString(16).padStart(4, '0')}")
    @onProgress()

  configureRunOpts: (opts = {}) ->
    @realTime = !!opts.realTime if opts.realTime?
    @setRTFactor(opts.rtFactor) if opts.rtFactor?
    if opts.rtIdleTimeout?
      t = parseFloat(opts.rtIdleTimeout)
      @rtIdleTimeoutMs = t * 1000 if isFinite(t) and t > 0
    return

  setRealTime: (enabled) ->
    @realTime = !!enabled
    if @running
      if @realTime
        @pacer = @_newPacer()
        @gpc.iop?.joinBarrier?()
      else
        @pacer = null
        @idling = false
        @gpc.iop?.leaveBarrier?()
    return

  setRTFactor: (f) ->
    f = parseFloat(f)
    return unless isFinite(f) and f > 0
    @rtFactor = f
    if @pacer?
      @pacer.factor = f
      @pacer.rebase()
    return

  _newPacer: () ->
    new RTPacer(@gpc.cpu, @rtFactor, @rtIdleTimeoutMs)

  simTimeSec: () -> @gpc.cpu.timeNs / 1e9

  _idleNote: (why) ->
    if why == 'masked'
      "wait state with every system interrupt masked: nothing can wake the CPU"
    else
      "wait state: no interrupt within #{(@rtIdleTimeoutMs / 1000)}s of real time"

  notify: (msg) ->
    @statusNote = msg
    console.log("RunHarness: #{msg}")

  _waitNote: (verb) ->
    "#{verb}: CPU in wait state (clear PSW2 wait bit 0x00020000, or Reset)"

  step: () ->
    return if @running
    if @halUCP.waitingForInput
      @notify("step refused: waiting for terminal input")
      @onProgress()
      return
    return @stepSwap() if @gpc.cpu.intArmed?
    if @gpc.cpu.psw.getWaitState()
      return @stepIdle()
    nia = @gpc.cpu.psw.getNIA()
    if @halUCP.active and @halUCP.isTrapAddr(nia)
      return if @halUCP.checkTrap(nia) == 'block'
    @statusNote = null
    @stepCount++
    @_syncStep()
    @_beforeStep(nia)
    intsBefore = @gpc.cpu.intCount
    if @_exec1(nia)
      @notify(@_interruptNote(@lastInterrupt)) if @gpc.cpu.intCount > intsBefore
      held = @gpc.cpu.heldInterrupt()
      @notify(@_heldNote(held)) if held?
      stop = @_afterStep(nia)
      @notify(stop) if stop?
    @_intBreak = null
    @onProgress()

  stepSwap: () ->
    @statusNote = null
    entry = @gpc.cpu.releaseInterrupt()
    @_intBreak = null
    if entry?
      @notify(@_interruptNote(entry))
    else
      @notify("held interrupt no longer pending: nothing taken")
    @onProgress()

  _exec1: (nia) ->
    try
      @gpc.exec1()
      return true
    catch e
      @running = false
      @notify("simulator error at 0x#{nia.toString(16).padStart(5, '0')}: #{e.message}")
      console.error(e)
      return false


  stepIdle: (maxSimSec = 1.0) ->
    # Advance paced wait-state time so a pending timer can wake the CPU.
    if not @realTime
      @notify(@_waitNote("step refused"))
      @onProgress()
      return
    cpu = @gpc.cpu
    if not cpu.canWake()
      @notify(@_idleNote('masked'))
      @onProgress()
      return
    @statusNote = null
    t0 = cpu.timeNs
    cpu.advanceIdleNs(maxSimSec * 1e9)
    held = cpu.heldInterrupt()
    if held?
      @notify(@_heldNote(held))
    else if cpu.psw.getWaitState()
      @notify("wait state: no interrupt in the next #{maxSimSec}s of simulated time")
    else
      woke = if @lastInterrupt? then "#{@lastInterrupt.label} after" else "woke after"
      @notify("wait state: #{woke} #{((cpu.timeNs - t0) / 1e6).toFixed(3)} ms of simulated time")
    @onProgress()

  run: () ->
    return if @running
    # Complete a held swap before testing the wait state it may clear.
    @gpc.cpu.releaseInterrupt() if @gpc.cpu.intArmed?
    if @gpc.cpu.psw.getWaitState() and not @realTime
      @notify(@_waitNote("run refused"))
      @onProgress()
      return
    @running = true
    @statusNote = null
    @idling = false
    @heldInReset = false
    @_intBreak = null
    @pacer = if @realTime then @_newPacer() else null
    # An unpaced machine must not constrain paced barrier partners.
    if @pacer? then @gpc.iop?.joinBarrier?() else @gpc.iop?.leaveBarrier?()
    @stallStartWall = null
    @onRunStart()

    @_lastShown = simNow()
    @_lastShownSim = @gpc.cpu.timeNs
    @_nextShow = 0
    @_runTick()

  _runFinish: (note) ->
    @running = false
    @idling = false
    @pacer = null
    @gpc.iop?.leaveBarrier?()
    @notify(note) if note?
    @onRunStop(note ? null)
    @onProgress()

  _runShow: () ->
    now = simNow()
    dtWall = now - @_lastShown
    return unless dtWall >= CHUNK_MS and now >= @_nextShow
    @speedRatio = ((@gpc.cpu.timeNs - @_lastShownSim) / 1e6) / dtWall
    @_lastShown = now
    @_lastShownSim = @gpc.cpu.timeNs
    @onProgress()
    cost = simNow() - now
    @_nextShow = simNow() + Math.round(cost * (1 - PROGRESS_DUTY) / PROGRESS_DUTY)

  # setImmediate avoids the millisecond clamp while still polling sockets.
  _runResume: (delay) ->
    if delay > 0 then setTimeout(call(@, '_runTick'), delay) else setImmediate(call(@, '_runTick'))

  _runSpin: () ->
    @gpc.cpu.ioTurns = (@gpc.cpu.ioTurns ? 0) + 1
    @spinTurns = (@spinTurns ? 0) + 1
    return @_runTick() unless @running and @pacer?
    if @pacer.aheadMs() > 0.05 then setImmediate(call(@, '_runSpin')) else @_runTick()

  _runTick: () ->
    @gpc.cpu.ioTurns = (@gpc.cpu.ioTurns ? 0) + 1
    return @_runFinish() unless @running
    return @_runFinish() if @halUCP.waitingForInput

    # Hold simulated time while an owed bus reply crosses the event loop.
    if @pacer?
      if @pacer.replyOwed()
        unless @stallStartWall?
          @stallStartWall = simNow()
        return @_runResume(0)
      if @stallStartWall?
        @pacer.stalls += 1
        @pacer.stallMs += simNow() - @stallStartWall
        @stallStartWall = null
    @gpc.iop?.ioTurnTaken?(@gpc.cpu.timeNs)

    # HALT freezes simulated time and temporarily releases the barrier.
    if @gpc.cpu.resetHeld
      return @_runFinish("CPU held in system reset after #{@stepCount} instructions") unless @pacer?
      @heldInReset = true
      @gpc.iop?.leaveBarrier?()
      @_runShow()
      return @_runResume(CHUNK_MS)
    if @heldInReset
      @heldInReset = false
      @pacer.rebase()
      @gpc.iop?.joinBarrier?()

    if @gpc.iop?.barrierStep?()
      @barrierTurns = (@barrierTurns ? 0) + 1
      return @_runResume(0)

    # Paced wait-state time advances until an interrupt wakes the CPU.
    if @gpc.cpu.psw.getWaitState()
      return @_runFinish("CPU entered wait state after #{@stepCount} instructions") unless @pacer?
      if not @idling
        @idling = true
        @pacer.enterIdle()
      why = @pacer.advanceIdle()
      if why == 'waiting'
        @_runShow()
        return @_runResume(if @pacer.aheadMs() > 0 then 1 else 0)
      @idling = false
      if why == 'held'
        return @_runFinish(@_heldNote(@gpc.cpu.heldInterrupt()))
      return @_runFinish(@_idleNote(why)) unless why == 'resumed'
      if @_intBreak?
        entry = @_intBreak
        @_intBreak = null
        return @_runFinish(@_interruptNote(entry))

    deadline = simNow() + CHUNK_MS
    simDeadlineNs = @gpc.cpu.timeNs + CHUNK_SIM_NS
    n = 0
    loop
      nia = @gpc.cpu.psw.getNIA()
      if @halUCP.active and @halUCP.isTrapAddr(nia)
        if @halUCP.checkTrap(nia) == 'block'
          @halUCP.wasRunning = true
          return @_runFinish()

      @stepCount++
      @_syncStep()
      @_beforeStep(nia)
      return @_runFinish() unless @_exec1(nia)

      stop = @_afterStep(nia)
      return @_runFinish(stop) if stop?

      # Run or Step completes a held PSW swap.
      if @gpc.cpu.intArmed?
        return @_runFinish(@_heldNote(@gpc.cpu.heldInterrupt()))

      if @_intBreak?
        entry = @_intBreak
        @_intBreak = null
        return @_runFinish(@_interruptNote(entry))

      bpAddr = @gpc.cpu.psw.getNIA()
      if @breakpoints.get(bpAddr)?.enabled
        return @_runFinish("breakpoint at 0x#{bpAddr.toString(16).padStart(5, '0')}")

      break if @gpc.cpu.psw.getWaitState() or @halUCP.waitingForInput

      n++
      break if @pacer?.replyOwed()
      break if @gpc.iop?.ioTurnWanted
      if n % POLL_STEPS == 0
        break if @pacer.aheadMs() > 1 if @pacer?
        break if @gpc.cpu.timeNs >= simDeadlineNs
        break if simNow() >= deadline

    @_runShow()

    @chunks = (@chunks ? 0) + 1
    @hotChunks = (@hotChunks ? 0) + 1 if @gpc.iop?.ioTurnWanted
    delay = 0
    if @pacer?
      ahead = Math.round(@pacer.aheadMs())
      delay = Math.min(CHUNK_MS, ahead) if ahead > 0
      @pacer.noteLag(-ahead, @gpc.iop?.isSearching?() ? false) if ahead < 0
      return @_runSpin() if delay > 0 and @gpc.iop?.isHot?()
    @_runResume(delay)



  stop: () ->
    @running = false
    @idling = false
    @pacer = null
    @gpc.iop?.leaveBarrier?()
    @onProgress()

  reset: () ->
    @running = false
    @idling = false
    @pacer = null
    @gpc.iop?.leaveBarrier?()
    @statusNote = null
    super() # reconfig from opts
    @onProgress()

  # A string from `_afterStep` stops execution and becomes its note.
  _beforeStep: (nia) -> null

  _afterStep: (nia) -> null
  onProgress: () ->
  onRunStart: () ->
  onRunStop: (note) ->
