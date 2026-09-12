import {now as simNow} from '../com/simRuntime.coffee'
import {call, setImmediate} from '../com/simRuntime.coffee'
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

import {Bus, BusMsg, SEV_VALID, busConfig, bceNumToBusConfig, wallNowUs} from 'com/bus'
import {BCEInstruction} from 'gpc/iop_bce_instr'


MIA_LOG_MAX = 64

# One word on a serial bus, in nanoseconds, from the programming note to
# the BCE's delay instruction: "Each count of 1 represents a delay of 16.5
# microseconds, the execution time of a BCE micro instruction.  Each count
# of 2 represents a delay of 33 microseconds, the minimum time for a word
# transmission over a serial bus."  Bus programs are written to it: a skip
# past the rest of a mass memory block is a delay of two counts per
# halfword.
#
# Receivers present queued halfwords at this rate.
export BUS_WORD_NS = 33000
export TX_BATCH_MAX = 512

# Maximum age measured on the shared host clock.
AGE_MAX_US = 50000
export {SEV_VALID}

export class MIA
  constructor: (@bceNum, @iop) ->
    @txLog = []
    @rxLog = []
    @tap = null
    @dataOutBuf = 0
    @dataOutAvail = false
    @dataOutIsCmd = false
    @reset = false

    @dataInBuf = 0
    @dataInAvail = false
    @dataInIsCmd = false
    @miaBusy = false
    @miaNoGo = false
    @miaParity = false

    @recvQueue = []
    # SEV bits parallel recvQueue; 101 is valid.
    @recvSev = []
    @lastSev = SEV_VALID
    @deliverCount = 0
    # Reply holds apply after this bus has answered at least once.
    @everHeard = false
    @lastCmdWall = 0
    @lastCmdNs = 0
    # Queued-word counts by transmission, oldest first.
    @recvRuns = []
    # Elapsed words are dropped only after reception of a run begins.
    @runStarted = false
    # Simulated deadline for the next word.
    @rxNextNs = 0
    # A pending datagram carries the first word's clocks.
    @txPend = []
    @txPendWallUs = null
    @txPendSimNs = 0
    @txFlushArmed = false

    @_setupBus()

  # BCE 24 is the instrumentation bus, one per computer: GPC n drives IPn
  # (com/bus.civet), and a computer with no ID drives IP5.
  _setupBus: () ->
    config = bceNumToBusConfig[@bceNum]
    config = busConfig["IP#{@iop.gpcId}"] ? config if @bceNum == 24 and @iop?.gpcId
    return unless config
    @busName = config.name
    @busNom = config.nom
    @bus = new Bus(config.name, config)
    @bus.onReceive @_onRecv, this

  _onRecv: (self, busID, msg, remote) ->
    return unless msg.data16?
    if msg.cmd
      self.hearCommand(msg.data16[0])
      return
    # Barrier peers already share simulated time, so wall age is ignored.
    ageUs = 0
    if msg.wallUs? and not self.iop?.barrier?
      ageUs = (wallNowUs() - msg.wallUs) | 0
      ageUs = 0 unless 0 <= ageUs <= AGE_MAX_US
    self.deliver(msg.data16, {delayUs: msg.delayUs, sev: msg.sev, ageUs: ageUs})
    return

  # A heard command dates response delay and starts a new transaction.
  hearCommand: (hw) ->
    @_log(@rxLog, hw, true)
    @lastCmdNs = @_nowNs()
    @everHeard = true
    stale = @recvQueue.length and not @_receiveUnderway()
    @iop?.bceEvent?(@bceNum, "command #{hw.toString(16)} heard" +
                             (if stale then ", #{@recvQueue.length} stale words flushed" else ''))
    @flushRecv() if stale
    return

  # One datagram is one transmission.  `delayUs` dates its first word from
  # the last command; `ageUs` backdates a listening transfer on the shared
  # host clock.  An active receive retains its word schedule.  `sev` has one
  # status byte per word and defaults to valid.
  deliver: (words, opts = {}) ->
    return unless words?.length
    listening = @_listening()
    unless @recvQueue.length or (listening and @_receiveUnderway())
      @rxNextNs = @_nowNs()
      @rxNextNs -= (opts.ageUs ? 0) * 1000 if listening
      if opts.delayUs > 0
        @rxNextNs = Math.max(@rxNextNs, @lastCmdNs + opts.delayUs * 1000)
    @deliverCount += 1
    @everHeard = true
    for i in [0...words.length]
      hw = words[i] & 0xffff
      @recvQueue.push(hw)
      @recvSev.push(if opts.sev? then ((opts.sev[i] ? SEV_VALID) & 7) else SEV_VALID)
      @_log(@rxLog, hw)
    @recvRuns.push(words.length)
    @iop?.bceEvent?(@bceNum, "#{words.length} words arrive #{opts.ageUs ? 0} us old" +
                             ", first due #{@dueInUs()} us from now" +
                             ", #{@recvQueue.length} queued")
    return

  dueInUs: () -> Math.round((@rxNextNs - @_nowNs()) / 1000)

  # `tap` sees entries before the diagnostic ring drops old ones.
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
    @recvSev = []
    @lastSev = SEV_VALID
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
    @clearLogs()
    return

  clearLogs: () ->
    @txLog = []
    @rxLog = []
    @_dropped = 0
    return

  flushRecv: () ->
    @recvQueue = []
    @recvSev = []
    @recvRuns = []
    @runStarted = false
    @rxNextNs = 0
    return

  _nowNs: () ->
    @iop?.cpu?.timeNs ? 0

  simStampUs: (ns = @_nowNs()) ->
    Math.floor(ns / 1000) % 4294967296

  _receiveUnderway: () ->
    st = @iop?.bce?[@bceNum - 1]?.recv
    st? and st.gotAny and st.left > 0

  _listening: () ->
    @iop? and not @iop.xmitEnabled(@bceNum)

  # Directly queued test data forms one open run.
  _runLeft: () ->
    if @recvRuns.length then @recvRuns[0] else @recvQueue.length

  _take: () ->
    hw = @recvQueue.shift() & 0xffff
    @lastSev = @recvSev.shift() ? SEV_VALID
    if @recvRuns.length
      @recvRuns[0] -= 1
      if @recvRuns[0] <= 0
        @recvRuns.shift()
        @runStarted = false        # the next run starts clean
    hw

  # Drop elapsed words from the active transmission, retaining the last
  # latched word.  A transmission not yet started remains queued.
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

  # Clamp an idle command-mode bus to the receive start.  A listening bus
  # keeps the arrival schedule of an unstarted queued transmission.  The
  # clamp occurs once per receive so 16.5 us BCE turns preserve the 33 us
  # word rate.
  rxBegin: (nowNs) ->
    return if @_listening() and @recvQueue.length > 0 and not @runStarted
    @rxNextNs = Math.max(@rxNextNs, nowNs)
    return

  getData: () ->
    return 0 unless @recvQueue.length > 0
    @rxNextNs += BUS_WORD_NS
    @runStarted = true
    @_take()

  xmitWord: (halfword) ->
    return unless @bus
    @_log(@txLog, halfword)
    # Stamp the first word's wire time before the batch is deferred.
    unless @txPendWallUs?
      @txPendWallUs = wallNowUs()
      @txPendSimNs = @_nowNs()
      @iop?.bceEvent?(@bceNum, 'transmission begins')
      # Shared-memory batches flush from the instruction loop.
      @iop?.noteTxPending?(this) if @bus?.ring?
    @txPend.push(halfword & 0xffff)
    if @txPend.length >= TX_BATCH_MAX
      @flushTx()
    else unless @txFlushArmed
      @txFlushArmed = true
      setImmediate call(@, 'flushTx')

  flushTx: () ->
    @txFlushArmed = false
    return unless @bus and @txPend.length
    msg = new BusMsg(@txPend.length)
    msg.data16[i] = w for w, i in @txPend
    msg.wallUs = @txPendWallUs
    msg.simUs = @simStampUs(@txPendSimNs)
    @txPend = []
    @txPendWallUs = null
    @bus.sendMsg(msg)

  xmitCmd: (cmd24) ->
    return unless @bus
    # A command starts a transaction after discarding unread prior data.
    @flushRecv() if @recvQueue.length
    @flushTx()
    msg = BusMsg.Command(cmd24)
    msg.simUs = @simStampUs(@_nowNs())
    @_log(@txLog, (cmd24 >>> 8) & 0xffff, true)
    @lastCmdWall = simNow()
    @lastCmdNs = @_nowNs()
    @bus.sendMsg(msg)


export class BCE
    constructor: (@bceNum, @iop) ->
        @mia = new MIA(@bceNum, @iop)
        @instr = new BCEInstruction()
        @recv = null

    exec: (iop, hw1, hw2) ->
        @instr.exec(iop, hw1, hw2)
