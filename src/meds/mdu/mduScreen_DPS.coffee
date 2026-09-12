# import * as fs from 'fs'
fs = window.fs
import * as THREE from 'three'

import {Bus, BusMsg} from './../com/bus.civet.jsx'
import {MDUScreen} from 'meds/mduScreen'
import {FCW, wordsFromBytes} from 'meds/deuFCW'
import * as FCWD from 'meds/deuFCW'
import * as DEU from 'meds/deuProto'
import {SPL, ERR_TEXT, splFCWs, SPL_ROW} from 'meds/deuSPL'
import {SelfTest, FRAME_HZ as SelfTestHz} from 'meds/deuSelfTest'

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
        idpNo: null
        bigX: false
        pollFail: false
        syntaxError: false
      }
    @init()

  data: () ->
    return @curData

  setIDPNo: (idpNo) ->
    @idpNo = idpNo
    @curData.idpNo = idpNo if @curData?
    return if not @group?
    if @geo_idpNo?
      @group.remove @geo_idpNo
      dispose3D(@geo_idpNo)
      @geo_idpNo = null
    if idpNo?
      @geo_idpNo = @d.str(IDP_NO_AT[0], IDP_NO_AT[1], "#{idpNo}", @d.c2h.green, 1.75)
      @group.add @geo_idpNo
    @d.dirty = true

  # 'left', 'right', 'both' or null: the forward keyboards switched to the
  # IDP whose display this is.
  setKybd: (@kybd) ->
    @curData.kybd = @kybd if @curData?
    @group.remove @geo_kybd_left
    @group.remove @geo_kybd_right
    @group.add @geo_kybd_left if @kybd in ['left', 'both']
    @group.add @geo_kybd_right if @kybd in ['right', 'both']
    @d.dirty = true

  # Half a box height down and about four pixels up from the box origin.
  IDP_NO_AT = [24.75, 30.665]

  # The big “X” comes up when no display update data has arrived for three
  # seconds.  POLL FAIL comes up, in the lower right-hand corner, when no
  # poll or time update command has arrived for three seconds.  A powered
  # IDP assigned to no GPC shows both.
  # (USA005350 Rev.B §3.2.15.2 and Figure 3-48; the timers are `mdu.coffee`.)

  # Where the format area sits in the view.
  #
  # A cell boundary at column c draws at world x = c+1 (`penX` below), so the
  # 52-column format area spans 1 to 53.  The view runs 0.20 to 52.442456
  # (`mduVectorDisplay`), a gutter of 0.80 on the left with column 51 0.56
  # past the right-hand clip plane.  Centring the format area in the view
  # leaves 0.121228 either side.
  #
  # The shift is on `@fmt`: the IDP box and the keyboard bars below it line
  # up with the menu area's edgekey boxes, and the menu area does not move.
  FMT_LEFT = 1 ; FMT_COLS = 52
  VIEW_LEFT = 0.20 ; VIEW_WIDTH = 52.242456
  FMT_SHIFT_X = VIEW_LEFT + (VIEW_WIDTH - FMT_COLS) / 2 - FMT_LEFT

  # The character rows are numbered 1 at the top to 26 at the bottom.  Lines
  # 1 and 2 carry the mission and event clocks, 25 the message line, and 26
  # the scratch pad line, which POLL FAIL shares.
  #
  # Three things on the DPS display are orange under MEDS and were green on
  # the MCDS, STS-83-0020V1-34/sect.3.1:
  #
  #   "Fault Message Line 25 - GREEN            Fault Message Line 25 - ORANGE
  #    POLL FAIL portion of Scratch Pad Line 26 POLL FAIL portion of Scratch
  #                                    - GREEN  Pad Line 26 - ORANGE
  #    "Big X" across the entire display        "Big X" across the entire
  #                                    - GREEN  display - ORANGE"
  #
  # All three are drawn by the IDP, and the GPC sends no colour with any of
  # them: the message line carries one FCW1 and its text, and the IDP timers
  # above raise the other two.  Photographs of the hardware show the big X
  # and POLL FAIL red, and they are drawn red here.
  #
  # No document names a palette code for either colour and no display sends
  # one.  The two below are fitted to the requirement above, to the
  # photographs, and to codes flight software leaves alone; `_deuColor`
  # carries their values.
  FAULT_COLOR = 63              # the message line
  FAIL_COLOR = 62               # the big X and POLL FAIL

  # The "X" is drawn on the vector lattice, which is the cell boundary: it
  # runs corner to corner over the whole picture, from the absolute top of
  # the format area (boundary row 0) to the bottom of line 26, and the full
  # width, boundary column 0 to 52.  A character's beam is the middle of its
  # cell and the glyph mesh runs to 1.00 of a cell below the origin, so the
  # bottom of a row of text is 1 - glyphCentre's row offset below it.
  BIG_X_BOTTOM = SPL_ROW + 1 - FCWD.glyphCentre()[1]
  BIG_X = [[0, 0, 52, BIG_X_BOTTOM], [52, 0, 0, BIG_X_BOTTOM]]
  POLL_FAIL_AT = [41, SPL_ROW]

  # The message line buffer runs to the display header, and the colour runs
  # with it: the walk enters at the buffer, draws it under the first word,
  # and takes the pen back at the header.  A display that opens with the
  # five usual setup words would clear FCW3 itself; the GPCIPL menu does
  # not.
  _msgLineColor: () ->
    prologue: [@fcw.colorMode(FAULT_COLOR)]
    epilogue: [@fcw.colorClear()]
    epilogueAt: DEU.ADDR.DISPLAY_HEADER

  _bigXFCWs: () ->
    fcws = [@fcw.colorMode(FAIL_COLOR), @fcw.attrMode({intensity: true})]
    fcws = fcws.concat @fcw.vector(seg...) for seg in BIG_X
    fcws

  _pollFailFCWs: () ->
    [@fcw.colorMode(FAIL_COLOR), @fcw.attrMode({intensity: true})]
      .concat @makeDFB("POLL FAIL", {xy: POLL_FAIL_AT})

  setBigX: (bigX) ->
    @curData.bigX = bigX if @curData?
    return if not @fcw? or not @geo_bigX?
    @geo_bigX = @drawFCWS((if bigX then @_bigXFCWs() else []), @geo_bigX)

  # The scratch pad line is reset as POLL FAIL comes up and again as it goes
  # away, JSC-18820/p.199 sect.4.6.61 "DEU Annunciated Messages":
  # "the DEU will reset the SPL and display POLL FAIL on the  right-hand side 
  # of the SPL", and on the first valid chained time-fill and poll "the POLL FAIL 
  # message will be removed from the display and the DEU will reset the SPL"   
  setPollFail: (fail) ->
    fail = !!fail
    was = !!@curData?.pollFail
    @curData.pollFail = fail if @curData?
    if @spl?
      @spl.pollFail = fail
      if fail != was
        @spl.clear()
        @updateScratchpad() if @geo_scratchpad?
    return if not @fcw? or not @geo_pollFail?
    @geo_pollFail = @drawFCWS((if fail then @_pollFailFCWs() else []),
                              @geo_pollFail)

  setSyntaxError: (err) ->
    @curData.syntaxError = err if @curData?
    if @geo_dps_scratch_err?
      @fmt.remove @geo_dps_scratch_err
      dispose3D(@geo_dps_scratch_err)
      @geo_dps_scratch_err = null
    if err
      @geo_dps_scratch_err = @d.str 48, 27, "ERR", @d.c2h.red
      @fmt.add @geo_dps_scratch_err
    @d.dirty = true


  # The two buffers a format can land in, from the DEU memory allocation
  # (JSC-11174,Vol.1,Rev.D dwg 8.3): 3656 halfwords of format buffer at
  # 0x0100, and 1527 of display buffer at 0x19EE.
  FORMAT_BUFFER_WORDS = 3656
  DISPLAY_BUFFER_WORDS = 1527

  # A fill of the unit's display memory: `words` load at `addr`, and the
  # screen redraws from the refresh entry point afterwards. 
  applyFill: (addr, words) ->
    @fillSeq = (@fillSeq ? 0) + 1
    for w, i in words
      j = (addr + i) & (@bgFCWS.length - 1)
      @bgFCWS[j] = w & 0xffff
      @fillGen[j] = @fillSeq
    @refresh()

  # What the last refresh executed, as address ranges, each with the fill
  # that wrote it and how many fills ago that was.  A range written long
  # before the rest is a leftover the walk should not have reached.
  walkReport: () ->
    log = []
    seen = []
    @drawFCWS(@bgFCWS, new THREE.Object3D(),
              {memory: @bgFCWS, start: @refreshStart ? DEU.ADDR.MESSAGE_LINE,
               vdisp: seen, pcLog: log})
    runs = []
    for a in log
      last = runs[runs.length - 1]
      if last? and a == last.hi + 1 and @fillGen[a] == last.gen
        last.hi = a
      else
        runs.push {lo: a, hi: a, gen: @fillGen[a]}
    now = @fillSeq ? 0
    lines = for r in runs
      age = if r.gen then now - r.gen else '-'
      "  0x#{r.lo.toString(16)}..0x#{r.hi.toString(16)}  " +
      "#{r.hi - r.lo + 1} hw  fill #{r.gen ? 'never'} (#{age} ago)"
    console.log "walk: #{log.length} halfwords, #{runs.length} runs, " +
                "vdisp #{seen.join(',') or 'none'}\n" + lines.join('\n')
    runs

  # Redraw from display memory, following the branch words from the entry
  # point: the message line, or `@refreshStart` when a critical format is
  # standing alone, as the stand-alone self test does.  A display with an
  # external background branches to it from the program the message line
  # holds, and the message line falls through into the display header.
  refresh: () ->
    seen = []
    start = @refreshStart ? DEU.ADDR.MESSAGE_LINE
    opts = {memory: @bgFCWS, start: start, vdisp: seen}
    Object.assign(opts, @_msgLineColor()) if start == DEU.ADDR.MESSAGE_LINE
    @geo_dps_fcws = @drawFCWS(@bgFCWS, @geo_dps_fcws, opts)
    # A resident background is a whole picture, opening with the same five
    # setup words a display's static section does, so it draws in a
    # separate pass.  An unknown code draws nothing.
    words = []
    for code in seen
      bg = @vdispBG?[code]
      if bg? then words = words.concat(Array.from(bg))
      else console.log "DPS: no resident background for VDISP #{code}"
    @geo_dps_vdisp = @drawFCWS(words, @geo_dps_vdisp)

  # Load a bare format control word stream at the refresh entry point: the
  # debug path for a captured display, and what dev mode uses.  A critical
  # format is longer than the display buffer and loads through the format
  # buffer below.
  setBGDFB: (words) ->
    return @setCritFormat(words) if words.length > DISPLAY_BUFFER_WORDS
    @bgFCWS.fill(0)
    @refreshStart = @displayEntry()
    @applyFill(DEU.ADDR.DISPLAY_HEADER, words)

  # Load a critical format into the format buffer, which is
  # 3656 halfwords at 0x0100 (JSC-11174,Vol.1,Rev.D dwg 8.3):
  setCritFormat: (words) ->
    if words.length > FORMAT_BUFFER_WORDS
      console.log "DPS: critical format of #{words.length} halfwords " +
                  "does not fit the format buffer"
    @bgFCWS.fill(0)
    @refreshStart = DEU.ADDR.CRITICAL_FORMAT
    @applyFill(DEU.ADDR.CRITICAL_FORMAT, words)

  # ---------------------------------------------------------------------
  # The DEU beam interpreter.
  #
  # An FCW stream is a program for a stroke-writing beam.  Mode-register
  # writes latch drawing state, position words move the beam, a glyph word
  # draws one or two characters and advances the beam by the MAJOR step,
  # and a carriage return sends it back to the start of the line and on by
  # the MINOR step.  A vector is a run of six words: enter vector mode,
  # position, a slope word, an extent word, and a mode word to leave.  A
  # circle is one word inside the same mode bracket, and a land-site label
  # is a pair of words holding three characters.
  #
  # A section ends at the end-of-refresh bit in an FCW2, or at a BRANCH with
  # nowhere left to go
  #
  # ---------------------------------------------------------------------
  MAX_FCW_STEPS = 40000     # a runaway branch loop must not hang the frame

  drawFCWS: (fcws, targetGroup, opts = {}) ->
    @fmt.remove targetGroup
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
    blink = dash = false
    fcw1Bright = fcw3Bright = false                       # both mean bright
    large = false ; angle = 0
    angleStep = 0                                         # radians per glyph
    incrOn = false                                        # op 5 writes angleStep
    vecRotate = false                                     # vectors turn with
                                                          # the character angle
    altchar = false                                       # alternate glyph set
    colorCode = null                                      # null = the DEU default
    slope = null
    lsiteHi = null                                        # first op 6 word
    repeatCount = 0
    # The 4K sector a branch word's 12-bit address is taken in.  An op-1
    # word is 0001aaaaaaaaaaaa: the 0x1000 bit is the OPCODE, not address
    # bit 12, so twelve bits is all it carries and everything it can name
    # is in the sector the interpreter is already running in.  An op-2
    # word changes that (below), which is how a display list in the upper
    # 4K reaches the format buffer at 0x0100.
    sector = (opts.start ? DEU.ADDR.DISPLAY_HEADER) & 0x1000

    # A glyph is drawn at the beam, in the character-cell coordinates the rest
    # of the display is laid out in.  The +1 on each axis is the DPS format
    # area origin.  The position words below fold in the reference
    # registers; they are not added here.
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

    # The pen.  A selected palette code is drawn as it is.  Otherwise the
    # DEU's monochrome intensity levels are MEDS colours, per
    # STS-83-0020V1-34/sect.3.1's table of MCDS items and their MEDS
    # replacements:
    #
    #   Overbright text (2X intensity) - BRIGHT GREEN      ... - YELLOW
    #   Overbright/Overwrite text (4X intensity)
    #                            - BRIGHTEST GREEN          ... - YELLOW
    #   Overwrite text (2X intensity) - BRIGHT GREEN       ... - GREEN
    #
    # Double intensity arrives as either FCW1 bit 3 or FCW3 bit 6, and
    # draws default yellow whether the default green is implied or selected
    # outright.  Overwrite is a glyph written twice at the same beam; a
    # glyph carries no intensity, so the second write changes nothing.
    penColor = () =>
      bright = fcw1Bright or fcw3Bright
      if bright and (colorCode ? DEU_DEFAULT_GREEN) == DEU_DEFAULT_GREEN
        return @_deuColor(DEU_DEFAULT_YELLOW)
      return @_deuColor(colorCode) if colorCode?
      @d.c2h.green
    penIntensity = () -> if fcw1Bright or fcw3Bright then 1.0 else 0.72

    # Rotate a beam-space delta by the character angle.  `angle` runs
    # opposite to the beam's Y, so a quarter turn advances up the screen.
    rot = (dx, dy) ->
      return [dx, dy] if not angle
      cs = Math.cos(angle) ; sn = Math.sin(angle)
      [dx * cs + dy * sn, -dx * sn + dy * cs]

    advance = () ->
      [dx, dy] = if axisY then rot(0, majorStep) else rot(majorStep, 0)
      beamX += dx ; beamY += dy
      angle += angleStep if angleStep       # letters a string around an arc

    carriageReturn = () ->
      if axisY
        beamY = homeY ; beamX += minorStep
      else
        beamX = homeX ; beamY += minorStep

    # The shaded landing-site symbols of the alternate character set, drawn
    # solid about the beam a character cell across.  `deuFCW.ALTCHARSET`
    # carries the shapes and the symbol numbers.  A symbol with no geometry
    # here returns false and draws its `DEUCharset` counterpart.
    ALT_RADIUS = FCWD.COL_PITCH / 2
    ALT_CIRCLE_SIDES = 24
    drawAltSymbol = (g) =>
      cx = penX() ; cy = penY()
      rx = ALT_RADIUS / FCWD.COL_PITCH ; ry = ALT_RADIUS / FCWD.ROW_PITCH
      switch g
        when 0x14
          n = ALT_CIRCLE_SIDES
          add @d.filledPoly (for i in [0...n]
            a = 2 * Math.PI * i / n
            [cx + rx * Math.cos(a), cy - ry * Math.sin(a)]), penColor()
        when 0x15
          add @d.filledPoly [[cx, cy - ry], [cx + rx, cy],
                             [cx, cy + ry], [cx - rx, cy]], penColor()
        else
          return false
      trace? 'ALTSYM', "symbol #{g.toString(16)}"
      true

    drawGlyph = (g) =>
      switch g
        when 0x0d                      # carriage return
          carriageReturn()
        when 0x08                      # backspace: undo one advance
          if axisY then beamY -= majorStep else beamX -= majorStep
        when 0x03
          null
          # SELF TEST, one of the four command codes in
          # USA-003090/Table 8-2.  It commands the symbol generator;
          # nothing reaches the screen and the beam does not advance.
        when 0x00
          null
          # The empty half of a single-glyph word draws nothing and does not
          # advance.  A display packs two glyphs to a word and puts an odd
          # trailing one in the LOW half with zero above it, so a zero that
          # advanced the beam would push every odd-length label one column
          # right of where its deck put it.
        else
          if not (altchar and drawAltSymbol(g))
            ch = @fcw.DEUCharset[g]
            if ch? and ch != ' '
              trace? 'GLYPH', "'#{ch}'#{if altchar then ' ALTCHAR' else ''}"
              # The beam is the middle of the character cell; the character
              # generator draws from the cell's corner.  See `glyphCentre`.
              sc = if large then FCWD.COL_PITCH_L / FCWD.COL_PITCH else 1.0
              [gx, gy] = FCWD.glyphCentre(sc)
              add @d.str penX() - gx, penY() - gy, ch, penColor(), sc,
                1.0, 1.0, @d.deuFont, angle, false
          advance()

    # Radius in beam units about the beam, which the circle does not move.
    # Beam units are square, so in character cells this is an ellipse.
    drawCircle = (r) =>
      return if not (r > 0)
      cx = penX() ; cy = penY()
      n = Math.max(24, Math.min(96, Math.round(2 * r)))
      pts = ([cx + r * Math.cos(2 * Math.PI * i / n) / FCWD.COL_PITCH,
              cy - r * Math.sin(2 * Math.PI * i / n) / FCWD.ROW_PITCH] \
             for i in [0..n])
      trace? 'CIRCLE', "r #{r} at #{cx.toFixed(2)},#{cy.toFixed(2)}"
      if dash
        add @d.dashedLine pts, penColor()
      else
        add @d.line pts, penColor(), penIntensity()

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
      [dx, dy] = rot(dx, dy) if vecRotate
      x0 = penX() ; y0 = penY()
      trace? 'VECTOR', "d #{dx},#{dy} major=#{major} minor=#{minor} " +
                       "yMajor=#{a.yMajor} signDiffer=#{a.signDiffer} slope=#{a.slope}"
      beamX += dx ; beamY += dy
      seg = [[x0, y0], [penX(), penY()]]
      if dash
        add @d.dashedLine seg, penColor()
      else
        add @d.line seg, penColor(), penIntensity()

    # A BRANCH moves the program counter, so the walk is by index, and `done`
    # ends it: CoffeeScript's `break` inside a `switch` leaves the switch.
    src = opts.memory ? fcws
    pc = opts.start ? 0
    visited = {}
    splice = null                 # the SUBLIST frame: {left, ret}
    done = false
    steps = 0
    # `opts.prologue` goes through the switch ahead of the first word in
    # memory, writing the mode registers the walk draws under; `opts.epilogue`
    # goes through it once the walk reaches `opts.epilogueAt`.
    injected = (opts.prologue ? []).slice()
    epilogue = (opts.epilogue ? []).slice()
    epilogueAt = opts.epilogueAt
    while not done and pc >= 0 and pc < src.length and steps < MAX_FCW_STEPS
      steps++
      # A spliced run carries no terminator and ends when its word count
      # runs out, so the return is checked before the fetch.
      if splice? and splice.left <= 0
        pc = splice.ret
        splice = null
        continue
      if injected.length > 0
        word = injected.shift()
      else if epilogueAt? and pc >= epilogueAt
        injected = epilogue
        epilogueAt = null
        continue
      else
        opts.pcLog?.push pc
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
          tgt = sector | (v.addr12 & 0xfff)
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
          # to take, so the spliced run goes through this same switch and
          # draws with the registers the static text left set.
          #
          # One frame deep: a nested sublist word is stepped over.
          #
          # A count of zero is a sector-qualified jump, the only way to
          # leave the display buffer.  A
          # branch word carries 13 bits, so a display list in the upper 4K
          # cannot name the format buffer at 0x0100; the sector field says
          # which 4K the target is in and the branch word supplies the rest.
          # That pair is what selects a resident critical format -- a
          # display's DEULOC= is the address of its slot in the table at
          # 0x0100, and dfg emits exactly `[0x2000, Branch(DEULOC)]` for it.
          nxt = @fcw.decodeFCW(src[pc])
          if splice?
            if nxt?.nm == 'BRANCH'
              pc++
              splice.left--             # the skipped word is still one of ours
          else if nxt?.nm == 'BRANCH' and v.count > 0
            splice = {left: v.count, ret: pc + 1}
            pc = ((v.sector << 12) & 0x1000) | (nxt.v.addr12 & 0xfff)
          else if nxt?.nm == 'BRANCH'
            sector = (v.sector << 12) & 0x1000
            tgt = sector | (nxt.v.addr12 & 0xfff)
            if not visited[tgt]
              visited[tgt] = true
              pc = tgt
            else
              done = true
        when 'FCW1'
          dash = v.dash == 1
          blink = v.blink == 1
          fcw1Bright = v.intensity == 1
          axisY = v.axisY == 1
        when 'FCW2'
          # AC5+AC4 gate the X/Y reference registers: while they are clear
          # the registers are held but not applied.
          xyRef = v.xyRef == 3
          incrOn = v.incr == 1
          angleStep = 0 if not incrOn
          if v.eor == 1
            done = true                 # end of refresh
          else
            switch v.mode & 0x3
              when FCWD.GEN.VECTOR
                vecRotate = (v.mode & FCWD.UPRIGHT) == 0
              when FCWD.GEN.CHAR_SMALL, FCWD.GEN.CHAR_LARGE
                large = (v.mode & 0x3) == FCWD.GEN.CHAR_LARGE
                altchar = v.polarX == 1     # where ALTCHAR is encoded
                # the upright bit is cleared while a rotation is in force
                angle = 0 if (v.mode & FCWD.UPRIGHT) != 0
        when 'FCW3'
          colorCode = if v.select == 1 then v.color else null
          fcw3Bright = v.intensity == 1
        when 'ROT'
          angle = -2 * Math.PI * v.angle / 4096
        when 'MAJINC'
          if incrOn
            # 12 unsigned bits of 360/32768 degrees, not MAJINC's signed
            # 11, so the field is read from the word.
            angleStep = -2 * Math.PI * (desc.word & 0x0fff) / 32768
          else
            majorStep = v.step
        when 'MININC', 'SPTYPE'
          minorStep = v.step
        when 'XPOS', 'YPOS'
          # A position word starts a new block: it sets and homes the
          # axis it names and returns the beam to home on the other.  Either
          # half shows only where a coordinate word stands alone -- an
          # X,Y pair leaves the same state either way -- and each was
          # measured on such a case.  X alone: the GPC IPL MENU's second
          # column is a lone XPOS after eight carriage returns have taken
          # the first down to BFS4, and PASS5 draws back on PASS1's row.
          # Y alone: SPEC 60 writes its 50-character underscore
          # row from a bare YC=9 five characters after CHAR=(PARAM); from
          # the block's XC=2 home it fills columns 2-51 exactly, and five
          # right of that it runs off the screen.  1041 of the display
          # decks' 3246 YC directives carry no XC.
          #
          # The X/Y reference registers (XTRN/YTRN) are held: every position
          # word on the axis draws at reference + coordinate for as long as
          # FCW2's AC5+AC4 gate is set.
          if v.translate == 1
            if desc.nm == 'XPOS' then tx = FCWD.beamFold(v.x)
            else                      ty = FCWD.beamFold(v.y)
          else if desc.nm == 'XPOS'
            beamX = (FCWD.beamFold(v.x) + (if xyRef then tx else 0)) %% FCWD.SCREEN_WRAP
            homeX = beamX ; beamY = homeY
          else
            beamY = (FCWD.beamFold(v.y) + (if xyRef then ty else 0)) %% FCWD.SCREEN_WRAP
            homeY = beamY ; beamX = homeX
        when 'CIRCLE'
          drawCircle(v.radius)
        when 'LSITE1'
          lsiteHi = word                # drawn when the pair completes
        when 'LSITE2'
          if lsiteHi?
            drawGlyph(@fcw.toGlyph(c)) for c in @fcw.lsiteText(lsiteHi, word)
            lsiteHi = null
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
        when 'VDISP'
          # A background the display unit holds, named by number: the
          # GPC's whole static section for such a display is this one
          # word.  The walk is over one word list and a resident
          # background is another, so this collects the number and
          # `refresh` draws it.  See `loadVdispBackgrounds`.
          opts.vdisp?.push v.vdisp

    @fmt.add targetGroup
    @d.dirty = true

    return targetGroup


  # "The flash rate for characters is 1 Hz with 5/8 sec 'on' time and 3/8
  # second 'off' time".  The IDP beats eight times a second, so a phase is
  # five beats lit and three dark.  There is no timer here: the beat
  # drives it, so a display with a dead port stops flashing.  See
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
  # MG070100A1012E2, the MEDS IDP Software Requirements Specification,
  # defines the 64-entry table, but we don't currently have that doc.
  #
  # Only three "MEDS enhanced" displays--all added or modified in
  # OI33--use the color feature.  Thirteen color numbers are used and
  # STS-83-0020V1-34 names the colour of ten of them, in the prose 
  # description of the display that sends each:
  #
  #   sect.3 field 47  "default green (color 40)", "default yellow
  #                     (color 54)"
  #   sect.4.2.1.1     alternate landing site 1 "in white", site 2 "in
  #                    cyan"; sect.4.2.1.4 item N gives those as 29 and 47
  #   sect.4.2.41 (5)  the target insertion line "in default yellow in both
  #                    the main plot and inset window", 7 and 56
  #   sect.4.2.41 (6)  the launch window lines "in default green", sent as
  #                    COLOR=DEU -- select clear, which is code 40
  #   sect.4.2.42 (2)  the selected runway line and its labels "in yellow",
  #                    21; the delaz line "in yellow", 7; the roll reversal
  #                    lines "in green", 4
  #   sect.4.2.42 (3)  alternate site 1 "in white", 31; site 2 "in cyan", 48
  #   sect.4.2.42 (4)  the IIP "as a white cross", 31
  #   sect.4.2.42 (5)  the range rings "in green", 4
  #   sect.4.2.42 (7)  the alternate site E/W scales "in green", 19
  #
  # 33 and 43 are the inset-window counterparts of 29 and 40 (sect.4.2.41
  # E and K).  The one main/inset pair whose colour is named, 7 and 56, is
  # one colour across both, and they are read the same way here.
  #
  # A code outside the table is read as two bits a channel, bits 5-4 red,
  # 3-2 green, 1-0 blue, fitted to nothing.  The colour values are in `c2h`.
  DEU_DEFAULT_GREEN = 40
  DEU_DEFAULT_YELLOW = 54

  DEU_NAMED_COLORS =
    4:  0x48f500    # green
    7:  0xfff600    # default yellow
    19: 0x48f500    # green
    21: 0xfff600    # yellow
    29: 0xffffff    # white
    31: 0xffffff    # white
    33: 0xffffff    # ... its inset window
    40: 0x48f500    # default green, and what a clear select bit draws
    43: 0x48f500    # ... its inset window
    47: 0x2dfada    # cyan
    48: 0x2dfada    # cyan
    54: 0xfff600    # default yellow
    56: 0xfff600    # default yellow
    62: 0xff0000    # red -- `FAIL_COLOR`, not a flight code
    63: 0xff1400    # near red -- `FAULT_COLOR`, not a flight code

  _deuColor: (code) ->
    return DEU_NAMED_COLORS[code] if DEU_NAMED_COLORS[code]?
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

    @fmt = new THREE.Object3D()
    @fmt.position.x = FMT_SHIFT_X
    @group.add @fmt

    @geo_idpNo = null
    @setIDPNo(@data().idpNo)
    @geo_idpBox = @d.box 24.60,30.265 ,28.40,32.915
    @group.add @geo_idpBox


    # kybd-active bar: 2px-tall filled quad, 1/4 up from the GPC box bottom,
    # ending just clear of the box sides (box x 24.60..28.40, y ..32.915)
    kbY = 32.25
    @geo_kybd_right = @d.box 28.45, kbY-0.053, 41.40, kbY+0.053, null, @d.c2h.yellow
    @geo_kybd_left = @d.box 12, kbY-0.053, 24.55, kbY+0.053, null, @d.c2h.red
    @setKybd @data().kybd

    @geo_dps_time = new THREE.Object3D()
    @fmt.add @geo_dps_time

    @geo_dps_vdisp = new THREE.Object3D()
    @fmt.add @geo_dps_vdisp

    @geo_scratchpad = new THREE.Object3D()
    @fmt.add @geo_scratchpad

    @geo_bigX = new THREE.Object3D()
    @fmt.add @geo_bigX

    @geo_pollFail = new THREE.Object3D()
    @fmt.add @geo_pollFail

    # fresh group: stale refs from a previous build must not be removed from it
    @geo_dps_scratch_err = null
    @setBigX @data().bigX
    @setPollFail @data().pollFail
    @setSyntaxError @data().syntaxError

    y=2
    @geo_dps_fcws = new THREE.Object3D()
    @fmt.add @geo_dps_fcws

    @_blinkOn ?= true

    # dev mode: preload the DEU self-test critical format locally.
    # Otherwise the display stays blank until an IDP delivers a
    # background DFB over the bus.
    @dispCritFormat(0) if @d.CONFIG.dev


  # the header clock
  #
  # The GPC ships seconds (two 48-bit extended floats and a conversion word,
  # `DEU.parseTimeFill`) and the display converts, so the DDD/HH:MM:SS is
  # drawn here and never reaches DEU display memory.
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
    fcws = @makeDFB(@_clockText(missionSecs), {xy: [39, 1]})
             .concat(@makeDFB(@_clockText(eventSecs), {xy: [39, 2]}))
    @geo_dps_time = @drawFCWS(fcws, @geo_dps_time)

  # Text at a character cell -> the FCWs that draw it: a position run, then
  # glyph pairs.
  makeDFB: (s, opt = {}) ->
    dfb = if opt?.xy? then @fcw.positionRun(opt.xy[0], opt.xy[1]) else []
    dfb.concat(@fcw.chars(s))

  # SPL: the scratch pad line
  #
  # The rules live in `meds/deuSPL`
  # With `--dcp` the IDP's control program composes the line into the message
  # line buffer at 0x19BC and the beam draws it out of display memory like
  # everything else, so this side channel stands down; see meds/deuDCP.
  splIsLocal: () -> not @d.CONFIG?.dcp

  # Where a refresh starts, as the DEU's symbol generator was told.  A
  # critical format overrides it: that draws the whole screen and the
  # message line is not part of it.
  setRefreshStart: (addr) ->
    @deuRefreshStart = addr
    # A critical format stands alone and the message line is not part of
    # it; the entry point is remembered and taken up again when the format
    # comes down.
    return if @refreshStart == DEU.ADDR.CRITICAL_FORMAT
    return if @refreshStart == addr
    @refreshStart = addr
    @refresh()
    @d.dirty = true

  # Where a normal display refresh starts: whatever the DEU's control
  # program last asked for, and the display header if it never has.
  displayEntry: () -> @deuRefreshStart ? DEU.ADDR.MESSAGE_LINE

  updateScratchpad: () ->
    if not @splIsLocal()
      @geo_scratchpad = @drawFCWS([], @geo_scratchpad)
      return
    @spl ?= new SPL(pollFail: @data().pollFail)
    # The command initiator flashes until the command is complete, and so
    # does ERR.  `splFCWs` is the words that draw it; the rules and the
    # composition both live in meds/deuSPL.
    @geo_scratchpad = @drawFCWS(splFCWs(@spl, @fcw), @geo_scratchpad)
    @d.dirty = true

  recvKey: (k) ->
    return if not @splIsLocal()
    @spl ?= new SPL(pollFail: @data().pollFail)
    @spl.press k.gpcCode
    @updateScratchpad()

  init: () ->  
    @fcw = new FCW()
    @bgFCWS = new Uint16Array(DEU.DEU_MEMORY_WORDS)
    # which fill last wrote each halfword; `walkReport` reads it
    @fillGen = new Uint32Array(DEU.DEU_MEMORY_WORDS)
    @fillSeq = 0

    @loadCritFormats()
    @loadVdispBackgrounds()

    @spl = new SPL(pollFail: @data().pollFail)
    @syntaxError = false


  loadCritFormats: () ->
    @critFormats = {}
    pth=@d.CONFIG.NSTS_TOP+'data/'
    @critFormats[0] = @loadBGDFBFile pth+'0000-DEU_STAND_ALONE_SELF_TEST.dfb'

  loadVdispBackgrounds: () ->
    # searches data/VDISP-nnn-*.dfb for virtual displays loadable by VDISP
    # nnn is the number used in the VDISP FCW.
    @vdispBG = {}
    pth = @d.CONFIG.NSTS_TOP + 'data/'
    for f in fs.readdirSync(pth)
      m = /^VDISP-(\d+)-.*\.dfb$/i.exec f
      continue if not m?
      @vdispBG[Number(m[1])] = @loadBGDFBFile(pth + f)

  dispCritFormat: (fmtNum) ->
    @setCritFormat(@critFormats[0])

  loadBGDFBFile: (path) -> wordsFromBytes fs.readFileSync(path)

  _dfbList: () ->
    pth = @d.CONFIG.NSTS_TOP + 'data/'
    if not @_dfbFiles?
      @_dfbFiles = (f for f in fs.readdirSync(pth) \
                    when /\.dfb$/i.test(f) and not /^VDISP-/i.test(f)).sort()
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
  # The DEU stand-alone self test.
  #
  # Built from its specification: see
  # `meds/deuSelfTest`, which turns STS-83-0020V2-34/sect.4.6.8 and its
  # Figure 4.6.8-1 into format control words.  The static half loads into the
  # format buffer, where a critical format belongs, and its trailing branch
  # carries the beam into the display buffer, where the animated half is
  # rewritten once a refresh frame.
  #
  # The frame number comes from elapsed time at the symbol generator's 55 Hz,
  # so every animated quantity is an integer count of frames however the
  # host's timer fires.
  # ---------------------------------------------------------------------------
  ST_TICK_MS = 18                        # about one refresh frame

  enterSelfTest: () ->
    return if @selfTestOn
    @_st ?= new SelfTest(@fcw)
    st = @_st.staticWords()
    @setCritFormat(st.concat([@fcw.branch(DEU.ADDR.DISPLAY_HEADER)]))
    @selfTestOn = true
    @_stFrame0 = Date.now()
    @tickSelfTest()
    @_stTimer = window.setInterval((=> @tickSelfTest()), ST_TICK_MS)
    console.log "DEU self test ON (#{st.length} halfwords of format)"

  exitSelfTest: () ->
    return if not @selfTestOn
    window.clearInterval(@_stTimer) if @_stTimer?
    @_stTimer = null
    @selfTestOn = false
    @setBGDFB(@critFormats[0])
    console.log "DEU self test OFF"

  toggleSelfTest: () ->
    if @selfTestOn then @exitSelfTest() else @enterSelfTest()

  selfTestFrame: () ->
    Math.floor((Date.now() - @_stFrame0) * SelfTestHz / 1000)

  tickSelfTest: () ->
    return if not @selfTestOn
    n = @selfTestFrame()
    return if n == @_stLastFrame
    @_stLastFrame = n
    w = @_st.frameWords(n)
    @bgFCWS[(DEU.ADDR.DISPLAY_HEADER + i) & (@bgFCWS.length - 1)] = x & 0xffff \
      for x, i in w
    @refresh()



#    ITEM ( 1)+4 EXEC  
# ITEM 18 EXEC

#     GPC        2     *   1 34       00:28:40
#     GPC2               * 1          02:34:30                    (01)
#     I/O EROR FF1           12       11:19:00
