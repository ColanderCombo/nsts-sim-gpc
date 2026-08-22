import {PackedBits} from '../gpc/util'

#
# DEU Format Control Words 
#
# These encodings match the Display Format Generator (`src/dfg/fcw.py` in the
# sdl tree), which builds the words a GPC sends.
#
# The DEU drives a vector CRT 'display unit' (And in the MEDS upgrade the MDU's 
# emulate the vector drawing).  FCW's are the display list stored on the DEU and
# executed to produce the vector drawing instructions.
#
# An example FCW stream:
#
#   5013  major increment  +19  (advance one character column per glyph)
#   78E5  minor increment  -27  (a carriage return drops one row)
#   3800  FCW1  attributes -- no blink, no dash, single intensity
#   3006  FCW2  small upright characters
#   3400  FCW3  colour, select off (the DEU's own default)
#   0000  position-run lead
#   8555  X = 1365   (character column 17: 1042 + 19*17)
#   9153  Y =  339   (character row     1:  366 - 27*1)
#   E0C2  glyph pair -- 0x41 'A' then 0x42 'B'
#   C00D  carriage return
#   19EE  branch back into the DEU's own program: end of the section
#
# Screen geometry: the beam sits on a 2048-unit modular grid -- the position
# field is eleven bits and the word above it writes the axis' reference
# register instead, so the coordinate wraps at 2048.  Character cell column c is at X = 1573 + 19c,
# row r at Y = 364 - 27r (rows run DOWN, so Y decreases), both modulo the
# grid; that puts the format area at columns 0..51 and rows 0..25.
#
#
GRID        = 2048   # beam-coordinate wrap, both axes
COL_PITCH   = 19     # screen units per character column (small characters)
ROW_PITCH   = 27     # screen units per character row
COL_PITCH_L = 24     # ... large characters (SIZE=L)
ROW_PITCH_L = 32
COL_ORIGIN  = 1573   # beam X of cell column 0
ROW_ORIGIN  = 364    # beam Y of cell row 0
ABS_X_ORIGIN = 1555  # beam X of absolute screen coordinate 0 (cell col 0 = 18)
ABS_Y_ORIGIN = 364   # beam Y of absolute screen coordinate 0 (= cell row 0)

export {GRID, COL_PITCH, ROW_PITCH, COL_PITCH_L, ROW_PITCH_L,
        COL_ORIGIN, ROW_ORIGIN, ABS_X_ORIGIN, ABS_Y_ORIGIN}

# Beam register -> screen coordinate, in character cells with the origin at
# the top left of the format area.  Both are modular: a column past the right
# of the grid wraps through zero.
export screenX = (x) -> ((x - ABS_X_ORIGIN + GRID) %% GRID) / COL_PITCH
export screenY = (y) -> ((ABS_Y_ORIGIN - y + GRID) %% GRID) / ROW_PITCH

# The same thing in character cells, which is what the renderer draws in:
# cell column 0 reads 0, cell row 0 reads 0, and a beam parked between cells
# reads a fraction.  These are the inverses of `cellX`/`cellY` below.
export cellCol = (x) -> ((x - COL_ORIGIN + GRID) %% GRID) / COL_PITCH
export cellRow = (y) -> ((ROW_ORIGIN - y + GRID) %% GRID) / ROW_PITCH

# Beam modes in FCW2's low nibble.  Bit 2 is the "upright" bit, which
# character rotation clears -- so rotated characters read 2 / 3.
export MODE = {VECTOR: 5, CHAR_SMALL: 6, CHAR_LARGE: 7}

# The REPEAT word: the number of repeats is (REPT_BASE - <FCW>)
# So, for 0x083A, reps = 0x0841 - 0x83A = 7
REPT_BASE = 0x0841
export {REPT_BASE}

# A `.dfb` file is the halfword stream as it goes over the bus: big endian,
# and the order the critical-format load module holds it in.
export wordsFromBytes = (buf) ->
  (((buf[2*i] << 8) | buf[2*i+1]) for i in [0...Math.floor(buf.length / 2)])

export bytesFromWords = (words) ->
  out = new Uint8Array(words.length * 2)
  for w, i in words
    out[2*i]   = (w >> 8) & 0xff
    out[2*i+1] = w & 0xff
  out

export class FCW extends PackedBits
  constructor: () ->
    super()
    @makeFCWTable()
    @makeCharToDEU()

  # word <-> descriptor
  #
  # `encodeFCW`/`decodeFCW` wrap PackedBits with the three things the bit
  # descriptors cannot express: the subtractive REPEAT count, sign extension
  # on the two step words, and the glyph <-> character translation.

  encodeFCW: (desc) ->
    if desc.nm == 'REPT'
      return (REPT_BASE - (desc.count ? 0)) & 0xffff
    d = desc
    if desc.nm == 'CHAR2'
      d = Object.assign {}, desc
      d.char1 = @toGlyph desc.char1
      d.char2 = @toGlyph desc.char2
    return @encode(d)

  decodeFCW: (hw) ->
    hw = hw & 0xffff
    desc = @decode(hw)
    return undefined if not desc?
    out = {nm: desc.nm, v: Object.assign({}, desc.v), word: hw}
    switch out.nm
      when 'REPT'
        out.v.count = (REPT_BASE - hw) & 0xffff
      when 'MAJINC'
        out.v.step = @signExtend out.v.step, 11
      when 'MININC', 'SPTYPE'
        out.v.step = @signExtend out.v.step, 8
      when 'ROT'
        out.v.quarterTurns = out.v.angle >> 10
      when 'BRANCH'
        # op 1's bottom bit is address bit 12 (see the table entry); the
        # 12-bit field stays as `addr12` for the record, `addr` is the target
        out.v.addr = hw & 0x1fff
      when 'CHAR2'
        out.v.g1 = out.v.char1
        out.v.g2 = out.v.char2
        out.v.char1 = @DEUCharset[out.v.char1]
        out.v.char2 = @DEUCharset[out.v.char2]
    return out

  signExtend: (v, bits) ->
    sign = 1 << (bits - 1)
    if v & sign then v - (1 << bits) else v

  toGlyph: (c) ->
    return c if typeof c == 'number'
    g = @chrToDEU[c]
    return if g? then Number(g) else 0x20

  noop:      ()        -> 0x0000
  repeat:    (n)       -> (REPT_BASE - n) & 0xffff
  branch:    (addr)    -> 0x1000 | (addr & 0x1fff)
  subList:   (n, addr) -> [0x2100 | (n & 0x00ff), 0x1000 | (addr & 0x1fff)]
  attrMode:  (o={})    -> 0x3800 | (if o.dash then 0x200 else 0) |
                                   (if o.blink then 0x100 else 0) |
                                   (if o.axisY then 0x020 else 0) |
                                   (if o.intensity then 0x008 else 0)
  #
  # NOTE: the interpretation of bits 5-6 is currently unclear.
  #   the FCW2 macro says they set polar coordinate mode: POLRX & POLRY
  #   dfg input suggests they set 'alternate character set'
  #
  charMode:  (o={})    ->
    mode = if o.large then MODE.CHAR_LARGE else MODE.CHAR_SMALL
    mode = mode & ~0x4 if o.rotated          # rotation clears the upright bit
    0x3000 | mode | (if o.alt then 0x40 else 0) |
                    (if o.alt and o.rotated then 0x20 else 0)
  vectorBegin: ()      -> 0x3000 | MODE.VECTOR
  endOfRefresh: ()     -> 0x3200   # FCW2 with the end-of-refresh bit
  colorMode: (code)    ->
    if code? then 0x3400 | 0x80 | (code & 0x3f) else 0x3400 | 40
  colorClear: ()       -> 0x3400
  valueDisplay: (n)    -> 0x3c00 | (n & 0x3ff)
  rotation:  (turns)   -> 0x4000 | ((turns & 3) << 10)
  angle:     (a)       -> 0x4000 | (a & 0xfff)
  majorInc:  (units)   -> 0x5000 | (units & 0x7ff)
  minorInc:  (units)   -> 0x7800 | (units & 0xff)
  specialType: (units) -> 0x7c00 | (units & 0xff)
  xPosition: (x)       -> 0x8000 | (x & 0x7ff)
  yPosition: (y)       -> 0x9000 | (y & 0x7ff)
  translateX: (x=0)    -> 0x8800 | (x & 0x7ff)
  translateY: (y=0)    -> 0x9800 | (y & 0x7ff)
  vecSlope:  (o={})    -> 0xa000 | (if o.yMajor then 0x800 else 0) |
                                   (if o.signDiffer then 0x400 else 0) |
                                   (o.slope & 0x3ff)
  vecExtent: (major)   -> 0xb000 | (if major < 0 then 0x800 else 0) |
                                   (Math.abs(major) & 0x7ff)
  glyphPair: (g1, g2)  -> 0xc000 | ((g1 & 0x7f) << 7) | (g2 & 0x7f)
  glyphSingle: (g)     -> 0xc000 | (g & 0x7f)
  carrtn:    ()        -> 0xc00d
  deuReturn: ()        -> 0x19ee   # branch back into the DEU's own program

  # Character cell -> beam register.  Rounded: a fractional cell is a real
  # beam position, and the position field is an integer.
  cellX: (col) -> Math.round(COL_ORIGIN + COL_PITCH * col) %% GRID
  cellY: (row) -> Math.round(ROW_ORIGIN - ROW_PITCH * row) %% GRID
  absX:  (n)   -> (ABS_X_ORIGIN + n) %% GRID
  absY:  (n)   -> (ABS_Y_ORIGIN - n) %% GRID
  
  positionRun: (col, row) -> [@noop(), 
                              @xPosition(@cellX(col)),
                              @yPosition(@cellY(row))]

  # One straight segment in character-cell coordinates:
  # enter vector mode, position, the slope word, the extent word, and back to
  # character mode.  The major axis is the larger delta and carries the signed
  # extent; the slope word holds 2*round(minor*512/major), i.e. 9-bit
  # resolution in a 10-bit field.
  vector: (x0, y0, x1, y1) ->
    dx = COL_PITCH * (x1 - x0)
    dy = -ROW_PITCH * (y1 - y0)             # beam Y decreases going down
    yMajor = Math.abs(dy) > Math.abs(dx)
    major = Math.round(if yMajor then dy else dx)
    minor = Math.round(Math.abs(if yMajor then dx else dy))
    am = Math.abs(major)
    slope = if minor and am
      2 * Math.min(Math.floor((minor * 1024 + am) / (2 * am)), 511)
    else 0
    [@vectorBegin(), @xPosition(@cellX(x0)), @yPosition(@cellY(y0)),
     @vecSlope({yMajor: yMajor, signDiffer: dx * dy < 0, slope: slope}),
     @vecExtent(major), @charMode({})]

  # Text -> glyph-pair FCWs, two glyphs per word; an odd trailing glyph rides
  # in the low (second) slot on its own
  chars: (t) ->
    out = []
    i = 0
    while i < t.length
      if i + 1 < t.length
        out.push @glyphPair(@toGlyph(t[i]), @toGlyph(t[i+1]))
      else
        out.push @glyphSingle(@toGlyph(t[i]))
      i += 2
    return out

  makeFCWTable: () ->
    @descByOp = {}
    @opByMask = {}
    @orderedMasks = []

    for nom,def of @FCWS
      desc = @makeDesc def.d
      desc.nm = nom
      desc.nom = def.nom
      desc.revNom = {}
      for k,v of desc.nom
        desc.revNom[v] = k
      @descByOp[nom] = desc
      if desc.mask not of @opByMask
        @orderedMasks.push desc.mask
        @opByMask[desc.mask] = {}
      @opByMask[desc.mask][desc.maskedVal] = desc
      #console.log nom,desc

    # When matching a halfword we search from more to less specific, so order
    # the masks widest first.  
    @orderedMasks = @orderedMasks.sort((a,b) -> b - a)

  makeCharToDEU: () ->
    @chrToDEU = {}
    for k,v of @DEUCharset
      @chrToDEU[v] = k

  encode: (data) ->
    desc = @descByOp[data.nm]

    hw1 = desc.maskedVal # init to static bit pattern
    for k,v of data
      if desc.revNom[k] of desc.f
        hw1 = hw1 | @fld(desc.f[desc.revNom[k]], v)

    return hw1


  decode: (hw1) ->
    for msk in @orderedMasks
      mTbl = @opByMask[msk]
      hw1msk = hw1 & msk
      if hw1msk of mTbl
        op = mTbl[hw1msk]
        break
    if not op
      return undefined

    op.v = {}
    for k,fld of op.f
      op.v[op.nom[k]] = @getField(hw1,fld)

    return op

  CMDS:
    DFT_DISPLAY_ID: {
      d:'mmdddddddddddddd'
      nom: { m:'majorFunction', d:'displayNumber'}
    }
    DFT_KVT_DATA: {
      d:'iiiiiiiipeu__'
      nom: {
        i:'ITEM_COUNT_INO',
        p:'PRO_KEY_VALIDITY_BIT'
        e:'EXEC_KEY_VALIDITY_BIT'
        u:'ONE_TIME_ONLY_UPDATE_FLAG'
      }
    }
    DFT_ITEM_WORD_1: {
      d:'petttlllllllab__'
      nom: {
        p: 'termWithPRO',
        e: 'termWithEXEC',
        t: 'itemType',
            # b101 - scalar or octal
            # b100 - octal
            # b010 - integer
            # b001 - scalar
        l: 'limitTableIndex',
        a: 'updateAllOnExec',
        b: 'updateAllOnEnter'
      }
    }
    DFT_ITEM_WORD_2 : {
        # contains the format (number of characters) of the item data entry
        d:'ffffffffffffffff'
        nom: { f: 'formatOfItem' }
    }
    BILEVEL_TEST_CMD: {
        # DFG command to be used whenever the testing of tw(2) bits is required
        # before dynamic data can be displayed
        # DECLARE BLT ARRAY(3) BIT(16)
        d: '000001__bbbbcccc',
        nom: {
            b: 'BLT_BIT1_ID',
            c: 'BLT_BIT2_ID'
        }
    }
    FCW_REMOTE_CMD: {
      d: '00010_________t',
      nom: {
        t: 'FCW_TYPE'
      }
    }
    REMOTE_TEXT_CMD: {
      d:'000011__cccciill'
      nom: {
        c: 'RTC_CONTROL_BIT'
        i: 'RTC_INTENSITY'
        l: 'RTC_TEXT_LENGTH'
      }
    }
    VARIABLE_PARAMETER_CMD: {
      d:'000101__iiiioooo'
      nom: {
        i: 'VPARM_INTERNAL_CHARACTERISTICS'
        o: 'VPARM_OUTPUT_CHARACTERISTICS'
      }
    }
    VPARM_FMT: {
      d:'llllrrrrdzssss__'
      nom: {
        l: 'VPARM_FMT_1'
        r: 'VPARM_FMT_2'
        d: 'VPARM_DOWNLIST_STATUS'
        z: 'VPARM_ZEROES_STATUS'
        s: 'VPARM_SIGN_STATUS'
      }
    }
    REMOTE_CHARACTER_1: {
      d:'001010__nnnnnnnn'
      nom: {
        n: 'REMOTE_CHARACTER_LENGTH'
      }
    }
    REMOTE_CHARACTER_2: {
      d:'aaaaaaaaaaaaaaaa'
      nom: {
        a:'REMOTE_CHARACTER_ADDR'
      }
    }
    STATUS_BYTE_CMD_1: {
      d:'001101__________'
      nom: {
      }
    }
    STATUS_BYTE_CMD_2: {
      d:'aaaaaaaaaaaaaaaa'
      nom: {
        a:'STATUS_BYTE_ADDR'
      }
    }
    MULTIPLE_DISCRETE_TEST_CMD_1: {
      d:'010001__________'
      nom: {
      }
    }
    TEST_COMMAND: {
      d:'010010______cccc'
      nom: {
        c: 'TEST_CONTROL_BIT'
      }
    }
    IMMEDIATE_DATA: {
      d:'010100__nnnnnnnn'
      nom: {
        n: 'NUMBER_OF_FCWS'
      }
    }
    RATE_COMMAND: {
      d:'010101______rrrr'
      nom: {
        r: 'RATE_VALUE'
      }
    }
    BRANCH_COMMAND: {
      d:'010110__________'
      nom: {
      }
    }
    ON_DEMAND_CMD: {
      d:'010111______bbbb'
      nom: {
        b: 'ON_DEMAND_BIT_NUMBER'
      }
    }
    
  # }

  # FCW Word Definitions
  #
  # Bit descriptors run MSB (bit 15) first; '_' is a  don't-care 
  # bit, '0'/'1' are the fixed opcode bits, a letter names a field.
  #
  #   op 0  no-op (the all-zero word) and REPEAT
  #   op 1  branch to a 12-bit DEU address
  #   op 3  mode-register write, register selected by bits 11-10
  #   op 4  character rotation
  #   op 5  major-axis (character advance) step
  #   op 7  minor-axis (carriage return) step
  #   op 8  X beam position / X reference (translate) register
  #   op 9  Y beam position / Y reference (translate) register
  #   op A  vector slope word
  #   op B  vector major-extent word
  #   op C..F  glyph pair (the whole top quadrant, 7 bits each)
  #
  FCWS: {
    # op 0: no-op and REPEAT
    #
    # The all-zero word leads every position run and pads the buffer.  It
    # needs the whole-word mask so it wins over REPT, which shares op 0.
    NOOP: {
      d:'0000000000000000'
      nom:{}
    }
    # REPEAT: draw the FOLLOWING glyph word `count` times.  The count is
    # subtractive (word = 0x0841 - count), so `decodeFCW` computes it; the
    # raw field is kept for debugging.
    REPT: {
      d:'0000nnnnnnnnnnnn'
      nom:{ n:'raw' }
    }

    # op 1: branch
    #
    # The same word doubles as the fill-address header of a DEU memory fill
    # ("load what follows at `target`"), and as the exit from a critical
    # format (0x111E) and from a display's static section (0x19EE).
    #
    # A target below 0x1000 cannot be expressed.  Nothing observed
    # needs one: display lists live in the upper half of memory. 
    BRANCH: {
      d:'0001aaaaaaaaaaaa'
      nom:{ a:'addr12' }
    }

    # op 2: splice in a run of words from elsewhere
    #
    # `0x2000 | count`, ALWAYS followed by a branch word giving the address.
    # Draw `count` words from there, then carry on after the branch word --
    # a call with an explicit length instead of a return instruction.
    #
    SUBLIST: {
      d:'00100001nnnnnnnn'
      nom:{ n:'count' }
    }

    # op 3: the three feature-control words and the value display
    #
    # The GPC-side interpreter keeps a running copy of each ("FEATURE
    # CONTROL WORD #1/#2/#3") and re-sends it whenever one bit changes, so
    # every one of these is a whole-register write, never a delta.
    #
    # FCW2 -- beam mode and refresh control.  The flight assembler macro
    # names its ten bits EOR, INCR, DLY, POLRX, POLRY, then the five beam
    # gating bits AC5..AC1.
    #   eor     end of refresh -- the DEU stops interpreting here
    #   incr    enable the angle-increment register
    #   polarX/polarY   polar coordinate mode on each axis
    #   xyRef   AC5 and AC4 -- the X/Y REFERENCE gate (see below)
    #   mode    AC3..AC1; 5 begins a vector, 6 selects small characters,
    #           7 large
    #
    FCW2: {
      d:'001100eidpqrrmmm'
      nom:{ e:'eor', i:'incr', d:'dly', p:'polarX', q:'polarY',
            r:'xyRef', m:'mode' }
    }
    # FCW3 -- colour (MEDS only; a monochrome DEU has no palette).  The
    # interpreter's own colour path is `... & 0xFFC0 | 0x0080 | palette`:
    # the palette is SIX bits and bit 7 enables it.  `select` off leaves
    # the DEU drawing in its own default colour.
    FCW3: {
      d:'001101_psqcccccc'
      nom:{ p:'spchar', s:'select', q:'ebit', c:'color' }
    }
    # FCW1 -- drawing attributes.  The macro names its eight bits TVB,
    # FBIT, TYPB, OCRB, XYBIT, SPBIT, HBIT, BLBIT -- FBIT
    # is the blink (flash) bit, XYBIT the spacing direction, HBIT the high
    # (double) intensity bit.
    #
    # Unresolved: we have seen 0x0040 noted as the "high intensity bit", 
    # which is not where most references put intensity.  
    # Left as bit 3 for now.
    FCW1: {
      d:'001110dbtoasik__'
      nom:{ d:'dash', b:'blink', t:'typ', o:'ocr', a:'axisY', s:'sp',
            i:'intensity', k:'blank' }
    }
    # Value display.
    VDISP: {
      d:'001111vvvvvvvvvv'
      nom:{ v:'vdisp' }
    }

    # op 4: character angle
    #
    # A 12-bit angle; the display decks only ever write quarter turns, so
    # `decodeFCW` also reports `quarterTurns` = the top two bits.
    ROT: {
      d:'0100aaaaaaaaaaaa'
      nom:{ a:'angle' }
    }

    # op 5 / 7: the spacing steps
    #
    # Register writes: 
    #   MAJINC is how far a glyph advances the beam (+19 small, +24 large), 
    #   MININC how far a carriage return moves it (-27 small, -32 large).  
    #   AXIS=Y swaps their roles.  
    # Both are two's complement -- `decodeFCW` sign-extends them.
    #
    # op 5 is also the ANGLE INCREMENT register: the same word, used as the
    # per-character step when characters are rotated.
    MAJINC: {
      d:'0101_sssssssssss'
      nom:{ s:'step' }
    }
    # Bits 11-10 of op 7 select what the low byte means.  10 is the normal
    # line spacing; 11 is "special type mode", the same step under a
    # different character generator.
    MININC: {
      d:'011110__ssssssss'
      nom:{ s:'step' }
    }
    SPTYPE: {
      d:'011111__ssssssss'
      nom:{ s:'step' }
    }

    # op 6: the land-site table
    #
    # Two opcodes, `01100` and `01101`, emitted as a pair by the LSITE DDT
    # command.  We haven't worked out exactly what this should generate yet.
    LSITE: {
      d:'0110svvvvvvvvvvv'
      nom:{ s:'second', v:'value' }
    }

    # op 8 / 9: beam position
    #
    # `XPOS`/`YPOS` are `DC BL.5'10000'/'10010',FL.11'&X'`, and
    # `XTRN`/`YTRN` -- the X and Y REFERENCE registers -- are the neighbouring
    # opcodes `10001` and `10011`.  So bit 11 is not a flag on a position
    # word; it selects a different word.  `translate` is kept as the field
    # name because that is what the register does: every position word is
    # drawn at reference + coordinate.
    XPOS: {
      d:'1000txxxxxxxxxxx'
      nom:{ t:'translate', x:'x' }
    }
    YPOS: {
      d:'1001tyyyyyyyyyyy'
      nom:{ t:'translate', y:'y' }
    }

    # op A / B: vectors
    #
    # A line is drawn by a pair: VECA carries the slope of the minor axis
    # against the major, VECB the signed extent along the major.  `slope`
    # is 2*round(minor*512/major) -- 9-bit resolution inside a 10-bit
    # field, so its low bit is always zero and a 45 degree line reads 1022.
    VECA: {
      d:'1010mjssssssssss'
      nom:{ m:'yMajor', j:'signDiffer', s:'slope' }
    }
    VECB: {
      d:'1011nlllllllllll'
      nom:{ n:'negative', l:'len' }
    }

    # op C: glyphs
    #
    # Two 7-bit DEU glyphs, drawn g1 then g2.  A lone glyph rides in the
    # low slot with g1 = 0.  `decodeFCW` adds `g1`/`g2` (the raw codes)
    # beside the translated `char1`/`char2`.
    CHAR2: {
      d:'11aaaaaaabbbbbbb'
      nom:{ a:'char1', b:'char2' }
    }
  }

  DEUCharset: {
    # ref USA-003090/p.104
    # The mapping here is for convenience and doesn't directly define the
    # shape of each glyph: actual shapes are loaded from the font.svg by
    # the character generator.
    0x00: '\0'
    0x01: ']'
    0x02: '['
    0x03: 'SELF TEST'
    0x04: '˙' # upper centered dot (U+02D9 -> SVG group c696)
    0x05: '¨' # upper double dot (U+00A8 -> SVG group c135)
    0x06: '∇'
    0x07: '·' # centered dot (U+00B7 -> SVG group c150)
    0x08: '\b'
    0x09: '÷'
    0x0a: 'ߠ' # TACAN WYE
    0x0b: '▷' # Right facing DEL
    0x0c: '◁' # Left facing DEL
    0x0d: '\r'
    0x0e: 'ߡ' # Shuttle Plan
    0x0f: 'ߟ' # Shuttle Profile
    0x10: 'α'
    0x11: 'β'
    0x12: 'ρ'
    0x13: 'ω'
    0x14: 'ε'
    0x15: 'Ω'
    0x16: '_'
    0x17: '⎯'
    0x18: 'ˈ' # upper vertical half line (U+02C8 -> SVG group c679)
    0x19: '◊'
    0x1a: '¥' # Empty Square
    0x1b: '°'
    0x1c: '↑'
    0x1d: '↓'
    0x1e: '→'
    0x1f: '←'
    0x20: ' ' # space
    0x21: '!'
    0x22: '~'
    0x23: '#'
    0x24: '√'
    0x25: '%'
    0x26: '&'
    0x27: "'" # apostrophe (U+0027 -> SVG group c6)
    0x28: '('
    0x29: ')'
    0x2a: '*'
    0x2b: '+'
    0x2c: ','
    0x2d: '-'
    0x2e: '.'
    0x2f: '/'
    0x30: '0'
    0x31: '1'
    0x32: '2'
    0x33: '3'
    0x34: '4'
    0x35: '5'
    0x36: '6'
    0x37: '7'
    0x38: '8'
    0x39: '9'
    0x3a: ':'
    0x3b: ';'
    0x3c: '<'
    0x3d: '='
    0x3e: '>'
    0x3f: '?'
    0x40: 'γ'
    0x41: 'A'
    0x42: 'B'
    0x43: 'C'
    0x44: 'D'
    0x45: 'E'
    0x46: 'F'
    0x47: 'G'
    0x48: 'H'
    0x49: 'I'
    0x4a: 'J'
    0x4b: 'K'
    0x4c: 'L'
    0x4d: 'M'
    0x4e: 'N'
    0x4f: 'O'
    0x50: 'P'
    0x51: 'Q'
    0x52: 'R'
    0x53: 'S'
    0x54: 'T'
    0x55: 'U'
    0x56: 'V'
    0x57: 'W'
    0x58: 'X'
    0x59: 'Y'
    0x5a: 'Z'
    0x5b: 'Σ'
    0x5c: 'θ'
    0x5d: '‾' # OVERSCORE (U+203E -> SVG group c8221)
    0x5e: 'π'
    0x5f: 'Ф'
    0x60: 'Ψ'
    0x61: 'a'
    0x62: 'b'
    0x63: 'c'
    0x64: 'd'
    0x65: 'e'
    0x66: 'f'
    0x67: 'g'
    0x68: 'h'
    0x69: 'i'
    0x6a: 'j'
    0x6b: 'k'
    0x6c: 'l'
    0x6d: 'm'
    0x6e: 'n'
    0x6f: 'o'
    0x70: 'p'
    0x71: 'q'
    0x72: 'r'
    0x73: 's'
    0x74: 't'
    0x75: 'u'
    0x76: 'v'
    0x77: 'w'
    0x78: 'x'
    0x79: 'y'
    0x7a: 'z'
    0x7b: 'σ'
    0x7c: '|'
    0x7d: '' # UNDERSCORE
    0x7e: 'λ'
    0x7f: '∆'
  }