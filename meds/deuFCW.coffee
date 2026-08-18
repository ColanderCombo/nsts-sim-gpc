import {PackedBits} from '../gpc/util'

export class FCW extends PackedBits
  constructor: () ->
    super()
    @makeFCWTable()
    @makeCharToDEU()

  encodeFCW: (desc) ->
    #console.log "ENCODE", desc
    if desc.nm == 'CHAR1'
      desc.char = @chrToDEU[desc.char]
    else if desc.nm == 'CHAR2'
      desc.char1 = @chrToDEU[desc.char1]
      desc.char2 = @chrToDEU[desc.char2]
    return @encode(desc)

  decodeFCW: (hw) ->
    desc = @decode(hw)
    if not desc?
      # Word doesn't match any implemented FCW opcode -- either a real,
      # not-yet-implemented multi-halfword FCW's own operand word (see
      # this file's own "Format control words" comment block: several
      # real historical FCW types are documented but not yet built into
      # @FCWS, e.g. multi-hw POSITION), or a FETCH's own referenced/
      # fetched payload data, not itself an FCW opcode at all. Skip
      # rather than crash the whole format -- one unrecognized word
      # shouldn't take down every other word already decoded correctly.
      console.log "decodeFCW: NO MATCH for hw=0x#{hw.toString(16)} -- skipping"
      return undefined
    dd = desc.v
    if desc.nm == 'CHAR1'
      dd.char = @DEUCharset[dd.char]
    else if desc.nm == 'CHAR2'
      dd.char1 = @DEUCharset[dd.char1]
      dd.char2 = @DEUCharset[dd.char2]
    return desc

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

    # when matching a hw to an instruction, we
    # search from more to less specific, so order
    # masks from largest to smallest:
    @orderedMasks = @orderedMasks.sort().reverse()

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

  FCWS: {
    POSX: {
      d:'00001xxxxxxxxx__'
      nom:{ x:'x' }
    }
    POSY: {
      d:'00000yyyyyyyyy__'
      nom:{ y:'y' }
    }
    POSTX: {
      d:'1000xxxxxxyyyyyy'
      nom:{ x:'x', y:'y' }
    }
    THETA: {
      d:'0001_rrrrrrrrr__'
      nom:{ r:'r' }
    }
    LENGT: {
      d:'0010cddddddddd__'
      nom:{ c:'yLonger', d:'length' }
    }
    CHAR1: {
      d:'0011cccccccbi___'
      nom: { c:'char', b:'blink', i:'intensity' }
    }
    CHAR2: {
      d:'11cccccccddddddd'
      nom: { c:'char1', d:'char2' }
      e:(t,v)->
    }
    FETCH: {
      d:'0100aaaaaacccccc'
      nom: { a:'addr', c:'count' }
    }
    FEAT: {
      d:'0101dboiiiiiiiii'
      nom: {d:'lineDash',b:'blink',o:'overbright',i:'intensity' }
    }
    CIRC: {
      d:'0110rrrrrrrrr___'
      nom: {r:'radius'}
    }
    # emulator char transform: sets rotation (9-bit, 0..511 = 0..2pi) and a
    # 3-bit scale index for subsequent CHAR1/CHAR2 words
    CHARXF: {
      d:'0111rrrrrrrrrsss'
      nom: {r:'rot', s:'scale'}
    }
    # SDATA: {
    #   d:'111101s____td___'
    #   nom: { s:'charSize', t:'isDynamic', d:'isStatic' }
    # }
    # EDATA: {
    #   d:'111110s____td___'
    #   nom: { s:'charSize', t:'isDynamic', d:'isStatic' }
    # }


    #
    # Format control words
    #
    # POSITION, 1 coordinate (X=)    (3-hw)
    # POSITION, 2 coordinate (X=,Y=) (4-hw)
    #
    # CHARACTER PAIR (1-hw)
    #
    # SPECIAL CHARACTER (3-hw)
    #
    # CIRCLE (static radius, without positioning)   3-hw
    #
    # LINE (with positioning)   (5-hw)
    #
    # VARIABLE PARAMETER (VPARM)  (3-hw)

    # REMOTE TEXT COMMAND (RTC) (3-hw)
    #
    #
    # TEST (3-hw)
    #
    # DASH ON (3-hw)
    #
    # DASH OFF (3-hw)
    # 
    # BRANCH   (2-hw)
    #
    # ITEM NUMBER (with positioning, without limits, with display of item number ) (9-hw)


    # END OF REFRESH
    # BACKSPACE
    # FEATURE CONTROL 1 : 1100
    # FEATURE CONTROL 2 : 1101
    # FEATURE CONTROL 3 : 1110
    # 1101____________
    #       normal intensity
    #       high intensity
    #
    # double bright char:
    #   HIGH INTENSITT / CHAR / BACKSPACE / CHAR / NORM INTENSITY
  }

  DEUCharset: {
    # ref USA-003090/p.104
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