R0          EQU     0
R1          EQU     1
R2          EQU     2
R3          EQU     3
R4          EQU     4
R5          EQU     5
R6          EQU     6
R7          EQU     7

            EXTRN   TPSASOP
            EXTRN   TCVTOLD
            EXTRN   TCVTNEW
            EXTRN   FPMSVCEP
            EXTRN   FPMDISP


#0FPMSVC    CSECT
FPMSVC      DS      0H
            ENTRY   FPMSVC  
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
            END

