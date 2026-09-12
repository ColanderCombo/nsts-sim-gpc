# lru -- the line replaceable units, one command
#
# Usage:
#   lru list                          the catalog
#   lru run imu                       one unit, as `imu run` does
#   lru run imu + mtu + mdm FF1       three units in this process, + between
#   lru run mdm FF1 + mdm FF2 -q      the same kind twice
#   lru mdm cards FF1                 the subcommands of one unit
#
# The units of one `lru run` share a process, an event loop and one set of
# bus options; each segment takes the options that unit's `run` takes.
# ^C reports every unit and takes them all down.
#
{Command} = require 'commander'
process = require 'process'

import {addBusOptions} from './../com/busCli'
import {die, runCommand, runUnits, unitProgram} from './lruCli'
import {SPECS, specOf} from './catalog'

SEPARATOR = '+'

# The argument list as one list a segment: `imu --units 1,2 + mtu`.
segments = (tokens) ->
  out = [[]]
  for t in tokens
    if t == SEPARATOR then out.push([]) else out[out.length - 1].push(t)
  (s for s in out when s.length)

wantSpec = (id) ->
  spec = specOf(id)
  die 'lru', "no unit '#{id}' (lru list)" unless spec?
  die 'lru', "#{spec.id} has no run; it is #{spec.summary} (lru #{spec.id} --help)" unless spec.run?
  spec

program = new Command('lru')
  .description('Space Shuttle line replaceable units -- device models and bus tools')
  .version('1.0.0')
program.enablePositionalOptions()

program.command('list')
  .description('the units this command knows')
  .action () ->
    for s in SPECS
      console.log "#{s.id.padEnd(6)} #{s.title}"

run = program.command('run')
  .description("run one or more units in this process, '#{SEPARATOR}' between them")
  .argument('[unit...]', "<unit> [options] [#{SEPARATOR} <unit> [options]] ...")
  .passThroughOptions()
  .action (tokens) ->
    segs = segments(tokens)
    die 'lru', "name a unit to run (lru list)" unless segs.length
    units = []
    for seg in segs
      spec = wantSpec(seg[0])
      cmd = runCommand(spec, (built) -> units = units.concat(built))
      cmd.name("lru run #{spec.id}").exitOverride()
      try
        cmd.parse(seg[1..], {from: 'user'})
      catch e
        process.exit(e.exitCode ? 1)
    runUnits units
addBusOptions run

program.addCommand(unitProgram(spec)) for spec in SPECS

program.addHelpText 'after', """

Examples:
  lru list
  lru run imu
  lru run imu #{SEPARATOR} mtu #{SEPARATOR} mdm FF1
  lru run mdm FF1 #{SEPARATOR} mdm FF2 -q
  lru mdm cards FF1
"""

program.parseAsync(process.argv).catch (e) ->
  console.error e
  process.exit(1)
