import {defc, cmdError} from './registry'
import {hex, renderList} from './render'

defc 'sdl',
  summary: 'Load the SDL index for the image, or report the one loaded'
  params: [{ name: 'file', type: 'str' }]
  exec: (s, a) ->
    file = if a.file? then require('path').resolve(a.file) else s.sdlPathFor()
    if file?
      try
        s.loadSdl(file)
      catch e
        throw cmdError('sdlFailed', "#{file}: #{e.message}")
    else unless s.sdl?
      throw cmdError('noSdl', 'no SDL index beside the image; ' +
        'build one with `sdlindex <CFG> --mmu <root>`')
    sdlStatus(s)
  render: (r) ->
    return 'no SDL index loaded' unless r.loaded
    "#{r.config} (#{r.phases.join(' ')}) from #{r.source}\n" +
    "  #{r.units} units, #{r.blocks} blocks, #{r.variables} variables in " +
    "#{r.csects} data csects, #{r.templates} templates, #{r.statements} statements"

sdlStatus = (s) ->
  return { loaded: false } unless s.sdl?
  {
    loaded: true, config: s.sdl.config, phases: s.sdl.phases
    source: s.sdl.source, units: s.sdl.units.length
    blocks: s.sdl.blocks.length, csects: s.sdl.csects.length
    variables: s.sdl.byAddr.length, templates: s.sdl.tmpl.length
    statements: s.sdl.stmtByAddr.length
  }

needSdl = (s) ->
  throw cmdError('noSdl', 'no SDL index loaded (`sdl`)') unless s.sdl?
  s.sdl

defc 'hal',
  summary: 'Search the SDL index for HAL blocks and variables'
  params: [
    { name: 'name', type: 'str', required: true }
    { name: 'limit', type: 'int', flag: true, default: 40 }
    { name: 'units', type: 'bool', flag: true, default: false }
  ]
  exec: (s, a) ->
    sdl = needSdl(s)
    return { units: sdl.searchUnits(a.name, a.limit ? 40), query: a.name } if a.units
    { hits: sdl.search(a.name, a.limit ? 40), query: a.name }
  render: (r) ->
    if r.units?
      return renderList r.units, "no unit matching #{r.query}", (u) ->
        "  #{u.stem.rpad(' ', 10)} #{(u.name ? '').rpad(' ', 32)} " +
        "#{(u.kind ? '').rpad(' ', 10)} #{u.phase ? ''} (#{u.blocks} blocks)"
    renderList r.hits, "no HAL name matching #{r.query}", (x) ->
      if x.what == 'block'
        "  #{hex(x.addr, 5)} #{(x.name ? '').rpad(' ', 32)} " +
        "#{(x.kind ? '').rpad(' ', 10)} #{x.csect} (#{x.size} HW)"
      else
        "  #{hex(x.addr, 5)} #{x.name.rpad(' ', 32)} #{x.type.rpad(' ', 22)}" +
        " #{x.csect}+#{hex(x.offset, 4)}"

defc 'halinfo',
  summary: 'Declaration, address and extent of one HAL name'
  aliases: ['decl']
  params: [{ name: 'name', type: 'str', required: true }]
  exec: (s, a) ->
    sdl = needSdl(s)
    hits = (sdl.describe(e) for e in sdl.lookup(a.name))
    for b in (sdl.blockByName.get(String(a.name).trim().toUpperCase()) ? [])
      hits.push({ what: 'block', name: b[4] ? b[2], addr: b[0], size: b[1],
                  csect: b[2], kind: b[3], unit: sdl.unitName(b[5]) })
    throw cmdError('noSymbols', "no HAL name #{a.name}") unless hits.length
    { hits, query: a.name }
  render: (r) ->
    (for x in r.hits
      if x.what == 'block'
        "  #{x.kind ? 'BLOCK'} #{x.name}\n" +
        "    #{hex(x.addr, 5)}-#{hex(x.addr + x.size - 1, 5)}  " +
        "#{x.csect} (#{x.size} HW)  #{x.unit ? ''}"
      else
        "  DECLARE #{x.name} #{x.type};\n" +
        "    #{hex(x.addr, 5)}  #{x.csect}+#{hex(x.offset, 4)}  " +
        "#{x.extent} HW  #{x.unit ? ''}").join('\n')

renderValue = (r) ->
  head = "  #{r.name} #{r.type}  #{hex(r.addr, 5)} #{r.csect} (#{r.extent} HW)"
  lines = [head]
  switch r.kind
    when 'name'
      lines.push "    #{r.text}"
    when 'struct'
      for c in r.copies
        lines.push "    +++ COPY #{c.copy} OF #{c.of} +++" if c.of > 1
        for f in c.fields
          lines.push "    #{f.name.rpad(' ', 28)} #{f.type.rpad(' ', 20)} " +
            valueText(f.values) + (if f.truncated then ' ...' else '')
      lines.push "    ... #{r.elements - r.copies.length} of #{r.elements} copies not shown" if r.truncated
    else
      lines.push "    #{valueText(r.values)}"
      lines.push "    ... #{r.elements - r.values.length} of #{r.elements} not shown" if r.truncated
  lines.join('\n')

valueText = (values) ->
  return '' unless values?.length
  return "#{values[0].text ? values[0].hex}" if values.length == 1
  ((v.text ? v.hex) for v in values).join('  ')

defc 'val',
  summary: 'Read a HAL variable and decode it by its declared type'
  aliases: ['value']
  params: [
    { name: 'name', type: 'str', required: true }
    { name: 'limit', type: 'int', flag: true, default: 32 }
    { name: 'fields', type: 'int', flag: true, default: 32 }
    { name: 'encoding', type: 'str', flag: true, default: 'ascii' }
  ]
  exec: (s, a) ->
    sdl = needSdl(s)
    hits = sdl.lookup(a.name)
    throw cmdError('noSymbols', "no HAL variable #{a.name}") unless hits.length
    if hits.length > 1
      throw cmdError('ambiguous', "#{a.name} is declared in " +
        (("#{h.csect}" for h in hits).join(', ')) +
        ' -- qualify it as UNIT.NAME')
    throw cmdError('badArgs', "encoding: expected 'ascii' or 'ebcdic'") unless a.encoding in ['ascii', 'ebcdic']
    sdl.read(hits[0], s.readHw, { limit: a.limit ? 32,
                                  fieldLimit: a.fields ? 32
                                  encoding: a.encoding })
  render: renderValue

defc 'halat',
  summary: 'What the SDL index says is at an address'
  params: [{ name: 'addr', type: 'addr', required: true }]
  exec: (s, a) ->
    sdl = needSdl(s)
    v = sdl.varAt(a.addr)
    {
      addr: a.addr
      variable: if v? then Object.assign(sdl.describe(v),
        { offset_in: a.addr - v.addr }) else null
      block: sdl.blockAt(a.addr)
      statement: sdl.stmtAt(a.addr)
    }
  render: (r) ->
    lines = ["  #{hex(r.addr, 5)}"]
    if r.block?
      lines.push "    #{r.block.kind ? 'BLOCK'} #{r.block.name} " +
        "#{r.block.csect}+#{hex(r.addr - r.block.addr, 4)}  #{r.block.unit ? ''}"
    if r.statement?
      lines.push "    statement #{r.statement.stmt}" +
        "#{if r.statement.srn then " SRN #{r.statement.srn}" else ''}" +
        " at #{hex(r.statement.addr, 5)}"
    if r.variable?
      lines.push "    #{r.variable.name} #{r.variable.type} " +
        "#{r.variable.csect}+#{hex(r.variable.offset, 4)}" +
        "#{if r.variable.offset_in then " +#{r.variable.offset_in}" else ''}"
    lines.push '    nothing in the index covers it' if lines.length == 1
    lines.join('\n')
