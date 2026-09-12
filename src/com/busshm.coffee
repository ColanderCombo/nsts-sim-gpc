# The session's busses in shared memory
#
# One POSIX shared-memory segment holds datagram slots tagged by bus and
# writer.  Each reader walks the sequence from its last position.  Payloads
# use the UDP framing from com/bus.civet.
#
# GPCs poll from their instruction loops; other processes use a millisecond
# timer.
#
# The segment is `/nsts2.<base port>`, sized SLOTS x SLOT_BYTES plus the
# header.  It persists until `gpc shm --unlink` or a reboot.  New readers
# begin at the current sequence.
#
# Header, 32-bit words:
#
#     0   magic, written last by the process that laid the ring out
#     1   slot count
#     2   bytes a slot
#     3   the sequence counter every writer claims a slot from
#     4   the writer-id counter every Bus takes an id from
#     16..79  the pid of each process on the ring, taken on the first
#         ring it opens and left for the next process to reap
#     80..111 the paced machines' barrier (com/simbarrier.coffee)
#
# Slot, 32-bit words then bytes:
#
#     0   the sequence this slot holds, stored last: a slot whose word 0
#         is not the sequence the reader wants has not been published
#     1   writer id, which is how a writer skips what it wrote
#     2   bus offset (com/bus.civet busConfig)
#     3   payload length in bytes
#     16.. the payload
#
# A writer that laps a reader overwrites what the reader had not taken;
# the reader counts the loss in `drops`, as a socket counts an overflow.

path = require 'path'

MAGIC = 0x4e534232                # 'NSB2'
MAGIC_CLAIMED = 0x4e534200

HDR_WORDS = 128
H_MAGIC = 0
H_SLOTS = 1
H_SLOT_BYTES = 2
H_SEQ = 3
H_NEXT_ID = 4
H_MEMBERS = 16
MEMBERS_MAX = 64

SLOT_HDR_WORDS = 4
SLOT_HDR = SLOT_HDR_WORDS * 4
S_SEQ = 0
S_WRITER = 1
S_BUS = 2
S_LEN = 3

# 4096 slots of 2 kB: eight megabytes for the session, and about a second
# of slots before one is reused with every bus of a session on the ring.
export SLOTS = Number(process.env.NSTS_SHM_SLOTS ? 4096)
export SLOT_BYTES = Number(process.env.NSTS_SHM_SLOT_BYTES ? 2048)
PAYLOAD_MAX = SLOT_BYTES - SLOT_HDR

addon = null
addonError = null

loadAddon = () ->
  return addon if addon? or addonError?
  candidates = [
    path.join(__dirname, '..', 'native', 'shmring.node')
    path.join(process.cwd(), 'build', 'native', 'shmring.node')
    path.join(process.cwd(), 'ext', 'sim', 'build', 'native', 'shmring.node')
  ]
  candidates.unshift(path.join(process.env.NSTS_NATIVE, 'shmring.node')) if process.env.NSTS_NATIVE
  for c in candidates
    try
      addon = require c
      return addon
    catch e
      addonError = e
  null

# `stalled` forces another poll when a claimed slot is not yet published.
segment = null
readers = []
drainTimer = null
polling = false
stalled = false
lastHead = null

segmentName = (basePort) -> "/nsts2.#{basePort}"

# Whether a pid is still there.  A process of another user answers EPERM,
# which is an answer that it is.
export alive = (pid) ->
  return false unless pid > 0
  try
    process.kill(pid, 0)
    true
  catch e
    e.code == 'EPERM'

# Take a place in the member table, reusing the place of a process that
# has gone.  A full table leaves this process unlisted and carries its
# traffic as usual.
joinMembers = (hdr) ->
  for i in [0...MEMBERS_MAX]
    w = H_MEMBERS + i
    held = Atomics.load(hdr, w)
    continue if held != 0 and held != process.pid and alive(held)
    return w if Atomics.compareExchange(hdr, w, held, process.pid) == held
  -1

export members = (hdr = segment?.hdr) ->
  return [] unless hdr?
  live = []
  for i in [0...MEMBERS_MAX]
    w = H_MEMBERS + i
    pid = Atomics.load(hdr, w)
    continue unless pid > 0
    if alive(pid) then live.push(pid) else Atomics.compareExchange(hdr, w, pid, 0)
  live

export unlinkSegment = (basePort) ->
  a = loadAddon()
  return -1 unless a?
  a.unlink(segmentName(basePort))

# Map the segment, returning null when the addon is unavailable.
openSegment = (basePort) ->
  return segment if segment?
  a = loadAddon()
  return null unless a?
  bytes = HDR_WORDS * 4 + SLOTS * SLOT_BYTES
  {buffer} = a.open(segmentName(basePort), bytes)
  hdr = new Int32Array(buffer, 0, HDR_WORDS)
  # A fresh segment reads zero throughout; one process claims the layout
  # and the rest wait for the magic it writes when the layout is there.
  if Atomics.compareExchange(hdr, H_MAGIC, 0, MAGIC_CLAIMED) == 0
    Atomics.store hdr, H_SLOTS, SLOTS
    Atomics.store hdr, H_SLOT_BYTES, SLOT_BYTES
    Atomics.store hdr, H_MAGIC, MAGIC
  else
    for i in [0...100000]
      break if Atomics.load(hdr, H_MAGIC) == MAGIC
    if Atomics.load(hdr, H_MAGIC) != MAGIC
      throw new Error("shm ring #{segmentName(basePort)} has no layout")
  slots = Atomics.load(hdr, H_SLOTS)
  slotBytes = Atomics.load(hdr, H_SLOT_BYTES)
  if slots != SLOTS or slotBytes != SLOT_BYTES
    throw new Error("shm ring #{segmentName(basePort)} is #{slots}x#{slotBytes}, " +
                    "expected #{SLOTS}x#{SLOT_BYTES}")
  segment = {
    buffer: buffer
    hdr: hdr
    i32: new Int32Array(buffer)
    bytes: new Uint8Array(buffer)
    slots: slots
    slotBytes: slotBytes
    base: HDR_WORDS * 4
    name: segmentName(basePort)
  }
  joinMembers(hdr)
  segment

export class BusRing
  constructor: (@busOffset) ->
    @seg = segment
    @writerId = Atomics.add(@seg.hdr, H_NEXT_ID, 1) + 1
    @cursor = Atomics.load(@seg.hdr, H_SEQ)
    @drops = 0
    @oversize = 0
    @sent = 0
    @received = 0
    @onData = null
    readers.push this

  close: () ->
    i = readers.indexOf this
    readers.splice(i, 1) if i >= 0
    @onData = null
    return

  resetCursor: () ->
    @cursor = Atomics.load(@seg.hdr, H_SEQ)
    return

  slotWord: (seq) -> (@seg.base + (seq %% @seg.slots) * @seg.slotBytes) >> 2

  # Put a datagram in the ring.  The sequence is claimed first and the
  # slot published last, so a reader reading the sequence it wants has the
  # whole slot.
  push: (buf, len) ->
    if len > PAYLOAD_MAX
      @oversize += 1
      return false
    seq = Atomics.add(@seg.hdr, H_SEQ, 1) + 1
    w = @slotWord(seq)
    @seg.i32[w + S_WRITER] = @writerId
    @seg.i32[w + S_BUS] = @busOffset
    @seg.i32[w + S_LEN] = len
    @seg.bytes.set(buf.subarray(0, len), (w << 2) + SLOT_HDR)
    Atomics.store @seg.i32, w + S_SEQ, seq
    @sent += 1
    true

  # Every slot published since the last call that is on this bus and was
  # not written here.  The callback gets a view into the slot, which the
  # next lap overwrites: take a copy of anything that outlives the call.
  drain: (head = Atomics.load(@seg.hdr, H_SEQ)) ->
    return 0 if head == @cursor
    if head - @cursor > @seg.slots - 1
      @drops += head - @cursor - (@seg.slots - 1)
      @cursor = head - (@seg.slots - 1)
    n = 0
    while @cursor < head
      next = @cursor + 1
      w = @slotWord(next)
      # A writer that has claimed this sequence and not yet published it
      # holds the reader here; the rest of the ring waits for it, and the
      # next poll runs whether or not the ring has grown.
      unless Atomics.load(@seg.i32, w + S_SEQ) == next
        stalled = true
        break
      @cursor = next
      continue unless @seg.i32[w + S_BUS] == @busOffset
      continue if @seg.i32[w + S_WRITER] == @writerId
      len = @seg.i32[w + S_LEN]
      @received += 1
      n += 1
      @onData?(Buffer.from(@seg.buffer, (w << 2) + SLOT_HDR, len))
    n

export attach = (basePort) -> openSegment(basePort)

export openRing = (basePort, busOffset) ->
  return null unless openSegment(basePort)?
  ring = new BusRing(busOffset)
  startDrainTimer()
  ring

# Drain every open ring from the shared sequence.
export pollRings = () ->
  # A GPC polls from inside its instruction loop and a handler runs
  # there, so a handler that reaches another poll finds this closed.
  return 0 if polling or not segment?
  head = Atomics.load(segment.hdr, H_SEQ)
  return 0 if head == lastHead and not stalled
  polling = true
  stalled = false
  n = 0
  try
    for r in readers
      n += r.drain(head)
  finally
    polling = false
    lastHead = head
  n

DRAIN_MS = Number(process.env.NSTS_SHM_DRAIN_MS ? 1)

startDrainTimer = () ->
  return if drainTimer?
  drainTimer = setInterval pollRings, DRAIN_MS
  drainTimer.unref?()
  return

export stats = () ->
  sum = (f) -> readers.reduce(((a, r) -> a + f(r)), 0)
  name: segment?.name ? null
  rings: readers.length
  sent: sum (r) -> r.sent
  received: sum (r) -> r.received
  drops: sum (r) -> r.drops
  oversize: sum (r) -> r.oversize

export available = () -> loadAddon()?

export inspect = (basePort) ->
  a = loadAddon()
  throw new Error('no shared-memory addon: build/native/shmring.node') unless a?
  bytes = HDR_WORDS * 4 + SLOTS * SLOT_BYTES
  {buffer} = a.open(segmentName(basePort), bytes, false)
  hdr = new Int32Array(buffer, 0, HDR_WORDS)
  name: segmentName(basePort)
  bytes: bytes
  slots: Atomics.load(hdr, H_SLOTS)
  slotBytes: Atomics.load(hdr, H_SLOT_BYTES)
  written: Atomics.load(hdr, H_SEQ)
  writers: Atomics.load(hdr, H_NEXT_ID)
  members: members(hdr)
  hdr: hdr
