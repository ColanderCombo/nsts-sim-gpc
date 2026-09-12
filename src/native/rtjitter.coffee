# UDP and timer latency under a GPC-like compute/wait duty cycle.
#
#   coffee native/rtjitter.coffee pong <port> [seconds]
#   coffee native/rtjitter.coffee ping <myport> <peerport> [seconds]
#   coffee native/rtjitter.coffee timer [count]  how late a 1 ms timer fires
#
# NSTS_SCHED names the policy every role applies to its thread; the
# policies are native/rtpolicy.coffee.  NSTS_BURN_US and NSTS_PERIOD_US set
# the duty cycle, 300 and 1000 by default.
#
dgram = require('dgram')

applyPolicy = require('./rtpolicy.coffee').apply

BURN_US = Number(process.env.NSTS_BURN_US or 300)
PERIOD_US = Number(process.env.NSTS_PERIOD_US or 1000)

# Retain the result to prevent dead-code elimination.
sink = 0
burn = (us) ->
  end = process.hrtime.bigint() + BigInt(Math.round(us * 1000))
  while process.hrtime.bigint() < end
    sink = (sink * 1103515245 + 12345) & 0x7fffffff for i in [0...256]
  return

burnUs = []

# Match RTPacer's timer choice at each period boundary.
duty = ->
  t0 = process.hrtime.bigint()
  burn(BURN_US)
  spent = Number(process.hrtime.bigint() - t0) / 1000
  burnUs.push(spent)
  left = PERIOD_US - spent
  if left > 1000 then setTimeout(duty, Math.floor(left / 1000)) else setImmediate(duty)
  return

stats = (xs) ->
  return 'no samples' unless xs.length
  sorted = Float64Array.from(xs).sort()
  at = (q) -> sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))]
  over = (threshold) -> sorted.filter((value) -> value > threshold).length
  [
    "n #{sorted.length}"
    "p50 #{at(0.5).toFixed(0)}us"
    "p99 #{at(0.99).toFixed(0)}us"
    "p99.9 #{at(0.999).toFixed(0)}us"
    "max #{sorted[sorted.length - 1].toFixed(0)}us"
    ">1ms #{over(1000)}"
    ">2ms #{over(2000)}"
    ">4ms #{over(4000)}"
  ].join('  ')

role = process.argv[2]

# Lateness of an otherwise idle setTimeout(1).
if role == 'timer'
  want = Number(process.argv[3] or 5000)
  late = []
  console.log(applyPolicy())
  tick = ->
    t0 = process.hrtime.bigint()
    setTimeout((->
      late.push(Number(process.hrtime.bigint() - t0) / 1000 - 1000)
      return tick() if late.length < want
      console.log("late by #{process.env.NSTS_SCHED or 'off'}: #{stats(late)}")
    ), 1)
  return tick()

sock = dgram.createSocket('udp4')

if role == 'pong'
  port = Number(process.argv[3])
  secs = Number(process.argv[4] or 30)
  sock.on('message', (msg, rinfo) -> sock.send(msg, rinfo.port, '127.0.0.1'))
  sock.bind port, '127.0.0.1', ->
    console.log("pong on #{port}: #{applyPolicy()}")
    duty()
    setTimeout((-> process.exit(0)), (secs + 5) * 1000)
else if role == 'ping'
  myport = Number(process.argv[3])
  peer = Number(process.argv[4])
  secs = Number(process.argv[5] or 30)
  rtt = []
  buf = Buffer.alloc(8)
  sock.on 'message', (msg) ->
    rtt.push(Number(process.hrtime.bigint() - msg.readBigUInt64LE(0)) / 1000)
  sock.bind myport, '127.0.0.1', ->
    console.log("ping #{myport}->#{peer}: #{applyPolicy()}")
    duty()
    send = ->
      buf.writeBigUInt64LE(process.hrtime.bigint(), 0)
      sock.send(Buffer.from(buf), peer, '127.0.0.1')
    iv = setInterval(send, 5)
    setTimeout((->
      clearInterval(iv)
      tag = process.env.NSTS_SCHED or 'off'
      console.log("round trip #{tag}: #{stats(rtt)}")
      console.log("chunk      #{tag}: #{stats(burnUs)}")
      process.exit(0)
    ), secs * 1000)
else
  console.error('usage: rtjitter.coffee pong <port> [secs] | ping <myport> <peer> [secs]')
  process.exit(2)
