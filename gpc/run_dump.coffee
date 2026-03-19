# FCM Dump Report Generator
# Loads an FCM image and symbol table, producing a formatted report with:
# 1. Alphabetically sorted symbol table grid
# 2. Full disassembly with symbol annotations
#
# Usage: node dist/fcmdump/fcmdump.js <fcm-file> [options]
#
# Options:
#   --symbols FILE     Specify symbol JSON file (default: <fcm-file>.sym.json replaces .fcm)
#   --no-symbols       Allow running without symbol file (fatal by default)
#   --output FILE      Write output to file instead of stdout
#   --columns N        Number of columns in symbol table grid (default: 7)
#   --asm              Enhanced disassembly: Rx registers, @ for indirect, # for indexed

fs = require 'fs'
path = require 'path'

require 'com/util'
import {CPU} from 'gpc/cpu'
import Instruction from 'gpc/cpu_instr'

class FCMDumper
  constructor: (@fcmPath, options = {}) ->
    @symbolsPath = options.symbolsPath ? null
    @requireSymbols = options.requireSymbols ? true
    @outputPath = options.outputPath ? null
    @columns = options.columns ? 7
    @asmMode = options.asmMode ? false   # Enhanced disassembly mode
    
    @cpu = new CPU()
    @lines = []
    @symbols = null
    @sectionsByAddr = []      # sorted by address
    @symbolsByAddr = {}       # addr -> [symbols]
    @sortedSymbols = []       # sorted alphabetically
    @symbolByName = {}        # name -> symbol
    @addrToSection = {}       # addr -> section object
    @imageSize = 0

  write: (s) ->
    if @outputPath?
      @lines.push s
    else
      process.stdout.write s + "\n"

  flush: ->
    if @outputPath? and @lines.length > 0
      fs.writeFileSync @outputPath, @lines.join("\n") + "\n"

  loadFCM: ->
    image = fs.readFileSync @fcmPath
    buf = new ArrayBuffer(image.length)
    buf8 = new Uint8Array(buf)
    for i in [0...image.length]
      buf8[i] = image[i]
    dv = new DataView(buf)
    @cpu.mainStorage.load16(0, dv)
    @imageSize = dv.byteLength / 2  # size in halfwords
    return @imageSize

  resolveSymbolsPath: ->
    if @symbolsPath?
      return @symbolsPath
    # Replace .fcm with .sym.json, or append .sym.json
    if @fcmPath.endsWith('.fcm')
      return @fcmPath.replace(/\.fcm$/, '.sym.json')
    else
      return @fcmPath + '.sym.json'

  loadSymbols: ->
    symPath = @resolveSymbolsPath()
    
    if not fs.existsSync(symPath)
      if @requireSymbols
        console.error "FATAL: Symbol file not found: #{symPath}"
        console.error "Use --no-symbols to run without symbol information."
        process.exit(1)
      else
        console.error "Warning: Symbol file not found: #{symPath}"
        return false
    
    try
      json = fs.readFileSync(symPath, 'utf8')
      @symbols = JSON.parse(json)
      
      # Build section lookup by address
      @sectionsByAddr = (@symbols.sections or []).slice()
      @sectionsByAddr.sort (a, b) -> a.address - b.address
      
      # Build section membership map (addr -> section object)
      for sect in @sectionsByAddr
        for offset in [0...sect.size]
          @addrToSection[sect.address + offset] = sect
      
      # Build symbol lookup by address
      @symbolsByAddr = {}
      for sym in (@symbols.symbols or [])
        addr = sym.address
        @symbolsByAddr[addr] ?= []
        @symbolsByAddr[addr].push sym
        @symbolByName[sym.name] = sym
      
      # Build alphabetically sorted symbol list
      @sortedSymbols = (@symbols.symbols or []).slice()
      @sortedSymbols.sort (a, b) -> 
        a.name.toUpperCase().localeCompare(b.name.toUpperCase())
      
      return true
    catch e
      if @requireSymbols
        console.error "FATAL: Could not load symbols: #{e.message}"
        process.exit(1)
      else
        console.error "Warning: Could not load symbols: #{e.message}"
        return false

  # Get symbols at a specific address
  getSymbolsAt: (addr) ->
    return @symbolsByAddr[addr] or []

  # Get the section containing an address
  getSectionAt: (addr) ->
    return @addrToSection[addr] or null

  # Format symbol table as grid
  printSymbolTable: ->
    @write "=".repeat(120)
    @write "SYMBOL TABLE"
    @write "=".repeat(120)
    @write ""
    
    if not @symbols? or @sortedSymbols.length == 0
      @write "(No symbols available)"
      @write ""
      return
    
    # Each entry: 8 char name + 1 space + 6 hex digits + 3 space gap = 18 chars
    # With 7 columns: 7*18 - 3 (no trailing gap) = 123 chars
    
    row = []
    for sym in @sortedSymbols
      name = sym.name.slice(0, 8).toUpperCase().rpad(' ', 8)
      addr = sym.address.asHex(6).toUpperCase()
      entry = "#{name} #{addr}"
      row.push entry
      
      if row.length >= @columns
        @write row.join('   ')
        row = []
    
    # Print remaining entries
    if row.length > 0
      @write row.join('   ')
    
    @write ""

  # Calculate effective address for disassembly (static, no runtime state)
  # Returns null if EA is not applicable
  calcStaticEA: (desc, v, currentAddr) ->
    return null unless desc?
    
    # Only memory-referencing instructions have EA
    # Skip register-only instructions (RR type without memory operand)
    if desc.type == 'RR'
      return null
    
    # Skip shift instructions
    if desc.opType == 4  # OPTYPE_SHFT
      return null
    
    # For disassembly, we can only compute EA if B2=3 (no base register)
    # or for relative addressing modes
    
    if v.d? and v.b?
      if v.b == 3  # B2 = 11 means displacement is the address
        ea = v.d & 0xFFFF
        # Handle indexed addressing modes  
        if v.i? and v.i == 0
          if v.ii == 0 and v.ia == 0
            # IC-relative forward: EA = NIA + PEA
            # NIA after fetch = currentAddr + instruction length
            nia = currentAddr + desc.len
            ea = (nia + v.d) & 0xFFFF
          else if v.ii == 1 and v.ia == 0
            # IC-relative backward: EA = NIA - PEA
            nia = currentAddr + desc.len
            ea = (nia - v.d) & 0xFFFF
          # Cases with indirect addressing can't be statically resolved
          else
            ea = v.d & 0xFFFF
        # Expand to 19-bit (simplified - just mask for now)
        return ea & 0x7FFFF
      else
        # EA depends on register contents - can't compute statically
        # But we can show the displacement as a partial EA
        return null
    
    return null

  # Format a register value - with 'R' prefix in asm mode
  formatReg: (r) ->
    if @asmMode
      return "R#{r}"
    else
      return "#{r}"

  # Format instruction with custom options
  # Returns {opcode, operands}
  formatInstr: (desc, v, hw1, hw2) ->
    # In non-asm mode, use the standard formatter and split
    if not @asmMode
      disasmStr = Instruction.toStr(hw1, hw2)
      parts = disasmStr.match(/^(\S+)\s*(.*)$/)
      if parts?
        return {opcode: parts[1], operands: parts[2] or null}
      else
        return {opcode: disasmStr, operands: null}
    
    # ASM mode: custom formatting with R prefixes and mode indicators
    
    # Determine addressing modes for suffix
    isIndexed = v.i? and v.i != 0       # X field non-zero = indexed
    isIndirect = v.ia? and v.ia == 1    # IA bit = indirect addressing
    
    # Build opcode with mode suffixes
    opcode = v.nm
    if isIndirect
      opcode += "@"
    if isIndexed
      opcode += "#"
    
    # Build operands based on instruction format
    # Follows the pattern from Instruction.toStr but with R prefixes for register operands
    # Note: base/index registers in address part (inside parentheses) do NOT get R prefix
    
    parts = []
    
    # R1 (x field) - appears first in most formats - gets R prefix
    if v.x?
      parts.push @formatReg(v.x)
    
    # R2 (y field) - for RR format instructions - gets R prefix
    if v.y?
      parts.push @formatReg(v.y)
    
    # Immediate value for RI format (immediately after registers)
    if v.I? and desc.type == 'RI'
      parts.push "X'#{v.I.asHex()}'"
    
    # Displacement with base/index addressing
    # Base/index registers also get R prefix in asm mode
    if v.d?
      dispStr = "X'#{v.d.asHex()}'"
      if v.b?
        if v.i? and v.i != 0
          # Indexed mode: D(X,B)
          dispStr += "(#{@formatReg(v.i)},#{@formatReg(v.b)})"
        else
          # Base only: D(B)
          dispStr += "(#{@formatReg(v.b)})"
      parts.push dispStr
    
    # Immediate value for SI format (comes at the end)
    if v.I? and desc.type == 'SI'
      parts.push "X'#{v.I.asHex()}'"
    
    operands = parts.join(",")
    
    return {opcode, operands}

  # Create a line data object with all fields for a disassembly line
  # All fields are optional - the formatter will handle missing/null values
  makeLineData: (options = {}) ->
    {
      startAddr: options.startAddr ? null      # Starting address (number)
      endAddr: options.endAddr ? null          # Ending address for multi-word (number), null for single
      section: options.section ? null          # Section name (string, max 8 chars)
      offset: options.offset ? null            # Offset within section (number)
      hw1: options.hw1 ? null                  # First halfword (number)
      hw2: options.hw2 ? null                  # Second halfword (number), null if single-word
      ea: options.ea ? null                    # Effective address (number)
      label: options.label ? null              # Label/symbol name (string, max 8 chars)
      opcode: options.opcode ? null            # Opcode mnemonic (string)
      operands: options.operands ? null        # Operand string
      comment: options.comment ? null          # Additional comment text
    }

  # Format a line data object into a properly aligned string
  # Column layout:
  # Col 0-12:   Address field (AAAAAA or AAAAAA-BBBBBB), 13 chars
  # Col 13-15:  gap (3 spaces)
  # Col 16-23:  Section name (left justified, 8 chars)
  # Col 24:     +
  # Col 25-28:  Offset (4 hex, zero-padded)
  # Col 29-35:  gap (7 spaces)
  # Col 36-39:  HW1 (4 hex)
  # Col 40-41:  gap (2 spaces)
  # Col 42-45:  HW2 (4 hex or 4 spaces)
  # Col 46-47:  gap (2 spaces)
  # Col 48-53:  EA (6 hex or 6 spaces)
  # Col 54-55:  gap (2 spaces)
  # Col 56-63:  Label (left justified, 8 chars)
  # Col 64:     gap (1 space)
  # Col 65+:    Opcode + operands + comment
  formatLine: (ld) ->
    # Address field (13 chars)
    if ld.startAddr?
      if ld.endAddr? and ld.endAddr != ld.startAddr
        addrStr = "#{ld.startAddr.asHex(6).toUpperCase()}-#{ld.endAddr.asHex(6).toUpperCase()}"
      else
        addrStr = ld.startAddr.asHex(6).toUpperCase()
    else
      addrStr = ""
    addrField = addrStr.rpad(' ', 13)
    
    # Section+offset field (8 + 1 + 4 = 13 chars)
    if ld.section?
      sectName = ld.section.slice(0, 8).toUpperCase().rpad(' ', 8)
    else
      sectName = "        "
    if ld.offset?
      offsetStr = ld.offset.asHex(4).toUpperCase()
    else
      offsetStr = "    "
    sectionField = "#{sectName}+#{offsetStr}"
    
    # HW1 (4 chars)
    if ld.hw1?
      hw1Str = ld.hw1.asHex(4).toUpperCase()
    else
      hw1Str = "    "
    
    # HW2 (4 chars)
    if ld.hw2?
      hw2Str = ld.hw2.asHex(4).toUpperCase()
    else
      hw2Str = "    "
    
    # EA (6 chars)
    if ld.ea?
      eaStr = ld.ea.asHex(6).toUpperCase()
    else
      eaStr = "      "
    
    # Label (8 chars, left justified)
    if ld.label?
      labelStr = ld.label.slice(0, 8).toUpperCase().rpad(' ', 8)
    else
      labelStr = "        "
    
    # Instruction field (opcode + operands)
    if ld.opcode?
      opStr = ld.opcode.rpad(' ', 6)  # 6 chars for opcode (room for @#)
      if ld.operands?
        instrStr = "#{opStr} #{ld.operands}"  # space after opcode field
      else
        instrStr = opStr
    else
      instrStr = ""
    
    # Comment
    if ld.comment?
      if instrStr.length > 0
        instrStr = "#{instrStr}  ; #{ld.comment}"
      else
        instrStr = "; #{ld.comment}"
    
    # Build the line with proper spacing:
    # addr(13) + gap(3) + sect(13) + gap(7) + hw1(4) + gap(2) + hw2(4) + gap(2) + ea(6) + gap(2) + label(8) + gap(1) + instr
    return "#{addrField}   #{sectionField}       #{hw1Str}  #{hw2Str}  #{eaStr}  #{labelStr} #{instrStr}"

  # Print disassembly
  printDisassembly: ->
    @write "=".repeat(120)
    @write "DISASSEMBLY"
    @write "=".repeat(120)
    @write ""
    
    addr = 0
    while addr < @imageSize
      hw1 = @cpu.mainStorage.get16(addr)
      hw2 = @cpu.mainStorage.get16(addr + 1)
      
      # Decode instruction
      [desc, v] = Instruction.decode(hw1, hw2)
      instrLen = if desc? then desc.len else 1
      
      # Get section info
      sect = @getSectionAt(addr)
      sectName = if sect? then sect.name else null
      sectOffset = if sect? then addr - sect.address else 0
      
      # Check for symbol at this address
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
        # Clear label for the actual instruction line
        labelName = null
      
      # Calculate EA
      ea = @calcStaticEA(desc, v, addr)
      
      # Build instruction string
      if desc?
        {opcode, operands} = @formatInstr(desc, v, hw1, hw2)
      else
        opcode = "DC"
        operands = "X'#{hw1.asHex(4).toUpperCase()}'"
      
      # Build the main instruction line
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
      })
      @write @formatLine(instrLine)
      
      addr += instrLen
    
    @write ""

  run: ->
    hwCount = @loadFCM()
    hasSymbols = @loadSymbols()
    
    @write "=".repeat(120)
    @write "FCM DUMP REPORT"
    @write "=".repeat(120)
    @write ""
    @write "FCM File:    #{@fcmPath}"
    @write "Image Size:  #{hwCount} halfwords (#{hwCount * 2} bytes)"
    if @symbols?
      symPath = @resolveSymbolsPath()
      @write "Symbols:     #{symPath}"
      @write "Entry Point: 0x#{(@symbols.entryPoint ? 0).asHex(6).toUpperCase()}"
      @write "Sections:    #{@symbols.sections?.length ? 0}"
      @write "Symbols:     #{@symbols.symbols?.length ? 0}"
    else
      @write "Symbols:     (none)"
    @write ""
    
    @printSymbolTable()
    @printDisassembly()
    
    @flush()


# CLI parsing
{Command} = require 'commander'

program = new Command()
program
  .name('gpc-dump')
  .description('FCM Dumper — disassemble and inspect FCM memory images')
  .showHelpAfterError(true)
  .argument('<fcm-file>', 'FCM memory image to inspect')
  .option('--symbols <file>', 'symbol JSON file (default: <fcm>.sym.json)')
  .option('--no-symbols', 'allow running without symbol file')
  .option('--output <file>', 'write output to file instead of stdout')
  .option('--columns <n>', 'columns in symbol table grid', '7')
  .option('--asm', 'enhanced disassembly: Rx registers, @ for indirect, # for indexed')
  .parse()

fcmPath = program.args[0]
o = program.opts()

options = {
  symbolsPath: o.symbols or null
  requireSymbols: o.symbols != false  # --no-symbols sets this to false
  outputPath: o.output or null
  columns: parseInt(o.columns, 10)
  asmMode: o.asm or false
}

dumper = new FCMDumper(fcmPath, options)
dumper.run()
