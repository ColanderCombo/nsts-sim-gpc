# import * as fs from 'fs'
fs = window.fs
import * as THREE from 'three'

import {Bus, BusMsg} from './../com/bus.civet.jsx'
import {MDUScreen} from 'meds/mduScreen'
import {FCW, wordsFromBytes} from 'meds/deuFCW'
import * as FCWD from 'meds/deuFCW'
import * as DEU from 'meds/deuProto'
import {SPL, ERR_TEXT} from 'meds/deuSPL'

dispose3D= (obj) ->
  if obj.children?
    for c in obj.children
      dispose3D(c)
  if obj.geometry?
    obj.geometry.dispose()
  if obj.material?
    obj.material.dispose()

export class Screen_DPS extends MDUScreen
  setData: (@curData) ->
    if not @curData?
      @curData = {
        kybd: 'left'
        gpcNo: 1
        pollFail: false
        syntaxError: false
      }
    @init()

  data: () ->
    return @curData

  setGPCNo: (@gpcNo) ->
    @group.remove @geo_gpcNo
    @geo_gpcNo = @d.str(25,30.715,"#{@gpcNo}",@d.c2h.green,1.75)
    @group.add @geo_gpcNo

  setKybd: (@kybd) ->
    @curData.kybd = @kybd if @curData?
    @group.remove @geo_kybd_left
    @group.remove @geo_kybd_right
    if @kybd == 'left'
      @group.add @geo_kybd_left
    else if @kybd == 'right'
      @group.add @geo_kybd_right
    @d.dirty = true

  POLL_FAIL_COLOR = 48
  POLL_FAIL_X = [[0, 1, 52, 27], [52, 1, 0, 27]]
  POLL_FAIL_AT = [41, 26]

  _pollFailFCWs: () ->
    fcws = [@fcw.colorMode(POLL_FAIL_COLOR), @fcw.attrMode({intensity: true})]
    fcws = fcws.concat @fcw.vector(seg...) for seg in POLL_FAIL_X
    fcws.concat @makeDFB("POLL FAIL", {xy: POLL_FAIL_AT})

  setPollFail: (fail) ->
    @curData.pollFail = fail if @curData?
    # POLL FAIL shares the scratch pad line, and takes 10 characters off what
    # may be entered on it: 29 rather than 39.
    @spl.pollFail = fail if @spl?
    return if not @fcw? or not @geo_pollFail?
    @geo_pollFail = @drawFCWS((if fail then @_pollFailFCWs() else []),
                              @geo_pollFail)

  setSyntaxError: (err) ->
    @curData.syntaxError = err if @curData?
    if @geo_dps_scratch_err?
      @group.remove @geo_dps_scratch_err
      dispose3D(@geo_dps_scratch_err)
      @geo_dps_scratch_err = null
    if err
      @geo_dps_scratch_err = @d.str 48, 27, "ERR", @d.c2h.red
      @group.add @geo_dps_scratch_err
    @d.dirty = true


  # A fill of the unit's display memory: `words` load at `addr`, and the
  # screen redraws from the refresh entry point afterwards. 
  applyFill: (addr, words) ->
    for w, i in words
      @bgFCWS[(addr + i) & (@bgFCWS.length - 1)] = w & 0xffff
    @refresh()

  # Redraw the display from display memory.  The refresh starts at the display
  # header and follows the branch words from there
  refresh: () ->
    @geo_dps_fcws = @drawFCWS(@bgFCWS, @geo_dps_fcws,
                              {memory: @bgFCWS, start: DEU.ADDR.DISPLAY_HEADER})

  # Load a bare format control word stream at the refresh entry point --
  # the debug path for a captured display, and what dev mode uses.
  setBGDFB: (words) ->
    @bgFCWS.fill(0)
    @applyFill(DEU.ADDR.DISPLAY_HEADER, words)

  # ---------------------------------------------------------------------
  # The DEU beam interpreter.
  #
  # An FCW stream is a program for a stroke-writing beam.  Mode-register
  # writes latch drawing state, position words move the beam, a glyph word
  # draws one or two characters and advances the beam by the MAJOR step,
  # and a carriage return sends it back to the start of the line and on by
  # the MINOR step.  A vector is a run of six words: enter vector mode,
  # position, a slope word, an extent word, and a mode word to leave.
  #
  # A section ends at the end-of-refresh bit in an FCW2, or at a BRANCH with
  # nowhere left to go
  #
  # ---------------------------------------------------------------------
  MAX_FCW_STEPS = 40000     # a runaway branch loop must not hang the frame

  drawFCWS: (fcws, targetGroup, opts = {}) ->
    @group.remove targetGroup
    dispose3D(targetGroup)
    targetGroup = new THREE.Object3D()

    # Beam and mode registers
    beamX = FCWD.COL_ORIGIN ; beamY = FCWD.ROW_ORIGIN     # beam position
    tx = ty = 0                                           # X/Y reference registers
    xyRef = false                                         # ... and their FCW2 gate
    homeX = beamX ; homeY = beamY                         # carriage-return home
    majorStep = FCWD.COL_PITCH                            # per-glyph advance
    minorStep = -FCWD.ROW_PITCH                           # per-carriage-return
    axisY = false                                         # spacing direction
    blink = dash = bright = false
    large = false ; rotated = false ; angle = 0
    colorCode = null                                      # null = the DEU default
    slope = null
    repeatCount = 0

    # A glyph is drawn at the beam, in the character-cell coordinates the rest
    # of the display is laid out in.  The +1 on each axis is the DPS format
    # area's own origin.  The reference registers are NOT added here -- the
    # position words below fold them in.
    penX = () -> FCWD.cellCol(beamX) + 1
    penY = () -> FCWD.cellRow(beamY) + 1

    blinkGroup = new THREE.Object3D()
    blinkGroup.userData.deuBlink = true
    blinkGroup.visible = @_blinkOn ? true
    targetGroup.add blinkGroup
    add = (o) -> (if blink then blinkGroup else targetGroup).add o

    # NSTS_FCW_TRACE logs what the beam interpreter drew
    trace = if globalThis.process?.env?.NSTS_FCW_TRACE then (kind, extra = '') =>
      console.log "FCW #{kind}  beam #{Math.round(beamX)},#{Math.round(beamY)}" +
        " tr #{tx},#{ty}  cell #{penX().toFixed(2)},#{penY().toFixed(2)}  #{extra}"
    else null

    penColor = () =>
      return @_deuColor(colorCode) if colorCode?
      @d.c2h.green
    penIntensity = () -> if bright then 1.0 else 0.72

    advance = () ->
      if axisY then beamY += majorStep else beamX += majorStep

    carriageReturn = () ->
      if axisY
        beamY = homeY ; beamX += minorStep
      else
        beamX = homeX ; beamY += minorStep

    drawGlyph = (g) =>
      switch g
        when 0x0d                      # carriage return
          carriageReturn()
        when 0x08                      # backspace: undo one advance
          if axisY then beamY -= majorStep else beamX -= majorStep
        when 0x00
          null
          # The empty half of a single-glyph word draws nothing AND does not
          # advance.  A display packs two glyphs to a word and puts an odd
          # trailing one in the LOW half with zero above it, so a zero that
          # advanced the beam would push every odd-length label one column
          # right of where its deck put it.
        else
          ch = @fcw.DEUCharset[g]
          if ch? and ch != ' '
            trace? 'GLYPH', "'#{ch}'"
            add @d.str penX(), penY(), ch, penColor(),
              (if large then FCWD.COL_PITCH_L / FCWD.COL_PITCH else 1.0),
              1.0, 1.0, @d.deuFont, angle, false
          advance()

    # A vector's two words carry the extent along the major axis and the
    # minor/major ratio; reconstruct both deltas in beam units and draw
    # from the beam to the far end, leaving the beam there.
    drawVector = (a, b) =>
      major = if b.negative then -b.len else b.len
      minor = Math.round((a.slope / 2) * b.len / 512)
      if a.yMajor
        dy = major
        dx = minor * (if a.signDiffer then -1 else 1) * (if dy < 0 then -1 else 1)
      else
        dx = major
        dy = minor * (if a.signDiffer then -1 else 1) * (if dx < 0 then -1 else 1)
      x0 = penX() ; y0 = penY()
      trace? 'VECTOR', "d #{dx},#{dy} major=#{major} minor=#{minor} " +
                       "yMajor=#{a.yMajor} signDiffer=#{a.signDiffer} slope=#{a.slope}"
      beamX += dx ; beamY += dy
      seg = [[x0, y0], [penX(), penY()]]
      if dash
        add @d.dashedLine seg, penColor()
      else
        add @d.line seg, penColor(), penIntensity()

    # The walk is by index, not `for word in fcws`, because a BRANCH moves the
    # program counter.  CoffeeScript's `break` inside a `switch` would break
    # the switch rather than the loop, hence the `done` flag.
    src = opts.memory ? fcws
    pc = opts.start ? 0
    visited = {}
    splice = null                 # the SUBLIST frame: {left, ret}
    done = false
    steps = 0
    while not done and pc >= 0 and pc < src.length and steps < MAX_FCW_STEPS
      steps++
      # A spliced run ends when its word count runs out -- it has no
      # terminator of its own -- so the return is checked before the fetch.
      if splice? and splice.left <= 0
        pc = splice.ret
        splice = null
        continue
      word = src[pc]
      pc++
      splice.left-- if splice?
      desc = @fcw.decodeFCW(word)
      continue if not desc?
      v = desc.v
      switch desc.nm
        when 'NOOP'
          null                          # position-run lead / buffer fill
        when 'REPT'
          repeatCount = v.count
        when 'BRANCH'
          tgt = v.addr
          if splice?
            null                        # a branch inside a spliced run is
                                        # data, not a jump: taking it would
                                        # lose the return address
          else if opts.memory? and not visited[tgt]
            visited[tgt] = true
            pc = tgt
          else
            done = true                 # nowhere to go: end of the section
        when 'SUBLIST'
          # `SUBLIST count` + `BRANCH addr`: draw `count` words from `addr`,
          # then carry on after the branch word.  
          #
          # Done by moving the program counter and remembering how many words
          # to take, so the spliced run goes through this same switch: it
          # draws with the registers the static text left set, which is the
          # point -- the values continue the line they sit in.
          #
          # One frame deep.  No spliced run observed contains another, and a
          # length-counted call has nowhere to keep a second return address;
          # a nested one is stepped over rather than followed, so a bad count
          # can never walk off with the program counter.
          nxt = @fcw.decodeFCW(src[pc])
          if splice?
            if nxt?.nm == 'BRANCH'
              pc++
              splice.left--             # the skipped word is still one of ours
          else if nxt?.nm == 'BRANCH' and v.count > 0
            splice = {left: v.count, ret: pc + 1}
            pc = nxt.v.addr
        when 'FCW1'
          dash = v.dash == 1
          blink = v.blink == 1
          bright = v.intensity == 1
          axisY = v.axisY == 1
        when 'FCW2'
          # AC5+AC4 gate the X/Y reference registers: while they are clear
          # the registers are held but not applied.
          xyRef = v.xyRef == 3
          if v.eor == 1
            done = true                 # end of refresh
          else if (v.mode & 0x7) != FCWD.MODE.VECTOR
            large = (v.mode & 1) == 1
            # the upright bit is cleared while a rotation is in force
            angle = 0 if (v.mode & 0x4) != 0
        when 'FCW3'
          colorCode = if v.select == 1 then v.color else null
        when 'ROT'
          angle = -2 * Math.PI * v.angle / 4096
        when 'MAJINC'
          majorStep = v.step
        when 'MININC', 'SPTYPE'
          minorStep = v.step
        when 'XPOS'
          # An X position word starts a new BLOCK: it re-homes the beam
          # vertically as well as setting the column.  Only observable when
          # an X word stands alone -- all 2450 X words across the deck corpus
          # are immediately followed by a Y word that overrides it -- and the
          # live GPCIPL menu has exactly one, `XPOS 1839` between BFS4 and
          # PASS5, where the real display puts PASS5 back on PASS1's row.
          #
          # The X/Y reference registers (the flight macros' `XTRN`/`YTRN`)
          # are held: every position word on the axis draws at reference +
          # coordinate for as long as FCW2's AC5+AC4 gate is set. 
          if v.translate == 1
            tx = v.x
          else
            beamX = (v.x + (if xyRef then tx else 0)) %% FCWD.GRID
            homeX = beamX ; beamY = homeY
        when 'YPOS'
          if v.translate == 1
            ty = v.y
          else
            beamY = (v.y + (if xyRef then ty else 0)) %% FCWD.GRID
            homeY = beamY
        when 'VECA'
          slope = v
        when 'VECB'
          drawVector(slope, v) if slope?
          slope = null
        when 'CHAR2'
          n = if repeatCount > 0 then repeatCount else 1
          repeatCount = 0
          for _ in [0...n]
            drawGlyph(v.g1)
            drawGlyph(v.g2)
        # VDISP and LSITE latch state this renderer does not draw.

    @group.add targetGroup
    @d.dirty = true

    return targetGroup


  # "The flash rate for characters is 1 Hz with 5/8 sec 'on' time and 3/8
  # second 'off' time".  The IDP beats eight times a second, so a phase is
  # five beats lit and three dark.  Driven by that beat and not by a timer
  # of its own, so a display with a dead port stops flashing; see
  # `mdu.recvFromPri`.
  #
  BLINK_ON_BEATS = 5
  BLINK_OFF_BEATS = 3

  blinkTick: () ->
    @_blinkBeats = (@_blinkBeats ? 0) + 1
    return if @_blinkBeats < (if @_blinkOn then BLINK_ON_BEATS else BLINK_OFF_BEATS)
    @_blinkBeats = 0
    @_blinkOn = not @_blinkOn
    showing = 0
    @group.traverse (o) =>
      return if not o.userData?.deuBlink
      o.visible = @_blinkOn
      showing++ if o.children.length > 0
    # Only ask for a frame when something is actually blinking.
    @d.dirty = true if showing > 0

  # The FCW3 palette index -> an RGB colour.
  #
  # The index-to-colour table is not in any document to hand.  Every COLOR=
  # value the display decks use (4, 7, 29, 31, 33, 40, 47, 48, 56) reads
  # consistently as three 2-bit channels -- bits 5-4 red, 3-2 green, 1-0 blue
  # -- giving pure red for 48, orange for 56, yellow for 40 and plain green
  # for 4, which is what those displays want.
  _deuColor: (code) ->
    lvl = [0x00, 0x60, 0xb0, 0xff]
    r = lvl[(code >> 4) & 3]
    g = lvl[(code >> 2) & 3]
    b = lvl[code & 3]
    (r << 16) | (g << 8) | b

  draw: () ->
      
  build: () ->
    if not @curData?
      @setData()
    @group = new THREE.Object3D()
    @group.position.y = -0.75               # DPS vertical position (was +1, shifted up 1.75)

    @geo_gpcNo = @d.str(24.75,30.665,"#{@data().gpcNo}",@d.c2h.green,1.75)   # down 1/2 box height, up ~4px
    @group.add @geo_gpcNo
    @geo_gpcBox = @d.box 24.60,30.265 ,28.40,32.915
    @group.add @geo_gpcBox


    # kybd-active bar: 2px-tall filled quad, 1/4 up from the GPC box bottom,
    # ending just clear of the box sides (box x 24.60..28.40, y ..32.915)
    kbY = 32.25
    @geo_kybd_right = @d.box 28.45, kbY-0.053, 41.40, kbY+0.053, null, @d.c2h.yellow
    @geo_kybd_left = @d.box 12, kbY-0.053, 24.55, kbY+0.053, null, @d.c2h.red
    @setKybd @data().kybd

    @geo_dps_time = new THREE.Object3D()
    @group.add @geo_dps_time

    @geo_scratchpad = new THREE.Object3D()
    @group.add @geo_scratchpad

    @geo_pollFail = new THREE.Object3D()
    @group.add @geo_pollFail

    # fresh group: stale refs from a previous build must not be removed from it
    @geo_dps_scratch_err = null
    @setPollFail @data().pollFail
    @setSyntaxError @data().syntaxError

    y=2
    @geo_dps_fcws = new THREE.Object3D()
    @group.add @geo_dps_fcws

    @_blinkOn ?= true

    # dev mode: preload the DEU self-test critical format locally.
    # Otherwise the display stays blank until an IDP delivers a
    # background DFB over the bus.
    @dispCritFormat(0) if @d.CONFIG.dev


  # the header clock
  #
  # The GPC ships SECONDS (two 48-bit extended floats and a conversion word,
  # `DEU.parseTimeFill`) and the display converts, so the DDD/HH:MM:SS is
  # drawn here rather than sent.
  #
  # It doesn't currently go into DEU display memory, but it probably should.
  #
  _clockText: (secs) ->
    secs = Math.max(0, Math.floor(secs))
    pad = (v, n) -> "#{v}".padStart(n, '0')
    "#{pad(Math.floor(secs / 86400), 3)}/#{pad(Math.floor(secs / 3600) % 24, 2)}:" +
    "#{pad(Math.floor(secs / 60) % 60, 2)}:#{pad(secs % 60, 2)}"

  setClock: (missionSecs, eventSecs, conv = 1) ->
    @_clock = {mission: missionSecs, event: eventSecs, conv: conv}
    # A time fill can arrive before this screen has ever been built: the GPC
    # starts polling as soon as it is up and the DPS page may not be the one
    # on show.  Keep the value and draw it when there is something to draw
    # into.
    return if not @fcw? or not @geo_dps_time?
    fcws = @makeDFB(@_clockText(missionSecs), {xy: [39, 0]})
             .concat(@makeDFB(@_clockText(eventSecs), {xy: [39, 1]}))
    @geo_dps_time = @drawFCWS(fcws, @geo_dps_time)

  # Text at a character cell -> the FCWs that draw it: a position run, then
  # glyph pairs.
  makeDFB: (s, opt = {}) ->
    dfb = if opt?.xy? then @fcw.positionRun(opt.xy[0], opt.xy[1]) else []
    dfb.concat(@fcw.chars(s))

  # SPL: the scratch pad line
  #
  # The rules live in `meds/deuSPL`
  updateScratchpad: () ->
    @spl ?= new SPL(pollFail: @data().pollFail)
    fcws = @fcw.positionRun(0, 27)
    # The command initiator flashes until the command is complete.
    # ERR flashes.  The blink attribute is a mode register, not a
    # property of the text, so it has to be turned off again after each run.
    span = @spl.initSpan
    if span? and not @spl.complete
      fcws = fcws.concat @makeDFB(@spl.line[0...span[0]])
      fcws.push @fcw.attrMode({blink: true})
      fcws = fcws.concat @makeDFB(@spl.line[span[0]...span[1]])
      fcws.push @fcw.attrMode({})
      fcws = fcws.concat @makeDFB(@spl.line[span[1]..])
    else
      fcws = fcws.concat @makeDFB(@spl.line)
    if @spl.err
      fcws.push @fcw.attrMode({blink: true})
      fcws = fcws.concat @makeDFB(ERR_TEXT)
      fcws.push @fcw.attrMode({})
    @geo_scratchpad = @drawFCWS(fcws, @geo_scratchpad)
    @d.dirty = true

  recvKey: (k) ->
    @spl ?= new SPL(pollFail: @data().pollFail)
    @spl.press k.gpcCode
    @updateScratchpad()

  init: () ->  
    @fcw = new FCW()
    @bgFCWS = new Uint16Array(DEU.DEU_MEMORY_WORDS)

    @loadCritFormats()

    @spl = new SPL(pollFail: @data().pollFail)
    @syntaxError = false


  loadCritFormats: () ->
    @critFormats = {}
    pth=@d.CONFIG.NSTS_TOP+'data/'
    @critFormats[0] = @loadBGDFBFile pth+'0000-DEU_STAND_ALONE_SELF_TEST.dfb'

  dispCritFormat: (fmtNum) ->
    @setBGDFB(@critFormats[0])

  loadBGDFBFile: (path) -> wordsFromBytes fs.readFileSync(path)

  _dfbList: () ->
    pth = @d.CONFIG.NSTS_TOP + 'data/'
    if not @_dfbFiles?
      @_dfbFiles = (f for f in fs.readdirSync(pth) when /\.dfb$/i.test(f)).sort()
      @_dfbIndex = -1        # nothing selected yet
    @_dfbFiles

  setBGDFBByName: (fname) ->
    i = @_dfbList().indexOf(fname)
    return if i < 0
    @_dfbIndex = i
    @setBGDFB(@loadBGDFBFile(@d.CONFIG.NSTS_TOP + 'data/' + fname))
    console.log "DPS bg DFB: #{fname}"
    return

  # descriptors for the parameter editor's test-control section
  testControls: () ->
    [
      {label: 'DEU self test',
       get: (=> !!@selfTestOn), set: ((v) => if v then @enterSelfTest() else @exitSelfTest())}
      {label: 'BG DFB', options: ['—'].concat(@_dfbList()),
       get: (=> if @_dfbIndex? and @_dfbIndex >= 0 then @_dfbFiles[@_dfbIndex] else '—'),
       set: ((f) => @setBGDFBByName(f))}
      {label: 'Kybd', options: ['left', 'right', 'none'],
       get: (=> @curData?.kybd ? 'none'),
       set: ((v) => @setKybd(if v == 'none' then null else v))}
      {label: 'POLL FAIL',
       get: (=> !!@curData?.pollFail), set: ((v) => @setPollFail(v))}
      {label: 'Syntax err',
       get: (=> !!@curData?.syntaxError), set: ((v) => @setSyntaxError(v))}
      # (the F7 reference-overlay group — image/slot/apply-values — is
      # appended generically by the param editor; see mdu._ovControls)
    ]

  # Debug: cycle the DPS background through every data/*.dfb (dir = +1 / -1)
  cycleBGDFB: (dir) ->
    @_dfbList()
    pth = @d.CONFIG.NSTS_TOP + 'data/'
    return if @_dfbFiles.length == 0
    n = @_dfbFiles.length
    @_dfbIndex = ((@_dfbIndex + dir) % n + n) % n
    fname = @_dfbFiles[@_dfbIndex]
    console.log "DPS bg DFB [#{@_dfbIndex+1}/#{n}]: #{fname}"
    @setBGDFB(@loadBGDFBFile(pth + fname))
    return fname

  # ---------------------------------------------------------------------------
  # DEU stand-alone self-test animation (debug mode).
  # Loads the static 0000 self-test format, overwrites its terminating branch
  # with animated elements, and rewrites their FCWs on a timer to animate the
  # elements the  DEU updated live (boxed vectors, revolving letters, the
  # two travelling squares, and the spinning "bug").
  #
  # Written inDEU FCWs, so it is limited to what the DEU can express:
  # characters rotate in quarter turns only and come in two sizes only, and
  # intensity is one bit.
  #
  # Slot sizes (the layout in `enterSelfTest` depends on them):
  #   position + glyph      3 words
  #   angle + position + glyph  4 words
  #   a vector              6 words  (enter vector mode, X, Y, slope,
  #                                   extent, leave vector mode)
  # ---------------------------------------------------------------------------

  ST_CHAR_WORDS = 3
  ST_CHARROT_WORDS = 4
  ST_VECTOR_WORDS = 6

  _stXY: (idx, cx, cy) ->
    @bgFCWS[idx]   = @fcw.xPosition(@fcw.cellX(cx))
    @bgFCWS[idx+1] = @fcw.yPosition(@fcw.cellY(cy))

  _stChar: (idx, cx, cy, ch) ->
    @_stXY(idx, cx, cy)
    @bgFCWS[idx+2] = @fcw.glyphSingle(@fcw.toGlyph(ch))

  _stCharRot: (idx, cx, cy, ch, rot) ->
    q = ((Math.round(rot / (Math.PI/2)) % 4) + 4) % 4
    @bgFCWS[idx] = @fcw.rotation(q)
    @_stChar(idx+1, cx, cy, ch)

  _stLine: (idx, x0, y0, x1, y1) ->
    @bgFCWS[idx + i] = w for w, i in @fcw.vector(x0, y0, x1, y1)
    return

  _stBoxRay: (idx, cx, cy, x0, y0, x1, y1, a) ->
    dc = Math.cos(a) ; dr = Math.sin(a)*0.733
    t = 1e9
    if dc >  1e-6 then t = Math.min(t, (x1-cx)/dc)
    if dc < -1e-6 then t = Math.min(t, (x0-cx)/dc)
    if dr >  1e-6 then t = Math.min(t, (y1-cy)/dr)
    if dr < -1e-6 then t = Math.min(t, (y0-cy)/dr)
    @_stLine(idx, cx, cy, cx+dc*t, cy+dr*t)

  enterSelfTest: () ->
    return if @selfTestOn
    pth = @d.CONFIG.NSTS_TOP + 'data/'
    @setBGDFB(@loadBGDFBFile(pth + '0000-DEU_STAND_ALONE_SELF_TEST.dfb'))
    base = 0
    base++ while base < @bgFCWS.length and
                 @fcw.decodeFCW(@bgFCWS[base])?.nm != 'BRANCH'
    base = 0 if base >= @bgFCWS.length
    o = base
    # leading attribute reset so animated elements draw normal/solid whatever
    # state the static format left set
    @bgFCWS[o] = @fcw.attrMode({})
    o += 1
    @_stLayout = {}
    @_stLayout.boxVec  = o ; o += 4*ST_VECTOR_WORDS   # (2) windmill: 4 half-lines
    @_stLayout.letters = o ; o += 5*ST_CHARROT_WORDS+1 # (3) A,B,C,D,X + angle reset
    @_stLayout.sqH     = o ; o += ST_CHAR_WORDS       # (9A) travelling square
    @_stLayout.sqV     = o ; o += ST_CHAR_WORDS       # (9B) travelling square
    @_stLayout.bug     = o ; o += 16*ST_VECTOR_WORDS  # (10) 16 vectors
    # (8) 5 short + attributes + 5 long + attributes + connector
    @_stLayout.eight   = o ; o += 11*ST_VECTOR_WORDS + 2
    @selfTestOn = true
    @_stT0 = Date.now()
    @tickSelfTest()
    @_stTimer = window.setInterval((=> @tickSelfTest()), 50)
    console.log "DEU self-test animation ON"

  exitSelfTest: () ->
    return if not @selfTestOn
    window.clearInterval(@_stTimer) if @_stTimer?
    @_stTimer = null
    @selfTestOn = false
    @setBGDFB(@critFormats[0])   # back to the static self-test
    console.log "DEU self-test animation OFF"

  toggleSelfTest: () ->
    if @selfTestOn then @exitSelfTest() else @enterSelfTest()

  tickSelfTest: () ->
    return if not @selfTestOn
    t = (Date.now() - @_stT0) / 1000
    L = @_stLayout

    # (2) box windmill: two crossed lines through the box centre, clipped to the
    # box borders as they rotate (drawn as 4 half-lines).
    bx0 = 19 ; by0 = 5 ; bx1 = 24.274 ; by1 = 8.866
    bcx = (bx0+bx1)/2 ; bcy = (by0+by1)/2
    spin2 = t * 0.9
    for i in [0...4]
      @_stBoxRay L.boxVec + i*ST_VECTOR_WORDS, bcx, bcy, bx0, by0, bx1, by1, spin2 + i*(Math.PI/2)

    # (3) AB & CD patterns + X revolving about the circle centre (~33.84 deg/s
    # clockwise, ~10.64 s). AB/CD are each a pair revolving about its own centre.
    # Not yet: X should spin about its own centre, and A/B/C/D should have
    # distinct heights (0.150"/0.125"), which needs the large/small character
    # mode word interleaved with the glyphs.
    lcx = 9 ; lcy = 12 ; Rorb = 7.0 ; rpair = 0.7 ; ASP = 0.733
    wlet = t * (33.84 * Math.PI/180)  # glyphs are centred by the renderer
    pab = wlet                        # clockwise (screen)
    abx = lcx + Rorb*Math.cos(pab) ; aby = lcy + Rorb*ASP*Math.sin(pab)
    tabc = -Math.sin(pab) ; tabr = ASP*Math.cos(pab)   # tangent = clockwise travel dir
    @_stCharRot L.letters + 0*ST_CHARROT_WORDS, abx - rpair*tabc, aby - rpair*tabr, 'A', 0   # trails
    @_stCharRot L.letters + 1*ST_CHARROT_WORDS, abx + rpair*tabc, aby + rpair*tabr, 'B', 0   # leads
    pcd = wlet + Math.PI
    cdx = lcx + Rorb*Math.cos(pcd) ; cdy = lcy + Rorb*ASP*Math.sin(pcd)
    tcdc = -Math.sin(pcd) ; tcdr = ASP*Math.cos(pcd)
    rcd = pcd + Math.PI/2             # base toward centre (flip sign if reversed)
    @_stCharRot L.letters + 2*ST_CHARROT_WORDS, cdx - rpair*tcdc, cdy - rpair*tcdr, 'C', rcd
    @_stCharRot L.letters + 3*ST_CHARROT_WORDS, cdx + rpair*tcdc, cdy + rpair*tcdr, 'D', rcd
    @_stCharRot L.letters + 4*ST_CHARROT_WORDS, lcx, lcy, 'X', wlet
    @bgFCWS[L.letters + 5*ST_CHARROT_WORDS] = @fcw.rotation(0)   # upright again for the squares

    # Both squares start at the same point (col 50.27, row 16) at t=0 and, since
    # 9B's period is exactly 1/4 of 9A's, they coincide there every 4th 9B cycle.
    # (9A) horizontal: centre <-> 3.3975" right; starts at the far right
    triA = 2*Math.abs((t/18.62) % 1 - 0.5)          # 1 at t=0 (rightmost)
    @_stChar L.sqH, 26 + triA*(3.3975*7.143), 16.5, '¥'
    # (9B) vertical at col 50.27; starts at its lowest (row 16.5)
    triB = 1 - 2*Math.abs((t/(18.62/4)) % 1 - 0.5)  # 0 at t=0 (lowest)
    @_stChar L.sqV, 26 + 3.3975*7.143, 16.5 - triB*6, '¥'

    # (10) spinning 16-line "bug" (spec measurements).
    # Lines run from r0..r1 inches from the centre of rotation (a hole in the
    # middle). The array spins at 53.17 deg/s; its centre slides up-right then
    # back along the 35.54 deg diagonal through screen centre over ~26.48 s.
    CPI = 7.143 ; RPI = 5.236            # cols/in (ruler: 51 cols=7"), rows/in (=CPI*pxCol/pxRow)
    r0 = 0.2051 ; r1 = 0.4102           # 0.8204" dia (spec), hole of 0.4102" dia
    scx = 26 ; scy = 13.5               # screen centre = centre of the 51x26 grid
    diag = 35.54 * Math.PI/180
    amp = 0.9                           # inches of travel each way -- tune
    s = amp * (1 - 2*Math.abs(2*((t/26.48) % 1) - 1))   # triangle in [-amp, +amp]
    gx = scx + s*Math.cos(diag)*CPI
    gy = scy - s*Math.sin(diag)*RPI
    spinB = t * (53.17 * Math.PI/180)
    for i in [0...16]
      a = spinB + i*(2*Math.PI/16)
      ca = Math.cos(a) ; sa = Math.sin(a)
      @_stLine L.bug + i*ST_VECTOR_WORDS,
        gx + r0*ca*CPI, gy - r0*sa*RPI,
        gx + r1*ca*CPI, gy - r1*sa*RPI

    # (8) ten varying-brightness lines, right-aligned, with a vertical connector.
    # Exact spec lengths (in); longest 3.5" reaches the X (col 23) above STATUS
    # with rightCol 48. The 5 shortest flash; the 5 longest alternate between
    # the two intensities.
    # the DEU has ONE intensity bit, so the ramp is a switch between normal
    # and double intensity
    LEN8 = [0.0068, 0.0137, 0.0273, 0.0547, 0.1094, 0.2188, 0.4375, 0.8750, 1.7500, 3.5000]
    rightCol = 51 ; topRow = 19.5 ; sp8 = 0.45
    flashOn = (Math.floor(t / 0.35) % 2) == 0
    bright = ((1 - Math.cos(2*Math.PI*t/2.33)) / 2) > 0.5   # over ~2.33 s
    # 5 shortest (k 0..4) at full intensity, flashing
    for k in [0...5]
      y = topRow + k*sp8
      if flashOn
        @_stLine L.eight + k*ST_VECTOR_WORDS, rightCol - LEN8[k]*CPI, y, rightCol, y
      else
        @_stLine L.eight + k*ST_VECTOR_WORDS, rightCol, y, rightCol, y   # flashed off
    o8 = L.eight + 5*ST_VECTOR_WORDS
    @bgFCWS[o8] = @fcw.attrMode({intensity: bright})
    for k in [5...10]
      y = topRow + k*sp8
      @_stLine o8 + 1 + (k-5)*ST_VECTOR_WORDS, rightCol - LEN8[k]*CPI, y, rightCol, y
    # back to normal intensity, then the vertical connector
    o8b = o8 + 1 + 5*ST_VECTOR_WORDS
    @bgFCWS[o8b] = @fcw.attrMode({})
    @_stLine o8b + 1, rightCol, topRow, rightCol, topRow + 9*sp8

    @refresh()



#    ITEM ( 1)+4 EXEC  
# ITEM 18 EXEC

#     GPC        2     *   1 34       00:28:40
#     GPC2               * 1          02:34:30                    (01)
#     I/O EROR FF1           12       11:19:00
