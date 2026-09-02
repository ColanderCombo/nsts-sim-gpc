
# AGEHarness: Aerospace/Ground Equipment Harness
#
# Development and debugging support equipment for the AP-101 GPC.
# In the original Shuttle program, AGE was the hardware that connected
# to physical AP-101 computers for development, testing, and debugging.
# Flight AP-101s have none of this: symbols, FCM file loading, breakpoints
# and HalUCP I/O trapping are all ground affordances.
#
# All simulator entry points (batch, debug, dump, GUI) use AGEHarness
# to wrap an AP101 instance with development capabilities.

fs = require 'fs'
path = require 'path'

import {AP101} from 'gpc/ap101'
import {CPU} from 'gpc/cpu'
import {IPLLoader} from 'gpc/iplloader'
import {HalUCP} from 'gpc/halUCP'
import {SymbolTable} from 'gpc/symbolTable'
import {DEFAULT_MACHINE, parseMachineOption} from 'gpc/machine'

parseHex = (s) -> parseInt(s.replace(/^0x/i, ''), 16)

parseGpcId = (v) ->
  n = parseInt(v, 10)
  unless n >= 0 and n <= 5
    process.stderr.write "FATAL: --gpc must be a GPC ID from 0 to 5\n"
    process.exit(1)
  return n

export class AGEHarness

  # CLI option registration: call on a commander Command to add
  # the options that AGEHarness knows how to consume.
  @addOptions: (cmd) ->
    cmd
      .option('--start <addr>', 'start address in hex')
      .option('--power-on', 'enter from the power-on PSW')
      .option('--sys-reset', 'enter at system reset PSW')
      .option('--ipl', 'simulate microcode IPL to load and run FCMBOOT from MMU')
      .option('--symbols <file>', 'load symbol table JSON from linker')
      .option('--ebcdic', 'use EBCDIC encoding for character I/O')
      .option('--trap-svc-error', 'intercept HAL/S SEND ERROR SVCs (default)', true)
      .option('--no-trap-svc-error', 'pass SEND ERROR SVCs to SVC handler')
      .option('--halucp-format-num-blanks <n>', 'blanks between WRITE output fields (default: 5)', '5')
      .option('--line-width <n>', 'WRITE line width for wrap (default: 132)', '132')
      .option('--machine <model>', "machine model, ap101s or ap101b (default ap101s)", parseMachineOption, DEFAULT_MACHINE)
      .option('--gpc <n>', 'GPC ID, 0-5', parseGpcId, 0)

  # Extract the AGEHarness-consumable subset of commander opts.
  # Use when forwarding parsed CLI options into a constructor that will
  # later pass them to configureFromOpts.
  @optsFrom: (o) ->
    machine: o.machine
    gpc: o.gpc
    start: o.start
    powerOn: o.powerOn
    sysReset: o.sysReset
    ipl: o.ipl
    symbols: o.symbols
    ebcdic: o.ebcdic
    trapSvcError: o.trapSvcError
    halucpFormatNumBlanks: o.halucpFormatNumBlanks
    lineWidth: o.lineWidth

  # Configure this AGEHarness instance from parsed CLI options.
  # Loads symbols (with auto-detect), loads FCM, sets entry point, and
  # configures HalUCP.  The (fcmPath, opts) pair is saved for reset().
  # Returns { byteCount, entryPoint, entrySource, symbolsPath,
  # entryWarning }, where entrySource is 'ipl', 'sys-reset', 'start',
  # 'symbols' or 'power-on'
  # and entryWarning is set when the entry chosen is not a usable one.
  configureFromOpts: (fcmPath, opts = {}) ->
    @gpc.setMachine(opts.machine) if opts.machine?

    # Configure HalUCP from options
    @halUCP.trapSvcError = opts.trapSvcError ? true
    @halUCP.formatNumBlanks = parseInt(opts.halucpFormatNumBlanks ? '5', 10)
    @halUCP.lineWidth = parseInt(opts.lineWidth ? '132', 10)

    symbolsPath = opts.symbols or (fcmPath? and @autoDetectSymbols(fcmPath)) or null
    @symbolsPath = symbolsPath
    symEntry = @loadSymbols(symbolsPath, !!opts.verbose)

    # Entry point priority: 
    #   --ipl > [--sys-reset|--power-on] > explicit --start > symbols
    if opts.ipl
      entryPoint = null
      entrySource = 'ipl'
    else if opts.sysReset
      entryPoint = null
      entrySource = 'sys-reset'
    else if opts.powerOn
      entryPoint = null
      entrySource = 'power-on'
    else if opts.start
      entryPoint = parseHex(opts.start)
      entrySource = 'start'
    else if symEntry?
      entryPoint = symEntry
      entrySource = 'symbols'
    else
      entryPoint = null
      entrySource = 'power-on'

    byteCount = if fcmPath? then @loadFCM(fcmPath) else 0
    @applyLoadProtection() if fcmPath?
    protectWarning =
      if not fcmPath? or @sym?.storeProtect? then null
      else "image carries no store-protect map; running unprotected " +
           "(relink to regenerate .sym.json)"
    entryWarning = null
    if entrySource == 'ipl'
      entryPoint = 0
    else if entryPoint?
      @setEntryPoint(entryPoint)
    else if entrySource == 'sys-reset'
      entryPoint = @gpc.cpu.systemReset()
      if entryPoint == 0
        entryWarning = "system reset PSW at PSA 0x#{CPU.SYSTEM_RESET_PSW.asHex(4)} is zero"
    else
      entryPoint = @gpc.cpu.loadPowerOnPSW()
      if entryPoint == 0
        entryWarning = "power-on PSW at PSA 0x#{CPU.POWER_ON_PSW.asHex(4)} is zero"

    # Save for reset() to replay
    @initialFcmPath = fcmPath
    @initialOpts = opts

    # Restore persisted breakpoints (no-op in CLI where localStorage is absent)
    @loadBreakpoints()

    return { byteCount, entryPoint, entrySource, symbolsPath, entryWarning,
             protectWarning }

  constructor: (opts = {}) ->
    # Create the flight computer
    @gpc = new AP101(opts)
    @CONFIG = opts  # preserve for subclasses that need config access
    @gpc.iop.onIPL = () => @iplFromButton()

    # Ground equipment: the HAL/S UCP I/O trap layer
    # Originally ran on the IBM 360 to simulate HAL/S I/O during development.
    @halUCP = new HalUCP(@gpc.cpu)
    @gpc.cpu.halUCP = @halUCP

    # Symbol table, development and debug only
    @sym = new SymbolTable()
    @symbolsPath = null

    # Step counter: incremented on each exec1 by the caller
    @stepCount = 0

    # Breakpoints: Map<addr, { enabled: bool }>
    @breakpoints = new Map()
    @fcmName = null  # basename of loaded FCM, used as localStorage key for breakpoints

    # Saved by configureFromOpts for reset() to replay
    @initialFcmPath = null
    @initialOpts = null

  # Delegated accessors for the flight computer
  Object.defineProperty @prototype, 'cpu', get: -> @gpc.cpu
  Object.defineProperty @prototype, 'iop', get: -> @gpc.iop
  Object.defineProperty @prototype, 'ram', get: -> @gpc.ram
  Object.defineProperty @prototype, 'mainStorage', get: -> @gpc.cpu.mainStorage

  # FCM loading: ground equipment file I/O

  file2arrayBuffer: (f) ->
    image = fs.readFileSync f
    buf = new ArrayBuffer(image.length)
    buf8 = new Uint8Array(buf)
    for i in [0...image.length]
      buf8[i] = image[i]
    dv = new DataView(buf)
    return dv

  loadFCM: (fcmPath) ->
    @fcmName = path.basename(fcmPath)
    dv = @file2arrayBuffer(fcmPath)
    @gpc.ram.load16(0, dv)
    return dv.byteLength

  # Storage protection as the IPL leaves it, from the linker's map.  Without
  # one, protect nothing: guessing by section locks the runtime's I/O cells.
  applyLoadProtection: () ->
    ranges = @sym?.storeProtect
    return 0 unless ranges?
    n = 0
    for [lo, hi] in ranges
      for a in [lo ... hi]
        @gpc.ram.setStoreProtect(a, true)
        n++
    return n

  iplFromMassMemory: (opts = {}, pacer = null, log = null) ->
    loader = new IPLLoader(@gpc, { log: log })
    info = await loader.run(pacer)
    @entryPoint = info.entry
    return info

  iplFromButton: () ->
    return if @iplRunning
    @iplRunning = true
    log = (m) -> process.stderr.write("IPL: #{m}\n")
    done = () => @iplRunning = false
    @iplFromMassMemory({}, @pacer ? null, log).then(done, (e) =>
      done()
      process.stderr.write("IPL failed: #{e.message}\n"))
    return

  # Auto-detect symbols file: replace .fcm with .sym.json
  autoDetectSymbols: (fcmPath) ->
    autoSymPath = fcmPath.replace(/\.fcm$/i, '.sym.json')
    if autoSymPath != fcmPath and fs.existsSync(autoSymPath)
      return autoSymPath
    return null

  # Symbol loading

  # Load a symbol table from an absolute path.  Returns the entry point
  # address from the symbols JSON (or null if none/failed).  Callers are
  # responsible for resolving relative paths before calling.
  loadSymbols: (symbolsPath, verbose = false) ->
    return null unless symbolsPath?
    entryPoint = @sym.load(symbolsPath, verbose)
    if entryPoint?
      @halUCP.initFromSymbols(@sym.symbols, @sym.symTypes)
    return entryPoint

  # Entry point management

  setEntryPoint: (addr) ->
    @gpc.cpu.psw.setNIA(addr)
    @gpc.cpu.psw.setWaitState(false)

  # Register snapshots: development instrumentation

  snapshotRegs: ->
    snap = {}
    grSet = @gpc.cpu.psw.getRegSet()
    for i in [0..7]
      snap["R0#{i}"] = @gpc.cpu.regFiles[grSet].r(i).get32()
    for i in [0..7]
      snap["FP#{i}"] = @gpc.cpu.regFiles[2].r(i).get32()
    snap.NIA = @gpc.cpu.psw.getNIA()
    snap.CC = @gpc.cpu.psw.getCC()
    snap.PSW1 = @gpc.cpu.psw.psw1.get32()
    snap.PSW2 = @gpc.cpu.psw.psw2.get32()
    return snap

  diffRegs: (before, after) ->
    changes = []
    for k of before
      if before[k] != after[k]
        changes.push { name: k, old: before[k], new: after[k] }
    return changes

  # Step counter sync

  _syncStep: () ->
    s = @stepCount
    @gpc.cpu.mainStorage.step = s
    for rf in @gpc.cpu.regFiles
      rf.step = s
    @gpc.cpu.psw.step = s

  # Breakpoint persistence

  # localStorage is only available in a browser/Electron renderer context.
  # We detect that via `typeof window`; accessing globalThis.localStorage
  # in plain Node 22+ triggers a noisy experimental-shim warning, so avoid it.
  _storage: () ->
    if typeof window != 'undefined' and window.localStorage?
      window.localStorage
    else
      null

  saveBreakpoints: () ->
    return unless @fcmName
    storage = @_storage()
    return unless storage?
    data = []
    @breakpoints.forEach (bp, addr) ->
      data.push({ addr, enabled: bp.enabled })
    storage.setItem("gpc-bp:#{@fcmName}", JSON.stringify(data))

  loadBreakpoints: () ->
    return unless @fcmName
    storage = @_storage()
    return unless storage?
    json = storage.getItem("gpc-bp:#{@fcmName}")
    return unless json
    for bp in JSON.parse(json)
      @breakpoints.set(bp.addr, { enabled: bp.enabled })

  # Reset
  #
  # Reset hardware and ground equipment, then replay the original
  # configureFromOpts to reload memory and symbols.  GUIHarness overrides
  # this to also clear @running and refresh the display.
  reset: () ->
    @stepCount = 0
    @gpc.reset()

    # Reset HalUCP trap state
    @halUCP.waitingForInput = false
    @halUCP.pendingIocode = null
    @halUCP.skipTrap = false
    @halUCP.wasRunning = false
    @halUCP.svcTrapped = false
    @halUCP.active = false

    if @initialFcmPath
      @gpc.ram.clear?()
      @configureFromOpts(@initialFcmPath, @initialOpts or {})
