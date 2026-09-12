# ddu -- the GPC's flight instrument output on the flight critical busses
#
import {Bus, BusMsg, busConfig} from './../../com/bus.civet.jsx'
import {die as lruDie, holdOpen} from './../lruCli'
import {IUA, MSG, MSG_NAMES, commandWord, hex4, hex6, fmtWords,
        WORDS_OF, DECODE, TEST_WORD, wordValid, HFE_PERIOD_MS,
        decodeMEDS1, decodeMEDS2} from './dduConf'
import {IDPFcRx} from './../../meds/idp/idpFc'
import {FIELDS, FLAGS, defaultState, fieldOf, rampState, messagesOf} from './dduDrive'

BIND_MS = 150

die = (msg) -> lruDie 'ddu', msg

collect = (v, acc) -> (acc ? []).concat([v])

FC_BUSSES = ['FC1', 'FC2', 'FC3', 'FC4']

wantBusses = (s) ->
  t = String(s).toUpperCase()
  return FC_BUSSES.slice() if t == 'ALL'
  out = []
  for b in t.split(',')
    b = b.trim()
    b = "FC#{b}" if /^\d$/.test(b)
    die "busses are FC1 to FC4, a list of them, or all" unless b in FC_BUSSES
    out.push b
  out

openBus = (name, forSend = false) ->
  die "unknown bus '#{name}'" unless busConfig[name]?
  bus = new Bus(name, busConfig[name])
  bus.onReceive (->), null if forSend
  bus

# The GPC's framing: a command datagram, then the data words
# (gpc/iop_bce MIA.xmitCmd, xmitWord).
sendCommand = (bus, cmd24) ->
  bus.sendMsg BusMsg.Command(cmd24)

sendWord = (bus, hw) ->
  msg = new BusMsg(1)
  msg.data16[0] = hw & 0xffff
  bus.sendMsg msg

sendMessage = (bus, m) ->
  sendCommand bus, commandWord(m.iua, m.msg)
  sendWord bus, w for w in m.words
  return

export SPEC =
  id:      'ddu'
  title:   'GPC flight instrument output'
  summary: "the GPC's flight instrument output on the flight critical busses"
  usage: [
    'Examples:'
    '  ddu drive FC1 --mm 305 --ramp'
    '  ddu drive all --set rollDeg=15 --off ADI.rollRate'
    '  ddu watch FC1 --msg ADI'
    '  ddu words adi'
    '  ddu decode adi 8000 5a5a 0000'
    '  ddu fields'
  ]
  tables: ['words', 'decode', 'fields']

  tools: (program) ->


    program.command('drive')
      .description('drive DDU and MEDS data on FC busses until ^C')
      .argument('<busses>', 'FC1..FC4, a list FC1,FC3, or all')
      .option('--mm <n>', 'major mode', '305')
      .option('--abort <mode>', 'RTLS | TAL | AOA | ATO | CA')
      .option('--ramp', 'every ranged field runs over its range')
      .option('--period <s>', 'ramp period in seconds; each field adds a second to it', '60')
      .option('--set <field=value>', 'one field held at a value (ddu fields), repeatable', collect, [])
      .option('--off <MSG.word>', 'leave a control bit clear, repeatable', collect, [])
      .option('--ddu <list>', 'the DDUs written', '1,2,3')
      .option('--no-meds', 'leave the MEDS transfer out')
      .option('--rate <hz>', 'cycles a second', String(1000 / HFE_PERIOD_MS))
      .action (bussesStr, o) ->
        busses = wantBusses(bussesStr)
        base = defaultState()
        base.majorMode = parseInt(o.mm, 10)
        die "bad --mm" unless isFinite(base.majorMode)
        if o.abort?
          a = String(o.abort).toUpperCase()
          die "abort modes are RTLS, TAL, AOA, ATO, CA" unless a in ['RTLS', 'TAL', 'AOA', 'ATO', 'CA']
          base.abortMode = a
        for s in o.set
          m = String(s).match(/^([^=]+)=(.*)$/)
          die "bad --set '#{s}' (want <field>=<value>)" unless m?
          f = fieldOf(m[1])
          die "no field '#{m[1]}' (ddu fields lists them)" unless f?
          v = m[2]
          base[m[1]] = if v in ['true', 'on', 'yes'] then true
          else if v in ['false', 'off', 'no'] then false
          else if v == 'none' then null
          else if isFinite(parseFloat(v)) and typeof f[1] != 'string' then parseFloat(v)
          else v
        for n in o.off
          m = String(n).match(/^(ADI|HSI|AVVI|AMI)\.(\w+)$/i)
          die "bad --off '#{n}' (want MSG.word, as ADI.rollRate)" unless m? and WORDS_OF[m[1].toUpperCase()].includes(m[2])
        offWords = (n.replace(/^(\w+)\./, (_, m) -> m.toUpperCase() + '.') for n in o.off)
        ddus = (parseInt(d, 10) for d in String(o.ddu).split(','))
        die "DDUs are 1, 2 and 3" unless ddus.every((d) -> d in [1, 2, 3])
        period = parseFloat(o.period)
        rateHz = parseFloat(o.rate)
        die "bad --rate" unless rateHz > 0
        bus = {}
        bus[b] = openBus(b, true) for b in busses
        t0 = Date.now()
        tick = ->
          s = if o.ramp then rampState((Date.now() - t0) / 1000, period, base) else base
          msgs = messagesOf(s, {offWords, ddus, meds: o.meds})
          for _, b of bus
            sendMessage b, m for m in msgs
          return
        console.log "DDU drive on #{busses.join(' ')}: MM #{base.majorMode}#{if base.abortMode then ' ' + base.abortMode else ''}, " +
                    "#{if o.ramp then 'ramping' else 'holding'}, DDU #{ddus.join(',')}#{if o.meds then ' and the MEDS transfer' else ''}, " +
                    "#{rateHz} Hz, ^C to stop"
        setTimeout (-> setInterval tick, 1000 / rateHz), BIND_MS


    fmtDecoded = (m) ->
      w = m.words
      switch m.msg
        when 'ADI', 'HSI', 'AVVI', 'AMI'
          d = DECODE[m.msg](w)
          names = WORDS_OF[m.msg]
          parts = []
          for n, i in names when i >= 2
            v = d[n]
            v = (if Math.abs(v) >= 100 then v.toFixed(0) else v.toFixed(3)) if typeof v == 'number'
            parts.push "#{n}=#{v}#{if wordValid(w[0], i) then '' else '(off)'}"
          "control #{hex4 w[0]} test #{hex4 w[1]}#{if w[1] == TEST_WORD[m.msg] then '' else '(!)'} " + parts.join(' ')
        when 'MEDS1'
          d = decodeMEDS1(w)
          on_ = (n for n, v of d.valid when v)
          "MM #{d.majorMode} #{d.abortMode ? ''} iphase #{d.iphase} islect #{d.islect} DAP #{if d.dapAuto then 'auto' else 'css'} " +
            "throt #{if d.throtAuto then 'auto' else 'man'} scale rr #{d.scale.rollRateL} pr #{d.scale.pitchRateL} " +
            "pe #{d.scale.pitchErrL} site '#{d.siteId}' Nz #{d.targetNz.toFixed(2)} beta #{d.beta} dAz #{d.dAz} valid #{on_.join(',')}"
        when 'MEDS2'
          d = decodeMEDS2(w)
          "xtrk #{d.xtrk} dev #{d.xtrkDev} tgtIncl #{d.tgtIncl}"
        else
          fmtWords(w)

    program.command('watch')
      .description('print the DDU and MEDS traffic on an FC bus, decoded')
      .argument('<bus>', 'FC1..FC4')
      .option('--raw', 'the words in hex')
      .option('--msg <name>', 'only this message (ADI, HSI, AVVI, AMI, MEDS1..4)')
      .action (busStr, o) ->
        [name] = wantBusses(busStr)
        bus = openBus(name)
        only = o.msg?.toUpperCase()
        die "messages are #{MSG_NAMES.join(', ')}" if only? and not MSG[only]?
        rx = new IDPFcRx(Number(name[2]), onMessage: (m) ->
          return if only? and m.msg != only
          who = if m.ddu? then "DDU #{m.ddu}" else "IUA #{m.iua}"
          body = if o.raw then fmtWords(m.words) else fmtDecoded(m)
          console.log "#{name} #{who} #{m.msg}: #{body}")
        bus.onReceive ((_, busID, msg) -> rx.recv(msg.data16, msg.cmd)), null
        console.log "watching #{name} for DDU 1-3 and the MEDS transfer, ^C to stop"
        holdOpen()

    program.command('words')
      .description("a message's words")
      .argument('[msg]', 'adi, hsi, avvi, ami or meds')
      .action (msgStr) ->
        show = (name) ->
          console.log "#{name}: IUA #{if name.startsWith('MEDS') then IUA.MEDS else IUA.DDU1 + '/' + IUA.DDU2 + (if name == 'ADI' then '/' + IUA.DDU3 else '')}, " +
                      "command payload #{hex6 commandWord(0, name)}, #{MSG[name].wc} words"
          if WORDS_OF[name]?
            for n, i in WORDS_OF[name]
              console.log "  #{String(i + 1).padStart(2)}  #{n}"
        if msgStr?
          n = String(msgStr).toUpperCase()
          if n == 'MEDS'
            show m for m in ['MEDS1', 'MEDS2', 'MEDS3', 'MEDS4']
          else
            die "messages are adi, hsi, avvi, ami, meds" unless WORDS_OF[n]?
            show n
        else
          show m for m in MSG_NAMES

    program.command('decode')
      .description('decode words given in hex')
      .argument('<msg>', 'adi, hsi, avvi, ami, meds1 or meds2')
      .argument('<words...>', 'the data words, hex')
      .action (msgStr, wordsStr) ->
        name = String(msgStr).toUpperCase()
        die "messages are adi, hsi, avvi, ami, meds1, meds2" unless MSG[name]?
        words = (parseInt(w, 16) for w in wordsStr)
        die "bad hex word" if words.some((w) -> not isFinite(w))
        words.push 0 while words.length < MSG[name].wc
        console.log fmtDecoded({msg: name, words})

    program.command('fields')
      .description("the drive's fields, their defaults and ramp ranges")
      .action ->
        for f in FIELDS
          range = if f[2]? then "#{f[2]}..#{f[3]}" else ''
          console.log "  #{f[0].padEnd(14)} #{String(f[1]).padStart(7)} #{f[4].padEnd(6)} #{range.padEnd(14)} #{f[5]}"
        for f in FLAGS
          console.log "  #{f[0].padEnd(14)} #{String(f[1]).padStart(7)} #{''.padEnd(6)} #{''.padEnd(14)} #{f[2]}"
