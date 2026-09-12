import {now as simNow} from '../com/simRuntime.coffee'
import {RAM,Register,RegisterFile,ProgramStatusWord} from 'gpc/regmem'
import {PackedBits} from 'gpc/util'

import {DiscreteBus, applyDiscrete, bitMask, resolveGpcId,
        SET as DISC_SET, RESET as DISC_RESET,
        REQUEST as DISC_REQUEST, VALUE as DISC_VALUE,
        REG_A as DISC_REG_A, REG_B as DISC_REG_B,
        REG_OUT as DISC_REG_OUT} from 'com/discretes'
import {GpcLinks} from 'gpc/gpclinks'
import {MSC} from 'gpc/iop_msc'
import {BCE, SEV_VALID} from 'gpc/iop_bce'
import {BCEReceive} from 'gpc/iop_receive'
import {MCM} from 'gpc/mcm'
import {pollShmRings} from 'com/bus'
import {Barrier} from 'com/simbarrier'

# The per-processor status registers
#
# STAT1 (GO/NO-GO), STAT4 (BUSY/WAIT), STAT5 (halt/enable), the program
# exception register and the BCE indicator register carry one bit per
# processor:
#
#   bit 0      MSC                   0x80000000
#   bits 1-24  BCE 1 through BCE 24  (BCE 1 = 0x40000000, BCE 24 = 0x80)
#   bit 25     self-test processor   0x00000040
#   bits 26-31 unused
#
# The registers are declared 32 bits wide because that is their width on
# the interface.  Register's width argument only rounds the backing store
# up to whole halfwords and never masks.
PROC_MSC = 0                   # processor number of the MSC
PROC_SELFTEST = 25             # ...and of the self-test processor
PROC_ALL = 0xffffff80          # MSC + BCE 1-24
PROC_ALL_BCE = 0x7fffff80      # BCE 1-24, no MSC
PROC_ALL_WITH_SELFTEST = 0xffffffc0

# IOP interrupt register A (Group 1)
#
# The five sources that share External 0 (Figure 2-20 priority 50, PSA
# 0078/007C, mask bit 35, code 0000, held pending when masked).  The CPU's
# handler reads this register with PCI 08000000 to find out which of them
# it was, and the read clears it; so does an ICR channel reset.  Bit
# numbering is IBM's, bit 0 the most significant bit of the 32-bit data
# word (POO Appendix I, "READ INTERRUPT REGISTER A/GROUP 1").
INTA_GO_NOGO   = 0x80000000   # 0  GO/NO-GO (watchdog) timer timed out
INTA_IOP_FAIL  = 0x40000000   # 1  IOP fail latch, from the RM voter logic
INTA_CM_IDLE   = 0x20000000   # 2  C/M logic idle and available again
INTA_ROS_PAR   = 0x10000000   # 3  ROS parity error
INTA_IOP_FAULT = 0x08000000   # 4  IOP timing fault
                              # 5  spare

# IOP interrupt register B (Group 2)
#
# External 1's register.  Bits 1-3 are a priority-encoded error code:
# "if multiple errors occur, only the highest priority event will be
# annunciated", ordered numerically with 001 lowest and 110 highest (POO
# Appendix I, "READ INTERRUPT REGISTER B/GROUP 2"). 
INTB_CODE_MASK = 0x70000000   # bits 1-3
INTB_CODE_SHIFT = 28
INTB_DEV_OUT   = 1            # 001  device out data parity error
INTB_R123      = 2            # 010  R1, R2, R3 parity error
INTB_DMA       = 3            # 011  flow bottom DMA address or data parity
INTB_QUEUE     = 4            # 100  MC queue control parity error
INTB_MIA       = 5            # 101  MIA parity error
INTB_DIAG25    = 6            # 110  diagnostic processor 25 error
INTB_QUEUE_OVF = 0x08000000   # 4    queue overflow (>64 requests queued)
INTB_DMA_TMOUT = 0x04000000   # 5    DMA in process for more than 8 us

# The MIA enable registers' two bit numberings
#
# The transmitter and receiver enable registers are stored in PROCESSOR
# numbering, like every other per-processor register here: bit n is BCE n,
# and bit 0 (the MSC's) is unused because the MSC has no MIA.  That is the
# numbering the ENABLE/DISABLE PCO data word uses -- "BIT 0 NOT USED ...
# BIT 1 CHANNEL NO. 1 MIA TRANSMITTER ... BIT 24 CHANNEL NO. 24 ... BITS
# 25-31 NOT USED".  A 1 in bit 0 is not a command to do anything: "the
# hardware does not respond".
#
# The READ PCIs, though, report in CHANNEL numbering -- "BIT 0 CHANNEL NO.
# 1 MIA TRANSMITTER ... BIT 23 CHANNEL NO. 24, BITS 24-31 NOT USED" -- so
# the word that comes back is the mask that went out shifted one place
# left. 
MIA_WRITE_MASK = 0x7fffff80    # BCE 1-24 in processor numbering
MIA_READ_MASK  = 0xffffff00    # channels 1-24 in channel numbering

# Discrete inputs
#
# Two 32-bit discrete input registers carry signals from outside the 
# GPC assembly. Ref. IBM-85-C67-001/p.321-325:
#
#   A   0     HALT (DI-0)
#             The setting of this bit indicates that the crew panel
#             switch has been set to 'HALT' Receipt of this DI
#             causes the IOP to configure all processors to Halt
#             thereby prohibiting IOP operation. The CPU is held
#             in system reset by this discrete.
#       1     STANDBY (DI-1)
#             This bit is set from a crew panel switch.
#       2     RUN (DI-2)
#             The bit is set from a crew panel switch.
#       3     IPL (DI-3)
#             Bit is set by crew panel switch.  The IOP response is to
#             perform the Initial Program Loading using data from the
#             Mass Memory Unit as indicated below (DI-5, 6, 7 and 8)
#       4     MM1 IPL (DI-4)
#             The discrete is driven from the orbiter systems network
#             and when set indicates that MM1 is to be used as source
#             for IPL.
#       5     MM2 IPL (DI-5)
#             same as bit 4 abore except applies to No. 2
#             Mass Memory Unit.
#       6     MM1 READY (DI-6)
#             This signal originates in No. 1 Mass Memory Unit and indicates,
#             when set, that No. 1 MMU is available for use.
#       7     MM2 READY (DI-7)
#             Same as bit 6 above except applies to No. 2 MMu.
#       8     (DI-8) GPC N+1 IS BFS RUN GPC
#       9     (DI-9) GPC N+2 IS BFS RUN GPC
#       10    (DI-9) GPC N+3 IS BFS RUN GPC
#       11    (DI-10) GPC N+4 IS BFS RUN GPC
#       12    I/O TERMINATE A (DI-11) 
#             Receipt of this DI causes the IOP to inhibit the MIA
#             transmitters thereby prohibiting the output of data
#             on Channels 10-13 (MIA's 10-13)
#       13    INHIBIT CHANS. 14-17 AND 20-23 (DI-13) 
#             Also called I/O terminate B discrete.
#             Receipt of this DI causes the IOP to inhibit MIA
#             transmitters 14-17 and 20-23.
#
#       14    SPARE (DI-14)
#       15    HISASM DUMP (DI-15)
#             SET BY ORBITER SWITCH TO INDICATE GPC DUMP REQUESTED
#       16    SPARE (DI-16)
#       17    SPARE (DI-17)
#       18    SPARE (DI-18)
#       19    SPARE (DI-19)
#       20    (DI-20) GPC N+1 DISCRETE OUTPUT BIT 20 (SYNC 1)
#       21    (DI-21) GPC N+2 DISCRETE OUTPUT BIT 20 (SYNC 1)
#       22    (DI-22) GPC N+3 DISCRETE OUTPUT BIT 20 (SYNC 1)
#       23    (DI-23) GPC N+4 DISCRETE OUTPUT BIT 20 (SYNC 1)
#       24    (DI-24) GPC N+1 DISCRETE OUTPUT BIT 24 (SYNC 2)
#       25    (DI-25) GPC N+2 DISCRETE OUTPUT BIT 24 (SYNC 2)
#       26    (DI-26) GPC N+3 DISCRETE OUTPUT BIT 24 (SYNC 2)
#       27    (DI-27) GPC N+4 DISCRETE OUTPUT BIT 24 (SYNC 2)
#       28    (DI-28) GPC N+1 DISCRETE OUTPUT BIT 28 (SYNC 3)
#       29    (DI-29) GPC N+2 DISCRETE OUTPUT BIT 28 (SYNC 3)
#       30    (DI-30) GPC N+3 DISCRETE OUTPUT BIT 28 (SYNC 3)
#       31    (DI-31) GPC N+4 DISCRETE OUTPUT BIT 28 (SYNC 3)
#
#   B   0-2   (DI-32,33,34) GPC SELFS IDS
#       3-5   (DI-35,36,37) BFS ENGAGE 1/2/3
#             SET BY ORBITER BFS CONTROLLER
#             WHEN BFS ENGAGE PUSH-BUTTON
#             IS DEPRESSED.
#       6-7   BFS CRT SELECT A AND B
#             INDICATES CURRENT SETTING OF
#             ORBITER BFC CRT SELECT SWITCH,
#             IF BFC CRT DISPLAY SWITCH
#             IS ON.
#       8-31  unused, undefined
#
# External lines arrive as SET/RESET masks on the discrete bus.  GpcLinks
# drives bits 8-11 and 20-31 from the other computers.
#   GPC 0, IPL source MM1, MM1 ready, display CRT 1.
#
DISCRETE_IN_A_DEFAULT = 0x0b000000    # bit 4 = MM1 is the IPL source,
                                      # bits 6,7 = MM1/MM2 ready
DISCRETE_IN_B_DEFAULT = 0x01000000    # bits 6-7 = CRT 1

GPC_ID_MASK = 0xe0000000
GPC_ID_SHIFT = 29

export gpcSelfId = (n) -> if n? then resolveGpcId(n) else 0

MM_READY_BIT = {1: 6, 2: 7}           # discrete input A

# During sync activity, the run loop services host I/O every HOT_TURN_NS.
# Activity is a nonzero, non-null sync code or DIA_BURST register-A reads
# spaced within DIA_BURST_NS.  A polling burst remains hot for HOT_TAIL_NS
# and at most HOT_POLL_MAX_NS.
HOT_TAIL_NS = 200000
HOT_TURN_NS = 100000
HOT_POLL_MAX_NS = 400000000
DIA_BURST = 3
DIA_BURST_NS = 50000

# Shared-memory rings are polled and flushed from the instruction loop.
SHM_POLL_NS = 20000
TX_FLUSH_NS = 20000

# Instruction-loop barrier interval.
BARRIER_NS = 10000
SYNC_OUT_MASK = 0x00000888          # DO-20, 24, 28: SELF SYNC 1, 2, 3

# GPC mode toggle: HALT, STANDBY and RUN (DI-0, DI-1, DI-2) 
#   HALT going high holds the machine in reset
#   STANDBY and RUN are read at a higher level by SSW
DISC_HALT = 0
# IPL: when the CPU is in HALT, hardware detects the IPL disc
#   going high to clear memory and load the bootstrap loader
#   from the MMU:
DISC_IPL  = 3

# I/O TERMINATE A and B, by the channels each inhibits.  A takes the
# payload and launch buses, B the eight flight critical buses.  Mass
# memory, channels 18 and 19, lies between B's two ranges and is left
# alone: a computer whose flight critical output is cut can still be
# loaded.
IO_TERM_A = 12
IO_TERM_B = 13

channelMask = (channels) ->
  mask = 0
  for c in channels
    mask = (mask | (0x80000000 >>> c)) >>> 0
  mask

IO_TERM_MASK = {}
IO_TERM_MASK[IO_TERM_A] = channelMask([10..13])
IO_TERM_MASK[IO_TERM_B] = channelMask([14..17].concat([20..23]))

# A local store word is 18 bits.  Register(18) backs that with two
# halfwords, and the model keeps the value as a plain integer through
# get32/set32 -- the paired registers (IH/IL, AH/AL, DH/DL, BSTH/BSTL) are
# the exception, being two 16-bit halves of a 32-bit quantity.
LS_WORD_MASK = 0x3ffff

# NSTS_RECV_TRACE prints every halfword a bus control element takes off its
# bus and the main-storage address it lands at: 1 for the whole IOP, or a
# processor number to follow one bus. 
RECV_TRACE = do ->
  v = process?.env?.NSTS_RECV_TRACE
  return false unless v
  if /^\d+$/.test(v) and +v > 1 then +v else true

# GPC_IOP_BCE accepts one processor, a comma list, or `all`.
TRACE_BCES = do ->
  v = process?.env?.GPC_IOP_BCE
  return null unless v? and v != ''
  return 'all' if v.toLowerCase() in ['all', '*']
  new Set(+n for n in v.split(/[\s,]+/) when /^\d+$/.test(n))

# NSTS_BUS_TIMEOUT_TRACE prints every BCE receive time out with how long it
# waited on both clocks, simulated and wall.
TIMEOUT_TRACE = process?.env?.NSTS_BUS_TIMEOUT_TRACE?

# GO/NO-GO timer resolution: "bit 31 (LSB) = 0.768 msec", 12 bits, so
# 3.145728 s at a full count (POO Appendix I, LOAD GO/NO-GO TIMER).
WD_TICK_NS = 768000
WD_COUNT_MASK = 0xfff

# Maximum time out register resolution: "The resolution of this timeout
# count is 16.5 microseconds", which the two ranges the POO quotes agree
# with -- 2047 counts to 33.78 ms, 262143 to 4.325 s.
MTO_TICK_NS = 16500

# How long one count of an MSC repeat instruction lasts.  Two of the IOP's
# 16.5 us resolution -- see the note on IOP.mscRepeat for the two flight
# constants that fix it.
MSC_REPEAT_TICK_NS = 2 * 16500

# NSTS_IOP_FAULT_TRACE reports the MSC program exceptions the POO defines for
# a BCE register load, or a start, naming a processor that is not in the wait
# state.  Flight software takes some of these in normal operation, so it is a
# switch and not a permanent log.
IOP_FAULT_TRACE = process?.env?.NSTS_IOP_FAULT_TRACE?
# How many of each (operation, processor) pair to report before falling
# silent.  The default shows that a fault happens; raise it to see when an
# intermittent one does.
IOP_FAULT_MAX = do ->
  v = process?.env?.NSTS_IOP_FAULT_MAX
  if v? then parseInt(v, 10) else 3

# The shortest a receive time out is allowed to be, in simulated time.
#
# The floor is zero: the time out the software loaded governs, as it does on
# the machine.  A floor above the loaded time out holds a bus control element
# busy past the point the software gives up on the transaction, and the
# sequence that follows wedges it: the software halts the element while it is
# still busy; the MSC's LOAD BCE PROGRAM COUNTER is refused (POO 6246556A,
# MSC section 3.4 -- a busy or halted element is not loaded and the MSC takes
# a program exception); and the START I/O that follows restarts the element
# wherever its program counter stopped, the halfword after the STORE STATUS /
# WAIT tail of the abandoned program, which STORE STATUS had just zeroed.  The
# element then executes zeros, never advancing, and its bus is silent for the
# rest of the run.
#
# The round trip through the host costs one to five milliseconds of simulated
# time, against the 303 counts (5.0 ms) the software loads for a display
# unit's poll, so an ordinary poll times out several times a minute and each
# one is an I/O error the hardware would not raise.
# NSTS_RECV_TIMEOUT_FLOOR_MS sets a floor for comparison.
REPLY_CMD_WINDOW_MS = 50
# BCEs whose pending replies hold simulated time.
STALL_BCES = [14, 15, 16, 17, 18, 19, 20, 21, 22, 23]

RECV_TIMEOUT_FLOOR_NS = do ->
  v = process?.env?.NSTS_RECV_TIMEOUT_FLOOR_MS
  return 0 unless v?
  Math.round(parseFloat(v) * 1e6)

class IOPLocalStore
  constructor: () ->
    # 0 = MSC, 1-24 = the BCEs, 25 = the diagnostic / self-test
    # processor.  25 runs no program and has a local store page: the
    # MSC and BCE self-test micro programs leave their
    # signature in it (POO: "MSC self-test modifies Proc 25's locations
    # in Local Store"), and software reads it back through READ LOCAL
    # STORE region 25 to confirm the test ran.
    @storePage = (new RegisterFile(x,16,18) for x in [0..25])

    @slice = 0
    @curBCE = 0
    @curPage = 0

  nextSlice: () ->
    @slice++
    if @slice == 33
      @slice = 0
      @curBCE = 0
      @curPage = 0
    if @slice % 4 != 0
      @curBCE++
      @curPage = @curBCE
    else
      @curPage = 0

  # MSC Mapping
  #
  #           BANK A      BANK B      BANK C
  # WORD 1       WR          WR          WR
  # WORD 2       WR          WR          WR
  # WORD 3    PROG CNTR  INSTR HI    INSTR LO
  # WORD 4    INDEX REG  ACCUM HI    ACCUM LO
  # WORD 5                              WR
  # WORD 6                              WR
  # WORD 7                         EXT CALL REG
  # WORD 8                            STATUS

  # BCE Mapping
  #
  #           BANK A      BANK B      BANK C
  # WORD 1       WR
  # WORD 2       WR          WR          WR
  # WORD 3    PROG CNTR  INSTR HI    INSTR LO
  # WORD 4    IDENT REG MAX TIME OUT BASE REG
  # WORD 5                              WR
  # WORD 6                           IUA REG
  # WORD 7                           STATUS HI
  # WORD 8                           STATUS LO

  cp: () -> @storePage[@curPage]

  # Bank A and B hold four words each and bank C eight, which is the 16
  # registers a page has: A = 0-3, B = 4-7, C = 8-15.
  ls: (bank,word) -> @cp().r(bank*4+word)

  # Local store as the CPU addresses it (LOAD/READ LOCAL STORE): region 0 is
  # the MSC, 1-24 are BCE 1-24, 25 is the self-test processor.
  at: (region, bank, word) ->
    page = @storePage[region]
    return null unless page?
    return page.r(bank*4 + word)

  # COMMON:
  PC: () -> @ls(0,2)
  IH: () -> @ls(1,2)
  IL: () -> @ls(2,2)

  # MSC:
  X:   () -> @ls(0,3)
  AH:  () -> @ls(1,3)
  AL:  () -> @ls(2,3)
  ECR: () -> @ls(2,6)
  MST:  () -> @ls(2,7)

  #BCE:
  DH:   () -> @ls(1,0)
  DL:   () -> @ls(2,0)
  ID:   () -> @ls(0,3)
  MTO:  () -> @ls(1,3)
  BASE: () -> @ls(2,3)
  IUAR: () -> @ls(2,5)
  BSTH:  () -> @ls(2,6)
  BSTL:  () -> @ls(2,7)

  getI: () -> (@IH().get16() << 16) | @IL().get16()
  setI: (v) ->
    @IH().set16(v>>>16)
    @IL().set16(v&0xffff)

  getD: () -> (@DH().get16() << 16) | @DL().get16()
  setD: (v) ->
    @DH().set16(v>>>16)
    @DL().set16(v&0xffff)

  getACC: () -> (@AH().get16() << 16) | @AL().get16()
  setACC: (v) ->
    @AH().set16(v>>>16)
    @AL().set16(v&0xffff)

  getBST: () -> (@BSTH().get16() << 16) | @BSTL().get16()
  setBST: (v) ->
    @BSTH().set16(v>>>16)
    @BSTL().set16(v&0xffff)

export class IOP
  # opts.iopWords sizes the share of main storage packaged in this LRU
  # (fullwords, 0 on the AP-101S where the store is one unit in the CPU LRU);
  # see gpc/machine.coffee.  Defaults to the AP-101B IOP LRU's 24K.
  # `gpcId` is this computer's self-ID, 0 to 5, constant for the life of
  # the machine: it seeds discrete input B and names the discrete channel.
  constructor: (@cpu, opts = {}, gpcId = null) ->
    @mainStorage = new MCM(opts.iopWords ? 24*1024)

    @msc = new MSC()
    # Set before the BCEs are built: BCE 24's bus is this computer's IP bus.
    @gpcId = gpcSelfId(gpcId)
    @powered = true
    @ioTurnWanted = false
    @lastTurnNs = 0
    @lastShmPollNs = 0
    @lastBarrierNs = 0
    @barrier = null
    @barrierOffsetUs = null
    @barrierHeld = false
    @txPending = []
    @lastDiaReadNs = -1e12
    @diaBurst = 0
    @pollStartNs = 0
    @bce = (new BCE(x, @) for x in [1..24])

    @curPE = 0  # MSC = 0, BCE = 1-24

    @dmaBurst = true
    @dmaForceBadParity = false
    @dataForceBadParity = false

    # Data flow parity (POO Appendix I, DATA FLOW PARITY CHECK)
    #
    # "Parity is generated in four locations in the IOP in order to detect
    # single bit errors.  Each of the four generators has its
    # corresponding checker...  All four checkers can be individually
    # checked with the PCO commands to force bad parity."  The four are
    # the H-Bus receive path (checked twice -- once off the device-out
    # data bus, and again, indirectly, when registers R1/R2/R3 are used),
    # the DMA address/data path out to the CPU, the bus to the octal MIAs,
    # and the local store address plus queue control bits.
    #
    # Checking starts disabled: "events that disable parity checking
    # include Power On, System Reset, and Disable Flow Parity Check".
    @parityEnabled = false
    @forceHBusParity = false      # C102: H-Bus received data
    @forceQueueParity = false     # C108: local store address / queue control
    @forceDMAParity = false       # C140: DMA address and data
    @forceMIAParity = false       # C180: octal MIA pages

    # Data that reached local store over a poisoned H-Bus carries the bad
    # parity with it: the device-out checker catches the transfer as it
    # arrives, and the IB page catches it AGAIN -- later -- when the owning
    # processor uses that register.  One tag set per local store page,
    # holding the indices of the registers written badly.
    @lsBadParity = ({} for x in [0..PROC_SELFTEST])


    # One bit per processor, laid out as the hardware lays them out (see
    # the comment above PROC_MSC).
    @regXmitEna = new Register("xmitEnable", 32)   # MIA transmitter enables
    @regRecvEna = new Register("resvEnable", 32)   # MIA receiver enables

    @regProgExcept = new Register("GO_NOGO", 32)   # STAT1: 1 = GO, 0 = error
    @regBusyWait = new Register("BUSY_WAIT", 32)   # STAT4: 1 = BUSY, 0 = WAIT
    # STAT5, "the Halt Register", read by READ PROCESSOR HALT STATUS --
    # whose data word is documented the enable way round: "0 = Processor
    # (MSC or BCE) Disabled, 1 = Processor Enabled".
    @regProcEnable = new Register("PROC_ENABLE", 32)
    @regIndicator = new Register("Indicator", 32)  # BCE indicator bits

    @regDiscreteOut = new Register("discreteOut", 32)
    @regDiscreteInA = new Register("discreteInA", 32)
    @regDiscreteInB = new Register("discreteInB", 32)
    @discDriven = {}
    @xmitInhibit = 0
    @discDriven[DISC_REG_A] = 0
    @discDriven[DISC_REG_B] = 0
    @resetDiscreteInputs()
    @_setupDiscreteBus()
    @regRMStatus = new Register("RMStatus", 32)

    @regInterrupts = new RegisterFile("int",5,32) # Interrupt Regs A-E
    @intForceTest = false

    # GO/NO-GO (watchdog) timer: a 12-bit count-UP device ticking every
    # 0.768 ms.  Software loads the two's complement of the interval it
    # wants, so the count reaching zero again is the timeout.  It does not
    # run until a LOAD GO/NO-GO TIMER PCO starts it -- "once the timer has
    # been reset, the counter will not operate until loaded via this PCO".
    @wdCount = 0
    @wdRunning = false
    @wdTimeout = false           # timeout latch (RM status bit 16)
    @wdAccumNs = 0
    @wdLastNs = 0

    # Redundancy management's voter, in the only mode a single simulated
    # GPC can be in: self test.  See loadVoterTest.
    @rmVoterInhibit = false
    @rmTestInputs = 0
    @rmVoterFail = false

    @regCCData = new Register("CCData",32)

    @ls = new IOPLocalStore()

    @dmaQueue = []
    @clockCycleCount = 0

    # See RECV_TIMEOUT_FLOOR_NS.  A property rather than a constant so a
    # harness with everything in one process can turn it off.
    @recvTimeoutFloorNs = RECV_TIMEOUT_FLOOR_NS
    # BCEs with a receive begun and no word taken yet; see replyOwedSince.
    @recvPending = 0

    # State of an MSC Repeat instruction in progress -- see mscRepeat.
    @mscRepeatPC = null
    @mscRepeatLeft = 0
    @mscRepeatUntilNs = 0

  # Per-processor register access
  #
  # Processor p's bit, and reading/writing it in one of the status
  # registers.  
  PROC_MSC: PROC_MSC
  PROC_SELFTEST: PROC_SELFTEST
  PROC_ALL: PROC_ALL
  PROC_ALL_BCE: PROC_ALL_BCE

  # The two interrupt registers' bit names, for the instruction
  # bodies that raise them (the MSC's self test reaches three of these).
  INTA_ROS_PAR: INTA_ROS_PAR
  INTB_DIAG25: INTB_DIAG25
  INTB_QUEUE_OVF: INTB_QUEUE_OVF

  procBit: (p) -> (0x80000000 >>> p) >>> 0

  procGet: (reg, p) -> if (reg.get32() & @procBit(p)) != 0 then 1 else 0

  procSet: (reg, p, v) ->
    m = @procBit(p)
    cur = reg.get32()
    reg.set32(if v then (cur | m) >>> 0 else (cur & ~m) >>> 0)
    return

  exec: () ->
    @execChannelControl()
    @execDMAQueue()
    @execProcessors()
    @execRM()

  execChannelControl: () ->


  # How many transfers may sit queued waiting for words that have not
  # arrived.  A receive DMA WAITS for its word (see below), so a bus with
  # nothing on it would otherwise pile up requests forever as the BCE
  # program loops.
  DMA_QUEUE_MAX: 4096

  execDMAQueue: () ->
    # Process one DMA request per cycle
    if @dmaQueue? and @dmaQueue.length > 0
      req = @dmaQueue[0]
      if req.direction == 'read'  # IOP reading from main memory (transmit to bus)
        @dmaQueue.shift()
        data = @cpu.mainStorage.get16(req.addr)
        @ls.setD(data)
        if req.bce? and @xmitEnabled(req.bce.bceNum)
          req.bce.mia.xmitWord(data)
      else  # IOP writing to main memory (receive from bus)
        return unless req.bce? and req.bce.mia.dataAvailable()
        @dmaQueue.shift()
        data = req.bce.mia.getData()
        @ls.setD(data)
        @writeMain16(req.addr, data)

      if @dmaBurst and @dmaQueue.length > 0
        @execDMAQueue()  # Burst mode: continue processing

  queueDMATrim: () ->
    @dmaQueue.shift() while @dmaQueue.length > @DMA_QUEUE_MAX
    return

  execProcessors: () ->
    @ls.nextSlice()
    page = @ls.curPage

    @curPE = page

    # Check halt state for current processor
    if page == 0  # MSC
      if not @procGet(@regProcEnable, PROC_MSC)   # halted
        return
      if not @procGet(@regBusyWait, PROC_MSC)     # not busy = waiting
        return
    else  # BCE 1-24, whose processor number is the local store page
      bceIdx = page
      if not @procGet(@regProcEnable, bceIdx)     # halted
        return
      if not @procGet(@regBusyWait, bceIdx)       # not busy = waiting 
        @clearBCETransfer(bceIdx)
        return

    # A slice is where the three data flow parity checkers that watch a
    # running processor get their chance, in the register's priority order
    # Any of them halts every processor, so the slice ends.
    return if @checkQueueParity()
    return if @checkDMAParity()
    return if @checkLocalStoreParity(page)

    # Fetch instruction
    pc = @ls.PC().get32() & LS_WORD_MASK
    hw1 = @cpu.mainStorage.get16(pc)
    hw2 = @cpu.mainStorage.get16(pc + 1)
    @ls.IH().set16(hw1)
    @ls.IL().set16(hw2)

    @onProcStep?(page, pc, hw1, hw2) if @traceProcs?[page]

    # Decode and execute - each proc manages its NIA
    if page == 0  # MSC
      @msc.exec(@, hw1, hw2)
    else  # BCE
      bce = @bce[page - 1]
      bce.exec(@, hw1, hw2)

  # Per-BCE state and traffic trace.
  IOP_TRACE_BCE: TRACE_BCES

  bceTraced: (bceNum) ->
    @IOP_TRACE_BCE? and (@IOP_TRACE_BCE == 'all' or @IOP_TRACE_BCE.has(bceNum))

  bceMaskEvent: (mask, what) ->
    return unless @IOP_TRACE_BCE?
    @bceEvent(p, what) for p in [1..24] when (mask & @procBit(p)) != 0
    return

  bceEvent: (bceNum, what) ->
    return unless @bceTraced(bceNum)
    pc = (@ls.at(bceNum, 0, 2)?.get32() ? 0) & LS_WORD_MASK
    en = @procGet(@regProcEnable, bceNum)
    bw = @procGet(@regBusyWait, bceNum)
    @trace("BCE#{bceNum} #{(@cpu.timeNs / 1e6).toFixed(3)} ms  #{what}" +
           "   [en=#{en} busy=#{bw} pc=#{pc.toString(16)}]", {bce: bceNum, what})

  # A debug session replaces stderr with its timestamped event sink.
  onTrace: null

  trace: (text, fields = {}) ->
    if @onTrace? then @onTrace(text, fields) else process.stderr.write(text + "\n")
    return

  # The MSC's BCE register-load instructions require their BCE to be in the
  # WAIT state and enabled; a busy or halted one is a program exception, and
  # the load does not happen -- the BCE keeps whatever program counter and
  # base register it had.  The bit in the MSC status register is the whole of
  # the report on real hardware, so a BCE restarted on a stale program
  # counter shows nothing from the outside.
  mscBCEFault: (op, bceNum) ->
    return unless IOP_FAULT_TRACE
    @iopFaults ?= {}
    key = "#{op}:#{bceNum}"
    @iopFaults[key] = (@iopFaults[key] ? 0) + 1
    return if @iopFaults[key] > IOP_FAULT_MAX
    pc = (@ls.at(bceNum, 0, 2)?.get32() ? 0) & LS_WORD_MASK
    why = if @procGet(@regBusyWait, bceNum) then 'busy' else 'halted'
    console.log "IOP: #{(@cpu?.timeNs ? 0) / 1e6} ms  #{op} BCE #{bceNum} " +
                "refused -- #{why}, PC left at #{pc.toString(16)}"

  # START I/O naming a BCE that is already busy is the same class of error.
  mscSIOConflict: (mask) ->
    return unless IOP_FAULT_TRACE
    who = (p for p in [1..24] when (mask & @procBit(p)) != 0)
    @iopFaults ?= {}
    key = "sio:#{who.join(',')}"
    @iopFaults[key] = (@iopFaults[key] ? 0) + 1
    return if @iopFaults[key] > 3
    console.log "IOP: @SIO conflict, BCE #{who.join(', ')} already busy"

  # A processor whose fetch decodes to nothing leaves its program counter
  # where it was, so it stands on the same halfword for the rest of the run
  # and takes millions of these at one site.  Reported once per site.
  unknownProcOp: (hw1, hw2) ->
    page = @ls.curPage
    pc = @ls.PC().get32() & LS_WORD_MASK
    @unknownOps ?= {}
    key = "#{page}:#{pc}"
    return if @unknownOps[key]
    @unknownOps[key] = true
    who = if page == 0 then 'MSC' else "BCE #{page}"
    h1 = (hw1 & 0xffff).toString(16).padStart(4, '0')
    h2 = (hw2 & 0xffff).toString(16).padStart(4, '0')
    console.log "#{who}: unknown instruction #{h1} #{h2} at #{pc.toString(16)}"

  # Redundancy management: the GO/NO-GO timer is RM's, and this is where
  # it advances.  Called once per CPU instruction
  execRM: () ->
    @tickWatchdog()
    @tickLinks()


  curBCE: () ->
    if @ls.curPage > 0
      return @bce[@ls.curPage - 1]
    return null

  queueDMA: (addr, direction, bce=null) ->
    @dmaQueue.push({addr: addr, direction: direction, bce: bce})
    @queueDMATrim()

  # Receiving, and the maximum time out register
  #
  # A BCE receive instruction WAITS.  It does not hand its word count to
  # the DMA machinery and run on to the next instruction: the BCE sits
  # there until the subsystem has sent every word. 
  #
  # Returns true when the transfer is complete, and the caller advances
  # the program counter; false while it is still waiting
  #
  bceReceive: (addr, count) ->
    bce = @curBCE()
    return true unless bce?
    pc = @ls.PC().get32() & LS_WORD_MASK
    receive = bce.recv
    unless receive? and receive.pc == pc
      receive = @_startBCEReceive(bce, pc, addr, count)
    return false unless @_advanceBCEReceive(bce, receive)
    return @_completeBCEReceive(bce, receive) if receive.complete()
    @_waitBCEReceive(bce, receive)

  _startBCEReceive: (bce, pc, addr, count) ->
    processor = @curPE
    dropped = bce.mia.dropStale()
    @onDropStale?(processor, pc, dropped) if dropped
    bce.mia.rxBegin(@cpu?.timeNs ? 0)
    @_releaseBCEReceive(bce)
    receive = bce.recv = new BCEReceive({
      pc: pc, addr: addr, count: count, nowNs: @cpu?.timeNs ? 0
      deliverAt: bce.mia.deliverCount, turnsAt: @cpu?.ioTurns ? 0
      startWall: simNow(), sinceWall: if TIMEOUT_TRACE then simNow() else 0
    })
    @recvPending += 1
    @bceEvent(processor, "receive of #{count} words begins, #{bce.mia.recvQueue.length} queued" +
                 ", first due #{bce.mia.dueInUs()} us from now" +
                 (if dropped then ", #{dropped} stale words dropped" else ''))
    receive

  _advanceBCEReceive: (bce, receive) ->
    processor = @curPE
    pc = receive.pc
    while receive.left > 0 and bce.mia.dataAvailable()
      data = bce.mia.getData()
      sev = bce.mia.lastSev
      if sev != SEV_VALID
        # POO sect.3.4.4 and 3.4.6: an input word whose SEV bits are other
        # than 101 is not accepted, and "the BCE will error terminate
        # regardless of its mode", ORing into the high half of its status
        # register "the SEV bits from the input with the S and V bits
        # inverted" and the interface unit address.  JSC-18819 Rev.F's
        # error table places them: bit 5 S reset, bit 6 E set, bit 7 V
        # reset, bits 8-12 the IUA.
        iua = @ls.IUAR().get32() & 0x1f
        @ls.setBST((@ls.getBST() | (((sev ^ SEV_VALID) & 7) << 24) | (iua << 19)) >>> 0)
        if TIMEOUT_TRACE
          @trace("BCE#{processor} RECV SEV #{sev.toString(2).padStart(3, '0')} " +
                 "pc=#{pc.toString(16)} left=#{receive.left} iua=#{iua}", {bce: processor})
        @bceErrorTerminate(processor)
        return false
      @ls.setD(data)
      ok = @writeMain16(receive.addr, data)
      if RECV_TRACE == true or RECV_TRACE == processor
        @trace("RECV BCE#{processor} #{receive.addr.toString(16)} <- " +
               "#{data.toString(16).padStart(4,'0')}#{if ok then '' else '  REJECTED'}", {bce: processor})
      @recvPending -= 1 unless receive.gotAny
      receive.advance(@cpu?.timeNs ? 0,
                 if TIMEOUT_TRACE then simNow() else receive.sinceWall)
    true

  _completeBCEReceive: (bce, receive) ->
    processor = @curPE
    @bceEvent(processor, "receive complete in " +
                 "#{(((@cpu?.timeNs ? 0) - receive.beganNs) / 1e6).toFixed(3)} ms")
    @_releaseBCEReceive(bce)
    # Hardware captures bus words during a commanded transfer. The MIA queue
    # retains unconsumed datagram words across receive instructions: a mass
    # memory block arrives as one datagram of 512 halfwords.
    return true

  _waitBCEReceive: (bce, receive) ->
    processor = @curPE
    pc = receive.pc
    # GPC_IOP_BCE counts waiting turns by the queue state: an empty queue
    # is starved; queued words awaiting their wire time are paced.
    if @bceTraced(processor)
      if bce.mia.recvQueue.length == 0
        bce.starveTurns = (bce.starveTurns ? 0) + 1
      else
        bce.pacedTurns = (bce.pacedTurns ? 0) + 1

    if receive.timedOut(@cpu?.timeNs ? 0, @recvTimeoutNs(processor))
      if TIMEOUT_TRACE
        simMs = ((@cpu?.timeNs ? 0) - receive.sinceNs) / 1e6
        wallMs = simNow() - receive.sinceWall
        @trace("BCE#{processor} RECV TIMEOUT pc=#{pc.toString(16)} " +
               "left=#{receive.left} gotAny=#{receive.gotAny} " +
               "sim=#{simMs.toFixed(2)}ms wall=#{wallMs}ms " +
               "delivered=#{bce.mia.deliverCount - (receive.deliverAt ? 0)} " +
               "turns=#{(@cpu?.ioTurns ? 0) - (receive.turnsAt ? 0)} " +
               "queued=#{bce.mia.recvQueue.length} " +
               "mto=#{(@recvTimeoutNs(processor)/1e6).toFixed(2)}ms", {bce: processor})
      @bceErrorTerminate(processor)
    return false

  # A delay instruction holds the BCE at the instruction for 
  # count x 16.5 us.
  # Returns true when the delay is up and the caller may advance.
  bceDelay: (count) ->
    bce = @curBCE()
    return true unless bce?
    pc = @ls.PC().get32() & LS_WORD_MASK
    now = @cpu?.timeNs ? 0
    st = bce.delay
    unless st? and st.pc == pc
      st = bce.delay = {pc: pc, untilNs: now + count * MTO_TICK_NS}
    return false if now < st.untilNs
    bce.delay = null
    true

  # The command of a #MOUT / #MIN.
  #
  # The fullword holding it carries eight zero bits, the 5-bit interface
  # unit address and the 19-bit command.  The four-halfword forms carry it
  # as a companion word at PC + 2; the indexed forms pass the address of
  # their command table entry.
  #
  # Returns the 24-bit command, or null if the transmitter is disabled.
  bceCommand: (addr = null) ->
    bce = @curBCE()
    return null unless bce?
    return null unless @xmitEnabled(@curPE)
    addr ?= @ls.PC().get32() + 2
    cmd = @g_EAF(addr & LS_WORD_MASK) & 0x00ffffff
    @ls.IUAR().set32((cmd >>> 19) & 0x1f)
    bce.mia.xmitCmd(cmd)
    cmd

  # True the first time a BCE reaches the receive at the current program
  # counter -- a receive re-fetches its instruction until the count is
  # met, and the command that asked for the data must go out once only.
  bceReceiveStarting: () ->
    bce = @curBCE()
    return true unless bce?
    pc = @ls.PC().get32() & LS_WORD_MASK
    not (bce.recv? and bce.recv.pc == pc)

  # Abandon whatever a BCE had in flight: the receive it was part way
  # through and anything its MIA had taken off the bus but not yet moved.
  clearBCETransfer: (p) ->
    bce = @bce[p - 1]
    return unless bce?
    @_releaseBCEReceive(bce)
    bce.mia.flushRecv() if bce.mia?.recvQueue?.length
    return

  # Is anything in the IOP actually running -- enabled and busy?  
  processorsRunning: () ->
    ((@regBusyWait.get32() & @regProcEnable.get32()) >>> 0) != 0

  # One IOP step taken while the CPU is idle: the processors and their
  # transfers run, but redundancy management does not, because the caller
  # is already ticking the GO/NO-GO timer on a schedule of its choosing.
  execIdle: () ->
    @execDMAQueue()
    @execProcessors()
    return

  _releaseBCEReceive: (bce) ->
    st = bce.recv
    return unless st?
    @recvPending -= 1 unless st.gotAny
    bce.recv = null
    return

  # Oldest wall time at which an answered bus began owing its first word.
  # Command and receive may occur in either order; the later starts the hold.
  # A receive more than REPLY_CMD_WINDOW_MS after its command is unrelated.
  replyOwedSince: () ->
    return null unless @recvPending > 0
    since = null
    for bce in @bce
      continue unless bce.bceNum in STALL_BCES
      st = bce.recv
      continue unless st? and not st.gotAny
      mia = bce.mia
      continue unless mia?.everHeard and mia.recvQueue.length == 0
      cmdWall = mia.lastCmdWall
      if cmdWall >= st.startWall
        t = cmdWall
      else if st.startWall - cmdWall < REPLY_CMD_WINDOW_MS
        t = st.startWall
      else
        continue
      since = t if not since? or t < since
    since

  # The maximum time out register in nanoseconds.  "The resolution of this
  # timeout count is 16.5 microseconds", over "0 and 2047 ... 0 to 33.78
  # millisec" immediate or "0 and 262143, or 0 to 4.325 sec" from storage.
  #
  # The POO scopes the register to "how long a BCE will wait for the FIRST
  # input word to arrive from a previously commanded subsystem"; it says
  # nothing about the gap between word two and word three.  Something must
  # bound that as well,so the same register stands in for it, measured
  # from the last word that arrived.
  #
  # The configured floor applies only after the bus has answered.
  recvTimeoutNs: (p) ->
    mto = (@ls.at(p, 1, 3)?.get32() ? 0) & LS_WORD_MASK
    ns = mto * MTO_TICK_NS
    return ns unless @bce[p - 1]?.mia?.everHeard
    Math.max(ns, @recvTimeoutFloorNs)

  # POO III-20: release from halt "continues for several BCE microcycles
  # (about 100 usec.) as the BCE resets its internal registers and prepares
  # to enter the Wait state".  The MIA buffer is retained.
  bceHalt: (p) ->
    bce = @bce[p - 1]
    return unless bce?
    @_releaseBCEReceive(bce)
    bce.delay = null
    @dmaQueue = @dmaQueue.filter (r) -> r.bce != bce
    @procSet(@regBusyWait, p, 0)
    return

  # An error termination: the BCE stops where it is.  Its program
  # exception bit goes to 0 (NO-GO in STAT1), it leaves the busy state, 
  # and its indicator bit is set
  #
  # Anything the MIA had received is dropped with it..
  # The BCE's status register is left alone
  bceErrorTerminate: (p) ->
    @procSet(@regProgExcept, p, 0)
    @procSet(@regBusyWait, p, 0)
    @procSet(@regIndicator, p, 1)
    bce = @bce[p - 1]
    return unless bce?
    @_releaseBCEReceive(bce)
    bce.mia?.flushRecv()
    @dmaQueue = @dmaQueue.filter (r) -> r.bce != bce
    return

  # MSC short-format effective address: PC-relative with optional indexing.
  # "PC refers to the updated program counter value i.e., the address of
  # the next instruction" , and the short formats are one halfword, so the 
  # base is the address of the instruction plus one.
  # The displacement is two's complement, range -1024 to +1023 halfwords.
  mscEA: (disp, indexed) ->
    if disp & 0x400
      disp = disp | 0xfffff800
    pc = (@ls.PC().get32() + 1) & LS_WORD_MASK
    ea = (pc + disp) & 0x3ffff
    if indexed
      x = @ls.X().get32()
      ea = (ea + x) & 0x3ffff
    ea

  # BCE short-format effective address: "PC + DISP", or with M=1
  # "PC + DISP + 2 x BCENO", where "PC is the updated Bus Control Element
  # Program Counter, i.e. the address of the next sequential instruction"
  # (IOP POO, #SSC/#SST).  Displacement is two's complement, -1024 to 
  # +1023 halfwords.
  bceEA: (disp, m) ->
    disp = disp | 0xfffff800 if disp & 0x400
    ea = ((@ls.PC().get32() + 1) + disp) & LS_WORD_MASK
    ea = (ea + 2 * @curPE) & LS_WORD_MASK if m
    ea

  # MSC long-format effective address: absolute 18-bit with optional indexing
  mscLongEA: (addr, indexed) ->
    ea = addr & 0x3ffff
    if indexed
      x = @ls.X().get32()
      ea = (ea + x) & 0x3ffff
    ea

  # A processor's operand accesses to CPU main storage.  Each is a DMA
  # transfer and so passes the address and data through the R4/R5/R6
  # generator that C140 poisons; a caught error kills the access.
  g_EAF: (addr) ->
    return 0 if @checkDMAParity()
    return @cpu.mainStorage.get32(addr)

  g_EAH: (addr) ->
    return 0 if @checkDMAParity()
    return @cpu.mainStorage.get16(addr)

  s_EAF: (addr, value) ->
    return false if @checkDMAParity()
    return false if not @writeMain16(addr, (value >>> 16) & 0xffff)
    @writeMain16(addr + 1, value & 0xffff)

  s_EAH: (addr, value) ->
    return false if @checkDMAParity()
    @writeMain16(addr, value)

  # The IOP's registers
  #
  globalRegs: () ->
    [
      { name: 'STAT1',   value: @regProgExcept.get32() >>> 0, note: 'GO/NO-GO, 1 = GO' }
      { name: 'STAT4',   value: @regBusyWait.get32() >>> 0,   note: 'BUSY/WAIT, 1 = busy' }
      { name: 'STAT5',   value: @regProcEnable.get32() >>> 0, note: 'halt/enable, 1 = enabled' }
      { name: 'INDIC',   value: @regIndicator.get32() >>> 0,  note: 'BCE indicator bits' }
      { name: 'XMITENA', value: @regXmitEna.get32() >>> 0,    note: 'MIA transmitter enables' }
      { name: 'RECVENA', value: @regRecvEna.get32() >>> 0,    note: 'MIA receiver enables' }
      { name: 'RMSTAT',  value: @rmStatus(),                  note: 'RM status as READ RM STATUS returns it' }
      { name: 'RMLTCH',  value: @regRMStatus.get32() >>> 0,   note: 'the latch word behind it (termination control, voter test)' }
      { name: 'INTREGA', value: @intReg(0), note: 'Group 1 - External 0' }
      { name: 'INTREGB', value: @intReg(1), note: 'Group 2 - External 1' }
      { name: 'INTREGC', value: @intReg(2), note: 'Group 3 - External 2' }
      { name: 'INTREGD', value: @intReg(3), note: 'Group 4 - External 3' }
      { name: 'INTREGE', value: @intReg(4), note: 'Group 5 - External 4' }
      { name: 'DISCOUT', value: @regDiscreteOut.get32() >>> 0, note: 'discrete outputs' }
      { name: 'DISCINA', value: @regDiscreteInA.get32() >>> 0, note: 'discrete inputs 1-32' }
      { name: 'DISCINB', value: @regDiscreteInB.get32() >>> 0,
        note: "discrete inputs 33-40, GPC #{@readGpcId()}" }
      { name: 'CCDATA',  value: @regCCData.get32() >>> 0,      note: 'data word of the last PCI/PCO' }
      { name: 'WDOG',    value: @wdCount & WD_COUNT_MASK
        note: "GO/NO-GO timer count - #{if @wdTimeout then 'TIMED OUT' else if @wdRunning then 'running' else 'stopped'}" }
      { name: 'FAILDSC', value: @msc.regFailDisc.get32() >>> 0, note: 'MSC fail discrete' }
      { name: 'INTPROG', value: @msc.regIntProg.get32() >>> 0,  note: 'MSC programmed interrupts' }
    ]

  # Processor state
  #
  # One snapshot per processor for a display (the GUI's IOP pane): its
  # status bits, the local store registers that belong to its kind, and
  # the bus traffic its MIA has seen.  The pane reads this rather than the
  # local store geometry, the way the interrupt pane reads intStatus().
  #
  # Register names follow IOPLocalStore's accessors: the MSC has PC, I
  # (the instruction it fetched), X, ACC, ECR and its status register; a
  # BCE has PC, I, D, ID, MTO, BASE, IUAR and its two status halfwords.
  PROC_REGS_MSC: [
    ['PC',  0, 2], ['IH',  1, 2], ['IL',  2, 2]
    ['X',   0, 3], ['AH',  1, 3], ['AL',  2, 3]
    ['ECR', 2, 6], ['MST', 2, 7]
  ]
  PROC_REGS_BCE: [
    ['PC',  0, 2], ['IH',  1, 2], ['IL',  2, 2]
    ['DH',  1, 0], ['DL',  2, 0], ['ID',  0, 3]
    ['MTO', 1, 3], ['BASE', 2, 3], ['IUAR', 2, 5]
    ['BSTH', 2, 6], ['BSTL', 2, 7]
  ]

  # Snapshot of processor p (0 = MSC, 1-24 = BCE n).
  procState: (p) ->
    page = @ls.storePage[p]
    return null unless page?
    isMSC = (p == PROC_MSC)
    regs = for [name, bank, word] in (if isMSC then @PROC_REGS_MSC else @PROC_REGS_BCE)
      { name: name, value: page.r(bank * 4 + word).get32() >>> 0 }
    pc = page.r(0 * 4 + 2).get32() & LS_WORD_MASK
    # Only the BCEs have a MIA, so the MSC's traffic fields stay empty.
    mia = @bce[p - 1]?.mia
    {
      num: p
      name: if isMSC then 'MSC' else "BCE #{p}"
      kind: if isMSC then 'MSC' else 'BCE'
      enabled: @procGet(@regProcEnable, p) == 1
      busy:    @procGet(@regBusyWait, p) == 1
      go:      @procGet(@regProgExcept, p) == 1
      indicator: @procGet(@regIndicator, p) == 1
      xmitEna: @procGet(@regXmitEna, p) == 1
      recvEna: @procGet(@regRecvEna, p) == 1
      current: @ls.curPage == p        # the page the IOP is slicing now
      pc: pc
      regs: regs
      tx: mia?.txLog ? []
      rx: mia?.rxLog ? []
      rxPending: mia?.recvQueue?.length ? 0
    }

  procStates: () -> (@procState(p) for p in [0..24])

  # Disassemble `count` instructions of a processor's program starting at
  # `addr` (defaulting to its PC).  
  # Returns rows of { addr, hw1, hw2, len, text }.
  procDisasm: (p, count = 4, addr = null) ->
    st = @procState(p)
    return [] unless st?
    decoder = if p == PROC_MSC then @msc.instr else @bce[p - 1]?.instr
    return [] unless decoder?.toStr?
    a = (addr ? st.pc) & LS_WORD_MASK
    rows = []
    for i in [0...count]
      hw1 = @cpu.mainStorage.get16(a, false)
      hw2 = @cpu.mainStorage.get16(a + 1, false)
      d = decoder.toStr(hw1, hw2)
      rows.push({ addr: a, hw1: hw1, hw2: hw2, len: d.len, text: d.text })
      a = (a + d.len) & LS_WORD_MASK
    return rows

  # Interrupt registers A-E are a RegisterFile, whose elements are reached
  # with r(i):
  intReg: (i) -> @regInterrupts.r(i).get32() >>> 0
  setIntReg: (i, v) -> @regInterrupts.r(i).set32(v >>> 0)

  # External 0 / interrupt register A
  #
  # Set one of the Group 1 bits and interrupt the CPU on External 0.  The
  # five conditions are grouped onto the one level, so this is a pulse to
  # the CPU's pending latch and not a level: the register is cleared by
  # the read in the handler, which can leave the CPU with an External 0
  # pending and the register already zero:
  signalGroup1: (bit) ->
    @setIntReg(0, (@intReg(0) | bit) >>> 0)
    @cpu.raiseInterrupt('ext0')
    return

  # The Group 1 sources currently set in register A, by name -- what the
  # handler would learn by reading it, for ground equipment that wants to
  # say which of the five an External 0 was without consuming the read.
  group1Sources: () ->
    v = @intReg(0)
    names = []
    names.push 'GO/NO-GO timer timeout' if v & INTA_GO_NOGO
    names.push 'IOP fail latch (RM voter)' if v & INTA_IOP_FAIL
    names.push 'C/M idle' if v & INTA_CM_IDLE
    names.push 'ROS parity error' if v & INTA_ROS_PAR
    names.push 'IOP fault' if v & INTA_IOP_FAULT
    return names

  # A master reset restores the defaults, but only for the bits nothing
  # outside has driven: see the note on DISCRETE_IN_A_DEFAULT.
  resetDiscreteInputs: () ->
    @regDiscreteInA.set32(
      @_discReset(DISC_REG_A, DISCRETE_IN_A_DEFAULT, @regDiscreteInA))
    @regDiscreteInB.set32(
      @_discReset(DISC_REG_B, @discreteInBDefault(), @regDiscreteInB))
    return

  # The B register's power-on value, with this computer's self-ID in it.
  discreteInBDefault: () ->
    (((DISCRETE_IN_B_DEFAULT & ~GPC_ID_MASK) |
      ((@gpcId & 0x7) << GPC_ID_SHIFT)) >>> 0)

  # The GPC ID as the register now reads it, which is what software sees.
  # The bits can be driven, so it can differ from the wired-in self-ID.
  readGpcId: () ->
    (@regDiscreteInB.get32() & GPC_ID_MASK) >>> GPC_ID_SHIFT

  _discReset: (reg, dflt, register) ->
    driven = @discDriven?[reg] ? 0
    (((dflt & ~driven) | (register.get32() & driven)) >>> 0)

  _setupDiscreteBus: () ->
    @discreteBus = new DiscreteBus @gpcId, (m) => @recvDiscrete(m)
    @gpcLinks = new GpcLinks @gpcId,
      ((bit, on_) => @setDiscreteInput(DISC_REG_A, bit, on_)),
      (=> if @cpu? then @cpu.timeNs / 1000 else null)
    return

  # One message off the discrete bus.  A set/reset of an input is applied,
  # and whoever sent it now owns those bits.  A request is answered.  The
  # outputs are this LRU's to drive and a value is this LRU's to send, so
  # neither is taken from anyone else.
  recvDiscrete: (m) ->
    return unless m?
    if m.op == DISC_REQUEST
      @reportDiscrete(m.reg)
      return
    return if m.op == DISC_VALUE or m.reg == DISC_REG_OUT
    register = if m.reg == DISC_REG_B then @regDiscreteInB else @regDiscreteInA
    before = register.get32() >>> 0
    register.set32(applyDiscrete(before, m))
    @discDriven[m.reg] = ((@discDriven[m.reg] ? 0) | m.mask) >>> 0
    @discreteInputsChanged(before) if m.reg == DISC_REG_A
    return

  # What register A drives inside this box.  The toggle and the button
  # are acted on where they change; the I/O TERMINATE lines are levels,
  # and inhibit their transmitters while they stand.
  discreteInputsChanged: (before) ->
    now = @regDiscreteInA.get32() >>> 0
    changed = ((before >>> 0) ^ now) >>> 0
    return unless changed
    if changed & (bitMask(IO_TERM_A) | bitMask(IO_TERM_B))
      @applyIOTerminate(now)
    if changed & bitMask(DISC_HALT)
      if now & bitMask(DISC_HALT) then @enterHalt() else @leaveHalt()
    # A press, not a level: the make is what counts, and only at HALT.
    if (changed & now & bitMask(DISC_IPL)) and (now & bitMask(DISC_HALT))
      @pressIPL()
    return

  # HALT (DI-0): "Receipt of this DI causes the IOP to configure all
  # processors to Halt thereby prohibiting IOP operation.  The CPU is
  # held in system reset by this discrete."
  enterHalt: () ->
    @regProcEnable.set32(0x00000000)
    @cpu?.resetHeld = true
    return

  # The toggle has left HALT.  A CPU released from system reset starts
  # from the system reset PSW at PSA 0x14, which is where an IPL leaves
  # the machine.  The processors stay halted until software enables them.
  leaveHalt: () ->
    return unless @cpu?.resetHeld
    @cpu.resetHeld = false
    @cpu.systemReset()
    return

  # Loss of power halts processors, disables MIAs, lowers outputs, and holds reset.
  setPowered: (on_) ->
    on_ = !!on_
    return if @powered == on_
    @powered = on_
    unless on_
      before = @regDiscreteOut.get32() >>> 0
      @regProcEnable.set32(0x00000000)
      @regXmitEna.set32(0x00000000)
      @regRecvEna.set32(0x00000000)
      @regDiscreteOut.set32(0x00000000)
      @publishDiscreteOut(before)
      @cpu?.resetHeld = true
      return
    if (@regDiscreteInA.get32() & bitMask(DISC_HALT)) != 0 then @enterHalt() else @leaveHalt()
    return

  # The IPL button, pressed at HALT.  The load is a run of bus
  # transactions that advances as the host event loop comes round, so the
  # front end performs it through this hook.
  pressIPL: () ->
    if @onIPL?
      @onIPL()
    else unless @iplUnwired
      @iplUnwired = true
      console.log "IOP: IPL requested at HALT with nothing wired to run it"
    return

  # The transmitters the I/O TERMINATE lines inhibit.  The inhibit is a
  # wire into the MIA: a master reset does not clear it, and it is gone
  # when the line drops.
  applyIOTerminate: (a) ->
    mask = 0
    mask = (mask | IO_TERM_MASK[IO_TERM_A]) >>> 0 if a & bitMask(IO_TERM_A)
    mask = (mask | IO_TERM_MASK[IO_TERM_B]) >>> 0 if a & bitMask(IO_TERM_B)
    @xmitInhibit = mask
    return

  # Drive a discrete output from inside the box, as the IPL microcode
  # does, and publish the change the way a PCO write is published.
  setDiscreteOut: (mask, on_) ->
    before = @regDiscreteOut.get32() >>> 0
    v = if on_ then (before | mask) else (before & ~mask)
    @regDiscreteOut.set32(v >>> 0)
    @publishDiscreteOut(before)
    return

  # A transmitter software has enabled and no I/O TERMINATE line is
  # inhibiting.  The enable register keeps what software wrote to it: the
  # inhibit is not in it, and READ MIA TRANSMITTER STATUS reports the
  # register.
  xmitEnabled: (p) ->
    return false unless @procGet(@regXmitEna, p)
    ((@xmitInhibit ? 0) & @procBit(p)) == 0

  # What this GPC holds for one register, for whoever asked.
  reportDiscrete: (reg) ->
    value = switch reg
      when DISC_REG_B   then @regDiscreteInB.get32()
      when DISC_REG_OUT then @regDiscreteOut.get32()
      else                   @regDiscreteInA.get32()
    @discreteBus?.report(reg, value >>> 0, @discreteStamp())
    return

  discreteStamp: () ->
    if @cpu? then (Math.floor(@cpu.timeNs / 1000) >>> 0) else null

  # Publish changed output bits with the CPU clock.
  publishDiscreteOut: (before) ->
    now = @regDiscreteOut.get32() >>> 0
    changed = ((before >>> 0) ^ now) >>> 0
    return unless changed
    on_ = (changed & now) >>> 0
    off_ = (changed & ~now) >>> 0
    stamp = @discreteStamp()
    @discreteBus?.publish(DISC_SET, DISC_REG_OUT, on_, stamp) if on_
    @discreteBus?.publish(DISC_RESET, DISC_REG_OUT, off_, stamp) if off_
    @wantIoTurn()
    return

  # Service transports, the barrier, and hot I/O turns from the instruction loop.
  tickLinks: () ->
    return unless @cpu?
    now = @cpu.timeNs
    if (now - @lastShmPollNs) >= SHM_POLL_NS or now < @lastShmPollNs
      @lastShmPollNs = now
      pollShmRings()
    @flushPendingTx(now) if @txPending.length
    @gpcLinks?.deliver(now / 1000)
    if @barrier? and ((now - @lastBarrierNs) >= BARRIER_NS or now < @lastBarrierNs)
      @lastBarrierNs = now
      @wantIoTurn() if @barrierStep(now)
    @wantIoTurn() if (now - @lastTurnNs) >= HOT_TURN_NS and @isHot()
    return

  joinBarrier: () ->
    b = @barrier ? new Barrier(@gpcId)
    @barrier = if b.join(@cpu?.timeNs ? 0) then b else null
    @barrierOffsetUs = @barrier?.offsetUs ? null
    @barrierHeld = false
    @barrier?

  leaveBarrier: () ->
    @barrier?.leave()
    @barrierHeld = false
    return

  barrierStep: (nowNs = @cpu?.timeNs ? 0) ->
    return false unless @barrier?
    @barrierHeld = @barrier.step(nowNs)
    pollShmRings() if @barrierHeld
    @barrierHeld

  barrierAllowanceNs: () ->
    return Infinity unless @barrier?
    @barrier.allowanceNs(@cpu?.timeNs ? 0)

  noteTxPending: (mia) ->
    @txPending.push(mia) unless mia in @txPending
    return

  flushPendingTx: (nowNs) ->
    keep = []
    for mia in @txPending
      continue unless mia.txPend.length
      if (nowNs - mia.txPendSimNs) >= TX_FLUSH_NS
        mia.flushTx()
      else
        keep.push(mia)
    @txPending = keep
    return

  isHot: () ->
    return false unless @cpu?
    code = (@regDiscreteOut.get32() & SYNC_OUT_MASK) >>> 0
    (code != SYNC_OUT_MASK and code != 0) or @isPolling() or @isHearing()

  # True while an enabled listening BCE runs a bus program.
  isHearing: () ->
    for bce in @bce
      p = bce.bceNum
      continue if @xmitEnabled(p)
      return true if @procGet(@regProcEnable, p) == 1 and @procGet(@regBusyWait, p) == 1
    false

  isPolling: () ->
    @cpu? and @diaBurst >= DIA_BURST and (@cpu.timeNs - @lastDiaReadNs) < HOT_TAIL_NS and
      (@cpu.timeNs - @pollStartNs) < HOT_POLL_MAX_NS

  isSearching: () ->
    @isPolling() and (@regDiscreteOut.get32() & SYNC_OUT_MASK) == 0

  noteDiaRead: () ->
    return unless @cpu?
    now = @cpu.timeNs
    if (now - @lastDiaReadNs) < DIA_BURST_NS
      @diaBurst += 1
    else
      @diaBurst = 1
      @pollStartNs = now
    @lastDiaReadNs = now
    return

  wantIoTurn: () ->
    @ioTurnWanted = true
    return

  ioTurnTaken: (nowNs) ->
    @ioTurnWanted = false
    @lastTurnNs = nowNs
    return

  # Drive one discrete input directly, as a device on the bus would.  For
  # tests and for ground equipment that is already inside this process.
  setDiscreteInput: (reg, bit, on_) ->
    @recvDiscrete({op: (if on_ then DISC_SET else DISC_RESET), reg: reg,
                   mask: bitMask(bit)})
    return

  setMassMemoryReady: (unit, ready) ->
    return unless MM_READY_BIT[unit]?
    @setDiscreteInput(DISC_REG_A, MM_READY_BIT[unit], ready)
    return

  # An MIA enable register as its READ PCI reports it: channel numbering,
  # one place left of the processor numbering it is stored in, with
  # nothing above channel 24.  See MIA_WRITE_MASK above.
  miaReadBack: (reg) -> ((reg.get32() << 1) & MIA_READ_MASK) >>> 0

  # Data flow parity
  #
  # Reset the four bad-parity generators.  "The Disable Flow Parity Check
  # PCO command disables the parity checkers.  It also resets any parity
  # generator which is forcing bad parity in response to one of the 'force
  # bad parity' PCOs."  Power on does the same.
  resetParityGenerators: () ->
    @forceHBusParity = false
    @forceQueueParity = false
    @forceDMAParity = false
    @forceMIAParity = false
    return

  # A checker caught bad parity: (POO Appendix I, DATA FLOW PARITY CHECK): 
  # "an external 1 interrupt is issued to the CPU and all BCE's and the 
  # MSC are halted, all transmitter and receiver enables are disabled and 
  # the discrete outputs are reset.  The cause of this interrupt can be 
  # determined by reading the IOP interrupt register B."
  #
  # The error leaves checking DISABLED and the generators reset, which is
  # why software that walks the four checkers re-issues ENABLE FLOW PARITY
  # CHECK before every one of them.  Nothing happens at all while checking
  # is disabled: "if parity is disabled no error indication is made".
  signalDataFlowParity: (code) ->
    return false unless @parityEnabled
    cur = (@intReg(1) & INTB_CODE_MASK) >>> INTB_CODE_SHIFT
    code = cur if cur > code
    @setIntReg(1, ((@intReg(1) & ~INTB_CODE_MASK) | (code << INTB_CODE_SHIFT)) >>> 0)

    discOutBefore = @regDiscreteOut.get32() >>> 0
    @regProcEnable.set32(0x00000000)     # MSC and every BCE halted
    @regXmitEna.set32(0x00000000)
    @regRecvEna.set32(0x00000000)
    @regDiscreteOut.set32(0x00000000)
    @publishDiscreteOut(discOutBefore)

    @parityEnabled = false
    @resetParityGenerators()

    # External 1 with interrupt code 0000 -- IOP data flow error
    @cpu.raiseInterrupt('ext1', {code: 0x0000})
    return true

  # Every IOP access to CPU main storage goes over the DMA path.
  # Returns true when the access was killed by a parity error.
  checkDMAParity: () ->
    return false unless @parityEnabled and @forceDMAParity
    return @signalDataFlowParity(INTB_DMA)

  # The local store address lines and the queue control bits.
  # Used by both the CPU's local store PCI/PCO and by a 
  # an instruction fetch by a processor (the queue is what an
  # instruction is fetched into).
  checkQueueParity: () ->
    return false unless @parityEnabled and @forceQueueParity
    return @signalDataFlowParity(INTB_QUEUE)

  # The bus out to the octal MIA pages:
  # "on the IB page parity is generated for all data and command words
  # being sent to the octal MIA.  Parity for this bus is then checked on
  # the MIA's, which sends an error message back to the IOP if any errors
  # are detected."  Called by anything that puts a word on that bus.
  checkMIAParity: () ->
    return false unless @parityEnabled and @forceMIAParity
    return @signalDataFlowParity(INTB_MIA)

  # The IB page's second look at H-Bus data: it "indirectly checks the
  # H-BUS parity when it checks parity for registers R1, R2, R3".  A
  # processor slice touches those registers, so a page holding a word that
  # arrived over a poisoned H-Bus reports here rather than at the
  # transfer.  The tags are consumed: the bad word has been seen.
  checkLocalStoreParity: (page) ->
    # With checking disabled the bad word is read anyway and nothing is
    # said -- "if parity is disabled no error indication is made" -- so the
    # tag has to SURVIVE those reads.  The bad parity is in the stored
    # word, not in the act of looking at it; only a rewrite clears it.
    return false unless @parityEnabled
    tags = @lsBadParity[page]
    return false unless tags? and Object.keys(tags).length > 0
    @lsBadParity[page] = {}
    return @signalDataFlowParity(INTB_R123)

  # C/M Master Reset (PCO 84400000).  Per the master reset table (POO
  # Appendix I): interrupt registers B-E are cleared; in register A the
  # ROS parity and IOP fault bits are reset while the fail and timeout
  # latches are left alone; the watchdog counter is zeroed and inhibited;
  # and C/M IDLE is SET -- the C/M announcing that it has finished and is
  # available for further operations. 
  masterResetCM: () ->
    @setIntReg(1, 0)
    @setIntReg(2, 0)
    @setIntReg(3, 0)
    @setIntReg(4, 0)
    kept = @intReg(0) & (INTA_GO_NOGO | INTA_IOP_FAIL)
    @setIntReg(0, kept >>> 0)
    @wdCount = 0
    @wdRunning = false
    @wdAccumNs = 0
    @signalGroup1(INTA_CM_IDLE)
    return

  # ICR channel reset (POO sect.10): "The channel reset operation issues a
  # reset to the IO.  The IO and CPU uses the signal to reset the IO/CPU
  # interface logic."  It also zeroes the interrupt registers, which is
  # why the programming note says it "must not be executed until IOP level
  # A interrupt register has been read" when an External 0 has occurred.
  channelReset: () ->
    @setIntReg(i, 0) for i in [0..4]
    return

  # Return the IOP to the state it powers up in: local store cleared, every
  # status and interrupt register zero, the watchdog stopped, and nothing
  # queued in the DMA path or the MIAs. 
  reset: () ->
    for page in @ls.storePage
      page.r(i).set32(0) for i in [0..16]
    @ls.slice = 0
    @ls.curBCE = 0
    @ls.curPage = 0
    @curPE = 0

    for reg in [@regXmitEna, @regRecvEna, @regProgExcept, @regBusyWait,
                @regProcEnable, @regIndicator, @regDiscreteOut,
                @regRMStatus, @regCCData]
      reg.set32(0)
    @resetDiscreteInputs()
    @setIntReg(i, 0) for i in [0..4]
    @intForceTest = false

    @msc.regFailDisc.set32(0)
    @msc.regIntProg.set32(0)

    @wdCount = 0
    @wdRunning = false
    @wdTimeout = false
    @wdAccumNs = 0
    @wdLastNs = 0

    @rmVoterInhibit = false
    @rmTestInputs = 0
    @rmVoterFail = false

    @dmaQueue = []
    @dmaBurst = true
    @dmaForceBadParity = false
    @dataForceBadParity = false
    @mscRepeatPC = null
    @mscRepeatLeft = 0

    # "Events that disable parity checking include Power On, System Reset"
    # -- and a reset also resets the four bad-parity generators.
    @parityEnabled = false
    @resetParityGenerators()
    @lsBadParity = ({} for x in [0..PROC_SELFTEST])

    # The MIAs keep their bus connections -- tearing those down and
    # rebuilding them would leave the old listeners attached -- but
    # everything in flight goes, including any half-finished receive.
    for b in @bce
      b.mia.clearState()
      @_releaseBCEReceive(b)
    return

  # LOAD GO/NO-GO TIMER (PCO 88040000) and its test form.  The data word's
  # low 12 bits are the count; the PCO starts the counter and resets the
  # timeout latch.
  loadWatchdog: (value) ->
    @wdCount = value & WD_COUNT_MASK
    @wdRunning = true
    @wdTimeout = false
    @wdAccumNs = 0
    @wdLastNs = @cpu.timeNs
    return

  # The test form of the load: the same load, plus the single increment
  # the hardware injects.  A wrap past a full count latches the timeout
  # the way any other full count does -- which is why STM1 resets the
  # latch with another load once it has read the count back.
  loadWatchdogTest: (value) ->
    @loadWatchdog(value)
    @wdRunning = false
    @wdCount = (@wdCount + 1) & WD_COUNT_MASK
    if @wdCount == 0
      @wdTimeout = true
      @signalGroup1(INTA_GO_NOGO)
    return

  # LOAD TEST REGISTER (PCO 88100000): redundancy management's voter, in
  # the only mode a single simulated GPC can exercise -- self test.
  #
  # Bit 27 is VOTER TEST CONTROL, which "inhibits the normal voter inputs
  # (when set) from the other IOP's and inhibits driving of the Computer
  # Fail latch and IOP Transmissions Termination logic", so a test cannot
  # be mistaken for a real failure.  Bits 28-31 are the four test inputs,
  # which the hardware ORs with the operational ones.
  #
  loadVoterTest: (data) ->
    @rmVoterInhibit = (data & 0x10) != 0
    @rmTestInputs = data & 0xf
    votes = 0
    votes += 1 for b in [0x8, 0x4, 0x2, 0x1] when (@rmTestInputs & b) != 0
    @rmVoterFail = votes >= 2
    return

  # Carry the watchdog forward to the CPU's clock.  A full count (the
  # counter wrapping back to zero) is the timeout: it sets the timeout
  # latch, which on a real vehicle drives the Computer Fail output, and
  # raises External 0 through Group 1 bit 0. 
  tickWatchdog: () ->
    return unless @wdRunning
    now = @cpu.timeNs
    @wdAccumNs += now - @wdLastNs
    @wdLastNs = now
    while @wdAccumNs >= WD_TICK_NS
      @wdAccumNs -= WD_TICK_NS
      @wdCount = (@wdCount + 1) & WD_COUNT_MASK
      if @wdCount == 0
        @wdTimeout = true
        @wdRunning = false
        @wdAccumNs = 0
        @signalGroup1(INTA_GO_NOGO)
        return
    return

  # The RM status register as the CPU reads it (POO Appendix I, READ RM
  # STATUS REGISTER), IBM bit numbering:
  #   0     fail or timeout latch (the voter's failure, or a timeout)
  #   1     PCO inhibiting the fail vote inputs for test
  #   3-6   failure votes in from the other IOPs
  #   7-10  failure votes out to them (set by the MSC; not modeled)
  #   11-14 the voter's four test inputs
  #   15    voter fail latch
  #   16    timeout latch
  #   17    voter termination control latch
  #   18    timer termination control latch
  #   20-31 GO/NO-GO timer count, bit 31 = 0.768 ms
  rmStatus: () ->
    v = @regRMStatus.get32() & 0x00006000        # bits 17-18
    v |= 0x40000000 if @rmVoterInhibit           # bit 1
    v |= (@rmTestInputs & 0xf) << 17             # bits 11-14, test inputs
    v |= 0x00010000 if @rmVoterFail              # bit 15, voter fail latch
    v |= 0x00008000 if @wdTimeout                # bit 16, timeout latch
    # Bit 0 is the two of them together: "RM has detected a failure and
    # set the failure latch or ... the watchdog timer has timed out
    # forcing the fail latch."
    v |= 0x80000000 if @rmVoterFail or @wdTimeout
    v |= @wdCount & WD_COUNT_MASK                # bits 20-31
    return v >>> 0

  writeMain16: (addr, value) ->
    return true if @cpu.mainStorage.set16(addr, value)
    @cpu.signalDMAProtectViolation()
    return false

  # One step of an MSC Repeat instruction (@RAI/@RAW/@RNI/@RNW).  `met` is
  # the condition this repeat waits for, already evaluated against the
  # accumulator's BCE mask; `v` carries the count field and the I bit.
  #
  #   condition met      -> skip the next halfword (PC + 2)
  #   count exhausted    -> fall through to it (PC + 1)
  #   otherwise          -> leave the PC where it is and go round again
  #
  # Leaving the PC alone is the wait: the MSC re-fetches this instruction
  # on its next slice, and the BCEs it is waiting for get their slices in
  # between.  "A time out value of zero will cause the Repeat instruction
  # to test once, and only once."
  # A repeat instruction's count is a count of time, not of re-fetches.
  # The waits software loads pin the rate down: a table of counts for a
  # bus control element to finish holds 0x350 where its comment says 31 ms
  # and 157 where it says 5.2 ms, which is 36.6 and 33.1 us a count, or two
  # of the 16.5 us resolution the IOP's delays and time outs are quoted in.
  # Counted against the clock, an 0x350 wait is 28 ms and a BCE's 10.7 ms
  # #DLYI fits inside it.
  mscRepeat: (v, met) ->
    pc = @ls.PC().get32() & LS_WORD_MASK
    now = @cpu?.timeNs ? 0
    if @mscRepeatPC != pc
      @mscRepeatPC = pc
      # "The lower 8-bits, bits 8 through 15, and the I-bit are used to
      # compute a count": the I bit adds the index register's count above
      # the eight in the instruction, the way it extends a displacement.
      count = v.d
      count += (@ls.X().get32() & LS_WORD_MASK) if v.i
      @mscRepeatLeft = count
      @mscRepeatUntilNs = now + count * MSC_REPEAT_TICK_NS
    if met
      @mscRepeatPC = null
      @incrNIA(2)
    else if now >= @mscRepeatUntilNs
      @mscRepeatPC = null
      @incrNIA(1)
    return

  setNIA: (x) -> @ls.PC().set32(x & LS_WORD_MASK)

  incrNIA: (incr=1) -> @setNIA(@ls.PC().get32()+incr)

  recvFromCPU: (cmd,data) ->
    # Command word (POO Appendix I, PCI/PCO COMMAND WORD FORMAT):
    #   bit 0      1 = PCO (CPU output), 0 = PCI (CPU input)
    #   bits 1-5   subsystem select: 00001 C/M, 00010 RM, 00100 DF,
    #              01000 LS (local store), 10000 CC (channel control)
    #   bit 6      handshake control
    #   bits 7-16  data select
    #   bits 17-31 ignored
    # Those are IBM bit numbers, so the subsystem select is bits 26-30 of
    # the word here and the data select bits 15-24. 
    isOutput = cmd >>> 31
    devSelect = (cmd >>> 26) & 0x1f
    handshake = (cmd >>> 25) & 0x1
    dataSelect = (cmd >>> 15) & 0x3ff

    @regCCData.set32(data)

    # The discrete outputs are published as they change; the tail of this
    # command sends whatever it moved.
    discOutBefore = @regDiscreteOut.get32() >>> 0

    # Was a bad-parity generator already armed when this transfer arrived?
    # Sampled BEFORE the command runs so that the "force bad parity" PCO
    # which arms a generator is not itself caught by it: the generator
    # poisons what comes after it, not the command word that set it.
    hbusPoisoned = @parityEnabled and @forceHBusParity
    queuePoisoned = @parityEnabled and @forceQueueParity

    switch cmd
      when 0xc0030000 # DMA BURST INHIBIT
        @dmaBurst = false
      when 0xc1040000 # DMA BURST ENABLE
        @dmaBurst = true
      when 0xc1100000 # BAD PARITY DMA ADDRESS ENABLE
        @dmaForceBadParity = true
      when 0xc0100000 # BAD PARITY DMA ADDRESS DISABLE
        @dmaForceBadParity = false
      when 0xc1200000 # BAD PARITY DATA INPUT ENABLE
        @dataForceBadParity = true
      when 0xc0200000 # BAD PARITY DATA INPUT DISABLE
        @dataForceBadParity = false
      when 0xc1010000 # ENABLE FLOW PARITY CHECK
        # "necessary to start the parity checking in the data flow
        # following any event that disables parity checking."
        @parityEnabled = true
      when 0xc0010000 # DISABLE FLOW PARITY CHECK
        @parityEnabled = false
        @resetParityGenerators()
      when 0xc1020000 # FORCE IOP H-BUS BAD PARITY
        # "forces bad parity on all data coming to the IOP via the H-Bus
        # (PCO's or DMA's)."
        @forceHBusParity = true
      when 0xc1080000 # FORCE QUEUE CONTROL BAD PARITY
        # "forces bad parity on the local store address and queue control
        # bits."
        @forceQueueParity = true
      when 0xc1400000 # FORCE DMA ADDRESS/DATA BAD PARITY
        # One generator covers both: which of the two checkers sees it
        # depends on the bit parity of the address against the data word.
        # Register B reports the pair under one code, so the distinction
        # is invisible to software and is not modelled.
        @forceDMAParity = true
      when 0xc1800000 # FORCE OCTAL MIA BAD PARITY
        # "forces bad parity on all data transmitted from the IOP to the
        # OCTAL MIA pages.  The MIA page checks parity on all incoming
        # command and data words."
        @forceMIAParity = true
      when 0x84040000 # MIA TRANSMITTER DISABLE
        @regXmitEna.set32((@regXmitEna.get32() & ~(data & MIA_WRITE_MASK)) >>> 0)
      when 0x85040000 # MIA TRANSMITTER ENABLE
        @regXmitEna.set32((@regXmitEna.get32() | (data & MIA_WRITE_MASK)) >>> 0)
      when 0x84080000 # MIA RECEIVER DISABLE
        @regRecvEna.set32((@regRecvEna.get32() & ~(data & MIA_WRITE_MASK)) >>> 0)
      when 0x85080000 # MIA RECEIVER ENABLE
        @regRecvEna.set32((@regRecvEna.get32() | (data & MIA_WRITE_MASK)) >>> 0)
      when 0x84100000 # DISCRETE OUTPUT RESET
        r1 = @regDiscreteOut.get32()
        r2 = r1 & data
        r1 = r1 ^ r2
        @regDiscreteOut.set32(r1)
      when 0x85100000 # DISCRETE OUTPUT SET
        r1 = @regDiscreteOut.get32()
        r1 = r1 | data
        @regDiscreteOut.set32(r1)
      when 0x86200000 # CONFIGURE PROCESSORS HALT
        # "The data word is used as a mask ... 0 = No change, 1 = HALT if
        # accompanied by the HALT command word."  STAT5 is an enable
        # register, so halting is clearing the named bits.
        @regProcEnable.set32((@regProcEnable.get32() & ~data) >>> 0)
        @bceHalt(p) for p in [1..24] when (data & @procBit(p)) != 0
        @bceMaskEvent(data, "CPU: CONFIGURE HALT   mask #{(data >>> 0).toString(16)}")
      when 0x87200000 # CONFIGURE PROCESSORS ENABLE
        # And "1 = ENABLE if accompanied by the ENABLE command word".
        @regProcEnable.set32((@regProcEnable.get32() | data) >>> 0)
        @bceMaskEvent(data, "CPU: CONFIGURE ENABLE mask #{(data >>> 0).toString(16)}")
      when 0x84400000 # MASTER RESET
        # The master reset table (POO Appendix I): STAT1 = GO, STAT4 =
        # WAIT, STAT5 = HALT for the MSC and every BCE, transmitters and
        # receivers disabled, discrete outputs inactive.  GO is 1 and
        # enabled is 1, so "all GO" is every processor bit set and "all
        # halted" is none of them: 0xffffff80 and 0.
        @regProgExcept.set32(PROC_ALL)
        @regBusyWait.set32(0x00000000)
        @regProcEnable.set32(0x00000000)
        @regXmitEna.set32(0x00000000)
        @regRecvEna.set32(0x00000000)

        @regDiscreteOut.set32(0x00000000)
        # And the interrupt side of the reset, which ends with the C/M
        # announcing itself idle on External 0.
        @masterResetCM()
      when 0x88040000 # LOAD GO/NO-GO TIMER
          # The count is the data word's low 12 bits (IBM bits 20-31), and
          # the load is what starts the counter.
          @loadWatchdog(data)
      when 0x88048000 # LOAD GO/NO-GO TIMER TEST
          # "This PCO is used to load the Go/No-Go Timer with any chosen
          # value which is incremented by one low order bit and read with
          # a PCI (READ STATUS REGISTER) to determine the operating status
          # of the timer." 
          @loadWatchdogTest(data)
      when 0x88080000 # CONFIGURE TERMINATION CONTROL LATCHES
          # Data word bit 30 = timeout termination latch, bit 31 = voter
          # termination control latch.  They land in RM status IBM bits 18
          # and 17 
          timerLatch = (data >>> 1) & 0x1
          voterLatch = (data      ) & 0x1
          r1 = @regRMStatus.get32()
          r1 = (r1 & ~0x6000) | (timerLatch << 13) | (voterLatch << 14)
          @regRMStatus.set32(r1)
      when 0x88100000 # LOAD TEST REGISTER
          @loadVoterTest(data)
      when 0x88180000 # TEST INTERRUPTS
          # "The TEST command word forces interrupt Registers A, B, D and E
          # to set all interrupts as follows: REG A bits 0-5 (FC000000),
          # REG B bits 4&5 (0C000000), REG D bit 0, REG E bit 0.  The
          # interrupts will stay set until [ENABLE is issued].  This
          # permits self-testing of the interrupt detection circuitry.  The
          # interrupt registers will not be reset by reading of the
          # registers as in normal operation."
          @intForceTest = true
          @setIntReg(0, 0xfc000000)
          @setIntReg(1, 0x0c000000)
          @setIntReg(3, 0x80000000)
          @setIntReg(4, 0x80000000)
          @cpu.raiseInterrupt(key) for key in ['ext0', 'ext1', 'ext3', 'ext4']
      when 0x88140000 # ENABLE INTERRUPTS
          # "The ENABLE command must be issued after the TEST command word
          # to remove the test interrupt.  After issuing this PCO, each of
          # the four registers must be read to reset them and to permit
          # normal operation."
          @intForceTest = false
      when 0x92000000 # RESET STATUS1(GO/NO-GO)
        # "These PCO's provide the capability (data word is used as mask)
        # to reset Status Register 1 to the normal or GO indicator": 1 in
        # the mask puts that processor back to GO, 0 leaves it alone.
        @regProgExcept.set32((@regProgExcept.get32() | data) >>> 0)
      when 0x92040000 # LOAD MSC BUSY
        # The MSC bit in STAT4, which is the top bit of the word
        @procSet(@regBusyWait, PROC_MSC, 1)
        # And the copy of it the MSC reads back with @LMS: bit 17 of
        # the 18-bit MSC status register, "the Busy/Wait bit for the MSC".
        # Software checks the copy against X'00000001' exactly, so nothing
        # else in the register may be disturbed here.  Reached by region,
        # not through @ls.MST(): that accessor reads whichever page the IOP
        # happens to be slicing, which for a CPU-side PCO is any of the 25.
        mst = @ls.at(PROC_MSC, 2, 7)
        mst.set32((mst.get32() | 1) >>> 0)
      when 0xc1008000 # INHIBIT COMPLETION OF A DMA CYCLE
        return # no-op
      when 0x04000000 # READ MIA TRANSMITTER STATUS
        @regCCData.set32(@miaReadBack(@regXmitEna))
      when 0x04040000 # READ MIA RECEIVER STATUS
        @regCCData.set32(@miaReadBack(@regRecvEna))
      when 0x04080000 # READ DISCRETE OUTPUT STATUS
        r1 = @regDiscreteOut.get32()
        @regCCData.set32(r1)
      when 0x040c0000 # READ PROCESSOR HALT STATUS
        # "The PCI provides access to Status Register 5 (The Halt
        # Register)": 0 = disabled, 1 = enabled, one bit per processor.
        @regCCData.set32(@regProcEnable.get32())
      when 0x08000000 # READ INTERRUPT REGISTER A
        r1 = @intReg(0)
        @regCCData.set32(r1)
        @setIntReg(0, 0x0) unless @intForceTest
      when 0x08040000 # READ INTERRUPT REGISTER B
        r1 = @intReg(1)
        @regCCData.set32(r1)
        @setIntReg(1, 0x0) unless @intForceTest
      when 0x08080000 # READ INTERRUPT REGISTER C
        r1 = @intReg(2)
        @regCCData.set32(r1)
        @setIntReg(2, 0x0) unless @intForceTest
      when 0x080c0000 # READ INTERRUPT REGISTER D
        r1 = @intReg(3)
        @regCCData.set32(r1)
        @setIntReg(3, 0x0) unless @intForceTest
      when 0x08100000 # READ INTERRUPT REGISTER E
        r1 = @intReg(4)
        @regCCData.set32(r1)
        @setIntReg(4, 0x0) unless @intForceTest
      when 0x08140000 # READ RM STATUS REGISTERS
        @regCCData.set32(@rmStatus())
      when 0x08180000 # READ DISCRETE INPUT A (1-32)
        @noteDiaRead()
        @tickLinks()
        r1 = @regDiscreteInA.get32()
        @regCCData.set32(r1)
      when 0x081c0000 # READ DISCRETE INPUTS B (33-40)
        @regCCData.set32(@regDiscreteInB.get32())
      when 0x10000000 # READ STATUS1(GO/NO-GO)
        r1 = @regProgExcept.get32()
        @regCCData.set32(r1)
      when 0x10040000 # READ STATUS4(BUSY/WAIT)
        r1 = @regBusyWait.get32()
        @regCCData.set32(r1)


    @publishDiscreteOut(discOutBefore)

    if devSelect == 0x8 # Local Store
        # Data select: bits 7-11 the region (MSC, BCE 1-24, self test),
        # bits 12-13 the bank, bits 14-16 the word.
        region = dataSelect >>> 5
        bank = (dataSelect >>> 3) & 0x3
        word = (dataSelect) & 0x7
        reg = @ls.at(region, bank, word)
        if isOutput and @bceTraced(region)
          @bceEvent(region, "CPU: LOAD LOCAL STORE bank #{bank} word #{word} " +
                            "= #{(data & 0x3ffff).toString(16)}")
        if reg?
          # A local store word is 18 bits, "scaled to the LSB portion of the
          # 32-bit data word". 
          if isOutput
            reg.set32(data & 0x3ffff)
            # The word is in local store now, but with the parity the
            # poisoned H-Bus generated for it.  Tag it so the IB page can
            # catch it when the owning processor next uses the register --
            # a clean write to the same register clears the tag, because
            # the good parity overwrites the bad.
            if hbusPoisoned
              @lsBadParity[region][bank * 4 + word] = true
            else
              delete @lsBadParity[region][bank * 4 + word]
          else
            @regCCData.set32(((0xfffc0000 | (reg.get32() & 0x3ffff)) >>> 0))
        # The local store address lines and queue control bits carried this
        # transfer, so the C108 generator poisons it.
        return if queuePoisoned and @checkQueueParity()

    # The device-out data bus checker sees every H-Bus transfer as it
    # arrives -- "the SI page checks the data for correct parity directly
    # off the 'DEV OUT DATA BUS'" -- so a poisoned PCI or PCO reports here
    # and now, whatever it was addressed to.
    @signalDataFlowParity(INTB_DEV_OUT) if hbusPoisoned
    return
