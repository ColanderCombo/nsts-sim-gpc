
import {PackedBits} from 'gpc/util'
import {STP_BCE_BASE} from 'gpc/iop_msc_instr'

export class BCEInstruction extends PackedBits
    constructor: () ->
        super()
        @makeOpTbl()

    makeOpTbl: () ->
        @opByMask = {}
        @descByOp = {}
        @orderedMasks = []

        @formats = []

        for k,v of @ops
            desc = @makeDesc v.d
            desc.nm = k
            desc.d = v.d
            desc.e = v.e
            desc.fmt = v.f

            @descByOp[desc.nm] = desc
            if desc.mask not of @opByMask
                @orderedMasks.push desc.mask
                @opByMask[desc.mask] = {}
            @opByMask[desc.mask][desc.maskedVal] = desc

        @orderedMasks = @orderedMasks.sort().reverse()

        @fmtTable = {}
        for format in @formats
            args = format.split(' ')[1]
            @fmtTable[args] = {}

    decode: (combined, desc) ->
        v = {nm: desc.nm}
        for k, f of desc.f
            v[k] = @getField(combined, f)
        return v

    # Disassembly
    #
    OPERAND_FIELDS: {
        ADDRESS: 'ad', ADDR: 'ad', COUNT: 'cd', DISP: 'd', DISPLACEMENT: 'd'
        TRANSFERCOUNT: 'c', IUA: 'u', IMMED: 'i', IMM: 'i', COMMAND: 'cm'
        TIMEOUT: 'i', FLAG: 'f', BCE: 'b', MASK: 'd'
    }

    toStr: (hw1, hw2) ->
        hw1 = hw1 & 0xffff
        hw2 = hw2 & 0xffff
        combined = (((hw1 * 0x10000) + hw2)) >>> 0
        for mask in @orderedMasks when mask > 0xffff
            maskedVal = (combined & mask) >>> 0
            desc = @opByMask[mask]?[maskedVal]
            if desc?
                return { text: @_render(desc, @decode(combined, desc)), len: 2, nm: desc.nm }
        for mask in @orderedMasks when mask <= 0xffff
            maskedVal = (hw1 & mask) >>> 0
            desc = @opByMask[mask]?[maskedVal]
            if desc?
                return { text: @_render(desc, @decode(hw1, desc)), len: 1, nm: desc.nm }
        return { text: "??? #{hw1.toString(16).padStart(4, '0')}", len: 1, nm: null }

    _render: (desc, v) ->
        ops = []
        fmt = desc.fmt?[0]
        if fmt?
          rest = fmt.split(' ').slice(1).join(' ')
          for name in (if rest then rest.split(',') else [])
            key = name.trim().toUpperCase().replace(/\s+/g, '')
            letters = @OPERAND_FIELDS[key] ? ''
            letter = (l for l in letters when v[l]?)[0]
            ops.push(if letter? then "X'#{v[letter].toString(16).toUpperCase()}'" else key)
        # m is the index-mode flag on the store forms.
        ops.push('X') if v.m
        text = desc.nm
        text += '  ' + ops.join(',') if ops.length > 0
        return text

    exec: (iop, hw1, hw2) ->
        # Try 32-bit combined match first (for long instructions)
        # Note: x & mask is SIGNED; '>>> 0' is a js trick to coerce to unsigned
        combined = ((hw1 << 16) | hw2) >>> 0
        for mask in @orderedMasks
            if mask > 0xffff
                maskedVal = (combined & mask) >>> 0
                if @opByMask[mask]?[maskedVal]?
                    desc = @opByMask[mask][maskedVal]
                    v = @decode(combined, desc)
                    if desc.e?
                        desc.e(iop, v)
                    return
        # Try 16-bit match (for short instructions)
        for mask in @orderedMasks
            if mask <= 0xffff
                maskedVal = (hw1 & mask) >>> 0
                if @opByMask[mask]?[maskedVal]?
                    desc = @opByMask[mask][maskedVal]
                    v = @decode(hw1, desc)
                    if desc.e?
                        desc.e(iop, v)
                    return
        iop.unknownProcOp(hw1, hw2)

    ops: {
#
#         3.1 BCE REGISTER INSTRUCTIONS
#
        # LOAD TIME OUT REGISTER
        #
        #   This instruction loads the Maximum Time Out Register (MTO)
        # with the Effective Count. This register is used by the
        # Receive Data instructions to determine how long a BCE will
        # wait for the first input word to arrive from a previsouly
        # commanded subsystem. The resolution of this timeout count
        # is 16.5 microseconds.
        #
        #   After loading the Maximum Time Out register, this BCE 
        # increments its program counter by 1 and begins execution
        # of the next sequential instruction
        #
        # PROGRAMMING NOTE
        #
        #   In direct mode, the computation of this effective address
        # includes the number of the BCE executing the instruction. 
        # This allows many BCE's to execute the same BCE program, but, 
        # each one uses a timeout parameter best suited for the sub-
        # system with which they are communicating. Note that two times 
        # the BCE number gives a fullword index.
        #
        # NOTES:
        #
        #       1.  Any value between 0 and 2047. This corresponds to
        #           time outs from 0 to 33.78 millisec.
        #
        #       2.  The lower 18-bits of the fullword addressed by
        #           PC(updated)+ displacement + 2 x BCE#. This allows
        #           any count between 0 and 262143, or 0 to 4.325 sec.
        #
        '#LTOI':    {
                        f:['#LTOI COUNT']
                        d:'10110ddddddddddd'
                        e:(t,v)->
                            t.ls.MTO().set32(v.d)
                            t.incrNIA(1)
                    }
        '#LTO':     {
                        f:['#LTO ADDR']
                        d:'10111ddddddddddd'
                        pr:true  # 'd' is a PC-relative displacement
                        e:(t,v)->
                            ea = t.bceEA(v.d, true) & ~1
                            t.ls.MTO().set32(t.g_EAF(ea) & 0x3ffff)
                            t.incrNIA(1)
                    }
        # RESET INDICATOR  BIT
        #
        #   The BCE to MSC indicator bit associated with the BCE that
        # is executing this instruction is reset to 0. This bit will
        # not change to 1 until oither a Set Indicator Bit (SIB)
        # instruction is executed or, the BCE error terminates some
        # instruction at a later time. After this bit is reset, the 
        # BCE's program counter is incremented by 1, and BCE program
        # execution continues.
        #
        '#RIB':     {
                        f:['#RIB']
                        d:'11100___________'
                        e:(t,v)->
                            t.procSet(t.regIndicator, t.curPE, 0)
                            t.incrNIA(1)
                    }
        # SET INDICATOR   BIT
        #
        #   The BCE to MSC indicator bit associated with the BCE that
        # is executing this instruction is set to 1. This bit will not
        # change to 0 until either the BCE executes a Reset Indicator
        # (#RIB) instruction or the MSC executes a Reset BCE Indicator 
        # (@RBI) instruction with this BCE's number. After this bit is
        # set, the BCE's program counter is incremented by 1, and BCE
        # program execution continues.
        #
        # PROGRAMMING NOTE
        #
        #   In indexing mode the computation of the effective address
        # includes the number of the BCE that is executing this 
        # instruction. This allows many BCE's to use the same BCE
        # program, and yet store the status from each BCE in a different
        # location. Note that the BCE number is multiplied by 2 to give
        # a fullword index.
        #
        '#SIB':     {
                        f:['#SIB']
                        d:'11101___________'
                        e:(t,v)->
                            t.procSet(t.regIndicator, t.curPE, 1)
                            t.incrNIA(1)
                    }
        # STORE STATUS AND  CLEAR
        #
        #   This instruction stores the BCE's status register in the 
        # fullword location addressed by the Effective Address. The
        # least significant bit of EA (the halfword address) is ignored.
        # After indicating the store operation the BCE will then clear
        # its status register and set its program execution bit (from
        # STAT1) to 1 (GO). It will then increment its program counter
        # by 1 and continue with execution of the next sequential 
        # instruction.
        #
        # PROGRAMMING NOTE
        #
        #   In indexing mode the computation of the effective address
        # includes the number of the BCE that is executing this 
        # instruction. This allows many BCE's to use the same BCE 
        # program and yet store the status for each BCE in a different
        # location. Note that the BCE number is multiplied by 2 to give
        # a fullword index.
        #
        '#SSC':     {
                        f:['#SSC ADDRESS']
                        d:'0100mddddddddddd'
                        pr:true
                        e:(t,v)->
                            # "The least significant bit of EA (the halfword
                            # address) is ignored" 
                            ea = t.bceEA(v.d, v.m) & ~1
                            t.s_EAF(ea, t.ls.getBST())
                            t.ls.setBST(0)
                            t.procSet(t.regProgExcept, t.curPE, 1)
                            t.incrNIA(1)
                    }
        # STORE STATUS
        #
        #   This instruction stores the BCE's status register in the
        # fullword location addressed by the Effective Address. The 
        # least significant bit of EA (the halfword address) is ignored.
        # After initiating the store operation, the program counter is
        # incremented by 1 and the next sequential instruction is begun.
        #
        # PROGRAMMING NOTE
        #
        #   In indexing mode the computation of the effective address
        # includes the number of the BCE that is executing this 
        # instruction. This allows many BCE's to use the same BCE
        # program, and yet store that status from each BCE in a 
        # different location. Note that the BCE number is multiplied by
        # 2 to give a fullword index.
        #
        '#SST':     {
                        f:['#SST ADDRESS']
                        d:'0101mddddddddddd'
                        pr:true
                        e:(t,v)->
                            ea = t.bceEA(v.d, v.m) & ~1
                            t.s_EAF(ea, t.ls.getBST())
                            t.incrNIA(1)
                    }
        # LOAD BASE REGISTER
        #
        #   The 18 bit effective address is loaded into the current
        # Bus Control Element (BCE) Base Register. The associated
        # program counter is incremented by two.
        #
        # PROGRAMMING NOTE
        #
        #   In direct mode the computation of the effective address
        # includes the number of the BCE executing the instruction.
        # This allows many BCE's to use the same program but, each BCE
        # will get a different Base register. Note that twice the BCE
        # number gives a fullword index.
        #
        '#LBR':     {
                        f:['#LBR ADDRESS']
                        d:'11110010000000aaaaaaaaaaaaaaaaaa'
                        e:(t,v)->
                            v1 = v.a
                            t.ls.BASE().set32(v1)
                            t.incrNIA(2)
                    }
        '#LBR@':    {
                        f:['#LBR@ ADDRESS']
                        d:'11111010000000aaaaaaaaaaaaaaaaaa'
                        e:(t,v)->
                            ea = v.a + 2*t.curPE
                            t.ls.BASE().set32(t.g_EAF(ea) & 0x3ffff)
                            t.incrNIA(2)
                    }
#
#         3.2 BCE BRANCHING
#
#   The BCE instruction set includes insturctions directing it to reset
# its own Program Counter and execute instructions at locations other
# than the next sequential one. As with the register class, these 
# instructions affect only the PC register belonging to the BCE 
# executing this instruction, and affects no other BCE.
#
#   This class of instruction includes an unconditional branch 
# instruction and an instruction that allows a Listen Mode BCE to 
# translate a Listen Command into a new Program Counter setting via a
# table lookup.
#
        # BRANCH UNCONDITIONAL
        #
        #   The 18 bit effective address is stored into the current Bus
        # Control Elements (BCE) Program Counter. The next instruction
        # is found at this degisnated location, which may be on either 
        # a full or halfword boundary.
        #
        # PROGRAMMING NOTE
        #
        #   In direct mode, the computation of the effective address
        # includes the number of BCE execution the instruction. This
        # allows many BCE's to use the same program and still retain
        # the capability to branch to different segments as required 
        # for each BCE's operation.
        #
        #   Note that twice the BCE number gives a fullword index.
        #
        '#BU':      {
                        f:['#BU ADDRESS']
                        d:'11110000000000aaaaaaaaaaaaaaaaaa'
                        e:(t,v)->
                            v1 = v.a
                            t.setNIA(v1)
                    }
        '#BU@':     {
                        f:['#BU@ ADDRESS']
                        d:'11111000000000aaaaaaaaaaaaaaaaaa'
                        e:(t,v)->
                            ea = v.a + 2*t.curPE
                            t.setNIA(t.g_EAF(ea) & 0x3ffff)
                    }
        # WAIT FOR INDEX
        #
        #   This instruction places the BCE in a state where it will
        # monitor, through its MIA, the system bus to which it is
        # attached for commands from other IOPs. When it receives such
        # a command, it uses part of the command as an index into a
        # table of branch addresses, and branches to the indicated
        # location. This procedure allows one BCE in one IOP to signal
        # to another BCE in a different IOP that it is time to perform
        # some BCE program.
        #
        #   Figure 3.2 diagrams operation of this instruction. The 
        # starting address of the table of branch addresses (one
        # address/fullword) is the sum of the updated PC (1 + address of
        # preset #WIX) and the 11 bit Displacement field. This address 
        # is rounded up by 1 if necessary to make it a fullword address
        # (least significant bit = 0). After computing this address the
        # BCE sets itself up to accept from its MIA a bus word termed a
        # "Listen Command" that has command sync and an Interface Unit
        # Address of 0 1 0 0 0 (in binary).
        #
        #   The BCE then goes into a tight loop of monitoring the MIA
        # Buffer for a valid Listen Command. If at the entry to this
        # loop, or at any time during this loop, the BCE finds that it
        # is not in Listen Mode (i.e. its transmitter is enabled -- see
        # Paragraph 4.1) then it will exit the loop and enter the Wait
        # State. If it stays in Listen Mode, and finds a valid Listen
        # Command, it exits the loop. The BCE then places bits 14 to 18
        # of the command in its Interface Unit Address Register (IUAR).
        # It also adds the Index bits 19 to 26 to the Table address 
        # computed earlier. This 8 bit Index is right justified and 
        # padded on the left by ten zero's when it is added to the 18
        # bit Table address. Figure 3.1 diagrams the makeup of a Listen 
        # command.
        #
        # This computed address is used to reference a fullword in memory
        # which contains in bits 14 through 31 a branch address. These 18
        # bits are then loaded into the BCE's PC, and execution of the 
        # indicated instruction begun.
        #
        # PROGRAMMING NOTE
        #
        #   If a #WIX is executed with the MIA's transmitter enabled,
        # execution of the #WIX is equivalent to that for a #WAT, i.e.
        # it resets its Busy/Wait bit, updates its PC by 1, and goes into 
        # a loop until the MSC sets the bit back to 1.
        #
        #   If the BCE is in Listen Mode, then during the entire time 
        # that the BCE is waiting for a Listen Command the BCE's Busy/
        # Wait bit stays set to Busy. Thus any attempt by the MSC to 
        # execute a @LBB, @LBP, or @SIO involving this BCE will not go
        # through, and will result in an MSC error and the setting of
        # appropriate bits in the MSC Status Register.
        #
        #   After execution of a #WIX, the BCE's IUAR has been set to
        # bits 14 to 18 of the received Listen Command. This permits the
        # BCE/IOP that placed the Listen Command on the bus to condition 
        # the listening BCE(s) to accept data only from a certain
        # subsystem. Typically the commanding BCE sends this subsystem
        # a command to return a stream of data, which will then be picked
        # up properly by not only the commanding BCE but also those on
        # the same bus that were "listening" to the command BCE. Paragraph
        # 4.1 should be referenced for more complete detail.
        #
        '#WIX':     {
                        f:['#WIX DISP']
                        d:'00100ddddddddddd'
                        pr:true
                        e:(t,v)->
                            if t.ls.ls(0,0).get32() == 0
                                table = t.ls.PC().get32() + 1 + v.d
                                if table & 1
                                    table += 1
                                # Store table in local store A:0
                                t.ls.ls(0,0).set32(table)
                            # PC not updated, subsequent execs
                            # enter WIX loop here:
                            if t.procGet(t.regXmitEna, t.curPE)
                                # Exit loop and wait
                                t.ls.ls(0,0).set32(0)
                                t.incrNIA(1)
                                t.procSet(t.regBusyWait, t.curPE, 0)
                            else if t.curBCE()?.mia.dataAvailable()
                                data = t.curBCE().mia.getData()
                                listenCmd = (data & 0x01f00000) >>> 20
                                if listenCmd == 0x8
                                    iua   = (data & 0x00003e00) >>> 9
                                    t.ls.IUAR().set32(iua)

                                    index = (data & 0x000001fe) >>> 1
                                    table = t.ls.ls(0,0).get32()
                                    table += index
                                    v1 = t.g_EAF(table)
                                    t.setNIA(v1)
                    }
#
#         3.3 BCE TRANSMISSION INSTRUCTIONS
#
#   Each BCE in an IOP has the capability of directing its MIA to
# initiate the transmission of a word over the associatd bus. These
# words may be either command or data words and when they are transmitted
# over the bus they have the formats shown in Figure 1.1(a) or (c). Out
# of these bits the bits the BCE provides only the 24 information bits
# 3 through 26 and an indication of whether the word is a command or data
# word.
#
#   Command words are used to tell a subsystem to perform some action 
# such as, set setup to accept N words of data that will be transmitted
# later. Since there can be many subsystems on a bus, each command 
# contains a 5-bit Interface Unit Address (IUA), bits 3-7 of a bus
# command word, that specifies which subsystem should obay the command.
#
#   Data words are typically sent after a command, and contain the
# actual information that the BCE wants transferred to the subsystem.
# For each bus word this information consists of a 16-bit halfword from
# GPC memory. Surrounding this word are sync bits, a 5-bit IUA, the 
# pattern 101, and parity. The BCE provides the MIA with just the IUA,
# the 16-bit data, and 101. The MIA adds the rest.
#
#
#
        # TRANSMIT COMMAND
        #
        #   This instruction is used to send 24 bit commands to a
        # subsystem on the serial bus connected to the current BCE's
        # MIA. In immediate mode (#CMDI) the command is found immediately
        # in bits 8 thru 31 of the instruction. In direct mode (#CMD) the
        # command is the lower 24 bits of the main store fullword 
        # computed from the address field (Bits 14 thru 31) of the
        # instruction. (The halfword addressing bit, bit 31, is ignored).
        # The format of the commands sent out by the MIA is:
        #
        #   The actual transmission of the command is conditional on the
        # BCE's associated MIA's Transmitter being enabled and the MIA 
        # not being busy. If either condition is false the command is 
        # not sent, but no error condition is set.
        #
        #   After execution of this instruction the BCE's program counter
        # is incremented by 2, and the next sequential instruction is
        # executed.
        #
        # PROGRAMMING NOTES:
        #
        #   The start of the actual transmission of the command by the
        # MIA begins about 16 usec before the end of the instruction.
        # Thus execution of the next instruction following a #CMDI or
        # #CMD (Transmit Command) beings before the MIA has completed
        # transmission of the command. If this next instruction is also
        # a #CMDI, the MIA will still be busy when the #CMDI wishes to
        # transmit its command, and transmission of the command will be
        # supressed. The #CMDI will then wait 16.5 microseconds and try
        # again. If the MIA is no longer busy and the transmitter is 
        # enabled, the command is sent and the next instruction is
        # processed. If either condition is false, the command is 
        # aborted, but no error condition is set, and the next instruction
        # will be executed.
        #
        #   MIA page hardware does not allow for TRANSMIT ENABLE going
        # active less than or equal to one microsecond before the #CMDI
        # or $CMD. If this one microsecond limitation is violated, proper
        # transmission of the ocmmand word cannot be ensured.
        #
        #   Either instruction can be used to send a "Listen Command" to
        # a BCE on the same bus but in another IOP. In either case the
        # 24 bits of command information consists of 01000 (the common
        # IOP address), a don't care bit, and an 18-bit absolute address.
        # 
        #   For the #CMD instruction, the address of the command word 
        # includes the number of the BCE executing the instruction. This
        # allows many BCE's to execute the same BCE program, but at the
        # same time it allows each BCE to transmit a different command.
        # Note that twice the BCE number gices a fullword index.
        # 
        '#CMDI':    {
                        f:['#CMDI IUA,IMMED']
                        d:'11110110uuuuuiiiiiiiiiiiiiiiiiii'
                        e:(t,v)->
                            # Transmit command immediate: IUA + 19 bits immediate
                            if t.xmitEnabled(t.curPE)
                                cmd = (v.u << 19) | v.i
                                t.ls.IUAR().set32(v.u)
                                t.curBCE()?.mia.xmitCmd(cmd)
                            t.incrNIA(2)
                    }
        '#CMD':     {
                        f:['#CMD ADDRESS']
                        d:'11111110000000aaaaaaaaaaaaaaaaaa'
                        e:(t,v)->
                            # Transmit command from memory at addr + 2*BCE#
                            addr = v.a + 2 * t.curPE
                            cmd = t.g_EAF(addr) & 0x00ffffff
                            if t.xmitEnabled(t.curPE)
                                t.ls.IUAR().set32((cmd >>> 19) & 0x1f)
                                t.curBCE()?.mia.xmitCmd(cmd)
                            t.incrNIA(2)
                    }
        # TRANSMIT DATA SHORT
        #
        '#TDS':     {
                        f:['#TDS COUNT,DISPLACEMENT']
                        d:'100cccccdddddddd'
                        e:(t,v)->
                            # Transmit 1-32 halfwords from base-relative buffer
                            count = v.c + 1
                            base = t.ls.BASE().get32()
                            bce = t.curBCE()
                            for i in [0...count]
                                addr = base + v.d + i
                                t.queueDMA(addr, 'read', bce)
                            t.incrNIA(1)
                    }
        # TRANSMIT DATA LONG
        #
        '#TDLI':    {
                        f:['#TDLI Count']
                        d:'11110100000000cccccccccccccccccc'
                        e:(t,v)->
                            # Transmit data long: count from immediate field
                            count = v.c + 1
                            base = t.ls.BASE().get32()
                            bce = t.curBCE()
                            for i in [0...count]
                                t.queueDMA(base + i, 'read', bce)
                            t.incrNIA(2)
                    }
        '#TDL':     {
                        f:['#TDL Address']
                        d:'11111100000000aaaaaaaaaaaaaaaaaa'
                        e:(t,v)->
                            # Transmit data long: count from memory at addr + 2*BCE#
                            #
                            # The table entry is a fullword, laid out as
                            # MESSAGE OUT documents it below: displacement in
                            # bits 5-15, transfer count in bits 16-31, so the
                            # count is the low halfword.
                            #
                            # The displacement half is not applied here: the
                            # data goes from the base register the program has
                            # just loaded.  Every bus program seen carries
                            # displacement zero in these entries, so nothing
                            # observed distinguishes the two.
                            addr = v.a + 2 * t.curPE
                            count = (t.g_EAF(addr) & 0xffff) + 1
                            base = t.ls.BASE().get32()
                            bce = t.curBCE()
                            for i in [0...count]
                                t.queueDMA(base + i, 'read', bce)
                            t.incrNIA(2)
                    }
        # MESSAGE OUT
        #
        #   Two formats. Bit 4 = 0 is a two-fullword instruction: an 8-bit
        # base-relative displacement and a 16-bit transfer count in the first
        # word, the 24-bit command in the second. Bit 4 = 1 is one fullword
        # carrying an address, and indexes two 24-entry fullword tables by
        # BCE number: the displacement and transfer count at ADDRESS +
        # 2 x BCE#, the command at ADDRESS + 48 + 2 x BCE#.
        #
        #   Table entry, displacement and transfer count:
        #
        #     ------------------------------------------------------
        #     |         |     DISPLACEMENT    |   TRANSFER COUNT   |
        #     ------------------------------------------------------
        #      0       4 5                 15 16                 31
        #
        #   Table entry, command:
        #
        #     ------------------------------------------------------
        #     |               |   IUA   |        COMMAND           |
        #     ------------------------------------------------------
        #      0             7 8      12 13                      31
        #
        '#MOUT':    {
                        f:['#MOUT Displacement,Transfer Count']
                        d:'11110101ddddddddcccccccccccccccc'
                        e:(t,v)->
                            count = v.c + 1
                            base = t.ls.BASE().get32()
                            bce = t.curBCE()
                            t.bceCommand()
                            for i in [0...count]
                                addr = base + v.d + i
                                t.queueDMA(addr, 'read', bce)
                            t.incrNIA(4)
                    }
        '#MOUT@':   {
                        f:['#MOUT@ Address']
                        d:'11111101000000aaaaaaaaaaaaaaaaaa'
                        e:(t,v)->
                            entry = t.g_EAF(v.a + 2 * t.curPE)
                            disp = (entry >>> 16) & 0x7ff
                            count = (entry & 0xffff) + 1
                            base = t.ls.BASE().get32()
                            bce = t.curBCE()
                            t.bceCommand(v.a + 48 + 2 * t.curPE)
                            for i in [0...count]
                                t.queueDMA(base + disp + i, 'read', bce)
                            t.incrNIA(2)
                    }
#
#         3.4 BCE RECEIVE DATA INSTRUCTIONS
#
        # RECEIVE DATA SHORT
        #
        '#RDS':     {
                        f:['#RDS COUNT,DISP']
                        d:'011cccccdddddddd'
                        e:(t,v)->
                            # Receive 1-32 halfwords into base-relative buffer
                            base = t.ls.BASE().get32()
                            if t.bceReceive(base + v.d, v.c + 1)
                                t.incrNIA(1)
                    }
        # RECEIVE DATA LONG
        #
        '#RDLI':    {
                        f:['#RDLI COUNT']
                        d:'11110011000000cccccccccccccccccc'
                        e:(t,v)->
                            # Receive data long: count from immediate field
                            base = t.ls.BASE().get32()
                            if t.bceReceive(base, v.c + 1)
                                t.incrNIA(2)
                    }
        '#RDL':     {
                        f:['#RDL ADDRESS']
                        d:'11111011000000aaaaaaaaaaaaaaaaaa'
                        e:(t,v)->
                            # Receive data long: count from memory at addr + 2*BCE#
                            # The same fullword table #TDL reads: the count is
                            # the low halfword, the high one the displacement.
                            addr = v.a + 2 * t.curPE
                            count = (t.g_EAF(addr) & 0xffff) + 1
                            base = t.ls.BASE().get32()
                            if t.bceReceive(base, count)
                                t.incrNIA(2)
                    }
        # MESSAGE IN
        #
        #   Two formats, laid out as for MESSAGE OUT. Bit 4 = 0 is two
        # fullwords, bit 4 = 1 is one fullword carrying an address and
        # indexing the same pair of tables.
        #
        '#MIN':     {
                        f:['#MIN DISPLACEMENT,Transfer Count']
                        d:'11110001ddddddddcccccccccccccccc'
                        e:(t,v)->
                            if t.bceReceiveStarting()
                                t.bceCommand()
                            base = t.ls.BASE().get32()
                            if t.bceReceive(base + v.d, v.c + 1)
                                t.incrNIA(4)
                    }
        '#MIN@':    {
                        f:['#MIN@ ADDRESS']
                        d:'11111001000000aaaaaaaaaaaaaaaaaa'
                        e:(t,v)->
                            entry = t.g_EAF(v.a + 2 * t.curPE)
                            disp = (entry >>> 16) & 0x7ff
                            count = (entry & 0xffff) + 1
                            if t.bceReceiveStarting()
                                t.bceCommand(v.a + 48 + 2 * t.curPE)
                            base = t.ls.BASE().get32()
                            if t.bceReceive(base + disp, count)
                                t.incrNIA(2)
                    }
#
#         3.5 SPECIAL INSTRUCTIONS
#
        # DELAY
        #
        #   This instruction simply delays the execution of the next
        # instruction. The time period delayed is a function of the 
        # Effective Count, with a resolution of 16.5 microseconds per
        # count.
        #
        #   At the end of this delay the program counter is incremented
        # by one, and the next instruction is executed.
        #
        # PROGRAMMING NOTE
        #
        #   Each count of 1 represents a delay of 16.5 microseconds, the
        # execution time of a BCE micro instruction. Each count of 2
        # represents a delay of 33 microseconds, the minimum time for a
        # word transmission over a serial bus.
        #
        #   For the #DLY instruction, the address of the word containing
        # the delay includes the number of the BCE executing the 
        # instruction. This allows many BCE's to execute the same program
        # while still retaining the capability to delay for different
        # periods. Note that twice the BCE number is a fullword index.
        #
        # 11000ccccccccccc #DLYI Timeout
        # 11001aaaaaaaaaaa #DLY# Address
        #
        '#DLYI':    {
                        f:['#DLYI TIMEOUT']
                        d:'11000iiiiiiiiiii'
                        e:(t,v)->
                            t.incrNIA(1) if t.bceDelay(v.i)
                    }
        '#DLY':     {
                        f:['#DLY ADDRESS']
                        d:'11001ddddddddddd'
                        pr:true
                        e:(t,v)->
                            # Count from the fullword at PC(updated) +
                            # displacement + 2 x BCE#, as #LTO reads its own.
                            count = t.g_EAF(t.bceEA(v.d, true) & ~1) & 0x3ffff
                            t.incrNIA(1) if t.bceDelay(count)
                    }
        # WAIT
        #
        #   This instruction causes the Bus Control Element (BCE) that
        # is executing it to leave the busy state and enter the wait
        # state. The BCE's Busy/Wait bit (in STAT4) is set to 0 (WAIT).
        # The BCE's Program Counter is incremented by 1, but no further
        # instructions are executed. The BCE is reset to the busy state
        # by the Master Sequence Controller (MSC) only. Once in the
        # Wait State, a BCE performs no actions other than the 
        # monitoring of its Busy/Wait bit for a command to re-enter the
        # Busy State.
        #
        #   Paragraph 2.2 describes transitions to and from the Wait 
        # State in detail.
        #
        # PROGRAMMING NOTE
        #
        #   While in the Wait State the BCE alters none of its programmer-
        # visible registers. Thus the CPU is free to change, via PCI/O,
        # any BCE register.
        #
        '#WAT':     {
                        f:['#WAT']
                        d:'00001___________'
                        e:(t,v)->
                            # Enter wait state: clear Busy/Wait bit
                            t.procSet(t.regBusyWait, t.curPE, 0)
                            t.incrNIA(1)
                            b = t.bce[t.curPE - 1]
                            t.bceEvent(t.curPE, "#WAT  starved=#{b?.starveTurns ? 0} " +
                                                "paced=#{b?.pacedTurns ? 0}")
                            if b? then b.starveTurns = b.pacedTurns = 0
                    }
        # INSTRUCTION - SELF TEST
        #
        #   This instruction initiates execution of a special micro
        # program to perform self tests on the hardware supporting
        # the Bus Control Element that is executing this instruction.
        # These tests include checks of:
        #
        #   o   BCE Local Store
        #   o   BCE Data Flow Operations
        #   o   Ability of BCE to read and write from memory
        #   o   MIA wrap capability
        #   o   MIA Buffer
        #
        #       A flag of 0 causes all but the last two tests to be
        # performed. A flag of 1 causes all test to be run.
        #
        #       If an error is detected, the BCE's Program Exception
        # bit is set to 0, bit 22 of the BCE Status Register is set to
        # 1 (Self Test failure). The PC is incremented by 1, and the 
        # next instruction is executed.
        #
        #   Successful completion of this instruction causes the BCE to
        # increment its PC by 1 and continue with the next instruction.
        #
        # DESCRIPTION M=1:
        #
        #   "This instruction initiates execution of a special micro
        # program to perform self test on the associated MIA Parity
        # Checker.  Before execution of this instruction parity must be
        # enabled and the BCE executing this instruction must have its
        # transmitter disabled.  If the transmitter is enabled the BCE
        # will set no-go, go to wait and set the BCE Status Register Bit
        # 22 to 1.  If the transmitter is disabled the micro program will
        # do a transmit.  This will allow data to be sent through the
        # Parity Checking Circuitry, but will not be transmitted on the
        # Bus.  If bad parity is detected an External 1 interrupt is
        # generated and the External 1 Status Register will indicate a MIA
        # Parity Error."
        #
        '#STP':     {
                        f:['#STP FLAG']
                        d:'0001I__________f'
                        e:(t,v)->
                            if v.I
                                if t.procGet(t.regXmitEna, t.curPE)
                                    # Transmitter enabled: refuse.
                                    t.procSet(t.regProgExcept, t.curPE, 0)
                                    t.procSet(t.regBusyWait, t.curPE, 0)
                                    st = t.ls.getBST()
                                    t.ls.setBST((st | (1 << (31 - 22))) >>> 0)
                                    t.incrNIA(1)
                                    return
                                # The transmit that never reaches the bus.
                                t.checkMIAParity()
                                t.incrNIA(1)
                                return
                            # "If an error is detected, the BCE's Program
                            # Exception bit is set to 0, bit 22 of the BCE
                            # Status Register is set to 1 (Self Test
                            # failure)."  The modelled hardware has no faults,
                            # so neither happens.
                            #
                            # "Ability of BCE to read and write from memory"
                            # is one of the tests, and like the MSC's it runs
                            # against a fixed PSA fullword -- this BCE's, at
                            # STP_BCE_BASE + 2*(n-1).  The high halfword is
                            # the pattern to read, the low halfword where it
                            # must land. 
                            fw = STP_BCE_BASE + 2 * (t.curPE - 1)
                            t.s_EAH(fw + 1, t.g_EAH(fw))
                            t.incrNIA(1)
                    }

    }

