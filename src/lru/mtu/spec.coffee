# mtu -- the Master Timing Unit
#
import {Bus, BusMsg, busConfig} from './../../com/bus.civet.jsx'
import {die as lruDie, holdOpen} from './../lruCli'
import {IO_OP, ioBusName, decodeIO, fmtIO} from './../mdm/mdmConf'
import {MTU} from './mtu'
import {ACCUM_MDM, ACCUM_BUS, CARD, CHANNEL, OI_OUTPUT, OI_CARD, OI_CHANNEL,
        CMD_READ, CMD_UPDATE, CMD_RESET,
        READ_WORDS, MODE, MS_PER_DAY,
        packTime, unpackTimeMs, packMode,
        fmtTime, parseTime, fmtBite} from './mtuConf'

BIND_MS = 150
READ_MS = 2000

die = (msg) -> lruDie 'mtu', msg

hex4 = (v) -> (v & 0xffff).toString(16).padStart(4, '0')

wantTime = (s, what) ->
  ms = parseTime(s)
  die "bad #{what} '#{s}' (want DDD:HH:MM:SS.sss)" unless ms?
  ms

wantAccum = (s) ->
  n = parseInt(s, 10)
  die "accumulators are 1, 2 and 3" unless ACCUM_MDM[n]
  n

# The host's UTC time as an accumulator reads it: day of year from 1,
# then time of day.
hostGmtMs = () ->
  d     = new Date()
  start = Date.UTC(d.getUTCFullYear(), 0, 1)
  d.getTime() - start + MS_PER_DAY

# "2=+0.9" or "2=-1.5", milliseconds.
parseSkew = (s) ->
  m = String(s).match(/^([123])\s*=\s*([-+]?[\d.]+)$/)
  die "bad --skew '#{s}' (want <accumulator>=<milliseconds>)" unless m?
  {accum: parseInt(m[1], 10), ms: Number(m[2])}

fmtReply = (words) ->
  gmt = unpackTimeMs(words.slice(0, 3))
  met = unpackTimeMs(words.slice(3, 6))
  "GMT #{fmtTime(gmt)}  MET #{fmtTime(met)}  BITE #{hex4 words[6]} (#{fmtBite words[6]})"

export SPEC =
  id:      'mtu'
  title:   'Master Timing Unit'
  summary: 'Space Shuttle Master Timing Unit -- device model and bus tools'
  usage: [
    'Examples:'
    '  mtu run'
    '  mtu run --accum 1,2 --gmt 052:14:30:00'
    '  mtu run --skew 2=+0.9 --fail 3 --disconnect 2'
    '  mtu read 1                 read accumulator 1 through MDM FF1, as a GPC does'
    '  mtu watch oi1              the traffic between MDM OF1 and the voted output'
    '  mtu time 052:14:30:00.125'
  ]
  tables: ['time', 'commands']

  run:
    summary: 'run the master timing unit behind its MDMs'
    options: [
      ['--accum <list>', 'accumulators to run (MDM FF1 / FF2 / FF3)', '1,2,3']
      ['--oi <list>',
       'instrumentation outputs to run: 1 (voted, OF1), 2 (non-voted, OF2), none', '1,2']
      ['--gmt <time>', 'GMT to start at, DDD:HH:MM:SS.sss (default: host UTC)']
      ['--met <time>', 'MET to start at', '000:00:00:00']
      {flag: '--skew <n=ms>', help: 'set accumulator skew, repeatable'
       many: true, apply: (mtu, s) ->
         k = parseSkew(s)
         die "accumulator #{k.accum} is not running" unless mtu.accums[k.accum]
         mtu.setSkew(k.accum, k.ms)}
      {flag: '--fail <n>'
       help: 'suppress an accumulator reply, repeatable'
       many: true, apply: (mtu, s) ->
         n = wantAccum(s)
         die "accumulator #{n} is not running" unless mtu.accums[n]
         mtu.setAnswers(n, false)}
      {flag: '--disconnect <n>', help: 'disconnect an accumulator, repeatable'
       many: true, apply: (mtu, s) ->
         n = wantAccum(s)
         die "accumulator #{n} is not running" unless mtu.accums[n]
         mtu.accums[n].connected = false}
      ['--osc <n>', 'driving oscillator, 1 or 2', '1']
      ['--rollover <days>', 'day GMT rolls over at: 365, 366, 375, 376 or 399', '365']
      'replyDelay'
      ['quiet', 'do not trace polls and writes']
    ]
    build: (o) ->
      accums = (wantAccum(s) for s in String(o.accum).split(',') when s.trim())
      die "no accumulators selected" unless accums.length
      outputs = if String(o.oi).toLowerCase() == 'none' then [] else
        (parseInt(s, 10) for s in String(o.oi).split(',') when s.trim())
      die "outputs are 1 and 2" for n in outputs when not OI_OUTPUT[n]
      new MTU({
        accumulators: accums
        outputs:      outputs
        gmtMs:        (if o.gmt then wantTime(o.gmt, 'GMT') else hostGmtMs())
        metMs:        wantTime(o.met, 'MET')
        oscillator:   parseInt(o.osc, 10)
        rolloverDays: parseInt(o.rollover, 10)
        replyDelayMs: parseFloat(o.replyDelay)
        verbose:      not o.quiet
      })

  tools: (program) ->
    program.command('read')
      .description('read an accumulator through its MDM, as a GPC does (test equipment)')
      .argument('[accumulator]', '1, 2 or 3', '1')
      .option('--repeat <n>', 'read this many times, one second apart', '1')
      .action (accStr, o) ->
        n = wantAccum(accStr)
        busName = ACCUM_BUS[n]
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
            console.error "mtu: no reply on #{busName}"
            process.exit(1)), READ_MS
        setTimeout send, BIND_MS

    program.command('watch')
      .description("print the traffic between an accumulator, or an output, and its MDM")
      .argument('[what]', 'accumulator 1, 2 or 3, or output oi1 or oi2', '1')
      .action (what) ->
        if /^oi[12]$/i.test(String(what))
          n = parseInt(String(what).slice(2), 10)
          name = ioBusName(OI_OUTPUT[n].mdm)
          [card, channel] = [OI_CARD, OI_CHANNEL]
        else
          n = wantAccum(what)
          name = ioBusName(ACCUM_MDM[n])
          [card, channel] = [CARD, CHANNEL]
        bus = new Bus(name, busConfig[name])
        bus.onReceive ((_, busID, msg) ->
          m = decodeIO(msg.data16)
          return unless m? and m.card == card and m.channel == channel
          line = fmtIO(m)
          line += "  #{fmtReply m.words}" if m.op == IO_OP.VALUE and m.words.length == READ_WORDS
          console.log "#{busID}: #{line}"
        ), null
        console.log "watching #{name} (port #{busConfig[name].port}), ^C to stop"
        holdOpen()

    program.command('time')
      .description('the three halfwords an accumulator sends for a time')
      .argument('<time>', 'DDD:HH:MM:SS.sss')
      .action (s) ->
        ms = wantTime(s, 'time')
        w  = packTime(ms)
        console.log "#{fmtTime(ms)}  #{(hex4 x for x in w).join(' ')}"

    program.command('commands')
      .description('the MDM command words a GPC reads and writes an accumulator with')
      .action () ->
        show = (name, cmd) ->
          console.log "#{name.padEnd(8)} #{cmd.toString(16).padStart(6, '0')}"
        show 'read', CMD_READ
        show 'update', CMD_UPDATE
        show 'reset', CMD_RESET
        console.log ''
        for name, m of MODE
          console.log "mode #{name.padEnd(10)} #{hex4 packMode(m, 0)}"
