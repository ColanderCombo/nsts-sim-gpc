#
# Real-time pacer for the AP-101 simulator.
#
#   Keeps accumulated simulated CPU time aligned with the wall clock, 
# so the simulator executes at approximately the speed of the real 
# machine. 
#

sleep = (ms) -> new Promise (res) -> setTimeout(res, ms)

# Give Node's event loop a turn without waiting for a timer.  setImmediate
# fires in the check phase, which follows the poll phase, so every datagram
# already at the socket has been delivered by the time this resolves.  A
# setTimeout of 0 would do the same but is clamped to a millisecond, capping
# the simulator at a thousand chunks a second.
yieldToIO = -> new Promise (res) -> setImmediate(res)

# The most simulated time one advanceIdle call will carry the wait state
# forward by.
#
# The wait state is paced by converting elapsed wall time into simulated
# time, so whatever the host was doing between calls comes back as a
# lump advanced in a single call, with no turn of the event loop inside
# it.  Nothing reaches a socket while that runs, and a receive time out is
# measured in the simulated time it just burned: an 85 ms refresh at factor
# 0.35 lands 30 ms of simulated time at once, past the 20 ms floor a bus
# receive gets, so a reply already at the socket arrives to a transaction
# that has been error-terminated.
#
# Stays below the shortest time out a bus transaction runs under, as
# GUIHarness bounds a chunk in simulated time: the lump is advanced in one
# call, no datagram is delivered inside it, and a receive's time out is spent
# in simulated time.  A display unit's poll allows 5.0 ms, which one 5 ms
# lump would spend entirely.
export IDLE_CATCHUP_MAX_NS = 1000000     # 1 ms of simulated time

export class RTPacer
  constructor: (@cpu, @factor = 1.0, @idleTimeoutMs = 10000) ->
    @wallStart = Date.now()     # pacing baseline (re-based after idle)
    @simStartNs = @cpu.timeNs
    @wallBirth = @wallStart     # fixed start, for reporting
    @lastCapped = false

  # Milliseconds of wall time the simulation is ahead of the wall clock
  # (negative when the simulation is behind).
  aheadMs: ->
    simMs = (@cpu.timeNs - @simStartNs) / 1e6 / @factor
    simMs - (Date.now() - @wallStart)

  # Called between instruction chunks: sleep off any lead over real time.
  pace: ->
    ahead = @aheadMs()
    if ahead > 2
      await sleep(ahead)
    else
      await yieldToIO()
    @cpu.ioTurns = (@cpu.ioTurns ? 0) + 1
    return

  # Wall time spent so far, for reporting.
  wallMs: -> Date.now() - @wallBirth
 
  rebase: ->
    @wallStart = Date.now()
    @simStartNs = @cpu.timeNs
    return

  enterIdle: ->
    @idleStartWall = Date.now()
    # The pacing baseline above is re-taken whenever a slice is capped, so
    # it cannot also time the wait state: with a cap short enough to matter
    # nearly every slice caps, and an idle time out measured from it would
    # never expire.  This one is taken once and left alone.
    @idleEnteredWall = @idleStartWall
    @idleStartSim = @cpu.timeNs
    return

  # Carry the wait state forward to the wall clock: advance simulated time
  # to cover the wall time elapsed since enterIdle(), servicing interrupts
  # as each step lands.  
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
      targetNs = (Date.now() - @idleStartWall) * 1e6 * @factor
      owedNs = targetNs - (@cpu.timeNs - @idleStartSim)
      capped = owedNs > IDLE_CATCHUP_MAX_NS
      owedNs = IDLE_CATCHUP_MAX_NS if capped
      @lastCapped = capped
      @cpu.advanceIdleNs(owedNs)
      if capped
        @idleStartWall = Date.now()
        @idleStartSim = @cpu.timeNs
    return 'held' if @cpu.intArmed?
    if not @cpu.psw.getWaitState()
      @rebase()          # post-wake execution paces at the normal rate
      return 'resumed'
    return if Date.now() - (@idleEnteredWall ? @idleStartWall) > @idleTimeoutMs then 'timeout' else 'waiting'

  # Sit in the wait state at the real-time rate until an interrupt clears
  # it.  Blocking form of advanceIdle(), for the batch/CLI runners
  idleWait: ->
    @enterIdle()
    loop
      why = @advanceIdle()
      return why unless why == 'waiting'
      # Behind the wall clock: come straight back round.  A millisecond of
      # setTimeout per capped slice would hold the wait state below real
      # time and it could never make the lost time back -- the same reason
      # GUIHarness resumes with no delay while it is behind.
      if @lastCapped then await yieldToIO() else await sleep(1)
      @cpu.ioTurns = (@cpu.ioTurns ? 0) + 1
