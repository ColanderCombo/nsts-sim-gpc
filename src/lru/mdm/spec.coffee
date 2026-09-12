# mdm -- one Multiplexer/Demultiplexer of the catalog
#
import {Bus, BusMsg, busConfig} from './../../com/bus.civet.jsx'
import {die as lruDie, holdOpen} from './../lruCli'
import {MDM} from './mdm'
import {MDM_CATALOG} from './mdmConfig'
import {buildProm} from './prom'
import {IO_OP, IO_OP_NAME, SERIAL_ANSWER_MS, ioBusName, decodeCommand, fmtCommand,
        decodePromWord, fmtPromWord, promClassOf, encodeIO, decodeIO, fmtIO, parseIOAddr,
        voltsToWord, wordToVolts, voltsToAodWord, aodWordToVolts, cardChannels,
        iomType, PROM_CLASS_WORDS} from './mdmConf'

BIND_MS   = 150
LINGER_MS = 250

die = (msg) -> lruDie 'mdm', msg

hex4 = (v) -> (v & 0xffff).toString(16).padStart(4, '0')

wantEntry = (id) ->
  e = MDM_CATALOG[id]
  die "no MDM '#{id}' (mdm list)" unless e?
  e

wantBus = (name) ->
  die "unknown bus '#{name}'" unless name of busConfig
  new Bus(name, busConfig[name])

IO_OPS = ['set', 'reset', 'value', 'request', 'connect', 'disconnect', 'watch']

parseWords = (tokens, o, type) ->
  for tok in tokens
    if o.volts
      v = parseFloat(tok)
      die "bad voltage '#{tok}'" if isNaN v
      if iomType(type)?.name == 'AOD' then voltsToAodWord(v) else voltsToWord(v)
    else
      n = parseInt(tok, 16)
      die "bad halfword '#{tok}'" if isNaN(n) or n < 0 or n > 0xffff
      n

ioWatch = (id, o) ->
  wantEntry(id)
  name = ioBusName(id)
  bus = wantBus(name)
  bus.onReceive ((_, busID, msg) ->
    m = decodeIO(msg.data16)
    unless m?
      console.log "#{busID}: #{(hex4 w for w in msg.data16).join(' ')}"
      return
    line = fmtIO(m)
    if o.volts and m.words.length and iomType(m.type)?.kind == 'analog'
      toV = if iomType(m.type).name == 'AOD' then aodWordToVolts else wordToVolts
      line += "  (#{(toV(w).toFixed(3) for w in m.words).join(' ')} V)"
    console.log "#{busID}: #{line}"
  ), null
  console.log "watching #{name} (port #{busConfig[name].port}), ^C to stop"
  holdOpen()

ioSend = (id, op, addrStr, tokens, o) ->
  e = wantEntry(id)
  die "#{op} needs a card/channel address" unless addrStr?
  a = parseIOAddr(addrStr)
  die "bad address '#{addrStr}' (want card/channel, * for every)" unless a?
  t = iomType(e.iom?[a.card])
  type = if o.type then (iomType(o.type) ? die "unknown card type '#{o.type}'").code else (t?.code ? 0)
  bare = op in [IO_OP.REQUEST, IO_OP.CONNECT, IO_OP.DISCONNECT]
  words = if bare then [] else parseWords(tokens, o, type)
  die "#{IO_OP_NAME[op]} needs at least one word" unless words.length or bare
  bus = wantBus ioBusName(id)
  bus.onReceive (->), null
  setTimeout (->
    data = encodeIO {op, type, card: a.card, channel: a.channel, words}
    m = new BusMsg(data.length)
    m.data16.set data
    bus.sendMsg m
    console.log "#{ioBusName(id)}: #{fmtIO decodeIO(data)}"
    setTimeout (-> process.exit(0)), LINGER_MS
  ), BIND_MS

export SPEC =
  id:      'mdm'
  title:   'Multiplexer/Demultiplexer'
  summary: 'Space Shuttle Multiplexer/Demultiplexer -- device model and bus tools'
  usage: [
    'Examples:'
    '  mdm run FF1                          answer a GPC as MDM FF1'
    '  mdm list                             the catalog'
    '  mdm cards FF1                        the cards in a unit'
    '  mdm prom FF1                         the PROM programs a unit runs'
    '  mdm io FF1 set 4/0 8000              drive a discrete input'
    '  mdm io FF1 value 1/3 --volts 2.5     drive an analog input'
    "  mdm io FF1 request '2/*'             ask for an output card's state"
    '  mdm io FF1 watch                     the hardware side traffic'
    '  mdm watch FC1 --decode               the flight bus traffic'
    '  mdm send FC1 518000                  put one command on a bus'
  ]
  tables: ['list', 'cards', 'prom']

  run:
    summary: 'run one MDM on its flight busses and its hardware side bus'
    args: [['<id>', 'catalog id, e.g. FF1']]
    options: [
      ['--bus-pri <name>', 'override the primary port bus']
      ['--bus-sec <name>', 'override the secondary port bus']
      ['--iua <n>', 'override the interface unit address']
      ['--reply-delay <ms>', 'delay before answering a command', '0']
      ['--serial-answer <ms>', "wall time allowed for a connected serial device's answer",
       String(SERIAL_ANSWER_MS)]
      ['--mdm', 'an original MDM: three channels on a discrete output card, not nine']
      ['quiet', 'do not trace commands']
    ]
    build: (o, id) ->
      wantEntry(id)
      new MDM({
        id
        busPri:         o.busPri
        busSec:         o.busSec
        iua:            (if o.iua? then parseInt(o.iua, 10))
        verbose:        not o.quiet
        replyDelayMs:   parseFloat(o.replyDelay)
        serialAnswerMs: parseFloat(o.serialAnswer)
        emdm:           not o.mdm
      })

  tools: (program) ->


    program.command('list')
      .description('the MDM catalog')
      .action () ->
        for id, e of MDM_CATALOG
          ports = if e.busPri? then "#{e.busPri}/#{e.busSec}" else '-'
          iua = if e.iua? then e.iua else '-'
          console.log "#{id.padEnd(4)} #{ports.padEnd(8)} IUA #{String(iua).padEnd(3)} #{e.nom}"

    program.command('cards')
      .description('the cards in a unit, slot by slot')
      .argument('<id>', 'catalog id')
      .action (id) ->
        e = wantEntry(id)
        console.log "#{id}: #{e.nom}"
        for slot in [0...16] by 1
          t = iomType(e.iom?[slot])
          if t?
            console.log "  #{String(slot).padStart(2)}  #{t.name}  #{String(cardChannels(t, e)).padStart(2)} ch  #{t.dir.padEnd(4)} #{t.nom}"
          else
            console.log "  #{String(slot).padStart(2)}  empty"

    program.command('prom')
      .description('decode the PROM a unit runs')
      .argument('<id>', 'catalog id')
      .option('--all', 'every nonzero word, not only the programs')
      .action (id, o) ->
        e = wantEntry(id)
        {prom, programs} = buildProm(e)
        console.log "#{id}: card classes"
        cls = ("#{i}:#{promClassOf(prom[i])}" for i in [0...PROM_CLASS_WORDS] by 1)
        console.log "  #{cls.join(' ')}"
        if o.all
          for w, a in prom when w and a >= PROM_CLASS_WORDS
            console.log "  #{String(a).padStart(3)}  #{hex4 w}  #{fmtPromWord decodePromWord(w)}"
        else
          for p in programs
            total = 0
            total += i.count for i in p.instr
            console.log "  location #{p.loc}, #{p.instr.length} instructions, #{total} words"
            for i in p.instr
              console.log "    #{String(i.loc).padStart(3)}  #{hex4 prom[i.loc]}  #{fmtPromWord decodePromWord(prom[i.loc])}"


    program.command('io')
      .description('drive and watch the hardware side of a unit')
      .argument('<id>', 'catalog id')
      .argument('<op>', IO_OPS.join('|') + ': set/reset discretes by mask, value channels, ' +
                        'request what the unit holds, plug a serial device in or out, or watch the bus')
      .argument('[address]', "card/channel; '*' for every, e.g. '2/*'")
      .argument('[words...]', 'hex halfwords, one per channel from the address up')
      .option('--volts', 'the words are voltages')
      .option('--type <iom>', 'tag with this card type instead of the catalog one')
      .action (id, op, addr, words, o) ->
        die "op must be one of #{IO_OPS.join(', ')}" unless op in IO_OPS
        return ioWatch(id, o) if op == 'watch'
        ioSend id, IO_OP[op.toUpperCase()], addr, words, o


    program.command('watch')
      .description('print the traffic on a flight bus')
      .argument('[bus]', 'bus name', 'FC1')
      .option('--decode', 'decode command words as MDM commands')
      .action (busName, o) ->
        bus = wantBus(busName)
        bus.onReceive ((_, busID, msg) ->
          words = msg.data16
          if o.decode and msg.cmd
            cmd = ((words[0] & 0xffff) << 8) | ((words[1] >> 8) & 0xff)
            c = decodeCommand(cmd)
            console.log "#{busID}: CMD #{cmd.toString(16).padStart(6, '0')}  IUA #{c.iua}  #{fmtCommand c}"
          else
            hex = (hex4 words[i] for i in [0...Math.min(words.length, 16)])
            more = if words.length > 16 then " ... (#{words.length} words)" else ''
            console.log "#{busID}: #{hex.join(' ')}#{more}"
        ), null
        console.log "watching #{busName} (port #{busConfig[busName].port}), ^C to stop"
        holdOpen()

    program.command('send')
      .description('put a command on a flight bus (test equipment)')
      .argument('<bus>', 'bus name, e.g. FC1')
      .argument('<cmd24>', '24-bit command word in hex')
      .argument('[data...]', 'data words to follow it, hex halfwords')
      .action (busName, cmdStr, data) ->
        bus = wantBus(busName)
        cmd = parseInt(cmdStr, 16) & 0xffffff
        bus.onReceive ((_, busID, msg) ->
          console.log "#{busID}: #{(hex4 w for w in msg.data16).join(' ')}"), null
        setTimeout (->
          bus.sendMsg BusMsg.Command(cmd)
          console.log "#{busName}: sent #{cmd.toString(16).padStart(6, '0')}  #{fmtCommand decodeCommand(cmd)}"
          for tok in data
            m = new BusMsg(1)
            m.data16[0] = parseInt(tok, 16) & 0xffff
            bus.sendMsg m
          setTimeout (-> process.exit(0)), LINGER_MS
        ), BIND_MS
