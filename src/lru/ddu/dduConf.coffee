#
# The GPC's flight instrument output on the flight critical busses: the
# DDU write and the MEDS FC GNC transfer.
#
# The high frequency executive writes each of FC1 to FC4 the same
# sequence every 40 ms (OI30 build listing, SSSRC/FIOHFEPG, "HFE OUTPUT
# BCE PROGRAM"): the four MEDS messages to IUA 15, then the 14 ADI words
# to DDU 1, 2 and 3, the 10 HSI words to DDU 1 and 2, the 6 AVVI words
# and the 6 AMI words to DDU 1 and 2.  The IUAs are 6, 9 and 15 for DDU 1
# to 3 (SSSRC/FIOPRMPG, the BCEEQU block).  A pre-MEDS DDU took its bus
# from the DATA BUS SELECT switch; an IDP hears all four busses and the
# MDU's DATA BUS edgekey picks the one its instruments follow
# (USA-005350 sect.2.3).  DDU 1 drives the commander's instruments, DDU 2
# the pilot's and DDU 3 the aft ADI.
#
# The command word is the bus's 24-bit word, IUA in the top five bits,
# framed on the simulated bus as com/bus.civet describes: a command
# datagram, then the data words.  The
# 19-bit payloads are the listing's equates:
#
#   Message  Payload       WC  Listing description
#   ADI      X'0004002E'   14  ADI DATA TYPE
#   HSI      X'0004004A'   10  HSI DATA TYPE
#   AVVI     X'00040086'    6  AVVI DATA TYPE
#   AMI      X'00040106'    6  AMI DATA TYPE
#   MEDS 1   X'0004081E'   30  MEDS FC COMMAND WORD MSG 1
#   MEDS 2   X'0004101E'   30  MEDS FC COMMAND WORD MSG 2
#   MEDS 3   X'0004201E'   30  MEDS FC COMMAND WORD MSG 3
#   MEDS 4   X'0004400A'   10  MEDS FC COMMAND WORD MSG 4
#
# so bit 18 marks a DDU or MEDS write, one bit of 5 to 14 names the
# message and the low five bits carry the word count.  The HUD messages
# share IUAs 6 and 9 with bit 18 clear (FIOHMSG1 X'0021F', FIOHMSG2
# X'0060C').
#
# Data words (STS-83-0020V3-34 Appendix F):
#
#   Message        Table
#   ADI            F.4.103.0-1
#   HSI            F.4.104.0-1
#   AMI            F.4.105.0-1
#   AVVI           F.4.106.0-1
#   MEDS transfer  F.4.128.1-2
#
# Scaling is specified in the text beside each table.
# The tables number bits 1 to 16 from the most significant; a field
# "bits a-b" here is read from that end.  "INTEGER" in the FSSR is the
# largest integer not above the value.
#

IUA =
  DDU1: 6
  DDU2: 9
  DDU3: 15
  MEDS: 15

DDU_OF_IUA = {6: 1, 9: 2, 15: 3}
IUA_OF_DDU = {1: 6, 2: 9, 3: 15}

DDU_WRITE_BIT = 0x40000

# The messages: the select bit of the command payload and the word count.
MSG =
  ADI:   {select: 0x020,  wc: 14}
  HSI:   {select: 0x040,  wc: 10}
  AVVI:  {select: 0x080,  wc: 6}
  AMI:   {select: 0x100,  wc: 6}
  MEDS1: {select: 0x800,  wc: 30}
  MEDS2: {select: 0x1000, wc: 30}
  MEDS3: {select: 0x2000, wc: 30}
  MEDS4: {select: 0x4000, wc: 10}

MSG_NAMES = Object.keys(MSG)
MSG_BY_SELECT = {}
MSG_BY_SELECT[v.select] = k for k, v of MSG
# A small code for a message name, for the IDP's message to the MDUs.
MSG_CODE = {}
MSG_CODE[k] = i + 1 for k, i in MSG_NAMES
MSG_OF_CODE = {}
MSG_OF_CODE[v] = k for k, v of MSG_CODE

# The HFE's output sequence on every FC bus, each cycle.
HFE_SEQUENCE = [
  {iua: IUA.MEDS, msg: 'MEDS1'}, {iua: IUA.MEDS, msg: 'MEDS2'}
  {iua: IUA.MEDS, msg: 'MEDS3'}, {iua: IUA.MEDS, msg: 'MEDS4'}
  {iua: IUA.DDU1, msg: 'ADI'},  {iua: IUA.DDU2, msg: 'ADI'},  {iua: IUA.DDU3, msg: 'ADI'}
  {iua: IUA.DDU1, msg: 'HSI'},  {iua: IUA.DDU2, msg: 'HSI'}
  {iua: IUA.DDU1, msg: 'AVVI'}, {iua: IUA.DDU2, msg: 'AVVI'}
  {iua: IUA.DDU1, msg: 'AMI'},  {iua: IUA.DDU2, msg: 'AMI'}
]

HFE_PERIOD_MS = 40

payloadOf = (msg) -> DDU_WRITE_BIT | MSG[msg].select | MSG[msg].wc

commandWord = (iua, msg) ->
  throw new Error("no such DDU message: #{msg}") unless MSG[msg]?
  (((iua & 0x1f) << 19) | payloadOf(msg)) >>> 0

# {iua, msg, wc, ddu} for a DDU or MEDS write, null for any other command.
decodeCommand = (cmd24) ->
  cmd = cmd24 & 0xffffff
  return null unless cmd & DDU_WRITE_BIT
  msg = MSG_BY_SELECT[cmd & 0x7fe0]
  return null unless msg?
  iua = (cmd >>> 19) & 0x1f
  wc = cmd & 0x1f
  ddu = if msg.startsWith('MEDS') then null else DDU_OF_IUA[iua]
  {iua, msg, wc, ddu}

hex4 = (v) -> (v & 0xffff).toString(16).padStart(4, '0')
hex6 = (v) -> (v & 0xffffff).toString(16).padStart(6, '0')

fmtCommand = (c) ->
  who = if c.ddu? then "DDU #{c.ddu}" else "IUA #{c.iua}"
  "#{who} #{c.msg} #{c.wc} words"

# words
#

s16 = (w) ->
  w &= 0xffff
  if w & 0x8000 then w - 0x10000 else w

u16 = (v) -> v & 0xffff

clamp = (v, lo, hi) -> Math.max(lo, Math.min(hi, v))

# The control word: bit 1 is C2, the validity of word 2, through to C14 at
# bit 13.  `n` is the 0-based index of the word in the message.
controlBit = (n) -> 0x8000 >>> (n - 1)
wordValid = (control, n) -> n == 0 or (control & controlBit(n)) != 0
controlWord = (n, valids) ->
  w = 0
  for i in [1...n] by 1
    w |= controlBit(i) if (valids?[i] ? true)
  w

# The fixed test words of tables F.4.103.0-1 to F.4.106.0-1.
TEST_WORD =
  ADI:  0x7ff8
  HSI:  0x7fc0
  AMI:  0xaaa9
  AVVI: 0xaaa9

# A pure fraction in -1..1, "8*INTEGER(4095*x)": the sines and cosines,
# the rate and error deflections as a fraction of full scale, the theta
# deltas.
fracToWord = (x) -> u16(8 * Math.floor(4095 * clamp(x, -1, 1)))
wordToFrac = (w) -> (s16(w) >> 3) / 4095

# An angle in degrees, "16*INTEGER(theta*1024/PI)": bit 2 weighs 180
# degrees, bits 2 to 12.
angleToWord = (deg) ->
  d = ((deg % 360) + 360) % 360
  u16(16 * Math.floor(d * 1024 / 180))
wordToAngle = (w) -> ((w >>> 4) & 0x7ff) * 180 / 1024

# A deviation count in -512..511, "64*INTEGER(x)": the CDI and GSI words,
# bits 1 to 10.  Full scale, +511, is +3 V at the DDU, three dots.
DEV_FULL_SCALE = 512
DEV_DOTS = 3
devToWord = (count) -> u16(64 * clamp(Math.floor(count), -512, 511))
wordToDev = (w) -> s16(w) >> 6
CDI_RAD_PER_COUNT = Math.PI / 24576
GSI_FT_PER_COUNT = 750 / 256
cdiDegToWord = (deg) -> devToWord(deg * Math.PI / 180 / CDI_RAD_PER_COUNT)
wordToCdiDeg = (w) -> wordToDev(w) * CDI_RAD_PER_COUNT * 180 / Math.PI
gsiFtToWord = (ft) -> devToWord(ft / GSI_FT_PER_COUNT)
wordToGsiFt = (w) -> wordToDev(w) * GSI_FT_PER_COUNT
devToDots = (count) -> count / DEV_FULL_SCALE * DEV_DOTS

# A distance in nautical miles as BCD, bits 2 to 15: 2000, 1000; 800..100;
# 80..10; 8..1, so the units digit sits at bits 12 to 15, above the zero
# at bit 16.
bcdToWord = (nm) ->
  n = clamp(Math.floor(nm), 0, 3999)
  th = Math.floor(n / 1000)
  hu = Math.floor(n / 100) % 10
  te = Math.floor(n / 10) % 10
  un = n % 10
  u16((th << 13) | (hu << 9) | (te << 5) | (un << 1))
wordToBcd = (w) ->
  ((w >>> 13) & 0x3) * 1000 + ((w >>> 9) & 0xf) * 100 + ((w >>> 5) & 0xf) * 10 + ((w >>> 1) & 0xf)

# ADI: table F.4.103.0-1
#
ADI_WORDS = ['control', 'test', 'rollSin', 'rollCos', 'pitchSin', 'pitchCos',
             'yawSin', 'yawCos', 'rollRate', 'pitchRate', 'yawRate',
             'rollErr', 'pitchErr', 'yawErr']

# AMI: table F.4.105.0-1
#
AMI_WORDS = ['control', 'test', 'mach', 'alpha', 'eas', 'accel']

# Word 3: 0.0075 mach a count, bits 2 to 13; 0 to 4 is mach, 4 to 27 the
# relative velocity in thousands of feet a second.
MACH_LSB = 0.0075
machToWord = (m) -> u16(8 * Math.floor(clamp(m, 0, 27) / MACH_LSB))
wordToMach = (w) -> ((w >>> 3) & 0xfff) * MACH_LSB

# Word 4: 0.015 degrees a count, bits 1 to 15.
ALPHA_LSB = 0.015
alphaToWord = (deg) -> u16(2 * Math.floor(clamp(deg, -180, 180) / ALPHA_LSB))
wordToAlpha = (w) -> (s16(w) >> 1) * ALPHA_LSB

# Word 5: 0.125 knots a count, bits 2 to 13, 0 to 500 knots.
EAS_LSB = 0.125
easToWord = (kt) -> u16(8 * Math.floor(clamp(kt, 0, 499.999) / EAS_LSB))
wordToEas = (w) -> ((w >>> 3) & 0xfff) * EAS_LSB

# Word 6: 0.00125 g a count below zero and 0.0025 g above, bits 1 to 13,
# -5 to +10 g.  The MEDS target Nz (message 1 word 28) is the same.
accelToWord = (g) ->
  g = clamp(g, -5, 9.999)
  u16(8 * Math.floor(g / (if g < 0 then 0.00125 else 0.0025)))
wordToAccel = (w) ->
  c = s16(w) >> 3
  c * (if c < 0 then 0.00125 else 0.0025)

# AVVI: table F.4.106.0-1
#
AVVI_WORDS = ['control', 'test', 'altitude', 'hdot', 'radarAlt', 'vertAccel']

# Word 3: five ranges over -1100 to 10^6 ft, bits 2 to 13, count 0 at
# -1100 ft.
ALT_MIN = -1100
ALT_MAX = 1e6
altToWord = (ft) ->
  a = clamp(ft, ALT_MIN, ALT_MAX - 1)
  c = if a < -100 then 220 + 0.2 * a
  else if a <= 0 then 280 + 0.8 * a
  else if a <= 500 then 280 + 0.6343 * a - 0.4686e-3 * a * a
  else if a < 1e5 then 470 + 0.02 * a
  else 2470 + (a - 1e5) / 625
  u16(8 * Math.floor(c))
wordToAlt = (w) ->
  c = (w >>> 3) & 0xfff
  if c < 200 then (c - 220) / 0.2
  else if c < 280 then (c - 280) / 0.8
  else if c <= 480 then (0.6343 - Math.sqrt(0.6343 * 0.6343 - 4 * 0.4686e-3 * (c - 280))) / (2 * 0.4686e-3)
  else if c < 2470 then (c - 470) / 0.02
  else 1e5 + (c - 2470) * 625

# Word 4: three ranges either side of zero over -2940 to +2940 ft/s, bits
# 1 to 13.
HDOT_MAX = 2940
hdotToWord = (v) ->
  v = clamp(v, -HDOT_MAX, HDOT_MAX)
  s = if v < 0 then -1 else 1
  a = Math.abs(v)
  c = if a <= 100 then -s * 0.0292875 * v * v + 7.92875 * v
  else if a <= 740 then 187.5 * s + 3.125 * v
  else 2204 * s + 0.4 * v
  u16(8 * Math.floor(c))
wordToHdot = (w) ->
  c = s16(w) >> 3
  s = if c < 0 then -1 else 1
  a = Math.abs(c)
  v = if a <= 500 then (7.92875 - Math.sqrt(7.92875 * 7.92875 - 4 * 0.0292875 * a)) / (2 * 0.0292875)
  else if a <= 2500 then (a - 187.5) / 3.125
  else (a - 2204) / 0.4
  s * v

# Word 5: 0 to 9000 ft, bits 2 to 12, 10 ft a count above 500 ft.
RADAR_ALT_MAX = 9000
radarAltToWord = (ft) ->
  a = clamp(ft, 0, RADAR_ALT_MAX)
  c = if a < 500 then 3.1715 * a - 2.343e-3 * a * a else 1000 + (a - 500) / 10
  u16(16 * Math.floor(c))
wordToRadarAlt = (w) ->
  c = (w >>> 4) & 0x7ff
  if c < 1000 then (3.1715 - Math.sqrt(3.1715 * 3.1715 - 4 * 2.343e-3 * c)) / (2 * 2.343e-3)
  else 500 + (c - 1000) * 10

# Word 6: 0.05 ft/s^2 a count, bits 1 to 9, -12.75 to +12.75.
VACC_LSB = 0.05
vertAccelToWord = (a) -> u16(128 * Math.floor(clamp(a, -12.75, 12.749) / VACC_LSB))
wordToVertAccel = (w) -> (s16(w) >> 7) * VACC_LSB

# HSI: table F.4.104.0-1
#
HSI_WORDS = ['control', 'test', 'course', 'heading', 'priBearing', 'secBearing',
             'priRange', 'secRange', 'cdi', 'gsi']

# The DDU messages in engineering units.  `fields` for the encoders and
# the decoders' result carry the names above; a missing field encodes as
# zero, and `valid` (an array or object by word index, default all set)
# builds the control word.
#

encodeADI = (f, valid) ->
  [controlWord(14, valid), TEST_WORD.ADI
   fracToWord(f.rollSin ? 0), fracToWord(f.rollCos ? 1)
   fracToWord(f.pitchSin ? 0), fracToWord(f.pitchCos ? 1)
   fracToWord(f.yawSin ? 0), fracToWord(f.yawCos ? 1)
   fracToWord(f.rollRate ? 0), fracToWord(f.pitchRate ? 0), fracToWord(f.yawRate ? 0)
   fracToWord(f.rollErr ? 0), fracToWord(f.pitchErr ? 0), fracToWord(f.yawErr ? 0)]

decodeADI = (w) ->
  control: w[0], test: w[1]
  rollSin: wordToFrac(w[2]), rollCos: wordToFrac(w[3])
  pitchSin: wordToFrac(w[4]), pitchCos: wordToFrac(w[5])
  yawSin: wordToFrac(w[6]), yawCos: wordToFrac(w[7])
  rollRate: wordToFrac(w[8]), pitchRate: wordToFrac(w[9]), yawRate: wordToFrac(w[10])
  rollErr: wordToFrac(w[11]), pitchErr: wordToFrac(w[12]), yawErr: wordToFrac(w[13])

encodeHSI = (f, valid) ->
  [controlWord(10, valid), TEST_WORD.HSI
   angleToWord(f.course ? 0), angleToWord(f.heading ? 0)
   angleToWord(f.priBearing ? 0), angleToWord(f.secBearing ? 0)
   bcdToWord(f.priRange ? 0), bcdToWord(f.secRange ? 0)
   devToWord(f.cdi ? 0), devToWord(f.gsi ? 0)]

decodeHSI = (w) ->
  control: w[0], test: w[1]
  course: wordToAngle(w[2]), heading: wordToAngle(w[3])
  priBearing: wordToAngle(w[4]), secBearing: wordToAngle(w[5])
  priRange: wordToBcd(w[6]), secRange: wordToBcd(w[7])
  cdi: wordToDev(w[8]), gsi: wordToDev(w[9])

encodeAMI = (f, valid) ->
  [controlWord(6, valid), TEST_WORD.AMI
   machToWord(f.mach ? 0), alphaToWord(f.alpha ? 0), easToWord(f.eas ? 0), accelToWord(f.accel ? 0)]

decodeAMI = (w) ->
  control: w[0], test: w[1]
  mach: wordToMach(w[2]), alpha: wordToAlpha(w[3]), eas: wordToEas(w[4]), accel: wordToAccel(w[5])

encodeAVVI = (f, valid) ->
  [controlWord(6, valid), TEST_WORD.AVVI
   altToWord(f.altitude ? 0), hdotToWord(f.hdot ? 0), radarAltToWord(f.radarAlt ? 0), vertAccelToWord(f.vertAccel ? 0)]

decodeAVVI = (w) ->
  control: w[0], test: w[1]
  altitude: wordToAlt(w[2]), hdot: wordToHdot(w[3]), radarAlt: wordToRadarAlt(w[4]), vertAccel: wordToVertAccel(w[5])

# The MEDS FC GNC transfer: table F.4.128.1-2
#
# Message 1 (30 words, 1-based as the table numbers them): 1 and 2 the
# validity words, 3 to 6 spare, 7 flags (bit 16 PFS), 8 major mode (bits
# 7-16), 9 the abort and roll switch flags, 10 IPHASE (bits 14-16), 11
# ISLECT (bits 13-16), 12 TAEM guidance end (bit 15) and WOWLON (16), 13
# the HSI mode indicators, 14 and 15 the theta limit sines, 16 to 21 the
# ADI scale labels and status indicators, 22 the CDI scale, 23 delta
# azimuth, 24 the relative velocity heading, 25 to 27 the landing site ID,
# 28 target Nz, 29 beta, 30 delta inclination.  Message 2: 1 cross track,
# 2 cross track deviation, 3 target inclination (ten bits, 0 to 102.3
# degrees).  Messages 3 and 4 are spare.
#
# Validity word 1 bit 1 is word 7, bit 16 word 22; validity word 2 bit 1
# is word 23, bit 8 word 30, bits 9 to 11 message 2 words 1 to 3.

MEDS1_WORDS = 30
MEDS2_WORDS = 30

# bit 1 is 0x8000
bit = (n) -> 0x8000 >>> (n - 1)
# bits a-b of a 16-bit word, a from the most significant
field = (w, a, b) -> (w >>> (16 - b)) & ((1 << (b - a + 1)) - 1)
setField = (v, a, b) -> (v & ((1 << (b - a + 1)) - 1)) << (16 - b)
sfield = (w, a, b) ->
  n = b - a + 1
  v = field(w, a, b)
  if v & (1 << (n - 1)) then v - (1 << n) else v

MEDS_VALIDITY_WORD_OF = (n) ->
  # message 1 word n, or ['M2', n]
  if n <= 22 then {word: 0, bit: n - 6} else {word: 1, bit: n - 22}

ABORT_FLAGS = {CA: 12, RTLS: 13, AOA: 14, ATO: 15, TAL: 16}

# `f`: the MEDS fields in engineering units and flags; `valid`: the word
# numbers of message 1 (7..30) and message 2 (as 'M2.1'..'M2.3') that are
# valid, default every word carrying a field given.
encodeMEDS1 = (f, valid) ->
  w = new Array(MEDS1_WORDS).fill(0)
  set = (n, v) -> w[n - 1] = u16(v)
  given = {}
  mark = (n) -> given[n] = true
  set 7, (if (f.isPfs ? true) then bit(16) else 0); mark 7
  if f.majorMode? then set 8, setField(f.majorMode, 7, 16); mark 8
  v9 = 0
  v9 |= bit(9) if f.eoYawSteering
  v9 |= bit(10) if f.rollSw
  v9 |= bit(11) if f.ppa
  v9 |= bit(ABORT_FLAGS[f.abortMode]) if f.abortMode? and ABORT_FLAGS[f.abortMode]?
  set 9, v9; mark 9 if f.majorMode?
  if f.iphase? then set 10, setField(f.iphase, 14, 16); mark 10
  if f.islect? then set 11, setField(f.islect, 13, 16); mark 11
  v12 = 0
  v12 |= bit(15) if f.tgEnd
  v12 |= bit(16) if f.wowlon
  set 12, v12; mark 12 if f.tgEnd? or f.wowlon?
  if f.hsiModeL? or f.hsiModeR?
    set 13, setField(f.hsiModeL ? 0, 13, 14) | setField(f.hsiModeR ? 0, 15, 16); mark 13
  if f.thetaMaxDelta? then set 14, fracToWord(f.thetaMaxDelta); mark 14
  if f.thetaMinDelta? then set 15, fracToWord(f.thetaMinDelta); mark 15
  sc = f.scale ? {}
  # the rate scale labels are integers (equation set F.4.103.0-2,
  # "MEDS_LADIPR/RADIPR_SCALE = INTEGER (Pitch Rate Full Scale Value)"); the
  # pitch error label alone carries the 0.25 LSB of word 21
  q = (v) -> clamp(Math.round(v ? 0), 0, 8191)
  v16 = setField(q(sc.pitchRateL), 4, 16)
  v16 |= bit(1) if sc.rollRateTgoL
  v16 |= bit(2) if sc.rollRate0OnRight
  set 16, v16
  v17 = setField(q(sc.pitchRateR), 4, 16)
  v17 |= bit(1) if sc.rollRateTgoR
  set 17, v17
  set 18, setField(q(sc.yawRateL), 4, 16)
  set 19, setField(q(sc.yawRateR), 4, 16)
  v20 = setField(f.attSelL ? 0, 1, 2) | setField(f.attSelR ? 0, 3, 4)
  v20 |= bit(5) if (f.sbAuto ? true)
  v20 |= bit(6) if f.throtBlank
  v20 |= bit(7) if f.throtAuto
  v20 |= bit(8) if f.dapAuto
  v20 |= setField(clamp(Math.round(sc.rollRateL ? 0), 0, 15), 9, 12)
  v20 |= setField(clamp(Math.round(sc.rollRateR ? 0), 0, 15), 13, 16)
  set 20, v20
  q8 = (v) -> clamp(Math.round((v ? 0) / 0.25), 0, 255)
  set 21, setField(q8(sc.pitchErrL), 1, 8) | setField(q8(sc.pitchErrR), 9, 16)
  mark n for n in [16..21] if f.scale?
  if f.cdiScale? then set 22, setField(clamp(Math.round(f.cdiScale), 0, 511), 8, 16); mark 22
  if f.dAz?
    v23 = setField(Math.floor(f.dAz), 8, 16)
    v23 |= bit(7) if f.dAzWarn
    set 23, v23; mark 23
  if f.hVr? then set 24, angleToWord(f.hVr); mark 24
  if f.siteId?
    s = (f.siteId + '     ').slice(0, 5)
    set 25, (s.charCodeAt(1) << 8) | s.charCodeAt(0)
    set 26, (s.charCodeAt(3) << 8) | s.charCodeAt(2)
    set 27, s.charCodeAt(4)
    mark n for n in [25, 26, 27]
  if f.targetNz? then set 28, accelToWord(f.targetNz); mark 28
  if f.beta? then set 29, setField(Math.floor(clamp(f.beta, -99.9, 99.9) * 10), 6, 16); mark 29
  if f.dIncl? then set 30, u16(2 * Math.floor(clamp(f.dIncl, -99.99, 99.99) * 100)); mark 30
  valid ?= (n for n of given).map((n) -> parseInt(n, 10))
  v1 = 0
  v2 = 0
  for n in valid
    if typeof n == 'string' and n.startsWith('M2.')
      v2 |= bit(8 + parseInt(n.slice(3), 10))
    else if n <= 22
      v1 |= bit(n - 6) if n >= 7
    else
      v2 |= bit(n - 22)
  w[0] = u16(v1)
  w[1] = u16(v2)
  w

encodeMEDS2 = (f) ->
  w = new Array(MEDS2_WORDS).fill(0)
  w[0] = u16(Math.floor((f.xtrk ? 0) * 10))
  w[1] = setField(Math.floor(clamp(f.xtrkDev ? 0, -2048, 2047)), 5, 16)
  w[2] = setField(Math.floor((f.tgtIncl ? 0) * 10), 7, 16)
  w

# The validity of message 1 word n (7..30) or message 2 word n (1..3, with
# m2 true) from the validity words of message 1.
medsValid = (w1, n, m2 = false) ->
  if m2 then (w1[1] & bit(8 + n)) != 0
  else if n < 7 then true
  else if n <= 22 then (w1[0] & bit(n - 6)) != 0
  else (w1[1] & bit(n - 22)) != 0

ABORT_OF_BIT = {}
ABORT_OF_BIT[v] = k for k, v of ABORT_FLAGS

# Message 1 decoded; every field carries the value in the word, and
# `valid` says which of them the GPC marked valid.
decodeMEDS1 = (w) ->
  g = (n) -> w[n - 1] & 0xffff
  abort = null
  for k, b of ABORT_FLAGS when g(9) & bit(b)
    abort = k
  valid = {}
  valid[n] = medsValid(w, n) for n in [7..30]
  valid["M2.#{n}"] = medsValid(w, n, true) for n in [1..3]
  {
    valid
    isPfs: (g(7) & bit(16)) != 0
    majorMode: field(g(8), 7, 16)
    eoYawSteering: (g(9) & bit(9)) != 0
    rollSw: (g(9) & bit(10)) != 0
    ppa: (g(9) & bit(11)) != 0
    abortMode: abort
    iphase: field(g(10), 14, 16)
    islect: field(g(11), 13, 16)
    tgEnd: (g(12) & bit(15)) != 0
    wowlon: (g(12) & bit(16)) != 0
    hsiModeL: field(g(13), 13, 14)
    hsiModeR: field(g(13), 15, 16)
    thetaMaxDelta: wordToFrac(g(14))
    thetaMinDelta: wordToFrac(g(15))
    scale:
      rollRateTgoL: (g(16) & bit(1)) != 0
      rollRate0OnRight: (g(16) & bit(2)) != 0
      pitchRateL: field(g(16), 4, 16)
      rollRateTgoR: (g(17) & bit(1)) != 0
      pitchRateR: field(g(17), 4, 16)
      yawRateL: field(g(18), 4, 16)
      yawRateR: field(g(19), 4, 16)
      rollRateL: field(g(20), 9, 12)
      rollRateR: field(g(20), 13, 16)
      pitchErrL: field(g(21), 1, 8) * 0.25
      pitchErrR: field(g(21), 9, 16) * 0.25
    attSelL: field(g(20), 1, 2)
    attSelR: field(g(20), 3, 4)
    sbAuto: (g(20) & bit(5)) != 0
    throtBlank: (g(20) & bit(6)) != 0
    throtAuto: (g(20) & bit(7)) != 0
    dapAuto: (g(20) & bit(8)) != 0
    cdiScale: field(g(22), 8, 16)
    dAzWarn: (g(23) & bit(7)) != 0
    dAz: sfield(g(23), 8, 16)
    hVr: wordToAngle(g(24))
    siteId: String.fromCharCode(g(25) & 0xff, (g(25) >>> 8) & 0xff, g(26) & 0xff,
                                (g(26) >>> 8) & 0xff, g(27) & 0xff).replace(/\0/g, ' ')
    targetNz: wordToAccel(g(28))
    beta: sfield(g(29), 6, 16) / 10
    dIncl: (s16(g(30)) >> 1) / 100
  }

decodeMEDS2 = (w) ->
  xtrk: s16(w[0]) / 10
  xtrkDev: sfield(w[1] & 0xffff, 5, 16)
  tgtIncl: field(w[2] & 0xffff, 7, 16) / 10

WORDS_OF = {ADI: ADI_WORDS, HSI: HSI_WORDS, AVVI: AVVI_WORDS, AMI: AMI_WORDS}
ENCODE = {ADI: encodeADI, HSI: encodeHSI, AVVI: encodeAVVI, AMI: encodeAMI}
DECODE = {ADI: decodeADI, HSI: decodeHSI, AVVI: decodeAVVI, AMI: decodeAMI}

fmtWords = (words) -> (hex4(w) for w in words).join(' ')

export {
  IUA, DDU_OF_IUA, IUA_OF_DDU, DDU_WRITE_BIT, MSG, MSG_NAMES, MSG_CODE, MSG_OF_CODE
  HFE_SEQUENCE, HFE_PERIOD_MS
  payloadOf, commandWord, decodeCommand, fmtCommand, hex4, hex6, fmtWords
  s16, u16, controlBit, wordValid, controlWord, TEST_WORD
  fracToWord, wordToFrac, angleToWord, wordToAngle
  devToWord, wordToDev, devToDots, DEV_FULL_SCALE, DEV_DOTS
  cdiDegToWord, wordToCdiDeg, gsiFtToWord, wordToGsiFt, bcdToWord, wordToBcd
  machToWord, wordToMach, alphaToWord, wordToAlpha, easToWord, wordToEas, accelToWord, wordToAccel
  altToWord, wordToAlt, hdotToWord, wordToHdot, radarAltToWord, wordToRadarAlt
  vertAccelToWord, wordToVertAccel
  ADI_WORDS, HSI_WORDS, AVVI_WORDS, AMI_WORDS, WORDS_OF, ENCODE, DECODE
  encodeADI, decodeADI, encodeHSI, decodeHSI, encodeAMI, decodeAMI, encodeAVVI, decodeAVVI
  MEDS1_WORDS, MEDS2_WORDS, ABORT_FLAGS, encodeMEDS1, encodeMEDS2, decodeMEDS1, decodeMEDS2, medsValid
  bit, field, sfield, setField
}
