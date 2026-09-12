# Packet counters and the four most recent packet prefixes, up to 24 bytes.
# Samples describe local send attempts and received packets.
export class BusTraffic
  constructor: ->
    @rx = 0
    @tx = 0
    @seq = 0
    @recent = []

  note: (direction, data, length = data.length) ->
    @[direction] += 1
    @recent.push {seq: ++@seq, time: Date.now() / 1000, direction,
                  length, bytes: Array.from(data.subarray(0, Math.min(24, length)))}
    @recent.shift() while @recent.length > 4
    return

  snapshot: ->
    {rx: @rx, tx: @tx, seq: @seq, recent: @recent.map (sample) ->
      {seq: sample.seq, time: sample.time, direction: sample.direction,
       length: sample.length, hex: sample.bytes.map((value) -> value.toString(16).padStart(2, '0')).join(' ')}
    }
