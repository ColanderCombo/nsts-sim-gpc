import {registerType, setTimeout, setImmediate, now as simNow} from '../com/simRuntime.coffee'
# Keeps simulated CPU time aligned with the wall clock.

sleep = (ms) -> new Promise (res) -> setTimeout(res, ms)

# setImmediate services polled sockets without the timer clamp.
yieldToIO = -> new Promise (res) -> setImmediate(res)

# Maximum simulated time advanced without servicing I/O.
export IDLE_CATCHUP_MAX_NS = 1000000     # 1 ms of simulated time

# Maximum wall-time hold while an active bus owes a reply; 0 disables it.
export STALL_MAX_MS = do ->
  v = process?.env?.NSTS_BUS_STALL_MAX_MS
  if v? then Math.max(0, parseFloat(v)) else 20

# Lag beyond this limit resets the pacing baseline.
export BEHIND_MAX_MS = 50

export class RTPacer
  constructor: (@cpu, @factor = 1.0, @idleTimeoutMs = 10000) ->
    @wallStart = simNow()
    @simStartNs = @cpu.timeNs
    @wallBirth = @wallStart
    @lastCapped = false
    @iop = @cpu.iop ? null
    @stalls = 0
    @stallMs = 0
    @behindMaxMs = 0
    @lagsGivenUp = 0
    @lagGivenUpMs = 0
    @reportWall = @wallStart
    @reportSimNs = @simStartNs

  noteLag: (behindMs, giveUp = false) ->
    @behindMaxMs = behindMs if behindMs > @behindMaxMs
    if giveUp or behindMs > BEHIND_MAX_MS
      @lagsGivenUp += 1
      @lagGivenUpMs += behindMs
      @rebase()
    return

  # Reset interval statistics after reporting them.
  lagReport: ->
    wallMs = simNow() - @reportWall
    simMs = (@cpu.timeNs - @reportSimNs) / 1e6 / @factor
    r = { behindNowMs: -@aheadMs(), behindMaxMs: @behindMaxMs,
          lagsGivenUp: @lagsGivenUp, lagGivenUpMs: @lagGivenUpMs,
          stalls: @stalls, stallMs: @stallMs,
          rate: (if wallMs > 0 then simMs / wallMs else null), sinceMs: wallMs }
    @behindMaxMs = 0
    @reportWall = simNow()
    @reportSimNs = @cpu.timeNs
    r

  replyOwed: ->
    return false unless STALL_MAX_MS > 0 and @iop?
    since = @iop.replyOwedSince()
    since? and (simNow() - since) < STALL_MAX_MS

  # Service I/O without advancing simulated time while a reply is owed.
  stallForReply: ->
    return false unless @replyOwed()
    t0 = simNow()
    while @replyOwed()
      await yieldToIO()
      @cpu.ioTurns = (@cpu.ioTurns ? 0) + 1
    @stalls += 1
    @stallMs += simNow() - t0
    @rebase()
    true

  # Service I/O without advancing simulated time while the barrier holds.
  barrierHold: ->
    return false unless @iop?.barrierStep?()
    while @iop.barrierStep()
      await yieldToIO()
      @cpu.ioTurns = (@cpu.ioTurns ? 0) + 1
    true

  aheadMs: ->
    simMs = (@cpu.timeNs - @simStartNs) / 1e6 / @factor
    simMs - (simNow() - @wallStart)

  pace: ->
    await @barrierHold()
    ahead = @aheadMs()
    if ahead > 2
      await sleep(ahead)
    else
      @noteLag(-ahead) if ahead < 0
      await yieldToIO()
    @cpu.ioTurns = (@cpu.ioTurns ? 0) + 1
    return

  wallMs: -> simNow() - @wallBirth

  rebase: ->
    @wallStart = simNow()
    @simStartNs = @cpu.timeNs
    return

  enterIdle: ->
    @idleStartWall = simNow()
    # Idle timeout uses the fixed entry time across pacing rebases.
    @idleEnteredWall = @idleStartWall
    @idleStartSim = @cpu.timeNs
    return

  # Returns:
  #   'resumed' - an interrupt woke the CPU (pacing re-baselined)
  #   'held'    - an interrupt is held pre-swap (stop-before-swap armed);
  #               the wait state ends when the caller releases it
  #   'masked'  - all system interrupts masked; nothing can ever wake it
  #   'timeout' - no wakeup within idleTimeoutMs of wall time
  #   'waiting' - still in the wait state; call again
  advanceIdle: ->
    if @cpu.psw.getWaitState()
      return 'masked' unless @cpu.canWake()
      if @replyOwed()
        @idleStartWall = simNow()
        @idleStartSim = @cpu.timeNs
        @lastCapped = true
        return 'waiting'
      targetNs = (simNow() - @idleStartWall) * 1e6 * @factor
      owedNs = targetNs - (@cpu.timeNs - @idleStartSim)
      capped = owedNs > IDLE_CATCHUP_MAX_NS
      owedNs = IDLE_CATCHUP_MAX_NS if capped
      @lastCapped = capped
      @cpu.advanceIdleNs(owedNs)
      if capped
        @idleStartWall = simNow()
        @idleStartSim = @cpu.timeNs
    return 'held' if @cpu.intArmed?
    if not @cpu.psw.getWaitState()
      @rebase()          # post-wake execution paces at the normal rate
      return 'resumed'
    return if simNow() - (@idleEnteredWall ? @idleStartWall) > @idleTimeoutMs then 'timeout' else 'waiting'

  # Blocking form of advanceIdle().
  idleWait: ->
    @enterIdle()
    loop
      await @barrierHold()
      why = @advanceIdle()
      return why unless why == 'waiting'
      # Avoid the timer clamp while catching up.
      if @lastCapped then await yieldToIO() else await sleep(1)
      @cpu.ioTurns = (@cpu.ioTurns ? 0) + 1

registerType(RTPacer)
