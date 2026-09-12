# The wiring language
#
# A file holds one or more `wiring` units.  Each declares enumerated
# types, ports bound to addresses on the simulation busses, internal
# signals, and concurrent assignments that say what drives what.  The
# grammar is VHDL's, with entity and architecture dropped and the binding
# written where a port is declared.
#
#   wiring adi_left is
#     type attitude is (INRTL, LVLH, REF);
#     port (
#       att       : in  attitude bind panel "F6/S3";
#       ddu_pwr   : in  logic    bind mdm   "FF2/6/0.0";
#       att_inrtl : out logic    bind mdm   "FF1/4/1.0"
#     );
#     signal enabled : logic;
#   begin
#     enabled   <= ddu_pwr;
#     att_inrtl <= enabled and att = INRTL;
#   end wiring;
#
# Identifiers, keywords and enumeration literals fold case.  A comment
# runs from `--` to the end of the line.
#
# TYPES
#
#   logic      '0' or '1'; std_logic and bit are the same type
#   word       sixteen bits, 0 to 65535
#   integer    a whole number
#   real       a number with a fraction: volts, degrees, whatever unit
#              the signal carries
#   time       a literal only: 300 ms, 1.5 s, 40 us
#   a type declared with `type <name> is (A, B, C);`; several types may
#   carry the same literal, and where it is written settles which one is
#   meant -- what it is compared with, or what it is assigned to
#
# OPERATORS, loosest first, as in VHDL
#
#   and or nand nor xor xnor    on logic; mixing two of them in one
#                               expression takes parentheses
#   = /= < <= > >=              yield logic
#   + - &                       & concatenates two logic values into a word
#   * / mod rem
#   not abs, unary -
#
# A conditional expression is VHDL-2008's:
#
#   rate_hi <= '1' when rate = HIGH else '0';
#
# A type name applied to a value converts it: word(v), real(n), logic(b).
#
# BUILT-IN FUNCTIONS
#
#   latch(set, reset)    holds 1 from a set until a reset; reset wins
#   pulse(x, 300 ms)     1 for the time given from each rising edge of x,
#                        restarted by another edge; `rising` is the same
#                        function under the name the edge suggests
#   falling(x, 20 ms)    the same on a falling edge
#   delay(x, 12 ms)      x as it stood that long ago
#
# Arguments associate by position or by name, `latch(set => a, reset => b)`.

KEYWORDS = ['wiring', 'is', 'begin', 'end', 'type', 'port', 'signal', 'constant',
            'in', 'out', 'inout', 'bind', 'when', 'else', 'not', 'abs',
            'and', 'or', 'nand', 'nor', 'xor', 'xnor', 'mod', 'rem', 'others']

LOGICAL = ['and', 'or', 'nand', 'nor', 'xor', 'xnor']
RELATIONAL = ['=', '/=', '<', '<=', '>', '>=']
ADDING = ['+', '-', '&']
MULTIPLYING = ['*', '/', 'mod', 'rem']

SYMBOLS = ['<=', '=>', ':=', '/=', '>=', '<', '>', '=', '(', ')', ';', ':', ',',
           '+', '-', '*', '/', '&', '|', '.']

TIME_UNITS = {fs: 1e-12, ps: 1e-9, ns: 1e-6, us: 1e-3, ms: 1, sec: 1000, s: 1000,
              min: 60000, hr: 3600000}

BUILTIN_TYPES = {
  logic: 'logic', std_logic: 'logic', bit: 'logic'
  word: 'word', std_logic_vector: 'word'
  integer: 'integer', natural: 'integer', positive: 'integer'
  real: 'real'
  time: 'time'
}

class WiringError extends Error
  constructor: (file, line, message) ->
    super "#{file}:#{line}: #{message}"
    @file = file
    @line = line
    @name = 'WiringError'


lex = (text, file) ->
  out = []
  line = 1
  i = 0
  n = text.length
  fail = (msg) -> throw new WiringError(file, line, msg)
  while i < n
    c = text[i]
    if c == '\n'
      line++
      i++
      continue
    if c == ' ' or c == '\t' or c == '\r'
      i++
      continue
    if c == '-' and text[i + 1] == '-'
      i++ while i < n and text[i] != '\n'
      continue
    if /[A-Za-z_]/.test(c)
      j = i
      j++ while j < n and /[A-Za-z0-9_]/.test(text[j])
      word = text[i...j]
      low = word.toLowerCase()
      i = j
      # A number already read takes a unit that follows it.
      last = out[out.length - 1]
      if TIME_UNITS[low]? and last? and (last.t == 'int' or last.t == 'real') and not last.united
        last.t = 'time'
        last.v = last.v * TIME_UNITS[low]
        last.united = true
        continue
      out.push {t: (if low in KEYWORDS then 'kw' else 'id'), v: low, raw: word, line}
      continue
    if /[0-9]/.test(c)
      j = i
      j++ while j < n and /[0-9_]/.test(text[j])
      if text[j] == '#'                       # 16#ff#, VHDL's based literal
        base = parseInt(text[i...j].replace(/_/g, ''), 10)
        k = j + 1
        k++ while k < n and text[k] != '#'
        fail "unterminated based literal" if k >= n
        v = parseInt(text[(j + 1)...k].replace(/_/g, ''), base)
        fail "'#{text[i...(k + 1)]}' is not a number in base #{base}" if isNaN(v)
        out.push {t: 'int', v, line}
        i = k + 1
        continue
      isReal = false
      if text[j] == '.' and /[0-9]/.test(text[j + 1] ? '')
        isReal = true
        j++
        j++ while j < n and /[0-9_]/.test(text[j])
      if (text[j] == 'e' or text[j] == 'E') and /[-+0-9]/.test(text[j + 1] ? '')
        isReal = true
        j += 2
        j++ while j < n and /[0-9]/.test(text[j])
      v = Number(text[i...j].replace(/_/g, ''))
      fail "'#{text[i...j]}' is not a number" if isNaN(v)
      out.push {t: (if isReal then 'real' else 'int'), v, line}
      i = j
      continue
    if c == "'"
      m = text[i..].match(/^'([01])'/)
      fail "a character literal is '0' or '1'" unless m?
      out.push {t: 'logic', v: Number(m[1]), line}
      i += m[0].length
      continue
    if c == '"'
      j = text.indexOf('"', i + 1)
      fail "unterminated string" if j < 0
      out.push {t: 'str', v: text[(i + 1)...j], line}
      i = j + 1
      continue
    sym = null
    for s in SYMBOLS when text.startsWith(s, i)
      sym = s
      break
    fail "'#{c}' has no meaning here" unless sym?
    out.push {t: sym, v: sym, line}
    i += sym.length
  out.push {t: 'eof', v: '', line}
  out


class Parser
  constructor: (@tokens, @file) ->
    @at = 0

  peek: (k = 0) -> @tokens[Math.min(@at + k, @tokens.length - 1)]
  next: () -> @tokens[@at++]
  line: () -> @peek().line

  fail: (msg, tok = null) ->
    tok ?= @peek()
    throw new WiringError(@file, tok.line, msg)

  sees: (what, k = 0) ->
    t = @peek(k)
    (t.t == what) or (t.t == 'kw' and t.v == what)

  take: (what) ->
    return @next() if @sees(what)
    null

  want: (what, why = null) ->
    return @next() if @sees(what)
    @fail "expected #{why ? "'#{what}'"}, found '#{@peek().raw ? @peek().v}'"

  wantId: (why) ->
    t = @peek()
    @fail "expected #{why}, found '#{t.raw ? t.v}'" unless t.t == 'id'
    @next()
    t


  parseFile: () ->
    units = []
    units.push @parseUnit() until @sees('eof')
    units

  parseUnit: () ->
    @want 'wiring', "'wiring'"
    name = @wantId('the wiring unit name').v
    @want 'is'
    unit = {
      name, file: @file, line: @line()
      types: {}, ports: [], signals: [], constants: [], stmts: []
      literals: {}                            # enum literal -> the types carrying it
    }
    until @sees('begin')
      @fail "a declaration or 'begin'" if @sees('eof')
      @parseDecl unit
    @want 'begin'
    until @sees('end')
      @fail "an assignment or 'end'" if @sees('eof')
      @parseStmt unit
    @want 'end'
    @take 'wiring'
    if @peek().t == 'id'
      tail = @next()
      @fail "'end #{tail.raw}' closes '#{name}'", tail unless tail.v == name
    @want ';'
    unit

  parseDecl: (unit) ->
    return @parseType unit if @sees('type')
    return @parsePorts unit if @sees('port')
    return @parseSignal unit if @sees('signal')
    return @parseConstant unit if @sees('constant')
    @fail "a type, port, signal or constant declaration"

  parseType: (unit) ->
    @want 'type'
    tok = @wantId('a type name')
    name = tok.v
    @fail "'#{tok.raw}' is a built-in type", tok if BUILTIN_TYPES[name]?
    @fail "type '#{tok.raw}' is declared twice", tok if unit.types[name]?
    @want 'is'
    @want '('
    literals = []
    loop
      lit = @wantId('an enumeration literal')
      @fail "#{name} carries '#{lit.raw}' twice", lit if lit.raw.toUpperCase() in literals
      literals.push lit.raw.toUpperCase()
      (unit.literals[lit.v] ?= []).push name
      break unless @take(',')
    @want ')'
    @want ';'
    unit.types[name] = {name, literals}
    return

  parseTypeMark: (unit) ->
    tok = @wantId('a type')
    name = BUILTIN_TYPES[tok.v] ? (if unit.types[tok.v]? then tok.v else null)
    @fail "unknown type '#{tok.raw}'", tok unless name?
    name

  parsePorts: (unit) ->
    @want 'port'
    @want '('
    loop
      line = @line()
      names = [@wantId('a port name').v]
      names.push @wantId('a port name').v while @take(',')
      @want ':'
      dir = null
      for d in ['in', 'out', 'inout'] when @sees(d)
        dir = d
        @next()
        break
      @fail "a port direction: in, out or inout" unless dir?
      type = @parseTypeMark(unit)
      bind = null
      if @take('bind')
        scheme = @wantId('a binding scheme: panel, mdm, discrete, adc or power').v
        addr = @peek()
        @fail "a quoted address after 'bind #{scheme}'" unless addr.t == 'str'
        @next()
        bind = {scheme, addr: addr.v, line: addr.line}
      @fail "port #{names[0]} has no binding" unless bind?
      unit.ports.push {name, dir, type, bind, line} for name in names
      break unless @take(';')
    @want ')'
    @want ';'
    return

  parseSignal: (unit) ->
    @want 'signal'
    line = @line()
    names = [@wantId('a signal name').v]
    names.push @wantId('a signal name').v while @take(',')
    @want ':'
    type = @parseTypeMark(unit)
    init = null
    init = @parseExpr(unit) if @take(':=')
    @want ';'
    unit.signals.push {name, type, init, line} for name in names
    return

  parseConstant: (unit) ->
    @want 'constant'
    line = @line()
    name = @wantId('a constant name').v
    @want ':'
    type = @parseTypeMark(unit)
    @want ':='
    value = @parseExpr(unit)
    @want ';'
    unit.constants.push {name, type, value, line}
    return

  parseStmt: (unit) ->
    line = @line()
    target = @wantId('a signal name').v
    @want '<=', "'<=' after #{target}"
    expr = @parseExpr(unit)
    @want ';'
    unit.stmts.push {target, expr, line, file: @file}
    return


  parseExpr: (unit) ->
    first = @parseLogical(unit)
    return first unless @sees('when')
    arms = []
    value = first
    loop
      @want 'when'
      arms.push {value, cond: @parseLogical(unit)}
      @want 'else', "'else' after a 'when' arm"
      value = @parseLogical(unit)
      break unless @sees('when')
    {k: 'cond', arms, otherwise: value, line: first.line}

  parseLogical: (unit) ->
    left = @parseRelation(unit)
    op = null
    while @peek().t == 'kw' and @peek().v in LOGICAL
      tok = @next()
      @fail "mixing '#{op}' and '#{tok.v}' takes parentheses", tok if op? and tok.v != op
      op = tok.v
      left = {k: 'bin', op, a: left, b: @parseRelation(unit), line: tok.line}
    left

  parseRelation: (unit) ->
    left = @parseAdding(unit)
    while @peek().t in RELATIONAL
      tok = @next()
      left = {k: 'bin', op: tok.t, a: left, b: @parseAdding(unit), line: tok.line}
    left

  parseAdding: (unit) ->
    left = @parseMultiplying(unit)
    while @peek().t in ADDING
      tok = @next()
      left = {k: 'bin', op: tok.t, a: left, b: @parseMultiplying(unit), line: tok.line}
    left

  parseMultiplying: (unit) ->
    left = @parseUnary(unit)
    while @peek().t in MULTIPLYING or (@peek().t == 'kw' and @peek().v in ['mod', 'rem'])
      tok = @next()
      left = {k: 'bin', op: tok.v, a: left, b: @parseUnary(unit), line: tok.line}
    left

  parseUnary: (unit) ->
    for op in ['not', 'abs'] when @sees(op)
      tok = @next()
      return {k: 'un', op, a: @parseUnary(unit), line: tok.line}
    if @sees('-')
      tok = @next()
      return {k: 'un', op: 'neg', a: @parseUnary(unit), line: tok.line}
    @take '+'
    @parsePrimary(unit)

  parsePrimary: (unit) ->
    tok = @peek()
    if @take('(')
      e = @parseExpr(unit)
      @want ')'
      return e
    switch tok.t
      when 'logic', 'int', 'real', 'time'
        @next()
        return {k: 'lit', type: (if tok.t == 'time' then 'time' else tok.t), v: tok.v, line: tok.line}
      when 'str'
        @next()
        return {k: 'lit', type: 'str', v: tok.v, line: tok.line}
      when 'id'
        @next()
        return @parseCall(unit, tok) if @sees('(')
        if unit.literals[tok.v]?
          return {k: 'enum', v: tok.raw.toUpperCase(), types: unit.literals[tok.v].slice(),
                  line: tok.line}
        return {k: 'name', name: tok.v, raw: tok.raw, line: tok.line}
    @fail "a value, found '#{tok.raw ? tok.v}'"

  parseCall: (unit, tok) ->
    @want '('
    args = []
    unless @sees(')')
      loop
        name = null
        if @peek().t == 'id' and @peek(1).t == '=>'
          name = @next().v
          @next()
        args.push {name, expr: @parseExpr(unit)}
        break unless @take(',')
    @want ')'
    {k: 'call', name: tok.v, raw: tok.raw, args, line: tok.line}

parse = (text, file = '<wiring>') ->
  new Parser(lex(text, file), file).parseFile()

export {WiringError, BUILTIN_TYPES, TIME_UNITS, LOGICAL, lex, parse}
