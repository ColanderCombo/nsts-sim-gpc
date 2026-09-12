import {call, setTimeout, setInterval, clearTimeout, clearInterval} from '../../com/simRuntime.coffee'
# MEDS Analog to Digital Converter
#
# One process serves four 1553B remote terminals. Each samples 32 inputs
# into a double buffer every 40 ms. Formats are in adcConf.coffee; MDM and
# signal-conditioner routes are in adcChannels.coffee.

import {busConfig} from './../../com/bus.civet.jsx'
import {LRU} from './../../com/lru.civet.jsx'
import {MDM_CATALOG} from './../mdm/mdmConfig'
import {IOM, IO_OP, IO_ALL, ioBusName, encodeIO, decodeIO,
        wordToVolts as aiWordToVolts, aodWordToVolts} from './../mdm/mdmConf'
import {tapsOfPair} from './adcChannels'
import {CHANNELS, SAMPLE_MS, UNITS, pairOf, rtAddressOf, idpBussesOf, analogBusOf,
        TR_TRANSMIT, TR_RECEIVE, STATUS, SA, STATUS_BLOCK_WORDS, STATUS_BLOCK,
        CST_STATE, COMMAND, SOFTWARE_VERSION, BITE, CST, CST_DURATION_MS,
        voltsToWord, biasVoltsOf,
        encodeRT, decode1553, fmt1553,
        ANALOG_OP, ANALOG_ALL, encodeAnalog, decodeAnalog} from './adcConf'

export class ADC extends LRU
  constructor: (opts = {}) ->
    units = opts.units ? UNITS
    for u in units
      throw new Error("no such adc unit: #{u}") unless u in UNITS
    busses = []
    for u in units
      for b in idpBussesOf(u).concat([analogBusOf(u)])
        busses.push b unless b in busses
    # The MDM cards carrying the pairs' signals, by hardware side bus:
    # {bus: [{pair, channel, card, chan, out}]}.  A tap on a card the
    # catalog does not hold as analog is dropped.
    taps = {}
    for pair in [1, 2] when units.some((u) -> pairOf(u) == pair)
      for mdm, list of tapsOfPair(pair)
        cat = MDM_CATALOG[mdm]
        continue unless cat?
        for tp in list
          type = IOM[cat.iom[tp.card]]
          continue unless type?.kind == 'analog'
          bus = ioBusName(mdm)
          (taps[bus] ?= []).push {pair, channel: tp.channel, card: tp.card, chan: tp.chan, out: type.dir == 'out', mdm}
    busses.push b for b of taps when b not in busses
    # "ADC 1A and 2A are powered by main A via a single circuit breaker on
    # panel R15, while 1B and 2B are powered by main B via a single
    # circuit breaker on panel R15" (USA-007587 sect.2.6), which is
    # medsConf's `powerBus` for each unit: the letter in a unit's name is
    # the main bus it is on.
    super({id: 'ADC', busses,
           power: (opts.power ? [{name: 'A', feed: 'MNA'}, {name: 'B', feed: 'MNB'}]),
           verbose: opts.verbose, onEvent: opts.onEvent})
    @taps = taps
    @tapHeard = 0

    @sampleMs = opts.sampleMs ? SAMPLE_MS
    @cstMs = opts.cstMs ? CST_DURATION_MS
    @replyDelayMs = opts.replyDelayMs ? 0

    # The signals on each pair's inputs, in volts.
    @analog = {}
    @units = {}
    for u in units
      pair = pairOf(u)
      @analog[pair] ?= new Float64Array(CHANNELS)
      @units[u] = {
        id:        u
        pair:      pair
        rt:        rtAddressOf(u)
        busNames:  idpBussesOf(u)
        analogBus: analogBusOf(u)
        front:     new Uint16Array(CHANNELS)
        back:      new Uint16Array(CHANNELS)
        samples:   0
        bite:      0
        cst:       0
        cstState:  CST_STATE.NONE
        cstInject: 0            # the result the next self-test reports
        cstTimer:  null
        # A silent unit hears its commands and says nothing.
        answers:   true
        polls:     0
        replies:   0
        commands:  0
      }

    for name, bus of @bus
      bus.onReceive @_onBusMessage, @

    @_timer = setInterval call(@, '_sample'), @sampleMs
    @_timer.unref?()
    @_sample()
    @ready().then => @_requestAnalogs()


  setAnalog: (pair, channel, volts) ->
    a = @analog[pair]
    throw new Error("no unit of pair #{pair} is running") unless a?
    if channel == ANALOG_ALL
      a[i] = volts[i] ? 0 for i in [0...CHANNELS] by 1
    else
      a[channel] = volts
    return

  _requestAnalogs: () ->
    sent = {}
    for _, u of @units when not sent[u.analogBus]
      sent[u.analogBus] = true
      @send @bus[u.analogBus], encodeAnalog(ANALOG_OP.REQUEST, ANALOG_ALL)
    for bus, list of @taps
      cards = {}
      cards[tp.card] = true for tp in list
      for card of cards
        @send @bus[bus], Array.from(encodeIO {op: IO_OP.REQUEST, card: parseInt(card, 10), channel: IO_ALL, words: []})
    return

  _sample: () ->
    for _, u of @units when @unitPowered(u)
      a = @analog[u.pair]
      testing = u.cstState == CST_STATE.RUNNING
      for i in [0...CHANNELS] by 1
        u.back[i] = voltsToWord(if testing then biasVoltsOf(i) else a[i])
      [u.front, u.back] = [u.back, u.front]
      u.samples = (u.samples + 1) & 0xffff
    return

  unitPowered: (u) -> @power.named(u.id.slice(-1))?.live() ? true

  onVoltage: (input) ->
    @sideLive ?= {}
    live = input.live()
    return if @sideLive[input.name] == live
    @sideLive[input.name] = live
    if live
      @reset(u) for _, u of @units when u.id.endsWith(input.name)
    @_log "MN #{input.name} #{if live then 'on' else 'off'}"
    return


  _unit: (id) ->
    u = @units[id]
    throw new Error("adc unit #{id} is not running") unless u
    u

  setAnswers: (id, on_) ->
    @_unit(id).answers = !!on_
    return

  setBite: (id, word) ->
    @_unit(id).bite = word & 0xffff
    return

  setCstResult: (id, word) ->
    @_unit(id).cstInject = word & 0xffff
    return


  statusFlags: (u) ->
    f = 0
    f |= STATUS.BUSY if u.cstState == CST_STATE.RUNNING
    f |= STATUS.SUBSYSTEM_FLAG if u.bite
    f

  statusBlock: (u) ->
    w = new Array(STATUS_BLOCK_WORDS).fill(0)
    w[STATUS_BLOCK.BITE] = u.bite
    w[STATUS_BLOCK.CST] = u.cst
    w[STATUS_BLOCK.CST_STATE] = u.cstState
    w[STATUS_BLOCK.SAMPLES] = u.samples
    w[STATUS_BLOCK.VERSION] = SOFTWARE_VERSION
    w


  startCst: (u) ->
    return if u.cstState == CST_STATE.RUNNING
    u.cstState = CST_STATE.RUNNING
    u.cstTimer = setTimeout call(@, '_finishCst', u), @cstMs
    u.cstTimer.unref?()
    @_log "#{u.id} CST started"
    return

  _finishCst: (u) ->
    u.cstTimer = null
    u.cst = u.cstInject
    u.cstState = CST_STATE.DONE
    refBits = CST.REF_M5V6 | CST.REF_M2V0 | CST.REF_0V | CST.REF_P2V0 | CST.REF_P5V6
    u.bite |= BITE.REFERENCE if u.cst & refBits
    u.bite |= BITE.PROM_CHECKSUM if u.cst & CST.PROM
    u.bite |= BITE.SRAM_SCRUB if u.cst & CST.SRAM
    @_log "#{u.id} CST done, result #{u.cst.toString(16).padStart(4, '0')}"
    return

  reset: (u) ->
    clearTimeout u.cstTimer if u.cstTimer?
    u.cstTimer = null
    u.cstState = CST_STATE.NONE
    u.cst = 0
    u.bite = 0
    u.samples = 0
    @_log "#{u.id} reset"
    return


  _onBusMessage: (self, busID, msg) ->
    if self.taps[busID]?
      self._onTap(busID, msg)
    else if /_analogs$/.test(busID)
      self._onAnalog(busID, msg)
    else
      self._on1553(busID, msg)
    return

  _onTap: (busID, msg) ->
    m = decodeIO(msg.data16)
    return unless m? and m.op == IO_OP.VALUE
    first = if m.channel == IO_ALL then 0 else m.channel
    for tp in @taps[busID] when tp.card == m.card
      i = tp.chan - first
      continue unless 0 <= i < m.words.length
      v = if tp.out then aodWordToVolts(m.words[i]) else aiWordToVolts(m.words[i])
      @setAnalog tp.pair, tp.channel, v
      @tapHeard += 1
    return

  _onAnalog: (busID, msg) ->
    m = decodeAnalog(msg.data16)
    return unless m? and m.op == ANALOG_OP.VALUE
    for _, u of @units when u.analogBus == busID
      if m.channel == ANALOG_ALL
        @setAnalog u.pair, ANALOG_ALL, m.volts
      else if m.channel < CHANNELS and m.volts.length
        @setAnalog u.pair, m.channel, m.volts[0]
      break
    return

  _on1553: (busID, msg) ->
    m = decode1553(msg.data16)
    return unless m?.kind == 'command'
    for _, u of @units when u.rt == m.rt and busID in u.busNames
      @_command(u, busID, m)
    return

  _command: (u, busID, m) ->
    return unless @unitPowered(u)
    u.polls += 1
    unless u.answers
      @_log "#{u.id} #{fmt1553 m} on #{busID}, silent"
      return
    flags = @statusFlags(u)
    data = []
    if m.tr == TR_TRANSMIT and m.sa == SA.SAMPLES
      data = Array.from(u.front.subarray(0, m.wc))
    else if m.tr == TR_TRANSMIT and m.sa == SA.STATUS
      data = @statusBlock(u).concat(new Array(Math.max(0, m.wc - STATUS_BLOCK_WORDS)).fill(0)).slice(0, m.wc)
    else if m.tr == TR_RECEIVE and m.sa == SA.COMMAND
      u.commands += 1
      switch m.data[0]
        when COMMAND.START_CST then @startCst(u)
        when COMMAND.RESET then @reset(u)
        else flags |= STATUS.MESSAGE_ERROR
      flags = @statusFlags(u) | (flags & STATUS.MESSAGE_ERROR)
    else
      flags |= STATUS.MESSAGE_ERROR
    u.replies += 1
    @send @bus[busID], encodeRT(u.rt, flags, data), @replyDelayMs
    @_log "#{u.id} #{fmt1553 m} on #{busID}, answered #{data.length} words" if m.sa != SA.SAMPLES or @verbose
    return

  onStop: () ->
    clearInterval @_timer if @_timer?
    @_timer = null
    for _, u of @units when u.cstTimer?
      clearTimeout u.cstTimer
      u.cstTimer = null
    return

  describe: () ->
    for _, u of @units
      ports = (busConfig[b].port for b in u.busNames).join('/')
      "ADC #{u.id} on #{u.busNames.join(' ')} (ports #{ports}), RT #{u.rt}, " +
      "inputs on #{u.analogBus} (port #{busConfig[u.analogBus].port})" +
      "#{if u.answers then '' else ', silent'}" +
      "#{if u.bite then ", BITE #{hex4 u.bite}" else ''}"

  report: () ->
    taps: (for bus, list of @taps
      bus: bus
      channels: ("#{tp.mdm} #{tp.card}/#{tp.chan} -> pair #{tp.pair} ch #{tp.channel}" for tp in list))
    tapHeard: @tapHeard
    units: (for _, u of @units
      id:       u.id
      pair:     u.pair
      rt:       u.rt
      busses:   u.busNames
      analogs:  u.analogBus
      samples:  u.samples
      bite:     u.bite
      cst:      u.cst
      cstState: u.cstState
      answers:  u.answers
      polls:    u.polls
      replies:  u.replies
      commands: u.commands)

hex4 = (v) -> (v & 0xffff).toString(16).padStart(4, '0')
