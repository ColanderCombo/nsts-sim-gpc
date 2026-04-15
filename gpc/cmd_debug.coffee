
# gpc debug cmd
# terminal based interactive debugger
#
fs = require 'fs'
path = require 'path'
readline = require 'readline'
{Command} = require 'commander'

require 'com/util'
import {AGEHarness} from 'gpc/ageharness'
import {IOHost} from 'gpc/iohost'
import Instruction from 'gpc/cpu_instr'
import {HalUCP} from 'gpc/halUCP'
import {C, P, formatRegVal, formatTraceLine, formatRegDump} from 'gpc/trace'

export class GPCDebugger
  constructor: (opts) ->
    @opts = opts
    @fcmPath = opts.fcmPath
    @maxSteps = opts.maxSteps ? 10000000
    @traceEnabled = opts.traceEnabled ? false

    @age = new AGEHarness()
    @age.halUCP.errorCallback = (msg) => @error msg

    @iohost = IOHost.fromOpts(@age.halUCP, opts)
    @breakpoints = new Map()  # <addr, {enabled: bool, name: string|null}>

    @memWatchpoints = new Map() # <addr, {enabled: bool, name: string|null}>
    @_memWatchTriggered = null
    @watches = new Map() # <addr, {name: string, size: int, type: string}>

    @outputBuffer = []
    @rl = null
    @_pendingInputResolve = null
    @lastCommand = null # enter -> repeats @lastCommand
    @stopReason = null
    @executing = false

  out: (s) -> process.stdout.write s + "\n"
  error: (s) -> @out "#{C.red}*** #{s}#{C.reset}"
  info: (s) -> @out "#{C.cyan}#{s}#{C.reset}"
  dim: (s) -> @out "#{C.dim}#{s}#{C.reset}"

  #
  # Symbol resolution
  #
  resolveAddr: (s) ->
    # returns actual address of hex string or symbol
    s = s.trim()
    if s.match(/^(0x)?[0-9a-fA-F]+$/)
      return parseInt(s.replace(/^0x/i, ''), 16)
    if @age.sym.symbols?
      for sym in (@age.sym.symbols.symbols or [])
        if sym.name == s.toUpperCase()
          return sym.address
    return null

  formatAddr: (addr) ->
    label = @age.sym.getLabelAt?(addr)
    if label
      return "#{addr.asHex(5)} <#{C.yellow}#{label}#{C.reset}>"
    sect = @age.sym.getSectionAt?(addr)
    if sect
      for s in @age.sym.sectionsByAddr
        if s.name == sect
          offset = addr - s.address
          return "#{addr.asHex(5)} <#{sect}+#{offset.asHex(3)}>"
    return addr.asHex(5)

  formatAddrPlain: (addr) ->
    label = @age.sym.getLabelAt?(addr)
    if label then "#{addr.asHex(5)} <#{label}>" else addr.asHex(5)

  load: ->
    { byteCount, entryPoint, symbolsPath } = @age.configureFromOpts(@fcmPath, @opts)
    @entryPoint = entryPoint
    @symbolsPath = symbolsPath
    unless @entryPoint?
      @error "No entry point: use --start=ADDR or provide symbols"
      process.exit(1)
    return byteCount

  #
  # I/O
  #
  initIO: ->
    @iohost.init(@age.sym.symbols, @age.sym.symTypes)

    # Customize: collect output in buffer for display between stops
    @iohost.outputCallback = (text, channel) =>
      @outputBuffer.push text

    @age.halUCP.controlCallback = (iocode, param, channel) => @handleControl(iocode, param, channel)

  handleControl: (iocode, param, channel) ->
    ch = channel.toString()
    text = switch iocode
      when 0, 1, 2, 3 then '\n'
      when 4 then '\n'.repeat(Math.max(1, param))      # LINE
      when 5 then ' '.repeat(Math.max(0, param))       # COLUMN
      when 6 then ' '.repeat(Math.max(1, param) * 5)   # TAB
      when 7 then '\n--- PAGE ---\n'                   # PAGE
      when 8 then '\n'.repeat(Math.max(1, param))      # SKIP
      else ''
    if @iohost.outStreams[ch]?
      @iohost.outStreams[ch].write(text)
    @outputBuffer.push text

  flushOutput: ->
    if @outputBuffer.length > 0
      combined = @outputBuffer.join('')
      if combined.length > 0
        @out "#{C.green}#{combined}#{C.reset}"
      @outputBuffer = []

  formatSectionOffset: (addr) ->
    return @age.sym.formatCSect?(addr) or ""

  _formatTraceLine: (step, nia, hw1, hw2, disasm, instrLen, changes) ->
    formatTraceLine(step, nia, hw1, hw2, disasm, instrLen, changes, { color: C, sym: @age.sym })

  #
  #  Exec loop
  #
  execOne: ->
    # Sync step counter
    @age._syncStep()

    nia = @age.cpu.psw.getNIA()

    # Check I/O trap
    if @age.halUCP.active and @age.halUCP.isTrapAddr(nia)
      result = @age.halUCP.checkTrap(nia)
      if @age.halUCP.waitingForInput
        return 'input'

    watchBefore = null
    if @memWatchpoints.size > 0
      watchBefore = new Map()
      @memWatchpoints.forEach (wp, addr) =>
        if wp.enabled
          watchBefore.set(addr, @age.mainStorage.get16(addr, false))

    before = @age.snapshotRegs()
    hw1 = @age.mainStorage.get16(nia)
    hw2 = @age.mainStorage.get16(nia + 1)
    disasm = Instruction.toStr(hw1, hw2)
    [d, v] = Instruction.decode(hw1, hw2)
    instrLen = if d? then d.origLen else 1

    unless d?
      @out @_formatTraceLine(@age.stepCount, nia, hw1, hw2, "??? (invalid)", 1, [])
      @stopReason = "invalid instruction 0x#{hw1.asHex(4)} at #{@formatAddrPlain(nia)}"
      return 'error'

    @age.gpc.exec1()
    @age.stepCount++

    after = @age.snapshotRegs()
    changes = @age.diffRegs(before, after)
    changes = changes.filter (c) -> c.name != 'NIA'

    if @traceEnabled
      relocSym = @age.sym.getRelocAt?(nia, instrLen)
      relocComment = if relocSym then "  #{C.dim}; #{relocSym}#{C.reset}" else ""
      @out @_formatTraceLine(@age.stepCount - 1, nia, hw1, hw2, disasm, instrLen, changes) + relocComment

    if watchBefore?
      @memWatchpoints.forEach (wp, addr) =>
        return unless wp.enabled
        oldVal = watchBefore.get(addr)
        return unless oldVal?
        newVal = @age.mainStorage.get16(addr, false)
        if oldVal != newVal
          wpName = if wp.name then " (#{wp.name})" else ""
          @_memWatchTriggered = {
            addr, name: wpName
            old: oldVal, new: newVal
            triggerNia: nia
            triggerStep: @age.stepCount - 1
            triggerDisasm: disasm
          }

    if @age.halUCP.svcTrapped
      @age.halUCP.svcTrapped = false
      @stopReason = "SVC trapped"
      return 'svc'

    if @age.cpu.psw.getWaitState()
      @stopReason = "wait state (program halted)"
      return 'halt'

    if @_memWatchTriggered?
      return 'watchpoint'

    return 'ok'

  _handleExecResult: (result) ->
    if result == 'error' or result == 'halt' or result == 'svc'
      return true
    if result == 'watchpoint'
      wp = @_memWatchTriggered
      @_memWatchTriggered = null
      @stopReason = "memory watchpoint: HW #{wp.addr.asHex(5)}#{wp.name} changed #{wp.old.asHex(4)} -> #{wp.new.asHex(4)} at step #{wp.triggerStep} (#{wp.triggerDisasm})"
      return true
    return false  # 'ok'

  # Async-resumable execution loop.
  _execLoop: (maxCount, onDone) ->
    ran = 0
    while ran < maxCount
      if ran > 0
        nextNia = @age.cpu.psw.getNIA()
        bp = @breakpoints.get(nextNia)
        if bp?.enabled
          @stopReason = "breakpoint at #{@formatAddrPlain(nextNia)}"
          break

      result = @execOne()
      if result == 'input'
        @flushOutput()
        @_handleInput(maxCount - ran, onDone)
        return  # resumes asynchronously via _handleInput callback
      ran++
      break if @_handleExecResult(result)

    @flushOutput()
    onDone?(ran)

  _handleInput: (remainingCount, onDone) ->
    ch = '0'
    # Try file input first
    if @iohost.hasFileInput(ch)
      line = @iohost.readInputLine(ch)
      @age.halUCP.provideInput(line)
      @_execLoop(remainingCount, onDone)
      return

    iocode = @age.halUCP.pendingIocode
    typeName = HalUCP.iocodeTypeName(iocode)
    @rl.question "#{C.green} INPUT(#{typeName}): #{C.reset}", (line) =>
      @age.halUCP.provideInput(line)
      @_execLoop(remainingCount, onDone)

  _execDone: ->
    @showStatus()
    @executing = false
    @rl.prompt()

  # ---------------------------------------------------------------
  # Display commands
  # ---------------------------------------------------------------
  showRegisters: ->
    for line in formatRegDump(@age.cpu, @age.stepCount, { color: C })
      @out line

  showRegister: (name) ->
    name = name.toUpperCase()
    grSet = @age.cpu.psw.getRegSet()
    if name.match(/^R(\d+)$/)
      i = parseInt(RegExp.$1)
      if i >= 0 and i <= 7
        val = @age.cpu.regFiles[grSet].r(i).get32()
        @out "  #{name} = 0x#{(val >>> 0).asHex(8)} (#{val})"
        return
    if name.match(/^FP(\d+)$/)
      i = parseInt(RegExp.$1)
      if i >= 0 and i <= 7
        val = @age.cpu.regFiles[2].r(i).get32()
        @out "  #{name} = 0x#{(val >>> 0).asHex(8)}"
        return
    if name == 'NIA'
      @out "  NIA = #{@age.cpu.psw.getNIA().asHex(5)}"
      return
    if name == 'CC'
      @out "  CC = #{@age.cpu.psw.getCC()}"
      return
    if name == 'PSW1'
      @out "  PSW1 = 0x#{(@age.cpu.psw.psw1.get32() >>> 0).asHex(8)}"
      return
    if name == 'PSW2'
      @out "  PSW2 = 0x#{(@age.cpu.psw.psw2.get32() >>> 0).asHex(8)}"
      return
    if name == 'BSR'
      @out "  BSR = #{@age.cpu.psw.getBSR()}"
      return
    if name == 'DSR'
      @out "  DSR = #{@age.cpu.psw.getDSR()}"
      return
    @error "Unknown register: #{name}"

  showDisasm: (startAddr, count=20) ->
    startAddr ?= @age.cpu.psw.getNIA()
    addr = startAddr
    nia = @age.cpu.psw.getNIA()
    for i in [0...count]
      break if addr >= 0x80000
      hw1 = @age.mainStorage.get16(addr)
      hw2 = @age.mainStorage.get16(addr + 1)
      [d, v] = Instruction.decode(hw1, hw2)

      marker = if addr == nia then "#{C.bgRed}>>#{C.reset}" else "  "
      bp = @breakpoints.get(addr)
      bpMark = if bp?.enabled then "#{C.red}*#{C.reset}" else " "
      label = @age.sym.getLabelAt?(addr)
      if label
        @out "#{C.yellow}                          #{label}:#{C.reset}"

      if d?
        instrLen = d.len
        disasmStr = Instruction.toStr(hw1, hw2)
        hw1Str = hw1.asHex(4)
        hw2Str = if instrLen > 1 then hw2.asHex(4) else "    "
        relocSym = @age.sym.getRelocAt?(addr, instrLen)
        comment = if relocSym then "  #{C.dim}; #{relocSym}#{C.reset}" else ""
        @out "#{marker}#{bpMark}#{addr.asHex(5)}: #{hw1Str} #{hw2Str}  #{disasmStr}#{comment}"
      else
        @out "#{marker}#{bpMark}#{addr.asHex(5)}: #{hw1.asHex(4)}       DC    X'#{hw1.asHex(4)}'"
        instrLen = 1
      addr += instrLen

  showMemory: (startAddr, count=16, format='hex') ->
    addr = startAddr & 0x7ffff
    row = 0
    while row < count
      rowAddr = addr + row
      hexParts = []
      asciiParts = []
      cols = Math.min(8, count - row)
      for col in [0...cols]
        a = rowAddr + col
        hw = @age.mainStorage.get16(a)
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
    val = @age.mainStorage.get32(addr)
    @out "  #{addr.asHex(5)}: #{val.asHex(8)} (int32: #{val | 0}, uint32: #{val})"

  showWatches: ->
    if @watches.size == 0
      @dim "  (no watches)"
      return
    @watches.forEach (w, addr) =>
      val = @age.mainStorage.get16(addr, false)
      if w.size >= 2
        fw = @age.mainStorage.get32(addr, false)
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
      val = @age.mainStorage.get16(addr, false)
      @out "  [#{status}] #{@formatAddr(addr)}#{name} = #{val.asHex(4)}"

  showSections: ->
    unless @age.sym.sectionsByAddr?.length > 0
      @dim "  (no symbols loaded)"
      return
    @out "#{C.bold}--- Section Map ---#{C.reset}"
    for sect in @age.sym.sectionsByAddr
      endAddr = sect.address + sect.size - 1
      @out "  #{sect.address.asHex(5)} - #{endAddr.asHex(5)}  #{sect.name.rpad(' ', 14)} (#{sect.size} HW, #{sect.module})"
    if @entryPoint?
      @out "  Entry: #{@formatAddr(@entryPoint)}"

  showSymbol: (name) ->
    unless @age.sym.symbols?
      @error "No symbols loaded"
      return
    name = name.toUpperCase()
    found = false
    for sym in (@age.sym.symbols.symbols or [])
      if sym.name == name or sym.name.indexOf(name) >= 0
        addr = sym.address
        sect = @age.sym.getSectionAt?(addr) or "?"
        @out "  #{C.cyan}#{sym.name}#{C.reset}  addr=#{addr.asHex(5)}  type=#{sym.type}  section=#{sect}"
        found = true
    unless found
      @error "Symbol not found: #{name}"

  showCurrentLocation: ->
    nia = @age.cpu.psw.getNIA()
    hw1 = @age.mainStorage.get16(nia)
    hw2 = @age.mainStorage.get16(nia + 1)
    disasm = Instruction.toStr(hw1, hw2)
    [d, v] = Instruction.decode(hw1, hw2)
    instrLen = if d? then d.len else 1
    hw2Str = if instrLen > 1 then hw2.asHex(4) else "    "
    sect = @formatSectionOffset(nia)
    @out "#{C.bold}>>#{C.reset} #{nia.asHex(5)} #{sect}: #{hw1.asHex(4)} #{hw2Str}  #{C.bold}#{disasm}#{C.reset}"

  showStatus: ->
    if @stopReason?
      @out "#{C.yellow}--- stopped: #{@stopReason} (#{@age.stepCount} steps) ---#{C.reset}"
      @stopReason = null
    @showCurrentLocation()
    if @watches.size > 0
      @showWatches()

  #
  # Commands
  #
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
        @executing = true
        @_execLoop count, => @_execDone()

    @repl.command('next')
      .alias('n')
      .description('Step over (run until next instruction)')
      .action =>
        nia = @age.cpu.psw.getNIA()
        hw1 = @age.mainStorage.get16(nia)
        hw2 = @age.mainStorage.get16(nia + 1)
        [d, v] = Instruction.decode(hw1, hw2)
        instrLen = if d? then d.origLen else 1
        nextAddr = nia + instrLen
        hadBp = @breakpoints.has(nextAddr)
        unless hadBp
          @breakpoints.set(nextAddr, { enabled: true, name: '__next__' })
        @executing = true
        @_execLoop @maxSteps, =>
          unless hadBp
            @breakpoints.delete(nextAddr)
          @_execDone()

    @repl.command('run')
      .aliases(['r', 'c', 'continue', 'g', 'go'])
      .description('Run until breakpoint/halt/watchpoint')
      .action =>
        @executing = true
        @_execLoop @maxSteps, (ran) =>
          if ran >= @maxSteps and not @stopReason
            @stopReason = "max steps reached (#{@maxSteps})"
          @_execDone()

    @repl.command('reset')
      .description('Reset CPU and reload program')
      .action =>
        @age.stepCount = 0
        @outputBuffer = []
        @age.halUCP.waitingForInput = false
        @age.halUCP.pendingIocode = null
        @age.halUCP.skipTrap = false
        @age.halUCP.svcTrapped = false
        @age.halUCP.active = false
        @load()
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
        @age.stepCount = 0
        @outputBuffer = []
        if not @symbolsPath?
          autoSymPath = @fcmPath.replace(/\.fcm$/i, '.sym.json')
          if autoSymPath != @fcmPath and fs.existsSync(autoSymPath)
            @symbolsPath = autoSymPath
        @load()
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
        label = @age.sym.getLabelAt?(addr)
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
        label = @age.sym.getLabelAt?(addr) or addrStr
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
        label = @age.sym.getLabelAt?(addr) or addrStr
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

    @repl.command('deposit')
      .aliases(['dep', 'dw'])
      .argument('<addr>', 'address or symbol')
      .argument('<values...>', 'hex values to write (halfwords by default)')
      .option('-w, --fullword', 'write as 32-bit fullwords')
      .description('Deposit values into memory')
      .action (addrStr, values, opts) =>
        addr = @resolveAddr(addrStr)
        unless addr?
          @error "Cannot resolve: #{addrStr}"
          return
        for valStr, idx in values
          val = parseInt(valStr.replace(/^0x/i, ''), 16)
          if isNaN(val)
            @error "Invalid hex value: #{valStr}"
            return
          if opts.fullword
            @age.mainStorage.set32(addr + (idx * 2), val, false)
            @info "  #{(addr + idx * 2).asHex(5)}: #{(val >>> 0).asHex(8)}"
          else
            @age.mainStorage.set16(addr + idx, val & 0xFFFF, false)
            @info "  #{(addr + idx).asHex(5)}: #{(val & 0xFFFF).asHex(4)}"

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

    # -- Misc --

    @repl.command('where')
      .aliases(['loc', 'here'])
      .description('Show current location')
      .action =>
        @showCurrentLocation()

    @repl.command('steps')
      .description('Show step count')
      .action =>
        @out "Step count: #{@age.stepCount}"

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
    grSet = @age.cpu.psw.getRegSet()
    if name.match(/^R(\d+)$/)
      i = parseInt(RegExp.$1)
      if i >= 0 and i <= 7
        @age.cpu.regFiles[grSet].r(i).set32(val)
        @info "#{name} = 0x#{(val >>> 0).asHex(8)}"
        return
    if name.match(/^FP(\d+)$/)
      i = parseInt(RegExp.$1)
      if i >= 0 and i <= 7
        @age.cpu.regFiles[2].r(i).set32(val)
        @info "#{name} = 0x#{(val >>> 0).asHex(8)}"
        return
    if name == 'NIA'
      @age.cpu.psw.setNIA(val)
      @info "NIA = #{val.asHex(5)}"
      return
    @error "Cannot set: #{name}"

  #
  # entry point
  #
  start: ->
    byteCount = @load()
    @initIO()
    @setupCommands()

    @out ""
    @out "#{C.bold}#{C.cyan}=== GPC Debugger ===#{C.reset}"
    @out "#{C.dim}FCM: #{@fcmPath} (#{byteCount} bytes)#{C.reset}"
    if @entryPoint?
      @out "#{C.dim}Entry: #{@formatAddr(@entryPoint)}#{C.reset}"
    if @age.sym.symbols?
      @out "#{C.dim}Symbols: #{@symbolsPath} (#{@age.sym.symbols.symbols?.length or 0} symbols, #{@age.sym.symbols.sections?.length or 0} sections)#{C.reset}"
    @out "#{C.dim}Type 'help' for commands#{C.reset}"
    @out ""

    @showSections() if @age.sym.sectionsByAddr?.length > 0
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
          if @age.sym.symbols? and word.length > 0
            syms = (@age.sym.symbols.symbols or [])
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

      @rl.prompt() unless @executing

    @rl.on 'close', =>
      try
        fs.writeFileSync @historyFile, @rl.history.slice(0, 1000).reverse().join('\n') + '\n'
      catch _e
        null  # ignore write errors
      @out "\nGoodbye."
      process.exit(0)

    @rl.prompt()


#
# cli command registration
#
export addCommand = (program) ->
  cmd = program.command('debug')
    .alias('dbg')
    .description('Interactive AP-101 debugger')
    .argument('<fcm-file>', 'FCM memory image to load')

  AGEHarness.addOptions(cmd)
  IOHost.addOptions(cmd, 3)

  cmd
    .option('--max-steps <n>', 'max instructions before auto-stop', '10000000')
    .option('--trace', 'enable instruction trace at startup')
    .action (fcmPath, o) ->
      debugger_ = new GPCDebugger(Object.assign({}, o, {
        fcmPath
        maxSteps: parseInt(o.maxSteps, 10)
        traceEnabled: o.trace or false
      }))
      debugger_.start()
