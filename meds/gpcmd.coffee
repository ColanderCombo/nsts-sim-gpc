# gpcmd — send GPC->IDP command traffic onto the simulated DK busses.
#
# Stands in for a GPC driving an IDP (DEU protocol) until the AP-101
# IOP/BCE integration takes over.  Each IDP listens on its own
# Display/Keyboard bus (IDP1 -> DK1, ... IDP4 -> DK4).
#
# Sim wire format (see meds/idp.coffee recvDK):
#   data16[0] = opcode (1..9, DEU protocol)
#   data16[1..] / data8[2..] = payload
#
#   op 1 DATA FILL  payload bytes = FCW stream (same content as a .dfb)
#   op 2 TIME FILL  met seconds (32b: hi,lo), crt seconds (32b: hi,lo)
#   op 6 RESET SPL  no payload
#
# Usage (via GPCMD.sh, which rebuilds first):
#   GPCMD.sh fill data/TEST-9011-GPC_MEMORY.dfb --idp 1
#   GPCMD.sh time --idp 1 --interval 1
#   GPCMD.sh time --met 2/03:45:00 --interval 1
#   GPCMD.sh resetspl
#   GPCMD.sh raw 5 0001 00ff
#   GPCMD.sh watch DK1

import * as fs from 'fs'
import {Bus, BusMsg, busConfig} from '../com/bus.civet.jsx'
{Command} = require 'commander'
process = require 'process'

# UDP bind is async and the bus doesn't expose completion — give the
# socket a beat to join the multicast group before sending, and a beat
# after so the datagram leaves before the (unref'd) socket would close.
BIND_MS = 150
LINGER_MS = 250

openBus = (name, forSend=false) ->
  if name not of busConfig
    console.error "gpcmd: unknown bus '#{name}' (try DK1..DK4, FC1..FC4, _IDP1..)"
    process.exit(2)
  bus = new Bus(name, busConfig[name])
  # swallow our own multicast loopback on send-only buses
  bus.onReceive (->), null if forSend
  bus

dkBusForIDP = (o) ->
  n = parseInt(o.idp, 10)
  if not (1 <= n <= 4)
    console.error "gpcmd: --idp must be 1..4"
    process.exit(2)
  openBus("DK#{n}", true)

sendMsgs = (bus, makeMsg, o) ->
  intervalS = parseFloat(o.interval ? '0')
  fire = -> bus.sendMsg makeMsg()
  setTimeout ->
    fire()
    if intervalS > 0
      setInterval fire, intervalS*1000
    else
      setTimeout (-> process.exit(0)), LINGER_MS
  , BIND_MS

# "d/hh:mm:ss" -> seconds
parseTimeStr = (s) ->
  m = s.match /^(\d+)\/(\d+):(\d+):(\d+)$/
  if not m
    console.error "gpcmd: bad time '#{s}' (want d/hh:mm:ss)"
    process.exit(2)
  (((parseInt(m[1])*24 + parseInt(m[2]))*60 + parseInt(m[3]))*60 + parseInt(m[4]))

# current day-of-year clock in seconds (matches the IDP's local test fill)
nowYearSecs = ->
  now = new Date(Date.now())
  jan1 = new Date(now.getFullYear(), 0, 1)
  Math.floor((now - jan1)/1000)

put32 = (msg, idx, val) ->
  msg.data16[idx]   = (val / 0x10000) & 0xffff
  msg.data16[idx+1] = val & 0xffff

program = new Command()
  .name('gpcmd')
  .description('Simulate GPC command traffic to a MEDS IDP (DK bus)')
  .version('1.0.0')

program.command('fill')
  .description('DATA FILL — send a display format (FCW stream, .dfb file) to an IDP')
  .argument('<dfb-file>', 'FCW stream, e.g. a data/*.dfb file')
  .option('--idp <n>', 'target IDP 1..4', '1')
  .action (file, o) ->
    data = fs.readFileSync file
    bus = dkBusForIDP(o)
    sendMsgs bus, ->
      msg = new BusMsg(1 + Math.ceil(data.length/2))
      msg.data16[0] = 1
      for c,i in data
        msg.data8[i+2] = c
      console.log "fill: #{data.length} bytes -> #{bus.busID}"
      msg
    , o

program.command('time')
  .description('TIME FILL + POLL — drive the DPS MET/CRT time header')
  .option('--idp <n>', 'target IDP 1..4', '1')
  .option('--met <d/hh:mm:ss>', 'MET start (default: current day-of-year clock)')
  .option('--crt <d/hh:mm:ss>', 'CRT timer start (default 0/00:00:00)')
  .option('--interval <secs>', 'resend every N seconds, advancing the clocks (0 = send once)', '0')
  .action (o) ->
    metBase = if o.met then parseTimeStr(o.met) else nowYearSecs()
    crtBase = if o.crt then parseTimeStr(o.crt) else 0
    t0 = Date.now()
    bus = dkBusForIDP(o)
    sendMsgs bus, ->
      elapsed = Math.floor((Date.now() - t0)/1000)
      msg = new BusMsg(5)
      msg.data16[0] = 2
      put32 msg, 1, metBase + elapsed
      put32 msg, 3, crtBase + elapsed
      msg
    , o

program.command('resetspl')
  .description('RESET SPL — clear the DPS scratch pad line')
  .option('--idp <n>', 'target IDP 1..4', '1')
  .action (o) ->
    bus = dkBusForIDP(o)
    sendMsgs bus, ->
      msg = new BusMsg(1)
      msg.data16[0] = 6
      msg
    , o

program.command('raw')
  .description('send an arbitrary opcode + payload halfwords (hex)')
  .argument('<op>', 'opcode 1..9')
  .argument('[words...]', 'payload halfwords in hex')
  .option('--idp <n>', 'target IDP 1..4', '1')
  .option('--interval <secs>', 'resend every N seconds (0 = send once)', '0')
  .action (op, words, o) ->
    bus = dkBusForIDP(o)
    sendMsgs bus, ->
      msg = new BusMsg(1 + words.length)
      msg.data16[0] = parseInt(op, 10)
      for w,i in words
        msg.data16[i+1] = parseInt(w, 16)
      msg
    , o

program.command('watch')
  .description('print traffic seen on a bus (debug)')
  .argument('[bus]', 'bus name: DK1..DK4, FC1..FC4, _IDP1.., _KYBD1..', 'DK1')
  .action (busName) ->
    bus = openBus(busName)
    bus.onReceive ((_, busID, msg, remote) ->
      hex = (msg.data16[i].toString(16).padStart(4,'0') for i in [0...Math.min(msg.data16.length,16)])
      more = if msg.data16.length > 16 then " ... (#{msg.data16.length} words)" else ""
      console.log "#{busID}: #{hex.join(' ')}#{more}"
    ), null
    console.log "watching #{busName} (port #{busConfig[busName].port}), ^C to stop"
    setInterval (->), 60000  # keep the process alive

program.parse()
