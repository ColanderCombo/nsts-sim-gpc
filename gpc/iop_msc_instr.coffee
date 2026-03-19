#
# MSC Instruction Set
#
# Instruction decode and execution for the Master Sequence Controller.
# Split from msc.coffee — see iop_msc.coffee for the MSC class itself.
#

# Sign-extend an n-bit value to 32 bits
signExtend = (val, bits) ->
    mask = 1 << (bits - 1)
    if val & mask
        val | (-1 << bits)
    else
        val

export class MSCInstruction
    constructor: ->
        @_buildOpTable()

    # Build opcode lookup table from descriptor strings
    _buildOpTable: ->
        @_opTable16 = {} # mask -> { maskedVal -> entry }
        @_opTable32 = {} # mask -> { maskedVal -> entry }
        @_orderedMasks16 = []
        @_orderedMasks32 = []

        for name, op of @ops
            continue unless op.d and op.d.length > 0
            desc = @_parseDesc(op.d)
            entry = { nm: name, desc: desc, e: op.e, d: op.d }

            if op.d.length <= 16
                tbl = @_opTable16
                masks = @_orderedMasks16
            else
                tbl = @_opTable32
                masks = @_orderedMasks32

            if desc.mask not of tbl
                masks.push desc.mask
                tbl[desc.mask] = {}
            tbl[desc.mask][desc.maskedVal] = entry

        @_orderedMasks16 = @_orderedMasks16.sort().reverse()
        @_orderedMasks32 = @_orderedMasks32.sort().reverse()

    # Parse a descriptor string into mask/value/fields
    _parseDesc: (s) ->
        mask = 0
        maskedVal = 0
        fields = {}
        for ch, i in s
            mask = (mask * 2) + (if ch == '0' or ch == '1' then 1 else 0)
            maskedVal = (maskedVal * 2) + (if ch == '1' then 1 else 0)
            if ch != '0' and ch != '1' and ch != '_'
                unless fields[ch]
                    fields[ch] = { shift: 0, mask: 0, bits: 0 }
                fields[ch].bits++

        # Force unsigned for 32-bit values
        mask = mask >>> 0
        maskedVal = maskedVal >>> 0

        # Now compute shift and mask for each field
        computed = {}
        for ch, i in s by -1
            if ch != '0' and ch != '1' and ch != '_' and fields[ch]? and not computed[ch]
                computed[ch] = true
                rightPos = s.length - 1 - s.lastIndexOf(ch)
                fields[ch].shift = rightPos
                fmask = 0
                for j in [0...s.length]
                    if s[j] == ch
                        bitpos = s.length - 1 - j
                        fmask = (fmask + Math.pow(2, bitpos)) >>> 0
                fields[ch].mask = fmask

        { mask, maskedVal, fields }

    # Extract a field value from an instruction word
    _getField: (word, field) ->
        (word & field.mask) >>> field.shift

    # Decode and execute an MSC instruction
    # t = IOP instance, hw1 = first halfword, hw2 = second halfword
    exec: (t, hw1, hw2) ->
        # Try 32-bit (long format) first: prefix 1111x
        if (hw1 >>> 12) == 0xf
            fullword = (((hw1 & 0xffff) * 0x10000) + (hw2 & 0xffff)) >>> 0
            entry = @_matchLong(fullword)
            if entry
                v = @_decodeFields(fullword, entry)
                entry.e(t, v) if entry.e
                return

        # Try 16-bit (short format)
        entry = @_matchShort(hw1 & 0xffff)
        if entry
            v = @_decodeFields(hw1 & 0xffff, entry)
            entry.e(t, v) if entry.e
            return

        # Unrecognized instruction - no-op, advance PC
        t.incrNIA(1)

    _matchShort: (hw1) ->
        hw1 = hw1 >>> 0
        for msk in @_orderedMasks16
            tbl = @_opTable16[msk]
            mval = (hw1 & msk) >>> 0
            if mval of tbl
                return tbl[mval]
        return null

    _matchLong: (fullword) ->
        fullword = fullword >>> 0
        for msk in @_orderedMasks32
            tbl = @_opTable32[msk]
            mval = (fullword & msk) >>> 0
            if mval of tbl
                return tbl[mval]
        return null

    _decodeFields: (word, entry) ->
        v = { nm: entry.nm }
        for ch, field of entry.desc.fields
            v[ch] = @_getField(word, field)
        v

    ops: {
        #
        # ACCUMULATOR/MEMORY INSTRUCTIONS
        #

        # LOAD ACCUMULATOR (short, PC-relative)
        '@L':   {
                    f:['@L ADDRESS']
                    d:'0100iddddddddddd'
                    e:(t,v)->
                        ea = t.mscEA(v.d, v.i)
                        v1 = t.g_EAF(ea)
                        t.ls.setACC(v1)
                        t.incrNIA(1)

                }
        # ADD TO ACCUMULATOR
        '@A':   {
                    f:['@A ADDRESS']
                    d:'0101iddddddddddd'
                    e:(t,v)->
                        ea = t.mscEA(v.d, v.i)
                        v1 = t.g_EAF(ea)
                        v2 = t.ls.getACC()
                        v3 = (v1 + v2) | 0
                        t.ls.setACC(v3)
                        t.incrNIA(1)
                }
        # AND TO ACCUMULATOR
        '@N':   {
                    f:['@N ADDRESS']
                    d:'0110iddddddddddd'
                    e:(t,v)->
                        ea = t.mscEA(v.d, v.i)
                        v1 = t.g_EAF(ea)
                        v2 = t.ls.getACC()
                        v3 = v1 & v2
                        t.ls.setACC(v3)
                        t.incrNIA(1)
                }
        # EXCLUSIVE OR
        '@X':   {
                    f:['@X ADDRESS']
                    d:'0111iddddddddddd'
                    e:(t,v)->
                        ea = t.mscEA(v.d, v.i)
                        v1 = t.g_EAF(ea)
                        v2 = t.ls.getACC()
                        v3 = v1 ^ v2
                        t.ls.setACC(v3)
                        t.incrNIA(1)
                }
        # STORE ACCUMULATOR (short, PC-relative)
        '@ST':  {
                    f:['@ST ADDRESS']
                    d:'1000iddddddddddd'
                    e:(t,v)->
                        ea = t.mscEA(v.d, v.i)
                        v2 = t.ls.getACC()
                        t.s_EAF(ea, v2)
                        t.incrNIA(1)
                }
        # LOAD ACC WITH FULLWORD (long, absolute)
        '@LF':  {
                    f:['@LF ADDRESS']
                    d:'1111i100000000aaaaaaaaaaaaaaaaaa'
                    e:(t,v)->
                        ea = t.mscLongEA(v.a, v.i)
                        v1 = t.g_EAF(ea)
                        t.ls.setACC(v1)
                        t.incrNIA(1)
                }
        # LOAD ACC WITH HALFWORD (long, absolute)
        '@LH':  {
                    f:['@LH ADDRESS']
                    d:'1111i100000010aaaaaaaaaaaaaaaaaa'
                    e:(t,v)->
                        ea = t.mscLongEA(v.a, v.i)
                        v1 = t.g_EAH(ea)
                        t.ls.setACC(v1)
                        t.incrNIA(1)
                }
        # STORE ACC FULLWORD (long, absolute)
        '@STF': {
                    f:['@STF ADDRESS']
                    d:'1111i101000000aaaaaaaaaaaaaaaaaa'
                    e:(t,v)->
                        ea = t.mscLongEA(v.a, v.i)
                        v2 = t.ls.getACC()
                        t.s_EAF(ea, v2)
                        t.incrNIA(1)
                }
        # STORE ACCUMULATOR HALFWORD (long, absolute)
        '@STH': {
                    f:['@STH ADDRESS']
                    d:'1111i101000010aaaaaaaaaaaaaaaaaa'
                    e:(t,v)->
                        ea = t.mscLongEA(v.a, v.i)
                        v2 = t.ls.AL().get16()
                        t.s_EAH(ea, v2)
                        t.incrNIA(1)
                }

        #
        # BRANCHING INSTRUCTIONS
        #

        # BRANCH ON ACCUMULATOR
        # Short format 2: OP=0010, I=0, OPX=condition(3), DISP=displacement(8)
        '@BC':  {
                    f:['@BC CONDITION,ADDRESS']
                    d:'00100cccdddddddd'
                    e:(t,v)->
                        doBranch = false
                        v1 = t.ls.getACC()
                        if v.c & 0x4  # ACC=0
                            if v1 == 0
                                doBranch = true
                        if v.c & 0x2 # ACC < 0
                            if v1 < 0
                                doBranch = true
                        if v.c & 0x1 # ACC > 0
                            if v1 > 0
                                doBranch = true
                        if doBranch
                            d8 = signExtend(v.d, 8)
                            t.incrNIA(d8)
                        else
                            t.incrNIA(1)
                }
        # BRANCH ON INDEX
        '@BXC': {
                    f:['@BXC CONDITION,ADDRESS']
                    d:'00101cccdddddddd'
                    e:(t,v)->
                        doBranch = false
                        v1 = t.ls.X().get32()
                        if v.c & 0x4  # X=0
                            if v1 == 0
                                doBranch = true
                        if v.c & 0x2 # X < 0
                            if v1 < 0
                                doBranch = true
                        if v.c & 0x1 # X > 0
                            if v1 > 0
                                doBranch = true
                        if doBranch
                            d8 = signExtend(v.d, 8)
                            t.incrNIA(d8)
                        else
                            t.incrNIA(1)

                }
        # BRANCH UNCONDITIONAL (long, direct)
        '@BU':  {
                    f:['@BU ADDRESS']
                    d:'1111i000_____0aaaaaaaaaaaaaaaaaa'
                    e:(t,v)->
                        ea = t.mscLongEA(v.a, v.i)
                        t.setNIA(ea)
                }
        # BRANCH UNCONDITIONAL INDIRECT (long, indirect)
        '@BU@':  {
                    f:['@BU@ ADDRESS']
                    d:'1111i000_____1aaaaaaaaaaaaaaaaaa'
                    e:(t,v)->
                        ea = t.mscLongEA(v.a, v.i)
                        addr = t.g_EAF(ea)
                        t.setNIA(addr & 0x3ffff)
                }
        # SUBROUTINE CALL
        #
        #   This instruction implements a subroutine call.  The current value
        #   of the MSC program counter plus the five bit positive integer delta
        #   (bits 8-12) is stored in the fullword specified by the lower 18
        #   bits of E.V.  This quantity is zero padded on the left to fill the
        #   entire fullword.  The MSC program counter is then loaded with the
        #   sum of the lower 18 bits of E.V. and two.
        #
        #   PROGRAMMING NOTE
        #
        #      This instruction is typically used to call a subroutine. A
        #      typical subroutine sequence is:
        #
        #      .
        #      .
        #      .
        #      @CALL 4,SUB
        #      .                ARGUMENT
        #      .                FIRST INSTRUCTION AFTER RETURN
        #      .
        #      .
        # SUB       +0          USED FOR RETURN ADDRESS
        #      .
        #      .                SUBROUTINE BODY
        #      .
        #      @BU@  SUB        SUBROUTINE RETURN
        #
        #
        #      The effective value used in the subroutine call may be either
        #      even or odd.  With an odd address, the least-significant bit is
        #      ignored when the return addres is stored, but is considered when
        #      the branch is take.  Thus a @CALL 2,101 will cause the return
        #      address to be stored in fullword 100, but a branch to 103 will
        #      be taken.
        #
        #      As with any instruction that writes information into memory, the
        #      affected memory location must not be storage protected.
        #
        '@CALL':{
                    f:['@CALL DELTA,ADDRESS']
                    d:'1111i001ttttt0aaaaaaaaaaaaaaaaaa'
                    e:(t,v)->
                        ea = t.mscLongEA(v.a, v.i)
                        pc = t.ls.PC().get32()
                        retAddr = (pc + v.t) & 0x3ffff
                        t.s_EAF(ea & 0x3fffe, retAddr) # store at even address
                        t.setNIA(ea + 2)
                }
        '@CALL@':{
                    f:['@CALL@ DELTA,ADDRESS']
                    d:'1111i001ttttt1aaaaaaaaaaaaaaaaaa'
                    e:(t,v)->
                        ea = t.mscLongEA(v.a, v.i)
                        addr = t.g_EAF(ea) & 0x3ffff # indirect: read address from memory
                        pc = t.ls.PC().get32()
                        retAddr = (pc + v.t) & 0x3ffff
                        t.s_EAF(addr & 0x3fffe, retAddr)
                        t.setNIA(addr + 2)
                }

        # RETURN FROM EXTERNAL CALL
        #
        # Restores ACC, X, PC, Status from memory saved by @SEC.
        # The address field gives the location of the saved context block
        # (same as the ECR value used by @SEC).
        #
        '@REC': {
                    f:['@REC ADDRESS']
                    d:'1010iddddddddddd'
                    e:(t,v)->
                        ea = t.mscEA(v.d, v.i)
                        # ECR value was stored at ea; saved regs follow at ea+2..ea+8
                        # Restore ACC from ea+2
                        acc = t.g_EAF(ea + 2)
                        t.ls.setACC(acc)
                        # Restore X from ea+4
                        xval = t.g_EAF(ea + 4)
                        t.ls.X().set32(xval & 0x3ffff)
                        # Restore PC from ea+6
                        pcval = t.g_EAF(ea + 6)
                        t.setNIA(pcval & 0x3ffff)
                        # Restore status from ea+8
                        stval = t.g_EAF(ea + 8)
                        t.ls.MST().set32(stval & 0x3ffff)
                        # Restore program exception bit from saved status bit 16
                        if stval & 0x00010000
                            pe = t.regProgExcept.get32()
                            pe = pe | 1 # bit 0 = MSC
                            t.regProgExcept.set32(pe)
                        else
                            pe = t.regProgExcept.get32()
                            pe = pe & ~1
                            t.regProgExcept.set32(pe)
                }

        #
        # CONDITIONAL SKIP INSTRUCTIONS
        #

        # TALLY AND SKIP ZERO
        '@TSZ': {
                    f:['@TSZ ADDRESS']
                    d:'1001iddddddddddd'
                    e:(t,v)->
                        ea = t.mscEA(v.d, v.i)
                        v2 = t.g_EAF(ea)
                        v2 = (v2 + 1) | 0
                        t.s_EAF(ea, v2)
                        if v2 == 0
                            t.incrNIA(2)
                        else
                            t.incrNIA(1)
                }
        # COMPARE IMMEDIATE
        # Three-way skip: ACC < value -> skip 1, ACC = value -> skip 2,
        # ACC > value -> fall through (NIA+1)
        '@CI':  {
                    f:['@CI VALUE']
                    d:'1111i110_____0aaaaaaaaaaaaaaaaaa'
                    e:(t,v)->
                        ea = t.mscLongEA(v.a, v.i)
                        # In immediate mode, EA is the value itself
                        val = ea
                        acc = t.ls.getACC()
                        if acc < val
                            t.incrNIA(2)  # skip 1 (NIA is already +1 for long instr)
                        else if acc == val
                            t.incrNIA(3)  # skip 2
                        else
                            t.incrNIA(1)
                }
        # COMPARE (memory)
        '@C':   {
                    f:['@C ADDRESS']
                    d:'1111i110_____1aaaaaaaaaaaaaaaaaa'
                    e:(t,v)->
                        ea = t.mscLongEA(v.a, v.i)
                        val = t.g_EAF(ea)
                        acc = t.ls.getACC()
                        if acc < val
                            t.incrNIA(2)
                        else if acc == val
                            t.incrNIA(3)
                        else
                            t.incrNIA(1)
                }
        # TEST UNDER MASK IMMEDIATE
        # If (ACC & mask) != 0, skip 1 instruction
        '@TMI': {
                    f:['@TMI VALUE']
                    d:'1111i111_____0aaaaaaaaaaaaaaaaaa'
                    e:(t,v)->
                        ea = t.mscLongEA(v.a, v.i)
                        mask = ea  # immediate value is the mask
                        acc = t.ls.getACC()
                        if (acc & mask) != 0
                            t.incrNIA(2)  # skip 1
                        else
                            t.incrNIA(1)
                }
        # TEST UNDER MASK (memory)
        '@TM':  {
                    f:['@TM ADDRESS']
                    d:'1111i111_____1aaaaaaaaaaaaaaaaaa'
                    e:(t,v)->
                        ea = t.mscLongEA(v.a, v.i)
                        mask = t.g_EAF(ea)
                        acc = t.ls.getACC()
                        if (acc & mask) != 0
                            t.incrNIA(2)
                        else
                            t.incrNIA(1)
                }

        #
        # BCE REGISTER LOAD INSTRUCTIONS
        #
        # Long format: 1111i 010 bbbbb m aaaaaaaaaaaaaaaaaa
        #   bbbbb = BCE number (0 means use ACC bits 27-31)
        #   m = 0: direct (EA = address), m = 1: indirect (EA = (address))
        #

        # LOAD BCE BASE REGISTER (direct)
        '@LBB':   {
                    f:['@LBB BCE,ADDRESS']
                    d:'1111i010bbbbb0aaaaaaaaaaaaaaaaaa'
                    e:(t,v)->
                        ea = t.mscLongEA(v.a, v.i)
                        bceNum = v.b
                        if bceNum == 0
                            bceNum = t.ls.getACC() & 0x1f
                        # Check if BCE is waiting (not busy, not halted)
                        if bceNum > 0 and bceNum <= 24
                            if t.regBusyWait.getbit32(bceNum) or t.regHalt.getbit32(bceNum)
                                # BCE busy or halted - set status bit 13, program exception
                                st = t.ls.MST().get32()
                                st = st | (1 << (17 - 13))  # bit 13
                                t.ls.MST().set32(st)
                                pe = t.regProgExcept.get32()
                                pe = pe & ~1 # clear MSC bit (0 = error)
                                t.regProgExcept.set32(pe)
                            else
                                savedPage = t.ls.curPage
                                t.ls.curPage = bceNum
                                t.ls.BASE().set32(ea & 0x3ffff)
                                t.ls.curPage = savedPage
                        else
                            # BCE 0 = MSC, always busy -> error
                            st = t.ls.MST().get32()
                            st = st | (1 << (17 - 13))
                            t.ls.MST().set32(st)
                            pe = t.regProgExcept.get32()
                            pe = pe & ~1
                            t.regProgExcept.set32(pe)
                        t.incrNIA(1)
                }
        # LOAD BCE BASE REGISTER (indirect)
        '@LBB@':   {
                    f:['@LBB@ BCE,ADDRESS']
                    d:'1111i010bbbbb1aaaaaaaaaaaaaaaaaa'
                    e:(t,v)->
                        ea = t.mscLongEA(v.a, v.i)
                        val = t.g_EAF(ea)
                        ea = val & 0x3ffff
                        bceNum = v.b
                        if bceNum == 0
                            bceNum = t.ls.getACC() & 0x1f
                        if bceNum > 0 and bceNum <= 24
                            if t.regBusyWait.getbit32(bceNum) or t.regHalt.getbit32(bceNum)
                                st = t.ls.MST().get32()
                                st = st | (1 << (17 - 13))
                                t.ls.MST().set32(st)
                                pe = t.regProgExcept.get32()
                                pe = pe & ~1
                                t.regProgExcept.set32(pe)
                            else
                                savedPage = t.ls.curPage
                                t.ls.curPage = bceNum
                                t.ls.BASE().set32(ea)
                                t.ls.curPage = savedPage
                        else
                            st = t.ls.MST().get32()
                            st = st | (1 << (17 - 13))
                            t.ls.MST().set32(st)
                            pe = t.regProgExcept.get32()
                            pe = pe & ~1
                            t.regProgExcept.set32(pe)
                        t.incrNIA(1)
                }
        # LOAD BCE PROGRAM COUNTER (direct)
        '@LBP':   {
                    f:['@LBP BCE,ADDRESS']
                    d:'1111i011bbbbb0aaaaaaaaaaaaaaaaaa'
                    e:(t,v)->
                        ea = t.mscLongEA(v.a, v.i)
                        bceNum = v.b
                        if bceNum == 0
                            bceNum = t.ls.getACC() & 0x1f
                        if bceNum > 0 and bceNum <= 24
                            if t.regBusyWait.getbit32(bceNum) or t.regHalt.getbit32(bceNum)
                                st = t.ls.MST().get32()
                                st = st | (1 << (17 - 12))  # bit 12
                                t.ls.MST().set32(st)
                                pe = t.regProgExcept.get32()
                                pe = pe & ~1
                                t.regProgExcept.set32(pe)
                            else
                                savedPage = t.ls.curPage
                                t.ls.curPage = bceNum
                                t.ls.PC().set32(ea & 0x3ffff)
                                t.ls.curPage = savedPage
                        else
                            st = t.ls.MST().get32()
                            st = st | (1 << (17 - 12))
                            t.ls.MST().set32(st)
                            pe = t.regProgExcept.get32()
                            pe = pe & ~1
                            t.regProgExcept.set32(pe)
                        t.incrNIA(1)
                }
        # LOAD BCE PROGRAM COUNTER (indirect)
        '@LBP@':   {
                    f:['@LBP@ BCE,ADDRESS']
                    d:'1111i011bbbbb1aaaaaaaaaaaaaaaaaa'
                    e:(t,v)->
                        ea = t.mscLongEA(v.a, v.i)
                        val = t.g_EAF(ea)
                        ea = val & 0x3ffff
                        bceNum = v.b
                        if bceNum == 0
                            bceNum = t.ls.getACC() & 0x1f
                        if bceNum > 0 and bceNum <= 24
                            if t.regBusyWait.getbit32(bceNum) or t.regHalt.getbit32(bceNum)
                                st = t.ls.MST().get32()
                                st = st | (1 << (17 - 12))
                                t.ls.MST().set32(st)
                                pe = t.regProgExcept.get32()
                                pe = pe & ~1
                                t.regProgExcept.set32(pe)
                            else
                                savedPage = t.ls.curPage
                                t.ls.curPage = bceNum
                                t.ls.PC().set32(ea)
                                t.ls.curPage = savedPage
                        else
                            st = t.ls.MST().get32()
                            st = st | (1 << (17 - 12))
                            t.ls.MST().set32(st)
                            pe = t.regProgExcept.get32()
                            pe = pe & ~1
                            t.regProgExcept.set32(pe)
                        t.incrNIA(1)
                }

        #
        # REGISTER OPERATIONS
        #
        # Short format 2: OP=1110, I=0, OPX=0-7, DATA=register select
        #

        # LOAD MSC ACC WITH AN IOP STATUS REGISTER
        # OPX=0, DATA bits 6-7 select the register:
        #   0 = STAT1 (GO/NOGO), 1 = BCE Indicators, 2 = Fail Discretes, 3 = STAT4 (Busy/Wait)
        '@LAR':   {
                    f:['@LAR REGISTER']
                    d:'11100000rrdddddd'
                    e:(t,v)->
                        switch v.r
                            when 0 # STAT1 - Program Exception (GO/NOGO)
                                t.ls.setACC(t.regProgExcept.get32())
                            when 1 # BCE-MSC Indicators
                                t.ls.setACC(t.regIndicator.get32())
                            when 2 # Fail Discretes
                                t.ls.setACC(t.msc.regFailDisc.get32())
                            when 3 # STAT4 - Busy/Wait
                                t.ls.setACC(t.regBusyWait.get32())
                        t.incrNIA(1)
                }
        # SET FAIL DISCRETES
        # OPX=1: OR ACC bits 0-4 into fail discrete register
        '@SFD':   {
                    f:['@SFD']
                    d:'1110000100000000'
                    e:(t,v)->
                        acc = t.ls.getACC()
                        fd = t.msc.regFailDisc.get32()
                        fd = fd | (acc >>> 27)  # top 5 bits of ACC
                        t.msc.regFailDisc.set32(fd & 0x1f)
                        t.incrNIA(1)
                }
        # RESET FAIL DISCRETES
        # OPX=2: Clear fail discrete bits where ACC bits 0-4 are 1
        '@RFD':   {
                    f:['@RFD']
                    d:'1110001000000000'
                    e:(t,v)->
                        acc = t.ls.getACC()
                        fd = t.msc.regFailDisc.get32()
                        mask = (acc >>> 27) & 0x1f
                        fd = fd & ~mask
                        t.msc.regFailDisc.set32(fd)
                        t.incrNIA(1)
                }
        # LOAD ACC WITH MSC STATUS
        # OPX=3
        '@LMS':   {
                    f:['@LMS']
                    d:'1110001100000000'
                    e:(t,v)->
                        st = t.ls.MST().get32()
                        t.ls.setACC(st)
                        t.incrNIA(1)
                }
        # START I/O
        # OPX=4: OR ACC with Busy/Wait register to start BCEs
        '@SIO':   {
                    f:['@SIO']
                    d:'1110010000000000'
                    e:(t,v)->
                        acc = t.ls.getACC()
                        bw = t.regBusyWait.get32()
                        # Check for busy conflict on BCE bits 1-24
                        conflict = acc & bw & 0x01fffffe
                        if conflict
                            st = t.ls.MST().get32()
                            st = st | (1 << (17 - 11)) | (1 << (17 - 16))  # bits 11, 16
                            t.ls.MST().set32(st)
                            pe = t.regProgExcept.get32()
                            pe = pe & ~1  # MSC error
                            t.regProgExcept.set32(pe)
                        bw = bw | acc
                        t.regBusyWait.set32(bw)
                        t.incrNIA(1)
                }
        # EXCHANGE ACC AND X
        # OPX=5: Lower 18 bits of ACC -> X, X sign-extended to 32 bits -> ACC
        '@XAX':   {
                    f:['@XAX']
                    d:'1110010100000000'
                    e:(t,v)->
                        acc = t.ls.getACC()
                        xval = t.ls.X().get32()
                        # Lower 18 bits of ACC -> X
                        t.ls.X().set32(acc & 0x3ffff)
                        # X sign-extended to 32 bits -> ACC
                        xSigned = signExtend(xval, 18)
                        t.ls.setACC(xSigned)
                        t.incrNIA(1)
                }
        # SAMPLE FOR EXTERNAL CALL
        # OPX=6: Check ECR. If non-zero, save context and branch.
        # DATA bits specify the address offset for saving context.
        '@SEC':   {
                    f:['@SEC ADDRESS']
                    d:'1110011000000000'
                    e:(t,v)->
                        ecr = t.ls.ECR().get32()
                        if ecr == 0
                            # No external call pending - NOP
                            t.incrNIA(1)
                        else
                            # Save context at address pointed to by ECR
                            # ECR+0: (reserved for ECR value itself)
                            # ECR+2: ACC
                            t.s_EAF(ecr + 2, t.ls.getACC())
                            # ECR+4: X (18 bits, zero padded)
                            t.s_EAF(ecr + 4, t.ls.X().get32())
                            # ECR+6: PC (18 bits, zero padded) - return to next instr
                            pc = t.ls.PC().get32()
                            t.s_EAF(ecr + 6, pc + 1)
                            # ECR+8: Status + ProgException bit
                            st = t.ls.MST().get32()
                            peBit = t.regProgExcept.getbit32(0)
                            st = st | (peBit << 16)
                            t.s_EAF(ecr + 8, st)
                            # Clear status and program exception
                            t.ls.MST().set32(0)
                            pe = t.regProgExcept.get32()
                            pe = pe | 1  # set MSC bit to 1 (no error)
                            t.regProgExcept.set32(pe)
                            # Clear ECR
                            t.ls.ECR().set32(0)
                            # Branch to ECR+8 (5th fullword = ECR + 4*2)
                            t.setNIA(ecr + 8)
                }
        # RESET BCE INDICATOR
        # OPX=7: Reset indicator bits for BCEs specified in ACC
        '@RBI':   {
                    f:['@RBI BCE']
                    d:'1110011100000000'
                    e:(t,v)->
                        acc = t.ls.getACC()
                        ind = t.regIndicator.get32()
                        # Clear indicator bits where ACC has 1s (BCE bits 1-24)
                        ind = ind & ~(acc & 0x01fffffe)
                        t.regIndicator.set32(ind)
                        t.incrNIA(1)
                }

        #
        # REGISTER IMMEDIATE INSTRUCTIONS
        #
        # Short format 2: OP=1110, I=1, OPX=0-7, IMM=8-bit signed
        #

        # NORMALIZE AND INCREMENT X
        # OPX=0: Shift ACC left until sign bit is 1 or ACC=0.
        # Each shift adds immediate to X. If ACC=0, X is cleared.
        '@NIX':   {
                    f:['@NIX IMM']
                    d:'11101000iiiiiiii'
                    e:(t,v)->
                        imm = signExtend(v.i, 8)
                        acc = t.ls.getACC()
                        xval = t.ls.X().get32()
                        if acc == 0
                            t.ls.X().set32(0)
                        else
                            loop
                                acc = (acc << 1) | 0
                                xval = (xval + imm) & 0x3ffff
                                break if acc & 0x80000000  # sign bit set
                                break if acc == 0
                            t.ls.setACC(acc)
                            if acc == 0
                                t.ls.X().set32(0)
                            else
                                t.ls.X().set32(xval)
                        t.incrNIA(1)
                }
        # TALLY ACC TO X
        # OPX=1: X = ACC + immediate (lower 18 bits)
        '@TAX':   {
                    f:['@TAX IMM']
                    d:'11101001iiiiiiii'
                    e:(t,v)->
                        imm = signExtend(v.i, 8)
                        acc = t.ls.getACC()
                        result = (acc + imm) & 0x3ffff
                        t.ls.X().set32(result)
                        t.incrNIA(1)
                }
        # TALLY X
        # OPX=2: X = X + immediate. If result <= 0, skip next instruction.
        '@TXI':   {
                    f:['@TXI IMM']
                    d:'11101010iiiiiiii'
                    e:(t,v)->
                        imm = signExtend(v.i, 8)
                        xval = signExtend(t.ls.X().get32(), 18)
                        result = xval + imm
                        t.ls.X().set32(result & 0x3ffff)
                        if result <= 0
                            t.incrNIA(2)
                        else
                            t.incrNIA(1)
                }
        # LOAD X IMMEDIATE
        # OPX=3: X = sign-extended immediate
        '@LXI':   {
                    f:['@LXI IMM']
                    d:'11101011iiiiiiii'
                    e:(t,v)->
                        imm = signExtend(v.i, 8)
                        t.ls.X().set32(imm & 0x3ffff)
                        t.incrNIA(1)
                }
        # TALLY X TO ACC
        # OPX=4: ACC = X + immediate (sign-extended to 32 bits)
        '@TXA':   {
                    f:['@TXA IMM']
                    d:'11101100iiiiiiii'
                    e:(t,v)->
                        imm = signExtend(v.i, 8)
                        xval = signExtend(t.ls.X().get32(), 18)
                        result = xval + imm
                        t.ls.setACC(result)
                        t.incrNIA(1)
                }
        # TALLY IMMEDIATE TO ACC
        # OPX=5: ACC = ACC + sign-extended immediate
        '@TI':   {
                    f:['@TI IMM']
                    d:'11101101iiiiiiii'
                    e:(t,v)->
                        imm = signExtend(v.i, 8)
                        acc = t.ls.getACC()
                        result = (acc + imm) | 0
                        t.ls.setACC(result)
                        t.incrNIA(1)
                }
        # SUBTRACT ACC FROM IMMEDIATE
        # OPX=6: ACC = sign-extended immediate - ACC
        '@SAI':   {
                    f:['@SAI IMM']
                    d:'11101110iiiiiiii'
                    e:(t,v)->
                        imm = signExtend(v.i, 8)
                        acc = t.ls.getACC()
                        result = (imm - acc) | 0
                        t.ls.setACC(result)
                        t.incrNIA(1)
                }
        # LOAD ACCUMULATOR IMMEDIATE
        # OPX=7: ACC = sign-extended immediate
        '@LI':   {
                    f:['@LI IMM']
                    d:'11101111iiiiiiii'
                    e:(t,v)->
                        imm = signExtend(v.i, 8)
                        t.ls.setACC(imm)
                        t.incrNIA(1)
                }

        #
        # REPEAT INSTRUCTIONS
        #
        # Short format 2: OP=1101, I=opx extension, OPX=condition, DATA=count
        # The I bit and OPX together form the repeat type:
        #   I=0 OPX=0 (@RAI): Repeat until ALL specified BCE indicators set
        #   I=0 OPX=1 (@RAW): Repeat until ALL specified BCEs waiting
        #   I=1 OPX=0 (@RNI): Repeat until ANY specified BCE indicator set
        #   I=1 OPX=1 (@RNW): Repeat until ANY specified BCE waiting
        #
        # In all cases:
        #   - BCEs to test are specified by ACC (bit i = BCE i)
        #   - Count field = max iterations before timeout
        #   - If condition met: skip 1 instruction (NIA+2)
        #   - If timeout: NIA+1 (next sequential instruction)
        #

        # REPEAT UNTIL ALL INDICATORS
        '@RAI':   {
                    f:['@RAI COUNT']
                    d:'11010000dddddddd'
                    e:(t,v)->
                        acc = t.ls.getACC()
                        bceMask = acc & 0x01fffffe  # BCE bits 1-24
                        ind = t.regIndicator.get32()
                        if (ind & bceMask) == bceMask
                            t.incrNIA(2)  # condition met, skip 1
                        else
                            # In simulator, don't actually loop - just check once
                            # If count is 0, check once. Otherwise simulate timeout.
                            if v.d == 0
                                t.incrNIA(1)  # timeout
                            else
                                # Check once more (simulator simplification)
                                if (ind & bceMask) == bceMask
                                    t.incrNIA(2)
                                else
                                    t.incrNIA(1)
                }
        # REPEAT UNTIL ALL WAITING
        '@RAW':   {
                    f:['@RAW COUNT']
                    d:'11010001dddddddd'
                    e:(t,v)->
                        acc = t.ls.getACC()
                        bceMask = acc & 0x01fffffe
                        bw = t.regBusyWait.get32()
                        # "Waiting" means bit is 0 (not busy)
                        # All waiting = none of the selected bits are set
                        if (bw & bceMask) == 0
                            t.incrNIA(2)  # condition met
                        else
                            t.incrNIA(1)  # timeout
                }
        # REPEAT UNTIL ANY INDICATOR
        '@RNI':   {
                    f:['@RNI COUNT']
                    d:'11011000dddddddd'
                    e:(t,v)->
                        acc = t.ls.getACC()
                        bceMask = acc & 0x01fffffe
                        ind = t.regIndicator.get32()
                        if (ind & bceMask) != 0
                            t.incrNIA(2)  # any indicator set
                        else
                            t.incrNIA(1)  # timeout
                }
        # REPEAT UNTIL ANY WAITING
        '@RNW':   {
                    f:['@RNW COUNT']
                    d:'11011001dddddddd'
                    e:(t,v)->
                        acc = t.ls.getACC()
                        bceMask = acc & 0x01fffffe
                        bw = t.regBusyWait.get32()
                        # Any waiting = any selected bit is 0
                        if (~bw & bceMask) != 0
                            t.incrNIA(2)  # at least one waiting
                        else
                            t.incrNIA(1)  # timeout
                }

        #
        # SPECIAL INSTRUCTIONS
        #

        # WAIT
        # OP=1011, I=0: Set MSC Busy/Wait bit to 0 (WAIT state).
        # PC is incremented to point to next instruction.
        '@WAT':   {
                    f:['@WAT']
                    d:'1011000000000000'
                    e:(t,v)->
                        # Set MSC busy/wait bit 0 to WAIT (0)
                        bw = t.regBusyWait.get32()
                        bw = bw & ~1  # clear bit 0
                        t.regBusyWait.set32(bw)
                        # Update MSC status register bit 17 (busy/wait copy)
                        st = t.ls.MST().get32()
                        st = st & ~1  # clear bit 17 (LSB) = wait
                        t.ls.MST().set32(st)
                        t.incrNIA(1)
                }
        # DELAY
        # OP=1011, I=1: Delay for count * 2us. In simulator, just advance NIA.
        # Short format 1: displacement is the count
        '@DLY':   {
                    f:['@DLY COUNT']
                    d:'1011iddddddddddd'
                    e:(t,v)->
                        # In the simulator, delay is a no-op - just advance PC
                        t.incrNIA(1)
                }
        # INTERRUPT CPU
        # OP=0011, I=interrupt level extension
        # Lower 12 bits are the interrupt list
        '@INT':   {
                    f:['@INT IL']
                    d:'0011Illlllllllll'
                    e:(t,v)->
                        il = v.l & 0xfff
                        if v.I
                            # OR with X register
                            xval = t.ls.X().get32()
                            il = il | (xval & 0xfff)
                        # Load into IOP Programmable Interrupt Register
                        t.msc.regIntProg.set32(il)
                        # Signal CPU interrupt if any bits are set
                        if il != 0 and t.cpu?
                            t.cpu.intPending.iopProg = true
                        t.incrNIA(1)
                }
        # SELF TEST - MSC
        # OP=0001, I=0
        '@STP':   {
                    f:['@STP']
                    d:'0001000000000000'
                    e:(t,v)->
                        # Self-test is a no-op in the simulator
                        # Set GO result (no error detected)
                        pe = t.regProgExcept.get32()
                        pe = pe | 1  # bit 0 = MSC, 1 = GO
                        t.regProgExcept.set32(pe)
                        t.incrNIA(1)
                }
    }
