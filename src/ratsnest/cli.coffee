import {call, setTimeout, setInterval, now as simNow} from '../com/simRuntime.coffee'
# ratsnest -- the wiring between the units
#
# Usage:
#   ratsnest run [wiring/...] [-v]
#   ratsnest check [wiring/...]
#   ratsnest show [wiring/...] [--nets | --drivers]
#   ratsnest set F6/S3 LVLH
#   ratsnest watch [--panel | --mdm FF1 | --discrete gpc4 | --adc 1 | --power]
#   ratsnest schemes
#
import {Bus, busConfig} from './../com/bus.civet.jsx'
import {addBusOptions} from './../com/busCli'
import {SimControl} from './../com/simControl'
import {Ratsnest, WiringError, WIRING_EXT} from './ratsnest'
import {PanelChannel, VALUE as P_VALUE, LOGIC, ENUM, WORD, REAL, fmtPanel,
        decodePanel, PANEL_BUS} from './../panel/panelBus'
import {decodeIO, fmtIO, ioBusName} from './../lru/mdm/mdmConf'
import {MDM_CATALOG} from './../lru/mdm/mdmConfig'
import {decodeDiscrete, GPC_DISCRETES} from './../com/discretes'
import {IDP_DISCRETES} from './../meds/idp/idpDiscretes'
import {decodeAnalog, fmtAnalog, analogBusOf} from './../lru/adc/adcConf'
import {decodePower, fmtPower, POWER_BUS} from './../com/power'

{Command} = require 'commander'
process = require 'process'

BIND_MS = 150

die = (msg) ->
  console.error "ratsnest: #{msg}"
  process.exit(2)

stamp = () ->
  d = new Date()
  "#{String(d.getHours()).padStart(2, '0')}:#{String(d.getMinutes()).padStart(2, '0')}:" +
  "#{String(d.getSeconds()).padStart(2, '0')}.#{String(d.getMilliseconds()).padStart(3, '0')}"

# Loads the wiring, reporting where a specification is wrong.
build = (specs, opts = {}) ->
  net = new Ratsnest(opts)
  try
    net.load(specs)
  catch e
    die e.message if e instanceof WiringError or e instanceof Error
  for line in net.netlist.errors
    console.error "ratsnest: #{line}"
  net

program = new Command()
program.name('ratsnest').description('routes signals between the simulation busses')

program.command('run')
  .description("hold the wiring between the units until ^C")
  .argument('[wiring...]', "specification files or directories (default: #{WIRING_EXT} in wiring/)")
  .option('-v, --verbose', 'a line for every net that moves')
  .option('-q, --quiet', 'nothing but errors')
  .action (specs, o) ->
    log = (t) -> console.error t
    net = build(specs, {log})
    if o.verbose
      net.onChange = (changed) ->
        for n in changed
          console.log "#{stamp()} #{n.qualified()} #{net.fmtValue(n)}"
        return
    try
      net.open()
    catch e
      die e.message
    buses = net.adapters.flatMap((adapter) -> adapter.controlBuses())
    driver = {
      id: 'ratsnest', config: {files: net.files}, state: net,
      bus: Object.fromEntries(buses.map((bus) -> [bus.busID, bus])),
      report: -> {units: net.units.length, nets: Object.keys(net.netlist.nets).length, unanswered: net.waiting().length}
    }
    driver.start = () ->
        net.start()
        unless o.quiet
          bound = (n for n in net.table() when n.bind)
          waiting = net.waiting()
          line = "ratsnest #{net.units.length} wiring unit#{if net.units.length == 1 then '' else 's'}, " +
                 "#{Object.keys(net.netlist.nets).length} nets, #{bound.length} bound"
          line += ", #{waiting.length} input#{if waiting.length == 1 then '' else 's'} unanswered" if waiting.length
          console.log line
        return
    control = new SimControl(driver)
    Promise.all([net.ready(), control.ready]).then () ->
      setTimeout call(driver, 'start'), BIND_MS
      return
    .catch (error) ->
      control.error(error).finally ->
        net.close()
        process.exit(2)
    stopping = false
    stop = ->
      return if stopping
      stopping = true
      control.close().finally ->
        net.close()
        process.exit(0)
    process.on 'SIGINT', stop
    process.on 'SIGTERM', stop
    # The busses' sockets are unref'd, so something must hold the loop.
    globalThis.setInterval (->), 60000

program.command('check')
  .description('read the wiring and report what is wrong with it')
  .argument('[wiring...]', 'specification files or directories')
  .action (specs) ->
    net = build(specs)
    rows = net.table()
    bound = (r for r in rows when r.bind)
    console.log "#{net.files.length} file#{if net.files.length == 1 then '' else 's'}, " +
                "#{net.units.length} wiring unit#{if net.units.length == 1 then '' else 's'}, " +
                "#{rows.length} nets, #{bound.length} bound, #{net.netlist.drivers.length} drivers"
    # A binding is checked against the busses only when an adapter claims it.
    try
      net.open()
      net.close()
    catch e
      die e.message
    process.exit(if net.netlist.errors.length then 1 else 0)

program.command('show')
  .description('the nets and what drives them')
  .argument('[wiring...]', 'specification files or directories')
  .option('--drivers', 'the driven nets only')
  .action (specs, o) ->
    net = build(specs)
    try
      net.open()
    catch e
      die e.message
    rows = net.table()
    rows = (r for r in rows when r.driven) if o.drivers
    w = Math.max(4, Math.max((r.name.length for r in rows)...))
    t = Math.max(4, Math.max((r.type.length for r in rows)...))
    console.log "#{'NET'.padEnd(w)}  #{'TYPE'.padEnd(t)}  #{'DIR'.padEnd(6)}  BINDING"
    for r in rows
      console.log "#{r.name.padEnd(w)}  #{r.type.padEnd(t)}  #{r.dir.padEnd(6)}  #{r.bind}"
    net.close()
    process.exit(0)

program.command('set')
  .description('put one control on the panel bus, as a frontend would')
  .argument('<control>', 'panel and control, as F6/S3')
  .argument('<value>', "a position name, '1' or '0' for a level, or a number")
  .option('--request', 'ask for the control instead of setting it')
  .option('--logic', "send it as a level: '1', 1 or on, and anything else off")
  .option('--word', 'send a number as sixteen bits')
  .option('--real', 'send a number as a measurement')
  .action (control, value, o) ->
    die "a control is <panel>/<control>, as F6/S3" unless /^[^\/]+\/[^\/]+$/.test(control)
    channel = new PanelChannel()
    channel.ready().then () ->
      if o.request
        channel.request(control)
        channel.bus.onReceive ((self, busID, msg) ->
          m = decodePanel(msg)
          console.log fmtPanel(m) if m? and m.op == P_VALUE and m.key == control), null
        setTimeout (-> process.exit(0)), 1000
        return
      # A switch position is a word, so only a quoted level, a number or
      # an option makes anything else.  ON and OFF are positions.
      v = String(value)
      if o.logic then channel.set(control, LOGIC, (if v in ["'1'", '1', 'on', 'ON'] then 1 else 0))
      else if o.word then channel.set(control, WORD, parseInt(v, 10))
      else if o.real then channel.set(control, REAL, Number(v))
      else if v in ["'1'", "'0'"] then channel.set(control, LOGIC, (if v == "'1'" then 1 else 0))
      else if /^-?\d+$/.test(v) then channel.set(control, WORD, parseInt(v, 10))
      else if /^-?\d*\.\d+$/.test(v) then channel.set(control, REAL, Number(v))
      else channel.set(control, ENUM, v.toUpperCase())
      setTimeout (-> process.exit(0)), BIND_MS
      return

program.command('watch')
  .description('the traffic on a bus the wiring reaches')
  .option('--panel', 'the panel bus')
  .option('--mdm <unit>', 'the hardware side of one MDM')
  .option('--discrete <device>', 'a discrete channel, as gpc4 or idp1')
  .option('--adc <pair>', 'the analog inputs of an ADC pair')
  .option('--power', 'the power feeds and the loads on them')
  .action (o) ->
    chosen = (k for k in ['panel', 'mdm', 'discrete', 'adc', 'power'] when o[k]?)
    die "name one bus: --panel, --mdm, --discrete, --adc or --power" unless chosen.length == 1
    switch chosen[0]
      when 'panel'
        name = PANEL_BUS
        show = (msg) -> fmtPanel(decodePanel(msg))
      when 'mdm'
        unit = String(o.mdm).toUpperCase()
        die "there is no MDM #{unit}" unless MDM_CATALOG[unit]?
        name = ioBusName(unit)
        show = (msg) ->
          m = decodeIO(msg.data16)
          if m? then fmtIO(m) else ''
      when 'discrete'
        m = String(o.discrete).match(/^(gpc|idp)(\d+)$/i)
        die "a device is gpc<n> or idp<n>" unless m?
        spec = if m[1].toLowerCase() == 'idp' then IDP_DISCRETES else GPC_DISCRETES
        try
          name = spec.busName(spec.resolveId(m[2]))
        catch e
          die e.message
        show = (msg) ->
          d = decodeDiscrete(msg)
          return '' unless d?
          "#{['', 'SET', 'RESET', 'REQUEST', 'VALUE'][d.op]} #{spec.regName(d.reg)} " +
          "#{spec.describe(d.reg, d.mask)}"
      when 'adc'
        name = analogBusOf("#{parseInt(o.adc, 10)}A")
        die "pairs are 1 and 2" unless name?
        show = (msg) ->
          a = decodeAnalog(msg.data16)
          if a? then fmtAnalog(a) else ''
      when 'power'
        name = POWER_BUS
        show = (msg) -> fmtPower(decodePower(msg))
    die "unknown bus '#{name}'" unless busConfig[name]?
    bus = new Bus(name, busConfig[name])
    bus.onReceive ((self, busID, msg) ->
      text = show(msg)
      console.log "#{stamp()} #{text}" if text), null
    console.log "watching #{name} (#{busConfig[name].nom})"
    globalThis.setInterval (->), 60000

program.command('schemes')
  .description('the binding schemes and the address each takes')
  .action () ->
    console.log "panel     <panel>/<control>            F6/S3"
    console.log "mdm       <unit>/<card>/<channel>[.<bit>]   FF1/4/1.0"
    console.log "discrete  <device><n>/<register>/<bit>  gpc4/A/mm1ready"
    console.log "adc       <pair>/<channel>              1/12"
    console.log "power     <feed>[.draw]                 MNA, MNA.draw"

addBusOptions(c) for c in program.commands when c.name() in ['run', 'check', 'show', 'set', 'watch']

program.parse()
