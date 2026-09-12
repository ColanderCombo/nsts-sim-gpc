# SdlIndex: the SDL database over a loaded image
#
# `<CFG>.sdl.json` (tools/sdlindex) carries what the compiler knew and the
# linker's symbol table does not: the HAL/S block each code csect holds, the
# variables in each #D/#P data csect with their declared types, the structure
# templates they instantiate, and the address of every executable statement.
# Addresses in it are absolute halfwords in the config it was built for.
#
# Rows arrive with their geometry already resolved -- elements, halfwords per
# element, extent, a template's copy stride -- so reading a value here is a
# walk over memory and a format per type.
#
# Row shape, for a variable and for a structure-template leaf:
#
#   [offset, name, type, elements, elem hw, extent hw, width, shift,
#    flags, template index, dims]
#
# type: I ID S SD B C V M E STR N ?; flags 1 = NAME, 2 = CONSTANT,
# 8 = REMOTE, 16 = a NAME over a label.  A leaf's offset is relative to its
# copy of the structure.

fs = require 'fs'

import {FloatIBM} from 'gpc/floatIBM'
import {EBCDIC_TO_ASCII} from 'gpc/ebcdic'

# Row field positions.
[R_OFF, R_NAME, R_TYPE, R_N, R_EHW, R_EXT, R_W, R_SH, R_FL, R_TI,
 R_DIMS] = [0..10]

FL_NAME = 1
FL_CONSTANT = 2
FL_REMOTE = 8
FL_LABEL = 16

TYPE_TEXT = {
  I: 'INTEGER', ID: 'INTEGER DOUBLE', S: 'SCALAR', SD: 'SCALAR DOUBLE'
  B: 'BIT', C: 'CHARACTER', V: 'VECTOR', VD: 'VECTOR DOUBLE'
  M: 'MATRIX', MD: 'MATRIX DOUBLE', E: 'EVENT', STR: 'STRUCTURE'
  N: 'NAME', '?': 'UNKNOWN'
}

export class SdlIndex
  constructor: (@doc, @source = null) ->
    @config = @doc.config ? null
    @phases = @doc.phases ? []
    @units = @doc.units ? []
    @blocks = @doc.blocks ? []
    @csects = @doc.csects ? []
    @tmpl = @doc.tmpl ? []
    @stmts = @doc.stmts ? []
    @_index()

  @load: (file) ->
    doc = JSON.parse(fs.readFileSync(file, 'utf8'))
    throw new Error("#{file} is not an sdlindex file") unless doc.tool == 'sdlindex'
    new SdlIndex(doc, file)

  # Name lookups are case-insensitive; a HAL name is upper case at the
  # source and the debugger's command line is not.
  _index: () ->
    @byName = new Map()
    @byAddr = []                # [addr, entry], address ordered
    for csect in @csects
      for row in csect[4]
        e = { row, csect: csect[0], base: csect[1], unit: csect[3] }
        e.addr = csect[1] + row[R_OFF]
        (@byName.get(row[R_NAME].toUpperCase()) ? @_new(row[R_NAME])).push(e)
        @byAddr.push(e)
    @byAddr.sort (a, b) -> a.addr - b.addr
    @blockByName = new Map()
    for b in @blocks
      key = (b[4] ? b[2]).toUpperCase()
      (@blockByName.get(key) ? @_newBlock(key)).push(b)
    @unitByStem = new Map()
    @unitByName = new Map()
    for u, i in @units
      @unitByStem.set(u[0].toUpperCase(), i)
      @unitByName.set(u[1].toUpperCase(), i) if u[1]
    @stmtByAddr = []
    for [ui, rows] in @stmts
      for [n, addr, srn] in rows
        @stmtByAddr.push({ unit: ui, stmt: n, addr, srn })
    @stmtByAddr.sort (a, b) -> a.addr - b.addr
    return

  _new: (name) ->
    list = []
    @byName.set(name.toUpperCase(), list)
    list

  _newBlock: (key) ->
    list = []
    @blockByName.set(key, list)
    list

  unitName: (i) -> if i >= 0 and @units[i]? then (@units[i][1] ? @units[i][0]) else null
  unitStem: (i) -> if i >= 0 and @units[i]? then @units[i][0] else null


  lookup: (spec) ->
    s = String(spec).trim().toUpperCase()
    [qual, name] = if s.indexOf('.') > 0 then s.split('.', 2) else [null, s]
    hits = @byName.get(name) ? []
    return hits unless qual?
    (e for e in hits when @_matchesQual(e, qual))

  _matchesQual: (e, qual) ->
    return true if e.csect.toUpperCase() == qual
    return true if e.csect.slice(2).toUpperCase() == qual
    stem = @unitStem(e.unit)
    return true if stem? and stem.toUpperCase() == qual
    nm = @unitName(e.unit)
    nm? and nm.toUpperCase() == qual

  addressOf: (spec) ->
    hits = @lookup(spec)
    return hits[0].addr if hits.length == 1
    b = @blockByName.get(String(spec).trim().toUpperCase())
    return b[0][0] if b? and b.length == 1
    null

  search: (want, limit = 40) ->
    want = String(want).toUpperCase()
    out = []
    for b in @blocks when (b[4] ? '').toUpperCase().indexOf(want) >= 0 or
                          b[2].toUpperCase().indexOf(want) >= 0
      out.push({
        what: 'block', name: b[4] ? b[2], addr: b[0], size: b[1]
        csect: b[2], kind: b[3], unit: @unitName(b[5])
      })
      return out if out.length >= limit
    for e in @byAddr when e.row[R_NAME].toUpperCase().indexOf(want) >= 0
      out.push(@describe(e))
      return out if out.length >= limit
    out

  searchUnits: (want, limit = 40) ->
    want = String(want).toUpperCase()
    out = []
    for u, i in @units
      continue unless u[0].toUpperCase().indexOf(want) >= 0 or
                      (u[1] ? '').toUpperCase().indexOf(want) >= 0
      out.push({ stem: u[0], name: u[1], kind: u[2], phase: u[3],
                 blocks: (b for b in @blocks when b[5] == i).length })
      return out if out.length >= limit
    out

  describe: (e) ->
    row = e.row
    {
      what: 'var', name: row[R_NAME], addr: e.addr, csect: e.csect
      offset: row[R_OFF], type: @declText(row), extent: row[R_EXT]
      elements: row[R_N], unit: @unitName(e.unit)
      constant: !!(row[R_FL] & FL_CONSTANT)
    }

  declText: (row) ->
    t = TYPE_TEXT[row[R_TYPE]] ? row[R_TYPE]
    text =
      if row[R_TYPE] == 'STR'
        tn = @tmpl[row[R_TI]]?[0]
        if tn? then "#{tn}-STRUCTURE" else 'STRUCTURE'
      else if row[R_TYPE] in ['B', 'C']
        "#{t}(#{(row[R_W] & 0xff) or 16})"
      else if row[R_TYPE] in ['V', 'VD']
        "#{t}(#{(row[R_W] & 0xff) or 3})"
      else if row[R_TYPE] in ['M', 'MD']
        "#{t}(#{(row[R_W] >> 8) or 3},#{(row[R_W] & 0xff) or 3})"
      else t
    dims = (d for d in (row[R_DIMS] ? []) when d > 1)
    text += " ARRAY(#{dims.join(',')})" if dims.length
    text = "NAME #{text}" if row[R_FL] & FL_NAME
    text += ' CONSTANT' if row[R_FL] & FL_CONSTANT
    text


  varAt: (addr) ->
    lo = 0
    hi = @byAddr.length - 1
    best = null
    while lo <= hi
      mid = (lo + hi) >> 1
      if @byAddr[mid].addr <= addr
        best = mid
        lo = mid + 1
      else
        hi = mid - 1
    return null unless best?
    e = @byAddr[best]
    if addr < e.addr + Math.max(e.row[R_EXT], 1) then e else null

  blockAt: (addr) ->
    for b in @blocks
      return { addr: b[0], size: b[1], csect: b[2], kind: b[3],
               name: b[4], unit: @unitName(b[5]) } if b[0] <= addr < b[0] + b[1]
    null

  stmtAt: (addr) ->
    blk = @blockAt(addr)
    return null unless blk?
    lo = 0
    hi = @stmtByAddr.length - 1
    best = null
    while lo <= hi
      mid = (lo + hi) >> 1
      if @stmtByAddr[mid].addr <= addr
        best = mid
        lo = mid + 1
      else
        hi = mid - 1
    return null unless best?
    s = @stmtByAddr[best]
    return null unless blk.addr <= s.addr < blk.addr + blk.size
    { stmt: s.stmt, addr: s.addr, srn: s.srn, unit: @unitName(s.unit),
      block: blk.name, csect: blk.csect }


  read: (e, readHw, opts = {}) ->
    row = e.row
    limit = opts.limit ? 64
    enc = opts.encoding ? 'ascii'
    out = {
      name: row[R_NAME], addr: e.addr, csect: e.csect
      unit: @unitName(e.unit), type: @declText(row), extent: row[R_EXT]
      elements: row[R_N]
    }
    if row[R_FL] & FL_NAME
      n = if row[R_FL] & FL_REMOTE then 2 else 1
      hws = (readHw(e.addr + i) for i in [0...n])
      out.kind = 'name'
      out.hws = hws
      out.text = if n == 2 then "sector #{hws[0]} offset #{hex(hws[1], 4)}" \
                 else hex(hws[0], 4)
      return out
    if row[R_TYPE] == 'STR'
      out.kind = 'struct'
      out.copies = @_readStruct(e.addr, row, readHw, limit,
                                opts.fieldLimit ? 32, enc)
      out.truncated = row[R_N] > limit
      return out
    out.kind = 'scalar'
    out.values = @_readElements(e.addr, row, readHw,
                                Math.min(row[R_N], limit), enc)
    out.truncated = row[R_N] > limit
    out

  _readStruct: (addr, row, readHw, limit, fieldLimit, enc) ->
    t = @tmpl[row[R_TI]]
    return [] unless t?
    [_name, _unit, stride, _used, leaves] = t
    copies = []
    for k in [0...Math.min(row[R_N], limit)]
      base = addr + k * stride
      fields = for leaf in leaves
        f = {
          name: leaf[R_NAME], addr: base + leaf[R_OFF]
          type: @declText(leaf), extent: leaf[R_EXT]
        }
        if leaf[R_FL] & FL_NAME
          n = if leaf[R_FL] & FL_REMOTE then 2 else 1
          f.values = ({ addr: f.addr + i, hex: hex(readHw(f.addr + i), 4) } \
                      for i in [0...n])
        else
          f.values = @_readElements(f.addr, leaf, readHw,
                                    Math.min(leaf[R_N], fieldLimit), enc)
          f.truncated = leaf[R_N] > fieldLimit
        f
      copies.push({ copy: k + 1, of: row[R_N], addr: base, fields })
    copies

  _readElements: (addr, row, readHw, count, enc) ->
    ehw = Math.max(row[R_EHW], 1)
    for i in [0...Math.max(count, 0)]
      a = addr + i * ehw
      hws = (readHw(a + j) for j in [0...ehw])
      @_decode(row, hws, a, enc)

  _decode: (row, hws, addr, enc) ->
    t = row[R_TYPE]
    v = { addr, hex: (hex(h, 4) for h in hws).join(' ') }
    switch t
      when 'I'
        v.value = signed16(hws[0])
        v.text = String(v.value)
      when 'ID'
        v.value = signed32((hws[0] << 16) | hws[1])
        v.text = String(v.value)
      when 'S'
        v.value = FloatIBM.From32(((hws[0] << 16) | hws[1]) >>> 0).toFloat()
        v.text = scalarText(v.value)
      when 'SD'
        v.value = FloatIBM.From64(((hws[0] << 16) | hws[1]) >>> 0,
                                  ((hws[2] << 16) | hws[3]) >>> 0).toFloat()
        v.text = scalarText(v.value)
      when 'E'
        v.value = if bigOf(hws) != 0 then true else false
        v.text = if v.value then 'TRUE' else 'FALSE'
      when 'B'
        w = (row[R_W] & 0xff) or 16
        field = (bigOf(hws) >> BigInt(row[R_SH])) & ((1n << BigInt(w)) - 1n)
        v.value = field.toString()
        v.text = "BIN'#{field.toString(2).padStart(w, '0')}'"
      when 'C'
        v.text = charText(hws, (row[R_W] & 0xff) or 1, enc)
        v.value = v.text
      when 'V', 'M', 'VD', 'MD'
        # Field 12 carries the shape as (rows << 8) | columns: a VECTOR(3)
        # is 0x0103, a MATRIX(3,3) 0x0303.
        dbl = t.length == 2
        comp = if dbl then 4 else 2
        rows = (row[R_W] >> 8) or 1
        cols = (row[R_W] & 0xff) or 3
        v.components = for k in [0...rows * cols]
          hw = hws.slice(k * comp, (k + 1) * comp)
          f = if dbl
            FloatIBM.From64(((hw[0] << 16) | hw[1]) >>> 0,
                            ((hw[2] << 16) | hw[3]) >>> 0).toFloat()
          else
            FloatIBM.From32(((hw[0] << 16) | hw[1]) >>> 0).toFloat()
          f
        v.shape = [rows, cols]
        v.text = '[' + (scalarText(c) for c in v.components).join(', ') + ']'
      else
        v.text = v.hex
    v


hex = (v, n = 4) -> (v >>> 0).toString(16).toUpperCase().padStart(n, '0')

signed16 = (v) -> if v & 0x8000 then v - 0x10000 else v

signed32 = (v) -> v | 0

bigOf = (hws) ->
  n = 0n
  for h in hws
    n = (n << 16n) | BigInt(h & 0xffff)
  n

# A HAL/S CHARACTER(n) is a length halfword -- the current length in the
# high byte, the declared maximum in the low -- followed by the characters,
# two to a halfword.  The PASS holds them in ASCII: CDJC_MODE reads
# 'RUN HALT', CGZV_CPLT_BLANK 'CPLT    ', CGYK_MESSAGES 'ST FAIL  '.
# `encoding` takes 'ebcdic' for a buffer that holds those instead.
charText = (hws, max, encoding = 'ascii') ->
  len = hws[0] >> 8
  len = max unless 0 <= len <= max
  chars = []
  for i in [0...len]
    hw = hws[1 + (i >> 1)] ? 0
    byte = if i % 2 == 0 then (hw >> 8) & 0xff else hw & 0xff
    chars.push(
      if encoding == 'ebcdic' then (EBCDIC_TO_ASCII[byte] ? '.')
      else if 0x20 <= byte < 0x7f then String.fromCharCode(byte)
      else '.')
  "'#{chars.join('')}'"

scalarText = (x) ->
  return '0' if x == 0
  a = Math.abs(x)
  if a >= 1e-4 and a < 1e9 then String(Number(x.toPrecision(9))) \
  else x.toExponential(8)

export {FL_NAME, FL_CONSTANT, FL_REMOTE, FL_LABEL}
