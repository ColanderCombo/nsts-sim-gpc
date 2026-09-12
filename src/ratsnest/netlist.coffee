import {now as simNow} from '../com/simRuntime.coffee'
# Elaboration produces typed nets and one driver per assignment. Bus input
# dirties dependent drivers; evaluation continues to a fixed point or
# `SETTLE_LIMIT`. Names are local to a wiring unit, while bound addresses
# connect units. Stateful built-ins retain one instance per call site.

import {WiringError, BUILTIN_TYPES} from './wiring'

SETTLE_LIMIT = 100

DEFAULT_WIDTH_MS = 20

NUMERIC = ['integer', 'word', 'real']

defaultOf = (netlist, type) ->
  return 0 if type in ['logic', 'word', 'integer']
  return 0.0 if type == 'real'
  netlist.types[type]?.literals[0] ? ''

LITERAL = 'literal'

assignable = (to, from) ->
  return true if to == from
  return true if to == 'real' and from in ['integer', 'word']
  return true if to == 'word' and from in ['integer', 'logic']
  return true if to == 'integer' and from in ['word', 'logic']
  false

coerce = (type, v) ->
  switch type
    when 'logic' then (if v then 1 else 0)
    when 'word' then (Math.round(Number(v)) & 0xffff)
    when 'integer' then Math.round(Number(v))
    when 'real' then Number(v)
    else v

class Net
  constructor: ({@name, @unit, @type, @port, @line, @file}) ->
    @value = null
    @driver = null                 # the one statement that drives it
    @readers = []                  # the statements that read it
    @heard = false                 # a bound input has been seen on its bus
    @adapter = null

  qualified: () -> "#{@unit}.#{@name}"

class Driver
  constructor: ({@target, @expr, @unit, @line, @file}) ->
    @reads = []
    @nodes = []                    # the stateful function instances in it
    @pending = []                  # enumeration literals more than one type carries
    @sources = []                  # the bound inputs it stands on, through the signals

  ready: () ->
    for net in @sources
      return false unless net.heard
    true


class StateNode
  constructor: (@kind, @line, @file) ->
    @wake = null
    @last = null
    @until = null                  # when an edge one-shot's output falls
    @state = 0
    @queue = []

  edge: (x, ms, dir, now) ->
    was = @last
    @last = x
    if was? and was != x and x == dir
      @until = now + ms
    @wake = if @until? and @until > now then @until else null
    if @until? and now < @until then 1 else 0

  latch: (set, reset) ->
    @wake = null
    @state = if reset then 0 else (if set then 1 else @state)
    @state

  delay: (x, ms, now) ->
    if @last == null
      @last = x
      @state = x
    else if x != @last
      @last = x
      @queue.push {at: now + ms, v: x}
    while @queue.length and @queue[0].at <= now
      @state = @queue.shift().v
    @wake = if @queue.length then @queue[0].at else null
    @state

BUILTINS = {
  latch:   {args: ['set', 'reset'], type: 'logic', stateful: true}
  pulse:   {args: ['signal', 'width'], type: 'logic', stateful: true}
  rising:  {args: ['signal', 'width'], type: 'logic', stateful: true}
  falling: {args: ['signal', 'width'], type: 'logic', stateful: true}
  delay:   {args: ['signal', 'time'], type: 'logic', stateful: true}
}


class Netlist
  constructor: () ->
    @nets = {}                     # qualified name -> Net
    @drivers = []
    @types = {}                    # type name -> {name, literals}
    @units = []
    @dirty = new Set()
    @onSettled = null              # (changed nets) after each settle
    @now = () -> simNow()
    @wakeAt = null                 # (whenMs) -> ; set by whoever runs a clock
    @errors = []

  net: (unit, name) -> @nets["#{unit}.#{name}"]

  bound: (scheme) ->
    (n for _, n of @nets when n.port?.bind.scheme == scheme)

  add: (unit, spec) ->
    key = "#{unit}.#{spec.name}"
    if @nets[key]?
      throw new WiringError(spec.file, spec.line,
        "#{spec.name} is declared twice in #{unit}")
    @nets[key] = new Net(Object.assign({unit}, spec))

  elaborate: (units) ->
    for unit in units
      throw new WiringError(unit.file, unit.line,
        "wiring #{unit.name} is declared twice") if unit.name in @units
      @units.push unit.name
      for name, t of unit.types
        @types["#{unit.name}.#{name}"] = t
      for p in unit.ports
        @unshadowed unit, p.name, p.line
        @add unit.name, {name: p.name, type: @typeKey(unit, p.type), port: p,
                         line: p.line, file: unit.file}
      for s in unit.signals
        @unshadowed unit, s.name, s.line
        @add unit.name, {name: s.name, type: @typeKey(unit, s.type),
                         line: s.line, file: unit.file}
    for unit in units
      @elaborateUnit unit
    for _, net of @nets
      net.value = defaultOf(this, net.type) if net.value == null
    d.sources = @sourcesOf(d) for d in @drivers
    this

  sourcesOf: (driver, seen = null) ->
    seen ?= new Set()
    out = []
    walk = (d) ->
      return if seen.has(d)
      seen.add d
      for net in d.reads
        if net.port? and net.port.dir in ['in', 'inout']
          out.push net unless net in out
        else if net.driver?
          walk net.driver
      return
    walk driver
    out

  unshadowed: (unit, name, line) ->
    type = unit.literals[name]
    return unless type?
    throw new WiringError(unit.file, line,
      "#{name} is a literal of #{type}; a signal cannot carry the same name")

  typeKey: (unit, type) ->
    return type if BUILTIN_TYPES[type]?
    "#{unit.name}.#{type}"

  elaborateUnit: (unit) ->
    consts = {}
    for c in unit.constants
      type = @typeKey(unit, c.type)
      consts[c.name] = {type, value: @constFold(unit, consts, c.value, type)}
    unit.consts = consts

    for s in unit.signals when s.init?
      net = @net(unit.name, s.name)
      net.value = coerce(net.type, @constFold(unit, consts, s.init, net.type))

    for st in unit.stmts
      net = @net(unit.name, st.target)
      throw new WiringError(unit.file, st.line,
        "#{st.target} is not a signal or port of #{unit.name}") unless net?
      throw new WiringError(unit.file, st.line,
        "#{st.target} is an input; nothing here drives it") if net.port?.dir == 'in'
      if net.driver?
        throw new WiringError(unit.file, st.line,
          "#{st.target} is already driven at line #{net.driver.line}")
      driver = new Driver({target: net, expr: st.expr, unit, line: st.line, file: unit.file})
      net.driver = driver
      type = @typeOf(unit, consts, st.expr, driver)
      type = net.type if type == LITERAL and @pin(unit, driver.pending, net.type, st.line)
      unless assignable(net.type, type)
        throw new WiringError(unit.file, st.line,
          "#{st.target} is #{@show(net.type)}; the expression is #{@show(type)}")
      @drivers.push driver
      r.readers.push driver for r in driver.reads

    for p in unit.ports when p.dir == 'out'
      net = @net(unit.name, p.name)
      @errors.push "#{unit.file}:#{p.line}: #{p.name} is an output that nothing drives" unless net.driver?
    return

  show: (type) ->
    if @types[type]? then type.split('.').pop() else type


  typeOf: (unit, consts, e, driver) ->
    fail = (msg) => throw new WiringError(unit.file, e.line, msg)
    switch e.k
      when 'lit'
        return {logic: 'logic', int: 'integer', real: 'real', time: 'time', str: 'str'}[e.type]
      when 'enum'
        e.candidates ?= (@typeKey(unit, t) for t in e.types)
        return e.type = e.candidates[0] if e.candidates.length == 1
        driver?.pending.push e
        return LITERAL
      when 'name'
        if consts[e.name]?
          e.const = consts[e.name].value
          return consts[e.name].type
        net = @net(unit.name, e.name)
        fail "#{e.raw} is not a signal, port or constant of #{unit.name}" unless net?
        if driver?
          driver.reads.push net unless net in driver.reads
          e.net = net
        return net.type
      when 'un'
        t = @typeOf(unit, consts, e.a, driver)
        if e.op == 'not'
          fail "'not' takes a logic value, not #{@show(t)}" unless t == 'logic'
          return 'logic'
        fail "'#{e.op}' takes a number, not #{@show(t)}" unless t in NUMERIC
        return t
      when 'bin'
        ta = @typeOf(unit, consts, e.a, driver)
        tb = @typeOf(unit, consts, e.b, driver)
        if e.op in ['and', 'or', 'nand', 'nor', 'xor', 'xnor']
          fail "'#{e.op}' takes logic values, not #{@show(ta)} and #{@show(tb)}" unless ta == 'logic' and tb == 'logic'
          return 'logic'
        if e.op in ['=', '/=', '<', '<=', '>', '>=']
          if ta == LITERAL and tb == LITERAL
            fail "neither side says which type these literals belong to"
          ta = tb if ta == LITERAL and @pin(unit, driver?.pending ? [], tb, e.line)
          tb = ta if tb == LITERAL and @pin(unit, driver?.pending ? [], ta, e.line)
          unless ta == tb or (ta in NUMERIC and tb in NUMERIC)
            fail "#{@show(ta)} and #{@show(tb)} cannot be compared"
          if e.op not in ['=', '/='] and ta not in NUMERIC
            fail "#{@show(ta)} has no order; compare it with = or /="
          return 'logic'
        if e.op == '&'
          fail "'&' concatenates logic values, not #{@show(ta)} and #{@show(tb)}" unless ta in ['logic', 'word'] and tb in ['logic', 'word']
          return 'word'
        fail "'#{e.op}' takes numbers, not #{@show(ta)} and #{@show(tb)}" unless ta in NUMERIC and tb in NUMERIC
        return if 'real' in [ta, tb] then 'real' else ta
      when 'cond'
        types = []
        for arm in e.arms
          types.push @typeOf(unit, consts, arm.value, driver)
          tc = @typeOf(unit, consts, arm.cond, driver)
          fail "a 'when' condition is logic, not #{@show(tc)}" unless tc == 'logic'
        types.push @typeOf(unit, consts, e.otherwise, driver)
        first = null
        for t in types when t != LITERAL
          first ?= t
        return LITERAL unless first?
        for t in types when t != first and t != LITERAL
          fail "the arms are #{@show(first)} and #{@show(t)}" unless first in NUMERIC and t in NUMERIC
        @pin(unit, driver?.pending ? [], first, e.line) if LITERAL in types
        return first
      when 'call'
        return @typeOfCall(unit, consts, e, driver)
    fail "cannot type this expression"

  typeOfCall: (unit, consts, e, driver) ->
    fail = (msg) => throw new WiringError(unit.file, e.line, msg)
    conv = BUILTIN_TYPES[e.name] ? (if unit.types[e.name]? then @typeKey(unit, e.name) else null)
    if conv?
      fail "#{e.raw}() converts one value" unless e.args.length == 1
      @typeOf(unit, consts, e.args[0].expr, driver)
      e.convert = conv
      return conv
    spec = BUILTINS[e.name]
    fail "there is no function '#{e.raw}'" unless spec?
    fail "#{e.raw} takes #{spec.args.length} arguments" if e.args.length > spec.args.length
    ordered = []
    for a, i in e.args
      if a.name?
        k = spec.args.indexOf(a.name)
        fail "#{e.raw} has no argument '#{a.name}'; it takes #{spec.args.join(', ')}" if k < 0
        fail "#{e.raw} is given '#{a.name}' twice" if ordered[k]?
        ordered[k] = a.expr
      else
        fail "a positional argument cannot follow a named one" if e.args[i - 1]?.name?
        ordered[i] = a.expr
    if e.name == 'latch'
      for k in [0, 1] when not ordered[k]?
        fail "latch takes #{spec.args.join(' and ')}"
      for k in [0, 1]
        t = @typeOf(unit, consts, ordered[k], driver)
        fail "latch's #{spec.args[k]} is logic, not #{@show(t)}" unless t == 'logic'
    else
      fail "#{e.raw} takes a signal and a time" unless ordered[0]?
      t = @typeOf(unit, consts, ordered[0], driver)
      fail "#{e.raw} watches a logic value, not #{@show(t)}" unless t == 'logic'
      if ordered[1]?
        tt = @typeOf(unit, consts, ordered[1], driver)
        fail "#{e.raw}'s width is a time, as 300 ms, not #{@show(tt)}" unless tt == 'time'
      else
        ordered[1] = {k: 'lit', type: 'time', v: DEFAULT_WIDTH_MS, line: e.line}
    e.ordered = ordered
    if spec.stateful
      e.node = new StateNode(e.name, e.line, unit.file)
      driver?.nodes.push e.node
    spec.type

  constFold: (unit, consts, e, type) ->
    scratch = {reads: [], nodes: [], pending: []}
    t = @typeOf(unit, consts, e, scratch)
    @pin(unit, scratch.pending, type, e.line) if t == LITERAL
    @evalExpr(unit, consts, e, @now())

  pin: (unit, nodes, wanted, line) ->
    return false unless @types[wanted]?
    for e in nodes
      unless wanted in e.candidates
        throw new WiringError(unit.file, e.line,
          "#{e.v} is not a literal of #{@show(wanted)}")
      e.type = wanted
    nodes.length = 0
    true


  evalExpr: (unit, consts, e, now) ->
    switch e.k
      when 'lit' then return e.v
      when 'enum' then return e.v
      when 'name'
        return e.const if e.const?
        return e.net.value
      when 'un'
        a = @evalExpr(unit, consts, e.a, now)
        return (if a then 0 else 1) if e.op == 'not'
        return -a if e.op == 'neg'
        return Math.abs(a)
      when 'bin' then return @evalBin(unit, consts, e, now)
      when 'cond'
        for arm in e.arms
          return @evalExpr(unit, consts, arm.value, now) if @evalExpr(unit, consts, arm.cond, now)
        return @evalExpr(unit, consts, e.otherwise, now)
      when 'call' then return @evalCall(unit, consts, e, now)
    0

  evalBin: (unit, consts, e, now) ->
    a = @evalExpr(unit, consts, e.a, now)
    b = @evalExpr(unit, consts, e.b, now)
    switch e.op
      when 'and' then return (if a and b then 1 else 0)
      when 'or' then return (if a or b then 1 else 0)
      when 'nand' then return (if a and b then 0 else 1)
      when 'nor' then return (if a or b then 0 else 1)
      when 'xor' then return (if (!!a) != (!!b) then 1 else 0)
      when 'xnor' then return (if (!!a) == (!!b) then 1 else 0)
      when '=' then return (if a == b then 1 else 0)
      when '/=' then return (if a != b then 1 else 0)
      when '<' then return (if a < b then 1 else 0)
      when '<=' then return (if a <= b then 1 else 0)
      when '>' then return (if a > b then 1 else 0)
      when '>=' then return (if a >= b then 1 else 0)
      when '&' then return (((a << 1) | (if b then 1 else 0)) & 0xffff)
      when '+' then return a + b
      when '-' then return a - b
      when '*' then return a * b
      when '/' then return (if b == 0 then 0 else a / b)
      when 'mod' then return (if b == 0 then 0 else ((a % b) + b) % b)
      when 'rem' then return (if b == 0 then 0 else a % b)
    0

  evalCall: (unit, consts, e, now) ->
    return coerce(e.convert, @evalExpr(unit, consts, e.args[0].expr, now)) if e.convert?
    args = (@evalExpr(unit, consts, a, now) for a in e.ordered)
    node = e.node
    out = switch e.name
      when 'latch' then node.latch(args[0], args[1])
      when 'pulse', 'rising' then node.edge((if args[0] then 1 else 0), args[1], 1, now)
      when 'falling' then node.edge((if args[0] then 1 else 0), args[1], 0, now)
      when 'delay' then node.delay((if args[0] then 1 else 0), args[1], now)
      else 0
    @wakeAt?(node.wake) if node.wake?
    out


  put: (net, value) ->
    net.heard = true
    v = coerce(net.type, value)
    return false if net.value == v
    net.value = v
    @dirty.add d for d in net.readers
    true

  settleAll: () ->
    @dirty.add d for d in @drivers
    @settle()

  settle: () ->
    changed = new Set()
    rounds = 0
    while @dirty.size
      if ++rounds > SETTLE_LIMIT
        moving = (d.target.qualified() for d in @dirty).sort()
        @dirty.clear()
        throw new Error("wiring does not settle: #{moving.slice(0, 8).join(', ')}")
      round = Array.from(@dirty)
      @dirty.clear()
      now = @now()
      for driver in round
        v = coerce(driver.target.type, @evalExpr(driver.unit, driver.unit.consts, driver.expr, now))
        continue if driver.target.value == v
        driver.target.value = v
        changed.add driver.target
        @dirty.add d for d in driver.target.readers
    out = Array.from(changed)
    @onSettled?(out) if out.length
    out

  timed: () ->
    (d for d in @drivers when d.nodes.length)

export {Netlist, Net, Driver, StateNode, BUILTINS, SETTLE_LIMIT, DEFAULT_WIDTH_MS,
        LITERAL, assignable, coerce, defaultOf}
