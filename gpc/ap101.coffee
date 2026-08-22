
# AP-101 Computer Implementation
#
# This class represents the physical GPC: CPU, IOP, and a the connection
# between the two. 
#
fs = require 'fs'
path = require 'path'
import {LRU} from 'com/lru'
import {CPU} from 'gpc/cpu'
import {IOP} from 'gpc/iop'
import {MemoryBus} from 'gpc/membus'
import {MCM} from 'gpc/mcm'
import {resolveMachine} from 'gpc/machine'


export class AP101 extends LRU
  constructor: (CONFIG) ->
    lruConfig = {
      id: "GPC"
      nom: "GPC"
      busses: []
    }
    super(lruConfig)
    @CONFIG = CONFIG

    @machine = resolveMachine(CONFIG?.machine)
    @cpu = new CPU(@machine)
    @iop = new IOP(@cpu, @machine)
    @cpu.iop = @iop
    @cpu.ram = new MemoryBus(@cpu.mainStorage, @iop.mainStorage)

  Object.defineProperty @prototype, 'ram', get: -> @cpu.ram

  setMachine: (name) ->
    m = resolveMachine(name)
    @cpu.fpModel = m.fp
    return @machine if m.cpuWords == @machine.cpuWords and
                       m.iopWords == @machine.iopWords
    @machine = m
    @cpu.mainStorage = new MCM(m.cpuWords)
    @iop.mainStorage = new MCM(m.iopWords)
    @cpu.ram = new MemoryBus(@cpu.mainStorage, @iop.mainStorage)
    return @machine

  exec1: () ->
    @cpu.exec1()
    @iop.exec()

  reset: () ->
    # Register File
    for bank in [0..2]
      for i in [0..7]
        @cpu.regFiles[bank].r(i).set32(0)

    # Register DSE Bits (AP-101-S)
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
