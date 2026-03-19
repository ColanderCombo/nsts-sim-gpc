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


export class MIA
  constructor: (@bceNum) ->
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

    @_setupBus()

  _setupBus: () ->
    config = bceNumToBusConfig[@bceNum]
    return unless config
    @bus = new Bus(config.name, config)
    @bus.onReceive @_onRecv, this

  _onRecv: (self, busID, msg, remote) ->
    self.recvQueue.push(msg)

  dataAvailable: () ->
    @recvQueue.length > 0

  getData: () ->
    if @recvQueue.length > 0
      msg = @recvQueue.shift()
      return msg.data16[0] if msg.data16?
      return 0
    return 0

  xmitWord: (halfword) ->
    return unless @bus
    msg = new BusMsg(1)
    msg.data16[0] = halfword & 0xffff
    @bus.sendMsg(msg)

  xmitCmd: (cmd24) ->
    return unless @bus
    msg = new BusMsg(2)
    msg.data16[0] = (cmd24 >>> 8) & 0xffff
    msg.data16[1] = (cmd24 & 0xff) << 8
    @bus.sendMsg(msg)


export class BCE
    constructor: (@bceNum) ->
        @mia = new MIA(@bceNum)
        @instr = new BCEInstruction()

    exec: (iop, hw1, hw2) ->
        @instr.exec(iop, hw1, hw2)


