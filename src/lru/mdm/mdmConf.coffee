#
# Multiplexer/Demultiplexer -- interface constants
#
# An MDM answers a GPC on two ports, each a Multiplexer Interface Adapter
# on one flight data bus, and reaches the vehicle through up to sixteen
# Input/Output Modules ("cards") in numbered slots.  A Sequence Control
# Unit executes each 28-bit command word from the bus directly, or runs a
# program of command words from a 512-word PROM.  JSC-18611,Rev.G sect.28
# is the description this module follows; the bit numbers below are
# quoted from it and mapped onto the 24-bit command word the simulator's
# busses carry (the three sync bits and the parity bit are absent).
#
#
# INTERFACE UNIT ADDRESSES (JSC-11174,Vol.1,Rev.F dwg 8.8 sht.1 note 14)
#
#   FF1-4  10      FA1-4  12      PF1  10      PF2  12
#   LL1     9      LL2     6      LR1  15      LR2  18
#   LF1    10      LA1    10      LM1  24
#   OF1    12      OF2    15      OF3  17      OF4  18
#   OA1    10      OA2     6      OA3   9
#   flex MDMs: 6, 9, 15, 29 or 30 by mission
#
# The four FF MDMs share one address and the four FA MDMs another; the bus
# a command goes out on selects the unit.
#
#
# COMMAND WORD (JSC-18611 sect.28.2.4.A and 28.2.6.A)
#
#   28-bit word    cmd24 bits   field
#   1-3            --           sync
#   4-8            23-19        MDM address (IUA)
#   9              18           spare
#   10-13          17-14        mode control field
#   direct mode:
#   14-17          13-10        module (card) address, 0-15
#   18-22           9-5         channel address, 0-31
#   23-27           4-0         number of words less one, 1-32 words
#   indirect mode:
#   14-22          13-5         PROM starting address, 0-511
#   23-27           4-0         number of PROM instructions less one
#   28             --           parity
#
# A discrete output command uses the high bit of the channel field to say
# whether the data words that follow set (1) or reset (0) the discretes
# they mask; the card's three channels are the low four bits.
#
#
# MODE CONTROL FIELD
#
#   0001  return the PROM word at the address in bits 14-22
#   0010  indirect mode: execute PROM words from the address in bits 14-22
#   0100  SCU BITE test
#   0101  A/D BITE test
#   0110  power supply BITE test
#   0111  IOM BITE test
#   1000  direct mode output: command data words follow
#   1001  direct mode input: response data words are returned
#   1010  return the BITE status register and reset it
#   1011  master reset: discretes to 0, analogs to 0 V
#   1100  return the command word (see RETURN WORD below)
#   1110  load the BITE status register with the data word that follows
#   0000, 0011, 1101, 1111  spare; commanding one sets BSR bit 8
#
#
# DATA WORD (JSC-18611 sect.28.2.6.B)
#
#   1-3    sync
#   4-8    MDM address
#   9-24   data, 16 bits
#   25-27  SEV: S cleared on the first response after power-up, E set
#          when a serial I/O channel received nothing valid, V cleared
#          when the MDM detected an error in the word being sent
#   28     parity
#
# The simulator's bus carries the 16 data bits of a data word and nothing
# else, so the SEV bits live in the model's log and statistics.
#
#
# RETURN WORD (mode 1100)
#
# "Bits 9-22 contain the module address, channel address, and
# number-of-words fields.  Bits 23, 24 contain zeros."  As a 16-bit data
# word: card in bits 1-4, channel in 5-9, words less one in 10-14, two
# zeros.
#
#
# BITE STATUS REGISTER (JSC-18611 sect.28.2.4.C), bit 1 = 0x8000
#
#    1  power interrupt
#    2  incoming data error
#    3  operation requested on a nonexistent channel
#    4  unable to transfer data to/from IOM
#    5  too many words in last message
#    6  last command not completed
#    7  simultaneous execution on primary and backup data bus
#    8  illegal mode commanded
#    9  internal error detected
#   10  gap time error
#   11  successful BITE completion
#   12-16  BITE test progression, zero outside a commanded BITE test
#
# The register is cleared when it is read (mode 1010) and by a master
# reset.  Bit 3 is always accompanied by bit 4.
#
#
# INPUT/OUTPUT MODULES (JSC-18611 table 28-1 and sect.28.2.6.A.1.d;
# JSC-11174,Vol.1,Rev.F dwg 8.8 sht.2-3 for the levels)
#
#   AIS  analog input, single-ended   32 channels  -5.12 to +5.11 V
#   AID  analog input, differential   16 channels  -5.12 to +5.11 V;
#                                     32 on an SRB MDM
#   AOD  analog output, differential  16 channels  -5.12 to +5.11 V,
#                                     a 12-bit D/A from data bits 1-12
#   DIL  discrete input, low            3 channels of 16 discretes  0/5 V,
#                                     threshold 2.25 V
#   DIH  discrete input, high           3 channels of 16 discretes  0/28 V,
#                                     threshold 8 V
#   DOL  discrete output, low           3 channels of 16 discretes  0/5 V
#   DOH  discrete output, high          3 channels of 16 discretes  0/28 V
#   SIO  serial input/output            4 channels, one 20-bit Manchester
#                                       bus each; the word count is a count
#                                       of serial words, not channels
#   TAC  TACAN / radar altimeter        FF MDMs only.  The flight software
#                                       reads seven words from channel 0
#                                       and writes two at channel 6, so
#                                       the model gives it eight channels,
#                                       each a 16-bit register readable
#                                       and writable from either side.
#
# An analog input is "a 10-bit output (sign plus nine bits) in two's
# complement form, Least Significant Bit (LSB) equals 10 millivolts",
# left justified in the 16-bit data field.  An analog output takes the
# top twelve bits of its data word, 2.5 mV a step over the same range.
#
# An IOM BITE test answers two words a channel.  For an analog input card
# "RSP WORD 1 = ANALOG BITE VALUE = 1/2(INPUT SIG) + (BITE REF); RSP WORD 2
# = NON-BITE VALUE = INPUT SIGNAL", the reference being +2.0 V on some
# channels and -2.0 V on others (dwg 8.8 sht.2 note 14; the model uses +2.0
# V throughout).  For a serial card the two words are 'AAAA' and '5555'
# (sht.3 note 13).
#
# The single-ended analog input card wraps: a read of 32 channels may
# start anywhere.  Every other card reports a channel past its last as
# BSR bits 3 and 4 and clears V in that word.
#
#
# PROM (JSC-18611 sect.28.2.4.E and 28.2.6)
#
# 512 words of 16 bits.  Words 0-15 hold the class of the card in each
# slot, low bit at bit 9 and high bit at bit 12 (JSC-11174 dwg 8.8 sht.1):
#
#   0000, 1111  no module     0010  DIL, DIH     0100  AID, AIS
#   0110  DOL, DOH            1000  SIO          1010  TAC       1100  AOD
#
# Programs of up to 32 command words start at word 16, and the flight
# software runs them by PROM address and instruction count:
#
#   FF   location 22 for 6 instructions   21 words   (PROM seq 1-2, MFE)
#   FF   location 23 for 9 instructions   36 words   (PROM seq 2-6, HFE)
#   FA   location 21 for 6 instructions   34 words   (PROM seq 1-2, MFE)
#   FA   location 27 for 15 instructions  54 words   (PROM seq 3-10, HFE)
#   LL1  location 20 for 1, 28 for 7, 35 for 29     1, 7 and 29 words
#   LL2  location 100 for 31                        31 words
#   LR1  location 160 for 1, 168 for 13, 181 for 29  1, 13 and 29 words
#   LR2  location 245 for 31                        31 words
#
# PROM command word, bit 1 = 0x8000:
#
#   1      parity
#   2-3    mode: 00 command data transfer (output), 01 response data
#          transfer (input), 10 send and reset the BSR, 11 IOM BITE
#   4-8    channel address
#   9-12   module address, bit 12 the high bit and bits 9-11 the next
#          three with the low bit in bit 11 ("The LSB is located in bit
#          position 11, with the next higher bits located in bit positions
#          10 and 9.  The MSB is located in bit position 12.")
#   13-16  number of words less one, 1-16 words
#
# A PROM program is all input or all output; mixing the two in one program
# sets BSR bit 8.
#
#
# MDM AND EMDM
#
# The Enhanced MDM keeps every word format, mode code and BSR bit of the
# MDM (JSC-11174 dwg 8.13 repeats dwg 8.8 line for line).  Its differences:
# a power supply on each card instead of one for eight; a discrete select
# line from the SCU to each card, so a card address error stops the
# response word with V cleared; an MIA-to-SCU wraparound test that sets
# BSR bit 2; and six transparent channels, 3-8, on each DOL and DOH card,
# not connected to outputs and addressable for BITE status.  The model is
# an EMDM unless told otherwise, and the channel count is the only one of
# these that shows on the bus.
#
#
# HARDWARE SIDE BUS
#
# Each MDM uses `_<id>_mdmIO`; halfwords:
#
#     0   operation   SET = 1, RESET = 2, REQUEST = 3, VALUE = 4, POLL = 5,
#                     CONNECT = 6, DISCONNECT = 7
#     1   type        the IOM type code of the card addressed (IOM.*.code),
#                     0 in a REQUEST that does not care
#     2   address     card in the high byte, channel in the low byte;
#                     0xff in either means every one
#     3   count       payload halfwords that follow; in a POLL, the words
#                     the GPC is reading
#     4.. payload     one halfword per channel from the address up, or the
#                     serial words of one channel for SIO
#
#
#   source  operation            result
#   device  SET/RESET or VALUE   drive an input card
#   MDM     SET/RESET or VALUE   mirror a GPC write to an output card
#   either  REQUEST              reply with matching VALUE records
#
# Serial-channel exchange:
#
#   device attach/detach         CONNECT / DISCONNECT
#   GPC write                    MDM sends VALUE
#   GPC read, connected          MDM sends POLL; device returns VALUE
#   GPC read, no reply           cached words with E set after SERIAL_ANSWER_MS
#   GPC read, disconnected       cached words with E set immediately
#   response delay               SIO_WORD_US per word
#

IUA =
  FF: 10, FA: 12
  PF1: 10, PF2: 12
  LL1: 9, LL2: 6, LR1: 15, LR2: 18
  LF1: 10, LA1: 10, LM1: 24
  OF1: 12, OF2: 15, OF3: 17, OF4: 18
  OA1: 10, OA2: 6, OA3: 9

MDM_BUS_PREFIX = '_'
MDM_BUS_SUFFIX = '_mdmIO'
ioBusName = (id) -> "#{MDM_BUS_PREFIX}#{id}#{MDM_BUS_SUFFIX}"

MODE =
  PROM_WORD:     0x1
  INDIRECT:      0x2
  BITE_SCU:      0x4
  BITE_AD:       0x5
  BITE_PS:       0x6
  BITE_IOM:      0x7
  OUTPUT:        0x8
  INPUT:         0x9
  BSR:           0xa
  MASTER_RESET:  0xb
  RETURN_WORD:   0xc
  LOAD_BSR:      0xe

MODE_NAME = {}
MODE_NAME[v] = k for k, v of MODE
modeName = (m) -> MODE_NAME[m] ? "SPARE#{m}"

SPARE_MODES = [0x0, 0x3, 0xd, 0xf]

DO_SET_BIT = 0x10

decodeCommand = (cmd24) ->
  cmd = cmd24 & 0xffffff
  c =
    raw:      cmd
    iua:      (cmd >>> 19) & 0x1f
    spare:    (cmd >>> 18) & 1
    mode:     (cmd >>> 14) & 0xf
    card:     (cmd >>> 10) & 0xf
    channel:  (cmd >>> 5) & 0x1f
    count:    (cmd & 0x1f) + 1
    promAddr: (cmd >>> 5) & 0x1ff
    nInstr:   (cmd & 0x1f) + 1
  c.name = modeName(c.mode)
  c

encodeDirect = (iua, mode, card, channel, count = 1) ->
  (((iua & 0x1f) << 19) | ((mode & 0xf) << 14) | ((card & 0xf) << 10) |
   ((channel & 0x1f) << 5) | ((count - 1) & 0x1f)) >>> 0

encodeIndirect = (iua, promAddr, nInstr = 1) ->
  (((iua & 0x1f) << 19) | (MODE.INDIRECT << 14) | ((promAddr & 0x1ff) << 5) |
   ((nInstr - 1) & 0x1f)) >>> 0

returnWord = (c) ->
  (((c.card & 0xf) << 12) | ((c.channel & 0x1f) << 7) | (((c.count - 1) & 0x1f) << 2)) & 0xffff

fmtCommand = (c) ->
  switch c.mode
    when MODE.INDIRECT
      "#{c.name} prom #{c.promAddr} x#{c.nInstr}"
    when MODE.PROM_WORD
      "#{c.name} prom #{c.promAddr}"
    when MODE.OUTPUT, MODE.INPUT, MODE.BITE_IOM, MODE.RETURN_WORD
      "#{c.name} card #{c.card} ch #{c.channel} x#{c.count}"
    else
      c.name

bsrBit = (n) -> (0x8000 >>> (n - 1)) & 0xffff

BSR =
  POWER_INTERRUPT:   bsrBit(1)
  INCOMING_DATA:     bsrBit(2)
  NO_SUCH_CHANNEL:   bsrBit(3)
  IOM_TRANSFER:      bsrBit(4)
  TOO_MANY_WORDS:    bsrBit(5)
  NOT_COMPLETED:     bsrBit(6)
  BOTH_PORTS:        bsrBit(7)
  ILLEGAL_MODE:      bsrBit(8)
  INTERNAL:          bsrBit(9)
  GAP_TIME:          bsrBit(10)
  BITE_COMPLETE:     bsrBit(11)

BSR_NAME = {}
BSR_NAME[v] = k for k, v of BSR

describeBSR = (word) ->
  names = (BSR_NAME[bsrBit(n)] for n in [1..11] when word & bsrBit(n))
  names.push "bite#{(word >>> 0) & 0x1f}" if word & 0x1f
  if names.length then names.join(', ') else 'clear'

IOM =
  DIL: {code: 1, dir: 'in',   kind: 'discrete', channels: 3,  cls: 0x2, nom: 'discrete input low, 0/5 V'}
  DIH: {code: 2, dir: 'in',   kind: 'discrete', channels: 3,  cls: 0x2, nom: 'discrete input high, 0/28 V'}
  DOL: {code: 3, dir: 'out',  kind: 'discrete', channels: 3,  cls: 0x6, nom: 'discrete output low, 0/5 V', emdmChannels: 9}
  DOH: {code: 4, dir: 'out',  kind: 'discrete', channels: 3,  cls: 0x6, nom: 'discrete output high, 0/28 V', emdmChannels: 9}
  AIS: {code: 5, dir: 'in',   kind: 'analog',   channels: 32, cls: 0x4, nom: 'analog input, single-ended', wrap: true}
  AID: {code: 6, dir: 'in',   kind: 'analog',   channels: 16, cls: 0x4, nom: 'analog input, differential', srbChannels: 32}
  AOD: {code: 7, dir: 'out',  kind: 'analog',   channels: 16, cls: 0xc, nom: 'analog output, differential'}
  SIO: {code: 8, dir: 'both', kind: 'serial',   channels: 4,  cls: 0x8, nom: 'serial input/output'}
  TAC: {code: 9, dir: 'both', kind: 'word',     channels: 8,  cls: 0xa, nom: 'TACAN / radar altimeter'}

IOM_BY_CODE = {}
for own name, t of IOM
  t.name = name
  IOM_BY_CODE[t.code] = t

IOM_CLASS_NONE = 0x0

cardChannels = (t, entry, emdm = true) ->
  return t.srbChannels if entry?.srb and t.srbChannels?
  return t.emdmChannels if emdm and t.emdmChannels?
  t.channels

BITE_REF_VOLTS = 2.0
SIO_BITE_WORDS = [0xaaaa, 0x5555]

iomType = (nameOrCode) ->
  return IOM[nameOrCode] if IOM[nameOrCode]?
  IOM_BY_CODE[nameOrCode] ? null

ANALOG_LSB_VOLTS = 0.01
ANALOG_MIN = -512
ANALOG_MAX = 511

voltsToWord = (v) ->
  n = Math.round(v / ANALOG_LSB_VOLTS)
  n = ANALOG_MIN if n < ANALOG_MIN
  n = ANALOG_MAX if n > ANALOG_MAX
  ((n & 0x3ff) << 6) & 0xffff

wordToVolts = (w) ->
  ((((w & 0xffff) << 16) >> 22)) * ANALOG_LSB_VOLTS

AOD_LSB_VOLTS = 0.0025
AOD_MIN = -2048
AOD_MAX = 2047

voltsToAodWord = (v) ->
  n = Math.round(v / AOD_LSB_VOLTS)
  n = AOD_MIN if n < AOD_MIN
  n = AOD_MAX if n > AOD_MAX
  ((n & 0xfff) << 4) & 0xffff

aodWordToVolts = (w) ->
  ((((w & 0xffff) << 16) >> 20)) * AOD_LSB_VOLTS

PROM_WORDS = 512
PROM_CLASS_WORDS = 16
PROM_PROGRAM_BASE = 16
PROM_MAX_INSTR = 32
PROM_MAX_WORDS = 16

PROM_MODE =
  OUTPUT:   0x0
  INPUT:    0x1
  BSR:      0x2
  BITE_IOM: 0x3

PROM_MODE_NAME = {}
PROM_MODE_NAME[v] = k for k, v of PROM_MODE

promModuleField = (card) ->
  a = card & 0xf
  (((a >> 2) & 1) << 7) | (((a >> 1) & 1) << 6) | ((a & 1) << 5) | (((a >> 3) & 1) << 4)

promModuleOf = (word) ->
  (((word >> 7) & 1) << 2) | (((word >> 6) & 1) << 1) | ((word >> 5) & 1) | (((word >> 4) & 1) << 3)

promParity = (w15) ->
  n = 0
  x = w15 & 0x7fff
  while x
    n ^= x & 1
    x >>>= 1
  if n then 0 else 0x8000

encodePromWord = (mode, card, channel, count = 1) ->
  w = ((mode & 0x3) << 13) | ((channel & 0x1f) << 8) | promModuleField(card) | ((count - 1) & 0xf)
  (w | promParity(w)) & 0xffff

encodePromClass = (cls) ->
  c = cls & 0xf
  ((c & 1) << 7) | (((c >> 1) & 1) << 6) | (((c >> 2) & 1) << 5) | (((c >> 3) & 1) << 4)

promClassOf = (word) ->
  ((word >> 7) & 1) | (((word >> 6) & 1) << 1) | (((word >> 5) & 1) << 2) | (((word >> 4) & 1) << 3)

decodePromWord = (word) ->
  w = word & 0xffff
  {
    raw:     w
    parity:  (w >>> 15) & 1
    mode:    (w >>> 13) & 0x3
    channel: (w >>> 8) & 0x1f
    card:    promModuleOf(w)
    count:   (w & 0xf) + 1
    cls:     promClassOf(w)
    name:    PROM_MODE_NAME[(w >>> 13) & 0x3]
  }

fmtPromWord = (p) -> "#{p.name} card #{p.card} ch #{p.channel} x#{p.count}"

IO_OP =
  SET:        1
  RESET:      2
  REQUEST:    3
  VALUE:      4
  POLL:       5
  CONNECT:    6
  DISCONNECT: 7

# The SEV bits of a response data word.  JSC-18611 Rev.G sect.28.2: "A
# proper (valid) code is always 101."  "The E-bit is associated with
# serial I/O modules.  If serial I/O data are not successfully received
# (no data, improper sync, invalid Manchester code, or bad parity), the
# E-bit is set to a logical '1' (invalid)."
SEV = {S: 0b100, E: 0b010, V: 0b001, VALID: 0b101}
SEV_E_SET = SEV.VALID | SEV.E

# The serial I/O card clocks its device one word at a time.  JSC-18611
# Rev.G fig.3-10, the NSP: "33.5 +/-5 usec word discrete pulse", "32 X
# (33.5 +/-5 usec) = 1072 +/-48 usec (total readout time)".  The readout
# runs whether or not the device answers a word discrete, so a read of n
# serial words is on the flight bus this long after the command.
SIO_WORD_US = 33.5
sioReadoutUs = (n) -> Math.round(n * SIO_WORD_US)

SERIAL_ANSWER_MS = 20

IO_OP_NAME = {}
IO_OP_NAME[v] = k for k, v of IO_OP

IO_ALL = 0xff
IO_HEADER_WORDS = 4

encodeIO = (m) ->
  words = m.words ? []
  out = new Uint16Array(IO_HEADER_WORDS + words.length)
  out[0] = m.op & 0xffff
  out[1] = (m.type ? 0) & 0xffff
  out[2] = (((m.card ? IO_ALL) & 0xff) << 8) | ((m.channel ? IO_ALL) & 0xff)
  out[3] = (if m.op == IO_OP.POLL then (m.count ? 0) else words.length) & 0xffff
  out[IO_HEADER_WORDS + i] = words[i] & 0xffff for i in [0...words.length] by 1
  out

decodeIO = (data16) ->
  return null unless data16?.length >= IO_HEADER_WORDS
  op = data16[0] & 0xffff
  return null unless IO_OP_NAME[op]?
  n = data16[3] & 0xffff
  payload = if op == IO_OP.POLL then 0 else n
  return null unless data16.length >= IO_HEADER_WORDS + payload
  {
    op:      op
    opName:  IO_OP_NAME[op]
    type:    data16[1] & 0xffff
    card:    (data16[2] >>> 8) & 0xff
    channel: data16[2] & 0xff
    count:   n
    words:   (data16[IO_HEADER_WORDS + i] & 0xffff for i in [0...payload] by 1)
  }

fmtIOAddr = (m) ->
  card = if m.card == IO_ALL then '*' else m.card
  ch = if m.channel == IO_ALL then '*' else m.channel
  "#{card}/#{ch}"

fmtIO = (m) ->
  t = IOM_BY_CODE[m.type]?.name ? (if m.type then "type#{m.type}" else '')
  tail = if m.op == IO_OP.POLL then "x#{m.count}" else (w.toString(16).padStart(4, '0') for w in m.words).join(' ')
  "#{m.opName} #{t} #{fmtIOAddr(m)} #{tail}".replace(/\s+/g, ' ').trim()

# "card/channel", "card" alone meaning channel 0, "*" for every.
parseIOAddr = (s) ->
  t = String(s).trim()
  [a, b] = t.split('/')
  one = (x) ->
    return IO_ALL if x == '*'
    n = parseInt(x, 10)
    if isNaN(n) or n < 0 or n > 0xfe then null else n
  card = one(a)
  channel = if b? then one(b) else 0
  return null unless card? and channel?
  {card, channel}

export {
  IUA, ioBusName
  MODE, MODE_NAME, modeName, SPARE_MODES, DO_SET_BIT
  decodeCommand, encodeDirect, encodeIndirect, returnWord, fmtCommand
  BSR, BSR_NAME, bsrBit, describeBSR
  IOM, IOM_BY_CODE, IOM_CLASS_NONE, iomType, cardChannels, BITE_REF_VOLTS, SIO_BITE_WORDS
  ANALOG_LSB_VOLTS, ANALOG_MIN, ANALOG_MAX, voltsToWord, wordToVolts
  AOD_LSB_VOLTS, AOD_MIN, AOD_MAX, voltsToAodWord, aodWordToVolts
  PROM_WORDS, PROM_CLASS_WORDS, PROM_PROGRAM_BASE, PROM_MAX_INSTR, PROM_MAX_WORDS
  PROM_MODE, PROM_MODE_NAME, promModuleField, promModuleOf, promParity
  encodePromWord, encodePromClass, promClassOf, decodePromWord, fmtPromWord
  IO_OP, IO_OP_NAME, IO_ALL, IO_HEADER_WORDS, SERIAL_ANSWER_MS
  SEV, SEV_E_SET, SIO_WORD_US, sioReadoutUs
  encodeIO, decodeIO, fmtIO, fmtIOAddr, parseIOAddr
}
