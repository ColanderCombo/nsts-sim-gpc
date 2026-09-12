import {defc, COMMANDS, lookupCommand, cmdError, PROTOCOL_VERSION} from './registry'
import {hex, locStr, renderLocationLine, renderStop, renderWatchRow, renderList} from './render'

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
