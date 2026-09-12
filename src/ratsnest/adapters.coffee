# `bind <scheme> "<address>"` connects a wiring port to a bus adapter:
#
#   panel     "F6/S3"        a control or indicator, panel/panelBus.coffee
#   mdm       "FF1/4/1.0"    an MDM channel toward the vehicle, unit, card,
#                            channel and, on a discrete card, the bit
#   discrete  "gpc4/A/mm1ready"   one bit of a device's discrete register
#   adc       "1/12"         an analog input of an ADC pair, in volts
#   power     "MNA"          a feed of the dc distribution, in volts, and
#                            "MNA.draw" the watts the units on it take
# Adapters request initial bus state when they attach.

import {Bus, BusMsg, busConfig} from 'com/bus'
import {PanelChannel, SET as P_SET, REQUEST as P_REQUEST, VALUE as P_VALUE,
        LOGIC, ENUM, WORD, REAL, splitKey} from './../panel/panelBus'
import {DiscreteChannel, GPC_DISCRETES, SET, RESET, REQUEST, VALUE,
        bitMask, applyDiscrete} from 'com/discretes'
import {IDP_DISCRETES} from './../meds/idp/idpDiscretes'
import {IO_OP, IO_ALL, ioBusName, encodeIO, decodeIO, iomType,
        voltsToWord, wordToVolts, voltsToAodWord, aodWordToVolts} from './../lru/mdm/mdmConf'
import {MDM_CATALOG} from './../lru/mdm/mdmConfig'
import {ANALOG_OP, ANALOG_ALL, encodeAnalog, decodeAnalog, analogBusOf,
        CHANNELS as ADC_CHANNELS} from './../lru/adc/adcConf'
import {PowerChannel, REQUEST as PWR_REQUEST, VALUE as PWR_VALUE, DRAW as PWR_DRAW,
        NOMINAL_VOLTS} from 'com/power'

class BindError extends Error
  constructor: (net, message) ->
    super "#{net.file}:#{net.line}: #{net.name} bound #{net.port.bind.scheme} \"#{net.port.bind.addr}\": #{message}"
    @name = 'BindError'

class Adapter
  scheme: ''

  constructor: (@netlist, @log = null) ->
    @nets = []

  claim: () ->
    for net in @netlist.bound(@scheme)
      net.adapter = this
      net.endpoint = @parse(net)
      @nets.push net
    @nets.length

  note: (text) -> @log?(text)

  ready: () -> Promise.resolve()
  controlBuses: () -> []
  open: () -> return
  close: () -> return
  drive: (net) -> return

  request: () -> return

  unheard: () -> (n for n in @reads() when not n.heard)

  reads: () -> (n for n in @nets when n.port.dir in ['in', 'inout'])
  writes: () -> (n for n in @nets when n.port.dir in ['out', 'inout'])

  answers: () -> (n for n in @writes() when n.driver?.ready())


# A control is "<panel>/<control>": a switch or pushbutton read `in`, a
# talkback, light or meter driven `out`.  The frontend holding the panel
# answers a REQUEST for its controls, and the ratsnest answers one for
# the indicators it drives.
class PanelAdapter extends Adapter
  controlBuses: () -> [@channel.bus]
  scheme: 'panel'

  parse: (net) ->
    {panel, control} = splitKey(net.port.bind.addr)
    throw new BindError(net, "a control is <panel>/<control>, as F6/S3") unless panel? and control?
    {key: "#{panel}/#{control}", panel, control, kind: @kindOf(net)}

  kindOf: (net) ->
    switch net.type
      when 'logic' then LOGIC
      when 'real' then REAL
      when 'word', 'integer' then WORD
      else ENUM

  open: () ->
    @byKey = {}
    for net in @nets
      @byKey[net.endpoint.key] ?= []
      @byKey[net.endpoint.key].push net
    @channel = new PanelChannel (m) => @recv(m)
    @channel.ready().then () => @request()
    return

  request: () ->
    @channel?.request('') if @unheard().length
    return

  ready: () -> @channel?.ready() ? Promise.resolve()

  close: () ->
    @channel?.close()
    @channel = null
    return

  recv: (m) ->
    if m.op == P_REQUEST
      for net in @answers()
        @drive(net) if not m.key or net.endpoint.key.startsWith(m.key)
      return
    return unless m.op == P_VALUE or m.op == P_SET
    for net in (@byKey[m.key] ? []) when net.port.dir in ['in', 'inout']
      @put net, m
    return

  put: (net, m) ->
    v = m.value
    if net.type not in ['logic', 'word', 'integer', 'real']
      name = String(v ? '').toUpperCase()
      literals = @netlist.types[net.type]?.literals ? []
      unless name in literals
        @note "panel #{m.key}: '#{v}' is not a position of #{net.name} (#{literals.join(', ')})"
        return
      v = name
    @netlist.put net, v
    @netlist.settle()
    return

  drive: (net) ->
    @channel?.report net.endpoint.key, net.endpoint.kind, net.value
    return


# "FF1/4/1.0" is MDM FF1, card 4, channel 1, the bit the catalog counts as
# 0; without a bit the whole sixteen-bit channel.  A real net on an analog
# card is volts, converted by the card's scaling.  lru/mdm/mdmConf.coffee has
# the message shape and lru/mdm/mdmConfig.coffee the card in each slot.
class MdmAdapter extends Adapter
  controlBuses: () -> Object.values(@busses)
  scheme: 'mdm'

  parse: (net) ->
    m = String(net.port.bind.addr).match(/^([A-Za-z]+\d*)\/(\d+)\/(\d+)(?:\.(\d+))?$/)
    throw new BindError(net, "an MDM signal is <unit>/<card>/<channel>[.<bit>], as FF1/4/1.0") unless m?
    unit = m[1].toUpperCase()
    entry = MDM_CATALOG[unit]
    throw new BindError(net, "there is no MDM #{unit}") unless entry?
    card = parseInt(m[2], 10)
    throw new BindError(net, "cards are 0 to 15") unless 0 <= card <= 15
    name = entry.iom[card]
    throw new BindError(net, "MDM #{unit} slot #{card} is empty") unless name?
    type = iomType(name)
    channel = parseInt(m[3], 10)
    bit = if m[4]? then parseInt(m[4], 10) else null
    throw new BindError(net, "bits are 0 to 15") if bit? and not (0 <= bit <= 15)
    if bit? and type.kind != 'discrete'
      throw new BindError(net, "#{unit} card #{card} is #{name}, which has no bits")
    if not bit? and type.kind == 'discrete' and net.type == 'logic'
      throw new BindError(net, "#{unit} card #{card} is #{name}: name the bit, as #{m[2]}/#{m[3]}.0")
    {unit, card, channel, bit, iom: name, type, bus: ioBusName(unit)}

  open: () ->
    @busses = {}
    @channels = {}                 # "unit/card/channel" -> the sixteen bits
    for net in @nets
      e = net.endpoint
      unless @busses[e.unit]?
        @busses[e.unit] = new Bus(e.bus, busConfig[e.bus])
        @busses[e.unit].onReceive ((self, busID, msg) => @recv(busID, msg)), null
      @channels[@slot(e)] ?= 0
    @readyAll = Promise.all(b.ready for _, b of @busses)
    @readyAll.then () => @request()
    return

  request: () ->
    asked = {}
    for net in @unheard()
      e = net.endpoint
      k = "#{e.unit}/#{e.card}"
      continue if asked[k]
      asked[k] = true
      @send e.unit, {op: IO_OP.REQUEST, type: e.type.code, card: e.card, channel: IO_ALL}
    return

  ready: () -> @readyAll ? Promise.resolve()

  close: () ->
    b.close() for _, b of @busses
    @busses = {}
    return

  slot: (e) -> "#{e.unit}/#{e.card}/#{e.channel}"

  send: (unit, m) ->
    bus = @busses[unit]
    return unless bus?
    words = encodeIO(m)
    msg = new BusMsg(words.length)
    msg.data16.set(words)
    bus.sendMsg msg
    return

  unitOf: (busID) ->
    for unit, bus of @busses
      return unit if bus.busID == busID
    null

  recv: (busID, msg) ->
    m = decodeIO(msg.data16)
    return unless m? and m.op in [IO_OP.SET, IO_OP.RESET, IO_OP.VALUE]
    unit = @unitOf(busID)
    return unless unit?
    touched = []
    for w, i in m.words
      channel = m.channel + i
      key = "#{unit}/#{m.card}/#{channel}"
      continue unless @channels[key]?
      @channels[key] = switch m.op
        when IO_OP.SET then (@channels[key] | w) & 0xffff
        when IO_OP.RESET then (@channels[key] & ~w) & 0xffff
        else w & 0xffff
      touched.push key
    return unless touched.length
    for net in @reads() when @slot(net.endpoint) in touched
      @netlist.put net, @valueOf(net)
    @netlist.settle()
    return

  valueOf: (net) ->
    e = net.endpoint
    w = @channels[@slot(e)] ? 0
    return (if w & (0x8000 >>> e.bit) then 1 else 0) if e.bit?
    return @toVolts(e, w) if net.type == 'real'
    w

  toVolts: (e, w) ->
    return aodWordToVolts(w) if e.iom == 'AOD'
    wordToVolts(w)

  fromVolts: (e, v) ->
    return voltsToAodWord(v) if e.iom == 'AOD'
    voltsToWord(v)

  drive: (net) ->
    e = net.endpoint
    if e.bit?
      mask = 0x8000 >>> e.bit
      op = if net.value then IO_OP.SET else IO_OP.RESET
      @send e.unit, {op, type: e.type.code, card: e.card, channel: e.channel, words: [mask]}
      key = @slot(e)
      @channels[key] = if net.value then (@channels[key] | mask) & 0xffff else (@channels[key] & ~mask) & 0xffff
      return
    w = if net.type == 'real' then @fromVolts(e, net.value) else (Math.round(net.value) & 0xffff)
    @channels[@slot(e)] = w & 0xffff
    @send e.unit, {op: IO_OP.VALUE, type: e.type.code, card: e.card, channel: e.channel, words: [w]}
    return


DEVICES = {gpc: GPC_DISCRETES, idp: IDP_DISCRETES}

# "gpc4/A/mm1ready" is GPC 4's register A, the bit com/discretes.coffee
# calls mm1ready; "idp1/A/load" the IDP's, from
# meds/idp/idpDiscretes.coffee.  A bit may be written as a number.
class DiscreteAdapter extends Adapter
  controlBuses: () -> Object.values(@channels).map((channel) -> channel.bus)
  scheme: 'discrete'

  parse: (net) ->
    m = String(net.port.bind.addr).match(/^([A-Za-z]+)(\d+)\/([A-Za-z]+)\/(\w+)$/)
    throw new BindError(net, "a discrete is <device><n>/<register>/<bit>, as gpc4/A/mm1ready") unless m?
    kind = m[1].toLowerCase()
    spec = DEVICES[kind]
    throw new BindError(net, "the devices are #{Object.keys(DEVICES).join(' and ')}") unless spec?
    try
      id = spec.resolveId(m[2])
    catch e
      throw new BindError(net, e.message)
    reg = null
    for r in spec.regs when spec.regName(r).toLowerCase() == m[3].toLowerCase()
      reg = r
    throw new BindError(net, "#{kind} registers are #{(spec.regName(r) for r in spec.regs).join(', ')}") unless reg?
    try
      bit = spec.resolve(reg, m[4])
    catch e
      throw new BindError(net, e.message)
    throw new BindError(net, "a discrete bit is one wire; #{net.name} is #{net.type}") unless net.type == 'logic'
    {kind, spec, id, reg, bit, bus: spec.busName(id)}

  open: () ->
    @channels = {}
    @registers = {}                # "bus/reg" -> the thirty-two bits
    for net in @nets
      e = net.endpoint
      unless @channels[e.bus]?
        do (name = e.bus) =>
          @channels[name] = new DiscreteChannel(name, ((m) => @recv(name, m)), e.id)
      @registers["#{e.bus}/#{e.reg}"] ?= 0
    @readyAll = Promise.all(c.ready() for _, c of @channels)
    @readyAll.then () => @request()
    return

  request: () ->
    asked = {}
    for net in @unheard()
      e = net.endpoint
      k = "#{e.bus}/#{e.reg}"
      continue if asked[k]
      asked[k] = true
      @channels[e.bus]?.request(e.reg)
    return

  ready: () -> @readyAll ? Promise.resolve()

  close: () ->
    c.close() for _, c of @channels
    @channels = {}
    return

  recv: (busName, m) ->
    return unless m? and m.op in [SET, RESET, VALUE]
    key = "#{busName}/#{m.reg}"
    return unless @registers[key]?
    @registers[key] = applyDiscrete(@registers[key], m)
    for net in @reads() when net.endpoint.bus == busName and net.endpoint.reg == m.reg
      @netlist.put net, (if @registers[key] & bitMask(net.endpoint.bit) then 1 else 0)
    @netlist.settle()
    return

  drive: (net) ->
    e = net.endpoint
    @channels[e.bus]?.set e.reg, e.bit, (net.value != 0)
    return


# "1/12" is analog input 12 of ADC pair 1, in volts: the signal both units
# of the pair sample (lru/adc/adcConf.coffee).
class AdcAdapter extends Adapter
  controlBuses: () -> Object.values(@busses)
  scheme: 'adc'

  parse: (net) ->
    m = String(net.port.bind.addr).match(/^([12])\/(\d+)$/)
    throw new BindError(net, "an ADC input is <pair>/<channel>, as 1/12") unless m?
    channel = parseInt(m[2], 10)
    throw new BindError(net, "channels are 0 to #{ADC_CHANNELS - 1}") unless 0 <= channel < ADC_CHANNELS
    pair = parseInt(m[1], 10)
    {pair, channel, bus: analogBusOf("#{pair}A")}

  open: () ->
    @busses = {}
    for net in @nets
      e = net.endpoint
      unless @busses[e.bus]?
        @busses[e.bus] = new Bus(e.bus, busConfig[e.bus])
        @busses[e.bus].onReceive ((self, busID, msg) => @recv(busID, msg)), null
    @readyAll = Promise.all(b.ready for _, b of @busses)
    @readyAll.then () => @request()
    return

  ready: () -> @readyAll ? Promise.resolve()

  close: () ->
    b.close() for _, b of @busses
    @busses = {}
    return

  request: () ->
    for net in @unheard()
      e = net.endpoint
      words = encodeAnalog(ANALOG_OP.REQUEST, e.channel)
      msg = new BusMsg(words.length)
      msg.data16.set(words)
      @busses[e.bus]?.sendMsg msg
    return

  recv: (busID, msg) ->
    m = decodeAnalog(msg.data16)
    return unless m?
    if m.op == ANALOG_OP.REQUEST
      @drive(net) for net in @answers() when net.endpoint.bus == busID and
        (m.channel == ANALOG_ALL or m.channel == net.endpoint.channel)
      return
    for net in @reads() when net.endpoint.bus == busID
      i = net.endpoint.channel - m.channel
      continue unless 0 <= i < m.volts.length
      @netlist.put net, m.volts[i]
    @netlist.settle()
    return

  drive: (net) ->
    e = net.endpoint
    words = encodeAnalog(ANALOG_OP.VALUE, e.channel, [net.value])
    msg = new BusMsg(words.length)
    msg.data16.set(words)
    @busses[e.bus]?.sendMsg msg
    return


# "MNA" is the feed's volts and "MNA.draw" the watts the units on it are
# taking, summed from what each reports (com/power.coffee).  A logic net
# on a feed reads it as live or dead and drives it at 28 V or none.
#
# The nets of one process see each other: a feed driven here is put on
# every net in this ratsnest bound to read it, the bus carrying its own
# datagrams to the other processes only.  A draw net starts at zero, the
# sum of no loads, so a feed nothing draws from does not hold up the
# outputs behind it.
class PowerAdapter extends Adapter
  controlBuses: () -> [@channel.bus]
  scheme: 'power'

  parse: (net) ->
    m = String(net.port.bind.addr).match(/^([A-Za-z][A-Za-z0-9_]*)(\.draw)?$/)
    throw new BindError(net, "a feed is a name in letters, digits and underscore, as MNA") unless m?
    feed = m[1].toUpperCase()
    draw = m[2]?
    throw new BindError(net, "a draw is read, not driven") if draw and net.port.dir != 'in'
    throw new BindError(net, "watts are a real; #{net.name} is #{net.type}") if draw and net.type != 'real'
    unless net.type in ['real', 'logic']
      throw new BindError(net, "a feed is volts or a level; #{net.name} is #{net.type}")
    {feed, draw}

  open: () ->
    @draws = {}                    # feed -> {unit: watts}
    @pending = null
    @channel = new PowerChannel (m) => @recv(m)
    @channel.ready().then () => @request()
    @netlist.put net, 0 for net in @reads() when net.endpoint.draw
    return

  ready: () -> @channel?.ready() ? Promise.resolve()

  close: () ->
    @channel?.close()
    @channel = null
    return

  request: () ->
    asked = {}
    for net in @unheard()
      feed = net.endpoint.feed
      continue if asked[feed]
      asked[feed] = true
      @channel?.request(feed)
    return

  recv: (m) ->
    if m.op == PWR_REQUEST
      for net in @answers() when not m.name or net.endpoint.feed == m.name.toUpperCase()
        @drive(net)
      return
    if m.op == PWR_DRAW
      feed = String(m.feed ? '').toUpperCase()
      (@draws[feed] ?= {})[m.unit ? '?'] = Number(m.value ? 0)
      @putDraw(feed)
      return
    return unless m.op == PWR_VALUE
    @putFeed String(m.name ? '').toUpperCase(), Number(m.value ? 0)
    return

  wattsOn: (feed) ->
    total = 0
    total += w for _, w of (@draws[feed] ? {})
    total

  putDraw: (feed) ->
    w = @wattsOn(feed)
    for net in @reads() when net.endpoint.draw and net.endpoint.feed == feed
      @netlist.put net, w
    @netlist.settle()
    return

  putFeed: (feed, volts) ->
    for net in @reads() when not net.endpoint.draw and net.endpoint.feed == feed
      @netlist.put net, (if net.type == 'logic' then (if volts >= NOMINAL_VOLTS / 2 then 1 else 0) else volts)
    @netlist.settle()
    return

  drive: (net) ->
    feed = net.endpoint.feed
    volts = if net.type == 'logic' then (if net.value then NOMINAL_VOLTS else 0) else Number(net.value)
    @channel?.report feed, volts
    (@pending ?= new Map()).set(feed, volts)
    queueMicrotask (=> @loopback()) if @pending.size == 1
    return

  loopback: () ->
    pending = @pending
    @pending = null
    return unless pending?
    pending.forEach (volts, feed) =>
      for net in @reads() when not net.endpoint.draw and net.endpoint.feed == feed
        @netlist.put net, (if net.type == 'logic' then (if volts >= NOMINAL_VOLTS / 2 then 1 else 0) else volts)
    @netlist.settle()
    return

ADAPTERS = [PanelAdapter, MdmAdapter, DiscreteAdapter, AdcAdapter, PowerAdapter]
SCHEMES = ['panel', 'mdm', 'discrete', 'adc', 'power']

export {Adapter, PanelAdapter, MdmAdapter, DiscreteAdapter, AdcAdapter, PowerAdapter,
        ADAPTERS, SCHEMES, BindError}
