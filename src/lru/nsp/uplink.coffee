import {call, setInterval, clearInterval} from '../../com/simRuntime.coffee'
#
# The far side of the forward link: the ground's PCM stream.
#
# JSC-18611,Rev.G sect.13.2: the command server BCH encodes each 48-bit
# command into a 128-bit word, multiplexes it with the voice channels
# into a frame and sends fifty frames a second.  The time authentication
# and the encryption between the ground and the NSP are the COMSEC's,
# which the simulation does not carry; the stream here is what the
# COMSEC hands the NSP.
#
# The stream is frames on the _SBAND_FWD bus, one command word a frame:
# a queued command, or the idle pattern of 128 zero bits, "a zero vehicle
# address in the idle pattern" (sect.12.3.3.6 C).  `chunkBits` splits a
# frame across datagrams at any bit.
#

import {Bus, BusMsg, busConfig} from './../../com/bus.civet.jsx'
import {FWD_LINK_BUS, RATE, FRAME_MS, UPLINK_WORD_BITS, BCH_INFO_BITS,
        encodeUplinkWord, buildFrame, packStream} from './nspConf'

IDLE_WORD = (0 for [0...UPLINK_WORD_BITS] by 1)

export class Uplink
  constructor: (opts = {}) ->
    @rate = RATE[opts.rate ? 'LDR']
    throw new Error("no such data rate: #{opts.rate}") unless @rate?
    @bus = opts.bus ? new Bus(FWD_LINK_BUS, busConfig[FWD_LINK_BUS])
    @ownBus = not opts.bus?
    @bus.onReceive (->), null if @ownBus
    @chunkBits = opts.chunkBits ? 0
    @frameMs = opts.frameMs ? FRAME_MS
    @stationId = opts.stationId ? 0
    @voice = opts.voice ? null
    @onFrame = opts.onFrame ? null
    @queue = []
    @timer = null
    @frames = 0
    @sent = 0
    @ready = @bus.ready

  # Queue a command, three halfwords, for the next free frame.  `errors`
  # parity bits are inverted so the word fails the NSP's check.
  push: (words, opts = {}) ->
    bits = encodeUplinkWord(words)
    for i in [0...(opts.errors ? 0)] by 1
      k = 1 + BCH_INFO_BITS + ((i * 7) % (UPLINK_WORD_BITS - 1 - BCH_INFO_BITS))
      bits[k] ^= 1
    @queue.push bits
    return

  # The next frame's bits.
  nextFrame: () ->
    word = @queue.shift() ? IDLE_WORD
    @frames += 1
    buildFrame @rate, word, {stationId: @stationId, voice: @voice}

  # Send one frame, in chunks when asked.
  sendFrame: () ->
    bits = @nextFrame()
    n = if @chunkBits > 0 then @chunkBits else bits.length
    for at in [0...bits.length] by n
      words = packStream(bits.slice(at, at + n))
      msg = new BusMsg(words.length)
      msg.data16.set words
      @bus.sendMsg msg
      @sent += 1
    @onFrame?(@frames, bits)
    return

  # Stream frames at the frame rate: `count` of them, or until stop().
  start: (count = 0) ->
    @stop()
    @remainingFrames = count
    @finiteStream = count > 0
    new Promise (resolve) =>
      @completeStream = resolve
      @timer = setInterval call(@, '_streamTick'), @frameMs
      return

  _streamTick: () ->
    @sendFrame()
    if @finiteStream
      @remainingFrames -= 1
      if @remainingFrames <= 0
        @stop()
        @completeStream?()
    return

  stop: () ->
    clearInterval @timer if @timer?
    @timer = null
    return

  close: () ->
    @stop()
    @bus.close?() if @ownBus
    return
