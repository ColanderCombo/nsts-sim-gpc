#
# Air Data Transducer Assembly: word formats and wiring
#
# JSC-12843,Rev.J SCP 1.3 figures 1.3-19 and 1.3-20, SCP 4.17 table
# 4.17-1; JSC-12770,Vol.6.
#
# Four units, ADTA 1 to 4, each on serial I/O card 11 channel 1 of a
# flight critical forward MDM.  ADTA 1 and 3 sit behind the left air data
# probe, 2 and 4 behind the right.  SCP 4.17: "At the end of each
# computational cycle, the pressures, temperature, and ADTA Mode/Status
# word are sent to the Manchester Input/Output circuit for transfer to the
# MDM."
#
#
# MODE STATUS, one halfword, bit 0 the high bit (figures 1.3-19 and
# 1.3-20).  The nominal value is 8FFC for all four units:
#
#    0  ADTA good, 1 good
#    1  radiate circuit good, 1 fail
#    2  high test mode, 1 on
#    3  low test mode, 1 on
#    4  P-alpha-lower good
#    5  P-alpha-upper good
#    6  P-alpha-center good
#    7  static pressure good
#    8  A/D converter good
#    9  electronics good
#   10  temperature circuit good
#   11  code memory CRC
#   12  power supply good
#   13  discrete inputs good
#   14  RAM memory good, 1 fail
#   15  frequency divider good, 1 fail
#
# Bits 1, 14 and 15 are "Data bits only valid for new Allied Signal ADTA
# units".  Bits 4 to 13 read 1 good, so the nominal word carries them set.
#
# A high or low self test sets bit 2 or bit 3 and drives "a set of
# constants, high or low values ... for the different pressures and
# temperature".
#
#
# DATA WORDS
#
# JSC-12770,Vol.6 gives the unit's output to the MDM as "ADTA STATUS,
# PRESS, TOTAL TEMP", and the flight software reads three words of it in
# OPS 9.  The six word layout below is fitted to that ordering and to the
# four pressures the unit senses, with no direct documentation of the
# order among them or of the scaling, so the model reads words 2 to 6
# zero and the constants naming them are `fake`.
#

import {IOM, IUA, MODE as MDM_MODE, encodeDirect} from './../mdm/mdmConf'

# wiring
#
UNIT_MDM = {1: 'FF1', 2: 'FF2', 3: 'FF3', 4: 'FF4'}
UNIT_BUS = {1: 'FC1', 2: 'FC2', 3: 'FC3', 4: 'FC4'}

# "cb MNA, B, C ADTA (four) - cl" (JSC-12843 SCP 4.4): the four units are
# spread over the three main buses.  Which unit takes which is fitted.
UNIT_FEED = {1: 'MNA', 2: 'MNB', 3: 'MNC', 4: 'MNB'}

# The left and right air data probes, by the unit behind each.
PROBE = {1: 'left', 2: 'right', 3: 'left', 4: 'right'}

CARD      = 11
CHANNEL   = 1
CARD_TYPE = IOM.SIO.code

OUT_WORDS  = 6
READ_WORDS = 3

# The MDM command word a GPC reads a unit with.
CMD_READ = encodeDirect(IUA.FF, MDM_MODE.INPUT, CARD, CHANNEL, READ_WORDS)

# mode status
#
statusBit = (n) -> (0x8000 >>> n) & 0xffff

STATUS =
  ADTA_GOOD:      statusBit(0)
  RADIATE_FAIL:   statusBit(1)
  HIGH_TEST:      statusBit(2)
  LOW_TEST:       statusBit(3)
  PAL_GOOD:       statusBit(4)
  PAU_GOOD:       statusBit(5)
  PAC_GOOD:       statusBit(6)
  PS_GOOD:        statusBit(7)
  AD_CONV_GOOD:   statusBit(8)
  ELEC_GOOD:      statusBit(9)
  TEMP_CKT_GOOD:  statusBit(10)
  CODE_MEM_CRC:   statusBit(11)
  PWR_SUP_GOOD:   statusBit(12)
  DISC_IN_GOOD:   statusBit(13)
  RAM_FAIL:       statusBit(14)
  FD_FAIL:        statusBit(15)

STATUS_NAME = {}
STATUS_NAME[v] = k for k, v of STATUS

# The bits a healthy unit sets: good, and the ten good bits below them.
NOMINAL_STATUS = STATUS.ADTA_GOOD | STATUS.PAL_GOOD | STATUS.PAU_GOOD |
                 STATUS.PAC_GOOD | STATUS.PS_GOOD | STATUS.AD_CONV_GOOD |
                 STATUS.ELEC_GOOD | STATUS.TEMP_CKT_GOOD | STATUS.CODE_MEM_CRC |
                 STATUS.PWR_SUP_GOOD | STATUS.DISC_IN_GOOD

# The bits whose sense is inverted: set means failed.
FAIL_BITS = STATUS.RADIATE_FAIL | STATUS.RAM_FAIL | STATUS.FD_FAIL

# The bits that report a mode rather than health: set means the self test
# is in force.
MODE_BITS = STATUS.HIGH_TEST | STATUS.LOW_TEST

# Data words 2 to 6, fitted to "STATUS, PRESS, TOTAL TEMP".
FAKE_DATA_NAME = ['P alpha upper', 'P alpha lower', 'P alpha center',
                  'static pressure', 'total temperature']

# The named bits set in a status halfword, bit 0 first.
fmtStatus = (hw) ->
  bits = (STATUS_NAME[statusBit(n)] for n in [0..15] when hw & statusBit(n))
  if bits.length then bits.join(' ') else 'none'

export {
  UNIT_MDM, UNIT_BUS, UNIT_FEED, PROBE, CARD, CHANNEL, CARD_TYPE
  OUT_WORDS, READ_WORDS, CMD_READ
  STATUS, STATUS_NAME, NOMINAL_STATUS, FAIL_BITS, MODE_BITS, FAKE_DATA_NAME, statusBit
  fmtStatus
}
