# Machine models: main-storage geometry per AP-101 variant.
#
#   AP-101B  64K words, split across two LRUs -- 40K in the CPU, 24K in the
#            IOP, presented to both as one contiguous space
#            (IBM-74-A31-016/p.20, 1.1.4 PACKAGING).
#
#   AP-101S  19-bit addressing over 524,288 halfwords = 256K words
#            (IBM-85-C67-001).  The same note records that only the first
#            256KHW -- those with the most significant CPU address bit 0 --
#            are addressable by the IOP
#
# Sizes are fullword counts.
#
fs   = require 'fs'
path = require 'path'

export MACHINES =
  ap101b:
    name: 'AP-101B'
    cpuWords: 40 * 1024
    iopWords: 24 * 1024
    model: 'B'
  ap101s:
    name: 'AP-101S'
    cpuWords: 256 * 1024
    iopWords: 0
    model: 'S'

export DEFAULT_MACHINE = 'ap101s'

export resolveMachine = (name) ->
  return MACHINES[DEFAULT_MACHINE] unless name?
  key = String(name).toLowerCase().replace(/-/g, '')
  m = MACHINES[key]
  if not m?
    known = Object.keys(MACHINES).join(', ')
    throw new Error("unknown machine model '#{name}' (known: #{known})")
  return m

export parseMachineOption = (v) ->
  try
    resolveMachine(v)
  catch e
    process.stderr.write "FATAL: --machine must be one of: #{Object.keys(MACHINES).join(', ')}\n"
    process.exit(1)
  return v

# --cpu-model takes the same names as --machine and answers with the
# model letter the CPU carries.
export parseCPUModelOption = (v) ->
  try
    return resolveMachine(v).model
  catch e
    process.stderr.write "FATAL: --cpu-model must be one of: #{Object.keys(MACHINES).join(', ')}\n"
    process.exit(1)

# Main storage in halfwords.  Both MCMs are one address space (MemoryBus).
export machineHalfwords = (m) -> (m.cpuWords + m.iopWords) * 2

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
