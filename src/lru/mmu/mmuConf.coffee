#
#
# Mass Memory Unit -- interface constants
#
# Device ID  = 11
# Bus number = 18 (MM1), 19 (MM2)
# IUA        = 11
#
#
# GEOMETRY
#
#   8 tracks x 8 files x 8 subfiles x 32 blocks x 512 halfwords
#     = 8,388,608 halfwords of storage.
#
# A track is a pass along the tape and a block the unit of transfer.  A
# file/track pair holds eight subfiles. Data is always written in 
# 512-halfword blocks regardless of how much the requestor asked for; 
# reads of less than a block are supported, because the IOP is not 
# required to receive in block units.
#
# A logical record's last halfword is a checksum: the sum (mod 2^16) of
# the halfwords before it, reader verified.
# (IBM-77-SS-3576/p.483)
#
#
# TAPE ADDRESS 
#
#   bits 0-1    unused
#        2-4    file
#        5-7    track
#        8-10   subfile
#        11-15  block
#
# Note the file/track order here is the OPPOSITE of the order in the
# position word below.
#
# BUS COMMAND WORD (24-bits)
#
#   bits 23-19  IUA -- 11 for mass memory
#        18-15  opcode
#        14-0   per-opcode operand
#
#
#
# OPCODES
#
#   0  POSITION           seek to a track/file/subfile boundary
#   1  BITE STATUS        return status registers A and B (2 halfwords)
#   2  POSITION REQUEST   return the current position (1 halfword)
#   3  EXTENDED BLOCK     block count > 15 for the read/write that follows
#   8  WRITE              write N blocks
#   9  READ               read N blocks
#  10  WRITE ENABLE       arm the write circuits for one track
#
# (The 1..10 opcode list that appears in mass-memory I/O REQUEST blocks --
# "write with checksum", "read ops overlay", "position tape" and so on --
# is a different, higher layer: those are requests made of the mass memory
# utility in software, which decomposes each into some sequence of the bus
# commands above.)
#
#
# POSITION REQUEST / POSITION WORD:
#
#   bits 0-1    unused
#        2-4    track
#        5-7    file
#        8-10   subfile
#        11     beginning of file
#        12     end of file
#        13-15  unused
#
# The value names the inter-record GAP the head is sitting in, not a
# block: subfile N means "past subfile N-1, before subfile N".  Reading
# blocks therefore leaves the position at the gap after the last block
# read -- one more than the subfile that block was in.
#
#
# BITE STATUS / STATUS REGISTER A / STATUS REGISTER B
#   1 = error
#
#   A  0  power transient
#      1  read/write address not equal to the commanded one
#      2  address is within or behind the search field
#      3  write protect violation
#      4  invalid opcode, or MIA command error
#      5-15 unused
#
#   B  0  write word count invalid      
#      1  read tape data dropout        
#      2  clock assurance on read       
#      3  read parity error             
#      4  MIA invalid Manchester        
#      5  command received not ready    
#      6  end of file, block count != 0 
#      7  end of file, no address match 
#      8  transport malfunction
#      9  beginning of tape sensed
#     10  end of tape sensed
#     11  operation aborted
#     12  MIA bit count error
#     13  MIA parity error on data
#     14  invalid '101' check
#     15  MIA data/address error
#
#
# Place to dump spec excerpts:
#
#   SS-P-0002-170H/p.4-29 sect.4.6.2.3.2 par.5:
#     All areas on the MM not filled with software elements shall contain
#     a fill batter of C6C6_16. No checksums shall be included at any
#     location for this fill data.
#   par.8:
#     Those areas of a MM block between the load block checksum and the end 
#     of the MM block shall be filled with a C6C6_16 fill pattern.
#


# geometry
#
TRACKS              = 8
FILES               = 8
SUBFILES            = 8
BLOCKS_PER_SUBFILE  = 32
HALFWORDS_PER_BLOCK = 512

# A file/track pair holds 8 subfiles, and that pair is what the
# end-of-file flag refers to: reading past subfile 7 is the end of the
# file.  A whole FILE is that for every track, which is how much of the
# tape one file number covers.
BLOCKS_PER_TRACK    = SUBFILES * BLOCKS_PER_SUBFILE     # one file/track pair
BLOCKS_PER_FILE     = TRACKS * BLOCKS_PER_TRACK
BLOCKS_TOTAL        = FILES * BLOCKS_PER_FILE

IUA = 11

OP =
  POSITION:       0x0
  BITE_STATUS:    0x1
  POSITION_REQ:   0x2
  EXTENDED_BLOCK: 0x3
  WRITE:          0x8
  READ:           0x9
  WRITE_ENABLE:   0xA

OP_NAME = {}
OP_NAME[v] = k for k, v of OP

# status bits (halfword, bit 0 = 0x8000)
#

STAT_A =
  POWER_TRANSIENT:   0x8000
  ADDR_MISCOMPARE:   0x4000
  ADDR_BEHIND:       0x2000
  WRITE_PROTECT:     0x1000
  INVALID_COMMAND:   0x0800

STAT_B =
  WRITE_COUNT:       0x8000
  DATA_DROPOUT:      0x4000
  CLOCK_ASSURANCE:   0x2000
  READ_PARITY:       0x1000
  BAD_MANCHESTER:    0x0800
  NOT_READY:         0x0400
  EOF_BLOCK_COUNT:   0x0200
  EOF_NO_COMPARE:    0x0100
  MALFUNCTION:       0x0080
  BOT:               0x0040
  EOT:               0x0020
  ABORTED:           0x0010
  MIA_BIT_COUNT:     0x0008
  MIA_PARITY:        0x0004
  MIA_101_CHECK:     0x0002
  MIA_DATA_ADDRESS:  0x0001

# command decode
#
decodeCommand = (cmd24) ->
  cmd = cmd24 & 0xffffff
  c =
    raw:    cmd
    iua:    (cmd >> 19) & 0x1f
    opcode: (cmd >> 15) & 0x0f
  c.name = OP_NAME[c.opcode] ? "OP#{c.opcode}"
  switch c.opcode
    when OP.POSITION
      c.track   = (cmd >> 12) & 7
      c.subfile = (cmd >> 9) & 7
      c.bof     = (cmd >> 7) & 1
      c.eof     = (cmd >> 6) & 1
      c.file    = (cmd >> 1) & 7
    when OP.READ, OP.WRITE
      c.track   = (cmd >> 12) & 7
      c.subfile = (cmd >> 9) & 7
      c.block   = (cmd >> 4) & 0x1f
      c.count   = cmd & 0x0f
    when OP.EXTENDED_BLOCK
      c.count   = cmd & 0xff
    when OP.WRITE_ENABLE
      c.track   = (cmd >> 12) & 7
  c

# position word
#
packPosition = (p) ->
  w = ((p.track & 7) << 11) | ((p.file & 7) << 8) | ((p.subfile & 7) << 5)
  w |= 0x0010 if p.bof
  w |= 0x0008 if p.eof
  w & 0xffff

unpackPosition = (hw) ->
  track:   (hw >> 11) & 7
  file:    (hw >> 8) & 7
  subfile: (hw >> 5) & 7
  bof:     if (hw & 0x0010) then 1 else 0
  eof:     if (hw & 0x0008) then 1 else 0

# tape address halfword (file/track/subfile/block)
#
packTapeAddr = (a) ->
  (((a.file & 7) << 11) | ((a.track & 7) << 8) |
   ((a.subfile & 7) << 5) | (a.block & 0x1f)) & 0xffff

unpackTapeAddr = (hw) ->
  file:    (hw >> 11) & 7
  track:   (hw >> 8) & 7
  subfile: (hw >> 5) & 7
  block:    hw & 0x1f

blockIndex = (a) ->
  (((a.file & 7) * TRACKS + (a.track & 7)) * SUBFILES +
   (a.subfile & 7)) * BLOCKS_PER_SUBFILE + (a.block & 0x1f)

blockAddr = (idx) ->
  block:   idx % BLOCKS_PER_SUBFILE
  subfile: Math.floor(idx / BLOCKS_PER_SUBFILE) % SUBFILES
  track:   Math.floor(idx / BLOCKS_PER_TRACK) % TRACKS
  file:    Math.floor(idx / BLOCKS_PER_FILE) % FILES

fmtAddr = (a) -> "#{a.track}/#{a.file}/#{a.subfile}/#{a.block}"

# A position names a gap, not a block, so it prints without one.
fmtPos = (p) ->
  s = "#{p.track}/#{p.file}/#{p.subfile}"
  s += ' BOF' if p.bof
  s += ' EOF' if p.eof
  s

# "t/f/s/b", or a bare hex/decimal number read as a tape address halfword.
parseAddr = (s) ->
  t = String(s).trim()
  if /^\d+\/\d+\/\d+\/\d+$/.test t
    [track, file, subfile, block] = (parseInt(x, 10) for x in t.split('/'))
    return null unless 0 <= track < TRACKS and 0 <= file < FILES and
                       0 <= subfile < SUBFILES and 0 <= block < BLOCKS_PER_SUBFILE
    return {track, file, subfile, block}
  n = if /^0x/i.test t then parseInt(t, 16) else parseInt(t, 10)
  return null if isNaN n
  unpackTapeAddr(n & 0xffff)

# record checksum
#
checksum = (words, from = 0, to = words.length) ->
  s = 0
  i = from
  while i < to
    s = (s + (words[i] & 0xffff)) & 0xffff
    i += 1
  s

export {
  TRACKS, FILES, SUBFILES, BLOCKS_PER_SUBFILE, HALFWORDS_PER_BLOCK
  BLOCKS_PER_FILE, BLOCKS_PER_TRACK, BLOCKS_TOTAL
  IUA, OP, OP_NAME, STAT_A, STAT_B
  decodeCommand, packPosition, unpackPosition
  packTapeAddr, unpackTapeAddr
  blockIndex, blockAddr, fmtAddr, fmtPos, parseAddr, checksum
}
