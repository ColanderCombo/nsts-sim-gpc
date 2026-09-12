
# AP-101 Computer Implementation
#
# A GPC containing a CPU, IOP, and their memory bus.
#
fs = require 'fs'
path = require 'path'
import {LRU} from 'com/lru'
import {CPU, IOP_SLICE_NS} from 'gpc/cpu'
import {IOP, gpcSelfId} from 'gpc/iop'
import {MemoryBus} from 'gpc/membus'
import {MCM} from 'gpc/mcm'
import {resolveMachine} from 'gpc/machine'


# "Positioning a switch to ON enables power from three essential buses,
# ESS 1BC, 2CA, and 3AB.  The essential bus power controls remote power
# controller (RPCs), which permit main bus DC power from the three main
# buses (MN A, MN B, and MN C) to power the GPC.  There are three RPCs for
# each GPC ... Each computer uses 560 watts of power" (USA-007587
# sect.2.6).  wiring/eps.wir drives the three feeds; GPC 0, the
# standalone computer, is on none of them.
GPC_WATTS = 560
GPC_SUPPLIES = ['A', 'B', 'C']

export class AP101 extends LRU
  constructor: (CONFIG) ->
    n = gpcSelfId(CONFIG?.gpc)
    lruConfig = {
      id: "GPC#{n}"
      nom: "GPC"
      busses: []
      power: (if n > 0 then ({name: s, feed: "GPC#{n}_#{s}"} for s in GPC_SUPPLIES) else null)
    }
    super(lruConfig)
    @CONFIG = CONFIG

    @machine = resolveMachine(CONFIG?.machine)
    @cpu = new CPU(@machine)
    @iop = new IOP(@cpu, @machine, CONFIG?.gpc)
    @cpu.iop = @iop
    @cpu.ram = new MemoryBus(@cpu.mainStorage, @iop.mainStorage)

  dstoreBlocks: ->
    # FCM is the contiguous, big-endian halfword image used by loadFCM.
    # Direct backing-store copies preserve access counters and protection.
    blocks = []
    offset = 0
    for [name, memory] in [['cpu', @cpu.mainStorage], ['iop', @iop.mainStorage]]
      continue unless memory.wordCount
      blocks.push {file: 'memory.fcm', value: memory.rawData, offset}
      offset += memory.rawData.byteLength
      blocks.push {file: "#{name}-protection.bin", value: memory.protData, encoding: 'bits'}
      for field in ['lastRead', 'lastWritten', 'protLastWritten']
        blocks.push {file: "#{name}-#{field}.bin.gz", value: memory[field].buffer, compression: 'gzip'}
    blocks

  beforeRestoreDstore: ->
    @iop.leaveBarrier()
    return

  afterRestoreDstore: ->
    # Shared-memory membership belongs to this process, not the saved PID.
    @iop.leaveBarrier()
    if @runState?.running and @runState?.realTime
      offset = @iop.barrierOffsetUs
      @iop.joinBarrier()
      if @iop.barrier? and offset?
        @iop.barrierOffsetUs = @iop.barrier.offsetUs = offset
        @iop.barrier.publish(@cpu.timeNs)
    return

  Object.defineProperty @prototype, 'ram', get: -> @cpu.ram

  controlBusMap: ->
    buses = super()
    for bce in @iop?.bce ? []
      bus = bce.mia?.bus
      buses[bus.busID] = bus if bus?
    bus = @iop?.discreteBus?.bus
    buses[bus.busID] = bus if bus?
    for _, other of @iop?.gpcLinks?.others ? {}
      bus = other.bus?.bus
      buses[bus.busID] = bus if bus?
    buses

  onPower: (on_) ->
    @iop?.setPowered(on_)
    return

  powerDraw: (input) ->
    live = (i for i in @power.inputs when i.live())
    return 0 unless input.live() and live.length
    GPC_WATTS / live.length

  setMachine: (name) ->
    m = resolveMachine(name)
    @cpu.fpModel = m.model
    return @machine if m.cpuWords == @machine.cpuWords and
                       m.iopWords == @machine.iopWords
    @machine = m
    @cpu.mainStorage = new MCM(m.cpuWords)
    @iop.mainStorage = new MCM(m.iopWords)
    @cpu.ram = new MemoryBus(@cpu.mainStorage, @iop.mainStorage)
    return @machine

  exec1: () ->
    t0 = @cpu.timeNs
    @cpu.exec1()
    @iopSliceNs = (@iopSliceNs ? 0) + (@cpu.timeNs - t0)
    while @iopSliceNs >= IOP_SLICE_NS
      @iopSliceNs -= IOP_SLICE_NS
      @iop.exec()
    return

  reset: () ->
    # Register File
    for bank in [0..2]
      for i in [0..7]
        @cpu.regFiles[bank].r(i).set32(0)

    # Register DSE Bits (AP-101S)
    for bank in [0..1]
      for i in [0..7]
        @cpu.regFiles[bank].setDSE(i, 0)

    # PSW
    @cpu.psw.psw1.set32(0)
    @cpu.psw.psw2.set32(0)

    @cpu.reset()
    @iop.reset()

start = (CONFIG) ->
  gpc = new AP101(CONFIG)
  return gpc

export default { start }
