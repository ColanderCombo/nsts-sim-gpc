# The session's simulated clock as a barrier
#
# Each paced machine publishes its session time and stays within `delta` of
# the least advanced peer.  This is bounded-lag conservative simulation.
#
# `--barrier`, or NSTS_SIM_BARRIER, is delta in microseconds; off, the
# default, leaves every machine free.
#
# A machine's simulated clock starts at zero, so it publishes that clock
# plus an offset taken as it joins: from the
# machines already on the barrier, and from the wall clock when it is
# the first.  Times are microseconds in a 32-bit word compared as signed
# differences, which carries the wrap every 71.6 minutes.
#
# The table is header words 80 to 111 of the shared-memory segment
# (com/busshm.coffee), eight slots of four words:
#
#     0   pid, taken by compare-and-exchange, 0 while the slot is free
#     1   the session simulated time this machine has reached, us
#     2   the wall microsecond it last published (com/bus wallNowUs)
#     3   which computer it is
#
# A stopped machine releases its slot.  Dead processes are reaped, and
# peers ignore slots that have not published for STALE_US.
#
# Only a paced machine joins (gpc/runharness.coffee, gpc/cmd/cmd_run.coffee).
# A reactive process -- an LRU, a display -- publishes nothing and is
# waited for by nobody.

import {busSettings, wallNowUs} from 'com/bus'

H_BARRIER = 80
SLOTS = 8
SLOT_WORDS = 4
B_PID = 0
B_SIM_US = 1
B_WALL_US = 2
B_WHO = 3

# Maximum publication age used by barrier calculations.
STALE_US = 500000

# Peer-table rescan interval.
SCAN_US = 20000

settings = {deltaUs: 0}

# --barrier, or NSTS_SIM_BARRIER: delta in microseconds, or off.
export configureBarrier = ({barrier} = {}) ->
  raw = String(barrier ? process.env.NSTS_SIM_BARRIER ? 'off').trim()
  if raw is '' or raw is 'off'
    settings.deltaUs = 0
  else
    v = Number(raw)
    unless Number.isFinite(v) and v >= 0
      throw new Error("invalid barrier '#{raw}'")
    settings.deltaUs = Math.round(v)
  settings

try
  configureBarrier()
catch e
  console.error("barrier: #{e.message}")
  process.exit(2)

export deltaUs = () -> settings.deltaUs

busshm = null
shmTried = false
loadShm = () ->
  return busshm if busshm?
  return null if shmTried
  shmTried = true
  return null if typeof window isnt 'undefined'
  try
    busshm = require './busshm'
  catch e
    console.error "barrier: shared memory unavailable, #{e.message}"
  busshm

localUs = (simNs) -> Math.round(simNs / 1000) | 0

claimed = new Set()

export class Barrier
  constructor: (@who = 0) ->
    @deltaUs = settings.deltaUs
    @hdr = null
    @word = -1
    @offsetUs = 0
    @simUs = 0
    @peerWords = []
    @scannedUs = 0
    @holds = 0                  # times this machine came to a stop here
    @heldUs = 0                 # wall time it stood at them
    @heldSinceUs = null

  join: (simNs) ->
    return true if @word >= 0
    return false unless @deltaUs > 0
    mod = loadShm()
    return false unless mod?
    seg = mod.attach(busSettings.basePort)
    return false unless seg?
    @hdr = seg.hdr
    @word = @claim(mod)
    return false if @word < 0
    Atomics.store(@hdr, @word + B_WHO, @who)
    @scan()
    peer = @peerTime()
    @offsetUs = ((peer ? (wallNowUs() | 0)) - localUs(simNs)) | 0
    @publish(simNs)
    unless @atExit?
      @atExit = () => @leave()
      process.on('exit', @atExit)
    true

  leave: () ->
    return unless @word >= 0
    Atomics.store(@hdr, @word + B_PID, 0)
    claimed.delete(@word)
    @word = -1
    @peerWords = []
    @heldSinceUs = null
    return

  claim: (mod) ->
    for i in [0...SLOTS]
      w = H_BARRIER + i * SLOT_WORDS
      continue if claimed.has(w)
      held = Atomics.load(@hdr, w + B_PID)
      continue if held isnt 0 and held isnt process.pid and mod.alive(held)
      continue unless Atomics.compareExchange(@hdr, w + B_PID, held, process.pid) is held
      claimed.add(w)
      return w
    -1

  scan: () ->
    @scannedUs = wallNowUs() | 0
    words = []
    for i in [0...SLOTS]
      w = H_BARRIER + i * SLOT_WORDS
      continue if w is @word
      words.push(w) if Atomics.load(@hdr, w + B_PID) > 0
    @peerWords = words
    return

  peerTime: () ->
    now = wallNowUs() | 0
    best = null
    for w in @peerWords
      continue if ((now - Atomics.load(@hdr, w + B_WALL_US)) | 0) > STALE_US
      t = Atomics.load(@hdr, w + B_SIM_US)
      best = t if not best? or ((t - best) | 0) > 0
    best

  publish: (simNs) ->
    @simUs = (localUs(simNs) + @offsetUs) | 0
    Atomics.store(@hdr, @word + B_SIM_US, @simUs)
    Atomics.store(@hdr, @word + B_WALL_US, wallNowUs() | 0)
    return

  allowanceUs: () ->
    now = wallNowUs() | 0
    @scan() if ((now - @scannedUs) | 0) > SCAN_US
    room = Infinity
    for w in @peerWords
      continue if ((now - Atomics.load(@hdr, w + B_WALL_US)) | 0) > STALE_US
      d = ((Atomics.load(@hdr, w + B_SIM_US) - @simUs) | 0) + @deltaUs
      room = d if d < room
    room

  step: (simNs) ->
    return false unless @word >= 0
    @publish(simNs)
    if @allowanceUs() > 0
      if @heldSinceUs?
        @heldUs += ((wallNowUs() | 0) - @heldSinceUs) | 0
        @heldSinceUs = null
      return false
    unless @heldSinceUs?
      @heldSinceUs = wallNowUs() | 0
      @holds += 1
    true

  allowanceNs: (simNs) ->
    return Infinity unless @word >= 0
    @publish(simNs)
    room = @allowanceUs()
    if room is Infinity then Infinity else Math.max(0, room * 1000)

  report: () ->
    rows = if @word >= 0 then slotRows(@hdr) else []
    r.aheadUs = ((r.simUs - @simUs) | 0) for r in rows
    r.self = (r.pid is process.pid) for r in rows
    deltaUs: @deltaUs
    joined: @word >= 0
    simUs: @simUs
    holds: @holds
    heldMs: @heldUs / 1000
    peers: rows

slotRows = (hdr) ->
  now = wallNowUs() | 0
  rows = []
  for i in [0...SLOTS]
    w = H_BARRIER + i * SLOT_WORDS
    pid = Atomics.load(hdr, w + B_PID)
    continue unless pid > 0
    rows.push {
      pid: pid
      who: Atomics.load(hdr, w + B_WHO)
      simUs: Atomics.load(hdr, w + B_SIM_US)
      ageUs: ((now - Atomics.load(hdr, w + B_WALL_US)) | 0)
    }
  rows

export describe = (hdr) ->
  rows = slotRows(hdr)
  return rows unless rows.length
  lead = rows.reduce(((a, r) -> if ((r.simUs - a.simUs) | 0) > 0 then r else a), rows[0])
  r.behindUs = ((lead.simUs - r.simUs) | 0) for r in rows
  rows
