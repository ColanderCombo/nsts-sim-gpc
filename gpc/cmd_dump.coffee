# gpc dump cmd
# dumps a report of a fcm (reading the syms file) with:
#   - list of symbols
#   - disasm
#
fs = require 'fs'

require 'com/util'
import {AGEHarness} from 'gpc/ageharness'
import Instruction from 'gpc/cpu_instr'

export class FCMDumper
  constructor: (@fcmPath, opts = {}) ->
    @opts = opts
    @requireSymbols = opts.requireSymbols ? true
    @outputPath = opts.outputPath ? null
    @columns = opts.columns ? 7

    @age = new AGEHarness()

    @lines = []
    @sortedSymbols = []
    @imageSize = 0

  write: (s) ->
    if @outputPath?
      @lines.push s
    else
      process.stdout.write s + "\n"

  flush: ->
    if @outputPath? and @lines.length > 0
      fs.writeFileSync @outputPath, @lines.join("\n") + "\n"

  load: ->
    # Resolve symbols path — use explicit option, or AGE auto-detect
    symbolsPath = @opts.symbols or @age.autoDetectSymbols(@fcmPath)

    if not symbolsPath?
      # No symbols path found at all
      if @requireSymbols
        # Compute the expected path for the error message
        expectedPath = @fcmPath.replace(/\.fcm$/, '.sym.json')
        console.error "FATAL: Symbol file not found: #{expectedPath}"
        console.error "Use --no-symbols to run without symbol information."
        process.exit(1)
    else if not fs.existsSync(symbolsPath)
      if @requireSymbols
        console.error "FATAL: Symbol file not found: #{symbolsPath}"
        console.error "Use --no-symbols to run without symbol information."
        process.exit(1)
      else
        console.error "Warning: Symbol file not found: #{symbolsPath}"
        symbolsPath = null

    byteCount = @age.loadFCM(@fcmPath)
    @imageSize = byteCount / 2

    if symbolsPath?
      try
        @age.loadSymbols(symbolsPath)
        @_buildSymbolLookups()
      catch e
        if @requireSymbols
          console.error "FATAL: Could not load symbols: #{e.message}"
          process.exit(1)
        else
          console.error "Warning: Could not load symbols: #{e.message}"

    @symbolsPath = symbolsPath
    return @imageSize

  _buildSymbolLookups: ->
    @sortedSymbols = (@age.sym.symbols?.symbols or []).slice()
    @sortedSymbols.sort (a, b) ->
      a.name.toUpperCase().localeCompare(b.name.toUpperCase())

  getSymbolsAt: (addr) ->
    return @age.sym.getSymbolsAt(addr)

  getSectionAt: (addr) ->
    sect = @age.sym.getSectionAt(addr)
    if sect?
      for s in @age.sym.sectionsByAddr
        if s.name == sect
          return s
    return null

  getRelocAt: (instrAddr, instrLen = 1) ->
    return @age.sym.getRelocAt?(instrAddr, instrLen) or null

  printSymbolTable: ->
    @write "=".repeat(120)
    @write "SYMBOL TABLE"
    @write "=".repeat(120)
    @write ""

    if @sortedSymbols.length == 0
      @write "(No symbols available)"
      @write ""
      return

    row = []
    for sym in @sortedSymbols
      name = sym.name.slice(0, 8).toUpperCase().rpad(' ', 8)
      addr = sym.address.asHex(6).toUpperCase()
      entry = "#{name} #{addr}"
      row.push entry

      if row.length >= @columns
        @write row.join('   ')
        row = []

    if row.length > 0
      @write row.join('   ')

    @write ""

  #
  # disasm generation
  #
  calcStaticEA: (desc, v, currentAddr) ->
    # static = no runtime info available
    return null unless desc?

    if desc.type == 'RR'
      return null

    if desc.opType == 4  # OPTYPE_SHFT
      return null

    if v.d? and v.b?
      if v.b == 3  # B2 = 11 means displacement is the address
        ea = v.d & 0xFFFF
        if v.i? and v.i == 0
          if v.ii == 0 and v.ia == 0
            nia = currentAddr + desc.len
            ea = (nia + v.d) & 0xFFFF
          else if v.ii == 1 and v.ia == 0
            nia = currentAddr + desc.len
            ea = (nia - v.d) & 0xFFFF
          else
            ea = v.d & 0xFFFF
        return ea & 0x7FFFF
      else
        return null

    return null

  formatReg: (r) -> "R#{r}"

  formatInstr: (desc, v, hw1, hw2) ->
    # format '3' -> R3 and add @ for indirect, # for indexed
    isIndexed = v.i? and v.i != 0
    isIndirect = v.ia? and v.ia == 1

    opcode = v.nm
    if isIndirect
      opcode += "@"
    if isIndexed
      opcode += "#"

    parts = []

    if v.x?
      parts.push @formatReg(v.x)

    if v.y?
      parts.push @formatReg(v.y)

    if v.I? and desc.type == 'RI'
      parts.push "X'#{v.I.asHex()}'"

    if v.d?
      dispStr = "X'#{v.d.asHex()}'"
      if v.b?
        if v.i? and v.i != 0
          dispStr += "(#{@formatReg(v.i)},#{@formatReg(v.b)})"
        else
          dispStr += "(#{@formatReg(v.b)})"
      parts.push dispStr

    if v.I? and desc.type == 'SI'
      parts.push "X'#{v.I.asHex()}'"

    operands = parts.join(",")

    return {opcode, operands}

  makeLineData: (options = {}) ->
    {
      startAddr: options.startAddr ? null
      endAddr: options.endAddr ? null
      section: options.section ? null
      offset: options.offset ? null
      hw1: options.hw1 ? null
      hw2: options.hw2 ? null
      ea: options.ea ? null
      label: options.label ? null
      opcode: options.opcode ? null
      operands: options.operands ? null
      comment: options.comment ? null
    }

  formatLine: (ld) ->
    if ld.startAddr?
      if ld.endAddr? and ld.endAddr != ld.startAddr
        addrStr = "#{ld.startAddr.asHex(6).toUpperCase()}-#{ld.endAddr.asHex(6).toUpperCase()}"
      else
        addrStr = ld.startAddr.asHex(6).toUpperCase()
    else
      addrStr = ""
    addrField = addrStr.rpad(' ', 13)

    if ld.section?
      sectName = ld.section.slice(0, 8).toUpperCase().rpad(' ', 8)
    else
      sectName = "        "
    if ld.offset?
      offsetStr = ld.offset.asHex(4).toUpperCase()
    else
      offsetStr = "    "
    sectionField = "#{sectName}+#{offsetStr}"

    if ld.hw1?
      hw1Str = ld.hw1.asHex(4).toUpperCase()
    else
      hw1Str = "    "

    if ld.hw2?
      hw2Str = ld.hw2.asHex(4).toUpperCase()
    else
      hw2Str = "    "

    if ld.ea?
      eaStr = ld.ea.asHex(6).toUpperCase()
    else
      eaStr = "      "

    if ld.label?
      labelStr = ld.label.slice(0, 8).toUpperCase().rpad(' ', 8)
    else
      labelStr = "        "

    if ld.opcode?
      opStr = ld.opcode.rpad(' ', 6)
      if ld.operands?
        instrStr = "#{opStr} #{ld.operands}"
      else
        instrStr = opStr
    else
      instrStr = ""

    if ld.comment?
      if instrStr.length > 0
        instrStr = "#{instrStr}  ; #{ld.comment}"
      else
        instrStr = "; #{ld.comment}"

    return "#{addrField}   #{sectionField}       #{hw1Str}  #{hw2Str}  #{eaStr}  #{labelStr} #{instrStr}"

  printDisassembly: ->
    @write "=".repeat(120)
    @write "DISASSEMBLY"
    @write "=".repeat(120)
    @write ""

    addr = 0
    while addr < @imageSize
      hw1 = @age.mainStorage.get16(addr)
      hw2 = @age.mainStorage.get16(addr + 1)

      [desc, v] = Instruction.decode(hw1, hw2)
      instrLen = if desc? then desc.len else 1

      sect = @getSectionAt(addr)
      sectName = if sect? then sect.name else null
      sectOffset = if sect? then addr - sect.address else 0

      syms = @getSymbolsAt(addr)
      hasLabel = syms.length > 0
      labelName = if hasLabel then syms[0].name else null

      # If there's a label AND this is a valid instruction, emit a DS 0H line first
      if hasLabel and desc?
        dsLine = @makeLineData({
          startAddr: addr
          section: sectName
          offset: sectOffset
          label: labelName
          opcode: "DS"
          operands: "0H"
        })
        @write @formatLine(dsLine)
        labelName = null

      ea = @calcStaticEA(desc, v, addr)

      if desc?
        {opcode, operands} = @formatInstr(desc, v, hw1, hw2)
      else
        opcode = "DC"
        operands = "X'#{hw1.asHex(4).toUpperCase()}'"

      relocSym = @getRelocAt(addr, instrLen)

      instrLine = @makeLineData({
        startAddr: addr
        endAddr: if instrLen > 1 then addr + instrLen - 1 else null
        section: sectName
        offset: sectOffset
        hw1: hw1
        hw2: if instrLen > 1 then hw2 else null
        ea: ea
        label: labelName
        opcode: opcode
        operands: operands
        comment: relocSym
      })
      @write @formatLine(instrLine)

      addr += instrLen

    @write ""

  run: ->
    hwCount = @load()

    @write "=".repeat(120)
    @write "FCM DUMP REPORT"
    @write "=".repeat(120)
    @write ""
    @write "FCM File:    #{@fcmPath}"
    @write "Image Size:  #{hwCount} halfwords (#{hwCount * 2} bytes)"
    if @age.sym.symbols?
      @write "Symbols:     #{@symbolsPath}"
      @write "Entry Point: 0x#{(@age.sym.symbols.entryPoint ? 0).asHex(6).toUpperCase()}"
      @write "Sections:    #{@age.sym.symbols.sections?.length ? 0}"
      @write "Symbols:     #{@age.sym.symbols.symbols?.length ? 0}"
    else
      @write "Symbols:     (none)"
    @write ""

    @printSymbolTable()
    @printDisassembly()

    @flush()

#
# cli command registration
#
export addCommand = (program) ->
  program.command('dump')
    .description('FCM dump report — symbol table and disassembly')
    .argument('<fcm-file>', 'FCM memory image to inspect')
    .option('--symbols <file>', 'symbol JSON file (default: <fcm>.sym.json)')
    .option('--no-symbols', 'allow running without symbol file')
    .option('--output <file>', 'write output to file instead of stdout')
    .option('--columns <n>', 'columns in symbol table grid', '7')
    .action (fcmPath, o) ->
      dumper = new FCMDumper(fcmPath, {
        symbols: o.symbols or null
        requireSymbols: o.symbols != false
        outputPath: o.output or null
        columns: parseInt(o.columns, 10)
      })
      dumper.run()
      process.exit(0) # force electron exit
