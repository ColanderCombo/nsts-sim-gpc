fs = require 'fs'
path = require 'path'
import {LRU} from 'com/lru'
import {CPU} from 'gpc/cpu'
import {IOP} from 'gpc/iop'
import {MemoryBus} from 'gpc/membus'
import {HalUCP} from 'gpc/halUCP'
import {SymbolTable} from 'gpc/symbolTable'


export class AP101 extends LRU
  constructor: (CONFIG) ->
    lruConfig = {
      id: "GPC"
      nom: "GPC"
      busses: []
    }
    super(lruConfig)
    @CONFIG = CONFIG
    @cpu = new CPU()
    @running = false
    @stepCount = 0
    @startAddr = 0x000e
    @iop = new IOP(@cpu)
    @cpu.ram = new MemoryBus(@cpu.mainStorage, @iop.mainStorage)

    # Store initial load parameters for reset
    @initialFcmPath = null
    @initialSymbolsPath = null
    @initialEntryPoint = null
    @iop.cpu = @cpu
    @cpu.iop = @iop
    @halUCP = new HalUCP(@cpu)
    @cpu.halUCP = @halUCP
    @breakOnInput = false   # when true, stop after input instead of auto-resuming

    # Breakpoints: Map of address -> { enabled: bool }
    @breakpoints = new Map()
    @fcmName = null  # basename of loaded FCM, used as localStorage key for breakpoints

    # Symbol table
    @sym = new SymbolTable()
    @selectedSection = null  # Currently selected section for highlighting
    @selectedWatch = null    # Currently selected watch variable name
    @watchAddresses = null   # Set of addresses occupied by selected watch variable

  # Sync step counter to all hardware components
  _syncStep: () ->
    s = @stepCount
    @cpu.mainStorage.step = s
    for rf in @cpu.regFiles
      rf.step = s
    @cpu.psw.step = s

  step: () ->
    if @running
      return
    if @halUCP.waitingForInput
      return
    if @cpu.psw.getWaitState()
      console.log("AP101: CPU is in wait state")
      return
    # Check for HAL/S I/O trap before executing
    nia = @cpu.psw.getNIA()
    if @halUCP.active and @halUCP.isTrapAddr(nia)
      result = @halUCP.checkTrap(nia)
      if result == 'block'
        return
    @stepCount++
    @_syncStep()
    @cpu.exec1()
    @iop?.exec()
    @disasmViewAddr = null  # auto-follow NIA after step
    @updateDisplay()

  run: () ->
    if @running
      return
    @running = true
    @disasmViewAddr = null  # auto-follow NIA during/after run
    @updateToolbar()
    batchSize = 100
    stepsInBatch = 0
    stepOne = () =>
      if not @running
        @updateDisplay()
        return
      if @halUCP.waitingForInput
        @running = false
        @updateDisplay()
        return
      if @cpu.psw.getWaitState()
        @running = false
        console.log("AP101: CPU entered wait state after #{@stepCount} instructions")
        @updateDisplay()
        return
      # Check for HAL/S I/O trap before executing
      nia = @cpu.psw.getNIA()
      if @halUCP.active and @halUCP.isTrapAddr(nia)
        result = @halUCP.checkTrap(nia)
        if result == 'block'
          @halUCP.wasRunning = true
          @running = false
          @updateDisplay()
          return
      @stepCount++
      @_syncStep()
      @cpu.exec1()
      @iop?.exec()
      # Stop if SVC was trapped (SEND ERROR or SVC 0 halt)
      if @halUCP.svcTrapped
        @halUCP.svcTrapped = false
        @running = false
        @updateDisplay()
        return
      # Check breakpoints: stop if next instruction is at an enabled breakpoint
      nextNia = @cpu.psw.getNIA()
      bp = @breakpoints.get(nextNia)
      if bp?.enabled
        @running = false
        @updateDisplay()
        return
      stepsInBatch++
      if stepsInBatch >= batchSize
        stepsInBatch = 0
        @updateDisplay()
        setTimeout(stepOne, 0)
      else
        stepOne()
    stepOne()

  stop: () ->
    @running = false
    @updateDisplay()

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

  saveBreakpoints: () ->
    return unless @fcmName
    data = []
    @breakpoints.forEach (bp, addr) ->
      data.push({ addr, enabled: bp.enabled })
    try
      localStorage.setItem("gpc-bp:#{@fcmName}", JSON.stringify(data))
    catch e
      console.warn("AP101: Failed to save breakpoints:", e)

  loadBreakpoints: () ->
    return unless @fcmName
    try
      json = localStorage.getItem("gpc-bp:#{@fcmName}")
      return unless json
      data = JSON.parse(json)
      for bp in data
        @breakpoints.set(bp.addr, { enabled: bp.enabled })
    catch e
      console.warn("AP101: Failed to load breakpoints:", e)

  reset: () ->
    @running = false
    @stepCount = 0

    # Reset all registers to zero
    for bank in [0..2]
      for i in [0..7]
        @cpu.regFiles[bank].r(i).set32(0)

    # Reset DSE (Data Sector Extension) for base registers
    for bank in [0..1]
      for i in [0..3]
        @cpu.regFiles[bank].setDSE(i, 0)

    # Reset PSW
    @cpu.psw.psw1.set32(0)
    @cpu.psw.psw2.set32(0)

    # Reset HAL/S I/O trap state
    @halUCP.waitingForInput = false
    @halUCP.pendingIocode = null
    @halUCP.skipTrap = false
    @halUCP.wasRunning = false
    @halUCP.svcTrapped = false
    @halUCP.active = false

    # Reload memory and symbols from original load parameters
    if @initialFcmPath
      @loadFCMFile(@initialFcmPath, @initialSymbolsPath, @initialEntryPoint)
    else
      @loadMemFile('SIMPLE.fcm', 0x005f)

    @updateDisplay()

  loadSymbols: (symbolsPath) ->
    return unless symbolsPath?
    symPath = if path.isAbsolute(symbolsPath)
      symbolsPath
    else
      path.join(@CONFIG.NSTS_TOP, symbolsPath)
    entryPoint = @sym.load(symPath)
    if entryPoint?
      @halUCP.initFromSymbols(@sym.symbols, @sym.symTypes)
    return entryPoint

  file2arrayBuffer: (f) ->
    image = fs.readFileSync f
    buf = new ArrayBuffer(image.length)
    buf8 = new Uint8Array(buf)
    for i in [0...image.length]
      buf8[i] = image[i]
    dv = new DataView(buf)
    return dv

  loadFCMFile: (fcmPath, symbolsPath, overrideEntry) ->
    console.log("AP101: Loading #{fcmPath}")

    # Track FCM name for breakpoint persistence
    @fcmName = path.basename(fcmPath)

    # Load symbols first to get entry point
    entryPoint = @loadSymbols(symbolsPath)

    # Override from config if specified
    if overrideEntry?
      entryPoint = overrideEntry

    # Default entry point if none found
    entryPoint ?= 0x0060

    dv = @file2arrayBuffer(fcmPath)
    @cpu.ram.load16(0, dv)
    console.log("AP101: Loaded #{dv.byteLength} bytes into MCM")

    # Set initial PSW: NIA to program start, run state active
    @cpu.psw.setNIA(entryPoint)
    @cpu.psw.setWaitState(false)
    console.log("AP101: NIA set to 0x#{@cpu.psw.getNIA().toString(16).padStart(5,'0')} (entry=0x#{entryPoint.toString(16)})")

    # Restore breakpoints for this FCM
    @loadBreakpoints()

    # Dump first few halfwords for verification
    for i in [0...0x24]
      hw = @cpu.mainStorage.get16(i)
      if hw != 0
        console.log("  MCM[0x#{i.toString(16).padStart(4,'0')}] = 0x#{hw.toString(16).padStart(4,'0')}")

  loadMemFile: (fcmFileName, startAddr) ->
    @fcmName = fcmFileName
    fcmPath = path.join(@CONFIG.NSTS_TOP, 'gpc', 'gen', fcmFileName)
    console.log("AP101: Loading #{fcmPath}")
    dv = @file2arrayBuffer(fcmPath)
    @cpu.ram.load16(0, dv)
    console.log("AP101: Loaded #{dv.byteLength} bytes into MCM")

    # Set initial PSW: NIA to program start, run state active
    @cpu.psw.setNIA(startAddr)
    @cpu.psw.setWaitState(false)
    console.log("AP101: NIA set to 0x#{@cpu.psw.getNIA().toString(16).padStart(5,'0')}")

    # Restore breakpoints for this FCM
    @loadBreakpoints()

    # Dump first few halfwords for verification
    for i in [0...0x24]
      hw = @cpu.mainStorage.get16(i)
      if hw != 0
        console.log("  MCM[0x#{i.toString(16).padStart(4,'0')}] = 0x#{hw.toString(16).padStart(4,'0')}")

  # No-op display methods - overridden by DebugGUI
  updateDisplay: () ->
  updateToolbar: () ->

start = (CONFIG) ->
  gpc = new AP101(CONFIG)
  return gpc

export default { start }
