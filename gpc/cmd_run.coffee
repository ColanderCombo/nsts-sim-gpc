
# gpc run command
# executes a program loaded from a fcm, logging output
# to console
#
fs = require 'fs'
readline = require 'readline'

require 'com/util'
import {AGEHarness} from 'gpc/ageharness'
import {checkFCMFits, parseCPUModelOption} from 'gpc/machine'
import {CPU} from 'gpc/cpu'
import {MSCInstruction} from 'gpc/iop_msc_instr'
import {BCEInstruction} from 'gpc/iop_bce_instr'
import {IOHost} from 'gpc/iohost'
import Instruction from 'gpc/cpu_instr'
import {HalUCP} from 'gpc/halUCP'
import {RTPacer} from 'gpc/rtpacer'
import {P as noColor, formatRegVal, formatTraceLine, formatRegDump} from 'gpc/trace'

# NSTS_PC_TRACE: addresses to count arrivals at, as hex halfword addresses.
PC_TRACE = do ->
  v = process?.env?.NSTS_PC_TRACE
  return null unless v
  t = {}
  t[parseInt(x.trim().replace(/^0x/i, ''), 16)] = 0 for x in v.split(',') when x.trim()
  t

export class BatchRunner
  constructor: (opts) ->
    @opts = opts
    @fcmPath = opts.fcmPath
    @maxSteps = opts.maxSteps ? 100000
    @maxSteps = Infinity if @maxSteps <= 0
    @realTime = opts.realTime ? false
    @rtFactor = opts.rtFactor ? 1.0
    @rtIdleTimeoutMs = (opts.rtIdleTimeout ? 10) * 1000
    @breakpoint = opts.breakpoint ? null
    @pcTraceWall = Date.now()
    @memWatchpoints = opts.memWatchpoints ? []  # [{addr, count}]
    @watchLog = opts.watchLog ? false
    @outputPath = opts.outputPath ? null
    @dumpInterval = opts.dumpInterval ? 100
    @traceEnabled = opts.traceEnabled ? false
    @verbose = opts.verbose ? false
    @interactive = opts.interactive ? false
    @breakOnInterrupt = opts.breakOnInterrupt ? false
    @iopTrace = opts.iopTrace ? null       # [processor numbers] or null

    @age = new AGEHarness(gpc: opts.gpc)
    @age.cpu.model = parseCPUModelOption(opts.cpuModel) if opts.cpuModel?
    # Interrupts are invisible in a trace otherwise: an unexplained jump
    # into a PSA handler.  Note every acceptance, and stop at one when
    # asked to.
    @intTaken = null
    @age.cpu.onInterrupt = (entry) =>
      @intTaken = entry
      if @traceEnabled
        codeLabel = @age.cpu.intCodeLabel(entry.key, entry.code)
        codeStr =
          if entry.code? and codeLabel? then " (code #{entry.code.asHex(4)}, #{codeLabel})"
          else if entry.code? then " (code #{entry.code.asHex(4)})"
          else ""
        @write "*** #{entry.label}: #{entry.fromNIA.asHex(5)} -> #{entry.toNIA.asHex(5)}" +
               codeStr + " at #{(entry.timeNs / 1e6).toFixed(3)} ms"

    @age.cpu.setInterruptHold(opts.holdInterrupt ? false)
    @age.cpu.onInterruptHold = (held) =>
      if @traceEnabled
        @write "*** #{held.label} HELD before PSW swap at #{held.fromNIA.asHex(5)}" +
               " (would swap to #{held.toNIA.asHex(5)})"

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

  _startIOPTrace: () ->
    iop = @age.gpc.iop
    iop.traceProcs = {}
    iop.traceProcs[p] = true for p in @iopTrace
    msc = new MSCInstruction()
    bce = new BCEInstruction()
    last = {}
    traceWall0 = Date.now()

    regs = (page) ->
      r16 = (bank, word) -> iop.ls.at(page, bank, word)?.get16() ? 0
      r32 = (bank, word) -> iop.ls.at(page, bank, word)?.get32() ? 0
      hex = (v, n) -> (v >>> 0).toString(16).padStart(n, '0')
      if page == 0
        "A=#{hex((r16(1,3) << 16 >>> 0) + r16(2,3), 8)} X=#{hex(r32(0,3), 5)}" +
        " MST=#{hex(r16(2,7), 4)}"
      else
        "D=#{hex((r16(1,0) << 16 >>> 0) + r16(2,0), 8)} BASE=#{hex(r32(2,3), 5)}" +
        " IUA=#{hex(r32(2,5), 2)} BST=#{hex((r16(2,6) << 16 >>> 0) + r16(2,7), 8)}"
    iop.onProcStep = (page, pc, hw1, hw2) =>
      d = if page == 0 then msc.toStr(hw1, hw2) else bce.toStr(hw1, hw2)
      name = if page == 0 then 'MSC ' else "BCE#{page}"
      # Collapse a processor sitting on one instruction into a count 
      k = "#{page}:#{pc}"
      if last.key == k
        last.n += 1
        return
      if last.key? and last.n > 1
        ms = (Date.now() - last.wall)
        process.stderr.write "        #{last.name} #{last.pc}  " +
          "... #{last.n} times (#{ms} ms wall)\n"
      last = {key: k, n: 1, name: name, pc: pc.toString(16).padStart(5, '0'),
              wall: Date.now()}
      us = (@age.cpu.timeNs / 1000).toFixed(1).padStart(11)
      w = ((Date.now() - traceWall0) / 1000).toFixed(3).padStart(8)
      process.stderr.write "#{us} us #{w} w  #{name} #{pc.toString(16).padStart(5,'0')}  " +
        "#{hw1.toString(16).padStart(4,'0')} #{hw2.toString(16).padStart(4,'0')}  " +
        "#{@formatSectionOffset?(pc) ? ''}  #{d.text.padEnd(22)}  #{regs(page)}\n"
      return

  _heldStopReason: () ->
    h = @age.cpu.heldInterrupt()
    "interrupt held before PSW swap: #{h.label} at 0x#{h.fromNIA.asHex(5)}" +
      " (would swap to 0x#{h.toNIA.asHex(5)})"

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
    { byteCount, entryPoint, entrySource, symbolsPath, entryWarning,
      protectWarning } = @age.configureFromOpts(@fcmPath, @opts)
    @entryPoint = entryPoint
    @entrySource = entrySource
    if entrySource == 'ipl'
      @info "Load FCMBOOT from MMU, enter from PSW at PSA 0x#{CPU.SYSTEM_RESET_PSW.asHex(4)}"
    else if entrySource == 'sys-reset'
      @info "Entry from system reset PSW at PSA 0x#{CPU.SYSTEM_RESET_PSW.asHex(4)}"
    else if entrySource == 'power-on'
      why = if @opts.powerOn then '--power-on' else 'no --start, no START symbol'
      @info "Entry from power-on PSW at PSA 0x#{CPU.POWER_ON_PSW.asHex(4)} (#{why})"
    process.stderr.write "Warning: #{entryWarning}\n" if entryWarning?
    process.stderr.write "Warning: #{protectWarning}\n" if protectWarning?
    if @age.sym.symbols?
      @info "Symbols: #{symbolsPath} (#{@age.sym.symbols.symbols?.length or 0} symbols, #{@age.sym.symbols.sections?.length or 0} sections)"
    return byteCount

  icRelNote: (d, v, addr) ->
    target = Instruction.icRelTarget(d, v, addr)
    return "" unless target?
    label = @age.sym.getLabelAt?(target)
    "   ; -> X'#{target.asHex(4)}'" + (if label then " <#{label}>" else "")

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
    # No --infileN was provided at all: fatal.  (If a file was provided
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
        disasmStr = Instruction.toStr(hw1, hw2) + @icRelNote(d, v, addr)
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
    @info "FCM: #{@fcmPath ? '(none -- the IPL loads the machine)'} (#{byteCount} bytes)"
    # Not known yet under --ipl: the IPL picks it, and says so.
    @info "Entry: 0x#{@entryPoint.asHex(4)}" unless @opts.ipl
    @info "Max steps: #{@maxSteps}"
    @info "Trace: #{if @traceEnabled then 'on' else 'off'}"
    if @realTime
      @info "Real-time: on (factor #{@rtFactor})"
    if @breakpoint?
      @info "Breakpoint: 0x#{@breakpoint.asHex(4)}"
    @info ""

    if @age.sym.symbols?
      @info "=== SECTION MAP ==="
      for sect in @age.sym.sectionsByAddr
        @info "  0x#{sect.address.asHex(4)} - 0x#{(sect.address + sect.size - 1).asHex(4)}  #{sect.name.rpad(' ', 12)} (#{sect.module})"
      @info "  Start: 0x#{@entryPoint.asHex(4)} (#{@formatSectionOffset(@entryPoint)})" unless @opts.ipl
      @info ""

    step = 0
    stopReason = null
    lastSection = null
    @pacer = if @realTime then new RTPacer(@age.cpu, @rtFactor, @rtIdleTimeoutMs) else null
    @_startIOPTrace() if @iopTrace?

    if @opts.ipl
      try
        info = await @age.iplFromMassMemory(@opts, @pacer, ((m) => @info "IPL: #{m}"))
        @entryPoint = info.entry
        @info "Entry: 0x#{@entryPoint.asHex(4)}"
      catch e
        @fatal "IPL failed: #{e.message}"

    # Build flat list of watched halfword addresses for fast checking
    watchAddrs = []
    for wp in @memWatchpoints
      for i in [0...wp.count]
        watchAddrs.push(wp.addr + i)
    hasWatchpoints = watchAddrs.length > 0

    while step < @maxSteps
      @age.cpu.releaseInterrupt() if @age.cpu.intArmed?
      before = if @traceEnabled then @age.snapshotRegs() else null
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

      # NSTS_PC_TRACE=<hex>[,<hex>...] counts arrivals at chosen addresses
      # and reports each with the simulated and wall time, without stopping.
      if PC_TRACE? and PC_TRACE[nia]?
        PC_TRACE[nia] += 1
        process.stderr.write "PC #{nia.toString(16).padStart(5,'0')} hit " +
          "##{PC_TRACE[nia]}  #{(@age.cpu.timeNs / 1e6).toFixed(1)} ms sim" +
          "  #{((Date.now() - @pcTraceWall) / 1000).toFixed(1)} s wall\n"

      hw1 = @age.mainStorage.get16(nia)
      hw2 = @age.mainStorage.get16(nia + 1)

      # Decode (disassembly text only when something will display it)
      disasm = if @traceEnabled then Instruction.toStr(hw1, hw2) else null
      [d, v] = Instruction.decode(hw1, hw2)
      instrLen = if d? then d.origLen else 1

      # Not decodable: exec1 raises the operation exception and steps over
      # the halfword, the way the hardware does.  Only the trace line is
      # ours to write.
      if not d?
        if @traceEnabled
          @write @_formatTraceLine(step, nia, hw1, hw2, "??? (invalid)", 1, [])

      watchBefore = null
      if hasWatchpoints
        watchBefore = new Uint16Array(watchAddrs.length)
        for addr, idx in watchAddrs
          watchBefore[idx] = @age.mainStorage.get16(addr, false)

      # Check I/O trap before execution
      if @age.halUCP.active and @age.halUCP.isTrapAddr(nia)
        result = @age.halUCP.checkTrap(nia)

      @intTaken = null
      @age.gpc.exec1()

      if @traceEnabled
        after = @age.snapshotRegs()
        changes = @age.diffRegs(before, after)
        changes = changes.filter (c) -> c.name != 'NIA'
        @write @_formatTraceLine(step, nia, hw1, hw2, disasm, instrLen, changes)

      step++

      if @age.cpu.intArmed?
        stopReason = @_heldStopReason()
        break

      if @breakOnInterrupt and @intTaken?
        stopReason = "interrupt: #{@intTaken.label} at 0x#{@intTaken.fromNIA.asHex(5)}"
        break

      # Real-time pacing: sleep off any lead over the wall clock
      if @pacer? and (step & 255) == 0
        await @pacer.pace()

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
            disasm ?= Instruction.toStr(hw1, hw2)
            after = @age.snapshotRegs()
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
        if @pacer?
          # Real time keeps flowing in the wait state: advance simulated
          # time at the real-time rate until an interrupt wakes the CPU.
          why = await @pacer.idleWait()
          if why == 'held'
            stopReason = @_heldStopReason()
            break
          if why != 'resumed'
            stopReason = "wait state (#{why})"
            break
        else
          stopReason = "wait state"
          break

    if not stopReason?
      stopReason = "max steps reached (#{@maxSteps})"

    @info "--- STOPPED after #{step} steps (reason: #{stopReason}) ---"
    simUs = @age.cpu.execTimeUs()
    @info "--- simulated CPU time: #{(simUs/1000).toFixed(3)} ms ---"
    if @pacer?
      wallMs = @pacer.wallMs()
      ratio = if wallMs > 0 then (simUs/1000) / wallMs else 0
      @info "--- wall time: #{wallMs.toFixed(0)} ms (#{ratio.toFixed(2)}x real speed) ---"
    @info "--- FINAL REGISTERS ---"
    for line in @_formatRegDump(step)
      @info line

    @flush()

    if stopReason.indexOf("wait state") != 0
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
    @pacer = if @realTime then new RTPacer(@age.cpu, @rtFactor, @rtIdleTimeoutMs) else null

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
      @age.cpu.releaseInterrupt() if @age.cpu.intArmed?
      before = if @traceEnabled then @age.snapshotRegs() else null
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

      disasm = if @traceEnabled then Instruction.toStr(hw1, hw2) else null
      [d, v] = Instruction.decode(hw1, hw2)
      instrLen = if d? then d.origLen else 1

      if not d?
        if @traceEnabled
          @write @_formatTraceLine(@step, nia, hw1, hw2, "??? (invalid)", 1, [])

      # Check I/O trap: if input is needed from terminal, the callback
      # will call promptInput which returns (async), breaking out of execLoop.
      if @age.halUCP.active and @age.halUCP.isTrapAddr(nia)
        result = @age.halUCP.checkTrap(nia)
        if @age.halUCP.waitingForInput
          # Async input pending: save state and return.
          # execLoop will be re-entered from promptInput callback.
          @lastSection = lastSection
          return

      @intTaken = null
      @age.gpc.exec1()

      if @traceEnabled
        after = @age.snapshotRegs()
        changes = @age.diffRegs(before, after)
        changes = changes.filter (c) -> c.name != 'NIA'
        @write @_formatTraceLine(@step, nia, hw1, hw2, disasm, instrLen, changes)

      @step++

      if @age.cpu.intArmed?
        @stopReason = @_heldStopReason()
        break

      if @breakOnInterrupt and @intTaken?
        @stopReason = "interrupt: #{@intTaken.label} at 0x#{@intTaken.fromNIA.asHex(5)}"
        break

      # Real-time pacing: sleep off any lead over the wall clock
      if @pacer? and (@step & 255) == 0
        await @pacer.pace()

      if @traceEnabled and @dumpInterval > 0 and @step % @dumpInterval == 0
        for line in @_formatRegDump(@step)
          @write line
        @write ""

      if @age.cpu.psw.getWaitState()
        if @pacer?
          why = await @pacer.idleWait()
          if why == 'held'
            @stopReason = @_heldStopReason()
            break
          if why != 'resumed'
            @stopReason = "wait state (#{why})"
            break
        else
          @stopReason = "wait state"
          break

    @lastSection = lastSection

    if not @stopReason?
      if @step >= @maxSteps
        @stopReason = "max steps reached (#{@maxSteps})"

    if @stopReason?
      @info "--- STOPPED after #{@step} steps (reason: #{@stopReason}) ---"
      simUs = @age.cpu.execTimeUs()
      @info "--- simulated CPU time: #{(simUs/1000).toFixed(3)} ms ---"
      if @pacer?
        wallMs = @pacer.wallMs()
        ratio = if wallMs > 0 then (simUs/1000) / wallMs else 0
        @info "--- wall time: #{wallMs.toFixed(0)} ms (#{ratio.toFixed(2)}x real speed) ---"
      @info "--- FINAL REGISTERS ---"
      for line in @_formatRegDump(@step)
        @info line
      @flush()
      exitCode = if @stopReason.indexOf("wait state") == 0 then 0 else 1
      if exitCode != 0
        process.stderr.write "ERROR: #{@stopReason}\n"
      process.exit(exitCode)


# `gpc run` subcommand registration
parseHex = (s) -> parseInt(s.replace(/^0x/i, ''), 16)

export addCommand = (program) ->
  cmd = program.command('run')
    .description('Run an AP-101 program in batch mode')
    .argument('[fcm-file]', 'FCM memory image to load')

  AGEHarness.addOptions(cmd)
  IOHost.addOptions(cmd)

  cmd
    .option('--max-steps <n>', 'max instructions to execute (0 = unlimited)', '100000')
    .option('--cpu-model <model>', 'CPU model for instruction timing, ap101s or ap101b (default ap101s)')
    .option('--real-time', 'pace execution at (approximately) real AP-101S speed', false)
    .option('--rt-factor <x>', 'real-time speed multiplier (2 = 2x real speed)', '1')
    .option('--rt-idle-timeout <s>', 'stop after this many wall seconds in wait state with no wakeup', '10')
    .option('--break <addr>', 'stop at halfword address (hex)')
    .option('--watch <spec>', 'memory watchpoint: addr[:count] in hex', (v, prev) ->
      prev ?= []
      [a, c] = v.split(':')
      prev.push { addr: parseInt(a.replace(/^0x/i,''),16), count: parseInt(c or '1', 10) }
      prev
    )
    .option('--output <file>', 'write trace/verbose output to file instead of stdout')
    .option('--dump-interval <n>', 'register dump every N steps (default: 100)', '100')
    .option('--break-on-interrupt', 'stop when an interrupt is accepted', false)
    .option('--hold-interrupt', 'stop just before an interrupt swaps PSWs', false)
    .option('--trace', 'enable instruction trace', false)
    .option('--no-trace', 'disable instruction trace (default)')
    .option('--verbose', 'print informational messages', false)
    .option('--no-verbose', 'suppress informational messages (default)')
    .option('--interactive', 'interactive terminal I/O')
    .option('--watch-log', 'log every watchpoint change instead of breaking', false)
    .option('--iop-trace <procs>', 'trace IOP processors: 0 = MSC, 1-24 = BCEs (e.g. 0,6)', ((v) -> (parseInt(x, 10) for x in v.split(',') when x.trim() != '')))
    .action (fcmPath, o) ->
      unless fcmPath? or o.ipl
        process.stderr.write("FATAL: no image given\n")
        process.exit(1)
      checkFCMFits(fcmPath, o.machine) if fcmPath?
      runner = new BatchRunner(Object.assign({}, o, {
        fcmPath
        maxSteps: parseInt(o.maxSteps, 10)
        realTime: o.realTime or false
        rtFactor: parseFloat(o.rtFactor)
        rtIdleTimeout: parseFloat(o.rtIdleTimeout)
        breakpoint: if o.break then parseHex(o.break) else null
        memWatchpoints: o.watch or []
        watchLog: o.watchLog or false
        iopTrace: o.iopTrace or null
        outputPath: o.output or null
        dumpInterval: parseInt(o.dumpInterval, 10)
        traceEnabled: o.trace
        breakOnInterrupt: o.breakOnInterrupt or false
        holdInterrupt: o.holdInterrupt or false
        interactive: o.interactive or false
      }))
      if o.interactive then runner.runInteractive() else runner.run()
