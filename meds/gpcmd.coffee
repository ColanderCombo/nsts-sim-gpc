# gpcmd — utility to send/monitor DEU traffic on a DK bus.
#
# Usage:
#   GPCMD.sh fill data/TEST.dfb --idp 1        # display data fill
#   GPCMD.sh fill f.dfb --addr 19EE --format   # format data fill
#   GPCMD.sh time --idp 1 --interval 1         # the header clock
#   GPCMD.sh poll --idp 1 --interval 1         # poll, and print the response
#   GPCMD.sh bite --idp 1                      # Built-In Test Equipment query
#   GPCMD.sh resetspl                          # clear the Scratch Pad Line
#   GPCMD.sh key SYS_SUMM --idp 1              # press a keyboard key
#   GPCMD.sh mf SM --idp 1                     # the major function switch
#   GPCMD.sh raw 71800 0001 19EE               # raw command and its data
#   GPCMD.sh monitor                           # monitor every bus
#   GPCMD.sh monitor DK1 --fcw                 # ... decoding the formats
#   GPCMD.sh unit --idp 1                      # simulate IDP state machine
#   GPCMD.sh unit --ipl-request --fcw          # ... and ask to be IPL'd
#
import * as fs from 'fs'
import {Bus, BusMsg, busConfig} from '../com/bus.civet.jsx'
import {addBusOptions} from '../com/busCli'
import {FCW, wordsFromBytes, bytesFromWords} from '../meds/deuFCW'
import * as DEU from '../meds/deuProto'
import {MDUMsgName} from '../meds/medsConf'
import {KYBD} from '../meds/kybd'
import {DEUUnit} from '../meds/deuUnit'
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

dkBusForIDP = (o, sendOnly=true) ->
  n = parseInt(o.idp, 10)
  if not (1 <= n <= 4)
    console.error "gpcmd: --idp must be 1..4"
    process.exit(2)
  openBus("DK#{n}", sendOnly)

# Run `fire` once after the socket has joined the group, then on the
# requested interval; with no interval, exit once the datagrams have left.
sendMsgs = (bus, fire, o) ->
  intervalS = parseFloat(o.interval ? '0')
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

program = new Command()
  .name('gpcmd')
  .description('Simulate GPC command traffic to a MEDS IDP (DK bus)')
  .version('1.0.0')

sendCommand = (bus, cmd24) ->
  msg = new BusMsg(2)
  msg.data16[0] = (cmd24 >>> 8) & 0xffff
  msg.data16[1] = (cmd24 & 0xff) << 8
  bus.sendMsg msg

sendWords = (bus, words) ->
  for w in words
    msg = new BusMsg(1)
    msg.data16[0] = w & 0xffff
    bus.sendMsg msg

sendFill = (bus, func, addr, words) ->
  msgs = DEU.fillMessages(func, addr, words)
  for m in msgs
    sendCommand bus, DEU.encodeCommand(m.func, m.count)
    sendWords bus, m.body
  msgs.length

readDFB = (file) -> wordsFromBytes fs.readFileSync(file)

hex4 = (v) -> (v & 0xffff).toString(16).padStart(4, '0')

sum16 = (words) ->
  s = 0
  s = (s + (w & 0xffff)) & 0xffff for w in words
  s

headerFlags = (hdr) ->
  flagsOut = (flagName for flagName, flagMask of DEU.HDR \
              when flagName not in DEU.HDR_FIELDS and (hdr & flagMask))
  majFunc = (hdr & DEU.HDR.MAJOR_FUNC) >> DEU.MAJOR_FUNC_SHIFT
  flagsOut.push "MAJFUNC=#{majFunc}" if majFunc
  deuId = (hdr & DEU.HDR.DEU_ID) >> DEU.DEU_ID_SHIFT
  flagsOut.push "DEU=#{deuId}" if deuId
  flagsOut

# Decode a 16-halfword poll response, or return null if it is not one.
describePoll = (w) ->
  return null if w.length != DEU.POLL_WORDS
  hdr = w[0] & 0xffff
  keyCount = w[1] & DEU.KEY_COUNT_MASK
  parts = ["POLL RESPONSE hdr #{hex4 hdr}"]
  flags = headerFlags(hdr)
  parts.push "[#{flags.join(' ')}]" if flags.length > 0
  if keyCount > 0
    codes = DEU.unpackKeys(w[2...(2 + DEU.KEY_WORDS)], keyCount)
    names = (DEU.KEY_NAME[k] ? "0x#{k.toString(16)}" for k in codes)
    parts.push "keys #{keyCount}: " + names.join(' ')
  parts.push "BITE #{hex4 w[12]}/#{hex4 w[13]} SW #{hex4 w[14]}"
  parts.push (if sum16(w) == 0 then 'cksum ok' else "cksum BAD (#{hex4 sum16 w})")
  parts.join '  '

# Reassemble a unit's reply from however many datagrams it arrived in, and
# hand each complete response to `onWords`.
replyReader = (nWords, onWords) ->
  heard = []
  (_, busID, msg) ->
    heard.push msg.data16[i] for i in [0...msg.data16.length]
    onWords heard.splice(0, nWords) while heard.length >= nWords

program.command('fill')
  .description('memory fill — load a format control word stream into a unit')
  .argument('<dfb-file>', 'format control words, e.g. a data/*.dfb file')
  .option('--idp <n>', 'target IDP 1..4', '1')
  .option('--addr <hex>', 'DEU address to load at', '19EE')
  .option('--format', 'send it as a FORMAT data fill instead of a display fill')
  .option('--interval <secs>', 'resend every N seconds (0 = send once)', '0')
  .action (file, o) ->
    words = readDFB(file)
    addr = parseInt(o.addr, 16)
    func = if o.format then DEU.FUNC.FORMAT_FILL else DEU.FUNC.DISPLAY_FILL
    bus = dkBusForIDP(o)
    sendMsgs bus, (->
      n = sendFill bus, func, addr, words
      console.log "fill: #{words.length} halfwords at " +
                  "0x#{addr.toString(16)} -> #{bus.busID} " +
                  "(#{n} transfer#{if n == 1 then '' else 's'})"), o

program.command('time')
  .description('the display header clock, as the monitor sends it')
  .option('--idp <n>', 'target IDP 1..4', '1')
  .option('--met <d/hh:mm:ss>', 'MET start (default: current day-of-year clock)')
  .option('--crt <d/hh:mm:ss>', 'CRT timer start (default 0/00:00:00)')
  .option('--interval <secs>', 'resend every N seconds, advancing the clocks (0 = send once)', '0')
  .action (o) ->
    metBase = if o.met then parseTimeStr(o.met) else nowYearSecs()
    crtBase = if o.crt then parseTimeStr(o.crt) else 0
    t0 = Date.now()
    bus = dkBusForIDP(o)
    sendMsgs bus, (->
      elapsed = Math.floor((Date.now() - t0)/1000)
      words = DEU.timeFillWords
        mission: metBase + elapsed
        event: crtBase + elapsed
      sendCommand bus, DEU.encodeCommand(DEU.FUNC.TIME_FILL, words.length)
      sendWords bus, words), o

program.command('poll')
  .description('poll a unit and print its response')
  .option('--idp <n>', 'target IDP 1..4', '1')
  .option('--interval <secs>', 'poll every N seconds (0 = once)', '0')
  .action (o) ->
    bus = dkBusForIDP(o, false)
    bus.onReceive replyReader(DEU.POLL_WORDS, (w) -> console.log describePoll w), null
    sendMsgs bus, (-> sendCommand bus, DEU.encodeCommand(DEU.FUNC.POLL)), o

program.command('bite')
  .description('BITE status request')
  .option('--idp <n>', 'target IDP 1..4', '1')
  .action (o) ->
    bus = dkBusForIDP(o, false)
    bus.onReceive ((_, busID, msg) ->
      hex = (hex4 msg.data16[i] for i in [0...msg.data16.length])
      console.log "BITE: #{hex.join(' ')}"), null
    sendMsgs bus, (-> sendCommand bus, DEU.encodeCommand(DEU.FUNC.BITE)), o

program.command('resetspl')
  .description('reset the scratch pad line')
  .option('--idp <n>', 'target IDP 1..4', '1')
  .action (o) ->
    bus = dkBusForIDP(o)
    sendMsgs bus, (-> sendCommand bus, DEU.encodeCommand(DEU.FUNC.RESET_SPL)), o

program.command('raw')
  .description('send an arbitrary 19-bit command (hex) and payload halfwords (hex)')
  .argument('<cmd>', '19-bit command, hex — e.g. 71800 for a display fill')
  .argument('[words...]', 'payload halfwords in hex')
  .option('--idp <n>', 'target IDP 1..4', '1')
  .option('--interval <secs>', 'resend every N seconds (0 = send once)', '0')
  .action (cmd, words, o) ->
    bus = dkBusForIDP(o)
    c19 = parseInt(cmd, 16)
    sendMsgs bus, (->
      sendCommand bus, ((DEU.IUA << 19) | c19) >>> 0
      sendWords bus, (parseInt(w, 16) for w in words)), o

program.command('key')
  .description('press keys on a unit\'s keyboard')
  .argument('<keys...>', 'key names, e.g. SYS_SUMM ITEM 1 EXEC (see --list-keys)')
  .option('--idp <n>', 'target IDP 1..4', '1')
  .option('--kybd <bus>', 'keyboard bus to send on (default: the IDP\'s first)')
  .action (keys, o) ->
    n = parseInt(o.idp, 10)
    busName = o.kybd ? "_KYBD#{if n == 4 then 3 else n}"
    codes = []
    for name in keys
      k = KYBD.DEUKey.keys[name.toUpperCase()] ? KYBD.DEUKey.keys[name]
      if not k?
        console.error "gpcmd: no such key '#{name}' " +
                      "(try #{Object.keys(KYBD.DEUKey.keys).join(' ')})"
        process.exit(2)
      codes.push k
    bus = openBus(busName, true)
    sendMsgs bus, (->
      for k in codes
        msg = new BusMsg(1)
        msg.data16[0] = k.deuCode
        bus.sendMsg msg
        console.log "key #{k.ascii} (scan #{k.deuCode.toString(16)}, " +
                    "code #{k.gpcCode.toString(16)}) -> #{bus.busID}"), o

program.command('mf')
  .description('set a unit\'s major function switch')
  .argument('<position>', 'GNC, SM or PL')
  .option('--idp <n>', 'target IDP 1..4', '1')
  .option('--kybd <bus>', 'keyboard bus to send on (default: the IDP\'s first)')
  .action (position, o) ->
    name = position.toUpperCase()
    if not DEU.MAJOR_FUNC_CODE[name]?
      console.error "gpcmd: the major function is GNC, SM or PL"
      process.exit(2)
    n = parseInt(o.idp, 10)
    busName = o.kybd ? "_KYBD#{if n == 4 then 3 else n}"
    bus = openBus(busName, true)
    sendMsgs bus, (->
      msg = new BusMsg(1)
      msg.data16[0] = KYBD.majorFuncWord(name)
      bus.sendMsg msg
      console.log "major function #{name} (word #{hex4 msg.data16[0]}) -> #{bus.busID}"), o

#
# monitor
#
DK_BUSSES = ('DK' + n for n in [1..4])
IDP_BUSSES = ('_IDP' + n for n in [1..4])
KYBD_BUSSES = ('_KYBD' + n for n in [1..3])

program.command('monitor')
  .alias('watch')
  .description('batch bus traffic into messages and decode')
  .argument('[busses...]', 'bus names; default DK1-4, _IDP1-4, _KYBD1-3')
  .option('--fcw', 'also disassemble fill payloads as display instructions')
  .option('--hex', 'also dump the raw halfwords of every message')
  .option('--quiet-heartbeat', 'hide the IDP heartbeat')
  .option('--json <file>', 'append one JSON record per message for analysis')
  .action (busses, o) ->
    fcw = new FCW()
    names = if busses.length then busses else DK_BUSSES.concat(IDP_BUSSES, KYBD_BUSSES)
    t0 = Date.now()
    jsonOut = if o.json then fs.createWriteStream(o.json, {flags: 'a'}) else null
    tally = {}
    say = (bus, text, rec) ->
      ms = ((Date.now() - t0) / 1000).toFixed(3).padStart(9)
      console.log "#{ms}  #{bus.padEnd(7)} #{text}"
      jsonOut?.write JSON.stringify(Object.assign({t: Date.now() - t0, bus: bus}, rec)) + '\n'

    state = {}
    for name in names
      state[name] = {xfer: null}

    onDK = (name, words) ->
      st = state[name]
      if words.length == 2
        cmd = ((words[0] & 0xffff) << 8) | ((words[1] >> 8) & 0xff)
        c = DEU.decodeCommand(cmd)
        tally["#{name} #{c.name}"] = (tally["#{name} #{c.name}"] ? 0) + 1
        if c.iua != DEU.IUA
          say name, "CMD #{cmd.toString(16).padStart(6,'0')} IUA #{c.iua} " +
                    "(not a display unit)", {kind: 'command', iua: c.iua, raw: cmd}
          return
        say name, "CMD #{cmd.toString(16).padStart(6,'0')} #{c.name} count #{c.count}",
             {kind: 'command', func: c.name, count: c.count, raw: cmd}
        expect = switch c.func
          when DEU.FUNC.POLL, DEU.FUNC.BITE, DEU.FUNC.RESET_SPL then 0
          when DEU.FUNC.MEDS_XFER then DEU.MEDS_XFER_WORDS
          else c.count
        st.xfer = if expect > 0 then {c: c, left: expect, words: []} else null
        return
      if words.length == 1 and st.xfer?
        st.xfer.words.push words[0] & 0xffff
        return if --st.xfer.left > 0
        x = st.xfer ; st.xfer = null
        f = DEU.parseFill(x.words)
        nz = x.words.filter((w) -> w != 0).length
        if f? and not f.short and f.count + 2 == x.words.length
          say name, "  #{x.c.name} #{f.count} hw at 0x#{f.addr.toString(16)}" +
                    "  (#{nz} non-zero)",
               {kind: 'fill', func: x.c.name, addr: f.addr, count: f.count,
                nonZero: nz, words: x.words}
          if o.fcw then printFCWs(fcw, f.payload, f.addr)
        else
          say name, "  #{x.c.name} #{x.words.length} hw, NO HEADER  " +
                    "(#{x.words.map(hex4).slice(0,8).join(' ')}#{if x.words.length > 8 then ' ...' else ''})",
               {kind: 'headerless', func: x.c.name, words: x.words}
        console.log '           ' + x.words.map(hex4).join(' ') if o.hex
        return
      # A single word with no transfer running is an orphan, which is what a
      # miscounted command looks like.
      if words.length == 1
        say name, "orphan data #{hex4 words[0]} (no transfer running)",
             {kind: 'orphan', words: words}
        return
      # Anything else on a DK bus is a reply from the unit.
      p = describePoll(words)
      if p?
        say name, p, {kind: 'poll-response', words: words}
      else
        say name, "REPLY #{words.length} hw  #{words.map(hex4).slice(0,16).join(' ')}",
             {kind: 'reply', words: words}

    onIDP = (name, words) ->
      tag = MDUMsgName[words[0]] ? "0x#{hex4 words[0]}"
      return if o.quietHeartbeat and tag == 'POLL'
      if tag == 'FILL'
        addr = words[1]
        body = words[2...]
        say name, "#{tag} #{body.length} hw at 0x#{addr.toString(16)}",
             {kind: 'mdu-fill', addr: addr, words: body}
        printFCWs(fcw, body, addr) if o.fcw
      else
        say name, "#{tag} #{words.length} hw #{words.map(hex4).slice(0,8).join(' ')}",
             {kind: 'mdu', tag: tag, words: words}

    onKYBD = (name, words) ->
      for w in words
        d = KYBD.decode(w)
        if d?.key?
          k = d.key
          say name, "KEY #{k.ascii} (scan #{hex4 w}, code #{k.gpcCode.toString(16)})",
               {kind: 'key', key: k.ascii, code: k.gpcCode}
        else if d?.majorFunc?
          say name, "MAJOR FUNC #{DEU.MAJOR_FUNC_NAME[d.majorFunc]} (word #{hex4 w})",
               {kind: 'major-func', majorFunc: DEU.MAJOR_FUNC_NAME[d.majorFunc]}
        else
          say name, "word #{hex4 w} (no such key)", {kind: 'key-unknown', raw: w}

    for name in names
      if name not of busConfig
        console.error "gpcmd: unknown bus '#{name}'"
        process.exit(2)
      bus = new Bus(name, busConfig[name])
      handler = if /^DK/.test(name) then onDK
      else if /^_IDP/.test(name) then onIDP
      else if /^_KYBD/.test(name) then onKYBD
      else onDK
      do (name, handler) ->
        bus.onReceive ((_, busID, msg) ->
          words = (msg.data16[i] for i in [0...msg.data16.length])
          handler name, words), null

    console.log "monitoring #{names.join(' ')} -- ^C to stop"
    process.on 'SIGINT', () ->
      console.log '\n--- message tally ---'
      for k in Object.keys(tally).sort()
        console.log "#{String(tally[k]).padStart(6)}  #{k}"
      process.exit(0)
    setInterval (->), 60000

printFCWs = (fcw, words, addr) ->
  for w, i in words
    d = fcw.decodeFCW(w)
    a = ((addr + i) & 0x1fff).toString(16).padStart(4, '0')
    if d?
      v = (("#{k}=#{if typeof x == 'number' then x else JSON.stringify(x)}" \
            for k, x of d.v when x != 0).join(' '))
      console.log "             #{a}  #{hex4 w}  #{d.nm}#{if v then '  ' + v else ''}"
    else
      console.log "             #{a}  #{hex4 w}  ???"

#
# unit - headless IDP/MDU
#
program.command('unit')
  .description('be a display unit on a DK bus (the same state machine MEDS runs)')
  .option('--idp <n>', 'answer as unit 1..4 (bus DK1..DK4)', '1')
  .option('--ipl-request', 'ask the GPC to IPL this unit (poll header bit 16)')
  .option('--no-bite', 'answer with a ZERO BITE register -- what a GPC reads as silence')
  .option('--quiet', 'do not trace each message')
  .option('--fcw', 'disassemble each fill as display instructions')
  .option('--dump <file>', 'on ^C, write display memory out (big endian)')
  .option('--stats-interval <secs>', 'print the running totals every N seconds', '0')
  .action (o) ->
    fcw = new FCW()
    n = parseInt(o.idp, 10)
    if not (1 <= n <= 4)
      console.error 'gpcmd: --idp must be 1..4'
      process.exit(2)
    busName = "DK#{n}"
    bus = new Bus(busName, busConfig[busName])
    t0 = Date.now()
    ms = () -> ((Date.now() - t0) / 1000).toFixed(3).padStart(9)

    unit = new DEUUnit
      name: "unit#{n}"
      ipled: not o.iplRequest
      send: (words) ->
        msg = new BusMsg(words.length)
        msg.data16[i] = words[i] & 0xffff for i in [0...words.length]
        bus.sendMsg msg
      log: (text) -> console.log "#{ms()}  #{text}"
    # a zero BITE register 1 is what a GPC reads as no response, from a unit
    # that is replying
    unit.biteState = (-> {bite1: 0}) if o.bite == false

    bus.onReceive ((_, busID, msg) ->
      words = (msg.data16[i] for i in [0...msg.data16.length])
      # Our own replies come back through multicast loopback and the bus drops
      # them only by exact match, so discard anything longer than a command:
      # no GPC sends more than two words at a time.
      return if words.length > 2
      r = unit.recv words
      return if o.quiet or not r?
      switch r.kind
        when 'command'
          console.log "#{ms()}  #{r.cmd.name} count #{r.cmd.count}"
        when 'fill'
          console.log "#{ms()}    fill #{r.count} hw at 0x#{r.addr.toString(16)} " +
                      "(#{r.payload.filter((w) -> w != 0).length} non-zero)"
          printFCWs(fcw, r.payload, r.addr) if o.fcw
        when 'headerless'
          console.log "#{ms()}    header-less fill, #{r.words.length} hw: " +
                      r.words.map(hex4).join(' ')
        when 'dump'
          console.log "#{ms()}    dump #{r.count} hw from 0x#{r.addr.toString(16)}"
        when 'meds'
          console.log "#{ms()}    MEDS DK buffer, #{r.words.length} hw"
      ), null

    kybdName = "_KYBD#{if n == 4 then 3 else n}"
    kybd = new Bus(kybdName, busConfig[kybdName])
    kybd.onReceive ((_, busID, msg) ->
      for i in [0...msg.data16.length]
        d = KYBD.decode(msg.data16[i])
        if d?.key?
          unit.pressKey d.key.gpcCode
          console.log "#{ms()}  key #{d.key.ascii} (code #{d.key.gpcCode.toString(16)}) queued"
        else if d?.majorFunc?
          unit.majorFunc = d.majorFunc
          console.log "#{ms()}  major function #{DEU.MAJOR_FUNC_NAME[d.majorFunc]}"
        else
          console.log "#{ms()}  unknown keyboard word 0x#{hex4 msg.data16[i]}"
      ), null

    console.log "display unit #{n} on #{busName}, keyboard #{kybdName} " +
                "(#{if o.iplRequest then 'asking for an IPL' else 'reporting loaded'}" +
                "#{if o.bite == false then ', BITE register ZERO' else ''}) -- ^C to stop"

    iv = parseFloat(o.statsInterval ? '0')
    setInterval (-> console.log "#{ms()}  #{JSON.stringify unit.stats}"), iv*1000 if iv > 0

    process.on 'SIGINT', () ->
      console.log "\n--- unit #{n} ---"
      console.log JSON.stringify(unit.stats, null, 1)
      used = 0
      used++ for w in unit.mem when w != 0
      console.log "display memory: #{used} non-zero halfwords of #{unit.mem.length}"
      console.log "last time fill: #{(unit.timeWords ? []).map(hex4).join(' ')}" +
                  " -> mission #{unit.time?.mission}s event #{unit.time?.event}s" if unit.timeWords?
      if o.dump
        fs.writeFileSync o.dump, bytesFromWords(Array.from(unit.mem))
        console.log "display memory written to #{o.dump}"
      process.exit(0)
    setInterval (->), 60000

# Every command here opens a bus.
addBusOptions(c) for c in program.commands

program.parse()
