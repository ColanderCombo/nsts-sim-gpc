# mmu -- simulate a Mass Memory Unit
#
# Usage (via MMU.sh, which rebuilds first):
#   MMU.sh run --unit 1 --volume tape.mmv
#   MMU.sh create tape.mmv
#   MMU.sh put tape.mmv 0/0/0/0 somefile.bin
#   MMU.sh get tape.mmv 0/0/0/0 --blocks 2 -o out.bin
#   MMU.sh ls tape.mmv
#   MMU.sh dump tape.mmv 0/0/0/0
#   MMU.sh watch MM1
#
import * as fs from 'fs'
import {Bus, BusMsg, busConfig} from './../com/bus.civet.jsx'
import {Volume} from './volume'
import {MMU} from './mmu'
import {HALFWORDS_PER_BLOCK, BLOCKS_TOTAL, parseAddr, fmtAddr,
        blockIndex, blockAddr, checksum, decodeCommand} from './mmuConf'

{Command} = require 'commander'
process = require 'process'

BIND_MS   = 150
LINGER_MS = 250

die = (msg) ->
  console.error "mmu: #{msg}"
  process.exit(2)

openVolume = (path, opts = {}) ->
  return Volume.load(path) if fs.existsSync path
  die "#{path}: no such volume (mmu create #{path})" unless opts.create
  new Volume({path})

wantAddr = (s) ->
  a = parseAddr(s)
  die "bad tape address '#{s}' (want track/file/subfile/block, or a number)" unless a?
  a

hex4 = (v) -> (v & 0xffff).toString(16).padStart(4, '0')

program = new Command()
  .name('mmu')
  .description('Space Shuttle Mass Memory Unit -- device model and tape tools')
  .version('1.0.0')

# run
#
program.command('run')
  .description('run a mass memory unit on its bus and answer a GPC')
  .option('--unit <n>', 'mass memory unit 1 or 2 (bus MM1 / MM2)', '1')
  .option('--bus <name>', 'override the bus this unit hangs on')
  .option('--volume <file>', 'tape volume to serve (default: a blank tape)')
  .option('--write-protect', 'refuse every write')
  .option('--fault-on-blank', 'report a data dropout when a block was never written')
  .option('--reply-delay <ms>', 'delay before answering a command', '0')
  .option('--block-delay <ms>', 'delay between the blocks of a transfer', '0')
  .option('--save-on-exit', 'write the volume back when the process is stopped')
  .option('-q, --quiet', 'do not trace commands')
  .action (o) ->
    vol = if o.volume then openVolume(o.volume, {create: true}) else new Volume()
    vol.writeProtect = true if o.writeProtect

    mmu = new MMU({
      unit:         parseInt(o.unit, 10)
      bus:          o.bus
      volume:       vol
      verbose:      not o.quiet
      faultOnBlank: !!o.faultOnBlank
      replyDelayMs: parseFloat(o.replyDelay)
      blockDelayMs: parseFloat(o.blockDelay)
    })

    console.log "MMU#{mmu.unit} on #{mmu.busName} (port #{busConfig[mmu.busName].port}), " +
                "#{vol.count()} block(s)#{if vol.path then " from #{vol.path}" else ' (blank tape)'}"
    console.log "^C to stop"

    stop = () ->
      console.log ''
      console.log JSON.stringify(mmu.report(), null, 2)
      if o.saveOnExit and vol.path and vol.dirty
        console.log "saving #{vol.path} (#{vol.count()} blocks)"
        vol.save()
      process.exit(0)
    process.on 'SIGINT', stop
    process.on 'SIGTERM', stop

    setInterval (->), 60000

# volume tools
#

program.command('create')
  .description('create an empty tape volume')
  .argument('<volume>', 'volume file to write')
  .option('--write-protect', 'mark the volume write protected')
  .action (path, o) ->
    die "#{path}: already exists" if fs.existsSync path
    v = new Volume({path, writeProtect: !!o.writeProtect})
    n = v.save(path)
    console.log "created #{path} (#{n} bytes, no blocks)"

program.command('put')
  .description('lay a halfword stream onto the tape, one block at a time')
  .argument('<volume>', 'volume file')
  .argument('<address>', 'starting tape address')
  .argument('<file>', 'binary file of big-endian halfwords')
  .option('--checksum', 'replace the last halfword of each block with its checksum')
  .action (path, addrStr, src, o) ->
    v    = openVolume(path, {create: true})
    addr = wantAddr(addrStr)
    buf  = fs.readFileSync(src)
    die "#{src}: #{buf.length} bytes is not a whole number of halfwords" if buf.length % 2
    words = new Uint16Array(buf.length / 2)
    words[i] = buf.readUInt16BE(i * 2) for i in [0...words.length] by 1

    first = blockIndex(addr)
    n = Math.ceil(words.length / HALFWORDS_PER_BLOCK)
    if first + n > BLOCKS_TOTAL
      die "#{fmtAddr(addr)} + #{n} blocks runs off the end of the tape"
    v.writeStream(first, words)
    if o.checksum
      for i in [0...n] by 1
        b = v.read(first + i)
        b[HALFWORDS_PER_BLOCK - 1] = checksum(b, 0, HALFWORDS_PER_BLOCK - 1)
        v.write(first + i, b)
    v.save(path)
    console.log "wrote #{n} block(s) at #{fmtAddr(addr)} from #{src}"

program.command('get')
  .description('read blocks off the tape')
  .argument('<volume>', 'volume file')
  .argument('<address>', 'starting tape address')
  .option('--blocks <n>', 'how many blocks', '1')
  .option('-o, --out <file>', 'write to a file instead of reporting')
  .action (path, addrStr, o) ->
    v     = openVolume(path)
    addr  = wantAddr(addrStr)
    n     = parseInt(o.blocks, 10)
    first = blockIndex(addr)
    buf   = Buffer.alloc(n * HALFWORDS_PER_BLOCK * 2)
    for i in [0...n] by 1
      b = v.read(first + i)
      buf.writeUInt16BE(b[j], (i * HALFWORDS_PER_BLOCK + j) * 2) for j in [0...HALFWORDS_PER_BLOCK] by 1
    if o.out
      fs.writeFileSync(o.out, buf)
      console.log "#{n} block(s) from #{fmtAddr(addr)} -> #{o.out} (#{buf.length} bytes)"
    else
      for i in [0...n] by 1
        a = blockAddr(first + i)
        b = v.read(first + i)
        console.log "#{fmtAddr(a)}  #{if v.has(first + i) then 'written' else 'blank  '}" +
                    "  sum=#{hex4 checksum(b, 0, HALFWORDS_PER_BLOCK - 1)}" +
                    "  last=#{hex4 b[HALFWORDS_PER_BLOCK - 1]}"

program.command('ls')
  .description('list the blocks a volume holds')
  .argument('<volume>', 'volume file')
  .action (path) ->
    v = openVolume(path)
    console.log "#{path}: #{v.count()} block(s) of #{v.hwPerBlock} halfwords" +
                "#{if v.writeProtect then ', write protected' else ''}"
    runFrom = null
    prev    = null
    flush = () ->
      return unless runFrom?
      a = blockAddr(runFrom)
      b = blockAddr(prev)
      if runFrom == prev
        console.log "  #{fmtAddr(a)}"
      else
        console.log "  #{fmtAddr(a)} .. #{fmtAddr(b)}  (#{prev - runFrom + 1} blocks)"
      return
    for e in v.entries()
      if prev? and e.index == prev + 1
        prev = e.index
      else
        flush()
        runFrom = prev = e.index
    flush()

program.command('dump')
  .description('hex dump one block')
  .argument('<volume>', 'volume file')
  .argument('<address>', 'tape address')
  .option('--words <n>', 'how many halfwords', "#{HALFWORDS_PER_BLOCK}")
  .action (path, addrStr, o) ->
    v = openVolume(path)
    a = wantAddr(addrStr)
    b = v.read(a)
    n = Math.min(parseInt(o.words, 10), HALFWORDS_PER_BLOCK)
    console.log "#{fmtAddr(a)} (#{if v.has(a) then 'written' else 'blank'})"
    for i in [0...n] by 8
      row = (hex4 b[j] for j in [i...Math.min(i + 8, n)])
      console.log "  #{i.toString(16).padStart(4, '0')}  #{row.join(' ')}"

# bus tools
#
program.command('watch')
  .description('print the traffic on a mass memory bus')
  .argument('[bus]', 'bus name', 'MM1')
  .option('--decode', 'decode command words')
  .action (busName, o) ->
    die "unknown bus '#{busName}'" unless busName of busConfig
    bus = new Bus(busName, busConfig[busName])
    bus.onReceive ((_, busID, msg) ->
      words = msg.data16
      if o.decode and words.length == 2
        cmd = ((words[0] & 0xffff) << 8) | ((words[1] >> 8) & 0xff)
        c = decodeCommand(cmd)
        console.log "#{busID}: CMD #{hex4 words[0]}#{hex4 words[1]}  #{JSON.stringify(c)}"
      else
        hex = (hex4 words[i] for i in [0...Math.min(words.length, 16)])
        more = if words.length > 16 then " ... (#{words.length} words)" else ''
        console.log "#{busID}: #{hex.join(' ')}#{more}"
    ), null
    console.log "watching #{busName} (port #{busConfig[busName].port}), ^C to stop"
    setInterval (->), 60000

program.command('send')
  .description('put a command on a mass memory bus (test equipment)')
  .argument('<bus>', 'bus name, e.g. MM1')
  .argument('<cmd24>', '24-bit command word in hex')
  .action (busName, cmdStr) ->
    die "unknown bus '#{busName}'" unless busName of busConfig
    cmd = parseInt(cmdStr, 16) & 0xffffff
    bus = new Bus(busName, busConfig[busName])
    bus.onReceive (->), null      # swallow our own multicast loopback
    setTimeout (->
      msg = new BusMsg(2)
      msg.data16[0] = (cmd >>> 8) & 0xffff
      msg.data16[1] = (cmd & 0xff) << 8
      bus.sendMsg msg
      console.log "#{busName}: sent #{cmd.toString(16).padStart(6, '0')}"
      setTimeout (-> process.exit(0)), LINGER_MS
    ), BIND_MS

program.parse()
