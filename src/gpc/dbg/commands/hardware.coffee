import {defc, cmdError} from './registry'
import {hex, locStr, renderList, durationStr} from './render'
import {shmStats} from 'com/bus'
{status: schedStatus} = require '../../../native/rtpolicy.coffee'

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
      lag: s.pacer?.lagReport?()
      chunks: s.chunks ? 0, hotChunks: s.hotChunks ? 0, spinTurns: s.spinTurns ? 0
      ioTurns: s.gpc.cpu.ioTurns ? 0
      sched: schedStatus()
      shm: shmStats()
      barrier: s.gpc.iop?.barrier?.report?() ? null
      barrierTurns: s.barrierTurns ? 0
    }
  render: (r) ->
    line = "real-time #{if r.enabled then 'on' else 'off'} at #{r.factor}x, " +
      "idle timeout #{r.idleTimeoutSec}s, sim time #{r.simTimeSec.toFixed(6)}s"
    if r.lag?
      l = r.lag
      rate = if l.rate? then ", #{l.rate.toFixed(3)} of the wall's rate over #{(l.sinceMs / 1000).toFixed(1)} s" else ''
      line += "\n  behind the wall #{l.behindNowMs.toFixed(2)} ms now, " +
        "#{l.behindMaxMs.toFixed(2)} ms at most since the last report; " +
        "#{l.lagsGivenUp} lag(s) given up, #{l.lagGivenUpMs.toFixed(1)} ms; " +
        "#{l.stalls} stall(s), #{l.stallMs} ms#{rate}" +
        "\n  #{r.chunks} chunks, #{r.hotChunks} ended for a turn, " +
        "#{r.spinTurns} spin turns, #{r.ioTurns} turns of the event loop"
    if (sc = r.sched)?
      state = 'unavailable'
      state = (if sc.set then "at priority #{sc.curPri}" else "refused, priority #{sc.curPri}") if sc.available
      line += "\n  sched #{sc.policy ? 'off'} #{state}"
      line += ", demoted out of the realtime band" if sc.demoted
    if (sh = r.shm)?
      line += "\n  shm #{sh.rings} ring(s), #{sh.sent} sent, #{sh.received} received, " +
        "#{sh.drops} lapped, #{sh.oversize} too long"
    if (b = r.barrier)?
      line += "\n  barrier #{b.deltaUs} us, held #{b.holds} time(s) for " +
        "#{b.heldMs.toFixed(1)} ms over #{r.barrierTurns} turn(s)"
      for p in b.peers when not p.self
        line += "\n    GPC #{p.who} pid #{p.pid} #{(p.aheadUs / 1000).toFixed(3)} ms " +
          "ahead, published #{(p.ageUs / 1000).toFixed(1)} ms ago"
    line
