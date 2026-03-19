#DDECLAR CSECT                
BL       DS    X'0'           
         DS    X'0'           
         DS    X'0'           
         DS    X'0'           
         DS    X'0'           
@0DECLAR CSECT                
#DDECLAR CSECT                
COUNTER  DC    I'0'           
POSITION DC    E'0'           
VELOCITY DC    E'0'           
TORQUE   DC    E'0'           
NEW_CO_ORDS DC    E'0'           
SPEED    DC    E'0'           
N        DC    I'0'           
WIND_FORCE DC    E'0'           
$0DECLAR CSECT                
DECLARE3 EQU   *              
         USING @0DECLAR,0     
         USING #DDECLAR,1     
         USING BL,3           
         LA    0,@0DECLAR     
         LA    1,#DDECLAR     
         NHI   1,=X'7FFF'     
         STH   1,5(0)         
         IAL   0,18           
         LA    3,BL           
*        LDM   $ZDSESET       
         STH   3,9(0)         
         SVC   =H'21'         
         END                  
