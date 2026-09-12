# Data-only graph codec. Preserve aliases, typed storage and class instances;
# host resources bind to the current launch; named calls retain saved arguments.
import {
  timerId, timerById, callRef, callSpec, externalName, externalObject,
  processActors, checkpoint, validateCheckpoint, restoreCheckpoint,
  stateTypes, stateFactory
} from './simRuntime.coffee'
import {BlockWriter, blockReader} from './stateBlocks.coffee'

fs = if typeof window == 'undefined' then require('fs') else window.fs
resources = new Set([
  'Bus', 'SimControl', 'StateStore', 'ControlHub', 'Barrier',
  'Socket', 'Server', 'Promise', 'WeakMap', 'WeakSet', 'BusTraffic',
  'WebGLRenderer', 'WebGLRenderTarget', 'WebGLRenderingContext',
  'WebGL2RenderingContext'
])
unsafe = new Set(['__proto__', 'prototype', 'constructor'])
skipped = (value) ->
  typeof value == 'function' or
    (value and resources.has(value.constructor?.name?.replace(/\d+$/, ''))) or
    (typeof Node != 'undefined' and value instanceof Node)
transient = (value, key) -> key == '_listeners' and
  (value.isObject3D or value.isMaterial or value.isBufferGeometry or value.isTexture)
bytes = (value) -> Array.from(new Uint8Array(value))

export class StateStore
  constructor: (@unit) ->
    @fields = []

  mark: (kind, fields, target = @unit) ->
    throw new Error('expected config or state') unless kind in ['config', 'state']
    unless Array.isArray(fields) and not fields.some((name) -> typeof name != 'string')
      throw new Error('fields must be an array of names')
    for name in fields
      if @fields.some((field) -> field.kind == kind and field.name == name)
        throw new Error("duplicate #{kind} field #{name}")
      throw new Error('invalid field name') if unsafe.has(name)
      @fields.push({kind, name, target})
    return

  roots: ->
    if @fields.length
      result = {config: {}, state: {}}
      result[kind][name] = target[name] for {kind, name, target} in @fields
      result
    else
      {config: @unit.config, state: @unit}

  fieldData: ->
    roots = @roots()
    # Explicit fields are ordinary JSON, with no executable or host values.
    seen = new Set()
    check = (value) ->
      return if value == null or typeof value in ['string', 'boolean']
      return if typeof value == 'number' and Number.isFinite(value)
      if not value or typeof value != 'object' or seen.has(value) or
          (not Array.isArray(value) and Object.getPrototypeOf(value) != Object.prototype)
        throw new Error('marked field is not JSON data')
      seen.add(value)
      for [key, child] from Object.entries(value)
        throw new Error('unsafe state field') if unsafe.has(key)
        check(child)
      seen.delete(value)
      return
    check(roots)
    {version: 1, lru: @unit.id, format: 'fields', roots...}

  prepareFields: (data) ->
    unless data.version == 1 and data.lru == @unit.id and @fields.length
      throw new Error('incompatible LRU fields')
    updates = @fields.map ({kind, name, target}) ->
      unless data[kind] and Object.hasOwn(data[kind], name)
        throw new Error("missing #{kind} field #{name}")
      {target, name, value: data[kind][name]}
    merge = (target, source) ->
      return source unless source and typeof source == 'object'
      unless target and typeof target == 'object' and Array.isArray(target) == Array.isArray(source)
        target = if Array.isArray(source) then [] else {}
      delete target[key] for key from Object.keys(target) when not Object.hasOwn(source, key)
      target.length = source.length if Array.isArray(source)
      target[key] = merge(target[key], value) for [key, value] from Object.entries(source)
      target
    check = (value) ->
      if value and typeof value == 'object'
        for [key, child] from Object.entries(value)
          throw new Error('unsafe state field') if unsafe.has(key)
          check(child)
      return
    check(value) for {value} in updates
    ->
      target[name] = merge(target[name], value) for {target, name, value} in updates
      return

  encode: (roots = @roots(), directory = null, owner = @unit) ->
    blocks = if directory then new BlockWriter(@unit, owner, directory) else null
    nodes = []
    seen = new Map()
    visit = (value) ->
      external = externalName(value)
      return {external} if external
      spec = callSpec(value)
      if spec
        return {call: {target: visit(spec.target), method: spec.method, args: visit(spec.args)}}
      throw new Error('unregistered saved callback') if typeof value == 'function'
      return {special: 'undefined'} if value == undefined
      return {bigint: String(value)} if typeof value == 'bigint'
      return {number: String(value)} if typeof value == 'number' and not Number.isFinite(value)
      return value if value == null or typeof value != 'object'
      timer = timerId(value)
      return {timer} if timer != null
      return {ref: seen.get(value)} if seen.has(value)
      id = nodes.length
      seen.set(value, id)
      node = {type: value.constructor?.name ? 'Object'}
      nodes.push(node)

      block = blocks?.reference(value)
      if block
        node.block = block
        node.length = value.length if Array.isArray(value)
      else if value instanceof ArrayBuffer
        node.bytes = bytes(value)
      else if ArrayBuffer.isView(value)
        node.buffer = visit(value.buffer)
        node.offset = value.byteOffset
        node.length = value.byteLength
      else if value instanceof Map
        node.entries = ([visit(key), visit(item)] for [key, item] from value)
      else if value instanceof Set
        node.entries = (visit(item) for item from value)
      else if value instanceof Date
        node.value = value.toISOString()
      else
        node.props = {}
        node.omitted = []
        node.length = value.length if Array.isArray(value)
        for key from Object.keys(value)
          continue if transient(value, key)
          throw new Error("unsafe field #{key}") if unsafe.has(key)
          if skipped(value[key]) and not callSpec(value[key]) and not externalName(value[key])
            node.omitted.push(key)
            continue
          node.props[key] = visit(value[key])
      {ref: id}
    root = visit(roots)
    blocks?.flush()
    {version: (if blocks?.used.size then 3 else 2), lru: @unit.id, root, nodes}

  prepare: (data, roots = @roots(), directory = null) ->
    readBlock = blockReader(directory)
    blockData = new Map()
    return @prepareFields(data) if data.format == 'fields'
    unless data.version in [2, 3] and data.lru == @unit.id and Array.isArray(data.nodes)
      throw new Error('incompatible LRU state')
    for node in data.nodes
      unless node and typeof node.type == 'string'
        throw new Error('invalid state node')
      if node.block
        throw new Error('invalid checkpoint block version') unless data.version == 3
        blockData.set(node, readBlock(node))
      if node.props and (not Array.isArray(node.omitted) or typeof node.props != 'object')
        throw new Error('invalid state properties')
      if node.bytes and (not Array.isArray(node.bytes) or
          node.bytes.some((v) -> not Number.isInteger(v) or v < 0 or v > 255))
        throw new Error('invalid storage bytes')
      if node.type == 'Array' and (not Number.isInteger(node.length) or node.length < 0)
        throw new Error('invalid array size')

    # Match nodes to existing objects before allocating, keeping references
    # held by CPU register views and timer callbacks intact.
    objects = new Map()
    claimed = new WeakMap()
    prototypes = stateTypes()
    scanned = new Set()
    scan = (value) ->
      return unless value and typeof value == 'object' and not scanned.has(value) and not skipped(value)
      scanned.add(value)
      prototypes.set(value.constructor?.name ? 'Object', Object.getPrototypeOf(value))
      return if ArrayBuffer.isView(value) or value instanceof ArrayBuffer
      children = if value instanceof Map then [...value.values()] else Object.values(value)
      scan(child) for child in children
      return
    scan(roots)

    match = (ref, value) ->
      return unless ref and typeof ref == 'object' and 'ref' of ref and not objects.has(ref.ref)
      matchNode = data.nodes[ref.ref]
      throw new Error('invalid state reference') unless matchNode
      return unless value and typeof value == 'object' and
        (value.constructor?.name ? 'Object') == matchNode.type
      # Storage can change shape as a display rebuilds. Reuse only compatible
      # views and buffers; otherwise allocate the saved layout and reconnect it.
      return if claimed.has(value) and claimed.get(value) != ref.ref
      if matchNode.type == 'ArrayBuffer' and value.byteLength !=
          (if matchNode.block then matchNode.block.length else matchNode.bytes.length)
        return
      if matchNode.buffer
        return if value.byteOffset != matchNode.offset or value.byteLength != matchNode.length
        match(matchNode.buffer, value.buffer)
        return if objects.get(matchNode.buffer.ref) != value.buffer
      objects.set(ref.ref, value)
      claimed.set(value, ref.ref)
      match(child, value[key]) for [key, child] from Object.entries(matchNode.props) if matchNode.props
      match(matchNode.buffer, value.buffer) if matchNode.buffer
      if matchNode.entries and value instanceof Map
        for [key, child] in matchNode.entries when typeof key != 'object'
          match(child, value.get(key))
      return
    match(data.root, roots)

    existing = new Set(objects.values())
    get = (ref) ->
      return ref unless ref and typeof ref == 'object'
      return externalObject(ref.external) if 'external' of ref
      if 'call' of ref
        {target, method, args} = ref.call
        # Arguments are populated by the graph pass before invocation.
        receiver = get(target)
        argv = get(args)
        unless receiver and typeof receiver[method] == 'function' and Array.isArray(argv)
          throw new Error("missing saved operation #{method}")
        return callRef(receiver, method, argv)
      return undefined if ref.special == 'undefined'
      return BigInt(ref.bigint) if 'bigint' of ref
      return Number(ref.number) if 'number' of ref
      return timerById(ref.timer) if 'timer' of ref
      unless Number.isInteger(ref.ref) and data.nodes[ref.ref]
        throw new Error('invalid state reference')
      return objects.get(ref.ref) if objects.has(ref.ref)
      getNode = data.nodes[ref.ref]
      if getNode.type == 'ArrayBuffer'
        obj = new ArrayBuffer(if getNode.block then getNode.block.length else getNode.bytes.length)
      else if getNode.buffer
        buffer = get(getNode.buffer)
        if getNode.type == 'Buffer'
          obj = Buffer.from(buffer, getNode.offset, getNode.length)
        else if getNode.type == 'DataView'
          obj = new DataView(buffer, getNode.offset, getNode.length)
        else
          Type = globalThis[getNode.type]
          throw new Error('unknown typed storage') unless Type?.BYTES_PER_ELEMENT
          obj = new Type(buffer, getNode.offset, getNode.length / Type.BYTES_PER_ELEMENT)
      else if getNode.type == 'Map'
        obj = new Map()
      else if getNode.type == 'Set'
        obj = new Set()
      else if getNode.type == 'Date'
        obj = new Date(getNode.value)
      else if getNode.type == 'Array'
        obj = []
      else if getNode.type == 'Object'
        obj = {}
      else
        unless prototypes.has(getNode.type)
          throw new Error("missing state adapter for #{getNode.type}")
        obj = stateFactory(getNode.type)?() ? Object.create(prototypes.get(getNode.type))
        # Constructors rebuild host callbacks (e.g. quaternion/rotation links).
        # Match their child objects before loading saved values into them.
        match(ref, obj)
      objects.set(ref.ref, obj)
      obj

    actions = []
    plan = (obj, action) -> if existing.has(obj) then actions.push(action) else action()
    prepareNode = (savedNode, i) ->
      obj = get({ref: i})
      if savedNode.block
        source = blockData.get(savedNode)
        if savedNode.type == 'ArrayBuffer'
          plan(obj, -> new Uint8Array(obj).set(source))
        else
          plan obj, ->
            obj.length = source.length
            obj[j] = source[j] for j in [0...source.length]
            return
      else if savedNode.type == 'Date'
        time = Date.parse(savedNode.value)
        throw new Error('invalid saved date') unless Number.isFinite(time)
        plan(obj, -> obj.setTime(time))
      else if savedNode.bytes
        throw new Error('storage size changed') unless obj.byteLength == savedNode.bytes.length
        source = Uint8Array.from(savedNode.bytes)
        plan(obj, -> new Uint8Array(obj).set(source))
      else if savedNode.entries
        entries = if savedNode.type == 'Map'
          ([get(key), get(value)] for [key, value] in savedNode.entries)
        else
          (get(value) for value in savedNode.entries)
        plan obj, ->
          obj.clear()
          for entry in entries
            if savedNode.type == 'Map' then obj.set(entry...) else obj.add(entry)
          return
      else if savedNode.props
        if savedNode.omitted.some((key) -> not (key of obj))
          missing = savedNode.omitted.filter((key) -> not (key of obj)).join(', ')
          throw new Error("missing #{savedNode.type} checkpoint resources: #{missing}")
        entries = Object.entries(savedNode.props).map ([key, value]) ->
          throw new Error('unsafe state field') if unsafe.has(key)
          descriptor = Object.getOwnPropertyDescriptor(obj, key)
          if descriptor and not descriptor.writable and not descriptor.set and obj[key] != get(value)
            throw new Error("read-only state field #{key}")
          [key, get(value)]
        plan obj, ->
          for key from Object.keys(obj)
            if not (key of savedNode.props) and key not in savedNode.omitted and
                not skipped(obj[key]) and not transient(obj, key)
              delete obj[key]
          obj.length = savedNode.length if savedNode.type == 'Array'
          obj[key] = value for [key, value] in entries when obj[key] != value
          return
      return
    prepareNode(savedNode, i) for savedNode, i in data.nodes

    apply = =>
      action() for action in actions
      restoredRoots = get(data.root)
      target[name] = restoredRoots[kind][name] for {kind, name, target} in @fields
      restoredRoots
    rootNode = data.nodes[data.root.ref]
    apply.value = Object.fromEntries(
      Object.entries(rootNode.props).map(([key, value]) -> [key, get(value)])
    )
    apply

  save: (directory) ->
    data = if @fields.length then @fieldData() else @encode(@roots(), directory)
    @prepare(data, @roots(), directory)
    fs.mkdirSync(directory, {recursive: true})
    fs.writeFileSync("#{directory}/state.json.tmp", JSON.stringify(data, null, 2) + '\n')
    fs.renameSync("#{directory}/state.json.tmp", "#{directory}/state.json")
    return

  validate: (directory) ->
    @prepare(JSON.parse(fs.readFileSync("#{directory}/state.json", 'utf8')), @roots(), directory)
    return

  restore: (directory) ->
    @prepare(JSON.parse(fs.readFileSync("#{directory}/state.json", 'utf8')), @roots(), directory)()
    return

processStore = -> new StateStore({id: '_runtime'})
processRoots = -> {actors: processActors()}

export saveRuntime = (directory, id, unit = null) ->
  store = processStore()
  owner = unit ? JSON.parse(fs.readFileSync("#{directory}/state.json", 'utf8')).lru
  data = store.encode({processRoots()..., runtime: checkpoint(id)}, directory, owner)
  fs.writeFileSync("#{directory}/runtime.json.tmp", JSON.stringify(data, null, 2) + '\n')
  fs.renameSync("#{directory}/runtime.json.tmp", "#{directory}/runtime.json")
  return

export prepareRuntime = (directory) ->
  data = JSON.parse(fs.readFileSync("#{directory}/runtime.json", 'utf8'))
  apply = processStore().prepare(data, processRoots(), directory)
  validateCheckpoint(apply.value.runtime)
  ->
    saved = apply()
    restoreCheckpoint(saved.runtime)
    return
