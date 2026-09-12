import {call, setTimeout, setImmediate, clearTimeout} from '../../com/simRuntime.coffee'
# Multiplexer/Demultiplexer implementation
#
# Each catalog unit has two flight busses, sixteen card slots, PROM and BITE
# storage, and a hardware-side bus. Word formats are in mdmConf.coffee.
#
# Commands responded to:
#
#   RETURN_WORD    one word, the card/channel/count fields of the command
#   BSR            one word, the register, which is then cleared
#   INPUT          count words from the card, one per channel from the
#                  channel named; for an SIO card, count serial words from
#                  the device the channel polls, 33.5 us a word after the
#                  command, E set on each when no device is connected or
#                  the one that is does not answer
#   OUTPUT         command only, then count data words from the GPC; a
#                  discrete card's words are set or reset masks by the
#                  high bit of the channel field
#   INDIRECT       the PROM words at the address, count of them, run in
#                  order; all their inputs as one response, or all their
#                  outputs taken from the data words that follow
#   PROM_WORD      one word, the PROM at the address
#   BITE_IOM       two words a channel: for an analog input half the
#                  input plus the reference and then the input, for a
#                  discrete input a test word and its complement, for an
#                  output card the output twice
#   BITE_SCU, BITE_AD, BITE_PS   command only; BSR bit 11 is set
#   LOAD_BSR       command only, then one data word into the register
#   MASTER_RESET   command only; every output to zero, the register cleared
#
# GPC data words have no address and belong to the pending output transfer.
# A new command before completion sets BSR bit 6; excess data sets bit 5.
#
# The EMDM's changes (gate array logic, a per-card power supply, a
# discrete select line to each card, an MIA-to-SCU wraparound test that
# sets BSR bit 2) do not change the command set or the word formats
# (JSC-18611 sect.28.8), so this model stands for either unit.
#

import {BusMsg, busConfig} from './../../com/bus.civet.jsx'
import {LRU} from './../../com/lru.civet.jsx'
import {MODE, BSR, DO_SET_BIT, IO_OP, IO_ALL, SERIAL_ANSWER_MS, SEV, SEV_E_SET, sioReadoutUs,
        PROM_WORDS, PROM_MODE, decodeCommand, decodePromWord, returnWord,
        fmtCommand, fmtPromWord, describeBSR, iomType, cardChannels, ioBusName,
        encodeIO, decodeIO, fmtIO, voltsToWord, wordToVolts,
        BITE_REF_VOLTS, SIO_BITE_WORDS} from './mdmConf'
import {MDM_CATALOG} from './mdmConfig'
import {buildProm} from './prom'

# The test word a discrete input channel reports under IOM BITE, and its
# complement.  A model value: the documents on hand give the words for the
# serial card only.
FAKE_BITE_DI_WORDS = [0xaaaa, 0x5555, 0xf0f0]

export class MDM extends LRU
  constructor: (opts = {}) ->
    id = opts.id ? 'FF1'
    entry = MDM_CATALOG[id]
    throw new Error("no MDM '#{id}' in the catalog") unless entry?
    busPri = opts.busPri ? entry.busPri ? null
    busSec = opts.busSec ? entry.busSec ? null
    ioBus = ioBusName(id)
    busses = (b for b in [busPri, busSec, ioBus] when b?)
    # The unit's own name is its feed: wiring/eps.wir drives one for each
    # MDM its panel O6 switch reaches.
    super({id, busses, power: (opts.power ? id),
           verbose: opts.verbose, onEvent: opts.onEvent})

    @entry        = entry
    @iua          = opts.iua ? entry.iua ? 0
    @busPri       = busPri
    @busSec       = busSec
    @ioBusName    = ioBus
    @replyDelayMs = opts.replyDelayMs ? 0
    @serialAnswerMs = opts.serialAnswerMs ? SERIAL_ANSWER_MS
    @emdm         = opts.emdm ? true

    # A card's `channels` is what it can be addressed by; `wired` is how
    # many of them reach the vehicle (the EMDM's transparent discrete
    # output channels do not).
    @cards = for slot in [0...16] by 1
      t = iomType(entry.iom?[slot])
      continue unless t?
      n = cardChannels(t, entry, @emdm)
      # `link` is whether a device has said CONNECT on each channel.
      {slot, type: t, channels: n, wired: Math.min(n, cardChannels(t, entry, false)),
       words: new Uint16Array(n), rx: [], tx: [], poll: null, link: (false for [0...n] by 1)}
    @cards[i] ?= null for i in [0...16] by 1

    built = buildProm(entry)
    @prom = opts.prom ? built.prom
    @programs = built.programs

    @stats = {commands: 0, wordsIn: 0, wordsOut: 0, invalidWords: 0,
              ioIn: 0, ioOut: 0, ignored: 0, serialErrors: 0}
    @powerUp()

    for name, b of @bus
      b.onReceive @_onBusMessage, @
    # Which devices are on the channels: each connected one answers CONNECT.
    @ready().then => @_publishRaw {op: IO_OP.REQUEST, type: 0, card: IO_ALL, channel: IO_ALL}


  # "the MDM returns the first commanded response data word with an invalid
  # SEV pattern (S-bit cleared to 0), and bit 1 of the BITE Status Register
  # (BSR) is set (power interrupt bit)."
  powerUp: () ->
    @_zeroOutputs()
    @bsr = BSR.POWER_INTERRUPT
    @firstResponse = true
    @pending = null
    @afterOutput = false
    return

  _zeroOutputs: () ->
    for c in @cards when c? and c.type.dir in ['out', 'both']
      c.words.fill 0
      c.tx = []
    return

  _fault: (bit, why) ->
    @bsr |= bit
    @_log "BSR #{describeBSR(bit)}: #{why}"
    return

  logName: () -> "MDM #{@id}"


  # "Turning off power to an MDM resets all the discrete and analog
  # command interfaces to subsystems" (USA-007587 sect.2.6).  A dead unit
  # hears its commands and says nothing, which is what a GPC reads as a
  # transmission error.
  onPowerOff: () ->
    @_zeroOutputs()
    @_log "power off"
    return

  onPowerOn: () ->
    @powerUp()
    @_log "power on"
    return

  _onBusMessage: (self, busID, msg) ->
    return unless self.powered()
    words = msg.data16
    return unless words?.length
    if busID == self.ioBusName
      self._onIO(words)
    else if msg.cmd
      self._onCommand(((words[0] & 0xffff) << 8) | ((words[1] >> 8) & 0xff), busID,
                      {wallUs: msg.wallUs, simUs: msg.simUs})
    else
      self._onDataWord(w & 0xffff, busID) for w in words
    return

  # `clocks` is the commanding computer's wall and simulated clocks off
  # the datagram header, carried to a serial channel's POLL so the device
  # answers with what it held when the computer asked.
  _onCommand: (cmd24, busID, clocks = null) ->
    c = decodeCommand(cmd24)
    if @pending?
      @_fault BSR.NOT_COMPLETED, "command during a #{@pending.expected}-word transfer" if c.iua == @iua
      @pending = null
    @afterOutput = false
    return unless c.iua == @iua
    @stats.commands += 1
    @_log "#{busID} cmd #{fmtCommand(c)}"
    switch c.mode
      when MODE.RETURN_WORD  then @_respond [returnWord(c)], busID
      when MODE.BSR          then @_respondBSR busID
      when MODE.INPUT        then @_directInput c, busID, clocks
      when MODE.OUTPUT       then @_directOutput c, busID
      when MODE.INDIRECT     then @_indirect c, busID, clocks
      when MODE.PROM_WORD    then @_respond [@prom[c.promAddr] & 0xffff], busID
      when MODE.BITE_IOM     then @_biteIOM c, busID
      when MODE.BITE_SCU, MODE.BITE_AD, MODE.BITE_PS
        @bsr |= BSR.BITE_COMPLETE
      when MODE.LOAD_BSR
        @pending = {expected: 1, got: [], done: call(@, '_setBsr')}
      when MODE.MASTER_RESET then @_masterReset()
      else
        @_fault BSR.ILLEGAL_MODE, "mode #{c.mode}"
    return

  _onDataWord: (hw, busID) ->
    p = @pending
    unless p?
      if @afterOutput
        @_fault BSR.TOO_MANY_WORDS, 'data word after the transfer'
        @afterOutput = false
      return
    @stats.wordsIn += 1
    p.got.push hw
    if p.got.length >= p.expected
      @pending = null
      @afterOutput = true
      p.done?(p.got)
    return

# `opts.sev` is one SEV value a word, or null for all valid;
  # `opts.delayUs` is how long after the command the first word is on the
  # bus, in simulated microseconds (com/bus.civet).
  _respond: (words, busID, opts = {}) ->
    b = @bus[busID]
    return unless b?
    unless opts.bsr
      if @firstResponse
        @_log 'first response after power-up: S cleared'
        @stats.invalidWords += 1
      @firstResponse = false
    n = words.length
    sev = opts.sev ? null
    delayUs = opts.delayUs ? 0
    emit = call(@, '_emitResponse', words, busID, delayUs, sev)
    if @replyDelayMs > 0 then setTimeout emit, @replyDelayMs else setImmediate emit
    return

  _emitResponse: (words, busID, delayUs, sev) ->
    @stats.wordsOut += words.length
    m = new BusMsg(words.length)
    m.data16.set(words)
    m.delayUs = delayUs
    m.sev = sev
    @bus[busID].sendMsg m
    return

  _respondBSR: (busID) ->
    w = @bsr
    @bsr = 0
    @_respond [w], busID, {bsr: true}
    return


  # The words a read of `count` channels from `channel` returns.  A channel
  # the card does not have reads as zero with V cleared and BSR bits 3 and
  # 4 set; the single-ended analog card wraps instead.
  _readChannels: (card, channel, count) ->
    out = []
    for i in [0...count] by 1
      ch = channel + i
      ch %= card.channels if card?.type.wrap
      if card? and ch < card.channels
        out.push card.words[ch]
      else
        @_fault BSR.NO_SUCH_CHANNEL | BSR.IOM_TRANSFER, "card #{card?.slot} channel #{ch}"
        @stats.invalidWords += 1
        out.push 0
    out

  # The words a serial channel gives for a read of `count`: whatever the
  # device answers the POLL with, padded with zeros; with no answer, what
  # the channel last received.
  _serialWords: (card, count) ->
    out = []
    for i in [0...count] by 1
      w = card.rx[i]
      unless w?
        @stats.invalidWords += 1
        w = 0
      out.push w & 0xffff
    out

  # A read of a serial channel.  With a device connected, POLL it and
  # wait for its VALUE; with none, the card's decoder hears nothing and
  # every word comes back with E set, at once.  `done` gets the words and
  # whether they are flagged.
  _pollSerial: (card, channel, count, done, clocks = null) ->
    @_endPoll card, false if card.poll?
    unless card.link[channel]
      @stats.serialErrors += count
      done @_serialWords(card, count), true
      return
    timer = setTimeout call(@, '_endPoll', card, false), @serialAnswerMs
    timer.unref?()
    card.poll = {channel, count, done, timer}
    @_publishIO IO_OP.POLL, card, channel, [], count, clocks
    return

  _endPoll: (card, answered) ->
    p = card.poll
    return unless p?
    clearTimeout p.timer
    card.poll = null
    unless answered
      @_log "poll of card #{card.slot} channel #{p.channel} unanswered"
      @stats.serialErrors += p.count
      p.done @_serialWords(card, p.count), true
      return
    # A device answering fewer words than the read leaves the rest with
    # E set: the card's decoder hears no data for them.
    short = p.count - card.rx.length
    @stats.serialErrors += short if short > 0
    flags = if short > 0 then (i >= card.rx.length for i in [0...p.count] by 1) else false
    p.done @_serialWords(card, p.count), flags
    return

  _readInput: (card, channel, count, done, clocks = null) ->
    if card.type.kind == 'serial'
      @_pollSerial card, channel, count, done, clocks
    else
      done @_readChannels(card, channel, count), false
    return

  # The SEV bytes of a response: E set on the flagged words (`flagged` is
  # true for all of them or a boolean a word), or null when every word is
  # valid.
  _sevOf: (n, flagged) ->
    return null unless flagged
    if Array.isArray(flagged)
      return null unless flagged.some((f) -> f)
      ((if flagged[i] then SEV_E_SET else SEV.VALID) for i in [0...n] by 1)
    else
      (SEV_E_SET for [0...n] by 1)

  _directInput: (c, busID, clocks = null) ->
    card = @cards[c.card]
    if not card? or card.type.dir == 'out'
      @_fault BSR.ILLEGAL_MODE, "input from card #{c.card} (#{card?.type.name ? 'empty'})"
      return
    delayUs = if card.type.kind == 'serial' then sioReadoutUs(c.count) else 0
    @_readInput card, c.channel, c.count, call(@, '_directInputDone', busID, delayUs), clocks
    return

  _setBsr: (words) -> @bsr = words[0] & 0xffff

  _directInputDone: (busID, delayUs, words, flagged) ->
    @_respond words, busID, {sev: @_sevOf(words.length, flagged), delayUs}

  _directOutput: (c, busID) ->
    card = @cards[c.card]
    if not card? or card.type.dir == 'in'
      @_fault BSR.ILLEGAL_MODE, "output to card #{c.card} (#{card?.type.name ? 'empty'})"
      @pending = {expected: c.count, got: []}
      return
    @pending = {expected: c.count, got: [], done: call(@, '_applyOutput', card, c.channel)}
    return

  # `channel` is the command's channel field: for a discrete card its high
  # bit says set or reset.
  _applyOutput: (card, channel, words) ->
    switch card.type.kind
      when 'discrete'
        set = (channel & DO_SET_BIT) != 0
        ch0 = channel & 0xf
        for w, i in words
          ch = ch0 + i
          if ch >= card.channels
            @_fault BSR.NO_SUCH_CHANNEL | BSR.IOM_TRANSFER, "card #{card.slot} channel #{ch}"
            continue
          card.words[ch] = if set then (card.words[ch] | w) else (card.words[ch] & ~w)
        wired = words[0...Math.max(0, card.wired - ch0)]
        @_publishIO (if set then IO_OP.SET else IO_OP.RESET), card, ch0, wired if wired.length
      when 'serial'
        card.tx = (w & 0xffff for w in words)
        @_publishIO IO_OP.VALUE, card, channel, card.tx
      else
        for w, i in words
          ch = channel + i
          if ch >= card.channels
            @_fault BSR.NO_SUCH_CHANNEL | BSR.IOM_TRANSFER, "card #{card.slot} channel #{ch}"
            continue
          card.words[ch] = w & 0xffff
        @_publishIO IO_OP.VALUE, card, channel, words
    return

  _indirect: (c, busID, clocks = null) ->
    if c.promAddr + c.nInstr > PROM_WORDS
      @_fault BSR.INTERNAL, "PROM #{c.promAddr} + #{c.nInstr} runs off the end"
      return
    instrs = (decodePromWord(@prom[a]) for a in [c.promAddr...c.promAddr + c.nInstr] by 1)
    hasIn  = instrs.some (p) -> p.mode != PROM_MODE.OUTPUT
    hasOut = instrs.some (p) -> p.mode == PROM_MODE.OUTPUT
    if hasIn and hasOut
      @_fault BSR.ILLEGAL_MODE, "PROM #{c.promAddr} mixes input and output"
      return
    @_log "  #{fmtPromWord(p)}" for p in instrs
    if hasOut
      total = 0
      total += p.count for p in instrs
      @pending = {expected: total, got: [], done: call(@, '_indirectOutput', instrs)}
      return
    @_indirectStep {instrs, busID, clocks, out: [], sev: [], anyFlagged: false, delayUs: 0, index: 0}
    return

  _indirectOutput: (instrs, words) ->
    at = 0
    for p in instrs
      card = @cards[p.card]
      if card? and card.type.dir != 'in'
        @_applyOutput card, p.channel, words[at...at + p.count]
      else
        @_fault BSR.ILLEGAL_MODE, "PROM output to card #{p.card}"
      at += p.count
    return

  _indirectReadDone: (transfer, words, flagged) ->
    transfer.out.push words...
    transfer.anyFlagged = true if flagged
    transfer.sev.push (@_sevOf(words.length, flagged) ? (SEV.VALID for [0...words.length] by 1))...
    transfer.index += 1
    @_indirectStep(transfer)

  _indirectStep: (transfer) ->
    {instrs, out, sev, busID, clocks} = transfer
    while transfer.index < instrs.length
      p = instrs[transfer.index]
      switch p.mode
        when PROM_MODE.INPUT
          card = @cards[p.card]
          if card? and card.type.dir != 'out'
            transfer.delayUs += sioReadoutUs(p.count) if card.type.kind == 'serial'
            @_readInput card, p.channel, p.count, call(@, '_indirectReadDone', transfer), clocks
            return
          @_fault BSR.ILLEGAL_MODE, "PROM input from card #{p.card}"
          out.push 0 for k in [0...p.count] by 1
        when PROM_MODE.BSR
          out.push @bsr
          @bsr = 0
        when PROM_MODE.BITE_IOM
          out.push @_biteWords(@cards[p.card], p.channel, p.count)...
      sev.push SEV.VALID while sev.length < out.length
      transfer.index += 1
    @_respond out, busID, {sev: (if transfer.anyFlagged then sev else null), delayUs: transfer.delayUs}
    return

  _biteWords: (card, channel, count) ->
    out = []
    for i in [0...count] by 1
      ch = channel + i
      unless card? and ch < card.channels
        @_fault BSR.NO_SUCH_CHANNEL | BSR.IOM_TRANSFER, "BITE card #{card?.slot} channel #{ch}"
        out.push 0, 0
        continue
      w = card.words[ch]
      switch card.type.kind
        when 'analog'
          if card.type.dir == 'in'
            out.push voltsToWord(wordToVolts(w) / 2 + BITE_REF_VOLTS), w
          else
            out.push w, w
        when 'discrete'
          if card.type.dir == 'in'
            t = FAKE_BITE_DI_WORDS[ch % FAKE_BITE_DI_WORDS.length]
            out.push t, (~t) & 0xffff
          else
            out.push w, w
        when 'serial'
          out.push SIO_BITE_WORDS...
        else
          out.push w, (~w) & 0xffff
    out

  _biteIOM: (c, busID) ->
    @bsr |= BSR.BITE_COMPLETE
    @_respond @_biteWords(@cards[c.card], c.channel, c.count), busID
    return

  _masterReset: () ->
    @_zeroOutputs()
    @bsr = 0
    for card in @cards when card? and card.type.dir in ['out', 'both']
      @_publishIO IO_OP.VALUE, card, 0, Array.from(card.words[0...card.wired])
    return


  _publishIO: (op, card, channel, words, count = words.length, clocks = null) ->
    @_publishRaw {op, type: card.type.code, card: card.slot, channel, words, count},
                 clocks
    return

  _publishRaw: (fields, clocks = null) ->
    b = @bus[@ioBusName]
    return unless b?
    data = encodeIO fields
    m = new BusMsg(data.length)
    m.data16.set data
    if clocks?
      m.wallUs = clocks.wallUs if clocks.wallUs?
      m.simUs = clocks.simUs if clocks.simUs?
    @stats.ioOut += 1
    @_log "io #{fmtIO(decodeIO(data))}"
    b.sendMsg m
    return

  _onIO: (words) ->
    m = decodeIO(words)
    return unless m?
    return if m.op == IO_OP.POLL
    if m.op in [IO_OP.CONNECT, IO_OP.DISCONNECT]
      @_onLink m
      return
    if m.op == IO_OP.REQUEST
      @_answerRequest m
      return
    card = @cards[m.card]
    unless m.card != IO_ALL and card?
      @_ioIgnore m, 'no such card'
      return
    if m.type and m.type != card.type.code
      @_ioIgnore m, "card #{card.slot} is #{card.type.name}"
      return
    if card.type.dir == 'out'
      @_ioIgnore m, 'the GPC drives an output card'
      return
    @stats.ioIn += 1
    switch card.type.kind
      when 'serial'
        unless m.op == IO_OP.VALUE
          @_ioIgnore m, 'serial data is VALUE'
          return
        card.rx = m.words.slice()
        @_endPoll card, true if card.poll?.channel == m.channel
      when 'analog'
        if m.op == IO_OP.VALUE then @_setRun card, m.channel, m.words, IO_OP.VALUE
        else @_ioIgnore m, 'an analog input is VALUE'
      else
        @_setRun card, m.channel, m.words, m.op
    return

  _setRun: (card, channel, words, op) ->
    channel = 0 if channel == IO_ALL
    for w, i in words
      ch = channel + i
      break if ch >= card.channels
      card.words[ch] = switch op
        when IO_OP.SET   then card.words[ch] | w
        when IO_OP.RESET then card.words[ch] & ~w
        else w
      card.words[ch] &= 0xffff
    return

  # A device plugging in or out of a channel.  A DISCONNECT ends a poll
  # open on the channel with the words flagged.
  _onLink: (m) ->
    on_ = m.op == IO_OP.CONNECT
    cards = if m.card == IO_ALL then (c for c in @cards when c?) else [@cards[m.card]]
    for card in cards when card?
      continue if m.type and m.type != card.type.code
      chans = if m.channel == IO_ALL then [0...card.channels] else [m.channel]
      for ch in chans when ch < card.channels
        card.link[ch] = on_
        @_log "card #{card.slot} channel #{ch} #{if on_ then 'connected' else 'disconnected'}"
        @_endPoll card, false if not on_ and card.poll?.channel == ch
    @stats.ioIn += 1
    return

  _answerRequest: (m) ->
    cards = if m.card == IO_ALL then (c for c in @cards when c?) else [@cards[m.card]]
    for card in cards when card?
      continue if m.type and m.type != card.type.code
      if card.type.kind == 'serial'
        words = if card.type.dir == 'out' then card.tx else card.rx
        @_publishIO IO_OP.VALUE, card, (if m.channel == IO_ALL then 0 else m.channel), words
      else if m.channel == IO_ALL
        @_publishIO IO_OP.VALUE, card, 0, Array.from(card.words[0...card.wired])
      else if m.channel < card.wired
        @_publishIO IO_OP.VALUE, card, m.channel, [card.words[m.channel]]
    return

  _ioIgnore: (m, why) ->
    @stats.ignored += 1
    @_log "io ignored #{fmtIO(m)}: #{why}"
    return

  describe: () ->
    ports = (b for b in [@busPri, @busSec] when b?)
    ports = ['no flight bus'] unless ports.length
    ["#{if @emdm then 'EMDM' else 'MDM'} #{@id} on #{ports.join(' and ')} (IUA #{@iua}), " +
     "hardware side #{@ioBusName} (port #{busConfig[@ioBusName].port})"]

  report: () ->
    cards = for c in @cards when c?
      nz = (i for w, i in c.words when w)
      on_ = (i for l, i in c.link when l)
      "#{c.slot}:#{c.type.name}" + (if nz.length then "[#{nz.join(',')}]" else '') +
        (if on_.length then " connected #{on_.join(',')}" else '')
    {
      id:      @id
      unit:    (if @emdm then 'EMDM' else 'MDM')
      iua:     @iua
      busses:  {primary: @busPri, secondary: @busSec, io: @ioBusName}
      bsr:     describeBSR(@bsr)
      cards:   cards
      stats:   @stats
    }
