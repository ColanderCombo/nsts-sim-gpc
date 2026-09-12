#
#
# Mass Memory Unit Implementation
#
# The Shuttle Mass Memory Unit (MMU) is nominally a linearly
# accessible tape drive.  When the GPC was upgraded to the
# newer CMOS based AP-101S, the MMU was also replaced with a
# solid-state storage device.  The interface and protocol were
# unchanged, so this implementation applies to both.
#
# Commands responded to:
#
#   POSITION           command only.  Moves the transport; nothing is sent
#                      back.  A GPC confirms it with a POSITION REQUEST.
#   POSITION REQUEST   command, then one data word: the position.
#   BITE STATUS        command, then two data words: status A, status B.
#   EXTENDED BLOCK     command only.  The block count for the READ or
#                      WRITE that follows, when it will not fit the four
#                      bits in the transfer command itself.
#   READ               command, then count+1 blocks of 512 data words.
#   WRITE ENABLE       command only.  Arms the write circuits for one
#                      track; a WRITE to any other track is refused.
#   WRITE              command, then per block: one word out (the search
#                      complete word, "the head is over the block"), 512
#                      words in, one word out (the block complete word).
#
# Position after a transfer.  The position word names a GAP, so a read of
# blocks ending in subfile S leaves the transport reporting subfile S+1 --
# and when that would be 8, the end-of-file bit instead.  This is what
# makes a GPC's expected-position check pass or fail, so it is the part of
# the model worth being exact about.
#
# Errors are latched in the BITE status registers and cleared when the
# status is read, which is why a GPC asks for status after every single
# transaction.
#

import {BusMsg} from './../com/bus.civet.jsx'
import {DiscreteLines, REG_A, REPUBLISH_MS} from './../com/discretes.coffee'
import {LRU} from './../com/lru.civet.jsx'
import {Volume} from './volume'
import {IUA, OP, STAT_A, STAT_B, HALFWORDS_PER_BLOCK,
        SUBFILES, BLOCKS_PER_SUBFILE,
        decodeCommand, packPosition, blockIndex, blockAddr,
        fmtAddr, fmtPos} from './mmuConf'

# Each of the two MMUs has a dedicated bus, also attached to all 5 GPCs:
UNIT_BUS = {1: 'MM1', 2: 'MM2'}
UNIT_READY_BIT = {1: 6, 2: 7}

export class MMU extends LRU
  constructor: (opts = {}) ->
    unit = opts.unit ? 1
    bus  = opts.bus  ? UNIT_BUS[unit]
    throw new Error("no bus for mass memory unit #{unit}") unless bus
    super({id: "MMU#{unit}", busses: [bus]})
    @readyBit = UNIT_READY_BIT[unit]
    @discretes = opts.discretes != false and @readyBit?

    @unit         = unit
    @busName      = bus
    @verbose      = !!opts.verbose
    @onEvent      = opts.onEvent ? null

    # The last few replies this unit put on the bus, for _notePeer.
    @_recentSent  = []
    @_peerSeen    = 0

    # How long the transport takes to answer, and how often a block comes
    # off the tape.  Seek and access time are not modelled, but the block
    # period is not free to choose: a bus program that has read part of a
    # block skips the rest of it by delaying, and the delay it computes
    # says what the transport's rate is.
    #
    # The count is two per halfword left in the block plus 128 more, over
    # a block of 512 -- and the software's comment calls that 128
    # "one half the MMU block gap in half words".  A delay count of two is
    # one word on a serial bus, 33 us (POO, the delay instruction's
    # programming note), so a block is 512 word times of data and 256 of
    # gap: 768 x 33 us, and the skip lands in the middle of the gap.
    @replyDelayMs   = opts.replyDelayMs ? 0
    @blockDelayMs   = opts.blockDelayMs ? (768 * 0.033)

    # How long the transport holds READY down for an operation that sends
    # nothing back.  A model parameter: no seek time is documented here,
    # and the only bound the software gives is that an operation lasts
    # long enough to be worth waiting on: it delays 160 ms between an
    # extended-block command and the read that follows it.
    @positionDelayMs = opts.positionDelayMs ? 50

    # A block that was never written is a hole in the recording, and a
    # transport that read one would report a data dropout.  Off by
    # default. Turn it on to find out whether a GPC is
    # asking for blocks nobody put on the tape.
    @faultOnBlank   = !!opts.faultOnBlank

    @volume = opts.volume ? new Volume()

    @reset()

    b = @bus[@busName]
    b.onReceive @_onBusMessage, @
    if @discretes
      # READY is wired to every computer, so it goes out on every
      # channel.  A level, on a transport with no delivery guarantee and
      # no replay: republished on a timer as well as on change, so a GPC
      # that starts afterwards does not hold a stale one forever.
      @discLines = new DiscreteLines()
      @_sendReady()
      @_discTimer = setInterval (=> @_sendReady()), REPUBLISH_MS
      @_discTimer.unref?()

  # state
  #

  reset: () ->
    @position = {track: 0, file: 0, subfile: 0, bof: 1, eof: 0}
    # No latched status at power up.  The bits are FAULTS, and a GPC
    # treats any of them as a reason to abandon the transaction it was
    # part way through -- including"beginning of tape sensed".  
    @statusA  = 0
    @statusB  = 0
    @writeEnabledTrack = null
    @extendedCount = null
    @busy = false
    @_busyTimer = null
    @stats = {commands: 0, blocksRead: 0, blocksWritten: 0, wordsOut: 0, wordsIn: 0}
    @_pendingWrite = null
    return

  # discretes
  #

  _sendReady: () ->
    @discLines?.set REG_A, @readyBit, not @busy
    return

  _hold: (ms, why) ->
    clearTimeout @_busyTimer if @_busyTimer?
    unless @busy
      @busy = true
      @_log "busy (#{why})"
      @_sendReady()
    @_busyTimer = setTimeout (=> @_release()), ms
    @_busyTimer.unref?()
    return

  _release: () ->
    clearTimeout @_busyTimer if @_busyTimer?
    @_busyTimer = null
    return unless @busy
    @busy = false
    @_log "ready"
    @_sendReady()
    return

  # An error the GPC will see the next time it asks for status.
  _fault: (reg, bit, why) ->
    if reg == 'A' then @statusA |= bit else @statusB |= bit
    @_log "fault #{reg} 0x#{bit.toString(16)}: #{why}"
    return

  _log: (msg) ->
    console.log "MMU#{@unit}: #{msg}" if @verbose
    @onEvent?({unit: @unit, msg})
    return

  # wire
  #
  _onBusMessage: (self, busID, msg, remote) ->
    words = msg.data16
    return if self._notePeer(words)
    if words.length >= 2
      cmd = ((words[0] & 0xffff) << 8) | ((words[1] >> 8) & 0xff)
      self._onCommand(cmd)
    else
      self._onData(w) for w in words
    return

  @PEER_WINDOW_MS = 2000
  @RECENT_SENT_MAX = 32

  _noteSent: (data16) ->
    @_recentSent.push {words: Array.from(data16), t: Date.now()}
    @_recentSent.shift() while @_recentSent.length > MMU.RECENT_SENT_MAX
    return

  _notePeer: (words) ->
    # Words this unit is expecting are never tested: a GPC writing back
    # a block it has just read would otherwise look like a second unit.
    return false if @_pendingWrite?
    now = Date.now()
    cutoff = now - MMU.PEER_WINDOW_MS
    @_recentSent = (e for e in @_recentSent when e.t >= cutoff)
    match = null
    for e, i in @_recentSent
      continue unless e.words.length == words.length
      same = true
      for w, j in e.words
        if w != (words[j] & 0xffff)
          same = false
          break
      if same
        match = i
        break
    return false unless match?
    @_recentSent.splice(match, 1)
    @_peerSeen += 1
    if @_peerSeen == 1
      console.error "MMU#{@unit}: too many MMU's on bus #{@busName}."
    @_log "peer reply on #{@busName} (#{@_peerSeen})"
    true

  _onCommand: (cmd24) ->
    c = decodeCommand(cmd24)
    return unless c.iua == IUA          # not ours
    @stats.commands += 1
    @_log "cmd #{c.name} #{JSON.stringify(c)}"

    # A command arriving in the middle of a transfer is an error in its
    # own right, and the transfer it interrupted is abandoned.
    if @_pendingWrite?
      @_fault 'B', STAT_B.NOT_READY, 'command during a write transfer'
      @_pendingWrite = null

    switch c.opcode
      when OP.POSITION       then @_doPosition(c)
      when OP.BITE_STATUS    then @_doStatus()
      when OP.POSITION_REQ   then @_doPositionRequest()
      when OP.EXTENDED_BLOCK then @extendedCount = c.count
      when OP.WRITE_ENABLE   then @_doWriteEnable(c)
      when OP.READ           then @_doRead(c)
      when OP.WRITE          then @_doWrite(c)
      else
        @_fault 'A', STAT_A.INVALID_COMMAND, "opcode #{c.opcode}"
    return

  _onData: (hw) ->
    p = @_pendingWrite
    unless p?
      @_fault 'B', STAT_B.NOT_READY, 'data word with no transfer in progress'
      return
    @stats.wordsIn += 1
    p.buf[p.n] = hw & 0xffff
    p.n += 1
    @_writeBlockDone(p) if p.n == HALFWORDS_PER_BLOCK
    return

  # Words go out one datagram per group.  The receiving MIA queues every
  # halfword of a datagram, so a whole block is one send.
  _send: (words, delayMs = @replyDelayMs) ->
    msg = new BusMsg(words.length)
    msg.data16[i] = words[i] & 0xffff for i in [0...words.length] by 1
    emit = () =>
      @stats.wordsOut += words.length
      @_noteSent msg.data16
      @bus[@busName].sendMsg msg
    if delayMs > 0 then setTimeout emit, delayMs else setImmediate emit
    return

  # commands
  #

  _doPosition: (c) ->
    @position = {
      track:   c.track
      file:    c.file
      subfile: c.subfile
      bof:     c.bof
      eof:     c.eof
    }
    @_log "position -> #{fmtPos(@position)}"
    @_hold @positionDelayMs, 'position'
    return

  _doPositionRequest: () ->
    @_send [packPosition(@position)]
    return

  _doStatus: () ->
    a = @statusA
    b = @statusB
    @statusA = 0
    @statusB = 0
    @_send [a, b]
    return

  _doWriteEnable: (c) ->
    if @volume.writeProtect
      @_fault 'A', STAT_A.WRITE_PROTECT, 'volume is write protected'
      return
    @writeEnabledTrack = c.track
    return

  # The block count that applies to this transfer: an EXTENDED BLOCK
  # command overrides the four bits in the transfer command, and is
  # consumed by the transfer it preceded.  Both are counts less one.
  _transferBlocks: (c) ->
    n = (@extendedCount ? c.count) + 1
    @extendedCount = null
    n

  # Where the transfer starts.  A transfer command carries track, subfile
  # and block but no file: the file is wherever the transport was last
  # positioned.
  _transferStart: (c) ->
    track:   c.track
    file:    @position.file
    subfile: c.subfile
    block:   c.block

  # Reading blocks ending in subfile S leaves the head in the gap after
  # them, which is subfile S+1 -- or the end of file when that is 8.
  _positionAfter: (start, nBlocks) ->
    endIdx  = blockIndex(start) + nBlocks - 1
    end     = blockAddr(endIdx)
    subfile = end.subfile + 1
    {
      track:   start.track
      file:    @position.file
      subfile: (if subfile >= SUBFILES then 0 else subfile)
      bof:     0
      eof:     (if subfile >= SUBFILES then 1 else 0)
    }

  _doRead: (c) ->
    n     = @_transferBlocks(c)
    start = @_transferStart(c)
    first = blockIndex(start)
    @_log "read #{n} block(s) from #{fmtAddr(start)}"

    # A transfer may run on through subfiles but not off the end of the
    # file it started in: that is the end-of-file block count error.
    fileEnd = (Math.floor(first / (SUBFILES * BLOCKS_PER_SUBFILE)) + 1) *
              (SUBFILES * BLOCKS_PER_SUBFILE)
    if first + n > fileEnd
      @_fault 'B', STAT_B.EOF_BLOCK_COUNT, "#{n} blocks runs past the file"
      n = fileEnd - first
      return if n <= 0

    delay = 0
    for i in [0...n] by 1
      idx = first + i
      if @faultOnBlank and not @volume.has(idx)
        @_fault 'B', STAT_B.DATA_DROPOUT, "#{fmtAddr(blockAddr(idx))} is blank"
      @_send @volume.read(idx), delay
      delay += @blockDelayMs
      @stats.blocksRead += 1

    @position = @_positionAfter(start, n)
    @_log "read done, position #{fmtPos(@position)}"
    @_hold delay, 'read'
    return

  _doWrite: (c) ->
    n     = @_transferBlocks(c)
    start = @_transferStart(c)
    if @volume.writeProtect
      @_fault 'A', STAT_A.WRITE_PROTECT, 'volume is write protected'
      return
    if @writeEnabledTrack != start.track
      @_fault 'A', STAT_A.WRITE_PROTECT,
              "track #{start.track} is not write enabled"
      return
    @_log "write #{n} block(s) at #{fmtAddr(start)}"
    @_hold n * @blockDelayMs, 'write'
    @_pendingWrite = {
      start: start
      first: blockIndex(start)
      done:  0
      total: n
      buf:   new Uint16Array(HALFWORDS_PER_BLOCK)
      n:     0
    }
    # The search complete word: the transport has reached the block and
    # the GPC may start sending.
    @_send [packPosition(@position)]
    return

  _writeBlockDone: (p) ->
    idx = p.first + p.done
    try
      @volume.write(idx, p.buf)
    catch e
      @_fault 'A', STAT_A.WRITE_PROTECT, e.message
      @_pendingWrite = null
      return
    @stats.blocksWritten += 1
    p.done += 1
    p.n = 0
    p.buf = new Uint16Array(HALFWORDS_PER_BLOCK)
    @position = @_positionAfter(p.start, p.done)
    if p.done >= p.total
      @_pendingWrite = null
      @_release()
      @_send [packPosition(@position)]
    else
      # Block complete, then the search complete word for the next one.
      @_send [packPosition(@position)]
      @_send [packPosition(@position)]
    return

  report: () ->
    unit:     @unit
    bus:      @busName
    position: fmtPos(@position)
    bof:      @position.bof
    eof:      @position.eof
    statusA:  @statusA
    statusB:  @statusB
    blocks:   @volume.count()
    stats:    @stats
