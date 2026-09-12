IPLMICRO TITLE '        IPL MICROCODE MASS MEMORY PROGRAMS'
***********************************************************************
*                                                                     *
*  THE MSC AND BCE PROGRAMS THAT READ THE IPL BOOTSTRAP COPY OFF THE  *
*  MASS MEMORY INTO SECTOR ZERO.                                      *
*                                                                     *
*  NOT IBM CODE.  THE IPL SEQUENCE IS MICROCODE; THESE PROGRAMS ARE   *
*  WRITTEN TO WHAT THE SPECIFICATION SAYS IT DOES.                    *
*                                                                     *
*  ASM101 ASSEMBLES THEM AND LNK101 LOCATES THEM AT X'3FF80': BELOW   *
*  X'40000', THE LIMIT OF AN 18 BIT IOP ADDRESS FIELD, AND ABOVE      *
*  SECTOR ZERO.  THE LOCATED IMAGE IS GPC/GEN/FAKEIPL.JSON, WHICH THE *
*  SIMULATOR EMBEDS; ITS ADDRESSES ARE ABSOLUTE.                      *
*                                                                     *
*  IPLSRC IS THE ONE CELL WRITTEN FROM OUTSIDE: THE TWO IPL SOURCE    *
*  DISCRETES, RIGHT JUSTIFIED, MM1 IN THE HIGH BIT.  NO IOP           *
*  INSTRUCTION READS THE DISCRETE INPUTS, SO THEY ARRIVE THERE.       *
*                                                                     *
*  #CMD TAKES ITS COMMAND WORD FROM THE FULLWORD AT ADDRESS PLUS      *
*  TWICE THE BUS CONTROL ELEMENT NUMBER, SO EACH COMMAND IS A TABLE   *
*  OF ONE FULLWORD PER ELEMENT AND THE OPERAND WRITTEN IS THE FIRST   *
*  ENTRY LESS 36.  ELEMENTS 18 AND 19 ARE MASS MEMORY 1 AND 2.        *
*                                                                     *
*  #RDLI TAKES A HALFWORD COUNT LESS ONE.                             *
*                                                                     *
***********************************************************************
IPLMICRO CSECT
IPLMMUM  EQU   11                  MASS MEMORY INTERFACE UNIT ADDRESS
IPLSRCW  EQU   X'00008000'         READ STATUS REGISTERS
IPLSECT  EQU   X'8000'             HALFWORDS IN A SECTOR
IPLRPT   EQU   X'3FFFF'            8.65 S, THE LONGEST A REPEAT MAY WAIT
*
*  THE BOOTSTRAP COPY IS AT TAPE ADDRESS 44500 AND FILLS A SECTOR.
*
IPLFILE  EQU   4                   FILE
IPLTRAK  EQU   4                   TRACK
IPLSUBF  EQU   5                   SUBFILE
IPLBLOK  EQU   0                   BLOCK
IPLNBLK  EQU   64                  BLOCKS OF 512 HALFWORDS IN A SECTOR
*
*  MASS MEMORY COMMAND WORD:  IUA AT BIT 19, OPCODE AT BIT 15, THEN
*  PER OPCODE FIELDS.  POSITION ADDRESSES THE GAP BEFORE THE DATA, SO
*  IT TAKES THE SUBFILE BELOW THE ONE WANTED.
*
IPLOPOS  EQU   0                   OPCODE: POSITION TAPE
IPLOEXT  EQU   3                   OPCODE: EXTEND BLOCK COUNT
IPLORD   EQU   9                   OPCODE: READ
IPLIUAF  EQU   IPLMMUM*X'80000'    IUA, IN PLACE
IPLTRKF  EQU   IPLTRAK*X'1000'     TRACK, IN PLACE
IPLCPOS  EQU   IPLIUAF+IPLTRKF+(IPLSUBF-1)*X'200'+IPLFILE*2
IPLCEXT  EQU   IPLIUAF+IPLOEXT*X'8000'+IPLNBLK-1
IPLCRD   EQU   IPLIUAF+IPLORD*X'8000'+IPLTRKF+IPLSUBF*X'200'
***********************************************************************
*                                                                     *
*  MSC PROGRAM                                                        *
*                                                                     *
*  RUNS BOTH BUS PROGRAMS: LOAD THE ELEMENT'S PROGRAM COUNTER, START  *
*  IT, WAIT FOR IT TO REACH ITS #WAT.  THE MSC BACK IN THE WAIT STATE *
*  IS THE WHOLE SEQUENCE DONE.                                        *
*                                                                     *
*  IPLSRC IS 2 FOR MM1 AND 1 FOR MM2.  0 IS A UNDEFINED OP AND THE    *
*  MSC GOES STRAIGHT TO ITS WAIT STATE.                               *
*                                                                     *
*  @LBP TAKES THE ELEMENT NUMBER FROM THE ACCUMULATOR WHEN ITS BCE    *
*  FIELD IS ZERO; @SIO AND @RAW TAKE THE PROCESSOR MASK THERE.  A     *
*  REPEAT COUNTS 33 US A COUNT, AND ITS EIGHT BITS REACH 8.4 MS, SO   *
*  THE INDEX REGISTER CARRIES THE REST OF THE WAIT.                   *
*                                                                     *
***********************************************************************
IPLMSC   DS    0F
         @LF   IPLSRC              THE IPL SOURCE DISCRETES
         @BZ   IPLDONE             NEITHER MADE
         @TI   -2                  MM1?
         @BZ   IPLSMM1
         @LF   IPLM2N              MM2: BUS CONTROL ELEMENT 19
         @ST   IPLBUSN
         @LF   IPLM2M
         @B    IPLSMSK
IPLSMM1  @LF   IPLM1N              MM1: BUS CONTROL ELEMENT 18
         @ST   IPLBUSN
         @LF   IPLM1M
IPLSMSK  @ST   IPLBUSM             ITS PROCESSOR MASK
         @LF   IPLRPTC             THE LONGEST A REPEAT MAY WAIT
         @TAX  0                   ... IN THE INDEX REGISTER
         @LF   IPLBUSN             THE SELECTED ELEMENT
         @LBP  0,IPLPOS            POSITION THE TAPE
         @LF   IPLBUSM             ITS PROCESSOR MASK
         @SIO  0                   START IT
         @RAW  0(1)                UNTIL IT IS WAITING AGAIN
         @LF   IPLBUSN
         @LBP  0,IPLREAD           READ THE COPY
         @LF   IPLBUSM
         @SIO  0
         @RAW  0(1)
IPLDONE  @WAT  0
***********************************************************************
*                                                                     *
*  POSITION TAPE BCE PROGRAM                                          *
*                                                                     *
***********************************************************************
IPLPOS   DS    0F
         #DLYI 0                   BOUNDARY ALIGNMENT
         #DLYI 1820                DELAY TO PREVENT TAPE REVERSAL
         #LBR  IPLPSTS             WHERE THE STATUS REPLY LANDS
         #CMDI IPLMMUM,IPLSRCW     READ THE STATUS REGISTERS
         #RDLI 1                   TWO HALFWORDS
         #CMD  IPLPTCT             POSITION THE TAPE
         #WAT  0
***********************************************************************
*                                                                     *
*  READ THE MASS MEMORY BCE PROGRAM                                   *
*                                                                     *
***********************************************************************
IPLREAD  DS    0F
         #DLYI 0                   BOUNDARY ALIGNMENT
         #DLYI 1820                DELAY TO PREVENT TAPE REVERSAL
         #DLYI 1820                ... AND FOR THE TRANSPORT TO POSITION
         #CMD  IPLEBCT             EXTEND THE BLOCK COUNT
         #DLYI 2
         #DLYI 0
         #CMD  IPLRDCT             READ
         #BU   IPLRECV
***********************************************************************
*                                                                     *
*  RECEIVE SEQUENCE.  THE COPY IS ONE FILE, ONE TRACK, BLOCKS BACK    *
*  TO BACK, AND LANDS IN SECTOR ZERO IN ONE RUN.                      *
*                                                                     *
***********************************************************************
IPLRECV  #DLYI 0                   BOUNDARY ALIGNMENT
         #LBR  0                   SECTOR ZERO
         #RDLI IPLSECT-1
         #SST  IPLSTAT
         #WAT  0
***********************************************************************
*                                                                     *
*  COMMAND AND STATUS DATA AREA                                       *
*                                                                     *
*  A COMMAND IS THE SAME FOR EITHER MASS MEMORY: THE BUS SELECTS THE  *
*  UNIT.  THE TABLES CARRY IT TWICE BECAUSE #CMD INDEXES BY ELEMENT.  *
*                                                                     *
***********************************************************************
         DS    0F
IPLPTCT  EQU   *-36                POSITION TAPE COMMAND TABLE
IPLPTCW  DC    A(IPLCPOS)          ELEMENT 18
         DC    A(IPLCPOS)          ELEMENT 19
IPLEBCT  EQU   *-36                EXTEND BLOCK COMMAND TABLE
IPLEBCW  DC    A(IPLCEXT)          ELEMENT 18
         DC    A(IPLCEXT)          ELEMENT 19
IPLRDCT  EQU   *-36                READ COMMAND TABLE
IPLRDCW  DC    A(IPLCRD)           ELEMENT 18
         DC    A(IPLCRD)           ELEMENT 19
IPLRPTC  DC    A(IPLRPT)           REPEAT COUNT EXTENSION
IPLM1N   DC    A(18)               MASS MEMORY 1: BUS CONTROL ELEMENT
IPLM1M   DC    A(X'2000')          ... AND ITS PROCESSOR MASK
IPLM2N   DC    A(19)               MASS MEMORY 2
IPLM2M   DC    A(X'1000')
IPLSRC   DC    F'0'                THE IPL SOURCE DISCRETES
IPLBUSM  DC    F'0'                PROCESSOR MASK OF THE SELECTED ELEMENT
IPLBUSN  DC    F'0'                ... AND ITS ELEMENT NUMBER
IPLPSTS  DC    F'-1'               POSITION STATUS REPLY
IPLSTAT  DC    F'-1'               READ STATUS; ZERO IS A CLEAN TRANSFER
         END
