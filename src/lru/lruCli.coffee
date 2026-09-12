# LRU commands are generated from `lru/<name>/spec.coffee` exports:
#
#   id       the command name and the catalog key, 'imu'
#   title    what the box is called, 'Inertial Measurement Unit'
#   summary  the one line of the command's help
#   usage    example command lines, printed after the help
#   run      how the unit is brought up (below); a spec without one is
#            test equipment alone, as lru/ddu is
#   tools    (program) -> ; adds the unit's other subcommands
#   tables   the subcommands that open no bus, so take no bus options
#
# A `run` block:
#
#   summary  the one line of `run`'s help
#   args     [flag, help, default] positional arguments
#   options  the options, each of them one of
#              'quiet'                          a standard option
#              ['quiet', 'do not trace polls']  a standard one reworded
#              [flag, help, default]            an option `build` reads
#              {flag, help, dflt, many, apply}  one applied to the unit
#            `many` is repeatable, and `apply` is called once a value with
#            the unit and the value: a fault injected, a unit silenced.
#   build    (opts, args...) -> the unit, or an array of them
#
# `runUnits` supplies the shared lifecycle and permits several units per process.

{Command, Option} = require 'commander'
process = require 'process'

import {addBusOptions} from './../com/busCli'


export collect = (v, acc) -> (acc ? []).concat([v])

STANDARD =
  quiet:      {flag: '-q, --quiet', help: 'do not trace the unit'}
  replyDelay: {flag: '--reply-delay <ms>', help: 'delay before answering a poll', dflt: '0'}

normOption = (o) ->
  if typeof o == 'string'
    std = STANDARD[o]
    throw new Error("no standard option '#{o}'") unless std?
    return Object.assign({}, std)
  if Array.isArray(o)
    if STANDARD[o[0]]?
      return Object.assign({}, STANDARD[o[0]], {help: o[1] ? STANDARD[o[0]].help})
    return {flag: o[0], help: o[1], dflt: o[2]}
  o

addOption = (cmd, spec) ->
  opt = new Option(spec.flag, spec.help)
  if spec.many
    opt.argParser(collect)
  else if spec.dflt?
    opt.default(spec.dflt)
  cmd.addOption opt
  Object.assign({}, spec, {key: opt.attributeName()})


export die = (who, msg) ->
  console.error "#{who}: #{msg}"
  process.exit(2)

openUnit = (spec, options, opts, args) ->
  unit = null
  try
    unit = spec.run.build(opts, args...)
  catch e
    die spec.id, e.message
  for opt in options
    continue unless opt.apply?
    values = if opt.many then (opts[opt.key] ? []) else (if opts[opt.key]? then [opts[opt.key]] else [])
    for value in values
      try
        opt.apply(unit, value, opts)
      catch e
        die spec.id, e.message
  if Array.isArray(unit) then unit else [unit]

reportOf = (units) ->
  return units[0].report() if units.length == 1
  out = {}
  for u in units
    key = u.id
    n = 2
    while out[key]?
      key = "#{u.id}##{n}"
      n += 1
    out[key] = u.report()
  out

export runUnits = (units) ->
  for u in units
    console.log line for line in u.describe()
  console.log "^C to stop"

  stopping = false
  stop = () ->
    return if stopping
    stopping = true
    console.log ''
    console.log JSON.stringify(reportOf(units), null, 2)
    Promise.all(u.stop() for u in units).then -> process.exit(0)
  process.on 'SIGINT', stop
  process.on 'SIGTERM', stop
  holdOpen()
  units

export holdOpen = () -> setInterval (->), 60000


export runCommand = (spec, onUnits = runUnits) ->
  cmd = new Command('run').description(spec.run.summary)
  cmd.argument(a[0], a[1], a[2]) for a in spec.run.args ? []
  options = (addOption(cmd, normOption(option)) for option in spec.run.options ? [])
  cmd.action (args...) ->
    args.pop()
    opts = args.pop()
    onUnits openUnit(spec, options, opts, args)
  cmd

export unitProgram = (spec) ->
  program = new Command(spec.id).description(spec.summary)
  program.addCommand runCommand(spec) if spec.run?
  spec.tools?(program)
  tables = spec.tables ? []
  addBusOptions(c) for c in program.commands when c.name() not in tables
  program.addHelpText('after', "\n" + spec.usage.join('\n')) if spec.usage?
  program

export main = (spec) ->
  program = unitProgram(spec)
  program.version('1.0.0')
  program.parseAsync(process.argv).catch (e) ->
    console.error e
    process.exit(1)
