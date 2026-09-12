import {registerType} from '../../com/simRuntime.coffee'
import * as THREE from 'three'

# Whether a feed field still holds what it held.  A field carrying a
# structure (the ADI rate scales) compares by content.
export sameField = (a, b) ->
  return true if a == b
  return false unless a? and b? and typeof a == 'object' and typeof b == 'object'
  JSON.stringify(a) == JSON.stringify(b)


export class VertGauge
  constructor: (@x, @y, @config, @dataSrc) ->
    @value = 0
    @width = 2
    @validData = true

  build: (t) ->
    @group = new THREE.Object3D(name="vertGauge") #")
    yy = if @config.up? then @y-@config.up else @y
    @group.add t.strCtrReg @x+0.5, yy-1.25-(@config.labelUp ? 0), @config.label, t.c2h.white, 1, @config.digits
    @dyn = null
    return @group

  # Everything value/validity-dependent — digital box+text, meter frame,
  # fill — rebuilds wholesale on each draw. (The old in-place update wrote
  # to legacy Geometry fields and to LineMat uniforms that box()/str()
  # never referenced — they only read ._color at build — so the meters
  # never followed the digitals.)
  draw: (t) ->
    if not @group?
      @build(t)
    data = @dataSrc.data()
    v = data[@config.src]
    # negative value = invalid/'missing' data -> red invalid state (negatives
    # survive the param editor's JSON round-trip, unlike undefined)
    @validData = v? and v >= 0
    @value = if @validData then v else 0
    if @dyn?
      @group.remove @dyn
      @dyn.traverse (o) -> o.geometry?.dispose()
    @dyn = new THREE.Object3D()
    @_drawDigital(t)
    @_drawMeter(t)
    @group.add @dyn
    return @group

  _drawDigital: (t) ->
    width = @config.digits
    yy = if @config.up? then @y-@config.up else @y
    boxC = if @validData then t.c2h.lightGreen else t.c2h.red
    # digital box (+ its centred digits) sits ~2px low in the gauge;
    # boxDy: per-gauge extra vertical shift on top of that
    dOff = 0.11 + (@config.boxDy ? 0)
    if @config.medsFont
      @dyn.add t.box @x-0.1, yy-0.1, @x+width+.35, yy+1.55, boxC
    else
      # boxTop: shift the digital box's top edge down (bottom stays put)
      @dyn.add t.box @x-0.25, yy-0.15+dOff+(@config.boxTop ? 0), @x+width+0.25, yy+1.15+dOff, boxC
    # invalid data: meds-font gauges show the digits red, the rest blank
    return if not @validData and not @config.medsFont
    txtC = if @validData then t.c2h.white else t.c2h.red
    vStr = "0000#{Math.round(@value)}"[-@config.digits...]
    # digits glyph-bbox-centred on the digital box's centre
    if @config.medsFont
      adv = 0.9
      cx = @x + width/2 + 0.125
      cy = yy + 0.725
      @dyn.add t.str cx-(vStr.length-1)*adv/2, cy, vStr, txtC, 1.3, adv, 1.1, t.medsFont, 0, true
    else
      adv = 0.92
      cx = @x + width/2
      cy = yy + 0.5 + dOff + (@config.boxTop ? 0)/2
      @dyn.add t.str cx-(vStr.length-1)*adv/2, cy, vStr, txtC, 0.94, adv, 1.0, t.deuFont, 0, true

  _drawMeter: (t) ->
    if @config.medsFont
      mx = @x + (@config.digits / 2) - 1 + .25
      my = @y+2.0
    else
      mx = @x + (@config.digits / 2) - 1
      my = @y+1.8
    my += @config.meterDn ? 0    # meterDn: whole meter shifted down
    range = @config.range
    height = @config.height+.2
    rSize = range[1]-range[0]
    # frame (red when invalid) + right-side ticks
    @dyn.add t.box mx, my, mx+2, my+height, (if @validData then t.c2h.white else t.c2h.red)
    for tick in @config.ticks
      frac = (tick-range[0])/rSize
      mY = (my+height) - frac*height
      @dyn.add t.line [[mx+2,mY],[mx+2.95,mY]], t.c2h.white
    return unless @validData                   # invalid: meter blanked
    # value fill: frame bottom up to the value line, status-band coloured
    v = Math.max(range[0], Math.min(range[1], @value))
    yV = my + ((range[1]-v)/rSize)*height
    if yV < my+height - 0.02
      @dyn.add t.box mx, yV, mx+2, my+height, null, @_valueToColor(t, @value)

  _valueToColor: (t,v) ->
    c = t.c2h.white
    # numeric ascending — Object.keys sorts lexically ('291' before '45')
    for bp in Object.keys(@config.status).map(Number).sort((a,b) -> a-b)
      if v >= bp
        c = t.c2h[@config.status[bp]]
    return c

export class MDUScreen
  constructor: (@d) ->
    @build()

  # meds --dev: a screen with no feed starts on sample values; started
  # normally it shows every instrument's invalid indication until data
  # arrives.
  dev: () -> !!@d?.CONFIG?.dev

  setData: () ->

  draw: () ->

  build: () ->

  # Debug parameter editor hook: repaint after live curData pokes. Default
  # rebuilds the screen wholesale, refreshes any draw()-driven elements, and
  # swaps the fresh group into the scene. Screens with cheap targeted
  # redraws (AE_PFD) override this.
  refreshFeed: () ->
    old = @group
    @build()
    @draw()
    if old? and @group? and @group != old and old.parent?
      p = old.parent
      p.remove old
      p.add @group
      old.traverse (o) -> o.geometry?.dispose()
    return

  # Reference-overlay slot hooks: each overlay image shows the MEDS screen
  # in a particular configuration, so slot snapshots also capture this
  # screen's feed values (curData). Restoring a slot can then re-configure
  # the screen to match its photo — gated by the 'apply values' checkbox
  # (overlayApplyVals) in the param editor's reference-overlay group.
  ovHooks: () ->
    getData: => (try JSON.parse(JSON.stringify(@curData ? {})))
    setData: (d) =>
      Object.assign(@curData ?= {}, d)
      @refreshFeed?()


  vx: (x) -> x*(51/1152)
  vy: (y) -> y*(30/1008)

  drawHorizGauge: (value,tickLeft,tickRight,tickBot,sLen,lLen, count,top=true) ->
    group = new THREE.Object3D(name="horizGauge") #"

    if top
      sTickTop = tickBot - sLen
      lTickTop = tickBot - lLen
      tTickBot = tickBot + .5
      tTickTop = tickBot - .7
      arrowC = @d.c2h.yellow
    else
      sTickTop = tickBot + sLen
      lTickTop = tickBot + lLen
      tTickBot = tickBot - .5
      tTickTop = tickBot + .7
      arrowC = @d.c2h.cyan

    scaleLen = tickRight - tickLeft

    group.add @d.line [[tickLeft,tickBot],[tickRight,tickBot]], @d.c2h.white
    for i in [0..count]
      x = i* (scaleLen/count)
      if i%2
        x2 = sTickTop
      else
        x2 = lTickTop
      group.add @d.line [[tickLeft+x,tickBot],[tickLeft+x,x2]], @d.c2h.white

    if value?
      x = tickLeft + (value * (scaleLen/count))
      ptr = @d.tri x-.9, tTickBot, x, tTickTop, x+0.9, tTickBot, null, arrowC
      # SDF ticks are transparent-pass quads; join that pass above the line
      # cores (renderOrder 1) so the pointer always paints on top
      ptr.material.transparent = true
      ptr.material.depthTest = false
      ptr.renderOrder = 2
      group.add ptr
    return group

  drawVertGauge: (value,tickTop,tickBot,tickLeft,sLen,lLen, count,left=true) ->
    group = new THREE.Object3D(name="vertGauge") #"
    
    if left
      sTickRight = tickLeft - sLen
      lTickRight = tickLeft - lLen
      tTickLeft = tickLeft + .75
      tTickRight = tickLeft - .85
    else
      sTickRight = tickLeft + sLen
      lTickRight = tickLeft + lLen
      tTickLeft = tickLeft - .75
      tTickRight = tickLeft + .85


    scaleLen = tickBot - tickTop

    group.add @d.line [[tickLeft,tickTop],[tickLeft,tickBot]], @d.c2h.white
    for i in [0..count]
      x = i * (scaleLen/count)
      if i%2
        x2 = sTickRight
      else
        x2 = lTickRight
      group.add @d.line [[tickLeft,tickTop+x],[x2,tickTop+x]], @d.c2h.white

    if value?
      x = tickTop + (value * (scaleLen/count))
      ptr = @d.tri tTickLeft, x-.6, tTickRight, x, tTickLeft, x+0.6, null, @d.c2h.yellow
      # see drawHorizGauge: transparent + renderOrder 2 beats the SDF ticks
      ptr.material.transparent = true
      ptr.material.depthTest = false
      ptr.renderOrder = 2
      group.add ptr
    return group

registerType(VertGauge)
registerType(MDUScreen)
