#
# Inertial Measurement Unit: word formats and wiring
#
# JSC-12843,Rev.J SCP 1.3 figures 1.3-1 to 1.3-3 and SCP 2.2; JSC-12770,
# Vol.6.
#
# Three HAINS units, IMU 1 to 3, each on serial I/O card 3 channel 0 of a
# flight critical forward MDM.  SCP 2.2 places them: "Can get a COMM GOOD
# BITE if an MDM serial I/O Card 3 channel 0 has failed."  The transfer is
# "The two IMU input data words from the GPC and the 16 IMU output data
# words to the GPC (only words 1 thru 14 are read by the GPC)", run at
# 25 Hz.  The MUX card "provides the interface for transmitting, receiving
# and formatting the data between the HAINS' internal parallel data bus
# and the MDM external serial data bus".
#
#
# DATA WORDS, the unit's output
#
#    1     mode status, figure 1.3-1
#    2     redundant axis rate, range +/-120 deg/hr; bit 1 set is "a
#          voltage saturation which invalidates the redundant axis rate
#          data word"
#    3-12  platform and accelerometer data
#   13     echo of command word 1, figure 1.3-2
#   14     echo of command word 2, figure 1.3-3
#   15-16  output by the unit and not read by the GPC
#
# Words 2 to 12, 15 and 16 read zero.
#
# The unit answers on card 3 channel 0.  The MDM catalog
# (lru/mdm/mdmConfig.coffee) names the IMU on card 11 channel 0 as well, and
# the flight software reads six words there from all four forward MDMs,
# FF4 among them, which carries no IMU.
#
#
# MODE STATUS, one halfword, bit 0 the high bit (figure 1.3-1).  The
# nominal value is 8000, "GROUND CRT IMU HEX STATUS WORD INDICATION: 8000":
#
#    0  HAINS good, 1 good
#    1  MUX fail
#    2  A/D fail
#    3  platform fail
#    4  digital subsystem fail
#    5  DC/DC fail
#    6  discrete power supply fail
#    7  resolver fail
#    8  circuit card overtemp
#    9  transmission word 1 fail
#   10  transmission word 2 fail
#   11  D1 + D8 sequence discrete
#   12  D2 sequence discrete
#   13  D3 sequence discrete
#   14  D4 sequence discrete
#   15  D5 sequence discrete
#
# Bit 0 is the only one the model drives; the rest are set by injection.
#
#
# COMMAND WORD 1 (figure 1.3-2), torquing, in two's complement.  Five bits
# an axis, sign then four of magnitude, "LSB (MAGNITUDE BIT) (1 = 0.5
# arcsec; 0 = 0 arcsec)", sign "1 = POSITIVE ROTATION; 0 = NEGATIVE
# ROTATION":
#
#    0- 4  torque X
#    5- 9  torque Y
#   10-14  torque Z
#   15     spare
#
# Four magnitude bits at 0.5 arcsec puts an axis over +/-7.5 arcsec.
#
# COMMAND WORD 2 (figure 1.3-3), slewing:
#
#    0  CAPRI SF, 1 on
#    1  slew X positive
#    2  slew X negative
#    3  slew Y positive
#    4  slew Y negative
#    5  slew Z positive
#    6  slew Z negative
#
# Data words 13 and 14 are the unit's echo of the two command words.  An
# echo that does not compare with what the GPC sent is the ECHO WORD 1/2
# FAIL BITE.
#

import {IOM, IUA, MODE as MDM_MODE, encodeDirect} from './../mdm/mdmConf'

# wiring
#
UNIT_MDM = {1: 'FF1', 2: 'FF2', 3: 'FF3'}
UNIT_BUS = {1: 'FC1', 2: 'FC2', 3: 'FC3'}

# "cb MNA, B, C" carries the entry LRUs (JSC-12843 SCP 4.4); each unit
# takes the main bus of its own number.
UNIT_FEED = {1: 'MNA', 2: 'MNB', 3: 'MNC'}

CARD      = 3
CHANNEL   = 0
CARD_TYPE = IOM.SIO.code

OUT_WORDS  = 16
READ_WORDS = 14
CMD_WORDS  = 2

# The data words carrying the echo, counting from one as the document does.
ECHO_WORD = {1: 13, 2: 14}

# The MDM command words a GPC reads and writes a unit with.
CMD_READ  = encodeDirect(IUA.FF, MDM_MODE.INPUT,  CARD, CHANNEL, READ_WORDS)
CMD_WRITE = encodeDirect(IUA.FF, MDM_MODE.OUTPUT, CARD, CHANNEL, CMD_WORDS)

# mode status
#
statusBit = (n) -> (0x8000 >>> n) & 0xffff

STATUS =
  HAINS_GOOD:      statusBit(0)
  MUX_FAIL:        statusBit(1)
  AD_FAIL:         statusBit(2)
  PLATFORM_FAIL:   statusBit(3)
  DIGITAL_FAIL:    statusBit(4)
  DCDC_FAIL:       statusBit(5)
  DISC_PS_FAIL:    statusBit(6)
  RESOLVER_FAIL:   statusBit(7)
  CARD_OVERTEMP:   statusBit(8)
  TRANS_WD1_FAIL:  statusBit(9)
  TRANS_WD2_FAIL:  statusBit(10)
  D1_D8_SEQUENCE:  statusBit(11)
  D2_SEQUENCE:     statusBit(12)
  D3_SEQUENCE:     statusBit(13)
  D4_SEQUENCE:     statusBit(14)
  D5_SEQUENCE:     statusBit(15)

STATUS_NAME = {}
STATUS_NAME[v] = k for k, v of STATUS

NOMINAL_STATUS = STATUS.HAINS_GOOD

# command words
#
TORQUE_BITS  = 5
TORQUE_LSB_ARCSEC = 0.5

SLEW =
  CAPRI_SF: statusBit(0)
  X_POS:    statusBit(1)
  X_NEG:    statusBit(2)
  Y_POS:    statusBit(3)
  Y_NEG:    statusBit(4)
  Z_POS:    statusBit(5)
  Z_NEG:    statusBit(6)

SLEW_NAME = {}
SLEW_NAME[v] = k for k, v of SLEW

# One axis of command word 1, arcseconds, from the field at `shift` bits
# below the top of the halfword.
torqueOf = (word, axis) ->
  shift = 16 - TORQUE_BITS * (axis + 1)
  field = (word >>> shift) & 0x1f
  mag   = (field & 0x0f) * TORQUE_LSB_ARCSEC
  return mag if (field & 0x10) or mag == 0
  -mag

# The three axes of a command word 1, X Y Z.
torques = (word) -> (torqueOf(word, axis) for axis in [0, 1, 2])

# The named bits set in a halfword, bit 0 first.
fmtBits = (hw, names) ->
  bits = (names[statusBit(n)] for n in [0..15] when (hw & statusBit(n)) and names[statusBit(n)])
  if bits.length then bits.join(' ') else 'none'

fmtStatus = (hw) -> fmtBits(hw, STATUS_NAME)
fmtSlew   = (hw) -> fmtBits(hw, SLEW_NAME)

export {
  UNIT_MDM, UNIT_BUS, UNIT_FEED, CARD, CHANNEL, CARD_TYPE
  OUT_WORDS, READ_WORDS, CMD_WORDS, ECHO_WORD
  CMD_READ, CMD_WRITE
  STATUS, STATUS_NAME, NOMINAL_STATUS, statusBit
  TORQUE_BITS, TORQUE_LSB_ARCSEC, SLEW, SLEW_NAME
  torqueOf, torques, fmtStatus, fmtSlew
}
