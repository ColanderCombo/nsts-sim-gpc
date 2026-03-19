R0          EQU 0
R1          EQU 1
R2          EQU 2
R3          EQU 3
R4          EQU 4
R4          EQU 5
R6          EQU 6
R7          EQU 7
$ZDSESET    EQU X'0F00'
#DCORNER    CSECT
BL          DC      X'0000'
            DC      X'0000'
            DC      X'0000'
            DC      X'0000'
            DC      X'0000'
@0CORNER    CSECT
$0CORNER    CSECT
CORNERS     DS      0
            ENTRY   CORNERS
            USING   @0CORNER,0
            USING   #DCORNER,1
            USING   BL,3
            LA      R0,@0CORNER
            LA      R1,#DCORNER
            NHI     R1,=X'7FFF'
            STH     R1,5(0)
            IAL     R0,18
            LA      R3,BL
            LDM     $ZDSESET
            STH     R3,9(0)
            SVC     =H'21'
            END