OUTPUT      CSECT
AOUT        DS      10H            
            ENTRY   AOUT

DATA        CSECT
AIN         DC    X'1234'
            ENTRY AIN
            DC    X'DEAD'
            DC    X'BEEF'
*            DC    D'456'
*            DC    E'3.14159'
*            DC    Y(TESTCOPY)
DATALEN     DC    X'3'

TESTCOPY    CSECT
            EXTRN AOUT,AIN
            LA    0,TESTCOPY
            LA    1,DATA
            LA    2,OUTPUT
            USING TESTCOPY,0
            USING DATA,1
            USING OUTPUT,2
            LHI   3,0
            IHL   3,DATALEN
            XUL   3,3
            AHI   3,-1
            XUL   3,3
LOOP        LH    4,AIN(3)
            STH   4,AOUT(3)
            BIX   3,LOOP
            ICR   4,5