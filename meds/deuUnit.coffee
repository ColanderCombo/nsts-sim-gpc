#
# The DEU behavior definition
#
# This is the state machine a DEU / IDP presents to a GPC: 8192 halfwords of
# display memory, the transfer in progress, the keyboard queue, and the
# status the GPC polls out of it.  The wire framing and message layouts are
# in `meds/deuProto.coffee`.
#
# ---------------------------------------------------------------------------
# The behavior of the MCDS/DEU & MEDS/IDP/MDU is specified in a number
# of documents, some of which are generally available, others that aren't
# known to be circulating:
#
# Available:
#   STS-83-0020V1-34   FSSR, Displays and Controls, Vol 1 (GNC)
#   STS-83-0020V2-34   ... Vol 2 (SM)
#   STS-83-0020V3-34   ... Vol 3, Appendixes A, B, F
#   USA-002869         PASS User's Guide (OI-32, OI-20)
#   SS-P-0002-170      CPDS Vol I, STS System Level Requirements, Software
#
# Not Currently Available:
#   ICD-3-1011-02      GPC/DEU ICD
#   ICD-3-0070-01      GPC/IDP ICD (MEDS)
#   MC615-0008         Display Electronic Unit, Orbiter
#   MG017300           CPDS for the OFT Display Electronic Unit Control
#                      Program End Item, Part I
#   SD 74-SH-0230      Data Processing Subsystem Principles of Operation
#   NAS9-14444         Display Format Generator, Off Line Support Processor
#                      Requirements Document
#   MG070100A1012E2    MEDS Display Application SW, SW Requirements Spec
#   MG07010000013E7    MEDS documentation
#   MG07010004013E2    MEDS documentation
#   SS-P-002-580       Level B SM CPDS
# ---------------------------------------------------------------------------
#
import * as DEU from 'meds/deuProto'
import {SPL} from 'meds/deuSPL'

export class DEUUnit
  # `o.send(words)`         put a reply on the display bus
  # `o.fill(addr, words)`   display memory changed; redraw from it
  # `o.reset()`             the GPC reset the scratch pad line
  # `o.time(t)`             a header clock arrived, decoded
  # `o.poll()`              the GPC polled; the display's only tick
  # `o.log(text)`           progress, if the caller wants it
  # `o.ipled`               false to ask the GPC for a load (default true)
  constructor: (o = {}) ->
    @send = o.send ? (->)
    @onFill = o.fill ? (->)
    @onReset = o.reset ? (->)
    @onTime = o.time ? (->)
    @onPoll = o.poll ? (->)      # the GPC polled: the display's only clock
    @log = o.log ? (->)
    @name = o.name ? 'DEU'

    @mem = new Uint16Array(DEU.DEU_MEMORY_WORDS)
    @xfer = null                 # the transfer in progress, if any
    @keyQueue = []               # completed entries (arrays of codes)
    @spl = new SPL()             # the scratch pad line, and the entry on it
    @majorFunc = o.majorFunc ? 0
    @ipled = o.ipled ? true
    @iplRunning = false
    # MSG RESET and ACK are not keystrokes.  A press latches a header 
    # bit that rides out on the next poll and is cleared once reported.
    @msgResetPending = false
    @ackPending = false
    @iplError = false
    @iplCircuitError = false
    @selfTest = false
    @swStatus = o.swStatus ? DEU.SWSTATUS_HEALTHY
    @timeWords = null            # the last time fill, raw
    @time = null                 # ...decoded: {mission, event, conv}
    @medsDK = null               # the last MEDS DK buffer
    @stats =
      commands: 0, fills: 0, timeFills: 0, headerless: 0, polls: 0, bite: 0, dumps: 0
      resets: 0, unknown: 0, wordsIn: 0, wordsOut: 0, abandoned: 0
      modeStatus: 0

  # DK bus handling
  #
  # A BCE transmits a command as the 24 command bits left
  # justified in two halfwords, and every data word on its own -- so the
  # datagram length tells them apart
  recv: (words) ->
    if words.length >= 2
      @onCommand ((words[0] & 0xffff) << 8) | ((words[1] >> 8) & 0xff)
    else
      (@onData(w) for w in words)[words.length - 1]

  onCommand: (cmd24) ->
    c = DEU.decodeCommand(cmd24)
    return null if c.iua != DEU.IUA        # not addressed to a display unit
    @stats.commands++
    # A new command abandons whatever transfer was part way through:
    if @xfer? and @xfer.left > 0
      @stats.abandoned++
      @log "#{@name}: transfer abandoned, #{@xfer.left} halfwords short"
    @xfer = null
    switch c.func
      when DEU.FUNC.TIME_FILL, DEU.FUNC.DISPLAY_FILL, DEU.FUNC.FORMAT_FILL
        @xfer = {func: c.func, left: c.count, words: []}
      when DEU.FUNC.MEDS_XFER
        @xfer = {func: c.func, left: DEU.MEDS_XFER_WORDS, words: []}
      when DEU.FUNC.DUMP
        @xfer = {func: c.func, left: c.count, words: []}
      when DEU.FUNC.POLL
        @stats.polls++
        @onPoll()
        if @iplRunning
          @stats.modeStatus++
          @_reply [@takeHeader()]
        else
          @_reply @pollResponse()
      when DEU.FUNC.BITE
        @stats.bite++
        @_reply DEU.biteResponse(@biteState())
      when DEU.FUNC.RESET_SPL
        @stats.resets++
        @keyQueue.length = 0
        @spl.clear()
        @onReset()
      else
        @stats.unknown++
        @log "#{@name}: unknown command #{c.name} " +
             "(function 0x#{c.func.toString(16)}, count #{c.count})"
    {kind: 'command', cmd: c}

  onData: (w) ->
    return null if not @xfer?
    @stats.wordsIn++
    @xfer.words.push(w & 0xffff)
    @xfer.left -= 1
    return {kind: 'data', left: @xfer.left} if @xfer.left > 0
    x = @xfer
    @xfer = null
    switch x.func
      when DEU.FUNC.MEDS_XFER
        @medsDK = x.words
        {kind: 'meds', words: x.words}
      when DEU.FUNC.DUMP
        @_dumpRequest(x.words)
      when DEU.FUNC.TIME_FILL
        @_timeFill(x.words)
      else
        @_fill(x.words, x.func)

  # The header clock.  Seven halfwords: mission time, event time -- both
  # 48-bit IBM extended floats holding seconds -- and the conversion word.
  _timeFill: (words) ->
    @stats.timeFills++
    @timeWords = words
    @time = DEU.parseTimeFill(words)
    if @time? and @time.conv != DEU.TIME_CONV_SEEN
      @_convReported ?= {}
      unless @_convReported[@time.conv]
        @_convReported[@time.conv] = true
        @log "#{@name}: TIME CONVERSION WORD X'#{@time.conv.asHex(4)}'"
    @onTime(@time) if @time?
    {kind: 'time', time: @time, words: words}

  # A fill message: a word count, the DEU address it loads at, and the
  # payload.
  _fill: (words, func) ->
    f = DEU.parseFill(words)
    if not f? or f.short or f.count + 2 != words.length
      @stats.headerless++
      @log "#{@name}: unheadered fill of #{words.length} halfwords, ignored"
      return {kind: 'headerless', words: words}
    @stats.fills++
    if not @ipled and not @iplRunning
      @iplRunning = true
      @log "#{@name}: load started"
    if @iplRunning and f.count == DEU.LAST_FILL_WORDS
      @iplRunning = false
      @ipled = true
      @deuId = f.payload[DEU.DEU_ID_ADDR - f.addr] if f.addr <= DEU.DEU_ID_ADDR < f.addr + f.count
      @log "#{@name}: load complete (#{f.count} halfwords at " +
           "0x#{f.addr.toString(16)}), reporting initialized" +
           (if @deuId? then " as unit #{@deuId}" else "")
    for w, i in f.payload
      @mem[(f.addr + i) & (DEU.DEU_MEMORY_WORDS - 1)] = w & 0xffff
    @onFill(f.addr, f.payload)
    {kind: 'fill', func: func, addr: f.addr, count: f.count,
     payload: f.payload}

  _dumpRequest: (words) ->
    addr = (words[1] ? 0) & DEU.ADDR_MASK
    n = (words[0] ? 0) & 0xffff
    @stats.dumps++
    out = (@mem[(addr + i) & (DEU.DEU_MEMORY_WORDS - 1)] for i in [0...n])
    @_reply out
    {kind: 'dump', addr: addr, count: n}

  _reply: (words) ->
    return if words.length == 0
    @stats.wordsOut += words.length
    @send words

  # what the GPC polls out of the unit
  #
  biteState: () ->
    b1 = DEU.BITE1.ALWAYS_ONE
    b1 |= DEU.BITE1.IPL_DONE if @ipled
    b1 |= DEU.BITE1.IPL_ERROR if @iplError
    b1 |= DEU.BITE1.IPL_CIRCUIT_ERROR if @iplCircuitError
    {bite1: b1, swStatus: @swStatus}

  header: () ->
    hdr = (@majorFunc << DEU.MAJOR_FUNC_SHIFT) & DEU.HDR.MAJOR_FUNC
    hdr |= DEU.HDR.SELF_TEST if @selfTest
    hdr |= DEU.HDR.IPL_REQUIRED if not @ipled
    hdr |= DEU.HDR.MSG_RESET if @msgResetPending
    hdr |= DEU.HDR.ACK if @ackPending
    # A response carrying MSG RESET or ACK does not carry a keyboard message:
    # when either bit is set the KYBD MSG PRESENT flag is not.  The queued
    # entry is not lost, it waits for the next poll 40 ms later.
    hdr |= DEU.HDR.KYBD_MSG if @keyQueue.length > 0 and
                              not (@msgResetPending or @ackPending)
    hdr

  # The header as transmitted, which is where MSG RESET and ACK are sent.
  # The monitor acts once per poll that carries one -- it pops one message
  # off the error list per MSG RESET bit it sees -- so a single press must
  # be reported exactly once.
  takeHeader: () ->
    hdr = @header()
    @msgResetPending = false
    @ackPending = false
    hdr

  pollResponse: () ->
    # The header is taken before the queue is drained: it carries the "a
    # keyboard message is ready" bit, which is set from the queue depth.
    hdr = @takeHeader()
    # One entry per message, never two concatenated: the monitor dispatches on
    # the first keystroke of the message, so a second entry riding behind the
    # first would be read as its arguments.  A queued entry waits 40 ms for
    # the next poll.
    keys = (if (hdr & DEU.HDR.KYBD_MSG) then @keyQueue.shift() else null) ? []
    DEU.pollResponse Object.assign({header: hdr, keys: keys}, @biteState())

  pressKey: (code) ->
    code = code & 0x1f
    if code == DEU.KEY.MSG_RESET
      @msgResetPending = true
      return
    if code == DEU.KEY.ACK
      @ackPending = true
      return
    return if @spl.press(code) != 'complete'
    @keyQueue.push @spl.keys[0...DEU.MAX_KEYS_IPL] if not @spl.err
    return
