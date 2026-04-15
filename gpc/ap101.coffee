
# AP-101 Computer Implementation
#
# This class represents the physical GPC: CPU, IOP, and a the connection
# between the two. (Partial: the CPU and IOP can talk, but only the
# memory access bus is modeled)
#
# The 'AP-101' is currently a vague hybrid between an AP-101-B
# and AP-101-S.  Once we make a pass to better conform to the
# -S specs we can split this into AP101B and AP101S
#
# The cpu.halUCP hook point remains (null by default) so that AGEHarness
# can wire in the HAL/S I/O trap layer when needed for development.

fs = require 'fs'
path = require 'path'
import {LRU} from 'com/lru'
import {CPU} from 'gpc/cpu'
import {IOP} from 'gpc/iop'
import {MemoryBus} from 'gpc/membus'


export class AP101 extends LRU
  constructor: (CONFIG) ->
    lruConfig = {
      id: "GPC"
      nom: "GPC"
      busses: []
    }
    super(lruConfig)
    @CONFIG = CONFIG

    @cpu = new CPU()
    @iop = new IOP(@cpu)
    @cpu.iop = @iop
    @cpu.ram = new MemoryBus(@cpu.mainStorage, @iop.mainStorage)

  Object.defineProperty @prototype, 'ram', get: -> @cpu.ram

  exec1: () ->
    @cpu.exec1()
    @iop?.exec()

  reset: () ->
    # Register File
    for bank in [0..2]
      for i in [0..7]
        @cpu.regFiles[bank].r(i).set32(0)

    # Register DSE Bits (AP-101-S)
    for bank in [0..1]
      for i in [0..3]
        @cpu.regFiles[bank].setDSE(i, 0)

    # PSW
    @cpu.psw.psw1.set32(0)
    @cpu.psw.psw2.set32(0)


start = (CONFIG) ->
  gpc = new AP101(CONFIG)
  return gpc

export default { start }
