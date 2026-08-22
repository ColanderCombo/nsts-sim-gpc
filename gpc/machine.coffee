# Machine models: main-storage geometry per AP-101 variant.
#
# The two GPC generations differ in how much store they have and how it is
# packaged, and an FCM image is only meaningful against the right one:
#
#   AP-101B  64K words, split across two LRUs -- 40K in the CPU, 24K in the
#            IOP, presented to both as one contiguous space
#            (IBM-74-A31-016/p.20, 1.1.4 PACKAGING).
#
#   AP-101S  19-bit addressing over 524,288 halfwords = 256K words
#            (IBM-85-C67-001).  The same note records that only the first
#            256KHW -- those with the most significant CPU address bit 0 --
#            are addressable by the IOP; that restriction is about
#            addressability, not where the store lives, and is not modeled
#            here.  We carry the S store as one unit in the CPU LRU.
#
# Sizes are fullword counts, which is what the MCM constructor takes.
#
# `fp` is the machine's extended-precision floating point behaviour, which
# differs between the two: the same MED or DED gives different low-order
# results, and self-test software distinguishes them.  'B' is the AP-101
# C/M rule (IBM-6246156B 8-25: operands truncated to 31 fraction bits and
# rounded in from the 32nd, a 62-bit product, truncate to 56); 'S' is
# IBM-85-C67-001's (three most significant fullword partial products summed
# to 68 bits, truncate to 56).

fs   = require 'fs'
path = require 'path'

export MACHINES =
  ap101b:
    name: 'AP-101B'
    cpuWords: 40 * 1024
    iopWords: 24 * 1024
    fp: 'B'
  ap101s:
    name: 'AP-101S'
    cpuWords: 256 * 1024
    iopWords: 0
    fp: 'S'

# The flight software this simulator exists to run is AP-101S.
export DEFAULT_MACHINE = 'ap101s'

# Accepts the key in any case and with an optional '-' ('AP-101S',
# 'ap101s').  Throws on an unknown name rather than sizing memory wrong.
export resolveMachine = (name) ->
  return MACHINES[DEFAULT_MACHINE] unless name?
  key = String(name).toLowerCase().replace(/-/g, '')
  m = MACHINES[key]
  if not m?
    known = Object.keys(MACHINES).join(', ')
    throw new Error("unknown machine model '#{name}' (known: #{known})")
  return m

# commander parser for --machine: reject a bad name at parse time with the
# same FATAL-and-exit shape the other model option (--cpu-model) uses,
# rather than letting the constructor throw a stack trace at the user.
export parseMachineOption = (v) ->
  try
    resolveMachine(v)
  catch e
    process.stderr.write "FATAL: --machine must be one of: #{Object.keys(MACHINES).join(', ')}\n"
    process.exit(1)
  return v

# Main storage in halfwords.  Both MCMs are one address space (MemoryBus).
export machineHalfwords = (m) -> (m.cpuWords + m.iopWords) * 2

# An FCM is a flat image of main storage from address 0, so its size alone
# decides whether it fits: an odd byte count is not a memory image, and one
# larger than the machine is the wrong image or the wrong --machine.
# Neither is recoverable further in, since a partial load would run as
# though it were whole, so frontends call this before opening anything and
# the loader downstream copies without checking.  The stat also stands in
# for opening the file, so an unreadable path fails here too.
export checkFCMFits = (fcmPath, machineName) ->
  return unless fcmPath?
  name = path.basename(fcmPath)
  unreadable = (why) ->
    process.stderr.write "FATAL: cannot read #{fcmPath}: #{why}\n"
    process.exit(1)
  try
    st = fs.statSync(fcmPath)
  catch e
    unreadable(if e.code == 'ENOENT' then 'no such file' else (e.code ? e.message))
  unreadable 'not a file' unless st.isFile()
  try
    fs.accessSync(fcmPath, fs.constants.R_OK)
  catch e
    unreadable 'permission denied'
  bytes = st.size
  if bytes % 2
    process.stderr.write "FATAL: #{name} is #{bytes} bytes; a memory image is halfwords\n"
    process.exit(1)
  machine = resolveMachine(machineName)
  capacity = machineHalfwords(machine)
  if bytes / 2 > capacity
    process.stderr.write "FATAL: #{name} is #{bytes / 2} halfwords; " +
                         "#{machine.name} main storage holds #{capacity}\n"
    process.exit(1)
  return
