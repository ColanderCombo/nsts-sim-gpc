import {call, setInterval, clearInterval} from './simRuntime.coffee'
# Power to the units
#
# A feed is a node of the vehicle's dc distribution with a voltage on it:
# a main bus, an essential or control bus, or the output of a switch,
# circuit breaker or remote power controller.  Whatever holds the
# distribution -- the ratsnest, reading the crew's switches and breakers
# through wiring/eps.wir -- publishes each feed's volts on `_POWER`.  A
# unit joins the bus for the feeds its inputs are on, and reports the
# watts it takes from each.
#
# Feeds are named as the documents name them, in letters, digits and
# underscore: MNA, MNB, MNC, ESS1BC, ESS2CA, ESS3AB, CNTLAB1, FPC1 for
# the distribution, and a controller's output after the unit it feeds,
# GPC1_A, MMU1, FF1_B.
#
# `_POWER` in com/bus.civet.  Message halfwords:
#
#     0   operation   REQUEST = 3, VALUE = 4, DRAW = 5
#     1   nameLen     characters of the name
#     2   nWords      value halfwords
#     3.. name        com/msgtext.coffee
#     ..  value       IEEE-754 binary32, high half first
#
# VALUE carries a feed's volts.  DRAW carries the watts one unit takes,
# named "<feed>/<unit>"; a feed name holds no slash, so the unit is what
# follows the one there is.  A REQUEST with an empty name asks for
# everything and with a feed name for that feed's volts and the draws on
# it.  Nothing is republished on a timer: a process that attaches late
# asks with REQUEST, and asks again every REASK_MS while any feed it
# needs is unanswered.
#
# An input is live at or above its dropout voltage, and a unit is powered
# by the rule its supply carries: `any`, which is how an MDM's two supplies
# and a GPC's three stand, or `all`.  A unit that declares no input is
# powered.

import {Bus, BusMsg, busConfig} from 'com/bus'
import {textWords, putText, getText} from 'com/msgtext'

export REQUEST = 3
export VALUE = 4
export DRAW = 5

export POWER_BUS = '_POWER'
export HEADER_WORDS = 3

export OP_NAME = {3: 'REQUEST', 4: 'VALUE', 5: 'DRAW'}

# The orbiter's dc distribution.
export NOMINAL_VOLTS = 28.0

# Where an input stops being live.  A model value: the documents on hand
# give no dropout voltage for the DPS boxes.  `minVolts` on an input
# replaces it.
export DROPOUT_VOLTS = 20.0

# How often a unit asks again for a feed nothing has answered for.
export REASK_MS = 2000

# The rules by which a unit's inputs make it powered.
export RULES = ['any', 'all']

# An input's voltage until its feed answers: `on`, `off`, or volts.
export DEFAULT_POWER = 'on'

parsePowerDefault = (raw) ->
  s = String(raw ? '').trim().toLowerCase()
  return NOMINAL_VOLTS if s == 'on'
  return 0 if s == 'off'
  v = Number(s)
  unless isFinite(v) and v >= 0
    throw new Error("invalid power default '#{raw}'")
  v

powerSettings = {dflt: NOMINAL_VOLTS}

export configurePower = ({dflt} = {}) ->
  powerSettings.dflt = parsePowerDefault(dflt ? process.env.NSTS_POWER_DEFAULT ? DEFAULT_POWER)
  powerSettings

export defaultVolts = () -> powerSettings.dflt

try
  configurePower()
catch e
  console.error "power: #{e.message}"
  process.exit(2)

export splitDraw = (name) ->
  s = String(name ? '')
  i = s.indexOf('/')
  return {feed: s, unit: null} if i < 0
  {feed: s[0...i], unit: (s[(i + 1)..] or null)}

export encodePower = ({op, name, value}) ->
  n = String(name ? '')
  words = []
  if op != REQUEST
    buf = new DataView(new ArrayBuffer(4))
    buf.setFloat32(0, Number(value ? 0))
    words = [buf.getUint16(0), buf.getUint16(2)]
  msg = new BusMsg(HEADER_WORDS + textWords(n.length) + words.length)
  msg.data16[0] = op & 0xffff
  msg.data16[1] = n.length & 0xffff
  msg.data16[2] = words.length & 0xffff
  at = putText(msg.data16, HEADER_WORDS, n)
  msg.data16[at + i] = words[i] & 0xffff for i in [0...words.length] by 1
  msg

export decodePower = (msg) ->
  d = msg?.data16
  return null unless d? and d.length >= HEADER_WORDS
  op = d[0] & 0xffff
  return null unless OP_NAME[op]?
  nameLen = d[1] & 0xffff
  nWords = d[2] & 0xffff
  return null unless d.length >= HEADER_WORDS + textWords(nameLen) + nWords
  at = HEADER_WORDS
  name = getText(d, at, nameLen)
  at += textWords(nameLen)
  m = {op, opName: OP_NAME[op], name}
  if nWords >= 2
    buf = new DataView(new ArrayBuffer(4))
    buf.setUint16(0, d[at] ? 0)
    buf.setUint16(2, d[at + 1] ? 0)
    m.value = buf.getFloat32(0)
  else
    m.value = null
  Object.assign m, splitDraw(name) if op == DRAW
  m

export fmtPower = (m) ->
  return '' unless m?
  return "REQUEST #{m.name or '*'}" if m.op == REQUEST
  unit = if m.op == DRAW then ' W' else ' V'
  "#{m.opName} #{m.name} #{Number(m.value).toPrecision(4)}#{unit}"

export class PowerChannel
  constructor: (onMessage = null) ->
    @bus = new Bus(POWER_BUS, busConfig[POWER_BUS])
    @bus.onReceive ((self, busID, msg) ->
      m = decodePower(msg)
      onMessage?(m) if m?), null

  ready: () -> @bus?.ready ? Promise.resolve()

  close: () ->
    @bus?.close()
    @bus = null
    return

  send: (m) ->
    @bus?.sendMsg encodePower(m)
    return

  report: (feed, volts) ->
    @send {op: VALUE, name: feed, value: volts}

  draw: (feed, unit, watts) ->
    @send {op: DRAW, name: "#{feed}/#{unit}", value: watts}

  request: (name = '') ->
    @send {op: REQUEST, name}

export class PowerInput
  constructor: ({@name, @feed, minVolts, watts}) ->
    @minVolts = minVolts ? DROPOUT_VOLTS
    @watts = watts ? 0
    @volts = defaultVolts()
    @heard = false

  live: () -> @volts >= @minVolts

# A `power` specification is a feed name or a list of names or input objects.
export inputsOf = (spec) ->
  return [] unless spec?
  list = if Array.isArray(spec) then spec else [spec]
  for entry, i in list
    e = if typeof entry == 'string' then {feed: entry} else entry
    throw new Error('power input has no feed') unless e.feed
    new PowerInput({name: (e.name ? e.feed), feed: e.feed, minVolts: e.minVolts, watts: e.watts})

export class PowerSupply
  constructor: (@id, spec = null, opts = {}) ->
    @inputs = inputsOf(spec)
    @rule = opts.rule ? 'any'
    throw new Error("invalid power rule '#{@rule}'") unless @rule in RULES
    @onPower = opts.onPower ? null
    @onVolts = opts.onVolts ? null
    @drawOf = opts.draw ? null
    @log = opts.log ? null
    @channel = null
    @asking = null
    @sent = {}
    @live = @powered()

  powered: () ->
    return true unless @inputs.length
    if @rule == 'all'
      return @inputs.every((i) -> i.live())
    @inputs.some((i) -> i.live())

  byFeed: (feed) -> (i for i in @inputs when i.feed == feed)

  named: (name) -> (i for i in @inputs when i.name == name)[0] ? null

  unheard: () -> (i.feed for i in @inputs when not i.heard)

  open: () ->
    return this unless @inputs.length
    @channel = new PowerChannel (m) => @recv(m)
    @channel.ready().then () =>
      @request()
      @publishDraw()
    @asking = setInterval call(@, 'reask'), REASK_MS
    @asking.unref?()
    this

  ready: () -> @channel?.ready() ? Promise.resolve()

  close: () ->
    clearInterval(@asking) if @asking?
    @asking = null
    @channel?.close()
    @channel = null
    return

  request: () ->
    asked = {}
    for feed in @unheard() when not asked[feed]
      asked[feed] = true
      @channel?.request(feed)
    return

  reask: () ->
    unless @unheard().length
      clearInterval(@asking) if @asking?
      @asking = null
      return
    @request()
    return

  recv: (m) ->
    return unless m?
    if m.op == REQUEST
      @publishDraw(m.name, true)
      return
    return unless m.op == VALUE
    @put m.name, m.value
    return

  # Accept a feed update from the bus or an embedded caller.
  put: (feed, volts) ->
    inputs = @byFeed(feed)
    return unless inputs.length
    for input in inputs
      input.heard = true
      before = input.live()
      input.volts = Number(volts)
      @onVolts?(input)
      @log?("#{@id} #{input.name} #{input.volts.toPrecision(3)} V" +
            "#{if input.live() then '' else ', dead'}") if input.live() != before
    @settled()
    return

  settled: () ->
    now = @powered()
    if now != @live
      @live = now
      @onPower?(now)
    @publishDraw()
    return

  wattsOn: (input) ->
    return Number(@drawOf(input) ? 0) if @drawOf?
    if input.live() then input.watts else 0

  publishDraw: (name = '', force = false) ->
    return unless @channel?
    for input in @inputs
      continue if name and input.feed != name
      w = @wattsOn(input)
      continue if not force and @sent[input.name] == w
      @sent[input.name] = w
      @channel.draw input.feed, @id, w
    return
