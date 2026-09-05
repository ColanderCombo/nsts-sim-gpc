# GPC discrete signals
#
# This module models a GPC's discrete input and output registers
# using the multicast bus mechanism.
#
# Each bit in a discrete register is a physical wire, asserted or read by
# devices modelled in separate processes (the MMU1/MMU2 READY bits are
# asserted by the MMU and read by the GPC).
#
# Each line runs to one computer: busConfig._gpcDiscretes<N>, bus offset
# 80 + GPC ID, 0 for a standalone GPC.  A device wired to every computer, such
# as a mass memory's READY, drives them all through DiscreteLines.
#
# Fields have no owner: any process writes a word through SET/RESET
# masks.  The GPC
# holds the canonical value of all three registers: it applies the
# SET/RESET a device sends, it publishes what it writes to the output
# register the same way, and it is the only sender of VALUE.  Nothing is
# re-broadcast on a timer, so a process that attaches late asks with
# REQUEST.
#
# Message layout, four halfwords:
#
#     0   operation   SET = 1, RESET = 2, REQUEST = 3, VALUE = 4
#     1   register    A = 1 (inputs 1-32), B = 2 (inputs 33-40),
#                     OUT = 3 (the discrete outputs)
#     2   mask, high half     big-endian bit 0 is 0x8000 of this word
#     3   mask, low half
#
#

import {Bus, BusMsg, busConfig} from 'com/bus'

export DISCRETE_BUS_PREFIX = '_gpcDiscretes'
export GPC_IDS = [0, 1, 2, 3, 4, 5]

export discreteBusName = (gpc) -> "#{DISCRETE_BUS_PREFIX}#{gpc}"

export resolveGpcId = (n) ->
  id = parseInt(n, 10)
  throw new Error("GPC ID must be 0 to 5, got '#{n}'") unless id in GPC_IDS
  id

export SET = 1
export RESET = 2
export REQUEST = 3                # ask the GPC for a register's value
export VALUE = 4                  # the GPC's answer: the whole register

export REG_A = 1                  # discrete inputs 1-32
export REG_B = 2                  # discrete inputs 33-40
export REG_OUT = 3                # discrete outputs

export REG_NAME = {}
REG_NAME[REG_A] = 'A'
REG_NAME[REG_B] = 'B'
REG_NAME[REG_OUT] = 'OUT'

export regName = (reg) -> REG_NAME[reg] ? "reg #{reg}"

export REPUBLISH_MS = 250
export DISCRETE_WORDS = 4

# big-endian bit n of a 32-bit discrete register.
export bitMask = (n) -> (0x80000000 >>> n) >>> 0

# The inter-GPC lines are numbered N+1..N+4 relative to this computer.
# The wiring rotates, so N+1 at gpc 1 is gpc 2 and
# N+1 at gpc 5 is gpc 1.  Hence the `n1`..`n4` suffixes.
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

export discreteOutName = (bit) ->
  for name, b of DISCRETE_OUT_BITS
    return name if b == bit
  "bit #{bit}"

export DISCRETE_MODES = ['halt', 'standby', 'run']

# When run with --ipl, how long to hold the IPL discrete high
# to simulate a button press:
export IPL_PRESS_MS = 300

bitTable = (reg) ->
  switch reg
    when REG_B then DISCRETE_BITS.B
    when REG_OUT then DISCRETE_OUT_BITS
    else DISCRETE_BITS.A

export discreteName = (reg, bit) ->
  for name, b of bitTable(reg)
    return name if b == bit
  "bit #{bit}"

export resolveDiscrete = (reg, token) ->
  table = bitTable(reg)
  key = String(token).toLowerCase()
  return table[key] if table[key]?
  n = parseInt(token, 10)
  throw new Error("unknown discrete '#{token}'") unless 0 <= n <= 31
  n

export describeDiscrete = (reg, mask) ->
  names = (discreteName(reg, b) for b in [0...32] when mask & bitMask(b))
  if names.length then names.join(', ') else 'no bits'

export encodeDiscrete = (op, reg, mask) ->
  msg = new BusMsg(DISCRETE_WORDS)
  msg.data16[0] = op & 0xffff
  msg.data16[1] = reg & 0xffff
  msg.data16[2] = (mask >>> 16) & 0xffff
  msg.data16[3] = mask & 0xffff
  msg

export decodeDiscrete = (msg) ->
  return null unless msg?.data16? and msg.data16.length >= DISCRETE_WORDS
  op = msg.data16[0] & 0xffff
  reg = msg.data16[1] & 0xffff
  return null unless op in [SET, RESET, REQUEST, VALUE]
  return null unless reg in [REG_A, REG_B, REG_OUT]
  mask = (((msg.data16[2] & 0xffff) << 16) | (msg.data16[3] & 0xffff)) >>> 0
  {op: op, reg: reg, mask: mask}

export applyDiscrete = (value, m) ->
  return value >>> 0 unless m?
  switch m.op
    when SET     then ((value | m.mask) >>> 0)
    when RESET   then ((value & ~m.mask) >>> 0)
    when VALUE   then (m.mask >>> 0)
    else (value >>> 0)

export class DiscreteBus
  constructor: (gpc, onMessage = null) ->
    @gpc = resolveGpcId(gpc)
    @name = discreteBusName(@gpc)
    config = busConfig[@name]
    return unless config
    gpc = @gpc
    @bus = new Bus(@name, config)
    @bus.onReceive ((self, busID, msg) ->
      onMessage?(decodeDiscrete(msg), gpc)), null

  close: () ->
    @bus?.close()
    @bus = null
    return

  publish: (op, reg, mask) ->
    @bus?.sendMsg encodeDiscrete(op, reg, mask)
    return

  set: (reg, bit, on_) ->
    @publish (if on_ then SET else RESET), reg, bitMask(bit)

  request: (reg) ->
    @publish REQUEST, reg, 0

  report: (reg, value) ->
    @publish VALUE, reg, value

# One line reaching several computers: the same traffic on each GPC's
# channel, and a receiver told which one it came from.
export class DiscreteLines
  constructor: (ids = GPC_IDS, onMessage = null) ->
    @busses = (new DiscreteBus(n, onMessage) for n in ids)

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
