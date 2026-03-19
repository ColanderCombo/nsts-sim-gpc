#0TESTDC    CSECT
REG2        EQU     2
TEST        EQU     X'3F'
ALPHA       EQU     1
BETA        EQU     2
GAMMA       EQU     3
FIELD       EQU     ALPHA-BETA+GAMMA*TEST

FIELD2      DC      C'TOTAL IS 10'
            DC      C'DONT''T'
            DC      C'A,B&&C'
            DC      3CL4'ABCDE'
            DC      4CL3'NO'
            DS      0F
TEST2       DC      X'FF00FF00'
ALPHA2      DC      3XL2'A6F4E'
            DC      2XL3'2DDA'
*CONWRD      DC      3F'+658474'
*            DC      4FL3'-9500250'
*            DC      2H'256'
*            DC      E'46.415'
*            DC      E'46415E-3'
*            DC      E'+46415.E-3'
*            DC      E'.46415E2'
*            DC      E'4.6415E+1'
*            DC      4E'3.45E76'
*            DC      D'-72957'
*            DC      D'-729.57E+2'
*            DC      D'-729.57E2'
*            DC      D'-.72957E5'
*            DC      D'-7295700.E-2'
*ADCON1      DC      A(AREA+2)
*ADCON2      DC      AL2(FIELD-256)
*
*BLCON       DC      FL.13'579'
*BLMCON      DC      FL.10'161,21,57'
*BLMOCON     DC      FL.7'9',CL.10'AB',XL.14'C4'
*FIELD2      DC      C'TOTAL IS 110'
*FIELD3      DC      CL15'TOTAL IS 110'
*FIELD4      DC      C'TOTAL IS &&10'
*FIELD5      DC      3CL4'ABCDE'
*            MVH     AREA(12),=3CL4'ABCDE'
*            DS      0F
*TEST1       DC      X'FF00FF00'
*            SB      5,=X'FF
*ALPHACON    DC      3XL2'A6F4E'
*BCON        DC      B'11011101'
*BTRUNC      DC      BL1'10100011'
*BPAD        DC      BL1'101'
*CONWRD      DC      3F'658474'
*HALFCON     DC      HS6'-25.46'
*FULLCON     DC      HS12'3.50E-2'
*            AH      7,=HS12'3.50E-2'
*THREECON    DC      FS4'10,25.3,100'
*            DC      E'46.415'
*            DC      E'46415E-3'
*            DC      E'+464.15E-1'
*            DC      E'+.46415E+2'
*            DC      EE2'.46415'
*            AE      6,=EE2'.46415'
*FLOAT       DC      DE+4'+46,-3.729,+473'
*            DC      P+'+1.25'
*            DC      Z'-543'
*            DC      Z'79.68'
*            DC      PL3'79.68'
*DECIMALS    DC      PL8'+25.8,-3874,+2.3',Z'+80,-3.72'
*ACONST      DC      A(108,LOOP,END-STRT,*+4096)
*            LM      4,7,=A(108,LOOP,END-STRT,*+4096)
*FIELD       DS      4CL10
*AREA        DS      CL100
*ONE         DS      CL80
*TWO         DS      80C
*THREE       DS      6F
*FOUR        DS      D
*FIVE        DS      4H
*            DS      0D
*AREA1       DS      CL128
*RDAREA      DS      0CL80
*            DS      CL4
*PAYNO       DS      CL6
*NAME        DS      CL20
*DATE        DS      0CL6
*DAY         DS      CL2
*MONTH       DS      CL2
*YEAR        DS      CL2
*            DS      CL10
*GROSS       DS      CL8
*FEDTAX      DS      CL8
*            DS      CL18
*PGM1        TITLE   'FIRST HEADING'
*            TITLE   'A NEW HEADING'
*            EJECT
*            SPACE
