import {PackedBits} from 'gpc/util'
import {FloatIBM,addE,subE,mulE,divE} from 'gpc/floatIBM'
import {q31_mul32, q15_mul, q31_div} from 'gpc/q31'

ADDR_HALFWORD = 1
ADDR_FULLWORD = 2
ADDR_DBLEWORD = 3

OPTYPE_DATA = 1
OPTYPE_BRCH = 2
OPTYPE_SHFT = 4


class Instruction extends PackedBits
    argTypes = {
        R1:{}
        R2:{}
        D2:{}
        B2:{}
        X2:{}
        Data:{}
        Value:{}
        M1:{}
        Count:{}
    }


    constructor: () ->
        super()
        @r = Array
        @makeOpTbl()

        @rs_d  = '________1111oabb'
        @rs_ae = 'dddddddddddddddd'
        @rs_ai = 'xxxaiddddddddddd'

        @d_rs_ae = @makeDesc(@rs_ae)
        @d_rs_ai = @makeDesc(@rs_ai)

    decodef: (desc, hw1, hw2) ->
        d = {nm:desc.nm}
        for k,f of desc.f
            d[k] = @getField(hw1, f)
        d.desc = desc
        if desc.type == 'RI' or desc.type == 'SI'
            d.I = hw2
        if desc.longdisp?
            if d.a
                d.d = hw2 & 0x07ff
                d.i = hw2 >> 13
            else
                d.d = hw2
        if desc.nm == 'LFXI'
            d.y = d.y - 2

        if desc.type == 'RS'
            if desc.f.d?
                d.d = ((hw1 >>> 2) & 0x3f) - 2
            else
                desc.len = 2
                d.extended = true
                if d.a == 0
                    d.d = hw2
                else
                    d.i = hw2 >>> 13
                    d.ia = (hw2 >>> 12) & 1
                    d.ii = (hw2 >>> 11) & 1
                    d.d = hw2 & 0x7ff

        if desc.type == 'SRS' and desc.opType != OPTYPE_SHFT
            if d.d == 0x3c || (desc.nm == 'IAL' and d.d == 0x3e)
                d.extended = true
                d.d = hw2
                desc.len = 2
            else if d.d == 0x3d || (desc.nm == 'IAL' and d.d == 0x3f)
                d.extended = true
                d.i = hw2 >>> 13
                d.ia = (hw2 >>> 12) & 1
                d.ii = (hw2 >>> 11) & 1
                d.d = hw2 & 0x7ff
                desc.len = 2

        d.addrWidth = desc.addrWidth
        d.opType = desc.opType

        return [desc,d]

    decode: (hw1, hw2) ->
        desc = undefined
        for msk in @orderedMasks
            mTbl = @opByMask[msk]
            hw1msk = hw1 & msk
            if hw1msk of mTbl
                desc = mTbl[hw1msk]
                desc.len = desc.origLen
                break
        if not desc
            return [undefined,undefined]

        d = desc
        res = @decodef(d,hw1,hw2)
        desc = res[0]
        v = res[1]

        return [desc,v]


    encode: (v) ->
        desc = @descByOp[v.nm]

        if v.d?
            disp = v.d.v
        else
            disp = 0
        instrType = desc.type

        switch instrType
            when 'RR'
                if not v.y? and v.d?
                    v.y = v.d
                    delete v.d
                if v.nm == 'LFXI'
                    v.y.v = v.y.v + 2

                hw1 = desc.maskedVal
                if desc.f.x?
                    hw1 = hw1 | @fld(desc.f.x, v.x.v)
                if desc.f.y?
                    hw1 = hw1 | @fld(desc.f.y, v.y.v)
                return [hw1]
            when 'SRS'
                if not v.b?
                    # shift instruction
                    hw1 = desc.maskedVal \
                        | @fld(desc.f.x,v.x.v) \
                        | @fld(desc.f.d,v.d.v)
                    return [hw1]

                if v.i?
                    if disp > 0x7ff
                        error("ERROR: disp too big")
                        return [0,0]
                    if not desc.eaFlg
                        if desc.opType != OPTYPE_BRCH and v.i.v == 0
                            hw1 = desc.maskedVal \
                                | @fld(desc.f.d,0x3c) \
                                | @fld(desc.f.b,v.b.v)
                            if desc.f.x?
                                hw1 = hw1 | @fld(desc.f.x,v.x.v)
                        else
                            hw1 = desc.maskedVal \
                                | @fld(desc.f.d,0x3d) \
                                | @fld(desc.f.b,v.b.v)
                            if desc.f.x?
                                hw1 = hw1 | @fld(desc.f.x,v.x.v)
                    else
                        hw1 = desc.maskedVal \
                            | @fld(desc.f.d,0x3e) \
                            | @fld(desc.f.b,v.b.v)

                    hw2 = disp | (v.i.v << 13)
                    return [hw1,hw2]

                # For short SRS format, convert halfword displacement to
                # fullword units for the 6-bit field
                shortDisp = if desc.addrWidth == 2 then disp >>> 1 else disp
                if shortDisp > 0x37 or v.b.v == 99
                    if v.b.v == 99
                      v.b.v = 3
                    hw1 = desc.maskedVal
                    if desc.f.x?
                        hw1 = hw1 | @fld(desc.f.x,v.x.v)
                    if desc.f.d?
                        hw1 = hw1 | @fld(desc.f.d,0x3c)
                    if desc.f.b?
                        hw1 = hw1 | @fld(desc.f.b,v.b.v)
                    hw2 = disp
                    return [hw1,hw2]
                else
                    hw1 = desc.maskedVal
                    if desc.f.x?
                        hw1 = hw1 | @fld(desc.f.x,v.x.v)
                    if desc.f.d?
                        hw1 = hw1 | @fld(desc.f.d,shortDisp)
                    if desc.f.b?
                        hw1 = hw1 | @fld(desc.f.b,v.b.v)
                    return [hw1]
            when 'SI'
                # SI is on halfwords:
                #disp = v.d.v
                hw1 = desc.maskedVal \
                    | @fld(desc.f.d,disp) \
                    | @fld(desc.f.b,v.b.v)
                if v.I.v?
                    hw2 = v.I.v & 0xffff
                else
                    hw2 = v.I & 0xffff
                return [hw1, hw2]
            when 'RI'
                if not desc.f.x? and v.x?
                    v.y = v.x
                    delete v.c
                if not desc.f.d? and v.d?
                    v.I = v.d
                    delete v.d

                REGfld = if desc.f.y? then desc.f.y else desc.f.x
                REG = if v.y? then v.y.v else v.x.v

                hw1 = desc.maskedVal | @fld(REGfld, REG)
                hw2 = v.I.v & 0xffff
                return [hw1, hw2]
            when 'RS'
                if not v.x?
                    v.x = 0 # no-op

                if v.i?     # indexed mode
                    v.a = 1
                    hw1 = desc.maskedVal \
                        | @fld(desc.f.x, v.x.v) \
                        | @fld(desc.f.a, v.a) \
                        | @fld(desc.f.b, v.b.v)
                    hw2 = @fld(@d_rs_ai.f.x, v.i.v) \
                        | @fld(@d_rs_ai.f.a, 0) \
                        | @fld(@d_rs_ai.f.i, 0) \
                        | @fld(@d_rs_ai.f.d, disp)
                    return [hw1, hw2]
                else        # extended mode
                    v.a = 0
                    hw1 = desc.maskedVal
                    if v.x?
                        hw1 = hw1 | @fld(desc.f.x, v.x.v)
                    if v.a?
                        hw1 = hw1 | @fld(desc.f.a, v.a)
                    if v.b?
                        hw1 = hw1 | @fld(desc.f.b, v.b.v)
                    hw2 = disp & 0xffff
                    return [hw1, hw2]

        return null

    toStr: (hw1, hw2) ->
        [d,v] = @decode(hw1,hw2)
        if not d
            return "UNDEFINED"
        s = "#{v.nm}".rpad(" ",5)
        if v.x?
            s += "#{v.x},"
        if v.y?
            s += "#{v.y}"
            if v.I?
                s += ","
        if v.I? and d.type =='RI'
            s += "X'"+v.I.asHex()+"'"
        if v.d?
            # s += "#{v.d}"
            s += "X'"+v.d.asHex()+"'"
        if v.b?
            if v.i? and v.i != 0
                s +="(#{v.i},"
                if v.b? and not (v.extended and v.b == 3)
                  s += "#{v.b}"
                s += ")"
            #else if not v.a? or v.a != 0
            else if v.b? and not (v.extended and v.b == 3)
              s +="(#{v.b})"
        if v.I? and d.type == 'SI'
            s += ",X'"+v.I.asHex()+"'"
        return s 

    execInstr: (hw1, hw2) ->
        [d,v] = @decode(hw1,hw2)

    makeOpTbl: () ->
        @opByMask = {}
        @descByOp = {}
        @orderedMasks = []

        @formats = []

        for k,v of @ops
            #console.log "!!!", k,v
            desc = @makeDesc v.d
            desc.nm = k
            desc.d = v.d
            desc.e = v.e
            desc.eaFlg = v.eaFlg
            if v.a?
                desc.addrWidth = v.a
            else
                desc.addrWidth = ADDR_FULLWORD
            if v.t?
                desc.opType = v.t
            else
                desc.opType = OPTYPE_DATA

            desc.s = v.f
            desc.fullName = v.n ? ''
            desc.dx = v.dx if v.dx?
            desc.dy = v.dy if v.dy?

            for f in v.f
                foperands = f.split(' ')[1]
                foperands = foperands.replace /D2\(X2,B2\)/, "BDI"
                foperands = foperands.replace /D2\(B2\)/, "BD"
                fopl = foperands.split(',')
                if not desc.operands? or (desc.operands? and 'BDI' in foperands)
                    desc.operands = fopl

                @formats.push f

            @descByOp[desc.nm] = desc
            #console.log "MOT", desc
            if desc.mask not of @opByMask
                @orderedMasks.push desc.mask
                @opByMask[desc.mask] = {}
            @opByMask[desc.mask][desc.maskedVal] = desc
        # when matching a hw to an instruction, we
        # search from more to less specific, so order
        # masks from largest to smallest:
        @orderedMasks = @orderedMasks.sort().reverse()

        @fmtTable = {}
        for format in @formats
            args = format.split(' ')[1]
            @fmtTable[args] = {}


    #   x register_1
    #   y register_2 or special value (4 bits)
    #   d 6-bit displacement
    #       - includes logic for selecting extended/indexed mode
    #       - Displacements of the form 111XXX are not valid
    #       - d =  111100 => Extended
    #       - d =  111101 => Indexed
    #   b 2-bit base register
    #   / required second halfword
    #   I 16-bit immediate value
    #   X Extended/indexed halfword
    #       - if d = 111100 => Extended => 16 bit displacement
    #       - if d = 111101 => Indexed => /xxxaidddddddddddd
    #                   IBM-6246156B/p.2-12
    #               x = 3-bit index register
    #               a =  i_a
    #               i =  i
    #               d =  10-bit displacement
    #   
    ops: {
        # PROGRAM-CONTROLLED I/O INSTRUCTION
        #
        #   The Input/Output instruction transfers a fullword to or from the
        # general register specified by R1.  Direct I/O operations are defined
        # by a control word (CW) contained in the general register specified by
        # R2. The CW format is shown below:
        #
        #  ----------------------------------------------------------------
        # |I|                      Command (M)                            |
        # |D| | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | |
        # ----------------------------------------------------------------
        #  0 1                                                          31  
        #
        #   The fields of the CW are defined as follows:
        #
        #   ID:               For an input operation, bit 0 must be coded as 0.
        #                     For an output operation, this bit must be coded
        #                     as 1.
        #
        #   Command (M):      Bits 1-31 specify the particular operation to be
        #                     performed, and can be used to expand the basic
        #                     input and output operations. For example, they
        #                     can be coded to specify sense and control 
        #                     operations.  Additionally, DMA I/O operations can
        #                     be initialized by a Direct I/O. In executing an
        #                     input operation, the channel (1) transmits the
        #                     32-bit CW to the external device; and (2) 
        #                     subsequently loads 32 bits of information, trans-
        #                     mitted from the addressed device, into general
        #                     register R1. In executing an output operation,
        #                     the channel (1) transmits the CW to the external
        #                     device, and (2) subsequently transmits bits 0-31
        #                     of general register R1 to the addressed device.
        #                     The specific definition of the command bits is
        #                     described in the Priciples of operation for 
        #                     PCI/PCO, MSC & BCE. The only restriction placed
        #                     on the system design is the definition of bit 0.
        #
        #   Each control unit connected to the channel is required to accept the
        # CW, decode the control unit and device addres, and perform the input
        # or output defined by the command field. The device address field
        # identifies, for example, the flight control subsystem, the radar
        # altimeter, the navigation sensors, the displays, or the mass storage
        # unit. The number and types of devices connected to the channel and
        # their address assignments depend on the system configuration.
        #
        #   If the IO handshaking operaion does not complete within 9 micro-
        # seconds for CW & DATA OUT transfers or 6 microseconds for data in
        # transfers, the Program Controlled instruction will terminate and the
        # condition code will be set to reflect the timeout.
        #
        # RESULTING CONDITION CODE
        #
        #   00  Operation successful
        #   01  Interface time-out error: operation not successful.
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this 
        #   instruction.
        #
        #   Program Interrupt -- Privileged instruction.
        #
        # PROGRAMMING NOTE
        #
        #   This is a privileged instruction and can only be executed when the
        # CPU is in the supervisor state.
        #
        PC:     {
                    n:'Program Controlled I/O'
                    f:['PC R1,R2'],
                    d:'11011xxx11101yyy',
                    e:(t,v) ->
                        if not t.i_SUPER() then return
                        cmd = t.r(v.x).get32()
                        data = t.r(v.y).get32()
                        t.sendToIOP(cmd, data)
                        isOutput = cmd >>> 31
                        if not isOutput
                            t.r(v.y).set32(t.recvFromIOP())
                        t.psw.setCC(0)
                }

        # ADD
        #
        #   The fullword second operand is added to the contents
        #   of general register R1. The result replaces the
        #   contents of general register R1. The second operand
        #   is not changed.
        #   
        #   RESULTING CONDITION CODE
        #   
        #     00  The result is zero
        #     11  The result is negative
        #     01  The result is positive (>0).
        #   INDICATORS
        #     The overflow indicator is set to one if the magnitude of the
        #     sum is too large to be represented in the general register;
        #     that is, greater than 1-2^-31 or less than -1. If the 
        #     overflow indicator already contains a one, it is not altered
        #     by this instruction. (Overflow can be reset by testing or by
        #     loading the PSW.) The carry indicator is set to indicate
        #     whether or not there is a carry out of the high-order bit
        #     position of the general register
        #
        #     Program Interrupt -- Fixed point overflow
        #
        AR:     {
                    n:'Add'
                    f:['AR R1,R2'],
                    d:'00000xxx11100yyy',  # AR R1,R2
                    a:ADDR_FULLWORD
                    e:(t,v) ->
                        v1 = t.r(v.x).get32()
                        v2 = t.r(v.y).get32()
                        result = v1 + v2
                        t.r(v.x).set32(result)
                        t.computeCCarith(result,0)
                }
        A:      {
                    n:'Add'
                    f:['A R1,D2(B2)','A R1,D2(X2,B2)']
                    d:'00000xxxddddddbb',  # A R1,D2(B2)
                                            # A [@] [#] R1,D2(X2,B2)
                    a:ADDR_FULLWORD
                    e:(t,v) ->
                        v1 = t.r(v.x).get32()
                        v2 = t.g_EAF(v)
                        result = v1 + v2
                        t.r(v.x).set32(result)
                        t.computeCCarith(result,0)
                }

        # ADD HALFWORD
        #
        #   The halfword second operand is first developed into a fullword
        #   operand by appending 16 low-order zeroes. This fullword operand
        #   operand is then added to the contents of general register R1.
        #   The result replaces the contents of general register R1. The
        #   second operand is not changed.
        #
        #   RESULTING CONDITION CODE
        #
        #   
        #     00  The result is zero
        #     11  The result is negative
        #     01  The result is positive (>0).
        #
        #   INDICATORS
        #
        #       The overflow indicator is set to one, if the magnitude
        #       of the sum is too large to be represented in the general
        #       register; that is, greater than 1-2**-31 or less than -1.
        #       If the overflow indicator already contains a one, it is not
        #       altered bu this instruction. (Overflow can be reset by testing 
        #       or by loading the PSW.) The carry indicator is set to indicate
        #       whether or not there is a carry out of the high-order bit 
        #       position of the general register.
        #
        #       Program Interrupt - Fixed point overflow
        #
        AH:     {
                    n:'Add Halfword'
                    f:['AH R1,D2(B2)','AH R1,D2(X2,B2)']
                    d:'10000xxxddddddbb',
                    a:ADDR_HALFWORD
                    e:(t,v) ->
                        v1 = t.r(v.x).get32()
                        v2 = t.g_EAH(v) << 16
                        result = (v1 + v2) | 0
                        t.r(v.x).set32(result)
                        t.computeCCarith(result,0)
                }

        # ADD HALFWORD IMMEDIATE
        #
        #   Instruction bits 16 through 31 are treated as immediate data. The
        # halfword immediate data is first developed into a fullword operand by
        # appending 16 low-order zeroes. The resulting fullword operand is then
        # added to the contents of general register R2. The result replaces the
        # contents of general register R2. The immeidate operand is not changed.
        #
        # RESULTING CONDITION CODE
        #
        #   00  The result is zero
        #   11  The result is negative
        #   01  The result is positive (>0)
        #
        # INDICATORS
        #
        #   The overflow indicator is set to one if the magnitude of the sum
        # is tool large to be represented in the genral register; that is, 
        # greater than 1-2**-31 or less than -1. If the overflow indicator
        # already contains a one, it is not altered by this instruction.
        # (Overflow can be reset by testing or by loading the PSW.) The carry
        # indicator is set to indicate whether or not there is acaryy out of
        # the high-order bit position of the general register.
        #
        # Program interrupt -- Fixed point overflow.
        #
        AHI:    {
                    n:'Add Halfword Immediate'
                    f:['AHI R2,Data']
                    d:'1011000011100yyy/I'
                    a:ADDR_HALFWORD
                    e:(t,v) ->
                        v1 = v.I << 16
                        v2 = t.r(v.y).get32()
                        result = (v1 + v2)
                        t.r(v.y).set32(result)
                        t.computeCCarith(result,0)
                }

        # ADD TO STORAGE
        #
        #   The contents of general register R1 is added to the fullword second
        # operand. The result replaces the contents of the second operand 
        # location. The first operand is not changed.
        #
        # RESULTING CONDITION CODE
        #
        #   00  The result is zero
        #   11  The result is negative
        #   01  The result is positive (>0)
        #
        # INDICATORS
        #
        #   The overflow indicator is set to one if the magnitude of the sum is
        # too large to be represented in the second operand location. That is,
        # greater than 1-2**-31 or less than -1. If the overflow indicator 
        # already contains a one, is is not altered by this instruction. 
        # (Overflow can be reset by testing or by loading the PSW.) The carry
        # indicator is set to indicate whether or not there is a carry out of
        # the high-order bit position of the result.
        #
        # Program Interrupt -- Fixed point overflow
        #
        AST:    {
                    n:'Add and Store'
                    f:['AST R1,D2(B2)','AST R1,D2(X2,B2)']
                    d:'00000xxx11111abb/X'
                    e:(t,v) ->
                        v1 = t.r(v.x).get32()
                        v2 = t.g_EAF(v)
                        result = v1 + v2
                        t.s_EAF(v,result)
                        t.computeCCarith(result,0)
                }

        # COMPARE
        #
        #   The fullword second operand is algebraically compared with the
        # contents of general register R1. The contents of general register R1 
        # and main storage are not charged at the end of instruction execution.
        #
        # RESULTING CONDITION CODE
        #
        # 00 The contents of general register R1 equals the second operand.
        # 11 The contents of general register R1 are less than the second operand.
        # 01 The contents of general register R1 are greater than the second operand.
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this
        # instruction.
        #
        CR:     {
                    n:'Compare'
                    f:['CR R1,R2'],
                    d:'00010xxx11100yyy'
                    e:(t,v) ->
                        v1 = t.r(v.x).get32()
                        v2 = t.r(v.y).get32()
                        t.computeCCarith(v1,v2)
                }
        C:      {
                    n:'Compare'
                    f:['C R1,D2(B2)','C R1,D2(X2,B2)']
                    d:'00010xxxddddddbb'
                    e:(t,v) ->
                        v1 = t.r(v.x).get32()
                        v2 = t.g_EAF(v)
                        t.computeCCarith(v1,v2)
                }

        # COMPARE BETWEEN LIMITS
        #
        #   A compare between limits instruction occurs. The condition code
        # reflects the result of the comparison.
        #
        # (R1) |   Addr or Operand          |       modifier      |
        # (R2) |   Addr or Limits           |       modifier      |
        #
        #   The address of a 16-bit two's complement integer operand is
        # contained in bits 0 through 15 general register R1. The address of a
        # fullword with the following format containing the upper and lower
        # limits is contained in bits 0 through 15 of the general register R2:
        #
        #   -----------------------------------------------------------------
        #   |           Upper Limit         |        Lower Limit            |
        #   | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | |
        #   -----------------------------------------------------------------
        #    0                            1516                            31
        #
        # These limits are 16-bit two's complement integers.
        #
        #   In bits 16 through 31 of general registers R1 and R2 are 16-bit
        # two's complement integer modifiers. After the address in bits 0 
        # through 16 have been used to locate the operands, each modifier is
        # added to the most significant 16 bits of the registers. The result
        # replaces the most-significant 16 bits. The modifier is not changed,
        # overflows and carry out the most-significant address bit are ignored.
        #
        # RESULTING CONDITION CODE
        #
        #   00  Within Limits:      Lower Limit <= Operand <= Upper Limit
        #   01  Above Upper Limit:  Operand > Upper Limit
        #   11  Below Lower Limit:  Operand < Lower Limit
        #
        # INDICATOS
        #
        #   The overflow and carry indicators are not changed by this
        # instruction.
        #
        CBL:    {
                    n:'Compare Between Limits'
                    f:['CBL R1,R2']
                    d:'00001xxx11101yyy'
                    e:(t,v) ->
                        r1val = t.r(v.x).get32()
                        r2val = t.r(v.y).get32()
                        operandAddr = t.g_EXPAND((r1val >>> 16) & 0xffff)
                        limitsAddr = t.g_EXPAND((r2val >>> 16) & 0xffff)
                        # Read 16-bit two's complement operand
                        operand = t.ram.get16(operandAddr)
                        if operand & 0x8000 then operand = operand - 0x10000
                        # Read limits fullword: upper limit (bits 0-15), lower limit (bits 16-31)
                        upperLimit = t.ram.get16(limitsAddr)
                        lowerLimit = t.ram.get16(limitsAddr + 1)
                        if upperLimit & 0x8000 then upperLimit = upperLimit - 0x10000
                        if lowerLimit & 0x8000 then lowerLimit = lowerLimit - 0x10000
                        # Compare
                        if operand < lowerLimit
                            t.psw.setCC(3)
                        else if operand > upperLimit
                            t.psw.setCC(1)
                        else
                            t.psw.setCC(0)
                        # Update modifiers: add low 16 bits to high 16 bits of each register
                        r1mod = r1val & 0xffff
                        r1addr = ((r1val >>> 16) + r1mod) & 0xffff
                        t.r(v.x).set32((r1addr << 16) | r1mod)
                        r2mod = r2val & 0xffff
                        r2addr = ((r2val >>> 16) + r2mod) & 0xffff
                        t.r(v.y).set32((r2addr << 16) | r2mod)
                }

        # COMPARE HALFWORD
        #
        #   The halfword second operand is first developed into a fullword
        # operand by appending 16 low-order zeros.  The fullword operand is 
        # then algebraically compared with the contents of general register R1. 
        # The contents of general register and main storage are not changed at 
        # the end of instruction execution.
        #
        # RESULTING CONDITION CODE
        #
        # 00 The contents of general register R1 equals the developed fullword operand.
        # 11 The contents of general register R1 are less than the developed fullword operand.
        # 01 The contents of general register R1 are greater than the developed fullword operand.
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this
        # instruction.
        #
        # PROGRAMMING NOTE
        #
        #   After development, all 32 bits of the fullword operand participate
        # in the comparison.
        #
        CH:     {
                    n:'Compare Halfword'
                    f:['CH R1,D2(B2)','CH R1,D2(X2,B2)']
                    d:'10010xxxddddddbb'
                    a:ADDR_HALFWORD
                    e:(t,v) ->
                        v1 = t.r(v.x).get32()
                        v2 = t.g_EAH(v) << 16
                        t.computeCCarith(v1,v2)
                }

        # COMPARE HALFWORD IMMEDIATE
        #
        #   Instruction bits 16 through 31 are treated as immediate data. The 
        # halfword of immediate data is first developed into a fullword operand 
        # by appending 16 low-order zeros.  The fullword operand is then 
        # algebraically compared with the contents of general register R1. The 
        # contents of general register and main storage are not changed at the 
        # end of instruction execution.
        #
        # RESULTING CONDITION CODE
        #
        # 00 The contents of general register R2 equals the developed fullword 
        #    operand.
        # 11 The contents of general register R2 are less than the developed 
        #    fullword operand.
        # 01 The contents of general register R2 are greater than the developed 
        #    fullword operand.
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this
        # instruction.
        #
        # PROGRAMMING NOTE
        #
        #   After development, all 32 bits of the fullword operand participate
        # in the comparison.
        #
        CHI:    {
                    n:'Compare Halfword Immediate'
                    f:['CHI R2,Data']
                    d:'1011010111100yyy/I'
                    a:ADDR_HALFWORD
                    e:(t,v) ->
                        v1 = t.r(v.y).get32()
                        v2 = v.I << 16
                        t.computeCCarith(v1,v2)
                }

        # COMPARE IMMEDIATE WITH STORAGE
        #
        #   Instruction bits 16 through 31 are treated as immediate data. This
        # is algebraically compared with the halfword main storage operand. The 
        # immediate data and the contents of main storage are not changed at the 
        # end of this instruction.
        #
        # RESULTING CONDITION CODE
        #
        # 00 The immediate data equals the halfword main storage operand.
        # 11 The immediate data are less than the halfword main storage operand.
        # 01 The immediate data are greater than the halfword main storage 
        #    operand.
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this
        # instruction.
        #
        # PROGRAMMING NOTE
        #
        #   The Main Storage location containing the halfword operand must not
        # be store protected. If the location is store protected, execution of
        # this instruction will result in a store protect violation interrupt.
        #
        CIST:   {
                    n:'Compare Immediate and Store'
                    f:['CIST D2(B2),Data']
                    d:'10110101ddddddbb/I'
                    a:ADDR_HALFWORD
                    e:(t,v) ->
                        v1 = v.I
                        v2 = t.g_EAH(v)
                        t.computeCCarith(v1,v2)
                }

        # DIVIDE
        #
        #   The first operand, a 64-bit, signed 2's complement divident, is 
        # contained in the even/odd general register pair R1 and R1(+)1. The
        # most-significant portion is in R1. When R1 indicates an odd general
        # register, the first operand is devleoped by appending 32 low-order
        # zeros to the contents of R1. The second operand is the divisor.
        #
        #   The first operand is divided by the second operand. The unrounded
        # quotient replaces the contents of general register R1. The remainder
        # is not developed. When R1 is even, specifying an even/odd general
        # register pair, the contents of R1(+)1 are indeterminant at the end
        # of instruction execution. When R1 is odd, R1(+)1 is never changed.
        # The second operand is not changed.
        #
        #   When the relative magnitude of divident and divisor is such that
        # the quotient cannot be expressed as a 32-bit signed fraction, an
        # overflow is generated. In this event, the contents of both R1 (and
        # R1(+)1 when R1 is even) are indeterminate upon instruction 
        # termination
        #
        # RESULTING CONDITION CODE
        #
        #   The code is not changed.
        #
        # INDICATORS
        #
        #   The overflow indicator is set to one when the quotient cannot be
        # represented, or when division by zero is attempted. The dividend is
        # destroyed in these cases. If the overflow indicator already contains
        # a one, it is not changed. The carry indicaton has no significance
        # following execution and is indeterminate.
        #
        # Program Interrupt - Fixed point overflow.
        #
        DR:     {
                    n:'Divide'
                    f:['R R1,R2'],
                    d:'01001xxx11100yyy'
                    e:(t,v) ->
                        hi = t.r(v.x).get32()
                        lo = if v.x % 2 then 0 else t.r(v.x+1).get32()
                        {quotient, overflow} = q31_div(hi, lo, t.r(v.y).get32())
                        t.r(v.x).set32(quotient)
                        if overflow then t.psw.setOverflow(1)
                }
        D:      {
                    n:'Divide'
                    f:['D R1,D2(B2)','D R1,D2(X2,B2)']
                    d:'01001xxxddddddbb'
                    e:(t,v) ->
                        hi = t.r(v.x).get32()
                        lo = if v.x % 2 then 0 else t.r(v.x+1).get32()
                        {quotient, overflow} = q31_div(hi, lo, t.g_EAF(v))
                        t.r(v.x).set32(quotient)
                        if overflow then t.psw.setOverflow(1)
                }

        # EXCHANGE UPPER AND LOWER HALFWORDS
        #
        #   The upper halfword of general register R1 is exchanged with the 
        # lower halfword of general register R2. Bits 0 through 15 of general
        # register R1 replace bits 16 through 31 of general register R2 while
        # simultaneously bits 16 through 31 of general register R2 replace
        # bits 0 through 15 of general register R1.
        #
        # RESULTING CONDITION CODE
        # 
        #   The code is not changed.
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed.
        #
        XUL:    {
                    n:'Exclusive OR Upper and Lower'
                    f:['XUL R1,R2'],
                    d:'00000xxx11101yyy'
                    e:(t,v) ->
                        v1 = t.r(v.x).get32()
                        v2 = t.r(v.y).get32()
                        # XOR upper half of R1 with lower half of R2;
                        # result is placed in both locations
                        xorVal = (((v1 >>> 16) ^ v2) & 0xffff)
                        if v.x == v.y
                            t.r(v.x).set32((xorVal << 16) | xorVal)
                        else
                            t.r(v.x).set32((xorVal << 16) | (v1 & 0xffff))
                            t.r(v.y).set32((v2 & 0xffff0000) | xorVal)
                }

        # 11100xxx11110abb  BAL
        # 11100xxx11111abb  IAL

        # INSERT ADDRESS LOW
        #
        #   A 16-bit effective address is developed in the normal manner without
        # expanding to 19-bits. This address itself replaces the 16 low-order
        # bits of general register R1. The 16 high-order bits of general
        # register R1 are not changed.
        #
        # RESULTING CONDITION CODE
        #
        #   The code is not changed.
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this
        # instruction.
        #
        #
        IAL:    {
                    n:'Insert Address Low'
                    f:['IAL R1,D2(B2)','IAL R1,D2(X2,B2)']
                    a:ADDR_HALFWORD,
                    d:'11100xxxddddddbb',
                    eaFlg: 0x3e,
                    e:(t,v) ->
                        #console.log v
                        #console.log "IAL x=#{v.x} d=#{v.d.asHex()} b=#{v.b}"
                        v1 = t.r(v.x).get32()
                        v2 = t.g_EA_16(v)
                        #console.log v1.asHex(8), v2.asHex(8)
                        result = (v1 & 0xffff0000) | v2
                        t.r(v.x).set32(result)
                }

        # INSERT HALFWORD LOW
        #
        #   The halfword second operand replaces the cont ents of bits 16-31 of
        # general register R1. Bits 0-15 of general register R1 are not changed.
        # The second operand is not changed.
        #
        # RESULTING CONDITION CODE
        #
        #   The code is not changed.
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this
        # instruction.
        #
        IHL:    {
                    n:'Insert Halfword Low'
                    f:['IHL R1,D2(B2)','IHL R1,D2(X2,B2)']
                    d:'10000xxx11111abb/X'
                    a:ADDR_HALFWORD
                    e:(t,v) ->
                        v1 = t.r(v.x).get32()
                        v2 = t.g_EAH(v)
                        result = (v1 & 0xffff0000) | v2
                        #console.log "IHL v1=#{v1}, v2=#{v2}, r=#{result}"
                        t.r(v.x).set32(result)
                }

        # LOAD
        #
        #   The fullword second operand is placed in general register R1. The
        # second operand is not changed.
        #
        # RESULTING CONDITION CODE
        #
        #   00  The second operand is zero
        #   11  The second operand is negative
        #   01  The second operand is positive (>0)
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this 
        # instruction.
        #
        LR:     {
                    n:'Load Register'
                    f:['LR R1,R2'],
                    d:'00011xxx11100yyy'
                    e:(t,v) ->
                        val = t.r(v.y).get32()
                        t.r(v.x).set32(val)
                        t.computeCCarith(val, 0)
                }
        L:      {
                    n:'Load'
                    f:['L R1,D2(B2)','L R1,D2(X2,B2)']
                    d:'00011xxxddddddbb',
                    a:ADDR_FULLWORD
                    e:(t,v) ->
                        val = t.g_EAF(v)
                        t.r(v.x).set32(val)
                        t.computeCCarith(val, 0)
                }

        # LOAD ADDRESS
        #
        #   A 16-bit effective halfword address is developed
        #   in the normal manner without expanding to 19-bits.
        #   The address itself replaces the 16 high-order bits
        #   of general register R1.  The 16 low-order bits of
        #   general register R1 are zeroed.
        #
        # RESULTING CONDITION CODE
        #
        #   The code is not changed.
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this 
        # instruction.
        #
        # PROGRAMMING NOTE
        #
        #   When R1 = B2, it is possible to increment R1 by the displacement
        # field.
        #
        #   In the RS format when B2 = 11 and AM = 0, this is functionally 
        # equivalent to a LOAD HALFWORD IMMEDIATE instruction. In this case,
        # buts 16 through 31 are treated as immediate data. The Immediate data
        # is expanded to 32 bits by appending 16 low-order zeros. This 
        # resulting fullword operand replaces the contents of general register
        # R1.
        #
        LA:     {
                    n:'Load Address'
                    f:['LA R1,D2(B2)','LA R1,D2(X2,B2)']
                    d:'11101xxxddddddbb',
                    a:ADDR_HALFWORD
                    e:(t,v) ->
                        ea = t.g_EA_16(v)
                        t.r(v.x).set32(ea << 16)
                }

        LHI:    {
                    n:'Load Halfword Immediate'
                    f:['LHI R1,Value']
                    d:'11101xxx11110011/I'
                    a:ADDR_HALFWORD
                    e:(t,v) ->
                        #console.log "LHI", v
                        t.r(v.x).set32(v.I << 16)
                }
        # LOAD ARITHMETIC COMPLEMENT
        #
        #   The two's complement of the fullword second operand replace the
        # contents of general register R1. Complementation is accomplished by
        # adding the one's complement of the fullword second operand and a 
        # low-order one.
        #
        # RESULTING CONDITION CODE
        #
        #   00  The result is zero
        #   11  The result is negative
        #   01  The result is positive (>0).
        #
        # INDICATORS
        #
        #   The overflow indicator is set to one when the maximum negative
        # number is complemented. IF the overflow indicator already contains
        # a one, it is not altered by this instruction. The carry indicator is
        # set to indicate whether or not there is a carry out of the high-order
        # bit position of general register. The carry indicator will only be set
        # when the operand is zero.
        #
        # Program Interrupt - Fixed point overflow
        #
        LCR:    {
                    n:'Load Complement'
                    f:['LCR R1,R2'],
                    d:'11101xxx11101yyy'
                    a:ADDR_FULLWORD
                    e:(t,v) ->
                        v2 = t.r(v.y).get32()
                        result = ~v2 + 1
                        t.r(v.x).set32(result)
                        t.computeCCarith(result,0)
                }

        # LOAD FIXED IMMEDIATE
        #
        #   A fixed-point literal value is loaded into the general register
        # specified by R1.
        #
        #   The immediate values are -2, -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
        # 11, 12 or 13. The immediate is loaded into bits 0 through 15 of 
        # general register R1. Bits 16 through 31 of general register R1 are
        # set to zero
        #
        # RESULTING CONDITION CODE
        #
        #   The code is not changed by this instruction.
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this 
        # instruction
        #
        LFXI:   {
                    n:'Load Fixed Immediate'
                    f:['LFXI R1,Value']
                    d:'10111xxx1110yyyy'
                    e:(t,v) ->
                        lits = [ 0xfffe0000, 0xffff0000, 0x00000000, 0x00010000,
                                 0x00020000, 0x00030000, 0x00040000, 0x00050000,
                                 0x00060000, 0x00070000, 0x00080000, 0x00090000,
                                 0x000A0000, 0x000B0000, 0x000C0000, 0x000D0000 ]
                        result = lits[v.y+2]
                        t.r(v.x).set32(result)
                }

        # LOAD HALFWORD
        #
        #   The halfword second operand is developed into a fullword operand by
        # appending 16 low-order zeros. The resulting fullword operand replaces
        # the contents of general register R1. The second operand is not
        # changed.
        #
        # RESULTING CONDITION CODE
        #
        #   00  The fullword operand is zero
        #   11  The fullword operand is negative
        #   01  The fullword operand is positive (>0).
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this 
        # instruction.
        #
        # PROGRAMMING NOTE
        # 
        #   This instruction clears the low-order half of general register R1.
        #
        LH:     {
                    n:'Load Halfword'
                    f:['LH R1,D2(B2)','LH R1,D2(X2,B2)']
                    d:'10011xxxddddddbb'
                    a:ADDR_HALFWORD
                    e:(t,v) ->
                        v2 = t.g_EAH(v)
                        result = v2 << 16
                        #console.log "+LH", v, v2.toString(16), result.toString(16), v.x
                        t.r(v.x).set32(result)
                        t.computeCCarith(result,0)
                }

        # LOAD MULTIPLE
        #
        #   All eight general registers are loaded from the eight fullword
        # locations starting at the fullword, second operand address. The 
        # general registers are loaded in ascending order.
        #
        # RESULTING CONDITION CODE
        #
        #   The code is not changed.
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this 
        # instruction.
        #
        # PROGRAMMING NOTE
        #
        #   This instruction will always have halfword index alignment and will
        # be excluded from automatic index alignment.
        #
        LM:     {
                    n:'Load Multiple'
                    f:['LM D2(B2)','LM D2(X2,B2)']
                    d:'1100110011111abb/X'
                    a:ADDR_FULLWORD
                    e:(t,v) ->
                        v2ea = t.g_EA(v)
                        for i in [0..7]
                            t.r(i).set32(t.ram.get32(v2ea+(i*2)))
                }

        # MODIFY STORAGE HALFWORD
        #
        #   Instruction bits 16 through 31 are treated as immediate data
        # representing a 2's complement integer. This immediate data is added
        # to the halfword main storage operand. The result replaces the halfword
        # main storage operand. The contents of the general registers are not
        # changed. Only the contents of the halfword main storage operand
        # location is altered.
        #
        # RESULTING CONDITION CODE
        #
        #   00  The result is zero
        #   11  The result is negative
        #   01  The result is positive (>0).
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this 
        # instruction.
        #
        # PROGRAMMING NOTE
        #
        #   The MSTH immediate data (mask) is algebraically added to the
        # halfword operand in main storage. Tally up and tally down is thus
        # possible.
        #
        MSTH:   {
                    n:'Modify Storage Halfword'
                    f:['MSTH D2(B2),Data']
                    d:'10110000ddddddbb/I'
                    a:ADDR_HALFWORD
                    e:(t,v) ->
                        v1 = v.I & 0xffff
                        v2 = t.g_EAH(v)
                        result = (v1 + v2) & 0xffff
                        t.s_EAH(v,result)
                        # CC based on signed 16-bit result
                        signed = if result & 0x8000 then result - 0x10000 else result
                        t.computeCCarith(signed,0)
                }

        # MULTIPLY
        #
        #   The product of the multiplier (the second operand) and the 
        # multiplicant (the first operand) replaces the multiplicand. Both
        # multiplier and multiplicant are 32-bit signed 2's complement 
        # fractions. The product is a 64-bit, signed 2's complement fraction
        # and occupies an even/odd register pair when the R1 field references
        # an even-numbered general register. When R1 is odd, only the most
        # significant 32 bits of the product is saved in general register R1.
        #
        # RESULTING CONDITION CODE
        #
        #   The code is not changed.
        #
        # INDICATORS
        #
        #   The overflow indicator is set to one when -1 is multiplied by -1.
        # If the overflow indicator already contains a one, it is not altered
        # by this instruction.
        #
        # Program Interrupt - Fixed point overflow
        # 
        #
        MR:     {
                    n:'Multiply'
                    f:['MR R1,R2'],
                    d:'01000xxx11100yyy'
                    e:(t,v) ->
                        if v.x % 2 == 0
                            {hi, lo, overflow} = q31_mul32(t.r(v.x).get32(), t.r(v.y).get32())
                            t.r(v.x).set32(hi)
                            t.r(v.x + 1).set32(lo)
                            if overflow then t.psw.setOverflow(1)
                        else
                            {result, overflow} = q15_mul(t.r(v.x).get32() >> 16, t.r(v.y).get32() >> 16)
                            t.r(v.x).set32(result)
                            if overflow then t.psw.setOverflow(1)
                }
        M:      {
                    n:'Multiply'
                    f:['M R1,D2(B2)','M R1,D2(X2,B2)']
                    d:'01000xxxddddddbb'
                    e:(t,v) ->
                        if v.x % 2 == 0
                            {hi, lo, overflow} = q31_mul32(t.r(v.x).get32(), t.g_EAF(v))
                            t.r(v.x).set32(hi)
                            t.r(v.x + 1).set32(lo)
                            if overflow then t.psw.setOverflow(1)
                        else
                            {result, overflow} = q15_mul(t.r(v.x).get32() >> 16, t.g_EAF(v) >> 16)
                            t.r(v.x).set32(result)
                            if overflow then t.psw.setOverflow(1)
                }

        # MULTIPLY HALFWORD
        #
        #   The product of the halfword multiplier (the halfword second 
        # operand) and the halfword multiplicand (the contents of bits 0 
        # through 15 of general register R1) replaces the multiplicand. The
        # product is a 32-bit signed fraction. This product is saved in 
        # general register R1.
        #
        # RESULTING CONDITION CODE
        #
        #   The code is not changed.
        #
        # INDICATORS
        #
        #   The overflow indicator is set to one when -1 is multiplied by -1.
        # IF the overflow indicator already contains a one, it is not altered
        # by this instruction.
        #
        # Program Interrrupt - Fixed point overflow
        #
        MH:     {
                    n:'Multiply Halfword'
                    f:['MH R1,D2(B2)','MH R1,D2(X2,B2)']
                    d:'10101xxxddddddbb'
                    a:ADDR_HALFWORD
                    e:(t,v) ->
                        v1 = t.r(v.x).get32() >> 16
                        v2 = t.g_EAH(v)
                        if v2 & 0x8000 then v2 = v2 - 0x10000
                        {result, overflow} = q15_mul(v1, v2)
                        t.r(v.x).set32(result)
                        if overflow then t.psw.setOverflow(1)
                }

        # MULTIPLY HALFWORD IMMEDIATE
        #
        #   Instruction bits 16 through 31 are treated as immediate data. This
        # halfword of immediate data is the multiplier. The contents of bits
        # 0 through 15 of general register R2 are the halfword multiplicand.
        # The product of multiplier and the multiplicand is a 32-bit signed
        # fraction. This product is saved in general register R2.
        #
        # RESULTING CONDITION CODE
        #
        #   The code is not changed.
        #
        # INDICATORS
        #
        #   The overflow indicator is set to one when -1 is multiplied by -1.
        # If the overflow indicator already contains a one, it is not altered
        # by this instruction.
        #
        # Program Interrupt - Fixed point overflow
        #
        MHI:    {
                    n:'Multiply Halfword Immediate'
                    f:['MHI R2,Data']
                    d:'1011011111100yyy/I'
                    a:ADDR_HALFWORD
                    e:(t,v) ->
                        v1 = v.I
                        if v1 & 0x8000 then v1 = v1 - 0x10000
                        v2 = t.r(v.y).get32() >> 16
                        {result, overflow} = q15_mul(v1, v2)
                        t.r(v.y).set32(result)
                        if overflow then t.psw.setOverflow(1)
                }

        # MULTIPLY INTEGER HALFWORD
        #
        #   The product of the multiplier (the two's complement signed integer
        # halfword second operand) and the two's complement signed integer
        # halfword multiplicand (the contents of bits 0 through 15 of general
        # register R1) replaces the multiplicant. An intermediate product is
        # formed as a 31-bit signed integer. The product is algebraically
        # shifted left 15 places, to form a two's complement signed halfword
        # integer product. This halfword product replaces bits 0 through 15 of
        # general register R1. Bits 16 through 31 of general register R1 are
        # zeroed.
        #
        # RESULTING CONDITION CODE
        #
        #   The code is not changed.
        #
        # INDICATORS
        #
        # Program Interrupt - Fixed point overflow
        #
        #   The overflow indicator is set when the upper 16 bits of the 
        # intermediate product does not euqal all ones or all zeroes. If the
        # overflow indicator already contains a one, it is not altered by this
        # instruction.
        #
        # PROGRAMMING NOTE
        #
        #   If I, J, K are halfword operands, the equation I*J+K may be solved
        # with the following code:
        #
        #                           LH      R1,I
        #                           MIH     R1,J
        #                           AH      R1,K
        #
        MIH:    {
                    n:'Multiply Integer Halfword'
                    f:['MIH R1,D2(B2)','MIH R1,D2(X2,B2)']
                    d:'10011xxx11111abb/X'
                    a:ADDR_HALFWORD
                    e:(t,v) ->
                        # Multiplicand: bits 0-15 of R1 (signed integer halfword)
                        v1 = t.r(v.x).get32() >> 16
                        # Multiplier: halfword from memory (signed integer)
                        v2 = t.g_EAH(v)
                        if v2 & 0x8000 then v2 = v2 - 0x10000
                        product = v1 * v2
                        # Store lower 16 bits of product in upper half of R1, zero lower half
                        t.r(v.x).set32((product & 0xffff) << 16)
                        # Overflow if product doesn't fit in signed 16 bits
                        check = product >> 15
                        if check != 0 and check != -1
                            t.psw.setOverflow(1)
                }

        # STORE
        #
        #   The contents of general register R1 are stored at the fullword
        # second operand location. The contents of general register R1 are
        # not changed.
        #
        # RESULTING CONDITION CODE
        #
        #   The code is not changed.
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this
        # instruction.
        #
        ST:     {
                    n:'Store'
                    f:['ST R1,D2(B2)','ST R1,D2(X2,B2)']
                    d:'00110xxxddddddbb'
                    a:ADDR_FULLWORD
                    e:(t,v) ->
                        v1 = t.r(v.x).get32()
                        result = v1
                        t.s_EAF(v,result)
                }

        # STORE HALFWORD
        #
        #   The most significant 16 bits (bits 0 through 15) of general register
        # R1 are stored at the halfword second operand location. No other 
        # storage location is altered. The contents of general register R1 are
        # not changed.
        #
        # RESULTING CONDITION CODE
        #
        #   The code is not changed by this instruction.
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this
        # instruction.
        #
        STH:    {
                    n:'Store Halfword'
                    f:['STH R1,D2(B2)','STH R1,D2(X2,B2)']
                    d:'10111xxxddddddbb'
                    a:ADDR_HALFWORD
                    e:(t,v) ->
                        v1 = t.r(v.x).get32()
                        result = v1 >>> 16
                        t.s_EAH(v,result)
                }

        # STORE MULTIPLE
        #
        #   All eight general registers are stored at the eight fullword
        # locations starting at the fullword second operand address. The
        # general registers are stored in ascending order.
        #
        # RESULTING CONDITION CODE
        #
        #   The code is not changed.
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this 
        # instruction.
        #
        # PROGRAMMING NOTE
        #
        #   The instruction is excluded from automatic index alignment. 
        # Indexes will always specify the halfword.
        #
        STM:    {
                    n:'Store Multiple'
                    f:['STM D2(B2)','STM D2(X2,B2)']
                    d:'1100100011111abb/X'
                    a:ADDR_FULLWORD
                    e:(t,v) ->
                        v2ea = t.g_EA(v)
                        for i in [0..7]
                            t.ram.set32(v2ea+(i*2),t.r(i).get32())
                }

        # SUBTRACT
        #
        #   The fullword second operand is subtracted from the contents of 
        # general register R1. The result replaces the contents of general
        # register R1. The second operand is not changed.
        #
        #   Subtraction is performed by adding the one's-complement of the 
        # second and a low-order one to form the two's complement for the 
        # fullword. This fullword is added to the first operand. All 32 bits
        # of both operands participate as in ADD. The overflow, carry, and
        # condition code indicators reflect the result of this addition.
        #
        # RESULTING CONDITION CODE
        #
        #    00  The result is zero
        #    11  The result is negative
        #    01  The result is positive (> 0).
        #
        # INDICATORS
        #
        #   The overflow indicator is set to one if the magnitude of the 
        # difference is too large to be represented in R1; that is, greater
        # than 1-2**-31 or less than -1. If the overflow indicator already
        # contains a one, it is not altered by this instruction. (Overflow
        # can be reset by testing or by loading the PSW.) The carry indicator
        # is set to indicate whether or not there is a carry out of the high-
        # order bit position of R1.
        # 
        # Program Interrupt - Fixed point overflow
        #
        SR:     {
                    n:'Subtract'
                    f:['SR R1,R2'],
                    d:'00001xxx11100yyy'
                    e:(t,v) ->
                        v1 = t.r(v.x).get32()
                        v2 = t.r(v.y).get32()
                        result = v1 + (~v2 + 1)
                        t.r(v.x).set32(result)
                        t.computeCCarith(result,0)
                }
        S:      {
                    n:'Subtract'
                    f:['S R1,D2(B2)','S R1,D2(X2,B2)']
                    d:'00001xxxddddddbb'
                    e:(t,v) ->
                        v1 = t.r(v.x).get32()
                        v2 = t.g_EAF(v)
                        result = v1 + (~v2 + 1)
                        t.r(v.x).set32(result)
                        t.computeCCarith(result,0)
                }

        # SUBTRACT FROM STORAGE
        #
        #   The contents of general register R1 is subtracted from the fullword
        # second operand. The result replaces the contents of the second
        # operand location. The first operand is not changed.
        #
        # RESULTING CONDITION CODE
        #
        #    00  The result is zero
        #    11  The result is negative
        #    01  The result is positive (> 0).
        #
        # INDICATORS
        #
        #   The overflow indicator is set to one if the magnitude of the 
        # difference is too large to be represented in R1; that is, greater
        # than 1-2**-31 or less than -1. If the overflow indicator already
        # contains a one, it is not altered by this instruction. (Overflow
        # can be reset by testing or by loading the PSW.) The carry indicator
        # is set to indicate whether or not there is a carry out of the high-
        # order bit position of R1.
        # 
        # Program Interrupt - Fixed point overflow
        #
        SST:    {
                    n:'Subtract From Storage'
                    f:['SST R1,D2(B2)','SST R1,D2(X2,B2)']
                    d:'00001xxx11111abb/X'
                    e:(t,v) ->
                        v1 = t.r(v.x).get32()
                        v2 = t.g_EAF(v)
                        result = (~v1+1) + v2
                        t.s_EAF(v,result)
                        t.computeCCarith(result,0)
                }

        # SUBTRACT HALFWORD
        #
        #   The halfword second operand is first developed into a fullword
        # operand by appending 16 low-order zeros. This second operand is then
        # subtraced from the contents of general register R1. The result 
        # replaces the contents of general register R1. The second halfword
        # operand is not changed.
        #
        #   Subtraction is performe dby adding the ones complement of the
        # developed fullword operand and a low-order one to form the fullword
        # twos complement. This fullword is added to the first operand.
        #
        #
        # RESULTING CONDITION CODE
        #
        #    00  The result is zero
        #    11  The result is negative
        #    01  The result is positive (> 0).
        #
        # INDICATORS
        #
        #   The overflow indicator is set to one if the magnitude of the 
        # difference is too large to be represented in R1; that is, greater
        # than 1-2**-31 or less than -1. If the overflow indicator already
        # contains a one, it is not altered by this instruction. (Overflow
        # can be reset by testing or by loading the PSW.) The carry indicator
        # is set to indicate whether or not there is a carry out of the high-
        # order bit position of R1.
        # 
        # Program Interrupt - Fixed point overflow
        #
        SH:     {
                    n:'Subtract Halfword'
                    f:['SH R1,D2(B2)','SH R1,D2(X2,B2)']
                    d:'10001xxxddddddbb'
                    a:ADDR_HALFWORD
                    e:(t,v) ->
                        v1 = t.r(v.x).get32()
                        v2 = t.g_EAH(v) << 16
                        result = v1 + (~v2 + 1)
                        t.r(v.x).set32(result)
                        t.computeCCarith(result,0)
                }

        # TALLY DOWN
        #
        #   The main storage halfword operand is decremented by one, and the
        # result replaces the halfword operand. The contents of the general
        # registers are not changed. Only the contents of the main storage
        # operand is altered.
        #
        # RESULTING CONDITION CODE
        #
        #    00  The result is zero
        #    11  The result is negative
        #    01  The result is positive (> 0).
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this
        # instruction.
        #
        # PROGRAMMING NOTE
        #
        #   This instruction is similar to the MODIFY STORAGE HALFWORD 
        # instruction with an implied operand of all ones. The MSTH instruction
        # should be used instead of TALLY DOWN when execution speed is 
        # important.
        #
        TD:     {
                    n:'Tally Down'
                    f:['TD D2(B2)','TD D2(X2,B2)']
                    d:'10100000ddddddbb'
                    a:ADDR_HALFWORD
                    e:(t,v) ->
                        v1 = t.g_EAH(v)
                        result = (v1 - 1) & 0xffff
                        t.s_EAH(v,result)
                        # CC based on signed 16-bit result
                        signed = if result & 0x8000 then result - 0x10000 else result
                        t.computeCCarith(signed,0)
                }

        # BRANCH AND LINK
        #
        #   First, the branch address is computed. Then, the first word of the
        # current PSW (bits 0 - 31) is loaded into general register R1. Thus,
        # the address of the next sequential instruction is preserved in 
        # register R1 (bits 0-15). The remaining bits of general register R1
        # (bits 16-31) will contain the condition code, the carry indicator,
        # overflow indicator, the fixed-point overflow mask, the exponent
        # underflow mask, the significance mask, and the contents of the branch
        # and data sector registers.
        #
        #   For the RR format, the branch address is contained in bits 0 
        # through 15 of general register R2, if R2 / 0. This 16-bit branch
        # address is expanded to a 19-bit branch address. (See Expanded
        # Addressing.)
        #
        # RESULTING CONDITION CODE
        #
        #   The code is not changed.
        #
        # INDICATORS
        #
        #   The overflow and carry indicatros are not changed by this
        # instruction.
        #
        # PROGRAMMING NOTE
        #
        #   The assembly instruction BALR R1, 0 causes the address (instruction
        # counter and BSR) of the next sequential instruction to be stored in
        # bits 0 through 15, and 24 through 27 of general register R1. In this
        # particular case, no branch is taken.
        #
        BALR:   {
                    n:'Branch and Link Register'
                    f:['BALR R1,R2'],
                    d:'11100xxx11100yyy'
                    t:OPTYPE_BRCH
                    e:(t,v) ->
                        t.r(v.x).set32(t.psw.psw1.get32())
                        # BALR R1, 0 -> no branch (R2 field must be nonzero)
                        if v.y != 0
                            branch = t.g_EXPAND(t.r(v.y).get32() >>> 16, OPTYPE_BRCH)
                            t.psw.setNIA(branch)
                }
        BAL:    {
                    n:'Branch and Link'
                    f:['BAL R1,D2(B2)','BAL R1,D2(X2,B2)']
                    d:'11100xxx11110abb/X'
                    a:ADDR_HALFWORD
                    t:OPTYPE_BRCH
                    e:(t,v) ->
                        branch = t.g_EA(v)
                        t.r(v.x).set32(t.psw.psw1.get32())
                        # BALR R1, 0 -> no branch
                        t.psw.setNIA(branch)

                }

        # 11100xxx11110abb  BAL
        # 11100xxx11111abb  IAL

        # BRANCH AND INDEX
        #
        # "Bits 0 through 15 of the general register specified by R1 contain an
        # an index. Bits 16 through 31 of general register R1 contain a count.
        # An effective address is computed in the normal manner for the 
        # extended class. (For the indexed addressing mode, the fullword 
        # indirect address pointer must contain zero's in bit locations 22 and
        # 32.) Next, the index is incremented by one. The the count is 
        # decremented by one. If the count prior to update is greater than zero,
        # a branch to the effective address is taken. If the count prior to
        # update is less than or equal to zero, no branch occurs."
        #
        # RESULTING CONDITION CODE
        #
        #   The code is not changed.
        #
        # INDICATORS
        #
        #   The carry and overflow indicators are not changed by this 
        # instruction.
        #
        BIX:    {
                    n:'Branch and Index'
                    f:['BIX R1,D2(B2)','BIX R1,D2(X2,B2)']
                    d:'11011xxx11110abb/X'
                    a:ADDR_HALFWORD
                    t:OPTYPE_BRCH
                    e:(t,v) ->
                        R1 = t.r(v.x).get32()
                        index = R1 >>> 16
                        count = R1 & 0xffff
                        branch = t.g_EA(v)
                        index = index + 1
                        count = count - 1
                        t.r(v.x).set32((index << 16) | (count & 0xffff)) 
                        if count+1 > 0
                            t.psw.setNIA(branch)
                }

        # BRANCH ON CONDITION
        #
        # This instruction tests the PSW condition code status bits. Instruction
        # bits 5 through 7 (the M1 field) specify which condition code (bits 16
        # and 17 of the PSW) is to be tested. Instruction bit 5 tests for a 
        # code equal 00, instruction bit 6 tests for a code equal 11, and 
        # instruction bit-7 tests for a code equal 01. Whenever the condition
        # code test is successful, the branch is taken. Thus, when more than one
        # bit of the M1 field is a one, the branch is taken for any successful
        # test. (e.g. M1=111 always branches, M1=000 never branches.)
        #   The branch address is contained in bits 0 through 15 of general
        # register R2 for the RR format., This 16-bit branch address is
        # expanded to a 19-bit branch addres. (See Expanded Addressing.)
        #
        # RESULTING CONDITION CODE
        #
        #   The condition code was set follwing all arithmetic, logical, test,
        # and compare instructions, and otherwise remains unchanged unless the
        # program status word is altered. The code is not changed by this
        # instruction.
        # 
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this 
        # instruction.
        #
        # PROGRAMMING NOTE
        #
        #   The result and test conditions are show as follows:
        #
        #
        #                          M1 Field (Test)
        #                            (5) (6) (7)
        #
        #       Arithmetic & Tally
        #           Zero              1   0   0
        #           Negative          0   1   0
        #           Positive (>0)     0   0   1
        #
        #       Logical
        #           Zero              1   0   0
        #           Not Zero          0   1   0
        #       
        #       Test
        #           Zero              1   0   0
        #           Mixed             0   1   1
        #           All ones          0   0   1
        #
        #       Compare
        #           Equal             1   0   0
        #           O_1 < O_2         0   1   0
        #           O_1 > O_2         0   0   1
        #
        #   It is possible to combine tests. For example, following the MSTH
        # instruction, an M1 field of 1 0 1 specifies branch on non-negative
        # (zero or positive).
        #
        BCR:    {
                    n:'Branch on Condition Register'
                    f:['BCR M1,R2']
                    d:'11000xxx11100yyy'
                    t:OPTYPE_BRCH
                    e:(t,v) ->
                        m1 = v.x
                        v2 = t.g_EXPAND(t.r(v.y).get32() >>> 16, OPTYPE_BRCH)
                        cc = t.psw.getCC()
                        if (m1&4 and cc==0) or (m1&2 and cc==3) or (m1&1 and cc==1)
                            t.psw.setNIA(v2)
                }
        BC:     {
                    n:'Branch on Condition'
                    f:['BC M1,D2(B2)','BC M1,D2(X2,B2)']
                    d:'11000xxx11110abb/X'
                    a:ADDR_HALFWORD
                    t:OPTYPE_BRCH
                    e:(t,v) ->
                        m1 = v.x
                        v2 = t.g_EA(v)
                        cc = t.psw.getCC()
                        if (m1&4 and cc==0) or (m1&2 and cc==3) or (m1&1 and cc==1)
                            t.psw.setNIA(v2)
                }

        # BRANCH ON CONDITION BACKWARD
        #
        #   This instruction tests the PSW condition code status bits. 
        # Instruction bits 5 through 7 (the M1 field) specify which condition 
        # code (bits 16 and 17 of the PSW) is to be tested. Instruction bit
        # 5 tests for a code equal 00, instruction bit 6 tests for a code equal
        # 11, and instruction bit 7 tests for a code equal 01. Whenever the
        # condition code test is successful, the branch is taken by subtracting
        # the Disp from the updated IC. This, when more than one bit of the M1
        # field is a one, the branch is taken for any successful test (e.g.,
        # M1=111 always branches).
        #
        # RESULTING CONDITION CODE
        #
        #   The condition code was set following all arithmetic, logical, test,
        # and compare instructions, and otherwise remains unchanged unless the
        # program status word is altered. The code is not changed by this 
        # instruction.
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this
        # instruction.
        #
        BCB:    {
                    n:'Branch on Condition Backward'
                    f:['BCB M1,D2']
                    d:'11011xxxdddddd10'
                    a:ADDR_HALFWORD
                    t:OPTYPE_BRCH
                    e:(t,v) ->
                        m1 = v.x
                        disp = v.d
                        cc = t.psw.getCC()
                        if (m1&4 and cc==0) or (m1&2 and cc==3) or (m1&1 and cc==1)
                            t.psw.setNIA(t.psw.getNIA()-disp)
                }

        # BRANCH ON CONDITION (EXTENDED)
        #
        #   This instruction tests the PSW condition code status bits. 
        # Instruction bits 5 through 7 (the M1 field) specify which condition 
        # code (bits 16 and 17 of the PSW) is to be tested. Instruction bit 5
        # tests for a code equal 00, instruction bit 6 test for a code equal 11,
        # and instruction bit-7 tests for a code equal 01. Whenever the 
        # condition code test is successful, the branch is taken. Thus, when
        # more than one bit of the M1 field is a one, the branch is taken for
        # any successful test. (e.g., M1=111 always branches.)
        #
        #   When the branch is taken, PSW bits 0 through 15 and bits 24 through
        # 31 are replaced by corresponding bits in general register R2.
        #
        # RESULTING CONDITION CODE
        #
        #   The condition code was set follwoing all arithmetic, logical, test,
        # and compare instructions, and otherwise remains unchanged unless the
        # program status word is altered. The code is not changed by this
        # instruction.
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this 
        # instruction.
        #
        # PROGRAMMING NOTE
        #
        #   This instruction is similar to the RR version of the BRANCH ON
        # CONDITION instruction. It is provided to facilitate subroutine
        # returns across sector boundaries after general register R2 had been
        # initialized by the use of the BRANCH AND LINK instruction.
        #
        BCRE:   {
                    n:'Branch on Condition (Extended)'
                    f:['BCRE M1,R2']
                    d:'11000xxx11101yyy'
                    t:OPTYPE_BRCH
                    e:(t,v) ->
                        m1 = v.x
                        branch = t.r(v.y).get32() >>> 16
                        bsr = (t.r(v.y).get32() >>> 4) & 0xf
                        dsr = (t.r(v.y).get32()) & 0xf
                        cc = t.psw.getCC()
                        if (m1&4 and cc==0) or (m1&2 and cc==3) or (m1&1 and cc==1)
                            t.psw.setNIA(branch)
                            t.psw.setBSR(bsr)
                            t.psw.setDSR(dsr)
                }

        # BRANCH ON CONDITION FORWARD
        #
        #   This instruction tests the PSW condition code status bits. 
        # Instruction bits 5 through 7 (the M1 field) specify which condition 
        # code (bits 16 and 17 of the PSW) is to be tested. Instruction bit
        # 5 tests for a code equal 00, instruction bit 6 tests for a code equal
        # 11, and instruction bit 7 tests for a code equal 01. Whenever the
        # condition code test is successful, the branch is taken by adding the 
        # Disp to the updated IC. This, when more than one bit of the M1 field 
        # is a one, the branch is taken for any successful test (e.g.,
        # M1=111 always branches).
        #
        # RESULTING CONDITION CODE
        #
        #   The condition code was set following all arithmetic, logical, test,
        # and compare instructions, and otherwise remains unchanged unless the
        # program status word is altered. The code is not changed by this 
        # instruction.
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this
        # instruction.
        #
        BCF:    {
                    n:'Branch on Condition Forward'
                    f:['BCF M1,D2']
                    d:'11011xxxdddddd00'
                    a:ADDR_HALFWORD
                    t:OPTYPE_BRCH
                    e:(t,v) ->
                        m1 = v.x
                        disp = v.d
                        cc = t.psw.getCC()
                        if (m1&4 and cc==0) or (m1&2 and cc==3) or (m1&1 and cc==1)
                            t.psw.setNIA(t.psw.getNIA()+disp)

                }

        # BRANCH ON COUNT
        #
        #   First, the branch address is computed. The branch address is 
        # contained in bits 0 through 15 of general register R2 for the RR
        # format. This 16-bit branch address is expanded to a 19-bit branch
        # address. (See Expanded Addressing.)
        #
        #   Then, the contents of bits 0 through 15 of general register R1 are
        # reduced by one. When the result is zero, the next sequential 
        # instruction is executed in the normal manner. When the result is not
        # zero, the instruction counter is loaded with the branch address.
        #
        # RESULTING CONDITION CODE
        #
        #   The code is not changed.
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this 
        # instruction.
        #
        # PROGRAMMING NOTE
        #
        #   An initial count of one results in zero, and no branch takes place.
        # An initial count of zero results in a minus one and cuases branching
        # to be executed.
        #
        BCTR:   {
                    n:'Branch on Count Register'
                    f:['BCTR R1,R2'],
                    d:'11010xxx11100yyy'
                    t:OPTYPE_BRCH
                    e:(t,v) ->
                        # Decrement bits 0-15 of R1
                        r1val = t.r(v.x).get32()
                        count = ((r1val >>> 16) - 1) & 0xffff
                        t.r(v.x).set32((count << 16) | (r1val & 0xffff))
                        # Branch if result is not zero
                        if count != 0
                            branch = t.g_EXPAND(t.r(v.y).get32() >>> 16, OPTYPE_BRCH)
                            t.psw.setNIA(branch)
                }
        BCT:    {
                    n:'Branch on Count'
                    f:['BCT R1,D2(B2)','BCT R1,D2(X2,B2)']
                    d:'11010xxx11110abb/X'
                    a:ADDR_HALFWORD
                    t:OPTYPE_BRCH
                    e:(t,v) ->
                        # Decrement bits 0-15 of R1
                        r1val = t.r(v.x).get32()
                        count = ((r1val >>> 16) - 1) & 0xffff
                        t.r(v.x).set32((count << 16) | (r1val & 0xffff))
                        # Branch if result is not zero
                        if count != 0
                            t.psw.setNIA(t.g_EA(v))
                }

        # BRANCH ON COUNT BACKWARD
        #
        #   First, the branch address is formed by subtracting the displacement
        # from the updated instruction counter. Then, the contents of bits 0 
        # through 15 of general register R1 are reduced by one. When the result 
        # is zero, the next sequential instruction is executed in the normal 
        # manner. When the result is not zero, the instruction counter is 
        # loaded with the branch address.
        #
        # RESULTING CONDITION CODE
        #
        #   The code is not changed.
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this 
        # instruction.
        #
        # PROGRAMMING NOTE
        #
        #   An initial count of one results in zero, and no branch takes place.
        # An initial count of zero results in a minus one and cuases branching
        # to be executed.
        #
        #
        BCTB:   {
                    n:'Branch on Count Backward'
                    f:['BCTB R1,D2'],
                    d:'11011xxxdddddd11'
                    a:ADDR_HALFWORD
                    t:OPTYPE_BRCH
                    e:(t,v) ->
                        # Decrement bits 0-15 of R1
                        r1val = t.r(v.x).get32()
                        count = ((r1val >>> 16) - 1) & 0xffff
                        t.r(v.x).set32((count << 16) | (r1val & 0xffff))
                        # Branch backward if result is not zero
                        if count != 0
                            disp = v.d
                            t.psw.setNIA(t.psw.getNIA() - disp)
                }

        # BRANCH ON OVERFLOW AND CARRY
        #
        #   This instruction tests the PSW overflow and carry indicator status
        # bits. The M1 field, instruction bits 5-7 specifies the test. 
        # Instruction bit 6 is tested against PSW bit 18 (carry), and 
        # instruction bit 7 is tested against PSW bit 19 (overflow). Whenever
        # a specified bit of the PSW is a one, the test is successful and the
        # branch is taken. This, when both indicators are tested by M1=011, the
        # branch is taken if either indicator contains a one. A one in instruct-
        # ion bit 5 inverts the logic, causing bits 6 and 7 to test the PSW bits
        # for zero.
        #   For the RR format, the branch address is contained in bits 0 through
        # 15 of general register R2. This 16-bit branch address is expanded to
        # a 19-bit branch address. (See Expanded Addressing.)
        #
        # RESULTING CONDITION CODE
        #
        #   The code is not changed.
        #
        # INDICATORS
        #
        #   The overflow indicator is set 0 by this instruction. The carry 
        # indicator is not changed by this instruction.
        #
        # PROGRAMMING NOTE
        #
        #   The possible combinations of test conditions are shown as follows:
        #
        #       M1 Field                    Test Conditions
        #       --------                    ---------------
        #        5 6 7
        #        -----
        #        0 0 0              Branch never taken (no operation)
        #        0 0 1              Branch on Overflow
        #        0 1 0              Branch on Carry
        #        0 1 1              Branch either on Overflow or on Carry
        #        1 0 0              Branch
        #        1 0 1              Branch On No Overflow
        #        1 1 0              Branch On No Carry
        #        1 1 1              Branch On No Overflow and No Carry
        #
        BVCR:   {
                    n:'Branch on Overflow/Carry Register'
                    f:['BVCR M1,R2']
                    d:'11001xxx11100yyy'
                    t:OPTYPE_BRCH
                    e:(t,v) ->
                        m1 = v.x
                        carry = t.psw.getCarry()
                        overflow = t.psw.getOverflow()
                        invert = m1 & 4
                        testCarry = m1 & 2
                        testOverflow = m1 & 1
                        taken = false
                        if invert
                            if testCarry and not carry then taken = true
                            if testOverflow and not overflow then taken = true
                            if not testCarry and not testOverflow then taken = true
                        else
                            if testCarry and carry then taken = true
                            if testOverflow and overflow then taken = true
                        if taken
                            branch = t.g_EXPAND(t.r(v.y).get32() >>> 16, OPTYPE_BRCH)
                            t.psw.setNIA(branch)
                        t.psw.setOverflow(0)
                }
        BVC:    {
                    n:'Branch on Overflow/Carry'
                    f:['BVC M1,D2(B2)','BVC M1,D2(X2,B2)']
                    d:'11001xxx11110abb/X'
                    a:ADDR_HALFWORD
                    t:OPTYPE_BRCH
                    e:(t,v) ->
                        m1 = v.x
                        carry = t.psw.getCarry()
                        overflow = t.psw.getOverflow()
                        invert = m1 & 4
                        testCarry = m1 & 2
                        testOverflow = m1 & 1
                        taken = false
                        if invert
                            if testCarry and not carry then taken = true
                            if testOverflow and not overflow then taken = true
                            if not testCarry and not testOverflow then taken = true
                        else
                            if testCarry and carry then taken = true
                            if testOverflow and overflow then taken = true
                        if taken
                            t.psw.setNIA(t.g_EA(v))
                        t.psw.setOverflow(0)
                }

        # BRANCH ON OVERFLOW AND CARRY FORWARD
        #
        #   This instruction tests the PSW overflow and carry indicator status
        # bits. Instruction bits 5 through 7 specifies the test. Instruction 
        # bit 6 is tested against PSW bit 18, and instruction bit 7 is tested 
        # against PSW bit 19. Whenever a specified bit of the PSW is a one, the 
        # test is successful and the branch is taken by adding the Disp to the
        # updated IC. Thus, when both indicators are tested by M1=011, the
        # branch is taken if either indicator contains a one. A one in instruct-
        # ion bit 5 inverts the logic, causing bits 6 and 7 to test the PSW bits
        # for zero.
        #
        #   The branch address is formed by adding the displacement to the 
        # updated instruction counter.
        #
        # RESULTING CONDITION CODE
        #
        #   The code is not changed.
        #
        # INDICATORS
        #
        #   The overflow indicator is set 0 by this instruction. The carry 
        # indicator is not changed by this instruction.
        #
        # PROGRAMMING NOTE
        #
        #   The possible combinations of test conditions are shown as follows:
        #
        #       M1 Field                    Test Conditions
        #       --------                    ---------------
        #        5 6 7
        #        -----
        #        0 0 0              Branch never taken (no operation)
        #        0 0 1              Branch on Overflow
        #        0 1 0              Branch on Carry
        #        0 1 1              Branch either on Overflow or on Carry
        #        1 0 0              Branch
        #        1 0 1              Branch On No Overflow
        #        1 1 0              Branch On No Carry
        #        1 1 1              Branch On No Overflow and No Carry
        #
        BVCF:   {
                    n:'Branch on Overflow/Carry Forward'
                    f:['BVCF M1,D2']
                    d:'11011xxxdddddd01'
                    a:ADDR_HALFWORD
                    t:OPTYPE_BRCH
                    e:(t,v) ->
                        m1 = v.x
                        carry = t.psw.getCarry()
                        overflow = t.psw.getOverflow()
                        invert = m1 & 4
                        testCarry = m1 & 2
                        testOverflow = m1 & 1
                        taken = false
                        if invert
                            if testCarry and not carry then taken = true
                            if testOverflow and not overflow then taken = true
                            if not testCarry and not testOverflow then taken = true
                        else
                            if testCarry and carry then taken = true
                            if testOverflow and overflow then taken = true
                        if taken
                            disp = v.d
                            t.psw.setNIA(t.psw.getNIA() + disp)
                        t.psw.setOverflow(0)
                }

        # NORMALIZE AND COUNT
        #
        #   First, all bits (0 through 31) of general register R1 are set to
        # zero. For each position that the contents of general register R2 are
        # shifted, to the left, the high-order half of general register R1 bits
        # (0 through 15) is incremented by 1. The shift terminates when bit
        # position 0 != bit position 1 of general register R2. If the contents
        # of general register R2 are initially zero, a count of zero is entered
        # in general register R1. Zeros are entered into the vacated low-order
        # bits of general register R2. Upon completion of this instruction, the
        # count is contained in bits 0 through 15 of general register R1.
        #
        # RESULTING CONDITION CODE
        #
        #   The code is not changed by this instruction.
        #
        # INDICATORS
        #
        #   The carry indicators will be zero at the end of the operation, if 
        # the general register R2 contains zero. The carry indicator will be
        # one at the end of the operation, if the shift is terminated by the
        # detection of bit position one not equal to bit position 0 of the 
        # general register R2. The overflow indicator is not changed by this
        # instruction.
        #
        # PROGRAMMING NOTE
        #
        #   If the initial condition of general register R2 was such that bit
        # position 0 is not equal to bit position 1, the count in the hight 
        # order bit of general register R1 is zero, the carry indicator is one,
        # and there is no shift.. If the initial condition of R2 wall all ones,
        # the count is 31, the carry is one and R2 contains 80000000.
        #
        #   The instruction is executed as show below in Figure 6-2.
        #
        NCT:    {
                    n:'Normalize and Count'
                    f:['NCT R1,R2'],
                    d:'11100xxx11101yyy'
                    e:(t,v) ->
                        # Zero all bits of R1
                        t.r(v.x).set32(0)
                        v2 = t.r(v.y).get32() >>> 0
                        if v2 == 0
                            t.psw.setCarry(0)
                            return
                        count = 0
                        # Shift left until bit 0 != bit 1
                        while count < 32
                            bit0 = (v2 >>> 31) & 1
                            bit1 = (v2 >>> 30) & 1
                            if bit0 != bit1
                                break
                            v2 = (v2 << 1) >>> 0
                            count++
                        t.r(v.y).set32(v2)
                        # Count goes in bits 0-15 (upper halfword) of R1
                        t.r(v.x).set32(count << 16)
                        t.psw.setCarry(1)
                }

        # SHIFT LEFT LOGICAL
        #
        #   The contents of general register R1 are shifted left, as specified
        # by the shift count Figure 6-1. Zeros are entered into the vacated low-
        # order bits of general register R1. Bits leaving the high-order bit
        # (bit 0 of general register R1) position are entered in the carry
        # indicator. (See indicators below.) Bits shifted out of the carry
        # indicator are lost. Only the contents of general register R1 are
        # changed.
        #
        # RESULTING CONDITION CODE
        #
        #   The code is not changed by this instruction.
        #
        # INDICATORS
        # 
        #   The carry indicator is set to one for each one, and to zero for
        # each zero, shifted left from the high-order position of general 
        # register R1. The overflow indicator is not changed by this 
        # instruction.
        #
        # PROGRAMMING NOTE
        #
        #   When the shift count n is greater than 31, then the result of the
        # shift of general register R1 is zero.
        #
        SLL:    {
                    n:'Shift Left Logical'
                    f:['SLL R1,Count']
                    d:'11110xxxdddddd00'
                    t:OPTYPE_SHFT
                    e:(t,v) ->
                        shiftCnt = t.g_SHIFT_CNT(v.hw1)
                        v1 = t.r(v.x).get32()
                        if shiftCnt >= 32
                            # Carry = last bit shifted out (bit 0 if shiftCnt==32, else 0)
                            if shiftCnt == 32
                                t.psw.setCarry(if v1 & 1 then 1 else 0)
                            else
                                t.psw.setCarry(0)
                            t.r(v.x).set32(0)
                        else if shiftCnt == 0
                            return
                        else
                            # Carry is set from each bit shifted out of bit 0
                            t.psw.setCarry(if v1 & (1 << (32 - shiftCnt)) then 1 else 0)
                            result = (v1 << shiftCnt) >>> 0
                            t.r(v.x).set32(result)
                }

        # SHIFT LEFT DOUBLE LOGICAL
        #
        #   The contents of the even/odd pair of general registers (R1 and
        # R1 (+) 1) are shifted left as a 64-bit register. The number of
        # positions shifted is specified by the shift count. Bits shifted out
        # of bit position zero, of general register R1 (+) 1, are entered into
        # bit position 31 of general register R1. Zeros are entered into the
        # vacated low-order bits of general register R1(+)1. Bits leaving the
        # high-order bit position (bit position 0 of general register R1) are
        # shifted into the carry indicator. Bits shifted out of the carry 
        # indicator are lost.
        #
        # RESULTING CONDITION CODE
        #
        #   The code is not changed by this instruction.
        #
        # INDICATORS
        #
        #   The carry indicator is set to one for each one, and to zero for 
        # each zero, shifted left from the high-order bit position of general
        # register R1. The overflow indicator is not changed by this 
        # instruction.
        #
        SLDL:   {
                    n:'Shift Left Double Logical'
                    f:['SLDL R1,Count']
                    t:OPTYPE_SHFT
                    d:'11111xxxdddddd00'
                    e:(t,v) ->
                        shiftCnt = t.g_SHIFT_CNT(v.hw1)
                        hi = t.r(v.x).get32() >>> 0
                        lo = t.r(v.x + 1).get32() >>> 0
                        if shiftCnt == 0
                            return
                        if shiftCnt >= 64
                            t.psw.setCarry(0)
                            t.r(v.x).set32(0)
                            t.r(v.x + 1).set32(0)
                        else if shiftCnt >= 32
                            # Carry from last bit shifted out of hi
                            s = shiftCnt - 32
                            if s == 0
                                t.psw.setCarry(if hi & 1 then 1 else 0)
                                t.r(v.x).set32(lo)
                            else
                                t.psw.setCarry(if lo & (1 << (32 - s)) then 1 else 0)
                                t.r(v.x).set32((lo << s) >>> 0)
                            t.r(v.x + 1).set32(0)
                        else
                            # Carry from last bit shifted out of hi position 0
                            t.psw.setCarry(if hi & (1 << (32 - shiftCnt)) then 1 else 0)
                            newHi = ((hi << shiftCnt) | (lo >>> (32 - shiftCnt))) >>> 0
                            newLo = (lo << shiftCnt) >>> 0
                            t.r(v.x).set32(newHi)
                            t.r(v.x + 1).set32(newLo)
                }

        # SHIFT RIGHT ARITHMETIC
        #
        #   The contents of general register R1 are shifted right the number of
        # places indicated by the shift count. Bits equal to the sign are 
        # entered into vacated high-order bit positions. Bits shifted out of bit
        # position 31 of general register R1 are lost.
        #
        # RESULTING CONDITION CODE
        #
        #   The code is not changed by this instruction.
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this 
        # instruction.
        #
        # PROGRAMMING NOTE
        #
        #   A shift right of n is equivalent to dividing the contents of 
        # general register R1 by 2**n.
        #
        SRA:    {
                    n:'Shift Right Arithmetic'
                    f:['SRA R1,Count']
                    d:'11110xxxdddddd01'
                    t:OPTYPE_SHFT
                    e:(t,v) ->
                        shiftCnt = t.g_SHIFT_CNT(v.hw1)
                        if shiftCnt == 0 then return
                        v1 = t.r(v.x).get32()
                        # Arithmetic right shift: sign bit fills vacated positions
                        if shiftCnt >= 32
                            result = if v1 & 0x80000000 then 0xffffffff else 0
                        else
                            result = v1 >> shiftCnt
                        t.r(v.x).set32(result)
                }
        # SHIFT RIGHT DOUBLE ARITHMETIC
        #
        #   The contents of an even/odd pair of general registers (R1 and 
        # R1 (+) 1) are shifted right as a 64-bit register. The number of
        # positions shifted is specified by the shift count. Bits shifted
        # out of bit position 31, of general register R1, are entered into
        # bit position 0 of general register R1 (+) 1. Bits equal to the sign
        # are enetered into vacated high-order bit positions. Bits shifted out
        # of bit position 31 of general register R1 (+) 1 are lost.
        #
        # RESULTING CONDITION CODE
        #
        #   The code is not changed by this instruction.
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this 
        # instruction.
        #
        SRDA:   {
                    n:'Shift Right Double Arithmetic'
                    f:['SRDA R1,Count']
                    d:'11111xxxdddddd01'
                    t:OPTYPE_SHFT
                    e:(t,v) ->
                        shiftCnt = t.g_SHIFT_CNT(v.hw1)
                        if shiftCnt == 0 then return
                        hi = t.r(v.x).get32()
                        lo = t.r(v.x + 1).get32() >>> 0
                        sign = if hi & 0x80000000 then 1 else 0
                        if shiftCnt >= 64
                            fill = if sign then 0xffffffff else 0
                            t.r(v.x).set32(fill)
                            t.r(v.x + 1).set32(fill)
                        else if shiftCnt >= 32
                            s = shiftCnt - 32
                            if s == 0
                                t.r(v.x + 1).set32(hi)
                            else
                                t.r(v.x + 1).set32(hi >> s)
                            t.r(v.x).set32(if sign then 0xffffffff else 0)
                        else
                            newLo = ((lo >>> shiftCnt) | (hi << (32 - shiftCnt))) >>> 0
                            newHi = hi >> shiftCnt
                            t.r(v.x).set32(newHi)
                            t.r(v.x + 1).set32(newLo)
                }

        # SHIFT RIGHT DOUBLE LOGICAL
        #
        #   The contents of an even/odd pair of general registers (R1 and
        # R (+) 1) are shifted right, and a 64-bit register. The number of
        # positions shifted is specified ny the shift count. Zeros are entered
        # into all vacated high-order bit positions. Bits shifted out of bit
        # position 31, of general register R1, are entered into bit position 0
        # of general register R (+) 1. Bits shofted out of bit position 31 of
        # general register R1 (+) 1 are lost.
        #
        #       The code is not changed by this instruction.
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this 
        # instruction.
        #
        SRDL:   {
                    n:'Shift Right Double Logical'
                    f:['SRDL R1,Count']
                    d:'11111xxxdddddd10'
                    t:OPTYPE_SHFT
                    e:(t,v) ->
                        shiftCnt = t.g_SHIFT_CNT(v.hw1)
                        if shiftCnt == 0 then return
                        hi = t.r(v.x).get32() >>> 0
                        lo = t.r(v.x + 1).get32() >>> 0
                        if shiftCnt >= 64
                            t.r(v.x).set32(0)
                            t.r(v.x + 1).set32(0)
                        else if shiftCnt >= 32
                            s = shiftCnt - 32
                            if s == 0
                                t.r(v.x + 1).set32(hi)
                            else
                                t.r(v.x + 1).set32(hi >>> s)
                            t.r(v.x).set32(0)
                        else
                            newLo = ((lo >>> shiftCnt) | (hi << (32 - shiftCnt))) >>> 0
                            newHi = hi >>> shiftCnt
                            t.r(v.x).set32(newHi)
                            t.r(v.x + 1).set32(newLo)
                }

        # SHIFT RIGHT LOGICAL
        #
        #   The contents of general register R1 are shifted right the number of
        # places indicated by the shift count. Zeros are entered into all vacated
        # high-order bit positions. Bits shifted out of bit position 31 of general 
        # register R1 are lost.
        #
        # RESULTING CONDITION CODE
        #
        #   The code is not changed by this instruction.
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this 
        # instruction.
        #
        SRL:    {
                    n:'Shift Right Logical'
                    f:['SRL R1,Count']
                    d:'11110xxxdddddd10'
                    t:OPTYPE_SHFT
                    e:(t,v) ->
                        shiftCnt = t.g_SHIFT_CNT(v.hw1)
                        if shiftCnt == 0 then return
                        v1 = t.r(v.x).get32() >>> 0
                        if shiftCnt >= 32
                            t.r(v.x).set32(0)
                        else
                            t.r(v.x).set32(v1 >>> shiftCnt)
                }

        # SHIFT RIGHT AND ROTATE
        #
        #   The contents of general register R1 are shifted right the number
        # of places indicated by the shift count. Bits shifted out of bit 
        # position 31 are entered into bit position 0. The general register
        # this becomes a circular register and no bits are lost. 
        #
        # RESULTING CONDITION CODE
        #
        #   The code is not changed by this instruction.
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this 
        # instruction.
        #
        SRR:    {
                    n:'Shift Right Rotate'
                    f:['SRR R1,Count']
                    d:'11110xxxdddddd11'
                    t:OPTYPE_SHFT
                    e:(t,v) ->
                        shiftCnt = t.g_SHIFT_CNT(v.hw1) % 32
                        if shiftCnt == 0 then return
                        v1 = t.r(v.x).get32() >>> 0
                        result = ((v1 >>> shiftCnt) | (v1 << (32 - shiftCnt))) >>> 0
                        t.r(v.x).set32(result)
                }

        # SHIFT RIGHT DOUBLE AND ROTATE
        #
        #   The contents of an even/odd pair of general registers (R1 and 
        # R1 (+) 1) are shifted right, as the 64-bit register. The number of
        # positions shifted is specified by the shift count. Bits shifted out
        # of bit position 31 of general register R1 are enetered into bit
        # position 0 of general register R1(+)1. Bits shifted out of bit 
        # position 31 of general register R1(+1) are entered into bit position
        # 0 of general register R1. Thus, the two registers become a single,
        # circular, 64-bit register, and no bits are lost.
        #
        # RESULTING CONDITION CODE
        # 
        #   The code is not changed by this instruction.
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this
        # instruction.
        #
        # PROGRAMMING NOTE
        #
        #   When the shift count equals 32, the contents of general register
        # R1 and R1 (+) 1 are exchanged.
        #
        SRDR:   {
                    n:'Shift Right Double Rotate'
                    f:['SRDR R1,Count']
                    d:'11111xxxdddddd11'
                    t:OPTYPE_SHFT
                    e:(t,v) ->
                        shiftCnt = t.g_SHIFT_CNT(v.hw1) % 64
                        if shiftCnt == 0 then return
                        hi = t.r(v.x).get32() >>> 0
                        lo = t.r(v.x + 1).get32() >>> 0
                        if shiftCnt >= 32
                            s = shiftCnt - 32
                            if s == 0
                                # Swap
                                t.r(v.x).set32(lo)
                                t.r(v.x + 1).set32(hi)
                            else
                                newHi = ((lo >>> s) | (hi << (32 - s))) >>> 0
                                newLo = ((hi >>> s) | (lo << (32 - s))) >>> 0
                                t.r(v.x).set32(newHi)
                                t.r(v.x + 1).set32(newLo)
                        else
                            newHi = ((hi >>> shiftCnt) | (lo << (32 - shiftCnt))) >>> 0
                            newLo = ((lo >>> shiftCnt) | (hi << (32 - shiftCnt))) >>> 0
                            t.r(v.x).set32(newHi)
                            t.r(v.x + 1).set32(newLo)
                }

        # AND
        #
        #   The logical product (AND), of the fullword second operand and the
        # contents of general register R1, is formed bit-by-bit. The result
        # replaces the contents of general register R1. The second operand is
        # not changed. The following table defines the AND operation.
        #
        #   AND
        #   Storage     1 1 0 0
        #   R1          1 0 1 0
        #   Result      1 0 0 0
        #
        # RESULTING CONDITION CODE
        #
        #   00  The result is zero
        #   11  The result is not zero
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this
        # instruction.
        #
        NR:     {
                    n:'AND'
                    f:['NR R1,R2'],
                    d:'00100xxx11100yyy'
                    e:(t,v) ->
                        v1 = t.r(v.x).get32()
                        v2 = t.r(v.y).get32()
                        result = v1 & v2
                        t.r(v.x).set32(result)
                        t.computeCClogical(result)
                }
        N:      {
                    n:'AND'
                    f:['N R1,D2(B2)','N R1,D2(X2,B2)']
                    d:'00100xxxddddddbb'
                    a:ADDR_FULLWORD
                    e:(t,v) ->
                        v1 = t.r(v.x).get32()
                        v2 = t.g_EAF(v)
                        result = v1 & v2
                        t.r(v.x).set32(result)
                        t.computeCClogical(result)
                }

        # AND HALFWORD IMMEDIATE
        #
        #   Instruction bits 16 through 31 are treated as immediate data. The
        # halfword immediate data is first developed into a fullword by 
        # appending 16 low-order zeros. The logical product (AND) of this
        # fullword operand and the contents of general register R2 is formed
        # bit-by-bit. The result replaces the contents of general register R2.
        # The immediate operand is not changed. The following table defines the
        # AND operation:
        #
        #   AND
        #   Immediate Data  1 1 0 0
        #   R2              1 0 1 0
        #   Result          1 0 0 0
        #
        # RESULTING CONDITION CODE
        #
        #   00  The result is zero
        #   11  The result is not zero
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this
        # instruction.
        #
        NHI:    {
                    n:'AND Halfword Immediate'
                    f:['NHI R2,Data']
                    d:'1011011011100yyy/I'
                    a:ADDR_HALFWORD
                    e:(t,v) ->
                        v1 = t.r(v.y).get32()
                        v2 = v.I << 16
                        result = v1 & v2
                        t.r(v.y).set32(result)
                        t.computeCClogical(result)
                }

        # AND IMMEDIATE WITH STORAGE
        #
        NIST:   {
                    n:'AND Immediate and Store'
                    f:['NIST D2(B2),Data']
                    d:'10110110ddddddbb/I'
                    a:ADDR_HALFWORD
                    e:(t,v) ->
                        v1 = v.I
                        v2 = t.g_EAH(v)
                        result = v1 & v2
                        t.s_EAH(v,result)
                        t.computeCClogical(result)
                }

        # AND TO STORE
        #
        NST:    {
                    n:'AND and Store'
                    f:['NST R1,D2(B2)','NST R1,D2(X2,B2)']
                    d:'00100xxx11111abb/X'
                    e:(t,v) ->
                        v1 = t.r(v.x).get32()
                        v2 = t.g_EAF(v)
                        result = v1 & v2
                        t.s_EAF(v,result)
                        t.computeCClogical(result)
                }

        # EXCLUSIVE OR
        #
        XR:     {
                    n:'Exclusive OR'
                    f:['XR R1,R2'],
                    d:'01110xxx11100yyy'
                    e:(t,v) ->
                        v1 = t.r(v.x).get32()
                        v2 = t.r(v.y).get32()
                        result = v1 ^ v2
                        t.r(v.x).set32(result)
                        t.computeCClogical(result)
                }
        X:      {
                    n:'Exclusive OR'
                    f:['X R1,D2(B2)','X R1,D2(X2,B2)']
                    d:'01110xxxddddddbb'
                    e:(t,v) ->
                        v1 = t.r(v.x).get32()
                        v2 = t.g_EAF(v)
                        result = v1 ^ v2
                        t.r(v.x).set32(result)
                        t.computeCClogical(result)
                }

        # EXCLUSIVE OR HALFWORD IMMEDIATE
        #
        XHI:    {
                    n:'Exclusive OR Halfword Immediate'
                    f:['XHI R2,Data']
                    d:'1011010011100yyy/I'
                    a:ADDR_HALFWORD
                    e:(t,v) ->
                        v1 = v.I << 16
                        v2 = t.r(v.y).get32()
                        result = v1 ^ v2
                        t.r(v.y).set32(result)
                        t.computeCClogical(result)
                }

        # EXCLUSIVE OR IMMEDIATE WITH STORAGE
        #
        XIST:   {
                    n:'Exclusive OR Immediate and Store'
                    f:['XIST D2(B2),Data']
                    d:'10110100ddddddbb/I'
                    a:ADDR_HALFWORD
                    e:(t,v) ->
                        v1 = v.I
                        v2 = t.g_EAH(v)
                        result = v1 ^ v2
                        t.s_EAH(v,result)
                        t.computeCClogical(result)
                }

        # EXCLUSIVE OR TO STORAGE
        #
        XST:    {
                    n:'Exclusive OR and Store'
                    f:['XST R1,D2(B2)','XST R1,D2(X2,B2)']
                    d:'01110xxx11111abb/X'
                    e:(t,v) ->
                        v1 = t.r(v.x).get32()
                        v2 = t.g_EAF(v)
                        result = v1 ^ v2
                        t.s_EAF(v,result)
                        t.computeCClogical(result)
                }

        # OR
        #
        OR:     {
                    n:'OR'
                    f:['OR R1,R2'],
                    d:'00101xxx11100yyy'
                    e:(t,v) ->
                        v1 = t.r(v.x).get32()
                        v2 = t.r(v.y).get32()
                        result = v1 | v2
                        t.r(v.x).set32(result)
                        t.computeCClogical(result)
                }
        O:      {
                    n:'OR'
                    f:['O R1,D2(B2)','O R1,D2(X2,B2)']
                    d:'00101xxxddddddbb'
                    e:(t,v) ->
                        v1 = t.r(v.x).get32()
                        v2 = t.g_EAF(v)
                        result = v1 | v2
                        t.r(v.x).set32(result)
                        t.computeCClogical(result)
                }

        # OR HALFWORD IMMEDIATE
        #
        OHI:    {
                    n:'OR Halfword Immediate'
                    f:['OHI R2,Data']
                    d:'1011001011100yyy/I'
                    a:ADDR_HALFWORD
                    e:(t,v) ->
                        v1 = v.I << 16
                        v2 = t.r(v.y).get32()
                        result = v1 | v2
                        t.r(v.y).set32(result)
                        t.computeCClogical(result)
                }

        # OR TO STORAGE
        #
        # The logical sum (OR) of the fullword second operand and the contents
        # of general register R1 is formed bit-by-bit. The result replaces the
        # second operand. The contents of general register R1 are not changed.
        # The following table defines the OR operation.
        #
        #       OR
        #     Storage   1100
        #     R1        1010
        #     Result    1110
        #
        # RESULTING CONDITION CODE
        #
        #   00  The result is zero
        #   11  The result is not zero.
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this 
        # instruction.
        #
        OST:    {
                    n:'OR and Store'
                    f:['OST R1,D2(B2)','OST R1,D2(X2,B2)']
                    d:'00101xxx11111abb/X'
                    e:(t,v) ->
                        v1 = t.r(v.x).get32()
                        v2 = t.g_EAF(v)
                        result = v1 | v2
                        t.s_EAF(v,result)
                        t.computeCClogical(result)
                }

        # SEARCH UNDER MASK
        #
        # A variable search of an array under control of fields in a mask for
        # specific bit patterns is performed. A two's complement 16-bit integer
        # count is contained in bits 0 through 15 of the general register 
        # specified by R2. (This must be a positive number for correct 
        # execution of this instruction.
        #
        #   The address of an array (Ai) is contained in bits 0 through 15 of
        # the even general register of the the event/odd pair specified by R1.
        # A twos' complement integer modifier is contained in bits 16 through
        # 31. After each Ai has been located bia bits 0 through 15, the 
        # modifier is added to the most-significant 16 bits of general register
        # R1. This result replaces the most-significant 16 bits. The modifier
        # is not changed. A 16-bit mask (M) is contained in bits 0 through 15
        # of the odd general register specified bu R1(+)001 while field values
        # (FV) are contained in bits 16 through 31.
        #
        #   The following equation is solved.
        #
        #       (Ai /\ M) (+) (FV /\ M)
        # 
        # where
        #
        #     i= 1,...,count
        #    /\= logical AND function
        #   (+)= logical Exclusive-OR function
        #
        #   Ai /\ M extracts bits selected by the mask out of the array.
        # FV /\ M extracts bits selected by the mask also. These latter bits
        # are compared with Ai/\M. If they are equal, the comparison continues
        # until the count is exhausted. The condition code reflects the result
        # of this operation.
        #
        #   If the comparison indicates an inequality, the instruction is
        # terminated with the address of the inequality operant located in
        # general register R1.
        #
        # RESULTING CONDITION CODE
        #
        #     00  All array items matched
        #     11  An array item miss-matched and general register R1 has the
        #         address where it failed.
        #
        # INDICATORS
        #
        #   The overflow and carry are not changed by this instruction.
        # 
        # PROGRAMMING NOTE
        #
        #   This is a variable length instruction execution. Care must be taken
        # to insure proper interrupt response by using sufficiently small count
        # values. In order to addure proper completion of the putaway routine,
        # the programmer must make sure that the count values do not exceed
        # eight.
        #
        #   The following flowchart indicates how this instruction is executed:
        #
        #
        #  
        SUM:    {
                    n:'Search Under Mask'
                    f:['SUM R1,R2'],
                    d:'10011xxx11101yyy'
                    e:(t,v) ->
                        # R2 bits 0-15: count (positive two's complement integer)
                        count = t.r(v.y).get32() >>> 16

                        # R1 even register: bits 0-15 = array address, bits 16-31 = modifier
                        evenReg = v.x & 0xfe  # ensure even
                        oddReg = evenReg | 1

                        r1Val = t.r(evenReg).get32()
                        arrayAddr = (r1Val >>> 16) & 0xffff
                        modifier = r1Val & 0xffff
                        if modifier & 0x8000 then modifier = modifier - 0x10000

                        # R1 odd register: bits 0-15 = mask, bits 16-31 = field values
                        r1OddVal = t.r(oddReg).get32()
                        mask = (r1OddVal >>> 16) & 0xffff
                        fieldValues = r1OddVal & 0xffff

                        maskedFV = fieldValues & mask

                        matched = true
                        curAddr = arrayAddr
                        for i in [0...count]
                            ai = t.ram.get16(t.g_EXPAND(curAddr))
                            maskedAi = ai & mask
                            if (maskedAi ^ maskedFV) != 0
                                # Mismatch found - store failure address in R1 even upper half
                                r1Val = (curAddr << 16) | (r1Val & 0xffff)
                                t.r(evenReg).set32(r1Val)
                                t.psw.setCC(3)
                                return
                            # Add modifier to array address for next iteration
                            curAddr = (curAddr + modifier) & 0xffff

                        # All matched - update R1 even with final address
                        r1Val = (curAddr << 16) | (r1Val & 0xffff)
                        t.r(evenReg).set32(r1Val)
                        t.psw.setCC(0)
                }

        # SET BITS
        #
        # Bits 16 through 31 of this instruction are treated as halfword
        # immediate data. The logical sum (OR) of the immediate data and the
        # halfword main storage operand is formed bit-by-bit. The result
        # replaces the halfword main storage operand.
        #
        # RESULTING CONDITION CODE
        #
        #   00 The result is zero
        #   11 The result is not zero.
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this
        # instruction.
        #
        # PROGRAMMING NOTE
        #
        #   The one bits in the halfword mask specify the bits of the halfword
        # second operand that are set one. The result replaces the halfword
        # second operand. The following table defines this instruction.
        #
        #                 SET BITS
        #                 Mask      1100
        #                 Storage   1010
        #                 Result    1110
        #
        SB:     {
                    n:'Set Bits'
                    f:['SB D2(B2),Data']
                    d:'10110010ddddddbb/I'
                    a:ADDR_HALFWORD
                    e:(t,v) ->
                        v1 = v.I
                        v2 = t.g_EAH(v)
                        result = v1 | v2
                        t.s_EAH(v,result)
                        t.computeCClogical(result)
                }

        # SET HALFWORD
        #
        # The halfword main storage operand is set to all ones.
        #
        # RESULTING CONDITION CODE
        #
        #   The condition code is not changed by this instruction.
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this
        # instruction.
        #
        # PROGRAMMING NOTE
        #
        #   This instruction is similar to the SET BITS instruction with the
        # mask (i.e., immediate data) equal to all ones.
        #
        SHW:    {
                    n:'Store Halfword to Word'
                    f:['SHW D2(B2)','SHW D2(X2,B2)']
                    d:'10100010ddddddbb'
                    a:ADDR_HALFWORD
                    e:(t,v) ->
                        result = 0xffff
                        t.s_EAH(v,result)
                }

        # TEST BITS
        #
        # Bits 16 through 31 of this instruction are treated as immediate data.
        # This halfword immediate data is logically tested with the halfword
        # main storage operand. A on ein the immediate data tests the 
        # corresponding bit in the halfword main storage operand. The halfword
        # main storage operand is not changed. The result of the test is given
        # in the condition code.
        #
        # RESULTING CONDITION CODE
        #
        #   00  Either the bits selected by the immediate data are zeros or the
        #       immediate data is all zeros
        #   11  The bits selected by the immediate data are mixed with zeros
        #       and ones
        #   01  The bits selected by the immediate data are all ones.
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this 
        # instruction.
        #
        # PROGRAMMING NOTE
        #
        #   The main storage location containing the halfword operand must not
        # be store protected. If the location is store protected, execution of
        # this instruction will result in a store protect violation interrupt.
        #
        TB:     {
                    n:'Test Under Mask'
                    f:['TB D2(B2),Data']
                    d:'10110011ddddddbb/I'
                    a:ADDR_HALFWORD
                    e:(t,v) ->
                        v1 = v.I
                        v2 = t.g_EAH(v)
                        testResult = v1 & v2
                        if testResult == 0
                            t.psw.setCC(0)
                        else if testResult == v1
                            t.psw.setCC(1)
                        else
                            t.psw.setCC(3)
                }

        # TEST REGISTER BITS
        #
        # Bits 16 through 31 of this instruction is treated as immediate data.
        # A fullword operand is formed by appending 16 low-order zeros.
        #
        #   A one, in this fullword, tests the corresponding bit in general
        # register R2. The corresponding bit position in general register R2
        # is not changed. The result of the test is given in the condition
        # code.
        #
        # RESULTING CONDITION CODE
        #
        #     00  Either the bits selected by the immediate data are all zeros
        #         or the immediate data is all zeros.
        #
        #     11  The bits selected buut the immediate data are mixed with
        #         zeros and ones.
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this 
        # instruction.
        #
        TRB:    {
                    n:'Test Register Bits'
                    f:['TRB R2,Data']
                    d:'1011001111100yyy/I'
                    e:(t,v) ->
                        v1 = v.I << 16
                        v2 = t.r(v.y).get32()
                        testResult = v1 & v2
                        if testResult == 0
                            t.psw.setCC(0)
                        else if testResult == v1
                            t.psw.setCC(1)
                        else
                            t.psw.setCC(3)
                }

        # TEST HALFWORD
        #
        # All bits in the halfword main storage operand are tested. This operand
        # is not changed. The result of the test is given in the condition code.
        #
        # RESULTING CONDITION CODE
        #
        #     00  The bits are all zeros
        #     11  The bits are mixed with zeros and ones
        #     01  The bits are all ones.
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this 
        # instruction.
        #
        # PROGRAMMING NOTE
        #
        #   This instruction is the same as the TEST BITS instruction with the
        # mask equal to all ones.
        #
        TH:     {
                    n:'Test Halfword'
                    f:['TH D2(B2)','TH D2(X2,B2)']
                    d:'10100011ddddddbb'
                    a:ADDR_HALFWORD
                    e:(t,v) ->
                        v1 = t.g_EAH(v)
                        testResult = v1
                        if testResult == 0
                            t.psw.setCC(0)
                        else if testResult == 0xffff
                            t.psw.setCC(1)
                        else
                            t.psw.setCC(3)
                }

        # ZERO BITS
        #
        # The logical complement of bits 16 through 31 of this instruction is
        # ANDed to the halfword main storage operand and is formed bit-by-bit.
        # The result replaces the halfword main storage operand.
        #
        # RESULING CONDITION CODE
        #
        #   00 The result is zero
        #   11 The result is not zero.
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this 
        # instruction.
        #
        # PROGRAMMING NOTE
        #
        #   The one bits in the halfword immediate data specify the bits of the
        # halfword main storage operand that are set zero. The result replaces
        # the halfword main storage operand. The following table defines this
        # instruction:
        #
        #       ZERO BITS
        #     Immediate Data  1100
        #     Storage         1010
        #     Result          0010
        #
        ZB:     {
                    n:'Zero and Add Byte'
                    f:['ZB D2(B2),Data']
                    d:'10110001ddddddbb/I'
                    a:ADDR_HALFWORD
                    e:(t,v) ->
                        v1 = v.I
                        v2 = t.g_EAH(v)
                        result = (~v1) & v2
                        t.s_EAH(v,result)
                        t.computeCClogical(result)
                }

        # ZERO REGISTER BITS
        #
        # First, the halfword immediate data is expanded to a fullword by
        # appending 16 low-order zeros. The logical complement of this 
        # fullword is then ANDed to the contents of general register R2. The
        # result replaces general register R2.
        #
        # RESULTING CONDITION CODE
        # 
        #     00  The result is zero
        #     11  The result is not zero.
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this
        # instruction.
        #
        # PROGRAMMING NOTE
        #
        #   The one bits in the halfword immediate data specify the bits in
        # the general register that are set zero. Bits 16 through 31 of general
        # register R2 are not changed by this instruction.
        #
        ZRB:    {
                    n:'Zero Register Bits'
                    f:['ZRB R2,Data']
                    d:'1011000111100yyy/I'
                    e:(t,v) ->
                        # Expand immediate data to fullword (append 16 low-order zeros)
                        mask = v.I << 16
                        # AND complement of mask with R2
                        regVal = t.r(v.y).get32()
                        result = (regVal & ~mask) >>> 0
                        t.r(v.y).set32(result)
                        t.computeCClogical(result)
                }

        # ZERO HALFWORD
        #
        # The halfword second operand is set to all zeros.
        #
        # RESULTING CONDITION CODE
        #
        #   The condition code is not changed by this instruction.
        #
        # INDICATORS
        #
        #   The overflow and carry indicator are not changed by this 
        # instruction.
        #
        # PROGRAMMING NOTE
        #
        #   This instruction is similar to the ZERO BITS instruction with the
        # mask equal to all ones.
        #
        ZH:     {
                    n:'Zero Halfword'
                    f:['ZH D2(B2)','ZH D2(X2,B2)']
                    d:'10100001ddddddbb'
                    a:ADDR_HALFWORD
                    e:(t,v) ->
                        t.s_EAH(v,0)
                }

        # ADD (LONG OPERANDS)
        #
        #   The second operand is added to the first operand, and then
        # the normalized sum is placed inthe first operand location.
        #
        #   The long 64-bit second operand is added with the contents
        # of the even/odd floating-point-register pair specified by
        # the even register R1. The normalized result is placed into
        # even/odd floating-point register R1.
        #
        #   Addition of two floating-point numbers consists of a 
        # characteristic comparison and a fraction addition. The
        # characteristics of the two operands are compared, and the
        # fraction with the smaller characteristic is right-shifted;
        # its characteristic is increased by one for each hexadecimal
        # digit of shift, until the two characteristics agree. The
        # fractions are then added algebraically for form an 
        # intermediate sum. If this increase causes a characteristic
        # overflow, an exponent-overflow exception is signaled, and a
        # program interruption occurs.
        #
        #   The long intermediate sum consists of 15 hexadecimal digits
        # and a possible carry.
        #
        #   After the addition, the intermediate sum is left-shifted as
        # necessary to form a normalized fraction; vacated low-order
        # digit positions are filled with zeros and the characteristic
        # is reduced by the amount of shift.
        #
        #   If normalization causes the characteristic to underflow,
        # characteristic and fraction are made zero, an exponent-
        # underflow exception exists, and a program interruption occurs
        # if the corresponding mask bit is one. If now left shift takes
        # place the intermediate sum is truncated to the proper fraction
        # length.
        #
        #   When the intermediate sum is zero and the significance mask
        # bit is one, a significance exception exists, and a program
        # interruption takes place. No normalization occurs; the
        # intermediate sum characteristic remains unchanged. When the
        # intermediate significance exception does not occur; rather,
        # the characteristic is made zero, yielding a true zero result.
        # Exponent underflow does not occur for a zero fraction.
        #
        #   Fist, the least-significant part of the intermediate sum
        # replaces the contents of floating-point register R1 (+) 001.
        # Then, the most significant part of the intermediate sum
        # replaces the contents of floating-point register R1.
        #
        #   The sign of the sum is derived by the rules of algebra. The
        # sign of a sum with zero result fraction is always positive.
        #
        # RESULTING CONDITION CODE
        #
        #   00  Result fraction is zero
        #   11  Result is less than zero
        #   01  Result is greater than zero
        #
        # PROGRAM INTERRUPTION
        #
        #   Significance
        #   Exponent Overflow
        #   Exponent Underflow
        #
        # PROGRAMMING NOTE
        #
        #   Interchanging the two operands in a floating-point addition
        # does not affect the value of the sum.
        #
        AEDR:   {
                    n:'Add Long'
                    f:['AEDR R1,R2'],
                    d:'01010xxx11101yyy'
                    e:(t,v) ->
                        v1 = FloatIBM.From64(t.f(v.x).get32(),t.f(v.x+1).get32())
                        v2 = FloatIBM.From64(t.f(v.y).get32(),t.f(v.y+1).get32())
                        result = addE(v1,v2)
                        if result.gFracBits().isZero()
                            t.psw.setCC(0)
                        else if result.gSign() < 0
                            t.psw.setCC(3)
                        else
                            t.psw.setCC(1)
                        t.f(v.x  ).set32(result.to64x())
                        t.f(v.x+1).set32(result.to64y())
                }
        AED:    {
                    n:'Add Long'
                    f:['AED R1,D2(B2)','AED R1,D2(X2,B2)']
                    d:'01010xxx11111abb/X'
                    a:ADDR_DBLEWORD
                    e:(t,v) ->
                        v1 = FloatIBM.From64(t.f(v.x).get32(),t.f(v.x+1).get32())
                        v2 = FloatIBM.From64(t.g_EAF(v), t.g_EAF(v,2))
                        result = addE(v1,v2)
                        if result.gFracBits().isZero()
                            t.psw.setCC(0)
                        else if result.gSign() < 0
                            t.psw.setCC(3)
                        else
                            t.psw.setCC(1)
                        t.f(v.x  ).set32(result.to64x())
                        t.f(v.x+1).set32(result.to64y())
                }

        # ADD (SHORT OPERANDS)
        #
        AER:    {
                    n:'Add Short'
                    f:['AER R1,R2'],
                    d:'01010xxx11100yyy'
                    a:ADDR_HALFWORD
                    e:(t,v) ->
                        v1 = FloatIBM.From32(t.f(v.x).get32())
                        v2 = FloatIBM.From32(t.f(v.y).get32())
                        result = addE(v1,v2)
                        if result.gFracBits().isZero()
                            t.psw.setCC(0)
                        else if result.gSign() < 0
                            t.psw.setCC(3)
                        else
                            t.psw.setCC(1)
                        t.f(v.x).set32(result.to32())
                }
        AE:     {
                    n:'Add Short'
                    f:['AE R1,D2(B2)','AE R1,D2(X2,B2)']
                    d:'01010xxxddddddbb'
                    a:ADDR_FULLWORD
                    e:(t,v) ->
                        v1 = FloatIBM.From32(t.f(v.x).get32())
                        v2 = FloatIBM.From32(t.g_EAF(v))
                        result = addE(v1,v2)
                        if result.gFracBits().isZero()
                            t.psw.setCC(0)
                        else if result.gSign() < 0
                            t.psw.setCC(3)
                        else
                            t.psw.setCC(1)
                        t.f(v.x).set32(result.to32())
                }

        # COMPARE (SHORT OPERANDS)
        #
        #   The first operand is compared with the second operand, and the 
        # condition code indicates the result.
        #
        #   Comparison is algebraic, taking into account the sign, fraction,
        # and exponent of each number. In short-precision, the low-order halves
        # of the floating-point registers are ignored. An equality is establised
        # by following the rules for normalized  floating-point subtraction.
        # When the intermediate sum, including a possible guard digit, is zero,
        # the operands are equal. Neither operand is changes as a result of the
        # operation.
        #
        #   Exponent overflow, exponent underflow, or lost significance cannot
        # occur.
        #
        # RESULTING CONDITION CODE
        #
        #   00  Operands are not equal
        #   11  First operand is low
        #   01  First operand is high
        #
        # PROGRAMMING NOTE
        #
        #   Numbers with zero fraction compare equal even when they differ in
        # sign or characteristic.
        #
        #   In comparing very small numbers (characteristic of 00 hexadecimal)
        # which would result in an exponent underflow in a subtract instruction,
        # the condition code will be set to 00 (equal) even through the number
        # is visually not equal. For example, a comparison of 00100000 and
        # 001FFFFF would yield a condition code of 00 (equal).
        #
        CER:    {
                    n:'Compare Short'
                    f:['CER R1,R2'],
                    d:'01001xxx11101yyy'
                    a:ADDR_HALFWORD
                    e:(t,v) ->
                        v1 = FloatIBM.From32(t.f(v.x).get32())
                        v2 = FloatIBM.From32(t.f(v.y).get32())
                        result = subE(v1,v2)
                        # XXX Handle Exponent overflow
                        if not result.gFracBits?
                            console.log("CER not result.gFracBits", result, v1, v2)
                        if result.gFracBits().isZero()
                            t.psw.setCC(0)
                        else if result.gSign() > 0
                            t.psw.setCC(1)
                        else
                            t.psw.setCC(3)
                }
        CE:     {
                    n:'Compare Short'
                    f:['CE R1,D2(B2)','x R1,D2(X2,B2)']
                    d:'01001xxx11111abb/X'
                    a:ADDR_FULLWORD
                    e:(t,v) ->
                        v1 = FloatIBM.From32(t.f(v.x).get32())
                        v2 = FloatIBM.From32(t.g_EAF(v))
                        result = subE(v1,v2)
                        if result.gFracBits().isZero()
                            t.psw.setCC(0)
                        else if result.gSign() > 0
                            t.psw.setCC(1)
                        else
                            t.psw.setCC(3)
                }

        # COMPARE (LONG OPERANDS)
        #   AP-101S
        #
        #   The long first operand is compared with the long second operand, 
        #   and the condition code indicates the result.
        #
        #   The long second operand is compares with the contents of the 
        # floating point register pair specified by regster R1.  Comparison
        # is algebraic, taking into account the sign, fraction, and exponent 
        # of each number.  An equality is establised by following the rules 
        # for normalized  floating-point subtraction. Neither operand is 
        # changed as a result of the operation.
        #
        #   Exponent overflow, exponent underflow, or lost significance cannot
        # occur.
        #
        # RESULTING CONDITION CODE
        #
        #   00  Operands are not equal
        #   11  First operand is less than the second operand
        #   01  First operand is greater than the second operand
        #
        # PROGRAMMING NOTE
        #
        #   Numbers with zero fraction compare equal even when they differ in
        # sign or characteristic.
        #
        # ANOMALY NOTE:
        #
        #   False indications of equality can occur in some cases when the
        # fractional portion of the operands differ by x'80 0000' after 
        # prealignment
        #
        # Prealignment shifts the fraction, of the oeprand with the smaller
        # exponent, right a number of hex digits equal to the absolute value of
        # the difference between the two exponents. The fraction being shifted
        # is left filled with zeroes. After prealignment, the comparison is 
        # based on 64 fractional bits (right filled with zeroes) and a possible 
        # guard bit.  Note that unnormalized numbers are not first normalized 
        # and are compared in the same manner as normalized numbers.
        #
        # Examples of failing cases (return false indications of equality)
        #
        # Operand 1:   423F FFFF 0000 1234
        # Operand 2:   423F FFFF 0080 1234
        # Absolute difference of OP2 and OP1 is .00 0000 0080 0000
        # Returns CC of 00 (equal); correct CC is 11 (OP1 < OP2)
        #
        # Operand 1:   BEFF FFFF FB07 6890
        # Operand 2:   BF10 0000 0030 7689
        # Absolute difference of OP2 and OP1 is .00 0000 0080 0000
        # Returns CC Of 00 (equal); correct CC is 01 (OP1 > OP2)
        #
        # Operand 1:   4010 0000 0000 1234
        # Operand 2:   3FFF FFFF F801 2340
        # Absolute difference of OP2 and OP1 is .00 0000 0080 0000
        # Returns CC of 00 (equal); correct CC is 01 (OP1 > OP2)
        #
        CEDR:   {
                    n:'Compare (Long Operands)'
                    f:['CEDR R1,R2'],
                    d:'00011xxx11101yyy'
                    a:ADDR_HALFWORD
                    e:(t,v) ->
                        v1 = FloatIBM.From64(t.f(v.x).get32(), t.f(v.x + 1).get32())
                        v2 = FloatIBM.From64(t.f(v.y).get32(), t.f(v.y + 1).get32())
                        result = subE(v1,v2)
                        # XXX Handle Exponent overflow
                        if not result.gFracBits?
                            console.log("CEDR not result.gFracBits", result, v1, v2)
                        if result.gFracBits().isZero()
                            t.psw.setCC(0)
                        else if result.gSign() > 0
                            t.psw.setCC(1)
                        else
                            t.psw.setCC(3)
                }
        CED:    {
                    n:'Compare (Long Operands)'
                    f:['CED R1,D2(B2)','CED R1,D2(X2,B2)']
                    d:'00011xxx11111abb/X'
                    a:ADDR_DBLEWORD
                    e:(t,v) ->
                        v1 = FloatIBM.From64(t.f(v.x).get32(), t.f(v.x + 1).get32())
                        v2hw1 = t.g_EAF(v)
                        v2hw2 = t.g_EAF(v, 2)
                        v2 = FloatIBM.From64(v2hw1, v2hw2)
                        result = subE(v1,v2)
                        if result.gFracBits().isZero()
                            t.psw.setCC(0)
                        else if result.gSign() > 0
                            t.psw.setCC(1)
                        else
                            t.psw.setCC(3)
                }

        # CONVERT TO FIXED-POINT
        #
        #   The second operand is normalized short 32-bit floating-point operand
        # using the sign magnitude floating-point representation. The second 
        # operand is converted to fixed-point by an unnormalization operation
        # in order to have its characteristic equal to a hexadecimal 44
        # [1000100 (2)]. It's sign bit is placed into the sign bit of general
        # register R1. Next, bits 8 through 39 of the intermediate value are
        # converted from sign-magnitude representaiton to two's complement and
        # placed into bits 1 through 31 of general register R1.
        #
        #   A convert overflow occurs when a floating-point second operand is 
        # not properly converted to fixed-point. This occurs when the char-
        # acteristic is larger than 44 hexadecimal 1000100 (2) or when bit 8 of
        # the intermediate value is a 1 unless the number is negative and bits
        # 9 through 31 are zero. The value of R1 is unchanged.
        #
        # CONDITION CODE
        #
        # 00 Bits 0 through 15 of the result in general register R1 is zero.
        # 11 Bits 0 through 15 of the result in general register R1 is negative.
        # 01 Bits 0 through 15 of the result in general register R1 is positive.
        #
        # ANOMALY NOTE
        #
        #   A floating-point value of 41100000 is converted to a fixed-point
        # 00010000 but gives a condition code of 00.
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed.
        #
        # PROGRAM INTERRUPTS
        #
        #   Convert overflow.
        #
        # PROGRAMMING NOTE
        #
        #   Refer to the CONVERT TO FLOATING instruction.
        #
        CVFX:   {
                    n:'Convert Float to Fixed'
                    f:['CVFX R1,R2'],
                    d:'00111xxx11100yyy'
                    e:(t,v) ->
                        v2 = FloatIBM.From32(t.f(v.y).get32())
                        # Unnormalize to characteristic 0x44 (exponent 4)
                        v2.unNormalizeToExp(4)
                        frac = v2.gFracBits()
                        intVal = ((frac.getHighBitsUnsigned() << 8) | ((frac.getLowBitsUnsigned() >>> 24) & 0xff)) >>> 0
                        if v2.gSign() < 0
                            intVal = ((~intVal) + 1) & 0xffffffff
                        t.r(v.x).set32(intVal)
                        # CC based on bits 0-15 of result
                        hi16 = intVal >>> 16
                        if hi16 == 0
                            t.psw.setCC(0)
                        else if intVal & 0x80000000
                            t.psw.setCC(3)
                        else
                            t.psw.setCC(1)
                }

        # CONVERT TO FLOATING-POINT
        #
        #   The second operand is a 32-bit two's complement number with its
        # binary point considered to be between bits 15 and 16. It is converted
        # to sign magnitude floating-point representation and placed into
        # floating-point register R1.
        #
        #   First, the sign bit of the fixed-point number is placed into the 
        # sign bit of the intermediate result shown below. Then, bits 0 through
        # 31 of the fixed-point number are converted from two's complement
        # representation to the magnitude of a sign-magnitude representation,
        # and the placed into bits 8 through 39 of the intermediate result. The
        # characteristic in bits 1 through 8 of the intermediate result is set
        # to 1000100 (2). Finally, the resulting intermediate number is 
        # normalized and only a short floating-point representation (bits 0
        # through 31) is developed and placed into the floating point register
        # R1.
        #
        # CONDITION CODE
        #
        #   00  The floating-point result is zero
        #   11  The floating-point result is negative.
        #   01  The floating-point result is positive (>0).
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this 
        # instruction.
        #
        # PROGRAM INTERRUPT
        #
        #   Significance
        #
        # PROGRAMMING NOTE
        #
        #   Since the significance interrupt will occur when converting a
        # zero, the programmer may want to mask this interrupt before doing a
        # CVFL by setting the significance mask (bit 32 of the PSW) to zero.
        # This, the significance interrupt would occur only for add or 
        # subtract floating, if not masked during the execution of those
        # instructions.
        #
        CVFL:   {
                    n:'Convert Fixed to Float Long'
                    f:['CVFL R1,R2'],
                    d:'00111xxx11101yyy'
                    e:(t,v) ->
                        # Get 32-bit two's complement value from general register R2
                        fixedVal = t.r(v.y).get32()
                        result = new FloatIBM()
                        magnitude = fixedVal
                        isNeg = fixedVal & 0x80000000
                        if isNeg
                            magnitude = ((fixedVal ^ 0xffffffff) + 1) >>> 0
                            result.sSign(-1)
                        # Place magnitude into fraction (bits 8-39 of intermediate)
                        result.data8[1] = (magnitude >>> 24) & 0xff
                        result.data8[2] = (magnitude >>> 16) & 0xff
                        result.data8[3] = (magnitude >>>  8) & 0xff
                        result.data8[4] = (magnitude       ) & 0xff
                        # Set characteristic to 1000100(2) = 0x44, exponent 4
                        result.sExp(4)
                        result.normalize()
                        # Store in floating-point register R1
                        t.f(v.x).set32(result.to32())
                        # CC: 00=zero, 01=positive, 11=negative
                        if magnitude == 0
                            t.psw.setCC(0)
                        else if isNeg
                            t.psw.setCC(3)
                        else
                            t.psw.setCC(1)
                }

        # DIVIDE (EXTENDED OPERANDS)
        #
        #
        #   The divident (the long first operand) is divided by the divisor
        # (the quasi-extended second operand) and replaced by the quotient.
        # No remainder is preserved.
        #
        #   The first operand is located in bits 0 through 63 of the even/odd
        # pair of floating point registers specified by R1. The first operand
        # is divided by the divisor. This quasi-extended divisor is limited to
        # 31 fraction bits. The quasi-extended divisor is formed from a long
        # floating-point operand by truncating the fraction portion of the 
        # second operand to 31 bits and then rounding into the 31st bit based 
        # upon the 32nd bit. The quasi-extended quotient replaces the dividend.
        # This quotient replaces bits 0 through 38 of the even/odd pair of 
        # floating-point registers specified by R1. (Bits 39 through 63 are
        # set to zero.)
        #
        #   A floating-point division consists of a characteristic subtraction
        # and a fraction division. The difference between the dividend and 
        # divisor characteristics plus 64 is used as an intermediate quotient
        # characteristic. The sign of the quotient is determined by the rules
        # of algebra.
        #
        #   Postnormalizing the intermediate quotient is never necessary with
        # both dividend and divisor being normalized, but a right-shift may
        # be called for. The intermediate quotient characteristic is adjusted
        # for the shifts. All dividend fraction digits participate in forming
        # the quotient, even if the normalized dividend fraction is larger than
        # the normalized divisor fraction. The quotient fraction is truncated
        # to 31 bits.
        #
        #   A program interruption for exponent overflow occurs when the final-
        # quotient characteristic is less than zero. The characteristic, sign,
        # and fraction are made zero, and the interruption occurs if the 
        # corresponding mask bit is one. Underflow is not signaled for the 
        # intermediate quotient or for the operand characteristics during
        # prenormalization.
        #
        #   When division by a true zero divisor is attempted, the operation
        # is suppressed. The divident remains unchanged, and a program 
        # interruption for floating-point divide occurs. When the dividend is
        # a true zero, the quotient fraction will be zero. The quotient sign
        # and characteristic are made zero, yielding a true zero result without
        # taking the program interruptions for exponent underflow and exponent
        # overflow. The program interruption for significance is never taken
        # for division.
        #
        #   When division is performed with un-normalized inputs, the 
        # un-normalized inputs interrupt will occur.
        #
        # CONDITION CODE
        #
        #   The code remains unchanged.
        #
        # PROGRAM INTERRUPTION
        #
        #   Exponent Overflow
        #   Exponent Underflow
        #   Floating-Point Divide Exception
        #   Unnormalized inputs
        #
        # PROGRAMMING NOTES
        #
        #   Fraction division proceeds as in fullword fixed-point division with
        # formation of a 32-bit signed quotient using a 32-bit signed divisor
        # and a 64-bit signed dividenc. The magnitude of the dividend fraction
        # is adjusted to ensure that the magnitude of the divisor exceeds the
        # magnitude of the dividend. The quotient is converted to a normal
        # extended precision floating point operand with low-order fraction bits
        # set to zero.,
        #
        #   Roudning of the quasi-extended divisor means adding the 32nd bit in
        # the fraction part of the floating-point operand to the 31st bit and
        # propagating all possible carriers.
        #
        #   There are several cases when the quotient fraction may exceed 31
        # bits. These situations occur with specific data patterns. The quotient
        # will be correct but the low-order fraction bits (39-63) will not be
        # set to zero as stated in paragraph two of the description.
        #
        # HARDWARE ANOMALY
        #
        #   1.  Due to an anomaly in the microcode implementation of this 
        #       instruction whereby internal status bit 21 is not cleared when
        #       there is a zero divident, the programmer must take steps to
        #       correct or avoid that condition. Usually, the best way to do
        #       this is to test the divident before executing the Divide and
        #       if it is zero, do not perform the Divide. Thus, status bit 21
        #       will never be left set equal to one. Another alternative would
        #       be to calculate the reciprocal of the divisor, then multiply
        #       the reciprocal instead of dividing.
        #
        #   2.  The extended form of the floating point divide (DED, DEDR) does
        #       not always produce a quotient which is accurate to 31 bits. The
        #       operands which would produce an incorrect result cannot be 
        #       precisely defined; however, the following observations can be
        #       made:
        #
        #       a.  If the divisor's fraction is less than hexadecimal 
        #           .8000 0000, then the quotient will be correct.
        #
        #       b.  If the divisor's fraction is greater than or equal to
        #           .8000 0000, then there exists a possibility of an 
        #           inaccurate quotient.
        #
        #       c.  The value of the divident does not affect the accuracy of
        #           the result.
        #
        #       d.  The inaccuracy can occur as early as bit 25 in the fraction
        #           (origin 0) and may be in any of the last seven bits, 25-31.
        #
        #       e.  The short precision divide (DE, DER) does not have this
        #           problem.
        #
        #       For those situations where accuracy to the full 31 bit precision
        #       is required, it is recommended that reciprocals of constants be
        #       stored and the extended form of the floating point multiply be
        #       used instead of the divide. For those conditions where the
        #       divisor is a variable, it will be necessary to use a work-around
        #       to preserve the accuracy.
        #
        #   3.  The divide instruction interrupt hierarchy for both long and
        #       short oeprands is given in the diagram below:
        #
        #       START
        #       -----
        #       1 o---------> Exponent Overflow (initial exponents test)
        #         |                         Code B
        #         |
        #       2 o---------> Floating Point Divide Exception
        #         |   |       (divisor is true zero) Code C
        #         |   |
        #         |   \-----> Divisor Not Normal  Code 6
        #         |
        #       3 o---------> Divident Not Normal  Code 6
        #         |
        #       4 o---------> Exponent Underflow (Not masked) Code 9
        #         |   |
        #         |   \-----> Exponent Overflow (final Quotient) Code B
        #         |
        #        \/
        #     Good Divide
        #
        DEDR:   {
                    n:'Divide Long'
                    f:['DEDR R1,R2'],
                    d:'00010xxx11101yyy'
                    a:ADDR_HALFWORD
                    e:(t,v) ->
                        v1 = FloatIBM.From64(t.f(v.x).get32(), t.f(v.x + 1).get32())
                        v2 = FloatIBM.From64(t.f(v.y).get32(), t.f(v.y + 1).get32())
                        if v2.gFracBits().isZero() then return
                        result = divE(v1, v2)
                        t.f(v.x).set32(result.to64x())
                        t.f(v.x + 1).set32(result.to64y())
                }
        DED:    {
                    n:'Divide Long'
                    f:['DED R1,D2(B2)','DED R1,D2(X2,B2)']
                    d:'00010xxx11111abb/X'
                    a:ADDR_DBLEWORD
                    e:(t,v) ->
                        v1 = FloatIBM.From64(t.f(v.x).get32(), t.f(v.x + 1).get32())
                        v2hw1 = t.g_EAF(v)
                        v2hw2 = t.g_EAF(v, 2)
                        v2 = FloatIBM.From64(v2hw1, v2hw2)
                        if v2.gFracBits().isZero() then return
                        result = divE(v1, v2)
                        t.f(v.x).set32(result.to64x())
                        t.f(v.x + 1).set32(result.to64y())
                }

        # DIVIDE (SHORT OPERANDS)
        #
        DER:    {
                    n:'Divide Short'
                    f:['DER R1,R2'],
                    d:'01101xxx11100yyy'
                    a:ADDR_HALFWORD
                    e:(t,v) ->
                        v1 = FloatIBM.From32(t.f(v.x).get32())
                        v2 = FloatIBM.From32(t.f(v.y).get32())
                        f2 = v2.toFloat()
                        if f2 == 0 then return
                        result = new FloatIBM(v1.toFloat() / f2)
                        t.f(v.x).set32(result.to32())
                }
        DE:     {
                    n:'Divide Short'
                    f:['DE R1,D2(B2)','DE R1,D2(X2,B2)']
                    d:'01101xxxddddddbb'
                    a:ADDR_FULLWORD
                    e:(t,v) ->
                        v1 = FloatIBM.From32(t.f(v.x).get32())
                        v2 = FloatIBM.From32(t.g_EAF(v))
                        f2 = v2.toFloat()
                        if f2 == 0 then return
                        result = new FloatIBM(v1.toFloat() / f2)
                        t.f(v.x).set32(result.to32())
                }

        # LOAD (LONG OPERANDS)
        #
        #   The long second operand is placed in the long first operand
        # register. The second operand is not changed.
        #
        #   First, bits 32 through 63 of the doubleword main storage operand
        # are loaded into floating-point register R1(+)001. Then, bits 0 through
        # 31 of the doubleword main storage operand are loaded into floating-
        # point register R1. Exponent overflow, exponent underflow, or lost
        # significance cannot occur.
        #
        # CONDITION CODE
        #
        #   00  The second operand is a true zero
        #   11  The second operand is negative
        #   01  The second operand is positive (>0)
        #
        LED:    {
                    n:'Load Long'
                    f:['LED R1,D2(B2)','LED R1,D2(X2,B2)']
                    d:'01111xxx11111abb/X'
                    a:ADDR_DBLEWORD
                    e:(t,v) ->
                        val = t.g_EAF(v)
                        t.f(v.x  ).set32(val)
                        t.f(v.x+1).set32(t.g_EAF(v,2))
                        if (val & 0x00ffffff) == 0
                            t.psw.setCC(0)
                        else if val & 0x80000000
                            t.psw.setCC(3)
                        else
                            t.psw.setCC(1)
                }
                 

        # LOAD (SHORT OPERANDS)
        #
        #   The second operand is placed in floating-point register R1. The
        # second operand is not changed. The overflow, underflow, and carry
        # indicators are not changed by this instruction.
        #
        # RESULTING CONDITION CODE
        #
        #   00  The second operand is a true zero
        #   11  The second operand is negative
        #   01  The second operand is positive (>0)
        #
        LER:    {
                    n:'Load Short Register'
                    f:['LER R1,R2'],
                    d:'01111xxx11100yyy'
                    a:ADDR_FULLWORD
                    e:(t,v) ->
                        val = t.f(v.y).get32()
                        t.f(v.x).set32(val)
                        if v.x % 2 == 0 then t.f(v.x + 1).set32(0)
                        if (val & 0x00ffffff) == 0
                            t.psw.setCC(0)
                        else if val & 0x80000000
                            t.psw.setCC(3)
                        else
                            t.psw.setCC(1)
                }
        LE:     {
                    n:'Load Short'
                    f:['LE R1,D2(B2)','LE R1,D2(X2,B2)']
                    d:'01111xxxddddddbb'
                    a:ADDR_FULLWORD
                    e:(t,v) ->
                        val = t.g_EAF(v)
                        t.f(v.x).set32(val)
                        if v.x % 2 == 0 then t.f(v.x + 1).set32(0)
                        if (val & 0x00ffffff) == 0
                            t.psw.setCC(0)
                        else if val & 0x80000000
                            t.psw.setCC(3)
                        else
                            t.psw.setCC(1)
                }

        # LOAD COMPLEMENT (SHORT OPERANDS)
        #
        #   The arithmetics complement of the fullword second operand replaces
        # the contents of floating-point register R1. The sign bit of the
        # second operand is inverted, while the characteristic, the fraction,
        # and register R1 (+) 001, are not changed. Indicators are unchanged
        # by this instruction.
        #
        # RESULTING CONDITION CODE
        #
        #   00  The result is a true zero
        #   11  The result is negative
        #   01  The result is positive (>0)
        #
        # PROGRAMMING NOTE
        #
        #   If this instruction is used to load a true zero, the condition code
        # is set to 11 indicating a negative result and the result will equal
        # hexadecimal 80000000. To avoid this condition, a test for zero 
        # operand should be made prior to the LECR and if the operand is zero,
        # branch around the LECR
        #
        LECR:   {
                    n:'Load Complement Short'
                    f:['LECR R1,R2'],
                    d:'01111xxx11101yyy',
                    e:(t,v) ->
                        v2 = t.f(v.y).get32()
                        result = (v2 ^ 0x80000000) >>> 0
                        t.f(v.x).set32(result)
                        if v.x % 2 == 0 then t.f(v.x + 1).set32(0)
                        # CC: sign bit determines negative, fraction zero = true zero
                        if result & 0x80000000
                            t.psw.setCC(3)
                        else if (result & 0x00ffffff) == 0
                            t.psw.setCC(0)
                        else
                            t.psw.setCC(1)
                }

        # LOAD FIXED REGISTER
        #
        #   The fullword contents of the floating-point register specified by
        # R2 is loaded into the general register specified by R1.
        #
        # RESULTING CONDITION CODE
        #
        #   The code is not changed by this instruction
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this
        # instruction.
        #
        LFXR:   {
                    n:'Load Fixed Register'
                    f:['LFXR R1,R2'],
                    d:'00100xxx11101yyy',
                    e:(t,v) ->
                        t.r(v.x).set32(t.f(v.y).get32())
                }

        # LOAD FLOATING IMMEDIATE
        #
        #   A floating-point immediate value is loaded into the 
        # floating-point register specified by R1.
        #
        #   The immediate values are 0., 1., 2., 3., 4., 5., 6., 7., 8., 9.,
        # 10., 11., 12., 13., 14., and 15.
        #
        #       OPX (bits 12, 13, 14, 15)       Immediate Values -> R1
        #       -------------------------       ----------------------
        #                (hex)                           (hex)
        #                  0                           4100 0000
        #                  1                           4110 0000
        #                  2                           4120 0000
        #                  3                           4130 0000
        #                  4                           4140 0000
        #                  5                           4150 0000
        #                  6                           4160 0000
        #                  7                           4170 0000
        #                  8                           4180 0000
        #                  9                           4190 0000
        #                  A                           41A0 0000
        #                  B                           41B0 0000
        #                  C                           41C0 0000
        #                  D                           41D0 0000
        #                  E                           41E0 0000
        #                  F                           41F0 0000
        #
        #   RESULTING CONDITION CODE
        #
        #       The code is not changed by this instruction
        #
        #   INDICATORS
        #
        #       The overflow and carry indicators are not changed by this
        #   instruction
        #
        #   PROGRAMMING NOTE
        #
        #       The result of a LFLZ with zero immediate value does not
        #   produce a true zero result.
        #
        LFLI:   {
                    n:'Load Float Long Immediate'
                    f:['LFLI R1,Value'],
                    d:'10001xxx1110yyyy',
                    e:(t,v) ->
                        t.f(v.x).set32(0x41000000 | (v.y<<20))
                }

        # LOAD FLOATING REGISTER
        #
        #   The fullword contents of the general register specified by R2 are
        # loaded into the floating-point register specified by R1.
        #
        # RESULTING CONDITION CODE
        #
        #   The code is not changed by this instruction.
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this 
        # instruction.
        #
        LFLR:   {
                    n:'Load Float Long Register'
                    f:['LFLR R1,R2'],
                    d:'00101xxx11101yyy',
                    e:(t,v) ->
                        t.f(v.x).set32(t.r(v.y).get32())
                }

        # MID-VALUE SELECT (SHORT OPERANDS)
        #
        #   The floating point registers specified by R1 and R1 (+) 001 each
        # contain a short (8/24) floating point operand. The third short 
        # floating point operand is located the main storage effective address.
        # The thrree operands are compared, and the mid-value operand is 
        # selected such that it is less than or eaqual to the maximum value
        # operand is selected such that it is less than or equal to the 
        # maximum value operand. This mid-valid operand is then placed in the
        # floating point register specified by R1. Both the main storage 
        # operand and the contents of Register R1 (+) 001 are not changed.
        #
        # RESULTING CONDITION CODE
        #
        #   The condition code is set as a result of executing this instruction,
        # but its valid is, in general, meaningless when this instruction is
        # used for mid-valid selection. However, see the Programming Note for
        # condition code settings when used as a limiter.
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this 
        # instruction.
        #
        # PROGRAMMING NOTES
        #
        #   This instruction can also be used as a limiter. The upper limit must
        # be placed in R1 (+) 001; the lower limit must be placed in the main
        # storage location. The input valud to be tested must be placed in R1.
        # The condition code will reflect the result of the instruction and, if
        # the input valid is outside the limit values. the appropriate limit
        # valud will be placed in R1.
        #
        #   When this instruction is used as a limiter, the condition code will
        # be set as follows:
        #
        # 00  Within Limits:     Lower Limit (Main Storage Operand)<=Operand
        #                        (Initial Contents of Register R1)<=Upper Limit
        #                        (Contents fo Register R1 (+) 001)
        # 01  Above Upper Limit: Initial R1 Operand > Upper Limit (R1 (+) 001)
        # 11  Below Lower Limit: Initial R1 Operand < Lower Limit (Main Storage
        #                        Operand)
        #
        #   As with all floating-point operations, normalized floating-point
        # numbers are required prior to execution. Also, the programmer is
        # responsible to insure that the upper limit is not equal to or less
        # than the lower limit. If these conditions are inadvertently setup,
        # the result is predictable in that the instruction will perform a
        # mid-value select.
        #
        MVS :   {
                    n:'Mid-Value Select'
                    f:['MVS R1,D2(B2)','MVS R1,D2(X2,B2)']
                    d:'01100xxx11111abb/X'
                    e:(t,v) ->
                        # R1 = input, R1+1 = upper limit, memory = lower limit
                        input = FloatIBM.From32(t.f(v.x).get32())
                        upper = FloatIBM.From32(t.f(v.x + 1).get32())
                        lower = FloatIBM.From32(t.g_EAF(v))
                        fi = input.toFloat()
                        fu = upper.toFloat()
                        fl = lower.toFloat()
                        if fi < fl
                            t.f(v.x).set32(lower.to32())
                            t.psw.setCC(3)
                        else if fi > fu
                            t.f(v.x).set32(upper.to32())
                            t.psw.setCC(1)
                        else
                            t.psw.setCC(0)
                }

        # MULTIPLY (EXTENDED OPERANDS)
        #
        #   The normalized product of multiplier (a quasi-extended second
        # operand) and multiplicand (a quasi-extended first operand) replaces
        # the multiplicand.
        #
        #   The first operand is located in bits 0 through 38 of the even/odd
        # pair of floating point register specified by the even register R1.
        # This operand is multiplied by the second operand. For the RR format,
        # the second operand is located in bits 0 through 38 of the even/odd
        # pair of floating-point registers specified by R2. (Bits 39 through 
        # 63 do not participate _except during rounding. See Programming Notes._
        # For the RS format, the second operand is located in bits 0 through 38
        # of the main storage extended operand. The extended product replaces
        # bits 0 through 63 of the even/odd pair of floating-point registers
        # specified by R1 and R1(+)001.
        #
        #   The multiplication of two floating-point numbers consists of a
        # characteristic addition and a fraction multiplication. (Participation
        # of multiplicand and multiplier fraction bits is limited to 31 bits,
        # except as used for rounding. See Programming Notes. Fraction multi-
        # plication proceeds as in fixed point full word multiplication, but
        # produces only a 62-bit fraction product.) The sum of the character-
        # istic of an intermediate product.
        #
        #   The sign of the product is determined by the rules of algebra.
        #
        #   The product fraction is normalized by post-normalizing the 62-bit
        # intermediate product, if necessary, then truncating the product to
        # 56 bits. The intermediate product characteristic is reduced by the
        # number of left-shifts.
        #
        #   Exponent overflow occurs if the final product characteristic exceeds
        # 127. The operation is terminated, and a program interruption occurs.
        # The overflow exception does not occur for an intermediate product
        # characteristic exceeding 128 when the final characteristic is brought
        # within range because of normalization.
        #
        #   Exponent underflow occurs if the final product characteristic is
        # less than zero. If the floating-point expondent underflow mask is a 
        # one, a program interruption occurs. If the mask bit is zero, the 
        # result is made a true zero.
        #
        #   When all digits of the intermediate product fraction are zero, the
        # product sign and characteristic are made zero, yielding a true zero
        # result. No interruption for exponent underflow or exponent overflow
        # can occur when the result fraction is zero. The program interruption
        # for lost significance is never taken for multiplication.
        #
        # CONDITION CODE
        #
        #   The code remains unchanged.
        #
        # PROGRAM INTERRUPTION
        #
        #   Exponent Overflow
        #   Exponent Underflow (occurs prior to zero operand test)
        #
        # PROGRAMMING NOTES
        #
        #   When either the multiplicant or multiplier is a true zero, the 
        # result is normally forced to a true zero without requiring the
        # hardware to enter the longer multiply-algorithm.
        #
        #   Rounding of both the multiplicant and multiplier occurs prior to
        # entering the actual multiply algorithm. The quasi-extended operands
        # are formed from a long floating-point operand by truncating the 
        # fraction portion to 31 bits and then rounding into the 31st bit based
        # upon the 32nd bit. (Rounding means adding the 32nd bit to the 31st bit
        # gating all possible carries.) Note that exponent overflow will be
        # caused by rounding a floating point number like 7FFFFFFFFF000000.
        #
        MEDR:   {
                    n:'Multiply Long'
                    f:['MEDR R1,R2'],
                    d:'00110xxx11101yyy'
                    e:(t,v) ->
                        v1 = FloatIBM.From64(t.f(v.x).get32(), t.f(v.x + 1).get32())
                        v2 = FloatIBM.From64(t.f(v.y).get32(), t.f(v.y + 1).get32())
                        result = mulE(v1, v2)
                        t.f(v.x).set32(result.to64x())
                        t.f(v.x + 1).set32(result.to64y())
                }
        MED:    {
                    n:'Multiply Long'
                    f:['MED R1,D2(B2)','MED R1,D2(X2,B2)']
                    d:'00110xxx11111abb/X'
                    a:ADDR_DBLEWORD
                    e:(t,v) ->
                        v1 = FloatIBM.From64(t.f(v.x).get32(), t.f(v.x + 1).get32())
                        v2hw1 = t.g_EAF(v)
                        v2hw2 = t.g_EAF(v, 2)
                        v2 = FloatIBM.From64(v2hw1, v2hw2)
                        result = mulE(v1, v2)
                        t.f(v.x).set32(result.to64x())
                        t.f(v.x + 1).set32(result.to64y())
                }

        # MULTIPLY (SHORT OPERANDS)
        #
        #   The normalized product of multiplier (the short second operand) and
        # multiplicant (the short first operand) replaces the multiplicant.
        MER:    {
                    n:'Multiply Short'
                    f:['MER R1,R2'],
                    d:'01100xxx11100yyy'
                    e:(t,v) ->
                        v1 = FloatIBM.From32(t.f(v.x).get32())
                        v2 = FloatIBM.From32(t.f(v.y).get32())
                        result = new FloatIBM(v1.toFloat() * v2.toFloat())
                        t.f(v.x).set32(result.to32())
                }
        ME:     {
                    n:'Multiply Short'
                    f:['ME R1,D2(B2)','ME R1,D2(X2,B2)']
                    d:'01100xxxddddddbb'
                    a:ADDR_FULLWORD
                    e:(t,v) ->
                        v1 = FloatIBM.From32(t.f(v.x).get32())
                        v2 = FloatIBM.From32(t.g_EAF(v))
                        result = new FloatIBM(v1.toFloat() * v2.toFloat())
                        t.f(v.x).set32(result.to32())
                }

        # SUBTRACT (LONG OPERANDS)
        #
        #   The long second operand is subtracted from the long first operand,
        # and the normalized difference is placed in the first operand location.
        #
        #   The long 64-bit second operand is subtracted from the contents of
        # floating-point register pair specified by the even register R1 and
        # R1(+)001. The normalized result is placed into floating-point 
        # registers R1 and R1(+)001.
        #
        #   The SUBTRACT (long operand) is similar to ADD (long operand), except
        # that the sign of the second operand is inverted before addition.
        #
        #   The sign of the difference is derived by the rules of algebra. The
        # sign of a difference with zero result fraction is always positive.
        #
        # RESULTING CONDITION CODE
        #
        #   00  Result fraction is zero
        #   11  Result is less than zero
        #   01  Result is greater than zero
        #
        # PROGRAM INTERRUPTIONS
        #
        #   Significance
        #   Exponent Overflow
        #   Exponent Underflow
        #
        SEDR:   {
                    n:'Subtract Long'
                    f:['SEDR R1,R2'],
                    d:'01011xxx11101yyy'
                    e:(t,v) ->
                        v1 = FloatIBM.From64(t.f(v.x).get32(),t.f(v.x+1).get32())
                        v2 = FloatIBM.From64(t.f(v.y).get32(),t.f(v.y+1).get32())
                        result = subE(v1,v2)
                        if result.gFracBits().isZero()
                            t.psw.setCC(0)
                        else if result.gSign() < 0
                            t.psw.setCC(3)
                        else
                            t.psw.setCC(1)
                        t.f(v.x  ).set32(result.to64x())
                        t.f(v.x+1).set32(result.to64y())
                }
        SED:    {
                    n:'Subtract Long'
                    f:['SED R1,D2(B2)','SED R1,D2(X2,B2)']
                    d:'01011xxx11111abb/X'
                    a:ADDR_DBLEWORD
                    e:(t,v) ->
                        v1 = FloatIBM.From64(t.f(v.x).get32(),t.f(v.x+1).get32())
                        v2 = FloatIBM.From64(t.g_EAF(v), t.g_EAF(v,2))
                        result = subE(v1,v2)
                        if result.gFracBits().isZero()
                            t.psw.setCC(0)
                        else if result.gSign() < 0
                            t.psw.setCC(3)
                        else
                            t.psw.setCC(1)
                        t.f(v.x  ).set32(result.to64x())
                        t.f(v.x+1).set32(result.to64y())
                }

        # SUBTRACT (SHORT OPERANDS)
        #
        #   The short second operand is subtracted from the short first operand,
        # and the normalized difference is placed in the first operand location.
        #
        #   The SUBTRACT (short operands) is similar to ADD (short operands), 
        # except that the sign of the second operand is inverted before 
        # addition.
        #
        #   The sign of the difference is derived by the rules of algebra. The
        # sign of a difference with zero result fraction is always positive.
        #
        # RESULTING CONDITION CODE
        #
        #   00  Result fraction is zero
        #   11  Result is less than zero
        #   01  Result is greater than zero
        #
        # PROGRAM INTERRUPTIONS
        #
        #   Significance
        #   Exponent Overflow
        #   Exponent Underflow
        #
        # PROGRAMMING NOTE
        #
        #   The technique used to clear a register by subtracting a floating-
        # point register from itself will work even through unnormalized numbers
        # are used in the subtract operation. The reason this works is that the
        # characteristics are compared and found to be equal. Thus, no shifting
        # takes place, the fractions are subtracted, and the result will be true
        # zero provided that the significance mask bit is zero.
        #
        SER:    {
                    n:'Subtract Short'
                    f:['SER R1,R2'],
                    d:'01011xxx11100yyy'
                    a:ADDR_FULLWORD
                    e:(t,v) ->
                        v1 = FloatIBM.From32(t.f(v.x).get32())
                        v2 = FloatIBM.From32(t.f(v.y).get32())
                        result = subE(v1,v2)
                        if result.gFracBits().isZero()
                            t.psw.setCC(0)
                        else if result.gSign() < 0
                            t.psw.setCC(3)
                        else
                            t.psw.setCC(1)
                        t.f(v.x).set32(result.to32())
                }
        SE:     {
                    n:'Subtract Short'
                    f:['SE R1,D2(B2)','SE R1,D2(X2,B2)']
                    d:'01011xxxddddddbb'
                    a:ADDR_FULLWORD
                    e:(t,v) ->
                        v1 = FloatIBM.From32(t.f(v.x).get32())
                        v2 = FloatIBM.From32(t.g_EAF(v))
                        result = subE(v1,v2)
                        if result.gFracBits().isZero()
                            t.psw.setCC(0)
                        else if result.gSign() < 0
                            t.psw.setCC(3)
                        else
                            t.psw.setCC(1)
                        t.f(v.x).set32(result.to32())
                }

        # STORE (LONG OPERANDS)
        #
        #   The long first operand is stored at the long second operand 
        # location. The first operation is not changed.
        #
        #   The first operand is located in the even/odd pair of floating-point
        # registers specified by the even register R1. First, bits 0 thrugh 31
        # of floating-point register R1(+)1 are stored into the second fullword
        # of the doubleword storage area starting with the second operand 
        # fullword address. Bits 0 through 31 of floating-point register R1 are
        # stored in the fullword specified by the second operand fullword 
        # address.
        #
        # CONDITION CODE
        #
        #   The code remains unchanged.
        #
        STED:   {
                    n:'Store Long'
                    f:['STED R1,D2(B2)','STED R1,D2(X2,B2)']
                    d:'00111xxx11111abb/X'
                    a:ADDR_DBLEWORD
                    e:(t,v) ->
                        t.s_EAF(v,t.f(v.x  ).get32(),0)
                        t.s_EAF(v,t.f(v.x+1).get32(),2)
                }

        # STORE (SHORT OPERANDS)
        #
        #   The contents of floating-point register R1 is stored at the second
        # operand location. The contents of R1 is not changed. The overflow and
        # carry indicators are not changed by this instruction.
        #
        # RESULTING CONDITION CODE
        #
        #   The code is not changed.
        #
        STE:    {
                    n:'Store Short'
                    f:['STE R1,D2(B2)','STE R1,D2(X2,B2)']
                    d:'00111xxxddddddbb'
                    a:ADDR_FULLWORD
                    e:(t,v) ->
                        v1 = t.f(v.x).get32()
                        result = v1
                        t.s_EAF(v,result)
                }

        # DETECT
        #
        #   The B2 field uniquely selects one of four special microprogram
        # routines, The selected micro-routine is executed. These routines are
        # used to perform built-in diagnostic functions to verify the proper
        # functioning of the CPU hardware.
        #
        #   Since the instruction is not intended for normal program usage,
        # DETECT has no mnemonic. This is a privileged operation and can only
        # be executed when the CPU is in the Supervisor state.
        #
        # PROGRAM INTERRUPTION
        #
        #   Privileged operation
        #
        _DETECT:{
                    n:'Diagnostic Detect'
                    f:[]
                    d:'11000000111110bb/0',
                    e:(t,v) ->
                        if not t.i_SUPER() then return
                        # Diagnostic built-in test - B2 field selects micro-routine
                        # Not simulated; no-op in emulator
                        return
                }

        # INSERT STORAGE PROTECT BITS
        #
        #   Bits 5 through 7, the M1 field, are decoded to set or reset the
        # protection bit associated with each halfword in main-storage as
        # specified by the EA. The contents of the specified location, however,
        # are not changed.
        # 
        #   The following defines the combinations of the M1 field and the
        # corresponding result:
        #
        #   M1 Field                        Result
        #   --------                        ------
        #     000       Reset the storage protection bit for the halfword second
        #               operand.
        #
        #     001       Reset the storage protection bits for both halfwords in
        #               the fullword second operand.
        #
        #     010       Set the storage protection bit for the halfword second
        #               operand.
        #
        #     011       Set the storage protection bits for both halfwords in
        #               the fullword second operand.
        # 
        #     100       Illegal
        #
        #     101       Illegal
        #
        #     110       Illegal
        #
        #     111       Illegal
        #
        #   This is a privileged operaion and can only be executed when the
        # CPU is in the supervisor state.
        #
        # RESULTING CONDITION CODE
        #
        #   The code is not changed by this instruction.
        #
        # INDICATORS
        #
        #   The carry and overflow indicators are not changed by this 
        # instruction.
        #
        # PROGRAM INTERRUPTIONS
        #
        #   Illegal operation
        #
        # PROGRAMMING NOTES
        #
        #   The low-order bit in the EA is used to specify the halfword when
        # M1 is 000 or 010. When M1 is 001 or 011, the low-order bit of the
        # EA should be 0 and will be ignored.
        #
        #   This instruction will always have halfword alignment and will be
        # excluded from automatic index alignment.
        #
        #   The illegal M1 field patterns (100, 101, 110, and 111) leave the
        # storage protect overrid bit set on which means that storage protected
        # locations can be written into without getting a store protect 
        # violation. The condition will occur until the next valid ISPB is
        # executed.
        #
        ISPB:   {
                    n:'Insert Storage Protect Bits'
                    f:['ISPB M1,D2(B2)','ISPB M1,D2(X2,B2)']
                    d:'11101xxx11111abb/X',
                    a:ADDR_HALFWORD
                    e:(t,v) ->
                        if not t.i_SUPER() then return
                        ea = t.g_EA(v)
                        m1 = (v.hw1 >>> 8) & 0x7  # bits 5-7
                        switch m1
                            when 0b000  # Reset protect bit for halfword at EA
                                t.ram.setStoreProtect(ea, false)
                            when 0b001  # Reset protect bits for both halfwords in fullword
                                fwAddr = ea & 0xfffe
                                t.ram.setStoreProtect(fwAddr, false)
                                t.ram.setStoreProtect(fwAddr + 1, false)
                            when 0b010  # Set protect bit for halfword at EA
                                t.ram.setStoreProtect(ea, true)
                            when 0b011  # Set protect bits for both halfwords in fullword
                                fwAddr = ea & 0xfffe
                                t.ram.setStoreProtect(fwAddr, true)
                                t.ram.setStoreProtect(fwAddr + 1, true)
                            else
                                # Illegal M1 (100-111): leaves store protect override set
                                # Per docs, no illegal operation interrupt, just override
                                t.storeProtectOverride = true
                }

        # LOAD PROGRAM STATUS
        #
        # Two fullwords starting at the location designated by the fullword
        # operand address replace the contents of the program status registers
        # on the CPU, as described under Program Status word. (Section 2,
        # Figure 2-19).
        #
        # RESULTING CONDITION CODE
        #
        #   The code is set or defined by the new PSW
        #
        # INDICATORS
        #
        #   The carry and overflow indicators are set or defined by the new
        #   PSW.
        #
        # PROGRAMMING NOTE
        #
        #   This is a privileged operation and can only by executed when the
        #   CPU is in the supervisor state. This instruction will always have
        #   halfword index alignment and will be excluded from automatic
        #   index alignment.
        #
        #     PSW bits 40 through 43 are not changed by the load operation.
        #
        # PROGRAM INTERRUPT
        #
        #   If PSW bits 19 and 20 are both set, a fixed-point overflow will
        #   occur.
        # 
        LPS:    {
                    n:'Load Program Status'
                    f:['LPS D2(B2)','LPS D2(X2,B2)']
                    d:'1100110111111abb/X'
                    a:ADDR_FULLWORD
                    e:(t,v) ->
                        if not t.i_SUPER() then return
                        eaw1 = t.g_EA(v)
                        eaw2 = eaw1 + 2
                        t.psw.load(t.ram.get32(eaw1),
                                   t.ram.get32(eaw2))
                }

        # MOVE HALFWORD OPERANDS
        #
        # Bits 0 through 15 of the general register specified by R1 contains
        # the destination address. (This is analogous to the RR Format Branch
        # Instructions except when bit 0 of general register R1 is a one; in 
        # that case the DSR in the current PSW is used.) Bits 16 through 31 of 
        # R1 contain a count of halfwords to be moved which must be greater than
        # zero. Since its representation uses a signed 2's complement integer
        # format, bit 16 (the sign bit) should be zero. A negative count (bit
        # 16 equals 1) indicates no data will be moved.
        #
        #     The content of the general register specified by R2 is as follows:
        #
        #   -----------------------------------------------------------------
        #   | |      Source Address         |Reserve|   Ignored     |  DSR  |
        #   | | | | | | | | | | | | | | | | |0|0|0|0| | | | | | | | |0| | | |
        #   -----------------------------------------------------------------
        #    0 1     4 5                  1516                    2728    31
        #
        # When bit 0 in R2 is zero, the source address uses an implied DSR of
        # all zeros. When bit 0 in R2 is one, the source address uses the DSR 
        # contained in bits 28-31.
        #
        #   Data (a block of contiguous halfwords) is moved a halfword at a time
        # from a source whose address is determined by concentrating the value
        # of the DSR in R2 with the Source Address in R2 and adding to it the
        # value of the count in bits 16 through 31 of R1 which is decremented
        # by one for each halfword moved. The data is moved to the destination
        # whose address is determined by adding to the operand address (Bits 0
        # through 15 of R1) the current value of the count. The move is 
        # completed when the count becomes zero. See Figure 9-1.
        #
        # RESULTING CONDITION CODE
        #
        #   The code is not changed.
        #
        # INDICATORS
        # 
        #   The overflow and carry indicators are not changed.
        #
        # PROGRAMMING NOTES
        #
        #   As in all instructions, main storage addresses (for source and
        # destination) must not be expected to cross 32K sector boundaries,
        # because this instruction will not modify the DSR's. If this is ever
        # attempted, the result is quite predictable in that operands will
        # be used from the first 32K main storage locations.
        #
        #   Because the MOVE HALFWORD instruction can execute for a long time,
        # it has been designed to be interruptible. The following interrupts
        # are typical of those interrupts which may break into the sequence
        # of moves before the instruction is finished:
        #
        #   1.  Initial power off signal (POI) from power supple.
        #   2.  Counter 1 or 2 interrupts.
        #
        # When MOVE HALFWORD ends prematurely due to any of the above pending
        # interrupts, the instruction counter will be decremented such that
        # when the interrupt is taken the old PSW contains the instruction
        # address of the move instruction. Also, when this instruction is
        # interrupted, the count in R1 is moditfied to reflect the number
        # of halfwords remaining to be moved. This will allow returning to the
        # move instruction so that it con continue to be executed from where
        # it was interrupted.
        #
        #   The programmer is encouraged to have both source and destination
        # address low-order bits set the same. This will enable the instruction
        # to accelerate execution by using fullword transfers for the majority
        # of the move.
        #
        # HARDWARE ANOMALY
        #
        #   External 1 Interrupt "Old PSW" can be invalid when any of the
        # following interrupts occur:
        #
        #   1.  I/O Interface Address Parity
        #   2.  DMA Parity
        #   3.  PCI Data Parity
        #
        MVH:    {
                    n:'Move Halfword Operands'
                    f:['MVH R1,R2'],
                    d:'01101xxx11101yyy',
                    dy: 'dsssssssssssssss0000________eee'
                    e:(t,v) ->
                        r1val = t.r(v.x).get32()
                        r2val = t.r(v.y).get32()
                        destAddr = (r1val >>> 16) & 0xffff
                        count = r1val & 0xffff
                        if count & 0x8000 then return # negative -> noop
                        srcAddr = (r2val >>> 16) & 0x7fff
                        if r2val & 0x80000000
                            dsr = r2val & 0xf
                            srcAddr = (dsr << 15) | srcAddr
                        if destAddr & 0x8000
                            destAddr = (t.psw.getDSR() << 15) | (destAddr & 0x7fff)
                        while count > 0
                            count--
                            hw = t.ram.get16(srcAddr + count)
                            t.ram.set16(destAddr + count, hw)
                        t.r(v.x).set32((destAddr << 16) | 0)
                }

        # SET PROGRAM MASK
        #
        #   The contents of bits 16 through 23 of general register R2 replace
        # the corresponding contents of the current program status registers
        # on the CPU as follows:
        #
        #   Bits 16 and 17 become the new condition code.
        #   Bit 18 become the new carry indicator.
        #   Bit 19 becomes the new overflow indicator.
        #   Bit 20 becomes the fixed-point overflow mask.
        #   Bit 21 (reserved)
        #   Bit 22 becomes the floating-point exponent underflow mask
        #   Bit 23 becomes the significance mask
        #
        # RESULT CONDITION CODE
        #
        #   The code is changed as defined above.
        #
        # INDICATORS
        #
        #       The carry, overflow, underflow, and significance indicators are
        # changed as defined above.
        #
        # PROGRAM INTERRUPT
        #
        #   If both bits 19 and 20 are set, the fixed-point overflow interrupt
        # will occur.
        #
        # PROGRAMMING NOTE
        #
        #   Bits 5 through 7 are not used by this instruction. It is recommended
        # that these bits be set to zero.
        #
        SPM:    {
                    n:'Set Program Mask'
                    f:['SPM R2'],
                    d:'1100100011101yyy',
                    e:(t,v) ->
                        r2val = t.r(v.y).get32()
                        # Bits 16-23 of R2 (IBM numbering) = bits 15-8 in JS
                        bits = (r2val >>> 8) & 0xff
                        t.psw.setCC((bits >>> 6) & 3)
                        t.psw.setCarry((bits >>> 5) & 1)
                        t.psw.setOverflow((bits >>> 4) & 1)
                        t.psw.setFixedPtOverflow((bits >>> 3) & 1)
                        # bit 2 reserved
                        t.psw.setExponentUnderflow((bits >>> 1) & 1)
                        t.psw.setSignificanceMask(bits & 1)
                }

        # SET SYSTEM MASK
        #
        #   The halfword second operand replaces bits 32 to 47 of the PSW.
        # This is privileged operation and can only by executed when the CPU
        # is in the supervisor state.
        #
        # RESULTING CONDITION CODE
        #
        #   The code is not changed by this instruction.
        #
        # INDICATORS
        #
        #   The carry and overflow indicators are not changed by this 
        # instruction.
        #
        # PROGRAMMING NOTE
        #
        #   Bits 5 through 7 are not used by this instruction. It is 
        # recommended that these bits be set to zero.
        #
        SSM:    {
                    n:'Set System Mask'
                    f:['SSM D2(B2)','SSM D2(X2,B2)']
                    d:'1000100011111abb/X',
                    e:(t,v) ->
                        if not t.i_SUPER() then return
                        hwVal = t.g_EAH(v)
                        # Replace bits 32-47 of PSW (upper halfword of PSW2)
                        psw2 = t.psw.psw2.get32()
                        psw2 = (hwVal << 16) | (psw2 & 0xffff)
                        t.psw.psw2.set32(psw2)
                }

        # STACK CALL
        #
        #   This instruction for calling subroutines automatically controls
        # saving bits 0 through 31 of the current PSW, the 8 general registers
        # and programmer's temporary work space in main storage. When the Stack
        # Call (SCAL) instruction is to be used, or the corresponding Stack
        # Return (SRET), general register R1 must contain a Stack Status
        # Descriptor word (SSD), as follows:
        #
        #   -----------------------------------------------------------------
        #   |               PTR             |              INC              |
        #   | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | |
        #   -----------------------------------------------------------------
        #    0                            1516                            31
        #
        #   First a branch address is computed. A save area address on the 
        # stack is computed from values in the SSD in R1 as:
        #
        #   SA = PTR + INC
        #
        # (This save area address must be an even boundary halfword address.)
        # Then the first two halfwords of the current PSW, and eight GPRs
        # automatically stored in the 18 halfwords beginning at location SA.
        #
        #   The SSD in R1 is now updated, as:
        #
        #   PTR = SA;
        #   INC = 18.
        #
        #   Finally, the next instruction is taken from the branch address.
        # This is essentially a BAL instruction which provides an automatic
        # call stack function.
        #
        # PROGRAMMING NOTE
        #
        #   PTR is a normal 16-bit address which is the location of a particular
        # place in the stack. (The stack utilizes a variable-length portion of
        # contiguous storage.) INC represents the number of halfwords which have
        # currently been used in the stack beyond PTR. Since its representation
        # uses a signed 2's complement integer format, its sign bit should be 
        # zero. See Figure 9-2.
        #
        #   "When SCAL is executed, the new stack save address is calculated 
        # from PTR_INC, (SA), and then the current PSW and eight general 
        # registers are automatically saved in the new stack saved area pointed
        # to by SA, so that the stack now appears as in Figure 9-3. Then the
        # PTR in R1 is updated to the value in SA and INC set at 18.
        #
        #   The programmer is free to use additional space in the stack, by
        # simply using R1 as a base, and an offset which is greater than 18
        # (to avoid destroying the saved GPR contents). However, this
        # additional information will be lost if he issues another SCAL without
        # specifically adjusting INC in R1 to include this new space.
        #
        #   When SRET is executed, the first 2 halfwords of the PSW and the 
        # eight GPRs are automatically loaded from the save area at location
        # PTR (in R1). Note that this restores R1 to contain the SSD it had
        # just prior to the last SCAL, which means that the stack is 
        # automatically restored to the state of Figure 9-2.
        #
        #   Refer to STACK RETURN.
        #
        # HARDWARE ANOMALY
        #
        #   External 1 interrupt "Old PSW" can be invalid when any of the 
        # following interrupts occur:
        #
        #   1.  I/O Interface Address Parity
        #   2.  DMA DATA Parity
        #   3.  PCI Data Parity
        #
        # PROGRAM INTERRUPTION
        #
        #   Specification
        #   Protection
        #
        SCAL:   {
                    n:'Stack Call'
                    f:['SCAL R1,D2(B2)','SCAL R1,D2(X2,B2)']
                    d:'11010xxx11111abb/X',
                    a:ADDR_HALFWORD
                    t:OPTYPE_BRCH
                    e:(t,v) ->
                        # Compute branch address first
                        branchAddr = t.g_EA(v)
                        # Get SSD from R1: PTR (bits 0-15), INC (bits 16-31)
                        r1val = t.r(v.x).get32()
                        #console.log "SCAL", v
                        #console.log "SCAL INIT R1=#{t.r(v.x).get32().asHex(8)}"
                        #console.log "SCAL PSW=#{t.psw.psw1.get32().asHex(8)}"
                        ptr = (r1val >>> 16) & 0xffff
                        inc = r1val & 0xffff
                        sa = (ptr + inc) & 0xffff
                        #console.log "SCAL SA=#{sa.asHex(8)}"
                        # Save PSW1 (first 2 halfwords) at SA
                        t.ram.set16(sa, t.psw.psw1.get32() >>> 16)
                        t.ram.set16(sa + 1, t.psw.psw1.get32() & 0xffff)
                        # Save 8 GPRs at SA+2 through SA+17
                        for i in [0..7]
                            regVal = t.r(i).get32()
                            t.ram.set16(sa + 2 + i * 2, regVal >>> 16)
                            t.ram.set16(sa + 2 + i * 2 + 1, regVal & 0xffff)
                        # Update SSD: PTR = SA, INC = 18
                        t.r(v.x).set32((sa << 16) | 18)
                        #console.log "SCAL UPDT R1=#{t.r(v.x).get32().asHex(8)}"
                        # Branch
                        t.psw.setNIA(branchAddr)
                }

        # STACK RETURN
        #
        #   When SCAL is used to call a subroutine, the complementary branch
        # instruction SRET is used to leave the calling subroutine and return to
        # the conditions prior to the last SCAL. This is a conditional branch
        # instruction in the RR format which provides the first two halfwords
        # of the PSW and restores the registers (GPR's) to the same state as
        # existed at the time of the SCAL.
        #
        #   The instruction execution first matches the M1 field against the
        # condition code to determine if the branch should be taken. If the
        # branch should not be taken, the instruction terminates at this point.
        # The remaining description applies when the branch should occur.
        #
        #   The stack pointer address, PTR, is located in bits 0 through 15 of
        # the general register specified by R2. (This address must be an even
        # boundary halfword address.) The first two halfwords of the stack are
        # moved into the active PSW. Next, all eight general purpose registers 
        # are loaded from the current stack save beginning at location PTR+2 as
        # specified in R2. Finally, instruction execution continues from the
        # address indicated by the active PSW.
        #
        # CONDITION CODE
        #
        #   The value in the corresponding field is loaded from the stack.
        #
        # INDICATORS
        #
        #   The value in the corresponding field is loaded from the stack.
        #
        # PROGRAMMING NOTES
        #
        #   The following notes are intended to amplify and clarify the use of
        # the stack and extended call facility.
        #
        #   o Since the stack is located in main store, any area of the stack
        #     can be accessed by standard addressing techniques (i.e., using R1
        #     as a base).
        #
        #   o While the primary purpose of the stack is automatic register 
        #     saving and restoring, it also provides automatic allocation and
        #     de-allocation of temporary work space, a function often required
        #     for efficient use of storage, and for use of reentrant programs.
        #     Note that the INC value in the SSD does not have to modified to
        #     use this work space; simply addressing relative to the base in R1
        #     allows this. The INC value only nees to be adjusted if the 
        #     information in the stack space needs to be preserved during a
        #     subsequent SCAL.
        #
        #   o The total stack space (i.e., the space taken up by the total stack
        #     at any given time) is variable. It grows and shrinks as a function
        #     of the depth of the call tree and the amount of workspace used by
        #     the variable programs. Howefver, in the overall data structure of
        #     the total application, there must inevitably be a fixed limit on
        #     the amount of main store which can be allocated to the stack. 
        #     Such limit would presumably be based on either statistics of usage
        #     plus a safety factor, or else on a detailed analysis of the usage
        #     of all possible call chains. In both cases (the latter as an error
        #     detection mechanism) it is important to have some mechanism to 
        #     stop the call chain if through some peculiar circumstances the
        #     stack should exceed its allocated space. Unfortunately, there
        #     does not appear to be any fool-proof scheme. However, most such
        #     situations would be caught by appending a few words at the end of
        #     the allocated space which have the store protect bit on. Any
        #     attempt to store into the stack beyond its limit would result in
        #     a protection violation and interrupt.
        #
        #   o Since the PSW and the eight general purpose registers are auto-
        #     matically restored on SRET, it is not possible to return results
        #     directly to the calling program in the registers. Rather, the 
        #     value to be returned in a register must be stored into the
        #     appropriate slot in the general purpose register save area in the
        #     stack. Then, when the registers are restored, the calling program
        #     will, in fact, find the value in the register. At the same time,
        #     additional values can be returned to the calling program in the
        #     work space in the stack, since the calling program can access that
        #     space by addressing relative to the base in R1 (SCAL). (There 
        #     must, of course, be an agreed-upon convention as to the specific
        #     location in the work space.) Note--the floating-point registers
        #     are not affected by SCAL and SRET so variables can be passed in
        #     these registers.
        #
        # HARDWARE ANOMALY
        #
        #   External 1 interrupt "Old PSW" can be invalid when any of the 
        # following interrupts occur:
        #
        #   1.  DMA Store Protect
        #   2.  DMA Address Specification
        #   3.  I/O Interface Address Parity
        #   4.  DMA Data Parity
        #   5.  PCI Data Parity
        #
        SRET:   {
                    n:'Stack Return'
                    f:['SRET M1,R2'],
                    d:'10010xxx11101yyy',
                    e:(t,v) ->
                        # Test M1 against CC (same as BCR)
                        m1 = v.x
                        cc = t.psw.getCC()
                        if not ((m1 & 4 and cc == 0) or (m1 & 2 and cc == 3) or (m1 & 1 and cc == 1))
                            return
                        # Get PTR from R2 (bits 0-15)
                        #console.log "SRET R= #{v.y} PTR=#{t.r(v.y).get32().asHex(8)}"
                        ptr = (t.r(v.y).get32() >>> 16) & 0xffff
                        #console.log "PTR=#{ptr}"
                        # Load PSW1 from stack at PTR
                        #console.log "HI=#{t.ram.get16(ptr).asHex()} LO=#{t.ram.get16(ptr+1).asHex()}"
                        psw1hi = t.ram.get16(ptr)
                        psw1lo = t.ram.get16(ptr + 1)
                        newPsw1 = (psw1hi << 16) | psw1lo
                        #console.log "SRET new PSW=#{newPsw1.asHex(8)}"

                        # Load 8 GPRs from stack at PTR+2
                        for i in [0..7]
                            hi = t.ram.get16(ptr + 2 + i * 2)
                            lo = t.ram.get16(ptr + 2 + i * 2 + 1)
                            t.r(i).set32((hi << 16) | lo)
                        # Restore PSW1 (sets NIA, CC, indicators)
                        t.psw.psw1.set32(newPsw1)
                }

        # SUPERVISOR CALL
        #
        # This instruction causes an interruption and program status word 
        # switch. As a result of this instruction, the interrupt code for the
        # stored program status is equal to the 16-bit effective address. This
        # is the only way to enter the supervisor state from the program state.
        #
        # RESULING CONDITION CODE
        #
        #   The condition code in the stored PSW is not changed by this 
        #  instruction.
        #
        # INDICATORS
        #
        #   The overflow and carry indicators in the stored PSW are not 
        # changed by this instruction.
        #
        # PROGRAMMING NOTE
        #
        #   The new PSW sets or defines the condition code, overflow indicator,
        # and carry indicator as well as all other bits in the new PSW.
        #
        SVC:    {
                    n:'Supervisor Call'
                    f:['SVC D2(B2)','SVC D2(X2,B2)']
                    d:'1100100111111abb/X',
                    a:ADDR_HALFWORD
                    e:(t,v) ->
                        ea = t.g_EA(v)
                        # Delegate to HalUCP for SVC interception (SEND ERROR, halt, etc.)
                        # Pass R1 (program data block pointer) so HalUCP can detect SVC 0
                        # which is generated as SVC 0(R1) — i.e. EA == R1
                        r1 = t.r(1).get32()
                        if t.halUCP?.handleSVC(ea, r1)
                            return
                        # Standard SVC: save PSW, load new PSW from interrupt vector
                        t.psw.setIntCode(ea)
                        t.ram.set32(0x58,t.psw.psw1.get32())
                        t.ram.set32(0x5a,t.psw.psw2.get32())
                        t.psw.load(t.ram.get32(0x5c),
                                   t.ram.get32(0x5e))
                }

        # TEST AND SET
        #
        #   Bits in the halfword second operand are tested to set the condition
        # code, and the second operand is set to all ones.  No other access to
        # this location is permitted between the fetch and the storing of all
        # ones.
        #
        # RESULTING CONDITION CODE
        #
        #     00  The bits are all zeros
        #     11  The bits are mixed with zeros and ones
        #     01  The bits are all ones.
        #
        # INDICATORS
        #
        #   The carry and overflow indicators are not changed by this 
        # instruction.
        #
        # PROGRAMMING NOTE
        #
        #   TS can be used for the controlling and sharing of a common sotrage
        # area by more than one program. To accomplish this, a halfword can be
        # designated as control. The desired interlock can be achieved by 
        # establishing a program convention in which a zero halfword indicates
        # that the common area is available, but a one means that the area is
        # being used. Each using program then must examine this halfword by 
        # means of a Test and Set before making access to the common area. If 
        # the test sets the condition code to 00, the area is available for use;
        # if it sets the condition code either 01 or to 11, the area cannot be
        # used. Because Test and Set permits no access to the test halfword be-
        # tween the moment of fetching (for testing) and the moment of storing
        # all ones (setting), the possibility is eliminated of a second program
        # testing the halfword before the first program is able to reset it.
        # Selective bits can be tested by using the TEST AND SET BITS 
        # instruction.
        #
        #   Bits 5 through 7 are not used by this instruction. It is recommended
        # that these bits be set to zero.
        #
        TS:     {
                    n:'Test and Set'
                    f:['TS D2(B2)','TS D2(X2,B2)']
                    d:'1011100011111abb/X',
                    e:(t,v) ->
                        ea = t.g_EA(v)
                        value = t.ram.get16(ea)
                        # Test: set CC based on current contents
                        if value == 0
                            t.psw.setCC(0)
                        else if value == 0xffff
                            t.psw.setCC(1)
                        else
                            t.psw.setCC(3)
                        # Set: store all ones
                        t.ram.set16(ea, 0xffff)
                }

        # TEST AND SET BITS
        #
        #   Bits 16 through 31 of this instruction are treated as halfword 
        # immediate data. The immediate data is logically tested with the 
        # halfword second operand. The logical sum (OR) of the immediate data 
        # and the halfword second operand is formed bit-by-bit. The result
        # replaces the halfword second operand. No other access to this location
        # is permitted between the fetching of the operand and the storing of
        # the result.
        #
        #
        # RESULTING CONDITION CODE
        #
        #   00  Either the bits selected by the immediate data are zeros or the
        #       immediate data is all zeros
        #   11  The bits selected by the immediate data are mixed with zeros and
        #       ones
        #   01  The bits selected by the immediate data are all ones.
        #
        # INDICATORS
        # 
        #   The overflow and carry indicators are not changed by this 
        # instruction.
        #
        # PROGRAMMING NOTE
        #
        #   The one bits in the halfword mask specify the bits of the halfword
        # second operand that are set one. The result replaces the halfword
        # second operand. The following table defines this instruction.
        #
        #               TEST AND SET
        #                   BITS
        #               ------------  ---------
        #                  Mask        1 1 0 0
        #                  Storage     1 0 1 0
        #                  Result      1 1 1 0
        #
        TSB:    {
                    n:'Test and Set Bits'
                    f:['TSB D2(B2),Data']
                    d:'10110111ddddddbb/I',
                    a:ADDR_HALFWORD
                    e:(t,v) ->
                        mask = v.I
                        ea = t.g_EA(v)
                        value = t.ram.get16(ea)
                        # Test: check bits selected by mask
                        selected = value & mask
                        if mask == 0 or selected == 0
                            t.psw.setCC(0)
                        else if selected == mask
                            t.psw.setCC(1)
                        else
                            t.psw.setCC(3)
                        # Set: OR mask with operand
                        t.ram.set16(ea, value | mask)
                }


        #
        # LOAD DSE MULTIPLE
        #   (AP-101S sect.9.13)
        #   The four Data Sector Extensions (DSE) corresponding to R0-R3 of the current register
        #   set are initialized from the fullword second operand.
        #
        #   The format of the fullword second operand is:
        #
        #   -----------------------------------------------------------------
        #   |0 0 0 0| R0DSE |0 0 0 0| R1DSE |0 0 0 0| R2DSE |0 0 0 0| R3DSE |
        #   | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | |
        #    0     3 4     7 8     1 1     1 1     1 2     2 2     2 2     3
        #                          1 2     5 6     9 0     3 4     7 8     1
        #
        #   PROGRAMMING NOTES:
        #   Bits 5 through 7 are not used by this instruction.  These bits should be set to zero
        #   as shown above and considered as an op code extension.
        #
        LDM:    {
                    n:'Load Data Memory'
                    f:['LDM D2(B2)','LDM D2(X2,B2)']
                    d:'0110100011111abb/X'
                    e:(t,v) ->
                        fw = t.g_EAF(v)
                        regSet = t.psw.getRegSet()
                        t.regFiles[regSet].setDSE(0, (fw >>> 28) & 0xf)
                        t.regFiles[regSet].setDSE(1, (fw >>> 24) & 0xf)
                        t.regFiles[regSet].setDSE(2, (fw >>> 20) & 0xf)
                        t.regFiles[regSet].setDSE(3, (fw >>> 16) & 0xf)
                }
        #
        # LOAD EXTENDED ADDRESS
        #   (AP101S sect.9.12)
        #   General register R1, and the associated Data Sector Extension (DSE), are initialized
        #   from the fullword second operand.  Bits 0 and bits 16 through 31 of R1 are zeroed.
        #   Bits 1 through 15 f R1 are replaced by bits 1 through 15 of the full word constant,
        #   and the DSE associated with T1 is replaced by bits 28 thrugh 31 of the fullword
        #   address constant.
        #
        #
        #   Load a DSE register and base register from an address constant
        #   in memory. The address constant contains a DSE value in bits
        #   24-27 and an address in bits 0-15. The DSE value is loaded into
        #   DSE[B2] and the address into R1 (upper halfword).
        #
        LXAR:   {
                    n:'Load Index Address Register'
                    f:['LXAR R1,R2']
                    d:'01000xxx11101yyy'
                    e:(t,v) ->



                }

        LXA:    {
                    n:'Load Index Address'
                    f:['LXA R1,D2(B2)','LXA R1,D2(X2,B2)']
                    d:'01000xxx11101abb/X'
                    e:(t,v) ->
                        addrConst = t.g_EAF(v)
                        addr = (addrConst >>> 16) & 0xffff
                        dseVal = (addrConst >>> 4) & 0xf
                        t.r(v.x).set32(addr << 16)
                        t.regFiles[t.psw.getRegSet()].setDSE(v.b, dseVal)
                }
        #
        # STORE DSE MULTIPLE
        #   (AP-101S sect.9.15)
        #   The four Data Sector Extensions (DSE) corresponding to R0-R3 of the current register
        #   set are strored at the location of the fullword second operand.
        #
        #   The format of the fullword second operand is:
        #
        #   -----------------------------------------------------------------
        #   |0 0 0 0| R0DSE |0 0 0 0| R1DSE |0 0 0 0| R2DSE |0 0 0 0| R3DSE |
        #   | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | |
        #    0     3 4     7 8     1 1     1 1     1 2     2 2     2 2     3
        #                          1 2     5 6     9 0     3 4     7 8     1
        #
        #   PROGRAMMING NOTES:
        #   Bits 5 through 7 are not used by this instruction.  These bits should be set to zero
        #   as shown above and considered as an op code extension.
        #
        STDM:   {
                    n:'Store Data Memory'
                    f:['STDM D2(B2)','STDM D2(X2,B2)']
                    d:'1001000011111abb/X'
                    e:(t,v) ->
                        regSet = t.psw.getRegSet()
                        fw = (t.regFiles[regSet].getDSE(0) << 28) |
                             (t.regFiles[regSet].getDSE(1) << 24) |
                             (t.regFiles[regSet].getDSE(2) << 20) |
                             (t.regFiles[regSet].getDSE(3) << 16)
                        t.s_EAF(v, fw)
                }


        #
        ################################
        ##
        ## INTERNAL CONTROL OPERATIONS
        ##
        ################################
        #
        #   A CPU instruction will initiate an Internal Control operation that
        # will perform the following functions, depending on the control word
        # (CW) coding:
        #
        #   o   A fullword will be transferred between general register R1 and
        #       counter 1 or 2. The high halfword of general register R1 (the
        #       most significant halfword) is transferred to or from the main
        #       store halfword location 00B0 for counter 1 or 00B1 for counter 
        #       2. The low halfword of general register R1 (the least 
        #       significant halfword) is transferred to or from a 16-bit 
        #       hardware binary counter 1 or counter 2. Section 2 contains a
        #       description of counter operations.
        #
        #   o   An AGE command word, specified by bits 16 through 31 of the CW
        #       (R2), will be transferred to the AGE interface, and a halfword
        #       will be transferred to or from bits 0 through 15 of a general
        #       reigster (R1) and the AGE interface.
        #
        #   o   Four discretes will be transferred from bits 0 through 3 of a
        #       general register (R1) to the I/O interface.
        #
        #       0 - XMIT Disable
        #       1 - BCE Disable
        #       2 - Spare 1
        #       3 - Spare 2
        #
        #   o   I/O channel reset. The channel reset operation issues a reset\
        #       to the IO. The IO and CPU uses the signal to reset the IO/CPU
        #       interface logic. If an external interrupt 0 has occurred, this
        #       command must not be executed until IOP level A interrupt has 
        #       been read.
        #
        #
        #
        # INTERNAL CONTROL
        #
        #   This instruction transfers a fullword to or from the general
        #   register specified by R1. Operations are further defined by a
        #   control word contained in bits 0 through 31 of the general 
        #   register specified by R2. The CW format is shown below.
        #
        #   CONTROL WORD (CW)
        #   -----------------------------------------------------------------
        #   |    D    |0 0 0 0 0 0 0 0 0 0 0| Reserved for AGE Command Word |
        #   | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | |
        #    0       4 5                  1516                            31
        #
        #   Legal D
        #   Command    Meaning
        #   -------    -------
        #    00000     Read Counter 1
        #    00001     Read Counter 2
        #    00101     Read AGE
        #    01000     Write Counter 1
        #    01001     Write Counter 2
        #    01100     Write Discretes
        #    01101     Write AGE
        #    10000     Channel Reset
        #
        #   No data transfer is associated with the Channel Reset Operation
        #
        # RESULTING CONDITION CODE
        #
        #   The code is not changed.
        #
        # INDICATORS
        #
        #   The overflow and carry indicators are not changed by this
        # instruction.
        #
        # PROGRAM INTERRUPTIONS
        #
        #   Illegal operation.
        #
        # PROGRAMMING NOTES
        #
        #   This is a privileged operation and can only be executed when the
        # CPU is in the supervisors state.
        #
        #   The illegal operation program interruption will occur if the
        # following illegal commands are used: 00010, 00011, 00100, 00110, 
        # 00111, 01010, 01011, 01110, and 01111.
        #
        #   Commands of the form 1XXXX other than 10000 are reserved and should
        # not be used. The illegal operation program interruption does not 
        # occur; instead a channel reset is performed.
        #
        #   When using either Counter 1 of Counter 2 as a counter (rather than 
        # as an incremental timer), a possibility exists that the counter could
        # be in error during a single read by 65.536 microseconds (low order bit
        # of location 00B0 or 00B1). This problem can be avoided by doing two
        # consecutive reads and making comparisons to pick the correct reading.
        #
        ICR:    {
                    n:'Internal Control Register'
                    f:['ICR R1,R2'],
                    d:'11011xxx11100yyy',
                    e:(t,v) ->
                        if not t.i_SUPER() then return

                        # Control word from R2
                        cw = t.r(v.y).get32()
                        cmd = (cw >>> 27) & 0x1f  # bits 0-4 = D field

                        switch cmd
                            when 0b00000  # Read Counter 1
                                hi = t.ram.get16(0x00b0)
                                lo = t.counter1 ? 0
                                t.r(v.x).set32(((hi << 16) | (lo & 0xffff)) >>> 0)
                            when 0b00001  # Read Counter 2
                                hi = t.ram.get16(0x00b1)
                                lo = t.counter2 ? 0
                                t.r(v.x).set32(((hi << 16) | (lo & 0xffff)) >>> 0)
                            when 0b01000  # Write Counter 1
                                r1 = t.r(v.x).get32()
                                t.ram.set16(0x00b0, (r1 >>> 16) & 0xffff)
                                t.counter1 = r1 & 0xffff
                            when 0b01001  # Write Counter 2
                                r1 = t.r(v.x).get32()
                                t.ram.set16(0x00b1, (r1 >>> 16) & 0xffff)
                                t.counter2 = r1 & 0xffff
                            when 0b00101  # Read AGE
                                # AGE not simulated - return 0
                                t.r(v.x).set32(0)
                            when 0b01100  # Write Discretes
                                # Discretes: bits 0-3 of R1 -> I/O interface
                                # Not simulated beyond storing the value
                                t.discretes = (t.r(v.x).get32() >>> 28) & 0xf
                            when 0b01101  # Write AGE
                                # AGE not simulated - no-op
                                return
                            when 0b10000  # Channel Reset
                                if t.iop?
                                    t.iop.reset?()
                            else
                                # Check for illegal commands
                                if (cmd & 0x10) == 0  # 0xxxx commands
                                    # Illegal operation for undefined commands
                                    t.i_ILLEGAL()
                                # else: 1xxxx other than 10000 -> channel reset
                                else
                                    if t.iop?
                                        t.iop.reset?()
                }
    }


instruction = new Instruction()
export default instruction
export {Instruction}

