      L    3,ZIGGY
      SLA  4,5             
      MVC  TARGET,SOURCE   
      AP   COUNT,=X'1'     
      B    NEXT            
HERE  EQU   *              
      CLC   TARGET,=C'ADDRESS'  
      BE    THERE               
    