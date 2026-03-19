         CLI   SEX,C'M'       Male?
         BNE   ISFEM          If not, branch around
         L     7,MALES        Load current value of MALES into register 7
         AL    7,=F'1'        add 1 
         ST    7,MALES        store back the result
         B     GO_ON          Finished with this portion
ISFEM    EQU   *              A label
         L     7,FEMALES      Load current value in FEMALES into register 7 
         AL    7,=F'1'        add 1 
         ST    7,FEMALES      store back the result
GOON     EQU   *              - rest of program -
*
MALES    DC    F'0'           Counter for MALES (initially=0)
FEMALES  DC    F'0'           Counter for FEMALES (initially=0)
