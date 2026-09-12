# pcmmu -- the PCM Master Units and their telemetry streams
#
import {Bus, BusMsg, busConfig} from './../../com/bus.civet.jsx'
import {die as lruDie, holdOpen} from './../lruCli'
import {decodeCommand as decodeMdmCommand, fmtCommand as fmtMdmCommand, SEV} from './../mdm/mdmConf'
import {PCMMU} from './pcmmu'
import {UNIT, HDR_BUS, LDR_BUS, OI_MDMS, ipBusOf, OP, TB_WORDS, RAM_WORDS
        decodeCommand, fmtCommand, CMD_WRITE_TB, CMD_READ_TB, CMD_EOM, CMD_READ_RAM, CMD_READ_BITE
        CMD_FMT_SELECT, CMD_LOAD_FMT, CMD_READ_FMT
        decodeFrame, fmtFrame, fmtBSR, BSR_MSID, bsrBit, BSR_NAME
        unpackStream, decodeMinorFrame, hex4, hex6} from './pcmmuConf'
import {buildFetch} from './fetch'
import {FORMATS, formatLayout} from './tlmFormat'

BIND_MS   = 150
READ_MS   = 2000

die = (msg) -> lruDie 'pcmmu', msg

wantGpc = (s) ->
  n = parseInt(s, 10)
  die "GPCs are 1 to 5" unless n >= 1 and n <= 5
  n

wantInt = (s, what, lo, hi) ->
  n = parseInt(s, 10)
  die "#{what} is #{lo} to #{hi}" if isNaN(n) or n < lo or n > hi
  n

fmtSev = (sev) -> sev.map((b) -> b.toString(2).padStart(3, '0')).join(' ')

# One command on a GPC's IP bus and the response, printed.
gpcTransaction = (gpc, cmd24, o, onWords) ->
  name = ipBusOf(gpc)
  bus = new Bus(name, busConfig[name])
  c = decodeCommand(cmd24)
  got = []; sev = []
  bus.onReceive ((_, busID, msg) ->
    words = Array.from(msg.data16)
    return if msg.cmd
    for w, i in words
      got.push w
      sev.push msg.sev?[i] ? SEV.VALID
    if got.length >= c.count
      onWords got[0...c.count], sev[0...c.count]
      process.exit(0)
  ), null
  setTimeout (->
    bus.sendMsg BusMsg.Command(cmd24)
    setTimeout (->
      console.error "pcmmu: no reply on #{name}"
      process.exit(1)), READ_MS
  ), BIND_MS

watchGpc = (gpc) ->
  name = ipBusOf(gpc)
  bus = new Bus(name, busConfig[name])
  pending = null
  frame = []
  bus.onReceive ((_, busID, msg) ->
    words = Array.from(msg.data16)
    if msg.cmd
      c = decodeCommand(((words[0] & 0xffff) << 8) | ((words[1] >> 8) & 0xff))
      switch c.op
        when OP.WRITE_TB
          frame = [] if c.tbAddr == 0
          pending = {c, got: []}
        when OP.EOM
          d = decodeFrame(frame)
          line = "#{busID}: #{fmtCommand c}"
          line += "  #{fmtFrame frame}" if d?
          line += "  #{(hex4 w for w in frame[0...8]).join(' ')}" if frame.length
          console.log line
          pending = null
        else
          console.log "#{busID}: #{hex6 c.raw}  #{fmtCommand c}"
          pending = if c.io and c.op != OP.EOM then {c, got: []} else null
      return
    if pending?
      pending.got = pending.got.concat(words)
      if pending.got.length >= pending.c.count
        if pending.c.op == OP.WRITE_TB
          frame = frame.concat(pending.got[0...pending.c.count])
        else
          console.log "  data #{(hex4 w for w in pending.got[0...pending.c.count]).join(' ')}"
        pending = null
      return
    flagged = if msg.sev? then "  (SEV #{fmtSev msg.sev})" else ''
    console.log "  response #{(hex4 w for w in words).join(' ')}#{flagged}"
  ), null
  console.log "watching #{name} (port #{busConfig[name].port}), ^C to stop"

watchStream = (which, o) ->
  name = if which == 'hdr' then HDR_BUS else LDR_BUS
  bus = new Bus(name, busConfig[name])
  every = parseInt(o.every, 10)
  n = 0
  bus.onReceive ((_, busID, msg) ->
    n += 1
    bytes = unpackStream(msg.data16)
    f = decodeMinorFrame(bytes)
    return unless f?
    return if every > 1 and f.count % every
    line = "#{String(f.count).padStart(2)} #{if f.sync then 'sync' else 'nosync'} #{bytes.length} bytes"
    words = f.words
    if o.all
      line += "\n   " + (hex4(w) for w in words).join(' ').replace(/((?:[0-9a-f]{4} ){16})/g, '$1\n   ')
    else
      line += "  #{(hex4 w for w in words[0...12]).join(' ')} ..."
    d = decodeFrame(words)
    line += "\n   downlist #{fmtFrame words}" if d?
    console.log line
  ), null
  console.log "watching #{name} (port #{busConfig[name].port}), ^C to stop"

watchOi = (unit) ->
  name = UNIT[unit].oiBus
  bus = new Bus(name, busConfig[name])
  bus.onReceive ((_, busID, msg) ->
    words = Array.from(msg.data16)
    if msg.cmd
      c = decodeMdmCommand(((words[0] & 0xffff) << 8) | ((words[1] >> 8) & 0xff))
      console.log "#{busID}: cmd #{fmtMdmCommand c}"
    else
      flagged = if msg.sev? then "  (SEV #{fmtSev msg.sev})" else ''
      console.log "  #{(hex4 w for w in words).join(' ')}#{flagged}"
  ), null
  console.log "watching #{name} (port #{busConfig[name].port}), ^C to stop"

export SPEC =
  id:      'pcmmu'
  title:   'PCM Master Unit'
  summary: 'Space Shuttle PCM Master Unit -- device model and telemetry tools'
  usage: [
    'Examples:'
    '  pcmmu run                          PCMMU 1 powered, FORMAT switch at GPC'
    '  pcmmu run --hdr-format 161 --ldr-format 103'
    "  pcmmu watch gpc 4                  GPC 4's commands on IP4, downlist frames decoded"
    '  pcmmu watch hdr                    the 128 kbps stream, minor frame by minor frame'
    '  pcmmu read --gpc 5 2043 3          read the OI/PL RAM as a GPC does, on a spare bus'
    '  pcmmu tb --gpc 5 1 0 8             read toggle buffer 1, the formatter side'
    '  pcmmu map [OF1]                    the fetch program: RAM address by MDM card/channel'
  ]
  tables: ['commands', 'map', 'formats']

  run:
    summary: 'run the two PCMMUs on the IP busses, the OI busses and the two streams'
    options: [
      ['--units <list>', 'units to run', '1,2']
      ['--power <n>', 'the powered unit, 1, 2 or none', '1']
      ['--format-switch <pos>', 'panel C3 OI PCMMU FORMAT: fixed, gpc or program', 'gpc']
      ['--hdr-format <id>', 'preload the 128-kbps format RAM from the library (none by default)']
      ['--ldr-format <id>', 'preload the 64-kbps format RAM from the library, or none', '102']
      ['--mdms <list>', 'the OI MDMs the fetch reads', OI_MDMS.join(',')]
      ['--mtu-fail', 'the 4.608 MHz input is absent: BSR bit 2 bad']
      ['--status-normal', 'powered and BITE-read before the session: S set from the start']
      ['quiet', 'do not trace commands']
    ]
    build: (o) ->
      units = (wantInt(s, 'unit', 1, 2) for s in String(o.units).split(',') when s.trim())
      power = if String(o.power).toLowerCase() == 'none' then 0 else wantInt(o.power, 'power', 1, 2)
      fmtId = (s) -> if not s? or String(s).toLowerCase() == 'none' then null else wantInt(s, 'format', 1, 254)
      new PCMMU({
        units, power
        formatSwitch: o.formatSwitch
        hdrFormat:    fmtId(o.hdrFormat)
        ldrFormat:    fmtId(o.ldrFormat)
        mdms:         (s.trim().toUpperCase() for s in String(o.mdms).split(',') when s.trim())
        mtuGood:      not o.mtuFail
        statusNormal: !!o.statusNormal
        verbose:      not o.quiet
      })

  tools: (program) ->


    program.command('read')
      .description('read the OI/PL RAM through a GPC bus, as a GPC does (test equipment)')
      .argument('<address>', '0 to 4095')
      .argument('[count]', '1 to 32', '1')
      .requiredOption('--gpc <n>', 'the IP bus to use, 1 to 5')
      .action (addrStr, countStr, o) ->
        addr = wantInt(addrStr, 'address', 0, RAM_WORDS - 1)
        count = wantInt(countStr, 'count', 1, 32)
        gpcTransaction wantGpc(o.gpc), CMD_READ_RAM(addr, count), o, (words, sev) ->
          for w, i in words
            console.log "#{String(addr + i).padStart(4)}  #{hex4 w}  #{fmtSev [sev[i]]}"

    program.command('bite')
      .description('read the BITE register through a GPC bus')
      .requiredOption('--gpc <n>', 'the IP bus to use, 1 to 5')
      .action (o) ->
        gpcTransaction wantGpc(o.gpc), CMD_READ_BITE, o, (words, sev) ->
          w = words[0]
          console.log "BSR #{hex4 w}  #{fmtBSR w}  (#{fmtSev sev})"
          for n in [1..16] by 1
            console.log "  bit #{String(n).padStart(2)} #{BSR_MSID[n]}  #{(BSR_NAME[bsrBit(n)] ? '').padEnd(14)} #{if w & bsrBit(n) then 1 else 0}"

    program.command('tb')
      .description("read a toggle buffer's formatter side through a GPC bus")
      .argument('<buffer>', '1 to 5')
      .argument('[address]', '0 to 127', '0')
      .argument('[count]', '1 to 32', '8')
      .requiredOption('--gpc <n>', 'the IP bus to use, 1 to 5')
      .action (bufStr, addrStr, countStr, o) ->
        b = wantInt(bufStr, 'buffer', 1, 5)
        addr = wantInt(addrStr, 'address', 0, TB_WORDS - 1)
        count = wantInt(countStr, 'count', 1, 32)
        gpcTransaction wantGpc(o.gpc), CMD_READ_TB(b, addr, count), o, (words, sev) ->
          console.log "buffer #{b} from #{addr}: #{(hex4 w for w in words).join(' ')}  (#{fmtSev sev})"

    program.command('select')
      .description('select the fixed or the programmable 128-kbps format through a GPC bus')
      .argument('<fixed|prgm>')
      .requiredOption('--gpc <n>', 'the IP bus to use, 1 to 5')
      .action (which, o) ->
        w = String(which).toLowerCase()
        die "fixed or prgm" unless w in ['fixed', 'prgm']
        name = ipBusOf(wantGpc(o.gpc))
        bus = new Bus(name, busConfig[name])
        cmd = CMD_FMT_SELECT(w == 'prgm')
        setTimeout (->
          bus.sendMsg BusMsg.Command(cmd)
          console.log "#{name}: #{fmtCommand cmd}"
          setTimeout (-> process.exit(0)), 50
        ), BIND_MS

    program.command('watch')
      .description('print the traffic on a GPC bus, a stream or an OI bus')
      .argument('<what>', 'gpc, hdr, ldr or oi')
      .argument('[n]', 'the GPC (1-5) or the unit (1-2)', '1')
      .option('--every <k>', 'a stream: print every kth minor frame', '1')
      .option('--all', 'a stream: print the whole minor frame')
      .action (what, n, o) ->
        switch String(what).toLowerCase()
          when 'gpc' then watchGpc wantGpc(n)
          when 'hdr', 'ldr' then watchStream String(what).toLowerCase(), o
          when 'oi' then watchOi wantInt(n, 'unit', 1, 2)
          else die "watch gpc <n>, hdr, ldr or oi <n>"
        holdOpen()


    program.command('commands')
      .description('the command words a GPC uses')
      .action () ->
        show = (name, cmd) -> console.log "#{name.padEnd(40)} #{hex6 cmd}   #{fmtCommand cmd}"
        show 'write buffer 1 at 0, 32 words', CMD_WRITE_TB(1, 0, 32)
        show 'write buffer 1 at 96, 32 words', CMD_WRITE_TB(1, 96, 32)
        show 'end of message, buffer 1, 32 words', CMD_EOM(1, 31)
        show 'end of message, buffer 1, 128 words', CMD_EOM(1, 127)
        show 'read buffer 1 at 0, 8 words', CMD_READ_TB(1, 0, 8)
        show 'read OI/PL RAM 2515, 1 word', CMD_READ_RAM(2515, 1)
        show 'read the BITE register', CMD_READ_BITE
        show 'select the fixed 128-kbps format', CMD_FMT_SELECT(false)
        show 'select the programmable format', CMD_FMT_SELECT(true)
        show 'load the 128-kbps RAM at 0, 32 words', CMD_LOAD_FMT(128, 0, 32)
        show 'read the 64-kbps RAM at 0, 32 words', CMD_READ_FMT(64, 0, 32)

    program.command('map')
      .description('the fetch program: OI/PL RAM address by MDM card and channel')
      .argument('[mdm]', 'one MDM, or all')
      .action (mdm) ->
        fetch = buildFetch()
        console.log "#{fetch.entries.length} commands a cycle, #{fetch.words} RAM words"
        for e in fetch.entries when not mdm? or e.mdm == String(mdm).toUpperCase()
          console.log "#{String(e.ram).padStart(4)}-#{String(e.ram + e.count - 1).padEnd(4)} " +
                      "#{e.mdm} card #{String(e.card).padStart(2)} #{e.type} " +
                      "#{if e.type == 'SIO' then "channel #{e.channel}, #{e.count} words" else "channels #{e.channel}-#{e.channel + e.count - 1}"}" +
                      "  #{e.rate} s/s"

    program.command('formats')
      .description('the format library and the windows of each')
      .action () ->
        for id, f of FORMATS
          console.log "#{id}  #{f.rate} kbps  #{f.nom}"
          for w in formatLayout(parseInt(id, 10))
            console.log "     #{w.name.padEnd(5)} slots #{String(w.slot).padStart(3)}-#{String(w.slot + w.slots - 1).padEnd(3)}" +
                        "#{if w.words? then "  #{w.words} words a downlist frame" else ''}"
