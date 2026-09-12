import {call, setTimeout, setInterval, clearTimeout, clearInterval, now as simNow} from '../com/simRuntime.coffee'
# Wiring simulator: loads units, attaches their bus adapters, settles the
# netlist, and publishes changed outputs. One wall-clock timer serves timed drivers.

import fs from 'fs'
import path from 'path'

import {parse, WiringError} from './wiring'
import {Netlist} from './netlist'
import {ADAPTERS, BindError} from './adapters'

WIRING_EXT = '.wir'

REASK_MS = 2000

defaultDir = () ->
  top = process.env.NSTS_TOP ? path.join(__dirname, '..', '..')
  path.join(top, 'config', 'wiring')

expand = (spec) ->
  st = null
  try
    st = fs.statSync(spec)
  catch
    throw new Error("no such wiring file '#{spec}'")
  return [spec] unless st.isDirectory()
  (path.join(spec, f) for f in fs.readdirSync(spec).sort() when f.endsWith(WIRING_EXT))

class Ratsnest
  constructor: ({log, onChange} = {}) ->
    @netlist = new Netlist()
    @adapters = []
    @units = []
    @log = log ? (->)
    @onChange = onChange ? null
    @timer = null
    @wake = null
    @asking = null


  load: (specs) ->
    files = []
    files = files.concat(expand(s)) for s in (if specs?.length then specs else [defaultDir()])
    throw new Error("no #{WIRING_EXT} files to read") unless files.length
    for file in files
      text = fs.readFileSync(file, 'utf8')
      @units = @units.concat(parse(text, file))
    @netlist.elaborate @units
    @files = files
    this


  open: () ->
    @netlist.wakeAt = (when_) => @schedule(when_)
    @netlist.onSettled = (changed) => @published(changed)
    for Klass in ADAPTERS
      a = new Klass(@netlist, (t) => @log(t))
      continue unless a.claim()
      @adapters.push a
      a.open()
    @asking = setInterval call(@, 'reask'), REASK_MS
    @asking.unref?()
    this

  reask: () ->
    unless @waiting().length
      clearInterval(@asking) if @asking?
      @asking = null
      return
    a.request() for a in @adapters
    return

  ready: () -> Promise.all(a.ready() for a in @adapters)

  start: () ->
    @netlist.settleAll()
    @publish()
    this

  close: () ->
    clearTimeout(@timer) if @timer?
    clearInterval(@asking) if @asking?
    @timer = null
    @asking = null
    a.close() for a in @adapters
    @adapters = []
    return

  published: (changed) ->
    @publish()
    @onChange?(changed)
    return

  publish: () ->
    for _, net of @netlist.nets
      continue unless net.port?.dir in ['out', 'inout'] and net.adapter?
      continue unless net.driver?.ready()
      continue if net.sent? and net.sent == net.value
      net.sent = net.value
      net.adapter.drive net
    return

  waiting: () ->
    (n for _, n of @netlist.nets when n.port?.dir in ['in', 'inout'] and not n.heard)

  schedule: (when_) ->
    return unless when_?
    return if @wake? and @wake <= when_ and @timer?
    clearTimeout(@timer) if @timer?
    @wake = when_
    delay = Math.max(1, when_ - @netlist.now())
    @timer = setTimeout call(@, 'fire'), delay
    @timer.unref?()
    return

  fire: () ->
    @timer = null
    @wake = null
    @netlist.dirty.add d for d in @netlist.timed()
    try
      @netlist.settle()
    catch e
      @log "ratsnest: #{e.message}"
    return


  table: () ->
    rows = []
    for _, net of @netlist.nets
      rows.push {
        name: net.qualified()
        type: @netlist.show(net.type)
        dir: net.port?.dir ? 'signal'
        bind: if net.port? then "#{net.port.bind.scheme} #{net.port.bind.addr}" else ''
        driven: net.driver?
        line: net.line
        file: net.file
        net: net
      }
    rows.sort (a, b) -> (if a.name < b.name then -1 else if a.name > b.name then 1 else 0)
    rows

  fmtValue: (net) ->
    switch net.type
      when 'logic' then (if net.value then "'1'" else "'0'")
      when 'real' then Number(net.value).toPrecision(4)
      when 'word' then "0x#{(net.value & 0xffff).toString(16).padStart(4, '0')}"
      when 'integer' then String(net.value)
      else String(net.value)

export {Ratsnest, WiringError, BindError, expand, defaultDir, WIRING_EXT}
