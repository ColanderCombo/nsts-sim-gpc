
import {PackedBits} from 'gpc/util'

export class RAM
    constructor:(@size) ->
        if @size % 2
            @size = @size + (@size % 2)
        @rawData = new ArrayBuffer(@size*2)
        @data16 =  new Uint16Array(@rawData)
        @data32 =  new Uint32Array(@rawData)
        @data8 = new Uint8Array(@rawData)

    _get16:(i) -> (@data8[i*2] << 8) | (@data8[(i*2)+1])
    _get32:(i) -> ((@_get16(i) << 16) | @_get16(i+1)) >>> 0

    get16: (i) -> @_get16(i)
    get32: (i) -> @_get32(i)

    _set16:(i,v) ->
        @data8[(i*2)] = (v >>> 8) & 0xff
        @data8[(i*2)+1] = v & 0xff
        @_updateView()

    _set32:(i,v) ->
        @_set16(i,(v >>> 16) & 0xffff)
        @_set16(i+1, v & 0xffff)
        @_updateView()

    set16: (i,v) -> @_set16(i,v)
    set32: (i,v) -> @_set32(i,v)

    load16: (base, data) ->
        for d,i in data
            @_set16(base+i,Number(d))

    setView: (@_view) ->

    _updateView: () ->
        if @_view?
            @_view.value = @get32(0)

export class Register extends RAM
    constructor: (@name, bits) ->
        hwCount = Math.ceil(bits/16)
        super(hwCount)
        @bits = bits
        @_regFile = null  # owning RegisterFile (set by RegisterFile)
        @_regIdx = 0      # index within the RegisterFile

    get32:() -> super(0)

    set32:(v) ->
        super(0,v)
        @_regFile?.markWritten(@_regIdx)

    get16:() -> super(0)
    set16:(v) ->
        super(0,v)
        @_regFile?.markWritten(@_regIdx)

    getbit32: (b) ->
        mask = 1 << b
        return (@get32() & mask) >>> b

    getbit16: (b) ->
        mask = 1 << b
        return (@get16() & mask) >>> b

    setbit32: (b,v=1) ->
        v1 = @get32()
        mask = 0xffffffff ^ (1<<b)
        v1 = (v1&mask) | (v<<b)
        @set32(v1)

    setbit16: (b,v=1) ->
        v1 = @get16()
        mask = 0xffff ^ (1<<b)
        v1 = (v1&mask) | (v<<b)
        @set16(v1)


export class RegisterFile
    constructor: (@bank,@num,@bits) ->
        @regs = (new Register("#{@bank}#{x}",@bits) for x in [0..@num])
        # Wire parent references for access tracking
        for reg, idx in @regs
            reg._regFile = @
            reg._regIdx = idx
        # DSE: 4-bit Data Sector Extension for base registers 0-3
        @dse = [0, 0, 0, 0]
        # Access tracking: step number of last write
        @lastWritten = new Uint32Array(@num + 1)
        @dseLastWritten = new Uint32Array(4)
        @step = 0  # synced by AP101._syncStep()

    r: (x) -> @regs[x]

    getDSE: (baseReg) -> @dse[baseReg & 3]
    setDSE: (baseReg, value) ->
        @dse[baseReg & 3] = value & 0xf
        @dseLastWritten[baseReg & 3] = @step

    markWritten: (regNum) ->
        @lastWritten[regNum] = @step

    getLastWritten: (regNum) -> @lastWritten[regNum]
    getDSELastWritten: (baseReg) -> @dseLastWritten[baseReg & 3]

    log: () ->
        lstr = ""
        for r,i in @regs
            lstr += "R#{i}=#{r.get32().asHex(8)} "
            if not (i+1)%4
                lstr += "\n"
        return lstr



export class ProgramStatusWord
    # IBM-75-A97-001/p.21
    # IBM-6246156/p.29
    #
    #  0:15 Next Instruction Address
    # 16:17 Condition Code
    #    18 Carry Indicator
    #    19 Overflow Indicator
    #    20 Fixed Point Arith Overflow Mask
    #    21     RESERVED
    #    22 Exponent Underflow Mask
    #    23 Significance Mask
    # 24:27 Branch Status Register
    # 28:31 Data Sector Register
    # 32:29 System mask for external interrupts
    #    32     Real-Time Clock 1 Mask
    #    33     Real-Time Clock 2 Mask
    #    34     Instruction Monitor Mask
    #    35     IOP Grp 1 Exception Mask
    #    36     IOP Grp 2 Exception Mask
    #    37     IOP Programmed Interrupt Mask
    #    38         SPARE
    #    39         SPARE
    # 40:43 RESERVED
    #    40     P08 XDSDCN
    #    41     P09 BDSDCN
    #    42     P10 SPR1N
    #    43     P11 SPR2N
    #    44 Register set controls which of two sets of general registers
    #    45 Machine Check Mask
    #    46 Run/Wait State Bit
    #    47 Problem State or Supervisor State
    # 48:63 Interrupt Code
    #
    @DESC1: 'ppppppppppppppppccrvf_usbbbbdddd'
    @DESC2: 'mmmmmmmmeeeercwpiiiiiiiiiiiiiiiiii'

    constructor: () ->
        @psw1 = new Register('psw1',32)
        @psw2 = new Register('psw2',32)

        @pack1 = new PackedBits(ProgramStatusWord.DESC1)
        @pack2 = new PackedBits(ProgramStatusWord.DESC2)

        # Access tracking
        @lastWritten1 = 0
        @lastWritten2 = 0
        @step = 0  # shared reference, set by CPU

    _getField1: (f) -> @pack1.getField(@psw1.get32(),f)
    _setField1: (f,v) ->
        @psw1.set32(@pack1.setFld(@psw1.get32(),f,v))
        @lastWritten1 = @step

    _getField2: (f) -> @pack2.getField(@psw2.get32(),f)
    _setField2: (f,v) ->
        @psw2.set32(@pack2.setFld(@psw2.get32(),f,v))
        @lastWritten2 = @step

    getNIA: () ->
        # Return the full 19-bit expanded address
        # NIA (bits 0:15 of PSW1) is 16-bit; if bit 15 is set, BSR provides sector
        nia16 = @_getField1(@pack1.desc.f.p)
        if nia16 & 0x8000
            (@getBSR() << 15) | (nia16 & 0x7FFF)
        else
            nia16

    setNIA: (v) ->
        # Accept a full 19-bit address, decompose into BSR + 16-bit NIA
        if v >= 0x8000
            sector = (v >>> 15) & 0xF
            @setBSR(sector)
            nia16 = (v & 0x7FFF) | 0x8000
        else
            nia16 = v & 0x7FFF
        @_setField1(@pack1.desc.f.p, nia16)

    getCC: () -> @_getField1(@pack1.desc.f.c)
    setCC: (v) -> @_setField1(@pack1.desc.f.c,v)

    getCarry: () -> @_getField1(@pack1.desc.f.r)
    setCarry: (v) -> @_setField1(@pack1.desc.f.r,v)

    getOverflow: () -> @_getField1(@pack1.desc.f.v)
    setOverflow: (v) -> @_setField1(@pack1.desc.f.v,v)

    getFixedPtOverflow: () -> @_getField1(@pack1.desc.f.f)
    setFixedPtOverflow: (v) -> @_setField1(@pack1.desc.f.f,v)

    getExponentUnderflow: () -> @_getField1(@pack1.desc.f.u)
    setExponentUnderflow: (v) -> @_setField1(@pack1.desc.f.u,v)

    getSignificanceMask: () -> @_getField1(@pack1.desc.f.s)
    setSignificanceMask: (v) -> @_setField1(@pack1.desc.f.s,v)

    getBSR: () -> @_getField1(@pack1.desc.f.b)
    setBSR: (v) -> @_setField1(@pack1.desc.f.b,v)

    getDSR: () -> @_getField1(@pack1.desc.f.d)
    setDSR: (v) -> @_setField1(@pack1.desc.f.d,v)

    getIntMask: () -> @_getField2(@pack2.desc.f.m)
    setIntMask: (v) -> @_setField2(@pack2.desc.f.m,v)

    getRegSet: () -> @_getField2(@pack2.desc.f.r)
    setRegSet: (v) -> @_setField2(@pack2.desc.f.r,v)

    getMachCheckMask: () -> @_getField2(@pack2.desc.f.c)
    setMachCheckMask: (v) -> @_setField2(@pack2.desc.f.c,v)

    getWaitState: () -> !@_getField2(@pack2.desc.f.w)
    setWaitState: (v) -> @_setField2(@pack2.desc.f.w,!v)

    getProblemState: () -> @_getField2(@pack2.desc.f.p)
    setProblemState: (v) -> @_setField2(@pack2.desc.f.p,v)

    getIntCode: () -> @_getField2(@pack2.desc.f.i)
    setIntCode: (v) -> @_setField2(@pack2.desc.f.i,v)

    load: (p1,p2) ->
        @psw1.set32(p1)
        @psw2.set32(p2)
        @lastWritten1 = @step
        @lastWritten2 = @step
