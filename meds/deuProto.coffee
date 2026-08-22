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
export FUNC_SHIFT = 9
export COUNT_MASK = 0x1ff

# TIME_FILL:  Used to update the standard GMT/MET clock displays:
export FUNC =
  TIME_FILL:     0x380   # the header clock: 7 halfwords, see TIME_FILL_WORDS
  DISPLAY_FILL:  0x38c   # display data fill -- AND the IPL memory-fill blocks
  FORMAT_FILL:   0x394   # format data fill (a critical-format background)
  MEDS_XFER:     0x398   # MEDS DK buffer transfer, always 100 halfwords
  DUMP:          0x3a0   # memory dump request
  POLL:          0x010   # poll / mode status request
  BITE:          0x040   # BITE status request
  RESET_SPL:     0x080   # reset the scratch pad line

export FUNC_NAME = {}
FUNC_NAME[v] = k for k, v of FUNC

# How many halfwords the GPC reads back
export POLL_WORDS = 16     # header, key count, 10 keys, 3 BITE, checksum
export BITE_WORDS = 5
# The same poll command, 0x502000, serves two bus programs: the normal poll
# reads sixteen halfwords, the mode-status check the DEU loader makes between
# blocks of a load reads one.  Nothing in the command distinguishes them, so
# a unit sizes its reply from context -- being loaded is that context.
export MODE_STATUS_WORDS = 1

# The DEU loader's own terminating condition: of its table of fill blocks,
# the one whose word count is 250 is the last, and a unit can use the same
# test to know its load is over.  That block is the low-core fill at DEU
# address 2, into which the GPC patches the unit's id at DEU_ID_ADDR.
export LAST_FILL_WORDS = 250
export DEU_ID_ADDR = 0x001d
export MEDS_XFER_WORDS = 100

export decodeCommand = (cmd24) ->
  cmd = cmd24 & 0xffffff
  {
    raw:   cmd
    iua:   (cmd >>> 19) & 0x1f
    func:  (cmd >>> FUNC_SHIFT) & 0x3ff
    count: cmd & COUNT_MASK
    name:  FUNC_NAME[(cmd >>> FUNC_SHIFT) & 0x3ff] ? 'UNKNOWN'
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
# We don't have enough documentation to confidently lay out the entire DEU
# memory map, but docs do have *some* important addresses and we can infer
# others from the messages that we need to handle.
#
# See the top of IDP.coffee for an approximate map.
#
# 8192 halfwords.  The addresses the flight software fills at, and the ones
# its display program branches through.
# ---------------------------------------------------------------------------
export DEU_MEMORY_WORDS = 8192
export ADDR =
  CRITICAL_FORMAT: 0x0100   # the critical-format index table and backgrounds
  VAR_DATA_HDR:    0x09ee   # variable data, with a header
  VAR_DATA_NOHDR:  0x0a06   # variable data, no header
  CF_CHECKSUM:     0x0f48
  CONTROL_PROGRAM: 0x0f49   # where the DEU's own IPL load starts
  DISPLAY_HEADER:  0x19ee   # the display header -- where a refresh starts
  UPLINK_IND:      0x1a06
  DYNAMIC:         0x1a0e   # the dynamic portion of the display
  BACKGROUND_TOP:  0x1fe4   # a background is filled ENDING just below here

# ---------------------------------------------------------------------------
# The poll response -- 16 halfwords
#
#   1     message header
#   2     number of keystrokes (6 bits)
#   3-12  the keystroke buffer
#   13-15 BITE status registers 1..3
#   16    checksum
#
# The header's bits are numbered from the most significant.
# ---------------------------------------------------------------------------
export HDR =
  MSG_RESET:      0x0800   # the MSG RESET key is down
  MAJOR_FUNC:     0x00c0   # the major function switch, bits 9-10
  ACK:            0x0020   # the ACK key is down
  KYBD_MSG:       0x0008   # a keyboard message is ready
  SELF_TEST:      0x0004   # stand-alone self test in progress
  BITE_CRITICAL:  0x0002   # critical BITE status present
  IPL_REQUIRED:   0x0001   # the unit needs an IPL

export MAJOR_FUNC_SHIFT = 6
export KEY_COUNT_MASK = 0x003f
export KEY_WORDS = 10

# ---------------------------------------------------------------------------
# Keystrokes in the poll response
#
# THREE keystrokes to a halfword, 5 bits each, most significant first:
# bits 15-11 are the first key, 10-6 the second, 5-1 the third, bit 0 spare.
#
# The count word is `KEY_COUNT_HIGH | count`
export KEYS_PER_WORD = 3
export KEY_BITS = 5
export KEY_COUNT_HIGH = 0xff00
# ---------------------------------------------------------------------------
# The time fill (function TIME_FILL, 7 halfwords).
#
#   TIMEFILL DC X'41000000'  T  MISSION TIME    3 halfwords, extended float
#            DC H'0'         T                      in seconds
#            DC X'41000000'  T  EVENT TIME      3 halfwords
#            DC H'0'         T                      in seconds
#            DC X'0001'      T  TIME CONVERSION WORD
#
#
# 0x0001 is the only known value for the time conversion word.
# ---------------------------------------------------------------------------
export TIME_FILL_WORDS = 7

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

# BITE status register 1.  
# To successfully communicate with the GPC, we must return
# BITE1_HEALTHY.
export BITE1 =
  ALWAYS_ONE:        0x8000
  IPL_DONE:          0x4000
  IPL_ERROR:         0x2000
  IPL_CIRCUIT_ERROR: 0x1000
export BITE1_HEALTHY = BITE1.ALWAYS_ONE | BITE1.IPL_DONE

# The unit's software status register -- poll response word 15, the third of
# the three status halfwords.  To communicate with the GPC, we need
# SWSTATUS_HEALTHY.
export SWSTATUS =
  INITIALIZED: 0x2000
  INT_MASK:    0x2010      # the two bits the monitor examines
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
  words[1] = KEY_COUNT_HIGH | (keys.length & KEY_COUNT_MASK)
  packed = packKeys(keys)
  words[2 + i] = packed[i] for i in [0...KEY_WORDS]
  words[12] = (o.bite1 ? BITE1_HEALTHY) & 0xffff
  words[13] = (o.bite2 ? 0) & 0xffff
  words[14] = (o.swStatus ? SWSTATUS_HEALTHY) & 0xffff
  words[15] = checksum(words[0...15])
  words

# The five-halfword BITE status response.  Register 1 leads it, for the same
# reason it does in the poll.
export biteResponse = (o = {}) ->
  words = [(o.bite1 ? BITE1_HEALTHY) & 0xffff,
           (o.bite2 ? 0) & 0xffff,
           (o.swStatus ? SWSTATUS_HEALTHY) & 0xffff,
           (o.software ? 0) & 0xffff, 0]
  words[4] = checksum(words[0...4])
  words
