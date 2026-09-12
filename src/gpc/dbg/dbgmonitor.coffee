# Bus and discrete monitoring, and the record log behind both
#
# Three pieces, all owned by a DebugSession:
#
#   EventLog       a file that records what the session publishes, one line
#                  per record, stamped with both clocks
#   BusMonitor     a tap on every BCE's MIA: the words that cross each bus
#   DiscreteMonitor  the discrete registers, sampled and hooked
#
# What a monitor records and what it broadcasts are separate: it always
# fills its ring and any open log, and sends events to connected clients
# only when asked to.  Bus traffic runs to thousands of words a second.

fs = require 'fs'
path = require 'path'

require 'com/util'
import {DISCRETE_BITS, discreteName, discreteOutName, bitMask,
        syncCodeOut, syncCodeIn, syncCodeName,
        REG_A, REG_B} from 'com/discretes'

# One record carries both clocks: the host's, for lining a run up against
# anything outside this process, and the machine's, which is the only one
# that means anything between two events inside it.
export stampOf = (session) ->
  {
    wall: new Date().toISOString()
    wallMs: Date.now()
    timeNs: session.gpc.cpu.timeNs
    simSec: session.gpc.cpu.timeNs / 1e9
    steps: session.stepCount
  }

# A file that records published events.  'ndjson' is one JSON object per
# line; 'text' is one padded line per record, for reading.
export class EventLog
  constructor: (@filePath, opts = {}) ->
    @format = if opts.format == 'text' then 'text' else 'ndjson'
    @kinds = opts.kinds ? null      # null = every kind
    @opened = new Date().toISOString()
    @count = 0
    @stream = fs.createWriteStream(@filePath, { flags: if opts.append then 'a' else 'w' })
    @stream.on 'error', (e) =>
      @error = e.message

  wants: (kind) -> not @kinds? or kind in @kinds

  write: (kind, body, stamp) ->
    return unless @stream? and not @error
    @count++
    if @format == 'ndjson'
      @stream.write(JSON.stringify({ kind, stamp, body }) + '\n')
    else
      @stream.write("#{stamp.wall}  #{(stamp.simSec.toFixed(9) + 's').lpad(' ', 18)}  " +
                    "#{String(stamp.steps).lpad(' ', 10)}  #{kind.rpad(' ', 10)} #{textBody(kind, body)}\n")
    return

  close: () ->
    @stream?.end()
    @stream = null
    return

  describe: () ->
    { path: @filePath, format: @format, kinds: @kinds, records: @count,
      opened: @opened, error: @error ? null }

# One line of a text-format log.
textBody = (kind, body) ->
  switch kind
    when 'bus'
      "#{body.bus.rpad(' ', 4)} BCE#{String(body.bce).lpad(' ', 2)} #{body.dir} " +
      "#{if body.cmd then 'CMD' else '   '} #{body.value.asHex(4)}"
    when 'discrete'
      "#{body.register} #{body.value.asHex(8)} #{body.changed.join(',')}"
    when 'output'
      JSON.stringify(body.text)
    when 'stopped'
      "#{body.reason} at #{body.location.hex} #{body.description ? ''}"
    when 'logpoint'
      "#{body.location.hex} #{body.name ? ''} hits=#{body.hits}"
    else JSON.stringify(body)

# The words crossing each BCE's bus.
#
# A tap on the MIA sees every word, which is more than the MIA's 64-word
# ring keeps.  `busses` limits which ones are watched by bus name (DK1, FC2);
# with none, all of them.
export class BusMonitor
  constructor: (@session, opts = {}) ->
    @enabled = false
    @events = false
    @limit = opts.limit ? 4096
    @busses = null
    @ring = []
    @dropped = 0
    @counts = {}

  _mias: () ->
    iop = @session.gpc.iop
    return [] unless iop?.bce?
    (b.mia for b in iop.bce when b?.mia?)

  wants: (mia) ->
    return false unless mia.busName?
    not @busses? or mia.busName in @busses

  start: (opts = {}) ->
    @busses = if opts.busses?.length then (String(b).toUpperCase() for b in opts.busses) else null
    @limit = opts.limit if opts.limit?
    @events = !!opts.events if opts.events?
    @ring = []
    @dropped = 0
    @counts = {}
    for mia in @_mias()
      mia.tap = if @wants(mia) then ((m, dir, entry) => @_word(m, dir, entry)) else null
    @enabled = true
    @describe()

  stop: () ->
    mia.tap = null for mia in @_mias()
    @enabled = false
    @describe()

  _word: (mia, dir, entry) ->
    body = {
      bus: mia.busName, nom: mia.busNom ? null, bce: mia.bceNum
      dir: dir, cmd: entry.cmd, value: entry.value, timeNs: entry.timeNs
    }
    key = "#{mia.busName}.#{dir}"
    @counts[key] = (@counts[key] ? 0) + 1
    @ring.push(Object.assign({ steps: @session.stepCount }, body))
    while @ring.length > @limit
      @ring.shift()
      @dropped++
    @session.publish('bus', body, @events)
    return

  # Words grouped into transactions: a command word opens one, and words
  # continue it while the bus and direction hold.
  transactions: (count = 20, busFilter = null) ->
    groups = []
    cur = null
    for e in @ring
      continue if busFilter? and e.bus != busFilter
      if not cur? or e.cmd or cur.bus != e.bus or cur.dir != e.dir
        cur = { bus: e.bus, bce: e.bce, dir: e.dir, timeNs: e.timeNs,
                steps: e.steps, cmd: (if e.cmd then e.value else null), words: [] }
        groups.push(cur)
      if e.cmd then cur.cmd = e.value else cur.words.push(e.value)
    groups.slice(-count)

  clear: () ->
    n = @ring.length
    @ring = []
    @dropped = 0
    @counts = {}
    n

  describe: () ->
    {
      enabled: @enabled, events: @events, limit: @limit
      busses: @busses, records: @ring.length, dropped: @dropped
      counts: @counts
      attached: (m.busName for m in @_mias() when m.busName?)
    }

# The discrete registers.
#
# Inputs arrive from another process at any time, so the monitor hooks the
# IOP's receive path and sees them whether or not the machine is running.
# Outputs are written by a PCO, so they are sampled once per instruction and
# once at every stop.
export class DiscreteMonitor
  constructor: (@session) ->
    @enabled = false
    @events = false
    @limit = 1024
    @ring = []
    @dropped = 0
    @last = { DISCOUT: null, DISCINA: null, DISCINB: null }
    @_origRecv = null

  _iop: () -> @session.gpc.iop

  start: (opts = {}) ->
    @limit = opts.limit if opts.limit?
    @events = !!opts.events if opts.events?
    iop = @_iop()
    return @describe() unless iop?
    @_snapshot()
    unless @_origRecv?
      @_origRecv = iop.recvDiscrete.bind(iop)
      iop.recvDiscrete = (m) =>
        @_origRecv(m)
        @sample()
        return
    @enabled = true
    @describe()

  stop: () ->
    iop = @_iop()
    if @_origRecv? and iop?
      iop.recvDiscrete = @_origRecv
      @_origRecv = null
    @enabled = false
    @describe()

  _regs: () ->
    iop = @_iop()
    return {} unless iop?
    {
      DISCOUT: iop.regDiscreteOut.get32() >>> 0
      DISCINA: iop.regDiscreteInA.get32() >>> 0
      DISCINB: iop.regDiscreteInB.get32() >>> 0
    }

  _snapshot: () ->
    @last = @_regs()
    return

  # Which named bits differ between two register values.
  @changedBits: (name, before, after) ->
    reg = if name == 'DISCINB' then REG_B else REG_A
    named = name != 'DISCOUT'
    out = []
    diff = (before ^ after) >>> 0
    for b in [0...32] when diff & bitMask(b)
      label = if named then discreteName(reg, b) else discreteOutName(b)
      out.push("#{if (after & bitMask(b)) then '+' else '-'}#{label}")
    out

  # The self-sync codes a set of register values carries: `out` is what
  # this computer is issuing, `partners` names each computer whose lines
  # are not all low, as `n2 SSIP (110)`.
  @syncOf: (regs) ->
    sync = {}
    if regs.DISCOUT?
      sync.out = syncCodeName(syncCodeOut(regs.DISCOUT))
    if regs.DISCINA?
      seen = for n in [1..4] when (syncCodeIn(regs.DISCINA, n)) != 0
        "n#{n} #{syncCodeName(syncCodeIn(regs.DISCINA, n))}"
      sync.partners = seen.join(', ') if seen.length
    sync

  # Compare against the last snapshot and record whatever moved.
  sample: () ->
    return unless @enabled or @_origRecv?
    now = @_regs()
    for name, value of now
      before = @last[name]
      continue if before == value
      changed = DiscreteMonitor.changedBits(name, before ? 0, value)
      @last[name] = value
      body = {
        register: name, value: value, previous: before ? 0, changed: changed
        timeNs: @session.gpc.cpu.timeNs
      }
      sync = DiscreteMonitor.syncOf({"#{name}": value})
      body.sync = sync.out ? sync.partners if sync.out? or sync.partners?
      @ring.push(Object.assign({ steps: @session.stepCount }, body))
      while @ring.length > @limit
        @ring.shift()
        @dropped++
      @session.publish('discrete', body, @events)
    return

  state: () ->
    iop = @_iop()
    return { registers: [] } unless iop?
    regs = @_regs()
    registers = for name, value of regs
      reg = if name == 'DISCINB' then REG_B else REG_A
      bits = for b in [0...32] when value & bitMask(b)
        { bit: b, name: (if name == 'DISCOUT' then discreteOutName(b) else discreteName(reg, b)) }
      { name: name, value: value, bits: bits }
    { registers: registers, sync: DiscreteMonitor.syncOf(regs), monitoring: @enabled }

  clear: () ->
    n = @ring.length
    @ring = []
    @dropped = 0
    n

  describe: () ->
    { enabled: @enabled, events: @events, limit: @limit,
      records: @ring.length, dropped: @dropped }
