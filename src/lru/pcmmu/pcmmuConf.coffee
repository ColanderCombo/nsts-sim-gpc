#
# Pulse Code Modulation Master Unit -- interface constants
#
# JSC-18611,Rev.G SB 29 (the unit: sect.29.2.4 the fetch and the data
# RAM, 29.2.5 the format memory, 29.2.6 the GPC interface with tables
# 29-1 and 29-2 and figs 29-15 to 29-17, 29.4.3.1 the BITE register), SB
# 30 (the SM side), SB 49 sect.49.2.3.1 (the minor frame); JSC-11174
# Vol.3 dwg 17.2 (the toggle buffer word, the RAM word, the BSR layout,
# the timing outputs, notes 2-5 and 10); JSC-18819,Rev.F SCP 4.2 (BCE 24,
# the device 10 op codes, the IUA); USA-002869 sect.7.3 (the downlist
# frames and formats); JSC-12829,Rev.G SCP 3.34 (the frame header).
# `.claude/pcmmu_docs_2026-09-05.md` indexes them.
#
# Two units, one powered.  Each GPC has a separate IP bus to both units
# (bus IPn for GPC n, BCE 24); the powered unit answers on the bus the
# command came on.  The unit polls the seven OI MDMs on the OI bus it
# commands (OI1 for unit 1, OI2 for unit 2) and formats what it gathers, with
# the GPC downlists, into the 128 kbps and 64 kbps streams both NSPs
# hear.
#
#
# THE GPC COMMAND WORD (sect.29.2.6.3, fig.29-16) -- the 24 bits between
# the sync and the parity, bit 1 the high bit of the 24:
#
#   bits  1-3   unit address, 011; the IUA on the bus is these three bits
#               and the two high bits of the op code, 13 to 15
#   bits  4-6   op code
#   bit   7     1 = data follows from the computer, 0 = a request
#   bits  8-19  starting address (table 29-2):
#                 toggle buffer ops   bits 8-10 buffer 1-5, bit 11 spare,
#                                     bits 12-19 the word in the buffer
#                 format memory ops   the format memory address
#                 OI/PL RAM read      the RAM address, 0-4095
#                 format select       bit 19: 0 hard, 1 programmable
#   bits 20-24  number of words less one, 0-31
#
# The LPS reads the RAM through a GPC with the same fields: the LDB READ
# PCMMU command carries gpcPort 5, pcmmuAddress 3, opCode 4,
# startAddress 12 and numOfWords 5 bits (SGOS 150Commands.h).
#
# Op code and bit 7 together (table 29-1):
#
#   1001  load the 128-kbps format RAM     0101  write a toggle buffer
#   1000  read the 128-kbps format RAM     0100  read a toggle buffer
#   1011  load the 64-kbps format RAM      0110  read the OI/PL RAM
#   1010  read the 64-kbps format RAM      1100  read the BITE register
#   1101  format selection                 111x  end of message
#   000x, 001x  invalid
#
# Measured on IP5 with GPC 4 in OPS 0 and in G9, the high 16 bits from
# the bus log and the low 8 from the datagrams:
#
#   6a401f, 6a441f, 6a481f, 6a4c1f   write buffer 1 at 0, 32, 64, 96, 32 words
#   7c43e0                           end of message, buffer 1, address 31 (OPS 0)
#   7c4fe0                           end of message, buffer 1, address 127 (G9)
#   780000                           read the BITE register, one word
#   6d3a60                           read OI/PL RAM 2515, one word (G9)
#   6cff62                           read OI/PL RAM 2043, three words, twice
#                                    6 ms apart at OPS 0 initialization
#
# The four writes and the end of message go out every 40 ms.  The end of
# message address is the length of the data set less one: the downlist
# frame is 32 words in OPS 0 (format 20) and 128 in G9 (format 44), and
# the computer writes 128 words each time, the rest AAAA.
#
# A command data word (fig.29-15) carries 16 data bits and the pattern
# 101; a response data word (fig.29-17) carries 16 data bits and three
# status bits, which the simulator carries as the SEV byte of the
# datagram (lru/mdm/mdmConf.coffee):
#
#   S   bit 25  unit power status, 1 normal; 0 after a power interrupt
#               until a BITE register read
#   E   bit 26  input data invalid, from bit 17 of the RAM word read;
#               0 for every other response
#   V   bit 27  BITE update notice, 1 normal; 0 while any BSR bit reads bad
#
# "When the 'no response' bit in the requested RAM word is logic 1, force
# bits 25 and 27 to logic 0, 1, respectively."  Dwg 17.2 note 4: "E bit is
# forced to 0 if response is BSR data."
#
#
# THE DOWNLIST FRAME (USA-002869 sect.7.3, JSC-12829 SCP 3.34)
#
# Fifty frames a cycle, 25 a second, up to 128 words each.  Measured:
#
#   word 1   sync, EB90
#   word 2   bits 1-2 a counter that steps every 24 frames, bits 3-8 the
#            frame count 0-49, bits 9-16 the format ID
#   frames 0 and 25: word 3 1400, words 4-6 a 48-bit time in
#            microseconds (frame 25 reads 1,000,000 more than frame 0)
#
# SCP 3.34: the six-word data cycle header of frames 0 and 25 holds "the
# sync word, frame counter, format ID, vehicle ID, GPC ID, mission ID, and
# GMT"; the other frames repeat words 1 and 2.
#
#
# THE TOGGLE BUFFERS (sect.29.2.6.2, dwg 17.2)
#
# Five, each two sides of 128 words of 19 bits: data 1-16, validity 17,
# EOM flag 18, odd parity 19.  One side takes the computer's writes while
# the formatter reads the other.  A buffer switches sides when the
# computer's side has received an end of message and the formatter has
# read all of the data set on its side, or, after power-on, at the first
# end of message.  A computer may read the formatter's side and not its
# own.  Note 10: "Major function downlist assigned by GPC software.
# Current assignments are GNC TB1, SM TB2, BFS TB5."
#
#
# THE DATA RAM (sect.29.2.4, SB 30.3, dwg 17.2)
#
# OI RAM 0-2047 and PL RAM 2048-4095, 18 bits a word: data, bit 17
# validity (set when the fetch transaction failed a validation test, the
# data left as it was), bit 18 odd parity.  The fetch PROM holds 4096
# commands of 44 bits, OI and PL interleaved, all issued once a second;
# each names an MDM or the PDI, up to 32 words, and the RAM slot.  The
# formatter never sends bit 17; a GPC read carries it as E.
#
#
# THE FORMAT MEMORY (sect.29.2.5, fig.29-13)
#
# 2048 words for each formatter; the 128-kbps formatter has a RAM and a
# PROM (the fixed format, 129) and the 64-kbps formatter a RAM.
#
#   words 1-8      the starting address of each sample rate group, bits
#                  1-11
#   words 9-168    the rate of each of the 160 slots of a minor frame
#                  (80 for 64 kbps), bits 1-3: 000 1, 001 2, 010 5, 011
#                  10, 100 20, 101 25, 110 50, 111 100 samples a second
#   words 169-2048 the groups, one entry a byte:
#                    bits 1-13  the data address
#                    bit  14    1 = the high byte of the word (for an OI
#                               RAM word bits 1 and 10-16), 0 = the low
#                    bit  15    1 = output bits 1-8 of this word itself
#                    bit  16    parity
#                    bit  17    validity
#
# Each group has a counter loaded from words 1-8 at the major frame; the
# 100 s/s counter is reset every minor frame, the 50 s/s every second
# frame, and so on to the 1 s/s at the major frame.  A slot takes the
# next entry of its rate's group.
#
# The data address space of the formatter is the unit's: sect.29.2.5
# names "OI/PL, GPC buffers", the BITE register and the PDI.  The model's
# map, fitted with no map in the documents held:
#
#   0-4095      OI/PL RAM
#   4096-4735   toggle buffers 1-5, 128 words each, the formatter's side
#   4736        the BITE register
#   4737        the minor frame count, 0-99
#
#
# THE OUTPUT (fig.29-14, SB 49.2.3.1)
#
# 128 kbps: 100 minor frames a second of 160 bytes; 64 kbps: 80 bytes.
# Bytes 1-4 of a minor frame are FA F3 20 and the frame count, 00-63H.
# Fill is all ones.  Bi-phase-L on the wire with a 1.152 MHz clock and a
# 100 Hz pulse to the NSPs; the simulator's stream is one datagram a
# minor frame on _PCMMU_HDR or _PCMMU_LDR, word 0 the bit count (1280 or
# 640) and the bits packed sixteen a word from bit 15 down, as
# lru/nsp/nspConf.coffee packs the forward link.
#
#
# THE BITE STATUS REGISTER (sect.29.4.3.1, dwg 17.2), bit 1 = 0x8000,
# bits 1-15 1 = good, reset to good by a GPC read or by every other major
# frame, parent word V75M2120P:
#
#    1  power status                    V75X2121D
#    2  MTU input                       V75X2122D
#    3  fetch PROM parity               V75X2123D
#    4  128-kbps downlink               V75X2124D
#    5  64-kbps downlink                V75X2125D
#    6  128-kbps format parity          V75X2126D
#    7  128-kbps counters               V75X2127D
#    8  64-kbps parity and counters     V75X2128D
#    9  recorder data out               V75X2129D
#   10  input data valid                V75X2130D
#   11  OI RAM parity                   V75X2131D
#   12  PL RAM parity                   V75X2132D
#   13  toggle buffer parity            V75X2133D
#   14  response on the computer buses  V75X2134D
#   15  response from the MDMs and PDI  V75X2135D
#   16  128-kbps format, 1 PRGM 0 FIXED V75X2136D
#
# Note 2: "BSR bits 5 and 8 are forced to a good (1) state until the 64
# kbps TM RAM receives the first GPC word."
#

import {SEV} from './../mdm/mdmConf'

# wiring
#
UNIT =
  1: {oiBus: 'OI1', nom: 'PCMMU 1'}
  2: {oiBus: 'OI2', nom: 'PCMMU 2'}

IP_BUSSES     = ['IP1', 'IP2', 'IP3', 'IP4', 'IP5']
HDR_BUS       = '_PCMMU_HDR'
LDR_BUS       = '_PCMMU_LDR'

ipBusOf = (gpc) -> "IP#{gpc}"

# The OI MDMs a unit polls, in IUA order.
OI_MDMS       = ['OF1', 'OF2', 'OF3', 'OF4', 'OA1', 'OA2', 'OA3']

# the GPC command word
#
ADDRESS       = 0b011
IUA_BASE      = ADDRESS << 2

OP =
  READ_FMT128:  0b1000
  LOAD_FMT128:  0b1001
  READ_FMT64:   0b1010
  LOAD_FMT64:   0b1011
  READ_TB:      0b0100
  WRITE_TB:     0b0101
  READ_RAM:     0b0110
  READ_BITE:    0b1100
  FMT_SELECT:   0b1101
  EOM:          0b1110

OP_NAME = {}
OP_NAME[v] = k for k, v of OP

TOGGLE_BUFFERS = 5
TB_WORDS       = 128
RAM_WORDS      = 4096
OI_RAM_WORDS   = 2048
FMT_WORDS      = 2048
MAX_WORDS      = 32

# 4-bit op: the three op code bits and bit 7; EOM ignores bit 7.
opOf = (cmd24) ->
  op = (cmd24 >>> 17) & 0xf
  if (op & 0xe) == OP.EOM then OP.EOM else op

decodeCommand = (cmd24) ->
  cmd = cmd24 & 0xffffff
  start = (cmd >>> 5) & 0xfff
  op = opOf(cmd)
  c =
    raw:      cmd
    address:  (cmd >>> 21) & 0x7
    op:       op
    name:     OP_NAME[op] ? 'INVALID'
    io:       (cmd >>> 17) & 1
    start:    start
    buffer:   (start >>> 9) & 0x7
    tbAddr:   start & 0xff
    prgm:     start & 1
    count:    (cmd & 0x1f) + 1
  c.valid = c.address == ADDRESS and (op & 0xc) != 0
  c

# `fields`: op (4-bit), start (12 bits) or buffer/tbAddr, count 1-32.
encodeCommand = (fields) ->
  op = fields.op & 0xf
  start = fields.start ? (((fields.buffer ? 1) & 0x7) << 9) | ((fields.tbAddr ? 0) & 0xff)
  ((ADDRESS << 21) | (op << 17) | ((start & 0xfff) << 5) | (((fields.count ? 1) - 1) & 0x1f)) >>> 0

CMD_WRITE_TB   = (buffer, tbAddr, count) -> encodeCommand {op: OP.WRITE_TB, buffer, tbAddr, count}
CMD_READ_TB    = (buffer, tbAddr, count) -> encodeCommand {op: OP.READ_TB, buffer, tbAddr, count}
CMD_EOM        = (buffer, last) -> encodeCommand {op: OP.EOM, buffer, tbAddr: last, count: 1}
CMD_READ_RAM   = (addr, count) -> encodeCommand {op: OP.READ_RAM, start: addr, count}
CMD_READ_BITE  = encodeCommand {op: OP.READ_BITE, start: 0, count: 1}
CMD_FMT_SELECT = (prgm) -> encodeCommand {op: OP.FMT_SELECT, start: (if prgm then 1 else 0), count: 1}
CMD_LOAD_FMT   = (rate, addr, count) -> encodeCommand {op: (if rate == 128 then OP.LOAD_FMT128 else OP.LOAD_FMT64), start: addr, count}
CMD_READ_FMT   = (rate, addr, count) -> encodeCommand {op: (if rate == 128 then OP.READ_FMT128 else OP.READ_FMT64), start: addr, count}

fmtCommand = (c) ->
  c = decodeCommand(c) if typeof c == 'number'
  n = "x#{c.count}"
  switch c.op
    when OP.WRITE_TB, OP.READ_TB
      "#{c.name} buffer #{c.buffer} at #{c.tbAddr} #{n}"
    when OP.EOM
      "EOM buffer #{c.buffer} last #{c.tbAddr}"
    when OP.READ_RAM
      "READ_RAM #{c.start} #{n}"
    when OP.READ_BITE
      "READ_BITE"
    when OP.FMT_SELECT
      "FMT_SELECT #{if c.prgm then 'PRGM' else 'FIXED'}"
    when OP.LOAD_FMT128, OP.READ_FMT128, OP.LOAD_FMT64, OP.READ_FMT64
      "#{c.name} at #{c.start} #{n}"
    else
      "INVALID #{c.raw.toString(16).padStart(6, '0')}"

# the response status
#
STATUS =
  NORMAL:      SEV.VALID
  INVALID:     SEV.VALID | SEV.E
  NO_RESPONSE: SEV.E | SEV.V

# the downlist frame
#
DL_SYNC        = 0xeb90
DL_FRAMES      = 50
DL_RATE_HZ     = 25

decodeFrameWord2 = (w) ->
  step: (w >>> 14) & 0x3, frame: (w >>> 8) & 0x3f, format: w & 0xff

# `words` a downlist frame as written.
decodeFrame = (words) ->
  return null unless words?.length >= 2 and words[0] == DL_SYNC
  d = decodeFrameWord2(words[1])
  d.words = words.length
  if d.frame in [0, 25] and words.length >= 6
    d.word3 = words[2]
    d.gmtUs = words[3] * 0x100000000 + words[4] * 0x10000 + words[5]
  d

fmtFrame = (words) ->
  d = decodeFrame(words)
  return "no sync" unless d?
  s = "format #{d.format} frame #{String(d.frame).padStart(2)} step #{d.step}"
  s += "  GMT #{(d.gmtUs / 1e6).toFixed(6)} s" if d.gmtUs?
  s

# the BITE status register
#
bsrBit = (n) -> 0x8000 >>> (n - 1)

BSR =
  POWER:        bsrBit(1)
  MTU:          bsrBit(2)
  FETCH_PARITY: bsrBit(3)
  DNLK_128:     bsrBit(4)
  DNLK_64:      bsrBit(5)
  PARITY_128:   bsrBit(6)
  COUNTERS_128: bsrBit(7)
  PARITY_64:    bsrBit(8)
  RCDR_DATA:    bsrBit(9)
  INPUT_VALID:  bsrBit(10)
  OI_PARITY:    bsrBit(11)
  PL_PARITY:    bsrBit(12)
  TB_PARITY:    bsrBit(13)
  GPC_RESPONSE: bsrBit(14)
  MDM_RESPONSE: bsrBit(15)
  PRGM:         bsrBit(16)

BSR_NAME = {}
BSR_NAME[v] = k for k, v of BSR
BSR_MSID =
  1: 'V75X2121D', 2: 'V75X2122D', 3: 'V75X2123D', 4: 'V75X2124D'
  5: 'V75X2125D', 6: 'V75X2126D', 7: 'V75X2127D', 8: 'V75X2128D'
  9: 'V75X2129D', 10: 'V75X2130D', 11: 'V75X2131D', 12: 'V75X2132D'
  13: 'V75X2133D', 14: 'V75X2134D', 15: 'V75X2135D', 16: 'V75X2136D'

# Bits 1-15 good.
BSR_GOOD = 0xfffe

fmtBSR = (w) ->
  bad = (BSR_NAME[bsrBit(n)] for n in [1..15] by 1 when not (w & bsrBit(n)))
  s = if w & BSR.PRGM then 'PRGM' else 'FIXED'
  if bad.length then "#{s}, bad: #{bad.join(' ')}" else "#{s}, all good"

# the format memory
#
RATES          = [1, 2, 5, 10, 20, 25, 50, 100]
FMT_GROUPS     = 8
FMT_SLOTS_BASE = 8              # words 9-168 are indexes 8-167
FMT_ENTRIES    = 168            # the first group entry
HDR_SLOTS      = 160
LDR_SLOTS      = 80
MINOR_FRAMES   = 100
SYNC_BYTES     = [0xfa, 0xf3, 0x20]

FRAME_MS       = 10

# Data addresses in a format entry (the model's map).
DATA =
  RAM:   0
  TB:    4096
  BSR:   4736
  COUNT: 4737

tbDataAddr = (buffer, word) -> DATA.TB + (buffer - 1) * TB_WORDS + word

FMT_ADDR_MASK  = 0x1fff
FMT_HIGH_BYTE  = 0x2000
FMT_FILL       = 0x4000

fmtEntry = (addr, high) -> ((addr & FMT_ADDR_MASK) | (if high then FMT_HIGH_BYTE else 0)) >>> 0
fillEntry = (byte) -> (FMT_FILL | (byte & 0xff)) >>> 0

decodeEntry = (w) ->
  fill: !!(w & FMT_FILL), high: !!(w & FMT_HIGH_BYTE), addr: w & FMT_ADDR_MASK, byte: w & 0xff

# The frame length of a data rate.
slotsOf = (rate) -> if rate == 128 then HDR_SLOTS else LDR_SLOTS

# the streams on the busses
#
packStream = (bytes) ->
  n = bytes.length * 8
  words = [n]
  for i in [0...bytes.length] by 2
    words.push ((bytes[i] << 8) | (bytes[i + 1] ? 0)) & 0xffff
  words

unpackStream = (data16) ->
  return [] unless data16?.length >= 1
  n = (data16[0] & 0xffff) >>> 3
  out = []
  for i in [1...data16.length] by 1
    w = data16[i] & 0xffff
    out.push (w >>> 8) & 0xff, w & 0xff
  out.slice(0, n)

# `bytes` a minor frame; the header and windows as words.
decodeMinorFrame = (bytes) ->
  return null unless bytes?.length >= 4
  sync: bytes[0] == SYNC_BYTES[0] and bytes[1] == SYNC_BYTES[1] and bytes[2] == SYNC_BYTES[2]
  count: bytes[3]
  words: ((bytes[i] << 8) | (bytes[i + 1] ? 0) for i in [4...bytes.length] by 2)

hex4 = (w) -> (w & 0xffff).toString(16).padStart(4, '0')
hex6 = (w) -> (w & 0xffffff).toString(16).padStart(6, '0')

export {
  UNIT, IP_BUSSES, HDR_BUS, LDR_BUS, OI_MDMS, ipBusOf
  ADDRESS, IUA_BASE, OP, OP_NAME, TOGGLE_BUFFERS, TB_WORDS, RAM_WORDS, OI_RAM_WORDS, FMT_WORDS, MAX_WORDS
  opOf, decodeCommand, encodeCommand, fmtCommand
  CMD_WRITE_TB, CMD_READ_TB, CMD_EOM, CMD_READ_RAM, CMD_READ_BITE, CMD_FMT_SELECT, CMD_LOAD_FMT, CMD_READ_FMT
  STATUS
  DL_SYNC, DL_FRAMES, DL_RATE_HZ, decodeFrameWord2, decodeFrame, fmtFrame
  bsrBit, BSR, BSR_NAME, BSR_MSID, BSR_GOOD, fmtBSR
  RATES, FMT_GROUPS, FMT_SLOTS_BASE, FMT_ENTRIES, HDR_SLOTS, LDR_SLOTS, MINOR_FRAMES, SYNC_BYTES, FRAME_MS
  DATA, tbDataAddr, FMT_ADDR_MASK, FMT_HIGH_BYTE, FMT_FILL, fmtEntry, fillEntry, decodeEntry, slotsOf
  packStream, unpackStream, decodeMinorFrame, hex4, hex6
}
