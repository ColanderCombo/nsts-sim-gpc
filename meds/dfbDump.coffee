import {FCW} from '../meds/deuFCW'
import * as fs from 'fs'
process = require 'process'

fcw = new FCW()

buf = fs.readFileSync process.argv[2]
n = Math.floor(buf.length/2)
data16 = new Uint16Array(n)
for i in [0...n]
  data16[i] = buf[i*2] | (buf[i*2+1] << 8)

for i in [0...n]
  hw = data16[i]
  d = fcw.decodeFCW hw
  if d?
    console.log "#{i}\t#{hw.toString(16).padStart(4,'0')}\t#{d.nm}\t#{JSON.stringify(d.v)}"
  else
    console.log "#{i}\t#{hw.toString(16).padStart(4,'0')}\t???"
