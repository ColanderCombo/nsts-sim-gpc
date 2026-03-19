#DDATATY CSECT                
BL       DS    X'0'           
         DS    X'0'           
         DS    X'0'           
         DS    X'0'           
         DS    X'0'           
@0DATATY CSECT                
#DDATATY CSECT                
S        EQU   *              
         DC    E'0'           
I        EQU   *              
         DC    I'0'           
V        EQU   *              
         DC    E'0'           
M        EQU   *              
         DC    E'0'           
$0DATATY CSECT                
DATATYPES EQU   *              
         USING @0DATATY,0     
         USING #DDATATY,1     
         USING BL,3           
         LA    0,@0DATATY     
         LA    1,#DDATATY     
         NHI   1,=X'7FFF'     
         STH   1,5(0)         
         IAL   0,18           
         LA    3,BL           
*        LDM   $ZDSESET       
         STH   3,9(0)         
         SVC   =H'21'         
         END                  
