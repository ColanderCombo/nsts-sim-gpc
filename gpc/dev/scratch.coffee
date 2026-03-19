    # # USA-003089/p.40
    # # 3.1.1.4 Condition Codes
    # # The following table lists the allowable relational operations and the 
    # # resultant condition code - referred to as COND throughout the remainder 
    # # of this section. Note that the AP-101 conditional branch instructions 
    # # branch on the "not true" condition.
    # #
    # #               <OP>    COND 
    # #                 =      3 
    # #                ¬=      4 
    # #                 <      5 
    # #                 >      6 
    # #             ¬< or >=   2 
    # #             ¬> or <=   1
    # # 
    # cond: { LEQ:1, GEQ:1, EQ:3, NEQ:4, LT:5, GT:6 }


# class CpuInterrupts

# class StatusRegister extends Register
#     #     0 A Reg Sign Bit
#     #  1:07 Exponent Counter
#     #           Used for handling the characteristic in floating
#     #           point poerations, STATUS:24 is the high bit of
#     #           this counter and is used to detect characteristic
#     #           overflows (OF) and underflows (UF)
#     #  8:11 Iteration Counter
#     #           Used by micro-code to perform micro branch on
#     #           count operations
#     # 12:15 Spill Status Bits
#     #           Used by shift micro operations to produce temporary
#     #           storage for spilled bits.
#     #    16 Enabled Store Protect Logic When A One
#     #    17 Store Protect Bit Generator (Only if Enabled by STATUS:16)
#     #    18 Performing Detect Micro Routine When a One
#     #    19 Always a Zero
#     #    20 Interrupt in Progress (Used bu Interrupt Handling Microroutines)
#     #    21 System Reset Register
#     #    22 Failure Indicator Register
#     #    23 Reserved for I/O Operations (Not Used)
#     #    24 Exponent OF/UF Register (See Description under STATUS:1-7)
#     #    25 B Register Sign
#     #    26 ALU Output Sign
#     #    27 ALU Output 32-bit Zero Detect
#     #    28 Fixed Point Overflow Register
#     #    29 Fixed Point Carry Register
#     # 30:31 General Usage for Micro Programmer

# @StatusRegister = StatusRegister
