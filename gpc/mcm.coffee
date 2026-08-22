

# Extended Performance/Modular Core Memory
#
# Interchangeable 8K by 18 bit pluggable modules.
#
#   The Space Shuttle main storage consists of two, separate Extended
# Performance/Modular Core Memories (EP/MCM). One of these memories,
# having a storage capacity of 40K words by 36 bits, is located in the
# CPU LRU.  The other memory with a storage capacity of 24K words by
# 36 bits is located in the IOP LRU.  Both memories communicate directly
# with the CPU.
#
#
export class MCM
  constructor: (@wordCount) ->
    @rawData = new ArrayBuffer(@wordCount*4)
    @data8 = new Uint8Array(@rawData)

    # initialize unprotected:
    @protData = new Array(@wordCount*2).fill(false)

    # Access tracking: step number of last read/write per halfword
    # 0 = never accessed.  Views compare against @step to determine recency.
    totalHW = @wordCount * 2
    @lastRead = new Uint32Array(totalHW)
    @lastWritten = new Uint32Array(totalHW)
    # Step number of the last protection-bit change per halfword (0 = never).
    @protLastWritten = new Uint32Array(totalHW)
    @step = 0
    @trackAccess = true

  get16: (addr, trackRead=true) ->
    addr = addr & 0x7ffff
    if trackRead and @trackAccess
      @lastRead[addr] = @step
    return (@data8[addr*2] << 8) | (@data8[(addr*2)+1])

  get32: (addr, trackRead=true) ->
    addr = addr & 0x7fffe
    return ((@get16(addr, trackRead) << 16) | @get16(addr+1, trackRead)) >>> 0

  set16: (i, v, checkProtect=true, trackWrite=true) ->
    if checkProtect and @protData[i]
        return false
    @data8[(i*2)] = (v >>> 8) & 0xff
    @data8[(i*2)+1] = v & 0xff
    if trackWrite and @trackAccess
      @lastWritten[i] = @step
    @_updateView()
    return true

  set32: (i, v, checkProtect=true, trackWrite=true) ->
    if checkProtect and (@protData[i] or @protData[i+1])
        return false
    @set16(i, (v>>>16) & 0xffff, false, trackWrite)
    @set16(i+1, v & 0xffff, false, trackWrite)
    @_updateView()
    return true

  load16: (base, data) ->
    total = Math.floor(data.byteLength / 2)
    for i in [0...total]
      @set16((base+i),data.getUint16((i*2), false), false, false)
    @clearAccessTracking()
    return total

  clear: () ->
    @data8.fill(0)
    @resetProtect()
    @clearAccessTracking()
    return

  resetProtect: () ->
    @protData.fill(false)
    @protLastWritten.fill(0)
    return

  setStoreProtect: (addr, v) ->
    if @protData[addr] != v and @trackAccess
      @protLastWritten[addr] = @step
    @protData[addr] = v

  getStoreProtect: (addr) -> return @protData[addr]

  getProtLastWritten: (addr) -> return @protLastWritten[addr & 0x7ffff]

  getProtColor: (addr, isSet, fadeCycles = 4) ->
    addr = addr & 0x7ffff
    st = if isSet then [0xff, 0xaa, 0x00] else [0x55, 0x55, 0x55]
    steady = "##{st[0].toString(16).padStart(2,'0')}#{st[1].toString(16).padStart(2,'0')}#{st[2].toString(16).padStart(2,'0')}"
    lw = @protLastWritten[addr]
    return steady if lw == 0
    age = @step - lw
    return steady if age >= fadeCycles
    # fade = 1.0 at age 0 -> 0.0 at fadeCycles. 
    fade = Math.max(0, Math.min(1, 1.0 - (age / Math.max(1, fadeCycles))))
    # Blend from white (the change highlight) toward the steady colour.
    r = Math.round(0xff*fade + st[0]*(1-fade))
    g = Math.round(0xff*fade + st[1]*(1-fade))
    b = Math.round(0xff*fade + st[2]*(1-fade))
    return "##{r.toString(16).padStart(2,'0')}#{g.toString(16).padStart(2,'0')}#{b.toString(16).padStart(2,'0')}"

  setView: (@_view) ->

  _updateView: () ->
     if @_view?
         @_view.value = @get32(0)

  tick: () ->
    @step++

  getLastRead: (addr) ->
    return @lastRead[addr & 0x7ffff]

  getLastWritten: (addr) ->
    return @lastWritten[addr & 0x7ffff]

  # Returns { type: 'none'|'read'|'write', age: number }
  getAccessInfo: (addr) ->
    addr = addr & 0x7ffff
    r = @lastRead[addr]
    w = @lastWritten[addr]
    if r == 0 and w == 0
      return { type: 'none', age: Infinity }
    if w >= r
      return { type: 'write', age: @step - w }
    else
      return { type: 'read', age: @step - r }

  # Get CSS color for a memory word based on access recency.
  # fadeCycles controls how many steps before color returns to default.
  getAccessColor: (addr, fadeCycles = 4) ->
    info = @getAccessInfo(addr)
    if info.type == 'none' or info.age >= fadeCycles
      return '#ccc'
    fade = 1.0 - (info.age / Math.max(1, fadeCycles))
    if info.type == 'read'
      r = Math.round(0xcc + (0x00 - 0xcc) * fade)
      g = Math.round(0xcc + (0xff - 0xcc) * fade)
      b = Math.round(0xcc + (0x00 - 0xcc) * fade)
    else
      r = Math.round(0xcc + (0xff - 0xcc) * fade)
      g = Math.round(0xcc + (0x00 - 0xcc) * fade)
      b = Math.round(0xcc + (0x00 - 0xcc) * fade)
    return "##{r.toString(16).padStart(2,'0')}#{g.toString(16).padStart(2,'0')}#{b.toString(16).padStart(2,'0')}"

  clearAccessTracking: () ->
    @lastRead.fill(0)
    @lastWritten.fill(0)
    @protLastWritten.fill(0)
