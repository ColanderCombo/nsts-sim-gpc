# nsp -- the Network Signal Processors and the forward link
#
import {Bus, BusMsg, busConfig} from './../../com/bus.civet.jsx'
import {die as lruDie, holdOpen} from './../lruCli'
import {IO_OP, ioBusName, decodeIO, fmtIO} from './../mdm/mdmConf'
import {NSP, FrameSync} from './nsp'
import {Uplink} from './uplink'
import {UNIT, CARD, CHANNEL, POWER_CHANNEL, BLOCK_CHANNEL, FWD_LINK_BUS
        MESSAGE_WORDS, COMMANDS, COMMAND_WORDS, CMD_READ, CMD_POWER, CMD_BLOCK
        STATUS, MODE_PARITY, fmtStatus, validityBit
        MF, MDM_NUMBER, packCommand, packRtc, fmtCommand, hex4
        RATE, frameUplinkBits, decodeUplinkWord, unpackStream
        bchParity, wordsToBits} from './nspConf'

BIND_MS   = 150
READ_MS   = 2000

die = (msg) -> lruDie 'nsp', msg

wantUnit = (s) ->
  n = parseInt(s, 10)
  die "NSPs are 1 and 2" unless UNIT[n]
  n

wantRate = (s) ->
  r = String(s).toUpperCase()
  die "rates are ldr (32 kbps) and hdr (72 kbps)" unless RATE[r]
  r

wantHalfwords = (tokens) ->
  for tok in tokens
    n = parseInt(tok, 16)
    die "bad halfword '#{tok}'" if isNaN(n) or n < 0 or n > 0xffff
    n

wantMf = (s) ->
  t = String(s).toUpperCase()
  return MF[t] if MF[t]?
  n = parseInt(t, 10)
  die "major function is GNC, SM, PL, BFS, ALL or a GPC number 1-5" unless n >= 1 and n <= 5
  n

fmtMessage = (words) ->
  lines = ["status #{hex4 words[0]} (#{fmtStatus words[0]})"]
  if words.length >= MESSAGE_WORDS
    v = words[MESSAGE_WORDS - 1]
    for i in [0...COMMANDS] by 1
      w = words[1 + i * COMMAND_WORDS ... 1 + (i + 1) * COMMAND_WORDS]
      continue unless w.some((x) -> x) or (v & validityBit(i))
      lines.push "  cmd #{String(i + 1).padStart(2)} #{(hex4 x for x in w).join(' ')}  " +
                 "#{if v & validityBit(i) then 'valid  ' else 'invalid'}  #{fmtCommand w}"
    lines.push "  validity #{hex4 v}"
  lines.join('\n')

# The forward link, driven from a list of command words.
streamCommands = (cmds, o) ->
  up = new Uplink({rate: wantRate(o.rate), chunkBits: parseInt(o.chunk, 10)})
  up.ready.then ->
    errors = parseInt(o.errors, 10)
    up.push(w, {errors}) for w in cmds
    pre = parseInt(o.preroll, 10)
    post = parseInt(o.postroll, 10)
    total = pre + cmds.length + post
    up.onFrame = (n, bits) ->
      return if o.quiet
      {words, ok} = decodeUplinkWord(frameUplinkBits(up.rate, bits))
      tag = if n <= pre then 'preroll' else if n <= pre + cmds.length then "command #{n - pre}" else 'postroll'
      console.log "frame #{String(n).padStart(3)}  #{tag.padEnd(10)}  #{(hex4 w for w in words).join(' ')}#{if ok then '' else '  (BCH fails)'}"
    console.log "#{up.rate.name} on #{FWD_LINK_BUS} (port #{busConfig[FWD_LINK_BUS].port}): " +
                "#{pre} idle frames, #{cmds.length} command#{if cmds.length == 1 then '' else 's'}, " +
                "#{post} idle frames#{if o.hold then ', then idle until ^C' else ''}"
    up.start(total).then ->
      if o.hold
        up.start()
      else
        setTimeout (-> up.close(); process.exit(0)), 100
    process.on 'SIGINT', -> up.close(); process.exit(0)

export SPEC =
  id:      'nsp'
  title:   'Network Signal Processor'
  summary: 'Space Shuttle Network Signal Processor -- device model and forward link tools'
  usage: [
    'Examples:'
    '  nsp run                            NSP 1 powered behind FF1, NSP 2 off behind FF3'
    '  nsp run --power 2 --rate hdr'
    '  nsp uplink 4a8b 1234 5678          one 48-bit command, three halfwords'
    '  nsp uplink $(nsp rtc FF1 10/0 set 0001)'
    '  nsp carrier                        the idle stream until ^C'
    '  nsp watch link                     the forward link, frame by frame'
    '  nsp rtc FF1 10/0 set 0001          the halfwords of a real-time command'
    '  nsp word --vehicle 2 --mf GNC --opcode 69 1a2b3c4d'
  ]
  tables: ['rtc', 'word', 'bch', 'commands']

  run:
    summary: 'run the two NSPs behind MDMs FF1 and FF3'
    options: [
      ['--units <list>', 'units to run', '1,2']
      ['--power <list>', 'units powered, or none', '1']
      ['--rate <ldr|hdr>', 'forward link data rate', 'ldr']
      ['--mode <name>',
       "receive mode, for the mode parity bits: #{Object.keys(MODE_PARITY).join(' ')}", 'STDN_LO']
      ['--uplink-switch <pos>', 'panel C3 UPLINK: enable, gpc-block or nsp-block', 'enable']
      ['--external', 'a PCMMU is feeding the return link (clears the internal mode bit)']
      {flag: '--bite <n=hex>', help: 'set status bits, repeatable'
       many: true, apply: (nsp, s) ->
         m = String(s).match(/^([12])\s*=\s*([0-9a-fA-F]{1,4})$/)
         die "bad --bite '#{s}' (want <unit>=<hex>)" unless m?
         nsp.setBite(parseInt(m[1], 10), parseInt(m[2], 16))}
      'replyDelay'
      ['quiet', 'do not trace frames and polls']
    ]
    build: (o) ->
      units = (wantUnit(s) for s in String(o.units).split(',') when s.trim())
      die "no units selected" unless units.length
      powered = if String(o.power).toLowerCase() == 'none' then [] else
        (wantUnit(s) for s in String(o.power).split(',') when s.trim())
      new NSP({
        units, powered
        rate:         wantRate(o.rate)
        mode:         String(o.mode).toUpperCase()
        uplinkSwitch: o.uplinkSwitch
        external:     !!o.external
        replyDelayMs: parseFloat(o.replyDelay)
        verbose:      not o.quiet
      })

  tools: (program) ->


    program.command('uplink')
      .description('send command words on the forward link: three hex halfwords each')
      .argument('<halfwords...>', '48-bit command words as hex halfwords')
      .option('--rate <ldr|hdr>', 'data rate', 'ldr')
      .option('--preroll <frames>', 'idle frames before the command', '4')
      .option('--postroll <frames>', 'idle frames after the command', '12')
      .option('--hold', 'keep the idle stream going afterwards')
      .option('--errors <n>', 'invert this many parity bits of every command', '0')
      .option('--chunk <bits>', 'split frames into datagrams of this many bits', '0')
      .option('-q, --quiet', 'do not print the frames')
      .action (tokens, o) ->
        words = wantHalfwords(tokens)
        die "a command is three halfwords" unless words.length and words.length % COMMAND_WORDS == 0
        cmds = (words[i...i + COMMAND_WORDS] for i in [0...words.length] by COMMAND_WORDS)
        streamCommands cmds, o

    program.command('carrier')
      .description('the idle stream, frames with the idle pattern, until ^C')
      .option('--rate <ldr|hdr>', 'data rate', 'ldr')
      .option('--chunk <bits>', 'split frames into datagrams of this many bits', '0')
      .action (o) ->
        streamCommands [], Object.assign({preroll: '0', postroll: '0', hold: true, errors: '0', quiet: true}, o)


    program.command('rtc')
      .description('the three halfwords of a real-time command to an MDM discrete output')
      .argument('<mdm>', 'FF1 .. LM1')
      .argument('<address>', 'card/channel')
      .argument('<set|reset>')
      .argument('<mask>', 'hex halfword')
      .option('--vehicle <n>', 'vehicle address, 3 bits', '2')
      .option('--mf <name>', 'major function or GPC', 'GNC')
      .option('--opcode <n>', 'op code (69 single, 3 multiple)', '69')
      .action (mdm, addr, setReset, maskStr, o) ->
        num = MDM_NUMBER[String(mdm).toUpperCase()]
        die "MDMs are #{Object.keys(MDM_NUMBER).join(' ')}" unless num?
        m = String(addr).match(/^(\d+)\/(\d+)$/)
        die "address is card/channel" unless m?
        set = String(setReset).toLowerCase()
        die "set or reset" unless set in ['set', 'reset']
        mask = parseInt(maskStr, 16)
        die "bad mask '#{maskStr}'" if isNaN(mask) or mask < 0 or mask > 0xffff
        data = packRtc {card: parseInt(m[1], 10), channel: parseInt(m[2], 10), set: set == 'set', mdm: num, mask}
        w = packCommand {vehicle: parseInt(o.vehicle, 10), mf: wantMf(o.mf), opcode: parseInt(o.opcode, 10), first: true, last: true}, data
        console.log (hex4 x for x in w).join(' ')

    program.command('word')
      .description('encode a command word')
      .argument('<data>', '32 data bits, hex')
      .option('--vehicle <n>', 'vehicle address, 3 bits', '2')
      .option('--mf <name>', 'major function or GPC', 'GNC')
      .option('--opcode <n>', 'op code', '69')
      .option('--first', 'first word of the load', true)
      .option('--no-first')
      .option('--last', 'last word of the load', true)
      .option('--no-last')
      .action (dataStr, o) ->
        data = parseInt(dataStr, 16)
        die "bad data '#{dataStr}'" if isNaN(data)
        w = packCommand {vehicle: parseInt(o.vehicle, 10), mf: wantMf(o.mf), opcode: parseInt(o.opcode, 10), first: o.first, last: o.last}, data >>> 0
        console.log "#{(hex4 x for x in w).join(' ')}  #{fmtCommand w}"

    program.command('bch')
      .description('the 77 parity bits of a command word, as hex')
      .argument('<halfwords...>', 'three hex halfwords')
      .action (tokens) ->
        words = wantHalfwords(tokens)
        die "a command is three halfwords" unless words.length == COMMAND_WORDS
        p = bchParity([0, 0].concat(wordsToBits(words)))
        s = p.join('')
        console.log "#{s.slice(0, 32)} #{s.slice(32, 64)} #{s.slice(64)}"
        console.log "0x#{BigInt("0b#{s}").toString(16).padStart(20, '0')}"

    program.command('commands')
      .description('the MDM command words a GPC reads an NSP with')
      .action () ->
        show = (name, cmd) ->
          console.log "#{name.padEnd(22)} #{cmd.toString(16).padStart(6, '0')}"
        show 'read (FF1 and FF3)', CMD_READ
        show 'NSP 1 power (FF1)', CMD_POWER[1]
        show 'NSP 2 power (FF3)', CMD_POWER[2]
        show 'uplink block (both)', CMD_BLOCK


    program.command('read')
      .description('read an NSP through its MDM, as a GPC does (test equipment)')
      .argument('[unit]', '1 or 2', '1')
      .option('--repeat <n>', 'read this many times, 320 ms apart', '1')
      .action (unitStr, o) ->
        n = wantUnit(unitStr)
        busName = UNIT[n].bus
        bus = new Bus(busName, busConfig[busName])
        left = parseInt(o.repeat, 10)
        bus.onReceive ((_, busID, msg) ->
          words = Array.from(msg.data16)
          return unless words.length == MESSAGE_WORDS or (words.length == 1 and msg.sev?)
          flagged = if msg.sev? then " (SEV #{msg.sev.map((b) -> b.toString(2).padStart(3, '0')).join(' ')})" else ''
          console.log "#{busID}: #{fmtMessage words}#{flagged}"
          process.exit(0) if left <= 0
        ), null
        send = () ->
          left -= 1
          bus.sendMsg BusMsg.Command(CMD_READ)
          if left > 0 then setTimeout send, 320 else setTimeout (->
            console.error "nsp: no reply on #{busName}"
            process.exit(1)), READ_MS
        setTimeout send, BIND_MS

    program.command('watch')
      .description('print the traffic between an NSP and its MDM, or the forward link frames')
      .argument('[what]', '1, 2 or link', '1')
      .option('--rate <ldr|hdr>', 'data rate of the link', 'ldr')
      .action (what, o) ->
        if String(what).toLowerCase() == 'link'
          bus = new Bus(FWD_LINK_BUS, busConfig[FWD_LINK_BUS])
          rate = RATE[wantRate(o.rate)]
          n = 0
          sync = new FrameSync rate, (bits) ->
            n += 1
            {words, ok} = decodeUplinkWord(frameUplinkBits(rate, bits))
            line = "frame #{String(n).padStart(4)}  #{(hex4 w for w in words).join(' ')}"
            line += "  #{fmtCommand words}" if words.some((w) -> w)
            line += "  (BCH fails)" unless ok
            console.log line
          bus.onReceive ((_, busID, msg) -> sync.feed unpackStream(msg.data16)), null
          console.log "watching #{FWD_LINK_BUS} (port #{busConfig[FWD_LINK_BUS].port}) as #{rate.name}, ^C to stop"
        else
          u = wantUnit(what)
          name = ioBusName(UNIT[u].mdm)
          bus = new Bus(name, busConfig[name])
          bus.onReceive ((_, busID, msg) ->
            m = decodeIO(msg.data16)
            return unless m?
            mine = (m.card == CARD and m.channel == CHANNEL) or
                   (m.card == UNIT[u].powerCard and m.channel == POWER_CHANNEL) or
                   (m.card == UNIT[u].blockCard and m.channel == BLOCK_CHANNEL)
            return unless mine
            line = fmtIO(m)
            line += "\n  #{fmtMessage(m.words).replace(/\n/g, '\n  ')}" if m.op == IO_OP.VALUE and m.card == CARD
            console.log "#{busID}: #{line}"
          ), null
          console.log "watching #{name} (port #{busConfig[name].port}), ^C to stop"
        holdOpen()
