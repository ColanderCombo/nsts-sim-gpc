import {call, setTimeout, clearTimeout, now as simNow} from '../../com/simRuntime.coffee'
# Network Signal Processor implementation
#
# JSC-18611,Rev.G SB 3 sect.3.6.2 and SB 12; the interface constants and
# the document references are in nspConf.coffee.
#
# The NSP is the command path from the ground: it bit and frame
# synchronizes the forward link, takes the command word out of each
# frame, checks its BCH parity, stores it in a ten-command double buffer
# and hands the buffer to the GPC through a serial I/O channel of MDM FF1
# (NSP 1) or FF3 (NSP 2).  Two units are installed and one is powered.
# One process carries both units and the panel C3 UPLINK switch:
#
#   _SBAND_FWD          the transponder's bit stream, heard by both units
#   _FF1_mdmIO          NSP 1: card 11 channel 3 serial, card 9 channel 1
#                       power discrete, card 4 channel 0 block discrete A
#   _FF3_mdmIO          NSP 2: the same with card 12 for the power
#                       discrete and block discrete B
#
# On the MDM side (lru/mdm/mdmConf.coffee):
#
#   POLL       the GPC is reading card 11 channel 3.  Answered with VALUE
#              of the 32-word message, or of the status word alone with
#              the UPLINK switch at NSP BLOCK.
#   CONNECT, DISCONNECT   a powered unit is on its channel; an unpowered
#              one is off it and the MDM's serial card hears nothing.
#   SET, RESET the power discrete follows the unit's power; the block
#              discretes follow the switch.
#
# FRAME SYNC (sect.12.3.3.2)
#
# The last 24 bits received are correlated with the sync pattern: three
# errors or fewer is a positive correlation, 21 or more a negative one
# and the data is inverted from then on.  In search the correlator runs
# bit by bit; the first correlation starts acquisition, a second one a
# frame later gives lock and bracket data status.  In lock a correlation
# is expected every frame; a miss drops bracket data status for that
# frame, three consecutive misses lose lock and return to search.  A
# frame's command is transferred only when the sync patterns on both
# sides of it correlated.  Bit sync is the presence of the stream: it is
# lost when no datagram has arrived for BIT_SYNC_HOLD_MS, and frame sync
# with it.
#
# THE DOUBLE BUFFER (sect.3.6.2.1, 12.3.3.6)
#
# Each frame's command goes into the next of the ten slots of the fill
# buffer; after the tenth the buffers switch and data ready is set if a
# command in the completed buffer passed.  A poll answers with the
# completed buffer and clears data ready; a second poll of the same
# buffer, or one in the last frame time before the switch, gets the
# status word and 31 zeros.  The status word is held from the moment
# data ready is set until the poll that reads it.
#

import {busConfig} from './../../com/bus.civet.jsx'
import {LRU} from './../../com/lru.civet.jsx'
import {IO_OP, IO_ALL, ioBusName, encodeIO, decodeIO} from './../mdm/mdmConf'
import {UNIT, CARD, CHANNEL, CARD_TYPE, POWER_CHANNEL, POWER_BIT, BLOCK_CHANNEL, BLOCK_BIT,
        DISCRETE_TYPE, FWD_LINK_BUS, MESSAGE_WORDS, COMMANDS, COMMAND_WORDS, UPLINK_SWITCH
        STATUS, MODE_PARITY, validityBit, fmtStatus, fmtCommand, hex4
        RATE, FRAME_SYNC, FRAME_SYNC_BITS, wordToBits, frameUplinkBits, decodeUplinkWord
        SYNC_CORRELATE, SYNC_ANTI, syncDistance, unpackStream} from './nspConf'

now = () -> simNow()

BIT_SYNC_HOLD_MS   = 200
LOCK_LOSS_MISSES   = 3
# The last 20 ms of the 200 ms fill: one frame time.
INHIBIT_FRAMES     = 1

newBuffer = () ->
  words: ((0 for [0...COMMAND_WORDS] by 1) for [0...COMMANDS] by 1)
  valid: (false for [0...COMMANDS] by 1)

# The frame synchronizer and demultiplexer for one stream.  `onFrame`
# gets the bits of every frame bracketed by two correlations.
export class FrameSync
  constructor: (@rate, @onFrame) ->
    @reset()

  reset: () ->
    @state    = 'SEARCH'
    @window   = 0
    @invert   = false
    @frame    = []
    @left     = 0
    @misses   = 0
    @bds      = false
    @opened   = false
    @bits     = 0
    @frames   = 0
    @losses   = 0
    return

  locked: () -> @state == 'LOCK'

  feed: (bits) ->
    @_bit(b) for b in bits
    return

  _bit: (b) ->
    b ^= 1 if @invert
    @window = ((@window << 1) | (b & 1)) & 0xffffff
    @bits += 1
    if @state == 'SEARCH'
      d = syncDistance(@window)
      if d >= SYNC_ANTI
        @invert = not @invert
        @window = (~@window) & 0xffffff
        d = syncDistance(@window)
      if d <= SYNC_CORRELATE
        @state = 'ACQ'
        @opened = true
        @_expect()
      return
    @frame.push b
    @left -= 1
    return if @left > 0
    # A frame of bits since the last sync: the window holds the next.
    # The frame is delivered when the sync on each side of it correlated.
    correlated = syncDistance(@window) <= SYNC_CORRELATE
    body = @frame.slice(0, @rate.frameBits - FRAME_SYNC_BITS)
    if correlated
      @state  = 'LOCK'
      @misses = 0
      @bds    = true
      if @opened
        @frames += 1
        @onFrame? wordToBits(FRAME_SYNC, FRAME_SYNC_BITS).concat(body)
    else if @state == 'ACQ'
      @state = 'SEARCH'
      @bds = false
      return
    else
      @misses += 1
      @bds = false
      if @misses >= LOCK_LOSS_MISSES
        @losses += 1
        @state = 'SEARCH'
        return
    @opened = correlated
    @_expect()
    return

  _expect: () ->
    @frame = []
    @left  = @rate.frameBits
    return

export class NSP extends LRU
  constructor: (opts = {}) ->
    units = opts.units ? [1, 2]
    for n in units
      throw new Error("no such NSP: #{n}") unless UNIT[n]
    busses = [FWD_LINK_BUS, ioBusName(UNIT[1].mdm), ioBusName(UNIT[2].mdm)]
    # A feed a unit: the switch below is the crew's, and the feed says
    # whether there is anything behind it.
    super({id: 'NSP', busses,
           power: (opts.powerFeeds ?
                   ({name: "#{n}", feed: "NSP#{n}"} for n in units)),
           verbose: opts.verbose, onEvent: opts.onEvent})

    @rate = RATE[opts.rate ? 'LDR']
    throw new Error("no such data rate: #{opts.rate}") unless @rate?
    # The receive mode, for the mode parity bits.
    @mode = opts.mode ? 'STDN_LO'
    throw new Error("no such receive mode: #{@mode}") unless MODE_PARITY[@mode]?
    @external = !!opts.external
    @uplinkSwitch = 'ENABLE'
    @replyDelayMs = opts.replyDelayMs ? 0

    powered = opts.powered ? [1]
    @units = {}
    for n in units
      @units[n] = u = {
        num:       n
        mdm:       UNIT[n].mdm
        busName:   ioBusName(UNIT[n].mdm)
        bus:       @bus[ioBusName(UNIT[n].mdm)]
        powered:   powered.includes(n)
        sync:      null
        bitSync:   false
        bitSyncTimer: null
        fill:      newBuffer()
        read:      newBuffer()
        fillCount: 0
        dataReady: false
        polled:    false
        held:      null
        bchValid:  false
        bchInvalid: false
        # BITE bits injected from outside.
        bite:      0
        stats:     {datagrams: 0, frames: 0, commands: 0, valid: 0, failed: 0, polls: 0, answers: 0}
      }
      u.sync = @_frameSync(u)

    for name, b of @bus
      b.onReceive @_onBusMessage, @
    @setUplinkSwitch(opts.uplinkSwitch ? 'ENABLE')

    @ready().then => @_announce()

  _frameSync: (u) -> new FrameSync(@rate, (bits) => @_onFrame(u, bits))


  setPower: (n, on_) ->
    u = @units[n]
    throw new Error("NSP #{n} is not running") unless u
    @switchAt ?= {}
    @switchAt[n] = !!on_
    @_applyPower()
    return

  _applyPower: () ->
    for _, u of @units
      want = @switchAt?[u.num] ? u.powered
      on_ = want and (@power.named("#{u.num}")?.live() ? true)
      continue if u.powered == on_
      u.powered = on_
      @_powerUp(u) if on_
      @_announceUnit(u)
      @_log "NSP #{u.num} power #{if on_ then 'on' else 'off'}"
    return

  onVoltage: (input) ->
    @_applyPower()
    return

  _powerUp: (u) ->
    u.sync.reset()
    u.fill = newBuffer()
    u.read = newBuffer()
    u.fillCount = 0
    u.dataReady = false
    u.polled = false
    u.held = null
    u.bchValid = u.bchInvalid = false
    return

  setUplinkSwitch: (pos) ->
    pos = String(pos).toUpperCase().replace(/[ -]/g, '_')
    throw new Error("invalid UPLINK position '#{pos}'") unless pos in UPLINK_SWITCH
    @uplinkSwitch = pos
    @_sendBlockDiscretes()
    return

  setBite: (n, bits) ->
    u = @units[n]
    throw new Error("NSP #{n} is not running") unless u
    u.bite = bits & 0xffff
    return

  statusOf: (u) ->
    s = u.bite
    s |= STATUS.DATA_READY if u.dataReady
    s |= STATUS.DATA_INHIBIT if @uplinkSwitch == 'NSP_BLOCK'
    s |= STATUS.BIT_SYNC_LOSS | STATUS.BIT_SYNC_QUAL unless u.bitSync
    s |= STATUS.FRAME_SYNC_LOSS unless u.sync.locked()
    s |= STATUS.BRACKET_LOSS unless u.sync.bds
    s |= STATUS.INTERNAL_MODE unless @external
    s |= STATUS.BCH_VALID if u.bchValid
    s |= STATUS.BCH_INVALID if u.bchInvalid
    s |= if MODE_PARITY[@mode] then STATUS.MODE_PARITY_EVEN else STATUS.MODE_PARITY_ODD
    s & 0xffff

  messageOf: (u) ->
    words = []
    words = words.concat(w) for w in u.read.words
    v = 0
    v |= validityBit(i) for i in [0...COMMANDS] by 1 when u.read.valid[i]
    words.concat([v])

  onStop: () ->
    for _, u of @units
      clearTimeout u.bitSyncTimer if u.bitSyncTimer?
      u.bitSyncTimer = null
      u.powered = false
      @_announceUnit(u)
    return

  describe: () ->
    lines = for _, u of @units
      "NSP #{u.num} on #{u.busName} (port #{busConfig[u.busName].port}), " +
      "MDM #{u.mdm} card #{CARD} channel #{CHANNEL}, " +
      "power discrete card #{UNIT[u.num].powerCard} channel #{POWER_CHANNEL}" +
      "#{if u.powered then ', powered' else ', off'}"
    lines.push "forward link on #{FWD_LINK_BUS} (port #{busConfig[FWD_LINK_BUS].port}), " +
               "#{@rate.name} #{@rate.bps / 1000} kbps, #{@mode}, " +
               "UPLINK switch #{@uplinkSwitch}"
    lines


  _onStream: (bits) ->
    for _, u of @units when u.powered
      u.stats.datagrams += 1
      @_bitSync(u)
      u.sync.feed bits
    return

  _bitSync: (u) ->
    unless u.bitSync
      u.bitSync = true
      @_log "NSP #{u.num} bit sync"
    clearTimeout u.bitSyncTimer if u.bitSyncTimer?
    u.bitSyncTimer = setTimeout call(@, '_bitSyncLost', u), BIT_SYNC_HOLD_MS
    u.bitSyncTimer.unref?()
    return

  _bitSyncLost: (u) ->
    u.bitSyncTimer = null
    u.bitSync = false
    u.sync.losses += 1 if u.sync.locked()
    u.sync.reset()
    @_log "NSP #{u.num} bit sync lost"
    return

  _onFrame: (u, frameBits) ->
    u.stats.frames += 1
    {words, ok} = decodeUplinkWord(frameUplinkBits(@rate, frameBits))
    valid = ok and (words[0] & 0xe000) != 0
    if not ok
      u.bchInvalid = true
      u.stats.failed += 1
      @_log "NSP #{u.num} command failed BCH: #{(hex4 w for w in words).join(' ')}"
    else if valid
      u.bchValid = true
      u.stats.valid += 1
      @_log "NSP #{u.num} command: #{fmtCommand words}"
    u.stats.commands += 1 if ok and (words.some (w) -> w != 0)
    slot = u.fillCount
    u.fill.words[slot] = words
    u.fill.valid[slot] = valid
    u.fillCount += 1
    @_switchBuffers(u) if u.fillCount >= COMMANDS
    return

  _switchBuffers: (u) ->
    u.read = u.fill
    u.fill = newBuffer()
    u.fillCount = 0
    u.dataReady = u.read.valid.some((v) -> v)
    u.polled = false
    u.held = if u.dataReady then @statusOf(u) else null
    @_log "NSP #{u.num} buffer switch, data ready #{u.dataReady}" if u.dataReady
    return


  _onBusMessage: (self, busID, msg) ->
    if busID == FWD_LINK_BUS
      self._onStream unpackStream(msg.data16)
      return
    m = decodeIO(msg.data16)
    return unless m?
    u = self._unitOn(busID)
    if m.op == IO_OP.REQUEST
      self._answerRequest(busID, u, m)
      return
    return unless u? and m.op == IO_OP.POLL
    return if m.type and m.type != CARD_TYPE
    return unless m.card == CARD and m.channel == CHANNEL
    self._doRead(u)
    return

  _unitOn: (busID) ->
    for _, u of @units
      return u if u.busName == busID
    null

  _answerRequest: (busID, u, m) ->
    names = (card, channel) ->
      (m.card == IO_ALL or m.card == card) and (m.channel == IO_ALL or m.channel == channel)
    if u?
      @_sendLink u, true if u.powered and names(CARD, CHANNEL)
      @_sendDiscrete u.bus, UNIT[u.num].powerCard, POWER_CHANNEL, POWER_BIT, u.powered if names(UNIT[u.num].powerCard, POWER_CHANNEL)
    n = if busID == ioBusName(UNIT[1].mdm) then 1 else 2
    if names(UNIT[n].blockCard, BLOCK_CHANNEL)
      @_sendDiscrete @bus[busID], UNIT[n].blockCard, BLOCK_CHANNEL, BLOCK_BIT, @uplinkSwitch == 'GPC_BLOCK'
    return

  _announce: () ->
    @_announceUnit(u) for _, u of @units
    @_sendBlockDiscretes()
    return

  _announceUnit: (u) ->
    @_sendLink u, u.powered
    @_sendDiscrete u.bus, UNIT[u.num].powerCard, POWER_CHANNEL, POWER_BIT, u.powered
    return

  _sendBlockDiscretes: () ->
    for n in [1, 2]
      b = @bus[ioBusName(UNIT[n].mdm)]
      @_sendDiscrete b, UNIT[n].blockCard, BLOCK_CHANNEL, BLOCK_BIT, @uplinkSwitch == 'GPC_BLOCK'
    return

  _sendLink: (u, on_) ->
    op = if on_ then IO_OP.CONNECT else IO_OP.DISCONNECT
    @_publish u.bus, {op, type: CARD_TYPE, card: CARD, channel: CHANNEL, words: []}
    return

  _sendDiscrete: (bus, card, channel, mask, on_) ->
    op = if on_ then IO_OP.SET else IO_OP.RESET
    @_publish bus, {op, type: DISCRETE_TYPE, card, channel, words: [mask]}
    return

  _publish: (bus, fields) ->
    @send bus, encodeIO(fields)
    return

  _send: (u, words) ->
    @send u.bus,
          encodeIO({op: IO_OP.VALUE, type: CARD_TYPE, card: CARD, channel: CHANNEL, words}),
          @replyDelayMs
    return

  _doRead: (u) ->
    u.stats.polls += 1
    return unless u.powered
    status = u.held ? @statusOf(u)
    if @uplinkSwitch == 'NSP_BLOCK'
      words = [status]
    else
      inhibit = u.polled or (u.sync.locked() and u.fillCount >= COMMANDS - INHIBIT_FRAMES)
      if u.dataReady and not inhibit
        words = [status].concat(@messageOf(u))
      else
        words = [status & ~STATUS.DATA_READY].concat(0 for [1...MESSAGE_WORDS] by 1)
    u.polled = true
    u.dataReady = false
    u.held = null
    u.bchValid = u.bchInvalid = false
    u.stats.answers += 1
    @_send u, words
    @_log "NSP #{u.num} polled: #{fmtStatus status}#{if words.length > 1 and words[1..].some((w) -> w) then ', commands' else ''}"
    return

  report: () ->
    units: (for _, u of @units
      num:       u.num
      mdm:       u.mdm
      bus:       u.busName
      powered:   u.powered
      bitSync:   u.bitSync
      frameSync: u.sync.state
      status:    fmtStatus(@statusOf(u))
      dataReady: u.dataReady
      fillCount: u.fillCount
      stats:     u.stats)
    rate:         @rate.name
    mode:         @mode
    uplinkSwitch: @uplinkSwitch
