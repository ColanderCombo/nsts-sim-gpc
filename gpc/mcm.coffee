

# Extended Performance/Modular Core Memory
#
# Interchangeable 8K by 18 bit pluggable modules.
#
#   The Space Shuttle main storage consists of two, separate Extended
# Performance/Modular Core Memories (EP/MCM). One of these memories,
# having a storage capacity of 40K words by 36 bits, is located in the
# CPU LRU.  The other memory with a storage capacity of 24K words by
# 36 bits is located in the CPU LRU.  Both memories communicate directly
# with the CPU.
#
#
export class MCM
  constructor: (@wordCount) ->
    @rawData = new ArrayBuffer(@wordCount*4)
    @data8 = new Uint8Array(@rawData)

    # 1 storage protect bits per HW
    @protData = new Array(@wordCount*2).fill(false)

    # Access tracking: step number of last read/write per halfword
    # 0 = never accessed.  Views compare against @step to determine recency.
    totalHW = @wordCount * 2
    @lastRead = new Uint32Array(totalHW)
    @lastWritten = new Uint32Array(totalHW)
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
    # FCM files are big-endian (native AP-101S format)
    # Don't track writes during initial load
    for i in [0...data.byteLength/2]
      @set16((base+i),data.getUint16((i*2), false), false, false)
    @clearAccessTracking()

  setStoreProtect: (addr, v) ->
    @protData[addr] = v

  getStoreProtect: (addr) -> return @protData[addr]

  setView: (@_view) ->

  _updateView: () ->
     if @_view?
         @_view.value = @get32(0)

  # Advance the step counter. Call after each instruction execution.
  tick: () ->
    @step++

  # Get the step number when addr was last read (0 = never)
  getLastRead: (addr) ->
    return @lastRead[addr & 0x7ffff]

  # Get the step number when addr was last written (0 = never)
  getLastWritten: (addr) ->
    return @lastWritten[addr & 0x7ffff]

  # Get how many steps ago addr was last accessed (read or write).
  # Returns { type: 'none'|'read'|'write', age: number }
  # age=0 means "this step", age=1 means "last step", etc.
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

  # Clear all access tracking
  clearAccessTracking: () ->
    @lastRead.fill(0)
    @lastWritten.fill(0)
