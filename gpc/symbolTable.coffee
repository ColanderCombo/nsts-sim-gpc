fs = require 'fs'
path = require 'path'

export class SymbolTable
  constructor: () ->
    @symbols = null       # Raw parsed JSON { symbols, sections, entryPoint }
    @symbolsByAddr = {}   # addr -> [sym, ...]
    @sectionsByAddr = []  # sorted array of { name, address, size }
    @addrToSection = {}   #
    @sectionColors = {}   #
    @symTypes = {}        # symbol type overrides from .symtypes.json
    @relocsByAddr = {}    # hwAddr -> symbol name (from linker relocation data)

  load: (symPath, verbose = false) ->
    # returns entry point
    try
      json = fs.readFileSync(symPath, 'utf8')
      @symbols = JSON.parse(json)

      # Sections sorted by address
      @sectionsByAddr = (@symbols.sections or []).slice()
      @sectionsByAddr.sort (a, b) -> a.address - b.address

      # Symbol lookup by address
      @symbolsByAddr = {}
      for sym in (@symbols.symbols or [])
        addr = sym.address
        @symbolsByAddr[addr] ?= []
        @symbolsByAddr[addr].push sym

      # Section membership index
      @addrToSection = {}
      for sect in @sectionsByAddr
        for offset in [0...sect.size]
          @addrToSection[sect.address + offset] = sect.name

      # Generate colors for each section (golden ratio hue spread)
      @sectionColors = {}
      for sect, idx in @sectionsByAddr
        hue = (idx * 137.508) % 360
        @sectionColors[sect.name] = "hsl(#{hue}, 40%, 20%)"

      # Build relocation lookup (hwAddr -> symbol name)
      @relocsByAddr = {}
      for reloc in (@symbols.relocations or [])
        @relocsByAddr[reloc.address] = reloc.symbol

      # Load .symtypes.json if present
      @symTypes = {}
      try
        symTypesPath = symPath.replace(/\.sym\.json$/, '.symtypes.json')
        typesJson = fs.readFileSync(symTypesPath, 'utf8')
        @symTypes = JSON.parse(typesJson)
        if verbose
          process.stderr.write "SymbolTable: Loaded symtypes from #{symTypesPath} (#{Object.keys(@symTypes).length} entries)\n"
      catch
        # No symtypes file — use defaults

      @symTypes['IOBUF'] ?= { type: 'ascii', size: 43 }

      if verbose
        process.stderr.write "SymbolTable: Loaded #{@symbols.symbols?.length or 0} symbols, #{@symbols.sections?.length or 0} sections from #{symPath}\n"

      return @symbols.entryPoint
    catch e
      console.error "SymbolTable: Could not load symbols: #{e.message}"
      return null

  getSymbolsAt: (addr) ->
    return @symbolsByAddr[addr] or []

  getSectionAt: (addr) ->
    return @addrToSection[addr] or null

  getSectionColor: (name) ->
    return @sectionColors[name] or null

  formatCSect: (addr) ->
    sect = @getSectionAt(addr)
    if sect?
      for s in @sectionsByAddr
        if s.name == sect
          offset = addr - s.address
          sn = sect.substring(0, 8).padEnd(8, ' ')
          return "#{sn}+#{offset.toString(16).padStart(5,'0')}"
    return "        +     "

  getLabelAt: (addr) ->
    syms = @getSymbolsAt(addr)
    if syms.length > 0
      return syms[0].name
    return null

  # Get relocation target symbol for any halfword in an instruction
  # instrAddr: halfword address of instruction start
  # instrLen: length in halfwords (1 or 2)
  getRelocAt: (instrAddr, instrLen = 1) ->
    for i in [0...instrLen]
      sym = @relocsByAddr[instrAddr + i]
      return sym if sym?
    return null

  getSymbolSize: (sym, displayType, displaySize) ->
    # In halfwords
    return displaySize if displaySize > 1
    switch displayType
      when 'fw', 'int32', 'float' then return 2
      when 'dfloat' then return 4
      when 'ebcdic', 'ascii' then return displaySize
      else
        sect = @getSectionAt(sym.address)
        if sect
          for s in @sectionsByAddr
            if s.name == sect
              sectionEnd = s.address + s.size
              nextAddr = sectionEnd
              for other in (@symbols?.symbols or [])
                if other.address > sym.address and other.address < nextAddr
                  nextAddr = other.address
              return Math.max(1, nextAddr - sym.address)
        return 1
