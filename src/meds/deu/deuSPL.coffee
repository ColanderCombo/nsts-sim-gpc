#
# The scratch pad line.
#
# The SPL holds the entry being typed, echoes it locally, and transmits 
# when it is complete.
#
#   * the line is 51 characters and the FIRST and LAST position are never
#     filled -- position 0 is always a space;
#   * a single delimiter key (+ or -) generates FIVE things at once: a
#     blank, an open parenthesis, the item number, a close parenthesis and
#     the sign -- ` (14)+`.  The item number occupies two spaces and runs
#     from 00 to 99, so it is the last two digits typed;
#   * at most 39 characters may be entered (29 when POLL FAIL is on the
#     line).  Exceeding it raises a FLASHING `ERR`, whose own characters
#     count towards the total;
#   * the one exception is a terminator arriving just after the 39th
#     character, which is allowed:
#         ` ITEM (11)+1234 (12)+1234 (13)+12345678 EXEC `      = 45
#   * ERR is an annunciation at the END of the line, so an entry can pass 
#     39 by more than one before it shows -- a delimiter adds six characters
#     in one keystroke:
#         ` ITEM (11)+1234 (12)+1234 (13)+12345678 (14)+ ERR ` = 50
#     which is the largest entry that can ever appear on the line, and is
#     where `_fits` comes from: a keystroke that would push the line (ERR
#     included) past position 49 is ignored;
#   * ACK, MSG RESET and CLEAR do not echo to the SPL.
#
# And the syntax check:
#
#   * the display checks every keystroke, and puts a flashing ERR to the
#     right of the illegal keystroke.
#   * CLEAR takes back one keystroke, so pressing it repeatedly backs the
#     entry out a keystroke at a time.  The line is the whole of the entry:
#     there is no history behind it, CLEAR on an empty line does nothing,
#     and a keystroke that wipes the line leaves nothing to back up into.
#   * the ERR goes away either by CLEAR, which takes back the ERR and that
#     one keystroke and leaves the rest of the entry standing, or by
#     reinitiating the sequence with a key that can begin one.  While it is
#     up, nothing else is accepted.
#   * the grammar is below, and `_transition` is it as an acceptor.
#
import * as DEU from 'meds/deu/deuProto'
import {FCW} from 'meds/deu/deuFCW'

export SPL_ROW = 26                    # the last character row, which POLL FAIL shares
export SPL_LENGTH = 51                 # positions 0..50
export SPL_LAST = SPL_LENGTH - 1       # ...and the last is never filled
export SPL_MAX = 39                    # characters, the leading blank included
export SPL_MAX_POLL_FAIL = 29          # ...when POLL FAIL shares the line
export ERR_TEXT = ' ERR '

# What each key draws.  ACK, MSG RESET and CLEAR have no entry
export KEY_LABEL = {}
KEY_LABEL[v] = k for k, v of DEU.KEY
KEY_LABEL[DEU.KEY.SYS_SUMM]   = 'SYS SUMM'
KEY_LABEL[DEU.KEY.FAULT_SUMM] = 'FAULT SUMM'
KEY_LABEL[DEU.KEY.IO_RESET]   = 'I/O RESET'
KEY_LABEL[DEU.KEY.GPC_CRT]    = 'GPC/CRT'
KEY_LABEL[DEU.KEY.MINUS]      = '-'
KEY_LABEL[DEU.KEY.PLUS]       = '+'
KEY_LABEL[DEU.KEY.DECIMAL]    = '.'
delete KEY_LABEL[DEU.KEY.ACK]
delete KEY_LABEL[DEU.KEY.MSG_RESET]
delete KEY_LABEL[DEU.KEY.CLEAR]

# ---------------------------------------------------------------------------
# The grammar:
#
#   b     = int 0-9
#   a     = alpha char A-F
#   data  = int 0-9, char A-F, and the decimal point
#
#   single keystrokes: MSG RESET, ACK, RESUME, SYS SUMM, FAULT SUMM, EXEC, CLEAR
#   I/O RESET  EXEC
#   OPS      b b b  PRO
#   SPEC     [[b]b]b  PRO
#   GPC/CRT  b b  EXEC
#   ITEM     [b]b  [(+|-) [data] [(+|-)] [data] ...]  EXEC
#   ITEM     a  [(+|-) data]  EXEC
#
# `data` is a RUN, not a single character (`ITEM D+XXXX EXEC` is one of the
# display's operational-test entries).  It takes the DECIMAL POINT as
# well as 0-9 and A-F; `b` and `a` do not, so a decimal can never appear in
# an item number, an OPS/SPEC number or a GPC/CRT id.
#
# Two consequences that read the wrong way round: EXEC on its own is legal
# (it is in the single-keystroke list), and two delimiters running are legal
# in the numeric ITEM form -- the grammar's `[data]` is optional between them.
# ---------------------------------------------------------------------------

# Keys that begin an entry.  An initiator is legal in any position: it starts
# a new sequence, which is also the "reinitiate" way out of a syntax error.
export INITIATORS =
  "#{DEU.KEY.ITEM}":     'item'
  "#{DEU.KEY.OPS}":      'ops1'
  "#{DEU.KEY.SPEC}":     'spec1'
  "#{DEU.KEY.GPC_CRT}":  'gpc1'
  "#{DEU.KEY.IO_RESET}": 'ioreset'
export DELIMITERS = [DEU.KEY.PLUS, DEU.KEY.MINUS]
# The keys that are an entry on their own (less the three that never reach
# the line, and less EXEC, which is also a terminator and is handled there).
export COMMAND_KEYS = [DEU.KEY.SYS_SUMM, DEU.KEY.FAULT_SUMM, DEU.KEY.RESUME]
export TERMINATORS = [DEU.KEY.EXEC, DEU.KEY.PRO]
isDigit = (code) -> code >= DEU.KEY['0'] and code <= DEU.KEY['9']
isAlpha = (code) -> code >= DEU.KEY.A and code <= DEU.KEY.F
isData  = (code) -> isDigit(code) or isAlpha(code) or code == DEU.KEY.DECIMAL

# Where EXEC and PRO are allowed to close an entry.  `start` is in the EXEC
# list because EXEC on its own is an entry.
EXEC_STATES = ['start', 'ioreset', 'gpc3', 'itemNum1', 'itemNum2', 'itemData',
               'itemAlpha', 'alphaData']
PRO_STATES  = ['ops4', 'spec2', 'spec3', 'spec4']

DIGITS = /[0-9A-F]$/

export class SPL
  constructor: (o = {}) ->
    @pollFail = o.pollFail ? false
    @clear()

  clear: () ->
    @line = ' '            # position 0 is always a space
    @keys = []             # the codes that will go to the GPC
    @err = false           # false | 'length' | 'syntax'
    @complete = false
    @lastKind = 'none'     # what the previous keystroke drew
    @state = 'start'       # where the entry has got to in the grammar
    @initSpan = null       # [start, end) of the initiator's label in @line
    return

  limit: () -> if @pollFail then SPL_MAX_POLL_FAIL else SPL_MAX

  # The line as drawn: ERR rides at the end, and it FLASHES, so the caller
  # gets it separately rather than glued on.
  text: () -> if @err then @line + ERR_TEXT else @line

  # Would this many more characters still fit, ERR included?
  _fits: (n) ->
    (@line.length + n + (if @err then ERR_TEXT.length else 0)) <= SPL_LAST

  _add: (s, code, exempt = false, kind = 'value') ->
    return false if not @_fits(s.length)
    # An initiator's label is the part that flashes until the command is
    # complete, so remember where on the line it landed.
    @initSpan = [@line.length, @line.length + s.length] if kind == 'name'
    @line += s
    @lastKind = kind
    @keys.push code if code?
    # `exempt`: a terminator arriving just past the limit is allowed through,
    # so ` ... 12345678 EXEC ` is a legal 45-character entry.
    @err = 'length' if not exempt and not @err and @line.length > @limit()
    true

  # the legal-syntax check
  _transition: (code) ->
    return {state: INITIATORS[code], restart: true} if INITIATORS[code]?
    return {state: 'start', done: true, restart: true} if code in COMMAND_KEYS
    return (if @state in EXEC_STATES then {state: 'start', done: true} else null) \
      if code == DEU.KEY.EXEC
    return (if @state in PRO_STATES then {state: 'start', done: true} else null) \
      if code == DEU.KEY.PRO
    d = isDigit(code) ; a = isAlpha(code) ; delim = code in DELIMITERS
    dat = isData(code)          # data takes the decimal point; b and a do not
    switch @state
      when 'ops1'  then return {state: 'ops2'}  if d
      when 'ops2'  then return {state: 'ops3'}  if d
      when 'ops3'  then return {state: 'ops4'}  if d
      when 'spec1' then return {state: 'spec2'} if d
      when 'spec2' then return {state: 'spec3'} if d
      when 'spec3' then return {state: 'spec4'} if d
      when 'gpc1'  then return {state: 'gpc2'}  if d
      when 'gpc2'  then return {state: 'gpc3'}  if d
      when 'item'
        return {state: 'itemNum1'}  if d
        return {state: 'itemAlpha'} if a
      when 'itemNum1'
        return {state: 'itemNum2'} if d
        return {state: 'itemData'} if delim
      when 'itemNum2'
        return {state: 'itemData'} if delim
      when 'itemData'
        # [(+|-) [data] [(+|-)] [data] ...] -- data optional, delimiters may
        # repeat, and this is where a multi-item entry lives: the SPL splits
        # the last two characters off as the next item number, but as far as
        # the grammar goes it is all one data run.
        return {state: 'itemData'} if dat or delim
      when 'itemAlpha'
        return {state: 'alphaDelim'} if delim
      when 'alphaDelim'
        # `ITEM a [(+|-) data]`: with the delimiter the data is REQUIRED, so
        # EXEC is not a way out of here.
        return {state: 'alphaData'} if dat
      when 'alphaData'
        return {state: 'alphaData'} if dat
    null

  press: (code) ->
    code = code & 0x1f
    if code == DEU.KEY.CLEAR
      # One keystroke back.  A keystroke is not a character -- a delimiter
      # draws ` (14)+` in one press and rewrites the digits already there,
      # a named key draws its whole label -- so the line is redrawn from
      # the keystrokes that are left rather than trimmed.
      keys = @keys[0...-1]
      @clear()
      @press(k) for k in keys
      return 'cleared'
    return 'silent' if not KEY_LABEL[code]?          # ACK / MSG RESET
    # A completed entry stays on the line to be read back: the next keystroke
    # wipes it
    @clear() if @complete
    if @err == 'syntax'
      if INITIATORS[code]? or code in COMMAND_KEYS
        @clear()
      else
        return 'blocked'
    step = @_transition(code)
    label = KEY_LABEL[code]
    # An illegal keystroke is still drawn -- CLEAR removing "the ERR and the
    # illegal keystroke" says so -- but as itself: a delimiter with no item
    # number in front of it echoes as a bare sign, not as ` (  )+`.
    if not step?
      sep = if @line[@line.length - 1] == ' ' then ''
      else if label.length > 1 or @lastKind == 'name' then ' '
      else ''
      if @_add(sep + label, code, true, 'value')
        @err = 'syntax'
      return 'illegal'
    # An initiator, or a key that is an entry on its own, begins a new
    # sequence wherever it is pressed.
    if step.restart and @line.length > 1
      @clear()
      wiped = true
    ok =
      if code in DELIMITERS
        @_delimiter(label, code)
      else if code in TERMINATORS or code in COMMAND_KEYS
        # A terminator is exempt from the length limit: ` ... 12345678 EXEC `
        # is a legal 45-character entry.
        sep = if @line[@line.length - 1] == ' ' then '' else ' '
        @_add(sep + label + ' ', code, true, 'term')
      else if INITIATORS[code]?
        @_add(label, code, false, 'name')
      else
        sep = if @lastKind == 'name' then ' ' else ''
        @_add(sep + label, code, false, 'value')
    return 'full' if not ok
    @state = step.state
    if step.done
      @complete = true
      return 'complete'
    'echoed'

  _delimiter: (sign, code) ->
    head = @line
    num = ''
    while num.length < 2 and DIGITS.test(head)
      num = head[head.length - 1] + num
      head = head[0...-1]
    head = head[0...-1] if num.length > 0 and head[head.length - 1] == ' '
    sep = if head[head.length - 1] == ' ' then '' else ' '
    group = sep + '(' + num.padStart(2, ' ') + ')' + sign
    return false if (head.length + group.length +
                     (if @err then ERR_TEXT.length else 0)) > SPL_LAST
    @line = head
    @_add(group, code, false, 'delim')

# ---------------------------------------------------------------------------
# The line as format control words, and as glyphs
#
# `splFCWs` draws it: a position run, then glyph pairs, with blink turned on
# around the initiator's label and around ERR.  `splGlyphs` is the same line
# one halfword a character, the DEU glyph in bits 0-6 and blink in bit 7,
# which is the form the control program composes from.  Walking `splGlyphs`
# and emitting an attribute word at every change of state produces
# `splFCWs`.
# ---------------------------------------------------------------------------
export GLYPH_MASK = 0x007f
export GLYPH_BLINK = 0x0080

_fcw = null
fcwEnc = () -> _fcw ?= new FCW()

# The three runs the line is drawn in: [text, blinking].  Everything else
# here is derived from this, so the two views cannot drift apart.
export splRuns = (spl) ->
  runs = []
  span = spl.initSpan
  if span? and not spl.complete
    runs.push [spl.line[0...span[0]], false]
    runs.push [spl.line[span[0]...span[1]], true]
    runs.push [spl.line[span[1]..], false]
  else
    runs.push [spl.line, false]
  runs.push [ERR_TEXT, true] if spl.err
  runs

export splFCWs = (spl, fcw = fcwEnc()) ->
  out = fcw.positionRun(0, SPL_ROW)
  blinking = false
  for [text, blink] in splRuns(spl)
    if blink != blinking
      out.push fcw.attrMode({blink: blink})
      blinking = blink
    out = out.concat fcw.chars(text)
  out.push fcw.attrMode({}) if blinking
  out

export splGlyphs = (spl, fcw = fcwEnc()) ->
  out = []
  for [text, blink] in splRuns(spl)
    for ch in text
      out.push (fcw.toGlyph(ch) & GLYPH_MASK) |
               (if blink then GLYPH_BLINK else 0)
  out

# ---------------------------------------------------------------------------
# The grammar in table form
#
# An alternate encoding to assist in building a fakeDCP control program
# in fakeSP0 assembly.  Internal, for dev use.
#
#   row     one per state, GRAMMAR_COLS halfwords
#   column  0 digit  1 alpha  2 decimal  3 delimiter  4 EXEC  5 PRO
#   entry   G_ILLEGAL, or the next state with G_DONE set if it terminates
# ---------------------------------------------------------------------------
export STATES = ['start', 'item', 'itemNum1', 'itemNum2', 'itemData',
                 'itemAlpha', 'alphaDelim', 'alphaData',
                 'ops1', 'ops2', 'ops3', 'ops4',
                 'spec1', 'spec2', 'spec3', 'spec4',
                 'gpc1', 'gpc2', 'gpc3', 'ioreset']
export GRAMMAR_COLS = 8            # a power of two, so the index is a shift
export G_ILLEGAL = 0xffff
export G_DONE    = 0x0100
export G_STATE   = 0x00ff

GRAMMAR_KEYS = [DEU.KEY['0'], DEU.KEY.A, DEU.KEY.DECIMAL, DEU.KEY.PLUS,
                DEU.KEY.EXEC, DEU.KEY.PRO]

export grammarTable = () ->
  probe = new SPL()
  out = []
  for st in STATES
    row = new Array(GRAMMAR_COLS).fill(G_ILLEGAL)
    for code, i in GRAMMAR_KEYS
      probe.state = st
      step = probe._transition(code)
      continue if not step?
      row[i] = (STATES.indexOf(step.state) & G_STATE) |
               (if step.done then G_DONE else 0)
    out = out.concat row
  out

# What the program needs to know about a key code, one halfword each.  The
# low three bits are the class the grammar table is indexed by; the flags
# above them are the cases decided before the table is reached; and the high
# byte is the state an initiator starts in.
export KA_CLASS   = 0x0007
export KA_DIGIT   = 0
export KA_ALPHA   = 1
export KA_DECIMAL = 2
export KA_DELIM   = 3
export KA_NONE    = 4
export KA_INIT    = 0x0008    # begins a sequence, wherever it is pressed
export KA_COMMAND = 0x0010    # ... and is a whole entry on its own
export KA_EXEC    = 0x0020
export KA_PRO     = 0x0040
export KA_NOLABEL = 0x0080    # ACK, MSG RESET, CLEAR: never reach the line
export KA_STATE_SHIFT = 8
export KEY_CODES = 32

export keyAttrTable = () ->
  for code in [0...KEY_CODES]
    cls =
      if isDigit(code) then KA_DIGIT
      else if isAlpha(code) then KA_ALPHA
      else if code == DEU.KEY.DECIMAL then KA_DECIMAL
      else if code in DELIMITERS then KA_DELIM
      else KA_NONE
    a = cls
    a |= KA_COMMAND if code in COMMAND_KEYS
    a |= KA_EXEC    if code == DEU.KEY.EXEC
    a |= KA_PRO     if code == DEU.KEY.PRO
    a |= KA_NOLABEL if not KEY_LABEL[code]?
    if INITIATORS[code]?
      a |= KA_INIT
      a |= (STATES.indexOf(INITIATORS[code]) << KA_STATE_SHIFT)
    a

# What each key draws, as glyphs: a table of pointers into a pool of
# length-counted strings.  `offset` is relative to the start of the pool;
# a key with no label is never asked for one (KA_NOLABEL says so).
export labelTables = (fcw = fcwEnc()) ->
  offset = []
  text = []
  for code in [0...KEY_CODES]
    lab = KEY_LABEL[code]
    offset.push 0
    continue if not lab?
    offset[code] = text.length
    text.push lab.length
    text.push (fcw.toGlyph(c) & GLYPH_MASK) for c in lab
  {offset: offset, text: text}

# ERR, as glyphs, for the program to append behind an entry it would not take.
export errGlyphs = (fcw = fcwEnc()) ->
  (fcw.toGlyph(c) & GLYPH_MASK) for c in ERR_TEXT
