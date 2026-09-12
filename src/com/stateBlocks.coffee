# Optional binary payloads for the graph codec. References stay in the graph,
# so typed views and aliases reconnect to the same restored backing storage.
import {processActors} from './simRuntime.coffee'

fs = if typeof window == 'undefined' then require('fs') else window.fs
BufferType = if typeof window == 'undefined' then Buffer else window.Buffer
zlib = if typeof window == 'undefined' then require('zlib') else window.zlib
validFile = (name) -> typeof name == 'string' and name.split('/').every (part) ->
  /^[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(part) and part != '.' and part != '..'

export class BlockWriter
  constructor: (unit, owner, @directory) ->
    @values = new WeakMap()
    @files = new Map()
    @used = new Set()
    actors = Object.entries(processActors())
    actors.push(['unit', unit]) unless actors.some(([, actor]) -> actor == unit)
    ownerActor = if typeof owner == 'object'
      owner
    else
      actors.find(([, actor]) -> actor.id == owner)?[1]
    for [key, actor] in actors
      prefix = if actor == ownerActor then '' else key.replace(/[^A-Za-z0-9_.-]/g, '_') + '/'
      for entry in actor.dstoreBlocks?() ? []
        file = prefix + entry.file
        value = entry.value
        encoding = entry.encoding ? 'bytes'
        if entry.compression != undefined and entry.compression != 'gzip'
          throw new Error('invalid block compression')
        unless validFile(file) and encoding in ['bytes', 'bits']
          throw new Error('invalid checkpoint block')
        validStorage = if encoding == 'bytes'
          value instanceof ArrayBuffer
        else
          Array.isArray(value) and not value.some((v) -> typeof v != 'boolean')
        throw new Error('invalid block storage') unless validStorage
        throw new Error('duplicate checkpoint block storage') if @values.has(value)
        length = if encoding == 'bytes' then value.byteLength else Math.ceil(value.length / 8)
        offset = entry.offset ? 0
        unless Number.isSafeInteger(offset) and offset >= 0
          throw new Error('invalid block offset')
        ref = {file, offset, length, encoding}
        ref.compression = entry.compression if entry.compression
        @values.set(value, ref)
        group = @files.get(file) ? []
        group.push({value, ref})
        @files.set(file, group)
    for group from @files.values()
      size = 0
      for {ref} in group.sort((a, b) -> a.ref.offset - b.ref.offset)
        if ref.compression != group[0].ref.compression
          throw new Error('inconsistent block compression')
        throw new Error('checkpoint blocks must be contiguous') unless ref.offset == size
        size += ref.length
      ref.fileSize = size for {ref} in group

  reference: (value) ->
    ref = @values.get(value)
    @used.add(ref.file) if ref
    ref

  flush: ->
    for file from @used
      group = @files.get(file)
      bytes = BufferType.alloc(group[0].ref.fileSize)
      for {value, ref} in group
        if ref.encoding == 'bytes'
          bytes.set(new Uint8Array(value), ref.offset)
        else
          for bit, i in value when bit
            bytes[ref.offset + (i >> 3)] |= 1 << (i & 7)
      target = @directory + '/' + file
      fs.mkdirSync(target[...target.lastIndexOf('/')], {recursive: true})
      payload = if group[0].ref.compression == 'gzip' then zlib.gzipSync(bytes) else bytes
      fs.writeFileSync(target + '.tmp', payload)
      fs.renameSync(target + '.tmp', target)
    return

export blockReader = (directory) ->
  files = new Map()
  (node) ->
    ref = node.block
    unless directory and ref and validFile(ref.file) and
        (ref.compression == undefined or ref.compression == 'gzip') and
        [ref.offset, ref.length, ref.fileSize].every((n) -> Number.isSafeInteger(n) and n >= 0) and
        ref.offset + ref.length <= ref.fileSize and
        (node.type == 'ArrayBuffer' and ref.encoding == 'bytes' or
         node.type == 'Array' and ref.encoding == 'bits' and ref.length == Math.ceil(node.length / 8))
      throw new Error('invalid checkpoint block reference')
    unless files.has(ref.file)
      bytes = fs.readFileSync(directory + '/' + ref.file)
      if ref.compression == 'gzip'
        try
          bytes = zlib.gunzipSync(bytes, {maxOutputLength: Math.max(1, ref.fileSize)})
        catch error
          throw new Error("cannot decompress checkpoint file #{ref.file}: #{error.message}")
      files.set(ref.file, {bytes, compression: ref.compression})
    cached = files.get(ref.file)
    if cached.compression != ref.compression
      throw new Error("inconsistent block compression: #{ref.file}")
    file = cached.bytes
    if file.length != ref.fileSize
      throw new Error("checkpoint file size changed: #{ref.file}")
    bytes = file.subarray(ref.offset, ref.offset + ref.length)
    if ref.encoding == 'bytes'
      bytes
    else
      Array.from({length: node.length}, (_, i) -> !!(bytes[i >> 3] & (1 << (i & 7))))
