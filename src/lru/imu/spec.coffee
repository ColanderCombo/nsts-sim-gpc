# imu -- the three Inertial Measurement Units
#
import {Bus, BusMsg, busConfig} from './../../com/bus.civet.jsx'
import {die as lruDie, holdOpen} from './../lruCli'
import {IO_OP, ioBusName, decodeIO, fmtIO} from './../mdm/mdmConf'
import {IMU} from './imu'
import {UNIT_MDM, UNIT_BUS, UNIT_FEED, CARD, CHANNEL,
        CMD_READ, READ_WORDS, STATUS, NOMINAL_STATUS, statusBit,
        fmtStatus, torques} from './imuConf'

BIND_MS = 150
READ_MS = 2000

die = (msg) -> lruDie 'imu', msg

hex4 = (v) -> (v & 0xffff).toString(16).padStart(4, '0')

wantUnit = (s) ->
  n = parseInt(s, 10)
  die "units are 1, 2 and 3" unless UNIT_MDM[n]
  n

# "3=PLATFORM_FAIL" or "3=0x2000".
parseFault = (s) ->
  m = String(s).match(/^([123])\s*=\s*(\w+)$/)
  die "bad --fail '#{s}' (want <unit>=<bit name or mask>)" unless m?
  bits = if /^0x/i.test(m[2]) or /^\d+$/.test(m[2]) then Number(m[2]) else STATUS[m[2].toUpperCase()]
  die "no such mode status bit '#{m[2]}'" unless bits
  {unit: parseInt(m[1], 10), bits}

fmtReply = (words) ->
  [tx, ty, tz] = torques(words[12] ? 0)
  "status #{hex4 words[0]} (#{fmtStatus words[0]})" +
  (if words.length > 13 then "  echo #{hex4 words[12]} #{hex4 words[13]} " +
                             "(torque #{tx}/#{ty}/#{tz} arcsec)" else '')

export SPEC =
  id:      'imu'
  title:   'Inertial Measurement Unit'
  summary: 'Space Shuttle Inertial Measurement Units -- device model and bus tools'
  usage: [
    'Examples:'
    '  imu run'
    '  imu run --units 1,2 --fail 3=PLATFORM_FAIL --silent 2'
    '  imu read 1                 read IMU 1 through MDM FF1 on FC1, as a GPC does'
    '  imu watch 1                the traffic between MDM FF1 and IMU 1'
    '  imu status                 the mode status bits and their nominals'
  ]
  tables: ['status']

  run:
    summary: 'run the inertial measurement units behind their MDMs'
    options: [
      ['--units <list>', 'units to run (MDM FF1 / FF2 / FF3)', '1,2,3']
      {flag: '--fail <n=bit>', help: 'set a status bit, repeatable'
       many: true, apply: (imu, s) ->
         k = parseFault(s)
         die "IMU #{k.unit} is not running" unless imu.units[k.unit]
         imu.setFault(k.unit, k.bits)}
      {flag: '--silent <n>', help: 'suppress a unit reply, repeatable'
       many: true, apply: (imu, s) -> imu.setAnswers(wantUnit(s), false)}
      {flag: '--disconnect <n>', help: 'disconnect a unit, repeatable'
       many: true, apply: (imu, s) -> imu.units[wantUnit(s)].connected = false}
      'replyDelay'
      ['quiet', 'do not trace polls and writes']
    ]
    build: (o) ->
      units = (wantUnit(s) for s in String(o.units).split(',') when s.trim())
      die "no units selected" unless units.length
      new IMU({
        units:        units
        replyDelayMs: parseFloat(o.replyDelay)
        verbose:      not o.quiet
      })

  tools: (program) ->
    program.command('read')
      .description('read a unit through its MDM, as a GPC does (test equipment)')
      .argument('[unit]', '1, 2 or 3', '1')
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
            console.error "imu: no reply on #{busName}"
            process.exit(1)), READ_MS
        setTimeout send, BIND_MS

    program.command('watch')
      .description('print the traffic between a unit and its MDM')
      .argument('[unit]', '1, 2 or 3', '1')
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
        console.log "IMU mode status, bit 0 the high bit; nominal #{hex4 NOMINAL_STATUS}"
        for n in [0..15]
          bit = statusBit(n)
          nom = if NOMINAL_STATUS & bit then 1 else 0
          console.log "  bit #{String(n).padStart(2)}  #{hex4 bit}  nominal #{nom}  " +
                      "#{fmtStatus(bit)}"
        console.log ''
        console.log "MDM wiring: card #{CARD} channel #{CHANNEL}"
        for n in [1, 2, 3]
          console.log "  IMU #{n}  MDM #{UNIT_MDM[n]} on #{UNIT_BUS[n]}, #{UNIT_FEED[n]}"
