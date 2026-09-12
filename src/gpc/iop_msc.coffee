#
# IBM-6246556/p.1
#
# 1.0   MASTER SEQUENCE CONTROLLER
#
#       The Master Sequence Controller (MSC) is a micro programmed
# computer specifically tailored for I/O Management within the Space
# Shuttle General Purpose Computer (GPC). As such, it has extensive and
# programmable capabilities for monitoring and controlling the basic I/O
# operations performed by upwards to 24 Bus Control Elements (BCE's)
# which are implemented in the baseline GPC. These capabilities include
# setting up, scheduling, and initiating BCE programs, monitoring the
# status of BCE opeartions, and communicating overall completion of
# these operations to the CPU.
#
#       MSC CHARACTERISTICS
#
# TYPE -        Single Accumulator I/O Management Computer
# CONTROL STRUCTURE - Microprogrammed
# PROGRAMMABLE
# REGISTERS-
#               32 Bit ACCUMULATOR (ACC)
#               18 Bit INDEX REGISTER (X)
#               18 Bit PROGRAM COUNTER (PC)
#
# PROGRAM       18 Bit STATUS REGISTER
# VISIBLE       25 Bit PROGRAM EXCEPTION REGISTER
# REGISTERS     25 Bit BUSY/WAIT REGISTER
#                5 Bit FAIL DISCRETES
#               12 Bit IOP PROGRAMMABLE INTERRUPT REGISTER
#               18 Bit EXTERNAL CALL REGISTER
#
# INSTRUCTION
# FORMATS -     16 Bit SHORT/32 Bit LONG
#
# INSTRUCTION - 47 SHORT FORMAT/10 LONG FORMAT
# REPERTOIRE       (NOT COUNTING ADDRESSING MODES)
#
# ADDRESSING    131,072 32 Bit FULLWORDS/262,144 16 Bit HALFWORDS
# SPACE
#
# ADDRESSING    IMMEDIATE, ABSOLUTE, INDEXED,
# MODES         PC RELATIVE
#
# DATA FORMAT   SIGNED, TWO'S COMPLEMENT INTEGER
#
# SPECIAL       INITIALIZE AND MONITOR BCEs.
# FEATURES      RESPOND TO CPU REQUESTS TO
#               CHANGE PROGRAM (EXTERNAL CALL).
#
# MSC Instruction Formats (IBM-85-C67-001, Section 1.1):
#
# Short Format 1 (Accumulator/Memory):
#   Bits 0-3: OP (4-bit opcode)
#   Bit 4:    I  (index mode)
#   Bits 5-15: DISP (11-bit signed displacement, PC-relative)
#
# Short Format 2 (Register ops, register immediate, repeat, branch):
#   Bits 0-3: OP (4-bit opcode)
#   Bit 4:    I  (opcode extension or index)
#   Bits 5-7: OPX (3-bit sub-opcode)
#   Bits 8-15: DATA (8-bit immediate or count)
#
# Long Format (32-bit):
#   Bits 0-3:   1111 (long format prefix)
#   Bit 4:      I (index mode)
#   Bits 5-7:   SUBOP (3-bit sub-opcode)
#   Bits 8-12:  BCE# or DELTA (5-bit field)
#   Bit 13:     M (mode: 0=immediate/direct, 1=indirect)
#   Bits 14-31: ADDR (18-bit absolute address)
#

import {Register} from 'gpc/regmem'
import {MSCInstruction} from 'gpc/iop_msc_instr'

export class MSC
    constructor: ->
        @regFailDisc = new Register("failDisc", 5)
        @regIntProg = new Register("intProg", 12)
        @instr = new MSCInstruction()

    exec: (t, hw1, hw2) ->
        @instr.exec(t, hw1, hw2)
