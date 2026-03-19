#
#
# Mass Memory Unit
#
#
# Device ID = 11
# Bus Numbers = 18,19
# IUA Address = 0x58
# Opcodes:
#   1 = WRITE WITH CHECKSUM
#   2 = WRITE WITHOUT CHECKSUM
#   3 = READ WITH CHECKSUM
#   4 = READ WITHOUT CHECKSUM
#   5 = MMU UTILITY WRITE
#   6 = MMU BITES STATUS
#   7 = READ OPS OVERLAY
#   8 = POSITION-TAPE COMMAND
#   9 = MMU UTILITY READ
#  10 = TCS MMU BITE STATUS
#
#
#   It should be noted, that data is written to MM in 512 16-bit words 
# regardless of the size of the output buffer or word count specified by the
# requestor. However, the IOP is not required to receive MM data in 512 word
# blocks. Therefore, reads of less than one block are supported.
#
#   MM data verification on read opeartions is performed by calculating a 
# checksum word from the input data words and comparing the checksum word 
# against the last input data word. The checksum word is calculated by summing
# the input data words. The last word of any logical data record is assumed to
# be a checksum word calculated from the intput data words before the data 
# block was originally written to MM.
#
# (IBM-77-SS-3576/p.483)
#
#
# MMU BITE
#
#   HW1 bit 1 = Power Interrupt
#           2 = R/W ADRS != CMD
#           3 = PAST REQ'd ADRS
#           4 = WRITE PROTECT ERR
#           5 = BAD CMD or MIA ERR
#
#   HW2 bit 1 = INVALID WORD COUNT
#             --- Tape Read ---
#           2 = DROP OUT
#           3 = BAD CLK CNT
#           4 = BAD PARITY
#             ---           ---
#           5 = WRITE INVALID MANCHESTER FMT
#           6 = NOT FIN & NEW CMD
#           7 = EOF BLK CNT != 0
#           8 = EOF ADRS MSNG
#           9 = TAPE MALF
#          10 = BOT DET
#          11 = EOT DET
#          12 = ABORT R/W OPER
#             --- Tape Write ---
#          13 = MIA BIT CNT
#          14 = MIA DET PRTY
#          15 = '101' check BAD
#          16 = INPUT DATA INTERRUPT
#
Bus = require 'com/bus'

export class MMU
  constructor: () ->

