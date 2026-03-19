* This is a comment line
* Load the fullword integer stored at the
* location labeled 'ZIGGY' into general register 3:
      L    3,ZIGGY
      SLA  4,5             shift the value in general register 4 left by 5 bits
      MVC  TARGET,SOURCE   move characters from location 'SOURCE' to 'TARGET'
      AP   COUNT,=P'1'     add 1 to value in memory location 'COUNT' (packed decimal format)
      B    NEXT            unconditional branch to label 'NEXT'
HERE  EQU   *              This is a label
      CLC   TARGET,=C'ADDRESS'  Compare memory location 'TARGET' to string 'ADDRESS'
      BE    THERE               branch if equal to program label 'THERE'
          