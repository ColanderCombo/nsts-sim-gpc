
# GUIHarness: AGEHarness plus the GUI run-loop and display hooks
#
import {AGEHarness} from 'gpc/ageharness'
import {RTPacer} from 'gpc/rtpacer'
import {CPU} from 'gpc/cpu'

CHUNK_MS = 200

# Instructions between wall-clock/pacing checks inside a chunk:
POLL_STEPS = 64

# The most simulated time one chunk may cover before the event loop is given
# a turn.
#
# CHUNK_MS bounds a chunk in wall time, and in real-time mode a chunk also
# ends once simulated time has run ahead of the wall clock.  Neither bounds a
# machine that is behind: aheadMs() is negative, so the loop runs flat out to
# the wall deadline, a fifth of a second of straight-line execution with no
# turn of the event loop.
#
# Nothing reaches a socket in that time, and a bus transaction's time out is
# spent in simulated time: a display unit's poll allows 303 counts (5.0 ms),
# so a receive beginning inside such a chunk error-terminates with its reply
# still unread in the host's socket.  Hence a simulated-time budget as well,
# well under the shortest time out flight software loads.
CHUNK_SIM_NS = 1000000            # 1 ms of simulated time

# The share of wall time the GUI refresh is allowed while the machine runs.
REFRESH_DUTY = 0.2

export class GUIHarness extends AGEHarness
  constructor: (opts = {}) ->
    super(opts)
    @running = false
    @disasmViewAddr = null
    @breakOnInput = false
    @selectedSection = null # Highlight state for memory/sections/watch 
                            # components
    @selectedWatch = null
    @watchAddresses = null
    @statusNote = null # Why the last step/run refused or ended.

    @realTime = false
    @rtFactor = 1.0
    @rtIdleTimeoutMs = 1000
    @pacer = null       # live only running in real-time mode
    @idling = false     # inside a wait-state period of the run loop
    @speedRatio = null  # simulated/wall time over the last refresh interval

    # Interrupts: break the run when one is accepted, and keep the most
    # recent acceptance for the display:
    @breakOnInterrupt = false
    @lastInterrupt = null
    @_intBreak = null
    @_wireInterruptHook()

  _wireInterruptHook: () ->
    @gpc.cpu.onInterrupt = (entry) =>
      @lastInterrupt = entry
      @_intBreak = entry if @breakOnInterrupt
    return

  setBreakOnInterrupt: (enabled) ->
    @breakOnInterrupt = !!enabled
    @updateToolbar()

  setHoldInterrupt: (enabled) ->
    @gpc.cpu.setInterruptHold(enabled)
    @updateToolbar()

  Object.defineProperty @prototype, 'holdInterrupt',
    get: -> @gpc.cpu.intHold

  _interruptNote: (entry) ->
    "#{entry.label} taken at 0x#{entry.fromNIA.toString(16).padStart(5, '0')}" +
      " -> 0x#{entry.toNIA.toString(16).padStart(5, '0')}"

  _heldNote: (held) ->
    "#{held.label} held before PSW swap at 0x#{held.fromNIA.toString(16).padStart(5, '0')}" +
      " (step or run to swap to 0x#{held.toNIA.toString(16).padStart(5, '0')})"

  #
  # Interrupt and interval-timer controls
  #
  raiseInterrupt: (key) ->
    @statusNote = null
    @gpc.cpu.raiseInterrupt(key)
    unless @running
      # Not running?  Nothing will look at the pending flag until the next
      # instruction, so service it now 
      @gpc.cpu.checkInterrupts()
      held = @gpc.cpu.heldInterrupt()
      @notify(@_heldNote(held)) if held?
    @updateDisplay()

  clearInterrupt: (key) ->
    @gpc.cpu.clearInterrupt(key)
    @updateDisplay()

  toggleInterruptMask: (maskBit) ->
    psw = @gpc.cpu.psw
    if maskBit == 45
      psw.setMachCheckMask(if psw.getMachCheckMask() then 0 else 1)
    else if 32 <= maskBit <= 39
      bit = 1 << (39 - maskBit)
      psw.setIntMask(psw.getIntMask() ^ bit)
    @updateDisplay()

  loadTimer: (n, value) ->
    @gpc.cpu.loadTimer(n, value)
    @updateDisplay()

  clearInterruptLog: ->
    @gpc.cpu.intLog = []
    @lastInterrupt = null
    @updateDisplay()

  systemReset: ->
    @stop() if @running
    @gpc.cpu.systemReset()
    @notify("system reset: PSW loaded from PSA 0x#{CPU.SYSTEM_RESET_PSW.toString(16).padStart(4, '0')}")
    @disasmViewAddr = null
    @updateDisplay()

  configureRunOpts: (opts = {}) ->
    @realTime = !!opts.realTime if opts.realTime?
    @setRTFactor(opts.rtFactor) if opts.rtFactor?
    if opts.rtIdleTimeout?
      t = parseFloat(opts.rtIdleTimeout)
      @rtIdleTimeoutMs = t * 1000 if isFinite(t) and t > 0
    return

  #
  # Real-time controls
  #
  setRealTime: (enabled) ->
    @realTime = !!enabled
    if @running
      if @realTime
        @pacer = @_newPacer()
      else
        @pacer = null
        @idling = false
    @updateToolbar()

  setRTFactor: (f) ->
    f = parseFloat(f)
    return unless isFinite(f) and f > 0
    @rtFactor = f
    if @pacer?
      @pacer.factor = f
      @pacer.rebase()
    @updateToolbar()

  _newPacer: () ->
    new RTPacer(@gpc.cpu, @rtFactor, @rtIdleTimeoutMs)

  # Simulated CPU time since power-on, in seconds.
  simTimeSec: () -> @gpc.cpu.timeNs / 1e9

  _idleNote: (why) ->
    if why == 'masked'
      "wait state with every system interrupt masked: nothing can wake the CPU"
    else
      "wait state: no interrupt within #{(@rtIdleTimeoutMs / 1000)}s of real time"

  notify: (msg) ->
    @statusNote = msg
    console.log("GUIHarness: #{msg}")

  _waitNote: (verb) ->
    "#{verb}: CPU in wait state (clear PSW2 wait bit 0x00020000, or Reset)"

  #
  # Execution
  #
  step: () ->
    return if @running
    if @halUCP.waitingForInput
      @notify("step refused: waiting for terminal input")
      @updateDisplay()
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
    intsBefore = @gpc.cpu.intCount
    if @_exec1(nia)
      @notify(@_interruptNote(@lastInterrupt)) if @gpc.cpu.intCount > intsBefore
      held = @gpc.cpu.heldInterrupt()
      @notify(@_heldNote(held)) if held?
    @_intBreak = null
    @disasmViewAddr = null  # auto-follow NIA after step
    @updateDisplay()

  # Take a held interrupt and stop again, at the handler's first
  # instruction:
  stepSwap: () ->
    @statusNote = null
    entry = @gpc.cpu.releaseInterrupt()
    @_intBreak = null
    if entry?
      @notify(@_interruptNote(entry))
    else
      # the latch was cleared or masked off while the machine \
      # sat in front of the swap:
      @notify("held interrupt no longer pending: nothing taken")
    @disasmViewAddr = null   # auto-follow NIA into the handler
    @updateDisplay()

  # Execute one instruction,:
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
    # A step in the wait state has no instruction to execute: the machine is
    # sitting there until an interrupt arrives.  Real time still runs there,
    # so step simulated time forward instead to the moment the next
    # interrupt lands.
    if not @realTime
      @notify(@_waitNote("step refused"))
      @updateDisplay()
      return
    cpu = @gpc.cpu
    if not cpu.canWake()
      @notify(@_idleNote('masked'))
      @updateDisplay()
      return
    @statusNote = null
    t0 = cpu.timeNs
    cpu.advanceIdleNs(maxSimSec * 1e9)
    held = cpu.heldInterrupt()
    if held?
      # The wakeup arrived and is being held in front of its swap: the
      # wait bit only clears when the swap happens.
      @notify(@_heldNote(held))
    else if cpu.psw.getWaitState()
      @notify("wait state: no interrupt in the next #{maxSimSec}s of simulated time")
    else
      woke = if @lastInterrupt? then "#{@lastInterrupt.label} after" else "woke after"
      @notify("wait state: #{woke} #{((cpu.timeNs - t0) / 1e6).toFixed(3)} ms of simulated time")
    @disasmViewAddr = null   # auto-follow NIA to the interrupt handler
    @updateDisplay()

  run: () ->
    # Execute chunks of instructions, refreshing the gui between chunks.  A
    # chunk is CHUNK_MS of wall time; in real-time mode it ends early once
    # simulated time has run ahead of the wall clock, and the sleep before
    # the next one is what holds the machine to AP-101 speed.
    return if @running
    # Resuming from a stop-before-swap: take the held interrupt first and
    # carry on into the handler.  It comes before the wait-state test
    # because the swap is also what clears the wait bit when the hold
    # caught the interrupt that ended an idle period.
    @gpc.cpu.releaseInterrupt() if @gpc.cpu.intArmed?
    if @gpc.cpu.psw.getWaitState() and not @realTime
      @notify(@_waitNote("run refused"))
      @updateDisplay()
      return
    @running = true
    @statusNote = null
    @disasmViewAddr = null
    @idling = false
    @_intBreak = null
    @pacer = if @realTime then @_newPacer() else null
    @updateToolbar()

    lastShown = Date.now()
    lastShownSim = @gpc.cpu.timeNs

    finish = (note) =>
      @running = false
      @idling = false
      @pacer = null
      @notify(note) if note?
      @updateDisplay()

    # Refresh no more often than one chunk
    nextShow = 0
    show = () =>
      now = Date.now()
      dtWall = now - lastShown
      return unless dtWall >= CHUNK_MS and now >= nextShow
      @speedRatio = ((@gpc.cpu.timeNs - lastShownSim) / 1e6) / dtWall
      lastShown = now
      lastShownSim = @gpc.cpu.timeNs
      @updateDisplay()
      # See REFRESH_DUTY.
      cost = Date.now() - now
      nextShow = Date.now() + Math.round(cost * (1 - REFRESH_DUTY) / REFRESH_DUTY)

    # setTimeout(0) is clamped to a millisecond, which would hold the
    # machine to real time and stop it ever making back a lost chunk;
    # setImmediate turns the loop for a fraction of that.  Either way the
    # poll phase runs first, so a reply at the socket is taken before the
    # next chunk.
    resume = (delay) => if delay > 0 then setTimeout(tick, delay) else setImmediate(tick)

    tick = () =>
      @gpc.cpu.ioTurns = (@gpc.cpu.ioTurns ? 0) + 1
      return finish() unless @running
      return finish() if @halUCP.waitingForInput

      # Wait state: with real-time pacing, simulated time keeps running
      # here (in <=1ms steps, interrupts serviced as they land) until one
      # wakes the CPU.
      if @gpc.cpu.psw.getWaitState()
        return finish("CPU entered wait state after #{@stepCount} instructions") unless @pacer?
        if not @idling
          @idling = true
          @pacer.enterIdle()
        why = @pacer.advanceIdle()
        if why == 'waiting'
          show()
          # Behind the wall clock: come straight back so the capped lumps
          # above can make the time back.  A millisecond of setTimeout per
          # millisecond of simulated time would hold the wait state below
          # real time and it would never catch up.
          return resume(if @pacer.aheadMs() > 0 then 1 else 0)
        @idling = false
        if why == 'held'
          return finish(@_heldNote(@gpc.cpu.heldInterrupt()))
        return finish(@_idleNote(why)) unless why == 'resumed'
        if @_intBreak?
          entry = @_intBreak
          @_intBreak = null
          return finish(@_interruptNote(entry))

      deadline = Date.now() + CHUNK_MS
      simDeadlineNs = @gpc.cpu.timeNs + CHUNK_SIM_NS
      n = 0
      loop
        nia = @gpc.cpu.psw.getNIA()
        if @halUCP.active and @halUCP.isTrapAddr(nia)
          if @halUCP.checkTrap(nia) == 'block'
            @halUCP.wasRunning = true
            return finish()

        @stepCount++
        @_syncStep()
        return finish() unless @_exec1(nia)

        # Stop-before-swap: this instruction's interrupt is decided but not
        # taken, and the machine is still standing on the interrupted
        # program.  Resuming (Run or Step) completes the swap.
        if @gpc.cpu.intArmed?
          return finish(@_heldNote(@gpc.cpu.heldInterrupt()))

        if @halUCP.svcTrapped
          @halUCP.svcTrapped = false
          return finish()

        # Break on an accepted interrupt (armed from the interrupt pane):
        # the hook records it and the run stops at the handler's first
        # instruction.
        if @_intBreak?
          entry = @_intBreak
          @_intBreak = null
          return finish(@_interruptNote(entry))
          
        bpAddr = @gpc.cpu.psw.getNIA()
        if @breakpoints.get(bpAddr)?.enabled
          return finish("breakpoint at 0x#{bpAddr.toString(16).padStart(5, '0')}")

        # Hand the wait state and terminal input back to the top of tick().
        break if @gpc.cpu.psw.getWaitState() or @halUCP.waitingForInput

        n++
        if n % POLL_STEPS == 0
          break if @pacer? and @pacer.aheadMs() > 1
          break if @gpc.cpu.timeNs >= simDeadlineNs
          break if Date.now() >= deadline

      show()

      delay = 0
      if @pacer?
        ahead = Math.round(@pacer.aheadMs())
        delay = Math.min(CHUNK_MS, ahead) if ahead > 0
      resume(delay)

    tick()

  stop: () ->
    @running = false
    @idling = false
    @pacer = null
    @updateDisplay()

  reset: () ->
    @running = false
    @idling = false
    @pacer = null
    @statusNote = null
    super() # reconfig from opts
    @updateDisplay()

  # 
  # Breakpoints
  # 
  toggleBreakpoint: (addr) ->
    if @breakpoints.has(addr)
      bp = @breakpoints.get(addr)
      bp.enabled = not bp.enabled
    else
      @breakpoints.set(addr, { enabled: true })
    @saveBreakpoints()
    @updateDisplay()

  deleteBreakpoint: (addr) ->
    @breakpoints.delete(addr)
    @saveBreakpoints()
    @updateDisplay()

  enableBreakpoint: (addr) ->
    bp = @breakpoints.get(addr)
    if bp then bp.enabled = true
    @saveBreakpoints()
    @updateDisplay()

  disableBreakpoint: (addr) ->
    bp = @breakpoints.get(addr)
    if bp then bp.enabled = false
    @saveBreakpoints()
    @updateDisplay()

  # 
  # Update hooks
  #
  updateDisplay: () ->
  updateToolbar: () ->
