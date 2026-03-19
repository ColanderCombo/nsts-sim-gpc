R0          EQU     0
R1          EQU     1
R2          EQU     2
R3          EQU     3
R4          EQU     4
R5          EQU     5
R6          EQU     6
R7          EQU     7

TPSASOP     EQU     X'0058'
TCVTOLD     EQU     X'0141'
TCVTNEW     EQU     X'0142'
FPMSVCEP    EQU     X'80CE'
FPMDISP     EQU     X'A844'


#0FPMSVC    CSECT

            STH     R2,X'9CA6'
#@LB20      DS      0H
            BCF     0,0
            LH      R2,X'0158'
            TRB     R2,X'0400'
            BC      3,X'8C1E'
            LHI     R4,X'8410'
            L       R5,X'0180'
            PC      R5,R4
            L       R5,X'0168'
            L       R0,X'0178'
            NR      R0,R5
            N       R5,X'0172'
            LHI     R6,X'0818'
FCMCSOUL    DS      0H
            XR      R7,R7
            ICR     R1,R7
            S       R1,X'8244'
FCMCSMNL    DS      0H
            PC      R2,R6
            ICR     R3,R7
            S       R3,X'81EA'
            LR      R4,R2
            SLL     R4,4
            XR      R2,R4
            ICR     R4,R7
            SR      R4,R1
            N       R4,X'81E8'
            BCF     4,8
            NR      R2,R5
            BAL     R7,X'95D6'
            OHI     R0,X'8000'
            BAL     R7,X'9400'
            BCF     7,X'001C'
FCMDIAR2    DS      0H
            ICR     R4,R7
            SR      R4,R3
            N       R4,X'81E8'
            BC      4,X'8C02'
            PC      R3,R6
            ICR     R4,R7
            ST      R4,X'81FC'
*            SHW     X'8200'
            LR      R2,R3
            SLL     R4,4
            XR      R3,R4
            OR      R2,R3
            NR      R2,R5
            BCF     4,X'000A'
            LR      R3,R2
            SLL     R3,8
            OR      R2,R3
            LR      R3,R0
            NR      R0,R2
            XR      R3,R0



            LA      R1,X'8145'
            LFXI    R5,2
            XR      R4,R4
#@LB7       DS      0H
            LH      R6,0(R1)
            BCF     7,6
#@LB8       DS      0H
            CH      R6,1(R0)
            BCF     3,4
            LH      R3,2(R0)
            STH     R3,1(R1)
            LFXI    R5,1
            LFXI    R4,-1
#@LB11      DS      0H
#@LB10      DS      0H
            LA      R1,2(R1)
            BCTB    R5,X'000C'
            CHI     R4,X'FFFF'
            BCF     4,X'000A'
            LR      R4,R4
            BCF     3,3
*            SHI     R1,2
            BCF     7,1
#@LB15      DS      0H
            LR      R1,R4
#@LB17      DS      0H
            LH      R3,1(R0)
            STH     R3,0(R1)
            LH      R3,2(R0)
            STH     R3,1(R1)
#@LB13      DS      0H
#@LB5       DS      0H
            BC      7,X'B010'
            LH      R0,TCVTOLD
            L       R5,TPSASOP
            ST      R5,4(R0)
            LH      R0,TPSASOP+3
            LH      R4,0(R0)
            NHI     R4,X'00FF'
            LA      R2,FPMSVCEP
            LH      R2,0(R4,R2)
            BAL     R7,0(R2)
FPMSVC1     DS      0H
            ENTRY   FPMSVC1
            LH      R0,TCVTOLD
            CH      R0,TCVTNEW
            BNE     FPMDISP
            LPS     4(R0)
