import {frozen} from '../../../com/simRuntime.coffee'
# Debug command table
#
# One entry per operation, carrying its parameters, a handler that returns
# JSON, and a renderer that turns that JSON into text.  `{"cmd":"step",
# "args":{"count":10}}` and `step 10` are coerced against the same parameter
# list and reach the same handler.
#
# Parameter types:
#   addr    an address: 0x-prefixed hex, a symbol, or bare hex, each
#           optionally followed by +/- an offset
#   addrs   a list of the above
#   int     decimal count
#   hex     hex value
#   hexes   a list of hex values
#   str     one token
#   text    the rest of the line, verbatim
#   bool    on/off, yes/no, true/false, 1/0
#   json    a structure, passed through from a JSON request; a text command
#           line carries it as one JSON token
#
# A parameter marked `flag` is only reachable as `--name value` (or `--name`
# alone when it is a bool).


export PROTOCOL_VERSION = 1

export COMMANDS = {}
export ALIASES = {}

export defc = (name, spec) ->
  spec.name = name
  execute = spec.exec
  spec.exec = (session, args) ->
    if frozen() and name not in ['help', 'status', 'capabilities', 'regs', 'mem', 'disasm',
                                'ints', 'timers', 'iop', 'iopdisasm', 'discretes']
      throw new Error('simulation is frozen')
    execute(session, args)
  spec.params ?= []
  COMMANDS[name] = spec
  for a in (spec.aliases ? [])
    ALIASES[a] = name
  spec

export lookupCommand = (name) ->
  return null unless name?
  key = String(name).toLowerCase()
  COMMANDS[key] ? COMMANDS[ALIASES[key] ? '']  ? null

class CmdError extends Error
  constructor: (@code, message) ->
    super(message)

export cmdError = (code, message) -> new CmdError(code, message)

BOOL_TRUE = ['on', 'yes', 'true', '1', 'enable', 'enabled']
BOOL_FALSE = ['off', 'no', 'false', '0', 'disable', 'disabled']

coerceOne = (session, p, raw) ->
  bad = (why) -> throw cmdError('badArgs', "#{p.name}: #{why}")
  switch p.type
    when 'addr'
      a = session.resolveAddr(raw)
      bad("cannot resolve '#{raw}'") unless a?
      a
    when 'addrs'
      list = if Array.isArray(raw) then raw else String(raw).split(/[\s,]+/)
      for r in list when String(r).length > 0
        a = session.resolveAddr(r)
        bad("cannot resolve '#{r}'") unless a?
        a
    when 'int'
      v = if typeof raw == 'number' then raw else parseInt(String(raw), 10)
      bad("'#{raw}' is not a number") if isNaN(v)
      v
    when 'hex'
      v = if typeof raw == 'number' then raw else parseInt(String(raw).replace(/^0[xX]/, ''), 16)
      bad("'#{raw}' is not hex") if isNaN(v)
      v
    when 'hexes'
      list = if Array.isArray(raw) then raw else String(raw).split(/[\s,]+/)
      for r in list when String(r).length > 0
        v = if typeof r == 'number' then r else parseInt(String(r).replace(/^0[xX]/, ''), 16)
        bad("'#{r}' is not hex") if isNaN(v)
        v
    when 'bool'
      return raw if typeof raw == 'boolean'
      t = String(raw).toLowerCase()
      return true if t in BOOL_TRUE
      return false if t in BOOL_FALSE
      bad("'#{raw}' is not on or off")
    when 'json'
      return raw unless typeof raw == 'string'
      try
        JSON.parse(raw)
      catch e
        bad("not JSON: #{e.message}")
    else String(raw)

export coerceArgs = (session, spec, args = {}) ->
  out = {}
  for p in spec.params
    raw = args[p.name]
    if not raw? or (typeof raw == 'string' and raw.length == 0 and p.type != 'text')
      throw cmdError('badArgs', "#{spec.name}: #{p.name} is required") if p.required
      out[p.name] = p.default ? null
      continue
    out[p.name] = coerceOne(session, p, raw)
  out

export parseArgLine = (spec, tokens) ->
  args = {}
  positional = (p for p in spec.params when not p.flag)
  byName = {}
  byName[p.name.toLowerCase()] = p for p in spec.params
  pi = 0
  i = 0
  while i < tokens.length
    tok = tokens[i]
    if tok.startsWith('--')
      key = tok.slice(2).toLowerCase()
      eq = key.indexOf('=')
      inline = null
      if eq >= 0
        inline = key.slice(eq + 1)
        key = key.slice(0, eq)
      p = byName[key]
      throw cmdError('badArgs', "#{spec.name}: unknown option --#{key}") unless p?
      if p.type == 'bool'
        args[p.name] = inline ? true
      else
        v = inline ? tokens[i + 1]
        throw cmdError('badArgs', "#{spec.name}: --#{key} needs a value") unless v?
        args[p.name] = v
        i++ unless inline?
      i++
      continue
    p = positional[pi]
    if not p?
      throw cmdError('badArgs', "#{spec.name}: unexpected argument '#{tok}'")
    if p.type == 'text'
      args[p.name] = tokens.slice(i).join(' ')
      i = tokens.length
    else if p.type in ['addrs', 'hexes']
      args[p.name] = tokens.slice(i)
      i = tokens.length
    else
      args[p.name] = tok
      i++
    pi++
  args
