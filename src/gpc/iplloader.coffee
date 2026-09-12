# The IPL, as the microcode performs it.
#
# POO 2.5.3.3: "IPL first causes a system reset function and the writing
# of C6C6 (hex) by the CPU to all memory locations above and including
# address 20000 Hex with memory store protected.  IOP microcode at IPL
# writes C9FB (hex) to all locations from 0 to 1FFFF Hex, with memory
# store protected."
#
# Then the microcode reads the IPL bootstrap copy off the mass memory
# the IPL SOURCE discrete names into sector zero, and takes a second
# system reset.  That reset enters the bootstrap loader through the PSW
# at halfword 0x14 of the record just read.
#
# Three deviations from the hardware:
#
#   * The programs are in main storage.  Microcode is fetched from a
#     control store the CPU cannot address.  They occupy the top of the
#     IOP's address range, above sector zero, and are erased to the fill
#     pattern afterwards.
#   * Sector zero is unprotected across the read and protected again
#     after.  A DMA write in this model honours the protect bit, and the
#     fill leaves the whole sector protected.  Storage is protected
#     either way at hand-over.
#   * Completion is the processor's busy/wait bit.  The mass memory
#     READY discrete reads set again while the element is still draining
#     its receiver.
#
import {IOP_SLICE_NS} from 'gpc/cpu'
import {RTPacer} from 'gpc/rtpacer'
import IMAGE from 'gpc/gen/fakeipl.json'

# POO 2.5.3.3: the two fill patterns and the address that divides them.
FILL_LOW   = 0xc9fb
FILL_HIGH  = 0xc6c6
FILL_SPLIT = 0x20000

# The bootstrap copy is one sector: the record is the content of sector
# zero, and the loader it carries runs at that address.
SECTOR_HW = 0x8000

# The two IPL SOURCE discretes, input A bits 4 and 5, and the bus
# control elements the two mass memories answer on.
IPL_SOURCE_SHIFT = 26              # bits 4 and 5, right justified
MM1_BCE = 18
MM2_BCE = 19

PROC_MSC    = 0
MAX_TIMEOUT = 0x3ffff              # 4.32 s, the longest a BCE will wait

# POO I/DO-31: "This bit when set (1) indicates that the IPL routine is
# in progress.  When reset (0), the bit indicates that the IPL routine
# has not been requested or that it is complete".
IPL_RUNNING = 0x00000001           # discrete output 31

# Simulated time the MSC is given before the IPL is treated as failed.
# Above the two 8.65 s repeats it spends waiting on the element, so a
# transfer that dies reports through its status word first.
PROGRAM_LIMIT_NS = 20e9

SLICES_PER_TURN = 512

bitMask = (n) -> (0x80000000 >>> n) >>> 0


export class IPLLoader
  constructor: (@gpc, opts = {}) ->
    @cpu = @gpc.cpu
    @iop = @gpc.iop
    @log = opts.log ? (->)

  sym: (name) -> IMAGE.symbols[name]

  # Fill, select, load, start the MSC, check, erase, hand over.
  run: (pacer) ->
    pacer ?= new RTPacer(@cpu, 1.0)
    @fill()
    @load()
    @configure()

    await @runMSC(pacer)

    status = @gpc.ram.get32(@sym('IPLSTAT')) >>> 0
    @erase()
    @iop.setDiscreteOut(IPL_RUNNING, false)

    # A clean transfer stores zero; the cell holds -1 until an element
    # stores over it.
    if status != 0
      throw new Error("mass memory read of the bootstrap copy ended " +
                      "with status 0x#{status.toString(16)}")
    @log "bootstrap copy read: #{SECTOR_HW} halfwords into sector zero"

    entry = @cpu.systemReset()
    @log "system reset: PSW at PSA 0x14 -> 0x#{entry.toString(16)}"
    return { status: status, entry: entry }

  # --- storage ------------------------------------------------------------

  protect: (lo, hi, v) ->
    @gpc.ram.setStoreProtect(a, v) for a in [lo...hi]
    return

  fill: ->
    n = (@gpc.machine.cpuWords + @gpc.machine.iopWords) * 2
    for a in [0...n]
      @gpc.ram.set16(a, (if a < FILL_SPLIT then FILL_LOW else FILL_HIGH), false)
      @gpc.ram.setStoreProtect(a, true)
    @log "memory filled: #{FILL_LOW.toString(16)} below " +
         "0x#{FILL_SPLIT.toString(16)}, #{FILL_HIGH.toString(16)} above, " +
         "#{n} halfwords store protected"
    return n

  # The programs, and the two discretes the MSC picks the source from.
  # No IOP instruction reads the discrete inputs, so IPLSRC is where
  # they reach the program.
  load: ->
    @protect(IMAGE.origin, IMAGE.origin + IMAGE.length, false)
    @protect(0, SECTOR_HW, false)
    for hw, i in IMAGE.image
      @gpc.ram.set16(IMAGE.origin + i, parseInt(hw, 16), false)
    src = (@iop.regDiscreteInA.get32() >>> IPL_SOURCE_SHIFT) & 3
    @gpc.ram.set32(@sym('IPLSRC'), src, false)
    @log "IPL source discretes: #{src.toString(2).padStart(2, '0')}"
    return

  erase: ->
    for a in [IMAGE.origin...IMAGE.origin + IMAGE.length]
      @gpc.ram.set16(a, FILL_HIGH, false)
    @protect(IMAGE.origin, IMAGE.origin + IMAGE.length, true)
    @protect(0, SECTOR_HW, true)
    return

  # --- the IOP ------------------------------------------------------------

  # Local store, per processor: the program counter, and the longest a
  # receive may wait.
  setPC: (p, addr) -> @iop.ls.at(p, 0, 2).set32(addr)
  setTimeout: (p, count) -> @iop.ls.at(p, 1, 3).set32(count)

  # The MSC and both mass memory elements enabled, their transmitters
  # and receivers on, their time outs at the maximum, and IPL RUNNING
  # asserted.  Which of the two runs is the MSC program's choice.
  configure: ->
    mask = (bitMask(MM1_BCE) | bitMask(MM2_BCE)) >>> 0
    @iop.regProcEnable.set32((mask | bitMask(PROC_MSC)) >>> 0)
    @iop.regXmitEna.set32(mask)
    @iop.regRecvEna.set32(mask)
    @setTimeout(MM1_BCE, MAX_TIMEOUT)
    @setTimeout(MM2_BCE, MAX_TIMEOUT)
    @iop.setDiscreteOut(IPL_RUNNING, true)
    return

  running: (p) ->
    @iop.procGet(@iop.regProcEnable, p) and @iop.procGet(@iop.regBusyWait, p)

  # --- running it ---------------------------------------------------------

  # One IOP slice and the simulated time it costs.  The CPU is held
  # through an IPL, so nothing else turns the clock the IOP runs on.
  slice: ->
    @cpu.timeNs += IOP_SLICE_NS
    @iop.exec()
    return

  # Run the IOP until `done`, yielding between turns:
  pump: (done, pacer, limitNs = PROGRAM_LIMIT_NS) ->
    return true if done()
    spent = 0
    while spent < limitNs
      for i in [0...SLICES_PER_TURN]
        @slice()
        spent += IOP_SLICE_NS
        return true if done()
      await pacer.pace()
    return false

  # Start the MSC and wait for it.  It runs both bus programs -- load the
  # element's program counter, start it, wait for it to reach its #WAT --
  # so the MSC back in the wait state is the whole sequence done.
  runMSC: (pacer) ->
    @setPC(PROC_MSC, @sym('IPLMSC'))
    @iop.procSet(@iop.regBusyWait, PROC_MSC, 1)
    unless await @pump((=> not @running(PROC_MSC)), pacer)
      throw new Error("the IPL programs did not finish inside " +
                      "#{PROGRAM_LIMIT_NS / 1e9} s")
    return
