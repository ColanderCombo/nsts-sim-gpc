# Debug command table
#
# One entry per operation, carrying its parameters, a handler that returns
# JSON, and a renderer that turns that JSON into text.  `{"cmd":"step",
# "args":{"count":10}}` and `step 10` are coerced against the same parameter
# list and reach the same handler.
#
# Parameter types:
#   addr    an address: 0x-prefixed hex, a symbol, or bare hex, each
#           optionally followed by +/- an offset
#   addrs   a list of the above
#   int     decimal count
#   hex     hex value
#   hexes   a list of hex values
#   str     one token
#   text    the rest of the line, verbatim
#   bool    on/off, yes/no, true/false, 1/0
#   json    a structure, passed through from a JSON request; a text command
#           line carries it as one JSON token
#
# A parameter marked `flag` is only reachable as `--name value` (or `--name`
# alone when it is a bool).

require 'com/util'
import Instruction from 'gpc/cpu_instr'
import {formatRegDump, P} from 'gpc/trace'
import {ASCII_TO_EBCDIC} from 'gpc/ebcdic'
import {discreteName, resolveDiscrete,
        REG_A as DISC_REG_A, REG_B as DISC_REG_B} from 'com/discretes'

export PROTOCOL_VERSION = 1

export COMMANDS = {}
export ALIASES = {}

defc = (name, spec) ->
  spec.name = name
  spec.params ?= []
  COMMANDS[name] = spec
  for a in (spec.aliases ? [])
    ALIASES[a] = name
  spec

export lookupCommand = (name) ->
  return null unless name?
  key = String(name).toLowerCase()
  COMMANDS[key] ? COMMANDS[ALIASES[key] ? '']  ? null

class CmdError extends Error
  constructor: (@code, message) ->
    super(message)

export cmdError = (code, message) -> new CmdError(code, message)

#
# Argument coercion
#
BOOL_TRUE = ['on', 'yes', 'true', '1', 'enable', 'enabled']
BOOL_FALSE = ['off', 'no', 'false', '0', 'disable', 'disabled']

coerceOne = (session, p, raw) ->
  bad = (why) -> throw cmdError('badArgs', "#{p.name}: #{why}")
  switch p.type
    when 'addr'
      a = session.resolveAddr(raw)
      bad("cannot resolve '#{raw}'") unless a?
      a
    when 'addrs'
      list = if Array.isArray(raw) then raw else String(raw).split(/[\s,]+/)
      for r in list when String(r).length > 0
        a = session.resolveAddr(r)
        bad("cannot resolve '#{r}'") unless a?
        a
    when 'int'
      v = if typeof raw == 'number' then raw else parseInt(String(raw), 10)
      bad("'#{raw}' is not a number") if isNaN(v)
      v
    when 'hex'
      v = if typeof raw == 'number' then raw else parseInt(String(raw).replace(/^0[xX]/, ''), 16)
      bad("'#{raw}' is not hex") if isNaN(v)
      v
    when 'hexes'
      list = if Array.isArray(raw) then raw else String(raw).split(/[\s,]+/)
      for r in list when String(r).length > 0
        v = if typeof r == 'number' then r else parseInt(String(r).replace(/^0[xX]/, ''), 16)
        bad("'#{r}' is not hex") if isNaN(v)
        v
    when 'bool'
      return raw if typeof raw == 'boolean'
      t = String(raw).toLowerCase()
      return true if t in BOOL_TRUE
      return false if t in BOOL_FALSE
      bad("'#{raw}' is not on or off")
    when 'json'
      return raw unless typeof raw == 'string'
      try
        JSON.parse(raw)
      catch e
        bad("not JSON: #{e.message}")
    else String(raw)

export coerceArgs = (session, spec, args = {}) ->
  out = {}
  for p in spec.params
    raw = args[p.name]
    if not raw? or (typeof raw == 'string' and raw.length == 0 and p.type != 'text')
      throw cmdError('badArgs', "#{spec.name}: #{p.name} is required") if p.required
      out[p.name] = p.default ? null
      continue
    out[p.name] = coerceOne(session, p, raw)
  out

# Map a text command line's tokens onto the spec's parameters.  Positional
# tokens fill the non-flag parameters in order; `--name` takes the next token
# unless the parameter is a bool, and a `text` parameter takes what is left.
export parseArgLine = (spec, tokens) ->
  args = {}
  positional = (p for p in spec.params when not p.flag)
  byName = {}
  byName[p.name.toLowerCase()] = p for p in spec.params
  pi = 0
  i = 0
  while i < tokens.length
    tok = tokens[i]
    if tok.startsWith('--')
      key = tok.slice(2).toLowerCase()
      eq = key.indexOf('=')
      inline = null
      if eq >= 0
        inline = key.slice(eq + 1)
        key = key.slice(0, eq)
      p = byName[key]
      throw cmdError('badArgs', "#{spec.name}: unknown option --#{key}") unless p?
      if p.type == 'bool'
        args[p.name] = inline ? true
      else
        v = inline ? tokens[i + 1]
        throw cmdError('badArgs', "#{spec.name}: --#{key} needs a value") unless v?
        args[p.name] = v
        i++ unless inline?
      i++
      continue
    p = positional[pi]
    if not p?
      throw cmdError('badArgs', "#{spec.name}: unexpected argument '#{tok}'")
    if p.type == 'text'
      args[p.name] = tokens.slice(i).join(' ')
      i = tokens.length
    else if p.type in ['addrs', 'hexes']
      args[p.name] = tokens.slice(i)
      i = tokens.length
    else
      args[p.name] = tok
      i++
    pi++
  args

#
# Rendering helpers
#
hex = (v, n = 4) -> (v >>> 0).asHex(n)

locStr = (loc) ->
  return '?' unless loc?
  s = loc.hex
  s += " <#{loc.label}>" if loc.label
  s

export renderLocationLine = (session, addr = session.gpc.cpu.psw.getNIA()) ->
  hw1 = session.ram.get16(addr, false)
  hw2 = session.ram.get16(addr + 1, false)
  [d, v] = Instruction.decode(hw1, hw2)
  len = if d? then d.len else 1
  text = if d? then Instruction.toStr(hw1, hw2) else "DC    X'#{hex(hw1)}'"
  hw2s = if len > 1 then hex(hw2) else '    '
  sect = session.formatCSect(addr)
  ">> #{hex(addr, 5)} #{sect}: #{hex(hw1)} #{hw2s}  #{text}"

renderStop = (r, session) ->
  lines = []
  # The description often opens with the reason; print it once.
  what =
    if r.description and r.description.indexOf(r.reason) == 0 then r.description
    else if r.description then "#{r.reason}: #{r.description}"
    else r.reason
  lines.push "--- #{what} (#{r.steps} steps) ---"
  lines.push "refused: #{r.refused}" if r.refused
  lines.push renderLocationLine(session, r.location.addr)
  if r.watches?.length
    lines.push renderWatchRow(w) for w in r.watches
  lines.join('\n')

renderWatchRow = (w) ->
  v = if w.fw? then "HW=#{hex(w.hw)}  FW=#{hex(w.fw, 8)} (#{w.fw | 0})" else "#{hex(w.hw)} (#{w.hw})"
  "  #{w.name} @ #{hex(w.addr, 5)}: #{v}"

renderMemory = (r) ->
  lines = []
  if r.unit == 'fw'
    for v, i in r.values
      lines.push "  #{hex(r.addr + i * 2, 5)}: #{hex(v, 8)} (int32: #{v | 0}, uint32: #{v >>> 0})"
    return lines.join('\n')
  row = 0
  while row < r.values.length
    cols = Math.min(8, r.values.length - row)
    parts = []
    chars = []
    for c in [0...cols]
      hw = r.values[row + c]
      parts.push hex(hw)
      for b in [(hw >> 8) & 0xff, hw & 0xff]
        chars.push(if 0x20 <= b <= 0x7e then String.fromCharCode(b) else '.')
    lines.push "  #{hex(r.addr + row, 5)}: #{parts.join(' ').rpad(' ', 39)}  |#{chars.join('')}|"
    row += cols
  lines.join('\n')

renderDisasm = (r, session) ->
  nia = session.gpc.cpu.psw.getNIA()
  lines = []
  for row in r.rows
    lines.push "                          #{row.label}:" if row.label
    marker = if row.addr == nia then '>>' else '  '
    bp = if row.breakpoint then '*' else ' '
    hw2 = if row.len > 1 then hex(row.hw2) else '    '
    comment = if row.reloc then "  ; #{row.reloc}" else ''
    lines.push "#{marker}#{bp}#{hex(row.addr, 5)}: #{hex(row.hw1)} #{hw2}  #{row.text}#{comment}"
  lines.join('\n')

renderTrace = (r) ->
  lines = []
  for e in r.entries
    hw2 = if e.len > 1 then hex(e.hw2) else '    '
    comment = if e.reloc then "  ; #{e.reloc}" else ''
    lines.push "[#{String(e.step).lpad(' ', 7)}] #{hex(e.addr, 5)}" +
               "#{if e.label then " <#{e.label}>" else ''}: " +
               "#{hex(e.hw1)} #{hw2}  #{e.text}#{comment}"
  if lines.length == 0 then '  (trace empty)' else lines.join('\n')

renderList = (rows, empty, fn) ->
  return "  (#{empty})" if rows.length == 0
  (fn(r) for r in rows).join('\n')

durationStr = (us) ->
  return "#{(us / 1e6).toFixed(3)} s" if us >= 1e6
  return "#{(us / 1e3).toFixed(3)} ms" if us >= 1e3
  "#{us} us"

#
# Session and status
#
defc 'help',
  summary: 'List commands, or describe one'
  aliases: ['?', 'h']
  params: [{ name: 'command', type: 'str' }]
  exec: (s, a) ->
    if a.command?
      spec = lookupCommand(a.command)
      throw cmdError('unknownCommand', "no such command: #{a.command}") unless spec?
      return { commands: [describeCommand(spec)] }
    { commands: (describeCommand(COMMANDS[k]) for k in Object.keys(COMMANDS).sort()) }
  render: (r) ->
    if r.commands.length == 1
      c = r.commands[0]
      lines = ["#{c.name} #{(paramSig(p) for p in c.params).join(' ')}".trimEnd(), "  #{c.summary}"]
      lines.push "  aliases: #{c.aliases.join(', ')}" if c.aliases.length
      for p in c.params
        lines.push "  #{p.name.rpad(' ', 12)} #{p.type}#{if p.required then ' (required)' else ''}"
      return lines.join('\n')
    ("  #{c.name.rpad(' ', 16)} #{c.summary}" for c in r.commands).join('\n')

paramSig = (p) ->
  if p.flag then "[--#{p.name}#{if p.type == 'bool' then '' else " <#{p.type}>"}]"
  else if p.required then "<#{p.name}>"
  else "[#{p.name}]"

describeCommand = (spec) ->
  {
    name: spec.name
    summary: spec.summary
    aliases: spec.aliases ? []
    params: ({ name: p.name, type: p.type, required: !!p.required,
               flag: !!p.flag, default: p.default ? null } for p in spec.params)
  }

defc 'status',
  summary: 'Where the machine is and why it stopped'
  aliases: ['where', 'st']
  exec: (s) -> s.stopBody()
  render: renderStop

defc 'capabilities',
  summary: 'Protocol version, machine, and what is loaded'
  aliases: ['caps']
  exec: (s) ->
    {
      protocol: PROTOCOL_VERSION
      machine: s.gpc.machine
      fcm: s.fcmPath
      fcmName: s.fcmName
      symbols: {
        loaded: s.hasSymbols()
        path: s.symbolsPath ? null
        count: s.sym.symbols?.symbols?.length ? 0
        sections: s.sym.sectionsByAddr?.length ? 0
        layers: s.syms.describe()
      }
      commands: Object.keys(COMMANDS).sort()
      events: ['welcome', 'stopped', 'continued', 'running', 'output', 'input',
               'bus', 'discrete', 'logpoint']
      # Handled by the connection, so absent from `commands` above.
      connectionCommands: ['mode', 'subscribe', 'quit', 'shutdown']
    }
  render: (r) ->
    [
      "protocol #{r.protocol}, machine #{r.machine.name}"
      "fcm      #{r.fcm ? '(none)'}"
      "symbols  #{if r.symbols.loaded then "#{r.symbols.count} symbols, #{r.symbols.sections} sections" else '(none)'}"
    ].join('\n')

defc 'load',
  summary: 'Load an FCM image and its symbols'
  params: [
    { name: 'fcm', type: 'str', required: true }
    { name: 'symbols', type: 'str', flag: true }
  ]
  exec: (s, a) ->
    opts = Object.assign({}, s.opts)
    opts.symbols = a.symbols if a.symbols?
    info = s.load(a.fcm, opts)
    Object.assign({ fcm: a.fcm }, info, { location: s.location() })
  render: (r, s) ->
    lines = ["loaded #{r.fcm} (#{r.byteCount} bytes), entry #{locStr(r.location)} (#{r.entrySource})"]
    lines.push "symbols: #{r.symbolsPath}" if r.symbolsPath
    lines.push "warning: #{w}" for w in [r.entryWarning, r.protectWarning] when w?
    lines.push renderLocationLine(s, r.location.addr)
    lines.join('\n')

defc 'reset',
  summary: 'Reset the machine and reload the image'
  exec: (s) ->
    s.reset()
    s.stopBody()
  render: renderStop

#
# Execution
#
defc 'step',
  summary: 'Execute instructions, stopping at breakpoints'
  aliases: ['s', 'si']
  params: [{ name: 'count', type: 'int', default: 1 }]
  exec: (s, a) -> s.stepInstr(a.count ? 1)
  render: renderStop

defc 'next',
  summary: 'Step over the instruction at the NIA'
  aliases: ['n']
  exec: (s) -> s.stepOver()
  render: renderStop

defc 'continue',
  summary: 'Run until a breakpoint, a halt, or the step budget'
  aliases: ['c', 'run', 'r', 'g', 'go']
  params: [{ name: 'maxsteps', type: 'int', flag: true }]
  exec: (s, a) -> s.continueRun(a.maxsteps ? s.maxSteps)
  render: renderStop

defc 'until',
  summary: 'Run to an address'
  aliases: ['runto', 'tbreak']
  params: [
    { name: 'addr', type: 'addr', required: true }
    { name: 'maxsteps', type: 'int', flag: true }
  ]
  exec: (s, a) -> s.runTo(a.addr, a.maxsteps ? s.maxSteps)
  render: renderStop

defc 'pause',
  summary: 'Stop a run in progress'
  aliases: ['stop', 'interrupt']
  exec: (s) -> s.pause()
  render: renderStop

defc 'input',
  summary: 'Answer a program read'
  params: [
    { name: 'text', type: 'text', default: '' }
    { name: 'noresume', type: 'bool', flag: true, default: false }
  ]
  exec: (s, a) ->
    wasRunning = s.provideInput(a.text ? '')
    throw cmdError('notWaiting', 'the program is not waiting for input') if wasRunning == false and not s.halUCP.waitingForInput
    # A read that interrupted a run resumes it, unless the client is
    # holding the machine at the read -- the GUI's `break on input`.
    return s.stopBody() if a.noresume
    s.resumeAfterInput(wasRunning)
  render: renderStop

defc 'output',
  summary: 'Program output written so far'
  params: [{ name: 'clear', type: 'bool', flag: true, default: false }]
  exec: (s, a) ->
    text = (o.text for o in s.outputLog).join('')
    dropped = s.outputDropped
    if a.clear
      s.outputLog = []
      s.outputDropped = 0
    { text, dropped, chunks: s.outputLog.length }
  render: (r) ->
    if r.dropped > 0 then "(#{r.dropped} earlier chunks dropped)\n#{r.text}" else r.text

#
# Breakpoints
#
defc 'break',
  summary: 'Set an instruction breakpoint'
  aliases: ['b', 'bp']
  params: [
    { name: 'addr', type: 'addr', required: true }
    { name: 'name', type: 'str', flag: true }
    { name: 'ignore', type: 'int', flag: true, default: 0 }
    { name: 'once', type: 'bool', flag: true, default: false }
  ]
  exec: (s, a) ->
    { breakpoint: s.setBreakpoint(a.addr, { name: a.name, ignore: a.ignore, once: a.once }) }
  render: (r) ->
    b = r.breakpoint
    extra = []
    extra.push "ignoring #{b.ignore}" if b.ignore
    extra.push 'once' if b.once
    "breakpoint at #{locStr(b)}#{if extra.length then " (#{extra.join(', ')})" else ''}"

defc 'bclear',
  summary: 'Clear a breakpoint, or all of them with *'
  aliases: ['bc', 'delete']
  params: [{ name: 'addr', type: 'str', required: true }]
  exec: (s, a) ->
    if a.addr == '*'
      return { cleared: s.clearBreakpoints(), all: true }
    addr = s.resolveAddr(a.addr)
    throw cmdError('badArgs', "cannot resolve '#{a.addr}'") unless addr?
    throw cmdError('noBreakpoint', "no breakpoint at #{hex(addr, 5)}") unless s.clearBreakpoint(addr)
    { cleared: 1, addr }
  render: (r) ->
    if r.all then "cleared #{r.cleared} breakpoints" else "cleared breakpoint at #{hex(r.addr, 5)}"

defc 'benable',
  summary: 'Enable or disable a breakpoint'
  params: [
    { name: 'addr', type: 'addr', required: true }
    { name: 'state', type: 'bool', default: true }
  ]
  exec: (s, a) ->
    bp = s.setBreakpointEnabled(a.addr, a.state)
    throw cmdError('noBreakpoint', "no breakpoint at #{hex(a.addr, 5)}") unless bp?
    { breakpoint: bp }
  render: (r) -> "breakpoint at #{locStr(r.breakpoint)} #{if r.breakpoint.enabled then 'enabled' else 'disabled'}"

defc 'bdisable',
  summary: 'Disable a breakpoint'
  params: [{ name: 'addr', type: 'addr', required: true }]
  exec: (s, a) ->
    bp = s.setBreakpointEnabled(a.addr, false)
    throw cmdError('noBreakpoint', "no breakpoint at #{hex(a.addr, 5)}") unless bp?
    { breakpoint: bp }
  render: (r) -> "breakpoint at #{locStr(r.breakpoint)} disabled"

defc 'breakpoints',
  summary: 'List breakpoints'
  aliases: ['bl', 'blist']
  exec: (s) -> { breakpoints: s.breakpointList() }
  render: (r) ->
    renderList r.breakpoints, 'no breakpoints', (b) ->
      extra = []
      extra.push "#{b.hits} hits" if b.hits
      extra.push "ignoring #{b.ignore}" if b.ignore
      extra.push 'once' if b.once
      "  [#{if b.enabled then 'ON ' else 'OFF'}] #{locStr(b)}" +
      "#{if b.name and b.name != b.label then " <#{b.name}>" else ''}" +
      "#{if extra.length then "  (#{extra.join(', ')})" else ''}"

defc 'setbreakpoints',
  summary: 'Replace the breakpoint set with this list'
  params: [{ name: 'addrs', type: 'addrs', default: [] }]
  exec: (s, a) ->
    s.clearBreakpoints()
    s.setBreakpoint(addr) for addr in (a.addrs ? [])
    { breakpoints: s.breakpointList() }
  render: (r) -> "#{r.breakpoints.length} breakpoints set"

#
# Data breakpoints
#
defc 'watchmem',
  summary: 'Stop when a halfword changes, or on any write to it'
  aliases: ['mw', 'wm']
  params: [
    { name: 'addr', type: 'addr', required: true }
    { name: 'count', type: 'int', default: 1 }
    { name: 'on', type: 'str', flag: true, default: 'change' }
  ]
  exec: (s, a) ->
    throw cmdError('badArgs', "on: expected 'change' or 'write'") unless a.on in ['change', 'write']
    label = s.labelAt(a.addr)
    n = Math.max(1, a.count ? 1)
    set = for i in [0...n]
      name = if n > 1 and label then "#{label}+#{i}" else label
      s.setDataBreakpoint(a.addr + i, { on: a.on, name })
    { dataBreakpoints: set }
  render: (r) ->
    renderList r.dataBreakpoints, 'none', (w) ->
      "  [ON ] #{locStr(w)} on #{w.on} = #{hex(w.value)}"

defc 'wmclear',
  summary: 'Clear a data breakpoint, or all of them with *'
  aliases: ['mwc']
  params: [{ name: 'addr', type: 'str', required: true }]
  exec: (s, a) ->
    if a.addr == '*'
      return { cleared: s.clearDataBreakpoints(), all: true }
    addr = s.resolveAddr(a.addr)
    throw cmdError('badArgs', "cannot resolve '#{a.addr}'") unless addr?
    throw cmdError('noBreakpoint', "no data breakpoint at #{hex(addr, 5)}") unless s.clearDataBreakpoint(addr)
    { cleared: 1, addr }
  render: (r) ->
    if r.all then "cleared #{r.cleared} data breakpoints" else "cleared data breakpoint at #{hex(r.addr, 5)}"

defc 'watchmems',
  summary: 'List data breakpoints'
  aliases: ['mwl', 'wml']
  exec: (s) -> { dataBreakpoints: s.dataBreakpointList() }
  render: (r) ->
    renderList r.dataBreakpoints, 'no data breakpoints', (w) ->
      "  [#{if w.enabled then 'ON ' else 'OFF'}] #{locStr(w)} on #{w.on} = #{hex(w.value)}"

#
# Watch list
#
defc 'watch',
  summary: 'Add to the watch list reported at every stop'
  aliases: ['w']
  params: [
    { name: 'addr', type: 'addr', required: true }
    { name: 'size', type: 'int', default: 2 }
  ]
  exec: (s, a) -> { watch: s.setWatch(a.addr, a.size ? 2) }
  render: (r) -> renderWatchRow(r.watch)

defc 'unwatch',
  summary: 'Remove a watch, or all of them with *'
  aliases: ['wc']
  params: [{ name: 'addr', type: 'str', required: true }]
  exec: (s, a) ->
    if a.addr == '*'
      return { cleared: s.clearWatches(), all: true }
    addr = s.resolveAddr(a.addr)
    throw cmdError('badArgs', "cannot resolve '#{a.addr}'") unless addr?
    throw cmdError('noWatch', "no watch at #{hex(addr, 5)}") unless s.clearWatch(addr)
    { cleared: 1, addr }
  render: (r) ->
    if r.all then "cleared #{r.cleared} watches" else "cleared watch at #{hex(r.addr, 5)}"

defc 'watches',
  summary: 'List watches with their current values'
  aliases: ['wl']
  exec: (s) -> { watches: s.watchList() }
  render: (r) -> renderList(r.watches, 'no watches', renderWatchRow)

#
# Memory
#
defc 'mem',
  summary: 'Read memory'
  aliases: ['x', 'examine', 'readmem']
  params: [
    { name: 'addr', type: 'addr', required: true }
    { name: 'count', type: 'int', default: 16 }
    { name: 'unit', type: 'str', flag: true, default: 'hw' }
  ]
  exec: (s, a) ->
    throw cmdError('badArgs', "unit: expected 'hw' or 'fw'") unless a.unit in ['hw', 'fw']
    n = Math.max(1, a.count ? 16)
    values =
      if a.unit == 'fw'
        (s.ram.get32(a.addr + i * 2, false) >>> 0 for i in [0...n])
      else
        (s.ram.get16(a.addr + i, false) for i in [0...n])
    { addr: a.addr, hex: hex(a.addr, 5), unit: a.unit, count: n, values }
  render: renderMemory

defc 'writemem',
  summary: 'Write memory, ignoring store protection'
  aliases: ['deposit', 'dep']
  params: [
    { name: 'addr', type: 'addr', required: true }
    { name: 'values', type: 'hexes', required: true }
    { name: 'unit', type: 'str', flag: true, default: 'hw' }
  ]
  exec: (s, a) ->
    throw cmdError('badArgs', "unit: expected 'hw' or 'fw'") unless a.unit in ['hw', 'fw']
    written = for v, i in a.values
      if a.unit == 'fw'
        addr = a.addr + i * 2
        s.ram.set32(addr, v >>> 0, false)
        { addr, value: v >>> 0 }
      else
        addr = a.addr + i
        s.ram.set16(addr, v & 0xffff, false)
        { addr, value: v & 0xffff }
    { unit: a.unit, written }
  render: (r) ->
    w = if r.unit == 'fw' then 8 else 4
    ("  #{hex(x.addr, 5)}: #{hex(x.value, w)}" for x in r.written).join('\n')

#
# Registers
#
defc 'regs',
  summary: 'Show the register file and PSW'
  aliases: ['reg', 'registers']
  params: [{ name: 'name', type: 'str' }]
  exec: (s, a) ->
    cpu = s.gpc.cpu
    set = cpu.psw.getRegSet()
    all = {
      bank: set
      gr: (cpu.regFiles[set].r(i).get32() >>> 0 for i in [0..7])
      fp: (cpu.regFiles[2].r(i).get32() >>> 0 for i in [0..7])
      psw1: cpu.psw.psw1.get32() >>> 0
      psw2: cpu.psw.psw2.get32() >>> 0
      nia: cpu.psw.getNIA()
      cc: cpu.psw.getCC()
      bsr: cpu.psw.getBSR()
      dsr: cpu.psw.getDSR()
      waitState: !!cpu.psw.getWaitState()
      steps: s.stepCount
      simTimeSec: s.simTimeSec()
    }
    return all unless a.name?
    v = registerValue(s, a.name)
    throw cmdError('badArgs', "unknown register: #{a.name}") unless v?
    { name: a.name.toUpperCase(), value: v }
  render: (r, s) ->
    return "  #{r.name} = #{hex(r.value, 8)} (#{r.value | 0})" if r.name?
    formatRegDump(s.gpc.cpu, r.steps, { color: P }).join('\n')

# `--bank` names a register file explicitly: 0 and 1 are the two general
# sets, 2 the floating point set.  Without it R<n> and DSE<n> mean the set
# the PSW is running in; a GUI showing both sets at once has to say which.
regBank = (s, bank) ->
  return s.gpc.cpu.psw.getRegSet() unless bank?
  throw cmdError('badArgs', 'bank must be 0, 1 or 2') unless bank in [0, 1, 2]
  bank

registerValue = (s, name, bank = null) ->
  cpu = s.gpc.cpu
  n = String(name).toUpperCase()
  set = regBank(s, bank)
  if (m = n.match(/^R0?(\d)$/)) and +m[1] <= 7 then return cpu.regFiles[set].r(+m[1]).get32() >>> 0
  if (m = n.match(/^FP(\d)$/)) and +m[1] <= 7 then return cpu.regFiles[2].r(+m[1]).get32() >>> 0
  if (m = n.match(/^DSE(\d)$/)) and +m[1] <= 7 then return cpu.regFiles[set].getDSE(+m[1])
  switch n
    when 'NIA'  then cpu.psw.getNIA()
    when 'CC'   then cpu.psw.getCC()
    when 'PSW1' then cpu.psw.psw1.get32() >>> 0
    when 'PSW2' then cpu.psw.psw2.get32() >>> 0
    when 'BSR'  then cpu.psw.getBSR()
    when 'DSR'  then cpu.psw.getDSR()
    else null

defc 'setreg',
  summary: 'Set a register'
  aliases: ['set']
  params: [
    { name: 'name', type: 'str', required: true }
    { name: 'value', type: 'hex', required: true }
    { name: 'bank', type: 'int', flag: true }
  ]
  exec: (s, a) ->
    cpu = s.gpc.cpu
    n = a.name.toUpperCase()
    set = regBank(s, a.bank)
    ok = true
    if (m = n.match(/^R0?(\d)$/)) and +m[1] <= 7
      cpu.regFiles[set].r(+m[1]).set32(a.value)
    else if (m = n.match(/^FP(\d)$/)) and +m[1] <= 7
      cpu.regFiles[2].r(+m[1]).set32(a.value)
    else if (m = n.match(/^DSE(\d)$/)) and +m[1] <= 7
      cpu.regFiles[set].setDSE(+m[1], a.value)
    else
      switch n
        when 'NIA'  then cpu.psw.setNIA(a.value & 0x7ffff)
        when 'CC'   then cpu.psw.setCC(a.value & 0x3)
        when 'PSW1' then cpu.psw.psw1.set32(a.value)
        when 'PSW2' then cpu.psw.psw2.set32(a.value)
        else ok = false
    throw cmdError('badArgs', "cannot set #{n}") unless ok
    { name: n, bank: (if a.bank? then set else null), value: registerValue(s, n, a.bank) }
  render: (r) -> "  #{r.name} = #{hex(r.value, 8)}"

#
# Disassembly
#
defc 'disasm',
  summary: 'Disassemble from an address'
  aliases: ['d', 'u', 'dis']
  params: [
    { name: 'addr', type: 'addr' }
    { name: 'count', type: 'int', default: 20 }
  ]
  exec: (s, a) ->
    addr = a.addr ? s.gpc.cpu.psw.getNIA()
    n = Math.max(1, a.count ? 20)
    rows = []
    for i in [0...n]
      break if addr >= 0x80000
      hw1 = s.ram.get16(addr, false)
      hw2 = s.ram.get16(addr + 1, false)
      [d, v] = Instruction.decode(hw1, hw2)
      len = if d? then d.len else 1
      rows.push Object.assign(s.location(addr), {
        hw1, hw2: (if len > 1 then hw2 else null), len
        text: if d? then Instruction.toStr(hw1, hw2) else "DC    X'#{hex(hw1)}'"
        reloc: s.relocAt(addr, len)
        breakpoint: s.breakpoints.get(addr)?.enabled ? false
      })
      addr += len
    { addr: rows[0]?.addr ? addr, rows }
  render: renderDisasm

#
# Instruction trace
#
defc 'trace',
  summary: 'Turn the instruction trace ring on or off'
  params: [
    { name: 'state', type: 'bool' }
    { name: 'limit', type: 'int', flag: true }
  ]
  exec: (s, a) ->
    return s.setTrace(a.state, a.limit) if a.state? or a.limit?
    { enabled: s.traceEnabled, limit: s.traceLimit, entries: s.traceRing.length }
  render: (r) ->
    "trace #{if r.enabled then 'on' else 'off'}, #{r.entries}/#{r.limit} entries"

defc 'tracelog',
  summary: 'The instructions the trace ring holds'
  aliases: ['tl', 'history']
  params: [
    { name: 'count', type: 'int', default: 50 }
    { name: 'clear', type: 'bool', flag: true, default: false }
  ]
  exec: (s, a) ->
    entries = s.traceLog(a.count ? 50)
    total = s.traceRing.length
    s.clearTrace() if a.clear
    { entries, total, enabled: s.traceEnabled }
  render: renderTrace

#
# Symbols and sections
#
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

#
# Interrupts and interval timers
#
defc 'ints',
  summary: 'Interrupt repertoire, masks and pending latches'
  aliases: ['interrupts', 'int']
  exec: (s) ->
    cpu = s.gpc.cpu
    {
      systemMask: cpu.psw.getIntMask()
      machineCheckMask: if cpu.psw.getMachCheckMask() then 1 else 0
      breakOnInterrupt: s.breakOnInterrupt
      hold: !!cpu.intHold
      held: cpu.heldInterrupt() ? null
      count: cpu.intCount
      interrupts: cpu.intStatus()
      timers: timerRows(s)
      iopGroup1: s.gpc.iop?.group1Sources?() ? []
    }
  render: (r) ->
    lines = ["=== INTERVAL TIMERS ==="]
    for t in r.timers
      pend = if t.pending then '  PENDING' else ''
      lines.push "  TIMER #{t.n}  #{hex(t.value, 8)}  timeout in #{durationStr(t.remainingUs)}#{pend}"
    lines.push "=== INTERRUPTS === (system mask #{hex(r.systemMask, 2)}, machine check mask #{r.machineCheckMask})"
    lines.push "   KEY           CLS  MASK  OLD/NEW    STATE"
    for st in r.interrupts
      lamp = if st.held then '>' else if st.pending then '*' else ' '
      maskStr = if st.maskBit? then "#{st.maskBit}:#{if st.enabled then 1 else 0}" else 'n/m'
      state =
        if st.held then 'HELD before PSW swap'
        else if st.blocked then "pending, MASKED #{if st.pends then '(held)' else '(will be dropped)'}"
        else if st.pending then 'pending'
        else if not st.enabled then 'masked off'
        else ''
      vector = if st.hasHandler then '' else '  (no handler)'
      lines.push " #{lamp} #{st.key.rpad(' ', 13)} #{st.cls.rpad(' ', 4)} #{maskStr.rpad(' ', 5)} " +
                 "#{hex(st.old)}/#{hex(st.new)}  #{state}#{vector}"
    lines.push "   IOP interrupt register A (External 0): #{r.iopGroup1.join(', ')}" if r.iopGroup1.length
    lines.push "   break on interrupt #{if r.breakOnInterrupt then 'on' else 'off'}, hold #{if r.hold then 'on' else 'off'}"
    lines.join('\n')

timerRows = (s) ->
  for n in [1, 2]
    {
      n, value: s.gpc.cpu.timerValue(n) >>> 0
      remainingUs: s.gpc.cpu.timerRemainingUs(n)
      pending: !!s.gpc.cpu.intPending["clk#{n}"]
      # Where the high halfword lives in the PSA; the low one is in the
      # hardware counter.  Reported so a remote display need not carry the
      # constant.
      hiAddr: s.gpc.cpu.TIMER_HI(n)
    }

defc 'intraise',
  summary: 'Force an interrupt pending, as the AGE could'
  params: [
    { name: 'key', type: 'str', required: true }
    { name: 'code', type: 'hex' }
  ]
  exec: (s, a) ->
    cpu = s.gpc.cpu
    opts = if a.code? then { code: a.code } else {}
    try
      spec = cpu.raiseInterrupt(a.key, opts)
    catch e
      throw cmdError('badArgs', e.message)
    hasHandler = cpu.intHasHandler(spec)
    before = cpu.intCount
    # Nothing looks at the latch until the next instruction, so a raise
    # against a stopped machine is serviced here.
    cpu.checkInterrupts() unless s.running
    taken = if cpu.intCount > before then s.lastInterrupt else null
    {
      key: a.key, hasHandler, taken
      held: cpu.heldInterrupt() ? null
      location: s.location()
    }
  render: (r) ->
    lines = []
    lines.push "no handler installed: the new PSW is all zeros" unless r.hasHandler
    if r.taken?
      lines.push "#{r.taken.label} taken: #{hex(r.taken.fromNIA, 5)} -> #{hex(r.taken.toNIA, 5)}"
    else if r.held?
      lines.push "#{r.held.label} held before PSW swap at #{hex(r.held.fromNIA, 5)}"
    else
      lines.push "#{r.key} pending"
    lines.join('\n')

defc 'intclear',
  summary: 'Clear a pending interrupt latch'
  params: [{ name: 'key', type: 'str', required: true }]
  exec: (s, a) ->
    try
      s.gpc.cpu.clearInterrupt(a.key)
    catch e
      throw cmdError('badArgs', e.message)
    { key: a.key }
  render: (r) -> "#{r.key} cleared"

defc 'intmask',
  summary: 'Show or change a PSW interrupt mask bit'
  params: [
    { name: 'bit', type: 'int', required: true }
    { name: 'state', type: 'bool' }
  ]
  exec: (s, a) ->
    psw = s.gpc.cpu.psw
    bit = a.bit
    throw cmdError('badArgs', 'mask bit must be 32-39 (system) or 45 (machine check)') unless (32 <= bit <= 39) or bit == 45
    cur = if bit == 45 then !!psw.getMachCheckMask() else (psw.getIntMask() & (1 << (39 - bit))) != 0
    want = a.state ? not cur
    if bit == 45
      psw.setMachCheckMask(if want then 1 else 0)
    else
      b = 1 << (39 - bit)
      psw.setIntMask(if want then (psw.getIntMask() | b) else (psw.getIntMask() & ~b & 0xff))
    { bit, enabled: want, systemMask: psw.getIntMask() }
  render: (r) ->
    "PSW mask bit #{r.bit} is #{if r.enabled then 'enabled' else 'masked off'} (system mask #{hex(r.systemMask, 2)})"

defc 'intlog',
  summary: 'Interrupts accepted since power-on'
  params: [
    { name: 'count', type: 'int', default: 20 }
    { name: 'clear', type: 'bool', flag: true, default: false }
  ]
  exec: (s, a) ->
    cpu = s.gpc.cpu
    entries = for e in (cpu.intLog ? []).slice(-(a.count ? 20))
      Object.assign({}, e, {
        codeLabel: (if e.code? then cpu.intCodeLabel(e.key, e.code) else null) ? null
        from: s.location(e.fromNIA), to: s.location(e.toNIA)
      })
    total = cpu.intCount
    s.clearInterruptLog() if a.clear
    { entries, total }
  render: (r) ->
    renderList r.entries, 'no interrupts accepted', (e) ->
      code = if e.code? then "  code #{hex(e.code)}#{if e.codeLabel then " (#{e.codeLabel})" else ''}" else ''
      "  #{String(e.seq).lpad(' ', 4)}  #{((e.timeNs / 1e6).toFixed(3) + ' ms').lpad(' ', 12)}  " +
      "#{e.key.rpad(' ', 13)}#{locStr(e.from)} -> #{locStr(e.to)}#{code}"

defc 'intbreak',
  summary: 'Break when an interrupt is accepted'
  params: [{ name: 'state', type: 'bool' }]
  exec: (s, a) ->
    s.setBreakOnInterrupt(a.state ? not s.breakOnInterrupt)
    { enabled: s.breakOnInterrupt }
  render: (r) -> "break on interrupt is #{if r.enabled then 'on' else 'off'}"

defc 'inthold',
  summary: 'Stop in front of the PSW swap, not after it'
  params: [{ name: 'state', type: 'bool' }]
  exec: (s, a) ->
    s.setHoldInterrupt(a.state ? not s.gpc.cpu.intHold)
    { enabled: !!s.gpc.cpu.intHold, held: s.gpc.cpu.heldInterrupt() ? null }
  render: (r) -> "hold before PSW swap is #{if r.enabled then 'on' else 'off'}"

defc 'timers',
  summary: 'Show the interval timers'
  exec: (s) -> { timers: timerRows(s) }
  render: (r) ->
    ("  TIMER #{t.n} = #{hex(t.value, 8)} (timeout in #{durationStr(t.remainingUs)})" for t in r.timers).join('\n')

defc 'timerload',
  summary: 'Load an interval timer, as the ICR would'
  params: [
    { name: 'n', type: 'int', required: true }
    { name: 'value', type: 'hex', required: true }
  ]
  exec: (s, a) ->
    throw cmdError('badArgs', 'timer must be 1 or 2') unless a.n in [1, 2]
    s.gpc.cpu.loadTimer(a.n, a.value)
    { timers: timerRows(s) }
  render: (r) ->
    ("  TIMER #{t.n} = #{hex(t.value, 8)} (timeout in #{durationStr(t.remainingUs)})" for t in r.timers).join('\n')

#
# IOP
#
defc 'iop',
  summary: 'IOP global registers and per-processor state'
  params: [{ name: 'active', type: 'bool', flag: true, default: false }]
  exec: (s, a) ->
    iop = s.gpc.iop
    throw cmdError('noIOP', 'no IOP on this machine') unless iop?
    procs = (p for p in (iop.procStates?() ? []) when p?)
    procs = (p for p in procs when p.enabled or p.busy or p.current) if a.active
    {
      slice: iop.ls?.slice ? 0
      currentPage: iop.ls?.curPage ? 0
      dmaQueue: iop.dmaQueue?.length ? 0
      dmaBurst: !!iop.dmaBurst
      watchdog: { count: iop.wdCount ? 0, running: !!iop.wdRunning, timedOut: !!iop.wdTimeout }
      group1: iop.group1Sources?() ? []
      registers: iop.globalRegs?() ? []
      processors: procs
    }
  render: (r) ->
    lines = ["slice #{r.slice}  current #{if r.currentPage == 0 then 'MSC' else "BCE #{r.currentPage}"}" +
             "  dma #{r.dmaQueue}#{if r.dmaBurst then ' burst' else ''}" +
             "  wdog #{hex(r.watchdog.count, 3)} #{if r.watchdog.timedOut then 'TIMED OUT' else if r.watchdog.running then 'running' else 'stopped'}"]
    lines.push "=== REGISTERS ==="
    for g in r.registers
      lines.push "  #{g.name.rpad(' ', 8)} #{hex(g.value, 8)}  #{g.note}"
    lines.push "=== PROCESSORS ==="
    lines.push "   #{'NAME'.rpad(' ', 8)} EN BSY GO IND TX RX  PC     REGISTERS"
    for p in r.processors
      b = (x) -> if x then ' 1' else ' 0'
      regs = ("#{x.name}=#{hex(x.value, 8)}" for x in p.regs).join(' ')
      lines.push " #{if p.current then '>' else ' '} #{p.name.rpad(' ', 8)}" +
                 "#{b(p.enabled)}#{b(p.busy).rpad(' ', 4)}#{b(p.go)}#{b(p.indicator).rpad(' ', 4)}" +
                 "#{b(p.xmitEna)}#{b(p.recvEna)}  #{hex(p.pc, 5)}  #{regs}"
    lines.join('\n')

defc 'iopdisasm',
  summary: 'Disassemble a IOP processor at its PC (0 = MSC, 1-24 = BCE)'
  aliases: ['iopd']
  params: [
    { name: 'proc', type: 'int', required: true }
    { name: 'count', type: 'int', default: 8 }
    { name: 'addr', type: 'addr', flag: true }
  ]
  exec: (s, a) ->
    iop = s.gpc.iop
    throw cmdError('noIOP', 'no IOP on this machine') unless iop?
    throw cmdError('badArgs', 'proc must be 0-24') unless 0 <= a.proc <= 24
    rows = iop.procDisasm(a.proc, a.count ? 8, a.addr ? null)
    st = iop.procStates?()[a.proc] ? null
    { proc: a.proc, name: st?.name ? "#{a.proc}", pc: st?.pc ? null, rows }
  render: (r) ->
    renderList r.rows, 'nothing to disassemble', (row) ->
      marker = if row.addr == r.pc then '>>' else '  '
      hw2 = if row.len > 1 then hex(row.hw2) else '    '
      "#{marker}#{hex(row.addr, 5)}: #{hex(row.hw1)} #{hw2}  #{row.text}"

#
# Real-time pacing
#
defc 'realtime',
  summary: 'Tie simulated time to the wall clock'
  aliases: ['rt']
  params: [
    { name: 'state', type: 'bool' }
    { name: 'factor', type: 'str', flag: true }
    { name: 'idletimeout', type: 'str', flag: true }
  ]
  exec: (s, a) ->
    s.setRealTime(a.state) if a.state?
    s.setRTFactor(a.factor) if a.factor?
    if a.idletimeout?
      t = parseFloat(a.idletimeout)
      s.rtIdleTimeoutMs = t * 1000 if isFinite(t) and t > 0
    {
      enabled: s.realTime, factor: s.rtFactor
      idleTimeoutSec: s.rtIdleTimeoutMs / 1000
      simTimeSec: s.simTimeSec(), speedRatio: s.speedRatio
    }
  render: (r) ->
    "real-time #{if r.enabled then 'on' else 'off'} at #{r.factor}x, " +
    "idle timeout #{r.idleTimeoutSec}s, sim time #{r.simTimeSec.toFixed(6)}s"

#
# Symbol layers
#
# An overlay reuses addresses another load already named, so the debugger
# holds several tables at once and picks between them by address range.
#
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

#
# Memory search
#
defc 'find',
  summary: 'Search memory for a run of halfwords or a string'
  params: [
    { name: 'values', type: 'hexes', default: [] }
    { name: 'text', type: 'str', flag: true }
    { name: 'encoding', type: 'str', flag: true, default: 'ascii' }
    { name: 'start', type: 'addr', flag: true }
    { name: 'end', type: 'addr', flag: true }
    { name: 'limit', type: 'int', flag: true, default: 32 }
  ]
  exec: (s, a) ->
    values = a.values ? []
    if a.text?
      throw cmdError('badArgs', "encoding: expected 'ascii' or 'ebcdic'") unless a.encoding in ['ascii', 'ebcdic']
      values = textToHalfwords(a.text, a.encoding)
    throw cmdError('badArgs', 'nothing to search for') unless values.length
    Object.assign(s.findMemory(values, {
      start: a.start, end: a.end, limit: a.limit ? 32
    }), { pattern: values })
  render: (r) ->
    head = "#{r.matches.length} match#{if r.matches.length == 1 then '' else 'es'} " +
           "in #{hex(r.start, 5)}-#{hex(r.end, 5)}#{if r.truncated then ' (limit reached)' else ''}"
    rows = renderList r.matches, 'no match', (m) ->
      "  #{locStr(m)}: #{(hex(v) for v in m.values).join(' ')}"
    "#{head}\n#{rows}"

# ASCII or EBCDIC text as the halfwords it occupies, two characters to one.
# An odd-length string leaves the low byte of the last halfword out of the
# comparison, so it is padded with a blank.
textToHalfwords = (text, encoding) ->
  bytes = for ch in String(text)
    code = ch.charCodeAt(0)
    if encoding == 'ebcdic' then (ASCII_TO_EBCDIC[ch] ? 0x40) else (code & 0xff)
  bytes.push(if encoding == 'ebcdic' then 0x40 else 0x20) if bytes.length % 2
  (((bytes[i] << 8) | bytes[i + 1]) for i in [0...bytes.length] by 2)

#
# Logpoints
#
defc 'logpoint',
  summary: 'Record an arrival and carry on, instead of stopping'
  aliases: ['lp']
  params: [
    { name: 'addr', type: 'addr', required: true }
    { name: 'message', type: 'text' }
    { name: 'events', type: 'bool', flag: true, default: false }
  ]
  exec: (s, a) ->
    { logpoint: s.setLogpoint(a.addr, { message: a.message, events: a.events }) }
  render: (r) -> "logpoint at #{locStr(r.logpoint)}"

defc 'lpclear',
  summary: 'Clear a logpoint, or all of them with *'
  params: [{ name: 'addr', type: 'str', required: true }]
  exec: (s, a) ->
    if a.addr == '*'
      return { cleared: s.clearLogpoints(), all: true }
    addr = s.resolveAddr(a.addr)
    throw cmdError('badArgs', "cannot resolve '#{a.addr}'") unless addr?
    throw cmdError('noLogpoint', "no logpoint at #{hex(addr, 5)}") unless s.clearLogpoint(addr)
    { cleared: 1, addr }
  render: (r) ->
    if r.all then "cleared #{r.cleared} logpoints" else "cleared logpoint at #{hex(r.addr, 5)}"

defc 'logpoints',
  summary: 'List logpoints with their hit counts'
  aliases: ['lpl']
  exec: (s) -> { logpoints: s.logpointList() }
  render: (r) ->
    renderList r.logpoints, 'no logpoints', (lp) ->
      "  [#{if lp.enabled then 'ON ' else 'OFF'}] #{locStr(lp)}  #{lp.hits} hits" +
      "#{if lp.message then "  #{lp.message}" else ''}"

#
# Bus traffic
#
defc 'bus',
  summary: 'The busses this GPC is attached to and what has crossed them'
  exec: (s) ->
    iop = s.gpc.iop
    throw cmdError('noIOP', 'no IOP on this machine') unless iop?
    busses = for b in (iop.bce ? []) when b?.mia?.busName?
      mia = b.mia
      {
        bus: mia.busName, nom: mia.busNom ? null, bce: mia.bceNum
        xmitEna: !!mia.xmitEna, recvEna: !!mia.recvEna
        tx: mia.txLog.length, rx: mia.rxLog.length
        rxPending: mia.recvQueue?.length ? 0
        lastTxNs: mia.txLog[mia.txLog.length - 1]?.timeNs ? null
        lastRxNs: mia.rxLog[mia.rxLog.length - 1]?.timeNs ? null
      }
    { busses, monitor: s.busMon.describe() }
  render: (r) ->
    lines = ["  BUS  BCE  XMIT RECV   TX    RX  PEND  LAST"]
    for b in r.busses
      last = Math.max(b.lastTxNs ? 0, b.lastRxNs ? 0)
      lines.push "  #{b.bus.rpad(' ', 4)} #{String(b.bce).lpad(' ', 3)}  " +
                 "#{(if b.xmitEna then ' on' else 'off')}  #{(if b.recvEna then ' on' else 'off')} " +
                 "#{String(b.tx).lpad(' ', 5)} #{String(b.rx).lpad(' ', 5)} " +
                 "#{String(b.rxPending).lpad(' ', 5)}  " +
                 "#{if last then (last / 1e6).toFixed(3) + ' ms' else '-'}"
    m = r.monitor
    lines.push "  monitor #{if m.enabled then 'on' else 'off'}" +
               "#{if m.busses then " (#{m.busses.join(',')})" else ''}" +
               ", #{m.records} records#{if m.dropped then ", #{m.dropped} dropped" else ''}"
    lines.join('\n')

defc 'busmon',
  summary: 'Tap every word crossing the busses'
  params: [
    { name: 'state', type: 'bool' }
    { name: 'bus', type: 'str', flag: true }
    { name: 'limit', type: 'int', flag: true }
    { name: 'events', type: 'bool', flag: true }
  ]
  exec: (s, a) ->
    return s.busMon.describe() unless a.state? or a.bus? or a.limit? or a.events?
    if a.state == false
      return s.busMon.stop()
    s.busMon.start({
      busses: if a.bus? then a.bus.split(/[\s,]+/) else null
      limit: a.limit, events: a.events
    })
  render: (r) ->
    "bus monitor #{if r.enabled then 'on' else 'off'}" +
    "#{if r.busses then " on #{r.busses.join(',')}" else ' on every bus'}" +
    ", ring #{r.records}/#{r.limit}, events #{if r.events then 'on' else 'off'}\n" +
    "  attached: #{r.attached.join(' ')}"

defc 'buslog',
  summary: 'The bus traffic the monitor has collected, as transactions'
  params: [
    { name: 'count', type: 'int', default: 20 }
    { name: 'bus', type: 'str', flag: true }
    { name: 'words', type: 'bool', flag: true, default: false }
    { name: 'clear', type: 'bool', flag: true, default: false }
  ]
  exec: (s, a) ->
    busFilter = a.bus?.toUpperCase() ? null
    out =
      if a.words
        rows = (e for e in s.busMon.ring when not busFilter? or e.bus == busFilter)
        { words: rows.slice(-(a.count ? 20)) }
      else
        { transactions: s.busMon.transactions(a.count ? 20, busFilter) }
    Object.assign(out, { monitor: s.busMon.describe() })
    s.busMon.clear() if a.clear
    out
  render: (r) ->
    if r.words?
      return renderList r.words, 'no bus traffic recorded', (e) ->
        "  #{(e.timeNs / 1e6).toFixed(3).lpad(' ', 12)} ms  #{e.bus.rpad(' ', 4)} " +
        "BCE#{String(e.bce).lpad(' ', 2)} #{e.dir} #{if e.cmd then 'CMD' else '   '} #{hex(e.value)}"
    renderList r.transactions, 'no bus traffic recorded', (t) ->
      cmd = if t.cmd? then "cmd #{hex(t.cmd)}" else "        "
      words = (hex(w) for w in t.words)
      shown = words.slice(0, 12).join(' ')
      more = if words.length > 12 then " ... (#{words.length} words)" else ''
      "  #{(t.timeNs / 1e6).toFixed(3).lpad(' ', 12)} ms  #{t.bus.rpad(' ', 4)} " +
      "BCE#{String(t.bce).lpad(' ', 2)} #{t.dir} #{cmd}  #{shown}#{more}"

#
# Discretes
#
defc 'discretes',
  summary: 'The discrete input and output registers, by named bit'
  aliases: ['disc']
  exec: (s) -> Object.assign(s.discMon.state(), { monitor: s.discMon.describe() })
  render: (r) ->
    return '  (no IOP on this machine)' unless r.registers.length
    lines = []
    for reg in r.registers
      names = (b.name for b in reg.bits)
      lines.push "  #{reg.name.rpad(' ', 8)} #{hex(reg.value, 8)}  " +
                 "#{if names.length then names.join(', ') else '(no bits set)'}"
    lines.join('\n')

defc 'discmon',
  summary: 'Record discrete register changes'
  params: [
    { name: 'state', type: 'bool' }
    { name: 'limit', type: 'int', flag: true }
    { name: 'events', type: 'bool', flag: true }
  ]
  exec: (s, a) ->
    return s.discMon.describe() unless a.state? or a.limit? or a.events?
    return s.discMon.stop() if a.state == false
    s.discMon.start({ limit: a.limit, events: a.events })
  render: (r) ->
    "discrete monitor #{if r.enabled then 'on' else 'off'}, " +
    "ring #{r.records}/#{r.limit}, events #{if r.events then 'on' else 'off'}"

defc 'disclog',
  summary: 'The discrete changes the monitor has collected'
  params: [
    { name: 'count', type: 'int', default: 20 }
    { name: 'clear', type: 'bool', flag: true, default: false }
  ]
  exec: (s, a) ->
    entries = s.discMon.ring.slice(-(a.count ? 20))
    s.discMon.clear() if a.clear
    { entries, monitor: s.discMon.describe() }
  render: (r) ->
    renderList r.entries, 'no discrete changes recorded', (e) ->
      "  #{(e.timeNs / 1e6).toFixed(3).lpad(' ', 12)} ms  #{e.register.rpad(' ', 8)} " +
      "#{hex(e.previous, 8)} -> #{hex(e.value, 8)}  #{e.changed.join(', ')}"

defc 'discset',
  summary: 'Drive a discrete input line, as a box on the bus would'
  params: [
    { name: 'bit', type: 'str', required: true }
    { name: 'state', type: 'bool', default: true }
    { name: 'b', type: 'bool', flag: true, default: false }
  ]
  exec: (s, a) ->
    iop = s.gpc.iop
    throw cmdError('noIOP', 'no IOP on this machine') unless iop?
    reg = if a.b then DISC_REG_B else DISC_REG_A
    try
      bit = resolveDiscrete(reg, a.bit)
    catch e
      throw cmdError('badArgs', e.message)
    iop.setDiscreteInput(reg, bit, a.state)
    s.discMon.sample()
    Object.assign(s.discMon.state(), { set: { register: (if a.b then 'B' else 'A'),
                                              bit, name: discreteName(reg, bit), state: a.state } })
  render: (r) ->
    "discrete input #{r.set.register} #{r.set.name} " +
    "#{if r.set.state then 'set' else 'cleared'}"

#
# Record log
#
defc 'log',
  summary: 'Record what the session publishes to a file, with both clocks'
  params: [
    { name: 'file', type: 'str' }
    { name: 'kinds', type: 'str', flag: true }
    { name: 'format', type: 'str', flag: true, default: 'ndjson' }
    { name: 'append', type: 'bool', flag: true, default: false }
  ]
  exec: (s, a) ->
    return { logs: (l.describe() for l in s.logs) } unless a.file?
    throw cmdError('badArgs', "format: expected 'ndjson' or 'text'") unless a.format in ['ndjson', 'text']
    kinds = if a.kinds? then a.kinds.split(/[\s,]+/).filter((k) -> k.length) else null
    log = s.openLog(a.file, { kinds, format: a.format, append: a.append })
    { logs: (l.describe() for l in s.logs), opened: log.describe() }
  render: (r) ->
    lines = []
    lines.push "recording to #{r.opened.path} (#{r.opened.format})" if r.opened?
    renderList2 = renderList r.logs, 'nothing being recorded', (l) ->
      "  #{l.path}  #{l.format}  #{l.records} records" +
      "#{if l.kinds then "  [#{l.kinds.join(',')}]" else ''}" +
      "#{if l.error then "  ERROR: #{l.error}" else ''}"
    lines.push renderList2
    lines.join('\n')

defc 'logstop',
  summary: 'Close a record log, or all of them'
  params: [{ name: 'file', type: 'str' }]
  exec: (s, a) ->
    closed = s.closeLog(a.file ? null)
    throw cmdError('noLog', 'nothing being recorded') unless closed
    { closed, logs: (l.describe() for l in s.logs) }
  render: (r) -> "closed #{r.closed} log#{if r.closed == 1 then '' else 's'}"

#
# The GUI backend
#
# `gpc gui` runs no machine.  Its panes read a mirror of this session -- a
# real MCM, real register files and a real PSW, refilled from here -- so
# every pane keeps the synchronous accessors it was written against and the
# machine runs in this process at full speed.
#
# One command carries a whole refresh.  A pane's redraw touches registers,
# a few hundred halfwords, the interrupt repertoire and the IOP.
#
# `windows` is the memory the panes touched on their last draw, coalesced
# into ranges by the mirror: what a pane wants to read is known only once
# it has read it, so the mirror asks for what it needed last time and draws
# again when the view has moved.  `access` and `prot` are per-window --
# only the memory pane colours by access recency, and those arrays are as
# long as `values`.
#
# Addresses here are the whole space, through the memory bus: on an
# AP-101B the last 24K words live in the IOP LRU, outside the CPU MCM.
#
GUI_WANT_ALL = ['regs', 'ints', 'intlog', 'iop', 'breakpoints', 'halucp']

# A window is bounded so a mistaken request cannot ask for the whole store
# on every refresh.  A pane showing more than this many halfwords at once
# would not be readable.
GUI_MAX_WINDOW = 4096

guiRegs = (s) ->
  cpu = s.gpc.cpu
  banks = for rf in cpu.regFiles
    {
      values: (rf.r(i).get32() >>> 0 for i in [0..7])
      lastWritten: Array.from(rf.lastWritten)
      dse: rf.dse.slice()
      dseLastWritten: Array.from(rf.dseLastWritten)
    }
  {
    # The step counter every change highlight is measured against.
    step: cpu.mainStorage.step
    regSet: cpu.psw.getRegSet()
    banks: banks
    psw: {
      psw1: cpu.psw.psw1.get32() >>> 0
      psw2: cpu.psw.psw2.get32() >>> 0
      lastWritten1: cpu.psw.lastWritten1
      lastWritten2: cpu.psw.lastWritten2
    }
  }

guiWindow = (s, w) ->
  addr = (w.addr ? 0) & 0x7ffff
  n = Math.max(0, Math.min(GUI_MAX_WINDOW, w.count ? 0))
  out = {
    addr: addr, count: n
    values: (s.ram.get16(addr + i, false) for i in [0...n])
  }
  if w.prot
    out.prot = ((if s.ram.getStoreProtect(addr + i) then 1 else 0) for i in [0...n])
  if w.access
    out.lastRead = (s.ram.getLastRead(addr + i) for i in [0...n])
    out.lastWritten = (s.ram.getLastWritten(addr + i) for i in [0...n])
    out.protLastWritten = (s.ram.getProtLastWritten(addr + i) for i in [0...n])
  out

defc 'guisnap',
  summary: 'One refresh of everything a GUI pane reads'
  params: [
    { name: 'windows', type: 'json', flag: true }
    { name: 'want', type: 'json', flag: true }
    { name: 'iopdisasm', type: 'json', flag: true }
    { name: 'intlogcount', type: 'int', flag: true, default: 40 }
  ]
  exec: (s, a) ->
    want = a.want ? GUI_WANT_ALL
    has = (k) -> want.indexOf(k) >= 0
    iop = s.gpc.iop
    out = {
      status: s.stopBody()
      running: !!s.running
      steps: s.stepCount
      simTimeSec: s.simTimeSec()
      speedRatio: s.speedRatio ? null
      realTime: !!s.realTime
      rtFactor: s.rtFactor
      idling: !!s.idling
      statusNote: s.statusNote ? null
      totalHW: s.ram.totalHWCount ? 0x80000
      memory: (guiWindow(s, w) for w in (a.windows ? []))
    }
    out.regs = guiRegs(s) if has('regs')
    out.ints = COMMANDS.ints.exec(s) if has('ints')
    out.intlog = COMMANDS.intlog.exec(s, { count: a.intlogcount ? 40 }) if has('intlog')
    out.iop = COMMANDS.iop.exec(s, { active: false }) if has('iop') and iop?
    if a.iopdisasm? and iop?
      wanted = if Array.isArray(a.iopdisasm) then a.iopdisasm else [a.iopdisasm]
      out.iopdisasm = for w in wanted when 0 <= w.proc <= 24
        COMMANDS.iopdisasm.exec(s, { proc: w.proc, count: w.count ? 8, addr: null })
    out.breakpoints = s.breakpointList() if has('breakpoints')
    if has('halucp')
      out.halucp = {
        active: !!s.halUCP.active
        waitingForInput: !!s.halUCP.waitingForInput
        trapAddrs: s.halUCP.trapAddrs ? null
      }
    out
  render: (r) ->
    hw = (w.count for w in r.memory).reduce(((a, b) -> a + b), 0)
    "guisnap: #{r.memory.length} window#{if r.memory.length == 1 then '' else 's'}" +
    " (#{hw} halfwords), #{r.steps} steps, " +
    "#{if r.running then 'running' else r.status.reason}"

defc 'sysreset',
  summary: 'System reset: PSW from the PSA, as the panel switch does'
  exec: (s) ->
    s.systemReset()
    s.stopReason = 'entry'
    s.stopDescription = s.statusNote ? null
    body = s.stopBody()
    s.emit('stopped', body)
    body
  render: renderStop
