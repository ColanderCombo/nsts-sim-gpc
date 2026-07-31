#
# Real-time pacer for the AP-101 simulator.
#
#   Keeps accumulated simulated CPU time aligned with the wall clock, 
# so the simulator executes at approximately the speed of the real 
# machine. 
#

sleep = (ms) -> new Promise (res) -> setTimeout(res, ms)

export class RTPacer
  constructor: (@cpu, @factor = 1.0, @idleTimeoutMs = 10000) ->
    @wallStart = Date.now()     # pacing baseline (re-based after idle)
    @simStartNs = @cpu.timeNs
    @wallBirth = @wallStart     # fixed start, for reporting

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
    return

  # Wall time spent so far, for reporting.
  wallMs: -> Date.now() - @wallBirth

  # Sit in the wait state at the real-time rate until an interrupt clears
  # it.  Simulated time is advanced in small increments (so counter
  # interrupts fire close to their correct simulated time) with interrupt
  # checks after each.  Returns:
  #   'resumed' - an interrupt woke the CPU
  #   'masked'  - all system interrupts masked; nothing can ever wake it
  #   'timeout' - no wakeup within idleTimeoutMs of wall time
  idleWait: ->
    # Advance is measured from idle ENTRY (not the global pacing baseline):
    # if the host fell behind real time while executing, that deficit must
    # not be dumped into the wait period as a burst of simulated time.
    idleStartWall = Date.now()
    idleStartSim = @cpu.timeNs
    while @cpu.psw.getWaitState()
      if @cpu.psw.getIntMask() == 0 and not @_pendingNonMaskable()
        return 'masked'
      if Date.now() - idleStartWall > @idleTimeoutMs
        return 'timeout'
      await sleep(1)
      # Simulated ns this idle period should have covered so far; catch up
      # in <=1ms sim steps, servicing interrupts as each step lands.
      targetNs = (Date.now() - idleStartWall) * 1e6 * @factor
      while @cpu.psw.getWaitState()
        doneNs = @cpu.timeNs - idleStartSim
        break if doneNs >= targetNs
        @cpu.advanceTimeNs(Math.min(1e6, Math.round(targetNs - doneNs)))
        @cpu.checkInterrupts()
    # Re-baseline so post-wake execution paces at the normal rate:
    @wallStart = Date.now()
    @simStartNs = @cpu.timeNs
    return 'resumed'

  _pendingNonMaskable: ->
    p = @cpu.intPending
    p.machineCheck or p.programCheck or p.svc
