ASM370A1 CSECT
***********************************************************************
*             ASM370A1.MLC - This is an HLASM Program                 *
*                 Provided by SimoTime Technologies                   *
*           (C) Copyright 1987-2016 All Rights Reserved               *
*             Web Site URL:   http://www.simotime.com                 *
*                   e-mail:   helpdesk@simotime.com                   *
***********************************************************************
*                                                                     *
* Created: 1986/04/01, Simmons                                        *
* Changed: 1988/09/15, Simmons, added additional instruction          *
*                                                                     *
***********************************************************************
*                                                                     *
* Micro Focus Mainframe Express, version 2.5 or later with the        *
* Assembler Option is required.                                       *
*                                                                     *
* This program provides a sample of the syntax used to code the       *
* problem-state instructions. The real value is in the animation of   *
* this program. You can immediately see the results of each           *
* instruction execution. This is a very effective way to become       *
* familiar with the 370 instruction set.                              *
* set.                                                                *
*                                                                     *
***********************************************************************
* This program will execute the non-floating-point 370 instructions   *
* supported by MF/370. Standard 370 Assembler coding guidelines are   *
* used.                                                               *
*     Position  1 - Optional Label                                    *
*     Position 10 - Mnemonic Opcode or Directive                      *
*     Position 16 - Operands                                          *
*     Position 30 - Optional Comment                                  *
* The labels in this example are the mnemonic opcode preceded by an   *
* "I@". For example, a CLC instruction would have a label of I@CLC.   *
* Note: The comments on the EQU statements are HTML links.            *
***********************************************************************
         BALR  12,0            PREPARE A BASE REGISTER
         USING *,12            ESTABLISH BASE REGISTER
         LA    R11,WTOID
***********************************************************************
I@A      EQU   *             * SIMOHTML-TAG 
* Add 4-byte memory value to register
         L     R4,FW00XX02     x'00000002'
         A     R4,FW00XX01   * Add x'00000001' = x'00000003' cc=2
         A     R4,FW80XX05   * Add x'80000005' = x'80000008' cc=1
***********************************************************************
I@AH     EQU   *             * SIMOHTML-TAG 
* Add 2-byte memory value to register
         AH    R4,HEX2+2     * Add HEX-2 TO REG-3
***********************************************************************
I@AL     EQU   *               
* Add 4-byte memory value to register
         L     R4,FW00XX02     x'00000002'
         AL    R4,FW00XX01   * Add x'00000001' result x'00000003'
         AL    R4,FW80XX05   * Add x'80000005' result x'80000008'
***********************************************************************
I@ALR    EQU   *               
* Add Logical Register to Register
         ALR   R3,R4         * Add  Register-Register
***********************************************************************
I@AP     EQU   *               
* Add decimal (packed)
         AP    D1,D2         * Add Memory-Memory
***********************************************************************
I@AR     EQU   *               
* Add Register to Register
         AR    R3,R4         * Add R4 to R3, Register-Register
***********************************************************************
I@BAL    EQU   *               
* The following two instructions are primarily used in 24-bit mode.
* Branch and Link, the BAL and BALR Instructions
         BAL   R9,*+4        * Load R9 with LINK ADDR,BRANCH (24-BIT)
I@BALR   EQU   *               
         BALR  R9,R0         * Load R9 with LINK ADDR (24-BIT)
***********************************************************************
I@BAS    EQU   *               
* The following two instructions are primarily used in 31-bit mode.
* Branch and Save, the BAS and BASR Instructions
         BAS   R10,*+4       * Load R10 with LINK ADDR,BRANCH (31-BIT)
I@BASR   EQU   *               
         BASR  R10,R0        * Load R10 with LINK ADDR (31-BIT)
***********************************************************************
I@BC     EQU   *               
* BRANCH on Condition
         BC    15,*+8        * BRANCH to SELF-PLUS-FOUR
         B     *+4             Same as preceding instruction
***********************************************************************
I@BCR    EQU   *               
* BRANCH on Condition Register
         LA    R8,BCREND       Load BRANCH-TO ADDRESS into REG-8
         BCR   15,R8         * BRANCH to ADDRESS specified in REG-8
         BR    R8              Same as preceding instruction
BCREND   EQU   *               Label for BCR-INSTRUCTION
***********************************************************************
I@BCT    EQU   *               
* Branch on Count
         LA    R3,3            Load 3 into REG-3 for DECREMENTING
BCTLOOP  EQU   *
         NOP   *               NO-OPERATION to show BCT-LOOP
         BCT   R3,BCTLOOP    * Loop until REG-3 goes to ZERO
***********************************************************************
I@BCTR   EQU   *               
* Branch on Count Register
         LA    R3,3            Load 3 into REG-3 for decrementing
         LA    R4,BCTRLOOP     Load BRANCH-TO ADDRESS into REG4
BCTRLOOP EQU   *
         NOP   BCTRNEXT        NO-OPERATION to show BCTR-LOOP
         BCTR  R3,R4         * LOOP until REG-3 GOES to ZERO
BCTRNEXT EQU   *
         LA    R3,3            The BCTR may be used to decrement a REG
         BCTR  R3,R0         * If OP-2 is 0 then DECR OP-1, NO BRANCH
***********************************************************************
I@BXH    EQU   *               
* BRANCH on INDEX High
         LA    R10,BXHEND      Establish BRANCH ADDRESS
         L     R4,BXHIDX       Establish INDEX
         L     R6,BXHINCR      1ST of EVEN/ODD - INCR VALUE
         L     R7,BXHCOMP      2ND of EVEN/ODD - COMP VALUE
BXHLOOP  EQU   *
         BXH   R4,R6,0(R10)  * Add INCR to IDX, BRANCH if IDX > COMP
         B     BXHLOOP         LOOP until IDX goes HIGH
         DS    0F              Force alignment
BXHIDX   DC    X'0000009E'   INDEX VALUE, to be INCREMENTED
BXHINCR  DC    X'00000002'   INCR VALUE for EVEN PAIR REG
BXHCOMP  DC    X'000000AA'   COMP VALUE for ODD  PAIR REG
         DS    0F
BXHEND   EQU   *
***********************************************************************
I@BXLE   EQU   *               
* BRANCH on INDEX Low-Equal
         LA    R10,BXLLOOP     Establish LOOP ADDRESS
         L     R4,BXLIDX       Establish INDEX
         L     R6,BXLINCR      1ST of EVEN/ODD - INCR VALUE
         L     R7,BXLCOMP      2ND of EVEN/ODD - COMP VALUE
BXLLOOP  EQU   *
         NOP   BXLEND          Do nothing instruction
         BXLE  R4,R6,0(R10)  * Add INCR to IDX, BRANCH if IDX LE COMP
         B     BXLEND          LOOP until IDX goes HIGH
         DS    0F              Force alignment
BXLIDX   DC    X'0000009E'   INDEX VALUE, to be INCREMENTED
BXLINCR  DC    X'00000002'   INCR VALUE for EVEN PAIR REG
BXLCOMP  DC    X'000000AA'   COMP VALUE for ODD  PAIR REG
         DS    0F
BXLEND   EQU   *
**********************************************************************
I@C      EQU   *               
* Compare, Register-Memory
         BAS   R11,*+12      * Prepare for possible ABEND...
         DC    C'Compare.'
         L     R8,ONEBIT01
         C     R8,ONEBIT00   * COMPARE  Register-Memory
         BNL   ABEND08
**********************************************************************
I@CDS    EQU   *               
* Compare DOUBLE and SWAP, Register-Memory
         CDS   R2,R4,SBYTE   * COMPARE Register-Memory
**********************************************************************
I@CH     EQU   *               
* Compare Halfword
         CH    R0,XBYTE      * COMPARE Register-Memory
**********************************************************************
I@CL     EQU   *               
* Compare Logical
         L     R8,ONEBIT01
         CL    R8,ONEBIT00   * COMPARE Register-Memory
         BNH   ABEND08
**********************************************************************
I@CLC    EQU   *               
* Compare Logical Characters
         CLC   ALPHA1,ALPHA2
         BNE   ABEND08
**********************************************************************
I@CLCL   EQU   *               
* Compare Logical Characters Long
         BAS   R11,*+12      * Prepare for possible ABEND...
         DC    C'CLCL....'
         LA    R4,ALPHA1       Load addr of opr1-1
         LA    R5,26           Length of opr-1
         LA    R6,ALPHA2       Load addr of opr-2
         L     R7,=X'4000001A' Pad and length of opr-2
         CLCL  R4,R6         * COMPARE Memory-Memory
         BNE   ABEND08
*
         LA    R4,ALPHA1       Load addr of opr1-1
         LA    R5,26           Length of opr-1 (26)
         LA    R6,ALPHA2       Load addr of opr-2
         L     R7,=X'40000022' Pad and length of opr-2 (34)
         CLCL  R4,R6         * Compare with different lengths
         BNE   ABEND08
*
         LA    R4,ALPHA1
         LA    R5,26
         LA    R6,ALPHA3
         LA    R7,26
         CLCL  R4,R6         * COMPARE Memory-Memory
         BE    ABEND08
**********************************************************************
I@CLI    EQU   *               
* Compare Logical Immediate
         BAS   R11,*+12      * Prepare for possible ABEND...
         DC    C'CLI.....'
I4EX     CLI   ALPHA1,C'A'
         BNE   ABEND08
**********************************************************************
I@CLM    EQU   *               
* Compare Logical under Mask
         BAS   R11,*+12      * Prepare for possible ABEND...
         DC    C'CLM.....'
         L     R8,DATAREG8     R8 value x'FF00FF00'
         CLM   R8,10,DATA4CLM  mask=1010, storage=x'FFFF0000'
         BNE   ABEND08
         CLM   R8,5,DATA4CLM   mask=0101, storage=x'FFFF0000'
         BE    ABEND08
         CLM   R8,5,DATA4CLM+2 mask=0101, storage=x'FFFF0000'
         BNE   ABEND08
**********************************************************************
I@CLR    EQU   *               
* Compare Logical (register-register)
         BAS   R11,*+12      * Prepare for possible ABEND...
         DC    C'CLR.....'
         L     R8,ONEBIT01
         L     R9,ONEBIT00
         CLR   R8,R9         * COMPARE LOGICAL
         BNH   ABEND08
**********************************************************************
I@CP     EQU   *               
* Compare Decimal (packed)
         CP    D1,D2         * COMPARE PACKED
**********************************************************************
I@CR     EQU   *               
* Compare (register-register)
         L     R8,ONEBIT01
         L     R9,ONEBIT00
         CR    R8,R9         * COMPARE REGISTERS
         BNL   ABEND08
**********************************************************************
I@CS     EQU   *               
* Compare and swap values
         CS    R1,R2,SBYTE   * COMPARE and SWAP
**********************************************************************
I@CVB    EQU   *               
* Memory to register, decimal to binary
         CVB   R3,D1         * CONVERT to BINARY
**********************************************************************
I@CVD    EQU   *               
* Register to memory, binary to decimal
         CVD   R3,D2         * CONVERT to DECIMAL
***********************************************************************
I@D      EQU   *               
* Divide (register-memory)
         L     R8,HEX0         Load EVEN-NUMBERED REG-8 with 0
         L     R9,HEX4         Load ODD-NUMBERED REG-9 with 4
         D     R8,HEX2       * DIVIDE EVEN/ODD REG-8/9 value of 2
***********************************************************************
I@DP     EQU   *               
* Divide Decimal (memory-memory)
         DP    D1,D2+4(4)    * DIVIDE DECIMAL, STORAGE & STORAGE
***********************************************************************
I@DR     EQU   *               
* Divide (register-register)
         L     R8,HEX0         EVEN/ODD PAIR, RESULT = REMAINDER
         L     R9,HEX5         EVEN/ODD PAIR, RESULT = QUOTIENT
         L     R3,HEX2         DIVISOR
         DR    R8,R3         * DIVIDE, REGISTER & REGISTER
***********************************************************************
I@ED     EQU   *               
* Edit
         MVC   EDFLD,EDMASK    Move EDIT MASK to OUTPUT FIELD
         ED    EDFLD,EDDATA  * MASK=ALL X'20, DATA=12345
***********************************************************************
I@EDMK   EQU   *               
* Edit and Mark
         EDMK  S1,S2         * Edit-Mark, Memory-Memory
***********************************************************************
I@EX     EQU   *               
* Execute
         LA    R3,X'F0'        Use X'F0' as second byte of CLI
         EX    R3,I4EX       * EXECUTE CLI INST at CLI ADDRESS
***********************************************************************
I@IC     EQU   *               
* Insert Character
         IC    R0,XBYTE      * INSERT Register-Memory
***********************************************************************
I@ICM    EQU   *                     
* Insert Character under Mask
         LA    R4,0                  Set REG-4 to ZERO
         LA    R5,0                  Set REG-5 to ZERO
         ICM   R4,MASK01,HEX1234   * Insert HEX-04, position 4
         ICM   R4,MASK02,HEX1234+1 * Insert HEX-03, position 3
         ICM   R4,MASK04,HEX1234+2 * Insert HEX-02, position 2
         ICM   R4,MASK08,HEX1234+3 * Insert HEX-01, position 1
*
         ICM   R5,MASK01,HEX1234+3 * Insert HEX-04, position 4
         ICM   R5,MASK02,HEX1234+2 * Insert HEX-03, position 3
         ICM   R5,MASK04,HEX1234+1 * Insert HEX-02, position 2
         ICM   R5,MASK08,HEX1234   * Insert HEX-01, position 1
*
         BAS   R11,*+12            * Prepare for possible ABEND
         DC    C'ICM.....'
         L     R6,HEX4321          * Expected value
         CR    R4,R6               * Is R4 as expected,
         BNE   ABEND08
         L     R6,HEX1234          * Expected value
         CR    R5,R6               * Is R5 as expected,
         BNE   ABEND08
***********************************************************************
I@L      EQU   *               
* Load, Register-Memory
         L     R0,XBYTE      * LOAD Register-Memory
***********************************************************************
I@LA     EQU   *               
* Show the different 'Load Address' functions
         LA    R8,I@LA       * Load ADDR of this routine into REG-8
         LA    R8,0          * Load ZERO to REGISTER 8
         LA    R8,1(,R8)     * Increment REGISTER-8 by 1
         LA    R8,2(,R8)     * Increment REGISTER-8 by 2
         LA    R8,3(,R8)     * Increment REGISTER-8 by 3
***********************************************************************
I@LCR    EQU   *               
* Load Complement
         LA    R2,1            Load R2 with a value of 1
         LCR   R1,R2         * Result R1=x'FFFFFFFF'
         LA    R4,16           Load R4 with a value of 16
         LCR   R3,R4         * Result R3 = x'FFFFFFF0'
***********************************************************************
I@LH     EQU   *               
* Load Halfword
         LH    R0,XBYTE      * Load  register-memory
***********************************************************************
I@LM     EQU   *               
* Load Multiple
         LM    R1,R2,SBYTE   * Load  registers-memory
***********************************************************************
I@LNR    EQU   *               
* Load Negative
         LNR   R1,R2         * Load register-register
***********************************************************************
I@LPR    EQU   *               
* Load Positive
         LPR   R1,R2         * Load  register-register
***********************************************************************
I@LR     EQU   *               
* Load register-register
         LR    R1,R2         * Load register-register
***********************************************************************
I@LTR    EQU   *               
* Load Test Register
         LTR   R1,R2         * Load and Test register content
***********************************************************************
I@M      EQU   *               
* Multiply, Register-Memory
         M     R0,XBYTE      * MULTPLY Register-Memory
***********************************************************************
I@MH     EQU   *               
* Multiply Halfword
         MH    R0,XBYTE      * MULTPLY Register-Memory
***********************************************************************
I@MP     EQU   *               
* Multiply Packed Decimal
         MVC   D3,D3X          Restore D1 value
         MVC   D4,D4X          Restore D2 value
         MP    D3,D4+1(7)    * MULTPLY PACKED, length of OP2=<8
***********************************************************************
I@MR     EQU   *               
* Multiply, Register-pair by Register
         LA    R6,0            Load EVEN REG-6
         LA    R7,4            Load ODD  REG-7
         LA    R8,2            Load MULTIPLIER
         MR    R6,R8         * MULTIPLY REG-6/7 by REG-8
***********************************************************************
I@MVC    EQU   *               
* Move Characters
         MVC   Z00,Z99       * MOVE CHARACTERS
***********************************************************************
I@MVCIN  EQU   *                     
* Move Inverse
         MVCIN WDIGITS,XDIGITS+9   * MOVE INVERSE
***********************************************************************
I@MVCL   EQU   *               
* Move Characters Long
         LA    R4,WORK4A
         LA    R5,4
         LA    R6,FW55
         LA    R7,4
         MVCL  R4,R6         * MOVE Long Memory-Memory
*        Different length operands...
         MVI   DATA80,X'00'    Set DATA80 to low values
         MVC   DATA80+1(80),DATA80
         LA    R4,DATA80       Set address of DATA80 into R4
         LA    R5,80           Set length of operand-1 to 80
         LA    R6,SIMOTIME     Set address of SIMOTIME into R6
         L     R7,FW40XX00     Set pad character for different length
         LA    R7,46(R7)       Set length of operand-2 to 46
         MVCL  R4,R6           Move with pad character of a space
***********************************************************************
I@MVI    EQU   *               
* Move Immediate
         MVI   SBYTE,I       * MOVE IMMEDIATE to STORAGE
***********************************************************************
I@MVN    EQU   *               
* Move Numeric
         MVN   S1,S2         * MOVE NUMERIC
***********************************************************************
I@MVO    EQU   *               
* Move with OFFSET
         MVO   S1,S2         * Rightmost 4-bits are unchanged
***********************************************************************
I@MVZ    EQU   *               
* Move Zone
         MVZ   S1,S2         * MOVE memory-memory
***********************************************************************
I@N      EQU   *               
* And, Set OFF high order bit
         L     R1,FW55         Load R1 with X'55555555'
         MVC   WORK4A,FWAA     Move X'AAAAAAAA' to WORK4A
         N     R1,WORK4A     * AND, into R1 from STORAGE
         LA    R2,0            Load ZERO into REG-2
         BCTR  R2,0            DECR by 1, make it 'FFFFFFFF'
         N     R2,=X'7FFFFFFF' Set OFF high order bit
***********************************************************************
I@NC     EQU   *               
* And, storage & storage
         MVC   WORK4A,FWAA     Move X'AAAAAAAA' to WORK4A
         MVC   WORK4B,FW55     Move X'55555555' to WORK4B
         NC    WORK4A,WORK4B * AND, STORAGE & STORAGE
***********************************************************************
I@NI     EQU   *               
* And, immediate to storage
         MVI   WORK1A,X'AA'    Move X'AA' to WORK1A
         NI    WORK1A,X'55'  * AND, IMMEDIATE to STORAGE
***********************************************************************
I@NR     EQU   *               
* And, register & register
         L     R1,FW55         Load R1 with X'55555555'
         L     R2,FWAA         Load R2 with X'AAAAAAAA'
         NR    R1,R2         * AND, REGISTER & REGISTER
***********************************************************************
I@O      EQU   *               
* Or, Set on HIGH-ORDER bit
         L     R1,FW55         Load R1 with X'55555555'
         MVC   WORK4A,FWAA     Move X'AAAAAAAA' to WORK4
         O     R1,WORK4A     * OR, into R1 from STORAGE
         LA    R2,0
         O     R2,=X'80000000' Set on HIGH-ORDER bit
***********************************************************************
I@OC     EQU   *               
* Or, storage & storage
         MVC   WORK4A,FWAA     Move X'AAAAAAAA' to WORK4A
         MVC   WORK4B,FW55     Move X'55555555' to WORK4B
         OC    WORK4A,WORK4B * OR, STORAGE & STORAGE
***********************************************************************
I@OI     EQU   *               
* Or, immediate & storage
         MVI   WORK1A,X'AA'    Move X'AA' to WORK1A
         OI    WORK1A,X'55'  * OR, IMMEDIATE & STORAGE
***********************************************************************
I@OR     EQU   *               
* Or, register & register
         L     R1,FW55         Load R1 with X'55555555'
         L     R2,FWAA         Load R2 with X'FFFFFFFF'
         OR    R1,R2         * OR, REGISTER & REGISTER
***********************************************************************
I@PACK   EQU   *               
* Pack Decimal
         PACK  D2,Z2         * PACK ZONED-DECIMAL to PACKED-DECIMAL
***********************************************************************
I@S      EQU   *               
* Subtract, register-memory
         S     R0,XBYTE      * Subtract register-memory
***********************************************************************
I@SH     EQU   *               
* Subtract Halfword
         SH    R0,XBYTE      * Subtract register-memory
***********************************************************************
I@SL     EQU   *               
* Subtract Logical
         SL    R0,XBYTE      * Subtract register-memory
***********************************************************************
I@SLA    EQU   *                     
* Shift Left
*
* The 1ST-OPERAND is a 32-bit single register.
* Only the rightmost 31-bit part of this signed
* value is shifted, the lefmost sign-bit remains
* unchanged.
*
* The 2ND-OPERAND address is not used to address
* memory. The rightmost 6-bits specify the number
* of bit positions to be shifted.
*
* If an overflow occurs then CONDITION CODE 3 is
* set.
*
         L     R10,=X'81010101'      Load REGISTER
         SLA   R10,X'01'           * Shift left 1-bit position
***********************************************************************
I@SLDA   EQU   *                     
* Shift Left Double
*
* The 1ST-OPERAND is a 64-bit EVEN/ODD register
* pair. Only the rightmost 63-bit part of this
* signed value is shifted, the lefmost sign-bit
* remains unchanged.
*
* NOTE: If an ODD/EVEN pair is specified then an
* 0C6 error will occur.
*
* The 2ND-OPERAND address is not used to address
* memory. The rightmost 6-bits specify the number
*
*
* If an overflow occurs then CONDITION CODE 3 is
* set.
*
         L     R8,=X'81010101'       Load EVEN REGISTER
         L     R9,=X'01010101'       Load ODD REGISTER
         SLDA  R8,X'01'            * Shift left 1-bit position
***********************************************************************
I@SLDL   EQU   *                     
* Shift Left Double Logical
*
* The 1ST-OPERAND, 64-bit EVEN/ODD register pair.
*
* NOTE: If an ODD/EVEN pair is specified then an
* 0C6 error will occur.
*
* The 2ND-OPERAND address is not used to address
* memory. The rightmost 6-bits specify the number
* of bit positions to be shifted.
*
         L     R2,=X'05050505'       Load EVEN REGISTER
         L     R3,=X'05050505'       Load ODD REGISTER
         SLDL  R2,X'01'            * Shift left 1-bit position
***********************************************************************
I@SLL    EQU   *                     
* Shift Left Single Logical
*
* The 1ST-OPERAND, 32-bit single register.
*
* The 2ND-OPERAND address is not used to address
* memory. The rightmost 6-bits specify the number
* of bit positions to be shifted.
*
         L     R4,=X'05050505'       Load Register
         SLL   R4,X'01'            * Shift left 1-bit position
***********************************************************************
I@SLR    EQU   *               
* Subtract Logical (register)
         SLR   R1,R2         * Subtract register-register
***********************************************************************
I@SP     EQU   *               
* Subtract, Packed Decimal
         MVC   D1,D1X        * Restore D1
         MVC   D2,D2X        * Restore D2
         SP    D2,D1         * SUBTRACT DECIMAL
***********************************************************************
I@SPM    EQU   *               
         L     R1,CC00         Set BITS 2-3 of REG-1 to 0
         SPM   R1            * Set CONDITION-CODE using BITS 2-3
         L     R1,CC01         Set BITS 2-3 of REG-1 to 1
         SPM   R1            * Set CONDITION-CODE using BITS 2-3
         L     R1,CC02         Set BITS 2-3 of REG-1 to 2
         SPM   R1            * Set CONDITION-CODE using BITS 2-3
         L     R1,CC03         Set BITS 2-3 of REG-1 to 3
         SPM   R1            * Set CONDITION-CODE using BITS 2-3
***********************************************************************
I@SR     SR    R1,R2         * SUBTRACT REGISTER
***********************************************************************
I@SRA    EQU   *                     
* Shift Right Single
*
* The 1ST-OPERAND is a 32-bit single register.
* only the rightmost 31-bit part of this signed
* value is shifted. The lefmost sign-bit remains
* unchanged.
*
* The 2ND-OPERAND address is not used to address
* memory. The rightmost 6-bits specify the number
* of bit positions to be shifted.
*
* If an overflow occurs then CONDITION CODE 3 is
* set.
*
         L     R10,=X'82020202'      Load REGISTER
         SRA   R10,X'01'           * Shift right 1-bit position
***********************************************************************
I@SRDA   EQU   *                     
* Shift Right Double
*
* The 1ST-OPERAND is a 64-bit EVEN/ODD register
* pair. Only the rightmost 63-bit part of this
* signed value is shifted. The lefmost sign-bit
* remains unchanged.
*
* NOTE: If an ODD/EVEN pair is specified then an
* 0C6 error will occur.
*
* The 2ND-OPERAND address is not used to address
* memory. The rightmost 6-bits specify the number
* of bit positions to be shifted.
*
* If an overflow occurs then CONDITION CODE 3 is
* set.
*
         L     R8,=X'82020202'       Load EVEN REGISTER
         L     R9,=X'02020202'       Load ODD REGISTER
         SRDA  R8,X'01'            * Shift right 1-bit position
***********************************************************************
I@SRDL   EQU   *                     
* Shift Right Double Logical
*
* The 1ST-OPERAND, 64-bit EVEN/ODD register pair.
*
* NOTE: If an ODD/EVEN pair is specified then an
* 0C6 error will occur.
*
* The 2ND-OPERAND address is not used to address
* memory. The rightmost 6-bits specify the number
* of bit positions to be shifted.
*
         L     R2,=X'0A0A0A0A'       Load EVEN REGISTER
         L     R3,=X'0A0A0A0A'       Load ODD REGISTER
         SRDL  R2,X'01'            * Shift right 1-bit position
***********************************************************************
I@SRL    EQU   *                     
* Shift Right Single Logical
*
* The 1ST-OPERAND is a 32-bit single register.
*
* The 2ND-OPERAND address is not used to address
* memory. The rightmost 6-bits specify the number
* of bit positions to be shifted.
*
         L     R4,=X'0A0A0A0A'       Load REGISTER
         SRL   R4,X'01'            * Shift right 1-bit position
***********************************************************************
I@SRP    EQU   *                     
* Shift and Round Decimal
         SRP   SRP1,1,1            * Shift 1ST OPR one digit to left
***********************************************************************
I@ST     EQU   *                     
* Store, a storage value into a register
         ST    R0,REGWORK          * Store REG-0 value into memory
***********************************************************************
I@STC    EQU   *                     
* Store Character
*
* The 1ST-OPERAND is a 32-bit single register
* (BITS 0-31).
*
* The 2ND-OPERAND specifies a memory location.
*
* Bits 24-31 of the 1ST-OPERAND are stored at
* the 2ND-OPERAND location.
*
         L     R8,=X'C1C2C3C4'       Load C'ABCD' into REG-8
         STC   R8,REGWORK          * STORE the 'D' at REGWORK location
***********************************************************************
I@STCK   EQU   *                     
* Store Clock
         STCK  STCKTIME            * Clock System-Memory
***********************************************************************
I@STCM   EQU   *                     
* Store Character under Mask
*
* STCM  R1,M3,D2(B2)
*
* The contents of OPERAND-1 is stored at
* OPERAND-2 under control of OPERAND-3.
*
* The following STCM with a mask of X'F' (1111)
* is the same as a STORE (ST) instruction.
*
         L     R3,=X'A0B1C2D3'       Initialize REGISTER to STORE
         MVC   STCMDATA(4),XFF       Initialize MEMORY for STORE
         STCM  R3,MASKF,STCMDATA   * STORE all four bytes
*
* The following STCM with a mask of X'8' (1000)
* will store BYTE-0 of the contents of R3.
*
         MVC   STCMDATA(4),XFF       Initialize MEMORY for STORE
         STCM  R3,MASK8,STCMDATA   * STORE BYTE-0
*
* The following STCM with a mask of X'3' (0011)
* will store bytes 2 and 3 of the contents of R3,
* This performs the same function as a STORE-
* HALFWORD instruction (STH).
*
         MVC   STCMDATA(4),XFF       Initialize MEMORY for STORE
         STCM  R3,MASK3,STCMDATA   * STORE BYTES 2 and 3
*
* The following STCM with a mask of X'7' (0111)
* will store bytes 1, 2 and 3 of the contents of
* R3, this may be used to store 24-bit (3-BYTE)
* addresses into control blocks.
*
         MVC   STCMDATA(4),XFF       Initialize MEMORY for STORE
         STCM  R3,MASK7,STCMDATA   * STORE BYTES 1, 2 and 3
***********************************************************************
I@STH    EQU   *               
* Store Halfword
         STH   R3,STHDATA    * Ignore BYTES 0 & 1, STORE 2 & 3
***********************************************************************
I@STM    EQU   *               
* Store Multiple
         STM   R1,R2,SBYTE   * Store multiple registers to memory
***********************************************************************
I@SVC    EQU   *               
* Supervisor Call
         B     *+6             Skip SVC Instruction
         SVC   27            * RETURN to CALLER via MF/370 DETACH
***********************************************************************
I@TM     EQU   *               
* Test under Mask
         TM    HEX1+3,X'01'  * TEST BIT for ON.
***********************************************************************
I@TR     EQU   *               
* Translate, memory-memory
         TR    S1,S2         * TRANSLATE memory-memory
***********************************************************************
I@TRT    EQU   *               
* Translate and Test, memory-register
         TRT   S1,S2         * Translate-Test, memory-register
***********************************************************************
I@UNPK   EQU   *               
* Unpack
         UNPK  Z4,D4         * UNPACK PACKED-DECIMAL to ZONED-DECIMAL
***********************************************************************
I@X      EQU   *               
* eXclusive or, into R1 from storage
         L     R1,FW5A         Load R1 with X'5A5A5A5A'
         MVC   WORK4A,FWAA     Move X'AAAAAAAA' to WORK4
         X     R1,WORK4A     * EXCLUSIVE OR, into R1 from STORAGE
***********************************************************************
I@XC     EQU   *               
* eXclusive or, storage & storage
         MVC   WORK4A,FW5A     Move X'5A5A5A5A' to WORK4A
         MVC   WORK4B,FW55     Move X'55555555' to WORK4B
         XC    WORK4A,WORK4B * EXCLUSIVE OR, STORAGE & STORAGE
*
         MVC   WORKA16,A16         Move all A's to WORKA16
         MVC   WORKZ16,Z16         Move all Z's to WORKZ16
         XC    WORKA16(16),WORKZ16 * The next three exclusive-or
         XC    WORKZ16(16),WORKA16   instructions will swap WORKA16
         XC    WORKA16(16),WORKZ16   contents with WORKZ16 contents
***********************************************************************
I@XI     EQU   *               
* eXclusive or, immediate & storage
         MVI   WORK1A,X'5A'    Move X'5A' to WORK1A
         XI    WORK1A,X'55'  * EXCLUSIVE OR, IMMEDIATE & STORAGE
***********************************************************************
I@XR     EQU   *               
* eXclusive or, register & register
         L     R1,FW5A         Load R1 with X'5A5A5A5A'
         L     R2,FWAA         Load R2 with X'FFFFFFFF'
         XR    R1,R2         * EXCLUSIVE OR, REGISTER & REGISTER
***********************************************************************
I@ZAP    EQU   *               
* ZERO and ADD Packed
         ZAP   D2,D4         * ZERO-ADD Memory-Memory
*
***********************************************************************
* NORMAL END-OF-JOB                                                   *
* RETURN to the CALLING PROGRAM OR OPERATING SYSTEM                   *
***********************************************************************
         LA    R15,0         * Set RETURN-CODE to ZERO
         BR    14            * RETURN to CALLER
***********************************************************************
* ABENDING WITH RETURN-CODE OF 8                                      *
* RETURN to the CALLING PROGRAM OR OPERATING SYSTEM                   *
***********************************************************************
ABEND08  EQU   *
         MVC   WTOID(8),0(R11)
         WTO   MF=(E,WTOBLOCK)
         LA    R15,8
         BR    14
WTOBLOCK DC    H'84'
         DC    X'0000'
WTOID    DC    C'????????'
         DC    C' ASM370A1 failed on or after this instruction...'
***********************************************************************
* Define Constants and EQUates                                        *
***********************************************************************
         DS    0F            + Force alignment
STCKTIME DC    XL'0000000000000000'
D0       DC    XL'000000000000000C'
D1       DC    XL'000000000000001C'
D2       DC    XL'000000000000002C'
D3       DC    XL'000000000000003C'
D4       DC    XL'000000000000004C'
D0X      DC    XL'000000000000000C'
D1X      DC    XL'000000000000001C'
D2X      DC    XL'000000000000002C'
D3X      DC    XL'000000000000003C'
D4X      DC    XL'000000000000004C'
X00      DC    XL'0000000000000000'
X55      DC    XL'5555555555555555'
XAA      DC    XL'AAAAAAAAAAAAAAAA'
XFF      DC    XL'FFFFFFFFFFFFFFFF'
X00X     DC    XL'0000000000000000'
X55X     DC    XL'5555555555555555'
XAAX     DC    XL'AAAAAAAAAAAAAAAA'
XFFX     DC    XL'FFFFFFFFFFFFFFFF'
ALPHA1   DC    C'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
ALPHA2   DC    C'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
SPACE8   DC    8CL1' '
ALPHA3   DC    C'ABCDEFGHI?KLMNOPQRSTUVWXYZ'
WORK1A   DC    X'00'
WORK1B   DC    X'00'
WORK4A   DC    X'00000000'
WORK4B   DC    X'00000000'
FW55     DC    X'55555555'
FW5A     DC    X'5A5A5A5A'
FWAA     DC    X'AAAAAAAA'
SRP1     DC    X'0000123F'
Z0       DC    CL15'000000000000000'
Z1       DC    CL15'000000000000001'
Z2       DC    CL15'000000000000002'
Z3       DC    CL15'000000000000003'
Z4       DC    CL15'000000000000004'
         DS    0F            + Force alignment
A16      DC    16CL1'A'
Z16      DC    16CL1'Z'
WORKA16  DC    16CL1'A'
WORKZ16  DC    16CL1'Z'
Z00      DC    C'00'
Z98      DC    C'98'
Z99      DC    C'99'
XDIGITS  DC    X'F0F1F2F3F4F5F6F7F8F9'
WDIGITS  DC    X'00000000000000000000'
HEX0     DC    X'00000000'
HEX1     DC    X'00000001'
HEX2     DC    X'00000002'
HEX4     DC    X'00000004'
HEX5     DC    X'00000005'
HEX1234  DC    X'01020304'
HEX4321  DC    X'04030201'
CC00     DC    X'0000CC00'
CC01     DC    X'1000CC01'
CC02     DC    X'2000CC02'
CC03     DC    X'3000CC03'
EDFLD    DC    X'00000000000000000000'
EDMASK   DC    X'F0202020202020202020'
EDDATA   DC    X'000012345C'
SIMOTIME DC    C'SimoTime, when technology complements business'
         DS    0F                  * Ensure full-word boundary
DATA80   DC    80X'00'
STCMDATA DC    X'00000000'
STHDATA  DC    X'00000000'
REGWORK  DC    X'00000000'
DATA4CLM DC    X'FFFF0000'
DATAREG8 DC    X'FF00FF00'
ONEBIT00 DC    X'00000001'
ONEBIT01 DC    X'80000001'
FW00XX00 DC    X'00000000'
FW00XX01 DC    X'00000001'
FW00XX02 DC    X'00000002'
FW00XX03 DC    X'00000003'
FW00XX04 DC    X'00000004'
FW00XX05 DC    X'00000005'
FW40XX00 DC    X'40000000'
FW80XX00 DC    X'80000000'
FW80XX01 DC    X'80000001'
FW80XX02 DC    X'80000002'
FW80XX03 DC    X'80000003'
FW80XX04 DC    X'80000004'
FW80XX05 DC    X'80000005'
MASK8    EQU   X'8'
MASK7    EQU   X'7'
MASK4    EQU   X'4'
MASK3    EQU   X'3'
MASK2    EQU   X'2'
MASK1    EQU   X'1'
MASKF    EQU   X'F'
XBYTE    EQU   *
AS       EQU   0
SBYTE    EQU   *
S1       EQU   *
S2       EQU   *
MASK     EQU   X'F'
MASK00   EQU   X'00'
MASK01   EQU   X'01'
MASK02   EQU   X'02'
MASK04   EQU   X'04'
MASK08   EQU   X'08'
MASKFF   EQU   X'FF'
I        EQU   X'FF'
*
         LTORG
*
R0       EQU   0
R1       EQU   1
R2       EQU   2
R3       EQU   3
R4       EQU   4
R5       EQU   5
R6       EQU   6
R7       EQU   7
R8       EQU   8
R9       EQU   9
R10      EQU   10
R11      EQU   11
R12      EQU   12
R13      EQU   13
R14      EQU   14
R15      EQU   15
*
         END
