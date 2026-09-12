import {defc, cmdError} from './registry'
import {hex, locStr, renderList} from './render'
import {discreteName, resolveDiscrete,
        REG_A as DISC_REG_A, REG_B as DISC_REG_B} from 'com/discretes'

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

defc 'bus',
  summary: 'The busses this GPC is attached to and what has crossed them'
  exec: (s) ->
    iop = s.gpc.iop
    throw cmdError('noIOP', 'no IOP on this machine') unless iop?
    nowNs = iop.cpu?.timeNs ? 0
    busses = for b in (iop.bce ? []) when b?.mia?.busName?
      mia = b.mia
      st = b.recv
      {
        bus: mia.busName, nom: mia.busNom ? null, bce: mia.bceNum
        xmitEna: iop.procGet(iop.regXmitEna, mia.bceNum) == 1
        recvEna: iop.procGet(iop.regRecvEna, mia.bceNum) == 1
        tx: mia.txLog.length, rx: mia.rxLog.length
        rxPending: mia.recvQueue?.length ? 0
        lastTxNs: mia.txLog[mia.txLog.length - 1]?.timeNs ? null
        lastRxNs: mia.rxLog[mia.rxLog.length - 1]?.timeNs ? null
        recvLeft: st?.left ? null
        recvGotAny: !!st?.gotAny
        recvForMs: if st? then (nowNs - (st.beganNs ? st.sinceNs)) / 1e6 else null
        dueInUs: if st? then mia.dueInUs() else null
      }
    { busses, monitor: s.busMon.describe() }
  render: (r) ->
    lines = ["  BUS  BCE  XMIT RECV   TX    RX  PEND  LAST            RECEIVE"]
    for b in r.busses
      last = Math.max(b.lastTxNs ? 0, b.lastRxNs ? 0)
      recv =
        if b.recvLeft?
          "#{b.recvLeft} left#{if b.recvGotAny then '' else ', none taken'}, " +
          "#{b.recvForMs.toFixed(3)} ms, due #{b.dueInUs} us"
        else ''
      lines.push "  #{b.bus.rpad(' ', 4)} #{String(b.bce).lpad(' ', 3)}  " +
                 "#{(if b.xmitEna then ' on' else 'off')}  #{(if b.recvEna then ' on' else 'off')} " +
                 "#{String(b.tx).lpad(' ', 5)} #{String(b.rx).lpad(' ', 5)} " +
                 "#{String(b.rxPending).lpad(' ', 5)}  " +
                 "#{(if last then (last / 1e6).toFixed(3) + ' ms' else '-').rpad(' ', 14)}#{recv}"
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

defc 'discretes',
  summary: 'The discrete input and output registers, by named bit'
  aliases: ['disc']
  exec: (s) -> Object.assign(s.discMon.state(),
                            { monitor: s.discMon.describe()
                              links: s.gpc?.iop?.gpcLinks?.heard() ? [] })
  render: (r) ->
    return '  (no IOP on this machine)' unless r.registers.length
    lines = []
    for reg in r.registers
      names = (b.name for b in reg.bits)
      lines.push "  #{reg.name.rpad(' ', 8)} #{hex(reg.value, 8)}  " +
                 "#{if names.length then names.join(', ') else '(no bits set)'}"
    if r.sync?
      lines.push "  sync out #{r.sync.out}" if r.sync.out?
      lines.push "  sync in  #{r.sync.partners}" if r.sync.partners?
    for link in (r.links ? []) when link.cross? or not link.lost
      c = link.cross
      h = link.held
      lines.push "  GPC #{link.gpc} out #{hex(link.out, 8)}" +
                 (if link.lost then '  lost' else '') +
                 (if c? then "  crossed #{c.n} in #{c.mean}/#{c.max} us mean/max" else '') +
                 (if h? and h.max > 0 then ", held #{h.mean}/#{h.max} us" else '')
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
