import {call, setTimeout, clearTimeout, now as simNow} from '../../com/simRuntime.coffee'
# Master Timing Unit implementation
#
# USA-005350,Rev.B sect.2.6 and 3.3; JSC-18819,Rev.F SCP 4.10.
#
# Three GMT/MET accumulators attach to forward MDM serial I/O card 3,
# channel 1. Formats and instrumentation outputs are in mtuConf.coffee.
#
#   POLL   the GPC is reading.  Answered with VALUE of seven words: GMT,
#          MET, BITE status.
#   VALUE  the GPC has written.  Four words are an update: a time and a
#          mode word with the minute it takes effect.  One word is a
#          reset: GMT to 001:00:00:00.000 or MET to 000:00:00:00.000.
#   CONNECT, DISCONNECT   sent by the accumulator: it is on the channel,
#          or unplugged from it.  CONNECT goes out when the process starts
#          and in answer to the MDM's REQUEST; DISCONNECT when it stops.
#
# An update is held until the accumulator's minutes field reaches the
# coincidence minute, and the BITE status carries "valid update received"
# over that interval.  A reset takes effect when it arrives.
#
# The unit's two instrumentation outputs, MTU 1 (voted) behind OF1 and
# MTU 2 (non-voted) behind OF2, card 0 channel 1, answer a POLL the same
# way and take no writes.
#
# The IRIG-B outputs to the crew timers and the instrumentation system,
# the oscillator switchover and the per-accumulator voting behind BITE
# bits 9 to 15 are not carried; those bits stay clear.
#

import {busConfig, wallNowUs} from './../../com/bus.civet.jsx'
import {LRU} from './../../com/lru.civet.jsx'
import {IO_OP, IO_ALL, ioBusName, encodeIO, decodeIO, fmtIO} from './../mdm/mdmConf'
import {ACCUM_MDM, CARD, CHANNEL, CARD_TYPE, OI_OUTPUT, OI_CARD, OI_CHANNEL,
        READ_WORDS, UPDATE_WORDS, RESET_WORDS, MODE, BITE,
        MS_PER_MINUTE, MS_PER_HOUR, MS_PER_DAY, MAX_DAYS,
        RESET_GMT_MS, RESET_MET_MS,
        packTime, unpackTimeMs, unpackMode,
        isReset, isGmt, fmtTime, fmtBite} from './mtuConf'

now = () -> simNow()

# How long ago a datagram's wall stamp was, in milliseconds.  Both ends
# of the subtraction are of one host clock, so the difference stands
# however far apart the two processes started, and a signed 32 bit result
# carries it across the stamp's wrap at 2^32 microseconds.
ageMsOf = (stampUs) ->
  return 0 unless stampUs?
  ((wallNowUs() - stampUs) | 0) / 1000

export class MTU extends LRU
  constructor: (opts = {}) ->
    accums = opts.accumulators ? [1, 2, 3]
    for n in accums
      throw new Error("no such mtu accumulator: #{n}") unless ACCUM_MDM[n]
    outputs = opts.outputs ? [1, 2]
    for n in outputs
      throw new Error("no such mtu output: #{n}") unless OI_OUTPUT[n]
    busName = (n) -> ioBusName(opts.mdm?[n] ? ACCUM_MDM[n])
    oiBusName = (n) -> ioBusName(OI_OUTPUT[n].mdm)
    busses = (busName(n) for n in accums).concat(oiBusName(n) for n in outputs)
    # "The MTU is redundantly powered by the ESS 1BC MTU A and ESS 2CA MTU
    # B circuit breakers on panel O13" (USA-007587 sect.2.6): either one
    # runs the unit.
    super({id: 'MTU', busses,
           power: (opts.power ? [{name: 'A', feed: 'MTU_A'}, {name: 'B', feed: 'MTU_B'}]),
           verbose: opts.verbose, onEvent: opts.onEvent})

    # The oscillator driving the accumulators, reported in BITE bit 1.
    @oscillator = opts.oscillator ? 1

    # GMT returns to day 1 at the end of this day.
    @rolloverDays = opts.rolloverDays ? 365

    # How long an accumulator takes to answer a poll.
    @replyDelayMs = opts.replyDelayMs ? 0

    @_t0 = now()
    # Elapsed time as the commanding computer's simulated clock reads it,
    # against the host clock this unit free-runs on: taken from the first
    # stamped poll and held, so the accumulators advance with that clock
    # from then on.  See _elapsedAt.
    @_simAnchorMs = null
    @_atMs = 0
    @_atWallMs = @_t0
    @accums = {}
    for n in accums
      @accums[n] = a = {
        num:      n
        mdm:      opts.mdm?[n] ? ACCUM_MDM[n]
        busName:  busName(n)
        bus:      @bus[busName(n)]
        # Added to elapsed time to give what the accumulator reads.
        gmtBase:  0
        metBase:  0
        # A constant error in this accumulator alone.
        skewMs:   0
        # A silent accumulator hears its poll and says nothing.
        answers:  true
        # A disconnected one is off the channel: the MDM's serial card
        # hears nothing and flags every word.
        connected: true
        bite:     0
        pending:  null      # an update waiting on its coincidence minute
        timer:    null
        reads:    0
        writes:   0
      }
      a.bus.onReceive @_onBusMessage, @

    @outputs = {}
    for n in outputs
      @outputs[n] = o = {
        num:     n
        nom:     OI_OUTPUT[n].nom
        mdm:     OI_OUTPUT[n].mdm
        busName: oiBusName(n)
        bus:     @bus[oiBusName(n)]
        reads:   0
      }
      o.bus.onReceive @_onBusMessage, @

    @setGmt(opts.gmtMs ? RESET_GMT_MS)
    @setMet(opts.metMs ? RESET_MET_MS)

    @ready().then => @_announce()


  _elapsed: () -> now() - @_t0

  # Elapsed time for a poll.  A datagram carrying the commanding
  # computer's simulated clock (com/bus.civet, gpc/iop_bce.coffee) is read
  # at that clock: the bus elements of one transaction transmit within a
  # few tens of microseconds of simulated time and milliseconds of wall
  # time, so a wall reading makes the three accumulators disagree by the
  # host's scheduling.  Once a simulated clock has been seen the unit runs
  # on it, and a poll without one -- an instrumentation reader has no
  # simulated clock of its own -- is answered from the last one carried
  # forward on the host, so every output stays on one time base.  With
  # none ever seen the host clock is the time base and a wall stamp is
  # read that far back from now.
  _elapsedAt: (clocks) ->
    at =
      if clocks?.simUs?
        simMs = clocks.simUs / 1000
        @_simAnchorMs ?= @_elapsed() - simMs
        simMs + @_simAnchorMs
      else if @_simAnchorMs?
        @_atMs + (now() - @_atWallMs) - ageMsOf(clocks?.wallUs)
      else
        @_elapsed() - ageMsOf(clocks?.wallUs)
    @_atMs = at
    @_atWallMs = now()
    at

  # GMT runs from day 1 and returns there at the end of the rollover day.
  # MET runs from day 0 and wraps at the end of day 399.
  _wrapGmt: (ms) ->
    limit  = (@rolloverDays + 1) * MS_PER_DAY
    return ms if ms < limit
    period = limit - MS_PER_DAY
    MS_PER_DAY + ((ms - MS_PER_DAY) % period)

  _wrapMet: (ms) ->
    period = (MAX_DAYS + 1) * MS_PER_DAY
    ((ms % period) + period) % period

  # `atMs` is the elapsed time to read the accumulator at, from
  # _elapsedAt; unset, it is read now.  The three accumulators are one
  # clock and a read of all three is one transaction, so what each returns
  # is the value at the instant the computer commanded it.
  gmtOf: (a, atMs = null) -> @_wrapGmt((atMs ? @_elapsed()) + a.gmtBase + a.skewMs)
  metOf: (a, atMs = null) -> @_wrapMet((atMs ? @_elapsed()) + a.metBase + a.skewMs)

  setGmt: (ms) ->
    @_setGmt(a, ms) for _, a of @accums
    return

  setMet: (ms) ->
    @_setMet(a, ms) for _, a of @accums
    return

  _setGmt: (a, ms, atMs = null) ->
    a.gmtBase = ms - (atMs ? @_elapsed())
    return

  _setMet: (a, ms, atMs = null) ->
    a.metBase = ms - (atMs ? @_elapsed())
    return


  # The accumulators are volatile: a unit that comes back up counts from
  # the reset time until a computer writes it, and says nothing while it
  # is down.
  onPowerOn: () ->
    @setGmt(RESET_GMT_MS)
    @setMet(RESET_MET_MS)
    @_log "power on"
    return

  onPowerOff: () ->
    @_log "power off"
    return

  setSkew: (n, ms) ->
    a = @accums[n]
    throw new Error("mtu accumulator #{n} is not running") unless a
    a.skewMs = ms
    return

  setAnswers: (n, on_) ->
    a = @accums[n]
    throw new Error("mtu accumulator #{n} is not running") unless a
    a.answers = !!on_
    return

  setConnected: (n, on_) ->
    a = @accums[n]
    throw new Error("mtu accumulator #{n} is not running") unless a
    a.connected = !!on_
    @_sendLink a.bus, CARD, CHANNEL, a.connected
    return

  _announce: (on_ = true) ->
    for _, a of @accums when a.connected
      @_sendLink a.bus, CARD, CHANNEL, on_
    for _, o of @outputs
      @_sendLink o.bus, OI_CARD, OI_CHANNEL, on_
    return

  onStop: () ->
    for _, a of @accums
      clearTimeout a.timer if a.timer?
      a.timer = null
    @_announce(false)
    return

  describe: () ->
    lines = for _, a of @accums
      "MTU accumulator #{a.num} on #{a.busName} (port #{busConfig[a.busName].port}), " +
      "MDM #{a.mdm} card #{CARD} channel #{CHANNEL}" +
      "#{if a.skewMs then ", skew #{a.skewMs} ms" else ''}" +
      "#{if a.answers then '' else ', silent'}" +
      "#{if a.connected then '' else ', disconnected'}"
    for _, x of @outputs
      lines.push "MTU output #{x.num} (#{x.nom}) on #{x.busName} " +
                 "(port #{busConfig[x.busName].port}), MDM #{x.mdm} " +
                 "card #{OI_CARD} channel #{OI_CHANNEL}"
    first = (a for _, a of @accums)[0]
    lines.push "GMT #{fmtTime(@gmtOf(first))}, MET #{fmtTime(@metOf(first))}, " +
               "oscillator #{@oscillator}" if first?
    lines


  # Bit 1 names the driving oscillator; bit 16 is set while an update
  # waits on its coincidence minute; the rest is whatever was injected.
  biteOf: (a) ->
    hw = a.bite
    hw |= BITE.OSC1_DRIVES if @oscillator == 1
    hw |= BITE.VALID_UPDATE if a.pending?
    hw & 0xffff


  _onBusMessage: (self, busID, msg) ->
    return unless self.powered()
    m = decodeIO(msg.data16)
    return unless m?
    return if m.type and m.type != CARD_TYPE
    names = (card, channel) ->
      (m.card == IO_ALL or m.card == card) and (m.channel == IO_ALL or m.channel == channel)
    if (a = self._accumOn(busID))?
      if m.op == IO_OP.REQUEST
        self._sendLink a.bus, CARD, CHANNEL, true if a.connected and names(CARD, CHANNEL)
        return
      return unless m.card == CARD and m.channel == CHANNEL
      switch m.op
        when IO_OP.POLL  then self._doRead(a, self._elapsedAt(msg))
        when IO_OP.VALUE
          # A seven-word VALUE on the channel is an accumulator's answer.
          self._doWrite(a, m.words) if m.words.length in [UPDATE_WORDS, RESET_WORDS]
    else if (o = self._outputOn(busID))?
      if m.op == IO_OP.REQUEST
        self._sendLink o.bus, OI_CARD, OI_CHANNEL, true if names(OI_CARD, OI_CHANNEL)
        return
      return unless m.card == OI_CARD and m.channel == OI_CHANNEL
      self._doReadOutput(o, self._elapsedAt(msg)) if m.op == IO_OP.POLL
    return

  _accumOn: (busID) ->
    for _, a of @accums
      return a if a.busName == busID
    null

  _outputOn: (busID) ->
    for _, o of @outputs
      return o if o.busName == busID
    null

  _sendLink: (bus, card, channel, on_) ->
    op = if on_ then IO_OP.CONNECT else IO_OP.DISCONNECT
    @send bus, encodeIO({op, type: CARD_TYPE, card, channel, words: []})
    return

  _send: (bus, card, channel, words) ->
    @send bus, encodeIO({op: IO_OP.VALUE, type: CARD_TYPE, card, channel, words}),
          @replyDelayMs
    return

  # The voted output: the middle value of the accumulators running.  The
  # non-voted output: accumulator 1, or the lowest numbered one running.
  _votedTime: (read) ->
    ts = (read(a) for _, a of @accums when a.answers).sort((x, y) -> x - y)
    ts = (read(a) for _, a of @accums).sort((x, y) -> x - y) unless ts.length
    ts[Math.floor(ts.length / 2)]

  _firstAccum: () ->
    for n in [1, 2, 3] when @accums[n]?
      return @accums[n]
    null


  _doRead: (a, atMs = null) ->
    a.reads += 1
    unless a.answers
      @_log "accumulator #{a.num} polled, silent"
      return
    gmt = @gmtOf(a, atMs)
    met = @metOf(a, atMs)
    @_send a.bus, CARD, CHANNEL, packTime(gmt).concat(packTime(met), [@biteOf(a)])
    @_log "accumulator #{a.num} read GMT #{fmtTime(gmt)} MET #{fmtTime(met)}"
    return

  _doReadOutput: (o, atMs = null) ->
    o.reads += 1
    if o.num == 1
      gmt = @_votedTime((a) => @gmtOf(a, atMs))
      met = @_votedTime((a) => @metOf(a, atMs))
      bite = @biteOf(@_firstAccum())
    else
      a = @_firstAccum()
      gmt = @gmtOf(a, atMs)
      met = @metOf(a, atMs)
      bite = @biteOf(a)
    @_send o.bus, OI_CARD, OI_CHANNEL, packTime(gmt).concat(packTime(met), [bite])
    @_log "output #{o.num} (#{o.nom}) read GMT #{fmtTime(gmt)} MET #{fmtTime(met)}"
    return

  _doWrite: (a, words) ->
    a.writes += 1
    modeWord = if words.length == RESET_WORDS then words[0] else words[3]
    m = unpackMode(modeWord)

    unless m.name of MODE
      @_log "accumulator #{a.num} write, mode #{m.mode} undefined"
      return

    if isReset(m.mode)
      if isGmt(m.mode) then @_setGmt(a, RESET_GMT_MS) else @_setMet(a, RESET_MET_MS)
      @_clearPending(a)
      @_log "accumulator #{a.num} #{m.name}"
      return

    return if words.length != UPDATE_WORDS
    @_schedule a, m, unpackTimeMs(words)
    return


  _clearPending: (a) ->
    clearTimeout a.timer if a.timer?
    a.timer = null
    a.pending = null
    return

  # The update takes effect when the accumulator's minutes field next
  # reads the coincidence minute, at zero seconds.
  _schedule: (a, m, timeMs) ->
    @_clearPending(a)
    cur   = if isGmt(m.mode) then @gmtOf(a) else @metOf(a)
    delta = (m.coincidence * MS_PER_MINUTE) - (cur % MS_PER_HOUR)
    delta += MS_PER_HOUR if delta <= 0
    a.pending = {mode: m.mode, timeMs, coincidence: m.coincidence}
    a.timer = setTimeout call(@, '_applyPending', a), delta
    a.timer.unref?()
    @_log "accumulator #{a.num} #{m.name} to #{fmtTime(timeMs)} " +
          "at minute #{m.coincidence}, in #{Math.round(delta)} ms"
    return

  _applyPending: (a) ->
    p = a.pending
    return unless p?
    if isGmt(p.mode) then @_setGmt(a, p.timeMs) else @_setMet(a, p.timeMs)
    a.pending = null
    a.timer = null
    @_log "accumulator #{a.num} update executed, #{fmtTime(p.timeMs)}"
    return

  report: () ->
    accumulators: (for _, a of @accums
      num:     a.num
      mdm:     a.mdm
      bus:     a.busName
      gmt:     fmtTime(@gmtOf(a))
      met:     fmtTime(@metOf(a))
      bite:    fmtBite(@biteOf(a))
      skewMs:  a.skewMs
      answers: a.answers
      connected: a.connected
      reads:   a.reads
      writes:  a.writes)
    outputs: (for _, o of @outputs
      num:   o.num
      nom:   o.nom
      mdm:   o.mdm
      bus:   o.busName
      reads: o.reads)
    oscillator:   @oscillator
    rolloverDays: @rolloverDays
