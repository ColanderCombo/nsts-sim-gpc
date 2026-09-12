# idp -- the MEDS Integrated Display Processors, with no window
#
# Usage (via idp, which rebuilds first):
#   idp run                            # IDP 1 to 4
#   idp run --units 1,2 --ipl-request 1   # two units, one asking for a load
#   idp run --ipl-request 1,2,3,4      # all four ask
#   idp run --fill data/TEST-9011-GPC_MEMORY.dfb   # a display with no GPC
#   idp run -q
#
# The keyboards, the IDP/CRT SEL switches, the IDP LOAD momentaries and
# the GPC side of the DK bus are driven with gpcmd and from the sim
# manager's GPC STATUS page; the MDUs are meds.
#
import * as fs from 'fs'
import {busSettings} from './../../com/bus.civet.jsx'
import {addBusOptions} from './../../com/busCli'
import {wordsFromBytes} from './../deu/deuFCW'
import {MEDSConf} from './../medsConf'
import {IDP, UNITS} from './idp'
import {IDP_DISCRETES} from './idpDiscretes'
{Command} = require 'commander'
process = require 'process'

die = (msg) ->
  console.error "idp: #{msg}"
  process.exit(2)

# "1", "idp1" or "IDP1" -> "IDP1"
wantUnit = (s) ->
  n = String(s).trim().toUpperCase().replace(/^IDP/, '')
  u = "IDP#{n}"
  die "units are 1 to 4" unless u in UNITS
  u

# One occurrence of a repeatable option, taking a unit or a list of them.
collect = (v, acc) -> acc.concat(t for t in String(v).split(',') when t.trim())

program = new Command()
  .name('idp')
  .description('the MEDS Integrated Display Processors')
  .version('1.0.0')

addBusOptions(program.command('run')
  .description('run the processors on their busses')
  .option('--units <list>', 'units to run', '1,2,3,4')
  .option('--ipl-request <list>', 'units that ask the GPC for their control program, repeatable',
          collect, [])
  .option('--fill <dfb>', 'a display file loaded into every unit at the display header')
  .option('--stats-interval <secs>', 'print the running totals every N seconds', '0')
  .option('-q, --quiet', 'do not trace the DK bus'))
  .action (o) ->
    units = (wantUnit(s) for s in String(o.units).split(',') when s.trim())
    die "no units selected" unless units.length
    asking = (wantUnit(s) for s in o.iplRequest)
    for u in asking when u not in units
      die "#{u} is not running"
    fill = if o.fill then wordsFromBytes(fs.readFileSync(o.fill)) else null

    idps = {}
    for u in units
      idps[u] = new IDP({unit: u, ipled: u not in asking, quiet: o.quiet})
    for u, idp of idps
      idp.loadFCWs(fill) if fill?
      idp.start()
      console.log "IDP #{idp.idpNo} on #{idp.busPorts()}" +
                  "#{if idp.unit.ipled then '' else ', asking for an IPL'}"
    console.log "base port #{busSettings.basePort} -- ^C to stop"

    secs = parseFloat(o.statsInterval)
    if secs > 0
      setInterval (->
        for u, idp of idps
          s = idp.stats
          console.log "#{u}: #{s.heartbeats} beats, #{s.adcFrames} ADC frames, " +
                      "#{s.fcMessages} FC messages, #{s.keys} keys (#{s.keysDropped} dropped), " +
                      "DK #{idp.unit.stats?.wordsIn ? 0} in / #{idp.unit.stats?.wordsOut ? 0} out"
        ), secs * 1000
    process.on 'SIGINT', ->
      idp.halt() for u, idp of idps
      process.exit(0)
    process.on 'SIGTERM', -> process.exit(0)

program.command('units')
  .description('the units and their busses')
  .action () ->
    for u in UNITS
      c = MEDSConf.idps[u]
      n = Number(u.replace(/\D/g, ''))
      console.log "#{u}  DK #{c.dkBus}  busses #{c.busses.join(' ')} #{IDP_DISCRETES.busName(n)}  " +
                  "MDUs #{c.errorMsgTarget.join(' ')}"
    process.exit(0)

program.parse(process.argv)
