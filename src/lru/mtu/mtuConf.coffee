#
# Master Timing Unit -- interface constants
#
# USA-005350,Rev.B sect.2.6 and 3.3; JSC-18819,Rev.F SCP 4.10;
# JSC-11174,Vol.1,Rev.F dwg 8.9 (the word formats and the notes quoted
# below).
#
# One unit, in forward avionics bay 3B.  "The MTU is not a BTU since it is
# not connected directly to the GPCs via a data bus.  Each of the MTU
# accumulators is tied to a flight critical forward MDM (accumulator 1 to
# MDM FF1, etc.)"  The tie is serial I/O card 3, channel 1 of that MDM, and
# a GPC reaches the accumulator through the MDM's ports:
#
#   accumulator 1   MDM FF1   FC1 (FC5)
#   accumulator 2   MDM FF2   FC2 (FC6)
#   accumulator 3   MDM FF3   FC3 (FC7)
#
# The GPC's three transactions with the channel are a read of 7 words, a
# write of 4 (an update) and a write of 1 (a reset).  The simulator's
# accumulator sits on the MDM's hardware side bus (lru/mdm/mdmConf.coffee): the
# MDM's POLL of card 3 channel 1 is the read, answered with a VALUE of the
# seven words, and the MDM's VALUE of four or one words is the write.
#
# The unit also gives time to the instrumentation system, through two
# operational instrumentation MDMs the PCMMU reads (JSC-18819 SCP 4.10 and
# SCP 5.1).  Telemetry names them MTU 1 and MTU 2:
#
#   MTU 1   voted GMT/MET      OF1 card 0 channel 1   V75W3504D, V75W3514D,
#                                                     BITE V75M3540P
#   MTU 2   non-voted GMT/MET  OF2 card 0 channel 1   V75W3604D, V75W3614D,
#                                                     BITE V75M3640P
#
# Dwg 8.9 draws them as the unit's "OF 1 INTERFACE" and "OF 2 INTERFACE"
# and tags the telemetry "MTU 1 - GMT ... OF 1 (OF 2)".  The voted output
# is the two-of-three vote of the accumulators; the model takes the middle
# value of the accumulators running.  The non-voted output is one
# accumulator's; the model uses accumulator 1.  Both answer the OI MDM's
# POLL with the seven demand words below.
#
#
# DEMAND OUTPUT -- seven halfwords
#
#   1-3  GMT       days/hours, minutes/seconds, milliseconds
#   4-6  MET       the same three
#   7    BITE status
#
# TIME, three halfwords, bit 15 the high bit:
#
#   word 1  bits 15-6  days, BCD, the hundreds digit two bits
#           bits  5-0  hours, BCD, the tens digit two bits
#   word 2  bits 15-9  minutes, BCD, the tens digit three bits
#           bits  8-2  seconds, BCD, the tens digit three bits
#           bits  1-0  spare
#   word 3  bits 15-13 spare
#           bits 12-0  milliseconds in 0.125 ms units, binary
#
# Note 13: "MAXIMUM OUTPUT OF THE MTU, BOTH GMT AND MET IS
# 399:23:59:59:999.875".  Note 12: "GMT OUTPUT WILL ROLLOVER TO
# 001:00:00:00:000.000 AT 125 MICROSECONDS PAST GMT OF: 365:23:59:59:999.875
# / 366:23:59:59:999.875 / 375:23:59:59:999.875 / 376:23:59:59:999.875 /
# 399:23:59:59:999.875".  MET returns to 000:00:00:00.000 at the end of day
# 399.
#
# BITE STATUS, one halfword (JSC-18819 table 4.10-1), bit 1 = 0x8000; bits
# 2 to 15 read 0 good, 1 failed:
#
#    1  oscillator: 1 = oscillator 1 drives the unit, 0 = oscillator 2
#    2  oscillator 1 amplitude, output under 0.8 V RMS
#    3  oscillator 2 amplitude
#    4  oscillator frequency difference, "a relative frequency of 0.04 Hz
#       in a 60-second period"
#    5  oscillator 1 temperature, oven outside 75 to 85 C
#    6  oscillator 2 temperature
#    7  power supply A voltage
#    8  power supply B voltage
#    9  accumulator 1: its shift register pair disagrees with 2 and 3
#       (dwg 8.9: "VOTED DEMAND CH-A")
#   10  accumulator 2 ("VOTED DEMAND CH-B")
#   11  accumulator 3 ("VOTED DEMAND CH-C")
#   12  IRIG B difference: one of the three GMT or MET format channels
#       disagrees with the other two ("ANY IRIG 'B' CHANNEL")
#   13  frequency divider 1: its 1 Hz output disagrees with 2 and 3
#   14  frequency divider 2
#   15  frequency divider 3
#   16  "1 = VALID UPDATE RECEIVED, 0 = UPDATE EXECUTED OR INVALID
#       TRANSMISSION IF BIT NEVER SET TO 1"; set from an update (a reset
#       excepted) "until coincidence time has been reached (1 to 2 minutes)"
#
# An amplitude or temperature failure of the driving oscillator moves the
# unit to the other one when the panel O6 OSCILLATOR switch is at AUTO.
#
#
# UPDATE INPUT -- four halfwords for an update, one for a reset
#
#   1-3  the time to load, in the three-halfword form above
#   4    mode word
#
# A reset sends the mode word alone.
#
# MODE WORD
#
#   bits 15-12  mode
#   bits 11-5   coincidence time, minutes, BCD
#   bits  4-0   spare
#
# MODE
#
#   3  update GMT       0x3000
#   5  update MET       0x5000
#   6  reset GMT        0x6000
#   9  reset MET        0x9000
#
# An update takes effect when the accumulator's minutes field reaches the
# coincidence time, and the time loaded is the time the accumulator is to
# read at that moment; the GPC picks the coincidence minute one to two
# minutes ahead.  A reset takes effect on receipt: note 7, "WHEN A MET OR
# GMT RESET IS ISSUED THE MET RESET TIME IS 000:00:00:00.000 AND THE GMT
# RESET IS 001:00:00:00.000".  Note 11: "CYCLING MTU POWER WILL RESULT IN
# MET RESET TO ZERO AND GMT RESET TO DAY ONE."
#

import {IOM, IUA, MODE as MDM_MODE, encodeDirect} from './../mdm/mdmConf'

# wiring
#
ACCUM_MDM = {1: 'FF1', 2: 'FF2', 3: 'FF3'}
ACCUM_BUS = {1: 'FC1', 2: 'FC2', 3: 'FC3'}

CARD         = 3
CHANNEL      = 1
CARD_TYPE    = IOM.SIO.code

# The instrumentation outputs, by the number telemetry gives them.
OI_OUTPUT =
  1: {mdm: 'OF1', nom: 'voted'}
  2: {mdm: 'OF2', nom: 'non-voted'}
OI_CARD      = 0
OI_CHANNEL   = 1

READ_WORDS   = 7
UPDATE_WORDS = 4
RESET_WORDS  = 1

# The MDM command words a GPC reads and writes an accumulator with.
CMD_READ   = encodeDirect(IUA.FF, MDM_MODE.INPUT,  CARD, CHANNEL, READ_WORDS)
CMD_UPDATE = encodeDirect(IUA.FF, MDM_MODE.OUTPUT, CARD, CHANNEL, UPDATE_WORDS)
CMD_RESET  = encodeDirect(IUA.FF, MDM_MODE.OUTPUT, CARD, CHANNEL, RESET_WORDS)

# mode word
#
MODE =
  UPDATE_GMT: 0x3
  UPDATE_MET: 0x5
  RESET_GMT:  0x6
  RESET_MET:  0x9

MODE_NAME = {}
MODE_NAME[v] = k for k, v of MODE

# BITE status, bit 1 = 0x8000
#
biteBit = (n) -> (0x8000 >>> (n - 1)) & 0xffff

BITE =
  OSC1_DRIVES:       biteBit(1)
  OSC1_AMPLITUDE:    biteBit(2)
  OSC2_AMPLITUDE:    biteBit(3)
  OSC_FREQ_DIFF:     biteBit(4)
  OSC1_TEMP:         biteBit(5)
  OSC2_TEMP:         biteBit(6)
  PS_A:              biteBit(7)
  PS_B:              biteBit(8)
  ACCUM1:            biteBit(9)
  ACCUM2:            biteBit(10)
  ACCUM3:            biteBit(11)
  IRIG_B:            biteBit(12)
  FREQ_DIV_1:        biteBit(13)
  FREQ_DIV_2:        biteBit(14)
  FREQ_DIV_3:        biteBit(15)
  VALID_UPDATE:      biteBit(16)

BITE_NAME = {}
BITE_NAME[v] = k for k, v of BITE

# time
#
MS_PER_SECOND = 1000
MS_PER_MINUTE = 60 * MS_PER_SECOND
MS_PER_HOUR   = 60 * MS_PER_MINUTE
MS_PER_DAY    = 24 * MS_PER_HOUR

MAX_DAYS      = 399
ROLLOVER_DAYS = [365, 366, 375, 376, 399]

TICK_MS = 0.125

# BCD
#
toBcd = (v, digits) ->
  b = 0
  for i in [0...digits] by 1
    b |= (Math.floor(v / Math.pow(10, i)) % 10) << (4 * i)
  b

fromBcd = (b, digits) ->
  v = 0
  for i in [0...digits] by 1
    v += ((b >> (4 * i)) & 0xf) * Math.pow(10, i)
  v

# time <-> the three halfwords
#
# `ms` counts from 000:00:00:00.000, so a GMT of day 1 is one whole day in.
#
splitTime = (ms) ->
  t     = Math.max(0, ms)
  days  = Math.floor(t / MS_PER_DAY)     ; t -= days * MS_PER_DAY
  hours = Math.floor(t / MS_PER_HOUR)    ; t -= hours * MS_PER_HOUR
  mins  = Math.floor(t / MS_PER_MINUTE)  ; t -= mins * MS_PER_MINUTE
  secs  = Math.floor(t / MS_PER_SECOND)  ; t -= secs * MS_PER_SECOND
  {days, hours, minutes: mins, seconds: secs, millis: t}

joinTime = (p) ->
  p.days * MS_PER_DAY + p.hours * MS_PER_HOUR +
  p.minutes * MS_PER_MINUTE + p.seconds * MS_PER_SECOND + p.millis

packTime = (ms) ->
  p     = splitTime(ms)
  ticks = Math.floor(p.millis / TICK_MS)
  [
    ((toBcd(p.days, 3) & 0x3ff) << 6) | (toBcd(p.hours, 2) & 0x3f)
    ((toBcd(p.minutes, 2) & 0x7f) << 9) | ((toBcd(p.seconds, 2) & 0x7f) << 2)
    ticks & 0x1fff
  ]

unpackTime = (words) ->
  days:    fromBcd((words[0] >> 6) & 0x3ff, 3)
  hours:   fromBcd(words[0] & 0x3f, 2)
  minutes: fromBcd((words[1] >> 9) & 0x7f, 2)
  seconds: fromBcd((words[1] >> 2) & 0x7f, 2)
  millis:  (words[2] & 0x1fff) * TICK_MS

unpackTimeMs = (words) -> joinTime(unpackTime(words))

# mode word
#
packMode = (mode, coincidenceMinutes = 0) ->
  (((mode & 0xf) << 12) | ((toBcd(coincidenceMinutes, 2) & 0x7f) << 5)) & 0xffff

unpackMode = (hw) ->
  m = (hw >> 12) & 0xf
  mode:        m
  name:        MODE_NAME[m] ? "MODE#{m}"
  coincidence: fromBcd((hw >> 5) & 0x7f, 2)

isReset  = (mode) -> mode == MODE.RESET_GMT or mode == MODE.RESET_MET
isGmt    = (mode) -> mode == MODE.UPDATE_GMT or mode == MODE.RESET_GMT

RESET_GMT_MS = MS_PER_DAY        # 001:00:00:00.000
RESET_MET_MS = 0                 # 000:00:00:00.000

# "DDD:HH:MM:SS.mmmmmm"
#
fmtTime = (ms) ->
  p = splitTime(ms)
  pad = (v, n) -> String(v).padStart(n, '0')
  frac = (p.millis / 1000).toFixed(6).slice(2)
  "#{pad(p.days, 3)}:#{pad(p.hours, 2)}:#{pad(p.minutes, 2)}:" +
  "#{pad(p.seconds, 2)}.#{frac}"

# "DDD:HH:MM:SS.sss", "DDD/HH:MM:SS", "HH:MM:SS" or a bare millisecond
# count.  Days default to 0.
#
parseTime = (s) ->
  t = String(s).trim()
  m = t.match(///^
    (?: (\d{1,3}) [:/] )?          # days
    (\d{1,2}) : (\d{1,2}) : (\d{1,2})
    (?: \. (\d{1,6}) )?            # fractional seconds
  $///)
  unless m?
    n = Number(t)
    return if isNaN(n) then null else n
  days  = if m[1]? then parseInt(m[1], 10) else 0
  hours = parseInt(m[2], 10)
  mins  = parseInt(m[3], 10)
  secs  = parseInt(m[4], 10)
  frac  = if m[5]? then Number("0.#{m[5]}") else 0
  return null unless days <= MAX_DAYS and hours < 24 and mins < 60 and secs < 60
  joinTime({days, hours, minutes: mins, seconds: secs, millis: frac * 1000})

# The named BITE bits set in a status halfword, bit 1 first.
#
fmtBite = (hw) ->
  bits = (BITE_NAME[biteBit(n)] for n in [1..16] when (hw & biteBit(n)))
  if bits.length then bits.join(' ') else 'none'

export {
  ACCUM_MDM, ACCUM_BUS, CARD, CHANNEL, CARD_TYPE, OI_OUTPUT, OI_CARD, OI_CHANNEL
  READ_WORDS, UPDATE_WORDS, RESET_WORDS
  CMD_READ, CMD_UPDATE, CMD_RESET
  MODE, MODE_NAME, BITE, BITE_NAME, biteBit
  MS_PER_SECOND, MS_PER_MINUTE, MS_PER_HOUR, MS_PER_DAY
  MAX_DAYS, ROLLOVER_DAYS, TICK_MS
  RESET_GMT_MS, RESET_MET_MS
  toBcd, fromBcd
  splitTime, joinTime, packTime, unpackTime, unpackTimeMs
  packMode, unpackMode, isReset, isGmt
  fmtTime, parseTime, fmtBite
}
