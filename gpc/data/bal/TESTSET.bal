TESTREP     CSECT
            ENTRY TESTREP
****** INSTRUCTION REPETOIRE
********
******** CPU I/O
********
            PC    1,2
********
******** FIXED-POINT ARITHMETIC
********
            AR    1,2
            A     1,X'2A'(2)
            A     1,X'2A'(6,2)
            AH    1,X'2A'(2)
            AH    1,X'2A'(6,2)
            AHI   1,X'DEAD'
            AST   1,X'2A'(2)
            AST   1,X'2A'(6,2)
            CR    1,2
            C     1,X'2A'(2)
            C     1,X'2A'(6,2)
            CBL   1,2
            CH    1,X'2A'(2)
            CH    1,X'2A'(6,2)
            CHI   1,X'DEAD'
            CIST  X'2A'(2),X'DEAD'
            DR    1,2
            D     1,X'2A'(2)
            D     1,X'2A'(6,2)
            XUL   1,2
            IAL   1,X'2A'(2)
            IAL   1,X'2A'(6,2)
            IHL   1,X'2A'(2)
            IHL   1,X'2A'(6,2)
            LR    1,2
            L     1,X'2A'(2)
            L     1,X'2A'(6,2)
            LA    1,X'2A'(2)
            LA    1,X'2A'(6,2)
            LCR   1,2
            LFXI  1,-2
            LFXI  1,-1
            LFXI  1,0
            LFXI  1,1
            LFXI  1,2
            LFXI  1,3
            LFXI  1,4
            LFXI  1,5
            LFXI  1,6
            LFXI  1,7
            LFXI  1,8
            LFXI  1,9
            LFXI  1,10
            LFXI  1,11
            LFXI  1,12
            LFXI  1,13
            LH    1,X'2A'(2)
            LH    1,X'2A'(6,2)
            LM    X'2A'(2)
            LM    X'2A'(6,2)
            MSTH  X'2A'(2),X'DEAD'
            MR    1,2
            M     1,X'2A'(2)
            M     1,X'2A'(6,2)
            MH    1,X'2A'(2)
            MH    1,X'2A'(6,2)
            MHI   1,X'DEAD'
            MIH   1,X'2A'(2)
            MIH   1,X'2A'(6,2)
            ST    1,X'2A'(2)
            ST    1,X'2A'(6,2)
            STH   1,X'2A'(2)
            STH   1,X'2A'(6,2)
            STM   X'2A'(2)
            STM   X'2A'(6,2)
            SR    1,2
            S     1,X'2A'(2)
            S     1,X'2A'(6,2)
            SST   1,X'2A'(2)
            SST   1,X'2A'(6,2)
            SH    1,X'2A'(2)
            SH    1,X'2A'(6,2)
            TD    X'2A'(2)
            TD    X'2A'(6,2)
********
******** BRANCHING
********
            BALR  1,2
            BAL   1,X'2A'(2)
            BAL   1,X'2A'(6,2)
            BIX   1,X'2A'(2)
            BIX   1,X'2A'(6,2)
            BCR   4,2
            BC    4,X'2A'(2)
            BC    4,X'2A'(6,2)
            BCB   4,X'2A'
            BCRE  4,2
            BCF   4,X'2A'
            BCT   1,X'2A'(2)
            BCT   1,X'2A'(6,2)
            BCTB  1,X'2A'
            BVCR  4,2
            BVC   4,X'2A'(2)
            BVC   4,X'2A'(6,2)
*            BVCF  4,X'2A'
            B     X'2A'(6,2)
            BZ    X'2A'(6,2)
            BNE   X'2A'(6,2)
********
******** SHIFT OPERATIONS
********
            NCT   1,2
            SLL   1,X'27'
            SLDL  1,X'27'
            SRA   1,X'27'
            SRDA  1,X'27'
            SRDL  1,X'27'
            SRL   1,X'27'
            SRR   1,X'27'
            SRDR  1,X'27'
********
******** LOGICAL OPERATIONS
********
            NR    1,2
            N     1,X'2A'(2)
            N     1,X'2A'(6,2)
            NHI   1,X'DEAD'
            NIST  X'2A'(2),X'DEAD'
            NST   1,X'2A'(2)
            NST   1,X'2A'(6,2)
            XR    1,2
            X     1,X'2A'(2)
            X     1,X'2A'(6,2)
            XHI   1,X'DEAD'
            XIST  X'2A'(2),X'DEAD'
            XST   1,X'2A'(2)
            XST   1,X'2A'(6,2)
            OR    1,2
            O     1,X'2A'(2)
            O     1,X'2A'(6,2)
            OHI   1,X'DEAD'
            OST   1,X'2A'(2)
            OST   1,X'2A'(6,2)
            SUM   1,2
            SB    X'2A'(2),X'BEEF'
            SHW   X'2A'(2)
            SHW   X'2A'(6,2)
            TB    X'2A'(2),X'BEEF'
            TRB   1,X'BEEF'
            TH    X'2A'(2)
            TH    X'2A'(6,2)
            ZB    X'2A'(6),X'BEEF'
            ZRB   2,X'BEEF'
            ZH    X'2A'(2)
            ZH    X'2A'(6,2)
********
******** FLOATING-POINT OPERATIONS
********
            AEDR  1,2
            AED   1,X'2A'(2)
            AED   1,X'2A'(6,2)
            AER   1,2
            AE    1,X'2A'(2)
            AE    1,X'2A'(6,2)
            CER   1,2
            CE    1,X'2A'(2)
            CE    1,X'2A'(6,2)
            CVFX  1,2
            CVFL  1,2
            DEDR  1,2
            DED   1,X'2A'(2)
            DED   1,X'2A'(6,2)
            DER   1,2
            DE    1,X'2A'(2)
            DE    1,X'2A'(6,2)
            LED   1,X'2A'(2)
            LED   1,X'2A'(6,2)
            LER   1,2
            LE    1,X'2A'(2)
            LE    1,X'2A'(6,2)
            LECR  1,2
            LFXR  1,2
            LFLI  1,E'0.0'
            LFLI  1,E'1.0'
            LFLI  1,E'2.0'
            LFLI  1,E'3.0'
            LFLI  1,E'4.0'
            LFLI  1,E'5.0'
            LFLI  1,E'6.0'
            LFLI  1,E'7.0'
            LFLI  1,E'8.0'
            LFLI  1,E'9.0'
            LFLI  1,E'10.0'
            LFLI  1,E'11.0'
            LFLI  1,E'12.0'
            LFLI  1,E'13.0'
            LFLI  1,E'14.0'
            LFLI  1,E'15.0'
            LFLR  1,2
            MVS   1,X'2A'(2)
            MVS   1,X'2A'(6,2)
            MEDR  1,2
            MED   1,X'2A'(2)
            MED   1,X'2A'(6,2)
            MER   1,2
            ME    1,X'2A'(2)
            ME    1,X'2A'(6,2)
            SEDR  1,2
            SED   1,X'2A'(2)
            SED   1,X'2A'(6,2)
            SER   1,2
            SE    1,X'2A'(2)
            SE    1,X'2A'(6,2)
            STED  1,X'2A'(2)
            STED  1,X'2A'(6,2)
            STE   1,X'2A'(2)
            STE   1,X'2A'(6,2)
********
******** SPECIAL OPERATIONS
********
            ISPB  4,X'2A'(2)
            ISPB  4,X'2A'(6,2)
            LPS   X'2A'(2)
            LPS   X'2A'(6,2)
            MVH   1,2
            SPM   2
            SSM   X'2A'(2)
            SSM   X'2A'(6,2)
            SCAL  1,X'2A'(2)
            SCAL  1,X'2A'(6,2)
            SRET  4,2
            SVC   X'2A'(2)
            SVC   X'2A'(6,2)
            TS    X'2A'(2)
            TS    X'2A'(6,2)
            TSB   X'2A'(2),X'BEEF'
*******
******* INTERNAL CONTROL OPERATIONS
*******
            ICR   1,2

#DDATA      CSECT
            ENTRY #DDATA,CONST1,CONST2,ZEROREGS
CONST1      DC    X'12345678'
CONST2      DC    X'87654321'
RESULT1     DC    X'00000000'
ZEROREGS    DS    16H
HMAXIN      DC    H'23'
            DC    H'14'
            DC    H'-1'
            DC    H'3'
            DC    H'99'
            DC    H'8'
            DC    H'4'
HMAXINSZ    DC    H'7'
HMAXOUT     DC    H'0'
TADD        CSECT
            ENTRY TADD
            EXTRN #DDATA,CONST1,CONST2
            USING #DDATA,0
            LA    0,#DDATA(0)
            L     3,CONST1(0)
            L     4,CONST2(0)
            AR    3,4
            ST    3,RESULT1(0)
            L     5,RESULT1(0)
            LFXI  5,8
            LFXI  6,2
            DR    5,6
            LFXI  0,-2
            LFXI  0,-1
            LFXI  0,0
            LFXI  0,1
TXUL        CSECT
*            ENTRY T2
            EXTRN #DDATA,CONST1,CONST2
            USING #DDATA,0
            LM    0,ZEROREGS(0)
            LA    0,#DDATA(0)
            L     1,CONST1(0)
            L     2,CONST2(0)
            XUL   1,1
            XUL   1,1
            XUL   1,2
            XUL   1,2
            LM    0,ZEROREGS(0)
            END
HMAX        CSECT
            ENTRY HMAX
            EXTRN HMAX
            USING HMAX,1
            LA    1,HMAX
            XUL   5,5   * put count in 16-31
            OR    2,5
            LH    5,0(2,0)
CMPLOOP     CH    5,0(2,0)
            BCF   2,2
            LH    5,0(2,0)
NXTLOOP     BIX   2,CMPLOOP(1)
            BCRE  7,0

HMAXT       CSECT
            EXTRN #DDATA,HMAXIN,HMAXINSZ,HMAXOUT,HMAX
            LM    0,ZEROREGS(0)
            LA    0,#DDATA(0)
            LA    2,HMAXIN(0)
            LH    5,HMAXINSZ(0)
*            BAL   0,HMAX(1)

