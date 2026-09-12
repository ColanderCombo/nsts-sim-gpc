# Simulation work uses this clock and these timers. Control/discovery uses
# native timers so a frozen process can still acknowledge commands.
nativeSetTimeout = globalThis.setTimeout.bind(globalThis)
nativeClearTimeout = globalThis.clearTimeout.bind(globalThis)
nativeSetImmediate = globalThis.setImmediate?.bind(globalThis)
nativeClearImmediate = globalThis.clearImmediate?.bind(globalThis)
cancel = (timer) ->
  if timer.immediate
    nativeClearImmediate?(timer.native)
  else
    nativeClearTimeout(timer.native)
wall = -> Date.now()
microWall = ->
  if typeof process != 'undefined' and process.hrtime?.bigint
    process.hrtime.bigint() / 1000n
  else
    BigInt(Math.round(performance.now() * 1000))

microOffset = 0n
heldMicro = null
export nowMicros = -> (heldMicro ? microWall()) - microOffset

offset = 0
heldAt = null
nextId = 1
frozenKeepAlive = null

keepFrozenAlive = ->
  if heldAt != null and actors.size and not frozenKeepAlive
    frozenKeepAlive = globalThis.setInterval((->), 60000)
  if (heldAt == null or not actors.size) and frozenKeepAlive
    globalThis.clearInterval(frozenKeepAlive)
    frozenKeepAlive = null
  return

timers = new Map()
deferred = []
actors = new Map()
externals = new Map()
externalNames = new WeakMap()
CALL = Symbol('simulation call')

export call = (target, method, args...) -> callRef(target, method, args)

export callRef = (target, method, args) ->
  unless target and typeof target[method] == 'function'
    throw new Error("unknown simulation operation #{method}")
  fn = (tail...) -> target[method](args..., tail...)
  fn[CALL] = {target, method, args}
  fn

export callSpec = (fn) -> fn?[CALL]

freeName = (table, name) ->
  n = 0
  n++ while table.has("#{name}:#{n}")
  "#{name}:#{n}"

export registerActor = (name, actor) ->
  key = freeName(actors, name)
  actors.set(key, actor)
  keepFrozenAlive()
  ->
    actors.delete(key)
    keepFrozenAlive()

export processActors = -> Object.fromEntries(actors)

export registerExternal = (name, value) ->
  key = freeName(externals, name)
  externals.set(key, value)
  externalNames.set(value, key)
  ->
    externals.delete(key)
    externalNames.delete(value)

export externalName = (value) ->
  if value and typeof value in ['object', 'function']
    externalNames.get(value)
  else
    undefined

export externalObject = (key) ->
  throw new Error("missing checkpoint endpoint #{key}") unless externals.has(key)
  externals.get(key)

export frozen = -> heldAt != null
export now = -> (heldAt ? wall()) - offset
export pausedMs = -> offset + if heldAt == null then 0 else wall() - heldAt

export freeze = ->
  return if frozen()
  heldAt = wall()
  heldMicro = microWall()
  keepFrozenAlive()
  cancel(timer) for timer from timers.values()
  return

export run = ->
  return unless frozen()
  offset += wall() - heldAt
  microOffset += microWall() - heldMicro
  heldMicro = null
  heldAt = null
  keepFrozenAlive()
  arm(timer) for timer from timers.values()
  work = deferred.splice(0)
  fn() for fn in work
  return

export dispatch = (fn) ->
  if frozen() then deferred.push(fn) else fn()
  return

arm = (timer) ->
  return if frozen()
  fire = ->
    return if frozen() or not timers.has(timer.id)
    if timer.interval == null
      timers.delete(timer.id)
    else
      timer.due = now() + timer.interval
    timer.fn(timer.args...)
    arm(timer) if timer.interval != null and timers.has(timer.id)
    return
  timer.native = if timer.immediate and nativeSetImmediate
    nativeSetImmediate(fire)
  else
    nativeSetTimeout(fire, Math.max(0, timer.due - now()))
  timer.native.unref?() if timer.unreferenced
  return

schedule = (fn, ms, args, interval, immediate = false) ->
  timer =
    id: nextId++
    fn: fn
    args: args
    immediate: immediate
    due: now() + Math.max(0, Number(ms) or 0)
    interval: interval
    unref: ->
      @unreferenced = true
      @native?.unref?()
      this
  timers.set(timer.id, timer)
  arm(timer)
  timerById(timer.id)

export setTimeout = (fn, ms = 0, args...) -> schedule(fn, ms, args, null)
export setInterval = (fn, ms = 0, args...) -> schedule(fn, ms, args, Math.max(1, Number(ms) or 0))
export setImmediate = (fn, args...) -> schedule(fn, 0, args, null, !!nativeSetImmediate)

export clearTimeout = (timer) ->
  return unless timer
  cancel(timers.get(timer.id) ? timer)
  timers.delete(timer.id)
  return

export clearInterval = clearTimeout
export clearImmediate = clearTimeout

# Checkpoints contain registered calls and data.
export checkpoint = (id = null) ->
  throw new Error('simulation must be frozen') unless frozen()
  # Drain shared transports into durable deferred deliveries before the cut.
  endpoint.prepareCheckpoint?() for endpoint from externals.values()
  for timer from timers.values()
    unless callSpec(timer.fn)
      throw new Error('pending anonymous timer')
  if deferred.some((fn) -> not callSpec(fn))
    throw new Error('pending anonymous simulation work')
  version: 2
  id: id
  time: now()
  microTime: nowMicros().toString()
  nextId: nextId
  timers: for t from timers.values()
    {id: t.id, fn: t.fn, args: t.args, due: t.due, interval: t.interval,
      immediate: t.immediate, unreferenced: !!t.unreferenced}
  work: deferred.slice()
  endpoints: for [key, value] from externals when value.checkpointTransport
    {key, state: value.checkpointTransport()}

export validateCheckpoint = (data) ->
  unless data and data.version == 2 and Number.isFinite(data.time) and
      Array.isArray(data.timers) and Array.isArray(data.work)
    throw new Error('unsupported runtime checkpoint')
  unless typeof data.microTime == 'string' and /^-?\d+$/.test(data.microTime)
    throw new Error('invalid saved microsecond clock')
  ids = new Set()
  for timer in data.timers
    unless Number.isSafeInteger(timer.id) and timer.id >= 1 and not ids.has(timer.id) and
        Number.isFinite(timer.due) and
        (timer.interval == null or Number.isFinite(timer.interval) and timer.interval >= 1) and
        Array.isArray(timer.args) and callSpec(timer.fn)
      throw new Error('invalid saved timer')
    ids.add(timer.id)
  unless Number.isSafeInteger(data.nextId) and data.nextId > Math.max(0, ids...)
    throw new Error('invalid timer sequence')
  throw new Error('invalid queued operation') if data.work.some((fn) -> not callSpec(fn))
  throw new Error('invalid checkpoint endpoints') unless Array.isArray(data.endpoints)
  for entry in data.endpoints
    endpoint = externalObject(entry.key)
    unless endpoint.restoreTransport and Array.isArray(entry.state)
      throw new Error('incompatible checkpoint endpoint')
  return

export restoreCheckpoint = (data) ->
  throw new Error('simulation must be frozen') unless frozen()
  validateCheckpoint(data)
  cancel(timer) for timer from timers.values()
  timers.clear()
  offset = heldAt - data.time
  microOffset = heldMicro - BigInt(data.microTime)
  nextId = data.nextId
  timers.set(timer.id, {...timer}) for timer in data.timers
  deferred.splice(0, deferred.length, data.work...)
  externalObject(entry.key).restoreTransport(entry.state) for entry in data.endpoints
  return

export timerId = (value) ->
  if value and typeof value == 'object' and value.simTimer == true then value.id else null

export timerById = (id) ->
  id: id
  simTimer: true
  unref: ->
    timer = timers.get(id)
    if timer
      timer.unreferenced = true
      timer.native?.unref?()
    this

# Hardware controls in an Electron renderer cannot mutate the model while
# frozen. Rendering and the manager's independent control socket remain live.
if typeof document != 'undefined' and document.addEventListener
  for name in ['click', 'dblclick', 'mousedown', 'mouseup', 'keydown', 'keyup', 'input', 'change']
    document.addEventListener name, ((event) ->
      if frozen()
        event.preventDefault()
        event.stopImmediatePropagation()
    ), true

types = new Map()
factories = new Map()

export registerType = (Type, factory) ->
  types.set(Type.name, Type.prototype)
  factories.set(Type.name, factory) if factory
  return

export stateFactory = (name) -> factories.get(name)
export stateTypes = -> new Map(types)
