import {defc, cmdError} from './registry'
import {hex} from './render'
import {FcosView} from 'gpc/dbg/fcos/fcos'

needFcos = (s) ->
  view = new FcosView(s)
  throw cmdError('noFcos', 'no FCOS in this image: TCVTPCT is not a symbol ' +
    '(load the configuration\'s symbols, or `symauto --adopt`)') unless view.cvt()?
  view

procRow = (p) ->
  {
    name: p.name ? p.csect, csect: p.csect, pde: p.addr
    scheduled: p.scheduled, pct: if p.scheduled then p.pct else 0
    state: p.state ? 'unscheduled'
    priority: p.pctRow?.priority ? null
    wait: p.pctRow?.waitText ? null
    flags: p.pctRow?.flagText ? null
    nia: p.pctRow?.nia ? null
    entry: p.entry.addr, event: p.event, pctClaimed: p.pct
    eventLabel: p.eventLabel
    overruns: p.pctRow?.overruns ? null
    error: p.pctRow?.error ? null
    tqes: p.pctRow?.tqes ? []
    eqes: p.pctRow?.eqes ? []
  }

renderTasks = (r) ->
  lines = []
  if r.one?
    return renderTaskDetail(r.one)
  lines.push "  active #{r.activeName ? '(none)'}" +
    "#{if r.active then " PCT #{hex(r.active, 5)}" else ''}" +
    "#{if r.next and r.next != r.active then ", next #{hex(r.next, 5)}" else ''}"
  lines.push "  #{r.counts.scheduled} scheduled, #{r.counts.unscheduled} unscheduled" +
    "#{if r.counts.orphans then ", #{r.counts.orphans} PCT(s) with no directory entry" else ''}"
  lines.push "  free pools: " + ((("#{p.pool} #{p.free}") for p in r.pools).join('  '))
  lines.push ''
  lines.push "  #{'PCT'.rpad(' ', 6)} #{'PRI'.rpad(' ', 4)} #{'STATE'.rpad(' ', 13)} " +
    "#{'PROCESS'.rpad(' ', 26)} WAITING ON"
  for p in r.rows
    mark = if p.pct and p.pct == r.active then '*' else ' '
    lines.push "#{mark} #{(if p.pct then hex(p.pct, 5) else '     ').rpad(' ', 6)} " +
      "#{(if p.priority? then String(p.priority) else '').rpad(' ', 4)} " +
      "#{p.state.rpad(' ', 13)} #{p.name.rpad(' ', 26)}#{whyText(p)}".trimEnd()
  lines.join('\n')

whyText = (p) ->
  return '' unless p.wait? and p.wait != 'ready'
  bits = [p.wait]
  for t in (p.tqes ? [])
    bits.push "#{t.type} at #{usText(t.micros)}"
  for e in (p.eqes ? [])
    bits.push "#{e.typeText} #{(evText(v) for v in e.vars).join(',')}"
  bits.join('; ')

usText = (us) ->
  s = Math.floor(us / 1e6)
  frac = us - s * 1e6
  d = Math.floor(s / 86400)
  h = Math.floor(s / 3600) % 24
  m = Math.floor(s / 60) % 60
  "#{String(d).padStart(3, '0')}:#{String(h).padStart(2, '0')}:" +
  "#{String(m).padStart(2, '0')}:#{String(s % 60).padStart(2, '0')}." +
  "#{String(Math.round(frac)).padStart(6, '0')}"

evText = (v) -> "#{v.name ? hex(v.addr, 5)}=#{hex(v.value, 4)}"

renderTaskDetail = (p) ->
  lines = [
    "  #{p.name}"
    "    PDE      #{hex(p.pde, 5)} #{p.csect}"
    "    entry    #{hex(p.entry, 5)}"
    "    event    #{hex(p.event, 4)}#{if p.eventLabel then " #{p.eventLabel}" else ''}"
  ]
  if not p.scheduled
    lines.push "    #{p.state}" + (
      if p.state == 'stale PCT'
        ": the entry names #{hex(p.pctClaimed, 5)}, which is not on the run queue"
      else if p.state == 'not resident'
        ': the entry reads the IPL background fill'
      else ': no PCT')
    return lines.join('\n')
  lines.push "    PCT      #{hex(p.pct, 5)}  priority #{p.priority}  #{p.state}"
  lines.push "    NIA      #{hex(p.nia, 5)}"
  lines.push "    wait     #{p.wait}"
  lines.push "    flags    #{p.flags}" if p.flags
  lines.push "    overruns #{p.overruns}" if p.overruns
  lines.push "    error    #{hex(p.error, 4)}" if p.error
  for t in p.tqes
    lines.push "    timer    #{hex(t.addr, 5)} #{t.type} at #{usText(t.micros)}" +
      "#{if t.initial then ' (initial)' else ''}"
  for e in p.eqes
    lines.push "    event    #{hex(e.addr, 5)} #{e.typeText}"
    for v in e.vars
      lines.push "      #{hex(v.addr, 5)} #{(v.name ? '').rpad(' ', 20)} " +
        "= #{hex(v.value, 4)}"
  lines.join('\n')

defc 'tasks',
  summary: 'FCOS processes: what is scheduled, what it is waiting for, what is not'
  aliases: ['procs', 'ps']
  params: [
    { name: 'name', type: 'str' }
    { name: 'all', type: 'bool', flag: true, default: false }
  ]
  exec: (s, a) ->
    view = needFcos(s)
    st = view.processes()
    rows = (procRow(p) for p in st.processes)
    for p in st.run.pcts when p.idle
      st.orphans.push(p)
    for p in st.orphans
      rows.push({
        name: p.process ? "PCT #{hex(p.addr, 5)}", csect: null, pde: p.pde
        idle: !!p.idle
        scheduled: true, pct: p.addr, state: p.state, priority: p.priority
        wait: p.waitText, flags: p.flagText, nia: p.nia
        entry: null, event: null, eventValue: null
        overruns: p.overruns, error: p.error
        tqes: p.tqes ? [], eqes: p.eqes ? []
      })
    if a.name?
      want = a.name.toUpperCase()
      hit = (r for r in rows when r.name.toUpperCase() == want or
             r.csect?.toUpperCase() == want or
             r.csect?.slice(2).toUpperCase() == want)[0]
      throw cmdError('noProcess', "no process named #{a.name}") unless hit?
      return { one: hit }
    shown = if a.all then rows else (r for r in rows when r.scheduled)
    shown.sort (x, y) ->
      (y.priority ? -1) - (x.priority ? -1) or x.name.localeCompare(y.name)
    {
      active: st.run.active, next: st.run.next
      activeName: (r.name for r in rows when r.pct == st.run.active)[0] ? null
      counts: {
        scheduled: (r for r in rows when r.scheduled).length
        unscheduled: (r for r in rows when not r.scheduled).length
        orphans: (p for p in st.orphans when not p.idle).length
      }
      pools: st.pools, rows: shown, all: a.all
    }
  render: renderTasks

defc 'queues',
  summary: 'The FCOS run, timer and event queues as they are chained'
  exec: (s) ->
    view = needFcos(s)
    { run: view.runQueue(), time: view.timeQueue(), event: view.eventQueue(),
      pools: view.pools() }
  render: (r) ->
    lines = ["  run queue, head #{hex(r.run.head, 5)}"]
    for p in r.run.pcts
      lines.push "    #{hex(p.addr, 5)} pri #{String(p.priority).rpad(' ', 4)} " +
        "#{p.state.rpad(' ', 13)} #{(p.process ? '').rpad(' ', 26)} #{p.flagText}".trimEnd()
    lines.push '    (empty)' unless r.run.pcts.length
    lines.push "  timer queue, head #{hex(r.time.head, 5)}"
    for t in r.time.tqes
      lines.push "    #{hex(t.addr, 5)} #{t.type.rpad(' ', 16)} " +
        "#{if t.sentinel then '' else "at #{usText(t.micros)}"}  #{t.process ? ''}".trimEnd()
    lines.push '    (empty)' unless r.time.tqes.length
    lines.push "  event waits, EQE pool at #{hex(r.event.pool, 5)}, " +
      "#{r.event.free} free"
    for e in r.event.eqes
      lines.push "    #{hex(e.addr, 5)} #{e.typeText.rpad(' ', 16)} " +
        "#{(evText(v) for v in e.vars).join(', ')}" +
        "  #{e.process ? ''}"
    lines.push '    (none)' unless r.event.eqes.length
    lines.push "  free pools: " + ((("#{p.pool} #{p.free}") for p in r.pools).join('  '))
    lines.join('\n')
