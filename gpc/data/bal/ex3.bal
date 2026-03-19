HELLO    CSECT               The name of this program is 'HELLO'
*                            Register 15 points here on entry from OPSYS or caller.
         STM   14,12,12(13)  Save registers 14,15, and 0 thru 12 in caller's Save area
         LR    12,15         Set up base register with program's entry point address
         USING HELLO,12      Tell assembler which register we are using for pgm. base
         LA    15,SAVE       Now Point at our own save area
         ST    15,8(13)      Set forward chain
         ST    13,4(15)      Set back chain               
         LR    13,15         Set R13 to address of new save area
*                            -end of housekeeping (similar for most programs) -
         WTO   =C'Hello World' Write To Operator  (Operating System macro)
*
         L     13,4(13)      restore address to caller-provided save area
         XC    8(4,13),8(13) Clear forward chain
         LM    14,12,12(13)  Restore registers as on entry
         DROP  12            The opposite of 'USING'
         SR    15,15         Set register 15 to 0 so that the return code (R15) is Zero
         BR    14            Return to caller
*           
SAVE     DS    18F           Define 18 fullwords to save calling program registers 
         LR    13,(SAVE+10)        Set R13 to address of new save area
         END  HELLO          This is the end of the program
