# gpc discretes
#
# cli/repl for monitoring and setting gpc discretes
#
#   set    hold named bits at a level until stopped
#   mode   the three-position mode toggle, one position made
#   ipl    a press of the IPL pushbutton
#   panel  repl to toggle any of them interactively 
#   watch  print what everything on the bus publishes
#   get    ask the GPC for a register's current value
#
#
# The GPC holds the canonical value, the discrete outputs included, so
# anything here that wants a starting picture asks for it with REQUEST.
#

import {addBusOptions} from 'com/busCli'
import {DiscreteBus, DiscreteLines, decodeDiscrete, applyDiscrete, bitMask,
        DISCRETE_BITS as BITS, DISCRETE_OUT_BITS as OUT_BITS,
        DISCRETE_MODES as MODES, GPC_IDS, resolveGpcId,
        discreteName as nameOf, resolveDiscrete as resolve,
        describeDiscrete as describe, regName,
        SET, RESET, REQUEST, VALUE,
        REG_A, REG_B, REG_OUT, REPUBLISH_MS, IPL_PRESS_MS} from 'com/discretes'
import {linksInto} from 'gpc/gpclinks'

regOf = (o) -> if o.b then REG_B else REG_A

# --gpc: a GPC ID, a comma list of them, or `all`.
gpcIds = (v) ->
  try
    return GPC_IDS.slice() if String(v ? '').toLowerCase() == 'all'
    (resolveGpcId(t) for t in String(v ? '0').split(',') when t.trim().length)
  catch e
    console.error "FATAL: #{e.message}"
    process.exit(2)

gpcId = (v) -> gpcIds(v)[0]

label = (list) -> "GPC #{list.join(', ')}"

gpcOption = (c, help) -> addBusOptions(c.option('--gpc <n>', help, '0'))

# How long to give the GPC to answer a request before showing what came
# back.
ANSWER_MS = 200

# The input registers, which anything here can drive, and all three,
# which it can watch.
DRIVEN = [REG_A, REG_B]
ALL = [REG_A, REG_B, REG_OUT]

hex = (v) -> (v >>> 0).toString(16).padStart(8, '0')

regFromToken = (token) ->
  switch String(token ? 'a').toLowerCase()
    when 'a' then REG_A
    when 'b' then REG_B
    when 'out', 'o', 'output' then REG_OUT
    else throw new Error("register must be a, b or out")

export addCommand = (program) ->
  cmd = program.command('discretes')
    .description('drive and watch the GPC discrete input lines')

  gpcOption(cmd.command('set')
    .description('hold discrete inputs at a level until stopped')
    .argument('<bits...>', 'names or IBM bit numbers; -name clears one')
    .option('-b, --b', 'register B (inputs 33-40) instead of A')
    .option('--once', 'send once and exit instead of republishing'),
    'GPC ID, a comma list of them, or all')
    .action (bits, o) ->
      list = gpcIds(o.gpc)
      reg = regOf(o)
      setMask = 0
      clrMask = 0
      for token in bits
        if String(token).startsWith('-')
          clrMask |= bitMask(resolve(reg, String(token).slice(1)))
        else
          setMask |= bitMask(resolve(reg, token))
      bus = new DiscreteLines(list)
      send = () ->
        bus.publish(SET, reg, setMask) if setMask
        bus.publish(RESET, reg, clrMask) if clrMask
      report = []
      report.push "set #{describe(reg, setMask)}" if setMask
      report.push "clear #{describe(reg, clrMask)}" if clrMask
      console.log "#{label(list)} register #{if reg == REG_B then 'B' else 'A'}: " +
                  report.join('; ')
      send()
      if o.once
        setTimeout (-> process.exit(0)), 100
      else
        console.log "republishing every #{REPUBLISH_MS} ms -- ^C to stop"
        setInterval send, REPUBLISH_MS

  gpcOption(cmd.command('mode')
    .description('the crew panel mode toggle: one position made, the other two broken')
    .argument('<position>', MODES.join(' | '))
    .option('--once', 'send once and exit instead of republishing'),
    'GPC ID, a comma list of them, or all')
    .action (position, o) ->
      list = gpcIds(o.gpc)
      chosen = String(position).toLowerCase()
      unless chosen in MODES
        console.error "mode must be one of: #{MODES.join(', ')}"
        process.exit(2)
      bus = new DiscreteLines(list)
      send = () ->
        for m in MODES
          bus.publish((if m == chosen then SET else RESET),
                      REG_A, bitMask(BITS.A[m]))
      console.log "#{label(list)} mode #{chosen.toUpperCase()}"
      send()
      if o.once
        setTimeout (-> process.exit(0)), 100
      else
        console.log "republishing every #{REPUBLISH_MS} ms -- ^C to stop"
        setInterval send, REPUBLISH_MS

  gpcOption(cmd.command('ipl')
    .description('press the IPL button')
    .option('--hold <ms>', 'how long to hold it down', String(IPL_PRESS_MS)),
    'GPC ID, a comma list of them, or all')
    .action (o) ->
      list = gpcIds(o.gpc)
      bus = new DiscreteLines(list)
      ms = Number(o.hold)
      bus.publish(SET, REG_A, bitMask(BITS.A.ipl))
      console.log "#{label(list)} IPL button pressed"
      setTimeout (->
        bus.publish(RESET, REG_A, bitMask(BITS.A.ipl))
        console.log "IPL button released"
        setTimeout (-> process.exit(0)), 100), ms

  gpcOption(cmd.command('watch')
    .description('print what is published on the discrete bus')
    .option('--changes', 'only when a register actually changes')
    .option('--seconds <n>', 'stop after this long'),
    'GPC ID, a comma list of them, or all')
    .action (o) ->
      list = gpcIds(o.gpc)
      state = {}
      for g in list
        state[g] = {}
        state[g][r0] = 0 for r0 in ALL
      t0 = Date.now()
      n = 0
      bus = new DiscreteLines list, (m, gpc) ->
        return unless m?
        n += 1
        reg = state[gpc]
        before = reg[m.reg]
        reg[m.reg] = applyDiscrete(before, m)
        return if o.changes and reg[m.reg] == before
        t = ((Date.now() - t0) / 1000).toFixed(2).padStart(7)
        op = switch m.op
          when SET     then 'SET    '
          when RESET   then 'RESET  '
          when REQUEST then 'REQUEST'
          else              'VALUE  '
        what = if m.op == VALUE then hex(m.mask) else describe(m.reg, m.mask)
        who = if list.length > 1 then "gpc#{gpc}  " else ""
        at = if m.timeUs? then "  @#{(m.timeUs / 1000).toFixed(3)} ms" else ""
        console.log "#{t}s  #{who}#{op} reg #{regName(m.reg).padEnd(3)}  " +
                    "#{what.padEnd(28)}   " +
                    "A=#{hex(reg[REG_A])} B=#{hex(reg[REG_B])} " +
                    "OUT=#{hex(reg[REG_OUT])}#{at}"
      console.log "listening to #{label(list)}"
      # A GPC already running has the values, so they are asked for.
      bus.request(r1) for r1 in ALL
      if o.seconds
        setTimeout (->
          console.log "#{n} discrete message(s)"
          process.exit(0)), Number(o.seconds) * 1000
      else
        keepAlive = setInterval (-> return), REPUBLISH_MS
        process.on 'SIGINT', ->
          clearInterval keepAlive
          console.log "\n#{n} discrete message(s)"
          process.exit(0)

  gpcOption(cmd.command('get')
    .description("ask the GPC for a register's current value")
    .argument('[register]', 'a | b | out (default a)')
    .option('--seconds <n>', 'how long to wait for the answer', '1'),
    'GPC to ask')
    .action (register, o) ->
      gpc = gpcId(o.gpc)
      reg = regFromToken(register)
      answered = false
      bus = new DiscreteBus gpc, (m) ->
        return unless m? and m.op == VALUE and m.reg == reg
        answered = true
        console.log "GPC #{gpc} register #{regName(reg)}  #{hex(m.mask)}"
        table = if reg == REG_OUT then OUT_BITS else \
                (if reg == REG_B then BITS.B else BITS.A)
        for name, b of table
          console.log "   #{String(b).padStart(2)}  #{name.padEnd(10)} " +
                      "#{if m.mask & bitMask(b) then '1' else '0'}"
        process.exit(0)
      bus.request(reg)
      setTimeout (->
        unless answered
          console.error "no answer for GPC #{gpc} register #{regName(reg)}"
          process.exit(1)), Number(o.seconds) * 1000

  gpcOption(cmd.command('links')
    .description("the register A inputs the other GPCs' outputs drive"),
    'GPC ID, a comma list of them, or all')
    .action (o) ->
      for gpc in gpcIds(o.gpc)
        links = linksInto(gpc)
        unless links.length
          console.log "GPC #{gpc}: standalone, no links"
          continue
        console.log "GPC #{gpc} register A"
        for l in links
          console.log "   #{String(l.inBit).padStart(2)}  #{l.input.padEnd(10)} " +
                      "<- GPC #{l.gpc} DO-#{l.outBit} #{l.out}"
      setTimeout (-> process.exit(0)), 0

  gpcOption(cmd.command('panel')
    .description('toggle the discrete inputs interactively')
    .option('--mode <position>', "mode switch position to start in (#{MODES.join(' | ')})"),
    'GPC this panel is wired to')
    .action (o) ->
      gpc = gpcId(o.gpc)
      readline = require 'readline'
      on_   = {}      # bits this panel asserts
      owned = {}      # bits this panel has taken responsibility for
      heard = {}      # what OTHER devices publish -- the bus filters our own
      for r0 in ALL
        on_[r0] = 0; owned[r0] = 0; heard[r0] = 0

      bus = new DiscreteBus gpc, (m) ->
        return unless m? and m.op != REQUEST
        heard[m.reg] = applyDiscrete(heard[m.reg], m)

      publish = () ->
        for rp in DRIVEN
          bus.publish(SET, rp, on_[rp]) if on_[rp]
          off_ = (owned[rp] & ~on_[rp]) >>> 0
          bus.publish(RESET, rp, off_) if off_
        return

      # The GPC holds all three registers, and nothing else publishes the
      # outputs, so a request is how the panel learns them.  The answers
      # arrive as ordinary traffic, so `done` runs once they have had
      # time to.
      refresh = (done = null) ->
        bus.request(rr) for rr in ALL
        setTimeout done, ANSWER_MS if done?
        return

      drive = (reg, bit, level) ->
        m = bitMask(bit)
        owned[reg] = (owned[reg] | m) >>> 0
        on_[reg] = if level then ((on_[reg] | m) >>> 0) else ((on_[reg] & ~m) >>> 0)
        return

      mode = (chosen) ->
        drive(REG_A, BITS.A[mm], mm == chosen) for mm in MODES
        return

      # A press of the IPL button: made, published, and taken back.  The
      # GPC loads from mass memory when it sees one with the toggle at
      # HALT.
      press = () ->
        drive(REG_A, BITS.A.ipl, true)
        publish()
        setTimeout (->
          drive(REG_A, BITS.A.ipl, false)
          publish()), IPL_PRESS_MS
        return

      level = (rl_) -> (((heard[rl_] & ~owned[rl_]) | on_[rl_]) >>> 0)

      snapshot = () -> ((hex(level(rn)) for rn in DRIVEN).join(' ') +
                        ' ' + hex(heard[REG_OUT]))

      show = () ->
        console.log ""
        for rs in DRIVEN
          table = if rs == REG_B then BITS.B else BITS.A
          console.log "register #{regName(rs)}   #{hex(level(rs))}"
          for name, b of table
            m = bitMask(b)
            mine = if owned[rs] & m then (if on_[rs] & m then 'panel ON ' else 'panel off') else 'elsewhere'
            mine = '         ' unless (owned[rs] & m) or (heard[rs] & m)
            console.log "   #{String(b).padStart(2)}  #{name.padEnd(10)} " +
                        "#{if level(rs) & m then '1' else '0'}   #{mine}"
        # What the GPC is asserting.  Nothing here drives these.
        console.log "register OUT #{hex(heard[REG_OUT])}"
        for name, b of OUT_BITS
          console.log "   #{String(b).padStart(2)}  #{name.padEnd(10)} " +
                      "#{if heard[REG_OUT] & bitMask(b) then '1' else '0'}   gpc"
        console.log ""
        return

      help = () ->
        console.log """
          <name|bit>        toggle a discrete in register A
          b <name|bit>      toggle one in register B
          on|off <name>     drive it to a level instead of toggling
          #{MODES.join(' | ')}   the mode toggle: one position made, the other two broken
          ipl               press the IPL button (loads from mass memory at HALT)
          show              the table above          release <name>   stop driving it
          refresh           ask the GPC for all three registers
          quit              stop the panel
        """
        return

      toggle = (reg, token) ->
        bit = resolve(reg, token)
        m = bitMask(bit)
        now = level(reg) & m
        drive(reg, bit, not now)
        console.log "#{regName(reg)} #{nameOf(reg, bit)} -> #{if on_[reg] & m then 'ON' else 'off'}"
        return

      mode(o.mode.toLowerCase()) if o.mode and o.mode.toLowerCase() in MODES

      pulse = () ->
        publish()
        bus.request(rr) for rr in ALL
        return
      pulse()
      timer = setInterval pulse, REPUBLISH_MS

      console.log "GPC #{gpc} discretes, #{REPUBLISH_MS} ms refresh; '?' for help"
      rl = readline.createInterface({input: process.stdin, output: process.stdout, prompt: 'discretes> '})
      # The table above is what this panel knows; the GPC's answer arrives
      # after it, and is worth drawing again only if it said something new.
      wasShowing = snapshot()
      refresh(-> if snapshot() != wasShowing then (show(); rl.prompt()))
      rl.prompt()
      rl.on 'line', (line) ->
        words = line.trim().split(/\s+/).filter((w) -> w.length)
        try
          if words.length == 0
            # nothing
          else if words[0] in ['quit', 'exit', 'q']
            clearInterval timer
            rl.close()
            return
          else if words[0] in ['?', 'help']    then help()
          else if words[0] == 'show'           then show()
          else if words[0] in ['refresh', 'sync'] then refresh(-> show(); rl.prompt())
          else if words[0] in MODES
            mode(words[0]); publish()
            console.log "GPC #{gpc} mode #{words[0].toUpperCase()}"
          else if words[0] == 'ipl'
            press()
            atHalt = (level(REG_A) & bitMask(BITS.A.halt)) != 0
            note = if atHalt then "" else " -- the toggle is not at HALT"
            console.log "IPL button pressed#{note}"
          else if words[0] == 'b' and words[1]? then toggle(REG_B, words[1]); publish()
          else if words[0] in ['on', 'off'] and words[1]?
            reg = if words[2] == 'b' then REG_B else REG_A
            bit = resolve(reg, words[1])
            drive(reg, bit, words[0] == 'on'); publish()
            console.log "#{regName(reg)} #{nameOf(reg, bit)} -> #{words[0]}"
          else if words[0] == 'release' and words[1]?
            reg = if words[2] == 'b' then REG_B else REG_A
            bit = resolve(reg, words[1])
            bus.publish(RESET, reg, bitMask(bit))
            owned[reg] = (owned[reg] & ~bitMask(bit)) >>> 0
            on_[reg]   = (on_[reg]   & ~bitMask(bit)) >>> 0
            console.log "released #{regName(reg)} #{nameOf(reg, bit)}"
          else
            toggle(REG_A, words[0]); publish()
        catch e
          console.log e.message
        rl.prompt()
      rl.on 'close', ->
        clearInterval timer
        console.log ""
        process.exit(0)
