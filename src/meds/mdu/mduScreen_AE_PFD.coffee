import {call, setInterval, clearInterval, now as simNow} from '../../com/simRuntime.coffee'
import * as THREE from 'three'
import {MDUScreen, sameField} from 'meds/mdu/mduScreen'
import {makeSDFLineGeometry, makeSDFLinesGeometry, makeSDFLineMaterial} from 'meds/mdu/shader/sdfLine'

rad2deg = (v) -> v * (180 / Math.PI)
deg2rad = (v) -> v * (Math.PI / 180)

zpad = (s) ->
  "000#{s}".substr(-3)

spad = (s) ->
  "    #{s}".substr(-4)


export class Screen_AE_PFD extends MDUScreen
  setData: (@curData) ->
    @curData ?= if @dev() then @sampleData() else @noData()
    @draw()

  # No data from the GPC: the ADI's OFF flag, every needle and pointer
  # stowed, every tape a red box, the meter without its needle, the mode
  # and DAP fields blank (STS-83-0020V1-34 sect.3.12: "a stow (out-of-view)
  # position which is used to indicate invalid conditions", "An OFF flag is
  # provided to indicate when the attitude ball display may be invalid",
  # "invalid indicator - solid red rectangle").
  noData: () ->
    adiValid: false
    adiRolRate: null, adiPchRate: null, adiYawRate: null
    adiRolErr: null, adiPchErr: null, adiYawErr: null
    machValid: false, alphaValid: false, keasValid: false, accValid: false
    altValid: false, hdotValid: false, radarValid: false, vertAccelValid: false
    hsiHeadingValid: false, hsiCourseValid: false, hsiCdiValid: false
    hsiPriBearingValid: false, hsiSecBearingValid: false
    hsiGsiValid: false, hsiPriRangeValid: false, hsiSecRangeValid: false

  # The sample of an entry, for --dev.
  sampleData: () ->
    {
        majorMode: 305
        abortMode: "TAL"
        fcsConfDAPAuto: true
        fcsConfThrotAuto: true
        fcsConfPitchAuto: true
        fcsConfRYAuto: true
        fcsConfSBAuto: true
        attSel: 2          # ADI ATTITUDE: 1 INRTL, 2 LVLH, 3 REF
        hsiMode: 2         # HSI MODE: 1 Entry, 2 TAEM, 3 Approach
        # TAEM, ADI RATE high: 5 deg/s each axis, pitch error 1.25 g
        adiRateScale: {roll: 5, pitch: 5, yaw: 5, rollTgo: false, rollZeroOnRight: false}
        adiPchErrScale: 1.25
        # sin(THETA_MAX - THETA) and sin(THETA - THETA_MIN)
        thetaMaxDelta: 0.20
        thetaMinDelta: 0.14
        dAz: 1,             dAzWarn: false
        iphase: 1          # TAEM guidance phase
        adiRolRate: -1.05 # -5 -> +5
        adiYawRate:  0 # -5 -> +5
        adiPchRate:  -0.1 # -5 -> +5
        # errors default centred; roll sits a touch left so the top needle
        # overlaps the left half of the belly band (per reference imagery)
        adiRolErr: -0.25  # -5 -> +5
        adiYawErr: 0  # -5 -> +5
        adiPchErr: 0  # -5 -> +
        # false = ADI OFF: ball locks, needles/pointers stow, digitals blank,
        # red OFF flag shows (toggle live via the dbl-click param editor)
        adiValid: true
        # adiRol: 0.5
        # adiPch: 348.5
        # adiYaw: 0.25,
        adiRol: 315
        adiPch: 315
        adiYaw: 316,
        vehicleAcceleration: 1.0
        targetNZ: 1.8      # MM 602 magenta target NZ line on the G-meter
        keas: 304          # velocity (KEAS) tape value
        alpha: 6.0         # angle-of-attack (alpha) tape value
        mach: 0.48         # mach: velocity tape + alpha limit bar + Max L/D diamond
        vel: 480           # VR/VI, fps — velocity-tape source above M 4 (shown as Kfps)
        ppa: false         # RTLS powered pitch-around done (MM 601 label M/VI -> M/VR)
        altitude: 2105     # altitude (H) tape value, ft
        altValid: true     # false -> H tape replaced by a blank red box
        hdot: -164        # altitude rate (H-dot) tape value, fps
        hdotValid: true    # false -> Hdot tape replaced by a blank red box
        radarAlt: 1950     # radar altitude, ft (pointer + 'R' digital when valid)
        radarValid: false  # radar altimeter lock (entry, < 5000 ft)
        vertAccel: -10     # altitude acceleration, fps2
        vertAccelValid: true
        # HSI: heading turns the compass card; course, the deviation and the
        # bearings are angles on the case (the DDU words carry heading
        # already subtracted)
        hsiHeading: 90,     hsiHeadingValid: true
        hsiCourse: 19,      hsiCourseValid: true
        hsiCdi: -2,         hsiCdiValid: true      # dots, + flies right
        hsiPriBearing: 122, hsiPriBearingValid: true
        hsiSecBearing: 59,  hsiSecBearingValid: true
        hsiGsi: -2,         hsiGsiValid: true      # dots, + flies down
        hsiPriRange: 0,     hsiPriRangeValid: true
        hsiSecRange: 0,     hsiSecRangeValid: true
    }

  T_setRPY: (rpy) ->
    @curData.adiRol = rpy[0]
    @curData.adiPch = rpy[1]
    @curData.adiYaw = rpy[2]

  # live-feed tape test
  #
  # Driven by the 'Hdot tape test' toggle in the debug parameter editor.
  # Sweeps hdot tape-minimum -> maximum -> minimum through the normal
  # curData/data() feed path, in tape-POSITION space so the tape scrolls at
  # a constant rows/s through the compressed >1000-fps regime too. Each
  # tick repaints the AVVI group exactly as a real feed update would.
  TT_PERIOD = 300           # s, one full min->max->min loop
  TT_TICK = 50              # ms, matches the DEU self-test cadence

  toggleTapeTest: () ->
    if @_ttTimer? then @exitTapeTest() else @enterTapeTest()

  enterTapeTest: () ->
    return if @_ttTimer?
    @_ttHdot0 = @curData.hdot          # restore the static sample on exit
    @_ttT0 = simNow()
    @tickTapeTest()
    @_ttTimer = setInterval(call(@, 'tickTapeTest'), TT_TICK)
    console.log "PFD tape feed test ON"

  exitTapeTest: () ->
    return if not @_ttTimer?
    clearInterval(@_ttTimer)
    @_ttTimer = null
    @curData.hdot = @_ttHdot0
    @_redrawAVVI()
    console.log "PFD tape feed test OFF"

  tickTapeTest: () ->
    ph = ((simNow() - @_ttT0) / 1000 % TT_PERIOD) / TT_PERIOD   # 0..1
    tri = if ph < 0.5 then 2*ph else 2 - 2*ph                     # 0..1..0
    posMax = 1000*HD_S + (HDOT_MAX - 1000)*HD_SHI
    pos = -posMax + tri*2*posMax
    a = Math.abs(pos)
    v = if a <= 1000*HD_S then a/HD_S else 1000 + (a - 1000*HD_S)/HD_SHI
    @curData.hdot = Math.round(v) * (if pos < 0 then -1 else 1)
    @_redrawAVVI()

  # live-feed altitude tape test
  #
  # Sweeps the H tape end to end (-1000 ft .. 165 nmi) at constant tape
  # speed (position space, so every ALT_SEGS regime gets equal screen time),
  # with the radar altimeter locking below 5000 ft to exercise the pointer
  # and the 'R' digital.
  AT2_PERIOD = 300
  enterAltTest: () ->
    return if @_altTimer?
    @_alt0 = [@curData.altitude, @curData.radarAlt, @curData.radarValid]
    @_altT0 = simNow()
    @_altTimer = setInterval(call(@, 'tickAltTest'), TT_TICK)
    @tickAltTest()
    console.log "PFD altitude tape test ON"

  exitAltTest: () ->
    return if not @_altTimer?
    clearInterval(@_altTimer)
    @_altTimer = null
    [@curData.altitude, @curData.radarAlt, @curData.radarValid] = @_alt0 if @_alt0?
    @_alt0 = null
    @_redrawAVVI()
    console.log "PFD altitude tape test OFF"

  tickAltTest: () ->
    ph = ((simNow() - @_altT0) / 1000 % AT2_PERIOD) / AT2_PERIOD
    tri = if ph < 0.5 then 2*ph else 2 - 2*ph
    p0 = altMapRows(ALT_MIN) ; p1 = altMapRows(ALT_MAX)
    alt = altInvRows(p0 + tri*(p1 - p0))
    @curData.altitude = Math.round(alt)
    # radar locks only in the tape's 0..5000 band — below 0 the digital
    # must keep showing NAV altitude down to the tape minimum, not '0R'
    @curData.radarValid = 0 <= alt < 5000
    @curData.radarAlt = Math.max(0, Math.round(alt*0.92 - 40))
    @_redrawAVVI()

  _redrawAVVI: () -> @_part 'avvi'

  # G-meter and ADI placement, shared by the part table and the tests
  ACC_ARGS = [7.6, 28.25, 2.55, -1, 4]
  ADI_C = [24.90, 12.0]

  # The instruments a PFD is assembled from.  Each is a group built from
  # curData, held on the named field, and rebuilt when the feed changes;
  # `u` names a cheaper update where a wholesale rebuild is not wanted.
  # A screen carries the ones its `parts` names.
  PARTS =
    fcsConfig: {f: 'fcsConfig', b: (t) -> t.drawFCSConfig()}
    majorMode: {f: 'majorMode', b: (t) -> t.drawMajorMode()}
    ami:       {f: 'ami',       b: (t) -> t.drawAMI()}
    avvi:      {f: 'avviGrp',   b: (t) -> t.drawAVVI()}
    accMeter:  {f: 'accMeter',  b: (t) -> t.drawAccMeter(ACC_ARGS...)}
    adi:
      f: 'adi'
      b: (t) -> t.drawADI(ADI_C...)
      # the ball geometry is static and expensive to build; updateADI()
      # redraws the attitude-driven overlays alone
      u: (t) -> t.updateADI()
    hsi:       {f: 'hsi',       b: (t) -> t.drawHSI()}
    gsi:       {f: 'gsi',       b: (t) -> t.drawGSI()}
    attAcc:    {f: 'attAcc',    b: (t) -> t.drawAttAcc()}
    xtrk:      {f: 'xtrk',      b: (t) -> t.drawXtrk()}
    range:     {f: 'range',     b: (t) -> t.drawRange()}
    dAz:       {f: 'dAz',       b: (t) -> t.drawDAz()}

  # A/E PFD: every instrument.  Screen_ORBIT_PFD names a subset.
  screenName: 'AE_PFD'
  parts: () -> ['fcsConfig', 'majorMode', 'ami', 'avvi', 'accMeter', 'adi',
                'hsi', 'gsi', 'attAcc', 'range', 'dAz', 'xtrk']

  # rebuild one part in place; a screen that does not carry it has nothing
  # to redraw
  _part: (name) ->
    return unless name in @parts()
    {f, b} = PARTS[name]
    @[f] = @_redo @[f], (=> @_reading name, (=> b(@)))
    return

  # The feed fields an instrument reads.
  #
  # A builder runs with `curData` behind a recorder, and the fields it read
  # are what a later feed has to name for it to be built again.  A builder
  # that enumerates the feed reads all of it, `ALL_FIELDS`.
  ALL_FIELDS = Symbol('all fields')

  _recorded: (build) ->
    keys = new Set()
    outer = @curData
    @curData = new Proxy outer,
      get: (t, k) -> keys.add(k) ; t[k]
      set: (t, k, v) -> t[k] = v ; true
      ownKeys: (t) -> keys.add(ALL_FIELDS) ; Reflect.ownKeys(t)
    try
      g = build()
    finally
      @curData = outer
    [g, keys]

  # `add` keeps what the part read before: an update path (`u` below) reads
  # what it draws now, and an instrument built with no data to draw has not
  # yet read the fields it will.
  _reading: (name, build, add = false) ->
    [g, keys] = @_recorded build
    prev = (@_partKeys ?= {})[name]
    if add and prev?
      keys.add(k) for k in Array.from(prev)
    @_partKeys[name] = keys
    g

  _reads: (name, changed) ->
    keys = @_partKeys?[name]
    return true if not keys? or keys.has(ALL_FIELDS)
    for k in changed
      return true if keys.has(k)
    false

  # An element of a part that is built once and kept until a field it reads
  # moves.  The builder runs behind the recorder, so what it read and what
  # those fields held is what the next call compares, and the part rebuilds
  # around the group it already has.  `_disposeGroup` spares a kept subtree
  # and `flatten` merges it once, leaving it under the strokes built after
  # it: a kept element stays where its builder put it.
  _kept: (name, build) ->
    c = (@_keptEls ?= {})[name]
    if c?
      moved = false
      for k, v of c.vals
        moved = true unless sameField(@curData[k], v)
      return c.g unless moved
    [g, keys] = @_recorded build
    g.userData.keepAlive = true
    vals = {}
    vals[k] = @curData[k] for k in Array.from(keys) when typeof k == 'string'
    @_keptEls[name] = {g, vals}
    g

  # Dispose a rebuilt group's geometry, sparing cached (userData.keepAlive)
  # subtrees: those are detached for reuse on the next build. Geometries are
  # per-build; materials are shared/cached — never disposed.
  _disposeGroup: (grp) ->
    keeps = []
    grp.traverse (o) -> keeps.push o if o.userData?.keepAlive
    for k in keeps
      k.parent?.remove k
    walk = (o) ->
      o.geometry?.dispose()
      walk(c) for c in o.children.slice()
      return
    walk(grp)

  # swap one data-driven group for a freshly built one
  _redo: (grp, builder) ->
    if grp?
      @group.remove grp
      @_disposeGroup grp
    ng = builder()
    if ng?
      @d.flatten ng
      @group.add ng
    @d.dirty = true
    ng

  # Cache/reuse one tape's expensive content (label glyphs + ticks) across
  # scrollTape rebuilds. Between rebuilds the cached layer just translates:
  # value-anchored mark positions are a pure shift of anchor-built ones, and
  # the clip rects live in world space (they ignore group transforms), so
  # the readout-box occlusion keeps working. The layer rebuilds only when
  # `fp` (the visible-mark fingerprint) changes — marks scrolling in or out
  # of the window, formats changing, or a mark crossing the readout centre
  # (its clip rect is chosen by side).
  # A tape's whole mark grid, which is the tape and not the value on it: the
  # id names the variant, so the provider runs once for each.
  _marksOf: (opts) ->
    return opts.marks() unless opts.id?
    (@_marksCache ?= {})[opts.id] ?= opts.marks()

  _tapeLayer: (id, fp, value, mapFn, scale, builder) ->
    return builder() if not id?                # uncached fallback
    @_tapeCache ?= {}
    c = @_tapeCache[id]
    if not c? or c.fp != fp
      c?.layer?.traverse (o) -> o.geometry?.dispose()
      layer = builder()
      layer.userData.keepAlive = true
      c = @_tapeCache[id] = {fp, layer, anchor: value, m0: (if mapFn? then mapFn(value) else null)}
    c.layer.position.y = if c.m0? then mapFn(value) - c.m0 else (value - c.anchor)*scale
    c.layer

  # Rebuild the data-driven elements `changed` reaches, naming the feed
  # fields that moved.  Without it every element is rebuilt: the debug
  # parameter editor (dbl-click outside the canvas) pokes curData directly.
  refreshFeed: (changed) ->
    for name in @parts()
      continue if changed? and not @_reads(name, changed)
      {u} = PARTS[name]
      if u? then @_reading name, (=> u(@)), true else @_part name
    return

  # live-feed ADI test
  #
  # Driven by the 'ADI test' pulldown in the debug parameter editor
  # (dbl-click outside the canvas):
  #   pitch sweep  +pitch revolution: horizon drops, ball top-to-bottom
  #   yaw sweep    triangle 0 -> +95 -> -95 -> 0: right-to-left ball motion,
  #                crossing the 90°±1.7° gimbal-protect region (R/P freeze)
  #   roll sweep   +roll revolution: ball CCW, bug rides the case scale CCW
  #   combo        combined tumble (error/rate needles sweep in every mode)
  #   freeze       feed stops, data holds wherever it is
  #   off          restores the defaults saved when the test first engaged
  AT_TICK = 50          # ms, matches the tape-test cadence
  AT_RATE = 12          # deg/s sweep rate
  AT_MODES = ['pitch sweep', 'yaw sweep (gimbal protect at 90)',
              'roll sweep', 'combined tumble', 'freeze']

  adiTestMode: () ->
    if @_atMode? then AT_MODES[@_atMode] else 'off'

  setAdiTestMode: (name) ->
    i = AT_MODES.indexOf(name)
    return if i == (@_atMode ? -1)
    d = @curData
    if i < 0                                   # off
      clearInterval(@_atTimer) if @_atTimer?
      @_atTimer = null
      if @_at0?
        [d.adiRol, d.adiPch, d.adiYaw, d.adiRolErr, d.adiPchErr,
         d.adiYawErr, d.adiRolRate, d.adiPchRate, d.adiYawRate] = @_at0
        @_at0 = null
      @_atMode = null
      @updateADI()
    else
      # save the static defaults once, when the test first engages
      @_at0 ?= [d.adiRol, d.adiPch, d.adiYaw, d.adiRolErr, d.adiPchErr,
                d.adiYawErr, d.adiRolRate, d.adiPchRate, d.adiYawRate]
      @_atMode = i
      if i == 4                                # freeze: hold data as-is
        clearInterval(@_atTimer) if @_atTimer?
        @_atTimer = null
      else
        @_atT0 = simNow()                    # each sweep starts from zero
        @_atTimer ?= setInterval(call(@, 'tickAdiTest'), AT_TICK)
        @tickAdiTest()
    console.log "PFD ADI test: #{@adiTestMode()}"
    return

  # descriptors for the parameter editor's test-control section: `options`
  # renders as a pulldown, plain get/set as an on/off checkbox
  testControls: () ->
    [
      {label: 'ADI test', options: ['off'].concat(AT_MODES),
       get: call(@, 'adiTestMode'), set: ((m) => @setAdiTestMode(m))}
      {label: 'Hdot tape test',
       get: (=> @_ttTimer?), set: ((v) => if v then @enterTapeTest() else @exitTapeTest())}
      {label: 'Alt tape test',
       get: (=> @_altTimer?), set: ((v) => if v then @enterAltTest() else @exitAltTest())}
      {label: 'G-meter test', options: ['off'].concat(m[0] for m in GT_MODES),
       get: call(@, 'gTestMode'), set: ((m) => @setGTestMode(m))}
      {label: 'Alpha tape test',
       get: (=> @_apTimer?), set: ((v) => if v then @enterAlphaTest() else @exitAlphaTest())}
      {label: 'Vel tape test',
       get: (=> @_vtTimer?), set: ((v) => if v then @enterVelTest() else @exitVelTest())}
      # (the F8 reference-overlay group — show/image/slot/apply-values — is
      # appended generically by the param editor; see mdu._ovControls)
    ]

  tickAdiTest: () ->
    return unless @_atMode? and @_atMode < 4
    t = (simNow() - @_atT0) / 1000
    d = @curData
    d.adiRol = 0 ; d.adiPch = 0 ; d.adiYaw = 0
    switch @_atMode
      when 0 then d.adiPch = (AT_RATE * t) % 360
      when 1
        u = (AT_RATE * t) % 380
        d.adiYaw = if u < 95 then u else if u < 285 then 190 - u else u - 380
      when 2 then d.adiRol = (AT_RATE * t) % 360
      when 3
        d.adiRol = (AT_RATE * t) % 360
        d.adiPch = 25 * Math.sin(2*Math.PI * t/37)
        d.adiYaw = 40 * Math.sin(2*Math.PI * t/23)
    d.adiRolErr = 5 * Math.sin(2*Math.PI * t/9)
    d.adiPchErr = 5 * Math.sin(2*Math.PI * t/11)
    d.adiYawErr = 5 * Math.sin(2*Math.PI * t/13)
    d.adiRolRate = 5 * Math.sin(2*Math.PI * t/15)
    d.adiPchRate = 5 * Math.sin(2*Math.PI * t/17)
    d.adiYawRate = 5 * Math.sin(2*Math.PI * t/19)
    @updateADI()

  # live-feed G-meter test
  #
  # Driven by the 'G-meter test' pulldown in the debug parameter editor.
  # Every mode sweeps the needle + digital through the full -1..4g range
  # (triangle, 12 s); the mode picks the major mode, exercising each meter
  # feature:
  #   Accel (MM 102)       powered-flight labelling
  #   Nz (MM 305)          glided-flight labelling
  #   Nz + target (MM 602) glided + the magenta target NZ line, which
  #                        sweeps slowly opposite the needle
  # 'off' restores the majorMode/value/target saved when the test engaged.
  GT_TICK = 100
  GT_MODES = [['Accel sweep (MM 102)', 102], ['Nz sweep (MM 305)', 305],
              ['Nz + target (MM 602)', 602]]

  gTestMode: () ->
    if @_gtMode? then GT_MODES[@_gtMode][0] else 'off'

  setGTestMode: (name) ->
    i = (m[0] for m in GT_MODES).indexOf(name)
    return if i == (@_gtMode ? -1)
    d = @curData
    if i < 0                                   # off
      clearInterval(@_gtTimer) if @_gtTimer?
      @_gtTimer = null
      [d.majorMode, d.vehicleAcceleration, d.targetNZ] = @_gt0 if @_gt0?
      @_gt0 = null
      @_gtMode = null
      @_redrawGMeter()
    else
      # save the statics once, when the test first engages
      @_gt0 ?= [d.majorMode, d.vehicleAcceleration, d.targetNZ]
      @_gtMode = i
      d.majorMode = GT_MODES[i][1]
      @_gtT0 = simNow()
      @_gtTimer ?= setInterval(call(@, 'tickGTest'), GT_TICK)
      @tickGTest()
    console.log "PFD G-meter test: #{@gTestMode()}"
    return

  tickGTest: () ->
    return unless @_gtMode?
    t = (simNow() - @_gtT0) / 1000
    d = @curData
    ph = (t % 12) / 12
    tri = if ph < 0.5 then 2*ph else 2 - 2*ph          # 0..1..0
    d.vehicleAcceleration = Math.round((-1 + tri*5) * 10) / 10
    if GT_MODES[@_gtMode][1] == 602
      ph = (t % 31) / 31
      tri = if ph < 0.5 then 2*ph else 2 - 2*ph
      d.targetNZ = Math.round((4 - tri*5) * 10) / 10
    @_redrawGMeter()

  # the meter and the MM digits (the test changes majorMode) only
  _redrawGMeter: () ->
    @_part 'accMeter'
    @_part 'majorMode'

  # live-feed alpha tape test
  #
  # Driven by the 'Alpha tape test' checkbox in the debug parameter editor.
  # Alpha sweeps -8..24 (through the whole green min/max band, hitting both
  # the grey negative and white positive faces — no need to walk the full
  # ±180 range) while mach sweeps 0.3..3.2 on its own period, so the limit
  # bar and the Max L/D diamond wander out of sync with the tape motion
  # (the diamond drops out while mach > 3, exercising that path too).
  ATP_TICK = 100
  enterAlphaTest: () ->
    return if @_apTimer?
    @_ap0 = [@curData.alpha, @curData.mach]
    @_apT0 = simNow()
    @_apTimer = setInterval(call(@, 'tickAlphaTest'), ATP_TICK)
    @tickAlphaTest()
    console.log "PFD alpha tape test ON"

  exitAlphaTest: () ->
    return if not @_apTimer?
    clearInterval(@_apTimer)
    @_apTimer = null
    [@curData.alpha, @curData.mach] = @_ap0 if @_ap0?
    @_ap0 = null
    @_part 'ami'
    console.log "PFD alpha tape test OFF"

  tickAlphaTest: () ->
    t = (simNow() - @_apT0) / 1000
    tri = (p) ->
      ph = (t % p) / p
      if ph < 0.5 then 2*ph else 2 - 2*ph
    @curData.alpha = Math.round((-8 + tri(11)*32) * 10) / 10
    @curData.mach = Math.round((0.3 + tri(17)*2.9) * 100) / 100
    @_part 'ami'

  # live-feed velocity tape test
  #
  # Driven by the 'Vel tape test' checkbox in the debug parameter editor.
  # u sweeps the tape end to end in tape units (mach 0..4, then VR as Kfps
  # up to 27), exercising both tape ends and the label/tick regime change
  # at 4.0. The sweep is piecewise: cruise above M 2, slower M 2->1, and a
  # crawl below M 1 so the KEAS tape (the MM 305 swap engages at mach<0.9)
  # can be watched at a useful speed. keas itself sweeps 0..500 on its own
  # period.
  VT_TICK = 100
  VT_SEGS = [[1, 30], [1, 15], [25, 55]]   # one-way legs [tape units, seconds]:
                                           # 0-1 crawl (KEAS), 1-2 slow, 2-27 cruise
  enterVelTest: () ->
    return if @_vtTimer?
    @_vt0 = [@curData.mach, @curData.vel, @curData.keas]
    @_vtT0 = simNow()
    @_vtTimer = setInterval(call(@, 'tickVelTest'), VT_TICK)
    @tickVelTest()
    console.log "PFD velocity tape test ON"

  exitVelTest: () ->
    return if not @_vtTimer?
    clearInterval(@_vtTimer)
    @_vtTimer = null
    [@curData.mach, @curData.vel, @curData.keas] = @_vt0 if @_vt0?
    @_vt0 = null
    @_part 'ami'
    console.log "PFD velocity tape test OFF"

  tickVelTest: () ->
    t = (simNow() - @_vtT0) / 1000
    tri = (p) ->
      ph = (t % p) / p
      if ph < 0.5 then 2*ph else 2 - 2*ph
    # triangle over the piecewise legs: up the segment table, then back down
    legT = 0 ; legT += s[1] for s in VT_SEGS
    ph = t % (2*legT)
    ph = 2*legT - ph if ph > legT
    u = 0
    for [du, dt] in VT_SEGS
      if ph >= dt
        u += du ; ph -= dt
      else
        u += du * ph/dt
        break
    @curData.mach = Math.round(Math.min(u, 4)*100)/100
    @curData.vel = Math.round(u*1000)
    @curData.keas = Math.round(tri(23)*500)
    @_part 'ami'

  data: () ->
    return @curData

  build: () ->
    @setData()
    @T_RPY_TOP = [0, 89, 271]
    @T_RPY_1 = [331, 348, 0]
    @T_RPY_2 = [0, 348, 0]

    @T_setRPY([0.5,348.5,0.25]) if @dev()
    @group = new THREE.Object3D name=@screenName #"

    for name in @parts()
      {f, b} = PARTS[name]
      @[f] = g = @_reading name, (=> b(@))
      if g?
        @d.flatten g
        @group.add g
    @d.dirty = true

  # The ADI ATTITUDE switch position the transfer carries (word 20 bits 1-4,
  # MEDS_L/R_ATT_SEL_SW): the FSSR maps the switch discrete -1, 0, +1 to 1,
  # 2, 3 (F.4.128.1.3.2.7) and names the positions "INRTL (inertial), LVLH
  # (local vertical/local horizontal), and REF (reference)" in panel order
  # (USA-007587 sect.2.7).  0 is no position.
  ATT_SEL = {1: "INRTL", 2: "LVLH", 3: "REF"}

  drawFCSConfig: () ->
    @fcsConfig = new THREE.Object3D()
    # FCS Configuration – DAP and throttle mode. During powered
    # flight (MM 101-103 & MM 601), the fields show DAP mode (AUTO
    # or CSS) and Throttle mode (AUTO or MAN). If CSS or MAN are
    # selected, a yellow box is drawn around the fields. Post-MECO
    # (MM 104-106), the DAP mode will indicate AUTO or INRTL, while
    # the throttle field is blanked in MM 103 at MECO confirmed and
    # throughout MM 104-106. In MM 301-303, the upper field will
    # show DAP: AUTO or INRTL as in post-MECO OPS 1, while the lower
    # field remains blank. During Entry (MM 304, 305, 602, & 603),
    # the fields display the Pitch and Roll/Yaw DAP mode (AUTO or
    # CSS) in the upper and lower fields, respectively.
    # Additionally, a yellow box is drawn around the field if CSS is
    # selected prior to M =1. For PASS, the following table
    # summarizes this field as well as items 10 and 11.
    #
    # [JSC-48017/6-8 item 1]
    #
    d = @data()
    mm = d.majorMode
    lbl = (x, y, t) => @fcsConfig.add @d.str x, y, t, @d.c2h.darkGray, 1, .9
    # an indicator whose word the GPC is not marking valid has no field
    val = (x, y, auto, a, b) =>
      @fcsConfig.add @d.str x, y, (if auto then a else b), @d.c2h.white, 1, .9 if auto?
    css = false                 # a CSS or MAN field is showing
    if mm in [101, 102, 103, 601]
      lbl 2, 0.75, "  DAP:"
      val 8, 0.75, d.fcsConfDAPAuto, "Auto", " CSS"
      css = d.fcsConfDAPAuto == false
      # word 20 bit 6, MEDS_THROT_RY_AUTO_BLANK: MECO confirmed
      unless d.fcsConfThrotBlank
        lbl 2, 1.75, "Throt:"
        val 8, 1.75, d.fcsConfThrotAuto, "Auto", "MAN"
        css = css or d.fcsConfThrotAuto == false
    else if mm in [104, 105, 106, 301, 302, 303]
      lbl 2, 0.75, "  DAP:"
      val 8, 0.75, d.fcsConfDAPAuto, "Auto", "INRTL"
    else if mm in [304, 305, 602, 603]
      lbl 3, 0.9, "Pitch:"
      lbl 3, 1.9, "  R/Y:"
      val 8.5, 0.90, d.fcsConfPitchAuto, "Auto", " CSS"
      val 8.5, 1.90, d.fcsConfRYAuto, "Auto", " CSS"
      # "prior to M = 1": entry decelerates through it, so above mach 1
      css = (d.fcsConfPitchAuto == false or d.fcsConfRYAuto == false) and (d.mach ? 0) > 1

    @fcsConfig.add @d.box 2, 0.75, 12.75, 1.75, @d.c2h.yellow if css

    # FCS Configuration/ADI Attitude – The field below the major
    # mode shows the applicable CDR or PLT ADI attitude selected,
    # i.e. INRTL, LVLH, or REF (MM 101-106 and 601, and 301-303), or
    # SB mode, i.e. AUTO or MAN (MM 304 and 305, and 602 and 603). A
    # yellow box is drawn around the indicator if MAN SB is
    # selected.
    #
    # [JSC-48017/6-14 item 10]
    #
    if mm in [101, 102, 103, 104, 105, 106, 301, 302, 303, 601]
      lbl 42, 2, " ATT:"
      if (att = ATT_SEL[d.attSel])?
        @fcsConfig.add @d.str 45.78, 2, " #{att}", @d.c2h.white, 1, .9
    else if mm in [304, 305, 602, 603]
      lbl 42, 2, " SB:"
      val 45.78, 2, d.fcsConfSBAuto, " Auto", " MAN"
      @fcsConfig.add @d.box 45.9, 1.55, 50.4, 2.55, @d.c2h.yellow if d.fcsConfSBAuto == false

    return @fcsConfig

  # R for RTLS, T for TAL, AOA for AOA, ATO for ATO, CA for contingency
  # (JSC-48017/6-14 item 11), keyed by the abort flags of message 1 word 9.
  ABORT_LTR = {RTLS: "R", TAL: "T", AOA: "AOA", ATO: "ATO", CA: "CA"}

  drawMajorMode: () ->
    @majorMode = new THREE.Object3D()
    # Major Mode – The current major mode is identified in the upper
    # right hand corner of the display. If an abort has been
    # declared, an indicator will verify the abort mode selected (R
    # for RTLS, T for TAL, AOA for AOA, ATO for ATO, and CA for
    # contingency aborts)
    #
    abt = ABORT_LTR[@data().abortMode] ? ""
    mmStr = if @data().majorMode? then " #{@data().majorMode}#{abt}" else ""

    @majorMode.add @d.str 42,.95," MM:", @d.c2h.darkGray, scale=1, advance=.9
    @majorMode.add @d.str 45.78,.95,mmStr, @d.c2h.white, scale=1, advance=.9

    return @majorMode

  buildHdotTape: () ->
    WIDTH = 4.75
    HEIGHT= 15.2-0.05
    

  drawTape: (x0,y0,pointer=false,value=undefined) ->
    group = new THREE.Object3D()
    if value?
      matW = @d.c2h.white
      matG = @d.c2h.darkGray
    else
      matW = @d.c2h.red
      matG = @d.c2h.red
    group.add @d.box x0,y0,x0+4.75,y0+15.15 , matW, 0
    clipBox = new THREE.Vector4(x0, x0+4.75, y0, y0+15.15)
    if pointer
      dl = new THREE.BufferGeometry()
      vertices = new Float32Array([
        x0-.5, 11, 1,
        x0+4.0, 11, 1,
        x0+4.7, 11.875, 1,
        x0+4.0, 12.75, 1,
        x0-.5, 12.75, 1
      ])
      dl.setAttribute( 'position', new THREE.BufferAttribute( vertices, 3 ) );
      dl.setIndex([0,1,3, 1,2,3, 3,4,0]);
      # group.add new THREE.Mesh(dl,@d.c2h.blackMsh)
      fill = new THREE.MeshBasicMaterial({color:@d.c2h.black, side:THREE.DoubleSide})
      group.add new THREE.Mesh(dl,fill)
      group.add @d.line [[x0-.5, 11],[x0+4.0, 11],[x0+4.7, 11.875],[x0+4.0, 12.75],[x0-.5, 12.75],[x0-.5, 11]], matG, 1.0, clipBox
    else
      group.add @d.box x0,11,x0+4.75,12.75, @d.c2h.lightGray, @d.c2h.black, @d.NO_CLIP
      # group.add @d.box x0,11,x0+4.75,12.75, matG
    return group

  # A tape's marks, trimmed to the tape above the readout box and again to
  # the tape below it: one geometry under two clip rects.  A mark carries no
  # side of the box, so the layer stands while the tape scrolls under the
  # window.
  #
  # The box is 1.70 rows and the tallest mark 1.33 (a 1.22-scale meds digit,
  # 0.409 rows of ink either side of its line, plus the stroke and its
  # feather), so no mark reaches from one window into the other and each
  # comes out as it would trimmed to the side it lies on.
  #
  # The second set is built after the first, in the same order, so the two
  # merge as two runs.
  _clipBoth: (lg, clipTop, clipBot) ->
    marks = []
    lg.traverse (o) -> marks.push o if o.isMesh
    mirror = new THREE.Object3D()
    for m in marks
      base = m.material
      m.material = @d._clipMat(base, clipTop)
      c = new THREE.Mesh(m.geometry, @d._clipMat(base, clipBot))
      c.frustumCulled = m.frustumCulled
      c.renderOrder = m.renderOrder
      c.position.copy m.position
      c.quaternion.copy m.quaternion
      c.scale.copy m.scale
      mirror.add c
    lg.add mirror
    lg

  # thin (1.5px) background-colour tick stroke.  A clip rect rides on a
  # cloned material, so the clones are cached per rect; a tick with no rect
  # takes the shared material and `_clipBoth` gives it the two it needs.
  _thinTick: (pts, clip = null) ->
    @_tickBlkMat ?= makeSDFLineMaterial(THREE, @d.sdfOpt({color: @d.c2h.black, widthPx: 1.5}))
    @_tickClipMats ?= {}
    m = if not clip? then @_tickBlkMat
    else @_tickClipMats["#{clip.x},#{clip.y},#{clip.z},#{clip.w}"] ?= @d._clipMat(@_tickBlkMat, clip)
    t = new THREE.Mesh(makeSDFLineGeometry(THREE, pts), m)
    t.frustumCulled = false
    t.renderOrder = -1        # tuck tick ends under the frame stroke
    t

  # Vertical scrolling tape: window (x0,y0)-(x0+w,y0+h), current `value` centred,
  # labels every `step` at `scale` rows/unit, all clipped to the window. A fixed
  # white-on-black digital readout sits at the centre (drawn in front, unclipped).
  scrollTape: (x0, y0, w, h, value, step, scale, opts={}) ->
    digits = opts.digits ? 0 ; tickW = opts.tickW ? 2
    tickColor = opts.tickColor ? @d.c2h.white
    pointer = opts.pointer ? false ; signed = opts.signed ? false ; center = opts.center ? false
    lblScale = opts.lblScale ? 1.0                           # legend type size (glyph scale)
    MADV = 0.8                                               # meds digit advance (nearly touching)
    adv = (opts.advF ? MADV)*lblScale                        # legend advance tracks type size
    rdScale = opts.rdScale ? 1.1                             # centre readout type size
    # meds digit ink metrics, measured from the meds_font.svg glyph geometry
    # (cell coords relative to the strMEDS origin; glyphStrokes places the cell
    # at x-1, so ink x = x - 1 + gx*scale, ink y = y + gy*scale):
    GXC = 1.368   # digit ink centre, x
    GXL = 1.009   # digit ink left edge, x
    GXR = 1.726   # digit ink right edge (the '4' tail is the widest)
    GYC = 0.330   # digit ink centre below the draw origin, y
    GHH = 0.409   # digit ink half-height
    grp = new THREE.Object3D()
    cy = y0 + h/2 ; cx = x0 + w/2
    bandH = 0.85                                              # half-height of centre readout box
    # opts.boxDy shifts the readout box (and its clips/text) off the tape
    # centre; the value->row mapping stays anchored on cy
    bcy = cy + (opts.boxDy ? 0)
    # opts.clipOff: the owning group's world offset. Clip planes live in
    # WORLD space and ignore group transforms, so tapes drawn in a shifted
    # group (the AMI rides at +0.075/+0.187) must shift their clip rects to
    # match or everything clips ~2px/5px off the drawn window.
    [cOx, cOy] = opts.clipOff ? [0, 0]
    clipTop = new THREE.Vector4(x0+cOx, x0+w+cOx, y0+cOy, bcy-bandH+cOy)  # marks above the readout
    clipBot = new THREE.Vector4(x0+cOx, x0+w+cOx, bcy+bandH+cOy, y0+h+cOy) # marks below the readout
    # opts.map: nonlinear/piecewise value->rows mapping (rows above the tape
    # datum, monotonic). All positions derive from map(V)-map(value), so
    # `scale` is ignored wherever a map is supplied.
    map0 = if opts.map? then opts.map(value) else 0
    dpos = (v) => if opts.map? then opts.map(v) - map0 else (v - value)*scale
    # A tape is a strip longer than its window, and scrolling it is a
    # translation of the strip.  The marks that go on it are those in a band
    # around a tape position quantised to TAPE_BAND rows: the strip then
    # stands until the tape has travelled a band, and the band covers the
    # window wherever the value sits inside it.  `dq` is a mark's row
    # measured from that quantised position.
    posQ = TAPE_BAND * Math.round((if opts.map? then map0 else value*scale) / TAPE_BAND)
    dq = (v) => (if opts.map? then opts.map(v) else v*scale) - posQ
    # opts.range [vMin, vMax]: bounded unsigned tape (the velocity tape's
    # mach and KEAS faces). The white face spans just the value range —
    # padded ~a label half-height past each end so the end labels sit on
    # tape — with black labels and thin black ticks; past the tape ends the
    # window shows bare background (the physical tape has run out).
    if opts.range?
      [vMin, vMax] = opts.range
      fPad = 0.55*lblScale
      yT = Math.max(y0, Math.min(y0+h, cy - dpos(vMax) - fPad))
      yB = Math.max(y0, Math.min(y0+h, cy - dpos(vMin) + fPad))
      grp.add @d.box x0, yT, x0+w, yB, null, @d.c2h.white if yB > yT
    # signed tapes: white background where value>=0, grey where value<0
    # (opts.grayFace picks the grey — the alpha tape uses the lighter one)
    if signed
      yZ = Math.max(y0, Math.min(y0+h, cy - dpos(0)))        # y of the value=0 boundary
      unless opts.marks?   # marks tapes bring their own face rects
        grp.add @d.box x0, y0, x0+w, yZ, null, @d.c2h.white
        grp.add @d.box x0, yZ, x0+w, y0+h, null, (opts.grayFace ? @d.c2h.darkGray)
      # reference: a background-blue rule separates the white (>=0) and grey
      # (<0) tape faces; clipped like the labels so it slides behind the box
      if opts.border and yZ > y0 and yZ < y0+h
        zl = @d.line [[x0, yZ], [x0+w, yZ]], @d.c2h.black, 1.0, (if yZ < bcy then clipTop else clipBot)
        # under the right-lane ticks (-1): the white 0 tick rides OVER
        # this boundary rule, per spec
        zl.renderOrder = -2
        grp.add zl
    # green min/max limit bar riding the right tick lane, under the ticks
    # (same width as the tick length), clamped to the window
    if opts.greenBar? and opts.rightTicks?
      [vLo, vHi] = opts.greenBar
      yHi = Math.max(y0, Math.min(y0+h, cy - dpos(vHi)))
      yLo = Math.max(y0, Math.min(y0+h, cy - dpos(vLo)))
      gtl = opts.rightTicks.len ? 0.75
      # left edge pulled slightly past the tick lane; right edge flush
      grp.add @d.box x0+w-gtl-0.15, yHi, x0+w, yLo, null, @d.c2h.green if yLo > yHi
    grp.add @d.box x0, y0, x0+w, y0+h, @d.c2h.white           # window frame
    # opts.border: white-on-grey content gets a thin background-blue halo
    # (SDF border) to set it off from the grey band, like the real MEDS.
    # On bordered tapes '0' straddles the white/grey boundary, so it draws
    # like the grey-side labels (white + halo) to read on both faces.
    lblClr = (v) =>
      return @d.c2h.black if opts.range?   # range tapes: black on the white face
      return @d.c2h.white unless signed
      return @d.c2h.black if v > 0 or (v == 0 and not opts.border)
      if opts.border then {c: @d.c2h.white, border: @d.c2h.black} else @d.c2h.white
    # label x-anchor: ink-true centring on cx via GXC, or ink-true LEFT
    # anchoring: left ink edge at x0+lblPad regardless of type size (labels
    # scale about their left side, per reference). 0.41 default reproduces
    # the legacy x0+0.4 origin at scale 1 to within a fraction of a pixel.
    lblAt = (txt) =>
      if center then cx - (txt.length-1)*adv/2 - (GXC*lblScale - 1)
      else x0 + (opts.lblPad ? 0.41) + 1 - GXL*lblScale
    if opts.marks?
      # opts.marks() -> {faces, labels, ticks}: the whole tape's marks, for
      # piecewise tapes (AVVI altitude / altitude-rate). faces [{v0,v1,fill,
      # padLo?,padHi?}] — pad extends the tape's outer ends ~a label half-
      # height so the end labels sit on tape; labels [{v,txt,c}]; ticks
      # [{v,x0,x1,thin?,c}] — thin gets the 1.5px background-colour stroke,
      # else a standard @d.line in c.  scrollTape takes the band it needs.
      mk = @_marksOf opts
      fPad = 0.55*lblScale
      # faces are a few clamped quads — cheap, rebuilt every call
      for f in (mk.faces ? [])
        yFT = Math.max(y0, Math.min(y0+h, cy - dpos(f.v1) - (if f.padHi then fPad else 0)))
        yFB = Math.max(y0, Math.min(y0+h, cy - dpos(f.v0) + (if f.padLo then fPad else 0)))
        grp.add @d.box x0, yFT, x0+w, yFB, null, f.fill if yFB > yFT
      # labels + ticks: the expensive glyph/stroke content rides a cached
      # layer (see _tapeLayer) — kept with a margin past the window so a
      # rebuild happens before anything scrolls on.
      MMARG = TAPE_BAND + 1.5
      visLabels = (L for L in (mk.labels ? []) when y0 - MMARG <= cy - dq(L.v) <= y0 + h + MMARG)
      visTicks  = (T for T in (mk.ticks ? []) when y0 - MMARG <= cy - dq(T.v) <= y0 + h + MMARG)
      fp = ("#{L.v}~#{L.txt}" for L in visLabels).join(',') + '|' +
           ("#{T.v}~#{T.x0}~#{T.x1}~#{+!!T.thin}" for T in visTicks).join(',')
      grp.add @_tapeLayer opts.id, fp, value, opts.map, scale, =>
        lg = new THREE.Object3D()
        for L in visLabels
          yV = cy - dpos(L.v)
          # y = yV - GYC*lblScale puts the measured ink centre on the value
          # line; the clips end at the readout box edges so labels slide
          # behind it
          lg.add @d.strMEDS lblAt(L.txt), yV-GYC*lblScale, L.txt, L.c, lblScale, adv, 1.0
        for T in visTicks
          yVt = cy - dpos(T.v)
          if T.thin
            lg.add @_thinTick [[T.x0, yVt], [T.x1, yVt]]
          else
            lg.add @d.line [[T.x0, yVt], [T.x1, yVt]], T.c
        @_clipBoth lg, clipTop, clipBot
    else
      nBand = Math.max(1, Math.round(TAPE_BAND/(scale*step)))
      nEach = Math.ceil((h/2)/(scale*step)) + nBand + 1
      vC = nBand*step * Math.round(value/(nBand*step))
      eps = step/1000                                        # float-noise guard at the range ends
      inRng = (v) -> not opts.range? or (vMin - eps <= v <= vMax + eps)
      # cached layer (see _tapeLayer): the mark window is anchored on vC, so
      # vC is the fingerprint
      fp = "#{vC}"
      grp.add @_tapeLayer opts.id, fp, value, opts.map, scale, =>
        lg = new THREE.Object3D()
        for k in [-nEach..nEach]
          V = vC + k*step
          yV = cy - dpos(V)                                  # higher value -> higher up
          if inRng(V)
            # opts.lblFn formats the legend (fractional-step tapes must round
            # the float noise out of V; suffixed labels centre as whole strings)
            txt = if opts.lblFn? then opts.lblFn(V) else "#{V}"
            # y = yV - GYC*lblScale puts the measured ink centre exactly on the
            # value line yV, so the half-step ticks land mid-gap between labels.
            # The clipTop/clipBot windows end at the readout box edges, so a
            # label scrolling toward the box is occluded progressively, like a
            # label printed on a physical tape sliding behind the readout.
            lg.add @d.strMEDS lblAt(txt), yV-GYC*lblScale, txt, lblClr(V), lblScale, adv, 1.0
          if tickW > 0                                       # minor tick at the half-step
            Vt = V + step/2 ; yVt = cy - dpos(Vt)
            if inRng(Vt)
              # opts.tickFn overrides the centred [cx±tickW/2] extent (the mach
              # tape switches to left-edge ticks above 4.0); null skips the tick
              ext = if opts.tickFn? then opts.tickFn(Vt) else [cx-tickW/2, cx+tickW/2]
              if ext?
                if opts.range?
                  # black face ticks run thin, like the alpha tape's right lane
                  lg.add @_thinTick [[ext[0], yVt], [ext[1], yVt]]
                else
                  lg.add @d.line [[ext[0], yVt],[ext[1], yVt]], (if signed then lblClr(Vt) else tickColor)
        @_clipBoth lg, clipTop, clipBot
    # right-lane unit ticks (opts.rightTicks {step, len}): black on the
    # white (positive) face, white with the dark halo on the grey face;
    # the 0 tick is white and rides OVER the face-boundary rule (drawn
    # above, earlier in the transparent pass)
    if opts.rightTicks?
      ts = opts.rightTicks.step ? 1 ; tl = opts.rightTicks.len ? 0.75
      # black (background-colour) ticks run thinner than the standard stroke
      @_tickBlkMat ?= makeSDFLineMaterial(THREE, @d.sdfOpt({color: @d.c2h.black, widthPx: 1.5}))
      vT0 = Math.ceil((value - (h/2)/scale)/ts)*ts
      vT1 = Math.floor((value + (h/2)/scale)/ts)*ts
      for V in [vT0..vT1] by ts
        yV = cy - dpos(V)
        continue if yV < y0 or yV > y0+h
        if V > 0
          t = new THREE.Mesh(makeSDFLineGeometry(THREE, [[x0+w-tl, yV], [x0+w, yV]]), @_tickBlkMat)
          t.frustumCulled = false
        else
          t = @d.line [[x0+w-tl, yV], [x0+w, yV]], {c: @d.c2h.white, border: @d.c2h.black}
        # renderOrder -1: the tick's right end tucks UNDER the tape frame
        t.traverse (o) -> o.renderOrder = -1 if o.isMesh
        grp.add t
    # Max L/D diamond riding the tick lane at opts.diamond's value:
    # background-colour fill, magenta outline w/ the standard dark halo,
    # as wide as it is tall
    if opts.diamond?
      yD = cy - dpos(opts.diamond)
      dw = 0.44 ; dh = dw * 13.783/18.79
      # draw while any part is inside the window; the clip rect trims it
      # smoothly under the top/bottom frame and the right border (no pop)
      if y0 - dh < yD < y0 + h + dh
        dcx = x0+w - (opts.rightTicks?.len ? 0.75)/2
        dclip = new THREE.Vector4(x0+cOx, x0+w+cOx, y0+cOy, y0+h+cOy)
        dpts = [[dcx-dw, yD], [dcx, yD-dh], [dcx+dw, yD], [dcx, yD+dh]]
        grp.add @d.polyFill dpts, @d.c2h.black, null, dclip
        # heavier outline than @d.line's default, rounding out the shape;
        # clipped materials cached on first use (the clip rect is fixed —
        # only the alpha tape draws a diamond)
        @_diaMats ?= [
          @d._clipMat(makeSDFLineMaterial(THREE, @d.sdfOpt({color: @d.c2h.black, widthPx: 3 + 1.8})), dclip)
          @d._clipMat(makeSDFLineMaterial(THREE, @d.sdfOpt({color: @d.c2h.magenta, widthPx: 3})), dclip)
        ]
        dgeom = makeSDFLineGeometry(THREE, dpts.concat([dpts[0]]))
        for [dm, dord] in [[@_diaMats[0], 0], [@_diaMats[1], 1]]
          dmesh = new THREE.Mesh(dgeom, dm)
          dmesh.frustumCulled = false
          dmesh.renderOrder = dord
          grp.add dmesh
    # centre digital readout: sign-coloured (signed) or bg-fill + grey outline
    # centre digital readout: always grey border, dark/bg fill, white text
    if pointer
      # square part reaches the tick lane; arrow tapers to the point from
      # there. Opaque over the frame/tick strokes: those are transparent
      # SDF lines, so the box fill+outline ride the transparent pass at
      # renderOrder 2 (readout text above at 3)
      # tip stops just short of the tape right border; grey outline gets
      # its own dark halo (border spec) setting the box off from the tape
      lx = x0-0.35 ; px = x0+w-0.24
      mx = if opts.rightTicks? then x0+w-(opts.rightTicks.len ? 0.75)-0.15 else px-1.3
      pf = @d.polyFill [[lx,bcy-bandH],[mx,bcy-bandH],[px,bcy],[mx,bcy+bandH],[lx,bcy+bandH]], @d.c2h.black, {c: @d.c2h.darkGray, border: @d.c2h.black}
      pf.traverse (o) ->
        if o.isMesh
          o.renderOrder = 2
          o.material.transparent = true if o.material.isMeshBasicMaterial
      grp.add pf
    else
      grp.add @d.box x0, bcy-bandH, x0+w, bcy+bandH, @d.c2h.darkGray, @d.c2h.black
    # opts.rdStr overrides the readout text outright (radar-altitude 'R')
    vstr = opts.rdStr ? (if digits>0 then value.toFixed(digits) else "#{Math.round(value)}")
    # readout advance tracks its type size (like the legend), else narrow
    # glyphs ('1') crowd their neighbours; legacy 0.8 kept for other tapes.
    # opts.rdAdv overrides outright (reference kerning sits between the two).
    rAdv = opts.rdAdv ? (if opts.rdScale? then MADV*rdScale else MADV)
    # rjust: right ink edge (origin - 1 + (n-1)*adv + GXR*rdScale) flush
    # against the box's right side (reference: the '4' tail touches the edge)
    rX = if opts.rjust then x0 + w - ((vstr.length-1)*rAdv + GXR*rdScale - 1)
    else if center then cx - (vstr.length*rAdv)/2
    else x0+0.3
    # ink-centre the readout vertically when rdScale is explicit; the legacy
    # -0.45 offset is kept for the other tapes (rdScale defaulted).
    # rdDx/rdDy: pixel-tuning offsets applied on top of the base anchoring
    rY = if opts.rdScale? then bcy - GYC*rdScale else bcy - 0.45
    rX += opts.rdDx ? 0
    rY += opts.rdDy ? 0
    # opts.rdLeadUp: the reference shows the leading chars of the readout
    # riding slightly high of the final digit — draw the lead separately
    leadUp = opts.rdLeadUp ? 0
    rTxt = new THREE.Object3D()
    if opts.rjust and leadUp
      rTxt.add @d.strMEDS rX, rY-leadUp, vstr[...-1], @d.c2h.white, rdScale, rAdv, 1.0
      rTxt.add @d.strMEDS rX+(vstr.length-1)*rAdv, rY, vstr[-1..], @d.c2h.white, rdScale, rAdv, 1.0
    else
      rTxt.add @d.strMEDS rX, rY, vstr, @d.c2h.white, rdScale, rAdv, 1.0
    # readout text rides above the pointer-box fill (renderOrder 2)
    rTxt.traverse (o) -> o.renderOrder = 3 if o.isMesh
    grp.add rTxt
    return grp

  # "A Max L/D diamond indicates the optimum alpha value for maximum lift
  # over drag flying techniques, and is displayed when M < 3.0. The values
  # for the diamond's location are linearly interpolated from a table of
  # values provided in Table 8-6."
  ALPHA_MAXLD = [[0.95, 10.5], [1.0, 12.0], [2.0, 15.0], [3.0, 17.0]]
  # "A green maximum and minimum alpha bar is provided in both PASS and BFS
  # MM 304, 305, 602, and 603, with the exception of contingency aborts.
  # Note: When using low alpha techniques during aborts, the alpha bar may
  # not be visible. The values of the bar are derived by linear
  # interpolation of tables of values in Table 8-7 and Table 8-8."
  # rows: [mach, alphaMax, alphaMin]
  ALPHA_LIM_ENTRY = [                    # Table 8-7, MM 304 & 305
    [0.0, 20.0, -4.0], [0.2, 20.0, -4.0], [0.5, 20.0, 0.0], [0.6, 20.0, 0.7]
    [0.8, 15.0, 2.0], [1.1, 15.8, 4.0], [2.0, 18.3, 4.0], [2.5, 19.6, 6.0]
    [3.0, 21.0, 7.6], [3.2, 21.4, 8.2], [3.5, 22.0, 12.0], [5.0, 28.0, 16.0]
    [8.0, 40.0, 28.9], [9.6, 44.0, 33.0], [11.4, 44.0, 36.0], [27.0, 44.0, 36.0]
  ]
  ALPHA_LIM_GRTLS = [                    # Table 8-8, MM 602 & 603
    [0.0, 20.0, -4.0], [0.2, 20.0, -4.0], [0.5, 20.0, 0.0], [0.6, 20.0, 0.7]
    [0.8, 15.0, 2.0], [1.1, 15.8, 4.0], [2.0, 18.3, 4.0], [2.5, 19.6, 6.0]
    [3.0, 21.0, 8.2], [3.4, 21.0, 10.0], [4.0, 21.0, 10.0], [5.1, 50.0, 10.0]
    [6.0, 53.0, 10.0], [8.0, 53.0, 10.0]
  ]

  # inches of physical tape -> display units. The tape geometry in the spec
  # is given in inches of tape face; the MDU active display area is 6.7 in
  # square and the screen coordinate grid is 52.2425 cols x 38.32 rows (see
  # px/pxy in drawAVVI), so one tape inch maps to:
  TAPE_BAND = 12                # rows of tape kept past each end of a window,
                                # which is how far it scrolls between rebuilds
  TAPE_IN_ROWS = 38.32/6.7      # rows per inch (vertical, along the tape)
  TAPE_IN_COLS = 52.2425/6.7    # cols per inch (tick widths)

  NM_FT = 6076.115              # feet per nautical mile

  # AVVI altitude tape segments, straight from the spec: each row is
  # [vLo, vHi, inches-of-tape, labelStep, tickStep, tickWidth-in, tickSide]
  # (ft except the last row's steps, which ride the nmi grid). The scale is
  # linear within a segment; label/tick grids are absolute multiples of the
  # step. Boundary values label once, with the UPPER segment's format (so
  # 2000 reads '2' — the thousands domain starts there); ticks skip labeled
  # values. Note: the spec text (labels every 1000 above 2000 ft, marks
  # every 100 in 200-2000) is used where the figure-derived description
  # ('200-pitch labels to 4000, 50-ft marks') can't fit the segment inches.
  ALT_SEGS = [
    [-1000,  0,         6.36,  200,     100,   0.3, 'c']
    [0,      200,       2.8,   50,      10,    0.2, 'c']
    [200,    2000,      3.6,   200,     100,   0.3, 'c']
    [2000,   30000,     14.0,  1000,    500,   0.3, 'c']
    [30000,  100000,    17.5,  5000,    1000,  0.2, 'c']
    [100000, 400000,    12.0,  50000,   10000, 0.2, 'l']
    [400000, 165*NM_FT, 24.12, 5*NM_FT, NM_FT, 0.1, 'r']
  ]
  do ->   # annotate each segment with its tape position (inches above 0 ft)
    p = -ALT_SEGS[0][2]
    for s in ALT_SEGS
      s.pos0 = p ; s.ips = s[2]/(s[1] - s[0]) ; p += s[2]
    return
  ALT_MIN = ALT_SEGS[0][0]
  ALT_LAST = ALT_SEGS[ALT_SEGS.length-1]
  ALT_MAX = ALT_LAST[1]

  # altitude -> tape rows above the 0-ft datum (clamped at the tape ends)
  altMapRows = (v) ->
    v = Math.max(ALT_MIN, Math.min(ALT_MAX, v))
    for s in ALT_SEGS
      if v <= s[1] + 1e-9
        return (s.pos0 + (v - s[0])*s.ips) * TAPE_IN_ROWS
    (ALT_LAST.pos0 + ALT_LAST[2]) * TAPE_IN_ROWS

  # inverse (rows -> altitude): tests sweep here so the tape moves at a
  # constant rows/s through every segment
  altInvRows = (r) ->
    p = r / TAPE_IN_ROWS
    for s in ALT_SEGS
      return s[0] + (p - s.pos0)/s.ips if p <= s.pos0 + s[2] + 1e-9
    ALT_MAX

  # Hdot tape legend scale (rows/fps) and type size, solved from reference
  # imagery captured at hdot = -164 (readout band half-height 0.85; a
  # strMEDS glyph at scale f drawn at y spans y..y+0.9f, so centred on a
  # value line yV it runs yV-0.5f .. yV+0.4f):
  #   '-180' (16 fps below) top touches the readout box bottom: 16s - 0.5f = 0.85
  #   '-240' (76 fps below) bottom sits on the frame bottom:    76s + 0.4f = h/2
  # -> f = 32s - 1.7 ; s = (h/2 + 0.8*0.85)/88.8, then sized down 5% and
  # respaced anchored at the tape bottom ('-240' ink atop the frame line,
  # inset by the stroke half-width + halo ~2px), and the final labels run
  # a further 5% smaller than the size the spacing was solved at.
  HD_H = 15.57
  PXY = 38.32/1024                             # one display pixel in row units
  HD_F0 = 0.95 * (32*((HD_H/2 + 0.8*0.85)/88.8) - 1.7)
  HD_S = (HD_H/2 - 0.409*HD_F0 - 2*PXY) / 76   # rows per fps, |hdot| <= 1000
  HD_F = 0.95 * HD_F0                          # label type size
  # above 1000 fps the spec compresses to 500-fps labels ('1.5K') with
  # 100-fps centre marks; no tape inches are given, so the compressed scale
  # keeps the mark rhythm (100-fps marks at the 10-fps mark pitch): s/10
  HD_SHI = HD_S/10
  HDOT_MAX = 3000

  # linear interpolation down a [mach, ...] table column, clamped at the ends
  _lerpTable: (tbl, m, col) ->
    return tbl[0][col] if m <= tbl[0][0]
    for i in [1...tbl.length]
      if m <= tbl[i][0]
        f = (m - tbl[i-1][0]) / (tbl[i][0] - tbl[i-1][0])
        return tbl[i-1][col] + f*(tbl[i][col] - tbl[i-1][col])
    tbl[tbl.length-1][col]

  drawAMI: () ->
    @ami =new THREE.Object3D()
    # Alpha/Mach Indicator (AMI) – Provides NAV derived and
    # barometric angle of attack (α) in degrees, and velocity in
    # Knots Equivalent Airspeed (KEAS) or Mach number. The source of
    # the data is determined by the AIR DATA switch (Left, Right, or
    # NAV). Both tapes scroll up and down within their respective
    # windows, with the tape digital value provided in a
    # white-on-black background format in a box at the tape’s
    # center. The tape displays the Mach value, and the digital
    # readout below the tape shows KEAS, for all major modes except
    # MM 305 and 603. For MM 305 and 603, the digital readout and
    # tape values will swap at M < 0.9. The digital readout label
    # will also change from “KEAS” to “M”. Likewise, the label above
    # the velocity tape changes with major mode and RTLS flyback
    # status. In MM 101, 102, 304, 305, 602, and 603, the label will
    # be “M/VR” indicating relative velocity is displayed. In MM 103
    # and 104, “M/VI” is displayed indicating inertial velocity.
    # During Powered RTLS (MM 601), prior to PPA, the label will be
    # “M/VI” indicating inertial velocity, and after PPA “M/VR”
    # indicating relative velocity.
    #
    # Invalid data is indicated when a tape is replaced by a blank
    # red box.
    #
    # In MM 102/103 and 601, a beta value (in degrees) is provided
    # below the alpha tape. “L” and “R” indicate the yaw steering
    # required to null the beta value, and used in conjunction with
    # the “E” bearing pointer. Note: Due to a coding limitation,
    # there is a brief window during RTLS flyback (between VREL = 0
    # and alpha = 90 degrees) when the beta sense will not be
    # consistent with the “E” bearing pointer, and the two
    # indicators will appear to be in conflict. This is due to
    # vehicle attitude and relative motion, but will be corrected
    # once vehicle acceleration is high enough to cause alpha to
    # decrease from 90 degrees. Both the “E” pointer and Beta
    # digital blank at altitude > 200K or MET > 2:30, whichever
    # occurs first. Resolution of the digital is one decimal place.
    #
    # Alpha is shown in a scrolling window with a fixed pointer
    # indicating the current angle of attack in one degree
    # increments. The digital decimal value is provided as part of
    # the pointer using white numbers on a black background.
    # Positive alpha values are black numbers on a white background,
    # and negative values are white numbers on a black background. A
    # Max L/D diamond (2a in the illustration) indicates the optimum
    # alpha value for maximum lift over drag flying techniques. The
    # L/D diamond is displayed when Mach < 3.0.
    #
    # A green maximum and minimum alpha bar (2b in the illustration)
    # is provided in both PASS and BFS MM 304, 305, 602, and 603,
    # with the exception of contingency aborts. Note: When using low
    # alpha techniques during aborts, the alpha bar may not be
    # visible.
    #
    # Ranges:
    #           Alpha +/- 180 degrees
    #           Mach/Velocity - Mach 0-4, 4K - 27K fps, 0 - 500 KEAS
    #
    #################
    # velocity tape #
    #################
    # Tape face per spec: mach 0.0-4.0 over 16.00 in and 4.0-27.0 (VR/VI as
    # Kfps) over 92.0 in — both exactly 4 in per unit, so one uniform scale.
    # Labels every 0.2 with the integers suffixed ("0.0M".."3.0M", then
    # "4.0K".."27.0K"); the unlabeled 0.1 positions carry 0.25 in centred
    # ticks below 4.0 and 0.17 in left-edge ticks above. KEAS face: 0-500
    # over 50.00 in (1 in per 10 KEAS), labels every 10, 0.27 in centred
    # ticks at the 5s. White face + outline, black markings, 0 at the
    # bottom (bare background past the tape ends).
    #
    # The tape shows mach except in MM 305/603 below M 0.9 (on the HAC),
    # where the tape and the digital readout below it swap: KEAS on the
    # tape, mach in the readout. The label above the tape is M/VR
    # (relative) or M/VI (inertial: MM 103/104, and MM 601 before PPA).
    AMI_OFF = [0.075, 0.187]     # group nudge (right ~2px, down ~5px); clips follow
    mm = @data().majorMode
    mach = @data().mach ? 0
    keas = @data().keas ? 0
    swap = mm in [305, 603] and mach < 0.9
    velLbl = if mm in [103, 104] or (mm == 601 and not @data().ppa) then "M/VI" else "M/VR"
    vx0 = 1.8 ; vw = 4.75 ; vcx = vx0 + vw/2
    vOpts = {center:true, lblScale:1.2, rdScale:1.2, clipOff:AMI_OFF}
    # an invalid tape is the solid red rectangle, as the AVVI's
    machOK = @data().machValid ? true
    keasOK = @data().keasValid ? true
    alphaOK = @data().alphaValid ? true
    if swap and not keasOK or not swap and not machOK
      @ami.add @d.str 2.25,3.24,(if swap then "KEAS" else velLbl), @d.c2h.darkGray, 1, .9
      @ami.add @_redTape vx0, 4.4, vw, 15.57
    else if swap
      @ami.add @d.str 2.25,3.24,"KEAS", @d.c2h.darkGray, 1, .9
      @ami.add @scrollTape vx0, 4.4, vw, 15.57, keas, 10, 0.1*TAPE_IN_ROWS, Object.assign(vOpts, {id:'ami-keas', tickW:0.27*TAPE_IN_COLS, range:[0, 500]})
    else
      # above M 4 the tape value is velocity in Kfps, continuing seamlessly
      # from the mach face (M 4 ~ 4000 fps at entry altitudes)
      tapeV = if mach < 4 then mach else Math.max(4, (@data().vel ? 0)/1000)
      machLbl = (V) ->
        v = Math.round(V*10)/10
        s = v.toFixed(1)
        if v == Math.round(v) then s + (if v >= 4 then "K" else "M") else s
      machTick = (Vt) -> if Vt < 4 then [vcx - 0.125*TAPE_IN_COLS, vcx + 0.125*TAPE_IN_COLS] else [vx0, vx0 + 0.17*TAPE_IN_COLS]
      @ami.add @d.str 2.25,3.24, velLbl, @d.c2h.darkGray, 1, .9
      @ami.add @scrollTape vx0, 4.4, vw, 15.57, tapeV, 0.2, 4*TAPE_IN_ROWS, Object.assign(vOpts, {id:'ami-mach', digits:(if tapeV < 4 then 2 else 1), tickW:1, lblFn:machLbl, tickFn:machTick, range:[0, 27]})

    # digital readout below the tape: KEAS normally; the mach/velocity value
    # (under the M/VR / M/VI label) when swapped. Positions were pixel-tuned
    # in unshifted screen coords before this moved into the AMI group, so
    # the child group backs the AMI nudge out.
    blo = new THREE.Object3D()
    blo.position.set(-AMI_OFF[0], -AMI_OFF[1], 0)
    bloVal = if swap then (if machOK then mach.toFixed(2) else "") else (if keasOK then "#{Math.round(keas)}" else "")
    blo.add @d.box 1.925,20.911,6.625,22.661, @d.c2h.darkGray
    blo.add @d.str 2.69,23.011, (if swap then velLbl else "KEAS"), @d.c2h.darkGray, 0.9, 0.9
    # value anchor tuned on the 4-char "0.48"; shorter strings centre on it
    blo.add @d.strMEDS 2.41 + (4 - bloVal.length)*0.94/2, 21.43, bloVal, @d.c2h.white, 1.25, 0.94
    # Beta digital, under the alpha tape: "In MM 102/103 and 601, a beta
    # value (in degrees) is provided below the alpha tape. 'L' and 'R'
    # indicate the yaw steering required to null the beta value, and used in
    # conjunction with the 'E' bearing pointer. ... Both the 'E' pointer and
    # Beta digital blank at altitude > 200K or MET > 2:30, whichever occurs
    # first. Resolution of the digital is one decimal place."
    # (JSC-48017/6-9 item 2; the blanking is the validity of message 1
    # word 29, MEDS_BETAHVR_VALID.)  Figure 6-8 shows the field as L00.1.
    # Which sign takes L is fitted: positive sideslip is nulled with right
    # yaw.
    if @data().beta?
      b = Math.max(-99.9, Math.min(99.9, @data().beta))
      bt = (if b < 0 then "L" else "R") + ("0" + Math.abs(b).toFixed(1))[-4..]
      blo.add @d.box BETA_X[0], 20.911, BETA_X[1], 22.661, @d.c2h.darkGray
      bcx = (BETA_X[0] + BETA_X[1])/2
      blo.add @d.strMEDS bcx - (bt.length-1)*0.94/2 - 0.455, 21.43, bt, @d.c2h.white, 1.25, 0.94
      blo.add @d.str bcx - 1.585, 23.011, "Beta", @d.c2h.darkGray, 0.9, 0.9
    @ami.add blo

    # # ######## 
    # # # α tape
    # # ########
    @ami.add @d.str 8.85,3.28,"α", @d.c2h.darkGray, 1.2   # just left of tape centre (per reference), baseline to the KEAS label

    # "Alpha is shown in a scrolling window with a fixed pointer indicating
    # the current angle of attack in one degree increments. The digital
    # decimal value is provided as part of the pointer using white numbers
    # on a black background. Positive alpha values are black numbers on a
    # white background, and negative values are white numbers on a black
    # background. A Max L/D diamond indicates the optimum alpha value for
    # maximum lift over drag flying techniques, and is displayed when
    # M < 3.0." (tables + green alpha min/max bar: see ALPHA_* above)
    # "The BFS only supports the velocity and alpha tapes in glided flight
    # (MM 304, 305, 602, 603), although the Beta digital is available until
    # MECO."
    # Range: -180..180 deg. Positive face white w/ background-colour labels
    # and ticks; negative face grey w/ white halo'd labels and ticks; the
    # 0 tick is white and rides over the background-colour face boundary.
    # (mm/mach already pulled from the feed by the velocity tape above.)
    # readout slightly smaller than the tape numerals; rdDx holds its right
    # edge as it shrinks about the centred anchor, rdDy lifts it 1px
    aOpts = {digits:1, tickW:0, pointer:true, signed:true, center:true,
             border:true, lblScale:1.2, rdScale:1.2, rdAdv:0.9, rjust:true, rdDx:-0.43, rdDy:-0.05,
             grayFace:@d.c2h.lightGray,
             rightTicks:{step:1, len:0.75}, clipOff:AMI_OFF}
    aTbl = if mm in [304, 305] then ALPHA_LIM_ENTRY
    else if mm in [602, 603] then ALPHA_LIM_GRTLS
    else null
    if aTbl?
      aOpts.greenBar = [@_lerpTable(aTbl, mach, 2), @_lerpTable(aTbl, mach, 1)]
    if mach < 3.0
      aOpts.diamond = @_lerpTable(ALPHA_MAXLD, mach, 1)
    if alphaOK
      @ami.add @scrollTape 7.4, 4.4, 4.75, 15.57, @data().alpha, 5, 0.685, Object.assign(aOpts, {id:'alpha'})
    else
      @ami.add @_redTape 7.4, 4.4, 4.75, 15.57

    @ami.position.set(AMI_OFF[0], AMI_OFF[1], 0)   # nudge left tapes right ~2px, down ~5px
    return @ami

  # The beta digital box sits under the alpha tape and spans it.
  BETA_X = [7.4, 12.15]

  makeClipWin: (clipBox) ->
    m = new THREE.MeshBasicMaterial {side:THREE.DoubleSide, wireframe:false, color:@d.c2h.black}

    g = new THREE.BufferGeometry()
    v = new Float32Array( [
      0,          0, 0,           # 0
      clipBox.x, 0, 0,           # 1
      clipBox.y, 0, 0,           # 2
      53,         0, 0,           # 3
      
      0,          clipBox.z, 0,  # 4
      clipBox.x, clipBox.z, 0,  # 5
      clipBox.y, clipBox.z, 0,  # 6
      53,         clipBox.z, 0,  # 7
      
      0,          clipBox.w, 0,  # 8
      clipBox.x, clipBox.w, 0,  # 9
      clipBox.y, clipBox.w, 0,  # 10
      53,         clipBox.w, 0,  # 11
      
      0,          37,         0,  # 12
      clipBox.x, 37,         0,  # 13
      clipBox.y, 37,         0,  # 14
      53,         37,         0   # 16
    ])
    i = [0, 1, 12, 12, 1, 13,
         1, 2, 5, 5, 2, 6, 
         2, 3, 14, 14, 3, 15,
         9, 10, 13, 13, 10, 14
        ]
    console.log(v)
    console.log(i)
    menuMask = new THREE.PlaneGeometry(52, 5)
    g.setIndex(i)
    g.setAttribute('position', new THREE.Float32BufferAttribute( v, 3 ))
    console.log(g)
    m = new THREE.Mesh(g, m)
    m.position.z = 98
    
    return m

  # green pointer arrows, shared by the ADI-case gauges and the radar-alt
  # pointer: green fill with the dark halo on the OUTSIDE only — a black
  # underlay at the full arrow footprint (so the overall size is exactly
  # the points given) with the green fill inset a uniform rim. Each vertex
  # pulls in along its angle bisector by rim/sin(half-angle), so sharp tips
  # pull in further and the rim runs constant-width along every edge. axr
  # is the px-per-x-unit / px-per-y-unit ratio of the drawing space, so the
  # rim stays uniform on screen (cols vs rows for the tapes; the ADI case's
  # stretched gauge units are near-isotropic at ~1.08). Both fills ride the
  # transparent pass over scale strokes, labels, and tape frames.
  GA_RIM = 2 * 38.32/1024              # rim thickness, rows (~2px)
  GA_SCL = 1.25                        # overall arrow scale
  GA_ASP = 38.32/52.2425               # rim aspect for arrows drawn in col/row space
  _greenArrow: (pts, axr=1.0) ->
    # arrows scale about their TIP (pts[1] at every call site), so the
    # point keeps indicating the exact value position as the body grows
    tip = pts[1]
    pts = ([tip[0] + (p[0]-tip[0])*GA_SCL, tip[1] + (p[1]-tip[1])*GA_SCL] for p in pts)
    n = pts.length
    inner = for i in [0...n]
      p = pts[i] ; a = pts[(i+n-1)%n] ; b = pts[(i+1)%n]
      d1 = [(a[0]-p[0])*axr, a[1]-p[1]] ; l1 = Math.hypot(d1[0], d1[1])
      d2 = [(b[0]-p[0])*axr, b[1]-p[1]] ; l2 = Math.hypot(d2[0], d2[1])
      d1 = [d1[0]/l1, d1[1]/l1] ; d2 = [d2[0]/l2, d2[1]/l2]
      bis = [d1[0]+d2[0], d1[1]+d2[1]] ; lb = Math.hypot(bis[0], bis[1])
      cosT = d1[0]*d2[0] + d1[1]*d2[1]
      m = GA_RIM / Math.max(0.1, Math.sqrt(Math.max(0.001, (1 - cosT)/2)))
      [p[0] + bis[0]/lb*m/axr, p[1] + bis[1]/lb*m]
    g = new THREE.Object3D()
    for [pp, clr, ord] in [[pts, @d.c2h.black, 2], [inner, @d.c2h.green, 3]]
      t = @d.tri pp[0][0], pp[0][1], pp[1][0], pp[1][1], pp[2][0], pp[2][1], null, clr
      t.material.transparent = true
      t.renderOrder = ord
      g.add t
    g

  # invalid-data presentation: the tape keeps its window-frame + readout-box
  # geometry but both render as empty red outlines — no face, marks, value,
  # or pointers
  _redTape: (x0, y0, w, h, boxDy=0) ->
    g = new THREE.Object3D()
    g.add @d.box x0, y0, x0+w, y0+h, @d.c2h.red
    bcy = y0 + h/2 + boxDy
    g.add @d.box x0, bcy-0.85, x0+w, bcy+0.85, @d.c2h.red
    g

  # marks provider for the piecewise altitude tape: label/tick grids straight
  # off ALT_SEGS. Faces: grey below 0 (white bordered text/marks), yellow
  # 0-2000 during entry, white above (black text, thin black ticks). Formats:
  # full feet up to 4000 ('1800', '2000', ... '4000'), the 'K' abbreviation
  # from 5K on every label ('5K','6K',...,'400K'), nmi with 'M' at 400K+.
  _altMarks: (x0, w, entry) ->
    cx = x0 + w/2
    fmt = (si, v) ->
      switch
        when si == 6 then "#{Math.round(v/NM_FT)}M"
        when v >= 5000 then "#{Math.round(v/1000)}K"
        else "#{Math.round(v)}"
    grayLbl = {c: @d.c2h.white, border: @d.c2h.black}
    () =>
      labels = {}
      for s, si in ALT_SEGS
        st = s[3]
        for k in [Math.ceil((s[0]-1)/st)..Math.floor((s[1]+1)/st)]
          v = k*st
          continue if v < s[0] - 1 or v > s[1] + 1
          labels[Math.round(v)] = {v, txt: fmt(si, v), c: (if v < 0 then grayLbl else @d.c2h.black)}
      ticks = []
      for s in ALT_SEGS
        st = s[4] ; tw = s[5]*TAPE_IN_COLS
        [xa, xb] = switch s[6]
          when 'l' then [x0, x0 + tw]                # left edge of the tape
          when 'r' then [x0 + w - tw, x0 + w]        # right edge
          else [cx - tw/2, cx + tw/2]                # centred
        for k in [Math.ceil((s[0]-1)/st)..Math.floor((s[1]+1)/st)]
          v = k*st
          continue if v < s[0] - 1 or v > s[1] + 1 or labels[Math.round(v)]?
          ticks.push {v, x0: xa, x1: xb, thin: v >= 0, c: (if v < 0 then grayLbl else null)}
      faces = [
        {v0: ALT_MIN, v1: 0, fill: @d.c2h.darkGray, padLo: true}
        {v0: 0, v1: 2000, fill: (if entry then @d.c2h.yellow else @d.c2h.white)}
        {v0: 2000, v1: ALT_MAX, fill: @d.c2h.white, padHi: true}
      ]
      {faces, labels: (L for own kk, L of labels), ticks}

  # map + marks for the piecewise Hdot tape (odd-symmetric about 0):
  # 20-fps labels / 10-fps centre marks to ±1000, then 500-fps labels
  # ('1.5K','2K',...) / 100-fps centre marks to ±3000 at the compressed
  # HD_SHI scale. Colours follow the signed convention: black on the white
  # (climbing) face, white with the dark halo on the grey (descending) face,
  # 0 white riding the boundary rule.
  _hdotTape: (x0, w) ->
    map = (v) ->
      a = Math.abs(v) ; sg = (if v < 0 then -1 else 1)
      sg * (Math.min(a, 1000)*HD_S + Math.max(0, a - 1000)*HD_SHI)
    cx = x0 + w/2
    fmtK = (v) ->
      "#{if v < 0 then '-' else ''}#{(Math.abs(v)/1000).toFixed(1).replace('.0', '')}K"
    lclr = (v) => if v > 0 then @d.c2h.black else {c: @d.c2h.white, border: @d.c2h.black}
    marks = () =>
      labels = [] ; ticks = []
      for v in [-980..980] by 20
        labels.push {v, txt: "#{v}", c: lclr(v)}
      for a in [1000..HDOT_MAX] by 500
        labels.push {v: a, txt: fmtK(a), c: lclr(a)}
        labels.push {v: -a, txt: fmtK(-a), c: lclr(-a)}
      for v in [-990..990] by 10 when v % 20 != 0
        ticks.push {v, x0: cx-1, x1: cx+1, c: lclr(v)}
      for a in [1100...HDOT_MAX] by 100 when a % 500 != 0
        for v in [a, -a]
          ticks.push {v, x0: cx-1, x1: cx+1, c: lclr(v)}
      faces = [
        {v0: -HDOT_MAX, v1: 0, fill: @d.c2h.darkGray, padLo: true}
        {v0: 0, v1: HDOT_MAX, fill: @d.c2h.white, padHi: true}
      ]
      {faces, labels, ticks}
    {map, marks}

  drawAVVI: () ->
    avvi = new THREE.Object3D()
    # Altitude/Vertical Velocity Indicator (AVVI) – Provides
    # NAV-derived or barometric altitude in feet (ft), and
    # NAV-derived and barometric altitude rate in feet/second (fps).
    # During landing, the tape will display NAV altitude, but a
    # radar altitude pointer will point to the radar altitude on the
    # NAV tape, and the embedded digital will indicate valid radar
    # altitude with an “R”. Calibrated barometric data is selected
    # in TAEM by positioning the AIR DATA switch to select the left
    # or right probe. Starting at ground level (0 feet), the
    # altitude tape numerical value increments every 50 feet, with
    # 10 foot marks along the center of the tape up to 200 feet.
    # From 200 to 1000 feet, the values increment every 200 feet,
    # with marks every 100 feet. Beginning at 2000 feet altitude,
    # the tape values transition to thousands of feet (indicated by
    # a following “K” at 5000 feet), with numbers every 1000 feet,
    # and marks every 500 feet up to 30K feet. From 30K to 100K,
    # numbers increment every 5K feet, with marks every 1K feet.
    # Beginning at 100K, the marks are moved to the left side of the
    # tape, and numbers incremented every 50K feet up to 400K. Above
    # 400K feet altitude, the scale transitions to nautical miles
    # (nmi), indicated by a following “M”. Altitude numerical value
    # is then incremented every 5 nmi beginning at 70 nmi, with
    # marks along the right side of the tape every nautical mile up
    # to 165 nm. Numbers and marks are black on a white background.
    # During Entry and below 2000 feet, the tape background
    # transitions from white to yellow. Invalid data is indicated
    # when a tape is replaced by a blank red box.
    #
    # Ranges:
    #       Altitude - -1100 to 2000 ft. (blank), 
    #                   30K - 400K ft (K), 
    #                   66 - 165 nautical miles (M), 
    #                   0 - 5000 ft (R)
    #       Altitude Rate - -3000 to 3000 fps
    #
    # Altitude (H) piecewise scrolling tape (ALT_SEGS): the embedded digital
    # shows radar altitude with an 'R' when valid (entry, < 5000 ft), and a
    # green radar-altitude pointer rides the NAV tape. Invalid altitude data
    # replaces the tape with a blank red box.
    avvi.add @d.str 43,3.25,"H", @d.c2h.darkGray, 1, .9
    hx0 = 40.75 ; hy0 = 4.4 ; hw = 4.75 ; hh = 15.57
    alt = @data().altitude ? 0
    entry = @data().majorMode in [304, 305, 602, 603]
    if @data().altValid ? true
      radarOK = entry and (@data().radarValid ? false) and 0 <= (@data().radarAlt ? -1) < 5000
      # digital: same abbreviation + precision as the tape labels — full
      # feet below 5000 ('2432'), then '12K', then nmi ('91M'). With radar
      # valid the digital shows radar altitude, its digits nudged left to
      # clear the half-size grey 'R' hugging the tape's right border.
      rdStr = if radarOK then "#{Math.round(@data().radarAlt)}"
      else if alt >= 400000 then "#{Math.round(alt/NM_FT)}M"
      else if alt >= 5000 then "#{Math.round(alt/1000)}K"
      else "#{Math.round(alt)}"
      hOpts = {id:"avvi-h#{if entry then '-e' else ''}", center:true, lblScale:1.15, rdScale:1.25, rdStr:rdStr, map:altMapRows, marks:@_altMarks(hx0, hw, entry)}
      # in the region where the radar 'R' may engage, pack the readout
      # digits tighter and to the left so they clear the R — layout keyed
      # to the region (not the lock) so the digits don't jump at lock-on
      if entry and alt < 5000
        hOpts.rdDx = -0.45
        hOpts.rdAdv = 0.85
      avvi.add @scrollTape hx0, hy0, hw, hh, alt, 1, 0, hOpts
      if radarOK
        # light-grey 'R' at 3/4 readout size: right ink edge against the
        # tape border (ink metrics per the strMEDS notes in scrollTape:
        # right edge x-1+1.726s, centre 0.33s below the origin), vertically
        # centred on the readout line, above the box fill like the readout
        rs = 1.25*0.75
        rg = @d.strMEDS hx0 + hw - 0.08 + 1 - 1.726*rs, hy0 + hh/2 - 0.33*rs, "R", @d.c2h.lightGray, rs
        rg.traverse (o) -> o.renderOrder = 3 if o.isMesh
        avvi.add rg
        # radar-altitude pointer, same style as the page's other green
        # arrows: rides the tape's RIGHT edge pushed outward (tip just
        # inside the frame, most of the arrow overhanging), pointing left
        # at the radar altitude on the NAV tape
        yR = hy0 + hh/2 - (altMapRows(@data().radarAlt) - altMapRows(alt))
        if hy0 + 0.2 < yR < hy0 + hh - 0.2
          xe = hx0 + hw
          avvi.add @_greenArrow [[xe+0.96, yR-0.6], [xe-0.26, yR], [xe+0.96, yR+0.6]], TAPE_IN_ROWS/TAPE_IN_COLS
    else
      avvi.add @_redTape hx0, hy0, hw, hh

    # Altitude-rate (Hdot) piecewise scrolling tape (see the HD_* notes for
    # the reference-derived scale/type size and the >1000-fps compression)
    px = 52.2425/1024                          # one display pixel in column units
    hdX = 47.4 - 3*px ; hdW = 4.5 + 3*px       # frame: 3px left of the
    # H tape gap, widened 2px on the left / 1px on the right per reference
    # title: 'H' overstruck with the DEU upper-centered-dot glyph (˙, cell
    # c696) to mark the derivative; the deu glyph cell spans x-0.05..x+0.85
    # so the visual centre sits at x+0.4 -> centre the cell over the tape
    for hc in ["H", "˙"]
      avvi.add @d.str hdX + hdW/2 - 0.4, 3.25, hc, @d.c2h.darkGray, 1, .9
    if @data().hdotValid ? true
      hd = @_hdotTape(hdX, hdW)
      avvi.add @scrollTape hdX, 4.4, hdW, HD_H, @data().hdot, 20, HD_S, {id:'avvi-hdot', signed:true, border:true, lblScale:HD_F, center:true, advF:0.75, rdScale:1.3, rdAdv:1.0, rdLeadUp:PXY, rjust:true, boxDy:-2*PXY, map:hd.map, marks:hd.marks}
    else
      avvi.add @_redTape hdX, 4.4, hdW, HD_H, -2*PXY

    return avvi
            

  drawAccMeter: (xc, yc, rad, min, max) ->
    @accMeter = new THREE.Object3D()
    @accMeter.name = "accMeter"
    # Vehicle Acceleration Meter – A vehicle acceleration meter (or
    # G-meter) is provided in PASS MM 102, 103, 304, 305, 601, 602,
    # & 603. The function of the meter is different in powered and
    # glided flight, with the label changing to reflect the data
    # being displayed. In powered flight, the meter reflects
    # IMU-derived vehicle acceleration and is labeled “Accel”.
    # During glided flight, the meter displays the RM selected AA NZ
    # value and is labeled “NZ”. Both are represented by a digital
    # value and a green needle. A magenta target NZ line is provided
    # during MM 602 showing the target NZ value in glided flight.
    #
    # Range: -1 to 4 g
    #
    mm = @data().majorMode
    if mm not in [102, 103, 304, 305, 601, 602, 603]
      return

    mat = @d.c2h.darkGray
    ASP = 1.47222        # @d.arc/arcTicks' default row->col stretch
    # the circular scale — and with it the needle's rotation centre —
    # rides 2px above and 2px left of the label reference centre
    # (photo-matched)
    xS = xc - 2/13.783 ; yS = yc - 2/18.79
    # scale geometry: min (-1g) at 45°, max (4g) at 270°, y-down angles
    ang = (v) -> deg2rad(45 + (270-45) * (v - min)/(max - min))
    pt = (v, r) ->
      a = ang(v)
      [xS + r*Math.cos(a)*ASP, yS + r*Math.sin(a)]

    bx0 = xc+0.60 ; by0 = yc-2.06 ; bx1 = xc+5.48 ; by1 = yc-0.41
    bcx = (bx0+bx1)/2

    # The scale (arc, ticks, labels, value box, mode label) is static per
    # mode label — built once, kept alive across rebuilds; only the needle,
    # target-NZ line, and digital readout are per-update.
    key = if mm in [102, 103] then 'accel' else 'nz'
    @_accCache ?= {}
    if not @_accCache[key]?
      sg = new THREE.Object3D()
      sg.userData.keepAlive = true
      # background (value box + digitals ride with the meter centre):
      sg.add @d.arc xS, yS, rad, 45, 270,mat
      sg.add @d.arcTicks xS,yS,rad,45,270,45,.33,mat
      # scale labels, individually photo-nudged off their nominal ring spots
      # (ring = centre (xc-.3, yc-.5), radius rad+1); "-1" additionally uses
      # a tight advance pulling the '-' against the '1'
      sg.add @d.strMEDS xc-0.23, yc+3.09, "0", mat, scale=0.8, advance=0.9, scalex=1.0
      sg.add @d.strMEDS xc-3.92, yc+1.96, "1", mat, scale=0.8, advance=0.9, scalex=1.0
      sg.add @d.strMEDS xc-5.42, yc-0.40, "2", mat, scale=0.8, advance=0.9, scalex=1.0
      sg.add @d.strMEDS xc-3.92, yc-3.02, "3", mat, scale=0.8, advance=0.9, scalex=1.0
      sg.add @d.strMEDS xc+3.07, yc+2.20, "-1", mat, scale=0.8, advance=0.55, scalex=1.0
      sg.add @d.box bx0, by0, bx1, by1, mat
      sg.add @d.str bx1-0.82, by0+0.29, "g", mat, scale=.75,advance=.75
      # powered flight (ascent MM) reads IMU-derived acceleration, labelled
      # "Accel"; glided flight reads the RM-selected AA NZ, labelled "Nz"
      # (small-caps z: the meds font has no lowercase). The PAIR is centred
      # under the value box, small z bottom-aligned to the N.
      if mm in [102, 103]
        sg.add @d.str bcx-1.9, by1+0.15, "Accel", mat, scale=.75, advance=.75
      else
        # +0.20/+0.45 rather than +0.15/+0.40: nets out to 1px up on screen
        # after the box's 2px rise
        sg.add @d.str bcx-0.68, by1+0.20, "N", mat, scale=.90, advance=.90, scalex=1.05
        sg.add @d.str bcx+0.72, by1+0.45, "Z", mat, scale=.65, advance=.65
      @_accCache[key] = sg
    @accMeter.add @_accCache[key]

    # MM 602 only: magenta target NZ line, running from the hub (the same
    # centre the green arrow pivots on) out just past the scale arc
    if mm == 602 and @data().targetNZ?
      @accMeter.add @d.line [pt(@data().targetNZ, 0), pt(@data().targetNZ, rad+0.5)], @d.c2h.magenta

    val = @data().vehicleAcceleration
    if val?
      v = Math.max(min, Math.min(max, val))
      # green needle, no outline: one filled polygon — a stem rectangle
      # (squared-off base, not a round line cap) plus the head triangle,
      # its base 3px proud of the stem each side (row units, 18.79 px/row)
      STEM_PX = 5
      a = ang(v)
      sw = (STEM_PX/2) / 18.79
      hw = (STEM_PX/2 + 4) / 18.79
      pxu = -Math.sin(a)*ASP ; pyu = Math.cos(a)    # perpendicular direction
      c0 = pt(v, -0.15)         # tail runs past the pivot, like a shaft-mounted needle
      bb = pt(v, rad-0.94)
      tp = pt(v, rad-0.25)
      ageom = new THREE.BufferGeometry()
      ageom.setAttribute 'position', new THREE.Float32BufferAttribute(new Float32Array([
        c0[0]+pxu*sw, c0[1]+pyu*sw, 0
        bb[0]+pxu*sw, bb[1]+pyu*sw, 0
        bb[0]-pxu*sw, bb[1]-pyu*sw, 0
        c0[0]-pxu*sw, c0[1]-pyu*sw, 0
        bb[0]+pxu*hw, bb[1]+pyu*hw, 0
        bb[0]-pxu*hw, bb[1]-pyu*hw, 0
        tp[0], tp[1], 0
      ]), 3)
      ageom.setIndex [0,1,2, 0,2,3, 4,6,5]
      @accMeter.add new THREE.Mesh(ageom, new THREE.MeshBasicMaterial({color: @d.c2h.green, side: THREE.DoubleSide}))
      @accMeter.add @d.strMEDS bx0+0.10, by0+0.35,
                    spad(val.toFixed(1)),
                    @d.c2h.white, scale=1.2,advance=.82

    @accMeter.position.y = 0.374   # shift acc meter down ~10px
    return @accMeter

  drawADI: (xc,yc,valid=true) ->
    @adi = new THREE.Object3D()
    @adi.name = "ADI"

    # ADI circular space
    #
    # Children of @adiC are authored in a circular frame: origin at the ball
    # centre, BOTH axes in row units, so a radius means the same thing in x
    # and y and circles are round by construction. The group transform then
    # stretches x by AX = 1.3632 (the true row->col pixel ratio, =
    # glyphStrokes AR 18.789/13.783) times ADI_STRETCH, the slight horizontal stretch the
    # real MEDS ADI shows against the menu-matched reference overlay.
    # Tune ADI_STRETCH against the F8 overlay; 1.0 = perfect circle.
    ADI_STRETCH = 1.08
    AX = 1.3632 * ADI_STRETCH
    @adiC = new THREE.Object3D()
    @adiC.name = "ADIcircular"
    @adiC.scale.x = AX
    @adiC.position.set(xc, yc, 0)
    @adi.add @adiC
    # text in local coords with unstretched glyph shapes: undo AX on the
    # glyph geometry (scalex, advance) and on glyphStrokes' baked-in x-1
    # origin offset, so only the *position* follows the stretch
    ltxt = call(@, '_adiLocalText', AX)
    @adiLtxt = ltxt          # the dynamic overlay redraw reuses this helper
    # Attitude Determination Indicator (ADI) – Simulated enclosed
    # ball and digital readouts. The ball provides three degrees of
    # freedom, allowing it to be positioned in response to software-
    # generated commands corresponding to the Orbiter roll, pitch,
    # and yaw attitude. The numbers on the ball and around the case
    # are angle magnitudes, with the trailing zero deleted for
    # simplicity. The digital readout (5a in the illustration) is
    # expressed in Orbiter Roll, Pitch, and Yaw corresponding to the
    # ADI ATTITUDE switch setting (INRTL, LVLH, or REF). A vehicle
    # symbol is provided fixed to the center of the ADI window as a
    # reference.
    #
    # PASS ADI sequencing is as follows:
    #       [JSC-48017/6-10]
    # BFS ADI sequencing is as follows:
    #       [JSC-48017/6-12]
    #

    # ADI Theta Limit Bracket – A green limit bracket available
    # while M < 2 if either 1) air data is inhibited to G&C, 2) no
    # ADTA/probes are available, or 3) an air data dilemma exists
    # (AD DG flag set to 0). The upper and lower bracket represent
    # the theta high and low limits, respectively, as determined by
    # guidance. The bracket is dynamic and varies with bank angle.
    # The limits are the same as the theta limit indicators
    # available on the VERT SIT display.
    #

    # Vehicle reference symbol – fixed to the centre of the ADI window
    # (green). Two layers:
    #   under: the 'U' — filled half-annulus index bowl whose ends continue
    #     outward as thick wing bars all the way to the arm tips, the whole
    #     shape black-outlined
    #   over: thin dark-halo cross strokes, stopping VTIP short of the tips
    # The wing green is exactly as wide as the cross stroke + halo, so
    # inboard the cross covers it and the wing's black border stacks
    # just outside the cross halo (reads as thicker dark edging); the last
    # bare VTIP of wing past the cross end reads as the thick green tips.
    # Pitch and yaw attitude are read against it at the display centre.
    VC = 2.85 ; VTIP = 0.58   # horizontal half-span: wings + cross bar
    VCV = 2.55                # the vertical cross arm keeps its old reach
    # vertical arm half-lengths (unchanged; top a tad longer than bottom)
    varmB = VCV - (2/3)*VTIP - 0.15
    varmT = varmB + 0.15
    # error needle inner ends: per reference the needles run a little
    # short of the cross/arm tips — NSET sets them back
    NSET = 0.25
    @adiNIN = VCV - (2/3)*VTIP + NSET     # pitch needle (right)
    @adiNINv = @adiNIN - 0.15             # yaw needle (bottom)
    @adiNINtop = @adiNINv + 0.15          # roll needle (top)
    gBorder = {c: @d.c2h.green, border: @d.c2h.black}
    # render-order plan (order beats z in THREE's transparent sort):
    #   0/1 needle halos/cores (magenta, under everything green)
    #   2   U black border (wings) + bowl outline
    #   3   U green (wing cores, over the bowl outline at the join)
    #   4/5 cross stroke halo/core, on top of the U
    veh = new THREE.Object3D()
    for ln in [@d.line([[0,-varmT],[0,varmB]], gBorder),
               @d.line([[-(VC-VTIP),0],[VC-VTIP,0]], gBorder)]
      ln.children[0].renderOrder = 4   # black halo
      ln.children[1].renderOrder = 5   # green core
      veh.add ln
    # the 'U': filled half-annulus index bowl under the centre, flat ends
    # joining the wing bars at y=0
    UR0 = 0.55 ; UR1 = 0.95
    outer = [] ; inner = []
    for a in [0..18]
      th = deg2rad(a*10)
      outer.push [UR1*Math.cos(th), UR1*Math.sin(th)]
      inner.push [UR0*Math.cos(th), UR0*Math.sin(th)]
    uverts = []
    for i in [0...18]
      uverts.push outer[i][0],outer[i][1],0, outer[i+1][0],outer[i+1][1],0, inner[i+1][0],inner[i+1][1],0
      uverts.push outer[i][0],outer[i][1],0, inner[i+1][0],inner[i+1][1],0, inner[i][0],inner[i][1],0
    ug = new THREE.BufferGeometry()
    ug.setAttribute 'position', new THREE.Float32BufferAttribute(uverts, 3)
    uGrp = new THREE.Object3D()
    uGrp.add new THREE.Mesh(ug, new THREE.MeshBasicMaterial({color: @d.c2h.green, side: THREE.DoubleSide}))
    # thin dark outline so the joint against the cross bar stays subtle
    @_uOutlineMat ?= makeSDFLineMaterial(THREE, @d.sdfOpt({color: @d.c2h.black, widthPx: 1.4}))
    om = new THREE.Mesh(makeSDFLineGeometry(THREE, outer.concat(inner.slice().reverse(), [outer[0]])), @_uOutlineMat)
    om.frustumCulled = false
    om.renderOrder = 2
    uGrp.add om
    # wing bars: the U continues outward under the cross to the arm tips,
    # green a smidge wider than the cross stroke + halo (LINE_PX+1.8) so
    # the black border lands clear of the halo feather and visibly stacks
    wingW = @d.LINE_PX + 2.4
    @_vthickMat ?= makeSDFLineMaterial(THREE, @d.sdfOpt({color: @d.c2h.green, widthPx: wingW}))
    @_wingBMat ?= makeSDFLineMaterial(THREE, @d.sdfOpt({color: @d.c2h.black, widthPx: wingW + 1.8}))
    for s in [-1, 1]
      wgeom = makeSDFLineGeometry(THREE, [[s*UR0, 0], [s*VC, 0]])
      for [mat, order] in [[@_wingBMat, 2], [@_vthickMat, 3]]
        m = new THREE.Mesh(wgeom, mat)
        m.frustumCulled = false
        m.renderOrder = order
        uGrp.add m
    uGrp.position.z = -0.5    # under the cross (z backup to the order plan)
    veh.add uGrp
    @adiC.add veh
    @adiC.add @d.arc 0,0,8.13,0,360,  @d.c2h.lightGray, 1
    @adiC.add @d.arc 0,0,WIN_R,0,360,  @d.c2h.lightGray, 1
    @adiC.add @d.arcTicks 0,0,WIN_R,0,360,5.0,.24, @d.c2h.lightGray, 1
    # the 30° (long) roll ticks run slightly thicker than the 5° ones
    @_rollTickMat ?= makeSDFLineMaterial(THREE, @d.sdfOpt({color: @d.c2h.lightGray, widthPx: @d.LINE_PX + 1.2}))
    for a in [0...360] by 30
      ca = Math.cos(deg2rad(a)) ; sa = Math.sin(deg2rad(a))
      mt = new THREE.Mesh(makeSDFLineGeometry(THREE, [[WIN_R*ca, WIN_R*sa], [(WIN_R+0.6)*ca, (WIN_R+0.6)*sa]]), @_rollTickMat)
      mt.frustumCulled = false
      @adiC.add mt

    # Roll Labels Around Outer Ring
    # ADI-local circular coords (rows both axes, origin at ball centre)
    # radially shifted out with the enlarged window ring (+0.085)
    outerLabels = [
      [ 6.05,  3.71, "24"],
      [ 3.82,  5.93, "21"],
      [-4.54,  5.92, "15"],
      [-6.73,  3.70, "12"],
      [-6.66, -4.33, "06"],
      [-4.57, -6.57, "03"],
      [ 3.73, -6.61, "33"],
      [ 5.99, -4.36, "30"],
    ]
    for [x,y,l] in outerLabels
      @adiC.add ltxt x, y, l, @d.c2h.lightGray, 0.85, 0.7, 1.0

    # Roll index marks: equal diamonds at the 0/90/180/270 roll positions,
    # inner tip touching the ball window ring (6.6), outer tip standing
    # clear of the outer ring; the error scales draw over them
    for [ux,uy] in [[1,0],[-1,0],[0,1],[0,-1]]
      @adiC.add @d.quad [
          6.77*ux,             6.77*uy,             0.0
          7.26*ux - 0.42*uy,   7.26*uy + 0.42*ux,   0.0
          7.95*ux,             7.95*uy,             0.0
          7.26*ux + 0.42*uy,   7.26*uy - 0.42*ux,   0.0
        ], undefined, @d.c2h.lightGray


    # ADI Attitude Error Needles – The ADI has three needles which
    # provide a continuous indication of vehicle attitude errors in
    # degrees. These needles extend in front of the ADI ball from
    # the top (roll), right (pitch), and bottom (yaw). Each needle
    # has a background scale with graduation marks to allow the crew
    # to deduce the magnitude of the attitude error. The scaling and
    # definition of these errors varies with the parameter, the
    # mission phase, and the error switch setting.
    #
    # The attitude error needles are fly-to indicators. During
    # powered flight (either ascent or OMS/RCS burns), the errors
    # are guidance thrust vector errors. This means that during
    # engine burns, the errors reflect TVC trim errors, and during
    # RCS burns the errors reflect the guidance VGO error. Note that
    # if bad IMU velocity data is processed, the error needles will
    # be incorrect.
    #
    # error scales: magenta arcs ±25° about the top (roll), right (pitch),
    # and bottom (yaw) cardinals; short uniform ticks every 5°, oriented
    # along the needle axis (vertical top/bottom, horizontal right), all
    # extending inward. The needles are data-driven (dynamic overlay).
    # Recessed slightly (z −0.5, behind the needles at −0.2) so the needle
    # halo stays visible where it lands on the scale.
    errScl = new THREE.Object3D()
    errScl.position.z = -0.5
    # black-bordered strokes; the bordered-line render orders (0/1) would
    # beat the needle halo's (0, nearer z) in THREE's sort, so drop the
    # scale to -2/-1 keeping it fully under the needles
    mScl = {c: @d.c2h.magenta, border: @d.c2h.black}
    reorder = (o) ->
      o.children[0].renderOrder = -2   # border
      o.children[1].renderOrder = -1   # core
      o
    for [base, tkx, tky] in [[270, 0, 1], [90, 0, -1], [0, -1, 0]]
      errScl.add reorder @d.arc 0,0, ERR_R, base-25, base+25, mScl, 1
      for a in [base-25..base+25] by 5
        ca = Math.cos(deg2rad(a)) ; sa = Math.sin(deg2rad(a))
        errScl.add reorder @d.line [[ERR_R*ca, ERR_R*sa],[ERR_R*ca + 0.28*tkx, ERR_R*sa + 0.28*tky]], mScl
    @adiC.add errScl
    # (the pitch error scale's labels are feed-driven; _drawADIDyn draws them)

    # ADI Rate Needles
    #
    # '0' labels: ink centred on the centre tick (ink-centre x ≈ lx + 0.11
    # at this size); top baseline / bottom topline hold a short space off
    # the meter line, right one v-centred on its tick and pushed right
    # (the '0' centre marks and the end labels of the three rate scales are
    # feed-driven; _drawADIDyn draws them)


    # (rate pointers, error needles, roll bug and the digital readout are
    # data-driven: they live in the dynamic overlay built by updateADI())
    # Pitch Scale Labels – Reflects the setting of the ADI ERROR
    # switch and displayed in degrees. During TAEM (MM 305 and 603)
    # and Nz hold (MM 602), the Pitch Attitude Error scale is in
    # g’s, and indicated by a “g” next to the scale value.
    #

    # ADI Rate Needles – Provide a continuous indication of vehicle
    # body rates in all supported major modes, except in MM 305 or
    # 603 with the ADI RATE Switch in the Medium (MED) position,
    # when the ADI Rate pointers display the Time to Heading
    # Alignment Cone (HAC) Intercept, Altitude Error, and Crosstrack
    # Error. Roll, pitch, and yaw rates are indicated by the top,
    # right, and bottom pointers, respectively, when the ADI
    # displays vehicle body rates. Time to HAC Intercept, Altitude
    # Error, and Crosstrack Error are indicated by the top, right,
    # and bottom pointers, respectively,
    #
    # when in MM 305/603 and the ADI RATE Switch is in the Medium
    # (MED) position. Graduation marks on either side of the null
    # (center) mark determine the rate magnitude based on full scale
    # range, which varies with the rate switch setting.
    #
    # Rate scale labels correspond to the setting of the ADI rate
    # switch.
    #
    # Rate label table: [JSC-48017/6-13]
    #
    # Rate scales are labeled for all axes and are in deg/sec unless
    # indicated by a suffix. For example, “5K” indicates the rate
    # scale now serves purpose of being a lateral deviation
    # indicator with max scale deflection of 5000 feet. Only the
    # pitch error scale is labeled and is assumed to denote degrees
    # of error except when a suffix is indicated; i.e., 1.2 G.
    #
    # The yaw error needle has the same meaning throughout MM’s 304
    # and 305: estimated sideslip (β). For q-bar < 20 psf, the
    # sideslip angle is INRTL β; i.e., the angle between the +X body
    # axis and the Earth relative velocity. For q-bar ≥ 20 psf,
    # estimated beta is based on NY and yaw jet effectiveness. Full
    # scale on the display is equivalent to the yaw produced by the
    # side force of 2.5 yaw jets.
    #

    # (the OFF flag is data-driven via curData.adiValid and lives in the
    # dynamic overlay; see _drawADIDyn)

    # the ball itself: static geometry, rotated per attitude by updateADI()
    @adiC.add @adiBall()

    @adi.position.y = 0.374   # shift ADI (and its outer circle) down ~10px
    @updateADI()
    return @adi

  # ADI ball
  #
  # Software ball per JSC-18863 fig 8-13. Ball model space: unstretched row
  # units, y down, z toward the viewer, origin at the ball centre:
  #   S(p,w) = R ( cos w (cos p ẑ − sin p ŷ) + sin w x̂ )
  # so pitch increases upward at the front face, yaw increases to the right,
  # and the gimbal poles sit at yaw ±90 (left/right edges at null attitude).
  # Pitch great circles every 30°; yaw belly band plus minor circles at
  # 30/60/300/330; the white hemisphere covers pitch 0..180 (up and over the
  # top), grey 180..360, with crenellated horizon boundaries (ref photo).
  # Markings ride at LINE_R just above the opaque hemisphere fill and
  # depth-test against it, so the ball occludes its own far side; the mask
  # ring (z −0.01 world, just behind the case plane) occludes everything
  # outside the r 6.6 window.
  # ball slightly oversized relative to the window (ratio 0.711, ~45.4°
  # visible half-angle): markings ride out toward the ring and the
  # outermost edge content occludes — at the default attitude the
  # lower-right '3' just grazes the window edge, per reference
  BALL_R = 9.405
  LINE_R = BALL_R * 1.012
  WIN_R = 6.69       # ball window / roll gauge ring radius
  ERR_R = 7.65       # attitude error scale radius
  COL_W = 3.75       # fill strip width, deg yaw
  # meds-font ink metrics (measured from meds_font.svg; see scrollTape)
  GXC = 1.368
  GYC = 0.330
  # ball label type: size in degrees of arc per glyph-cell unit, advance in
  # cell units, and an x narrowing that reproduces the meds font's screen
  # aspect (glyph cells are near-square in the ball's row-unit space, but
  # the font renders ~0.64 w/h on the normal char grid)
  LBL_DEG = 5.4
  LBL_ADV = 0.78
  LBL_SX = 0.66
  # the near-pole '0' pair (yaw ±45) sits in tabs whose arc width shrinks
  # by cos(yaw), so it rides this much higher into the white for clearance
  ZERO_LIFT = 3

  ballPt = (p, w, r) ->
    cp = Math.cos(deg2rad(p)) ; sp = Math.sin(deg2rad(p))
    cw = Math.cos(deg2rad(w)) ; sw = Math.sin(deg2rad(w))
    [r*sw, -r*cw*sp, r*cw*cp]

  adiBall: () ->
    g = new THREE.Object3D()
    g.name = "adiBall"
    # rotor: everything painted on the ball; updateADI() sets its rotation
    @adiBallRot = new THREE.Object3D()
    @adiBallRot.userData.flattenApart = true   # updateADI turns it
    @adiBallRot.add @_ballFills()
    @adiBallRot.add @_ballMarkMeshes(@_ballMarks())
    g.add @adiBallRot
    # circular window: opaque background-colour ring just behind the case
    # plane depth-masks the ball outside r 6.6
    mask = new THREE.Mesh(new THREE.RingGeometry(WIN_R, 50, 100),
      new THREE.MeshBasicMaterial({side: THREE.DoubleSide, color: @d.c2h.black}))
    mask.position.z = 9.99
    g.add mask
    g.position.z = -10
    return g

  # hemisphere fills: white pitch 0..180, grey 180..360, smooth horizon.
  # White cut-out tabs sit just below the front horizon around each pitch-0
  # label position — the grey '0' glyphs render inside them.
  _ballFills: () ->
    white = [] ; gray = []
    quad = (arr, p0, p1, w0, w1, r=BALL_R) ->
      a = ballPt(p0,w0,r) ; b = ballPt(p0,w1,r)
      c = ballPt(p1,w1,r) ; e = ballPt(p1,w0,r)
      arr.push a[0],a[1],a[2], b[0],b[1],b[2], c[0],c[1],c[2]
      arr.push a[0],a[1],a[2], c[0],c[1],c[2], e[0],e[1],e[2]
      return
    band = (arr, pa, pb, w0, w1, r=BALL_R) ->
      n = Math.max(1, Math.ceil((pb-pa)/7.5))
      for i in [0...n]
        quad arr, pa+(pb-pa)*i/n, pa+(pb-pa)*(i+1)/n, w0, w1, r
      return
    for j in [0...Math.round(180/COL_W)]
      w0 = -90 + j*COL_W
      # grey pulled back ~a stroke width (0.5°) from the nominal horizon
      # at both boundaries; white extends underneath to keep the sphere
      # covered. Both hemisphere colours carry all the way to the poles
      # (ref cockpit photo)
      band white, -0.5, 180.5, w0, w0+COL_W
      band gray, 180.5, 359.5, w0, w0+COL_W
    # cut-outs: '0'-label height tall, ~3 label-widths wide, slightly proud
    # of the grey fill so they paint over it (still under the marking lines)
    CUT_H = 4.5 ; CUT_W = 7.0
    for wc in [-45, -15, 15, 45]
      # the tabs stay put — the ±45 '0's lift ZERO_LIFT up INTO the white
      # hemisphere (see _ballMarks), out of their too-narrow tabs
      for [wa, wb] in [[wc-CUT_W/2, wc], [wc, wc+CUT_W/2]]
        band white, 359.5-CUT_H, 359.5, wa, wb, BALL_R+0.03
    g = new THREE.Object3D()
    for [arr, c] in [[white, @d.c2h.white], [gray, @d.c2h.darkGray]]
      geom = new THREE.BufferGeometry()
      geom.setAttribute 'position', new THREE.Float32BufferAttribute(arr, 3)
      g.add new THREE.Mesh(geom, new THREE.MeshBasicMaterial({color: c, side: THREE.DoubleSide}))
    return g

  # ball markings, batched into a few polyline buckets by colour:
  #   w  - white strokes on the grey hemisphere
  #   d  - grey strokes on the white hemisphere
  #   wb - white with dark halo (labels on grey / straddling a horizon)
  _ballMarks: () ->
    b = { w: [], d: [], wb: [] }
    onWhite = (pp) ->
      pp = ((pp % 360) + 360) % 360
      pp > 0 and pp < 180
    # evenly-sampled runs (~5° steps, exact endpoints)
    mseg = (p, wa, wb) ->
      n = Math.max(1, Math.ceil((wb-wa)/5))
      (ballPt(p, wa+(wb-wa)*i/n, LINE_R) for i in [0..n])
    cseg = (w, pa, pb) ->
      n = Math.max(1, Math.ceil((pb-pa)/5))
      (ballPt(pa+(pb-pa)*i/n, w, LINE_R) for i in [0..n])
    # label clearance: solid lines break around the painted numbers
    lgapW = (s) -> (((s.length-1)*LBL_ADV + 0.72)/2) * LBL_DEG * LBL_SX + 1.8
    LGAP = 0.41*LBL_DEG + 1.8      # label half-height + margin, deg pitch
    # pitch great circles every 30° (0/180 are shown by the horizon
    # boundary), broken around their labels at yaw ±15 and ±45, running
    # through the ticked ±75 ring out to the ±85 stop circles
    for p in [30..330] by 30 when p != 180
      key = if onWhite(p) then 'd' else 'w'
      gp = lgapW("#{p/10}")
      for [s0, s1] in [[-85,-45-gp],[-45+gp,-15-gp],[-15+gp,15-gp],[15+gp,45-gp],[45+gp,85]]
        b[key].push mseg(p, s0, s1)
    # yaw circle runs, split at the horizons so each hemisphere gets its
    # contrasting colour
    pushC = (w, pa, pb) ->
      cuts = [pa]
      (cuts.push c if pa < c < pb) for c in [180, 360]
      cuts.push pb
      for i in [0...cuts.length-1]
        b[if onWhite((cuts[i]+cuts[i+1])/2) then 'd' else 'w'].push cseg(w, cuts[i], cuts[i+1])
      return
    # belly band (three lines) runs unbroken; the minors at 30/60/300/330
    # break around their labels at the 15°+30k rows. The label gap is
    # measured in pitch degrees, so it grows by 1/cos(yaw) to keep constant
    # arc clearance on the smaller circles near the poles.
    pushC w, 0, 360 for w in [-1.3, 0, 1.3]
    # latitude rings framing the pole caps, hemisphere-contrast coloured
    # like every other circle: the ticked ring at ±75 and the small ±85
    # stop circles where the meridians end
    pushC w, 0, 360 for w in [-75, 75, -85, 85]
    # short ticks on the equator side of the ±75 ring, every 10° of
    # pitch; the horizon rows (0/180) ride the exposed white strip so
    # they stay dark
    POLE_TICK = 2.0
    for p in [0...360] by 10
      key = if onWhite(p) or p % 180 == 0 then 'd' else 'w'
      b[key].push [ballPt(p, 75-POLE_TICK, LINE_R), ballPt(p, 75, LINE_R)]
      b[key].push [ballPt(p, -75, LINE_R), ballPt(p, -75+POLE_TICK, LINE_R)]
    # between the rings, a single abbreviated tick marks each dashed-row
    # meridian (pitch 15+30k) that isn't drawn out there — shorter than
    # the normal grid ticks, centred at ±80 and running along the
    # latitude-ring direction
    MID_TICK = 1.0
    for pb in [0..330] by 30
      pp = pb + 15
      key = if onWhite(pp) then 'd' else 'w'
      for s in [-1, 1]
        b[key].push [ballPt(pp-MID_TICK, s*80, LINE_R), ballPt(pp+MID_TICK, s*80, LINE_R)]
    for w in [-60, -30, 30, 60]
      gy = LGAP / Math.cos(deg2rad(w))
      for k in [0...12]
        pushC w, 15 + 30*k + gy, 45 + 30*k - gy
    # minor grid, drawn as perpendicular tick series, one dashed line
    # centred in every gap between solid lines:
    #   columns (yaw ≡ ±15 mod 30) -> short yaw-wise (horizontal) ticks
    #     every 5° of pitch
    #   rows (pitch ≡ 15 mod 30) -> short meridional (vertical) ticks
    #     every 5° of yaw
    # crosses appear where a dashed row meets a dashed column; the belly
    # band gets its own ticks, long (2x) at 10/20 and short at 5/15/25
    # dashed rows run out to the ±75 ring; the belly band ticks stay tight
    TICK = 1.6         # latitude-column tick half-length, deg
    LTICK = 1.45       # dashed-longitude (row) tick half-length, deg
    BELLY_T = 2.34     # belly tick half-length (long rows double it)
    for pb in [0..330] by 30
      for dp in [5..25] by 5
        pp = pb + dp
        key = if onWhite(pp) then 'd' else 'w'
        # pp 355 would sit right under the '0' cut-out tabs — skip it
        if pp != 355
          for ww in [-45, -15, 15, 45]
            b[key].push [ballPt(pp, ww-TICK, LINE_R), ballPt(pp, ww+TICK, LINE_R)]
        # belly ticks run wider than the grid ticks, hidden between the
        # band lines (two outboard halves only)
        tl = (if dp % 10 == 0 then 2 else 1) * BELLY_T
        b[key].push [ballPt(pp, -tl, LINE_R), ballPt(pp, -1.3, LINE_R)]
        b[key].push [ballPt(pp, 1.3, LINE_R), ballPt(pp, tl, LINE_R)]
      pp = pb + 15
      key = if onWhite(pp) then 'd' else 'w'
      # tick rows run out to the ±75 ring (last tick at ±70)
      for j in [-14..14] when j != 0 and (j*5) % 30 != 0
        b[key].push [ballPt(pp-LTICK, j*5, LINE_R), ballPt(pp+LTICK, j*5, LINE_R)]
    # horizon gauge ticks between the '33' and '3' circles: five per side
    # every 5° of yaw, dark, touching the pulled-back grey edge and
    # extending into the white region (both horizons); 2nd and 4th longer
    for j in [1..5]
      hlen = if j % 2 == 0 then 3.4 else 2.2
      for ww in [-j*5, j*5]
        b.d.push [ballPt(-0.5, ww, LINE_R), ballPt(hlen, ww, LINE_R)]
        b.d.push [ballPt(180 - hlen, ww, LINE_R), ballPt(180.5, ww, LINE_R)]
    # the horizon rows carry a long belly tick too (dark, riding the white
    # strip the grey pull-back exposes)
    for pp in [0, 180]
      b.d.push [ballPt(pp, -2*BELLY_T, LINE_R), ballPt(pp, -1.3, LINE_R)]
      b.d.push [ballPt(pp, 1.3, LINE_R), ballPt(pp, 2*BELLY_T, LINE_R)]
    # labels: angle magnitudes with the trailing zero deleted. Pitch values
    # on each pitch line centred between the belly band and the solid
    # circles (yaw ±15, matching the minor tick columns) and again at ±45;
    # yaw values on each minor circle at the 15° midrows between pitch lines
    lbl = (p, w, s) =>
      @_ballText b[if onWhite(p) then 'd' else 'wb'], p, w, s
    for p in [0..330] by 30
      for w in [-45, -15, 15, 45]
        if p == 0
          # the '0' rides just below the horizon (ink top at pitch 0),
          # grey, inside its white cut-out tab (see _ballFills); the
          # near-pole pair lifts ZERO_LIFT further into the white
          lift = if Math.abs(w) == 45 then ZERO_LIFT else 0
          @_ballText b.d, -2.8 + lift, w, "0"
        else
          lbl p, w, "#{p/10}"
    for [w, s] in [[30, "3"], [60, "6"], [-30, "33"], [-60, "30"]]
      for k in [0...12]
        lbl 15 + k*30, w, s
    return b

  # paint `str` onto the ball surface at pitch p / yaw w: meds-font strokes
  # (glyph cell units) -> degrees of arc -> tangent-plane offsets at (p,w),
  # renormalised back onto the marking radius. Labels are painted upright
  # for the null view and rotate rigidly with the ball.
  _ballText: (out, p, w, str) ->
    n = str.length
    cp = Math.cos(deg2rad(p)) ; sp = Math.sin(deg2rad(p))
    cw = Math.cos(deg2rad(w)) ; sw = Math.sin(deg2rad(w))
    sc = [sw, -cw*sp, cw*cp]         # unit surface point
    ew = [cw, sw*sp, -sw*cp]         # +yaw tangent (screen right at null)
    ep = [0, -cp, -sp]               # +pitch tangent (screen up at null)
    for c, k in str
      for stroke in (@d.medsFont.chars[c] ? [])
        pl = []
        for [gx, gy] in stroke
          du = deg2rad((gx + k*LBL_ADV - (GXC + (n-1)*LBL_ADV/2)) * LBL_DEG * LBL_SX)
          dv = deg2rad((gy - GYC) * LBL_DEG)
          vx = sc[0] + du*ew[0] - dv*ep[0]
          vy = sc[1] + du*ew[1] - dv*ep[1]
          vz = sc[2] + du*ew[2] - dv*ep[2]
          m = LINE_R / Math.hypot(vx, vy, vz)
          pl.push [vx*m, vy*m, vz*m]
        out.push pl
    return

  # one draw call per colour bucket (the border'd bucket gets two: a widened
  # dark underlay plus the white core, like @d.line's halo spec). Negative
  # renderOrder keeps the transparent ball strokes underneath the needles
  # and case symbology drawn at order >= 0.
  _ballMarkMeshes: (b) ->
    g = new THREE.Object3D()
    mk = (geom, mat, order) ->
      m = new THREE.Mesh(geom, mat)
      m.frustumCulled = false
      m.renderOrder = order
      g.add m
    mk makeSDFLinesGeometry(THREE, b.w), @d.mats[0][@d.c2h.white], -1 if b.w.length
    mk makeSDFLinesGeometry(THREE, b.d), @d.mats[0][@d.c2h.darkGray], -1 if b.d.length
    if b.wb.length
      geom = makeSDFLinesGeometry(THREE, b.wb)
      @_ballBMat ?= makeSDFLineMaterial(THREE, @d.sdfOpt({color: @d.c2h.black, widthPx: @d.LINE_PX + 2.5}))
      mk geom, @_ballBMat, -2
      mk geom, @d.mats[0][@d.c2h.white], -1
    return g

  # ADI drive
  #
  # Re-derives every data-driven ADI element. The ball geometry is static;
  # attitude only updates the rotor's rotation, and the needle / roll bug /
  # rate pointer / digital readout groups are cheaply rebuilt.
  updateADI: () ->
    return unless @adi?
    d = @data()
    # ADI OFF mode (curData.adiValid = false): valid GPC data is no longer
    # driving the ADI software — the ball locks at its last driven
    # orientation, the needles and rate pointers stow, the digital readout
    # blanks, and the red OFF flag shows at the left of the case
    valid = d.adiValid ? true
    if valid
      [r, p, y] = @_adiProtect(d.adiRol ? 0, d.adiPch ? 0, d.adiYaw ? 0)
      @_adiLast = [r, p, y]
      # The ball turns opposite the causative rotation (fly-to indicator):
      #   +roll  -> ball CCW on screen          Rz(-R)
      #   +pitch -> front face rotates downward Rx(-P)
      #   +yaw   -> front face right-to-left    Ry(-Y)
      # composed as Rz(-R)·Ry(-Y)·Rx(-P) = THREE 'ZYX' Euler with angles
      # (-P,-Y,-R). This is the order that keeps the marking at the ball's
      # front centre equal to the vehicle's current (pitch, yaw) at ANY
      # attitude — verified against a cockpit photo at R/P/Y 315/315/316
      # (yaw-270 pole upper-left, 46 deg off boresight). Single-axis tests
      # can't distinguish the order (all orders agree there), which is how
      # the previous 'XYZ' composition slipped through; both orders are
      # also singular at yaw 90/270, matching the gimbal-protect region.
      @adiBallRot?.rotation.set deg2rad(-p), deg2rad(-y), deg2rad(-r), 'ZYX'
    else
      # static ball: rotation left untouched; overlays use the last attitude
      [r, p, y] = @_adiLast ? [0, 0, 0]
    if @adiDynC?
      @adiC.remove @adiDynC
      @_disposeGroup @adiDynC
    if @adiDynS?
      @adi.remove @adiDynS
      @_disposeGroup @adiDynS
    # The two overlays this method replaces hold the strokes under them
    # across a part flatten.  They merge here when they are going onto a
    # standing display; during the part's build the flatten at the end of it
    # covers them, in the order the whole part was drawn.
    @adiC.add (@adiDynC = @_drawADIDyn(r, p, y, valid))
    @adi.add (@adiDynS = @drawADIDigitals(r, p, y, valid))
    @adiDynC.userData.flattenApart = true
    @adiDynS.userData.flattenApart = true
    if @adi.parent?
      @d.flatten @adiDynC
      @d.flatten @adiDynS
    @d.dirty = true
    return

  # PYR-gimballed ADIs coalign the pitch and roll axes at yaw 90/270; the
  # attitude processor protects the region by freezing roll and pitch while
  # yaw is within ±1.7° of either singularity
  _adiProtect: (r, p, y) ->
    wrap = (v) -> ((v % 360) + 360) % 360
    r = wrap(r) ; p = wrap(p) ; y = wrap(y)
    if Math.abs(y - 90) < 1.7 or Math.abs(y - 270) < 1.7
      [r, p] = @_adiFrz if @_adiFrz?
    else
      @_adiFrz = [r, p]
    [r, p, y]

  # dynamic overlay in ADI circular space: roll bug, attitude error needles,
  # rate pointers (with their scales); a few dozen meshes, rebuilt per update
  # Rate Scale Labels and the Pitch Error Scale Label
  #
  # "Rate scales are labeled for all axes and are in deg/sec unless
  # indicated by a suffix. For example, '5K' indicates the rate scale now
  # serves purpose of being a lateral deviation indicator with max scale
  # deflection of 5000 feet. Only the pitch error scale is labeled and is
  # assumed to denote degrees of error except when a suffix is indicated;
  # i.e., 1.2 G." (JSC-48017/6-13 item 8)
  #
  # The six rate labels and the pitch error label come from MEDS transfer
  # message 1 words 16 to 21; the rate labels are integers of the scale's
  # units (equation set F.4.103.0-2) and the error label carries the 0.25
  # LSB of word 21.  A scale term of 0 stows that needle, and its scale
  # goes unlabelled.
  #
  # Word 16 bit 1 says the roll scale reads time to go to the turn on the
  # HAC, and bit 2 which end of it is zero: "The MEDS must know when this
  # occurs in order to display the scale label correctly and must also know
  # which side of the scale represents zero" (STS-83-0020V3-34
  # F.4.128.1.3.1.7).  A rate scale reads full scale at both ends about a 0
  # centre; the tgo scale reads 0 at one end and full scale at the other.
  _rateLbl = (v) ->
    return "" unless v? and v > 0
    return "#{v}" if v < 1000
    k = v/1000
    (if k == Math.round(k) then "#{k}" else k.toFixed(1)) + "K"

  # 1.25 g prints as "1.2 G ... due to space limitations and truncation"
  # (JSC-48017/6-13)
  _errLbl = (v) ->
    return "" unless v? and v > 0
    if v == Math.round(v) then "#{v}" else (Math.floor(v*10)/10).toFixed(1)

  _adiLocalText: (ax,lx,ly,s,color,scale=1.0,advance=0.62,scalex=1.0) ->
    @d.strMEDS lx+1-1/ax, ly, s, color, scale, advance/ax, scalex/ax

  ADI_LBL_ADV = 0.62            # per-character step of the scale labels

  # The legends beside the rate scales, which follow the scale words the
  # transfer carries and not the attitude.
  _adiScaleLabels: () -> @_kept 'adiScaleLabels', =>
    d = @data()
    g = new THREE.Object3D()
    sc = d.adiRateScale ? {}
    ltxt = @adiLtxt
    # left-anchored, and right-anchored so a wider label grows away from
    # the scale
    lt = (x, y, t, color = @d.c2h.white) =>
      g.add ltxt x, y, t, color, 0.85, ADI_LBL_ADV, 1.18 if t
    rt = (x, y, t, color = @d.c2h.white) =>
      lt x - (t.length-1)*ADI_LBL_ADV, y, t, color
    zero = (x, y) => g.add ltxt x, y, "0", @d.c2h.darkGray, 0.85

    # roll, across the top: tgo puts 0 at one end and the scale at the other
    roll = _rateLbl(sc.roll)
    if sc.rollTgo
      if sc.rollZeroOnRight
        rt -6.42, -9.10, roll
        zero 6.03, -9.10
      else
        rt -6.42, -9.10, "0"
        lt 6.03, -9.10, roll
    else
      rt -6.42, -9.10, roll
      zero -0.11, -9.88
      lt 6.03, -9.10, roll
    # yaw, across the bottom
    yaw = _rateLbl(sc.yaw)
    rt -6.51, 8.48, yaw
    zero -0.11, 9.37
    lt 6.06, 8.48, yaw
    # pitch, up the right side
    pch = _rateLbl(sc.pitch)
    lt 8.27, -6.83, pch
    zero 9.55, -0.28
    lt 8.27, 6.30, pch
    # Pitch Scale Labels – Reflects the setting of the ADI ERROR switch and
    # displayed in degrees. During TAEM (MM 305 and 603) and Nz hold (MM
    # 602), the Pitch Attitude Error scale is in g's, and indicated by a "g"
    # next to the scale value. (JSC-48017/6-12 item 7.  Nz hold is where
    # the target Nz word is valid, MM 602 with IPHASE at least 5.)
    err = _errLbl(d.adiPchErrScale)
    if err
      err += "g" if d.majorMode in [305, 603] or (d.majorMode == 602 and d.targetNZ?)
      # baseline of the upper label flush with the top tick and topline of
      # the lower flush with the bottom tick (meds glyph ink at scale s
      # spans y-0.08s .. y+0.74s)
      sy = ERR_R * Math.sin(deg2rad(25))
      g.add ltxt 7.05, -sy - 0.74*0.8 - 0.05, err, @d.c2h.magenta, 0.8, 0.7, 1.0
      g.add ltxt 7.05, sy - 0.08*0.8 + 0.05, err, @d.c2h.magenta, 0.8, 0.7, 1.0
    g

  # ADI Theta Limit Bracket – A green limit bracket available while
  # M < 2 if either 1) air data is inhibited to G&C, 2) no ADTA/probes
  # are available, or 3) an air data dilemma exists (AD DG flag set to
  # 0). The upper and lower bracket represent the theta high and low
  # limits, respectively, as determined by guidance. The bracket is
  # dynamic and varies with bank angle. The limits are the same as the
  # theta limit indicators available on the VERT SIT display.
  #
  #       [JSC-48017/6-10 item 4]
  #
  # Message 1 words 14 and 15 carry sin(THETA_MAX - THETA) and
  # sin(THETA - THETA_MIN), and the GPC sets their validity for exactly the
  # conditions above.  A point that many degrees off the ball centre
  # projects to BALL_R times that sine, so the words place the brackets
  # directly; they ride the ball, so the group turns with roll.  The
  # bracket's shape — a bar with ends turned toward the centre — is fitted.
  THETA_HALF = 1.15             # bracket half length, rows
  THETA_TICK = 0.42             # turned end
  _adiThetaBracket: (roll) ->
    d = @data()
    g = new THREE.Object3D()
    # an A/E PFD element; the ORB PFD's five items carry no bracket
    return g unless @screenName == 'AE_PFD'
    return g unless d.thetaMaxDelta? and d.thetaMinDelta?
    bar = (yv, sgn) =>
      return if Math.abs(yv) > WIN_R
      g.add @d.line [[-THETA_HALF, yv + sgn*THETA_TICK], [-THETA_HALF, yv],
                     [ THETA_HALF, yv], [ THETA_HALF, yv + sgn*THETA_TICK]], @d.c2h.green
    bar -BALL_R * d.thetaMaxDelta, 1
    bar  BALL_R * d.thetaMinDelta, -1
    g.rotation.z = deg2rad(-roll)
    g

  _drawADIDyn: (r, p, y, valid=true) ->
    d = @data()
    g = new THREE.Object3D()
    g.name = "ADIdyn"
    # roll bug: reads the case roll scale, counterclockwise from 0 at top,
    # driven with respect to the MDU regardless of ball orientation; green
    # pointer riding the ball edge, tip outward on the window ring, base
    # corners clipped, with a thin dark outline
    # geometry built once at roll 0 (screen angle 270°, pointing up) and
    # rotated into place per update — R(270-r) = R(-r)·R(270)
    if not @_adiBugG?
      a0 = deg2rad(270)
      ca = Math.cos(a0) ; sa = Math.sin(a0)
      pts = ([rad*ca - tg*sa, rad*sa + tg*ca] for [rad, tg] in [[WIN_R,0],[WIN_R-0.58,0.40],[WIN_R-0.72,0.22],[WIN_R-0.72,-0.22],[WIN_R-0.58,-0.40]])
      @_adiBugG = new THREE.Object3D()
      @_adiBugG.userData.keepAlive = true
      @_adiBugG.add @d.polyFill pts, @d.c2h.green
      @_uOutlineMat ?= makeSDFLineMaterial(THREE, @d.sdfOpt({color: @d.c2h.black, widthPx: 1.4}))
      bm = new THREE.Mesh(makeSDFLineGeometry(THREE, pts.concat([pts[0]])), @_uOutlineMat)
      bm.frustumCulled = false
      @_adiBugG.add bm
    @_adiBugG.rotation.z = deg2rad(-r)
    g.add @_adiBugG
    if valid
      # attitude error needles: fly-to, ±5 (MED scale) full range mapping
      # linearly onto the scale ends; axis-aligned single strokes with a
      # dark halo, translated (not pivoted), reaching in from the scales to
      # about the vehicle-cross tips, sorted behind the vehicle symbol
      fs = ERR_R * Math.sin(deg2rad(25))
      defl = (e) -> fs * Math.max(-1, Math.min(1, (e ? 0)/5))
      # heavy stroke (1.5x the old needle weight), dark halo
      @_ndlMats ?= [
        makeSDFLineMaterial(THREE, @d.sdfOpt({color: @d.c2h.black, widthPx: 1.5*(@d.LINE_PX + 0.8) + 1.8}))
        makeSDFLineMaterial(THREE, @d.sdfOpt({color: @d.c2h.magenta, widthPx: 1.5*(@d.LINE_PX + 0.8)}))
      ]
      nd = (p0, p1) =>
        gg = new THREE.Object3D()
        geom = makeSDFLineGeometry(THREE, [p0, p1])
        for [mat, order] in [[@_ndlMats[0], 0], [@_ndlMats[1], 1]]
          m = new THREE.Mesh(geom, mat)
          m.frustumCulled = false
          m.renderOrder = order
          gg.add m
        gg.position.z = -0.2
        gg
      # outer end pulls EOUT inside the curved scale arc so the round cap
      # (which extends half the stroke past the endpoint) just kisses the
      # arc's inner edge instead of crossing it; inner reach set in drawADI
      EOUT = 0.15
      nin = @adiNIN ? 2.16
      ninV = @adiNINv ? 2.0     # bottom needle kisses the vertical arm
      ninT = @adiNINtop ? 2.15  # top arm runs longer; roll needle matches
      # a needle whose error word is invalid (null) stows
      if d.adiRolErr?
        xr = defl(d.adiRolErr)                  # top:    + error -> right
        g.add nd [xr, -Math.sqrt(ERR_R**2 - xr*xr) + EOUT], [xr, -ninT]
      if d.adiPchErr?
        yp = -defl(d.adiPchErr)                 # right:  + error -> up
        g.add nd [Math.sqrt(ERR_R**2 - yp*yp) - EOUT, yp], [nin, yp]
      if d.adiYawErr?
        xy = defl(d.adiYawErr)                  # bottom: + error -> right
        g.add nd [xy, Math.sqrt(ERR_R**2 - xy*xy) - EOUT], [xy, ninV]
    g.add @_adiScaleLabels()
    g.add @_adiThetaBracket(r)
    # rate pointers, -5..+5 onto the fixed scales
    # rate scales always draw; the pointers stow when the data is invalid
    rolV = if valid and d.adiRolRate? then d.adiRolRate + 5 else undefined
    yawV = if valid and d.adiYawRate? then d.adiYawRate + 5 else undefined
    pchV = if valid and d.adiPchRate? then 10 - (d.adiPchRate + 5) else undefined
    # the scales stand; only the pointer arrows on them move
    g.add @_kept 'adiRateScales', =>
      s = new THREE.Object3D()
      s.add @drawHorizGauge undefined, "5", "0", "5", -5.81, 5.88, -9.1, .55, .55, 10, false
      s.add @drawHorizGauge undefined, "5", "0", "5", -5.81, 5.88, 9.15, .55, .55, 10
      s.add @drawVertGauge undefined, "5", "0", "5", -5.95, 5.95, 9.13, .41, .41, 10
      s
    g.add @drawHorizGauge rolV, "5", "0", "5", -5.81, 5.88, -9.1, .55, .55, 10, false, true
    g.add @drawHorizGauge yawV, "5", "0", "5", -5.81, 5.88, 9.15, .55, .55, 10, true, true
    g.add @drawVertGauge pchV, "5", "0", "5", -5.95, 5.95, 9.13, .41, .41, 10, true, true
    if not valid
      # ADI OFF Flag – a remnant of the mechanical dedicated displays:
      # valid GPC data is not driving the ADI (commfault / GPC-IDP comm
      # errors); red flag at the left of the case between the rings.
      # Topmost element of the ADI: the fill rides the transparent pass at
      # renderOrder 3 and the text at 4, above every other stroke (needle
      # cores / label halos at 1, rate pointer triangles at 2).
      fb = @d.box -7.81, -2, -6.96, 2, null, @d.c2h.red
      fb.traverse (o) ->
        if o.material?
          o.material.transparent = true
          o.renderOrder = 3
      g.add fb
      # letters ink-centred on the flag box (box centre −7.385; ltxt ink
      # centre sits ~0.25 right of its lx at scale 1)
      for [ty, ch] in [[-1.75, "O"], [-.45, "F"], [.75, "F"]]
        t = @adiLtxt -7.64, ty, ch, @d.c2h.black
        t.traverse (o) -> o.renderOrder = 4 if o.material?
        g.add t
    return g


  # Glide Slope Indicator (GSI) – Distance of the vehicle above or
  # below the desired glide slope and is indicated by the deflection
  # of the pointer. The pointer is a fly-to indicator, so an
  # increase in glide slope deviation above (below) the desired
  # slope results in deflection of the pointer downward (upward).
  # The GSI computation is available above 1500 ft in TAEM MM 305
  # and 603. The pointer is blanked prior to MM 305 or 603, and the
  # GS flag is displayed below 1500 ft.
  #
  # Range:
  #       TAEM – -5000 to 5000 ft, 1 dot = 2500 ft
  #       Approach/Land – -1000 to 1000 ft, 1 dot = 500 ft
  #
  #       [JSC-48017/6-16 item 19]
  #
  GSI_BOX = [45.43, 20.55, 46.95, 31.31]
  GSI_DOT = 2.275               # one dot of glide slope deviation, rows
  drawGSI: () ->
    g = new THREE.Object3D(name="GSI") #"
    # available in MM 305 and 603; with no major mode the outline stands, as
    # it does on the prelaunch A/E PFD ("The OPS 9 A/E PFD contains no
    # active elements, however outlines for all major display elements are
    # provided", JSC-48017/6-22).  The region is shared with the four
    # ascent digitals of items 20 to 23.
    return g unless @data().majorMode in [305, 603] or not @data().majorMode?
    [x0, y0, x1, y1] = GSI_BOX
    cy = (y0 + y1)/2
    g.add @_kept 'gsiFrame', =>
      fg = new THREE.Object3D()
      fg.add @d.box x0, y0, x1, y1, @d.c2h.white
      fg.add @d.line [[x0, cy], [x1, cy]], @d.c2h.darkGray
      for k in [-2, -1, 1, 2]
        fg.add @d.filledArc (x0+x1)/2, cy + k*GSI_DOT, 0.29, 0, 360, @d.c2h.white
      fg
    # full scale centred above and below the box: 5K in TAEM, 1K in
    # approach and land (the inset beside item 19)
    if (lbl = HSI_GSI_LBL[@data().hsiMode])?
      # meds glyph ink at scale s runs y-0.08s to y+0.74s, so the upper
      # label's ink bottom and the lower's ink top clear the box
      cx = (x0+x1)/2 - (lbl.length-1)*0.45 - 0.36
      g.add @d.strMEDS cx, y0 - 1.00, lbl, @d.c2h.white, 0.9, 0.9
      g.add @d.strMEDS cx, y1 + 0.30, lbl, @d.c2h.white, 0.9, 0.9
    if @data().hsiGsiValid
      v = Math.max(-2.4, Math.min(2.4, @data().hsiGsi ? 0))
      yv = cy + v*GSI_DOT
      g.add @_greenArrow [[x1+0.66, yv-0.452], [x1-0.74, yv], [x1+0.66, yv+0.452]], GA_ASP
    else if @data().majorMode in [305, 603]
      g.add @_hsiFlag (x0+x1)/2, cy, "GS"
    return g

  # Altitude Acceleration – Available in PASS MM 304 and 602. A
  # pointer slides vertically on a scale in fps2. Maximum range of
  # the scale is ±10 fps2. A green pointer indicates the current
  # NAV-derived altitude acceleration value.
  #
  # Range:
  #       Altitude Acceleration – -10 to 10 fps2
  #
  #       [JSC-48017/6-16 item 18]
  #
  HDD_X    = [48.80, 50.30]     # scale face
  HDD_ZERO = 26.62              # the zero row
  HDD_S    = 0.507              # rows per fps2
  HDD_MAX  = 10
  HDD_PAD  = 0.35               # face run past the end marks
  HDD_LBL  = 50.86              # left ink edge of the scale legends
  GAUGE_DIG = 0.856             # meds digits at the 0.70-row cap these fields use
  drawAttAcc: () ->
    g = new THREE.Object3D(name="attAcc") #"
    # available in MM 304 and 602, plus the prelaunch outline
    return g unless @data().majorMode in [304, 602] or not @data().majorMode?
    [x0, x1] = HDD_X
    yTop = HDD_ZERO - HDD_MAX*HDD_S - HDD_PAD
    yBot = HDD_ZERO + HDD_MAX*HDD_S + HDD_PAD
    # title: 'H' overstruck with the DEU upper-double-dot glyph (¨, cell
    # c135) for the second derivative; the deu glyph cell spans x-0.05..x+0.85
    for hc in ["H", "¨"]
      g.add @d.str (x0+x1)/2 - 0.4, 20.05, hc, @d.c2h.darkGray, 1, .9
    # positive above the zero row on the white face, negative on the grey
    g.add @d.box x0, yTop, x1, HDD_ZERO, null, @d.c2h.white
    g.add @d.box x0, HDD_ZERO, x1, yBot, null, @d.c2h.darkGray
    g.add @d.box x0, yTop, x1, yBot, @d.c2h.white
    for v in [-HDD_MAX..HDD_MAX] by 2
      y = HDD_ZERO - v*HDD_S
      long = v == 0 or Math.abs(v) == HDD_MAX
      g.add @d.line [[x1, y], [x1 + (if long then 0.44 else 0.25), y]], @d.c2h.white
      continue unless long
      s = GAUGE_DIG
      # left-aligned on the digits, the minus sign outdented one advance
      g.add @d.strMEDS HDD_LBL + 1 - 1.009*s - (if v < 0 then 0.9 else 0),
                       y - 0.330*s, "#{v}", @d.c2h.white, s, 0.9
    if @data().vertAccelValid
      v = Math.max(-HDD_MAX, Math.min(HDD_MAX, @data().vertAccel ? 0))
      yv = HDD_ZERO - v*HDD_S
      g.add @_greenArrow [[x0-0.61, yv-0.42], [x0+0.71, yv], [x0-0.61, yv+0.42]], GA_ASP
    return g

  # Delta Cross Track digital – ∆ X-Trk is X-Trk minus the radius of
  # the targeted TAL cross-range circle in nautical miles, showing the
  # lateral distance the vehicle must steer to meet TAL cross-range
  # targeting. It is only available for TAL abort ...
  #
  # Cross Track digital – X-Trk is the lateral off-set distance from
  # targeted plane in nautical miles ... The value is positive for
  # positions north of the target insertion plane, and negative for
  # positions south of the target plane. X-Trk is available for
  # nominal uphill, TAL, and ATO powered flight (MM 102 and 103).
  #
  # Delta Inclination digital – ∆ Inc is the difference between the
  # current & targeted inclination, in degrees ...
  #
  # Target Inclination digital – Tgt Inc indicates the value of the
  # targeted inclination in degrees. It is only available for ATO
  # (MM 103) ...
  #
  #       [JSC-48017/6-17 items 20 to 23]
  #
  # Each row draws while its word is valid, which carries the availability
  # above.  Resolutions are the transfer's: cross track a tenth of a mile,
  # cross track deviation whole miles (F.4.128.1.3.1.16, LSB = 1 NM, where
  # the p.6-17 inset draws a tenth), delta inclination a hundredth of a
  # degree, target inclination a tenth.  They share the lower right region
  # with the GSI and the altitude acceleration face; the major modes do not
  # overlap.
  XTRK_LBL = 42.60              # left edge of the labels
  XTRK_VAL = 50.40              # right edge of the values
  XTRK_LADV = 0.62
  XTRK_VADV = 0.80
  XTRK_ROWS = [24.5, 26.0, 27.5, 29.0]
  drawXtrk: () ->
    d = @data()
    g = new THREE.Object3D(name="xtrk") #"
    fmt = (v, dp) -> (if v < 0 then "-" else "") + Math.abs(v).toFixed(dp)
    rows = [
      ["\u2206 X-Trk", (if d.xtrkDev? then fmt(d.xtrkDev, 0) else null)]
      ["X-Trk",        (if d.xtrk? then fmt(d.xtrk, 1) else null)]
      ["\u2206 Inc",    (if d.dIncl? then fmt(d.dIncl, 2) else null)]
      ["Tgt Inc",      (if d.tgtIncl? then fmt(d.tgtIncl, 1) else null)]]
    for [lbl, v], i in rows
      continue unless v?
      y = XTRK_ROWS[i]
      g.add @d.strMEDS XTRK_LBL, y, lbl, @d.c2h.darkGray, 0.72, XTRK_LADV
      g.add @d.strMEDS XTRK_VAL - (v.length-1)*XTRK_VADV - 0.66, y, v, @d.c2h.white, 0.78, XTRK_VADV
    return g

  # ΔAZ or HAC Turn Angle - As ΔAZ this field displays the angle
  # between the vehicle flight path and the HAC tangent in degrees.
  # The outline box will flash red when roll reversal limits are met
  # or exceeded (10.5° or 17°). During TAEM post-HAC intercept, the
  # field changes to HAC Turn Angle (HTA).
  #
  # Ranges:
  #       ΔAZ - 0 - 180 degrees
  #       HTA - 0 -360 degrees
  #
  #       [JSC-48017/6-15 item 17]
  #
  # "Delta Azimuth - White label, yellow digits" and the label reads AZ
  # (STS-83-0020V1-34 fig.3.12.2-2 item 23); the box is figure 6-8's.  The
  # value is message 1 word 23, one degree a count, with the warning flag
  # beside it; the box is drawn red for the warning where the display
  # flashes it.  The GPC marks the word valid in MM 305 and 603 only while
  # IPHASE is below 2, so the HTA relabel has no data to carry.
  DAZ_BOX = [33.80, 22.30, 38.00, 23.53]
  DAZ_LBL = 33.50               # right edge of the label
  drawDAz: () ->
    g = new THREE.Object3D(name="dAz") #"
    return g unless @data().dAz?
    [x0, y0, x1, y1] = DAZ_BOX
    s = GAUGE_DIG
    g.add @d.strMEDS DAZ_LBL - 2*0.9, (y0+y1)/2 - 0.330*s, "AZ", @d.c2h.white, s, 0.9
    g.add @d.box x0, y0, x1, y1, (if @data().dAzWarn then @d.c2h.red else @d.c2h.darkGray)
    txt = "#{Math.round(@data().dAz)}°"
    g.add @d.strMEDS x1 - 0.726*s - (txt.length-1)*0.9, (y0+y1)/2 - 0.330*s, txt, @d.c2h.yellow, s, 0.9
    return g

  # Range to Landing Site - The range to the SPEC 50 primary runway
  # is displayed in nautical miles. The range label (above the range
  # value) reflects the SPEC 50 primary runway. Range to the landing
  # site is displayed in powered flight at TAL MM 103, RTLS MM 601,
  # and after ECAL/BDA abort selection. In glided flight, the range
  # to the runway is displayed at MM 304 and 602, and both range to
  # the runway and HAC center are displayed at MM 305 and 603.
  #
  # Range:
  #       0 - 999.9 nautical miles
  #
  #       [JSC-48017/6-15 items 15 and 16]
  #
  # "Primary Range - White digits in a white rectangle (invalid indicator -
  # solid red rectangle)" (STS-83-0020V1-34 fig.3.12.2-2).
  RNG_X = [38.45, 42.09]
  drawRange: () ->
    g = new THREE.Object3D(name="range") #"
    [x0, x1] = RNG_X
    # the primary label is the selected landing site (message 1 words 25 to
    # 27), the secondary HAC-C in the TAEM mode: "In the TAEM mode, a range
    # box for HAC center (HAC-C) will also appear, showing the straight-line
    # range from the vehcile to the center of the HAC in nautical miles"
    # (USA-007587 sect.2.7)
    secLbl = if @data().hsiMode == HSI_MODE_TAEM then "HAC-C" else "SEC"
    for [lbl, ly, y0, y1, v, ok] in [
        [(@data().siteId ? "PRI"), 26.469, 27.22, 28.45, @data().hsiPriRange, @data().hsiPriRangeValid]
        [secLbl, 29.269, 30.06, 31.30, @data().hsiSecRange, @data().hsiSecRangeValid]]
      g.add @d.strMEDS 39.30, ly, lbl, @d.c2h.darkGray, 0.868, .95
      if ok
        g.add @d.box x0, y0, x1, y1, @d.c2h.darkGray
        s = GAUGE_DIG ; txt = "#{Math.round(v ? 0)}"
        g.add @d.strMEDS 41.66 + 1 - 1.726*s - (txt.length-1)*0.9,
                         (y0+y1)/2 - 0.330*s, txt, @d.c2h.white, s, 0.9
      else
        g.add @d.box x0, y0, x1, y1, @d.c2h.red, @d.c2h.red
    return g

  # HSI geometry, in rows about the compass-card centre; x is stretched by
  # HSI_ASP (@d.arc's row->col ratio) so a radius means the same in both
  # axes.  Radii and type sizes are measured off the reference photo.
  HSI_ASP   = 1.47222
  HSI_C     = [24.85, 31.12]    # compass-card centre
  HSI_CASE  = 7.56              # case circle
  HSI_CARD  = 6.97              # compass card outer edge
  HSI_FACE  = 4.56              # compass card inner edge
  HSI_MARK  = 7.98              # outer end of the lubber lines and fixed indices
  HSI_LBL   = 5.28              # compass label ring
  HSI_TICK  = [0.80, 0.50]      # 10-degree and 5-degree mark lengths
  HSI_LTR   = 1.03              # cardinal cap height, rows
  HSI_DIG   = 0.70              # ten-degree label cap height
  HSI_GLYPH = 0.818             # meds glyph cap height at scale 1
  # The instrument face — orbiter symbol, course pointer, deviation bar and
  # its dots — is centred 0.29 rows above the compass card.
  HSI_FC    = [24.78, 30.83]
  HSI_DOT   = 1.52              # one dot of course deviation, rows
  HSI_DEV   = [2.98, 0.195]     # deviation bar half length and half width
  # Bearing pointer: the head is a kite astride the card's outer edge, the
  # tail a pentagon inside the card.  Each entry is [halfWidth, radius].
  HSI_BHEAD = [[0, 6.37], [0.53, 7.15], [0, 7.59]]
  HSI_BTAIL = [[0, 5.18], [0.355, 5.32], [0.355, 6.22], [0.18, 6.34]]
  HSI_BLTR  = [7.05, 5.78]      # radius of the head's letter and the tail's
  # Course pointer: an arrow with swept barbs, tip outward, and opposite it
  # the tail — the same shaft with a blunt end (fig.3.12.2-2 items 19, 9).
  HSI_ARROW = [[0, 5.65], [0.24, 5.10], [0.31, 4.30], [0.87, 3.90], [0.87, 3.66],
               [0.31, 3.53], [0.22, 3.36]]
  HSI_CTAIL = [[0.16, 5.65], [0.24, 5.45], [0.24, 3.53], [0.22, 3.36]]
  # Orbiter symbol, [halfWidth, rows below the face centre].
  HSI_ORB   = [[0, -1.36], [0.10, -0.90], [0.17, -0.50], [0.24, -0.10],
               [0.53, 0.24], [0.20, 0.56], [0, 0.72]]

  # The instrument runs under the menu area; everything on it is clipped to
  # the display above it.
  HSI_CLIP  = new THREE.Vector4(-1, 53, -2, 32.374)
  # Stacking on the face and the card.  An SDF stroke's geometry carries
  # z = 100, in front of every fill, so the fills join the same transparent
  # pass and the order is renderOrder throughout: dots under the deviation
  # bar, both under the course pointer and the bearing tags, the tags'
  # letters over their fill, the orbiter symbol over all of it.
  HSI_ORD   = {dot: 2, bar: 3, ptr: 4, ltr: 5, orb: 6}

  # r rows out along screen angle `a` (degrees, 0 = +x, y down) and v rows
  # across it, about centre c
  _hsiRV: (c, r, v, a) ->
    t = deg2rad(a) ; cs = Math.cos(t) ; sn = Math.sin(t)
    [c[0] + (r*cs - v*sn)*HSI_ASP, c[1] + r*sn + v*cs]

  # a [halfWidth, radius] outline mirrored about the pointer axis and
  # filled as a strip, so the swept shapes fill correctly; `sgn` -1 turns it
  # through the centre for a pointer's tail
  _hsiShape: (c, shape, a, sgn, color) ->
    aa = if sgn < 0 then a + 180 else a
    verts = [] ; idx = []
    for [v, r], i in shape
      p = @_hsiRV(c, r, v, aa) ; q = @_hsiRV(c, r, -v, aa)
      verts.push p[0], p[1], 0, q[0], q[1], 0
      idx.push 2*i-2, 2*i-1, 2*i, 2*i-1, 2*i+1, 2*i if i > 0
    geom = new THREE.BufferGeometry()
    geom.setAttribute 'position', new THREE.Float32BufferAttribute(verts, 3)
    geom.setIndex idx
    mat = new THREE.MeshBasicMaterial({color: color, side: THREE.DoubleSide})
    mat.clippingPlanes = @d.clipPlanes(HSI_CLIP)
    mat.transparent = true          # joins the pass the strokes are in
    new THREE.Mesh(geom, mat)

  # one card string, glyphs centred on radius r at screen angle a and turned
  # so the type reads outward; `up` -1 turns it to read inward
  _hsiText: (c, str, r, a, h, color, up = 1) ->
    g = new THREE.Object3D()
    rot = deg2rad(a + 90*up)
    AR = 18.789/13.783                  # pxRow/pxCol, glyphStrokes' rotation aspect
    adv = 0.654*h                       # glyph pitch along the card, rows
    [cx, cy] = @_hsiRV(c, r, 0, a)
    for ch, i in str
      t = up * (i - (str.length-1)/2)*adv
      g.add @d.str cx + t*Math.cos(rot)*AR, cy + t*Math.sin(rot), ch, color,
                   h/HSI_GLYPH, 1.0, 1.0, @d.medsFont, rot, true, HSI_CLIP
    g

  # black legend on a solid red rectangle (STS-83-0020V1-34 fig.3.12.2-2:
  # "Bearing Flag - Black 'BRG' on a solid red rectangle")
  _hsiFlag: (cx, cy, txt) ->
    g = new THREE.Object3D()
    adv = 0.95
    w = adv*txt.length + 0.3
    fill = @d.box cx-w/2, cy-0.62, cx+w/2, cy+0.62, null, @d.c2h.red, HSI_CLIP
    fill.traverse (o) ->
      if o.material?
        o.material.transparent = true
        o.renderOrder = HSI_ORD.ptr
    g.add fill
    lbl = @d.str cx-(txt.length-1)*adv/2, cy, txt, @d.c2h.black, 0.9, adv, 1.0,
                 @d.medsFont, 0, true, HSI_CLIP
    lbl.traverse (o) -> o.renderOrder = HSI_ORD.ltr
    g.add lbl
    g

  # case: outer circle, the fixed lubber line at the top, its reciprocal at
  # the bottom, and the six fixed indices between them
  # The case ring and its fixed indices, all of it outside the compass card.
  _hsiCase: () -> @_kept 'hsiCase', =>
    g = new THREE.Object3D()
    g.add @_hsiArc HSI_CASE, @d.c2h.darkGray
    for a in [-90, 90]
      g.add @d.line [@_hsiRV(HSI_C, HSI_CARD, 0, a), @_hsiRV(HSI_C, HSI_MARK, 0, a)],
                    @d.c2h.lightGray, 1.0, HSI_CLIP
    for a in [0, 45, 135, 180, 225, 315]
      g.add @d.line [@_hsiRV(HSI_C, HSI_CASE, 0, a), @_hsiRV(HSI_C, HSI_MARK, 0, a)],
                    @d.c2h.lightGray, 1.0, HSI_CLIP
    g

  # a full circle about the card centre, clipped like the rest
  _hsiArc: (r, color) ->
    pts = (@_hsiRV(HSI_C, r, 0, a) for a in [0..360])
    @d.line pts, color, 1.0, HSI_CLIP

  # The 72 marks of the card, every five degrees, the ten-degree ones long.
  # The ring is built at heading 0 and turned: mark k sits at 5k - hdg on a
  # card, so the turn is -hdg, and reverse drawing puts mark k where mark -k
  # is, the same length either way (72 marks, alternating).
  #
  # A turn of the card is a rotation in its circular frame, which the
  # display's anisotropic x makes a shear on screen: about the card centre
  # C, with S = diag(HSI_ASP, 1), the map is S R(phi) S^-1.
  _hsiMarks: (hdg, rev) ->
    g = @_kept 'hsiMarks', =>
      ring = new THREE.Object3D()
      ring.matrixAutoUpdate = false
      for k in [0...72]
        a = 5*k - 90
        len = HSI_TICK[k % 2]
        ring.add @d.line [@_hsiRV(HSI_C, HSI_CARD, 0, a), @_hsiRV(HSI_C, HSI_CARD-len, 0, a)],
                         @d.c2h.white, 1.0, HSI_CLIP
      ring
    phi = deg2rad(if rev then hdg else -hdg)
    cs = Math.cos(phi) ; sn = Math.sin(phi)
    [a11, a12] = [cs, -HSI_ASP*sn]
    [a21, a22] = [sn/HSI_ASP, cs]
    [cx, cy] = HSI_C
    g.matrix.set(a11, a12, 0, cx - (a11*cx + a12*cy),
                 a21, a22, 0, cy - (a21*cx + a22*cy),
                 0,   0,   1, 0,
                 0,   0,   0, 1)
    g.matrixWorldNeedsUpdate = true
    g

  # The card's annulus and the two edges of it, which the heading does not
  # move.
  _hsiFace: () -> @_kept 'hsiFace', =>
    g = new THREE.Object3D()
    fill = new THREE.Mesh(new THREE.RingGeometry(HSI_FACE, HSI_CARD, 120),
             new THREE.MeshBasicMaterial({side: THREE.DoubleSide, color: @d.c2h.darkGray}))
    fill.scale.x = HSI_ASP
    fill.position.set(HSI_C[0], HSI_C[1], 0)
    fill.material.clippingPlanes = @d.clipPlanes(HSI_CLIP)
    g.add fill
    g.add @_hsiArc HSI_CARD, @d.c2h.white
    g.add @_hsiArc HSI_FACE, @d.c2h.white
    g

  # compass card at `hdg`: the annulus, marks every 5 degrees (every 10 run
  # long) and a label every 30
  _hsiCard: (hdg, rev = false) ->
    g = new THREE.Object3D()
    g.add @_hsiFace()
    # reverse drawing mirrors each card value about the lubber line, so a
    # value still reads under it when the vehicle is inverted
    sgn = if rev then -1 else 1
    g.add @_hsiMarks(hdg, rev)
    cards = if @data().majorMode in [102, 103] then ['0','9','18','27'] else ['N','E','S','W']
    for k in [0...12]
      txt = if k % 3 == 0 then cards[k/3] else "#{3*k}"
      h = if k % 3 == 0 then HSI_LTR else HSI_DIG
      g.add @_hsiText HSI_C, txt, HSI_LBL, sgn*(30*k - hdg) - 90, h, @d.c2h.white
    g

  # HSI mode indicator (message 1 word 13, MEDS_HSI_MODE_LEFT/RIGHT) and what
  # each mode makes of the instrument, from the HSI Function Matrix
  # (USA-007587 sect.2.7) and JSC-48017/6-14 item 13:
  #
  #   Entry     [H] spherical bearing to the NEP HAC intercept; the CDI is
  #             pegged at zero and its scale unlabelled; the GSI is blanked
  #   TAEM      [H] the same, [C] bearing to the HAC centre and the HAC-C
  #             range box; CDI full scale 10 deg, GSI 5000 ft
  #   Approach  [R] bearing to the runway touchdown point; CDI 2.5 deg,
  #             GSI 1000 ft
  #
  # The secondary pointer's letter outside TAEM is fitted: the JSC-48017
  # availability matrix carries the runway pointer on the secondary bearing
  # through MM 304, 305, 601, 602 and 603, and the function matrix names one
  # pointer for Entry and for Approach.
  HSI_MODE_ENTRY = 1
  HSI_MODE_TAEM = 2
  HSI_MODE_APPROACH = 3
  HSI_MODE_LTR =
    1: {pri: "H", sec: "R"}
    2: {pri: "H", sec: "C"}
    3: {pri: "R", sec: "R"}
  # CDI full scale in degrees for TAEM and Approach (item 14, "the scale and
  # digital set to 10 (deg) ... at HSI approach and land, the scale and
  # digital changes to 2.5 (deg)"); the GSI's in feet (item 19).
  HSI_CDI_DEG = {2: "10", 3: "2.5"}
  HSI_GSI_LBL = {2: "5K", 3: "1K"}

  # The letters the two bearing pointers carry.  In powered flight the HSI
  # mode word is not yet valid (it turns on at the first area navigation
  # pass): the primary is the runway pointer and the secondary the inertial
  # velocity pointer, and the primary becomes the HAC pointer after the RTLS
  # powered pitch-around.  With neither a mode nor a major mode the letters
  # are the P and S of figure 3.12.2-2's legend.
  _hsiLetters: () ->
    d = @data()
    return HSI_MODE_LTR[d.hsiMode] if HSI_MODE_LTR[d.hsiMode]?
    if d.majorMode in [101, 102, 103, 104]
      {pri: "R", sec: "I"}
    else if d.majorMode == 601
      {pri: (if d.ppa then "H" else "R"), sec: "I"}
    else
      {pri: "P", sec: "S"}

  # course pointer, its tail, the four deviation dots across them and the
  # deviation bar, all on the face centre
  _hsiCourse: (crs, cdi, cdiValid) ->
    g = new THREE.Object3D()
    ca = crs - 90
    for [shape, sg] in [[HSI_ARROW, 1], [HSI_CTAIL, -1]]
      arw = @_hsiShape(HSI_FC, shape, ca, sg, @d.c2h.magenta)
      arw.renderOrder = HSI_ORD.ptr
      g.add arw
    for k in [-2, -1, 1, 2]
      [dx, dy] = @_hsiRV(HSI_FC, 0, k*HSI_DOT, ca)
      dot = @d.filledArc dx, dy, 0.30, 0, 360, @d.c2h.white
      dot.material.clippingPlanes = @d.clipPlanes(HSI_CLIP)
      dot.material.transparent = true
      dot.renderOrder = HSI_ORD.dot
      g.add dot
    lbl = @_hsiCdiScale(ca)
    if lbl?
      lbl.traverse (o) -> o.renderOrder = HSI_ORD.ltr
      g.add lbl
    if cdiValid
      v = Math.max(-3, Math.min(3, cdi)) * HSI_DOT
      [hl, hw] = HSI_DEV
      bar = @_hsiShape(HSI_FC, [[hw, -hl], [hw, hl]], ca, 1, @d.c2h.magenta)
      bar.position.set(-Math.sin(deg2rad(ca))*v*HSI_ASP, Math.cos(deg2rad(ca))*v, 0)
      bar.renderOrder = HSI_ORD.bar
      g.add bar
    g

  # Course Deviation Indicator (CDI) - Shows the lateral off-set from the
  # targeted plane or course in nautical miles. It is auto re-scaled at
  # 50, 10, & 1 nm and labeled accordingly, with one mile scaling only
  # occurring after 6+30 MET. ... During entry (MM 304 and 602), the CDI
  # dots are displayed but without scaling (indicated by the absence of
  # labels). During TAEM (MM 305 and 603), the CDI represents the angular
  # displacement from the runway centerline, and the scale and digital set
  # to 10 (deg). At HSI approach and land, the scale and digital changes
  # to 2.5 (deg).
  #
  #       [JSC-48017/6-15 item 14]
  #
  # Powered flight takes the label from message 1 word 22, which the GPC
  # marks valid in MM 101 to 104; glided flight from the HSI mode.  It sits
  # beyond the outer dot on the fly-left side of the dot row (figure 6-8).
  HSI_CDI_LBL = 3.5              # rows along the dot row from the face centre
  HSI_CDI_ADV = 0.72
  _hsiCdiScale: (ca) ->
    d = @data()
    txt = if d.majorMode in [101, 102, 103, 104]
      if d.cdiScale? then "#{d.cdiScale}" else null
    else
      HSI_CDI_DEG[d.hsiMode]
    return null unless txt
    [cx, cy] = @_hsiRV(HSI_FC, 0, -HSI_CDI_LBL, ca)
    @d.strMEDS cx - (txt.length-1)*HSI_CDI_ADV/2 - 0.36, cy + 0.33, txt,
               @d.c2h.white, 0.85, HSI_CDI_ADV, 1.0, HSI_CLIP

  drawHSI: () ->
    # Horizontal Situation Indicator (HSI)
    #
    # The compass card replaces N, E, S, and W with 0, 9, 18, and 27
    # in MM 102/103, and references the target insertion plane
    # course as the baseline for 0 on the display. For MM 304/305
    # and MM 601-603, the card reflects magnetic heading indicated
    # by N, E, S, and W being present on the compass card. In
    # powered flight, the compass card is reverse drawn while
    # inverted, thus will always reflect the correct heading
    # information, regardless of whether the vehicle is heads-up or
    # heads-down.
    #
    # For ascent, heading references the target insertion plane,
    # with 0 representing the pre-flight planned target insertion
    # plane course. The course arrow is pinned at 0 unless TAL or
    # ATO is selected with variable IY active. If TAL, the arrow is
    # redefined to point at a tangent to a cross- range circle
    # around the TAL site, and reflects the nominal or minimum
    # crossrange, as appropriate. If ATO and variable IY is active,
    # the course arrow indicates the new target inclination course
    # (if redefined), with 0 still representing the pre-launch
    # target insertion plane course. If variable IY steering is not
    # active, the course arrow remains pegged at 0.
    #
    # The VREL Bearing Pointer, labeled "E", indicates the direction
    # of the Earth-relative velocity vector relative to the vehicle
    # nose (lubber line) & course (compass card/course arrow). It
    # works in concert with the beta digital readout, and both the
    # "E" bearing pointer and the beta digital blank on ascent at
    # altitude > 200K or MET > 2:30.
    #
    # In MM 102-104 and 601, the Inertial Bearing Pointer, labeled
    # "I", indicates the direction of the inertial velocity vector
    # relative to nose & course. It is not displayed in glided or
    # orbital flight.
    #
    # The Runway/HAC Bearing Pointer (labeled "*" in the figure)
    # indicates "R" for bearing to runway in powered flight and "H"
    # for bearing to HAC in gliding flight. It appears at RTLS/TAL
    # abort select & entry (MM 304/305 and 602/603).
    #
    # The HAC Center Bearing Pointer, labeled "C", indicates bearing
    # to the HAC center during TAEM (MM 305 and 603).
    #
    # The bearing flag (BRG) is displayed when valid TACAN, GPS, or
    # MLS data is not available due to commfault, lack of comm-lock,
    # or invalid station.
    #
    # Ranges:
    #           Compass Card - 0- 360 degrees
    #
    #       [JSC-48017/6-14 item 13]
    #
    # The course and bearing words carry the vehicle heading already
    # subtracted, so they are angles on the case: "the software must
    # subtract (modulo 360) the vehicle's heading from the course. It is
    # this difference that is represented by the digital input to the HSI
    # from the DDU" (STS-83-0020V1-34 sect.3.12.2 (3)).
    d = @data()
    hsi = new THREE.Object3D(name="HSI") #"
    # word 9 bit 10 is the HSI heads-down flag (table F.4.128.1-2)
    rev = d.rollSw and d.majorMode in [101, 102, 103, 104, 601]
    hsi.add @_hsiCard((if d.hsiHeadingValid then d.hsiHeading ? 0 else 0), rev)
    hsi.add @_hsiCase()

    if d.hsiCourseValid
      hsi.add @_hsiCourse(d.hsiCourse ? 0, d.hsiCdi ? 0, d.hsiCdiValid)
    unless d.hsiCdiValid
      hsi.add @_hsiFlag HSI_FC[0], HSI_C[1] - 3.78, "CDI"

    # primary and secondary bearing pointers, each a head on the card's
    # outer edge and a tail opposite it, both carrying the letter
    # The primary and secondary bearings come from the DDU words; the
    # relative velocity pointer is message 1 word 24, which the GPC drives
    # in MM 102, 103 and 601 and stops at 200K feet or MET 2:30
    # (F.4.104, MEDS_BETAHVR_VALID).  Its shape here is the bearing
    # pointer's and its colour is fitted: figure 6-8 draws it as a larger
    # solid triangle and no legend gives the colour.
    ltrs = @_hsiLetters()
    for [brg, ok, clr, ltr] in [[d.hsiPriBearing, d.hsiPriBearingValid, @d.c2h.green, ltrs.pri]
                                [d.hsiSecBearing, d.hsiSecBearingValid, @d.c2h.white, ltrs.sec]
                                [d.hVr, d.hVr?, @d.c2h.lightGray, "E"]]
      continue unless ok
      ba = (brg ? 0) - 90
      g = new THREE.Object3D()
      for [shape, sg] in [[HSI_BHEAD, 1], [HSI_BTAIL, -1]]
        tag = @_hsiShape(HSI_C, shape, ba, sg, clr)
        tag.renderOrder = HSI_ORD.ptr
        g.add tag
      for [lr, la, lu] in [[HSI_BLTR[0], ba, 1], [HSI_BLTR[1], ba + 180, -1]]
        t = @_hsiText HSI_C, ltr, lr, la, 0.62, @d.c2h.black, lu
        t.traverse (o) -> o.renderOrder = HSI_ORD.ltr
        g.add t
      hsi.add g
    # heading or either bearing (STS-83-0020V1-34 sect.3.12.2 (8)).  The
    # figure puts the flag off the case, under the menu area; this place on
    # the face is fitted.  The flag belongs to the modes that drive the
    # bearings — glided flight, RTLS, and a TAL abort.  The secondary is out
    # of the test: MM 601 leaves that word alone (F.4.104, the control
    # word).
    brgMode = d.majorMode in [304, 305, 601, 602, 603] or not d.majorMode? or
              (d.majorMode in [103, 104] and d.abortMode == 'TAL')
    if brgMode and not (d.hsiHeadingValid and d.hsiPriBearingValid)
      hsi.add @_hsiFlag HSI_C[0] - 3.2*HSI_ASP, HSI_FC[1], "BRG"

    # fixed orbiter symbol, over everything else on the face
    orb = @_hsiShape(HSI_FC, HSI_ORB, 90, 1, @d.c2h.lightGray)
    orb.renderOrder = HSI_ORD.orb
    hsi.add orb

    hsi.position.z = -.001

    return hsi

  # digital attitude readout, R/P/Y order (FDF convention, not the PYR Euler
  # sequence); takes the gimbal-protect-processed values from updateADI()
  drawADIDigitals: (r, p, y, valid=true) ->
    r ?= @data().adiRol ; p ?= @data().adiPch ; y ?= @data().adiYaw
    wrap = (v) -> (Math.round(v ? 0) % 360 + 360) % 360
    group = new THREE.Object3D()
    group.add @d.strMEDS 36.65,1.7,"R", @d.c2h.darkGray, 0.85, .85, 0.85
    group.add @d.strMEDS 36.65,2.7,"P", @d.c2h.darkGray, 0.85, .85, 0.85
    group.add @d.strMEDS 36.65,3.7,"Y", @d.c2h.darkGray, 0.85, .85, 0.85
    if valid   # value fields blank in OFF mode
      group.add @d.strMEDS 37.80,1.7, zpad(wrap(r)), @d.c2h.white, 0.85, .71
      group.add @d.strMEDS 37.80,2.7, zpad(wrap(p)), @d.c2h.white, 0.85, .71
      group.add @d.strMEDS 37.80,3.7, zpad(wrap(y)), @d.c2h.white, 0.85, .71
    return group


  drawHorizGauge: (value,rangeMin,rangeMid,rangeMax,tickLeft,tickRight,tickBot,sLen,lLen, count,top=true,pointerOnly=false) ->
    gauge = new THREE.Object3D()

    if top
      sTickTop = tickBot - sLen
      lTickTop = tickBot - lLen
      eTickTop = tickBot - 1.3*lLen
      tTickBot = tickBot + .5 + .6
      tTickTop = tickBot - .7 + .6
    else
      sTickTop = tickBot + sLen
      lTickTop = tickBot + lLen
      eTickTop = tickBot + 1.3*lLen
      tTickBot = tickBot - .5 - .6
      tTickTop = tickBot + .7 - .6

    scaleLen = tickRight - tickLeft

    unless pointerOnly
      gauge.add @d.line [[tickLeft,tickBot],[tickRight,tickBot]], @d.c2h.darkGray
      for i in [0..count]
        x = i* (scaleLen/count)
        # end and centre ('0') ticks run slightly longer
        x2 = if i == 0 or i == count or i*2 == count then eTickTop
        else if i%2 then sTickTop
        else lTickTop
        gauge.add @d.line [[tickLeft+x,tickBot],[tickLeft+x,x2]], @d.c2h.darkGray

    if value?
      x = tickLeft + (value * (scaleLen/count))
      # x half-width .61 = .9 cols unstretched (drawn inside @adiC, x in rows)
      gauge.add @_greenArrow [[x-.61, tTickBot], [x, tTickTop], [x+.61, tTickBot]], 1.08

    return gauge

  drawVertGauge: (value,rangeMin,rangeMid,rangeMax,tickTop,tickBot,tickLeft,sLen,lLen, count,left=true,pointerOnly=false) ->
    gauge = new THREE.Object3D()

    # pointer x offsets in unstretched (row) units (drawn inside @adiC):
    # .51/.48/.58 = .75/.7/.85 cols
    if left
      sTickRight = tickLeft - sLen
      lTickRight = tickLeft - lLen
      eTickRight = tickLeft - 1.3*lLen
      tTickLeft = tickLeft + .51  + .48
      tTickRight = tickLeft - .58 + .48
    else
      sTickRight = tickLeft + sLen
      lTickRight = tickLeft + lLen
      eTickRight = tickLeft + 1.3*lLen
      tTickLeft = tickLeft - .51 - .48
      tTickRight = tickLeft + .58 - .48

    scaleLen = tickBot - tickTop

    unless pointerOnly
      gauge.add @d.line [[tickLeft,tickTop],[tickLeft,tickBot]], @d.c2h.darkGray
      for i in [0..count]
        x = i * (scaleLen/count)
        # end and centre ('0') ticks run slightly longer
        x2 = if i == 0 or i == count or i*2 == count then eTickRight
        else if i%2 then sTickRight
        else lTickRight
        gauge.add @d.line [[tickLeft,tickTop+x],[x2,tickTop+x]], @d.c2h.darkGray

    if value?
      x = tickTop + (value * (scaleLen/count))
      gauge.add @_greenArrow [[tTickLeft, x-.6], [tTickRight, x], [tTickLeft, x+.6]], 1.08

    return gauge
