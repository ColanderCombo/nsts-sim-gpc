# MEDS Analog to Digital Converter -- word formats, the 1553B framing and
# the analog input bus.
#
# JSC-11174,Vol.1,Rev.F dwg 8.3 sheet 3 "ANALOG TO MEDS DIGITAL CONVERTER":
# 32 analog inputs ("INPUTS ARE DIFFERENTIAL INPUTS", note 5), buffered
# four to a card, through two ranks of 8:1 analog multiplexers to one A/D
# converter with "A RESOLUTION OF 2.5 MV PER LSB" (note 2) and 12 data
# lines.  The second mux rank also selects the reference voltages -5.6,
# -2.0, 0, +2.0 and +5.6 V, and the BITE drive biases the input buffers:
#
#   note 1: "THE BIAS VOLTAGE IS ASSIGNED TO THE CHANNELS AS FOLLOWS,
#            +2V  0, 3, 5, 6, 9, 10, 12, 15, 17, 18, 20, 23, 24, 27, 29, 30
#            -2V  1, 2, 4, 7, 8, 11, 13, 14, 16, 19, 21, 22, 25, 26, 28, 31"
#
# An 8051 CPU with a 16K x 8 PROM runs the unit; the ADC gate array holds
# a bus controller/remote terminal module (BCRTM), two 2K x 22 SRAMs with
# a scrubber, and two 1553B transceivers "TO IDP BUSES".  The RT address
# is five strapped lines plus parity on the J2 connector (note 6).  Power
# is 28 V through one 3 A breaker per pair: ADC 1A/2A from MNA (D&C PNL
# R15 CB82), ADC 1B/2B from MNB (CB85).
#
# USA-005350,Rev.B sect.2.5.4.1: "The ADC has the ability to sample 32
# input channels at a rate of 25 Hz.  It converts them into 12-bit digital
# data and transmits it to the associated IDP, when requested.  The ADC
# has a double buffer so that it can write new data while old data is
# being read.  Each ADC's software performs a self-test continuously."
#
# SFOC-FL0884 sect.2.6: "ADCs 1A and 1B convert the analog signals from
# the MPS, OMS, and SPI meters.  ADCs 2A and 2B convert the signals from
# the APU and HYD meters.  Each ADC maintains communication with two IDPs
# simultaneously (the 'As' with IDP 1 and 2 and the 'Bs' with IDP 3 and
# 4)."  The unit's two IDP busses and RT address are in meds/medsConf
# (MEDSConf.adcs).
#
# The 1553B message layout below the command word -- which subaddress
# carries the samples, the status block and its words, the receive
# command -- is fitted to those constraints with no direct documentation.
#

import {MEDSConf} from './../../meds/medsConf'

CHANNELS = 32
LSB_VOLTS = 0.0025
DATA_BITS = 12
COUNT_MIN = -(1 << (DATA_BITS - 1))          # -2048, -5.12 V
COUNT_MAX = (1 << (DATA_BITS - 1)) - 1       # +2047, +5.1175 V
VOLTS_MIN = COUNT_MIN * LSB_VOLTS
VOLTS_MAX = COUNT_MAX * LSB_VOLTS
SAMPLE_HZ = 25
SAMPLE_MS = 1000 / SAMPLE_HZ

voltsToCount = (v) ->
  n = Math.round(v / LSB_VOLTS)
  Math.max(COUNT_MIN, Math.min(COUNT_MAX, n))

countToWord = (n) -> n & ((1 << DATA_BITS) - 1)

wordToCount = (w) ->
  n = w & ((1 << DATA_BITS) - 1)
  if n & (1 << (DATA_BITS - 1)) then n - (1 << DATA_BITS) else n

voltsToWord = (v) -> countToWord(voltsToCount(v))
wordToVolts = (w) -> wordToCount(w) * LSB_VOLTS

REFERENCE_VOLTS = [-5.6, -2.0, 0.0, 2.0, 5.6]

BIAS_PLUS_CHANNELS = [0, 3, 5, 6, 9, 10, 12, 15, 17, 18, 20, 23, 24, 27, 29, 30]
biasVoltsOf = (channel) -> if channel in BIAS_PLUS_CHANNELS then 2.0 else -2.0

UNITS = ['1A', '1B', '2A', '2B']
pairOf = (unit) -> parseInt(String(unit)[0], 10)
unitConf = (unit) -> MEDSConf.adcs["ADC#{unit}"]
rtAddressOf = (unit) -> unitConf(unit).busAddr
idpBussesOf = (unit) -> unitConf(unit).busses
unitsOfIdp = (idpNo) ->
  (u for u in UNITS when "IDP#{idpNo}" in unitConf(u).dataBus)

ANALOG_BUS = {1: '_ADC1_analogs', 2: '_ADC2_analogs'}
analogBusOf = (unit) -> ANALOG_BUS[pairOf(unit)]

# MIL-STD-1553B words
#
# Command word: remote terminal address in bits 15-11, transmit/receive
# in bit 10 (1 = the RT transmits), subaddress in bits 9-5, data word
# count in bits 4-0 with 0 meaning 32.  Status word: RT address in bits
# 15-11, then message error, instrumentation, service request, three
# reserved bits, broadcast command received, busy, subsystem flag,
# dynamic bus control acceptance and terminal flag in bits 10-0.
#
# A datagram on an IDP bus opens with a sync word standing for the sync
# waveform that tells a command from a status word on the wire.  The
# words are below 0xff00, the range meds/medsConf reserves for the IDP to
# MDU message tags.
SYNC_COMMAND = 0x0001
SYNC_STATUS  = 0x0002

TR_RECEIVE = 0
TR_TRANSMIT = 1

commandWord = ({rt, tr, sa, wc}) ->
  ((rt & 0x1f) << 11) | ((tr & 1) << 10) | ((sa & 0x1f) << 5) | (wc & 0x1f)

decodeCommand = (w) ->
  wc = w & 0x1f
  {rt: (w >>> 11) & 0x1f, tr: (w >>> 10) & 1, sa: (w >>> 5) & 0x1f, wc: (if wc == 0 then 32 else wc)}

STATUS =
  MESSAGE_ERROR:   1 << 10
  INSTRUMENTATION: 1 << 9
  SERVICE_REQUEST: 1 << 8
  BROADCAST_RCVD:  1 << 4
  BUSY:            1 << 3
  SUBSYSTEM_FLAG:  1 << 2
  DBC_ACCEPTANCE:  1 << 1
  TERMINAL_FLAG:   1 << 0

statusWord = (rt, flags = 0) -> ((rt & 0x1f) << 11) | (flags & 0x7ff)

decodeStatus = (w) ->
  flags = w & 0x7ff
  names = (k for k, v of STATUS when flags & v)
  {rt: (w >>> 11) & 0x1f, flags, names}

# the message layout
#
# Subaddress 1, transmit: the sampled frame, one data word a channel,
# channel 0 first.  Subaddress 2, transmit: the status block.  Subaddress
# 3, receive: one command word.
SA =
  SAMPLES: 1
  STATUS:  2
  COMMAND: 3

STATUS_BLOCK_WORDS = 5
STATUS_BLOCK =
  BITE:      0       # the BITE summary the MDU maintenance display shows in hex
  CST:       1       # the comprehensive self-test result, valid when CST_STATE is DONE
  CST_STATE: 2
  SAMPLES:   3       # frames sampled since power-up, modulo 65536
  VERSION:   4       # software version, shown as V xxxx

CST_STATE =
  NONE:    0
  RUNNING: 1
  DONE:    2

COMMAND =
  START_CST: 0x0001
  RESET:     0x0002

SOFTWARE_VERSION = 0x0100

# The BITE summary bits, one per monitor on dwg 8.3 sheet 3.
BITE =
  PROM_CHECKSUM:  1 << 0
  SRAM_SCRUB:     1 << 1
  REFERENCE:      1 << 2
  WATCHDOG_RESET: 1 << 3
  POWER_MONITOR:  1 << 4
  XCVR_A:         1 << 5
  XCVR_B:         1 << 6

# The CST result bits: the five reference voltages in REFERENCE_VOLTS
# order, the bias pattern on the 32 inputs, then the memory checks.
# A clear word is a pass.
CST =
  REF_M5V6:     1 << 0
  REF_M2V0:     1 << 1
  REF_0V:       1 << 2
  REF_P2V0:     1 << 3
  REF_P5V6:     1 << 4
  BIAS_PATTERN: 1 << 5
  PROM:         1 << 6
  SRAM:         1 << 7

CST_DURATION_MS = 1000

bitNames = (table, w) ->
  names = (k for k, v of table when w & v)
  if names.length then names.join(' ') else 'none'

fmtBite = (w) -> bitNames(BITE, w)
fmtCst = (w) -> bitNames(CST, w)

# datagrams on an IDP bus
#
# A bus controller's transmission: sync, command word, then the data
# words of a receive command.  A remote terminal's: sync, status word,
# then the data words of a transmit command.
encodeBC = (cmd, data = []) -> [SYNC_COMMAND, commandWord(cmd)].concat(w & 0xffff for w in data)
encodeRT = (rt, flags, data = []) -> [SYNC_STATUS, statusWord(rt, flags)].concat(w & 0xffff for w in data)

decode1553 = (words) ->
  return null unless words?.length >= 2
  data = (words[i] & 0xffff for i in [2...words.length] by 1)
  switch words[0]
    when SYNC_COMMAND then Object.assign {kind: 'command', data}, decodeCommand(words[1])
    when SYNC_STATUS  then Object.assign {kind: 'status', data}, decodeStatus(words[1])
    else null

hex4 = (v) -> (v & 0xffff).toString(16).padStart(4, '0')

fmt1553 = (m) ->
  return '' unless m?
  if m.kind == 'command'
    dir = if m.tr == TR_TRANSMIT then 'transmit' else 'receive'
    tail = if m.data.length then "  #{(hex4 w for w in m.data).join(' ')}" else ''
    "CMD rt #{m.rt} #{dir} sa #{m.sa} wc #{m.wc}#{tail}"
  else
    flags = if m.names.length then " [#{m.names.join(' ')}]" else ''
    "STATUS rt #{m.rt}#{flags}  #{m.data.length} words" +
      (if m.data.length then "  #{(hex4 w for w in m.data.slice(0, 8)).join(' ')}#{if m.data.length > 8 then ' ...' else ''}" else '')

# the analog input bus
#
# Word 0 is the operation, word 1 the channel (0xff for every channel),
# then one signed millivolt word a channel.  VALUE carries the signal a
# source is putting on a channel; REQUEST asks the sources to send every
# channel again, and a source answers with VALUE for all 32.
ANALOG_OP =
  REQUEST: 3
  VALUE:   4
ANALOG_ALL = 0xff
ANALOG_HEADER_WORDS = 2

encodeAnalog = (op, channel, volts = []) ->
  out = [op & 0xffff, channel & 0xff]
  for v in volts
    mv = Math.max(-32768, Math.min(32767, Math.round(v * 1000)))
    out.push mv & 0xffff
  out

decodeAnalog = (data16) ->
  return null unless data16?.length >= ANALOG_HEADER_WORDS
  op = data16[0] & 0xffff
  return null unless op in [ANALOG_OP.REQUEST, ANALOG_OP.VALUE]
  channel = data16[1] & 0xff
  volts = for i in [ANALOG_HEADER_WORDS...data16.length] by 1
    w = data16[i] & 0xffff
    (if w & 0x8000 then w - 0x10000 else w) / 1000
  {op, channel, volts}

fmtAnalog = (m) ->
  name = if m.op == ANALOG_OP.REQUEST then 'REQUEST' else 'VALUE'
  ch = if m.channel == ANALOG_ALL then '*' else m.channel
  vs = (v.toFixed(3) for v in m.volts).join(' ')
  "#{name} ch #{ch} #{vs}".trim()

export {
  CHANNELS, LSB_VOLTS, DATA_BITS, COUNT_MIN, COUNT_MAX, VOLTS_MIN, VOLTS_MAX
  SAMPLE_HZ, SAMPLE_MS
  voltsToCount, countToWord, wordToCount, voltsToWord, wordToVolts
  REFERENCE_VOLTS, BIAS_PLUS_CHANNELS, biasVoltsOf
  UNITS, pairOf, unitConf, rtAddressOf, idpBussesOf, unitsOfIdp, ANALOG_BUS, analogBusOf
  SYNC_COMMAND, SYNC_STATUS, TR_RECEIVE, TR_TRANSMIT
  commandWord, decodeCommand, STATUS, statusWord, decodeStatus
  SA, STATUS_BLOCK_WORDS, STATUS_BLOCK, CST_STATE, COMMAND, SOFTWARE_VERSION
  BITE, CST, CST_DURATION_MS, fmtBite, fmtCst
  encodeBC, encodeRT, decode1553, fmt1553
  ANALOG_OP, ANALOG_ALL, ANALOG_HEADER_WORDS, encodeAnalog, decodeAnalog, fmtAnalog
}
