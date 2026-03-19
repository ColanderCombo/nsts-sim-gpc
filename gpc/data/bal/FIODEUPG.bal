FIODEUPG    CSECT

                              * BCE_Base_Register        &008.09
FIODBF1P    DS      1H        * DEU_Message_Header       J060.02
FIOBRE      DS      1H        * BCE_Base_Register_Table  Y005
FIOWCE      DS      1H        * BCE_Word_Count_Table     Y006
FIODBF1B    DS      1H        * DEU_BITE_Message_Header  J070.05
FIODBF2B    DS      1H        
FIODBF3B    DS      1H        

* DEU_Poll (261.1)
* Enter
* Load BCE_Base_Register With Address Of Entry 1 Of DEU_Message_Header
* Issue Listen Command
* Load BCE_Base_Register With Address Of Entry 1 Of DEU_Message_Header (1)
* Issue Mode Status Request
* CALL Common_BCE_Processing FIOWAT11 Entry Point Figure (3.2.8.9-1)
*
* DEU_Dump (201.2)
* Enter
* Load BCE_Base_Register From BCE_Base_Register Table
* Issue Listen Command
* Issue DEU Memory Dump Request
* Load BCE_Base_Register From BCE_Base_Register_Table (1)
* Receive Data Using Word Count From BCE_Word_Count_Table
* CALL Common_BCE_Processing FIOWAT11 Entry Point Figure (3.2.8.9-1)
*
* DEU_Memory_Fill (261.3)
* Enter
* Load BCE_Base_Register From BCE_Base_Register Table
* Issue DEU Memory Fill Command
* CALL Common_BCE_Processing FIOLISTN Entry Point Figure (3.2.8.9-1)
*
* DEU_Reset_Scratch_Pad_Line (261.4)
* Enter
* Issue Scratch Pad Line Request
* CALL Common_BCE_Processing FIOLISTN Entry Point Figure (3.2.8.9-1)
*
* DEU_Keyboard_Request (261.5)
* Enter
* Load BCE_Base_Register With Addres Of Entry 1 Of DEU_Message_Header
* Issue Listen Command
* Load BCE_Base_Register With Address Of First DEU_Message_Header Entry (1)
* Issue Keyboard Request (Receive 42 Words)
* CALL Common_BCE_Processing FIOWAT11 Entry Point Figure (3.2.8.9-1)
*
* DEU_Bite_Status_Request (261.6)
* Enter
* Load BCE_Base_Register With Address Of Entry 1 Of DEU_BITE_Message_Header
* Issue Listen Command
* Load BCE_Base_Register With Address Of Entry 1 Of DEU_BUTE_Message_Header (1)
* Issue BITE STATUS Request (Receive 5 Words)
* CALL Common_BCE_Processing FIOWAT11 Entry Point Figure (3.2.8.9-1)
*

#PFIDFCT    CSECT
#PFIDECT    DS      0H
   



#PFIOECT    CSECT

FIOB0012    DS      1H        * IUA_12_N_Counters           #200.6
FIOWIXTB    DS      1H        * WIX_Table                   #201
FIOB0017    DS      1H        * IUA_17_N_Counters           #200.9
FIOB0611    DS      1H        * IUA_11_N_Counters           #200.5
FIOB0011    DS      1H        * Data_Path_Error_Counters    #200.4

FIOWAT11    DS      0H
FIOWAT12    DS      0H
FIOWAT17    DS      0H

FIOLISTN    DS      0H

FIOMLSTN    DS      0H





