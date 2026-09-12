# Inertial Measurement Unit implementation
#
# Three HAINS units attach to forward MDM serial I/O card 3, channel 0.
# Formats and wiring are in imuConf.coffee (JSC-12843 Rev. J, SCP 1.3 and 2.2).
#
#   POLL   the GPC is reading.  Answered with VALUE of as many of the
#          sixteen data words as requested
#   VALUE  the GPC has written.  Two words are the torque and slew
#          commands, echoed in data words 13 and 14
#   CONNECT, DISCONNECT   sent by the unit: it is on the channel, or
#          unplugged from it
#
# Data words 2 to 12, 15 and 16 read zero: the platform resolver angles,
# accelerometer counts, and redundant-axis rate are not modeled.

import {busConfig} from './../../com/bus.civet.jsx'
import {LRU} from './../../com/lru.civet.jsx'
import {IO_OP, IO_ALL, ioBusName, encodeIO, decodeIO} from './../mdm/mdmConf'
import {UNIT_MDM, UNIT_FEED, CARD, CHANNEL, CARD_TYPE,
        OUT_WORDS, CMD_WORDS, ECHO_WORD,
        NOMINAL_STATUS, STATUS, fmtStatus, fmtSlew, torques} from './imuConf'

export class IMU extends LRU
  constructor: (opts = {}) ->
    units = opts.units ? [1, 2, 3]
    for n in units
      throw new Error("no such imu: #{n}") unless UNIT_MDM[n]
    busName = (n) -> ioBusName(opts.mdm?[n] ? UNIT_MDM[n])
    busses = (busName(n) for n in units)
    # The entry LRUs hang on the main buses (JSC-12843 SCP 4.4, "cb MNA,
    # B, C"); each unit takes the bus of its own number.
    power = opts.power ? ({name: String(n), feed: UNIT_FEED[n]} for n in units)
    super({id: 'IMU', busses, power, powerRule: 'any',
           verbose: opts.verbose, onEvent: opts.onEvent})

    # How long a unit takes to answer a poll.
    @replyDelayMs = opts.replyDelayMs ? 0

    @units = {}
    for n in units
      @units[n] = u = {
        num:       n
        mdm:       opts.mdm?[n] ? UNIT_MDM[n]
        feed:      UNIT_FEED[n]
        busName:   busName(n)
        bus:       @bus[busName(n)]
        # The sixteen data words, one indexed off by one from the
        # document's numbering.
        out:       new Array(OUT_WORDS).fill(0)
        answers:   true
        connected: true
        # Failures injected into the mode status word.
        fault:     0
        cmd:       [0, 0]
        # Whether the unit's feed was live at the last voltage report.
        live:      true
        reads:     0
        writes:    0
      }
      @_refresh u
      u.bus.onReceive @_onBusMessage, @

    @ready().then => @_announce()

  statusOf: (u) -> ((NOMINAL_STATUS | u.fault) & 0xffff)

  _refresh: (u) ->
    u.out[0] = @statusOf(u)
    u.out[ECHO_WORD[1] - 1] = u.cmd[0]
    u.out[ECHO_WORD[2] - 1] = u.cmd[1]
    return

  unit: (n) ->
    u = @units[n]
    throw new Error("imu #{n} is not running") unless u
    u

  setFault: (n, bits, on_ = true) ->
    u = @unit(n)
    u.fault = if on_ then (u.fault | bits) else (u.fault & ~bits)
    u.fault &= 0xffff
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
      if on_
        u.cmd = [0, 0]
        @_refresh u
      @_sendLink u.bus, on_ and u.connected
      @_log "IMU #{u.num} power #{if on_ then 'on' else 'off'} (#{u.feed})"
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
    switch m.op
      when IO_OP.POLL  then self._doRead(u, m.count)
      when IO_OP.VALUE then self._doWrite(u, m.words) if m.words.length == CMD_WORDS
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
      @_log "IMU #{u.num} polled, silent"
      return
    n = Math.min(count ? OUT_WORDS, OUT_WORDS)
    @_send u.bus, u.out.slice(0, n)
    @_log "IMU #{u.num} read #{n} words, status #{hex4 @statusOf(u)} (#{fmtStatus @statusOf(u)})"
    return

  _doWrite: (u, words) ->
    u.writes += 1
    u.cmd = [words[0] & 0xffff, words[1] & 0xffff]
    @_refresh u
    [tx, ty, tz] = torques(u.cmd[0])
    @_log "IMU #{u.num} command torque #{tx}/#{ty}/#{tz} arcsec, " +
          "slew #{hex4 u.cmd[1]} (#{fmtSlew u.cmd[1]})"
    return


  onStop: () -> @_announce(false)

  describe: () ->
    for _, u of @units
      "IMU #{u.num} on #{u.busName} (port #{busConfig[u.busName].port}), " +
      "MDM #{u.mdm} card #{CARD} channel #{CHANNEL}, #{u.feed}, " +
      "status #{hex4 @statusOf(u)}" +
      "#{if u.answers then '' else ', silent'}" +
      "#{if u.connected then '' else ', disconnected'}"

  report: () ->
    units: for _, u of @units
      {
        num:       u.num
        mdm:       u.mdm
        bus:       u.busName
        status:    hex4 @statusOf(u)
        bites:     fmtStatus(@statusOf(u) & ~NOMINAL_STATUS)
        echo:      (hex4 w for w in u.cmd)
        powered:   @unitPowered(u)
        answers:   u.answers
        connected: u.connected
        reads:     u.reads
        writes:    u.writes
      }

hex4 = (v) -> (v & 0xffff).toString(16).padStart(4, '0')
