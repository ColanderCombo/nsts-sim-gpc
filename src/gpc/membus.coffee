
# MemoryBus - arbitrate access to the MCM's in the CPU and IOP
#
# The AP-101B presents both MCM units as a contiguous 64K-word address space.
#
# per IBM-74-A31-016/p.20, 1.1.4 PACKAGING:
# 
# A GPC subsystem is packaged in two line replaceable units (LRU) as follows:
#   • One LRU contains the CPU and 40K of main memory.
#   • The second LRU contains the IOP and 24K of main memory.
# Although 24K of main memory is located in the IOP, the total 64K main memory is
# treated as one memory, and neither portion of main memory (40K or 24K) is dedicated
# to either the IOP or CPU. Both the IOP and CPU view the total 64K as one main mem-
# ory. The only significance that the IOP has to the 24K of memory located in its LRU
# is that the IOP supplies power to that portion of memory.
#
export class MemoryBus
  constructor: (@cpuMCM, @iopMCM) ->
    @cpuHWCount = @cpuMCM.wordCount * 2
    @totalHWCount = @cpuHWCount + @iopMCM.wordCount * 2
    if (@totalHWCount & (@totalHWCount - 1)) != 0
      throw new Error("MemoryBus: total halfword count #{@totalHWCount} is not a power of two")
    @addrMask = @totalHWCount - 1

  _route: (addr) ->
    addr = addr & @addrMask
    if addr < @cpuHWCount
      return { mcm: @cpuMCM, addr: addr }
    else
      return { mcm: @iopMCM, addr: addr - @cpuHWCount }

  get16: (addr, trackRead=true) ->
    r = @_route(addr)
    r.mcm.get16(r.addr, trackRead)

  get32: (addr, trackRead=true) ->
    r = @_route(addr)
    r.mcm.get32(r.addr, trackRead)

  set16: (i, v, checkProtect=true, trackWrite=true) ->
    r = @_route(i)
    r.mcm.set16(r.addr, v, checkProtect, trackWrite)

  set32: (i, v, checkProtect=true, trackWrite=true) ->
    r = @_route(i)
    r.mcm.set32(r.addr, v, checkProtect, trackWrite)

  load16: (base, data) ->
    total = Math.floor(data.byteLength / 2)
    for i in [0...total]
      @set16((base + i), data.getUint16((i * 2), false), false, false)
    @clearAccessTracking()
    return total

  clear: () ->
    @cpuMCM.clear()
    @iopMCM.clear()
    return

  resetProtect: () ->
    @cpuMCM.resetProtect()
    @iopMCM.resetProtect()
    return

  setStoreProtect: (addr, v) ->
    r = @_route(addr)
    r.mcm.setStoreProtect(r.addr, v)

  getStoreProtect: (addr) ->
    r = @_route(addr)
    r.mcm.getStoreProtect(r.addr)

  getProtLastWritten: (addr) ->
    r = @_route(addr)
    r.mcm.getProtLastWritten(r.addr)

  getProtColor: (addr, isSet, fadeCycles = 4) ->
    r = @_route(addr)
    r.mcm.getProtColor(r.addr, isSet, fadeCycles)

  setView: (view) -> @cpuMCM.setView(view)

  tick: () ->
    @cpuMCM.tick()
    @iopMCM.tick()

  getLastRead: (addr) ->
    r = @_route(addr)
    r.mcm.getLastRead(r.addr)

  getLastWritten: (addr) ->
    r = @_route(addr)
    r.mcm.getLastWritten(r.addr)

  getAccessInfo: (addr) ->
    r = @_route(addr)
    r.mcm.getAccessInfo(r.addr)

  getAccessColor: (addr, fadeCycles = 4) ->
    r = @_route(addr)
    r.mcm.getAccessColor(r.addr, fadeCycles)

  clearAccessTracking: () ->
    @cpuMCM.clearAccessTracking()
    @iopMCM.clearAccessTracking()
