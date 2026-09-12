import {call, setTimeout, setInterval, setImmediate, clearTimeout, clearInterval, now as simNow} from '../../com/simRuntime.coffee'
# Pulse Code Modulation Master Unit implementation
#
# JSC-18611,Rev.G SB 29 and SB 30, JSC-11174 Vol.3 dwg 17.2; the word
# formats, the memory maps and the document references are in
# pcmmuConf.coffee.
#
# One process carries two units, one powered. The powered unit serves five
# GPC IP busses, fetches from the OI MDMs, and produces both telemetry streams.
#
# GPC commands (pcmmuConf.coffee OP):
#
#   WRITE_TB      count data words follow, into the computer's side of
#                 the buffer from the word named
#   EOM           the computer's side holds a data set of tbAddr + 1
#                 words; the buffer switches sides when the formatter has
#                 read the set on its side
#   READ_TB       count words from the formatter's side, E set on a word
#                 never written
#   READ_RAM      count words of the OI/PL RAM, E set on a word whose
#                 fetch failed, S cleared and V set on one the MDM did
#                 not answer
#   READ_BITE     the BITE register, then bits 1-15 reset to good and the
#                 power interrupt status cleared
#   FMT_SELECT    RAM or PROM for the 128-kbps formatter, taken only with
#                 the panel C3 FORMAT switch at GPC
#   LOAD_FMT128, LOAD_FMT64    count data words follow, into the format RAM
#   READ_FMT128, READ_FMT64    count words of the format RAM
#
# Every response word carries the status: S cleared from power-up until
# a BITE read, V cleared while any BSR bit reads bad.  A command to the
# other unit address is not answered.  A command arriving before a
# transfer's data words all did ends the transfer and sets BSR bit 14
# bad.
#
# THE FETCH
#
# fetch.coffee defines the program. Entries come due at their sample
# rate and go out one at a time on the OI bus as MDM INPUT commands; the
# MDM's response words go into the RAM slot with bit 17 from the E bit.
# An MDM that does not answer within FETCH_TIMEOUT_MS leaves its slot as
# it was, flagged no response, and sets BSR bit 15 bad; an E bit sets bit
# 10 bad.
#
# THE FORMATTERS
#
# Each minor frame the 128-kbps formatter runs the selected 128-kbps
# format memory and the 64-kbps formatter its RAM: the eight rate group
# counters are loaded from words 1-8 when their rate's frames come round
# and each slot takes the next entry of its rate's group.  A toggle
# buffer word read by the 128-kbps formatter counts toward the data set
# on that side; when the set is read and an end of message is waiting on
# the computer's side, the sides switch.
#
# The BITE register is reset to good every second major frame and by a
# GPC read; a condition still present sets its bit bad again.
#

import {BusMsg, busConfig} from './../../com/bus.civet.jsx'
import {LRU} from './../../com/lru.civet.jsx'
import {MODE as MDM_MODE, encodeDirect, SEV} from './../mdm/mdmConf'
import {UNIT, IP_BUSSES, HDR_BUS, LDR_BUS, OP, TOGGLE_BUFFERS, TB_WORDS, RAM_WORDS, FMT_WORDS
        decodeCommand, fmtCommand, STATUS, BSR, BSR_GOOD, fmtBSR
        RATES, FMT_GROUPS, FMT_SLOTS_BASE, MINOR_FRAMES, FRAME_MS, DATA, decodeEntry, slotsOf
        packStream, hex4} from './pcmmuConf'
import {buildFetch} from './fetch'
import {buildTlmFormat, FORMATS} from './tlmFormat'

now = () -> simNow()

# Longer than the MDM waits for a serial device (lru/mdm/mdmConf.coffee).
FETCH_TIMEOUT_MS  = 40
FETCH_TICK_MS     = 2
BSR_RESET_FRAMES  = 2
FORMAT_SWITCH     = ['FIXED', 'GPC', 'PROGRAM']

RAM_INVALID       = 0x1
RAM_NO_RESPONSE   = 0x2

newSide = () ->
  words: new Uint16Array(TB_WORDS)
  valid: new Uint8Array(TB_WORDS)
  read:  new Uint8Array(TB_WORDS)
  readCount: 0
  len:   0
  eom:   null

newToggleBuffer = (n) -> {num: n, gpc: newSide(), fmt: newSide(), switches: 0, writes: 0, eoms: 0}

sideDone = (s) -> s.readCount >= s.len

export class PCMMU extends LRU
  constructor: (opts = {}) ->
    units = opts.units ? [1, 2]
    for n in units
      throw new Error("no such PCMMU: #{n}") unless UNIT[n]
    busses = IP_BUSSES.concat((UNIT[n].oiBus for n in units), [HDR_BUS, LDR_BUS])
    # A feed a unit: the switch below selects which one the OI PCMMU POWER
    # switch has picked, and the feed says whether that unit has anything
    # behind it.
    super({id: 'PCMMU', busses,
           power: (opts.powerFeeds ?
                   ({name: "#{n}", feed: "PCMMU#{n}"} for n in units)),
           verbose: opts.verbose, onEvent: opts.onEvent})

    @fetch = opts.fetch ? buildFetch({mdms: opts.mdms})
    @formatSwitch = 'GPC'
    @mtuGood = opts.mtuGood ? true
    @hdrFormat = opts.hdrFormat ? null
    @ldrFormat = opts.ldrFormat ? 102
    @fetchTimeoutMs = opts.fetchTimeoutMs ? FETCH_TIMEOUT_MS
    # A unit powered and BITE-read before the session began answers with
    # S set from the start.
    @statusNormal = !!opts.statusNormal
    @frameMs = opts.frameMs ? FRAME_MS
    @prom = buildTlmFormat(129, @fetch)
    @timers = []

    @units = {}
    for n in units
      @units[n] = u = {
        num:      n
        oiBus:    UNIT[n].oiBus
        bus:      @bus[UNIT[n].oiBus]
        powered:  false
        tb:       (newToggleBuffer(i + 1) for i in [0...TOGGLE_BUFFERS] by 1)
        ram:      new Uint16Array(RAM_WORDS)
        ramFlags: new Uint8Array(RAM_WORDS)
        fmt128:   new Uint16Array(FMT_WORDS)
        fmt64:    new Uint16Array(FMT_WORDS)
        fmtSelect: 'FIXED'
        bsr:      BSR_GOOD
        powerInterrupt: true
        fmt64Written: false
        pending:  null
        frame:    0
        majors:   0
        counters: {128: new Int32Array(FMT_GROUPS), 64: new Int32Array(FMT_GROUPS)}
        due:      new Float64Array(@fetch.entries.length)
        queue:    []
        inflight: null
        stats:    {commands: 0, ignored: 0, writes: 0, eoms: 0, reads: 0, bites: 0, loads: 0, cut: 0,
                   fetches: 0, fetchErrors: 0, invalidWords: 0, minorFrames: 0}
      }
    @setFormatSwitch(opts.formatSwitch ? 'GPC')
    @setPower(opts.power ? 1)

    for name, b of @bus
      b.onReceive @_onBusMessage, @
    @ready().then => @_start()


  # `n` the powered unit, 0 for neither (the panel C3 OI PCMMU POWER switch).
  setPower: (n) ->
    n = Number(n)
    throw new Error("invalid PCMMU power position '#{n}'") unless n in [0, 1, 2]
    @switchAt = n
    @_applyPower()
    return

  _applyPower: () ->
    return unless @switchAt?
    for _, u of @units
      on_ = (u.num == @switchAt) and (@power.named("#{u.num}")?.live() ? true)
      continue if u.powered == on_
      u.powered = on_
      @_powerUp(u) if on_
      @_log "PCMMU #{u.num} power #{if on_ then 'on' else 'off'}"
    return

  onVoltage: (input) ->
    @_applyPower()
    return

  # The panel C3 OI PCMMU FORMAT switch: FIXED, GPC or PROGRAM.  Away
  # from GPC it sets the 128-kbps selection itself.
  setFormatSwitch: (pos) ->
    pos = String(pos).toUpperCase()
    throw new Error("invalid FORMAT position '#{pos}'") unless pos in FORMAT_SWITCH
    @formatSwitch = pos
    for _, u of @units
      u.fmtSelect = 'PRGM' if pos == 'PROGRAM'
      u.fmtSelect = 'FIXED' if pos == 'FIXED'
    return

  setMtu: (good) ->
    @mtuGood = !!good
    return

  _powerUp: (u) ->
    u.tb = (newToggleBuffer(i + 1) for i in [0...TOGGLE_BUFFERS] by 1)
    u.ram.fill 0
    u.ramFlags.fill 0
    u.fmt128.fill 0
    u.fmt64.fill 0
    u.fmtSelect = if @formatSwitch == 'PROGRAM' then 'PRGM' else 'FIXED'
    u.bsr = BSR_GOOD
    u.powerInterrupt = not @statusNormal
    u.fmt64Written = false
    u.pending = null
    u.frame = 0
    u.majors = 0
    u.queue = []
    @_clearInflight(u)
    t = now()
    u.due[i] = t + (i % 50) for i in [0...u.due.length] by 1
    if @hdrFormat?
      u.fmt128.set buildTlmFormat(@hdrFormat, @fetch)
    if @ldrFormat?
      u.fmt64.set buildTlmFormat(@ldrFormat, @fetch)
      u.fmt64Written = true
    return

  _start: () ->
    @_frameLoop()
    t = setInterval call(@, '_fetchAll'), FETCH_TICK_MS
    t.unref?()
    @timers.push t
    return

  onStop: () ->
    clearTimeout @frameTimer if @frameTimer?
    @frameTimer = null
    clearInterval t for t in @timers
    @timers = []
    @_clearInflight(u) for _, u of @units
    return

  describe: () ->
    lines = for _, u of @units
      "PCMMU #{u.num} on #{u.oiBus} (port #{busConfig[u.oiBus].port})" +
      "#{if u.powered then ', powered' else ', off'}"
    lines.push "GPC busses #{IP_BUSSES.join(' ')} " +
               "(ports #{busConfig.IP1.port}-#{busConfig.IP5.port}), " +
               "128 kbps on #{HDR_BUS} (port #{busConfig[HDR_BUS].port}), " +
               "64 kbps on #{LDR_BUS} (port #{busConfig[LDR_BUS].port})"
    lines.push "fetch: #{@fetch.entries.length} commands, #{@fetch.words} RAM words; " +
               "FORMAT switch #{@formatSwitch}; PROM 129, " +
               "RAM #{@hdrFormat ? 'empty'} / #{@ldrFormat ? 'empty'}"
    lines

  _bad: (u, bit) ->
    u.bsr &= ~bit & 0xffff
    return

  bsrWord: (u) ->
    w = u.bsr
    w &= ~BSR.MTU unless @mtuGood
    w |= BSR.DNLK_64 | BSR.PARITY_64 unless u.fmt64Written
    w |= BSR.PRGM if u.fmtSelect == 'PRGM'
    w & 0xffff

  # The status of a response word; a no-response word's S and V are
  # forced.
  _status: (u, base = STATUS.NORMAL) ->
    return base if base == STATUS.NO_RESPONSE
    s = base
    s &= ~SEV.S if u.powerInterrupt
    s &= ~SEV.V if (@bsrWord(u) & BSR_GOOD) != BSR_GOOD
    s

  poweredUnit: () ->
    for _, u of @units when u.powered
      return u
    null


  _onBusMessage: (self, busID, msg) ->
    words = msg.data16
    return unless words?.length
    if busID in IP_BUSSES
      u = self.poweredUnit()
      return unless u?
      if msg.cmd
        self._onCommand u, busID, decodeCommand(((words[0] & 0xffff) << 8) | ((words[1] >> 8) & 0xff))
      else
        self._onDataWord u, busID, w & 0xffff for w in words
      return
    for _, u of self.units when u.oiBus == busID
      self._onOI u, msg
    return

  _onCommand: (u, busID, c) ->
    if u.pending?
      if u.pending.bus == busID and u.pending.got.length < u.pending.count
        @_bad u, BSR.GPC_RESPONSE
        u.stats.cut += 1
        @_log "#{busID}: transfer cut short at #{u.pending.got.length} of #{u.pending.count}"
      u.pending = null
    unless c.valid
      u.stats.ignored += 1
      return
    u.stats.commands += 1
    @_log "#{busID}: #{fmtCommand c}" unless c.op in [OP.WRITE_TB, OP.EOM]
    switch c.op
      when OP.WRITE_TB
        tb = u.tb[c.buffer - 1]
        return unless tb?
        u.stats.writes += 1
        tb.writes += 1
        u.pending = {bus: busID, count: c.count, got: [], done: call(@, '_writeTB', tb, c.tbAddr)}
      when OP.EOM
        tb = u.tb[c.buffer - 1]
        return unless tb?
        u.stats.eoms += 1
        tb.eoms += 1
        tb.gpc.eom = {len: c.tbAddr + 1}
        @_trySwitch u, tb
      when OP.READ_TB
        tb = u.tb[c.buffer - 1]
        return unless tb?
        u.stats.reads += 1
        words = []; sev = []
        for i in [0...c.count] by 1
          k = (c.tbAddr + i) % TB_WORDS
          words.push tb.fmt.words[k]
          sev.push @_status(u, if tb.fmt.valid[k] then STATUS.NORMAL else STATUS.INVALID)
        @_respond u, busID, words, sev
      when OP.READ_RAM
        u.stats.reads += 1
        words = []; sev = []
        for i in [0...c.count] by 1
          k = (c.start + i) % RAM_WORDS
          words.push u.ram[k]
          f = u.ramFlags[k]
          sev.push @_status(u, if f & RAM_NO_RESPONSE then STATUS.NO_RESPONSE else if f & RAM_INVALID then STATUS.INVALID else STATUS.NORMAL)
        @_respond u, busID, words, sev
      when OP.READ_BITE
        u.stats.bites += 1
        w = @bsrWord(u)
        @_respond u, busID, [w], [@_status(u)]
        u.bsr = BSR_GOOD
        u.powerInterrupt = false
      when OP.FMT_SELECT
        if @formatSwitch == 'GPC'
          u.fmtSelect = if c.prgm then 'PRGM' else 'FIXED'
      when OP.LOAD_FMT128, OP.LOAD_FMT64
        u.stats.loads += 1
        mem = if c.op == OP.LOAD_FMT128 then u.fmt128 else u.fmt64
        u.fmt64Written = true if c.op == OP.LOAD_FMT64
        u.pending = {bus: busID, count: c.count, got: [], done: call(@, '_loadFormat', mem, c.start)}
      when OP.READ_FMT128, OP.READ_FMT64
        u.stats.reads += 1
        mem = if c.op == OP.READ_FMT128 then u.fmt128 else u.fmt64
        words = (mem[(c.start + i) % FMT_WORDS] for i in [0...c.count] by 1)
        @_respond u, busID, words, (@_status(u) for [0...c.count] by 1)
    return

  _loadFormat: (mem, start, words) ->
    mem[(start + i) % FMT_WORDS] = x for x, i in words
    return

  _fetchAll: () ->
    @_fetchTick(u) for _, u of @units when u.powered
    return

  _onDataWord: (u, busID, w) ->
    p = u.pending
    return unless p? and p.bus == busID
    p.got.push w
    if p.got.length >= p.count
      u.pending = null
      p.done p.got
    return

  _writeTB: (tb, at, words) ->
    s = tb.gpc
    for w, i in words
      k = (at + i) % TB_WORDS
      s.words[k] = w
      s.valid[k] = 1
    return

  _trySwitch: (u, tb) ->
    return unless tb.gpc.eom?
    return unless sideDone(tb.fmt)
    [tb.fmt, tb.gpc] = [tb.gpc, tb.fmt]
    tb.fmt.len = tb.fmt.eom.len
    tb.fmt.eom = null
    tb.fmt.read.fill 0
    tb.fmt.readCount = 0
    tb.gpc.eom = null
    tb.switches += 1
    return

  _respond: (u, busID, words, sev) ->
    b = @bus[busID]
    return unless b?
    n = words.length
    flagged = sev.some((s) -> s != SEV.VALID)
    setImmediate call(@, '_emitResponse', busID, words, sev)
    return

  _emitResponse: (busID, words, sev) ->
    m = new BusMsg(words.length)
    m.data16.set(words)
    m.sev = sev if sev.some((s) -> s != SEV.VALID)
    @bus[busID].sendMsg m
    return


  _fetchTick: (u) ->
    t = now()
    for e, i in @fetch.entries
      continue if u.due[i] > t
      period = 1000 / e.rate
      u.due[i] += period
      u.due[i] = t + period if u.due[i] < t
      u.queue.push e unless e in u.queue
    @_issue u
    return

  _issue: (u) ->
    return if u.inflight?
    e = u.queue.shift()
    return unless e?
    cmd = encodeDirect(e.iua, MDM_MODE.INPUT, e.card, e.channel, e.count)
    msg = BusMsg.Command(cmd)
    u.stats.fetches += 1
    timer = setTimeout call(@, '_fetchTimeout', u), @fetchTimeoutMs
    timer.unref?()
    u.inflight = {e, got: [], sev: [], timer}
    u.bus.sendMsg msg
    return

  _clearInflight: (u) ->
    clearTimeout u.inflight.timer if u.inflight?
    u.inflight = null
    return

  _onOI: (u, msg) ->
    f = u.inflight
    return unless f?
    words = msg.data16
    return if msg.cmd
    for w, i in words
      f.got.push w & 0xffff
      f.sev.push (msg.sev?[i] ? SEV.VALID) & 7
    return if f.got.length < f.e.count
    @_clearInflight u
    e = f.e
    for w, i in f.got[0...e.count]
      u.ram[e.ram + i] = w
      if f.sev[i] & SEV.E
        u.ramFlags[e.ram + i] = RAM_INVALID
        u.stats.invalidWords += 1
        @_bad u, BSR.INPUT_VALID
      else
        u.ramFlags[e.ram + i] = 0
    @_issue u
    return

  _fetchTimeout: (u) ->
    f = u.inflight
    return unless f?
    u.inflight = null
    e = f.e
    u.ramFlags[e.ram + i] |= RAM_NO_RESPONSE for i in [0...e.count] by 1
    u.stats.fetchErrors += 1
    @_bad u, BSR.MDM_RESPONSE
    @_issue u
    return


  _frameLoop: () ->
    @_frameT0 = now()
    @_frameK = 0
    @frameTimer = setTimeout call(@, '_frameStep'), @frameMs
    @frameTimer.unref?()
    return

  _frameStep: () ->
    @_frameK += 1
    @_minorFrame u for _, u of @units when u.powered
    @frameTimer = setTimeout call(@, '_frameStep'), Math.max(0, @_frameT0 + @_frameK * @frameMs - now())
    @frameTimer.unref?()
    return

  _minorFrame: (u) ->
    if u.frame == 0
      u.majors += 1
      if u.majors % BSR_RESET_FRAMES == 0
        u.bsr = BSR_GOOD
    for rate in [128, 64]
      mem = if rate == 128 then (if u.fmtSelect == 'PRGM' then u.fmt128 else @prom) else u.fmt64
      bytes = @_format(u, rate, mem)
      words = packStream(bytes)
      m = new BusMsg(words.length)
      m.data16.set words
      @bus[if rate == 128 then HDR_BUS else LDR_BUS]?.sendMsg m
    u.stats.minorFrames += 1
    u.frame = (u.frame + 1) % MINOR_FRAMES
    return

  # The bytes of one minor frame from a format memory.
  _format: (u, rate, mem) ->
    ctr = u.counters[rate]
    for g in [0...FMT_GROUPS] by 1
      ctr[g] = mem[g] if u.frame % (MINOR_FRAMES / RATES[g]) == 0
    bytes = []
    for slot in [0...slotsOf(rate)] by 1
      g = mem[FMT_SLOTS_BASE + slot] & 7
      e = decodeEntry(mem[ctr[g] % FMT_WORDS])
      ctr[g] += 1
      bytes.push if e.fill then e.byte else @_dataByte(u, e.addr, e.high, rate)
    # Complete the current minor frame before exchanging consumed buffers,
    # keeping both bytes of its final data word on the same side.
    @_trySwitch(u, tb) for tb in u.tb if rate == 128
    bytes

  _dataByte: (u, addr, high, rate) ->
    if addr < RAM_WORDS
      w = u.ram[addr]
    else if addr < DATA.BSR
      i = addr - DATA.TB
      tb = u.tb[Math.floor(i / TB_WORDS)]
      k = i % TB_WORDS
      s = tb.fmt
      w = s.words[k]
      if rate == 128 and k < s.len and not s.read[k]
        s.read[k] = 1
        s.readCount += 1
    else if addr == DATA.BSR
      w = @bsrWord(u)
    else if addr == DATA.COUNT
      w = u.frame
    else
      w = 0xffff
    if high then (w >>> 8) & 0xff else w & 0xff

  report: () ->
    units: (for _, u of @units
      num:       u.num
      oiBus:     u.oiBus
      powered:   u.powered
      fmtSelect: u.fmtSelect
      bsr:       hex4(@bsrWord(u))
      bsrText:   fmtBSR(@bsrWord(u))
      powerInterrupt: u.powerInterrupt
      frame:     u.frame
      toggleBuffers: (for tb in u.tb
        num: tb.num, writes: tb.writes, eoms: tb.eoms, switches: tb.switches, setLen: tb.fmt.len, readCount: tb.fmt.readCount)
      stats:     u.stats)
    formatSwitch: @formatSwitch
    mtuGood:      @mtuGood
    fetch:        {entries: @fetch.entries.length, words: @fetch.words}
    formats:      {prom: 129, hdr: @hdrFormat, ldr: @ldrFormat}
