
# GPC Batch Mode Simulator
# Loads an FCM image and runs it with trace output
#
# Usage: node dist/batch/batch.js <fcm-file> <start-hex> [options]

fs = require 'fs'
path = require 'path'
readline = require 'readline'

require 'com/util'
import {CPU} from 'gpc/cpu'
import {MCM} from 'gpc/mcm'
import {MemoryBus} from 'gpc/membus'
import Instruction from 'gpc/cpu_instr'
import {HalUCP} from 'gpc/halUCP'

class BatchRunner
  constructor: (opts) ->
    @fcmPath = opts.fcmPath
    @entryPoint = opts.entryPoint ? null
    @maxSteps = opts.maxSteps ? 100000
    @breakpoint = opts.breakpoint ? null
    @memWatchpoints = opts.memWatchpoints ? []  # [{addr, count}]
    @watchLog = opts.watchLog ? false
    @outputPath = opts.outputPath ? null
    @dumpInterval = opts.dumpInterval ? 100
    @symbolsPath = opts.symbolsPath ? null
    @traceEnabled = opts.traceEnabled ? false
    @verbose = opts.verbose ? false
    @interactive = opts.interactive ? false
    @ebcdic = opts.ebcdic ? false
    @trapSvcError = opts.trapSvcError ? true
    @inFiles = opts.inFiles ? {}     # channel -> filename
    @outFiles = opts.outFiles ? {}   # channel -> filename

    @cpu = new CPU()
    @iopMCM = new MCM(24*1024)
    @cpu.ram = new MemoryBus(@cpu.mainStorage, @iopMCM)
    @halUCP = new HalUCP(@cpu)
    @cpu.halUCP = @halUCP
    @halUCP.trapSvcError = @trapSvcError
    @halUCP.formatNumBlanks = opts.formatNumBlanks ? 1
    @halUCP.lineWidth = opts.lineWidth ? 132
    @halUCP.verbose = @verbose
    @halUCP.errorCallback = (msg) -> process.stderr.write "\n*** " + msg + "\n\n"
    @lines = []
    @symbols = null
    @sectionsByAddr = []
    @symbolsByAddr = {}
    @addrToSection = {}

    # I/O state
    @inStreams = {}     # channel -> array of remaining lines
    @outStreams = {}    # channel -> fs write stream or null (stdout)
    @channelLinePos = {}  # channel -> current column position (for control codes)

  write: (s) ->
    if @outputPath?
      @lines.push s
    else
      process.stdout.write s + "\n"

  # Informational/state output — only emitted when --verbose is set.
  # All run-mode banners, section maps, register dumps at exit, etc. go
  # through this so that the default invocation produces only the program's
  # own input/output channel traffic.
  info: (s) ->
    @write(s) if @verbose

  flush: ->
    if @outputPath? and @lines.length > 0
      fs.writeFileSync @outputPath, @lines.join("\n") + "\n"
    # Close output file streams
    for ch, stream of @outStreams
      stream?.end?()

  # Fatal error: print message and exit
  fatal: (msg) ->
    process.stderr.write "FATAL: #{msg}\n"
    # Synchronously write any buffered channel output before exiting
    for ch, stream of @outStreams
      if stream? and not stream.destroyed
        try
          fd = stream.fd ? stream._writableState?.fd
          if fd? then fs.fdatasyncSync(fd)
        catch e
          # ignore sync errors
    @flush()
    process.exit(1)

  loadSymbols: ->
    return unless @symbolsPath?
    try
      json = fs.readFileSync(@symbolsPath, 'utf8')
      @symbols = JSON.parse(json)

      # Build lookup structures
      @sectionsByAddr = (@symbols.sections or []).slice()
      @sectionsByAddr.sort (a, b) -> a.address - b.address

      # Build symbol lookup by address
      @symbolsByAddr = {}
      for sym in (@symbols.symbols or [])
        addr = sym.address
        @symbolsByAddr[addr] ?= []
        @symbolsByAddr[addr].push sym

      # Build section membership index
      for sect in @sectionsByAddr
        for offset in [0...sect.size]
          @addrToSection[sect.address + offset] = sect.name

      @info "Symbols: #{@symbolsPath} (#{@symbols.symbols?.length or 0} symbols, #{@symbols.sections?.length or 0} sections)"

      # Resolve entry point from symbols if not explicitly set
      unless @entryPoint?
        # Look for START symbol first
        for sym in (@symbols.symbols or [])
          if sym.name == 'START' and sym.type == 'entry'
            @entryPoint = sym.address
            break
        # Fall back to entryPoint field in symbols JSON
        @entryPoint ?= @symbols.entryPoint
    catch e
      process.stderr.write "Warning: Could not load symbols: #{e.message}\n"

  getSymbolsAt: (addr) ->
    return @symbolsByAddr[addr] or []

  getSectionAt: (addr) ->
    return @addrToSection[addr] or null

  formatAddrWithSymbol: (addr) ->
    syms = @getSymbolsAt(addr)
    if syms.length > 0
      names = (s.name for s in syms)
      return "#{addr.asHex(6)} <#{names.join(', ')}>"
    sect = @getSectionAt(addr)
    if sect?
      for s in @sectionsByAddr
        if s.name == sect
          offset = addr - s.address
          if offset > 0
            return "#{addr.asHex(6)} <#{sect}+#{offset.asHex(2)}>"
          break
    return addr.asHex(6)

  loadFCM: ->
    image = fs.readFileSync @fcmPath
    buf = new ArrayBuffer(image.length)
    buf8 = new Uint8Array(buf)
    for i in [0...image.length]
      buf8[i] = image[i]
    dv = new DataView(buf)
    @cpu.ram.load16(0, dv)
    unless @entryPoint?
      @fatal "No entry point: use --start=ADDR or provide a symbols file with a START symbol"
    @cpu.psw.setNIA(@entryPoint)
    @cpu.psw.setWaitState(false)
    return dv.byteLength

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
    return val.asHex(8)

  formatSectionOffset: (addr) ->
    if not @symbols?
      return ""
    for sect in @sectionsByAddr
      if addr >= sect.address and addr < sect.address + sect.size
        offset = addr - sect.address
        sectName = sect.name.slice(0, 8).toUpperCase().rpad(' ', 8)
        return "#{sectName}+#{offset.asHex(4)}"
    return "        +    "

  formatTraceLine: (step, nia, hw1, hw2, disasm, instrLen, changes) ->
    stepStr = step.toString().lpad(" ", 5)
    niaStr = nia.asHex(6)
    sectOffsetStr = ""
    if @symbols?
      sectOffsetStr = " " + @formatSectionOffset(nia)
    hw1Str = hw1.asHex(4)
    if instrLen > 1
      hw2Str = hw2.asHex(4)
    else
      hw2Str = "    "
    changesStr = ""
    if changes.length > 0
      parts = []
      for c in changes
        parts.push "#{c.name}: #{@formatRegVal(c.name, c.old)}->#{@formatRegVal(c.name, c.new)}"
      changesStr = parts.join(", ")
    return "[#{stepStr}] #{niaStr}#{sectOffsetStr}: #{hw1Str} #{hw2Str}  #{disasm.rpad(' ', 28)}#{changesStr}"

  formatRegDump: (step) ->
    lines = []
    lines.push "--- REGISTERS (step #{step}) ---"
    grSet = @cpu.psw.getRegSet()
    row = ""
    for i in [0..7]
      name = "R0#{i}"
      val = @cpu.regFiles[grSet].r(i).get32()
      row += "#{name}=#{val.asHex(8)} "
    lines.push row.trimEnd()
    row = ""
    for i in [0..7]
      val = @cpu.regFiles[2].r(i).get32()
      row += "FP#{i}=#{val.asHex(8)} "
    lines.push row.trimEnd()
    psw1 = @cpu.psw.psw1.get32()
    psw2 = @cpu.psw.psw2.get32()
    nia = @cpu.psw.getNIA()
    cc = @cpu.psw.getCC()
    lines.push "PSW1=#{psw1.asHex(8)} PSW2=#{psw2.asHex(8)} NIA=#{nia.asHex(4)} CC=#{cc} GR=#{grSet}"
    return lines

  # ---------------------------------------------------------------
  # I/O subsystem
  # ---------------------------------------------------------------

  initIO: ->
    # Initialize HalUCP from symbols
    @halUCP.initFromSymbols(@symbols)

    # Override encoding: default to ASCII unless --ebcdic was given
    unless @ebcdic
      @halUCP.iobufEncoding = 'ascii'

    # Load input files: read all lines up front
    for ch, filePath of @inFiles
      try
        content = fs.readFileSync(filePath, 'utf8')
        @inStreams[ch] = content.split('\n')
        # Remove trailing empty line from final newline
        if @inStreams[ch].length > 0 and @inStreams[ch][@inStreams[ch].length - 1] == ''
          @inStreams[ch].pop()
      catch e
        @fatal "Cannot open input file for channel #{ch}: #{filePath} (#{e.message})"

    # Open output file streams
    for ch, filePath of @outFiles
      try
        @outStreams[ch] = fs.createWriteStream(filePath)
      catch e
        @fatal "Cannot open output file for channel #{ch}: #{filePath} (#{e.message})"

    # Wire callbacks. HalUCP handles all WRITE positioning logic itself
    # (line wrap, IOINIT defaults, SKIP/LINE/PAGE/TAB/COLUMN) and emits the
    # resulting text — including newlines and column-advance spaces — via
    # outputCallback. There is no separate control callback path.
    @halUCP.outputCallback = (text, channel) => @handleOutput(text, channel)
    # inputCallback is set per-mode (sync for file, async for interactive)

  # In interactive mode, channel 6 (the conventional HAL/S WRITE target) is
  # treated exactly like the non-interactive path: raw bytes straight to
  # stdout, no "OUTPUT(ch):" prefix. Other channels keep the prefixed wrapper
  # so the source channel is still distinguishable.
  _useRawStdout: (ch) ->
    (not @interactive) or ch == '6'

  # Write output text to the appropriate destination
  handleOutput: (text, channel) ->
    ch = channel.toString()
    if @outStreams[ch]?
      @outStreams[ch].write(text)
    else if @_useRawStdout(ch)
      process.stdout.write text
    else
      process.stdout.write "OUTPUT(#{ch}): #{text}\n"

  # Format an echoed input line for stdout. Channel 5 (the conventional
  # HAL/S READ source) is shown bare so its echo blends with the program's
  # output stream like a real interactive session; other channels keep the
  # "INPUT(ch):" prefix to remain identifiable.
  _formatInputEcho: (ch, line) ->
    if ch == '5' then "#{line}\n" else " INPUT(#{ch}): #{line}\n"

  # Read one line from input for the given channel (file mode).
  # Returns the raw line text, or `null` on EOF — HalUCP will attempt
  # to dispatch to an ON ERROR$(IO:5) handler and halt if none is
  # installed. Field parsing and validation are handled by
  # HalUCP._extractNextField — this just supplies raw lines.
  readInputLine: (channel, iocode) ->
    ch = channel.toString()
    if not @inStreams[ch]?
      @fatal "Program requests input on channel #{ch} (#{HalUCP.iocodeTypeName(iocode)}) but no --infile#{ch} was provided"
    if @inStreams[ch].length == 0
      if @verbose
        process.stderr.write "HalUCP: Input exhausted on channel #{ch}\n"
      return null
    return @inStreams[ch].shift()

  # ---------------------------------------------------------------
  # Disassembly mode
  # ---------------------------------------------------------------

  disasm: (startAddr, endAddr) ->
    @loadSymbols()
    startAddr ?= @entryPoint ? 0
    byteCount = @loadFCM()
    hwCount = byteCount / 2
    if not endAddr?
      endAddr = hwCount - 1
      while endAddr > 0 and @cpu.mainStorage.get16(endAddr) == 0
        endAddr--
      endAddr++

    @write "=== GPC Disassembly ==="
    @write "FCM: #{@fcmPath} (#{byteCount} bytes, #{hwCount} halfwords)"
    @write "Range: 0x#{startAddr.asHex(4)} - 0x#{endAddr.asHex(4)}"
    if @symbols?
      @write "Entry Point: 0x#{@symbols.entryPoint?.asHex(4) or 'N/A'}"
    @write ""

    currentSection = null
    addr = startAddr
    while addr < endAddr
      if @symbols?
        for sect in @sectionsByAddr
          if sect.address == addr
            @write ""
            @write ";" + "=".repeat(60)
            @write "; SECTION: #{sect.name} (#{sect.size} halfwords, module: #{sect.module})"
            @write ";" + "=".repeat(60)
            currentSection = sect.name
            break

      syms = @getSymbolsAt(addr)
      if syms.length > 0
        for sym in syms
          typeStr = if sym.type == 'entry' then 'ENTRY' else 'LABEL'
          @write "                      #{sym.name}:  ; #{typeStr}"

      hw1 = @cpu.mainStorage.get16(addr)
      hw2 = @cpu.mainStorage.get16(addr + 1)
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

  # ---------------------------------------------------------------
  # Run mode (synchronous — file I/O or no I/O)
  # ---------------------------------------------------------------

  run: ->
    @loadSymbols()
    byteCount = @loadFCM()
    @initIO()

    # Wire synchronous input handler for file mode
    @halUCP.inputCallback = (channel, iocode) =>
      line = @readInputLine(channel, iocode)
      if line?
        @halUCP.provideInput(line)
      else
        @halUCP.provideEof()

    @info "=== GPC Batch Simulator ==="
    @info "FCM: #{@fcmPath} (#{byteCount} bytes)"
    @info "Entry: 0x#{@entryPoint.asHex(4)}"
    @info "Max steps: #{@maxSteps}"
    @info "Trace: #{if @traceEnabled then 'on' else 'off'}"
    if @breakpoint?
      @info "Breakpoint: 0x#{@breakpoint.asHex(4)}"
    @info ""

    if @symbols?
      @info "=== SECTION MAP ==="
      for sect in @sectionsByAddr
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
      before = @snapshotRegs()
      nia = @cpu.psw.getNIA()

      # Section transition
      if @traceEnabled and @symbols?
        currentSection = @getSectionAt(nia)
        if currentSection? and currentSection != lastSection
          @write "--- ENTERING: #{currentSection} ---"
          lastSection = currentSection

      # Breakpoint
      if @breakpoint? and nia == @breakpoint
        stopReason = "breakpoint at 0x#{nia.asHex(4)}"
        break

      hw1 = @cpu.mainStorage.get16(nia)
      hw2 = @cpu.mainStorage.get16(nia + 1)

      # Decode
      disasm = Instruction.toStr(hw1, hw2)
      [d, v] = Instruction.decode(hw1, hw2)
      instrLen = if d? then d.origLen else 1

      if not d?
        if @traceEnabled
          @write @formatTraceLine(step, nia, hw1, hw2, "??? (invalid)", 1, [])
        stopReason = "invalid instruction 0x#{hw1.asHex(4)} at 0x#{nia.asHex(4)}"
        break

      # Snapshot watched addresses before execution
      watchBefore = null
      if hasWatchpoints
        watchBefore = new Uint16Array(watchAddrs.length)
        for addr, idx in watchAddrs
          watchBefore[idx] = @cpu.mainStorage.get16(addr, false)

      # Check I/O trap before execution
      if @halUCP.active and @halUCP.isTrapAddr(nia)
        result = @halUCP.checkTrap(nia)

      @cpu.exec1()

      # Diff and trace
      after = @snapshotRegs()
      changes = @diffRegs(before, after)
      changes = changes.filter (c) -> c.name != 'NIA'

      if @traceEnabled
        @write @formatTraceLine(step, nia, hw1, hw2, disasm, instrLen, changes)

      step++

      if @traceEnabled and @dumpInterval > 0 and step % @dumpInterval == 0
        for line in @formatRegDump(step)
          @write line
        @write ""

      # Check memory watchpoints
      if watchBefore?
        for addr, idx in watchAddrs
          newVal = @cpu.mainStorage.get16(addr, false)
          if newVal != watchBefore[idx]
            section = @getSectionAt(nia)
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

      if @cpu.psw.getWaitState()
        stopReason = "wait state"
        break

    if not stopReason?
      stopReason = "max steps reached (#{@maxSteps})"

    @info "--- STOPPED after #{step} steps (reason: #{stopReason}) ---"
    @info "--- FINAL REGISTERS ---"
    for line in @formatRegDump(step)
      @info line

    @flush()

    # Exit with error if the program didn't halt cleanly
    if stopReason != "wait state"
      process.stderr.write "ERROR: #{stopReason}\n"
      process.exit(1)

  # ---------------------------------------------------------------
  # Interactive run mode (async — terminal I/O with readline)
  # ---------------------------------------------------------------

  runInteractive: ->
    @loadSymbols()
    byteCount = @loadFCM()
    @initIO()

    @info "=== GPC Interactive Simulator ==="
    @info "FCM: #{@fcmPath} (#{byteCount} bytes)"
    @info "Entry: 0x#{@entryPoint.asHex(4)}"
    @info "Trace: #{if @traceEnabled then 'on' else 'off'}"
    @info "(Ctrl-C to halt)"
    @info ""

    if @symbols?
      @info "=== SECTION MAP ==="
      for sect in @sectionsByAddr
        @info "  0x#{sect.address.asHex(4)} - 0x#{(sect.address + sect.size - 1).asHex(4)}  #{sect.name.rpad(' ', 12)} (#{sect.module})"
      @info "  Start: 0x#{@entryPoint.asHex(4)} (#{@formatSectionOffset(@entryPoint)})"
      @info ""

    @step = 0
    @stopReason = null
    @lastSection = null

    # Override input handler: for channels with files, read from file;
    # for others, prompt interactively.
    @halUCP.inputCallback = (channel, iocode) =>
      ch = channel.toString()
      if @inStreams[ch]?
        # File input for this channel
        line = @readInputLine(channel, iocode)
        if line?
          @halUCP.provideInput(line)
        else
          @halUCP.provideEof()
        # Continue executing
        @execLoop()
      else
        # Interactive input
        typeName = HalUCP.iocodeTypeName(iocode)
        @promptInput(channel, iocode, typeName)

    # Ctrl-C handler
    process.on 'SIGINT', =>
      @info "\n--- INTERRUPTED after #{@step} steps ---"
      @info "--- FINAL REGISTERS ---"
      for line in @formatRegDump(@step)
        @info line
      @flush()
      process.exit(0)

    @execLoop()

  promptInput: (channel, iocode, typeName) ->
    rl = readline.createInterface({ input: process.stdin, output: process.stdout, terminal: false })
    ch = channel.toString()

    # If the output cursor isn't at column 1, emit a newline so the
    # user's input appears on its own line (not jammed after WRITE text).
    if (@halUCP.column[6] ? 1) > 1
      process.stdout.write '\n'

    prompt = if ch == '5' then '' else " INPUT(#{ch}): "
    rl.question prompt, (answer) =>
      rl.close()
      @halUCP.provideInput(answer)
      # The prompt newline + user's Enter have moved the terminal to a
      # fresh line.  Tell HalUCP so the next WRITE(6) skips its default
      # line advance (avoiding a blank line).
      @halUCP.notifyInteractiveInput(6)
      @execLoop()

  execLoop: ->
    lastSection = @lastSection
    while @step < @maxSteps
      before = @snapshotRegs()
      nia = @cpu.psw.getNIA()

      if @traceEnabled and @symbols?
        currentSection = @getSectionAt(nia)
        if currentSection? and currentSection != lastSection
          @write "--- ENTERING: #{currentSection} ---"
          lastSection = currentSection

      if @breakpoint? and nia == @breakpoint
        @stopReason = "breakpoint at 0x#{nia.asHex(4)}"
        break

      hw1 = @cpu.mainStorage.get16(nia)
      hw2 = @cpu.mainStorage.get16(nia + 1)

      disasm = Instruction.toStr(hw1, hw2)
      [d, v] = Instruction.decode(hw1, hw2)
      instrLen = if d? then d.origLen else 1

      if not d?
        if @traceEnabled
          @write @formatTraceLine(@step, nia, hw1, hw2, "??? (invalid)", 1, [])
        @stopReason = "invalid instruction 0x#{hw1.asHex(4)} at 0x#{nia.asHex(4)}"
        break

      # Check I/O trap — if input is needed from terminal, the callback
      # will call promptInput which returns (async), breaking out of execLoop.
      if @halUCP.active and @halUCP.isTrapAddr(nia)
        result = @halUCP.checkTrap(nia)
        if @halUCP.waitingForInput
          # Async input pending — save state and return.
          # execLoop will be re-entered from promptInput callback.
          @lastSection = lastSection
          return

      @cpu.exec1()

      after = @snapshotRegs()
      changes = @diffRegs(before, after)
      changes = changes.filter (c) -> c.name != 'NIA'

      if @traceEnabled
        @write @formatTraceLine(@step, nia, hw1, hw2, disasm, instrLen, changes)

      @step++

      if @traceEnabled and @dumpInterval > 0 and @step % @dumpInterval == 0
        for line in @formatRegDump(@step)
          @write line
        @write ""

      if @cpu.psw.getWaitState()
        @stopReason = "wait state"
        break

    @lastSection = lastSection

    if not @stopReason?
      if @step >= @maxSteps
        @stopReason = "max steps reached (#{@maxSteps})"

    if @stopReason?
      @info "--- STOPPED after #{@step} steps (reason: #{@stopReason}) ---"
      @info "--- FINAL REGISTERS ---"
      for line in @formatRegDump(@step)
        @info line
      @flush()
      exitCode = if @stopReason == "wait state" then 0 else 1
      if exitCode != 0
        process.stderr.write "ERROR: #{@stopReason}\n"
      process.exit(exitCode)


# ---------------------------------------------------------------
# CLI parsing
# ---------------------------------------------------------------
{Command} = require 'commander'

parseHex = (s) -> parseInt(s.replace(/^0x/i, ''), 16)

program = new Command()
program
  .name('gpc-batch')
  .description('GPC Batch Simulator — run AP-101 programs')
  .showHelpAfterError(true)
  .argument('<fcm-file>', 'FCM memory image to load')
  .option('--start <addr>', 'start address in hex')
  .option('--max-steps <n>', 'max instructions to execute', '100000')
  .option('--break <addr>', 'stop at halfword address (hex)')
  .option('--watch <spec>', 'memory watchpoint: addr[:count] in hex (break on write)', (v, prev) ->
    prev ?= []
    [a, c] = v.split(':')
    prev.push { addr: parseInt(a.replace(/^0x/i,''),16), count: parseInt(c or '1', 10) }
    prev
  )
  .option('--output <file>', 'write trace/verbose output to file instead of stdout')
  .option('--dump-interval <n>', 'register dump every N steps (default: 100)', '100')
  .option('--symbols <file>', 'load symbol table JSON from linker')
  .option('--trace', 'enable instruction trace', false)
  .option('--no-trace', 'disable instruction trace (default)')
  .option('--verbose', 'print informational messages (banners, section maps, final state)', false)
  .option('--no-verbose', 'suppress informational messages (default)')
  .option('--interactive', 'interactive terminal I/O')
  .option('--ebcdic', 'use EBCDIC encoding for character I/O')
  .option('--trap-svc-error', 'intercept HAL/S SEND ERROR SVCs (default)', true)
  .option('--no-trap-svc-error', 'pass SEND ERROR SVCs to SVC handler')
  .option('--halucp-format-num-blanks <n>', 'blanks between WRITE output fields (default: 5)', '5')
  .option('--line-width <n>', 'WRITE line width for wrap (default: 132)', '132')
  .option('--disasm [end]', 'disassemble from start to END (hex)')
  .option('--infile0 <file>', 'read input for channel 0')
  .option('--infile1 <file>', 'read input for channel 1')
  .option('--infile2 <file>', 'read input for channel 2')
  .option('--infile3 <file>', 'read input for channel 3')
  .option('--infile4 <file>', 'read input for channel 4')
  .option('--infile5 <file>', 'read input for channel 5')
  .option('--infile6 <file>', 'read input for channel 6')
  .option('--infile7 <file>', 'read input for channel 7')
  .option('--outfile0 <file>', 'write output for channel 0')
  .option('--outfile1 <file>', 'write output for channel 1')
  .option('--outfile2 <file>', 'write output for channel 2')
  .option('--outfile3 <file>', 'write output for channel 3')
  .option('--outfile4 <file>', 'write output for channel 4')
  .option('--outfile5 <file>', 'write output for channel 5')
  .option('--outfile6 <file>', 'write output for channel 6')
  .option('--outfile7 <file>', 'write output for channel 7')
  .option('--watch-log', 'log every watchpoint change instead of breaking', false)
  .parse()

fcmPath = program.args[0]
o = program.opts()

# Build inFiles/outFiles maps from individual options
inFiles = {}
outFiles = {}
for ch in [0..7]
  inFiles[ch] = o["infile#{ch}"] if o["infile#{ch}"]
for ch in [0..7]
  outFiles[ch] = o["outfile#{ch}"] if o["outfile#{ch}"]

opts = {
  fcmPath
  entryPoint: if o.start then parseHex(o.start) else null
  maxSteps: parseInt(o.maxSteps, 10)
  breakpoint: if o.break then parseHex(o.break) else null
  memWatchpoints: o.watch or []
  watchLog: o.watchLog or false
  outputPath: o.output or null
  dumpInterval: parseInt(o.dumpInterval, 10)
  symbolsPath: o.symbols or null
  traceEnabled: o.trace
  verbose: o.verbose
  interactive: o.interactive or false
  ebcdic: o.ebcdic or false
  trapSvcError: o.trapSvcError
  formatNumBlanks: parseInt(o.halucpFormatNumBlanks, 10)
  lineWidth: parseInt(o.lineWidth, 10)
  inFiles
  outFiles
}

# Auto-detect symbols file if not specified
if not opts.symbolsPath?
  autoSymPath = fcmPath.replace(/\.fcm$/i, '.sym.json')
  if autoSymPath != fcmPath and fs.existsSync(autoSymPath)
    opts.symbolsPath = autoSymPath
    if o.verbose
      process.stderr.write "Auto-detected symbols: #{opts.symbolsPath}\n"

runner = new BatchRunner(opts)
if o.disasm?
  disasmEnd = if typeof o.disasm == 'string' then parseHex(o.disasm) else null
  runner.disasm(opts.entryPoint, disasmEnd)
else if opts.interactive
  runner.runInteractive()
else
  runner.run()
