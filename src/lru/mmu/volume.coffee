#
#
# Mass Memory Unit tape file
#
#
# A volume is the contents of one MMU: up to 131072 blocks of
# 512 halfwords, addressed track/file/subfile/block.  
# A full tape is 16 MB.
#
# This header is for our modern tools and isn't related
# to any period format.
#
#   offset  0   magic "MMUVOL01"             8 bytes
#           8   halfwords per block          u32
#          12   number of directory entries  u32
#          16   flags                        u32   bit 0 = write protected
#          20   reserved                     12 bytes, zero
#          32   directory                    entries x u32 block index,
#                                            ascending, no duplicates
#         ...   block data                   one block per entry, same
#                                            order, big-endian halfwords
#
# All data is big-endian 
#
# A block that is not in the directory currently reads back as zeros;
# this is reasonable but not authoritative.

import * as fs from 'fs'
import {HALFWORDS_PER_BLOCK, BLOCKS_TOTAL, blockIndex, blockAddr,
        fmtAddr} from './mmuConf'

MAGIC       = 'MMUVOL01'
HEADER_SIZE = 32
FLAG_WRITE_PROTECT = 0x1

export class Volume
  constructor: (opts = {}) ->
    @path           = opts.path ? null
    @hwPerBlock     = opts.hwPerBlock ? HALFWORDS_PER_BLOCK
    @writeProtect   = !!opts.writeProtect
    # block index -> Uint16Array(hwPerBlock)
    @blocks         = new Map()
    @dirty          = false

  # addressing
  #
  _index: (a) ->
    return a if typeof a == 'number'
    blockIndex(a)

  has: (a) -> @blocks.has(@_index(a))

  count: () -> @blocks.size

  # read / write
  #
  read: (a) ->
    idx = @_index(a)
    b = @blocks.get(idx)
    return new Uint16Array(@hwPerBlock) unless b?
    b

  write: (a, words) ->
    throw new Error('volume is write protected') if @writeProtect
    idx = @_index(a)
    throw new Error("block index #{idx} out of range") unless 0 <= idx < BLOCKS_TOTAL
    b = new Uint16Array(@hwPerBlock)
    n = Math.min(words.length, @hwPerBlock)
    b[i] = words[i] & 0xffff for i in [0...n] by 1
    @blocks.set(idx, b)
    @dirty = true
    b

  erase: (a) ->
    @dirty = true if @blocks.delete(@_index(a))
    return

  writeStream: (a, words) ->
    idx = @_index(a)
    n = Math.ceil(words.length / @hwPerBlock)
    for i in [0...n] by 1
      @write(idx + i, words.subarray(i * @hwPerBlock,
                                     Math.min((i + 1) * @hwPerBlock, words.length)))
    n

  entries: () ->
    idx = [...@blocks.keys()].sort (x, y) -> x - y
    for i in idx
      addr = blockAddr(i)
      {index: i, addr: addr, name: fmtAddr(addr), data: @blocks.get(i)}

  # file format
  #
  @load: (path) ->
    buf = fs.readFileSync(path)
    throw new Error("#{path}: not an MMU volume") if buf.length < HEADER_SIZE
    unless buf.toString('latin1', 0, 8) == MAGIC
      throw new Error("#{path}: not an MMU volume")
    hwPerBlock = buf.readUInt32BE(8)
    entries    = buf.readUInt32BE(12)
    flags      = buf.readUInt32BE(16)
    unless 0 < hwPerBlock <= 65536
      throw new Error("#{path}: block size #{hwPerBlock} halfwords")
    need = HEADER_SIZE + entries * 4 + entries * hwPerBlock * 2
    if buf.length < need
      throw new Error("#{path}: truncated (#{buf.length} of #{need} bytes)")

    v = new Volume({path, hwPerBlock, writeProtect: (flags & FLAG_WRITE_PROTECT) != 0})
    dataAt = HEADER_SIZE + entries * 4
    for i in [0...entries] by 1
      idx = buf.readUInt32BE(HEADER_SIZE + i * 4)
      at = dataAt + i * hwPerBlock * 2
      b = new Uint16Array(hwPerBlock)
      b[j] = buf.readUInt16BE(at + j * 2) for j in [0...hwPerBlock] by 1
      v.blocks.set(idx, b)
    v.dirty = false
    v

  save: (path = @path) ->
    throw new Error('no path for volume') unless path
    ents = @entries()
    buf = Buffer.alloc(HEADER_SIZE + ents.length * 4 +
                       ents.length * @hwPerBlock * 2)
    buf.write(MAGIC, 0, 'latin1')
    buf.writeUInt32BE(@hwPerBlock, 8)
    buf.writeUInt32BE(ents.length, 12)
    buf.writeUInt32BE((if @writeProtect then FLAG_WRITE_PROTECT else 0), 16)
    dataAt = HEADER_SIZE + ents.length * 4
    for e, i in ents
      buf.writeUInt32BE(e.index, HEADER_SIZE + i * 4)
      at = dataAt + i * @hwPerBlock * 2
      buf.writeUInt16BE(e.data[j], at + j * 2) for j in [0...@hwPerBlock] by 1
    fs.writeFileSync(path, buf)
    @path = path
    @dirty = false
    buf.length
