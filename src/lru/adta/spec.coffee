# adta -- the four Air Data Transducer Assemblies
#
import {Bus, BusMsg, busConfig} from './../../com/bus.civet.jsx'
import {die as lruDie, holdOpen} from './../lruCli'
import {IO_OP, ioBusName, decodeIO, fmtIO} from './../mdm/mdmConf'
import {ADTA} from './adta'
import {UNIT_MDM, UNIT_BUS, UNIT_FEED, PROBE, CARD, CHANNEL,
        CMD_READ, READ_WORDS, STATUS, NOMINAL_STATUS, FAIL_BITS, MODE_BITS,
        statusBit, fmtStatus} from './adtaConf'

BIND_MS = 150
READ_MS = 2000

die = (msg) -> lruDie 'adta', msg

hex4 = (v) -> (v & 0xffff).toString(16).padStart(4, '0')

wantUnit = (s) ->
  n = parseInt(s, 10)
  die "units are 1 to 4" unless UNIT_MDM[n]
  n

parseFault = (s) ->
  m = String(s).match(/^([1234])\s*=\s*(\w+)$/)
  die "bad --fail '#{s}' (want <unit>=<bit name or mask>)" unless m?
  bits = if /^0x/i.test(m[2]) or /^\d+$/.test(m[2]) then Number(m[2]) else STATUS[m[2].toUpperCase()]
  die "no such mode status bit '#{m[2]}'" unless bits
  {unit: parseInt(m[1], 10), bits}

parseSelfTest = (s) ->
  m = String(s).match(/^([1234])\s*=\s*(high|low|off)$/i)
  die "bad --self-test '#{s}' (want <unit>=high|low|off)" unless m?
  which = m[2].toLowerCase()
  {unit: parseInt(m[1], 10), which: (if which == 'off' then null else which)}

fmtReply = (words) -> "status #{hex4 words[0]} (#{fmtStatus words[0]})"

export SPEC =
  id:      'adta'
  title:   'Air Data Transducer Assembly'
  summary: 'Space Shuttle Air Data Transducer Assemblies -- device model and bus tools'
  usage: [
    'Examples:'
    '  adta run'
    '  adta run --units 1,2 --fail 3=PS_GOOD --self-test 1=high'
    '  adta read 1                read ADTA 1 through MDM FF1 on FC1, as a GPC does'
    '  adta watch 1               the traffic between MDM FF1 and ADTA 1'
    '  adta status                the mode status bits and their nominals'
  ]
  tables: ['status']

  run:
    summary: 'run the air data transducer assemblies behind their MDMs'
    options: [
      ['--units <list>', 'units to run (MDM FF1 / FF2 / FF3 / FF4)', '1,2,3,4']
      {flag: '--fail <n=bit>', help: 'flip a status bit, repeatable'
       many: true, apply: (adta, s) ->
         k = parseFault(s)
         die "ADTA #{k.unit} is not running" unless adta.units[k.unit]
         adta.setFault(k.unit, k.bits)}
      {flag: '--self-test <n=which>'
       help: 'set self-test input, repeatable'
       many: true, apply: (adta, s) ->
         k = parseSelfTest(s)
         die "ADTA #{k.unit} is not running" unless adta.units[k.unit]
         adta.setSelfTest(k.unit, k.which)}
      {flag: '--silent <n>', help: 'suppress a unit reply, repeatable'
       many: true, apply: (adta, s) -> adta.setAnswers(wantUnit(s), false)}
      {flag: '--disconnect <n>', help: 'disconnect a unit, repeatable'
       many: true, apply: (adta, s) -> adta.units[wantUnit(s)].connected = false}
      'replyDelay'
      ['quiet', 'do not trace polls']
    ]
    build: (o) ->
      units = (wantUnit(s) for s in String(o.units).split(',') when s.trim())
      die "no units selected" unless units.length
      new ADTA({
        units:        units
        replyDelayMs: parseFloat(o.replyDelay)
        verbose:      not o.quiet
      })

  tools: (program) ->
    program.command('read')
      .description('read a unit through its MDM, as a GPC does (test equipment)')
      .argument('[unit]', '1 to 4', '1')
      .option('--repeat <n>', 'read this many times, one second apart', '1')
      .action (unitStr, o) ->
        n = wantUnit(unitStr)
        busName = UNIT_BUS[n]
        bus = new Bus(busName, busConfig[busName])
        left = parseInt(o.repeat, 10)
        bus.onReceive ((_, busID, msg) ->
          words = Array.from(msg.data16)
          return unless words.length == READ_WORDS
          console.log "#{busID}: #{fmtReply words}"
          process.exit(0) if left <= 0
        ), null

        send = () ->
          left -= 1
          bus.sendMsg BusMsg.Command(CMD_READ)
          if left > 0 then setTimeout send, 1000 else setTimeout (->
            console.error "adta: no reply on #{busName}"
            process.exit(1)), READ_MS
        setTimeout send, BIND_MS

    program.command('watch')
      .description('print the traffic between a unit and its MDM')
      .argument('[unit]', '1 to 4', '1')
      .action (what) ->
        n = wantUnit(what)
        name = ioBusName(UNIT_MDM[n])
        bus = new Bus(name, busConfig[name])
        bus.onReceive ((_, busID, msg) ->
          m = decodeIO(msg.data16)
          return unless m? and m.card == CARD and m.channel == CHANNEL
          line = fmtIO(m)
          line += "  #{fmtReply m.words}" if m.op == IO_OP.VALUE and m.words.length >= 1
          console.log "#{busID}: #{line}"
        ), null
        console.log "watching #{name} (port #{busConfig[name].port}), ^C to stop"
        holdOpen()

    program.command('status')
      .description('the mode status word, bit by bit')
      .action () ->
        console.log "ADTA mode status, bit 0 the high bit; nominal #{hex4 NOMINAL_STATUS}"
        for n in [0..15]
          bit = statusBit(n)
          nom = if NOMINAL_STATUS & bit then 1 else 0
          sense = if MODE_BITS & bit then '1 on  ' else if FAIL_BITS & bit then '1 fail' else '1 good'
          console.log "  bit #{String(n).padStart(2)}  #{hex4 bit}  nominal #{nom}  " +
                      "#{sense}  #{fmtStatus(bit)}"
        console.log ''
        console.log "MDM wiring: card #{CARD} channel #{CHANNEL}"
        for n in [1, 2, 3, 4]
          console.log "  ADTA #{n}  MDM #{UNIT_MDM[n]} on #{UNIT_BUS[n]}, " +
                      "#{PROBE[n]} probe, #{UNIT_FEED[n]}"
