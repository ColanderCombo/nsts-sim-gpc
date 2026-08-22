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
#   * CLEAR takes back one keystroke, not the line: pressing it repeatedly
#     backs the entry out a keystroke at a time.
#   * the ERR goes away either by CLEAR, which takes back the ERR and that
#     one keystroke and leaves the rest of the entry standing, or by
#     reinitiating the sequence with a key that can begin one.  While it is
#     up, nothing else is accepted.
#   * the grammar is below, and `_transition` is it as an acceptor.
#
import * as DEU from 'meds/deuProto'

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
# display's own operational-test entries).  It takes the DECIMAL POINT as
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
export VALUE_KEYS = [DEU.KEY['0'], DEU.KEY['1'], DEU.KEY['2'], DEU.KEY['3'],
                     DEU.KEY['4'], DEU.KEY['5'], DEU.KEY['6'], DEU.KEY['7'],
                     DEU.KEY['8'], DEU.KEY['9'], DEU.KEY.A, DEU.KEY.B,
                     DEU.KEY.C, DEU.KEY.D, DEU.KEY.E, DEU.KEY.F]

isDigit = (code) -> code >= DEU.KEY['0'] and code <= DEU.KEY['9']
isAlpha = (code) -> code >= DEU.KEY.A and code <= DEU.KEY.F
isData  = (code) -> isDigit(code) or isAlpha(code) or code == DEU.KEY.DECIMAL

# Where EXEC and PRO are allowed to close an entry.  `start` is in the EXEC
# list because EXEC on its own IS an entry.
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
    @history = []          # one snapshot per keystroke, for CLEAR

  # CLEAR takes back ONE keystroke, so the line has to be remembered as it
  # was before each one: a keystroke is not a character.  A delimiter puts
  # ` (14)+` on the line in a single press, a named key puts its whole label
  # there, and an illegal keystroke arrives with an ERR behind it -- each
  # comes off again the same way.
  _snapshot: () ->
    line: @line
    keys: @keys[..]
    err: @err
    complete: @complete
    lastKind: @lastKind
    state: @state
    initSpan: @initSpan

  _restore: (s) ->
    {@line, @err, @complete, @lastKind, @state, @initSpan} = s
    @keys = s.keys[..]
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
    # An initiator's own label is the part that flashes until the command is
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
      # One keystroke back, not the whole line.  With nothing left to take
      # back there is nothing on the line either.
      if @history.length > 0 then @_restore(@history.pop()) else @clear()
      return 'cleared'
    return 'silent' if not KEY_LABEL[code]?          # ACK / MSG RESET
    # Taken before anything below can clear the line, and pushed only once
    # the keystroke has actually landed on it.
    snap = @_snapshot()
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
        @history.push snap
      return 'illegal'
    # An initiator, or a key that is an entry on its own, begins a new
    # sequence wherever it is pressed.
    @clear() if step.restart and @line.length > 1
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
    @history.push snap
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
