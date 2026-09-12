# GUIMirror: the session's state, answering the panes' accessors
#
# A pane reads a live `cpu` synchronously inside a redraw --
# `cpu.mainStorage.get16(a, false)`, `cpu.regFiles[1].r(3).get32()`,
# `cpu.psw.getNIA()`.  The mirror answers with real `MCM`, `RegisterFile`
# and `ProgramStatusWord` objects refilled from a `guisnap` reply, so
# getAccessColor, getProtColor, getLastWritten, the PSW's field unpacking
# and the DSE tracking are not reimplemented.  Interrupt, timer and IOP
# state come from the snapshot's JSON.
#
# A pane cannot say what memory it wants until it has read it, so the mirror
# records the addresses each redraw touched, coalesces them into ranges, and
# asks for those next time; `stale()` is true when the last draw read past
# what the snapshot carried.
#
# A register edited in a pane goes into the mirror's objects and out to the
# session as a `setreg`.  The next snapshot replaces it.

require 'com/util'
import {MCM} from 'gpc/mcm'
import {RegisterFile, ProgramStatusWord} from 'gpc/regmem'

# Two reads closer than this are fetched as one window: a window costs an
# address and a count, a halfword one number.
COALESCE_GAP = 32

# Ceilings on one refresh: MAX_WINDOW per window, MAX_TOTAL over all of
# them.  The watch pane is the greediest, reading one to four halfwords of
# every symbol in the table -- a flight image of 5 000 to 6 000 symbols
# coalesces to about 150 windows and 28 000 halfwords, some 165 KB of JSON a
# refresh.  `truncated` says when something was dropped.
MAX_WINDOW = 4096
MAX_TOTAL = 65536

# Coalesce a set of addresses into { addr, count } ranges.  The result
# carries `.truncated`: the halfwords that did not fit under `maxTotal`.
export coalesce = (addrs, gap = COALESCE_GAP, maxWindow = MAX_WINDOW,
                   maxTotal = MAX_TOTAL) ->
  list = Array.from(addrs).sort (a, b) -> a - b
  out = []
  total = 0
  dropped = 0
  cur = null
  # Emit `cur` as one window.  A run longer than `maxWindow` is split, not
  # cut short: only what will not fit under `maxTotal` is dropped.
  push = () ->
    return unless cur?
    while cur?
      want = cur.end - cur.start + 1
      room = Math.max(0, maxTotal - total)
      n = Math.min(maxWindow, want, room)
      if n <= 0
        dropped += want
        break
      out.push({ addr: cur.start, count: n })
      total += n
      break if n >= want
      cur = { start: cur.start + n, end: cur.end }
    cur = null
  for a in list
    if cur? and a - cur.end <= gap
      cur.end = a
    else
      push()
      cur = { start: a, end: a }
  push()
  out.truncated = dropped
  out

# Main storage, with the reads recorded
#
# `trackAccess` is off: the access-recency arrays are the session's, written
# here from the snapshot, and a pane reading a cell must not look like the
# machine having read it.
class MirrorMemory extends MCM
  constructor: (wordCount, @owner) ->
    super(wordCount)
    @trackAccess = false

  get16: (addr, trackRead = true) ->
    @owner._touchRead(addr)
    super(addr & 0x7ffff, false)

  getStoreProtect: (addr) ->
    @owner._touchMeta(addr)
    super(addr)

  getAccessColor: (addr, fadeCycles = 4) ->
    @owner._touchMeta(addr)
    super(addr, fadeCycles)

  getProtColor: (addr, isSet, fadeCycles = 4) ->
    @owner._touchMeta(addr)
    super(addr, isSet, fadeCycles)

  # Fill one window from a snapshot, arrays and all.
  applyWindow: (w) ->
    base = w.addr
    for v, i in w.values
      @set16(base + i, v & 0xffff, false, false)
    if w.prot?
      @protData[(base + i) & 0x7ffff] = !!p for p, i in w.prot
    if w.lastRead?
      @lastRead[(base + i) & 0x7ffff] = v for v, i in w.lastRead
    if w.lastWritten?
      @lastWritten[(base + i) & 0x7ffff] = v for v, i in w.lastWritten
    if w.protLastWritten?
      @protLastWritten[(base + i) & 0x7ffff] = v for v, i in w.protLastWritten
    return

# The IOP pane's state, answered from the `iop` command's payload.
class MirrorIOP
  constructor: (@owner) ->
    @ls = { slice: 0, curPage: 0 }
    @dmaQueue = { length: 0 }
    @dmaBurst = false
    @wdCount = 0
    @wdRunning = false
    @wdTimeout = false
    @_group1 = []
    @_registers = []
    @_processors = []
    @_disasm = {}          # proc -> rows

  apply: (r) ->
    return unless r?
    @ls = { slice: r.slice ? 0, curPage: r.currentPage ? 0 }
    @dmaQueue = { length: r.dmaQueue ? 0 }
    @dmaBurst = !!r.dmaBurst
    @wdCount = r.watchdog?.count ? 0
    @wdRunning = !!r.watchdog?.running
    @wdTimeout = !!r.watchdog?.timedOut
    @_group1 = r.group1 ? []
    @_registers = r.registers ? []
    @_processors = r.processors ? []
    return

  applyDisasm: (list) ->
    return unless list?
    @_disasm[d.proc] = d.rows ? [] for d in list
    return

  group1Sources: () -> @_group1
  globalRegs: () -> @_registers
  procStates: () -> @_processors

  # An unfolded processor's disassembly.  The rows come from the snapshot,
  # so the first draw after a processor is opened has none and the request
  # goes out with the next refresh: a frame's lag.
  procDisasm: (proc, count = 8) ->
    @owner._wantDisasm(proc, count)
    @_disasm[proc] ? []

# The CPU as the panes read it: real registers and real memory, with the
# interrupt and timer state answered from the snapshot.
class MirrorCPU
  constructor: (@owner, wordCount) ->
    @mainStorage = new MirrorMemory(wordCount, @owner)
    @ram = @mainStorage
    @regFiles = [
      new RegisterFile("r0", 8, 32)
      new RegisterFile("r1", 8, 32)
      new RegisterFile("f1", 8, 32)
    ]
    @psw = new ProgramStatusWord()
    @intLog = []
    @intCount = 0
    @intHold = false
    @_ints = null
    @_timers = {}
    @_codeLabels = {}

  r: (x) -> @regFiles[@psw.getRegSet()].r(x)

  intStatus: () -> @_ints?.interrupts ? []
  heldInterrupt: () -> @_ints?.held ? null
  timerValue: (n) -> @_timers[n]?.value ? 0
  timerRemainingUs: (n) -> @_timers[n]?.remainingUs ? 0

  # The PSA halfword the interval timer's high half lives in.  Reported by
  # the session rather than repeated here, so there is one definition.
  TIMER_HI: (n) -> @_timers[n]?.hiAddr ? (if n == 2 then 0x00B1 else 0x00B0)

  # Only codes that have been accepted are ever asked about -- the log is
  # the one place a code is displayed -- and each entry arrives with its
  # label already looked up.
  intCodeLabel: (key, code) -> @_codeLabels["#{key}:#{code}"] ? null

export class GUIMirror
  constructor: (opts = {}) ->
    # `write` carries an edit out to the session; without one the mirror is
    # read-only, which is what a test wants.
    @write = opts.write ? (cmd, args) ->
    @totalHW = opts.totalHW ? 0x80000
    @cpu = new MirrorCPU(@, @totalHW / 2)
    @iop = new MirrorIOP(@)
    @halUCP = { active: false, waitingForInput: false, trapAddrs: null }
    @breakpoints = new Map()
    @status = null
    @snap = null

    @_tracking = false
    @_reads = new Set()
    @_meta = new Set()      # ...of those, the ones read for prot/access too
    @truncated = 0          # halfwords the last request could not carry
    @_covered = []          # the windows the last snapshot actually filled
    @_disasmWanted = new Map()
    @_suppress = 0
    @_wireWrites()

  #
  # Writes: a pane edits the mirror, and the edit goes out
  #
  _forward: (cmd, args) ->
    return if @_suppress > 0
    @write(cmd, args)
    return

  _wireWrites: () ->
    m = @
    for rf, bank in @cpu.regFiles
      do (rf, bank) ->
        for reg, i in rf.regs
          do (reg, i) ->
            base = reg.set32.bind(reg)
            reg.set32 = (v) ->
              base(v)
              name = if bank == 2 then "FP#{i}" else "R#{i}"
              m._forward('setreg', { name, value: v >>> 0, bank })
              return
        baseDSE = rf.setDSE.bind(rf)
        rf.setDSE = (r, v) ->
          baseDSE(r, v)
          m._forward('setreg', { name: "DSE#{r & 7}", value: v & 0xf, bank })
          return
    psw = @cpu.psw
    for n in [1, 2]
      do (n) ->
        reg = psw["psw#{n}"]
        base = reg.set32.bind(reg)
        reg.set32 = (v) ->
          base(v)
          m._forward('setreg', { name: "PSW#{n}", value: v >>> 0 })
          return
    # `setNIA` and `setCC` reach PSW1 through the register above, so the
    # inner forward is suppressed and one command goes out, naming the field
    # the pane actually edited.
    for [fn, name] in [['setNIA', 'NIA'], ['setCC', 'CC']]
      do (fn, name) ->
        base = psw[fn].bind(psw)
        psw[fn] = (v) ->
          m._suppress++
          try
            base(v)
          finally
            m._suppress--
          m._forward('setreg', { name, value: v >>> 0 })
          return
    return

  #
  # Which memory the panes are looking at
  #
  beginTrack: () ->
    @_tracking = true
    @_reads = new Set()
    @_meta = new Set()
    return

  endTrack: () ->
    @_tracking = false
    return @windows()

  _touchRead: (addr) ->
    @_reads.add(addr & 0x7ffff) if @_tracking
    return

  # The memory pane is the only thing that colours by protection and access
  # recency.  Which windows carry those arrays is answered from the
  # addresses themselves: the watch pane's windows are scattered across the
  # whole image, so a low/high bracket around the memory pane's run would
  # mark every window between its ends.
  _touchMeta: (addr) ->
    return unless @_tracking
    a = addr & 0x7ffff
    @_reads.add(a)
    @_meta.add(a)
    return

  _wantDisasm: (proc, count) ->
    @_disasmWanted.set(proc, count) if @_tracking
    return

  windows: () ->
    ranges = coalesce(@_reads)
    @truncated = ranges.truncated ? 0
    for w in ranges
      hit = false
      for a from @_meta
        if a >= w.addr and a < w.addr + w.count
          hit = true
          break
      if hit then Object.assign(w, { access: true, prot: true }) else w

  iopDisasmWanted: () ->
    ({ proc, count } for [proc, count] from @_disasmWanted)

  # True when the last draw read memory the last snapshot did not carry, so
  # the GUI should fetch again and draw once more.  A view that has not
  # moved answers false, which is the usual case.
  stale: () ->
    for a from @_reads
      covered = false
      for w in @_covered
        if a >= w.addr and a < w.addr + w.count
          covered = true
          break
      return true unless covered
    false

  #
  # Filling from a snapshot
  #
  apply: (snap) ->
    return unless snap?
    @snap = snap
    @status = snap.status ? @status
    @_covered = ({ addr: w.addr, count: w.count } for w in (snap.memory ? []))
    @cpu.mainStorage.applyWindow(w) for w in (snap.memory ? [])
    @_applyRegs(snap.regs) if snap.regs?
    @_applyInts(snap.ints, snap.intlog) if snap.ints?
    @iop.apply(snap.iop) if snap.iop?
    @iop.applyDisasm(snap.iopdisasm) if snap.iopdisasm?
    if snap.halucp?
      @halUCP.active = !!snap.halucp.active
      @halUCP.waitingForInput = !!snap.halucp.waitingForInput
      @halUCP.trapAddrs = snap.halucp.trapAddrs ? null
    # In place: the panes were handed this Map when they were wired, and
    # replacing it would leave them holding the one from startup.
    if snap.breakpoints?
      @breakpoints.clear()
      for bp in snap.breakpoints
        @breakpoints.set(bp.addr, { enabled: bp.enabled, name: bp.name, hits: bp.hits })
    return

  # A register's `set32` marks it written, so the values go in first and the
  # session's tracking arrays over the top -- otherwise every register
  # would look freshly written on every refresh.
  _applyRegs: (r) ->
    @_suppress++
    try
      for b, bank in (r.banks ? [])
        rf = @cpu.regFiles[bank]
        continue unless rf?
        rf.r(i).set32(v) for v, i in (b.values ? [])
        rf.lastWritten.set(b.lastWritten) if b.lastWritten?
        rf.dse = (b.dse ? rf.dse).slice()
        rf.dseLastWritten.set(b.dseLastWritten) if b.dseLastWritten?
        rf.step = r.step ? 0
      psw = @cpu.psw
      psw.psw1.set32(r.psw.psw1)
      psw.psw2.set32(r.psw.psw2)
      psw.lastWritten1 = r.psw.lastWritten1 ? 0
      psw.lastWritten2 = r.psw.lastWritten2 ? 0
      psw.step = r.step ? 0
      @cpu.mainStorage.step = r.step ? 0
    finally
      @_suppress--
    return

  _applyInts: (ints, log) ->
    cpu = @cpu
    cpu._ints = ints
    cpu.intHold = !!ints.hold
    cpu.intCount = ints.count ? 0
    cpu._timers = {}
    cpu._timers[t.n] = t for t in (ints.timers ? [])
    if log?
      cpu.intLog = log.entries ? []
      cpu._codeLabels = {}
      for e in cpu.intLog when e.code? and e.codeLabel?
        cpu._codeLabels["#{e.key}:#{e.code}"] = e.codeLabel
    return
