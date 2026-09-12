import * as THREE from 'three'

import {MDUScreen} from 'meds/mduScreen'

export class Screen_SPI extends MDUScreen
  setData: (@curData) ->
    if not @curData?
      @curData = {
        elevonDeg_LL: -25
        elevonDeg_LR: -30
        elevonDeg_RL: -20
        elevonDeg_RR: -15
        bodyFlapPc: 20
        rudderDeg: -10
        aileronDeg: -1
        speedbrakePc_ACT: 30
        speedbrakePc_CMD: 40
      }
    @draw()

  data: () ->
    return @curData

  build: () ->
    @setData(@curData)   # preserve live edits across editor-driven rebuilds
    @bg = new THREE.Object3D()
    labels = [
      [3,2.5,"ELEVONS"],[5,3.5,"DEG"],
      [14.65,2.5,"BODY FLAP"],[18.65,3.5,"%"],
      [33.75,2.90,"RUDDER-DEG"],
      [33.75,10.9,"AILERON-DEG"],
      [32.32,18.1,"SPEEDBRAKE  %"],
      [26.85,4.60,"30"],
      [30.75,4.60,"20"],
      [34.5,4.60,"10"],
      # [39,4.60,"0", @d.c2h.yellow],
      [39,4.60,"0", @d.c2h.yellow],
      [42,4.60,"10"],
      [46,4.60,"20"],
      [49.75,4.60,"30"],

      [6.9,8.27,"-30"],
      [6.9,11.11,"-20"],
      [6.9,14.21,"-10"],
      # [8.3,17.15,"0", @d.c2h.yellow],
      [8.3,17.15,"0", @d.c2h.yellow],
      [6.9,19.84,"+10"],
      [6.9,22.67,"+20"],

      [23.10,7.14,"0"],
      [23.10,10.34,"20"],
      [23.10,13.43,"40"],
      [23.10,16.79,"60"],
      [23.10,19.89,"80"],
      [23.10,22.98,"100"]

      [26.9, 8.46, "L RUD", @d.c2h.green],
      [47.25, 8.46, "R RUD", @d.c2h.green],
      [26.9, 15.6, "L AIL", @d.c2h.green],
      [47.25, 15.6, "R AIL", @d.c2h.green]

      [ 27.5, 11.9, "5"],
      [ 38.95, 11.9, "0", @d.c2h.yellow],
      [ 50.25, 11.9, "5"],

      [ 27.57, 20.9, "0"],
      [ 31.57, 20.9, "20"],
      [ 36.07, 20.9, "40"],
      [ 40.57, 20.9, "60"],
      [ 45.07, 20.9, "80"],
      [ 49.32, 20.9, "100"],
      [ 36.17, 19.25, "ACTUAL", @d.c2h.yellow],
      [ 36.47, 26.46, "COMMAND", @d.c2h.cyan],
      [ 7.75, 4.25, "  TE UP", @d.c2h.green],
      [ 7.65, 25.64, "  TE DN", @d.c2h.green]
      # [ 47.75, 18.75, "030", @d.c2h.yellow],
      # [ 47.75, 25.75,"040", @d.c2h.cyan]
    ]

    for label in labels
      if label[3]?
        m = label[3]
      else
        m = @d.c2h.white
      @bg.add @d.str label[0], label[1], label[2], m,scale=0.96,advance=1.01,scalex=1.111

    lines = [
      [[0.5,6], [0.5,4.75], [8,4.75]],
      [[16.5,4.75],[24,4.75],[24,6]],
      [[0.55,24.66], [0.5,25.91], [8,25.91]],
      [[16.5,25.91],[24,25.91],[24,24.66]]
    ]
    for line in lines
      @bg.add @d.line line, @d.c2h.green

    grayBar = @d.c2h.darkGray

    @bg.add @d.box 47.17, 19.1, 50.67, 20.15, @d.c2h.white
    @bg.add @d.box 47.17, 26.1, 50.67, 27.15, @d.c2h.white

    # Elevons Deg L
    if @data().elevonDeg_LL?
      ellVal = (@data().elevonDeg_LL + 35) / (55/11)
    if @data().elevonDeg_LR?
      elrVal = (@data().elevonDeg_LR + 35) / (55/11)
    @bg.add @drawVertGauge ellVal, 7.6, 23.5, 3.75, 1.25, .75, 11
    @bg.add @d.box  4.05, 7.2, 5.45,24.0, null, grayBar
    @bg.add @drawVertGauge elrVal, 7.6, 23.5, 5.75, 1.25, .75, 11, left=false

    # Elevons Deg R
    if @data().elevonDeg_RL?
      erlVal = (@data().elevonDeg_RL + 35) / (55/11)
    if @data().elevonDeg_RR?
      errVal = (@data().elevonDeg_RR + 35) / (55/11)
    @bg.add @drawVertGauge erlVal, 7.6, 23.5, 12, 1.25, .75, 11
    @bg.add @d.box 12.25, 7.2,13.75,24.0, null, grayBar
    @bg.add @drawVertGauge errVal, 7.6, 23.5, 14, 1.25, .75, 11, left=false

    # Body Flap %
    if @data().bodyFlapPc?
      bfpVal = (@data().bodyFlapPc) / (100/10)
    @bg.add @d.box 19.5, 7.2,20.75,24.0, null, grayBar
    @bg.add @drawVertGauge bfpVal,7.6, 23.5, 21.10, .75, 1.25, 10, left=false
    @bg.add @flpPointer 21.9,12.85,@d.c2h.yellow

    # Rudder-Deg
    if @data().rudderDeg?
      rdVal = (@data().rudderDeg + 30) / (60/12)
    @bg.add @drawHorizGauge rdVal, 28.30, 50.95, 6.5, .55, .9, 12
    @bg.add @d.box 27.45,6.7,51.75,7.6,null,grayBar

    # Aileron-Deg
    if @data().aileronDeg?
      alVal = (@data().aileronDeg + 5) / (10/20)
    @bg.add @drawHorizGauge alVal, 28.30, 50.95, 13.75, .6, .85, 20
    @bg.add @d.box 27.45,13.95, 51.75, 14.85, null, grayBar

    # Speedbrake %
    if @data().speedbrakePc_ACT?
      spaVal = (@data().speedbrakePc_ACT) / (100/10)
    if @data().speedbrakePc_CMD?
      spcVal = (@data().speedbrakePc_CMD) / (100/10)
    @bg.add @drawHorizGauge spaVal, 28.37, 51.02, 22.75, .55, .9, 10
    @bg.add @d.box 27.52,22.95, 51.82, 23.8, null,grayBar
    @bg.add @drawHorizGauge spcVal, 28.37, 51.02, 24.05, .55, .9, 10, false

    @bg.add @d.str 47.32,19.15, "00#{@data().speedbrakePc_ACT}".slice(-3), @d.c2h.yellow, scale=0.96,advance=1.01,scalex=1.111
    @bg.add @d.str 47.32,26.15, "00#{@data().speedbrakePc_CMD}".slice(-3), @d.c2h.cyan, scale=0.96,advance=1.01,scalex=1.111

    @group = new THREE.Object3D()
    @group.add @bg

  flpPointer: (x,y,color) ->
    fill = new THREE.MeshBasicMaterial({color: color, side: THREE.DoubleSide})
    dl = new THREE.BufferGeometry()
    vertices = new Float32Array([
      x, y, 1,
      x+1, y+0.37, 1,
      x+1.85, y+0.37, 1,
      x+1.85, y-0.37, 1,
      x+1, y-0.37, 1,
    ])
    dl.setAttribute( 'position', new THREE.BufferAttribute( vertices, 3 ) );
    dl.setIndex([0,1,4, 1,2,3, 3,1,4]);
    fill.transparent = true
    fill.depthTest = false
    m = new THREE.Mesh(dl,fill)
    m.renderOrder = 2      # above the SDF tick strokes (cores at 1)
    return m

  # live-feed indicator test
  #
  # Driven by the 'SPI sweep test' checkbox in the debug parameter editor
  # (dbl-click outside the canvas). Sweeps every surface through its full
  # range as a triangle wave; each channel gets its own period so the
  # arrows move visibly out of phase. Statics are restored on exit.
  ST_TICK = 100          # ms; refreshFeed() is a full rebuild, keep modest
  ST_SWEEPS = [
    # [field,             min, max, period s]
    ['elevonDeg_LL',      -35,  20,  8]
    ['elevonDeg_LR',      -35,  20,  9]
    ['elevonDeg_RL',      -35,  20, 10]
    ['elevonDeg_RR',      -35,  20, 11]
    ['bodyFlapPc',          0, 100, 12]
    ['rudderDeg',         -30,  30,  7]
    ['aileronDeg',         -5,   5,  6]
    ['speedbrakePc_ACT',    0, 100, 13]
    ['speedbrakePc_CMD',    0, 100, 15]
  ]

  enterSweepTest: () ->
    return if @_stTimer?
    @_st0 = Object.assign({}, @curData)    # restore the statics on exit
    @_stT0 = Date.now()
    @_stTimer = window.setInterval((=> @tickSweepTest()), ST_TICK)
    @tickSweepTest()
    console.log "SPI sweep test ON"

  exitSweepTest: () ->
    return if not @_stTimer?
    window.clearInterval(@_stTimer)
    @_stTimer = null
    Object.assign(@curData, @_st0) if @_st0?
    @_st0 = null
    @refreshFeed()
    console.log "SPI sweep test OFF"

  tickSweepTest: () ->
    t = (Date.now() - @_stT0) / 1000
    for [k, lo, hi, period] in ST_SWEEPS
      ph = (t % period) / period
      tri = if ph < 0.5 then 2*ph else 2 - 2*ph        # 0..1..0
      @curData[k] = Math.round(lo + tri*(hi - lo))
    @refreshFeed()

  # descriptors for the parameter editor's test-control section
  testControls: () ->
    [
      {label: 'SPI sweep test',
       get: (=> @_stTimer?), set: ((v) => if v then @enterSweepTest() else @exitSweepTest())}
    ]
