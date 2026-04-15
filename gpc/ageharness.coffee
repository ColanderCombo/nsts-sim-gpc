
# AGEHarness — Aerospace/Ground Equipment Harness
#
# Development and debugging support equipment for the AP-101 GPC.
# In the original Shuttle program, AGE was the hardware that connected
# to physical AP-101 computers for development, testing, and debugging.
# Flight AP-101s have none of this — symbols, FCM file loading, breakpoints,
# and HalUCP I/O trapping are all ground affordances.
#
# All simulator entry points (batch, debug, dump, GUI) use AGEHarness
# to wrap an AP101 instance with development capabilities.

fs = require 'fs'
path = require 'path'

import {AP101} from 'gpc/ap101'
import {HalUCP} from 'gpc/halUCP'
import {SymbolTable} from 'gpc/symbolTable'

parseHex = (s) -> parseInt(s.replace(/^0x/i, ''), 16)

export class AGEHarness

  # ---------------------------------------------------------------
  # CLI option registration — call on a commander Command to add
  # the options that AGEHarness knows how to consume.
  # ---------------------------------------------------------------
  @addOptions: (cmd) ->
    cmd
      .option('--start <addr>', 'start address in hex')
      .option('--symbols <file>', 'load symbol table JSON from linker')
      .option('--ebcdic', 'use EBCDIC encoding for character I/O')
      .option('--trap-svc-error', 'intercept HAL/S SEND ERROR SVCs (default)', true)
      .option('--no-trap-svc-error', 'pass SEND ERROR SVCs to SVC handler')
      .option('--halucp-format-num-blanks <n>', 'blanks between WRITE output fields (default: 5)', '5')
      .option('--line-width <n>', 'WRITE line width for wrap (default: 132)', '132')

  # ---------------------------------------------------------------
  # Extract the AGEHarness-consumable subset of commander opts.
  # Use when forwarding parsed CLI options into a constructor that will
  # later pass them to configureFromOpts.
  # ---------------------------------------------------------------
  @optsFrom: (o) ->
    start: o.start
    symbols: o.symbols
    ebcdic: o.ebcdic
    trapSvcError: o.trapSvcError
    halucpFormatNumBlanks: o.halucpFormatNumBlanks
    lineWidth: o.lineWidth

  # ---------------------------------------------------------------
  # Configure this AGEHarness instance from parsed CLI options.
  # Loads symbols (with auto-detect), loads FCM, sets entry point, and
  # configures HalUCP.  The (fcmPath, opts) pair is saved for reset().
  # Returns { byteCount, entryPoint, symbolsPath }.
  # ---------------------------------------------------------------
  configureFromOpts: (fcmPath, opts = {}) ->
    # Configure HalUCP from options
    @halUCP.trapSvcError = opts.trapSvcError ? true
    @halUCP.formatNumBlanks = parseInt(opts.halucpFormatNumBlanks ? '5', 10)
    @halUCP.lineWidth = parseInt(opts.lineWidth ? '132', 10)

    # Symbol loading (with auto-detect if not explicit)
    symbolsPath = opts.symbols or @autoDetectSymbols(fcmPath)
    symEntry = @loadSymbols(symbolsPath)

    # Entry point priority: explicit --start > symbols > null
    entryPoint = if opts.start then parseHex(opts.start) else symEntry

    byteCount = @loadFCM(fcmPath)
    @setEntryPoint(entryPoint) if entryPoint?

    # Save for reset() to replay
    @initialFcmPath = fcmPath
    @initialOpts = opts

    # Restore persisted breakpoints (no-op in CLI where localStorage is absent)
    @loadBreakpoints()

    return { byteCount, entryPoint, symbolsPath }

  constructor: (opts = {}) ->
    # Create the flight computer
    @gpc = new AP101(opts)
    @CONFIG = opts  # preserve for subclasses that need config access

    # Ground equipment: HAL/S UCP I/O trap layer
    # Originally ran on the IBM 360 to simulate HAL/S I/O during development.
    @halUCP = new HalUCP(@gpc.cpu)
    @gpc.cpu.halUCP = @halUCP

    # Symbol table — development/debug only
    @sym = new SymbolTable()

    # Step counter: incremented on each exec1 by the caller
    @stepCount = 0

    # Breakpoints: Map<addr, { enabled: bool }>
    @breakpoints = new Map()
    @fcmName = null  # basename of loaded FCM, used as localStorage key for breakpoints

    # Saved by configureFromOpts for reset() to replay
    @initialFcmPath = null
    @initialOpts = null

  # ---------------------------------------------------------------
  # Delegated accessors — convenience access to the flight computer
  # ---------------------------------------------------------------
  Object.defineProperty @prototype, 'cpu', get: -> @gpc.cpu
  Object.defineProperty @prototype, 'iop', get: -> @gpc.iop
  Object.defineProperty @prototype, 'ram', get: -> @gpc.ram
  Object.defineProperty @prototype, 'mainStorage', get: -> @gpc.cpu.mainStorage

  # ---------------------------------------------------------------
  # FCM loading — ground equipment file I/O
  # ---------------------------------------------------------------

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

  # Auto-detect symbols file: replace .fcm with .sym.json
  autoDetectSymbols: (fcmPath) ->
    autoSymPath = fcmPath.replace(/\.fcm$/i, '.sym.json')
    if autoSymPath != fcmPath and fs.existsSync(autoSymPath)
      return autoSymPath
    return null

  # ---------------------------------------------------------------
  # Symbol loading
  # ---------------------------------------------------------------

  # Load a symbol table from an absolute path.  Returns the entry point
  # address from the symbols JSON (or null if none/failed).  Callers are
  # responsible for resolving relative paths before calling.
  loadSymbols: (symbolsPath) ->
    return null unless symbolsPath?
    entryPoint = @sym.load(symbolsPath)
    if entryPoint?
      @halUCP.initFromSymbols(@sym.symbols, @sym.symTypes)
    return entryPoint

  # ---------------------------------------------------------------
  # Entry point management
  # ---------------------------------------------------------------

  setEntryPoint: (addr) ->
    @gpc.cpu.psw.setNIA(addr)
    @gpc.cpu.psw.setWaitState(false)

  # ---------------------------------------------------------------
  # Register snapshots — development instrumentation
  # ---------------------------------------------------------------

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

  # ---------------------------------------------------------------
  # Step counter sync
  # ---------------------------------------------------------------

  _syncStep: () ->
    s = @stepCount
    @gpc.cpu.mainStorage.step = s
    for rf in @gpc.cpu.regFiles
      rf.step = s
    @gpc.cpu.psw.step = s

  # ---------------------------------------------------------------
  # Breakpoint persistence
  # ---------------------------------------------------------------

  # localStorage is only available in a browser/Electron renderer context.
  # We detect that via `typeof window` — accessing globalThis.localStorage
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

  # ---------------------------------------------------------------
  # Reset
  # ---------------------------------------------------------------

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
      @configureFromOpts(@initialFcmPath, @initialOpts or {})
