# dfbDump — print a format control word stream.
#
#   node build/dist/dfbDump.js <file.dfb>
#
import {FCW, wordsFromBytes} from 'meds/deu/deuFCW'
import * as fs from 'fs'
process = require 'process'

fcw = new FCW()
words = wordsFromBytes fs.readFileSync(process.argv[2])

for hw, i in words
  d = fcw.decodeFCW hw
  addr = i.toString(16).padStart(4,'0')
  word = hw.toString(16).padStart(4,'0')
  if d?
    console.log "#{addr}\t#{word}\t#{d.nm}\t#{JSON.stringify(d.v)}"
  else
    console.log "#{addr}\t#{word}\t???"
