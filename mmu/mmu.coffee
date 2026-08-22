#
#
# Mass Memory Unit Implementation
#
# The Shuttle Mass Memory Unit (MMU) is nominally a linearly
# accessible tape drive.  When the GPC was upgraded to the
# newer CMOS based AP-101-S, the MMU was also replaced with a
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
import {LRU} from './../com/lru.civet.jsx'
import {Volume} from './volume'
import {IUA, OP, STAT_A, STAT_B, HALFWORDS_PER_BLOCK,
        SUBFILES, BLOCKS_PER_SUBFILE,
        decodeCommand, packPosition, blockIndex, blockAddr,
        fmtAddr, fmtPos} from './mmuConf'

# Each of the two MMUs has a dedicated bus, also attached to all 
# 5 GPCs:
UNIT_BUS = {1: 'MM1', 2: 'MM2'}

export class MMU extends LRU
  constructor: (opts = {}) ->
    unit = opts.unit ? 1
    bus  = opts.bus  ? UNIT_BUS[unit]
    throw new Error("no bus for mass memory unit #{unit}") unless bus
    super({id: "MMU#{unit}", busses: [bus]})

    @unit         = unit
    @busName      = bus
    @verbose      = !!opts.verbose
    @onEvent      = opts.onEvent ? null

    # How long the transport takes to answer, and how long a block takes
    # to come off the tape.   Although we're not yet modeling how much
    # time the tape takes to seek and access the tape, we need to build
    # in at least some delay to give the GPC time to handle each block.
    # 512 halfwords at the megabit bus rate is about 8.2 ms, so we start
    # with that:
    @replyDelayMs   = opts.replyDelayMs ? 0
    @blockDelayMs   = opts.blockDelayMs ? 8.2

    # A block that was never written is a hole in the recording, and a
    # transport that read one would report a data dropout.  Off by
    # default. Turn it on to find out whether a GPC is
    # asking for blocks nobody put on the tape.
    @faultOnBlank   = !!opts.faultOnBlank

    @volume = opts.volume ? new Volume()

    @reset()

    b = @bus[@busName]
    b.onReceive @_onBusMessage, @

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
    @stats = {commands: 0, blocksRead: 0, blocksWritten: 0, wordsOut: 0, wordsIn: 0}
    @_pendingWrite = null
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
    if words.length >= 2
      cmd = ((words[0] & 0xffff) << 8) | ((words[1] >> 8) & 0xff)
      self._onCommand(cmd)
    else
      self._onData(w) for w in words
    return

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
