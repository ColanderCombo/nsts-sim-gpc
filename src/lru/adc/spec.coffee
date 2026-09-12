import {call, setTimeout, setInterval, clearTimeout, clearInterval, now as simNow} from '../../com/simRuntime.coffee'
# adc -- the MEDS Analog to Digital Converters
#
import {Bus, BusMsg, busConfig} from './../../com/bus.civet.jsx'
import {SimControl} from './../../com/simControl'
import {die as lruDie, holdOpen} from './../lruCli'
import {ADC} from './adc'
import {IDPAdcBC} from './../../meds/idp/idpAdc'
import {CHANNELS, UNITS, pairOf, rtAddressOf, idpBussesOf, ANALOG_BUS,
        TR_TRANSMIT, TR_RECEIVE, SA, STATUS_BLOCK_WORDS, STATUS_BLOCK, CST_STATE, COMMAND,
        CST_DURATION_MS, commandWord, fmtBite, fmtCst,
        wordToVolts, decode1553, fmt1553, encodeBC,
        ANALOG_OP, encodeAnalog, decodeAnalog, fmtAnalog} from './adcConf'
import {CHANNEL_VOLTS_MIN, CHANNEL_VOLTS_MAX, channelsOfPair, channelOf, parseChannel,
        euToVolts, voltsToEu} from './adcChannels'
import {MDM_CATALOG} from './../mdm/mdmConfig'
import {IOM, IO_OP, ioBusName, encodeIO, decodeIO, voltsToWord as aiVoltsToWord} from './../mdm/mdmConf'

BIND_MS  = 150
REPLY_MS = 2000

die = (msg) -> lruDie 'adc', msg

hex4 = (v) -> (v & 0xffff).toString(16).padStart(4, '0')

wantUnit = (s) ->
  u = String(s).toUpperCase()
  die "units are #{UNITS.join(', ')}" unless u in UNITS
  u

wantPair = (s) ->
  n = parseInt(s, 10)
  die "pairs are 1 (MPS/OMS/SPI) and 2 (APU/HYD)" unless ANALOG_BUS[n]
  n

# "1A=0020": a unit and a hex word.
parseUnitWord = (s, what) ->
  m = String(s).match(/^([12][AaBb])\s*=\s*(?:0x)?([0-9a-fA-F]{1,4})$/)
  die "bad --#{what} '#{s}' (want <unit>=<hex>)" unless m?
  {unit: m[1].toUpperCase(), word: parseInt(m[2], 16)}

openBus = (name) ->
  die "unknown bus '#{name}'" unless busConfig[name]?
  new Bus(name, busConfig[name])

sendWords = (bus, words) ->
  msg = new BusMsg(words.length)
  msg.data16[i] = words[i] & 0xffff for i in [0...words.length] by 1
  bus.sendMsg msg

fmtEu = (c, v) ->
  return '' unless c?
  eu = voltsToEu(c, v)
  digits = if c.hi - c.lo <= 20 then 2 else if c.hi - c.lo <= 200 then 1 else 0
  "#{eu.toFixed(digits)} #{c.units}"

# Where a channel's signal is in the simulation: the MDM card the catalog
# holds as analog, or null for the analog bus alone.
tapOf = (c) ->
  return null unless c?.tap?
  cat = MDM_CATALOG[c.tap.mdm]
  return null unless cat?
  type = IOM[cat.iom[c.tap.card]]
  return null unless type?.kind == 'analog'
  {bus: ioBusName(c.tap.mdm), typeName: type.name, code: type.code, out: type.dir == 'out',
   mdm: c.tap.mdm, card: c.tap.card, chan: c.tap.channel}

fmtTap = (tp) -> if tp? then "#{tp.mdm} #{tp.card}/#{tp.chan} #{tp.typeName}" else ''

# The IDP bus a tool uses to reach a unit: the first of the unit's two,
# or the one an --idp names.
busForUnit = (unit, idpOpt) ->
  names = idpBussesOf(unit)
  return names[0] unless idpOpt?
  name = "_IDP#{idpOpt}"
  die "ADC #{unit} is on #{names.join(' and ')}" unless name in names
  name

idpOfBus = (busName) -> parseInt(busName.replace(/\D/g, ''), 10)

# Send one command to a unit as its IDP and wait for the answer.
transact = (unit, busName, cmd, data, cb) ->
  bus = openBus(busName)
  bc = new IDPAdcBC(idpOfBus(busName), {send: (words) -> sendWords bus, words})
  timer = null
  bus.onReceive ((_, busID, msg) ->
    m = decode1553(msg.data16)
    return unless m?.kind == 'status' and m.rt == rtAddressOf(unit)
    wanted = if cmd.tr == TR_TRANSMIT then cmd.wc else 0
    return unless m.data.length == (if wanted == 0 and cmd.tr == TR_TRANSMIT then 32 else wanted)
    clearTimeout timer
    cb(m, bus)
  ), null
  setTimeout (->
    bc.send(encodeBC(cmd, data))
    timer = setTimeout (->
      console.error "adc: no reply from ADC #{unit} on #{busName}"
      process.exit(1)), REPLY_MS
  ), BIND_MS

printFrame = (unit, m) ->
  pair = pairOf(unit)
  console.log "ADC #{unit} status #{hex4 (m.rt << 11) | m.flags}#{if m.names.length then " [#{m.names.join(' ')}]" else ''}"
  for w, i in m.data
    c = channelOf(pair, i)
    v = wordToVolts(w)
    console.log "  ch #{String(i).padStart(2)}  #{hex4 w}  #{(if v < 0 then '' else ' ')}#{v.toFixed(4)} V  " +
                "#{(c?.msid ? '').padEnd(10)} #{(c?.field ? (if c? then '(not displayed)' else 'spare')).padEnd(18)} #{fmtEu c, v}"
  return

printStatusBlock = (unit, m) ->
  d = m.data
  state = (k for k, v of CST_STATE when v == d[STATUS_BLOCK.CST_STATE])[0] ? d[STATUS_BLOCK.CST_STATE]
  console.log "ADC #{unit} status #{hex4 (m.rt << 11) | m.flags}#{if m.names.length then " [#{m.names.join(' ')}]" else ''}"
  console.log "  BITE      #{hex4 d[STATUS_BLOCK.BITE]}  #{fmtBite d[STATUS_BLOCK.BITE]}"
  cst = d[STATUS_BLOCK.CST]
  console.log "  CST       #{hex4 cst}  #{if state != 'DONE' then state else if cst then fmtCst(cst) else 'pass'}"
  console.log "  samples   #{d[STATUS_BLOCK.SAMPLES]}"
  console.log "  version   V #{hex4 d[STATUS_BLOCK.VERSION]}"
  return

export SPEC =
  id:      'adc'
  title:   'Analog to Digital Converter'
  summary: 'Space Shuttle MEDS Analog to Digital Converter -- device model and bus tools'
  usage: [
    'Examples:'
    '  adc run [--units 1A,2A] [--fail 1B] [--bite 1A=0020] [--cst-result 2A=0004]'
    '  adc drive 1 [--nominal | --sweep | --zero] [--set field=eu ...]'
    '  adc set 1 <channel|field> <volts> [--eu]'
    '  adc poll 1A [--idp 2] [--repeat n]'
    '  adc cst 1A'
    '  adc watch 1A | _IDP1 | analog 1'
    '  adc channels [1|2]'
  ]
  tables: ['channels', 'commands']

  run:
    summary: 'run the converters on their IDP busses'
    options: [
      ['--units <list>', 'units to run', UNITS.join(',')]
      {flag: '--fail <unit>', help: 'suppress a unit reply, repeatable'
       many: true, apply: (adc, s) ->
         u = wantUnit(s)
         die "ADC #{u} is not running" unless adc.units[u]
         adc.setAnswers(u, false)}
      {flag: '--bite <unit=hex>', help: 'set BITE summary, repeatable'
       many: true, apply: (adc, s) ->
         k = parseUnitWord(s, 'bite')
         die "ADC #{k.unit} is not running" unless adc.units[k.unit]
         adc.setBite(k.unit, k.word)}
      {flag: '--cst-result <unit=hex>', help: 'set next self-test result, repeatable'
       many: true, apply: (adc, s) ->
         k = parseUnitWord(s, 'cst-result')
         die "ADC #{k.unit} is not running" unless adc.units[k.unit]
         adc.setCstResult(k.unit, k.word)}
      ['--reply-delay <ms>', 'delay before answering a command', '0']
      ['quiet', 'do not trace commands']
    ]
    build: (o) ->
      units = (wantUnit(s) for s in String(o.units).split(',') when s.trim())
      die "no units selected" unless units.length
      new ADC({
        units
        replyDelayMs: parseFloat(o.replyDelay)
        verbose: not o.quiet
      })

  tools: (program) ->


    program.command('drive')
      .description("drive an ADC pair's inputs until ^C")
      .argument('<pair>', '1 (MPS/OMS/SPI) or 2 (APU/HYD)')
      .option('--nominal', 'every channel at its nominal value (default)')
      .option('--zero', 'every channel at 0 V')
      .option('--sweep', 'every channel a triangle wave over its meter range')
      .option('--period <s>', 'sweep period in seconds; each channel adds a second to it', '10')
      .option('--set <field=eu>', 'one channel held at an engineering value, repeatable',
              ((v, acc) -> (acc ? []).concat([v])), [])
      .option('--all', 'drive the GPC-written channels too, on the analog bus')
      .option('--rate <hz>', 'how often the channels are sent', '10')
      .action (pairStr, o) ->
        pair = wantPair(pairStr)
        chans = channelsOfPair(pair)
        volts = new Float64Array(CHANNELS)
        held = {}
        for s in o.set
          m = String(s).match(/^([^=]+)=(.+)$/)
          die "bad --set '#{s}' (want <field>=<value>)" unless m?
          n = parseChannel(pair, m[1])
          die "no channel '#{m[1]}' on pair #{pair}" unless n?
          c = channelOf(pair, n)
          v = parseFloat(m[2])
          die "bad value '#{m[2]}'" unless isFinite(v)
          held[n] = if c? then euToVolts(c, v) else v
        period = parseFloat(o.period)
        t0 = simNow()
        fill = () ->
          t = (simNow() - driver.state.t0) / 1000
          for c in chans
            if o.sweep
              p = period + c.channel
              ph = (t % p) / p
              tri = if ph < 0.5 then 2 * ph else 2 - 2 * ph
              volts[c.channel] = euToVolts(c, c.lo + tri * (c.hi - c.lo))
            else if o.zero
              volts[c.channel] = 0
            else
              volts[c.channel] = euToVolts(c, c.nominal)
          volts[n] = v for n, v of held
          return
        # Each channel's route: an MDM input card, the analog bus, or the GPC's.
        routes = for c in chans
          tp = tapOf(c)
          if tp? and not tp.out then {c, tp, via: 'mdm'}
          else if tp? and tp.out then {c, tp, via: (if o.all then 'analog' else 'gpc')}
          else {c, tp: null, via: 'analog'}
        busName = ANALOG_BUS[pair]
        busses = {}
        busses[busName] = openBus(busName)
        for r in routes when r.via == 'mdm' and not busses[r.tp.bus]
          busses[r.tp.bus] = openBus(r.tp.bus)
        # A channel goes out when its value changes, and every channel again
        # when a unit asks with REQUEST on either bus.
        lastSent = new Float64Array(CHANNELS).fill(NaN)
        send = (all = false) ->
          fill()
          for r in routes
            v = volts[r.c.channel]
            continue if not all and v == lastSent[r.c.channel]
            lastSent[r.c.channel] = v
            if r.via == 'mdm'
              sendWords busses[r.tp.bus], Array.from(encodeIO {op: IO_OP.VALUE, type: r.tp.code, card: r.tp.card, channel: r.tp.chan, words: [aiVoltsToWord(v)]})
            else if r.via == 'analog'
              sendWords busses[busName], encodeAnalog(ANALOG_OP.VALUE, r.c.channel, [v])
          return
        busses[busName].onReceive ((_, busID, msg) ->
          m = decodeAnalog(msg.data16)
          send(true) if m?.op == ANALOG_OP.REQUEST
        ), null
        for name, b of busses when name != busName
          b.onReceive ((_, busID, msg) ->
            m = decodeIO(msg.data16)
            send(true) if m?.op == IO_OP.REQUEST
          ), null
        mode = if o.sweep then 'sweeping' else if o.zero then '0 V on' else 'nominal values on'
        n = (via) -> (r for r in routes when r.via == via).length
        console.log "#{mode} #{busName} (port #{busConfig[busName].port}), pair #{pair}, ^C to stop"
        console.log "  #{n 'mdm'} channels on MDM input cards (#{(b for b of busses when b != busName).join(' ')}), " +
                    "#{n 'analog'} on the analog bus, #{n 'gpc'} left to the GPC"
        for r in routes when r.via == 'gpc'
          console.log "    #{r.c.field ? r.c.msid}: #{fmtTap r.tp}"
        driver = {
          id: "adcsig#{pair}", config: {pair, mode, rate: parseFloat(o.rate), held},
          state: {volts, held, lastSent, t0}, send,
          bus: busses, report: -> {channels: chans.length, mdm: n('mdm'), analog: n('analog'), gpc: n('gpc')}
        }
        control = new SimControl(driver)
        setTimeout call(driver, 'send', true), BIND_MS
        timer = setInterval call(driver, 'send'), 1000 / parseFloat(o.rate)
        stopping = false
        stop = ->
          return if stopping
          stopping = true
          clearInterval(timer)
          control.close().finally ->
            bus.close() for bus in Object.values(busses)
            process.exit(0)
        process.on 'SIGINT', stop
        process.on 'SIGTERM', stop

    program.command('set')
      .description('set one ADC input channel')
      .argument('<pair>', '1 or 2')
      .argument('<channel>', 'a channel number, field name or MSID')
      .argument('<value>', 'volts, or engineering units with --eu')
      .option('--eu', 'the value is in the channel\'s engineering units')
      .option('--direct', 'on the analog bus whatever the channel\'s tap')
      .action (pairStr, chStr, valStr, o) ->
        pair = wantPair(pairStr)
        n = parseChannel(pair, chStr)
        die "no channel '#{chStr}' on pair #{pair}" unless n?
        c = channelOf(pair, n)
        v = parseFloat(valStr)
        die "bad value '#{valStr}'" unless isFinite(v)
        if o.eu
          die "channel #{n} has no engineering scale" unless c?
          v = euToVolts(c, v)
        tp = tapOf(c)
        if tp? and not tp.out and not o.direct
          busName = tp.bus
          words = Array.from(encodeIO {op: IO_OP.VALUE, type: tp.code, card: tp.card, channel: tp.chan, words: [aiVoltsToWord(v)]})
          where = "#{fmtTap tp} on #{busName}"
        else
          busName = ANALOG_BUS[pair]
          words = encodeAnalog(ANALOG_OP.VALUE, n, [v])
          where = busName
          console.log "channel #{n} is the GPC's (#{fmtTap tp}); the value goes on the analog bus" if tp?.out and not o.direct
        bus = openBus(busName)
        bus.onReceive (->), null
        setTimeout (->
          sendWords bus, words
          console.log "#{where}: channel #{n}#{if c? then " (#{c.field ? c.msid})" else ''} = #{v.toFixed(3)} V" +
                      "#{if c? then "  #{fmtEu c, v}" else ''}"
          setTimeout (-> process.exit(0)), 50
        ), BIND_MS


    program.command('poll')
      .description('read the 32 samples of a unit, as its IDP does (test equipment)')
      .argument('<unit>', UNITS.join(', '))
      .option('--idp <n>', 'which of the unit\'s two IDP busses to use')
      .option('--repeat <n>', 'read this many times, a second apart', '1')
      .action (unitStr, o) ->
        unit = wantUnit(unitStr)
        busName = busForUnit(unit, o.idp)
        left = parseInt(o.repeat, 10)
        cmd = {rt: rtAddressOf(unit), tr: TR_TRANSMIT, sa: SA.SAMPLES, wc: 0}
        once = ->
          left -= 1
          transact unit, busName, cmd, [], (m, bus) ->
            printFrame unit, m
            bus.close()
            if left > 0 then setTimeout once, 1000 else process.exit(0)
        once()

    program.command('status')
      .description('read the status block of a unit')
      .argument('<unit>', UNITS.join(', '))
      .option('--idp <n>', 'which of the unit\'s two IDP busses to use')
      .action (unitStr, o) ->
        unit = wantUnit(unitStr)
        cmd = {rt: rtAddressOf(unit), tr: TR_TRANSMIT, sa: SA.STATUS, wc: STATUS_BLOCK_WORDS}
        transact unit, busForUnit(unit, o.idp), cmd, [], (m) ->
          printStatusBlock unit, m
          process.exit(0)

    program.command('cst')
      .description('start the comprehensive self-test of a unit and read the result')
      .argument('<unit>', UNITS.join(', '))
      .option('--idp <n>', 'which of the unit\'s two IDP busses to use')
      .action (unitStr, o) ->
        unit = wantUnit(unitStr)
        busName = busForUnit(unit, o.idp)
        start = {rt: rtAddressOf(unit), tr: TR_RECEIVE, sa: SA.COMMAND, wc: 1}
        transact unit, busName, start, [COMMAND.START_CST], (m, bus) ->
          console.log "ADC #{unit} CST started#{if m.names.length then " [#{m.names.join(' ')}]" else ''}"
          bus.close()
          read = {rt: rtAddressOf(unit), tr: TR_TRANSMIT, sa: SA.STATUS, wc: STATUS_BLOCK_WORDS}
          setTimeout (->
            transact unit, busName, read, [], (m2) ->
              printStatusBlock unit, m2
              process.exit(0)
          ), CST_DURATION_MS + 500

    program.command('watch')
      .description('print the traffic to and from a unit, on an IDP bus, or on an analog bus')
      .argument('<what>', "a unit (1A), an IDP bus (_IDP1), or 'analog'")
      .argument('[pair]', "with 'analog': 1 or 2", '1')
      .action (what, pairStr) ->
        w = String(what)
        if w.toLowerCase() == 'analog'
          name = ANALOG_BUS[wantPair(pairStr)]
          bus = openBus(name)
          bus.onReceive ((_, busID, msg) ->
            m = decodeAnalog(msg.data16)
            console.log "#{busID}: #{fmtAnalog m}" if m?
          ), null
          console.log "watching #{name} (port #{busConfig[name].port}), ^C to stop"
        else
          if /^_IDP[1-4]$/i.test(w)
            names = [w.toUpperCase()]
            rt = null
          else
            unit = wantUnit(w)
            names = idpBussesOf(unit)
            rt = rtAddressOf(unit)
          for name in names
            bus = openBus(name)
            bus.onReceive ((_, busID, msg) ->
              m = decode1553(msg.data16)
              return unless m? and (not rt? or m.rt == rt)
              console.log "#{busID}: #{fmt1553 m}"
            ), null
          console.log "watching #{names.join(' ')}#{if rt? then " for RT #{rt}" else ''}, ^C to stop"
        holdOpen()


    program.command('channels')
      .description('list ADC channels')
      .argument('[pair]', '1 or 2; both when omitted')
      .action (pairStr) ->
        pairs = if pairStr? then [wantPair(pairStr)] else [1, 2]
        for pair in pairs
          units = (u for u in UNITS when pairOf(u) == pair)
          console.log "pair #{pair} (ADC #{units.join(', ')}), #{CHANNEL_VOLTS_MIN} to #{CHANNEL_VOLTS_MAX} V full scale; " +
                      "channel numbers are JSC-18819 SCP 4.9's less one"
          for i in [0...CHANNELS] by 1
            c = channelOf(pair, i)
            unless c?
              console.log "  ch #{String(i).padStart(2)}  spare"
              continue
            tp = tapOf(c)
            console.log "  ch #{String(i).padStart(2)}  #{c.msid.padEnd(10)} #{c.signal.padEnd(33)} #{c.source.padEnd(8)} " +
                        "#{(if tp? then fmtTap(tp) else 'analog bus').padEnd(16)} #{(c.field ? '-').padEnd(17)} " +
                        "#{String(c.lo).padStart(4)}..#{String(c.hi).padEnd(5)} #{c.units}"
        return

    program.command('commands')
      .description('the 1553B command words an IDP sends each unit')
      .action () ->
        for u in UNITS
          rt = rtAddressOf(u)
          console.log "ADC #{u}  RT #{rt} (#{rt.toString(2).padStart(5, '0')})  on #{idpBussesOf(u).join(' ')}"
          console.log "  samples  #{hex4 commandWord({rt, tr: TR_TRANSMIT, sa: SA.SAMPLES, wc: 0})}  transmit sa #{SA.SAMPLES}, 32 words"
          console.log "  status   #{hex4 commandWord({rt, tr: TR_TRANSMIT, sa: SA.STATUS, wc: STATUS_BLOCK_WORDS})}  transmit sa #{SA.STATUS}, #{STATUS_BLOCK_WORDS} words"
          console.log "  command  #{hex4 commandWord({rt, tr: TR_RECEIVE, sa: SA.COMMAND, wc: 1})}  receive sa #{SA.COMMAND}, 1 word: " +
                      "#{hex4 COMMAND.START_CST} start CST, #{hex4 COMMAND.RESET} reset"
        return
