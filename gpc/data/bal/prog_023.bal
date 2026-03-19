#DINITIA CSECT                
BL       DS    X'0'           
         DS    X'0'           
         DS    X'0'           
         DS    X'0'           
         DS    X'0'           
@0INITIA CSECT                
$0INITIA CSECT                
INITIAL_AND_CONSTANT EQU   *              
         USING @0INITIA,0     
         USING #DINITIA,1     
         USING BL,3           
         LA    0,@0INITIA     
         LA    1,#DINITIA     
         NHI   1,=X'7FFF'     
         STH   1,5(0)         
         IAL   0,18           
         LA    3,BL           
*        LDM   $ZDSESET       
         STH   3,9(0)         
         SVC   =H'21'         
         END                  
