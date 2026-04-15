
# GUIHarness — AGEHarness + GUI run-loop and display hooks
#
import {AGEHarness} from 'gpc/ageharness'

export class GUIHarness extends AGEHarness
  constructor: (opts = {}) ->
    super(opts)
    @running = false
    @disasmViewAddr = null
    @breakOnInput = false
    # Highlight state for memory/sections/watch components
    @selectedSection = null
    @selectedWatch = null
    @watchAddresses = null

  #
  # Execution
  #
  step: () ->
    return if @running
    return if @halUCP.waitingForInput
    if @gpc.cpu.psw.getWaitState()
      console.log("GUIHarness: CPU is in wait state")
      return
    nia = @gpc.cpu.psw.getNIA()
    if @halUCP.active and @halUCP.isTrapAddr(nia)
      return if @halUCP.checkTrap(nia) == 'block'
    @stepCount++
    @_syncStep()
    @gpc.exec1()
    @disasmViewAddr = null  # auto-follow NIA after step
    @updateDisplay()

  run: () ->
    # Execute batches of instructions, refresh gui between batches
    return if @running
    @running = true
    @disasmViewAddr = null
    @updateToolbar()
    batchSize = 100
    stepsInBatch = 0

    finish = =>
      @running = false
      @updateDisplay()

    tick = () =>
      return finish() unless @running
      if @halUCP.waitingForInput
        return finish()
      if @gpc.cpu.psw.getWaitState()
        console.log("GUIHarness: CPU entered wait state after #{@stepCount} instructions")
        return finish()

      nia = @gpc.cpu.psw.getNIA()
      if @halUCP.active and @halUCP.isTrapAddr(nia)
        if @halUCP.checkTrap(nia) == 'block'
          @halUCP.wasRunning = true
          return finish()

      @stepCount++
      @_syncStep()
      @gpc.exec1()

      if @halUCP.svcTrapped
        @halUCP.svcTrapped = false
        return finish()

      if @breakpoints.get(@gpc.cpu.psw.getNIA())?.enabled
        return finish()

      stepsInBatch++
      if stepsInBatch >= batchSize
        stepsInBatch = 0
        @updateDisplay()
        setTimeout(tick, 0)
      else
        tick()

    tick()

  stop: () ->
    @running = false
    @updateDisplay()

  reset: () ->
    @running = false
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
