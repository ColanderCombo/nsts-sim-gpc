# import * as fs from 'fs'
fs = window.fs
import * as THREE from 'three'

import {Bus, BusMsg} from './../com/bus.civet.jsx'
import {MDUScreen} from 'meds/mduScreen'
import {FCW} from 'meds/deuFCW'
import {KYBD} from 'meds/kybd'

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
        bg: []
        queuedKeys: []
        cmdComplete: true
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

  setPollFail: (fail) ->
    @curData.pollFail = fail if @curData?
    if @geo_bigRedX?
      @group.remove @geo_bigRedX
      dispose3D(@geo_bigRedX)
      @geo_bigRedX = null
    if @geo_pollFail?
      @group.remove @geo_pollFail
      dispose3D(@geo_pollFail)
      @geo_pollFail = null
    if fail
      @geo_bigRedX = new THREE.Object3D()
      @geo_bigRedX.add @d.line([[0,2],[53,28]], @d.c2h.red)
      @geo_bigRedX.add @d.line([[53,2],[0,28]], @d.c2h.red)
      @geo_pollFail = @d.str 42, 27, "POLL FAIL", @d.c2h.red
      @group.add @geo_bigRedX
      @group.add @geo_pollFail
    @d.dirty = true

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
  
  setBGDFB: (msg) ->
    @bgFCWS.fill(0)   # clear stale FCWs so a shorter format doesn't leave leftovers
    for i in [1..msg.data16.length]
      @bgFCWS[i-1] = msg.data16[i]

    # capture the new group drawFCWS returns, else the old one is never removed
    # and successive backgrounds accumulate on top of each other
    @geo_dps_fcws = @drawFCWS(@bgFCWS,@geo_dps_fcws)

  setTime: (msg) ->
    for i in [1...msg.data16.length]
      @timeFCWS[i-1] = msg.data16[i]

    @geo_dps_time = @drawFCWS(@timeFCWS,@geo_dps_time)
    @d.dirty = true

  drawFCWS: (fcws, targetGroup) ->
    @group.remove targetGroup
    dispose3D(targetGroup)
    targetGroup = new THREE.Object3D()

    blinkOn = false
    lineDashOn = false
    intensity = 1.0
    charScale = 1.0
    charRot = 0
    charCentered = false
    scaleFactors = [1.0, 0.654, 0.785, 0.5, 1.25, 1.5, 0.75, 1.0]  # CHARXF scale index (7 = full+centred)
    xc = yc = 0
    theta = 0

    for fcw in fcws
      if fcw == 0x0
        break
 
      if lineDashOn
        color = @d.c2h.green      # DASH
        if blinkOn and overbrightOn
          color = @d.c2h.yellow   # DASH, BLINK
        else if blinkOn and not overbrightOn
          color = @d.c2h.green   # DASH BLINK
        else if not blinkOn and overbrightOn
          color = @d.c2h.yellow # DASH
      else
        color = @d.c2h.green
        if blinkOn and overbrightOn
          color = @d.c2h.yellow # BLINK
        else if blinkOn and not overbrightOn
          color = @d
          .c2h.green # BLINK
        else if not blinkOn and overbrightOn
          color = @d.c2h.yellow


      desc = @fcw.decodeFCW(fcw)
      switch desc.nm
        when 'POSTX'
          xc = desc.v.x
          yc = desc.v.y
        when 'POSX'
          xc = (desc.v.x/511)*53
        when 'POSY'
          yc = (desc.v.y/511)*26
        when 'CHARXF'
          charRot = (desc.v.rot/512)*2*Math.PI
          charScale = scaleFactors[desc.v.scale] ? 1.0
          # scale 0 + rot 0 is the "reset" word (corner origin); anything else centres
          charCentered = (desc.v.scale != 0 or desc.v.rot != 0)
        when 'CHAR1'
          targetGroup.add @d.str xc+1,yc+1, desc.v.char, color, charScale, 1.0, 1.0, @d.deuFont, charRot, charCentered
          xc++
        when 'CHAR2'
          targetGroup.add @d.str xc+1,yc+1, desc.v.char1, color, charScale, 1.0, 1.0, @d.deuFont, charRot, charCentered
          xc++
          targetGroup.add @d.str xc+1,yc+1, desc.v.char2, color, charScale, 1.0, 1.0, @d.deuFont, charRot, charCentered
          xc++
        when 'FEAT'
          lineDashOn = (desc.v.lineDash==1)
          blinkOn = (desc.v.blink==1)
          overbrightOn = (desc.v.overbright==1)
          # intensity field 0 = full/default; 1..511 = graded brightness
          intensity = if desc.v.intensity == 0 then 1.0 else desc.v.intensity/511
        when 'THETA'
          theta = desc.v.r
        when 'LENGT'
          # Reconstruct the segment from THETA (direction) + LENGT (longer-axis
          # magnitude). Use cos/sin directly so all four quadrants are correct;
          # the old quadrant-by-theta sign fixups mishandled down-left vectors,
          # which matters once elements sweep a full circle (self-test animation).
          angle = 2*Math.PI*(theta/512)
          mag = desc.v.length/512
          if desc.v.yLonger
            r = mag / Math.abs(Math.sin(angle))
          else
            r = mag / Math.abs(Math.cos(angle))
          dx = r * Math.cos(angle) * 53
          dy = r * Math.sin(angle) * 26

          seg = [[1+xc,1+yc],[1+xc+dx,1+yc+dy]]
          if lineDashOn
            targetGroup.add @d.dashedLine seg, color
          else
            targetGroup.add @d.line seg, color, intensity
          xc = xc+dx
          yc = yc+dy
        when 'CIRC'
          radius = (desc.v.radius/512)
          coords = []
          for i in [0..512]
            angle = (i/512)*2*Math.PI
            x = xc+1 + (Math.cos(angle)*radius*53)
            y = yc+1 + (Math.sin(angle)*radius*38.87)   # 53*(pxCol/pxRow) -> round circles
            coords.push [x,y]
          if lineDashOn
            targetGroup.add @d.dashedLine coords, color
          else
            targetGroup.add @d.line coords, color

    @group.add targetGroup
    @d.dirty = true

    return targetGroup

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

    # fresh group: stale refs from a previous build must not be removed from it
    @geo_bigRedX = null
    @geo_pollFail = null
    @geo_dps_scratch_err = null
    @setPollFail @data().pollFail
    @setSyntaxError @data().syntaxError

    y=2
    @geo_dps_fcws = new THREE.Object3D()
    @group.add @geo_dps_fcws

    # dev mode: preload the DEU self-test critical format locally.
    # Otherwise the display stays blank until an IDP delivers a
    # background DFB over the bus.
    @dispCritFormat(0) if @d.CONFIG.dev


  makeDFB: (s,opt={}) ->
    dfb = []
    curFCW = {}

    if opt? and opt.xy?
      dfb.push @fcw.encodeFCW {nm:'POSTX', x:opt.xy[0], y:opt.xy[1]}
    for x in s
      if curFCW.nm == 'CHAR1'
        curFCW = {nm:'CHAR2', char1:@fcw.DEUCharset[curFCW.char], char2:x}
        dfb.pop()
        dfb.push @fcw.encodeFCW curFCW
      else
        curFCW = {nm:'CHAR1', char:x, blink:0, intensity:0}
        dfb.push @fcw.encodeFCW curFCW
    # dfb.push 0
    return dfb

  parseKeys: () ->
    lastKey =  @queued_keys[@queued_keys.length-1]
    return if not lastKey?
    if lastKey.ascii == 'CLEAR'
      @queued_keys.pop()
      if @queued_keys
        @queued_keys.pop()
    if lastKey.ascii in ['ACK', 'MSG RESET', 'SYS SUMM', 'FAULT SUMM', 'RESUME']
      @cmdComplete = true
      # return

    # switch @parseState
    #   when 'EMPTY'
    #     if lastKey.ascii not in ['OPS', 'SPEC', 'DISP', 'ITEM']
    # @cmd_complete = false

  updateScratchpad: () ->
    @FCW_BLINK_ON = @fcw.encodeFCW({nm:'FEAT', blink:1})
    @FCW_BLINK_OFF = @fcw.encodeFCW({nm:'FEAT', blink:0})
    @FCW_SPACE = @fcw.encodeFCW({nm:'CHAR1', char:' '})

    @parseKeys()

    # NB: an EMPTY key queue still redraws (erasing the line, e.g. on
    # RESET SPL); only bail when there's no queue at all
    if not @queued_keys?
      return

    txt_scratchpad = ""
    
    cmdIncomplete = false
    firstKey = @queued_keys[0]
    lastKey = @queued_keys.slice(-1)?[0]
    cmdInitiators = [KYBD.DEUKey.keys.ITEM, KYBD.DEUKey.keys.OPS, KYBD.DEUKey.keys.SPEC]
    cmdExec = [KYBD.DEUKey.keys.EXEC, KYBD.DEUKey.keys.PRO]
    if firstKey in cmdInitiators  and lastKey not in cmdExec
      cmdIncomplete = true

    scratchFCWS = []
    scratchFCWS.push @fcw.encodeFCW {nm:'POSTX', x:1, y:27}
    if cmdIncomplete
      scratchFCWS.push @FCW_BLINK_ON
    if @queued_keys[0]
      scratchFCWS = scratchFCWS.concat @makeDFB " #{@queued_keys[0].ascii } "
    if cmdIncomplete
      scratchFCWS.push @FCW_BLINK_OFF
    # scratchFCWS = scratchFCWS.concat @makeDFB    

    for key in @queued_keys.slice(1)
      #console.log key
      txt_scratchpad+="#{key.ascii}"
    scratchFCWS = scratchFCWS.concat(@makeDFB(txt_scratchpad))
    # console.log scratchFCWS
    @geo_scratchpad = @drawFCWS(scratchFCWS,@geo_scratchpad)
    # return

    # (syntax-error ERR annunciation is managed by setSyntaxError)
    @d.dirty = true

  recvKey: (k) ->
    if @cmdComplete
      @queued_keys = []
      @cmdComplete = false
    @queued_keys.push k
    @updateScratchpad()

  init: () ->  
    @fcw = new FCW()
    @bgFCWS = new Uint16Array(1536)
    @timeFCWS = new Uint16Array(100)
    @fgFCWS = new Uint16Array(2000)

    @loadCritFormats()

    @queued_keys = []
    @cmdComplete = true
    @syntaxError = false
    @parseState = "EMPTY"


  loadCritFormats: () ->
    @critFormats = {}
    pth=@d.CONFIG.NSTS_TOP+'data/'
    bgDFB = fs.readFileSync pth+'0000-DEU_STAND_ALONE_SELF_TEST.dfb'
    #bgDFB = fs.readFileSync pth+'TEST-1041-OMS_1_MNVR_EXEC.dfb'
    # bgDFB = fs.readFileSync pth+'TEST-9011-GPC_MEMORY.dfb'
    # bgDFB = fs.readFileSync pth+'TEST-9011-100-GTS_DISPLAY.dfb'
    dfbMsg = new BusMsg(1+bgDFB.length)
    dfbMsg.data16[0] = 0xff00
    for c,i in bgDFB
      dfbMsg.data8[i+2] = c
    @critFormats[0] = dfbMsg

  dispCritFormat: (fmtNum) ->
    @setBGDFB(@critFormats[0])

  # Debug helper: load a .dfb file from disk into a background-format BusMsg
  loadBGDFBFile: (path) ->
    bgDFB = fs.readFileSync path
    dfbMsg = new BusMsg(1+bgDFB.length)
    dfbMsg.data16[0] = 0xff00
    for c,i in bgDFB
      dfbMsg.data8[i+2] = c
    return dfbMsg

  # debug helpers for the parameter editor's test controls
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
  # Loads the static 0000 self-test dfb, appends animated elements after the
  # buffer's zero-terminator, and rewrites their FCWs on a timer to animate
  # the elements the real DEU updated live (boxed vectors, revolving letters,
  # the two travelling squares, and the spinning "bug").
  # POSY is always clamped >= 1: POSY at y=0 encodes to 0x0000, which drawFCWS
  # treats as the end-of-buffer terminator.
  # ---------------------------------------------------------------------------

  _stXY: (idx, cx, cy) ->
    # POSY uses (cy+1) to match the converter's GRIDLINES/RECT/FOCUS convention
    # so animated elements sit on the same row-grid as the diagonals/focus/box.
    @bgFCWS[idx]   = @fcw.encodeFCW {nm:'POSX', x: Math.round((cx/53)*511)}
    @bgFCWS[idx+1] = @fcw.encodeFCW {nm:'POSY', y: Math.max(1, Math.round(((cy+1)/26)*511))}

  # vector from (cx,cy) at screen-angle `ang`, screen length ~lenCols columns
  # (asp squashes the row axis so a sweep looks circular, not elliptical)
  _stSeg: (idx, cx, cy, ang, lenCols, asp=0.73) ->
    dxn = (Math.cos(ang) * lenCols) / 53
    dyn = (Math.sin(ang) * lenCols * asp) / 26
    th = Math.floor(512 * Math.atan2(dyn, dxn) / (2*Math.PI))
    th = ((th % 512) + 512) % 512
    if Math.abs(dxn) >= Math.abs(dyn)
      yL = 0 ; ln = Math.floor(Math.abs(dxn) * 512)
    else
      yL = 1 ; ln = Math.floor(Math.abs(dyn) * 512)
    @_stXY(idx, cx, cy)
    @bgFCWS[idx+2] = @fcw.encodeFCW {nm:'THETA', r: th}
    @bgFCWS[idx+3] = @fcw.encodeFCW {nm:'LENGT', yLonger: yL, length: ln}

  _stChar: (idx, cx, cy, ch) ->
    @_stXY(idx, cx, cy)
    @bgFCWS[idx+2] = @fcw.encodeFCW {nm:'CHAR1', char: ch}

  # char with a CHARXF transform word (scale index + rotation radians) preceding it
  _stCharXF: (idx, cx, cy, ch, scaleIdx, rot) ->
    rf = ((Math.round(rot/(2*Math.PI)*512) % 512) + 512) % 512
    @bgFCWS[idx] = @fcw.encodeFCW {nm:'CHARXF', rot: rf, scale: scaleIdx}
    @_stXY(idx+1, cx, cy)
    @bgFCWS[idx+3] = @fcw.encodeFCW {nm:'CHAR1', char: ch}

  # exact segment from (x0,y0) to (x1,y1) in col/row space (mirrors the
  # converter's GRIDLINES encoding so it round-trips through drawFCWS)
  _stLine: (idx, x0, y0, x1, y1) ->
    dxn = (x1-x0) / 53
    dyn = (y1-y0) / 26
    th = ((Math.floor(512 * Math.atan2(dyn, dxn) / (2*Math.PI)) % 512) + 512) % 512
    if Math.abs(dxn) >= Math.abs(dyn)
      yL = 0 ; ln = Math.floor(Math.abs(dxn) * 512)
    else
      yL = 1 ; ln = Math.floor(Math.abs(dyn) * 512)
    @_stXY(idx, x0, y0)
    @bgFCWS[idx+2] = @fcw.encodeFCW {nm:'THETA', r: th}
    @bgFCWS[idx+3] = @fcw.encodeFCW {nm:'LENGT', yLonger: yL, length: ln}

  # half-line from (cx,cy) at visual angle a, clipped to the box [x0,y0]-[x1,y1]
  # (0.733 squashes the row axis so the sweep looks circular)
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
    # append after the static buffer's zero terminator
    base = 0
    base++ while base < @bgFCWS.length and @bgFCWS[base] != 0
    o = base
    # leading FEAT reset so animated elements draw normal/solid regardless of
    # whatever feature state the static dfb left set
    @bgFCWS[o] = @fcw.encodeFCW {nm:'FEAT', lineDash:0, blink:0, overbright:0}
    o += 1
    @_stLayout = {}
    @_stLayout.boxVec  = o ; o += 4*4    # (2) windmill: 4 half-lines (POSX,POSY,THETA,LENGT)
    @_stLayout.letters = o ; o += 5*4+1  # (3) A,B,C,D,X x (CHARXF,POSX,POSY,CHAR1) + reset
    @_stLayout.sqH     = o ; o += 3      # (9A) POSX,POSY,CHAR1
    @_stLayout.sqV     = o ; o += 3      # (9B) POSX,POSY,CHAR1
    @_stLayout.bug     = o ; o += 16*4   # (10) 16 vectors
    @_stLayout.eight   = o ; o += 46     # (8) 5 short + FEAT + 5 long + FEAT + connector
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
      @_stBoxRay L.boxVec + i*4, bcx, bcy, bx0, by0, bx1, by1, spin2 + i*(Math.PI/2)

    # (3) AB & CD patterns + X revolving about the circle centre (~33.84 deg/s
    # clockwise, ~10.64 s). AB/CD are each a pair revolving about its own centre.
    # DEFERRED (needs glyph rotation/sizing): CD should rotate so its base faces
    # centre, X should spin about its own centre, and A/B/C/D have distinct
    # heights (0.150"/0.125") -- for now all upright, default size.
    lcx = 9 ; lcy = 12 ; Rorb = 7.0 ; rpair = 0.7 ; ASP = 0.733
    wlet = t * (33.84 * Math.PI/180)  # glyphs are centred by the renderer now
    SC_A = 2 ; SC_B = 1               # scale indices -> 0.150" / 0.125"
    pab = wlet                        # clockwise (screen)
    abx = lcx + Rorb*Math.cos(pab) ; aby = lcy + Rorb*ASP*Math.sin(pab)
    tabc = -Math.sin(pab) ; tabr = ASP*Math.cos(pab)   # tangent = clockwise travel dir
    @_stCharXF L.letters + 0,  abx - rpair*tabc, aby - rpair*tabr, 'A', SC_A, 0   # A upright, trails
    @_stCharXF L.letters + 4,  abx + rpair*tabc, aby + rpair*tabr, 'B', SC_B, 0   # B upright, leads
    pcd = wlet + Math.PI
    cdx = lcx + Rorb*Math.cos(pcd) ; cdy = lcy + Rorb*ASP*Math.sin(pcd)
    tcdc = -Math.sin(pcd) ; tcdr = ASP*Math.cos(pcd)
    rcd = pcd + Math.PI/2             # base toward centre (flip sign if reversed)
    @_stCharXF L.letters + 8,  cdx - rpair*tcdc, cdy - rpair*tcdr, 'C', SC_A, rcd
    @_stCharXF L.letters + 12, cdx + rpair*tcdc, cdy + rpair*tcdr, 'D', SC_B, rcd
    @_stCharXF L.letters + 16, lcx, lcy, 'X', SC_B, wlet              # X spins
    @bgFCWS[L.letters + 20] = @fcw.encodeFCW {nm:'CHARXF', rot:0, scale:0}      # reset for squares

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
      @_stLine L.bug + i*4,
        gx + r0*ca*CPI, gy - r0*sa*RPI,
        gx + r1*ca*CPI, gy - r1*sa*RPI

    # (8) ten varying-brightness lines, right-aligned, with a vertical connector.
    # Exact spec lengths (in); longest 3.5" reaches the X (col 23) above STATUS
    # with rightCol 48. The 5 shortest flash; the 5 longest ramp intensity
    # 0<->max over ~2.33s (via a FEAT intensity word).
    LEN8 = [0.0068, 0.0137, 0.0273, 0.0547, 0.1094, 0.2188, 0.4375, 0.8750, 1.7500, 3.5000]
    rightCol = 51 ; topRow = 19.5 ; sp8 = 0.45
    flashOn = (Math.floor(t / 0.35) % 2) == 0
    bright = (1 - Math.cos(2*Math.PI*t/2.33)) / 2          # 0..1..0 over 2.33 s
    # 5 shortest (k 0..4) at full intensity, flashing
    for k in [0...5]
      y = topRow + k*sp8
      if flashOn
        @_stLine L.eight + k*4, rightCol - LEN8[k]*CPI, y, rightCol, y
      else
        @_stLine L.eight + k*4, rightCol, y, rightCol, y     # flashed off
    # FEAT sets ramped intensity for the 5 longest
    @bgFCWS[L.eight + 20] = @fcw.encodeFCW {nm:'FEAT', lineDash:0, blink:0, overbright:0, intensity: Math.max(1, Math.round(bright*511))}
    for k in [5...10]
      y = topRow + k*sp8
      @_stLine L.eight + 21 + (k-5)*4, rightCol - LEN8[k]*CPI, y, rightCol, y
    # restore full intensity, then the vertical connector
    @bgFCWS[L.eight + 41] = @fcw.encodeFCW {nm:'FEAT', lineDash:0, blink:0, overbright:0, intensity: 0}
    @_stLine L.eight + 42, rightCol, topRow, rightCol, topRow + 9*sp8

    @geo_dps_fcws = @drawFCWS(@bgFCWS, @geo_dps_fcws)



#    ITEM ( 1)+4 EXEC  
# ITEM 18 EXEC

#     GPC        2     *   1 34       00:28:40
#     GPC2               * 1          02:34:30                    (01)
#     I/O EROR FF1           12       11:19:00
