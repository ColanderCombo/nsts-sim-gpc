# SymbolStack: several symbol tables over one address space
#
# An overlay names addresses an earlier load has already named.  The stack
# holds the image's table as its base with named tables layered over it,
# each carrying an optional address range.  An address lookup takes the
# topmost enabled layer whose range covers it and falls through to the base;
# a name lookup runs from the topmost enabled layer down, to whatever
# address the name holds there.
#
# `switchTo` enables one layer and disables every other layer whose range
# overlaps it: the state after a load, with the layers describing what used
# to be there still on the stack.

fs = require 'fs'
path = require 'path'

import {SymbolTable} from 'gpc/symbolTable'

export class SymbolStack
  constructor: (@base) ->
    @layers = []
    @nextId = 1

  # A layer covering [lo, hi]; with no range it covers every address.
  load: (symPath, opts = {}) ->
    table = new SymbolTable()
    entryPoint = table.load(symPath, false)
    throw new Error("no symbols read from #{symPath}") unless table.symbols?
    name = opts.name ? path.basename(symPath).replace(/\.sym\.json$/i, '')
    layer = {
      id: @nextId++
      name: name
      path: symPath
      table: table
      lo: opts.lo ? null
      hi: opts.hi ? null
      enabled: true
      entryPoint: entryPoint ? null
    }
    @layers = (l for l in @layers when l.name != name)
    @layers.push(layer)
    layer

  unload: (name) ->
    before = @layers.length
    @layers = (l for l in @layers when l.name != name)
    before - @layers.length

  unloadAll: () ->
    n = @layers.length
    @layers = []
    n

  # Called when the base table has been reloaded under the stack.
  rebase: () ->
    delete @base._nameIndex
    return

  find: (name) ->
    for l in @layers when l.name == name
      return l
    null

  setEnabled: (name, enabled) ->
    l = @find(name)
    return null unless l?
    l.enabled = !!enabled
    l

  # The state after a load: this layer owns its addresses and the layers it
  # overlaps step aside.
  switchTo: (name) ->
    want = @find(name)
    return null unless want?
    want.enabled = true
    for l in @layers when l != want and l.enabled and @_overlaps(l, want)
      l.enabled = false
    want

  _overlaps: (a, b) ->
    return true unless a.lo? and b.lo?     # an unscoped layer covers all
    not (a.hi < b.lo or b.hi < a.lo)

  covers: (layer, addr) ->
    return true unless layer.lo?
    layer.lo <= addr <= layer.hi

  # Topmost enabled layer covering addr, or null for the base.
  layerAt: (addr) ->
    for i in [@layers.length - 1 .. 0] by -1
      l = @layers[i]
      return l if l.enabled and @covers(l, addr)
    null

  # Every table an address could be described by, topmost first.
  tablesAt: (addr) ->
    out = []
    for i in [@layers.length - 1 .. 0] by -1
      l = @layers[i]
      out.push(l) if l.enabled and @covers(l, addr)
    out

  # The SymbolTable read interface, resolved through the stack.

  getLabelAt: (addr) ->
    for l in @tablesAt(addr)
      v = l.table.getLabelAt(addr)
      return v if v?
    @base.getLabelAt(addr)

  getSectionAt: (addr) ->
    for l in @tablesAt(addr)
      v = l.table.getSectionAt(addr)
      return v if v?
    @base.getSectionAt(addr)

  getSymbolsAt: (addr) ->
    for l in @tablesAt(addr)
      v = l.table.getSymbolsAt(addr)
      return v if v?.length
    @base.getSymbolsAt(addr)

  formatCSect: (addr) ->
    for l in @tablesAt(addr)
      return l.table.formatCSect(addr) if l.table.getSectionAt(addr)?
    @base.formatCSect(addr)

  getRelocAt: (addr, len = 1) ->
    for l in @tablesAt(addr)
      v = l.table.getRelocAt(addr, len)
      return v if v?
    @base.getRelocAt(addr, len)

  # Which layer named an address, for a report that says where a name came
  # from.  'base' when no layer did.
  sourceAt: (addr) ->
    for l in @tablesAt(addr)
      return l.name if l.table.getLabelAt(addr)? or l.table.getSectionAt(addr)?
    'base'

  addressOf: (name) ->
    want = String(name).toUpperCase()
    for i in [@layers.length - 1 .. 0] by -1
      l = @layers[i]
      continue unless l.enabled
      a = @_lookupIn(l.table, want)
      return a if a?
    @_lookupIn(@base, want)

  _lookupIn: (table, want) ->
    idx = @_index(table)
    sym = idx.get(want)
    if sym? then sym.address else null

  _index: (table) ->
    table._nameIndex ?= do ->
      m = new Map()
      for s in (table.symbols?.symbols ? [])
        m.set(s.name.toUpperCase(), s) unless m.has(s.name.toUpperCase())
      m

  # Every symbol whose name contains `want`, topmost layer first, each
  # tagged with the layer that carries it.
  search: (want, limit = 40) ->
    want = String(want).toUpperCase()
    out = []
    seen = new Set()
    push = (sym, source) =>
      key = "#{source}:#{sym.name}:#{sym.address}"
      return if seen.has(key)
      seen.add(key)
      out.push({
        name: sym.name, addr: sym.address, type: sym.type
        kind: sym.kind ? null, module: sym.module ? null
        source: source
      })
    for i in [@layers.length - 1 .. 0] by -1
      l = @layers[i]
      continue unless l.enabled
      for sym in (l.table.symbols?.symbols ? []) when sym.name.toUpperCase().indexOf(want) >= 0
        push(sym, l.name)
        return out if out.length >= limit
    for sym in (@base.symbols?.symbols ? []) when sym.name.toUpperCase().indexOf(want) >= 0
      push(sym, 'base')
      return out if out.length >= limit
    out

  # Sections from the base and every enabled layer, address ordered.
  sections: () ->
    out = ({
      name: s.name, addr: s.address, size: s.size, module: s.module
      source: 'base'
    } for s in (@base.sectionsByAddr ? []))
    for l in @layers when l.enabled
      for s in (l.table.sectionsByAddr ? [])
        out.push({ name: s.name, addr: s.address, size: s.size,
                   module: s.module, source: l.name })
    out.sort (a, b) -> a.addr - b.addr or a.source.localeCompare(b.source)

  describe: () ->
    for l in @layers
      {
        name: l.name, path: l.path, enabled: l.enabled
        lo: l.lo, hi: l.hi
        entryPoint: l.entryPoint
        symbols: l.table.symbols?.symbols?.length ? 0
        sections: l.table.sectionsByAddr?.length ? 0
      }
