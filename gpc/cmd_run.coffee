
# gpc run command
# executes a program loaded from a fcm, logging output
# to console
#
fs = require 'fs'
readline = require 'readline'

require 'com/util'
import {AGEHarness} from 'gpc/ageharness'
import {IOHost} from 'gpc/iohost'
import Instruction from 'gpc/cpu_instr'
import {HalUCP} from 'gpc/halUCP'
import {P as noColor, formatRegVal, formatTraceLine, formatRegDump} from 'gpc/trace'

export class BatchRunner
  constructor: (opts) ->
    @opts = opts
    @fcmPath = opts.fcmPath
    @maxSteps = opts.maxSteps ? 100000
    @breakpoint = opts.breakpoint ? null
    @memWatchpoints = opts.memWatchpoints ? []  # [{addr, count}]
    @watchLog = opts.watchLog ? false
    @outputPath = opts.outputPath ? null
    @dumpInterval = opts.dumpInterval ? 100
    @traceEnabled = opts.traceEnabled ? false
    @verbose = opts.verbose ? false
    @interactive = opts.interactive ? false

    @age = new AGEHarness()
    @age.halUCP.verbose = @verbose
    @age.halUCP.errorCallback = (msg) -> process.stderr.write "\n*** " + msg + "\n\n"

    @iohost = IOHost.fromOpts(@age.halUCP, opts)

    @lines = []

  write: (s) ->
    if @outputPath?
      @lines.push s
    else
      process.stdout.write s + "\n"

  info: (s) ->
    @write(s) if @verbose

  flush: ->
    if @outputPath? and @lines.length > 0
      fs.writeFileSync @outputPath, @lines.join("\n") + "\n"
    @iohost.close()

  fatal: (msg) ->
    process.stderr.write "FATAL: #{msg}\n"
    @flush()
    process.exit(1)

  load: ->
    # Process options, load FCM and symbols
    { byteCount, entryPoint, symbolsPath } = @age.configureFromOpts(@fcmPath, @opts)
    @entryPoint = entryPoint
    unless @entryPoint?
      @fatal "No entry point: use --start=ADDR or provide a symbols file with a START symbol"
    if @age.sym.symbols?
      @info "Symbols: #{symbolsPath} (#{@age.sym.symbols.symbols?.length or 0} symbols, #{@age.sym.symbols.sections?.length or 0} sections)"
    return byteCount

  formatSectionOffset: (addr) ->
    sym = @age.sym
    return "" unless sym.symbols?
    sect = sym.getSectionAt(addr)
    if sect?
      for s in sym.sectionsByAddr
        if s.name == sect
          offset = addr - s.address
          sectName = sect.slice(0, 8).toUpperCase().rpad(' ', 8)
          return "#{sectName}+#{offset.asHex(4)}"
    return "        +    "

  _formatTraceLine: (step, nia, hw1, hw2, disasm, instrLen, changes) ->
    stepStr = step.toString().lpad(" ", 5)
    niaStr = nia.asHex(6)
    sectOffsetStr = ""
    if @age.sym.symbols?
      sectOffsetStr = " " + @formatSectionOffset(nia)
    hw1Str = hw1.asHex(4)
    hw2Str = if instrLen > 1 then hw2.asHex(4) else "    "
    changesStr = ""
    if changes.length > 0
      parts = []
      for c in changes
        parts.push "#{c.name}: #{formatRegVal(c.name, c.old)}->#{formatRegVal(c.name, c.new)}"
      changesStr = parts.join(", ")
    return "[#{stepStr}] #{niaStr}#{sectOffsetStr}: #{hw1Str} #{hw2Str}  #{disasm.rpad(' ', 28)}#{changesStr}"

  _formatRegDump: (step) ->
    return formatRegDump(@age.cpu, step, { color: noColor })


  #
  # I/O
  #
  initIO: ->
    @iohost.init(@age.sym.symbols, @age.sym.symTypes)
    @iohost.outputCallback = (text, channel) => @handleOutput(text, channel)

  _useRawStdout: (ch) ->
    (not @interactive) or ch == '6'

  handleOutput: (text, channel) ->
    ch = channel.toString()
    if @iohost.outStreams[ch]?
      # IOHost already wrote to file stream
      return
    if @_useRawStdout(ch)
      process.stdout.write text
    else
      process.stdout.write "OUTPUT(#{ch}): #{text}\n"

  _formatInputEcho: (ch, line) ->
    if ch == '5' then "#{line}\n" else " INPUT(#{ch}): #{line}\n"

  readInputLine: (channel, iocode) ->
    ch = channel.toString()
    # No --infileN was provided at all — fatal.  (If a file was provided
    # but is exhausted, return null and let HAL/S detect EOF via its
    # ON ERROR$(IO:N) handler.)
    if not @iohost.hasFileConfigured(channel)
      @fatal "Program requests input on channel #{ch} (#{HalUCP.iocodeTypeName(iocode)}) but no --infile#{ch} was provided"
    return @iohost.readInputLine(channel)

  # 
  # Disassembly - used by gpc disasm
  # 
  disasm: (startAddr, endAddr) ->
    byteCount = @load()
    startAddr ?= @entryPoint ? 0
    hwCount = byteCount / 2
    if not endAddr?
      endAddr = hwCount - 1
      while endAddr > 0 and @age.mainStorage.get16(endAddr) == 0
        endAddr--
      endAddr++

    @write "=== GPC Disassembly ==="
    @write "FCM: #{@fcmPath} (#{byteCount} bytes, #{hwCount} halfwords)"
    @write "Range: 0x#{startAddr.asHex(4)} - 0x#{endAddr.asHex(4)}"
    if @age.sym.symbols?
      @write "Entry Point: 0x#{@age.sym.symbols.entryPoint?.asHex(4) or 'N/A'}"
    @write ""

    currentSection = null
    addr = startAddr
    while addr < endAddr
      if @age.sym.symbols?
        for sect in @age.sym.sectionsByAddr
          if sect.address == addr
            @write ""
            @write ";" + "=".repeat(60)
            @write "; SECTION: #{sect.name} (#{sect.size} halfwords, module: #{sect.module})"
            @write ";" + "=".repeat(60)
            currentSection = sect.name
            break

      syms = @age.sym.getSymbolsAt(addr)
      if syms.length > 0
        for sym in syms
          typeStr = if sym.type == 'entry' then 'ENTRY' else 'LABEL'
          @write "                      #{sym.name}:  ; #{typeStr}"

      hw1 = @age.mainStorage.get16(addr)
      hw2 = @age.mainStorage.get16(addr + 1)
      [d, v] = Instruction.decode(hw1, hw2)
      if d?
        instrLen = d.len
        disasmStr = Instruction.toStr(hw1, hw2)
        hw1Str = hw1.asHex(4)
        if instrLen > 1
          hw2Str = hw2.asHex(4)
        else
          hw2Str = "    "
        @write "#{addr.asHex(6)}: #{hw1Str} #{hw2Str}  #{disasmStr}"
      else
        @write "#{addr.asHex(6)}: #{hw1.asHex(4)}       DC    X'#{hw1.asHex(4)}'"
        instrLen = 1
      addr += instrLen

    @flush()

  #
  # Execute with no console input (ie 'batch')
  #
  run: ->
    byteCount = @load()
    @initIO()

    # Wire synchronous input handler for file mode
    @age.halUCP.inputCallback = (channel, iocode) =>
      line = @readInputLine(channel, iocode)
      if line?
        @age.halUCP.provideInput(line)
      else
        @age.halUCP.provideEof()

    @info "=== GPC Batch Simulator ==="
    @info "FCM: #{@fcmPath} (#{byteCount} bytes)"
    @info "Entry: 0x#{@entryPoint.asHex(4)}"
    @info "Max steps: #{@maxSteps}"
    @info "Trace: #{if @traceEnabled then 'on' else 'off'}"
    if @breakpoint?
      @info "Breakpoint: 0x#{@breakpoint.asHex(4)}"
    @info ""

    if @age.sym.symbols?
      @info "=== SECTION MAP ==="
      for sect in @age.sym.sectionsByAddr
        @info "  0x#{sect.address.asHex(4)} - 0x#{(sect.address + sect.size - 1).asHex(4)}  #{sect.name.rpad(' ', 12)} (#{sect.module})"
      @info "  Start: 0x#{@entryPoint.asHex(4)} (#{@formatSectionOffset(@entryPoint)})"
      @info ""

    step = 0
    stopReason = null
    lastSection = null
    # Build flat list of watched halfword addresses for fast checking
    watchAddrs = []
    for wp in @memWatchpoints
      for i in [0...wp.count]
        watchAddrs.push(wp.addr + i)
    hasWatchpoints = watchAddrs.length > 0

    while step < @maxSteps
      before = @age.snapshotRegs()
      nia = @age.cpu.psw.getNIA()

      # Trace when NIA jumps into a new CSECT:
      if @traceEnabled and @age.sym.symbols?
        currentSection = @age.sym.getSectionAt(nia)
        if currentSection? and currentSection != lastSection
          @write "--- ENTERING: #{currentSection} ---"
          lastSection = currentSection

      if @breakpoint? and nia == @breakpoint
        stopReason = "breakpoint at 0x#{nia.asHex(4)}"
        break

      hw1 = @age.mainStorage.get16(nia)
      hw2 = @age.mainStorage.get16(nia + 1)

      # Decode
      disasm = Instruction.toStr(hw1, hw2)
      [d, v] = Instruction.decode(hw1, hw2)
      instrLen = if d? then d.origLen else 1

      if not d?
        if @traceEnabled
          @write @_formatTraceLine(step, nia, hw1, hw2, "??? (invalid)", 1, [])
        stopReason = "invalid instruction 0x#{hw1.asHex(4)} at 0x#{nia.asHex(4)}"
        break

      watchBefore = null
      if hasWatchpoints
        watchBefore = new Uint16Array(watchAddrs.length)
        for addr, idx in watchAddrs
          watchBefore[idx] = @age.mainStorage.get16(addr, false)

      # Check I/O trap before execution
      if @age.halUCP.active and @age.halUCP.isTrapAddr(nia)
        result = @age.halUCP.checkTrap(nia)

      @age.gpc.exec1()

      after = @age.snapshotRegs()
      changes = @age.diffRegs(before, after)
      changes = changes.filter (c) -> c.name != 'NIA'

      if @traceEnabled
        @write @_formatTraceLine(step, nia, hw1, hw2, disasm, instrLen, changes)

      step++

      if @traceEnabled and @dumpInterval > 0 and step % @dumpInterval == 0
        for line in @_formatRegDump(step)
          @write line
        @write ""

      #
      # Watchpoints
      #
      if watchBefore?
        for addr, idx in watchAddrs
          newVal = @age.mainStorage.get16(addr, false)
          if newVal != watchBefore[idx]
            section = @age.sym.getSectionAt(nia)
            msg = "memory watchpoint: HW 0x#{addr.toString(16).padStart(5,'0')} " +
              "changed 0x#{watchBefore[idx].toString(16).padStart(4,'0')} -> " +
              "0x#{newVal.toString(16).padStart(4,'0')} " +
              "by #{disasm} at NIA=0x#{nia.toString(16).padStart(5,'0')} step=#{step}" +
              (if section then " (#{section})" else "") +
              " R0=#{after.R00.toString(16).padStart(8,'0')} " +
              "R1=#{after.R01.toString(16).padStart(8,'0')} " +
              "R3=#{after.R03.toString(16).padStart(8,'0')} " +
              "R5=#{after.R05.toString(16).padStart(8,'0')} " +
              "R7=#{after.R07.toString(16).padStart(8,'0')}"
            if @watchLog
              process.stderr.write msg + "\n"
              watchBefore[idx] = newVal
            else
              stopReason = msg
              break
        if stopReason?
          break

      if @age.cpu.psw.getWaitState()
        stopReason = "wait state"
        break

    if not stopReason?
      stopReason = "max steps reached (#{@maxSteps})"

    @info "--- STOPPED after #{step} steps (reason: #{stopReason}) ---"
    @info "--- FINAL REGISTERS ---"
    for line in @_formatRegDump(step)
      @info line

    @flush()

    if stopReason != "wait state"
      process.stderr.write "ERROR: #{stopReason}\n"
      process.exit(1)

  #
  # Execute with console input (ie 'interactive')
  #
  runInteractive: ->
    byteCount = @load()
    @initIO()

    @info "=== GPC Interactive Simulator ==="
    @info "FCM: #{@fcmPath} (#{byteCount} bytes)"
    @info "Entry: 0x#{@entryPoint.asHex(4)}"
    @info "Trace: #{if @traceEnabled then 'on' else 'off'}"
    @info "(Ctrl-C to halt)"
    @info ""

    if @age.sym.symbols?
      @info "=== SECTION MAP ==="
      for sect in @age.sym.sectionsByAddr
        @info "  0x#{sect.address.asHex(4)} - 0x#{(sect.address + sect.size - 1).asHex(4)}  #{sect.name.rpad(' ', 12)} (#{sect.module})"
      @info "  Start: 0x#{@entryPoint.asHex(4)} (#{@formatSectionOffset(@entryPoint)})"
      @info ""

    @step = 0
    @stopReason = null
    @lastSection = null

    # attach channels without files to the console:
    @age.halUCP.inputCallback = (channel, iocode) =>
      ch = channel.toString()
      if @iohost.hasFileInput(channel)
        line = @iohost.readInputLine(channel)
        if line?
          @age.halUCP.provideInput(line)
        else
          @age.halUCP.provideEof()
        @execLoop()
      else
        typeName = HalUCP.iocodeTypeName(iocode)
        @promptInput(channel, iocode, typeName)

    process.on 'SIGINT', =>
      @info "\n--- INTERRUPTED after #{@step} steps ---"
      @info "--- FINAL REGISTERS ---"
      for line in @_formatRegDump(@step)
        @info line
      @flush()
      process.exit(0)

    @execLoop()

  promptInput: (channel, iocode, typeName) ->
    rl = readline.createInterface({ input: process.stdin, output: process.stdout, terminal: false })
    ch = channel.toString()

    # If the output cursor isn't at column 1, emit a newline so the
    # user's input appears on its own line (not jammed after WRITE text).
    if (@age.halUCP.column[6] ? 1) > 1
      process.stdout.write '\n'

    prompt = if ch == '5' then '' else " INPUT(#{ch}): "
    rl.question prompt, (answer) =>
      rl.close()
      @age.halUCP.provideInput(answer)
      # The prompt newline + user's Enter have moved the terminal to a
      # fresh line.  Tell HalUCP so the next WRITE(6) skips its default
      # line advance (avoiding a blank line).
      @age.halUCP.notifyInteractiveInput(6)
      @execLoop()

  execLoop: ->
    lastSection = @lastSection
    while @step < @maxSteps
      before = @age.snapshotRegs()
      nia = @age.cpu.psw.getNIA()

      if @traceEnabled and @age.sym.symbols?
        currentSection = @age.sym.getSectionAt(nia)
        if currentSection? and currentSection != lastSection
          @write "--- ENTERING: #{currentSection} ---"
          lastSection = currentSection

      if @breakpoint? and nia == @breakpoint
        @stopReason = "breakpoint at 0x#{nia.asHex(4)}"
        break

      hw1 = @age.mainStorage.get16(nia)
      hw2 = @age.mainStorage.get16(nia + 1)

      disasm = Instruction.toStr(hw1, hw2)
      [d, v] = Instruction.decode(hw1, hw2)
      instrLen = if d? then d.origLen else 1

      if not d?
        if @traceEnabled
          @write @_formatTraceLine(@step, nia, hw1, hw2, "??? (invalid)", 1, [])
        @stopReason = "invalid instruction 0x#{hw1.asHex(4)} at 0x#{nia.asHex(4)}"
        break

      # Check I/O trap — if input is needed from terminal, the callback
      # will call promptInput which returns (async), breaking out of execLoop.
      if @age.halUCP.active and @age.halUCP.isTrapAddr(nia)
        result = @age.halUCP.checkTrap(nia)
        if @age.halUCP.waitingForInput
          # Async input pending — save state and return.
          # execLoop will be re-entered from promptInput callback.
          @lastSection = lastSection
          return

      @age.gpc.exec1()

      after = @age.snapshotRegs()
      changes = @age.diffRegs(before, after)
      changes = changes.filter (c) -> c.name != 'NIA'

      if @traceEnabled
        @write @_formatTraceLine(@step, nia, hw1, hw2, disasm, instrLen, changes)

      @step++

      if @traceEnabled and @dumpInterval > 0 and @step % @dumpInterval == 0
        for line in @_formatRegDump(@step)
          @write line
        @write ""

      if @age.cpu.psw.getWaitState()
        @stopReason = "wait state"
        break

    @lastSection = lastSection

    if not @stopReason?
      if @step >= @maxSteps
        @stopReason = "max steps reached (#{@maxSteps})"

    if @stopReason?
      @info "--- STOPPED after #{@step} steps (reason: #{@stopReason}) ---"
      @info "--- FINAL REGISTERS ---"
      for line in @_formatRegDump(@step)
        @info line
      @flush()
      exitCode = if @stopReason == "wait state" then 0 else 1
      if exitCode != 0
        process.stderr.write "ERROR: #{@stopReason}\n"
      process.exit(exitCode)


# ---------------------------------------------------------------
# `gpc run` subcommand registration
# ---------------------------------------------------------------
parseHex = (s) -> parseInt(s.replace(/^0x/i, ''), 16)

export addCommand = (program) ->
  cmd = program.command('run')
    .description('Run an AP-101 program in batch mode')
    .argument('<fcm-file>', 'FCM memory image to load')

  AGEHarness.addOptions(cmd)
  IOHost.addOptions(cmd)

  cmd
    .option('--max-steps <n>', 'max instructions to execute', '100000')
    .option('--break <addr>', 'stop at halfword address (hex)')
    .option('--watch <spec>', 'memory watchpoint: addr[:count] in hex', (v, prev) ->
      prev ?= []
      [a, c] = v.split(':')
      prev.push { addr: parseInt(a.replace(/^0x/i,''),16), count: parseInt(c or '1', 10) }
      prev
    )
    .option('--output <file>', 'write trace/verbose output to file instead of stdout')
    .option('--dump-interval <n>', 'register dump every N steps (default: 100)', '100')
    .option('--trace', 'enable instruction trace', false)
    .option('--no-trace', 'disable instruction trace (default)')
    .option('--verbose', 'print informational messages', false)
    .option('--no-verbose', 'suppress informational messages (default)')
    .option('--interactive', 'interactive terminal I/O')
    .option('--watch-log', 'log every watchpoint change instead of breaking', false)
    .action (fcmPath, o) ->
      runner = new BatchRunner(Object.assign({}, o, {
        fcmPath
        maxSteps: parseInt(o.maxSteps, 10)
        breakpoint: if o.break then parseHex(o.break) else null
        memWatchpoints: o.watch or []
        watchLog: o.watchLog or false
        outputPath: o.output or null
        dumpInterval: parseInt(o.dumpInterval, 10)
        traceEnabled: o.trace
        interactive: o.interactive or false
      }))
      if o.interactive then runner.runInteractive() else runner.run()
