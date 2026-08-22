# The interrupt page: 
# Interrupt codes, the pending register and the mask the PSW implies, 
# the priority search, and the PSW swap that accepts one.  
# The signal* methods that raise a program check are here too.
#
# Mixed into CPU.prototype by gpc/cpu.coffee, so @ is the CPU.  

# Priority order, from IBM-85-C67-001 Figure 2-20, "Interrupt Structure and
# Priority".  It is also the bit order of the pending register.
#
#   key      name of its latch, as ground equipment addresses it
#   cls      POO class: MC (machine check), PE (program), SC (SVC), SYS
#   old/new  PSA halfword addresses of the old and new PSW
#   maskBit  PSW mask bit that gates it (null = not maskable)
#   pends    stays pending while masked.  Per POO 2.5.2.3 only the system
#            class does; machine check and program checks are dropped.
#   code     interrupt code written into the old PSW (null = none).  The
#            table's default; raiseInterrupt overrides it, which External 1
#            needs since it carries three (EXT1_* below).
#   bit      its bit in the pending register (assigned below)
#
export INTERRUPTS = [
  { key: 'machineCheck', cls: 'MC',  old: 0x0040, new: 0x0044, maskBit: 45,
    pends: false, code: 0x0008, label: 'Machine Check' }
  { key: 'instrMonitor', cls: 'PE',  old: 0x0070, new: 0x0074, maskBit: 34,
    pends: false, code: null,   label: 'CPU Breakpoint (Instruction Monitor)' }
  { key: 'programCheck', cls: 'PE',  old: 0x0048, new: 0x004c, maskBit: null,
    pends: false, code: 0x0000, label: 'Program Check' }
  { key: 'svc',          cls: 'SC',  old: 0x0058, new: 0x005c, maskBit: null,
    pends: false, code: null,   label: 'Supervisor Call' }
  { key: 'clk1',         cls: 'SYS', old: 0x0060, new: 0x0064, maskBit: 32,
    pends: true,  code: null,   label: 'Interval Timer 1' }
  { key: 'clk2',         cls: 'SYS', old: 0x0068, new: 0x006c, maskBit: 33,
    pends: true,  code: null,   label: 'Interval Timer 2' }
  { key: 'ext0',         cls: 'SYS', old: 0x0078, new: 0x007c, maskBit: 35,
    pends: true,  code: 0x0000, label: 'External 0 (IOP Group 1: C/M idle, fail, watchdog)' }
  { key: 'ext1',         cls: 'SYS', old: 0x0080, new: 0x0084, maskBit: 36,
    pends: true,  code: 0x0000, label: 'External 1 (IOP data flow/DMA, AGE)' }
  { key: 'ext2',         cls: 'SYS', old: 0x0088, new: 0x008c, maskBit: 37,
    pends: true,  code: null,   label: 'External 2 (IOP programmed 1-12)' }
  { key: 'ext3',         cls: 'SYS', old: 0x0090, new: 0x0094, maskBit: 38,
    pends: true,  code: null,   label: 'External 3 (spare)' }
  { key: 'ext4',         cls: 'SYS', old: 0x0098, new: 0x009c, maskBit: 39,
    pends: true,  code: null,   label: 'External 4 (spare)' }
  # The Shuttle AGE interrupt shares External 1's PSW pair and mask bit, and
  # is told from it only by the interrupt code in the old PSW (0006 against
  # 0000/0004).  It has a latch of its own because it is a separate source
  # that can be pending alongside External 1, and it is the lowest priority
  # of the twelve: the interrupt-priority test sets every latch at once and
  # requires AGE to arrive eighth, after External 4.
  { key: 'age',          cls: 'SYS', old: 0x0080, new: 0x0084, maskBit: 36,
    pends: true,  code: 0x0006, label: 'External 1 (Shuttle AGE)' }
]

INTERRUPTS_BY_KEY = {}
INTERRUPTS_BY_KEY[i.key] = i for i in INTERRUPTS

# Program check interrupt codes (Figure 2-20, the PE rows)
#
# The code is one field of the old PSW, and all a handler has to tell the
# eleven program interrupts apart with.  0004 appears on the system side of
# the figure as well, as the Ext 1 DMA store protect violation: a different
# interrupt on a different PSW pair, raised by the IOP's accesses to main
# store rather than the CPU's.
export PC_ILLEGAL_OP       = 0x0000   # 34/C1  illegal instruction or I/O command
export PC_PRIVILEGED_OP    = 0x0001   # C2     privileged instruction (problem state)
export PC_ADDRESS_SPEC     = 0x0002   # 31     CPU address specification
export PC_FIXED_OVERFLOW   = 0x0004   # 20     fixed point overflow (mask bit 20)
export PC_SIGNIFICANCE     = 0x0005   # C4     significance (mask bit 23)
export PC_STORE_PROTECT    = 0x0007   # 33     store protect violation
export PC_FP_UNDERFLOW     = 0x0009   # 22     floating point underflow (mask bit 22)
export PC_CONVERT_OVERFLOW = 0x000A   # C5     convert overflow
export PC_FP_OVERFLOW      = 0x000B   # 21     floating point (exponent) overflow
export PC_FP_DIVIDE        = 0x000C   # C3     divide by zero (floating point)

# Names for those codes, for anything that displays an old PSW.
export PROGRAM_CHECK_LABELS = {}
PROGRAM_CHECK_LABELS[PC_ILLEGAL_OP]       = 'illegal instruction or I/O command'
PROGRAM_CHECK_LABELS[PC_PRIVILEGED_OP]    = 'privileged instruction'
PROGRAM_CHECK_LABELS[PC_ADDRESS_SPEC]     = 'address specification'
PROGRAM_CHECK_LABELS[PC_FIXED_OVERFLOW]   = 'fixed point overflow'
PROGRAM_CHECK_LABELS[PC_SIGNIFICANCE]     = 'significance'
PROGRAM_CHECK_LABELS[PC_STORE_PROTECT]    = 'store protect violation'
PROGRAM_CHECK_LABELS[PC_FP_UNDERFLOW]     = 'floating point underflow'
PROGRAM_CHECK_LABELS[PC_CONVERT_OVERFLOW] = 'convert overflow'
PROGRAM_CHECK_LABELS[PC_FP_OVERFLOW]      = 'floating point overflow'
PROGRAM_CHECK_LABELS[PC_FP_DIVIDE]        = 'floating point divide by zero'

# External 1's codes, from the IOP side of the figure: an IOP data flow
# error reports 0000, a DMA store protect violation 0004 (raised by the
# CPU, not the IOP), and the Shuttle AGE interrupt 0006.
export EXT1_DATA_FLOW      = 0x0000
export EXT1_DMA_PROTECT    = 0x0004
export EXT1_AGE            = 0x0006

# Machine check codes from the same figure.  Only the one the machine can
# raise from inside an instruction is named here: the Force ROS Parity Error
# diagnostic assist (POO sect.15, X'F300') reports a microstore parity error.
export MC_MICROSTORE_PARITY = 0x0005

# The interrupt page, as a register
#
# Each interrupt is a latch in a pending register; the POO calls the
# external half of it the "External Pending Interrupt Register", and the
# Start Interrupt Priority Test IIO command sets every valid bit of it at
# once (Appendix I).  The register is ANDed with the enable mask the PSW
# implies, and the first bit set in the result is the interrupt taken.
#
# Bit assignment is Figure 2-20's priority order, machine check in the
# highest bit and AGE in bit 0, so "first bit set" is a count of leading
# zeros and the table index is clz32(bits) - INT_CLZ_BIAS.
INT_REG_WIDTH = INTERRUPTS.length
INT_CLZ_BIAS  = 32 - INT_REG_WIDTH
spec.bit = 1 << (INT_REG_WIDTH - 1 - idx) for spec, idx in INTERRUPTS

# Handles for the interrupts the CPU itself raises, so those sites name a
# table entry rather than repeating a bit or a PSA address.
export INT_MACHINE_CHECK = INTERRUPTS_BY_KEY.machineCheck
export INT_INSTR_MONITOR = INTERRUPTS_BY_KEY.instrMonitor
export INT_CLK1 = INTERRUPTS_BY_KEY.clk1
export INT_CLK2 = INTERRUPTS_BY_KEY.clk2
INT_PROGRAM_CHECK = INTERRUPTS_BY_KEY.programCheck
INT_EXT1 = INTERRUPTS_BY_KEY.ext1

# Interrupts that no mask can hold off, and those that stay latched while
# masked.  Per POO 2.5.2.3 only the system class waits for an unmask;
# machine check and program interrupts are dropped when masked.
export INT_BITS_NONMASKABLE = 0
INT_BITS_PERSISTENT  = 0
for spec in INTERRUPTS
  INT_BITS_NONMASKABLE |= spec.bit if not spec.maskBit?
  INT_BITS_PERSISTENT  |= spec.bit if spec.pends

# Name-addressable view of the pending register: cpu.intPending.clk1 reads
# and writes that latch.  For ground equipment, tests, and the instructions
# that clear a latch by name.
class PendingInterrupts
  constructor: (@cpu) ->

for spec in INTERRUPTS
  do (spec) ->
    Object.defineProperty PendingInterrupts.prototype, spec.key,
      enumerable: true
      get: -> (@cpu.intPendingReg & spec.bit) != 0
      set: (v) ->
        if v
          @cpu.intPendingReg |= spec.bit
        else
          @cpu.intPendingReg &= ~spec.bit


export INTERRUPT_METHODS =

  _initInterrupts: () ->
      @intPendingReg = 0
      @intPending = new PendingInterrupts(@)
      @intCode = 0                 # interrupt code for the next program check
      @mcCode = 0x0008             # and for the next machine check
      # And for a system interrupt whose source supplies one that is not the
      # table default.  Keyed by interrupt key, consumed at acceptance.
      @intCodeByKey = {}

      # Ring of the most recent acceptances.  
      @intLog = []
      @intLogMax = 256
      @intCount = 0                # total accepted since power-on
      @onInterrupt = null          # AGE hook: called with each log entry

      # Stop-before-swap: with @intHold set the machine decides an interrupt
      # in the ordinary way but parks the decision in @intArmed instead of
      # swapping PSWs, so nothing of the interrupted state has moved yet.
      @intHold = false
      @intArmed = null             # {spec, code} decided but not yet taken
      @intReleasing = false        # inside releaseInterrupt: take, don't re-hold
      @onInterruptHold = null      # AGE hook: called with the held status
      return

  # The share of a CPU reset and a system reset that belongs to the page.
  resetInterrupts: () ->
      @intPendingReg = 0
      @intArmed = null
      @intCode = 0
      @mcCode = 0x0008
      @intCodeByKey = {}
      return

  clearInterruptLog: () ->
      @intLog = []
      @intCount = 0
      return

  # Accept `spec`: swap PSWs, log it, and tell whatever ground equipment is
  # watching
  _takeInterrupt: (spec, code = null) ->
      @intPendingReg &= ~spec.bit
      delete @intCodeByKey[spec.key]
      fromNIA = @psw.getNIA()
      @psw.setIntCode(code) if code?
      # Figure 2-20 note '#': "When one of these interrupts is taken, the
      # condition code (CC) in the OLD PSW will be set to a binary 10 and
      # clear the carry and overflow bits.  This can result in erroneous
      # GPC operation of an instruction which tries to utilize the CC,
      # carry bit or overflow bit before they are set by another
      # instruction."  Marked on every machine check, on the store protect
      # violation and on the Ext 1 DMA store protect violation, so it is a
      # property of the event rather than of the latch.  Set before the swap
      # stores the old PSW, which is where a handler sees them.
      if @_ccAnomaly(spec, code)
          @psw.setCC(2)
          @psw.setCarry(0)
          @psw.setOverflow(0)
      @swapPSW(spec.old, spec.new)
      @intCount += 1
      entry = {
          seq:     @intCount
          timeNs:  @timeNs
          key:     spec.key
          label:   spec.label
          cls:     spec.cls
          code:    code
          fromNIA: fromNIA
          toNIA:   @psw.getNIA()
          oldPSA:  spec.old
          newPSA:  spec.new
      }
      @intLog.push(entry)
      @intLog.shift() while @intLog.length > @intLogMax
      @onInterrupt?(entry)
      return entry

  # Does this acceptance carry Figure 2-20's '#' anomaly?  Every machine
  # check does; of the program checks only the store protect violation; of
  # the system interrupts only External 1 raised by a DMA store protect.
  _ccAnomaly: (spec, code) ->
      return true if spec.cls == 'MC'
      return true if spec.bit == INT_PROGRAM_CHECK.bit and code == PC_STORE_PROTECT
      return true if spec.key == 'ext1' and code == EXT1_DMA_PROTECT
      return false

  # With the hold armed the machine stops here instead of swapping.  The
  # pending latch is left set, so a display still shows the interrupt
  # waiting to be taken.
  _acceptInterrupt: (spec, code) ->
      if @intHold and not @intReleasing
          @intArmed = { spec: spec, code: code }
          @onInterruptHold?(@heldInterrupt())
          return null
      return @_takeInterrupt(spec, code)

  # Complete a held interrupt.  The operator may have cleared the latch, 
  # flipped a mask bit or raised something higher while the machine sat 
  # there:
  releaseInterrupt: () ->
      return null unless @intArmed?
      @intArmed = null
      @intReleasing = true
      try
          entry = @checkInterrupts()
      finally
          @intReleasing = false
      return entry ? null

  # What the machine is holding: the interrupt, where it would leave the
  # interrupted program, and where the swap would send it.
  heldInterrupt: () ->
      return null unless @intArmed?
      {spec, code} = @intArmed
      {
          key:     spec.key
          label:   spec.label
          cls:     spec.cls
          code:    code
          fromNIA: @psw.getNIA()
          toNIA:   @vectorNIA(spec)
          oldPSA:  spec.old
          newPSA:  spec.new
      }

  # The NIA a swap into `spec` would produce, read out of the new-PSW slot
  # without loading it: bit 15 set means that PSW's own BSR supplies the
  # sector, the same expansion PSW.getNIA does.
  vectorNIA: (spec) ->
      p1 = @ram.get32(spec.new, false)
      nia16 = (p1 >>> 16) & 0xffff
      return nia16 unless nia16 & 0x8000
      ((p1 >>> 4) & 0xf) << 15 | (nia16 & 0x7fff)

  # Disarming leaves an already-held interrupt armed: it was decided under
  # the old setting, and dropping it here would lose an interrupt the
  # machine has accepted.  The next step or run takes it.
  setInterruptHold: (enabled) ->
      @intHold = !!enabled
      return @intHold

  # Request an interrupt from outside the instruction stream
  raiseInterrupt: (key, opts = {}) ->
      spec = INTERRUPTS_BY_KEY[key]
      throw new Error("unknown interrupt '#{key}'") unless spec?
      if opts.code?
          if key == 'machineCheck'
              @mcCode = opts.code
          else if key == 'programCheck'
              @intCode = opts.code
          else
              @intCodeByKey[key] = opts.code
      @intPendingReg |= spec.bit
      return spec

  clearInterrupt: (key) ->
      spec = INTERRUPTS_BY_KEY[key]
      throw new Error("unknown interrupt '#{key}'") unless spec?
      @intPendingReg &= ~spec.bit
      return

  # Is `spec` unmasked in the current PSW?  The system class is gated by
  # its bit in the system mask, machine check by PSW bit 45, and the rest
  # cannot be masked at all.
  intEnabled: (spec) ->
      (@intEnableMask() & spec.bit) != 0

  # An all-zero new-PSW slot is an empty vector: the swap would send NIA to
  # 0 and the machine would wander through low memory.
  intHasHandler: (spec) ->
      spec = INTERRUPTS_BY_KEY[spec] if typeof spec == 'string'
      return false unless spec?
      not (@ram.get32(spec.new, false) == 0 and @ram.get32(spec.new + 2, false) == 0)

  # Snapshot of the whole repertoire for a display: what is pending, what
  # is masked, and what is therefore blocked.
  intStatus: () ->
      enable = @intEnableMask()
      for spec in INTERRUPTS
          pending = (@intPendingReg & spec.bit) != 0
          enabled = (enable & spec.bit) != 0
          {
              key: spec.key, label: spec.label, cls: spec.cls
              maskBit: spec.maskBit, old: spec.old, new: spec.new
              pends: spec.pends, pending: pending, enabled: enabled
              blocked: pending and not enabled
              hasHandler: @intHasHandler(spec)
              held: @intArmed?.spec == spec
          }

  # Which interrupts the current PSW would let through, as a word to AND
  # with the pending register.  The eight system mask bits (32-39) permute
  # into their register bits; machine check answers to PSW bit 45, and the
  # two non-maskable classes are always in.
  intEnableMask: () ->
      m = @psw.getIntMask()          # PSW bits 32-39, 0x80 = bit 32
      e = INT_BITS_NONMASKABLE
      e |= INT_MACHINE_CHECK.bit if @psw.getMachCheckMask()
      e |= (m & 0x20) << 5           # bit 34 -> instruction monitor
      e |= (m & 0xc0)                # bits 32-33 -> interval timers 1, 2
      e |= (m & 0x1f) << 1           # bits 35-39 -> External 0-4
      e |= (m & 0x08) >> 3           # bit 36 -> AGE, with External 1
      return e

  checkInterrupts: () ->
      # AND the pending register with the enable mask and take the first bit
      # set: the priority ordering is the bit ordering, and clz32 is the
      # search under mask.
      #
      pend = @intPendingReg
      return if pend == 0

      # Holding a decision already: no further ones until it is released.
      return if @intArmed?

      enable = @intEnableMask()

      # Masked machine check and program interrupts do not stay pending
      # (POO 2.5.2.3); the system class waits for an unmask.
      if pend & ~enable & ~INT_BITS_PERSISTENT
          pend &= enable | INT_BITS_PERSISTENT
          @intPendingReg = pend

      active = pend & enable
      return if active == 0

      spec = INTERRUPTS[Math.clz32(active) - INT_CLZ_BIAS]

      if spec.bit == INT_PROGRAM_CHECK.bit
          # No handler installed: swapping into a zero new-PSW slot would
          # send NIA to 0, so log and carry on instead.
          if @ram.get32(0x004c) == 0 and @ram.get32(0x004e) == 0
              @intPendingReg &= ~spec.bit
              @psw.setIntCode(@intCode)
              if @halUCP and @halUCP._log
                  what = PROGRAM_CHECK_LABELS[@intCode]
                  @halUCP._log "GPC: unhandled program check, code=0x#{@intCode.toString(16).toUpperCase().padStart(4, '0')}" +
                               (if what? then " (#{what})" else "") +
                               " (no handler at 0x004C); continuing\n"
              return
          return @_acceptInterrupt(spec, @intCode)

      code =
          if spec.bit == INT_MACHINE_CHECK.bit then @mcCode
          else @intCodeByKey[spec.key] ? spec.code
      return @_acceptInterrupt(spec, code)

  # Raising a program check
  #
  # Each names one of the Figure 2-20 codes above and sets the single
  # program check latch.  Whether it is delivered, and to what, is
  # checkInterrupts' business.

  # Figure 2-20 priority 20, mask bit 20, code 0004.  Its pending column is
  # Note 1, "status held active in PSW 19": the overflow indicator is the
  # latch, so it is set here whether or not the interrupt is enabled, and
  # the interrupt follows from the two bits being set together.
  signalFixedOverflow: () ->
      @psw.setOverflow(1)
      @testFixedOverflow()

  # Re-test the Note 1 condition.  Called after anything that can set
  # either bit: an overflowing operation, SPM, a PSW load.
  testFixedOverflow: () ->
      if @psw.getOverflow() and @psw.getFixedPtOverflow()
          @intPendingReg |= INT_PROGRAM_CHECK.bit
          @intCode = PC_FIXED_OVERFLOW
      return

  signalExponentOverflow: () ->
      # POO 2.5.2 priority 21, non-maskable, code 0x000B.
      @intPendingReg |= INT_PROGRAM_CHECK.bit
      @intCode = PC_FP_OVERFLOW

  signalExponentUnderflow: () ->
      # POO 2.5.2 priority 22, mask bit 22, code 0x0009.
      if @psw.getExponentUnderflow()  # PSW bit 22 = 1 means enabled
          @intPendingReg |= INT_PROGRAM_CHECK.bit
          @intCode = PC_FP_UNDERFLOW

  signalSignificance: () ->
      # POO 2.5.2 priority C4, mask bit 23, code 0x0005.
      if @psw.getSignificanceMask()  # PSW bit 23 = 1 means enabled
          @intPendingReg |= INT_PROGRAM_CHECK.bit
          @intCode = PC_SIGNIFICANCE

  signalFPDivide: () ->
      # POO 2.5.2 priority C3, non-maskable, code 0x000C.  Division is
      # suppressed.
      @intPendingReg |= INT_PROGRAM_CHECK.bit
      @intCode = PC_FP_DIVIDE

  signalConvertOverflow: () ->
      # POO 2.5.2 priority C5, non-maskable, code 0x000A.
      # CVFX value out of int32 range.  R1 unchanged.
      @intPendingReg |= INT_PROGRAM_CHECK.bit
      @intCode = PC_CONVERT_OVERFLOW

  # Takes the exc field of the {result, exc} a floatIBM op returns; true if
  # the caller should write the result back and set CC.  Per POO 8.8:
  #   OK            - write back, set CC normally.
  #   EXP_OVERFLOW  - signal, terminate (no writeback, no CC change).
  #   EXP_UNDERFLOW - signal; mask 0 writes true zero (CC 0), mask 1
  #                   terminates with no writeback.
  #   SIGNIFICANCE  - signal only when mask is 1; always write true zero
  #                   with CC 00.
  #   FP_DIVIDE     - signal, suppress division (no writeback, no CC change).
  fp_dispatch_exc: (exc) ->
      switch exc
          when 0          # OK
              return true
          when 0x000B     # EXP_OVERFLOW
              @signalExponentOverflow()
              return false
          when 0x0009     # EXP_UNDERFLOW
              @signalExponentUnderflow()
              # With the mask bit set the operands are unchanged, so
              # suppress the writeback.
              return not @psw.getExponentUnderflow()
          when 0x0005     # SIGNIFICANCE
              @signalSignificance()
              # True zero is always written; the primitive has already
              # returned it, and CC 00 falls out of the "result is zero"
              # branch.
              return true
          when 0x000C     # FP_DIVIDE
              @signalFPDivide()
              return false
          when 0x000A     # CONVERT_OVERFLOW
              @signalConvertOverflow()
              return false
          else
              return true

  signalIllegalOp: () ->
      @intPendingReg |= INT_PROGRAM_CHECK.bit
      @intCode = PC_ILLEGAL_OP

  signalPrivilegedOp: () ->
      @intPendingReg |= INT_PROGRAM_CHECK.bit
      @intCode = PC_PRIVILEGED_OP

  # What an interrupt code means, for anything that displays one.  Null when
  # the interrupt carries no code, or one this table cannot name.
  intCodeLabel: (key, code) ->
      return null unless code?
      return PROGRAM_CHECK_LABELS[code] ? null if key == 'programCheck'
      if key == 'ext1' or key == 'age'
          return switch code
              when EXT1_DATA_FLOW   then 'IOP data flow error'
              when EXT1_DMA_PROTECT then 'DMA store protect violation'
              when EXT1_AGE         then 'Shuttle AGE interrupt'
              else null
      return null

  # The interrupt page's Internal I/O commands
  #
  # DIAG 7000/7001 put an IIO command and its data on the H-BUS; sect.15
  # lists "the hexadecimal value for the H-BUS IIO command required to
  # select each of the micro sequences".  Only the ones with an externally
  # visible effect are modelled: the page's own self tests report through
  # the scan register, which stays zero on a machine with no faults.
  diagIIO: (cmd, data) ->
      switch cmd
          when 0x9014
              # START INTERRUPT PRIORITY MICROCODE TEST.  "Sets all of the
              # valid interrupts in the External Pending Interrupt
              # Register.  Also, the two interval timers are set pending.
              # Interrupt processing will then proceed in the normal
              # manner.  Any pending interrupts will be lost when this
              # command is executed."  The six externals are External 0-4
              # and AGE; the timers go into the I/O interrupt register,
              # and "Timer A and B interrupts only become macro interrupts
              # if location B0 and B1, respectively, equal zero".
              @intPendingReg = 0
              @raiseInterrupt(k) for k in ['ext0','ext1','ext2','ext3','ext4','age']
              @raiseInterrupt('clk1') if @ram.get16(0x00b0, false) == 0
              @raiseInterrupt('clk2') if @ram.get16(0x00b1, false) == 0
          when 0x900c
              # RESET PENDING INTERRUPTS.  Software uses this after an
              # operation whose side effects it does not want delivered: an
              # IOP master reset sets C/M idle, which is an External 0 the
              # code that ordered the reset is not waiting for.
              @intPendingReg = 0
          when 0x9013
              # SET/RESET INTERRUPT PAGE DIAGNOSE MODE.  "When in diagnose
              # mode, the interrupt page will not reset the computer when
              # it detects a crash interrupt condition.  Also, the ROS
              # parity error, and the Endop Timeout machine check
              # interrupts will not be generated."  Nonzero data sets the
              # mode.  This machine never resets itself, so the flag is
              # readback state only.
              @diagInterruptPageDiagnoseMode = (data != 0)
          else
              # The page's own micro tests report through the scan
              # register, which a fault-free page leaves zero.  Anything
              # genuinely unmodelled announces itself once.
              return if cmd == 0x9011
              @diagUnknownIIO ?= {}
              unless @diagUnknownIIO[cmd]
                  @diagUnknownIIO[cmd] = true
                  console.error "DIAG: unimplemented H-BUS IIO command " +
                      "0x#{cmd.toString(16)} at 0x#{@psw.getNIA().toString(16)}"
      return

  # The IOP's store protect violation: Figure 2-20 priority
  # 51, External 1, PSA 0080/0084, mask bit 36, code 0004, and "CPU
  # generated" even though it is the IOP's access that trips it. 
  #
  # Figure 2-20 note '##': "A masked DMA store protect interrupt will set
  # the condition code (CC) to a binary 10 and clear the carry and
  # overflow bits...  Additionally, a masked DMA store protect interrupt
  # clears any fixed point overflow, floating point underflow, and
  # floating point overflow interrupts.  This can result in a lost
  # arithmetic interrupt if a masked DMA store protect interrupt occurs
  # during an instruction that causes one of these arithmetic interrupts."
  signalDMAProtectViolation: () ->
      @intCodeByKey.ext1 = EXT1_DMA_PROTECT
      @intPendingReg |= INT_EXT1.bit
      if not @intEnabled(INT_EXT1)
          @psw.setCC(2)
          @psw.setCarry(0)
          @psw.setOverflow(0)
          if (@intPendingReg & INT_PROGRAM_CHECK.bit) and
             @intCode in [PC_FIXED_OVERFLOW, PC_FP_UNDERFLOW, PC_FP_OVERFLOW]
              @intPendingReg &= ~INT_PROGRAM_CHECK.bit
      return

  # POO 2.4: "Attempting to store data in a protected location will result
  # in a program interrupt.  In this case, the store operation does not
  # occur."
  signalProtectionViolation: () ->
      @intPendingReg |= INT_PROGRAM_CHECK.bit
      @intCode = PC_STORE_PROTECT

  signalAddressingException: () ->
      @intPendingReg |= INT_PROGRAM_CHECK.bit
      @intCode = PC_ADDRESS_SPEC
