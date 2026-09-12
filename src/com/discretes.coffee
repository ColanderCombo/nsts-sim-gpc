# Discrete signals
#
# A discrete-register bit represents a wire shared by device processes.
#
# Each device on a channel has one bus: busConfig._gpcDiscretes<N> for a
# GPC, offset 80 + GPC ID, 0 for a standalone GPC; _idpDiscretes<N> for an
# IDP, offset 86 + IDP number - 1.  A DiscreteSpec names a device's
# channels and bits; the GPC's is below, the IDP's is
# meds/idp/idpDiscretes.coffee.  A device wired to every computer, such as
# a mass memory's READY, drives them all through DiscreteLines.  The lines
# from one GPC's outputs to the others' inputs are gpc/gpclinks.coffee.
#
# SET and RESET are multi-writer.  The channel's device holds each register,
# drives its outputs, and alone answers REQUEST with VALUE.
#
# Message layout, four halfwords:
#
#     0   operation   SET = 1, RESET = 2, REQUEST = 3, VALUE = 4
#     1   register    A = 1 (inputs 1-32), B = 2 (inputs 33-40),
#                     OUT = 3 (the outputs)
#     2   mask, high half     big-endian bit 0 is 0x8000 of this word
#     3   mask, low half
#     4-5 optional sender simulated time in microseconds
#

import {Bus, BusMsg, busConfig} from 'com/bus'

export SET = 1
export RESET = 2
export REQUEST = 3                # ask the device for a register's value
export VALUE = 4                  # the device's answer: the whole register

export REG_A = 1                  # inputs 1-32
export REG_B = 2                  # inputs 33-40
export REG_OUT = 3                # outputs

export REPUBLISH_MS = 250
export DISCRETE_WORDS = 4
export STAMPED_DISCRETE_WORDS = 6

# big-endian bit n of a 32-bit discrete register.
export bitMask = (n) -> (0x80000000 >>> n) >>> 0

export encodeDiscrete = (op, reg, mask, timeUs = null) ->
  msg = new BusMsg(if timeUs? then STAMPED_DISCRETE_WORDS else DISCRETE_WORDS)
  msg.data16[0] = op & 0xffff
  msg.data16[1] = reg & 0xffff
  msg.data16[2] = (mask >>> 16) & 0xffff
  msg.data16[3] = mask & 0xffff
  if timeUs?
    t = Math.floor(timeUs) >>> 0
    msg.data16[4] = (t >>> 16) & 0xffff
    msg.data16[5] = t & 0xffff
  msg

export decodeDiscrete = (msg) ->
  return null unless msg?.data16? and msg.data16.length >= DISCRETE_WORDS
  op = msg.data16[0] & 0xffff
  reg = msg.data16[1] & 0xffff
  return null unless op in [SET, RESET, REQUEST, VALUE]
  return null unless reg in [REG_A, REG_B, REG_OUT]
  mask = (((msg.data16[2] & 0xffff) << 16) | (msg.data16[3] & 0xffff)) >>> 0
  m = {op: op, reg: reg, mask: mask}
  if msg.data16.length >= STAMPED_DISCRETE_WORDS
    m.timeUs = (((msg.data16[4] & 0xffff) << 16) | (msg.data16[5] & 0xffff)) >>> 0
  m.wallUs = msg.wallUs if msg.wallUs?
  m

export applyDiscrete = (value, m) ->
  return value >>> 0 unless m?
  switch m.op
    when SET     then ((value | m.mask) >>> 0)
    when RESET   then ((value & ~m.mask) >>> 0)
    when VALUE   then (m.mask >>> 0)
    else (value >>> 0)

export class DiscreteSpec
  constructor: ({@unit, @prefix, @ids, @registers, regNames}) ->
    @regNames = Object.assign({}, {1: 'A', 2: 'B', 3: 'OUT'}, regNames ? {})
    @regs = (Number(r) for r of @registers)

  busName: (id) -> "#{@prefix}#{id}"

  resolveId: (n) ->
    id = parseInt(n, 10)
    throw new Error("invalid #{@unit} ID '#{n}'") unless id in @ids
    id

  regName: (reg) -> @regNames[reg] ? "reg #{reg}"

  bitTable: (reg) -> @registers[reg] ? {}

  name: (reg, bit) ->
    for name, b of @bitTable(reg)
      return name if b == bit
    "bit #{bit}"

  resolve: (reg, token) ->
    table = @bitTable(reg)
    key = String(token).toLowerCase()
    return table[key] if table[key]?
    n = parseInt(token, 10)
    throw new Error("unknown discrete '#{token}'") unless 0 <= n <= 31
    n

  describe: (reg, mask) ->
    names = (@name(reg, b) for b in [0...32] when mask & bitMask(b))
    if names.length then names.join(', ') else 'no bits'

  pack: (reg, levels) ->
    v = 0
    for name, on_ of levels when on_
      v = (v | bitMask(@resolve(reg, name))) >>> 0
    v

export class DiscreteChannel
  constructor: (busName, onMessage = null, id = null) ->
    @name = busName
    @id = id
    config = busConfig[@name]
    return unless config
    @bus = new Bus(@name, config)
    @bus.onReceive ((self, busID, msg) ->
      onMessage?(decodeDiscrete(msg), id)), null

  ready: () ->
    @bus?.ready ? Promise.resolve()

  close: () ->
    @bus?.close()
    @bus = null
    return

  publish: (op, reg, mask, timeUs = null) ->
    @bus?.sendMsg encodeDiscrete(op, reg, mask, timeUs)
    return

  set: (reg, bit, on_) ->
    @publish (if on_ then SET else RESET), reg, bitMask(bit)

  request: (reg) ->
    @publish REQUEST, reg, 0

  report: (reg, value, timeUs = null) ->
    @publish VALUE, reg, value, timeUs

# The device end holds canonical register values.  Inputs accept SET and
# RESET; output registers accept local writes.  REQUEST returns VALUE.
export class DiscreteHolder
  constructor: (@channel, {registers, outputs, @onChange} = {}) ->
    @value = {}
    @dflt = {}
    @driven = {}
    @outputs = outputs ? [REG_OUT]
    for reg, v of registers ? {}
      @value[reg] = v >>> 0
      @dflt[reg] = v >>> 0
      @driven[reg] = 0

  get: (reg) -> (@value[reg] ? 0) >>> 0

  bit: (reg, bit) -> (@get(reg) & bitMask(bit)) != 0

  recv: (m) ->
    return unless m? and @value[m.reg]?
    if m.op == REQUEST
      @channel.report(m.reg, @get(m.reg))
      return
    return if m.op == VALUE or m.reg in @outputs
    @_apply(m.reg, applyDiscrete(@get(m.reg), m), m.mask)
    return

  setInput: (reg, bit, on_) ->
    @recv {op: (if on_ then SET else RESET), reg: reg, mask: bitMask(bit)}
    return

  setOutput: (reg, bit, on_) ->
    before = @get(reg)
    now = if on_ then ((before | bitMask(bit)) >>> 0) else ((before & ~bitMask(bit)) >>> 0)
    return if now == before
    @value[reg] = now
    on_ = ((now & ~before) >>> 0)
    off_ = ((before & ~now) >>> 0)
    @channel.publish(SET, reg, on_) if on_
    @channel.publish(RESET, reg, off_) if off_
    return

  report: () ->
    @channel.report(Number(reg), v) for reg, v of @value
    return

  # A reset restores the defaults for the bits nothing outside has driven.
  reset: () ->
    for reg, dflt of @dflt
      driven = @driven[reg] ? 0
      @_apply(Number(reg), (((dflt & ~driven) | (@get(reg) & driven)) >>> 0), 0)
    return

  _apply: (reg, now, mask) ->
    before = @get(reg)
    @value[reg] = now >>> 0
    @driven[reg] = ((@driven[reg] ? 0) | mask) >>> 0
    @onChange?(reg, before, now >>> 0) if now != before
    return

export class DiscreteLines
  constructor: (ids = null, onMessage = null, spec = null) ->
    spec ?= GPC_DISCRETES
    ids ?= spec.ids
    @busses = (new DiscreteChannel(spec.busName(n), onMessage, n) for n in ids)

  ready: () -> Promise.all(b.ready() for b in @busses)

  close: () ->
    b.close() for b in @busses
    return

  publish: (op, reg, mask) ->
    b.publish(op, reg, mask) for b in @busses
    return

  set: (reg, bit, on_) ->
    b.set(reg, bit, on_) for b in @busses
    return

  request: (reg) ->
    b.request(reg) for b in @busses
    return

# The GPC
#
# The inter-GPC lines are numbered N+1..N+4 relative to this computer.
# The wiring rotates, so N+1 at gpc 1 is gpc 2 and N+1 at gpc 5 is gpc 1.
# Hence the `n1`..`n4` suffixes.
export DISCRETE_BITS =
  A:
    halt: 0, standby: 1, run: 2, ipl: 3
    mm1src: 4, mm2src: 5
    mm1ready: 6, mm2ready: 7
    bfsrunn1: 8, bfsrunn2: 9, bfsrunn3: 10, bfsrunn4: 11
    ioterma: 12, iotermb: 13
    dumpreq: 15
    stbyn1: 20, stbyn2: 21, stbyn3: 22, stbyn4: 23
    runn1: 24, runn2: 25, runn3: 26, runn4: 27
    syncn1: 28, syncn2: 29, syncn3: 30, syncn4: 31
  B:
    gpcid0: 0, gpcid1: 1, gpcid2: 2
    bfs1: 3, bfs2: 4, bfs3: 5
    crta: 6, crtb: 7

export DISCRETE_OUT_BITS =
  ioactivetb: 7
  readytb: 9
  mm1reset: 12, mm2reset: 13
  stbyout: 20
  bfsrunout: 22
  runout: 24
  syncout: 28
  idsource: 30
  iplout: 31

# The self-sync lines
#
#   DO-20, 24 and 28 carry a code as one octal digit, SYNC 1 the most
# significant, and a computer reads its partners' on DI-A.  A code is
# issued by resetting bits from the null code and held past the last read
# of the partners' lines; all three lines low is a computer powered off,
# halted or in standby.
export SYNC_OUT_LINES = ['stbyout', 'runout', 'syncout']

export syncInLines = (n) -> ["stbyn#{n}", "runn#{n}", "syncn#{n}"]

export SYNC_CODE_NAMES =
  7: 'null'
  6: 'SSIP'
  5: 'timer'
  4: 'SVC'
  2: 'IPR'
  1: 'IOC'
  0: 'off'

codeOf = (value, bits) ->
  code = 0
  for b in bits
    code = ((code << 1) | (if (value & bitMask(b)) != 0 then 1 else 0)) >>> 0
  code

export syncCodeOut = (value) ->
  codeOf(value, (DISCRETE_OUT_BITS[n] for n in SYNC_OUT_LINES))

export syncCodeIn = (value, n) ->
  codeOf(value, (DISCRETE_BITS.A[l] for l in syncInLines(n)))

# `IOC (001)`, or the digits alone for a code the software does not issue.
export syncCodeName = (code) ->
  name = SYNC_CODE_NAMES[code]
  digits = (code & 7).toString(2).padStart(3, '0')
  if name? then "#{name} (#{digits})" else digits

export DISCRETE_BUS_PREFIX = '_gpcDiscretes'
export GPC_IDS = [0, 1, 2, 3, 4, 5]

export GPC_DISCRETES = new DiscreteSpec
  unit: 'GPC'
  prefix: DISCRETE_BUS_PREFIX
  ids: GPC_IDS
  registers: {1: DISCRETE_BITS.A, 2: DISCRETE_BITS.B, 3: DISCRETE_OUT_BITS}

export discreteBusName = (gpc) -> GPC_DISCRETES.busName(gpc)
export resolveGpcId = (n) -> GPC_DISCRETES.resolveId(n)
export regName = (reg) -> GPC_DISCRETES.regName(reg)
export discreteName = (reg, bit) -> GPC_DISCRETES.name(reg, bit)
export discreteOutName = (bit) -> GPC_DISCRETES.name(REG_OUT, bit)
export resolveDiscrete = (reg, token) -> GPC_DISCRETES.resolve(reg, token)
export describeDiscrete = (reg, mask) -> GPC_DISCRETES.describe(reg, mask)

export REG_NAME = GPC_DISCRETES.regNames

export DISCRETE_MODES = ['halt', 'standby', 'run']

# IPL button-press duration.
export IPL_PRESS_MS = 300

export class DiscreteBus extends DiscreteChannel
  constructor: (gpc, onMessage = null) ->
    id = resolveGpcId(gpc)
    super(discreteBusName(id), onMessage, id)
    @gpc = id
