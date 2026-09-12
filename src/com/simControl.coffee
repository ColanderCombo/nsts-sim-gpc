# Simulation component announcements; wire protocol: simMgr/controlbus.py.
# Lifecycle commands target the configured process at the master. A process
# may contain several LRU objects, each with a separate instance identity.

import {busSettings, busConfig} from './bus.civet.jsx'
import {BusTraffic} from './busTraffic'
import * as runtime from './simRuntime.coffee'
import {StateStore, saveRuntime, prepareRuntime} from './stateStore.coffee'

dgram = if typeof window != 'undefined' then window.dgram else require('dgram')
identity = if typeof window != 'undefined' then window.simIdentity else {
  pid: process.pid, env: process.env, host: require('os').hostname()
}
bufferType = if typeof window != 'undefined' then window.Buffer else Buffer
hubs = new Map()
serial = 0
MAX_DATAGRAM = 8000
MAX_MESSAGE = 262144
CHUNK_BYTES = 5600

snapshot = (value) ->
  seen = new WeakSet()
  JSON.parse JSON.stringify(value, (key, item) ->
    return undefined if typeof item == 'function'
    return String(item) if typeof item == 'bigint'
    if item? and typeof item == 'object'
      return undefined if seen.has(item)
      seen.add(item)
    item
  )

class ControlHub
  constructor: (@port, @iface) ->
    @traffic = new BusTraffic()
    @members = new Set()
    @socket = dgram.createSocket({type: 'udp4', reuseAddr: true})
    @ready = new Promise (resolve, reject) =>
      @socket.once 'error', reject
      @socket.bind @port, =>
        try
          @socket.setMulticastInterface(@iface)
          @socket.setMulticastLoopback(true)
          @socket.setMulticastTTL(1)
          @socket.addMembership('239.255.1.1', @iface)
          resolve()
        catch error
          reject(error)
    @socket.on 'error', (error) -> console.error "sim control: #{error.message}"
    @socket.on 'message', (data) =>
      @traffic.note('rx', data)
      try
        message = JSON.parse(data.toString('utf8'))
        if message?.v == 1 and message.type == 'query'
          @publish() if not message.master? or message.master == identity.env.NSTS_SIM_ID
        if message?.v == 1 and message.type == 'command' and message.master == identity.env.NSTS_SIM_ID
          member.command(message) for member from @members when member.instance == message.instance
      catch error
        return
    @socket.unref()
    @timer = setInterval((=> @publish()), 1000)
    @timer.unref?()
    @ready.catch (error) -> console.error "sim control: #{error.message}"

  publish: ->
    member.publish() for member from @members
    return

  send: (message) ->
    @ready.then =>
      data = bufferType.from(JSON.stringify(message), 'utf8')
      throw new Error('control message exceeds 262144 bytes') if data.length > MAX_MESSAGE
      packets = [data]
      if data.length > MAX_DATAGRAM
        count = Math.ceil(data.length / CHUNK_BYTES)
        packets = for index in [0...count]
          bufferType.from JSON.stringify {
            v: 1, type: 'fragment', id: "#{message.instance}:#{message.seq}",
            index, count, data: data.subarray(index * CHUNK_BYTES, (index + 1) * CHUNK_BYTES).toString('base64')
          }
      for packet in packets
        await new Promise (resolve, reject) =>
          @traffic.note('tx', packet)
          @socket.send packet, @port, '239.255.1.1', (error) ->
            if error then reject(error) else resolve()

  remove: (member) ->
    @members.delete(member)
    unless @members.size
      clearInterval(@timer)
      @socket.close()
      hubs.delete("#{@iface}:#{@port}")

export class SimControl
  constructor: (@unit) ->
    unless @unit.saveDstore?
      store = new StateStore(@unit)
      @unit.saveDstore = (directory) -> store.save(directory)
      @unit.validateDstore = (directory) -> store.validate(directory)
      @unit.restoreDstore = (directory) -> store.restore(directory)
    key = "#{busSettings.iface}:#{busSettings.basePort}"
    unless hubs.has(key)
      hubs.set(key, new ControlHub(busSettings.basePort, busSettings.iface))
    @hub = hubs.get(key)
    @ready = @hub.ready
    @instance = "#{identity.host}:#{identity.pid}:#{Date.now()}:#{serial++}"
    @seq = 0
    @closed = false
    @commands = new Map()
    @unregisterActor = runtime.registerActor(@unit.id, @unit)
    @hub.members.add(@)
    setImmediate => @publish()

  envelope: (type) ->
    {v: 1, type, master: identity.env.NSTS_SIM_ID ? null,
     key: identity.env.NSTS_SIM_LRU ? null, host: identity.host,
     launch: identity.env.NSTS_SIM_LAUNCH ? null,
     pid: identity.pid, instance: @instance, id: @unit.id, seq: ++@seq}

  publish: (state = 'running') ->
    return Promise.resolve() if @closed
    try
      buses = @unit.controlBusMap?() ? @unit.bus
      message = Object.assign @envelope('component'), {
        state
        frozen: runtime.frozen()
        capabilities: ['freeze', 'run', 'dstore', 'restore']
        checkpointVersion: 2
        error: @lastError ? null
        config: snapshot(@unit.config)
        report: snapshot(@unit.report())
        buses: (@unit.controlBuses?() ? Object.keys(@unit.bus).concat(['_simControl'])).map (name) =>
          bus = buses[name]
          bus = @unit.power?.channel?.bus ? bus if name == '_POWER'
          {name, port: @hub.port + busConfig[name].offset,
           transport: if bus?.ring? then 'shm' else 'udp',
           traffic: if name == '_simControl' then @hub.traffic.snapshot() else bus?.traffic() ? null}
      }
      @hub.send(message).catch (error) => @error(error)
    catch error
      @error(error)

  command: (message) ->
    return unless typeof message.command == 'string'
    if @commands.has(message.command)
      @hub.send(@commands.get(message.command)).catch (error) => @error(error)
      return
    status = (state, error = null) =>
      reply = Object.assign(@envelope('command_status'), {
        command: message.command, operation: message.operation, status: state, error
      })
      @commands.set(message.command, reply)
      @commands.delete(@commands.keys().next().value) if @commands.size > 1024
      @hub.send(reply).catch (error) => @error(error)
    status('received')
    Promise.resolve().then(=>
      switch message.operation
        when 'freeze' then runtime.freeze()
        when 'run' then runtime.run()
        when 'dstore'
          throw new Error('simulation must be frozen') unless runtime.frozen()
          throw new Error('LRU has no state adapter') unless @unit.saveDstore?
          await @unit.saveDstore(message.directory)
          saveRuntime(message.directory, message.snapshot, @unit)
        when 'validate', 'restore'
          throw new Error('simulation must be frozen') unless runtime.frozen()
          applyRuntime = prepareRuntime(message.directory)
          await @unit.validateDstore(message.directory)
          if message.operation == 'restore'
            await @unit.beforeRestoreDstore?()
            await @unit.restoreDstore(message.directory)
            applyRuntime()
            await @unit.afterRestoreDstore?()
        else throw new Error('unknown simulation command')
    ).then((=> status('completed')), (error) => status('failed', String(error.message ? error)))
    return

  error: (error) ->
    return Promise.resolve() if @closed
    message = Object.assign(@envelope('error'), {time: Date.now() / 1000,
      message: String(error?.stack ? error?.message ? error).slice(0, 4000)})
    @lastError = message
    @hub.send(message).catch (failure) -> console.error "sim control: #{failure.message}"

  close: ->
    return @closing if @closing?
    @closing = @publish('stopped').finally =>
      @closed = true
      @unregisterActor()
      @hub.remove(@)
    @closing

if typeof window == 'undefined'
  process.on 'uncaughtExceptionMonitor', (error) ->
    for hub from hubs.values()
      member.error(error) for member from hub.members
    return
