
import {addBusOptions} from 'com/busCli'
import {busSettings, busConfig, shmNames} from 'com/bus'
import {describe as barrierTable, deltaUs} from 'com/simbarrier'

{inspect, unlinkSegment, available} = require './../../com/busshm'

export addCommand = (program) ->
  cmd = program
    .command('shm')
    .description("the session's shared-memory bus ring")
    .option('--unlink', 'drop the segment')
    .action (o) ->
      base = busSettings.basePort
      if o.unlink
        rc = unlinkSegment(base)
        console.log(if rc == 0 then "dropped /nsts2.#{base}" else "no ring at /nsts2.#{base}")
        return
      console.log "this process would carry #{shmNames.size} bus(ses): " +
                  "#{if shmNames.size then Array.from(shmNames).join(' ') else 'none'}"
      unless available()
        console.log 'shared-memory addon unavailable'
        return
      try
        r = inspect(base)
      catch e
        console.log "no ring at /nsts2.#{base}: #{e.message}"
        return
      console.log "#{r.name}  #{r.slots} slots of #{r.slotBytes} bytes, " +
                  "#{(r.bytes / 1048576).toFixed(1)} MB"
      console.log "#{r.written} datagram(s) written by #{r.writers} bus(ses)"
      console.log "#{r.members.length} process(es) on the ring: " +
                  "#{if r.members.length then r.members.join(', ') else 'none'}"
      rows = barrierTable(r.hdr)
      console.log "barrier #{if deltaUs() then deltaUs() + ' us here' else 'off here'}, " +
                  "#{rows.length} machine(s) on it"
      for row in rows
        console.log "  GPC #{row.who} pid #{row.pid} " +
                    "#{(row.behindUs / 1000).toFixed(3)} ms behind the furthest on, " +
                    "published #{(row.ageUs / 1000).toFixed(1)} ms ago"
      return
  addBusOptions(cmd)
  cmd
