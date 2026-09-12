import {call, setTimeout, clearTimeout} from '../../com/simRuntime.coffee'
# The IDP's discrete lines
#
# `idpSel.coffee` defines the JSC-11174 drawing 8.3 keyboard-select wiring.
#
# The IDP LOAD switch on panel O6 is a momentary (USA-005350 sect.2.5.9,
# 3.7.1; USA-007587 sect.2.6 "IDP Load Switch"): taken to LOAD, the IDP
# asks the GPC assigned to it for a load, VM LOAD IN PROGRESS shows on its
# DPS display, and the GPC "sees the LOAD discrete and performs the LOAD"
# when it runs an OPS that supports one: SM OPS 2 or 4, PL OPS 9, or OPS 0
# after an IPL.
#
# Register A carries the input lines. Model-only STATUS reports load state.
# `_idpDiscretes<N>` uses the `com/discretes.coffee` message format.

import {DiscreteSpec, DiscreteChannel, DiscreteHolder, DiscreteLines, applyDiscrete, bitMask,
        SET, RESET, REQUEST, VALUE, REG_A, REG_OUT} from './../../com/discretes'
import {IDPSel} from './idpSel'

export IDP_IDS = [1, 2, 3, 4]

export IDP_BITS =
  A:
    kybdsela: 0, kybdselb: 1
    load: 2
  STATUS:
    loaded: 0, loading: 1

export IDP_DISCRETES = new DiscreteSpec
  unit: 'IDP'
  prefix: '_idpDiscretes'
  ids: IDP_IDS
  registers: {1: IDP_BITS.A, 3: IDP_BITS.STATUS}
  regNames: {3: 'STATUS'}

export REG_STATUS = REG_OUT

export LOAD_PRESS_MS = 300

export kybdSelLines = (idp, positions) -> IDPSel.discretes(idp, positions)

export defaultInputs = (idp) ->
  IDP_DISCRETES.pack REG_A, kybdselLevels(kybdSelLines(idp, IDPSel.DEFAULT))

kybdselLevels = (d) -> {kybdsela: d.A, kybdselb: d.B}

export class IDPDiscretes
  constructor: (idp, {onInput, onRequest} = {}) ->
    @idp = IDP_DISCRETES.resolveId(idp)
    @channel = new DiscreteChannel IDP_DISCRETES.busName(@idp), ((m) => @holder.recv(m)), @idp
    registers = {}
    registers[REG_A] = defaultInputs(@idp)
    registers[REG_STATUS] = bitMask(IDP_BITS.STATUS.loaded)
    @holder = new DiscreteHolder @channel,
      registers: registers
      outputs: [REG_STATUS]
      onChange: (reg, before, now) =>
        return unless reg == REG_A
        changed = ((before ^ now) >>> 0)
        for name, b of IDP_BITS.A when changed & bitMask(b)
          onInput?(b, (now & bitMask(b)) != 0)
        return

  ready: () -> @channel.ready()
  close: () -> @channel.close()

  input: (name) -> @holder.bit(REG_A, IDP_BITS.A[name])

  lines: () -> {A: @input('kybdsela'), B: @input('kybdselb')}

  setInput: (name, on_) -> @holder.setInput(REG_A, IDP_BITS.A[name], on_)

  setLoadState: (stage) ->
    loading = stage != 'complete'
    @holder.setOutput(REG_STATUS, IDP_BITS.STATUS.loading, loading)
    @holder.setOutput(REG_STATUS, IDP_BITS.STATUS.loaded, not loading)
    return

  loading: () -> @holder.bit(REG_STATUS, IDP_BITS.STATUS.loading)

export class IDPPanel
  constructor: ({onChange, ids} = {}) ->
    @ids = ids ? IDP_IDS
    @onChange = onChange
    @regs = {}
    @heard = {}
    for n in @ids
      @regs[n] = {}
      @regs[n][REG_A] = defaultInputs(n)
      @regs[n][REG_STATUS] = 0
      @heard[n] = false
    @lines_ = new DiscreteLines @ids, ((m, id) => @_hear(id, m)), IDP_DISCRETES
    @pressTimers = {}

  ready: () -> @lines_.ready()

  close: () ->
    clearTimeout(t) for own n, t of @pressTimers
    @lines_.close()

  channel: (n) -> @lines_.busses[@ids.indexOf(n)]

  query: () ->
    @lines_.request(REG_A)
    @lines_.request(REG_STATUS)
    return

  _hear: (id, m) ->
    return unless m? and m.op in [SET, RESET, VALUE] and @regs[id]?[m.reg]?
    before = @regs[id][m.reg]
    @regs[id][m.reg] = applyDiscrete(before, m)
    @heard[id] = true if m.op == VALUE
    @onChange?() if @regs[id][m.reg] != before
    return

  register: (n, reg = REG_A) -> @regs[n]?[reg] ? 0

  _drive: (n, bit, on_) ->
    @channel(n).set(REG_A, bit, on_)
    @_hear n, {op: (if on_ then SET else RESET), reg: REG_A, mask: bitMask(bit)}
    return

  lines: (n) ->
    a = @register(n)
    {A: (a & bitMask(IDP_BITS.A.kybdsela)) != 0, B: (a & bitMask(IDP_BITS.A.kybdselb)) != 0}

  loading: (n) -> (@register(n, REG_STATUS) & bitMask(IDP_BITS.STATUS.loading)) != 0

  positions: () ->
    l1 = @lines(1); l2 = @lines(2); l3 = @lines(3)
    left = if @heard[3] then (if l3.A then 3 else 1) else (if @heard[1] then (if l1.B then 1 else 3) else IDPSel.DEFAULT.left)
    right = if @heard[3] then (if l3.B then 3 else 2) else (if @heard[2] then (if l2.A then 2 else 3) else IDPSel.DEFAULT.right)
    {left, right}

  setSel: (left, right) ->
    return false unless left in IDPSel.LEFT_POSITIONS and right in IDPSel.RIGHT_POSITIONS
    for n in [1, 2, 3] when n in @ids
      d = kybdSelLines(n, {left, right})
      @_drive(n, IDP_BITS.A.kybdsela, d.A)
      @_drive(n, IDP_BITS.A.kybdselb, d.B)
    true

  toggleLeft: () ->
    p = @positions()
    @setSel (if p.left == 1 then 3 else 1), p.right

  toggleRight: () ->
    p = @positions()
    @setSel p.left, (if p.right == 2 then 3 else 2)

  pressLoad: (n, ms = LOAD_PRESS_MS) ->
    return false unless @channel(n)?
    @_drive(n, IDP_BITS.A.load, true)
    clearTimeout(@pressTimers[n]) if @pressTimers[n]?
    @pressTimers[n] = setTimeout call(@, '_releaseLoad', n), ms
    true

  _releaseLoad: (n) ->
    delete @pressTimers[n]
    @_drive(n, IDP_BITS.A.load, false)
