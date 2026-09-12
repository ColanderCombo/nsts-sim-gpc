# Air Data Transducer Assembly implementation
#
# Four units attach to forward MDM serial I/O card 11, channel 1. Formats
# and wiring are in adtaConf.coffee (JSC-12843 Rev. J, SCP 1.3 and 4.17).
#
#   POLL   the GPC is reading.  Answered with VALUE of as many of the six
#          data words as requested
#   CONNECT, DISCONNECT   sent by the unit: it is on the channel, or
#          unplugged from it
#
# Pressure and temperature conversion is not modeled; those words are zero.

import {busConfig} from './../../com/bus.civet.jsx'
import {LRU} from './../../com/lru.civet.jsx'
import {IO_OP, IO_ALL, ioBusName, encodeIO, decodeIO} from './../mdm/mdmConf'
import {UNIT_MDM, UNIT_FEED, PROBE, CARD, CHANNEL, CARD_TYPE,
        OUT_WORDS, NOMINAL_STATUS, STATUS, fmtStatus} from './adtaConf'

export class ADTA extends LRU
  constructor: (opts = {}) ->
    units = opts.units ? [1, 2, 3, 4]
    for n in units
      throw new Error("no such adta: #{n}") unless UNIT_MDM[n]
    busName = (n) -> ioBusName(opts.mdm?[n] ? UNIT_MDM[n])
    busses = (busName(n) for n in units)
    power = opts.power ? ({name: String(n), feed: UNIT_FEED[n]} for n in units)
    super({id: 'ADTA', busses, power, powerRule: 'any',
           verbose: opts.verbose, onEvent: opts.onEvent})

    # How long a unit takes to answer a poll.
    @replyDelayMs = opts.replyDelayMs ? 0

    @units = {}
    for n in units
      @units[n] = u = {
        num:       n
        mdm:       opts.mdm?[n] ? UNIT_MDM[n]
        probe:     PROBE[n]
        feed:      UNIT_FEED[n]
        busName:   busName(n)
        bus:       @bus[busName(n)]
        # The six data words; word 1 is rebuilt from the state below.
        out:       new Array(OUT_WORDS).fill(0)
        answers:   true
        connected: true
        live:      true
        # Failures injected into the mode status word, and the self test
        # the discrete lines have commanded.
        fault:     0
        selfTest:  null       # null, 'high' or 'low'
        reads:     0
      }
      @_refresh u
      u.bus.onReceive @_onBusMessage, @

    @ready().then => @_announce()

  statusOf: (u) ->
    hw = NOMINAL_STATUS
    hw |= STATUS.HIGH_TEST if u.selfTest == 'high'
    hw |= STATUS.LOW_TEST  if u.selfTest == 'low'
    (hw ^ u.fault) & 0xffff

  _refresh: (u) ->
    u.out[0] = @statusOf(u)
    return

  unit: (n) ->
    u = @units[n]
    throw new Error("adta #{n} is not running") unless u
    u

  setFault: (n, bits, on_ = true) ->
    u = @unit(n)
    u.fault = if on_ then (u.fault | bits) else (u.fault & ~bits)
    u.fault &= 0xffff
    @_refresh u
    return

  setSelfTest: (n, which) ->
    u = @unit(n)
    throw new Error("invalid self test '#{which}'") unless which in [null, 'high', 'low']
    u.selfTest = which
    @_refresh u
    return

  setAnswers: (n, on_) ->
    @unit(n).answers = !!on_
    return

  setConnected: (n, on_) ->
    u = @unit(n)
    u.connected = !!on_
    @_sendLink u.bus, u.connected
    return


  unitPowered: (u) -> @power.named(String(u.num))?.live() ? true

  onVoltage: (input) ->
    for _, u of @units
      on_ = @unitPowered(u)
      continue if on_ == u.live
      u.live = on_
      u.selfTest = null unless on_
      @_refresh u
      @_sendLink u.bus, on_ and u.connected
      @_log "ADTA #{u.num} power #{if on_ then 'on' else 'off'} (#{u.feed})"
    return


  _onBusMessage: (self, busID, msg) ->
    return unless self.powered()
    m = decodeIO(msg.data16)
    return unless m?
    return if m.type and m.type != CARD_TYPE
    u = self._unitOn(busID)
    return unless u?
    if m.op == IO_OP.REQUEST
      names = (m.card == IO_ALL or m.card == CARD) and
              (m.channel == IO_ALL or m.channel == CHANNEL)
      self._sendLink u.bus, true if u.connected and names
      return
    return unless m.card == CARD and m.channel == CHANNEL
    self._doRead(u, m.count) if m.op == IO_OP.POLL
    return

  _unitOn: (busID) ->
    for _, u of @units
      return u if u.busName == busID
    null

  _sendLink: (bus, on_) ->
    op = if on_ then IO_OP.CONNECT else IO_OP.DISCONNECT
    @send bus, encodeIO({op, type: CARD_TYPE, card: CARD, channel: CHANNEL, words: []})
    return

  _send: (bus, words) ->
    @send bus, encodeIO({op: IO_OP.VALUE, type: CARD_TYPE, card: CARD,
                         channel: CHANNEL, words}), @replyDelayMs
    return

  _announce: (on_ = true) ->
    @_sendLink u.bus, on_ for _, u of @units when (u.connected and @unitPowered(u)) or not on_
    return


  _doRead: (u, count) ->
    u.reads += 1
    return unless @unitPowered(u)
    unless u.answers
      @_log "ADTA #{u.num} polled, silent"
      return
    n = Math.min(count ? OUT_WORDS, OUT_WORDS)
    @_send u.bus, u.out.slice(0, n)
    @_log "ADTA #{u.num} read #{n} words, status #{hex4 @statusOf(u)} (#{fmtStatus @statusOf(u)})"
    return


  onStop: () -> @_announce(false)

  describe: () ->
    for _, u of @units
      "ADTA #{u.num} on #{u.busName} (port #{busConfig[u.busName].port}), " +
      "MDM #{u.mdm} card #{CARD} channel #{CHANNEL}, #{u.probe} probe, " +
      "#{u.feed}, status #{hex4 @statusOf(u)}" +
      "#{if u.answers then '' else ', silent'}" +
      "#{if u.connected then '' else ', disconnected'}"

  report: () ->
    units: for _, u of @units
      {
        num:       u.num
        mdm:       u.mdm
        probe:     u.probe
        bus:       u.busName
        status:    hex4 @statusOf(u)
        selfTest:  u.selfTest
        powered:   @unitPowered(u)
        answers:   u.answers
        connected: u.connected
        reads:     u.reads
      }

hex4 = (v) -> (v & 0xffff).toString(16).padStart(4, '0')
