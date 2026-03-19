STACK       CSECT
            DS    10H
            END

TADATA      CSECT
            ENTRY TADATA,X1,X2
X1          DC    X'0000'
X2          DC    X'0000'



TESTADDRS   CSECT
            EXTRN X1,X2,STACK,TADATA,LOCAL,L1,L2
*            LA    0,STACK
*            LA    1,TADATA
*            LA    2,LOCAL
*            USING STACK,0
*            USING LOCAL,2
*            USING TADATA,1
*            L     4,X1
*            A     4,L2
*            L     4,L2
*            ST    4,L2
*            L     5,X1+1
*            LHI   1,X'1234'
*            LH     1,L2+1

LOCAL       CSECT
            ENTRY L1,L2
L1          DC    X'1234'
L2          DC    X'4567'

