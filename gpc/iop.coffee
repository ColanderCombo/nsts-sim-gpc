import {RAM,Register,RegisterFile,ProgramStatusWord} from 'gpc/regmem'
import {PackedBits} from 'gpc/util'

import {MSC} from 'gpc/iop_msc'
import {BCE} from 'gpc/iop_bce'
import {MCM} from 'gpc/mcm'

class IOPLocalStore
  constructor: () ->
    @storePage = (new RegisterFile(x,16,18) for x in [0..24])

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

  ls: (bank,word) -> @cp.r(bank*4+word)

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
  constructor: (@cpu) ->
    @mainStorage = new MCM(24*1024)

    @msc = new MSC()
    @bce = (new BCE(x) for x in [1..24])

    @curPE = 0  # MSC = 0, BCE = 1-24

    @dmaBurst = true
    @dmaForceBadParity = false
    @dataForceBadParity = false


    @regXmitEna = new Register("xmitEnable", 24)
    @regRecvEna = new Register("resvEnable", 24)

    @regProgExcept = new Register("GO_NOGO", 25) # STAT1 (GO/NOGO)
    @regBusyWait = new Register("BUSY_WAIT", 25) # STAT4 (BUSY/WAIT)
    @regHalt = new Register("HALT", 25) # STAT5 (HALT/NO HALT)
    @regIndicator = new Register("Indicator", 25)

    @regDiscreteOut = new Register("discreteOut", 32)
    @regDiscreteInA = new Register("discreteInA", 32)
    @regDiscreteInB = new Register("discreteInB", 32)
    @regRMStatus = new Register("RMStatus", 32)

    @regInterrupts = new RegisterFile("int",5,32) # Interrupt Regs A-E
    @intForceTest = false

    @regCCData = new Register("CCData",32)

    @ls = new IOPLocalStore()

    @dmaQueue = []
    @clockCycleCount = 0

  _bitPE: (w) -> (w >>> @curPE) & 1 # return value of bit in word for curPE

  _setBitPE: (w,v) -> 
    shifted = (v << @curPE)
    mask = 0xffffffff - shifted
    w = (w & mask) | shifted
    return w

  exec: () ->
    @execChannelControl()
    @execDMAQueue()
    @execProcessors()
    @execRM()

  execChannelControl: () ->


  execDMAQueue: () ->
    # Process one DMA request per cycle
    if @dmaQueue? and @dmaQueue.length > 0
      req = @dmaQueue.shift()
      if req.direction == 'read'  # IOP reading from main memory (transmit to bus)
        data = @cpu.mainStorage.get16(req.addr)
        @ls.setD(data)
        if req.bce?
          req.bce.mia.xmitWord(data)
      else  # IOP writing to main memory (receive from bus)
        if req.bce? and req.bce.mia.dataAvailable()
          data = req.bce.mia.getData()
          @ls.setD(data)
        else
          data = @ls.getD()
        @cpu.mainStorage.set16(req.addr, data, false)  # bypass protection

      if @dmaBurst and @dmaQueue.length > 0
        @execDMAQueue()  # Burst mode: continue processing

  execProcessors: () ->
    @ls.nextSlice()
    page = @ls.curPage

    # Check halt state for current processor
    if page == 0  # MSC
      if @regHalt.getbit32(0)
        return
      if not (@regBusyWait.getbit32(0))  # Not busy = waiting
        return
    else  # BCE
      bceIdx = page
      if @regHalt.getbit32(bceIdx)
        return
      if not (@regBusyWait.getbit32(bceIdx))
        return

    # Fetch instruction
    pc = @ls.PC().get16()
    hw1 = @cpu.mainStorage.get16(pc)
    hw2 = @cpu.mainStorage.get16(pc + 1)
    @ls.IH().set16(hw1)
    @ls.IL().set16(hw2)

    # Decode and execute
    if page == 0  # MSC
      @msc.exec(@, hw1, hw2)
      # MSC instructions manage their own NIA via incrNIA/setNIA
    else  # BCE
      bce = @bce[page - 1]
      bce.exec(@, hw1, hw2)
      @ls.PC().set16(pc + 1)  # Default NIA increment for BCE

  execRM: () ->


  curBCE: () ->
    if @ls.curPage > 0
      return @bce[@ls.curPage - 1]
    return null

  queueDMA: (addr, direction, bce=null) ->
    @dmaQueue.push({addr: addr, direction: direction, bce: bce})

  # MSC short-format effective address: PC-relative with optional indexing
  # disp = 11-bit displacement (needs sign extension), indexed = index flag
  mscEA: (disp, indexed) ->
    # Sign-extend 11-bit displacement
    if disp & 0x400
      disp = disp | 0xfffff800
    pc = @ls.PC().get32()
    ea = (pc + disp) & 0x3ffff
    if indexed
      x = @ls.X().get32()
      ea = (ea + x) & 0x3ffff
    ea

  # MSC long-format effective address: absolute 18-bit with optional indexing
  mscLongEA: (addr, indexed) ->
    ea = addr & 0x3ffff
    if indexed
      x = @ls.X().get32()
      ea = (ea + x) & 0x3ffff
    ea

  g_EAF: (addr) ->
    return @cpu.mainStorage.get32(addr)

  g_EAH: (addr) ->
    return @cpu.mainStorage.get16(addr)

  s_EAF: (addr, value) ->
    @cpu.mainStorage.set32(addr, value, false)

  s_EAH: (addr, value) ->
    @cpu.mainStorage.set16(addr, value, false)

  setNIA: (x) -> @ls.PC().set32(x)

  incrNIA: (incr=1) -> @setNIA(@ls.PC().get32()+incr)

  recvFromCPU: (cmd,data) ->
    isOutput = cmd >>> 31
    devSelect = (cmd >>> 25) & 0x1f
    dataSelect = (cmd >>> 14) & 0x3ff

    @regCCData.set32(data)

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
      when 0x84040000 # MIA TRANSMITTER DISABLE
        r1 = @regXmitEna.get32()
        r2 = r1 & data
        r1 = r1 ^ r2
        @regXmitEna.set32(r1)
      when 0x85040000 # MIA TRANSMITTER ENABLE
        r1 = @regXmitEna.get32()
        r1 = r1 | data
        @regXmitEna.set32(r1)
      when 0x84080000 # MIA RECEIVER DISABLE
        r1 = @regRecvEna.get32()
        r2 = r1 & data
        r1 = r1 ^ r2
        @regRecvEna.set32(r1)
      when 0x85080000 # MIA RECEIVER ENABLE
        r1 = @regRecvEna.get32()
        r1 = r1 | data
        @regRecvEna.set32(r1)
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
        r1 = @regHalt.get32()
        r1 = r1 | data
        @regHalt.set32(r1)
      when 0x87200000 # CONFIGURE PROCESSORS ENABLE
        r1 = @regHalt.get32()
        r2 = r1 & data
        r1 = r1 ^ r2
        @regHalt.set32(r1)
      when 0x84400000 # MASTER RESET
        @regProgExcept.set32(0xfffff800)
        @regBusyWait.set32(0x00000000)
        @regHalt.set32(0xfffff800)
        @regXmitEna.set32(0x00000000)
        @regRecvEna.set32(0x00000000)

        @regDiscreteOut.set32(0x00000000)
      when 0x88040000 # LOAD GO/NO-GO TIMER
          r1 = @regRMStatus.get32()
          timerVal = data & 0x00000fff
          r1 = (r1 & 0xf000ffff) | (timerVal << 16)
          @regRMStatus.set32(r1)
      when 0x88048000 # LOAD GO/NO-GO TIMER TEST
          r1 = @regRMStatus.get32()
          timerVal = data & 0x00000fff
          r1 = (r1 & 0xf000ffff) | (timerVal << 16)
          @regRMStatus.set32(r1)
      when 0x88080000 # CONFIGURE TERMINATION CONTROL LATCHES
          timerLatch = (data >>> 1) & 0x1
          voterLatch = (data      ) & 0x1
          r1 = @regRMStatus.get32()
          r1 = (r1 & 0xffffafff) | (timerLatch << 12 ) | (voterLatch << 14)
          @regRMStatus.set32(r1)
      when 0x88100000 # LOAD TEST REGISTER
        return # no-op
      when 0x88180000 # TEST INTERRUPTS
          @intForceTest = true
          @regInterrupts.set32(0,0xffffffff)
          @regInterrupts.set32(1,0xffffffff)
          @regInterrupts.set32(3,0xffffffff)
          @regInterrupts.set32(4,0xffffffff)
      when 0x88140000 # ENABLE INTERRUPTS
          @intForceTest = false
      when 0x92000000 # RESET STATUS1(GO/NO-GO)
        return # no-op
      when 0x92040000 # LOAD MSC BUSY
        r1 = @regBusyWait.get32()
        r1 |= (1 << 0)
        @regBusyWait.set32(r1)
      when 0xc1008000 # INHIBIT COMPLETION OF A DMA CYCLE
        return # no-op
      when 0x04000000 # READ MIA TRANSMITTER STATUS
        r1 = @regXmitEna.get32()
        @regCCData.set32(r1)
      when 0x40400000 # READ MIA RECEIVER STATUS
        r1 = @regRecvEna.get32()
        @regCCData.set32(r1)
      when 0x04080000 # READ DISCRETE OUTPUT STATUS
        r1 = @regDiscreteOut.get32()
        @regCCData.set32(r1)
      when 0x040c0000 # READ PROCESSOR HALT STATUS
        r1 = @regHalt.get32()
        @regCCData.set32(r1)
      when 0x08000000 # READ INTERRUPT REGISTER A
        r1 = @regInterrupts.get32(0)
        @regCCData.set32(r1)
        @regInterrupts.set32(0,0x0)
      when 0x08040000 # READ INTERRUPT REGISTER B
        r1 = @regInterrupts.get32(1)
        @regCCData.set32(r1)
        @regInterrupts.set32(1,0x0)
      when 0x08080000 # READ INTERRUPT REGISTER C
        r1 = @regInterrupts.get32(2)
        @regCCData.set32(r1)
        @regInterrupts.set32(2,0x0)
      when 0x080c0000 # READ INTERRUPT REGISTER D
        r1 = @regInterrupts.get32(3)
        @regCCData.set32(r1)
        @regInterrupts.set32(3,0x0)
      when 0x08100000 # READ INTERRUPT REGISTER E
        r1 = @regInterrupts.get32(4)
        @regCCData.set32(r1)
        @regInterrupts.set32(4,0x0)
      when 0x08140000 # READ RM STATUS REGISTERS
        r1 = @regRMStatus.get32()
        @regCCData.set32(r1)
        @regInterrupts.set32(5,0x0)
      when 0x08180000 # READ DISCRETE INPUT A (1-32)
        r1 = @regDiscreteInA.get32()
        @regCCData.set32(r1)
      when 0x081c0000 # READ DISCRETE INPUTS (33-40)
        r1 = @regDiscreteInA.get32()
        @regCCData.set32(r1)
      when 0x10000000 # READ STATUS1(GO/NO-GO)
        r1 = @regProgExcept.get32()
        @regCCData.set32(r1)
      when 0x10040000 # READ STATUS4(BUSY/WAIT)
        r1 = @regBusyWait.get32()
        @regCCData.set32(r1)


    if devSelect == 0x8 # Local Store
        region = dataSelect >>> 5
        bank = (dataSelect >>> 3) & 0x3
        word = (dataSelect) & 0x7

        if isOutput
          r1 = @ls.ls(bank,word).get32()
          @regCCData.set32(r1)
        else
          @ls.ls(bank,word).set32(data)

