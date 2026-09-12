import {defc, cmdError} from './registry'
import {hex, locStr, renderList} from './render'

defc 'sym',
  summary: 'Look symbols up by name or substring'
  aliases: ['symbol']
  params: [
    { name: 'name', type: 'str', required: true }
    { name: 'limit', type: 'int', flag: true, default: 40 }
  ]
  exec: (s, a) ->
    throw cmdError('noSymbols', 'no symbols loaded') unless s.hasSymbols()
    hits = for x in s.syms.search(a.name, a.limit ? 40)
      Object.assign({}, x, { hex: hex(x.addr, 5), section: s.sectionOf(x.addr) })
    { symbols: hits, query: a.name }
  render: (r) ->
    renderList r.symbols, "no symbol matching #{r.query}", (x) ->
      "  #{x.name.rpad(' ', 16)} #{x.hex}  #{(x.type ? '').rpad(' ', 10)} " +
      "#{(x.section ? '').rpad(' ', 14)} [#{x.source}]"

defc 'sections',
  summary: 'The section map'
  aliases: ['sect']
  params: [{ name: 'match', type: 'str', flag: true }]
  exec: (s, a) ->
    want = a.match?.toUpperCase()
    rows = for sect in s.syms.sections() when not want? or sect.name.toUpperCase().indexOf(want) >= 0
      {
        name: sect.name, addr: sect.addr, hex: hex(sect.addr, 5)
        end: sect.addr + sect.size - 1, size: sect.size
        module: sect.module, source: sect.source
      }
    { sections: rows }
  render: (r) ->
    renderList r.sections, 'no symbols loaded', (x) ->
      "  #{x.hex} - #{hex(x.end, 5)}  #{x.name.rpad(' ', 14)} (#{x.size} HW, #{x.module})" +
      "#{if x.source == 'base' then '' else " [#{x.source}]"}"

defc 'resolve',
  summary: 'Resolve an address expression'
  params: [{ name: 'expr', type: 'str', required: true }]
  exec: (s, a) ->
    addr = s.resolveAddr(a.expr)
    throw cmdError('badArgs', "cannot resolve '#{a.expr}'") unless addr?
    Object.assign(s.location(addr), { expr: a.expr, source: s.syms.sourceAt(addr) })
  render: (r) ->
    "  #{r.expr} = #{locStr(r)}#{if r.section then " [#{r.section}]" else ''}" +
    "#{if r.source == 'base' then '' else " (#{r.source})"}"

defc 'symload',
  summary: 'Load a symbol table as a layer over the image, for an overlay'
  params: [
    { name: 'file', type: 'str', required: true }
    { name: 'name', type: 'str', flag: true }
    { name: 'lo', type: 'addr', flag: true }
    { name: 'hi', type: 'addr', flag: true }
    { name: 'switch', type: 'bool', flag: true, default: false }
  ]
  exec: (s, a) ->
    if (a.lo? and not a.hi?) or (a.hi? and not a.lo?)
      throw cmdError('badArgs', 'a range needs both --lo and --hi')
    try
      layer = s.syms.load(a.file, { name: a.name, lo: a.lo, hi: a.hi })
    catch e
      throw cmdError('symbolsFailed', e.message)
    s.syms.switchTo(layer.name) if a.switch
    { layer: layerRow(layer), layers: s.syms.describe() }
  render: (r) ->
    "loaded #{r.layer.name}: #{r.layer.symbols} symbols, #{r.layer.sections} sections" +
    "#{rangeStr(r.layer)}"

layerRow = (l) ->
  {
    name: l.name, path: l.path, enabled: l.enabled, lo: l.lo, hi: l.hi
    symbols: l.table?.symbols?.symbols?.length ? l.symbols ? 0
    sections: l.table?.sectionsByAddr?.length ? l.sections ? 0
  }

rangeStr = (l) ->
  if l.lo? then " over #{hex(l.lo, 5)}-#{hex(l.hi, 5)}" else " (unscoped)"

defc 'symunload',
  summary: 'Drop a symbol layer, or all of them with *'
  params: [{ name: 'name', type: 'str', required: true }]
  exec: (s, a) ->
    if a.name == '*'
      return { dropped: s.syms.unloadAll(), all: true }
    n = s.syms.unload(a.name)
    throw cmdError('noLayer', "no symbol layer named #{a.name}") unless n
    { dropped: n, name: a.name }
  render: (r) ->
    if r.all then "dropped #{r.dropped} symbol layers" else "dropped #{r.name}"

defc 'symswitch',
  summary: 'Make a layer the one in force, standing down the layers it overlaps'
  params: [{ name: 'name', type: 'str', required: true }]
  exec: (s, a) ->
    l = s.syms.switchTo(a.name)
    throw cmdError('noLayer', "no symbol layer named #{a.name}") unless l?
    { active: a.name, layers: s.syms.describe() }
  render: (r) ->
    lines = ["switched to #{r.active}"]
    lines.push renderLayer(l) for l in r.layers
    lines.join('\n')

defc 'symenable',
  summary: 'Enable or disable a symbol layer'
  params: [
    { name: 'name', type: 'str', required: true }
    { name: 'state', type: 'bool', default: true }
  ]
  exec: (s, a) ->
    l = s.syms.setEnabled(a.name, a.state)
    throw cmdError('noLayer', "no symbol layer named #{a.name}") unless l?
    { layers: s.syms.describe() }
  render: (r) -> (renderLayer(l) for l in r.layers).join('\n')

renderLayer = (l) ->
  "  [#{if l.enabled then 'ON ' else 'OFF'}] #{l.name.rpad(' ', 16)}" +
  "#{rangeStr(l)}  #{l.symbols} symbols, #{l.sections} sections"

defc 'symlayers',
  summary: 'The symbol layers in force, topmost last'
  aliases: ['syms']
  exec: (s) -> { layers: s.syms.describe(), base: {
    loaded: s.sym.symbols?
    symbols: s.sym.symbols?.symbols?.length ? 0
    sections: s.sym.sectionsByAddr?.length ? 0
  } }
  render: (r) ->
    lines = ["  [base] #{r.base.symbols} symbols, #{r.base.sections} sections"]
    lines.push renderLayer(l) for l in r.layers
    lines.join('\n')

renderAuto = (r) ->
  lines = ["  base #{r.base ? '?'}" +
           "#{if r.adopted? then ", holding #{r.adopted}" else ''}" +
           ", auto #{if r.armed then 'on' else 'off'}" +
           " (adopt at #{Math.round(r.min * 100)}%)"]
  if r.fcos?
    lines.push '  software ' +
      (("#{v.variable} #{v.mc}" for v in r.fcos.read).join(', '))
    if r.fcos.mc > 0
      lines.push "    MC #{r.fcos.mc}" +
        "#{if r.fcos.phases? then " phases #{r.fcos.phases.join(',')}" else ''}" +
        "#{if r.fcos.config? then " -> #{r.fcos.config}" else ' (no configuration carries them)'}"
    else
      lines.push '    it has not moded to a configuration'
  else
    lines.push '  software record unreadable (no SDL index)'
  if r.agrees == false
    lines.push "  memory says #{r.best}, the software says #{r.fcos.config}"
  lines.push '  phase ' + (("#{p.phase}:#{pct(p.score).trim()}" for p in r.residency).join(' '))
  for row in r.fingerprint
    mark = if row.config == r.best then '*' else ' '
    lines.push " #{mark} #{row.config.rpad(' ', 6)} " +
      "#{pct(row.score)} (#{row.matched}/#{row.probed} of its weakest phase)" +
      "#{phaseText(row)}"
  lines.push "  took #{r.took.config}: #{[
    (if r.took.layer? then "symbol layer #{r.took.layer}" else 'base symbols'),
    (if r.took.sdl? then 'SDL index' else 'no SDL index')].join(', ')}" if r.took?
  lines.join('\n')

pct = (x) -> "#{(x * 100).toFixed(1)}%".padStart(6)

phaseText = (row) ->
  short = (p for p in (row.phases ? []) when p.score < 0.995)
  return " phases #{row.want.join(',')}" unless short.length
  '  short: ' + (("#{p.phase} #{pct(p.score).trim()}" for p in short).join(' '))

defc 'symauto',
  summary: 'Detect the memory configuration in storage and take its symbols on'
  params: [
    { name: 'state', type: 'bool' }
    { name: 'adopt', type: 'bool', flag: true, default: false }
    { name: 'config', type: 'str', flag: true }
    { name: 'root', type: 'str', flag: true }
    { name: 'min', type: 'int', flag: true }
  ]
  exec: (s, a) ->
    s.autoConfig.min = a.min / 100 if a.min?
    s.configRoot = require('path').resolve(a.root) if a.root?
    if a.config?
      try
        adopted = s.adoptConfig(a.config)
      catch e
        throw cmdError('noConfig', e.message)
      return Object.assign(s.detectConfig(), { adopted: adopted.config,
                                               took: adopted })
    if a.state?
      s.autoConfig.armed = a.state
    try
      r = s.detectConfig()
    catch e
      throw cmdError('noConfigs', e.message)
    if (a.adopt or (a.state and not s.autoConfig.adopted?)) and r.best?
      r.took = s.adoptConfig(r.best)
      r.adopted = r.best
    r
  render: renderAuto
