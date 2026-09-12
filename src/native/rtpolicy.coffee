# Event-loop scheduling policy selected by --sched or NSTS_SCHED:
#
#   off     the timeshare band, as Node leaves it
#   qos     user-interactive, with the task's timers at latency tier 1
#   fixed   priority 63, the top of the timeshare band, no priority decay,
#           timers at latency tier 1
#   rt      the realtime band: priority 97, no timer coalescing, ahead of
#           every timeshare thread on the machine
#
# `fixed` is the default.  Realtime parameters use NSTS_SCHED_PERIOD_US,
# NSTS_SCHED_COMP_US, and NSTS_SCHED_CONSTRAINT_US.  Fixed precedence uses
# NSTS_SCHED_IMPORTANCE.
#
# A thread carrying a QoS class refuses THREAD_LATENCY_QOS_POLICY, and a
# thread carrying a latency tier refuses a QoS class.  `qos` applies latency
# to the task; `fixed` applies it to the thread.
path = require('path')

QOS_USER_INTERACTIVE = 0x21

# The priority band a realtime thread runs in; below it, the kernel's
# failsafe has demoted the thread for overrunning its computation.
RT_BAND = 97

DEFAULT_POLICY = 'fixed'

machrt = null
loadError = null
applied = null

load = ->
  return machrt if machrt or loadError
  candidates = [
    process.env.NSTS_NATIVE and path.join(process.env.NSTS_NATIVE, 'machrt.node')
    path.join(__dirname, 'machrt.node')
    path.join(__dirname, '..', 'native', 'machrt.node')
    path.join(process.cwd(), 'build', 'native', 'machrt.node')
    path.join(process.cwd(), 'ext', 'sim', 'build', 'native', 'machrt.node')
  ].filter(Boolean)
  for candidate in candidates
    try
      machrt = require(candidate)
      return machrt
    catch error
      loadError = error
  null

num = (name, dflt) ->
  value = process.env[name]
  if not value? or value == '' then dflt else Number(value)

apply = (name) ->
  want = String(name or process.env.NSTS_SCHED or DEFAULT_POLICY).toLowerCase()
  applied = {policy: want, set: false}
  if want == 'off'
    applied.set = true
    return 'sched off'
  addon = load()
  unless addon
    applied.error = loadError and loadError.message
    return "sched #{want} unavailable"

  ok = false
  if want == 'qos'
    ok = addon.setQosClass(QOS_USER_INTERACTIVE, 0) == 0
    ok = addon.setTaskLatencyQos(1) == 0 and ok
  else if want == 'fixed'
    ok = addon.setLatencyQos(1) == 0
    ok = addon.setTimeshare(false) == 0 and ok
    ok = addon.setPrecedence(num('NSTS_SCHED_IMPORTANCE', 63)) == 0 and ok
  else if want == 'rt'
    ok = addon.setRealtime(
      periodUs: num('NSTS_SCHED_PERIOD_US', 1000)
      computationUs: num('NSTS_SCHED_COMP_US', 500)
      constraintUs: num('NSTS_SCHED_CONSTRAINT_US', 1000)
      preemptible: num('NSTS_SCHED_PREEMPTIBLE', 1) != 0
    ) == 0
  else
    applied.error = 'unknown policy'
    return "sched #{want} unknown"
  applied.set = ok
  info = addon.info()
  "sched #{want} #{if ok then 'set' else 'refused'}, priority #{info.curPri}" +
    if want == 'rt' then ", #{info.computationUs} of every #{info.periodUs} us" else ''

status = ->
  addon = load()
  info = if addon then addon.info() else null
  result = Object.assign({available: !!addon}, applied)
  if info
    result.curPri = info.curPri
    result.basePri = info.basePri
    result.timeshare = info.timeshare
    if applied and applied.policy == 'rt'
      result.periodUs = info.periodUs
      result.computationUs = info.computationUs
      result.demoted = info.curPri < RT_BAND
  result

module.exports = {apply, status, load, DEFAULT_POLICY}
