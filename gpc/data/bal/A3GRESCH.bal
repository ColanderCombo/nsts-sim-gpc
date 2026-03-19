#DGRESCH    CSECT
            ENTRY   #DGRESCH
#DGRESCH    DS      0H
            DC      X'0000'
            DC      X'0000'
            DC      X'0000'
            DC      X'0000'
            DC      X'0000'
            DC      X'0000'
            DC      X'0000'
            DC      X'0000'
            DC      X'0000'
            DC      X'0000'
            DC      X'0000'
BITPTR      DC      X'0000' * 0x0B
            DC      X'0000'
            DC      X'0000'
            DC      X'0000'
            DC      X'0000'
FAULTPPS    DC      X'0000' * 0x10
FDSTATUS    DC      X'0000' * 0x11
SFFAULT     DC      X'0000' * 0x12
            DC      X'0000'
FAILCNT     DC      X'0000'         * 0x14
            DC      X'0000'
TOLERANC    DC      X'00000000'     * 0x16
            DC      X'0000'
            DC      X'0000'
FAILCNTR    DC      X'0000'         * 0x1a 
            DC      X'0000'
            DC      X'0000'
            DC      X'0000'
            DC      X'0000'
            DC      X'0000'
            DC      X'0000'
            DC      X'0000'
            DC      X'0000'
            DC      X'0000'
            DC      X'0000'
            DC      X'0000'
            DC      X'0000'
            DC      X'0000'
            DC      X'0000'
GREVINDX    DC      X'0001'         * 0x29 [4]
            DC      X'0002'
            DC      X'0003'
            DC      X'0001'
GREVDATA    DC      E'0.0'  * 0x32 [3]
            DC      E'0.0'
            DC      E'0.0'

#LOCAL      CSECT
            ENTRY   #LOCAL
#LOCAL      DS      0H
            DC      X'0000'
MASKS       DC      X'0000' * 0x01
            DC      X'0000'
            DC      X'0000'
            DC      X'0000'
KH1         DC      X'0000' * 0x05
KH4         DC      X'0000' * 0x06
SHIFTS      DC      X'0000' * 0x07
KH6         DC      X'0000' * 0x08
KH3         DC      X'0000' * 0x09
            DC      X'0000'
FLAGS       DC      X'0000' * 0x0B
            DC      X'0000'
KH5         DC      X'0000' * 0x0D
KH2         DC      X'0000' * 0x0E

            
           



*--->A3GRESCH    AMAIN
#0A3GRESCH  CSECT
A3GRESCH    DS      0H             PRIMARY ENTRY POINT
            ENTRY   A3GRESCH
STACK       DSECT
STACK       DS      0H
OLDSTACK    DS      0H
            ENTRY   STACK,OLDSTACK
*           DS      18H            STANDARD STACK AREA DEFINITION
            DS      F              PSW (LEFT HALF)
            DS      2F             R0,R1
ARG2        DS      F              R2
            DS      F              R3
ARG4        DS      F              R4
ARG5        DS      F              R5
ARG6        DS      F              R6
ARG7        DS      F              R7
*        AND CF STANDARD STACK AREA
*        NO ADDITIONAL STACK STORAGE REQUIRED FOR THIS ROUTINE
STACKEND    DS      0F             END OF COMBINED STACK AREA
NEXTSTK     DS      0H
#0A3GRESCH  CSECT
            USING STACK,0           ADDRESS STACK AREA
            NIST    9(0),0          CLEAR ON ERROR INFO (LCL DATA PTR)
            SPACE
*<---A3GRESCH    AMAIN
A3GRESCH    CSECT
R0          EQU     0
R1          EQU     1
R2          EQU     2
R3          EQU     3
R4          EQU     4
R5          EQU     5
R6          EQU     6
R7          EQU     7
F0          EQU     0
F1          EQU     1
F2          EQU     2
F3          EQU     3
F4          EQU     4
F5          EQU     5
F6          EQU     6
F7          EQU     7
            USING   STACK,0            ADDRESS STACK AREA
            LA      0,0(0)             CLEAR LOWER HALF AS NULL LOCAL DATA PTR
            STM@    NEXTSTK            SAVE REGS AT CALL IN NEW STACK AREA
            LH      0,NEXTSTK          UPDATE STACK PTR
ACC         EQU     6
S5          EQU     61
S7          EQU     63
            USING   #DGRESCH,R1
            USING   #LOCAL,2
*-------------- HAL STATEMENT NUMBER 44
*-------------- HAL STATEMENT NUMBER 45
*-------------- HAL STATEMENT NUMBER 46
HAL46       LH      7,KH1
*-------------- HAL STATEMENT NUMBER 47
HAL47       LH      6,GREVINDX(7)
            LE      0,GREVDATA(6)
            LR      5,7
            AH      5,KH1
            LH      6,GREVINDX(5)
            SE      0,GREVDATA(6)
            BNM     HAL47A
            LECR    0,0
HAL47A      CE      0,TOLERANC
            BNH     HAL49
*-------------- HAL STATEMENT NUMBER 48
            LH      ACC,FAILCNTR(7)
            AH      ACC,KH1
            B       HAL49A
*-------------- HAL STATEMENT NUMBER 49
HAL49       SR      ACC,ACC
HAL49A      STH     ACC,FAILCNTR(7)
*-------------- HAL STATEMENT NUMBER 50
            AH      7,KH1
            CH      7,KH4
            BL      HAL47
*-------------- HAL STATEMENT NUMBER 51
            LH      ACC,FAILCNTR+1
            AH      ACC,FAILCNTR+2
            AH      ACC,FAILCNTR+3
            BZ      HAL79
*-------------- HAL STATEMENT NUMBER 52
*-------------- HAL STATEMENT NUMBER 53
            LH      5,BITPTR
            LH      5,FLAGS(5)
            LH      4,KH1
            SLL     4,(S5)
            LH      3,FAULTPPS
*-------------- HAL STATEMENT NUMBER 54
            LH      7,KH1
            LH      ACC,FAILCNT
*-------------- HAL STATEMENT NUMBER 55
HAL55       CH      ACC,FAILCNTR(7)
            BH      HAL57
*-------------- HAL STATEMENT NUMBER 56
            OR      3,4
            B       HAL58
*-------------- HAL STATEMENT NUMBER 57
HAL57       LR      5,4
            XHI     5,X'FFFF'
            NR      3,5
*-------------- HAL STATEMENT NUMBER 58
HAL58       SRL     4,1
            AH      7,KH1
            CH      7,KH4
            BL      HAL55
            STH     3,FAULTPPS
*-------------- HAL STATEMENT NUMBER 59
            LH      7,BITPTR
            LH      4,MASKS(7)
            LH      5,SHIFTS(7)
            LH      7,FLAGS(7)
            NR      3,4
            SRL     3,(S5)
            SH      3,KH3
            BZ      CASE1
            SH      3,KH1
*-------------- HAL STATEMENT NUMBER 66
CASE2       BZ      HAL79
            SH      3,KH1
            BZ      CASE3
            SH      3,KH1
            BZ      CASE4
            B       HAL79
*-------------- HAL STATEMENT NUMBER 60
*-------------- HAL STATEMENT NUMBER 61
CASE1       LH      6,KH6
            SH      7,KH2
*-------------- HAL STATEMENT NUMBER 64
            STH     3,FAILCNTR+2
            B       HAL70A
*-------------- HAL STATEMENT NUMBER 65
*-------------- HAL STATEMENT NUMBER 67
CASE3       LH      6,KH3
*-------------- HAL STATEMENT NUMBER 70
            STH     3,FAILCNTR+1
HAL70A      STH     3,FAILCNTR+3
            B       SUB
*-------------- HAL STATEMENT NUMBER 71
*-------------- HAL STATEMENT NUMBER 72
CASE4       LH      6,KH5
            SH      7,KH1
*-------------- HAL STATEMENT NUMBER 75
            STH     3,FAILCNTR+2
            STH     3,FAILCNTR+1
*-------------- HAL STATEMENT NUMBER 76
*-------------- HAL STATEMENT NUMBER 63
*-------------- HAL STATEMENT NUMBER 69
*-------------- HAL STATEMENT NUMBER 74
SUB         LH      5,SFFAULT
            NR      5,6
            STH     5,SFFAULT
*-------------- HAL STATEMENT NUMBER 62
*-------------- HAL STATEMENT NUMBER 68
*-------------- HAL STATEMENT NUMBER 73
            LH      5,KH1
            SLL     5,(S7)
            XHI     5,X'FFFF'
            LH      3,FDSTATUS
            NR      3,5
            STH     3,FDSTATUS
*-------------- HAL STATEMENT NUMBER 77
*-------------- HAL STATEMENT NUMBER 78
*-------------- HAL STATEMENT NUMBER 79
*---->HAL79       AEXIT
HAL79       DS      0H
*<----HAL79       AEXIT
************RETURN TO CALLER******************************************
HAL79       LM      OLDSTACK     RESTORE REGS AT ENTRY
            BCRE    7,4          RETURN TO CALLER
**********************************************************************
