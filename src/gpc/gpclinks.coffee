import {call, setInterval, clearInterval} from '../com/simRuntime.coffee'
# The discrete lines between the five GPCs
#
# IBM-85-C67-001/p.321-325 wires four of a GPC's discrete outputs to the
# other four computers: DO-20, DO-24 and DO-28 are "GPC SELF SYNC 1", "2"
# and "3", DO-22 is "BFS RUN".  Each arrives at the others as an input
# naming the sender by its distance around the ring: DI-20 to DI-23 are
# "GPC N+1 DISCRETE OUTPUT BIT 20 (SYNC 1)" through N+4, DI-24 to DI-27
# and DI-28 to DI-31 the same for bits 24 and 28, and DI-8 to DI-11 "GPC
# N+1 IS BFS RUN GPC" through N+4.  N+k is GPC number arithmetic modulo 5
# over 1 to 5: GPC 5's N+1 is GPC 1, and GPC 1 is GPC 2's N+4.
#
# GpcLinks listens on the other computers' discrete channels and maps their
# output registers onto this computer's register A.  After LOST_AFTER
# unanswered polls, a computer's inputs fall to zero.
#
# Stamped changes retain the sender's simulated-time spacing.  The first
# change in a burst lands immediately; gaps and holds are capped at
# HOLD_MAX_US.  Unstamped changes land immediately.
#
# GPC 0 is a standalone computer, on the ring at no position, with no
# links.

import {DiscreteBus, applyDiscrete, bitMask, resolveGpcId,
        DISCRETE_BITS, DISCRETE_OUT_BITS,
        SET, RESET, VALUE, REG_OUT} from 'com/discretes'
import {wallNowUs} from 'com/bus'

export LINKED_IDS = [1, 2, 3, 4, 5]

# Output bit at the sender, and the register A input family it lands in at
# each receiver: `stbyn` is stbyn1 for the sender at N+1, stbyn4 at N+4.
export LINKS = [
  { out: 'stbyout',   input: 'stbyn' }
  { out: 'runout',    input: 'runn' }
  { out: 'syncout',   input: 'syncn' }
  { out: 'bfsrunout', input: 'bfsrunn' }
]

export POLL_MS = 1000
export LOST_AFTER = 3
export HOLD_MAX_US = 5000

# Host-crossing measurements above this limit use an incompatible clock.
export CROSS_MAX_US = 1000000

tally = () -> {n: 0, sum: 0, max: 0, last: null}

note = (t, us) ->
  us = Math.round(us)
  t.n += 1
  t.sum += us
  t.max = us if us > t.max
  t.last = us
  return

export tallyOf = (t) ->
  return null unless t? and t.n > 0
  {n: t.n, mean: Math.round(t.sum / t.n), max: t.max, last: t.last}

export ringOffset = (self, other) ->
  return null unless self in LINKED_IDS and other in LINKED_IDS
  k = (other - self + 5) % 5
  if k == 0 then null else k

export inputBitFor = (self, other, outBit) ->
  k = ringOffset(self, other)
  return null unless k?
  for link in LINKS when DISCRETE_OUT_BITS[link.out] == outBit
    return DISCRETE_BITS.A["#{link.input}#{k}"]
  null

export inputMaskFor = (self, other) ->
  k = ringOffset(self, other)
  return 0 unless k?
  mask = 0
  for link in LINKS
    mask = (mask | bitMask(DISCRETE_BITS.A["#{link.input}#{k}"])) >>> 0
  mask

export inputImageFor = (self, other, value) ->
  k = ringOffset(self, other)
  return 0 unless k?
  image = 0
  for link in LINKS when value & bitMask(DISCRETE_OUT_BITS[link.out])
    image = (image | bitMask(DISCRETE_BITS.A["#{link.input}#{k}"])) >>> 0
  image

export sourceOf = (self, inBit) ->
  return null unless self in LINKED_IDS
  for link in LINKS
    for k in [1..4]
      name = "#{link.input}#{k}"
      continue unless DISCRETE_BITS.A[name] == inBit
      return { gpc: ((self - 1 + k) % 5) + 1, outBit: DISCRETE_OUT_BITS[link.out],
               out: link.out, inBit: inBit, input: name }
  null

export linksInto = (self) ->
  links = []
  for b in [0...32]
    s = sourceOf(self, b)
    links.push(s) if s?
  links

# `drive(bit, level)` receives register A changes.  `clock()` returns
# simulated microseconds; without it, changes land as datagrams arrive.
export class GpcLinks
  constructor: (self, drive, clock = null) ->
    @self = resolveGpcId(self)
    @drive = drive
    @clock = clock
    @others = {}
    @queued = 0
    return unless @self in LINKED_IDS
    for other in LINKED_IDS when other != @self
      @others[other] =
        gpc: other
        out: 0
        missed: 0
        pending: []
        lastTimeUs: null
        lastDueUs: null
        cross: tally()
        held: tally()
        bus: new DiscreteBus other, (m, gpc) => @hear(gpc, m)
    @_poll = setInterval call(@, 'poll'), POLL_MS
    @_poll.unref?()
    @poll()

  ready: () ->
    Promise.all(o.bus.ready() for own id, o of @others)

  close: () ->
    clearInterval @_poll if @_poll?
    @_poll = null
    o.bus.close() for own id, o of @others
    @others = {}
    @queued = 0
    return

  heard: () ->
    (({gpc: +id, out: o.out, lost: o.missed >= LOST_AFTER,
       cross: tallyOf(o.cross), held: tallyOf(o.held)}) for own id, o of @others)

  # VALUE marks the sender live; SET and RESET carry changes.
  hear: (gpc, m) ->
    o = @others[gpc]
    return unless o? and m? and m.reg == REG_OUT
    return unless m.op in [SET, RESET, VALUE]
    o.missed = 0 if m.op == VALUE
    if m.wallUs?
      age = (wallNowUs() - m.wallUs) | 0
      note(o.cross, age) if 0 <= age <= CROSS_MAX_US
    now = @clock?()
    unless now? and m.timeUs?
      @flush(o)
      o.lastTimeUs = null
      @land gpc, m
      return
    delta = if o.lastTimeUs? then ((m.timeUs - o.lastTimeUs) | 0) else null
    due = if delta? and 0 <= delta <= HOLD_MAX_US then o.lastDueUs + delta else now
    due = now if due < now
    due = now + HOLD_MAX_US if due > now + HOLD_MAX_US
    o.lastTimeUs = m.timeUs
    o.lastDueUs = due
    note(o.held, due - now)
    if due <= now and o.pending.length == 0
      @land gpc, m
    else
      o.pending.push {due, m}
      @queued += 1
    return

  deliver: (now) ->
    return unless @queued > 0
    for own id, o of @others
      while o.pending.length > 0 and o.pending[0].due <= now
        @land o.gpc, o.pending.shift().m
        @queued -= 1
    return

  flush: (o) ->
    while o.pending.length > 0
      @land o.gpc, o.pending.shift().m
      @queued -= 1
    return

  land: (gpc, m) ->
    @apply gpc, applyDiscrete(@others[gpc].out, m)
    return

  apply: (gpc, value) ->
    o = @others[gpc]
    changed = ((o.out ^ value) >>> 0)
    o.out = value >>> 0
    return unless changed
    for link in LINKS
      ob = DISCRETE_OUT_BITS[link.out]
      continue unless changed & bitMask(ob)
      @drive inputBitFor(@self, gpc, ob), (value & bitMask(ob)) != 0
    return

  poll: () ->
    for own id, o of @others
      o.missed += 1
      if o.missed >= LOST_AFTER
        @flush(o)
        o.lastTimeUs = null
        @apply(+id, 0)
      o.bus.request(REG_OUT)
    return
