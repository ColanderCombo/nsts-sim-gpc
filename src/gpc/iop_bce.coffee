#
# IBM-6246556A/p.1
#
# 1.0   BUS CONTROL ELEMENT
#
#       The Bus Control Element (BCE) is a microprogrammed controller
# specifically tailored for management of I/O traffic on one of the
# Space Shuttle system busses. Within each IOP there is one BCE for
# each system bus, for a total of 24 BCE's. Each of these BCE's is
# capable of independent program execution, data buffering to and from
# memory, and communication with the MSC. Further, each BCE is
# connected to its own bus via its own Multiplexer Interface Adapter
# (MIA), which performs all parallel to serial and serial to parallel
# conversions. Table 1.1 summarizes the basic characteristics of a BCE.
#
#          The major purpose of a BCE is threefold.
#
#          (1)  Initiate transmission of commands to subsystems on the
#               bus.
#
#          (2)  Handle data coming back from a commanded subsystem.
#
#          (3)  Fetch data to be sent to a commanded subsystem.
#
#          To handle these tasks there are two classes of instructions
# (transmit and receive), and two special operating modes (Command, and
# Listen ) that are unique to the BCE.
#
#          The transmit instructions allow transmission of both commands
# and data to a subsystem. When transmitting data a BCE/MIA pair
# performs:
#
#          (1)  Update of main memory buffer addresses.
#
#          (2)  Conversion between 32 bit main memory data format and 25
#               + Sync bits bus data format.
#
#          (3)  Check on number of words to be transferred.
#
#          The receive commands allow a BCE to accept a stream of input
# data from a subsystem through its MIA. When receiving data a BCE
# performs:
#
#          (1)  Time outs on data arrival.
#
#          (2)  Error checks on incoming data.
#
#          (3)  Assembly into main memory 32 bit data format.
#
#          (4)  Maintenance of main memory buffer addresses.
#
#          (5)  Transferral of data to main memory
#
#          (6)  Check on number of words to be received.
#
#          The two operating modes that a BCE may be in influed the
# way the BCE uses its bus. In Command mode, a BCE is master of its
# bus, and is free to transmit both commands and data. This allows a
# BCE to command a subsystem, receive data from it, or transmit data to
# it. In Listen mode a BCE monitors its bus for directions on how to
# handle any data that might appear on the bus. In this mode a BCE may
# only receive data, and may not transmit either commands or data. This
# handles the common situation in the Space Shuttle where several IOP's
# and this several BCE's may be connected to one bus. In such a 
# situation only one BCE is allowed to issue subsystem commands, but all
# BCE's on that bus wish to receive copies of the resulting data. The
# listening mode allows the command BCE to tell the others what data to
# exepect, and when to expect it.
#
#
#       BCE CHARACTERISTICS
#
# Type -- Programmable I/O traffic controller
# Number -- One per bus, 24 BCE's per IOP
# Control Structure -- Microprogrammed
#
# Programmable Registers (per BCE)
#
#     18 Bit Base Register (BASE)
#     18 Bit Program Counter (PC)
#     18 Bit Maximum Time Out Register (MTO)
#      5 Bit Interface Unit Address Register (IUAR)
#      1 Bit BCE/MSC Indicator Bit
#
# Other BCE Registers (per BCE)
#
#     32 Bit Status Register
#      1 Bit Program Exception Register (part of STAT 1)
#      1 Bit Busy/Wait Bit (part of STAT 4)
#      1 Bit MIA Transmitter Enable
#      1 Bit MIA Receiver Enable
#      6 Bit Identify Register
#
# Instruction Formats:  16 Bit Short/32 Bit Long/ 64 Bit Extended
#
# Instruction Repertoire: 10 Short/5 Long/ 2 Extended
#
# Addressing Space:  131,072 32 Bit Fullwords/262,144 16 Bit Halfwords
#
# Addressing Modes:  Immediate, PC relative, Base relative, Absolute
#
# Special Operating Modes:     Command, Listen
#
# Bus Data Format:   25 + Sync Bit serial.
#
#

# ____ 0000 0000 0000 0000 0000 0000 0000
# ____ DDDa aaaa dddd dddd dddd dddd 101p
# ____ DDDa aaaa dddd dddd dddd dddd sevp
# ____ CCCa aaaa cccc cccc cccc cccc cccp
# ____ CCC0 1000 ____ __aa aaai iiii iiip
#
# CMDS
#
# ____ 00101 00000 0000 00000 11111   SSIP ICC
# ____ 00101 00000 0000 00011 11111   Data Init via ICC
# ____ 01011 00000 00000 00000 0000   DEU
# ____ 01011 00001 00000 0000 00000   DEU
# ____ 01011 00010 00000 0000 00000   DEU
# ____ 01011 00100 00000000000000   DEU
#
# ____ 01101 10000 000000001 01110 DDU ADI
# ____ 01101 10000 000010000 00110 DDU AMI
# ____ 01101 10000 000001000 00110 DDU AVI
# ____ 01101 10000 000000010 01010 DDU HSI
# ____ 011110000000000000000000
# ____ 01011 01010 000000000 00000 FF BITE Read
# ____ 01100 01010 000000000 00000 FA BITE Read
# ____ 01011 00010 0000 10000 10011 FCINPUT1 (FF/FA)
# ____ 01100 00010 0000 10000 01110  FCINPUI1 (FF/FA)
# ____ 01100 00010 0000 10000 00011  FCINPUI1 (FF/FA)
# ____ 00010 000010000 01110 01100  FCINPUT1 (FF/FA)
# ____ 01011 00010 0000 11011 00110  FCINPUT2
# ____ 01011 00010 0001 01010 00111  FCINPUT2
# ____ 01011 00010 0001 10010 00000  FCINPUT2
# ____ 01011 00010 0001 10100 00000  FCINPUT2
# ____ 01011 00010 0001 10011 00000  FCINPUT2
#
# ____ 01011 0 1000 0010 10000 0000
# ____ 01011 0 1000 0010 00000 0000
# ____ 01011 0 1000 1010 10000 0000
#

import {Bus, BusMsg, bceNumToBusConfig} from 'com/bus'
import {BCEInstruction} from 'gpc/iop_bce_instr'


# How many words of bus traffic each MIA keeps for the display:
MIA_LOG_MAX = 64

# One word on a serial bus, in nanoseconds, from the programming note to
# the BCE's delay instruction: "Each count of 1 represents a delay of 16.5
# microseconds, the execution time of a BCE micro instruction.  Each count
# of 2 represents a delay of 33 microseconds, the minimum time for a word
# transmission over a serial bus."  Bus programs are written to it: a skip
# past the rest of a mass memory block is a delay of two counts per
# halfword.
#
# A receiver presents halfwords to its BCE at that rate, however fast the
# host modelling the subsystem answered.  The queue behind the MIA is a
# socket buffer, so a whole transfer can land in it in one datagram, and
# software paces itself against the transfer -- a per-block handshake
# through a status location, say.  Metering here needs no time sync with
# the sending process.
export BUS_WORD_NS = 33000

export class MIA
  constructor: (@bceNum, @iop) ->
    @txLog = []
    @rxLog = []
    @tap = null
    @dataOutBuf = 0
    @dataOutAvail = false
    @dataOutIsCmd = false
    @reset = false
    @xmitEna = false
    @recvEna = false

    @dataInBuf = 0
    @dataInAvail = false
    @dataInIsCmd = false
    @miaBusy = false
    @miaNoGo = false
    @miaParity = false

    @recvQueue = []
    # Diagnostic only: how many transmissions this receiver has been handed.
    @deliverCount = 0
    # How many of the queued words belong to each transmission still
    # waiting, oldest first: a mass memory block, a display unit's poll
    # response.  A transmission is a run of words with dead bus either
    # side of it, and that boundary is where a receiver resynchronises.
    @recvRuns = []
    # Whether the run at the head has had a word taken from it.  Only a
    # run already being received loses the words that go by unheard.
    @runStarted = false
    # Simulated time at or after which the next received word may be
    # taken; see BUS_WORD_NS.
    @rxNextNs = 0

    @_setupBus()

  _setupBus: () ->
    config = bceNumToBusConfig[@bceNum]
    return unless config
    @busName = config.name
    @busNom = config.nom
    @bus = new Bus(config.name, config)
    @bus.onReceive @_onRecv, this

  _onRecv: (self, busID, msg, remote) ->
    return unless msg.data16?
    self.deliver(msg.data16)
    return

  # One transmission arrives: a run of words with dead bus either side.
  # The caller may be the bus or a test standing in for a subsystem.
  deliver: (words) ->
    return unless words?.length
    # Nothing was on the bus, so the first word of this transmission is
    # due now rather than at some deadline left over from the last one.
    @rxNextNs = @_nowNs() unless @recvQueue.length
    @deliverCount += 1
    for i in [0...words.length]
      hw = words[i] & 0xffff
      @recvQueue.push(hw)
      @_log(@rxLog, hw)
    @recvRuns.push(words.length)
    return

  # Push one word onto a traffic ring, stamped with the simulated time the
  # CPU had reached.  `tap`, when one is attached, sees every word as it is
  # logged, which is more than the ring holds.
  _log: (ring, value, isCmd = false) ->
    entry = {
      seq: ring.length + (@_dropped ? 0) + 1
      timeNs: @iop?.cpu?.timeNs ? 0
      value: value & 0xffff
      cmd: !!isCmd
    }
    ring.push(entry)
    @tap?(this, (if ring == @txLog then 'tx' else 'rx'), entry)
    while ring.length > MIA_LOG_MAX
      ring.shift()
      @_dropped = (@_dropped ? 0) + 1
    return

  clearState: () ->
    @recvQueue = []
    @recvRuns = []
    @runStarted = false
    @rxNextNs = 0
    @dataOutBuf = 0
    @dataOutAvail = false
    @dataOutIsCmd = false
    @dataInBuf = 0
    @dataInAvail = false
    @dataInIsCmd = false
    @miaBusy = false
    @miaNoGo = false
    @miaParity = false
    @xmitEna = false
    @recvEna = false
    @clearLogs()
    return

  clearLogs: () ->
    @txLog = []
    @rxLog = []
    @_dropped = 0
    return

  flushRecv: () ->
    @recvQueue = []
    @recvRuns = []
    @runStarted = false
    @rxNextNs = 0
    return

  _nowNs: () ->
    @iop?.cpu?.timeNs ? 0

  # How many words are left in the transmission at the head.  Words put
  # straight into the queue with no run behind them (a test, ground
  # equipment) count as one open run.
  _runLeft: () ->
    if @recvRuns.length then @recvRuns[0] else @recvQueue.length

  _take: () ->
    hw = @recvQueue.shift() & 0xffff
    if @recvRuns.length
      @recvRuns[0] -= 1
      if @recvRuns[0] <= 0
        @recvRuns.shift()
        @runStarted = false        # the next run starts clean
    hw

  # The words that went by while nobody was listening.
  #
  # A bus program skips the rest of a mass memory block by delaying: the
  # transport streams on and what the receiver does not capture is gone.
  # The queue here is a socket buffer, which would otherwise hold it all
  # for the next receive.
  #
  # Called where a receive begins.  A receiver is enabled for the length of
  # a commanded transfer and captures every word of it, so words are lost
  # only outside one.
  #
  # Dropping stops at the end of the transmission being received.  A block
  # has dead bus either side of it, which is what the delay is sized to
  # land in -- two counts per halfword left in the block plus half the
  # block gap, so the receiver comes back mid-gap.  A run nothing has been
  # taken from yet is untouched, which holds the resynchronisation exact
  # however the simulated clock and the sender's clock drift.
  #
  # One word survives: the MIA's receive buffer holds the last word it
  # latched, and a bus program that has read part of a block starts its
  # next sequence with a one-halfword receive that clears it.
  #
  # Returns how many words were lost.
  dropStale: () ->
    return 0 unless @runStarted and @recvQueue.length
    missed = Math.floor((@_nowNs() - @rxNextNs) / BUS_WORD_NS)
    return 0 unless missed > 0
    n = Math.min(missed, @_runLeft() - 1)
    return 0 unless n > 0
    @_take() for [1..n]
    @rxNextNs = @_nowNs()
    n

  dataAvailable: () ->
    return false unless @recvQueue.length > 0
    @_nowNs() >= @rxNextNs

  # A receive begins: an idle bus owes the receiver nothing, so the first
  # word of this transfer is due now rather than at a deadline left over
  # from the last one.
  #
  # The clamp is once per receive.  A BCE's turn comes round once in 33
  # slices, 16.5 us, and a word is due every 33, so clamping at every word
  # quantises the schedule to the turn -- a word falling due a little after
  # a turn waits for the one after that, and the average rate settles at 49
  # us a word.  Clamping once per receive lets the debt accrue inside the
  # transfer, so a turn that comes round late takes the two words it is
  # owed and the average holds at the bus rate.
  #
  # dropStale() measures the words that went by unheard as the distance
  # between this deadline and now, so without the clamp a receive is
  # charged for the whole of the sender's schedule.
  rxBegin: (nowNs) ->
    @rxNextNs = Math.max(@rxNextNs, nowNs)
    return

  getData: () ->
    return 0 unless @recvQueue.length > 0
    @rxNextNs += BUS_WORD_NS
    @runStarted = true
    @_take()

  xmitWord: (halfword) ->
    return unless @bus
    msg = new BusMsg(1)
    msg.data16[0] = halfword & 0xffff
    @_log(@txLog, halfword)
    @bus.sendMsg(msg)

  xmitCmd: (cmd24) ->
    return unless @bus
    # A command begins a new transaction, so anything still queued from the
    # last one is stale and must not lead this one.  A subsystem cannot
    # always know how many words the bus program will read: a display unit
    # answers a status request with its whole status block, and software
    # reads either one halfword of it or sixteen from the same command
    # word.  A leftover word is therefore normal, and the hardware, whose
    # receiver is inhibited outside a commanded transfer, never captures it.
    #
    # Flushed here rather than on receive completion, which would also
    # discard words that legitimately arrive later in a transfer and
    # measurably destabilises the mass memory load.  At command time
    # nothing a transaction needs has been sent yet.
    @flushRecv() if @recvQueue.length
    msg = new BusMsg(2)
    msg.data16[0] = (cmd24 >>> 8) & 0xffff
    msg.data16[1] = (cmd24 & 0xff) << 8
    @_log(@txLog, (cmd24 >>> 8) & 0xffff, true)
    @bus.sendMsg(msg)


export class BCE
    constructor: (@bceNum, @iop) ->
        @mia = new MIA(@bceNum, @iop)
        @instr = new BCEInstruction()
        @recv = null

    exec: (iop, hw1, hw2) ->
        @instr.exec(iop, hw1, hw2)


