#
# Network Signal Processor -- interface constants
#
# JSC-18611,Rev.G: Systems Brief 1 (onboard command, the command word),
# SB 3 sect.3.6.2 (the serial channel, fig.3-10 and 3-11), SB 12 (the NSP:
# the forward link format, table 12-2, the frame synchronizer, the command
# processor, the summary BITE, the upmode logic), SB 13 (the BCH code,
# fig.13-2 and 13-8).  JSC-18819,Rev.F I/O transaction ID 24, elements
# 66-69.
#
# Two units, NSP 1 and NSP 2, one powered at a time.  Each hangs on a
# flight critical forward MDM through a serial I/O channel and one power
# discrete; the GPC's cyclic read of the current unit is three MDM
# commands on that MDM's bus every 160 ms, measured on FC1 in OPS 0 (with
# the message element bypassed, the two discrete reads go on at 320 ms):
#
#   526420   INPUT card 9 channel 1 x1     NSP 1 power discrete   (FF1)
#   527020   INPUT card 12 channel 1 x1    NSP 2 power discrete   (FF3)
#   525000   INPUT card 4 channel 0 x1     GPC uplink block       (FF1, FF3)
#   526c7f   INPUT card 11 channel 3 x32   the NSP message
#
# The power discrete is the high bit of its word, "GCIL - NSP POWER 1
# (ON)".  The uplink block discrete is bit 3 of its word (bit 1 the high
# bit), "GPC UPLINK 2-STAGE BLOCK CMD A" behind FF1 and "CMD B" behind
# FF3; JSC-18611 sect.1.4.2.4: "Both discretes must be high (+28 volts)
# before the GPCs will stop processing commands."  The panel C3 UPLINK
# switch drives them in its GPC BLOCK position; in NSP BLOCK it is wired
# to the unit instead, which sets the data inhibit bit and answers a poll
# with the status word alone (sect.12.5.3).
#
# The simulator's unit sits on the MDM's hardware side bus
# (lru/mdm/mdmConf.coffee): the MDM's POLL of card 11 channel 3 is the read,
# answered with a VALUE of the 32 words; the unit drives the discretes
# with SET and RESET.
#
#
# THE MESSAGE -- 32 halfwords (fig.3-11)
#
#    1      status, sixteen BITE bits
#    2-31   ten commands of 48 bits, three halfwords each, command 1 first
#   32      validity: bits 1-10 one per command, 1 = the command passed
#           the BCH check and has a nonzero vehicle address; bits 11-16
#           spare (the GPC sets them for the downlist)
#
# STATUS WORD, bit 1 = 0x8000 (sect.12.4.6, with the MSIDs)
#
#    1  data ready          1 = a command in the buffer passed (V92X6081X)
#    2  NSP command path    1 = UPLINK switch at NSP BLOCK (V92X6082X)
#    3  bit sync lock       1 = loss (V92X6083X)
#    4  frame sync lock     1 = loss (V92X6084X)
#    5  bracket data        1 = loss (V92X6085X)
#    6  demux, uplink voice 1 = fail (V92X6086X)
#    7  mux, downlink voice 1 = fail (V92X6087X)
#    8  internal mode       1 = internal (V92X6088X)
#    9  secondary power     1 = fail (V92X6089X)
#   10  record mode mux     1 = fail (V92X6090X)
#   11  bit sync quality    1 = fail (V92X6091X)
#   12  BCH valid           1 = a command decoded correctly since the
#                           last poll (V92X6092X)
#   13  BCH invalid         1 = a command failed since the last poll
#                           (V92X6093X)
#   14  mode parity even    (V92X6094X), table 12-5
#   15  mode parity odd     the inverse of bit 14 (V92X6095X)
#   16  NSP status          1 = fail (V92X6096X)
#
# Sect.3.6.2.1: "Status data are continuously loaded when data ready is
# LOW and then held when data ready is HIGH until the NSP is polled."
#
# COMMAND WORD -- 48 bits (sect.1.3.1, fig.1-2)
#
#   bits  1-3   vehicle address           table 1-1
#   bits  4-7   major function / GPC      table 1-2
#   bits  8-14  op code                   table 1-3
#   bit  15     first word
#   bit  16     last word                 table 1-4
#   bits 17-48  command data
#
# A command that failed the BCH check reaches the GPC with its vehicle
# address cleared to zero; the idle pattern is 48 zero bits.
#
# For a real-time command (sect.1.3.2, fig.1-3), bits 17-48 are
#
#   bits 17-20  card
#   bit  21     1 = set, 0 = reset
#   bits 22-23  spare
#   bits 24-25  channel
#   bits 26-32  MDM number, table 1-5
#   bits 33-48  mask
#
#
# THE FORWARD LINK (sect.12.3.2.2, table 12-2, fig.13-2)
#
# Fifty frames a second: 640 bits at the low data rate, 32 kbps, one
# voice channel; 1440 bits at the high rate, 72 kbps, two.  A frame is
# the 24-bit sync pattern FAF320, 8 bits of station ID, then voice blocks
# of 96 (LDR) or 128 (HDR) bits a channel alternating with four 32-bit
# command blocks.  The four command blocks are one 128-bit command word:
#
#   bit    1      dummy
#   bits   2-3    dummy, covered by the BCH code
#   bits   4-51   the 48-bit command
#   bits  52-128  77 BCH parity bits over bits 2-51
#
# Sect.13.2.1: "1 dummy bit + [ ( 2 dummy bits + 48 bit Command Word ) +
# 77 bit BCH Check ] = 128 bits".
#
# THE BCH CODE (fig.13-8)
#
# "BCH encoder polynomial = X50 + X48 + X47 + X46 + X44 + X43 + X39 + X38
# + X36 + X35 + X30 + X27 + X26 + X25 + X24 + X23 + X16 + X15 + X12 + X9 +
# X4 + 1", a "50-Bit Shift Register".  The 50 information bits are shifted
# into the register first transmitted first; each of the 77 parity bits
# is the sum modulo 2 of the register taps, the tap X^k holding the bit
# shifted in k periods earlier, and is itself shifted in.  The polynomial
# divides x^127 + 1 and the quotient has alpha^1 to alpha^26 among its
# roots over x^7 + x^3 + 1, so the 127 bits form a codeword of the
# (127,50) BCH code, distance 27.  Sect.13.4.7: "Neither the COMSEC nor
# the NSP use BCH to correct transmission errors"; the check compares the
# parity received with the parity computed.
#
#
# THE STREAM ON THE BUS
#
# The forward link is one bus, the transponder's bit stream to both
# units.  A datagram carries a run of bits, word 0 the count, the bits
# packed sixteen a word from bit 15 down; the run need not start or end
# at a frame boundary.
#

import {IOM, IUA, MODE as MDM_MODE, encodeDirect} from './../mdm/mdmConf'

# wiring
#
UNIT =
  1: {mdm: 'FF1', bus: 'FC1', powerCard: 9,  blockCard: 4}
  2: {mdm: 'FF3', bus: 'FC3', powerCard: 12, blockCard: 4}

CARD          = 11
CHANNEL       = 3
CARD_TYPE     = IOM.SIO.code

POWER_CHANNEL = 1
POWER_BIT     = 0x8000
BLOCK_CHANNEL = 0
BLOCK_BIT     = 0x2000
DISCRETE_TYPE = IOM.DIH.code

FWD_LINK_BUS  = '_SBAND_FWD'

MESSAGE_WORDS = 32
COMMANDS      = 10
COMMAND_WORDS = 3

CMD_READ   = encodeDirect(IUA.FF, MDM_MODE.INPUT, CARD, CHANNEL, MESSAGE_WORDS)
CMD_POWER  = {1: encodeDirect(IUA.FF, MDM_MODE.INPUT, UNIT[1].powerCard, POWER_CHANNEL, 1),
              2: encodeDirect(IUA.FF, MDM_MODE.INPUT, UNIT[2].powerCard, POWER_CHANNEL, 1)}
CMD_BLOCK  = encodeDirect(IUA.FF, MDM_MODE.INPUT, UNIT[1].blockCard, BLOCK_CHANNEL, 1)

# The panel C3 UPLINK switch.
UPLINK_SWITCH = ['ENABLE', 'GPC_BLOCK', 'NSP_BLOCK']

# status word
#
bit = (n) -> (0x8000 >>> (n - 1)) & 0xffff

STATUS =
  DATA_READY:        bit(1)
  DATA_INHIBIT:      bit(2)
  BIT_SYNC_LOSS:     bit(3)
  FRAME_SYNC_LOSS:   bit(4)
  BRACKET_LOSS:      bit(5)
  DEMUX_FAIL:        bit(6)
  MUX_FAIL:          bit(7)
  INTERNAL_MODE:     bit(8)
  SEC_PWR_FAIL:      bit(9)
  RCD_MUX_FAIL:      bit(10)
  BIT_SYNC_QUAL:     bit(11)
  BCH_VALID:         bit(12)
  BCH_INVALID:       bit(13)
  MODE_PARITY_EVEN:  bit(14)
  MODE_PARITY_ODD:   bit(15)
  NSP_FAIL:          bit(16)

STATUS_NAME = {}
STATUS_NAME[v] = k for k, v of STATUS

# Table 12-5: the mode parity bit for each receive mode.
MODE_PARITY =
  TDRS: 0, STDN_LO: 1, STDN_HI: 1
  SGLS1: 0, SGLS2: 1, SGLS3: 1, SGLS4: 0, SGLS5: 1, SGLS6: 0

fmtStatus = (hw) ->
  names = (STATUS_NAME[bit(n)] for n in [1..16] when hw & bit(n))
  if names.length then names.join(' ') else 'none'

# The validity word: bit 1 is command 1.
validityBit = (i) -> bit(i + 1)

# command word
#
VEHICLE = {103: 0b011, 104: 0b100, 105: 0b101}

MF =
  GPC1: 1, GPC2: 2, GPC3: 3, GPC4: 4, GPC5: 5, ALL: 6
  GNC: 7, SM: 8, PL: 9, BFS: 10

MF_NAME = {}
MF_NAME[v] = k for k, v of MF

# Table 1-3, the ones a real-time command uses.  Op codes with the high
# two bits 10 are single stage; the rest go to the two-stage buffer and
# wait for a buffer execute.
OPCODE =
  MDM_MULTIPLE:          0b0000011
  TWO_STAGE_CLEAR:       0b1000001
  TWO_STAGE_EXECUTE:     0b1000011
  MDM_SINGLE:            0b1000101
  UL_ACTIVITY_OFF:       0b1000110
  UL_ACTIVITY_ON:        0b1000111
  UPLINK_COUNTER_RESET:  0b1001010

OPCODE_NAME = {}
OPCODE_NAME[v] = k for k, v of OPCODE

MDM_NUMBER =
  FF1: 1, FF2: 2, FF3: 3, FF4: 4, FA1: 5, FA2: 6, FA3: 7, FA4: 8
  PF1: 9, PF2: 10, LF1: 11, LA1: 12, LM1: 18

MDM_NAME = {}
MDM_NAME[v] = k for k, v of MDM_NUMBER

packHeader = (h) ->
  (((h.vehicle & 7) << 13) | ((h.mf & 0xf) << 9) | ((h.opcode & 0x7f) << 2) |
   (if h.first then 2 else 0) | (if h.last then 1 else 0)) & 0xffff

unpackHeader = (hw) ->
  vehicle: (hw >>> 13) & 7
  mf:      (hw >>> 9) & 0xf
  opcode:  (hw >>> 2) & 0x7f
  first:   !!(hw & 2)
  last:    !!(hw & 1)

# A 48-bit command as its three halfwords, from the header fields and
# the 32 data bits.
packCommand = (h, data32) ->
  [packHeader(h), (data32 >>> 16) & 0xffff, data32 & 0xffff]

# The 32 data bits of a real-time command.
packRtc = (r) ->
  (((r.card & 0xf) << 28) | ((if r.set then 1 else 0) << 27) | ((r.channel & 3) << 23) |
   ((r.mdm & 0x7f) << 16) | (r.mask & 0xffff)) >>> 0

unpackRtc = (data32) ->
  card:    (data32 >>> 28) & 0xf
  set:     !!((data32 >>> 27) & 1)
  channel: (data32 >>> 23) & 3
  mdm:     (data32 >>> 16) & 0x7f
  mask:    data32 & 0xffff

fmtCommand = (words) ->
  h = unpackHeader(words[0])
  fl = (if h.first then 'F' else '') + (if h.last then 'L' else '')
  mf = MF_NAME[h.mf] ? "mf#{h.mf}"
  op = OPCODE_NAME[h.opcode] ? "op#{h.opcode}"
  "veh #{h.vehicle} #{mf} #{op} #{fl} #{hex4 words[1]} #{hex4 words[2]}"

hex4 = (v) -> (v & 0xffff).toString(16).padStart(4, '0')

# bits
#
# A bit sequence is an array of 0 and 1, first transmitted first.

wordToBits = (w, n = 16) -> ((w >>> (n - 1 - i)) & 1 for i in [0...n] by 1)

bitsToWord = (bits, from = 0, n = 16) ->
  w = 0
  w = (w << 1) | (bits[from + i] & 1) for i in [0...n] by 1
  w >>> 0

wordsToBits = (words, n = 16) ->
  out = []
  out = out.concat(wordToBits(w, n)) for w in words
  out

bitsToWords = (bits, n = 16) ->
  (bitsToWord(bits, i, n) for i in [0...bits.length] by n)

# BCH
#
BCH_INFO_BITS   = 50
BCH_PARITY_BITS = 77
BCH_TAPS        = [4, 9, 12, 15, 16, 23, 24, 25, 26, 27, 30, 35, 36, 38, 39, 43, 44, 46, 47, 48, 50]

# The 77 parity bits for 50 information bits.
bchParity = (info) ->
  s = info.slice(0, BCH_INFO_BITS)
  for i in [BCH_INFO_BITS...(BCH_INFO_BITS + BCH_PARITY_BITS)] by 1
    b = 0
    b ^= s[i - k] for k in BCH_TAPS
    s.push b
  s.slice(BCH_INFO_BITS)

bchCheck = (info, parity) ->
  p = bchParity(info)
  return false unless parity.length == BCH_PARITY_BITS
  for i in [0...BCH_PARITY_BITS] by 1
    return false if (p[i] & 1) != (parity[i] & 1)
  true

# The 128-bit uplink word for a 48-bit command given as three halfwords.
UPLINK_WORD_BITS = 128

encodeUplinkWord = (cmdWords) ->
  info = [0, 0].concat(wordsToBits(cmdWords))
  [0].concat(info, bchParity(info))

# The command inside a 128-bit word: the three halfwords, with the
# vehicle address cleared when the parity does not check, and whether it
# did.
decodeUplinkWord = (bits) ->
  info   = bits.slice(1, 1 + BCH_INFO_BITS)
  parity = bits.slice(1 + BCH_INFO_BITS, UPLINK_WORD_BITS)
  ok     = bchCheck(info, parity)
  words  = bitsToWords(info.slice(2))
  words[0] &= 0x1fff unless ok
  {words, ok}

# frames
#
FRAME_SYNC      = 0xfaf320
FRAME_SYNC_BITS = 24
FRAMES_PER_SEC  = 50
FRAME_MS        = 1000 / FRAMES_PER_SEC
STATION_ID_BITS = 8
COMMAND_BLOCK   = 32
COMMAND_BLOCKS  = 4

RATE =
  LDR: {name: 'LDR', bps: 32000, frameBits: 640,  voice: 1, voiceBits: 96}
  HDR: {name: 'HDR', bps: 72000, frameBits: 1440, voice: 2, voiceBits: 128}

# The fields after the sync pattern, in order: table 12-2 with the
# command word's four 32-bit blocks as one kind of field.
frameFields = (rate) ->
  voice = ({kind: 'voice', channel: c + 1, bits: rate.voiceBits} for c in [0...rate.voice] by 1)
  fields = [{kind: 'station', bits: STATION_ID_BITS}]
  fields = fields.concat(voice)
  for b in [0...COMMAND_BLOCKS] by 1
    fields.push {kind: 'command', block: b, bits: COMMAND_BLOCK}
    fields = fields.concat(voice)
  at = FRAME_SYNC_BITS
  for f in fields
    f.at = at
    at += f.bits
  throw new Error("frame fields total #{at}, want #{rate.frameBits}") unless at == rate.frameBits
  fields

# One frame: the sync, the station ID, the voice fill and the 128-bit
# uplink word.
buildFrame = (rate, uplinkBits, opts = {}) ->
  bits = wordToBits(FRAME_SYNC, FRAME_SYNC_BITS)
  for f in frameFields(rate)
    switch f.kind
      when 'station'
        bits = bits.concat(wordToBits(opts.stationId ? 0, STATION_ID_BITS))
      when 'voice'
        fill = opts.voice ? ((i) -> i & 1)
        bits.push(fill(i, f.channel) & 1) for i in [0...f.bits] by 1
      when 'command'
        bits = bits.concat(uplinkBits.slice(f.block * COMMAND_BLOCK, (f.block + 1) * COMMAND_BLOCK))
  bits

# The 128 uplink bits out of a frame's bits (the sync included).
frameUplinkBits = (rate, frameBits) ->
  out = []
  for f in frameFields(rate) when f.kind == 'command'
    out = out.concat(frameBits.slice(f.at, f.at + f.bits))
  out

# The Hamming distance from the sync pattern of a 24-bit window.
SYNC_CORRELATE  = 3      # errors or fewer: positive correlation
SYNC_ANTI       = 21     # errors or more: negative correlation

popcount = (v) ->
  n = 0
  while v
    v &= v - 1
    n += 1
  n

syncDistance = (window24) -> popcount((window24 ^ FRAME_SYNC) & 0xffffff)

# the stream on the bus
#
packStream = (bits) ->
  words = [bits.length]
  words = words.concat(bitsToWords(bits))
  words

unpackStream = (data16) ->
  return [] unless data16?.length >= 1
  n = data16[0] & 0xffff
  bits = wordsToBits(Array.from(data16.subarray?(1) ? data16.slice(1)))
  bits.slice(0, n)

export {
  UNIT, CARD, CHANNEL, CARD_TYPE, POWER_CHANNEL, POWER_BIT, BLOCK_CHANNEL, BLOCK_BIT
  DISCRETE_TYPE, FWD_LINK_BUS, MESSAGE_WORDS, COMMANDS, COMMAND_WORDS
  CMD_READ, CMD_POWER, CMD_BLOCK, UPLINK_SWITCH
  STATUS, STATUS_NAME, MODE_PARITY, fmtStatus, validityBit, bit
  VEHICLE, MF, MF_NAME, OPCODE, OPCODE_NAME, MDM_NUMBER, MDM_NAME
  packHeader, unpackHeader, packCommand, packRtc, unpackRtc, fmtCommand, hex4
  wordToBits, bitsToWord, wordsToBits, bitsToWords
  BCH_INFO_BITS, BCH_PARITY_BITS, BCH_TAPS, bchParity, bchCheck
  UPLINK_WORD_BITS, encodeUplinkWord, decodeUplinkWord
  FRAME_SYNC, FRAME_SYNC_BITS, FRAMES_PER_SEC, FRAME_MS, STATION_ID_BITS
  COMMAND_BLOCK, COMMAND_BLOCKS, RATE, frameFields, buildFrame, frameUplinkBits
  SYNC_CORRELATE, SYNC_ANTI, popcount, syncDistance
  packStream, unpackStream
}
