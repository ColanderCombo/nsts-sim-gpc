# FCOS process and queue state decoded from CVT symbols and map layouts.

import {ProgramStatusWord} from 'gpc/regmem'

# Process Control Table entry, 0x32 halfwords.
export PCT =
  NXT:  0x00        # next PCT in the priority queue
  PRI:  0x01        # priority level
  STOR: 0x02        # storage area
  PDE:  0x03        # the process directory entry this runs
  PSW:  0x04        # 4 halfwords, the PSW at the last interrupt
  GPR:  0x08        # 8 fullwords
  FPR:  0x18        # 8 fullwords
  RPTH: 0x28        # repeat delta time, microseconds within a half hour
  DSE:  0x2a
  OPRI: 0x2c        # priority before promotion
  ERR:  0x2d        # group and code of the last error
  ECNT: 0x2e        # cyclic display overrun count
  FLGS: 0x2f
  WAIT: 0x30
  IOPP: 0x31
  LEN:  0x32

# Process Directory Entry, 6 halfwords.
export PDE =
  EVENT: 0          # the process event variable
  PCT:   1          # the PCT scheduled for it, or zero
  ENTRY: 2          # 2 halfwords: a ZCON of the entry point
  STAK:  4          # stack address, or its size when FLGS bit 15 is clear
  FLGS:  5
  LEN:   6

# Timer Queue Element, 6 halfwords.
export TQE =
  NXT:  0
  PCT:  1
  TOXH: 2           # 2 halfwords: microseconds into the half hour
  TOXM: 4           # half hours
  FLGS: 5
  LEN:  6

# Event Queue Element, 0xa halfwords.
export EQE =
  NXT:  0
  PCT:  1
  OPS:  2           # 2 halfwords: operator count and the operator field
  VAR:  4           # 5 halfwords: the event variables
  TYPE: 9
  LEN:  0xa

# TPCTWAIT, the reason a process is not dispatchable.  Zero is ready.
WAIT_BITS = [
  [0x01, 'schedule']
  [0x02, 'delta time']
  [0x04, 'event']
  [0x08, 'I/O']
  [0x10, 'until time']
  [0x40, 'OPS cancel']
]

# TPCTFLGS.
FLAG_BITS = [
  [0x0001, 'task']
  [0x0002, 'no dispatch']
  [0x0010, 'SSIP']
  [0x0020, 'OPS cancelled']
  [0x0400, 'cycle overrun']
  [0x0800, 'terminated']
  [0x1000, 'EQE initiation']
  [0x2000, 'EQE cancellation']
  [0x4000, 'FCOS']
]
FLAG_LIVE = 0x8000
FLAG_TERMINATED = 0x0800
INITIAL = { 0x0: null, 0x4: 'AT', 0x8: 'IN', 0xc: 'ON' }
REPEAT = { 0x00: null, 0x80: 'REPEAT EVERY' }
CANCEL = { 0x000: null, 0x100: 'UNTIL TIME', 0x200: 'WHILE EVENT',
           0x300: 'UNTIL EVENT' }

# TTQEFLGS low nibble.
TQE_TYPE = {
  0x1: 'SSIP', 0x2: 'WAIT', 0x3: 'WAIT UNTIL', 0x4: 'SCHEDULE AT'
  0x5: 'SCHEDULE IN', 0x6: 'SCHEDULE UNTIL', 0x7: 'REPEAT AFTER'
  0x8: 'REPEAT EVERY', 0x9: 'I/O', 0xa: 'runtime update'
  0xb: 'MET update', 0xc: 'init GMT request', 0xd: 'I/O delay'
}

# TEQETYPE.
EQE_TYPE = [[0x8000, 'ON'], [0x4000, 'WHILE'], [0x2000, 'UNTIL'],
            [0x1000, 'null']]

MAX_CHAIN = 512

MEM_HW = 0x80000

FILL = [0xc9fb, 0xc6c6]

export class FcosView
  constructor: (@session) ->

  cvt: () ->
    out = {}
    for name in ['TCVTPCT', 'TCVTOLD', 'TCVTNEW', 'TCVTTTQE', 'TCVTPCTP',
                 'TCVTTQEP', 'TCVTEQEP', 'TCVTTEQE', 'TCVTSTOR', 'TCVTIOA',
                 'TCVTIOW']
      a = @session.syms.addressOf(name)
      out[name] = if a? then { addr: a, value: @hw(a) } else null
    return null unless out.TCVTPCT?
    out

  hw: (a) -> @session.readHw(a)
  fw: (a) -> ((@hw(a) << 16) | @hw(a + 1)) >>> 0


  _walk: (head, nextOff, limit = MAX_CHAIN) ->
    out = []
    seen = new Set()
    a = head
    while a? and a != 0 and a < MEM_HW and out.length < limit
      break if seen.has(a)
      seen.add(a)
      out.push(a)
      a = @hw(a + nextOff)
    { addrs: out, truncated: out.length >= limit, looped: seen.has(a ? 0) and a != 0 }

  runQueue: () ->
    c = @cvt()
    return null unless c?
    chain = @_walk(c.TCVTPCT.value, PCT.NXT)
    active = c.TCVTOLD?.value ? 0
    next = c.TCVTNEW?.value ? 0
    rows = for a in chain.addrs
      row = @pct(a)
      row.active = a == active
      row.next = a == next
      row
    { head: c.TCVTPCT.value, active, next, pcts: rows,
      truncated: chain.truncated }

  pct: (a) ->
    flags = @hw(a + PCT.FLGS)
    wait = @hw(a + PCT.WAIT)
    pdeAddr = @hw(a + PCT.PDE)
    idle = pdeAddr == 0
    psw = new ProgramStatusWord()
    psw.psw1.set32(@fw(a + PCT.PSW))
    psw.psw2.set32(@fw(a + PCT.PSW + 2))
    {
      addr: a
      priority: @hw(a + PCT.PRI)
      originalPriority: @hw(a + PCT.OPRI)
      pde: pdeAddr
      idle: idle
      process: if idle then 'FCOS idle' else @processName(pdeAddr)
      storage: @hw(a + PCT.STOR)
      psw: [psw.psw1.get32() >>> 0, psw.psw2.get32() >>> 0]
      nia: psw.getNIA()
      error: @hw(a + PCT.ERR)
      overruns: @hw(a + PCT.ECNT)
      flags: flags
      flagText: flagText(flags)
      wait: wait
      waitText: waitText(wait)
      state:
        if idle then 'idle'
        else if flags & FLAG_TERMINATED then 'terminated'
        else if not (flags & FLAG_LIVE) then 'cancelled'
        else if wait == 0 then 'ready'
        else 'waiting'
    }

  timeQueue: () ->
    c = @cvt()
    return null unless c?
    chain = @_walk(c.TCVTTTQE?.value ? 0, TQE.NXT)
    rows = for a in chain.addrs
      f = @hw(a + TQE.FLGS)
      pctAddr = @hw(a + TQE.PCT)
      {
        addr: a, pct: pctAddr
        process: if pctAddr then @processName(@hw(pctAddr + PCT.PDE)) else null
        toxh: @fw(a + TQE.TOXH), toxm: @hw(a + TQE.TOXM)
        micros: @hw(a + TQE.TOXM) * @halfHourUs() + @fw(a + TQE.TOXH)
        flags: f
        type: if @hw(a + TQE.TOXM) == 0x7fff then 'end of queue' \
              else TQE_TYPE[f & 0xf] ? "type #{f & 0xf}"
        sentinel: @hw(a + TQE.TOXM) == 0x7fff
        initial: !!(f & 0x2000)
      }
    { head: c.TCVTTTQE?.value ? 0, tqes: rows, truncated: chain.truncated }

  eventQueue: (live = null) ->
    c = @cvt()
    return null unless c?
    live ?= new Set(p.addr for p in (@runQueue()?.pcts ? []))
    base = c.TCVTTEQE?.value ? 0
    free = new Set()
    if c.TCVTEQEP?
      free.add(a) for a in @_walk(c.TCVTEQEP.value, EQE.NXT).addrs
    slots = Math.min(free.size + live.size + 8, 256)
    addrs = []
    for i in [0...slots]
      a = base + i * EQE.LEN
      break if a >= MEM_HW
      continue if free.has(a)
      addrs.push(a) if live.has(@hw(a + EQE.PCT))
    chain = { addrs, truncated: false }
    rows = for a in chain.addrs
      t = @hw(a + EQE.TYPE)
      pctAddr = @hw(a + EQE.PCT)
      vars = []
      for i in [0...5]
        v = @hw(a + EQE.VAR + i)
        continue unless v
        vars.push({ addr: v, value: @hw(v), name: @session.labelAt(v) })
      {
        addr: a, pct: pctAddr
        process: if pctAddr then @processName(@hw(pctAddr + PCT.PDE)) else null
        ops: @fw(a + EQE.OPS)
        type: t
        typeText: (n for [b, n] in EQE_TYPE when t & b).join(' ') or 'WAIT'
        vars: vars
      }
    { pool: base, free: free.size, eqes: rows, truncated: chain.truncated }

  pools: () ->
    c = @cvt()
    return null unless c?
    out = []
    for [name, field, nxt] in [['PCT', 'TCVTPCTP', PCT.NXT],
                               ['TQE', 'TCVTTQEP', TQE.NXT],
                               ['EQE', 'TCVTEQEP', EQE.NXT]]
      continue unless c[field]?
      chain = @_walk(c[field].value, nxt)
      out.push({ pool: name, head: c[field].value, free: chain.addrs.length,
                 truncated: chain.truncated })
    out

  directory: () ->
    rows = []
    for s in @session.syms.sections() when s.name.slice(0, 2) == '#E'
      rows.push(@pde(s.addr, s.name))
    rows.sort (a, b) -> (a.name ? '').localeCompare(b.name ? '')

  pde: (a, csect = null) ->
    csect ?= @session.sectionOf(a)
    flags = @hw(a + PDE.FLGS)
    stak = @hw(a + PDE.STAK)
    resident = true
    for fill in FILL
      allFill = true
      for i in [0...PDE.LEN]
        allFill = false unless @hw(a + i) == fill
      resident = false if allFill
    {
      resident: resident
      addr: a, csect: csect
      stem: if csect?.slice(0, 2) == '#E' then csect.slice(2) else null
      name: @processName(a)
      event: @hw(a + PDE.EVENT)
      eventLabel: @session.labelAt(@hw(a + PDE.EVENT))
      pct: @hw(a + PDE.PCT)
      entry: @zcon(a + PDE.ENTRY)
      stack: if flags & 0x8000 then stak else null
      stackSize: if flags & 0x8000 then null else stak
      flags: flags
      scheduled: @hw(a + PDE.PCT) != 0
    }

  zcon: (a) ->
    hw0 = @hw(a)
    hw1 = @hw(a + 1)
    bsr = (hw1 >> 4) & 0xf
    addr = if hw0 & 0x8000 then ((bsr << 15) | (hw0 & 0x7fff)) else hw0
    { addr, bsr, dsr: hw1 & 0xf, label: @session.labelAt(addr) }

  processName: (pdeAddr) ->
    return null unless pdeAddr
    csect = @session.sectionOf(pdeAddr)
    return null unless csect?
    return csect unless csect.slice(0, 2) == '#E'
    stem = csect.slice(2)
    i = @session.sdl?.unitByStem?.get(stem.toUpperCase())
    (if i? then @session.sdl?.unitName(i) else null) ? stem

  halfHourUs: () ->
    a = @session.syms.addressOf('FPM30MIN')
    if a? then @fw(a) else 1800000000

  processes: () ->
    dir = @directory()
    run = @runQueue()
    return null unless run?
    byPct = {}
    byPct[p.addr] = p for p in run.pcts
    tq = @timeQueue()
    eq = @eventQueue(new Set(p.addr for p in run.pcts))
    for t in (tq?.tqes ? [])
      (byPct[t.pct]?.tqes ?= []).push(t) if byPct[t.pct]?
    for e in (eq?.eqes ? [])
      (byPct[e.pct]?.eqes ?= []).push(e) if byPct[e.pct]?
    rows = for p in dir
      row = byPct[p.pct] ? null
      Object.assign({}, p, {
        pctRow: row
        scheduled: row?
        state:
          if row? then row.state
          else if not p.resident then 'not resident'
          else if p.pct then 'stale PCT'
          else 'unscheduled'
      })
    entries = new Set()
    entries.add(p.addr) for p in dir
    orphans = (p for p in run.pcts when not p.idle and not entries.has(p.pde))
    { processes: rows, run, timeQueue: tq, eventQueue: eq, orphans,
      pools: @pools() }

export flagText = (f) ->
  out = (n for [b, n] in FLAG_BITS when f & b)
  out.push(INITIAL[f & 0x000c]) if INITIAL[f & 0x000c]?
  out.push(REPEAT[f & 0x00c0]) if REPEAT[f & 0x00c0]?
  out.push(CANCEL[f & 0x0300]) if CANCEL[f & 0x0300]?
  out.join(' ')

export waitText = (w) ->
  return 'ready' if w == 0
  out = (n for [b, n] in WAIT_BITS when w & b)
  out.join('+') or "wait #{w.toString(16)}"

export {WAIT_BITS, FLAG_BITS, TQE_TYPE, MAX_CHAIN}
