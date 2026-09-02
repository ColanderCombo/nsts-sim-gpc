#
# The DEU / IDP display-keyboard bus protocol.
#
# A GPC talks to the four DEUs over the 4 DK buses (DK1..DK4 = BCE 6..9)
# using IUA=10.  Every transaction is one 24-bit command word from the 
# GPC followed by data in whichever direction the command names.  This 
#
# The MCDS->MEDS update did not change the basic protocol.  An IDP answers 
# the same commands a DEU did; the additions are one new command 
# (the 100-halfword MEDS DK buffer transfer) and a couple of new/updated
# FCWS (landing site glyphs and colour support).
#

# Interface unit address of the display units on the DK bus.
export IUA = 10

# The 19 command bits are a 10-bit function and a 9-bit halfword count.
# JSC-18820/sect.4.6.1.1 splits the function further: a five-bit message type
# FIELD, a three-bit SUBFIELD, and two bits that are not used.  Only the
# 11100 family reads the subfield -- everywhere else it is a don't-care, so
# matching a whole function word exactly would miss commands a GPC may
# legitimately send.
export FUNC_SHIFT = 9
export COUNT_MASK = 0x1ff
export FIELD_MASK = 0x3e0        # the function's top five bits
export SUBFIELD_MASK = 0x01c

export FUNC =
  TIME_FILL:     0x380   # the header clock: 7 halfwords, see TIME_FILL_WORDS
  DISPLAY_FILL:  0x38c   # display data fill -- AND the IPL memory-fill blocks
  FORMAT_FILL:   0x394   # format data fill (a critical-format background)
  MEDS_XFER:     0x398   # MEDS DK buffer transfer, always 100 halfwords
  DUMP:          0x3a0   # memory dump request (GNC OPS 9 only)
  POLL:          0x010   # poll / mode status request
  BITE:          0x040   # BITE status request
  RESET_SPL:     0x080   # reset the scratch pad line
  BUFFER_FILL:   0x0c0   # fill via the I/O buffer: at most 23 halfwords,
                         # a test path (JSC-18820/sect.4.6.1.1.4)

# The commands whose subfield is a don't-care are matched on the field alone.
FIELD_ONLY = {}
FIELD_ONLY[FUNC[k] & FIELD_MASK] = k for k in \
  ['BITE', 'RESET_SPL', 'BUFFER_FILL', 'DUMP']

export FUNC_NAME = {}
FUNC_NAME[v] = k for k, v of FUNC

export funcName = (func) ->
  FUNC_NAME[func] ? FIELD_ONLY[func & FIELD_MASK] ? 'UNKNOWN'

export funcCanonical = (func) ->
  return func if FUNC_NAME[func]?
  n = FIELD_ONLY[func & FIELD_MASK]
  if n? then FUNC[n] else func

# How many halfwords the GPC reads back
export POLL_WORDS = 16     # header, key count, 10 keys, 3 BITE, checksum
export BITE_WORDS = 5
# The same poll command, 0x502000, serves two bus programs: the normal poll
# reads sixteen halfwords, the mode-status check the DEU loader makes between
# blocks of a load reads one.  Nothing in the command distinguishes them, so
# a unit sizes its reply from context -- being loaded is that context.
export MODE_STATUS_WORDS = 1

# The DEU loader's terminating condition: of its table of fill blocks,
# the one whose word count is 250 is the last, and a unit can use the same
# test to know its load is over.  That block is the low-core fill at DEU
# address 2, into which the GPC patches the unit's id at DEU_ID_ADDR.
export LAST_FILL_WORDS = 250
export DEU_ID_ADDR = 0x001d
export MEDS_XFER_WORDS = 100

export decodeCommand = (cmd24) ->
  cmd = cmd24 & 0xffffff
  raw = (cmd >>> FUNC_SHIFT) & 0x3ff
  {
    raw:      cmd
    iua:      (cmd >>> 19) & 0x1f
    func:     funcCanonical(raw)
    rawFunc:  raw
    field:    (raw & FIELD_MASK) >> 5
    subfield: (raw & SUBFIELD_MASK) >> 2
    count:    cmd & COUNT_MASK
    name:     funcName(raw)
  }

export encodeCommand = (func, count = 0) ->
  ((IUA << 19) | ((func & 0x3ff) << FUNC_SHIFT) | (count & COUNT_MASK)) >>> 0

# ---------------------------------------------------------------------------
# The memory-fill message
#
# Word 1 is the number of format control words, word 2 the DEU address they
# load at, and the words after that are the payload.  The transfer count is
# therefore the payload length plus two.
#
# The address is the plain 13-bit DEU address.  The DEU loader writes its
# eight fill addresses out literally and they include 0x0F49 and 0x0002 with
# bit 12 clear and 0x1FE4 with it set -- the OR reconstitutes the top bit of
# an address that really is 0x19EE.
# ---------------------------------------------------------------------------
export ADDR_MASK = 0x1fff

# The transfer count is nine bits: no transfer exceeds 511 halfwords, so a
# fill carries at most 509 format control words (the header takes two):
export MAX_TRANSFER_WORDS = COUNT_MASK          # 511
export MAX_FILL_PAYLOAD = MAX_TRANSFER_WORDS - 2

export fillHeader = (addr, nWords) -> [nWords & 0xffff, addr & ADDR_MASK]

# Split content into the fills that carry it: `[{func, addr, count, body}]`,
# each within the transfer limit, at successive addresses.
export fillMessages = (func, addr, words, limit = MAX_FILL_PAYLOAD) ->
  out = []
  i = 0
  while i < words.length
    chunk = words[i...i + limit]
    body = fillHeader(addr + i, chunk.length).concat(chunk)
    out.push {func: func, addr: addr + i, count: body.length, body: body}
    i += limit
  out

export parseFill = (words) ->
  return null if words.length < 2
  n = words[0] & 0xffff
  short = (words.length - 2) < n
  {addr: words[1] & ADDR_MASK, count: n, payload: words.slice(2, 2 + n),
   short: short}

# ---------------------------------------------------------------------------
# The DEU memory map
#
# The documentation we have does not lay out the whole DEU memory map.  It
# gives some addresses outright; the rest are inferred from the messages
# the model handles.
#
# See the top of idp.coffee for an approximate map.
#
# ---------------------------------------------------------------------------
export DEU_MEMORY_WORDS = 8192
# MESSAGE LINE BUFFER is 50 halfwords at 6588 and DISPLAY BUFFER begins at
# 6638, so the two are contiguous: a refresh entered at the message line
# draws it and falls straight through into the display list, with no branch
# between them and none needed.
export MESSAGE_LINE_WORDS = 50
export ADDR =
  CRITICAL_FORMAT: 0x0100   # the critical-format index table and backgrounds
  VAR_DATA_HDR:    0x09ee   # variable data, with a header
  VAR_DATA_NOHDR:  0x0a06   # variable data, no header
  CF_CHECKSUM:     0x0f48
  CONTROL_PROGRAM: 0x0f49   # where the DEU's own IPL load starts
  MESSAGE_LINE:    0x19bc   # the message line buffer, 50 halfwords...
  DISPLAY_HEADER:  0x19ee   # ...running straight into the display header
  UPLINK_IND:      0x1a06
  DYNAMIC:         0x1a0e   # the dynamic portion of the display
  BACKGROUND_TOP:  0x1fe4   # a background is filled ENDING just below here

# ---------------------------------------------------------------------------
# The poll response -- 16 halfwords
#
#   1     message header
#   2     format index and the keystroke count
#   3-12  the keystroke buffer
#   13    hardware status word 1
#   14    hardware status word 2
#   15    the software status word
#   16    checksum
#
# JSC-11174,Vol.1,Rev.D dwg 8.3 note 22 gives the whole response, and
# JSC-18820/sect.4.6.1 the same in prose.  A word on the wire is 28 bits --
# 1-3 data sync, 4-8 the DEU address, 9-24 the sixteen data bits, 25-27 SEV,
# 28 parity -- and only bits 9-24 reach memory, so the bit numbers below run
# most significant first: data bit 9 is 0x8000.
# ---------------------------------------------------------------------------
export HDR =
  MSG_TYPE:       0xf000   # bits 9-12, zero in a poll response
  MSG_RESET:      0x0800   # bit 13, the MSG RESET key is down
  DEU_ID:         0x0700   # bits 14-16, the unit's identity
  MAJOR_FUNC:     0x00c0   # bits 17-18, the major function switch
  ACK:            0x0020   # bit 19, the ACK key is down
  DISPLAY_FREEZE: 0x0010   # bit 20
  KYBD_MSG:       0x0008   # bit 21, a keyboard message is ready
  SELF_TEST:      0x0004   # bit 22, stand-alone self test in progress
  BITE_CRITICAL:  0x0002   # bit 23, critical BITE status present
  IPL_REQUIRED:   0x0001   # bit 24, the unit needs an IPL

# "Following the DEU transmission of this response, bits 13, 19, 21, and 23 of
# the header word are reset" -- MSG RESET, ACK, KYBD MSG and CRITICAL BITE are
# all self-clearing.  The last two are derived here, so only the first two
# need taking back; see `DEUUnit.takeHeader`.
export HDR_SELF_CLEARING = HDR.MSG_RESET | HDR.ACK |
                           HDR.KYBD_MSG | HDR.BITE_CRITICAL

export MAJOR_FUNC_SHIFT = 6
export DEU_ID_SHIFT = 8

# Major Function Switch, JSC-18820/sect.4.4: 
# A failed switch reports the last valid position, or GNC if it failed
# before one was ever read"
export MAJOR_FUNC_CODE =
  PL:  0    # ...or DEU load
  GNC: 1
  SM:  2
export MAJOR_FUNC_NAME = {}
MAJOR_FUNC_NAME[v] = k for k, v of MAJOR_FUNC_CODE
# What a DEU reports before a valid position has ever been read.
export MAJOR_FUNC_DEFAULT = MAJOR_FUNC_CODE.GNC

# The header's multi-bit fields, so a flag decoder can skip them.
export HDR_FIELDS = ['MSG_TYPE', 'DEU_ID', 'MAJOR_FUNC']

# Response word 2.  The drawing gives bits 9-16 as the FORMAT INDEX, 17-19 as
# unused, and 20-24 as the keystroke count -- thirty codes at most, so five
# bits.  Every count word yet taken off the wire carries 0xff in the index,
# which is what the GPC IPL monitor's `XOR 0xff00` to recover the count
# assumes, so that is the default here.
export FORMAT_INDEX_MASK = 0xff00
export FORMAT_INDEX_SHIFT = 8
export FORMAT_INDEX_NONE = 0xff
# The whole top byte at its default, which is what the monitor XORs away.
export KEY_COUNT_HIGH = FORMAT_INDEX_NONE << FORMAT_INDEX_SHIFT
export KEY_COUNT_MASK = 0x001f
export KEY_WORDS = 10

# ---------------------------------------------------------------------------
# Keystrokes in the poll response
#
# THREE keystrokes to a halfword, 5 bits each, most significant first:
# bits 15-11 are the first key, 10-6 the second, 5-1 the third, bit 0 spare.
# "Unused keystroke codes will be padded zero."  The count word is above.
export KEYS_PER_WORD = 3
export KEY_BITS = 5
# ---------------------------------------------------------------------------
# The time fill (function TIME_FILL, 7 halfwords).
#
#   TIMEFILL DC X'41000000'  T  MISSION TIME    3 halfwords, extended float
#            DC H'0'         T                      in seconds
#            DC X'41000000'  T  EVENT TIME      3 halfwords
#            DC H'0'         T                      in seconds
#            DC X'0001'      T  TIME CONVERSION WORD
#
# JSC-18820/sect.4.6.1.1.5: 
# the time fill "contains control information to allow starting, stopping, 
# incrementing, or decrementing the time values"
#
# That's the TIME CONVERSION WORD.  The only value we've seen so far 
# is X'0001', so we should keep watch for anything different.
# ---------------------------------------------------------------------------
export TIME_FILL_WORDS = 7

# The only TIME CONVERSION WORD seen; `DEUUnit._timeFill` reports any other.
export TIME_CONV_SEEN = 0x0001

# A 48-bit IBM extended float: sign, 7-bit exponent biased by 64, and a
# 40-bit fraction in base 16.  (0x41000000 0000 is 0.0; 0x41100000 0000 is
# 1.0 -- 1/16 x 16^1.)
export ibmFloat48 = (w0, w1, w2) ->
  sign = if (w0 & 0x8000) then -1 else 1
  exp  = ((w0 >> 8) & 0x7f) - 64
  frac = ((w0 & 0xff) * 0x100000000) + (w1 * 0x10000) + w2
  sign * (frac / 0x10000000000) * Math.pow(16, exp)

# Seconds -> the three halfwords.  Zero goes out as exponent 0x41 with a zero
# fraction -- what the monitor's buffer holds before its first tick
# (`DC X'41000000'`) -- not the all-zero word an IBM true zero would be.
export encodeIbmFloat48 = (v) ->
  return [0x4100, 0x0000, 0x0000] if not v
  sign = if v < 0 then 0x8000 else 0
  a = Math.abs(v)
  e = 0
  while a >= 1
    a /= 16 ; e++
  while a < 1/16
    a *= 16 ; e--
  frac = Math.round(a * 0x10000000000)
  if frac >= 0x10000000000                      # rounding carried into the exponent
    frac = Math.floor(frac / 16) ; e++
  [sign | (((e + 64) & 0x7f) << 8) | Math.floor(frac / 0x100000000),
   Math.floor(frac / 0x10000) & 0xffff,
   frac & 0xffff]

export timeFillWords = (t = {}) ->
  encodeIbmFloat48(t.mission ? 0)
    .concat(encodeIbmFloat48(t.event ? 0))
    .concat([(t.conv ? 1) & 0xffff])

export parseTimeFill = (words) ->
  return null if words.length != TIME_FILL_WORDS
  mission: ibmFloat48(words[0], words[1], words[2])
  event:   ibmFloat48(words[3], words[4], words[5])
  conv:    words[6] & 0xffff

export MAX_KEYS = KEY_WORDS * KEYS_PER_WORD      # 30 the buffer can carry
export MAX_KEYS_IPL = 6                          # ...and 6 the monitor takes

export packKeys = (keys) ->
  words = new Array(KEY_WORDS).fill(0)
  for k, i in keys[0...MAX_KEYS]
    w = Math.floor(i / KEYS_PER_WORD)
    slot = i %% KEYS_PER_WORD                    # 0 is the most significant
    shift = 16 - KEY_BITS * (slot + 1)
    words[w] |= (k & 0x1f) << shift
  words

export unpackKeys = (words, count) ->
  out = []
  for i in [0...count]
    w = words[Math.floor(i / KEYS_PER_WORD)] ? 0
    shift = 16 - KEY_BITS * ((i %% KEYS_PER_WORD) + 1)
    out.push (w >> shift) & 0x1f
  out

# The 5-bit key codes:
export KEY =
  '0': 0x00, '1': 0x01, '2': 0x02, '3': 0x03, '4': 0x04, '5': 0x05
  '6': 0x06, '7': 0x07, '8': 0x08, '9': 0x09
  A: 0x0a, B: 0x0b, C: 0x0c, D: 0x0d, E: 0x0e, F: 0x0f
  SYS_SUMM: 0x10, OPS: 0x11, SPEC: 0x12, FAULT_SUMM: 0x13, ITEM: 0x14
  MINUS: 0x15, PLUS: 0x16, DECIMAL: 0x17, IO_RESET: 0x18, GPC_CRT: 0x19
  CLEAR: 0x1a, RESUME: 0x1b, ACK: 0x1c, MSG_RESET: 0x1d, EXEC: 0x1e
  PRO: 0x1f

export KEY_NAME = {}
KEY_NAME[v] = k for k, v of KEY

# ---------------------------------------------------------------------------
# The status registers
#
# Three are hardware, latched by the box; the fourth the control program
# keeps.  Bits are numbered most significant first.  All four lead with a
# hard-wired one, so a register reading zero is a dead unit.  The DEU
# stand-alone self test displays them, and its normal reading is
# `8200 8000 8000 0000` (STS-83-0020V2-34/sect.4.6.8 para 17).
# ---------------------------------------------------------------------------

# Hardware status register 1.  The control program reads it to form the
# poll response's first status word.  Every bit is named in
# JSC-18820/sect.4.6.1.3.1; bits 9-11, 13 and 14 are the analog and wrap
# tests the stand-alone self test arms, and are not modelled.
export BITE1 =
  ALWAYS_ONE:        0x8000   # bit 0
  IPL_DONE:          0x4000   # bit 1, "IPL PROM is control of DEU"
  IPL_ERROR:         0x2000   # bit 2, detected by PROM or cyclic circuit check
  IPL_CIRCUIT_ERROR: 0x1000   # bit 3, not used
  SG_INTENSITY:      0x0800   # bit 4, symbol generator intensity parity
  SG_SINCOS:         0x0400   # bit 5, ... sine-cosine ROM parity
  SG_ACTIVE:         0x0200   # bit 6, "symbol generator is processing the
                              #   contents of the refresh buffer" -- NOT an
                              #   error, and the only other bit a healthy
                              #   register carries
  SG_CHARACTER:      0x0100   # bit 7, character generator ROM parity
  OSCILLATOR:        0x0080   # bit 8
  SG_ZERO_DEFL:      0x0040   # bit 9, SASTP
  SG_NONZERO_DEFL:   0x0020   # bit 10, SASTP
  SG_PULSE:          0x0010   # bit 11, SASTP
  CIRCLE_OSC:        0x0008   # bit 12, circle repetition rate goes to zero
  SG_ANALOG:         0x0004   # bit 13, the OR of bits 9, 10 and 11
  SG_WRAP:           0x0002   # bit 14, SASTP display wrap
  SG_REFRESH:        0x0001   # bit 15, the refresh is overdue by 18 ms
# Bit 6 says a healthy register reads 0x8200, not 0x8000: the self test's
# STATUS line is `8200 8000 8000 0000` (STS-83-0020V2-34/sect.4.6.8) and
# so is the OTP display's status line in JSC-18820 figure 4-30, taken off a
# DEU with the control program running.  Neither has bit 1 set, which fits
# sect.4.6.1.3.1's reading of it -- "IPL PROM is control of DEU", true only
# while an IPL is under way -- and not the one below, where IPL_DONE means
# "loaded, and not asking for another".  The poll path reads it that way
# (dcp.asm sets IPL REQUIRED when it is clear), so changing it changes what
# every GPC sees; left alone, and recorded here.
export BITE1_HEALTHY = BITE1.ALWAYS_ONE | BITE1.IPL_DONE

# Hardware status register 2 -- the CPU and the two interfaces.
export BITE2 =
  ALWAYS_ONE:       0x8000   # bit 0
  CPU_SOFTWARE_FAIL: 0x0080  # bit 8
  KBA_A_ERROR:      0x0040   # bit 9, critical BITE
  KBA_B_ERROR:      0x0020   # bit 10, critical BITE
  MIA_ECHO_ERROR:   0x0010   # bit 11
  MIA_PARITY_ERROR: 0x0008   # bit 12
  MIA_MANCHESTER:   0x0004   # bit 13
  MIA_BIT_COUNT:    0x0002   # bit 14
  MIA_CMD_ERROR:    0x0001   # bit 15, the OR of bits 12-14
export BITE2_HEALTHY = BITE2.ALWAYS_ONE

# Hardware status register 3 -- the display unit.  Carried by the BITE
# command's response, not by the poll.
export BITE3 =
  ALWAYS_ONE:       0x8000   # bit 0
  DU_DEFLECTION:    0x4000   # bit 1
  DU_VIDEO:         0x2000   # bit 2
  DU_PHOS_PROTECT:  0x1000   # bit 3, not used
  DU_FILAMENT:      0x0400   # bit 5
  DU_TEMPERATURE:   0x0200   # bit 6
  DU_POWER_SUPPLY:  0x0001   # bit 15
export BITE3_HEALTHY = BITE3.ALWAYS_ONE

# The software status word -- poll response word 15, and the last of the four
# the self test displays.  Every bit is something the control program itself
# detects, so this register is the DCP's report card.  Unlike the three
# hardware registers it does not lead with a one: healthy is zero, and the
# self test reads 0000 except just after a load, when INITIALIZED stands.
export SWSTATUS =
  FILL_DATA_ERROR:  0x8000   # bit 0, display/format data fill error
  INITIALIZED:      0x2000   # bit 2, initialization performed, critical BITE
  BAD_FILL_COUNT:   0x1000   # bit 3, invalid fill/dump word count
  MIA_WRAP_ERROR:   0x0800   # bit 4
  COMMAND_OVERLOAD: 0x0400   # bit 5
  CPU_PARITY:       0x0100   # bit 7, CPU memory parity, critical BITE
  BAD_MESSAGE:      0x0040   # bit 9, invalid message received
  RIPPLE_TEST:      0x0020   # bit 10
  CHECKSUM_ERROR:   0x0010   # bit 11, format/IPL
  BAD_FILL_ADDR:    0x0008   # bit 12, invalid fill/dump data address
  MESSAGE_SHORT:    0x0004   # bit 13, received message incomplete
  CPU_SELF_TEST:    0x0002   # bit 14, critical BITE
  XMIT_INCOMPLETE:  0x0001   # bit 15, incomplete DEU transmission
  INT_MASK:         0x2010   # the two bits the monitor examines:
                             # initialized, and no format/IPL checksum error
# What the GPC monitor requires to talk to a unit.  A real DEU latches
# INITIALIZED once after a load and clears it when the status is read; this
# model reports it continuously, which is what the monitor's INT_MASK test
# has always been given.
export SWSTATUS_HEALTHY = SWSTATUS.INITIALIZED

# GPC compatible checksum: sub the first fifteen, negates, and compares.
export checksum = (words) ->
  s = 0
  s = (s + (w & 0xffff)) & 0xffff for w in words
  (-s) & 0xffff

# Build a poll response.  `keys` is up to 30 five-bit key codes, three to a
# halfword; anything past the buffer is dropped
export pollResponse = (o = {}) ->
  words = new Array(POLL_WORDS).fill(0)
  words[0] = (o.header ? 0) & 0xffff
  keys = (o.keys ? [])[0...MAX_KEYS]
  words[1] = (((o.formatIndex ? FORMAT_INDEX_NONE) << FORMAT_INDEX_SHIFT) &
              FORMAT_INDEX_MASK) | (keys.length & KEY_COUNT_MASK)
  packed = packKeys(keys)
  words[2 + i] = packed[i] for i in [0...KEY_WORDS]
  words[12] = (o.bite1 ? BITE1_HEALTHY) & 0xffff
  words[13] = (o.bite2 ? BITE2_HEALTHY) & 0xffff
  words[14] = (o.swStatus ? SWSTATUS_HEALTHY) & 0xffff
  words[15] = checksum(words[0...15])
  words

# The five-halfword BITE status response: the three hardware registers, the
# software status word, and the checksum -- the four the self test displays,
# in the order it displays them.  The poll carries only 1, 2 and the software
# word; register 3, the display unit's, is read out here.
export biteResponse = (o = {}) ->
  words = [(o.bite1 ? BITE1_HEALTHY) & 0xffff,
           (o.bite2 ? BITE2_HEALTHY) & 0xffff,
           (o.bite3 ? BITE3_HEALTHY) & 0xffff,
           (o.swStatus ? SWSTATUS_HEALTHY) & 0xffff, 0]
  words[4] = checksum(words[0...4])
  words
