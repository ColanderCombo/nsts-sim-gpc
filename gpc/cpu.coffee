
require 'com/util'
import {RAM,Register,RegisterFile,ProgramStatusWord} from 'gpc/regmem'
import {MCM} from 'gpc/mcm'
import Instruction from 'gpc/cpu_instr'

_now = if typeof window != 'undefined' and window.performance? then (-> window.performance.now()) else (-> Date.now())

ADDR_HALFWORD = 1
ADDR_FULLWORD = 2
ADDR_DBLEWORD = 3

OPTYPE_DATA = 1
OPTYPE_BRCH = 2
OPTYPE_SHFT = 4

export class CPU
  #
  #   The CPU is microprogram-controlled and provides 32-bit, parallel data 
  # flow, floating point arithmetic, and 40,960 36-bit words of core main
  # storage in a single LRU (line replacable unit). The processing capability
  # is 480,000 operations per second based on a typical distribution of
  # instructions. The instruction repertoire includes short- and extended-
  # precision floating point, conversion, input/output, fixed point, shifting,
  # and logic operations.
  #
  #   The modular memory consists of pluggable modules containing 8192 18-bit
  # halfwords. The failure of any module is detectable by self-test and built-
  # in test hardware.
  #
  #   During periods of time when the CPU is operating below its processing
  # capacity, power-switching places the memory in a low-power, quiescent mode
  # when the memory is not addressed.
  #
  constructor: () ->
    @mainStorage = new MCM(40*1024)
    @ram = @mainStorage
    @regFiles = [
        new RegisterFile("r0",8,32), # R0 - R7   fixed bank 0
        new RegisterFile("r1",8,32), # R8 - R15  fixed bank 1
        new RegisterFile("f1",8,32)  # FP0 - FP7 float]
    ]
    @psw = new ProgramStatusWord()

    # Interrupt pending flags by priority
    @intPending = {
        powerTransient: false    # Group 0 - highest
        systemReset: false       # Group 0
        ipl: false               # Group 0
        machineCheck: false      # Group 0
        programCheck: false      # Groups 1-3 (use intCode to distinguish)
        svc: false               # Group 1
        clk1: false              # Group 4
        clk2: false              # Group 5
        ext1: false              # External interrupt 1
        ext2: false              # External interrupt 2
        ext3: false              # External interrupt 3
        ext4: false              # External interrupt 4
        iopGrp1: false           # IOP Group 1
        iopGrp2: false           # IOP Group 2
        iopProg: false           # IOP Programmable
    }
    @intCode = 0                 # Interrupt code for program check
    @halUCP = null               # HalUCP instance for SVC interception

    # Hardware counters
    @counter1 = 0                # Counter 1 (PSA 00B0)
    @counter2 = 0                # Counter 2 (PSA 00B1)
    @counter1Enabled = false
    @counter2Enabled = false

  r: (x) -> @regFiles[@psw.getRegSet()].r(x)
  f: (x) -> @regFiles[2].r(x)

  setNIA: (x) -> @psw.setNIA(x)

  incrNIA: (incr=1) -> @setNIA(@psw.getNIA()+incr)
  computeCCarith: (v1,v2) ->
      sv1 = v1 | 0
      sv2 = v2 | 0
      if sv1 == sv2
          @psw.setCC(0)
      else if sv1 < sv2
          @psw.setCC(3)
      else
          @psw.setCC(1)

  computeCClogical: (result) ->
      if result == 0
          @psw.setCC(0)
      else
          @psw.setCC(3)


  DSR: 0
  BSR: 1

  swapPSW: (oldAddr, newAddr) ->
    @ram.set32(oldAddr  ,@psw.psw1.get32())
    @ram.set32(oldAddr+2,@psw.psw2.get32())
    @psw.load(@ram.get32(newAddr  ),
              @ram.get32(newAddr+2))

  sendToIOP: (cmd, data) ->
    @iop.recvFromCPU(cmd, data)

  recvFromIOP: () -> @iop.regCCData.get32()

  INT_addressSpec: () ->
    # Interrupt:             CPU address specification
    # Interrupt Priority:    7
    # Class:                 PE
    # Old PSW:               0048 (Contains address of next instruction or
    #                             second half of existing full-word instruction)
    # New PSW:               004C
    # Not Maskable:          X
    # Mask Bit:              -
    # Pending:               -
    # Interrupt Code:        0003
    # Interrupt Accept Time: Immediate
    # CPU/IOP/AGE Generated: CPU
    #
    @psw.setIntCode(0x003)
    @swapPSW(0x0048, 0x004c)

  INT_illegalOperation: () ->
    # Interrupt:             Illegal operation
    # Interrupt Priority:    11
    # Class:                 PE
    # Old PSW:               0048
    # New PSW:               004C
    # Not Maskable:          X
    # Mask Bit:              -
    # Pending:               -
    # Interrupt Code:        0000
    # Interrupt Accept Time: During instr fetch
    # CPU/IOP/AGE Generated: CPU
    #
    @psw.setIntCode(0x000)
    @swapPSW(0x0048,0x004c)


  INT_privilegedInstruction: () ->
    # Interrupt:             Privileged instruction
    # Interrupt Priority:    11
    # Class:                 PE
    # Old PSW:               0048
    # New PSW:               004C
    # Not Maskable:          X (Only occurs when in problem state: PSW 48=1)
    # Mask Bit:              -
    # Pending:               -
    # Interrupt Code:        0001
    # Interrupt Accept Time: During addr generation
    # CPU/IOP/AGE Generated: CPU
    #
    @psw.setIntCode(0x001)
    @swapPSW(0x0048,0x004C)


  INT_supervisorCall: () ->
    # Interrupt:             Supervisor Call
    # Interrupt Priority:    12
    # Class:                 SC
    # Old PSW:               0058
    # New PSW:               005C
    # Not Maskable:          X
    # Mask Bit:              -
    # Pending:               0
    # Interrupt Code:        0
    # Interrupt Accept Time: Address Generation
    # CPU/IOP/AGE Generated: CPU
    #
    @swapPSW(0x0058, 0x005c)

  INT_CLK1: () ->
    # Interrupt:             Real-time CLK 1
    # Interrupt Priority:    14
    # Class:                 SYS
    # Old PSW:               0060
    # New PSW:               0064
    # Not Maskable:          -
    # Mask Bit:              32
    # Pending:               X
    # Interrupt Code:        -
    # Interrupt Accept Time: End of instr
    # CPU/IOP/AGE Generated: CPU
    #
    @swapPSW(0x0060, 0x0064)

  INT_CLK2: () ->
    # Interrupt:             Real-time CLK 2
    # Interrupt Priority:    15
    # Class:                 SYS
    # Old PSW:               0068
    # New PSW:               006C
    # Not Maskable:          -
    # Mask Bit:              33
    # Pending:               X
    # Interrupt Code:        -
    # Interrupt Accept Time: End of instr
    # CPU/IOP/AGE Generated: CPU
    #
    @swapPSW(0x0068, 0x006c)

  checkInterrupts: () ->
      # Check highest priority first

      # Group 0: Non-maskable (always serviced)
      if @intPending.machineCheck
          if @psw.getMachCheckMask()  # Machine check mask (PSW bit 45)
              @intPending.machineCheck = false
              @psw.setIntCode(0x0008)
              @swapPSW(0x0040, 0x0044)
              return

      # Program check: Non-maskable (except FP exceptions which are pre-filtered by signal methods)
      if @intPending.programCheck
          @intPending.programCheck = false
          @psw.setIntCode(@intCode)
          @swapPSW(0x0048, 0x004c)
          return

      # SVC: Non-maskable
      if @intPending.svc
          @intPending.svc = false
          @swapPSW(0x0058, 0x005c)
          return

      # External interrupts: Maskable via PSW bits 32-39
      intMask = @psw.getIntMask()

      # CLK1: Mask bit 32 (intMask bit 0, value 0x80)
      if @intPending.clk1 and (intMask & 0x80)
          @intPending.clk1 = false
          @swapPSW(0x0060, 0x0064)
          return

      # CLK2: Mask bit 33 (intMask bit 1, value 0x40)
      if @intPending.clk2 and (intMask & 0x40)
          @intPending.clk2 = false
          @swapPSW(0x0068, 0x006c)
          return

      # External 1: Mask bit 38 (intMask bit 6, value 0x02)
      if @intPending.ext1 and (intMask & 0x02)
          @intPending.ext1 = false
          @swapPSW(0x0070, 0x0074)
          return

      # IOP Group 1: Mask bit 35 (intMask bit 3, value 0x10)
      if @intPending.iopGrp1 and (intMask & 0x10)
          @intPending.iopGrp1 = false
          @swapPSW(0x0078, 0x007c)
          return

      # IOP Group 2: Mask bit 36 (intMask bit 4, value 0x08)
      if @intPending.iopGrp2 and (intMask & 0x08)
          @intPending.iopGrp2 = false
          @swapPSW(0x0080, 0x0084)
          return

      # IOP Programmable: Mask bit 37 (intMask bit 5, value 0x04)
      if @intPending.iopProg and (intMask & 0x04)
          @intPending.iopProg = false
          @swapPSW(0x0088, 0x008c)
          return


  signalFixedOverflow: () ->
      if @psw.getFixedPtOverflow()  # PSW bit 20 = 1 means enabled
          @intPending.programCheck = true
          @intCode = 0x0002  # Fixed-point overflow

  signalExponentOverflow: () ->
      # Always interrupt (not maskable)
      @intPending.programCheck = true
      @intCode = 0x0005

  signalExponentUnderflow: () ->
      if @psw.getExponentUnderflow()  # PSW bit 22 = 1 means enabled
          @intPending.programCheck = true
          @intCode = 0x0006

  signalSignificance: () ->
      if @psw.getSignificanceMask()  # PSW bit 23 = 1 means enabled
          @intPending.programCheck = true
          @intCode = 0x0007

  signalIllegalOp: () ->
      @intPending.programCheck = true
      @intCode = 0x0000

  signalPrivilegedOp: () ->
      @intPending.programCheck = true
      @intCode = 0x0001

  signalProtectionViolation: () ->
      @intPending.programCheck = true
      @intCode = 0x0004

  signalAddressingException: () ->
      @intPending.programCheck = true
      @intCode = 0x0003

  i_SUPER: () ->
      if @psw.getProblemState() == 1   # problem state == not supervisor
          @signalPrivilegedOp()
          return false
      return true

  g_EA: (v) ->
      if v.niaIncr == 2 and not v.I?
          # RS extended/indexed addressing
          #
          #   There are two major classes of RS instructions, extended and
          # indexed addressing modes, differing in the techniques used to
          # specify the second operand. See Figure 2-11.
          #
          #   Extended addressing is specified when RS format bit 13 (AM) 
          # equals 0. This addressing mode provides a full 16-bit halfword
          # displacement. The base and displacement are aligned as shown in 
          # Figure 2-12 when base addressing is performed.
          #
          #   Aside from the size and alignment of the displacement, RS
          # extended addressing differs from SRS addressing in two other
          # respects:
          #
          #   1) The alignment of the displacenemtn is the same whether 
          #      addressing double word, fullword or halfword operands.
          #
          #   2) When B2 equals 11, base addressing is not performed. In this
          #      case the displacement is instead used directly as the 
          #      address. Then the resulting 16-bit EA is expanded (See
          #      Expanded Addressing) to a 19-bit EA. Bit 15 of the operand
          #      effective address is always treated as zero when addressing
          #      fullword operands.
          #
          #   Indexed addressing is specified by RS format bit 13 (AM) equal
          # to 1. This addressing mode contains three additional fields.
          # Normally, they contribute to the effective address generation as
          # follows:
          #
          #   X     This 3-bit field specifies one of seven general registers
          #         containing the index. Indexing is not performed when X is
          #         equal to 000. An index is contained in the upper halfword
          #         of a general register. The index is automatically aligned
          #         as illustrated in Figure 2-13. For additional information
          #         on index alignment, see Section 14. Consistent with the
          #         restrictions that apply to register usage and indirect
          #         addressing, general register contents can be used inter-
          #         changeably as either a base or an index or both. When
          #         indirect addressing is specified, indexing follows 
          #         indirect addressing.
          #
          #   IA    This format bit, when a one, specifies indirect 
          #         addressing. Indirect addressing is not performed when this
          #         bit is zero.
          #
          #   I     This format bit, in conjunction with X and IA, specifies
          #         various addressing modes which are explained below.
          #
          #   The development of the EA for the indexed mode of operand 
          # addressing is explained in detail in the subsequent steps:
          #
          #   1)    Indexed addressing is specified by RS format bit 13 (AM)
          #         equal to 1. This addressing mode provides an 11-bit
          #         displacement. The base and displacement are aligned as 
          #         shown in Figure 2-14 when indexed addressing is performed.
          #
          #         The displacement is aligned so that bit 31 corresponds to
          #         base or index bit 15 and displacement bit 21 corresponds
          #         to base or index bit 5. The displacement is expanded to 
          #         16 bits by appending five leading zeros.
          #
          #   2)    If B2 is not equal to 11, the 16-bit base, contained in
          #         the higher order half of the specified register, is added
          #         to the aligned displacement. This results in a prelim-
          #         inary effective address (PEA) whereby the PEA = (B) +
          #         Displacement.
          #
          #         If B2 is equal to 11, the aligned displacement is added 
          #         to zero. This result is the preliminary effective address
          #         (PEA), whereby the PEA=Displacement.
          #

          disp = v.d

          # extended
          if v.b == 3 # B2 == 11 -> no base addressing
              base = 0
          else
              base = @r(v.b).get32() >>> 16
          pea = base+disp

        #   console.log "#{v.nm} g_EA: B2=#{base} D=#{disp} X=#{v.i} ii=#{v.ii} ia=#{v.ia}",
        #   console.log "\td=#{v.d} b=#{v.b} baseR=#{@r(v.b).get32()}"
        #   console.log v

          if v.i?
              # console.log "g_EA: INDEXED"
              # indexed
              if v.i == 0
                  # console.log "g_EA X=0"
                  # Indexing is not performed when X is equal to 000.
                  index = 0

                  # 3) If the X field is all zeros, IA (bit 19) is a zero and
                  #    I (bit 20) is a zero, then the 16-bit result of Step 2
                  #    is added to the contents of the updated instruction
                  #    counter (IC) to form the 16-bit EA whereby 
                  #    EA = updated IC + PEA*. (This EA is then expanded to a
                  #    19-bit EA, as explained in the Expanded Addressing 
                  #    section, the the exception that the Branch Sector
                  #    Register (BSR) bits are used instead of the Data
                  #    Sector Register (DSR) bits.)
                  #
                  #    * Usage of B2 equal to 11 (no base) is encouraged in 
                  #      the relative addressing mode. Usage of B2 not equal
                  #      to 11 may be changed in figure computers.
                  #
                  if v.ii==0 and v.ia==0
                      ea = @psw.getNIA() + pea

                  # 4) If the X field is all zeros, IA (bit 19) is a zero and
                  #    and I (bit 20) is a one, the 16-bit result of Step 2 is
                  #    subtracted from the contents of the updated IC to form
                  #    the 16-bit EA whereby EA=(updated) IC - PEA*. (This EA
                  #    is then expanded to a 19-bit EA, as explained in the 
                  #    Expanded Addressing section with the exception that the
                  #    Branch Sector Register (BSR) bits are used instead of
                  #    the Data Sector Register (DSR) bits.)
                  #
                  if v.ia==0 and v.ii==1
                      ea = @psw.getNIA() - pea

                  # 5) If the X field is all zeros, IA (bit 19) is a one and
                  #    I (bit 20) is a zero, then Indirect Addressing is 
                  #    performed. The 16-bit result of Step 2 is expanded
                  #    to a 19-bit address and is used as the address of a
                  #    main-storage halfword. This halfword is then fetched
                  #    and expanded to 19-bits by using expanded addressing
                  #    to form the EA. EA<-MS(PEA). Functional equivalency to
                  #    preindexing capability can be optained through
                  #    modification of the base.
                  #
                  if v.ia==1 and v.ii==0
                      indirectAddr = @g_EXPAND(pea,OPTYPE_DATA)
                      indirectHW = @ram.get16(indirectAddr)
                      ea = @g_EXPAND(indirectHW,v.opType)

                  # 6) If the X field is all zeros, IA (bit 19) is a one and
                  #    I (bit 20) is a one, Indirect Addressing is performed
                  #    as described in Step 5 with a full word main storage
                  #    pointer.  Then, storage modification is automatically
                  #    performed. The indirect address is contained in a full
                  #    word and must have an even addres. A modifier is 
                  #    contained in bits 16 through 32. The modifier is added
                  #    to the address and the resulting modified address 
                  #    replaces bits 0 through 15 of the indirect address
                  #    word. (See Figure 2-15.)
                  if v.ia==1 and v.ii==1
                      indirectAddr = @g_EXPAND(pea,OPTYPE_DATA)
                      indirectFW = @ram.get32(indirectAddr)
                      ea = indirectFW >>> 16
                      modifier = indirectFW & 0xffff
                      ea = @g_EXPAND(ea,v.opType)
                      ea = ea + modifier
                      @ram.set32(indirectAddr,(ea<<16) + modifier)

              else
                  #console.log "g_EA X!=0, DO INDEXING"
                  # v.i != 0, indexing performed

                  # 7) If the X field is not all zeros, IA (bit 19) is a zero
                  #    and I (bit 20) is a zero, the most significant 16-bits
                  #    of the general register specified by the X field are
                  #    aligned, and then added to the 16-bit result of Step 2
                  #    (PEA)    to form the 16-bit EA (see Figure 2-13). (This
                  #    EA is then expanded to a 19-bit EA, as explained in the
                  #    Expanded Addressing section.)
                  if v.ia==0 and v.ii==0
                      regx = (@r(v.i).get32() >>> 16) << (v.addrWidth - 1)
                      ea = pea + regx
                      ea = @g_EXPAND(ea,v.opType)
                      #console.log " regx=#{regx}, ea=#{pea+regx}, EXP=#{ea}"

                  # 8) If the X field is not all zeros, IA (bit 19) is a zero
                  #    and I (bit 20) is a one, the most significant 16 bits
                  #    of the general register specified by the X field are
                  #    aligned, and then added to the 16-bit result of Step 2
                  #    (PEA) to form the 16-bit EA (see Figure 2-13). (This 
                  #    EA is then expanded to a 19-bit EA, as explained in the
                  #    Expanded Addressing section.) (The modifier is added
                  #    to the address and the resulting modified address
                  #    replaces bits 0 through 15 of the index register after
                  #    the EA is determined.)
                  #
                  if v.ia==0 and v.ii==1
                      regx = (@r(v.i).get32() >>> 16) << (v.addrWidth - 1)
                      modifier = @r(v.i).get32() & 0xffff
                      ea16 = (pea + regx) & 0xffff
                      ea = @g_EXPAND(ea16,v.opType)
                      modifiedAddr = (ea16 + modifier) & 0xffff
                      @r(v.i).set32((modifiedAddr << 16) + modifier)


                  # 9) If the X field is not all zeros, IA (bit 19) is a one 
                  #    and I (bit 20) is a zero, Indirect Addressing (IA) with
                  #    post-indexing is performed. The 16-bit result of Step 2
                  #    is expanded to a 19-bit address and is used to fetch a
                  #    main storage halfword. The index contained in the
                  #    general register specified by X is aligned and then
                  #    added to the fetched halfword to form the 16-bit EA
                  #    (see Figure 2-13). This EA is then expanded to a 19-bit
                  #    EA by using expanded addressing. Functional equivalency
                  #    to preindexing capability can be obtained through 
                  #    modification of the base.
                  #
                  if v.ia==1 and v.ii==0
                      indirectAddr = @g_EXPAND(pea,OPTYPE_DATA)
                      indirectHW = @ram.get16(indirectAddr)
                      regx = (@r(v.i).get32() >>> 16) << (v.addrWidth - 1)
                      ea = indirectHW + regx
                      ea = @g_EXPAND(ea,v.opType)

                  #10) If the X field is not all zeros, IA (bit 19) is a one
                  #    and I (bit 20) is a one, a direct addressing mode is
                  #    defined using a 32-bit fullword indirect address 
                  #    pointer as follows:
                  #
                  #   a) First, the PEA from Step 2 must locate a fullword
                  #      indirect address pointer, with the format as 
                  #      illustrated in Figure 2-17.
                  #
                  # -----------------------------------------------------------------
                  # |1|    Address                  |Reserve|X|C|C|C|  BSR  |  DSR  |
                  # | | | | | | | | | | | | | | | | |0|0|0|0|C| |B|D|0| | | |0| | | |
                  # -----------------------------------------------------------------
                  #  0 1                          1516    192021222324    2728    31
                  #
                  #               Field   Function
                  #               -----   --------
                  #                XC     Index Control
                  #                C      Control
                  #                CB     Control BSR Usage
                  #                CD     Control DSR Usage
                  #
                  #   b) If C (bit 21) equals 0, XC (bit 20) equals 1, and 
                  #      the instruction is not a branch type instruction,
                  #      the 19-bit EA equals the 4-bit DSR with the 15-bit
                  #      address field appended. When C (bit 21) eqals 0, XC
                  #      (bit 20) equals 0, and the instruction is not a
                  #      branch type instruction, the 19-bit EA equals equals
                  #      the 15-bit address field added to the index value in
                  #      indexing register X with the result appended to the
                  #      fullword indirect address pointers DSR. The current
                  #      PSW's DSR is not changed.
                  #
                  #      If C (bit 21) equals 0 and the instruction is a 
                  #      branch type instruction, the current PSW's BSR in
                  #      conjunction with bits 0 through 15 of the fullword
                  #      indirect address pointer will be used to form the BA.
                  #      If XC = 0, post-indexing will occur. When C (bit 21)
                  #      equals zero, CB and CD are reserved and should be set
                  #      to zero.
                  #
                  #   c) If C (bit 21) equals 1 and the instruction is a 
                  #      branch type instruction and the branch is taken, the
                  #      BSR and DSR fields selectively replace the corre-
                  #      sponding fields in the current PSW, based on the CB
                  #      and CD bit values as follows:
                  #
                  #   CB    CD              Result
                  #   --    --              ------
                  #   0     0     Use current PSW's BSR to form the BA.
                  #   0     1     Replace the current PSW's DSR with this DSR.
                  #               Form the BA normally.
                  #   1     0     Replace the current PSW's BSR with this BSR
                  #               before forming the BA.
                  #   1     1     First, replace the current PSW's DSR with
                  #               this DSR. Then, replace the current PSW's
                  #               BSR with this BSR before forming the BA.
                  #
                  #   d) When C (bit 21) equals 1 and XC (bit 20) equals 1,
                  #      postindexing is not performed. When C (bit 21) equals
                  #      1 and XC (bit 20) equals 0, the BA calculation 
                  #      includes the final addition of the index value in 
                  #      index registers X.
                  #
                  #      If C (bit 21) equals 1, XC equals 1, and the 
                  #      instruction is not a branch, the 19-bit EA equals 
                  #      the curent PSW's DSR and the 15-bit field appended.
                  #      If XC=0, postindexing will occur.
                  #
                  if v.ia==1 and v.ii==1
                      indirectAddr = @g_EXPAND(pea,OPTYPE_DATA)
                      indirectFW = @ram.get32(indirectAddr)
                      # Parse fullword indirect address pointer fields
                      # Bit layout (bit 0 = MSB):
                      #   0-15:  Address (bit 0 is always 1 for expansion)
                      #   16-19: Reserved
                      #   20:    XC (Index Control)
                      #   21:    C (Control)
                      #   22:    CB (Control BSR Usage)
                      #   23:    CD (Control DSR Usage)
                      #   24-27: BSR
                      #   28-31: DSR
                      address16 = (indirectFW >>> 16) & 0xffff
                      address15 = address16 & 0x7fff  # 15-bit address (strip bit 0)
                      xc = (indirectFW >>> 11) & 1    # bit 20
                      c = (indirectFW >>> 10) & 1     # bit 21
                      cb = (indirectFW >>> 9) & 1     # bit 22
                      cd = (indirectFW >>> 8) & 1     # bit 23
                      ptrBSR = (indirectFW >>> 4) & 0x7  # bits 24-27 (bit 24 always 0)
                      ptrDSR = indirectFW & 0x7          # bits 28-31 (bit 28 always 0)
                      
                      regx = (@r(v.i).get32() >>> 16) << (v.addrWidth - 1)  # aligned index register value

                      if c == 0
                          # C=0: use pointer's BSR/DSR for data, current PSW's BSR for branches
                          if v.opType == OPTYPE_BRCH
                              # Branch: use current PSW's BSR
                              if xc == 0
                                  # Post-indexing
                                  ea = (address15 + regx) & 0x7fff
                                  ea = (@psw.getBSR() << 15) + ea
                              else
                                  # No post-indexing
                                  ea = (@psw.getBSR() << 15) + address15
                          else
                              # Data instruction: use pointer's DSR
                              if xc == 0
                                  # Post-indexing
                                  ea = (address15 + regx) & 0x7fff
                                  ea = (ptrDSR << 15) + ea
                              else
                                  # No post-indexing: ptrDSR || address15
                                  ea = (ptrDSR << 15) + address15
                      else
                          # C=1: selectively update PSW BSR/DSR based on CB/CD
                          if cd == 1
                              @psw.setDSR(ptrDSR)
                          if cb == 1
                              @psw.setBSR(ptrBSR)
                          
                          if v.opType == OPTYPE_BRCH
                              # Branch: use (possibly updated) PSW's BSR
                              if xc == 0
                                  # Post-indexing
                                  ea = (address15 + regx) & 0x7fff
                                  ea = (@psw.getBSR() << 15) + ea
                              else
                                  # No post-indexing
                                  ea = (@psw.getBSR() << 15) + address15
                          else
                              # Data instruction: use (possibly updated) PSW's DSR
                              if xc == 0
                                  # Post-indexing
                                  ea = (address15 + regx) & 0x7fff
                                  ea = (@psw.getDSR() << 15) + ea
                              else
                                  # No post-indexing
                                  ea = (@psw.getDSR() << 15) + address15
                  
              #ea = pea + index & 0xffff
          else
              ea = pea
              ea = @g_EXPAND(ea,v.opType)

      else
          # SRS or SI addressing
          base = @r(v.b).get32() >>> 16
          disp = v.d << (v.addrWidth-1)
          ea = base+disp
          if v.addrWidth == 2
              ea = ea & 0xfffe  # mask off bit 15 for fullwords
          # Use DSE for base registers 0-2; register 3 means no base
          if v.b? and v.b != 3
              dseVal = @regFiles[@psw.getRegSet()].getDSE(v.b)
              ea = @g_EXPAND_DSE(ea, v.opType, dseVal)
          else
              ea = @g_EXPAND(ea,v.opType)

          # console.log "SRS", base, disp , ea


      # console.log "\tEXPAND", ea.toString(16)
      return ea

  # g_EA_16: Compute a 16-bit effective address WITHOUT final expansion
  # to 19 bits. Used by LA and IAL per AP-101S spec: "A 16-bit effective
  # halfword address is developed in the normal manner without expanding
  # to 19-bits."
  # Intermediate expansions (for indirect memory lookups) still expand
  # so we can read the correct memory location.
  g_EA_16: (v) ->
      # Raw 16-bit IC from PSW (not expanded to 19-bit)
      ic16 = @psw._getField1(@psw.pack1.desc.f.p)

      if v.niaIncr == 2 and not v.I?
          # RS extended/indexed addressing
          disp = v.d

          if v.b == 3
              base = 0
          else
              base = @r(v.b).get32() >>> 16
          pea = base + disp

          if v.i?
              # indexed
              if v.i == 0
                  index = 0

                  # Step 3: IC-relative, forward: EA = IC + PEA (16-bit)
                  if v.ii==0 and v.ia==0
                      ea = (ic16 + pea) & 0xffff

                  # Step 4: IC-relative, backward: EA = IC - PEA (16-bit)
                  if v.ia==0 and v.ii==1
                      ea = (ic16 - pea) & 0xffff

                  # Step 5: Indirect halfword (expand for memory lookup, not for result)
                  if v.ia==1 and v.ii==0
                      indirectAddr = @g_EXPAND(pea, OPTYPE_DATA)
                      indirectHW = @ram.get16(indirectAddr)
                      ea = indirectHW & 0xffff

                  # Step 6: Indirect fullword with modification (expand for memory lookup)
                  if v.ia==1 and v.ii==1
                      indirectAddr = @g_EXPAND(pea, OPTYPE_DATA)
                      indirectFW = @ram.get32(indirectAddr)
                      ea = (indirectFW >>> 16) & 0xffff
                      modifier = indirectFW & 0xffff
                      ea = (ea + modifier) & 0xffff
                      @ram.set32(indirectAddr, (ea << 16) + modifier)

              else
                  # v.i != 0, indexing performed

                  # Step 7: Indexed, no indirect
                  if v.ia==0 and v.ii==0
                      regx = (@r(v.i).get32() >>> 16) << (v.addrWidth - 1)
                      ea = (pea + regx) & 0xffff

                  # Step 8: Indexed with modification
                  if v.ia==0 and v.ii==1
                      regx = (@r(v.i).get32() >>> 16) << (v.addrWidth - 1)
                      modifier = @r(v.i).get32() & 0xffff
                      ea = (pea + regx) & 0xffff
                      modifiedAddr = (ea + modifier) & 0xffff
                      @r(v.i).set32((modifiedAddr << 16) + modifier)

                  # Step 9: Indirect with post-indexing (expand for memory lookup)
                  if v.ia==1 and v.ii==0
                      indirectAddr = @g_EXPAND(pea, OPTYPE_DATA)
                      indirectHW = @ram.get16(indirectAddr)
                      regx = (@r(v.i).get32() >>> 16) << (v.addrWidth - 1)
                      ea = (indirectHW + regx) & 0xffff

                  # Step 10: ZCON fullword indirect pointer
                  # Return 16-bit address portion (bits 0-15 of pointer)
                  if v.ia==1 and v.ii==1
                      indirectAddr = @g_EXPAND(pea, OPTYPE_DATA)
                      indirectFW = @ram.get32(indirectAddr)
                      address16 = (indirectFW >>> 16) & 0xffff
                      xc = (indirectFW >>> 11) & 1
                      regx = (@r(v.i).get32() >>> 16) << (v.addrWidth - 1)
                      if xc == 0
                          ea = (address16 + regx) & 0xffff
                      else
                          ea = address16 & 0xffff

          else
              # Non-indexed extended: no expansion
              ea = pea & 0xffff

      else
          # SRS or SI addressing: no expansion
          base = @r(v.b).get32() >>> 16
          disp = v.d << (v.addrWidth - 1)
          ea = base + disp
          if v.addrWidth == 2
              ea = ea & 0xfffe
          ea = ea & 0xffff

      return ea

  g_EXPAND: (ea, bsrdsr=OPTYPE_DATA) ->
      # EXPANDED ADDRESSING
      #
      #   The addressing philosophy accommodates 64K* halfword addresses
      # since a full 16-bit address is provided. Extending the addressing
      # range beyond 64K halfword locations up to 512K halfword locations
      # is provided by utilizing PSW bits.
      #
      #   Expanding to 19 bits is achieved by replacing the high-order bit of
      # a 16-bit address with 4 bits, as shown in Figure 2-18. Data operand
      # addresses are extended to 19 bits by specifying either a 4-bit Data
      # Sector Register (DSR) or an implied DSR. When the high-order bit of
      # a 16-bit address is 1, a 4-bit DSR (PSW bits 28 through 31) is se-
      # lected to replace the high-order bit. When the high-order bit of a
      # 16-bit data address is a 0, an implied DSR containing 0000 is 
      # selected. Note that indirect addressing locates the indirect address
      # pointer as if the pointer were a data operand. Branch addresses are
      # extended to 19 bits in an equivalent manner. When the high-order bit
      # of a 16-bit branch address is a 1, a 4-bit Branch Sector Register 
      # (BSR-PSW bits 24 through 27) is selected to replace the high-order 
      # bit. When the high-order bit is a 0, an implied BSR containing 0000
      # is selected. The high-order bit of both the BSR and DSR must be zero.
      #
      ea = ea & 0xffff
      
      if ea & 0x8000
          if bsrdsr == OPTYPE_DATA || bsrdsr == OPTYPE_SHFT
              ea = (@psw.getDSR() << 15) + (ea & 0x7fff)
          else         # OPTYPE_BRCH
              ea = (@psw.getBSR() << 15) + (ea & 0x7fff)
      return ea

  g_EXPAND_DSE: (ea, bsrdsr, dseVal) ->
      # DSE-based expanded addressing: uses per-base-register DSE
      # instead of the PSW DSR for data operands
      ea = ea & 0xffff
      if ea & 0x8000
          if bsrdsr == OPTYPE_DATA || bsrdsr == OPTYPE_SHFT
              ea = (dseVal << 15) + (ea & 0x7fff)
          else
              ea = (@psw.getBSR() << 15) + (ea & 0x7fff)
      return ea

  g_EAF: (v, extraOffset=0) ->
      ea = @g_EA(v)+extraOffset
      value = (@ram.get16(ea) << 16) + (@ram.get16(ea+1))
      return value

  g_EAH: (v) ->
      ea = @g_EA(v)
      value = @ram.get16(ea)
      #console.log "g_EAH ea=#{ea} value=#{value}"
      return value

  s_EAF: (v, value,extraOffset=0) ->
      ea = @g_EA(v)+extraOffset
      #console.log "s_EAF", ea.toString(16), value.toString(16)
      if not @ram.set16(ea, value >>> 16)
          @signalProtectionViolation()
          return
      if not @ram.set16(ea+1, value & 0xffff)
          @signalProtectionViolation()
          return

  s_EAH: (v, value) ->
      ea = @g_EA(v)
      if not @ram.set16(ea, value)
          @signalProtectionViolation()
          return
      #console.log "s_EAH ea=#{ea}, value=#{value}"
  


  g_SHIFT_CNT: (hw1) ->
          # 6246156B/p.78
          #
          # If bits 8-13 of instruction are < 56, that's the shift count
          # Else, shift is in bits 10-15 of a general register:
          #       111000 (56) -> Bit 10-15 of R0
          #       111001 (57) -> Bit 10-15 of R1
          #           ...
          #       111111 (63) -> Bit 10-15 of R7
          #
          insBits = (hw1 >>> 2) & 0x3f  # instruction bits 8-13
          if insBits > 55
              srcReg = insBits - 56
              return (@r(srcReg).get32() >>> 16) & 0x3f
          else
              return insBits

  reset: () ->
      @psw.psw1.set32(@ram.get32(0x14))
      @psw.psw2.set32(@ram.get32(0x16))

  run: () ->
      #console.log "CPU @ #{@psw.getNIA().asHex()}: starting execution"
      ## console.log "CPU @ #{asHex(@psw.getNIA())}: starting execution"
      insCnt = 0
      while not @psw.getWaitState()
          insCnt = insCnt + 1
          @exec1()
      #console.log "CPU @ #{@psw.getNIA().asHex()}: IN WAIT MODE"
      ## console.log "CPU @ #{asHex(@psw.getNIA())}: IN WAIT MODE"
      #console.log "CPU: #{insCnt} instructions executed."

  exec1: () ->
      times = [0.0, 0.0, 0.0]
      times[0] = _now()
      nia = @psw.getNIA()

      hw1 = @ram.get16(nia)
      hw2 = @ram.get16(nia+1)
      [d,v] = Instruction.decode(hw1,hw2)

      v.niaIncr = d.len
      d.len=d.origLen

      v.hw1 = hw1
      v.hw2 = hw2

      if d.type == 'RS'
          # b2 = hw1 & bin("11")
          b2 = hw1 & "11".bin()
          # srsSig = bin("0000000011111000")
          srsSig = "0000000011111000".bin()
          if (hw1 & srsSig) == srsSig
              if not (hw1 & 4)
                  v.d = hw2
              else
                  v.i = hw2 >>> 13
                  v.ia = (hw2 >>> 12) & 1
                  v.ii = (hw2 >>> 11) & 1
                  # v.d = hw2 & bin("0000011111111111")
                  v.d = hw2 & "0000011111111111".bin()

      @incrNIA(v.niaIncr)

      # Instruction monitor: PSW bit 34 = 1 and instruction is unprotected
      intMask = @psw.getIntMask()
      if (intMask & 0x20) and not @ram.protData[nia]
          @intPending.programCheck = true
          @intCode = 0x0009

      if d.e?
          d.e(@,v)
      # Decrement hardware counters and check for interrupt
      if @counter1Enabled
          @counter1--
          if @counter1 <= 0
              @counter1 = @ram.get16(0x00B0) << 16  # Reload from PSA high halfword
              @intPending.clk1 = true
      if @counter2Enabled
          @counter2--
          if @counter2 <= 0
              @counter2 = @ram.get16(0x00B1) << 16
              @intPending.clk2 = true

      # Check and service pending interrupts
      @checkInterrupts()

      times[1] = _now()
      times[2] = times[1] - times[0]

