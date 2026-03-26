
# GPC Debugger
#
fs = require 'fs'
path = require 'path'
readline = require 'readline'
{Command} = require 'commander'

require 'com/util'
import {CPU} from 'gpc/cpu'
import Instruction from 'gpc/cpu_instr'
import {HalUCP} from 'gpc/halUCP'
import {SymbolTable} from 'gpc/symbolTable'

C =
  reset:   '\x1b[0m'
  bold:    '\x1b[1m'
  dim:     '\x1b[2m'
  red:     '\x1b[31m'
  green:   '\x1b[32m'
  yellow:  '\x1b[33m'
  blue:    '\x1b[34m'
  magenta: '\x1b[35m'
  cyan:    '\x1b[36m'
  white:   '\x1b[37m'
  bgRed:   '\x1b[41m'

class GPCDebugger
  constructor: (opts) ->
    @fcmPath = opts.fcmPath
    @entryPoint = opts.entryPoint ? null
    @maxSteps = opts.maxSteps ? 10000000
    @symbolsPath = opts.symbolsPath ? null
    @traceEnabled = opts.traceEnabled ? false
    @ebcdic = opts.ebcdic ? false
    @trapSvcError = opts.trapSvcError ? true
    @inFiles = opts.inFiles ? {}
    @outFiles = opts.outFiles ? {}

    @cpu = new CPU()
    @halUCP = new HalUCP(@cpu)
    @cpu.halUCP = @halUCP
    @halUCP.trapSvcError = @trapSvcError
    @halUCP.errorCallback = (msg) => @error msg

    @sym = new SymbolTable()
    @stepCount = 0

    # Breakpoints: Map<addr, {enabled: bool, name: string|null}>
    @breakpoints = new Map()

    # Watchpoints: Map<addr, {enabled: bool, name: string|null}>
    @memWatchpoints = new Map()
    @_memWatchTriggered = null  # set when a watchpoint fires

    # Watch expressions: Map<addr, {name: string, size: int, type: string}>
    @watches = new Map()

    # I/O
    @inStreams = {}
    @outStreams = {}
    @outputBuffer = []   # collects program output between stops

    @rl = null
    @_pendingInputResolve = null

    # Last command for repeat with Enter
    @lastCommand = null

    # Stop reason for display
    @stopReason = null

  # ---------------------------------------------------------------
  # Output helpers
  # ---------------------------------------------------------------
  out: (s) -> process.stdout.write s + "\n"
  error: (s) -> @out "#{C.red}*** #{s}#{C.reset}"
  info: (s) -> @out "#{C.cyan}#{s}#{C.reset}"
  dim: (s) -> @out "#{C.dim}#{s}#{C.reset}"

  # ---------------------------------------------------------------
  # Symbol resolution
  # ---------------------------------------------------------------
  resolveAddr: (s) ->
    # Try hex literal first
    s = s.trim()
    if s.match(/^(0x)?[0-9a-fA-F]+$/)
      return parseInt(s.replace(/^0x/i, ''), 16)
    # Try symbol lookup
    if @sym.symbols?
      for sym in (@sym.symbols.symbols or [])
        if sym.name == s.toUpperCase()
          return sym.address
    return null

  formatAddr: (addr) ->
    label = @sym.getLabelAt?(addr)
    if label
      return "#{addr.asHex(5)} <#{C.yellow}#{label}#{C.reset}>"
    sect = @sym.getSectionAt?(addr)
    if sect
      for s in @sym.sectionsByAddr
        if s.name == sect
          offset = addr - s.address
          return "#{addr.asHex(5)} <#{sect}+#{offset.asHex(3)}>"
    return addr.asHex(5)

  formatAddrPlain: (addr) ->
    label = @sym.getLabelAt?(addr)
    if label then "#{addr.asHex(5)} <#{label}>" else addr.asHex(5)

  # ---------------------------------------------------------------
  # Loading
  # ---------------------------------------------------------------
  loadSymbols: ->
    return unless @symbolsPath?
    entryPoint = @sym.load(@symbolsPath)
    if entryPoint? and not @entryPoint?
      @entryPoint = entryPoint
    if @sym.symbols?
      @halUCP.initFromSymbols(@sym.symbols, @sym.symTypes)

  loadFCM: ->
    image = fs.readFileSync @fcmPath
    buf = new ArrayBuffer(image.length)
    buf8 = new Uint8Array(buf)
    for i in [0...image.length]
      buf8[i] = image[i]
    dv = new DataView(buf)
    @cpu.mainStorage.load16(0, dv)
    unless @entryPoint?
      @error "No entry point: use --start=ADDR or provide symbols"
      process.exit(1)
    @cpu.psw.setNIA(@entryPoint)
    @cpu.psw.setWaitState(false)
    return dv.byteLength

  # ---------------------------------------------------------------
  # I/O subsystem 
  # ---------------------------------------------------------------
  initIO: ->
    unless @ebcdic
      @halUCP.iobufEncoding = 'ascii'

    for ch, filePath of @inFiles
      try
        content = fs.readFileSync(filePath, 'utf8')
        @inStreams[ch] = content.split('\n')
        if @inStreams[ch].length > 0 and @inStreams[ch][@inStreams[ch].length - 1] == ''
          @inStreams[ch].pop()
      catch e
        @error "Cannot open input file for channel #{ch}: #{filePath} (#{e.message})"
        process.exit(1)

    for ch, filePath of @outFiles
      try
        @outStreams[ch] = fs.createWriteStream(filePath)
      catch e
        @error "Cannot open output file for channel #{ch}: #{filePath} (#{e.message})"
        process.exit(1)

    @halUCP.outputCallback = (text, channel) => @handleOutput(text, channel)
    @halUCP.controlCallback = (iocode, param, channel) => @handleControl(iocode, param, channel)

  handleOutput: (text, channel) ->
    ch = channel.toString()
    if @outStreams[ch]?
      @outStreams[ch].write(text)
    @outputBuffer.push text

  handleControl: (iocode, param, channel) ->
    ch = channel.toString()
    text = switch iocode
      when 0, 1, 2, 3 then '\n'
      when 4 then '\n'.repeat(Math.max(1, param))      # LINE
      when 5 then ' '.repeat(Math.max(0, param))        # COLUMN
      when 6 then ' '.repeat(Math.max(1, param) * 5)    # TAB
      when 7 then '\n--- PAGE ---\n'                     # PAGE
      when 8 then '\n'.repeat(Math.max(1, param))        # SKIP
      else ''
    if @outStreams[ch]?
      @outStreams[ch].write(text)
    @outputBuffer.push text

  flushOutput: ->
    if @outputBuffer.length > 0
      combined = @outputBuffer.join('')
      if combined.length > 0
        @out "#{C.green}#{combined}#{C.reset}"
      @outputBuffer = []

  # ---------------------------------------------------------------
  # Register formatting
  # ---------------------------------------------------------------
  snapshotRegs: ->
    snap = {}
    grSet = @cpu.psw.getRegSet()
    for i in [0..7]
      snap["R0#{i}"] = @cpu.regFiles[grSet].r(i).get32()
    for i in [0..7]
      snap["FP#{i}"] = @cpu.regFiles[2].r(i).get32()
    snap.NIA = @cpu.psw.getNIA()
    snap.CC = @cpu.psw.getCC()
    snap.PSW1 = @cpu.psw.psw1.get32()
    snap.PSW2 = @cpu.psw.psw2.get32()
    return snap

  diffRegs: (before, after) ->
    changes = []
    for k of before
      if before[k] != after[k]
        changes.push { name: k, old: before[k], new: after[k] }
    return changes

  formatRegVal: (name, val) ->
    if name == 'CC' or name == 'NIA'
      return val.toString()
    return (val >>> 0).asHex(8)

  formatSectionOffset: (addr) ->
    return @sym.formatCSect?(addr) or ""

  # ---------------------------------------------------------------
  # Trace line
  # ---------------------------------------------------------------
  formatTraceLine: (step, nia, hw1, hw2, disasm, instrLen, changes) ->
    stepStr = step.toString().lpad(" ", 6)
    niaStr = nia.asHex(5)
    sectStr = @formatSectionOffset(nia)
    hw1Str = hw1.asHex(4)
    hw2Str = if instrLen > 1 then hw2.asHex(4) else "    "
    changesStr = ""
    if changes.length > 0
      parts = []
      for c in changes
        parts.push "#{c.name}: #{@formatRegVal(c.name, c.old)}->#{@formatRegVal(c.name, c.new)}"
      changesStr = "  " + parts.join(", ")
    return "#{C.dim}[#{stepStr}]#{C.reset} #{niaStr} #{sectStr}: #{hw1Str} #{hw2Str}  #{disasm.rpad(' ', 28)}#{C.yellow}#{changesStr}#{C.reset}"

  # ---------------------------------------------------------------
  #  Exec loop
  # ---------------------------------------------------------------
  execOne: ->
    # Sync step counter
    @cpu.mainStorage.step = @stepCount
    for rf in @cpu.regFiles
      rf.step = @stepCount

    nia = @cpu.psw.getNIA()

    # Check I/O trap
    if @halUCP.active and @halUCP.isTrapAddr(nia)
      result = @halUCP.checkTrap(nia)
      if @halUCP.waitingForInput
        return 'input'

    watchBefore = null
    if @memWatchpoints.size > 0
      watchBefore = new Map()
      @memWatchpoints.forEach (wp, addr) =>
        if wp.enabled
          watchBefore.set(addr, @cpu.mainStorage.get16(addr, false))

    before = @snapshotRegs()
    hw1 = @cpu.mainStorage.get16(nia)
    hw2 = @cpu.mainStorage.get16(nia + 1)
    disasm = Instruction.toStr(hw1, hw2)
    [d, v] = Instruction.decode(hw1, hw2)
    instrLen = if d? then d.origLen else 1

    unless d?
      @out @formatTraceLine(@stepCount, nia, hw1, hw2, "??? (invalid)", 1, [])
      @stopReason = "invalid instruction 0x#{hw1.asHex(4)} at #{@formatAddrPlain(nia)}"
      return 'error'

    @cpu.exec1()
    @stepCount++

    after = @snapshotRegs()
    changes = @diffRegs(before, after)
    changes = changes.filter (c) -> c.name != 'NIA'

    if @traceEnabled
      @out @formatTraceLine(@stepCount - 1, nia, hw1, hw2, disasm, instrLen, changes)

    if watchBefore?
      @memWatchpoints.forEach (wp, addr) =>
        return unless wp.enabled
        oldVal = watchBefore.get(addr)
        return unless oldVal?
        newVal = @cpu.mainStorage.get16(addr, false)
        if oldVal != newVal
          wpName = if wp.name then " (#{wp.name})" else ""
          @_memWatchTriggered = {
            addr, name: wpName
            old: oldVal, new: newVal
            triggerNia: nia
            triggerStep: @stepCount - 1
            triggerDisasm: disasm
          }

    if @halUCP.svcTrapped
      @halUCP.svcTrapped = false
      @stopReason = "SVC trapped"
      return 'svc'

    if @cpu.psw.getWaitState()
      @stopReason = "wait state (program halted)"
      return 'halt'

    if @_memWatchTriggered?
      return 'watchpoint'

    return 'ok'

  _handleExecResult: (result) ->
    if result == 'input'
      @flushOutput()
      @handleInteractiveInput()
      return false  # continue running (don't count as step)
    if result == 'error' or result == 'halt' or result == 'svc'
      return true
    if result == 'watchpoint'
      wp = @_memWatchTriggered
      @_memWatchTriggered = null
      @stopReason = "memory watchpoint: HW #{wp.addr.asHex(5)}#{wp.name} changed #{wp.old.asHex(4)} -> #{wp.new.asHex(4)} at step #{wp.triggerStep} (#{wp.triggerDisasm})"
      return true
    return false  # 'ok'

  execSteps: (count) ->
    ran = 0
    while ran < count
      # Check breakpoint before execution (except on first step of a 'continue')
      if ran > 0
        nextNia = @cpu.psw.getNIA()
        bp = @breakpoints.get(nextNia)
        if bp?.enabled
          @stopReason = "breakpoint at #{@formatAddrPlain(nextNia)}"
          break

      result = @execOne()
      if result == 'input'
        @flushOutput()
        @handleInteractiveInput()
        continue
      ran++
      break if @_handleExecResult(result)

    @flushOutput()
    return ran

  execRun: ->
    ran = 0
    while ran < @maxSteps
      # Check breakpoint (skip on first step to allow continuing past a bp)
      if ran > 0
        nextNia = @cpu.psw.getNIA()
        bp = @breakpoints.get(nextNia)
        if bp?.enabled
          @stopReason = "breakpoint at #{@formatAddrPlain(nextNia)}"
          break

      result = @execOne()
      if result == 'input'
        @flushOutput()
        @handleInteractiveInput()
        continue
      ran++
      break if @_handleExecResult(result)

    if ran >= @maxSteps and not @stopReason
      @stopReason = "max steps reached (#{@maxSteps})"

    @flushOutput()
    return ran

  handleInteractiveInput: ->
    ch = '0'
    iocode = @halUCP.pendingIocode
    typeName = HalUCP.iocodeTypeName(iocode)

    # Try file input first
    if @inStreams[ch]? and @inStreams[ch].length > 0
      line = @inStreams[ch].shift()
      @halUCP.provideInput(line)
      return

    buf = Buffer.alloc(1024)
    process.stdout.write "#{C.green} INPUT(#{typeName}): #{C.reset}"
    try
      n = fs.readSync(0, buf, 0, 1024)
      line = buf.toString('utf8', 0, n).replace(/\n$/, '')
    catch e
      line = ''
    @halUCP.provideInput(line)

  # ---------------------------------------------------------------
  # Display commands
  # ---------------------------------------------------------------
  showRegisters: ->
    grSet = @cpu.psw.getRegSet()
    @out "#{C.bold}--- Registers (bank #{grSet}) ---#{C.reset}"

    for row in [0, 4]
      parts = []
      for i in [row..row+3]
        val = @cpu.regFiles[grSet].r(i).get32()
        name = "R#{i.toString().padStart(2, '0')}"
        parts.push "#{C.cyan}#{name}#{C.reset}=#{(val >>> 0).asHex(8)}"
      @out "  " + parts.join("  ")

    parts = []
    for i in [0..3]
      val = @cpu.regFiles[2].r(i).get32()
      parts.push "#{C.cyan}FP#{i}#{C.reset}=#{(val >>> 0).asHex(8)}"
    @out "  " + parts.join("  ")
    parts = []
    for i in [4..7]
      val = @cpu.regFiles[2].r(i).get32()
      parts.push "#{C.cyan}FP#{i}#{C.reset}=#{(val >>> 0).asHex(8)}"
    @out "  " + parts.join("  ")

    psw1 = @cpu.psw.psw1.get32()
    psw2 = @cpu.psw.psw2.get32()
    nia = @cpu.psw.getNIA()
    cc = @cpu.psw.getCC()
    bsr = @cpu.psw.getBSR()
    dsr = @cpu.psw.getDSR()
    @out "  #{C.cyan}PSW1#{C.reset}=#{(psw1 >>> 0).asHex(8)}  #{C.cyan}PSW2#{C.reset}=#{(psw2 >>> 0).asHex(8)}  #{C.cyan}NIA#{C.reset}=#{nia.asHex(5)}  #{C.cyan}CC#{C.reset}=#{cc}  #{C.cyan}BSR#{C.reset}=#{bsr}  #{C.cyan}DSR#{C.reset}=#{dsr}"

  showRegister: (name) ->
    name = name.toUpperCase()
    grSet = @cpu.psw.getRegSet()
    if name.match(/^R(\d+)$/)
      i = parseInt(RegExp.$1)
      if i >= 0 and i <= 7
        val = @cpu.regFiles[grSet].r(i).get32()
        @out "  #{name} = 0x#{(val >>> 0).asHex(8)} (#{val})"
        return
    if name.match(/^FP(\d+)$/)
      i = parseInt(RegExp.$1)
      if i >= 0 and i <= 7
        val = @cpu.regFiles[2].r(i).get32()
        @out "  #{name} = 0x#{(val >>> 0).asHex(8)}"
        return
    if name == 'NIA'
      @out "  NIA = #{@cpu.psw.getNIA().asHex(5)}"
      return
    if name == 'CC'
      @out "  CC = #{@cpu.psw.getCC()}"
      return
    if name == 'PSW1'
      @out "  PSW1 = 0x#{(@cpu.psw.psw1.get32() >>> 0).asHex(8)}"
      return
    if name == 'PSW2'
      @out "  PSW2 = 0x#{(@cpu.psw.psw2.get32() >>> 0).asHex(8)}"
      return
    if name == 'BSR'
      @out "  BSR = #{@cpu.psw.getBSR()}"
      return
    if name == 'DSR'
      @out "  DSR = #{@cpu.psw.getDSR()}"
      return
    @error "Unknown register: #{name}"

  showDisasm: (startAddr, count=20) ->
    startAddr ?= @cpu.psw.getNIA()
    addr = startAddr
    nia = @cpu.psw.getNIA()
    for i in [0...count]
      break if addr >= 0x80000
      hw1 = @cpu.mainStorage.get16(addr)
      hw2 = @cpu.mainStorage.get16(addr + 1)
      [d, v] = Instruction.decode(hw1, hw2)

      # Marker for current NIA
      marker = if addr == nia then "#{C.bgRed}>>#{C.reset}" else "  "

      # Breakpoint marker
      bp = @breakpoints.get(addr)
      bpMark = if bp?.enabled then "#{C.red}*#{C.reset}" else " "

      # Symbol label
      label = @sym.getLabelAt?(addr)
      if label
        @out "#{C.yellow}                          #{label}:#{C.reset}"

      if d?
        instrLen = d.len
        disasmStr = Instruction.toStr(hw1, hw2)
        hw1Str = hw1.asHex(4)
        hw2Str = if instrLen > 1 then hw2.asHex(4) else "    "
        sect = @formatSectionOffset(addr)
        @out "#{marker}#{bpMark}#{addr.asHex(5)}: #{hw1Str} #{hw2Str}  #{disasmStr}"
      else
        @out "#{marker}#{bpMark}#{addr.asHex(5)}: #{hw1.asHex(4)}       DC    X'#{hw1.asHex(4)}'"
        instrLen = 1
      addr += instrLen

  showMemory: (startAddr, count=16, format='hex') ->
    addr = startAddr & 0x7ffff
    row = 0
    while row < count
      # 8 halfwords per row
      rowAddr = addr + row
      hexParts = []
      asciiParts = []
      cols = Math.min(8, count - row)
      for col in [0...cols]
        a = rowAddr + col
        hw = @cpu.mainStorage.get16(a)
        hexParts.push hw.asHex(4)
        b1 = (hw >> 8) & 0xff
        b2 = hw & 0xff
        c1 = if b1 >= 0x20 and b1 <= 0x7e then String.fromCharCode(b1) else '.'
        c2 = if b2 >= 0x20 and b2 <= 0x7e then String.fromCharCode(b2) else '.'
        asciiParts.push c1 + c2
      hexStr = hexParts.join(' ')
      asciiStr = asciiParts.join('')
      @out "  #{rowAddr.asHex(5)}: #{hexStr.rpad(' ', 39)}  |#{asciiStr}|"
      row += cols

  showMemoryFullword: (addr) ->
    val = @cpu.mainStorage.get32(addr)
    @out "  #{addr.asHex(5)}: #{val.asHex(8)} (int32: #{val | 0}, uint32: #{val})"

  showWatches: ->
    if @watches.size == 0
      @dim "  (no watches)"
      return
    @watches.forEach (w, addr) =>
      val = @cpu.mainStorage.get16(addr, false)
      if w.size >= 2
        fw = @cpu.mainStorage.get32(addr, false)
        @out "  #{C.cyan}#{w.name}#{C.reset} @ #{addr.asHex(5)}: HW=#{val.asHex(4)}  FW=#{(fw >>> 0).asHex(8)} (#{fw})"
      else
        @out "  #{C.cyan}#{w.name}#{C.reset} @ #{addr.asHex(5)}: #{val.asHex(4)} (#{val})"

  showBreakpoints: ->
    if @breakpoints.size == 0
      @dim "  (no breakpoints)"
      return
    @breakpoints.forEach (bp, addr) =>
      status = if bp.enabled then "#{C.green}ON #{C.reset}" else "#{C.red}OFF#{C.reset}"
      name = if bp.name then " <#{bp.name}>" else ""
      @out "  [#{status}] #{@formatAddr(addr)}#{name}"

  showMemWatchpoints: ->
    if @memWatchpoints.size == 0
      @dim "  (no memory watchpoints)"
      return
    @memWatchpoints.forEach (wp, addr) =>
      status = if wp.enabled then "#{C.green}ON #{C.reset}" else "#{C.red}OFF#{C.reset}"
      name = if wp.name then " <#{wp.name}>" else ""
      val = @cpu.mainStorage.get16(addr, false)
      @out "  [#{status}] #{@formatAddr(addr)}#{name} = #{val.asHex(4)}"

  showSections: ->
    unless @sym.sectionsByAddr?.length > 0
      @dim "  (no symbols loaded)"
      return
    @out "#{C.bold}--- Section Map ---#{C.reset}"
    for sect in @sym.sectionsByAddr
      endAddr = sect.address + sect.size - 1
      @out "  #{sect.address.asHex(5)} - #{endAddr.asHex(5)}  #{sect.name.rpad(' ', 14)} (#{sect.size} HW, #{sect.module})"
    if @entryPoint?
      @out "  Entry: #{@formatAddr(@entryPoint)}"

  showSymbol: (name) ->
    unless @sym.symbols?
      @error "No symbols loaded"
      return
    name = name.toUpperCase()
    found = false
    for sym in (@sym.symbols.symbols or [])
      if sym.name == name or sym.name.indexOf(name) >= 0
        addr = sym.address
        sect = @sym.getSectionAt?(addr) or "?"
        @out "  #{C.cyan}#{sym.name}#{C.reset}  addr=#{addr.asHex(5)}  type=#{sym.type}  section=#{sect}"
        found = true
    unless found
      @error "Symbol not found: #{name}"

  showCurrentLocation: ->
    nia = @cpu.psw.getNIA()
    hw1 = @cpu.mainStorage.get16(nia)
    hw2 = @cpu.mainStorage.get16(nia + 1)
    disasm = Instruction.toStr(hw1, hw2)
    [d, v] = Instruction.decode(hw1, hw2)
    instrLen = if d? then d.len else 1
    hw2Str = if instrLen > 1 then hw2.asHex(4) else "    "
    sect = @formatSectionOffset(nia)
    @out "#{C.bold}>>#{C.reset} #{nia.asHex(5)} #{sect}: #{hw1.asHex(4)} #{hw2Str}  #{C.bold}#{disasm}#{C.reset}"

  # Status line shown after each stop
  showStatus: ->
    if @stopReason?
      @out "#{C.yellow}--- stopped: #{@stopReason} (#{@stepCount} steps) ---#{C.reset}"
      @stopReason = null
    @showCurrentLocation()
    if @watches.size > 0
      @showWatches()

  # ---------------------------------------------------------------
  # Commands
  # ---------------------------------------------------------------
  setupCommands: ->
    @repl = new Command()
    @repl.exitOverride()
    @repl.configureOutput
      writeOut: (str) => @out str.trimEnd()
      writeErr: (str) => @error str.trimEnd()
    @repl.addHelpCommand false
    @repl.showSuggestionAfterError true

    # -- Execution --

    @repl.command('step')
      .aliases(['s', 'si'])
      .argument('[count]', 'number of instructions', '1')
      .description('Step N instructions (default 1)')
      .action (countStr) =>
        count = parseInt(countStr, 10)
        if isNaN(count) or count < 1
          @error "Usage: step [N]"
          return
        @execSteps(count)
        @showStatus()

    @repl.command('next')
      .alias('n')
      .description('Step over (run until next instruction)')
      .action =>
        nia = @cpu.psw.getNIA()
        hw1 = @cpu.mainStorage.get16(nia)
        hw2 = @cpu.mainStorage.get16(nia + 1)
        [d, v] = Instruction.decode(hw1, hw2)
        instrLen = if d? then d.origLen else 1
        nextAddr = nia + instrLen
        hadBp = @breakpoints.has(nextAddr)
        unless hadBp
          @breakpoints.set(nextAddr, { enabled: true, name: '__next__' })
        @execRun()
        unless hadBp
          @breakpoints.delete(nextAddr)
        @showStatus()

    @repl.command('run')
      .aliases(['r', 'c', 'continue', 'g', 'go'])
      .description('Run until breakpoint/halt/watchpoint')
      .action =>
        @execRun()
        @showStatus()

    @repl.command('reset')
      .description('Reset CPU and reload program')
      .action =>
        @stepCount = 0
        @outputBuffer = []
        @halUCP.waitingForInput = false
        @halUCP.pendingIocode = null
        @halUCP.skipTrap = false
        @halUCP.svcTrapped = false
        @halUCP.active = false
        @loadSymbols()
        @loadFCM()
        @initIO()
        @info "Program reset"
        @showStatus()

    @repl.command('load')
      .argument('<fcm>', 'FCM memory image to load')
      .argument('[symbols]', 'symbols JSON file')
      .description('Load a new program')
      .action (fcm, symbols) =>
        @fcmPath = fcm
        @symbolsPath = symbols or null
        @entryPoint = null
        @stepCount = 0
        @outputBuffer = []
        if not @symbolsPath?
          autoSymPath = @fcmPath.replace(/\.fcm$/i, '.sym.json')
          if autoSymPath != @fcmPath and fs.existsSync(autoSymPath)
            @symbolsPath = autoSymPath
        @loadSymbols()
        @loadFCM()
        @initIO()
        @info "Loaded: #{@fcmPath}"
        @showStatus()

    # -- Breakpoints --

    @repl.command('break')
      .aliases(['b', 'bp'])
      .argument('<addr>', 'address or symbol')
      .description('Set breakpoint')
      .action (addrStr) =>
        addr = @resolveAddr(addrStr)
        unless addr?
          @error "Cannot resolve: #{addrStr}"
          return
        label = @sym.getLabelAt?(addr)
        @breakpoints.set(addr, { enabled: true, name: label or addrStr })
        @info "Breakpoint set at #{@formatAddr(addr)}"

    @repl.command('clear')
      .aliases(['bc', 'del'])
      .argument('<addr>', 'address, symbol, or * for all')
      .description('Clear breakpoint')
      .action (addrStr) =>
        if addrStr == '*'
          @breakpoints.clear()
          @info "All breakpoints cleared"
          return
        addr = @resolveAddr(addrStr)
        unless addr?
          @error "Cannot resolve: #{addrStr}"
          return
        if @breakpoints.has(addr)
          @breakpoints.delete(addr)
          @info "Breakpoint cleared at #{@formatAddr(addr)}"
        else
          @error "No breakpoint at #{addr.asHex(5)}"

    @repl.command('bd')
      .argument('<addr>', 'address or symbol')
      .description('Disable breakpoint')
      .action (addrStr) =>
        addr = @resolveAddr(addrStr)
        unless addr?
          @error "Cannot resolve: #{addrStr}"
          return
        bp = @breakpoints.get(addr)
        if bp
          bp.enabled = false
          @info "Breakpoint disabled at #{@formatAddr(addr)}"
        else
          @error "No breakpoint at #{addr.asHex(5)}"

    @repl.command('be')
      .argument('<addr>', 'address or symbol')
      .description('Enable breakpoint')
      .action (addrStr) =>
        addr = @resolveAddr(addrStr)
        unless addr?
          @error "Cannot resolve: #{addrStr}"
          return
        bp = @breakpoints.get(addr)
        if bp
          bp.enabled = true
          @info "Breakpoint enabled at #{@formatAddr(addr)}"
        else
          @error "No breakpoint at #{addr.asHex(5)}"

    @repl.command('bl')
      .description('List breakpoints')
      .action =>
        @showBreakpoints()

    # -- Memory watchpoints --

    @repl.command('mw')
      .aliases(['memwatch', 'watchmem'])
      .argument('<addr>', 'address or symbol')
      .argument('[count]', 'number of halfwords', '1')
      .description('Set memory watchpoint (break on write)')
      .action (addrStr, countStr) =>
        addr = @resolveAddr(addrStr)
        unless addr?
          @error "Cannot resolve: #{addrStr}"
          return
        count = parseInt(countStr, 10)
        label = @sym.getLabelAt?(addr) or addrStr
        for i in [0...count]
          @memWatchpoints.set(addr + i, { enabled: true, name: if count > 1 then "#{label}+#{i}" else label })
        @info "Memory watchpoint set at #{@formatAddr(addr)}#{if count > 1 then " (#{count} HW)" else ""}"

    @repl.command('mwc')
      .alias('memwatchclear')
      .argument('<addr>', 'address, symbol, * for all')
      .description('Clear memory watchpoint')
      .action (addrStr) =>
        if addrStr == '*'
          @memWatchpoints.clear()
          @info "All memory watchpoints cleared"
          return
        addr = @resolveAddr(addrStr)
        unless addr?
          @error "Cannot resolve: #{addrStr}"
          return
        if @memWatchpoints.has(addr)
          @memWatchpoints.delete(addr)
          @info "Memory watchpoint cleared at #{@formatAddr(addr)}"
        else
          @error "No memory watchpoint at #{addr.asHex(5)}"

    @repl.command('mwl')
      .description('List memory watchpoints')
      .action =>
        @showMemWatchpoints()

    # -- Watch expressions --

    @repl.command('watch')
      .alias('w')
      .argument('<addr>', 'address or symbol')
      .argument('[size]', 'size in halfwords', '2')
      .description('Add watch expression (displayed on stop)')
      .action (addrStr, sizeStr) =>
        addr = @resolveAddr(addrStr)
        unless addr?
          @error "Cannot resolve: #{addrStr}"
          return
        label = @sym.getLabelAt?(addr) or addrStr
        size = parseInt(sizeStr, 10)
        @watches.set(addr, { name: label, size: size, type: 'hex' })
        @info "Watch added: #{label} @ #{@formatAddr(addr)}"

    @repl.command('unwatch')
      .alias('wc')
      .argument('<addr>', 'address, symbol, or * for all')
      .description('Remove watch expression')
      .action (addrStr) =>
        if addrStr == '*'
          @watches.clear()
          @info "All watches cleared"
          return
        addr = @resolveAddr(addrStr)
        unless addr?
          @error "Cannot resolve: #{addrStr}"
          return
        if @watches.has(addr)
          @watches.delete(addr)
          @info "Watch removed at #{@formatAddr(addr)}"
        else
          @error "No watch at #{addr.asHex(5)}"

    @repl.command('wl')
      .description('List watch expressions')
      .action =>
        @showWatches()

    # -- Registers --

    @repl.command('reg')
      .aliases(['regs', 'registers'])
      .argument('[name]', 'register name')
      .description('Show registers')
      .action (name) =>
        if name
          @showRegister(name)
        else
          @showRegisters()

    @repl.command('set')
      .argument('<register>', 'register name')
      .argument('<value>', 'value')
      .description('Set register value')
      .action (name, valStr) =>
        @setRegister(name, valStr)

    # -- Disassembly --

    @repl.command('disasm')
      .aliases(['d', 'u', 'unassemble'])
      .argument('[addr]', 'start address (def: NIA)')
      .argument('[count]', 'number of instructions', '20')
      .description('Disassemble instructions')
      .action (addrStr, countStr) =>
        startAddr = if addrStr then @resolveAddr(addrStr) else null
        count = parseInt(countStr, 10)
        @showDisasm(startAddr, count)

    # -- Memory --

    @repl.command('mem')
      .aliases(['x', 'examine'])
      .argument('<addr>', 'address or symbol')
      .argument('[count]', 'number of halfwords', '16')
      .description('Examine hw')
      .action (addrStr, countStr) =>
        addr = @resolveAddr(addrStr)
        unless addr?
          @error "Cannot resolve: #{addrStr}"
          return
        count = parseInt(countStr, 10)
        @showMemory(addr, count)

    @repl.command('xw')
      .aliases(['x32', 'fw'])
      .argument('<addr>', 'address or symbol')
      .description('Examine fw')
      .action (addrStr) =>
        addr = @resolveAddr(addrStr)
        unless addr?
          @error "Cannot resolve: #{addrStr}"
          return
        @showMemoryFullword(addr)

    # -- Symbols & sections --

    @repl.command('sym')
      .alias('symbol')
      .argument('<name>', 'symbol name')
      .description('Look up symbol')
      .action (name) =>
        @showSymbol(name)

    @repl.command('sections')
      .alias('sect')
      .description('Show section map')
      .action =>
        @showSections()

    # -- Trace --

    @repl.command('trace')
      .argument('[state]', 'on or off')
      .description('Toggle or show instruction trace')
      .action (state) =>
        if state == 'on'
          @traceEnabled = true
          @info "Trace enabled"
        else if state == 'off'
          @traceEnabled = false
          @info "Trace disabled"
        else
          @info "Trace is #{if @traceEnabled then 'on' else 'off'}"

    # -- Info --

    infoCmd = @repl.command('info')
      .alias('i')
      .description('Show info (breakpoints, watches, memwatch, registers, sections)')

    infoCmd.command('breakpoints')
      .aliases(['b', 'bp'])
      .description('List breakpoints')
      .action => @showBreakpoints()

    infoCmd.command('watches')
      .aliases(['w', 'watch'])
      .description('List watch expressions')
      .action => @showWatches()

    infoCmd.command('memwatch')
      .alias('mw')
      .description('List memory watchpoints')
      .action => @showMemWatchpoints()

    infoCmd.command('registers')
      .aliases(['r', 'reg'])
      .description('Show all registers')
      .action => @showRegisters()

    infoCmd.command('sections')
      .alias('s')
      .description('Show section map')
      .action => @showSections()

    # -- Other --

    @repl.command('where')
      .aliases(['loc', 'here'])
      .description('Show current location')
      .action =>
        @showCurrentLocation()

    @repl.command('steps')
      .description('Show step count')
      .action =>
        @out "Step count: #{@stepCount}"

    @repl.command('help')
      .aliases(['h', '?'])
      .argument('[command]', 'command to get help for')
      .description('Show help')
      .action (cmdName) =>
        if cmdName
          sub = @repl.commands.find (c) ->
            c.name() == cmdName or cmdName in c.aliases()
          if sub
            sub.outputHelp()
          else
            @error "Unknown command: #{cmdName}"
        else
          @repl.outputHelp()

    @repl.command('quit')
      .aliases(['q', 'exit'])
      .description('Exit debugger')
      .action =>
        @out "Goodbye."
        process.exit(0)

  setRegister: (name, valStr) ->
    name = name.toUpperCase()
    val = parseInt(valStr.replace(/^0x/i, ''), if valStr.match(/^0x/i) then 16 else 10)
    if isNaN(val)
      @error "Invalid value: #{valStr}"
      return
    grSet = @cpu.psw.getRegSet()
    if name.match(/^R(\d+)$/)
      i = parseInt(RegExp.$1)
      if i >= 0 and i <= 7
        @cpu.regFiles[grSet].r(i).set32(val)
        @info "#{name} = 0x#{(val >>> 0).asHex(8)}"
        return
    if name.match(/^FP(\d+)$/)
      i = parseInt(RegExp.$1)
      if i >= 0 and i <= 7
        @cpu.regFiles[2].r(i).set32(val)
        @info "#{name} = 0x#{(val >>> 0).asHex(8)}"
        return
    if name == 'NIA'
      @cpu.psw.setNIA(val)
      @info "NIA = #{val.asHex(5)}"
      return
    @error "Cannot set: #{name}"

  # ---------------------------------------------------------------
  # entry point
  # ---------------------------------------------------------------
  start: ->
    @loadSymbols()
    byteCount = @loadFCM()
    @initIO()
    @setupCommands()

    @out ""
    @out "#{C.bold}#{C.cyan}=== GPC Debugger ===#{C.reset}"
    @out "#{C.dim}FCM: #{@fcmPath} (#{byteCount} bytes)#{C.reset}"
    if @entryPoint?
      @out "#{C.dim}Entry: #{@formatAddr(@entryPoint)}#{C.reset}"
    if @sym.symbols?
      @out "#{C.dim}Symbols: #{@symbolsPath} (#{@sym.symbols.symbols?.length or 0} symbols, #{@sym.symbols.sections?.length or 0} sections)#{C.reset}"
    @out "#{C.dim}Type 'help' for commands#{C.reset}"
    @out ""

    @showSections() if @sym.sectionsByAddr?.length > 0
    @out ""
    @showCurrentLocation()

    completions = []
    for cmd in @repl.commands
      completions.push cmd.name()
      for a in cmd.aliases()
        completions.push a

    @rl = readline.createInterface
      input: process.stdin
      output: process.stdout
      prompt: "#{C.bold}gpc> #{C.reset}"
      terminal: true
      completer: (line) =>
        parts = line.split(/\s+/)
        if parts.length <= 1
          word = parts[0] or ''
          hits = completions.filter (n) -> n.startsWith(word)
          return [hits, word]
        else
          word = parts[parts.length - 1] or ''
          if @sym.symbols? and word.length > 0
            syms = (@sym.symbols.symbols or [])
              .map((s) -> s.name)
              .filter((n) -> n.toLowerCase().startsWith(word.toLowerCase()))
              .slice(0, 20)
            return [syms, word]
          return [[], word]

    @historyFile = path.join(process.env.HOME or '.', '.gpc_dbg_history')
    try
      history = fs.readFileSync(@historyFile, 'utf8').split('\n').filter (l) -> l.length > 0
      @rl.history = history.slice(-1000).reverse()
    catch _e
      null  # No history file yet

    @rl.on 'line', (line) =>
      line = line.trim()
      if line.length == 0 and @lastCommand?
        tokens = @lastCommand
      else if line.length > 0
        tokens = line.split(/\s+/)
        @lastCommand = tokens
      else
        @rl.prompt()
        return

      try
        @repl.parse tokens, { from: 'user' }
      catch e
        if e.code == 'commander.helpDisplayed' or e.code == 'commander.version'
          null  # expected — help/version was displayed
        else unless e.code
          @error "Internal error: #{e.message}"
          if @traceEnabled
            @error e.stack

      @rl.prompt()

    @rl.on 'close', =>
      try
        fs.writeFileSync @historyFile, @rl.history.slice(0, 1000).reverse().join('\n') + '\n'
      catch _e
        null  # ignore write errors
      @out "\nGoodbye."
      process.exit(0)

    @rl.prompt()


# ---------------------------------------------------------------
# CLI parsing
# ---------------------------------------------------------------
parseHex = (s) -> parseInt(s.replace(/^0x/i, ''), 16)

program = new Command()
program
  .name('gpc-dbg')
  .description('GPC Debugger — interactive AP-101 debugger')
  .showHelpAfterError(true)
  .argument('<fcm-file>', 'FCM memory image to load')
  .option('--start <addr>', 'start address in hex')
  .option('--max-steps <n>', 'max instructions before auto-stop', '10000000')
  .option('--symbols <file>', 'load symbol table JSON from linker')
  .option('--trace', 'enable instruction trace at startup')
  .option('--ebcdic', 'use EBCDIC encoding for character I/O')
  .option('--trap-svc-error', 'intercept HAL/S SEND ERROR SVCs (default)', true)
  .option('--no-trap-svc-error', 'pass SEND ERROR SVCs to SVC handler')
  .option('--infile0 <file>', 'read input for channel 0')
  .option('--infile1 <file>', 'read input for channel 1')
  .option('--infile2 <file>', 'read input for channel 2')
  .option('--infile3 <file>', 'read input for channel 3')
  .option('--outfile0 <file>', 'write output for channel 0')
  .option('--outfile1 <file>', 'write output for channel 1')
  .option('--outfile2 <file>', 'write output for channel 2')
  .option('--outfile3 <file>', 'write output for channel 3')
  .parse()

fcmPath = program.args[0]
o = program.opts()

inFiles = {}
outFiles = {}
for ch in [0..3]
  inFiles[ch] = o["infile#{ch}"] if o["infile#{ch}"]
for ch in [0..7]
  outFiles[ch] = o["outfile#{ch}"] if o["outfile#{ch}"]

opts = {
  fcmPath
  entryPoint: if o.start then parseHex(o.start) else null
  maxSteps: parseInt(o.maxSteps, 10)
  symbolsPath: o.symbols or null
  traceEnabled: o.trace or false
  ebcdic: o.ebcdic or false
  trapSvcError: o.trapSvcError
  inFiles
  outFiles
}

# Auto-detect symbols file
if not opts.symbolsPath?
  autoSymPath = fcmPath.replace(/\.fcm$/i, '.sym.json')
  if autoSymPath != fcmPath and fs.existsSync(autoSymPath)
    opts.symbolsPath = autoSymPath
    process.stderr.write "Auto-detected symbols: #{opts.symbolsPath}\n"

debugger_ = new GPCDebugger(opts)
debugger_.start()
