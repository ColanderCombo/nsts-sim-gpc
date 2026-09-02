
require 'com/util'
import {RAM,Register,RegisterFile,ProgramStatusWord} from 'gpc/regmem'
import {MCM} from 'gpc/mcm'
import Instruction from 'gpc/cpu_instr'
import {INTERRUPTS, INTERRUPT_METHODS, INT_BITS_NONMASKABLE, INT_MACHINE_CHECK,
        INT_INSTR_MONITOR, INT_CLK1, INT_CLK2} from 'gpc/cpu_intr'

_now = if typeof window != 'undefined' and window.performance? then (-> window.performance.now()) else (-> Date.now())

ADDR_HALFWORD = 1
ADDR_FULLWORD = 2
ADDR_DBLEWORD = 3

OPTYPE_DATA = 1
OPTYPE_BRCH = 2
OPTYPE_SHFT = 4

# IOP timeslice wakeup:
#  the IOP is an independent processor, so it gets one slice per
#  IOP_SLICE_NS of elapsed time, whether the CPU is executing or waiting.
# A BCE comes round once every 33 slices, and the BCE delay and 
# time-out counters have a resolution of 16.5 us  which puts the slice 
# itself at half a microsecond:
export IOP_SLICE_NS = 500

export class CPU
  @POWER_ON_PSW: 0x0004
  @SYSTEM_RESET_PSW: 0x0014

  @INTERRUPTS: INTERRUPTS

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
  constructor: (opts = {}) ->
    @mainStorage = new MCM(opts.cpuWords ? 40*1024)
    @ram = @mainStorage
    @regFiles = [
        new RegisterFile("r0",8,32), # R0 - R7   fixed bank 0
        new RegisterFile("r1",8,32), # R8 - R15  fixed bank 1
        new RegisterFile("f1",8,32)  # FP0 - FP7 float]
    ]
    @psw = new ProgramStatusWord()

    @_initInterrupts()           # see gpc/cpu_intr.coffee

    # Storage protect override (POO 9.2, ISPB programming notes): an ISPB
    # with an illegal M1 (100-111) "leaves the storage protect override
    # bit set on, which means that storage protected locations can be
    # written into without getting a store protect violation.  The
    # condition will occur until the next valid ISPB is executed."
    @storeProtectOverride = false
    @halUCP = null               # HalUCP instance for SVC interception

    # DIAGNOSE state (POO sect.15).  The interrupt page's scan register
    # doubles as its Diagnose Error register: the EA Scan 5 assist reads it
    # and clears it, and nothing in a fault-free machine ever sets a bit in
    # it.  'diagIuStoreDetect' is B STAT bit 6, set/reset by DIAG 7100/7101
    @diagScanReg = 0
    @diagIuStoreDetect = true
    # The stale halfwords the IU file holds while detection is off.
    # Null whenever the machine is behaving normally:
    @iuShadow = null
    @curIC = 0

    # Program interval timers (POO 2.5.2 "System" interrupts).  Each is a
    # 32-bit counter decrementing once per microsecond of CPU time.  The
    # low halfword lives in a hardware counter (here), the high halfword
    # in main store at 00B0 (counter 1) / 00B1 (counter 2).
    @counter1 = 0xffff           # Counter 1 low halfword (hi at PSA 00B0)
    @counter2 = 0xffff           # Counter 2 low halfword (hi at PSA 00B1)

    # Accumulated execution time.  Instruction times (xts/xtbs/opExecT) are
    # microseconds from IBM-85-C67-001 sect.17; accumulate integer ns to
    # stay exact (all table values are multiples of 5 ns).
    @timeNs = 0                  # total CPU time since power-on
    @cntAccumNs = 0              # sub-microsecond residue for counter ticks
    @xtCase = 0                  # addressing-mode timing case of current instr
    @xtIndexed = false           # plain indexing used (AP-101B: +0.4us)
    @opExecT = null              # per-instruction override (us), set by e()
    @xtcRow = null               # B-model row override [5 x us], set by e()
    @xtcAddT = null              # B-model additive (us), set by e()

    # CPU model for instruction timing and fp behavior: 
    # 'S' (AP-101S, xts/xtbs) or
    # 'B' (AP-101B, xtc/xtcs).
    @model = 'S'
    @fpModel = opts.model ? 'S'
    @prevDiscont = false         # last instr broke sequential fetch (B: ~NOK)

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
    @loadPSW(@ram.get32(newAddr  ),
             @ram.get32(newAddr+2))

  loadPSW: (p1, p2) ->
    @psw.load(p1, p2)
    @testFixedOverflow()
    return

  # NSTS_PCO_TRACE prints every program-controlled I/O the CPU issues:
  sendToIOP: (cmd, data) ->
    if process?.env?.NSTS_PCO_TRACE
      process.stderr.write "PCO nia=#{@psw.getNIA().toString(16)} " +
        "cmd=#{(cmd >>> 0).toString(16)} data=#{(data >>> 0).toString(16)}\n"
    @iop.recvFromCPU(cmd, data)

  recvFromIOP: () -> @iop.regCCData.get32()

  reset: () ->
      @resetInterrupts()
      @clearInterruptLog()
      @storeProtectOverride = false
      @counter1 = 0xffff
      @counter2 = 0xffff
      @cntAccumNs = 0
      @timeNs = 0
      @prevDiscont = false
      return

  # System reset (POO 2.5.3.2)
  systemReset: () ->
      # XXX Power-off putaway and IPL memory fill not modeled
      @resetInterrupts()
      @storeProtectOverride = false
      @counter1 = 0xffff
      @counter2 = 0xffff
      @cntAccumNs = 0
      @loadPSW(@ram.get32(CPU.SYSTEM_RESET_PSW), @ram.get32(CPU.SYSTEM_RESET_PSW + 2))
      return @psw.getNIA()


  # Fixed point add/subtract indicators
  #
  # Every add and subtract in the repertoire carries the same two
  # sentences: "The carry indicator is set to indicate whether or not
  # there is a carry out of the high-order bit position of the general
  # register", and "The overflow indicator is set to one if the magnitude
  # of the sum is too large to be represented in the general register ...
  # If the overflow indicator already contains a one, it is not altered by
  # this instruction.  (Overflow can be reset by testing or by loading the
  # PSW.)"
  #
  # So the two differ: carry is written on every one of these instructions,
  # set or reset, while overflow is only ever set.  Self-test software
  # depends on both, priming overflow and adding 2 to FFFF to check that it
  # survived ("OFLOW SET AT ENTRY, NOT RESET BY AHI").
  #
  addFixed: (a, b, carryIn = 0) ->
      a = a >>> 0
      b = b >>> 0
      sum = a + b + carryIn        # exact: both are 32-bit, JS numbers are 53
      @psw.setCarry(if sum > 0xffffffff then 1 else 0)
      result = sum | 0             # ...then truncate to the register width
      # Signed overflow: the two addends agreed in sign and the sum did not.
      if ((a ^ result) & (b ^ result) & 0x80000000) != 0
          @signalFixedOverflow()
      return result

  subFixed: (a, b) -> @addFixed(a, ~b, 1)

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

          dseVal = @g_BASE_DSE(v, true)

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
                      # "address calculations used to form the EA are
                      # performed on the low 16 bits only" 
                      ea = @g_EXPAND(@psw.getIC16() + pea, OPTYPE_BRCH)

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
                      ea = @g_EXPAND(@psw.getIC16() - pea, OPTYPE_BRCH)

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
                      # Timing: single-level indirection has no column of its
                      # own in the sect.17 table; use the closest double-
                      # indirection case (XC=1: no post-indexing here).
                      @xtCase = 3
                      indirectAddr = @g_EXPAND(pea,OPTYPE_DATA,dseVal)
                      indirectHW = @ram.get16(indirectAddr)
                      ea = @g_EXPAND(indirectHW,v.opType,dseVal)

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
                      @xtCase = 5     # timing: auto storage modification
                      indirectAddr = @g_EXPAND(pea,OPTYPE_DATA,dseVal)
                      indirectFW = @ram.get32(indirectAddr)
                      addr16 = indirectFW >>> 16
                      modifier = indirectFW & 0xffff
                      # "Indirect Addressing is performed as described in
                      # Step 5 ... THEN, storage modification is automatically
                      # performed"
                      ea = @g_EXPAND(addr16,v.opType,dseVal)
                      modifiedAddr = (addr16 + modifier) & 0xffff
                      @ram.set32(indirectAddr,(modifiedAddr << 16) + modifier)

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
                      @xtIndexed = true   # timing (AP-101B): plain indexing
                      regx = (@r(v.i).get32() >>> 16) << (v.indexWidth - 1)
                      ea = pea + regx
                      ea = @g_EXPAND(ea,v.opType,dseVal)
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
                      @xtCase = 6     # timing: auto indexing
                      index = @r(v.i).get32() >>> 16
                      regx = index << (v.indexWidth - 1)
                      modifier = @r(v.i).get32() & 0xffff
                      ea16 = (pea + regx) & 0xffff
                      ea = @g_EXPAND(ea16,v.opType,dseVal)
                      modifiedAddr = (index + modifier) & 0xffff
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
                      # Timing: indirection with post-indexing; closest table
                      # case is double indirection XC=0 (post-indexed), C=0.
                      @xtCase = 1
                      indirectAddr = @g_EXPAND(pea,OPTYPE_DATA,dseVal)
                      indirectHW = @ram.get16(indirectAddr)
                      regx = (@r(v.i).get32() >>> 16) << (v.indexWidth - 1)
                      ea = indirectHW + regx
                      ea = @g_EXPAND(ea,v.opType,dseVal)

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
                      indirectAddr = @g_EXPAND(pea,OPTYPE_DATA,dseVal)
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
                      ptrBSR = (indirectFW >>> 4) & 0xF  # bits 24-27
                      ptrDSR = indirectFW & 0xF          # bits 28-31

                      # Timing: double indirection, case selected by (XC,C)
                      @xtCase = 1 + xc*2 + c

                      regx = (@r(v.i).get32() >>> 16) << (v.indexWidth - 1)  # aligned index register value

                      # The sector replaces the address' high-order bit.
                      # Figure 2-17 draws that bit as a literal 1 because a
                      # pointer into the upper sectors always has it set;
                      # the sect.2.2.9 rule `g_EXPAND` implements holds here
                      # too: "when the high-order bit of a 16-bit data
                      # address is a 0, and no base register is used, an
                      # implied DSR containing 0000 is selected":
                      expand = (sector, index = 0) ->
                          within = (address15 + index) & 0x7fff
                          if address16 & 0x8000 then (sector << 15) + within
                          else within

                      if c == 0
                          # C=0: use pointer's BSR/DSR for data, current PSW's BSR for branches
                          if v.opType == OPTYPE_BRCH
                              # Branch: use current PSW's BSR
                              if xc == 0
                                  ea = expand(@psw.getBSR(), regx)   # post-indexing
                              else
                                  ea = expand(@psw.getBSR())
                          else
                              # Data instruction: use pointer's DSR
                              if xc == 0
                                  ea = expand(ptrDSR, regx)          # post-indexing
                              else
                                  ea = expand(ptrDSR)
                      else
                          # C=1: selectively update PSW BSR/DSR based on CB/CD
                          if cd == 1
                              @psw.setDSR(ptrDSR)
                          if cb == 1
                              @psw.setBSR(ptrBSR)

                          if v.opType == OPTYPE_BRCH
                              # Branch: use (possibly updated) PSW's BSR
                              if xc == 0
                                  ea = expand(@psw.getBSR(), regx)   # post-indexing
                              else
                                  ea = expand(@psw.getBSR())
                          else
                              # Data instruction: use (possibly updated) PSW's DSR
                              if xc == 0
                                  ea = expand(@psw.getDSR(), regx)   # post-indexing
                              else
                                  ea = expand(@psw.getDSR())
                  
              #ea = pea + index & 0xffff
          else
              ea = pea
              ea = @g_EXPAND(ea,v.opType,dseVal)

      else
          # SRS or SI addressing
          #
          # The displacement is scaled to the operand: a fullword D2 counts
          # fullwords, so it contributes an even offset by itself.  The
          # base keeps its low bit -- "bit 15 of the operand effective
          # address is always treated as zero when addressing fullword
          # operands" belongs to RS extended addressing with B2 = 11, where
          # the displacement is the address and no base is added.  A record
          # of an odd number of halfwords puts every second instance on an
          # odd boundary, and its leading address / sector pair is loaded as
          # one fullword.
          base = @r(v.b).get32() >>> 16
          disp = v.d << (v.addrWidth-1)
          ea = base+disp
          ea = @g_EXPAND(ea, v.opType, @g_BASE_DSE(v, false))

          # console.log "SRS", base, disp , ea


      # console.log "\tEXPAND", ea.toString(16)
      return ea

  # g_EA_16: Compute a 16-bit effective address WITHOUT final expansion
  # to 19 bits. Used by LA and IAL per AP-101S spec: "A 16-bit effective
  # halfword address is developed in the normal manner without expanding
  # to 19-bits."
  # Intermediate expansions (for indirect memory lookups) still expand
  # to reach the right memory location.
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
                      @xtCase = 3     # timing: see g_EA step 5
                      indirectAddr = @g_EXPAND(pea, OPTYPE_DATA)
                      indirectHW = @ram.get16(indirectAddr)
                      ea = indirectHW & 0xffff

                  # Step 6: Indirect fullword with modification (expand for memory lookup)
                  if v.ia==1 and v.ii==1
                      @xtCase = 5     # timing: auto storage modification
                      indirectAddr = @g_EXPAND(pea, OPTYPE_DATA)
                      indirectFW = @ram.get32(indirectAddr)
                      ea = (indirectFW >>> 16) & 0xffff
                      modifier = indirectFW & 0xffff
                      # EA is the pointer as it stands; the modified value is
                      # what the pointer holds for next time.  See g_EA step 6.
                      modifiedAddr = (ea + modifier) & 0xffff
                      @ram.set32(indirectAddr, (modifiedAddr << 16) + modifier)

              else
                  # v.i != 0, indexing performed

                  # Step 7: Indexed, no indirect
                  if v.ia==0 and v.ii==0
                      @xtIndexed = true   # timing (AP-101B): plain indexing
                      regx = (@r(v.i).get32() >>> 16) << (v.indexWidth - 1)
                      ea = (pea + regx) & 0xffff

                  # Step 8: Indexed with modification
                  if v.ia==0 and v.ii==1
                      @xtCase = 6     # timing: auto indexing
                      index = @r(v.i).get32() >>> 16
                      regx = index << (v.indexWidth - 1)
                      modifier = @r(v.i).get32() & 0xffff
                      ea = (pea + regx) & 0xffff
                      # Modifier advances the INDEX, not the EA -- see the
                      # long note on step 8 in g_EA.
                      modifiedAddr = (index + modifier) & 0xffff
                      @r(v.i).set32((modifiedAddr << 16) + modifier)

                  # Step 9: Indirect with post-indexing (expand for memory lookup)
                  if v.ia==1 and v.ii==0
                      @xtCase = 1     # timing: see g_EA step 9
                      indirectAddr = @g_EXPAND(pea, OPTYPE_DATA)
                      indirectHW = @ram.get16(indirectAddr)
                      regx = (@r(v.i).get32() >>> 16) << (v.indexWidth - 1)
                      ea = (indirectHW + regx) & 0xffff

                  # Step 10: ZCON fullword indirect pointer
                  # Return 16-bit address portion (bits 0-15 of pointer)
                  if v.ia==1 and v.ii==1
                      indirectAddr = @g_EXPAND(pea, OPTYPE_DATA)
                      indirectFW = @ram.get32(indirectAddr)
                      address16 = (indirectFW >>> 16) & 0xffff
                      xc = (indirectFW >>> 11) & 1
                      c16 = (indirectFW >>> 10) & 1
                      @xtCase = 1 + xc*2 + c16   # timing: double indirection
                      regx = (@r(v.i).get32() >>> 16) << (v.indexWidth - 1)
                      if xc == 0
                          ea = (address16 + regx) & 0xffff
                      else
                          ea = address16 & 0xffff

          else
              # Non-indexed extended: no expansion
              ea = pea & 0xffff

      else
          # SRS or SI addressing: no expansion.  The base's low bit survives,
          # as in g_EA above.
          base = @r(v.b).get32() >>> 16
          disp = v.d << (v.addrWidth - 1)
          ea = base + disp
          ea = ea & 0xffff

      return ea

  g_EXPAND: (ea, bsrdsr=OPTYPE_DATA, dseVal=null) ->
      # 2.2.9 EXPANDED ADDRESSING
      #
      #   The addressing philosophy accommodates 64K* halfword addresses
      # since a full 16-bit address is provided. Extending the addressing
      # range beyond 64K halfword locations up to 512K halfword locations
      # is provided by utilizing PSW bits and Data Sector Extension (DSE)
      # registers.
      #
      #   Expanding to 19 bits is achieved by replacing the high-order bit of
      # a 16-bit address with 4 bits, as shown in Figure 2-18. Data operand
      # addresses are extended to 19 bits with a 4-bit Data Sector Register
      # (DSR), a DSE, a BSR, or an implied DSR of zero. When the high-order
      # bit of a 16-bit data address is 1, a 4-bit DSR (PSW bits 28 through
      # 31) is selected to replace the high-order bit. (Note: IC relative
      # data operand addressing would use BSR instead.) When the high-order
      # bit of a 16-bit data address is 0 and a base register is used to
      # determine the address, the 4-bit DSE for that base register is
      # selected to replace the high-order bit. When the high-order bit of a
      # 16-bit data address is a 0, and no base register is used, an implied
      # DSR containing 0000 is selected. Note that indirect addressing
      # locates the indirect address pointer as if the pointer were a data
      # operand. Second stage expansion of the indirect address pointer uses
      # an implied DSR of zero if the high-order bit of the 16-bit address is
      # 0 and no base register is used; if the high-order bit is 0 and a base
      # register is used, the 4-bit DSE for that base register is selected.
      # Branch addresses are also extended to 19 bits. When the high-order
      # bit of a 16-bit branch address is a 1, a 4-bit Branch Sector Register
      # (BSR-PSW bits 24 through 27) is selected to replace the high-order
      # bit. When the high-order bit is a 0, an implied BSR containing 0000
      # is selected. 
      #
      # AP-101B only: The high-order bit of both the BSR and DSR must be zero.
      #
      ea = ea & 0xffff

      if ea & 0x8000
          if bsrdsr == OPTYPE_DATA || bsrdsr == OPTYPE_SHFT
              ea = (@psw.getDSR() << 15) + (ea & 0x7fff)
          else         # OPTYPE_BRCH
              ea = (@psw.getBSR() << 15) + (ea & 0x7fff)
      else if dseVal? and bsrdsr != OPTYPE_BRCH
          ea = (dseVal << 15) + ea
      return ea

  # The DSE of the base register an EA is formed from, or null when the
  # instruction uses no base register.  RS extended/indexed addressing uses
  # B2 == 11 to mean "no base"; SRS and SI do not -- there B2 == 11 is
  # register 3, used as a base like any other (POO 2.2.8)
  g_BASE_DSE: (v, noBase3) ->
      return null if not v.b?
      return null if noBase3 and v.b == 3
      return @regFiles[@psw.getRegSet()].getDSE(v.b)

  g_EAF: (v, extraOffset=0) ->
      ea = @g_EA(v)+extraOffset
      value = (@ram.get16(ea) << 16) + (@ram.get16(ea+1))
      return value

  g_EAH: (v) ->
      ea = @g_EA(v)
      value = @ram.get16(ea)
      #console.log "g_EAH ea=#{ea} value=#{value}"
      return value

  # Macrocode stores to main storage
  #
  # Every store an instruction makes goes through storeHW/storeFW, so the
  # protection rule is handled once: a protected location is not written
  # ("In this case, the store operation does not occur", POO 2.4) and the
  # store protect violation program check is raised.  An ISPB with an
  # illegal M1 leaves the override on, and nothing is protected until the
  # next valid ISPB.
  #
  # They return true when the store happened, so a multi-halfword
  # instruction (STM, SCAL, MVH) can stop at the halfword that faulted.

  # The instruction unit's view of a store into the IU file:
  #
  # The IU prefetches ahead of the PC, so a store into the instruction
  # stream can land on a halfword that has already been fetched.  B STAT
  # bit 6 decides what happens then (POO sect.15, DIAG 7100/7101).  Set:
  # "the CPU hardware checks for conflicts within the IU file.  When
  # conflicts are detected, the file is purged", which a machine that
  # always refetches from store gets without modelling.  Reset: "no checks for
  # conflicts within the IU file are performed.  THE PIPELINE WILL NOT BE
  # PURGED", and the already-fetched halfword executes stale.
  #
  # Only the second case needs modelling, and it needs no IU file: keep the
  # pre-store halfword for the window the IU could have reached and hand it
  # to the instruction fetch instead of storage, until the next
  # discontinuity flushes it.  Sect.16.8 gives the window: "the actual
  # detection circuitry uses the range of IC-1 to IC+23", compared on "the
  # 15 least significant bits of the logical address" with 7FFF/0000 and
  # FFFF/8000 contiguous.
  IU_WINDOW_AHEAD = 23
  shadowIuStore: (addr) ->
      return if @diagIuStoreDetect
      d = (addr - @curIC) & 0x7fff
      return unless d <= IU_WINDOW_AHEAD or d == 0x7fff
      @iuShadow ?= new Map()
      @iuShadow.set(addr, @ram.get16(addr, false)) unless @iuShadow.has(addr)
      return

  storeHW: (addr, value) ->
      @shadowIuStore(addr) unless @diagIuStoreDetect
      return true if @ram.set16(addr, value, not @storeProtectOverride)
      @signalProtectionViolation()
      return false

  # The fullword form tests both halfwords' protect bits before writing
  # either, so a fullword store that straddles a protection boundary
  # leaves neither half changed.  The two halves are then written one at a
  # time, which is also how they are addressed: main storage is two MCMs
  # and only the halfword path routes between them.
  storeFW: (addr, value) ->
      unless @diagIuStoreDetect
          @shadowIuStore(addr)
          @shadowIuStore(addr + 1)
      if not @storeProtectOverride and
         (@ram.getStoreProtect(addr) or @ram.getStoreProtect(addr + 1))
          @signalProtectionViolation()
          return false
      @ram.set16(addr,     (value >>> 16) & 0xffff, false)
      @ram.set16(addr + 1, value & 0xffff, false)
      return true

  s_EAF: (v, value,extraOffset=0) ->
      @storeFW(@g_EA(v)+extraOffset, value)

  s_EAH: (v, value) ->
      @storeHW(@g_EA(v), value)
  


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

  # Pick the timing-table value for the current addressing case from a row
  # of alternate times.  Used by e() overrides whose whole row differs from
  # the xts default (e.g. R1-odd multiply/divide).
  xtPick: (row) -> row[@xtCase] ? row[0]

  execTimeUs: () -> @timeNs / 1000

  # Advance CPU time by ns and tick the two 1-MHz interval timers.
  # Callable from outside exec1 as well (e.g. to model wait-state time).
  advanceTimeNs: (ns) ->
      @timeNs += ns
      @cntAccumNs += ns
      if @cntAccumNs >= 1000
          ticks = (@cntAccumNs / 1000) | 0
          @cntAccumNs -= ticks*1000
          @counter1 = @tickCounter(@counter1, 0x00B0, INT_CLK1, ticks)
          @counter2 = @tickCounter(@counter2, 0x00B1, INT_CLK2, ticks)

  # Decrement one interval timer by `ticks` microseconds (POO 2.5.2).  The
  # low halfword is the 16-bit hardware counter; on borrow, microcode
  # decrements the high halfword in main store (bypassing store protect).
  # When the high halfword is 0000 at borrow time it wraps to FFFF and the
  # clock interrupt is raised.
  #
  # The borrow is an interrupt, and a masked one does not move main store:
  # "When the low halfword ... passes from 0000 to FFFF an interrupt occurs
  # which can cause the high halfword in main store (via microcode) to be
  # decremented by one.  This interrupt is transparent to the programmer
  # until the high halfword in main store equals 0000 ... If the interrupt
  # is masked the high halfword will not be decremented by the microcode.
  # The low halfword continues to count down.  The interrupt remains
  # pending and if unmasked within 65 ms, the upper halfword will be
  # decremented without a loss of a count."
  #
  # Software checksums a region containing 00B0/00B1 by masking the clocks
  # first, and low core then holds still.
  #
  # The deferral covers the transparent decrement the note describes, where
  # the high halfword is non-zero.  A borrow out of a high halfword already
  # at 0000 is the 32-bit count running out, which is the program's clock
  # interrupt: it latches and the halfword rolls to FFFF whatever the mask
  # says, as any other interrupt latches while masked.  Software arms a
  # counter by writing a value whose high halfword is zero -- a delay of a
  # few microseconds as 0000/count, a flat zero to expire at once -- and
  # reads 00B0/00B1 back a microsecond later expecting FFFF.
  tickCounter: (low, hiAddr, spec, ticks) ->
      @_timerBorrowDue(hiAddr, spec)
      low -= ticks
      if low < 0
          low += 0x10000        # ticks <= 65535, so at most one borrow
          if @intEnabled(spec) or @ram.get16(hiAddr) == 0
              @_timerBorrow(hiAddr, spec)
          else
              # Pending, and the count is not lost: it is applied when the
              # interrupt is unmasked.  One latch, so a second borrow while
              # still masked is the "within 65 ms" the note allows for.
              @timerBorrowPending ?= {}
              @timerBorrowPending[hiAddr] = spec
      return low

  # A borrow that was masked when it happened, applied once it is not.
  _timerBorrowDue: (hiAddr, spec) ->
      return unless @timerBorrowPending?[hiAddr]?
      return unless @intEnabled(spec)
      delete @timerBorrowPending[hiAddr]
      @_timerBorrow(hiAddr, spec)
      return

  _timerBorrow: (hiAddr, spec) ->
      hi = @ram.get16(hiAddr)
      if hi == 0
          @ram.set16(hiAddr, 0xffff, false)
          @intPendingReg |= spec.bit
      else
          @ram.set16(hiAddr, hi - 1, false)
      return

  TIMER_HI: (n) -> if n == 2 then 0x00B1 else 0x00B0

  # The full 32-bit count of interval timer n: high halfword from the PSA,
  # low halfword from the hardware counter.
  timerValue: (n) ->
      hi = @ram.get16(@TIMER_HI(n), false)
      lo = (if n == 2 then @counter2 else @counter1) & 0xffff
      return ((hi << 16) | lo) >>> 0

  # Microseconds of CPU time until interval timer n times out.  It fires
  # when the count borrows past zero, which is (low + 1 + hi*65536) ticks
  # away.
  timerRemainingUs: (n) ->
      lo = (if n == 2 then @counter2 else @counter1) & 0xffff
      return lo + 1 + @ram.get16(@TIMER_HI(n), false) * 0x10000

  # The ICR write command's effect (POO sect.10), including its reset of
  # the clock interrupt latch.  The PSA half is written past store protect:
  # 00B0/00B1 are on the POO's list of locations that must not be protected
  # (2.5.2.4), and the AGE is not subject to it in any case.
  loadTimer: (n, value) ->
      value = value >>> 0
      @ram.set16(@TIMER_HI(n), (value >>> 16) & 0xffff, false)
      # "The write Counter N commands reset the corresponding clock
      # interrupt latch, clearing any pending interrupts" (POO sect.10) --
      # a borrow that was waiting on the mask goes with them, or it would
      # decrement the halfword the load just set.
      delete @timerBorrowPending[@TIMER_HI(n)] if @timerBorrowPending?
      if n == 2
          @counter2 = value & 0xffff
          @intPendingReg &= ~INT_CLK2.bit
      else
          @counter1 = value & 0xffff
          @intPendingReg &= ~INT_CLK1.bit
      return value

  # Nanoseconds of CPU time until the next interval-timer interrupt.
  nextTimerNs: () ->
      Math.min(@timerRemainingUs(1), @timerRemainingUs(2)) * 1000 - @cntAccumNs

  # Could anything still wake a CPU sitting in the wait state?  Only an
  # unmasked system interrupt or an already-pending non-maskable one; with
  # neither the wait is permanent and callers should stop.
  canWake: () ->
      return true if @psw.getIntMask() != 0
      (@intPendingReg & (INT_BITS_NONMASKABLE | INT_MACHINE_CHECK.bit)) != 0

  # Advance simulated time through the wait state by up to `ns`, stopping
  # early if an interrupt takes the CPU out of it.  Steps are at most 1 ms
  # and are shortened to land exactly on the next interval-timer expiry, so
  # a wakeup is taken at its true simulated time rather than a step late.
  # Returns the nanoseconds actually advanced.
  advanceIdleNs: (ns) ->
      done = 0
      while done < ns and @psw.getWaitState()
          step = Math.min(1e6, ns - done)
          tNs = @nextTimerNs()
          step = tNs if tNs > 0 and tNs < step
          step = Math.max(1, Math.round(step))   # never stall on a 0 step
          done += step
          # The IOP's watchdog runs on wall time, not CPU instructions, so
          # it keeps counting through the wait state.
          @iop?.tickWatchdog?()
          # So does the IOP: it is an independent processor and does not
          # stop because the CPU has.  Stepped at the slice rate, and only
          # when something is enabled and busy, so an idle IOP costs
          # nothing here.
          #
          # Time must advance with the slices rather than in one jump
          # before them.  The IOP's two waiting mechanisms are otherwise
          # incommensurate: a bus control element's delay and time out are
          # measured in simulated time, while a master sequence
          # controller's repeat instruction counts re-fetches.  A
          # 1 ms step is about 2000 slices, so an @RAW waiting 848 repeats
          # would expire well inside a BCE's legitimate 10.7 ms #DLYI.
          if @iop?.processorsRunning?()
              left = step
              while left > 0
                  slice = Math.min(IOP_SLICE_NS, left)
                  @advanceTimeNs(slice)
                  left -= slice
                  @idleIopNs = (@idleIopNs ? 0) + slice
                  while @idleIopNs >= IOP_SLICE_NS
                      @idleIopNs -= IOP_SLICE_NS
                      @iop.execIdle()
          else
              @advanceTimeNs(step)
              @idleIopNs = 0
          @checkInterrupts()
          break if @intArmed?
      return done

  loadPowerOnPSW: () ->
      @loadPSW(@ram.get32(CPU.POWER_ON_PSW), @ram.get32(CPU.POWER_ON_PSW + 2))
      return @psw.getNIA()

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

  unknownOp: (nia, hw1) ->
      @unknownOps ?= {}
      return if @unknownOps[nia]
      @unknownOps[nia] = true
      console.log "CPU: operation exception, X'#{hw1.asHex(4)}' at " +
                  "#{nia.asHex(5)} is not an instruction"
      return

  exec1: () ->
      # A held interrupt is taken before anything else runs: the swap it
      # was stopped in front of is the machine's next act.  Front ends that
      # know about the hold call releaseInterrupt themselves and stop on
      # the swap; this is for the ones that just keep stepping.

      # Held in system reset by the HALT discrete, which the IOP sets and
      # clears (gpc/iop, discrete input A bit 0).  Nothing is fetched and
      # no time passes; the machine starts from the system reset PSW when
      # the toggle leaves HALT.
      return if @resetHeld

      @releaseInterrupt() if @intArmed?

      times = [0.0, 0.0, 0.0]
      times[0] = _now()
      nia = @psw.getNIA()

      @curIC = nia

      hw1 = @ram.get16(nia)
      hw2 = @ram.get16(nia+1)
      # A halfword the IU already held when a store rewrote it, with
      # conflict detection off: the fetch sees what the IU has, not what
      # storage has.  See shadowIuStore.
      if @iuShadow?
          hw1 = @iuShadow.get(nia)   if @iuShadow.has(nia)
          hw2 = @iuShadow.get(nia+1) if @iuShadow.has(nia+1)
      [d,v] = Instruction.decode(hw1,hw2)

      # A halfword that decodes to nothing is an operation exception: the
      # CPU takes a program check with code PC_ILLEGAL_OP and the handler
      # decides what happens next.  The halfword is skipped, so the old
      # PSW's NIA points just past it, as for the program checks e()
      # raises.
      unless d?
          @unknownOp(nia, hw1)
          @incrNIA(1)
          @signalIllegalOp()
          @advanceTimeNs(250)
          @checkInterrupts()
          @prevDiscont = true
          @iuShadow = null
          return

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

      # Instruction monitor: PSW bit 34 = 1 and instruction is unprotected.
      intMask = @psw.getIntMask()
      if (intMask & 0x20) and not @ram.getStoreProtect(nia)
          @intPendingReg |= INT_INSTR_MONITOR.bit

      # Instruction timing: reset the per-instruction state.  g_EA/g_EA_16
      # set xtCase/xtIndexed for the special addressing modes; e() may set
      # opExecT (microseconds) to override the table values entirely.
      @xtCase = 0
      @xtIndexed = false
      @opExecT = null
      @xtcRow = null
      @xtcAddT = null
      seqNIA = @psw.getNIA()    # fall-through NIA, for branch-taken detection

      if d.e?
          d.e(@,v)

      if @model == 'B' and (@xtcRow? or d.xtcNs? or d.xtcsNs?)
          # AP-101B (IBM 75-A97-001 sect.2.4).  Column by IC
          # parity; the ~NOK column applies only right after a discontinuity
          # (branch/interrupt).  Operands assumed in internal (CPU) memory --
          # the Even-100/Even-200 columns (IOP external memory / EMU) are
          # not yet selected.  opExecT overrides are AP-101S formulas and
          # are ignored here; count-scaled B ops (e.g. SUM note 2) TBD.
          if @xtcRow?
              # e() supplied a command-specific row (us), e.g. ICR
              row = (Math.round(x*1000) for x in @xtcRow)
          else
              row = if v.niaIncr == 1 and d.xtcsNs? then d.xtcsNs else (d.xtcNs ? d.xtcsNs)
          col = if nia & 1 then (if @prevDiscont then 2 else 1) else 0
          dtNs = row[col]
          dtNs += Math.round(@xtcAddT * 1000) if @xtcAddT?
          # NOTE 4 adders: index +0.4, index modification +1.2,
          # indirect +1.2 (+0.4 when post-indexed), indirect mod +2.8
          dtNs += 400 if @xtIndexed
          switch @xtCase
              when 1 then dtNs += 1600          # indirect, post-indexed
              when 2, 3, 4 then dtNs += 1200    # indirect
              when 5 then dtNs += 2800          # indirect modification
              when 6 then dtNs += 1200          # index modification
      else if @opExecT?
          dtNs = Math.round(@opExecT * 1000)
      else if @xtCase == 0 and d.xtbsNs?
          taken = @psw.getNIA() != seqNIA
          dtNs = d.xtbsNs[if taken then 0 else 1]
      else if d.xtsNs?
          dtNs = d.xtsNs[@xtCase] ? d.xtsNs[0]
      else
          dtNs = 250            # op missing from the timing table
      @advanceTimeNs(dtNs)

      # Check and service pending interrupts
      @checkInterrupts()

      # Sequential-fetch discontinuity (branch taken or interrupt swap):
      # the next instruction starts with an empty lookahead (C-model ~NOK)
      @prevDiscont = @psw.getNIA() != seqNIA
      @iuShadow = null if @prevDiscont and @iuShadow?

      times[1] = _now()
      times[2] = times[1] - times[0]


# Import interrupt methods from cpu_intr:
for own name, fn of INTERRUPT_METHODS
    Object.defineProperty CPU.prototype, name,
        value: fn, writable: true, configurable: true, enumerable: false
