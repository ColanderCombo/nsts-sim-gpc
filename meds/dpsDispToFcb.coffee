#
# dpsDispToFcb — compile a DPS display mock-up into a format control word
# stream.
#
# Input is a `.dsp` file: lines 5..28 are the 24 x 52 character grid, and an
# optional block after a `----` line holds drawing commands.  Output is a
# `.dfb`, the stream a memory fill would carry.
#
# Usage:  node dpsDispToFcb.js <in.dsp> <out.dfb>
#

import {FCW} from '../meds/deuFCW'
import * as FCWD from '../meds/deuFCW'

import * as fs from 'fs'
process = require 'process'

fcw = new FCW()

COLS = 53
ROWS = 26

parseXY = (arg) -> arg.match(/\(([0-9.]+),([0-9.]+)\)/)[1..2]

emitXY = (dfb, col, row) -> dfb.push fcw.positionRun(col, row)...

emitSeg = (dfb, x0, y0, x1, y1) -> dfb.push fcw.vector(x0, y0, x1, y1)...

emitPolyline = (dfb, pts) ->
  prev = pts[0]
  for pt in pts[1..]
    emitSeg dfb, prev[0], prev[1], pt[0], pt[1]
    prev = pt

dpsDispToFcb = (path) ->
  dspFile = fs.readFileSync path

  lines = dspFile.toString().split('\n')

  mn = lines[4...28]
  stText = ((x[3...]+"        ")[...52] for x in mn)

  dfb = []
  # The static preamble every format opens with: the character advance, the
  # carriage-return step, and the three feature-control words.
  dfb.push fcw.majorInc(FCWD.COL_PITCH)
  dfb.push fcw.minorInc(-FCWD.ROW_PITCH)
  dfb.push fcw.attrMode({})
  dfb.push fcw.charMode({})
  dfb.push fcw.colorClear()

  cy = 2
  for line in stText
    # Each run of non-blank text is its own position run, so the beam is not
    # walked across the blanks.
    cx = 0
    while cx < line.length
      if line[cx] == ' '
        cx++
        continue
      start = cx
      cx++ while cx < line.length and line[cx] != ' '
      emitXY dfb, start, cy
      dfb = dfb.concat fcw.chars(line[start...cx])
    cy++

  blocks = dspFile.toString().split('----\n')
  if blocks.length > 1
    cmds = blocks[1].split('\n')
    for cmd in cmds
      cargs = cmd.split(' ')
      op = cargs[0]
      args = cargs[1..]
      switch op
        when 'POSTX'
          [x,y] = parseXY(args[0])
          emitXY dfb, parseFloat(x), parseFloat(y)
        when 'CHAR', 'CHAR1'
          dfb.push fcw.glyphSingle(fcw.toGlyph(args[0]))
        when 'ROT'
          # ROT n: character rotation, n in degrees.
          dfb.push fcw.rotation(parseFloat(args[0]))
        when 'SIZE'
          # SIZE S|L: the DEU's two character sizes.
          dfb.push fcw.charMode({large: args[0] == 'L'})
        when 'STRING'
          dfb = dfb.concat fcw.chars(args[0..].join(" "))
        when 'DASHON'
          dfb.push fcw.attrMode({dash: true})
        when 'DASHOFF'
          dfb.push fcw.attrMode({})
        when 'BLINKON'
          dfb.push fcw.attrMode({blink: true})
        when 'BLINKOFF'
          dfb.push fcw.attrMode({})
        when 'OVERBRIGHTON'
          dfb.push fcw.attrMode({intensity: true})
        when 'OVERBRIGHTOFF'
          dfb.push fcw.attrMode({})
        when 'COLOR'
          dfb.push fcw.colorMode(if args[0] == 'DEU' then null else parseInt(args[0], 10))
        when 'GRIDLINES'
          pts = (parseXY(a).map(parseFloat) for a in args)
          emitPolyline dfb, pts
        when 'CIRCLE'
          # CIRCLE r (cx,cy): r in character columns, scaled to the screen
          # units the circle word carries.
          r = parseFloat(args[0])
          c = if args.length > 1 then parseXY(args[1]).map(parseFloat) else [COLS/2, ROWS/2]
          emitXY dfb, c[0], c[1]
          dfb.push fcw.circleRun(r * FCWD.COL_PITCH)...
        when 'LSITE'
          # LSITE (cx,cy) TEXT: a three-character landing-site label.
          c = parseXY(args[0]).map(parseFloat)
          emitXY dfb, c[0], c[1]
          dfb.push fcw.lsiteWords(args[1..].join(' '))...
        when 'FOCUS'
          # (6) focus/resolution tick array about (cx,cy): 0.0273" spacing;
          # 33 vertical ticks left of centre + 34 right (horizontal array),
          # 33 horizontal ticks above + 34 below (vertical array).
          c = parseXY(args[0])
          fcx = parseFloat(c[0]) ; fcy = parseFloat(c[1])
          CPI = 7.143 ; RPI = 5.236
          spc = 0.0273*CPI ; spr = 0.0273*RPI      # spacing in cols / rows
          hlr = 0.1*RPI/2 ; hlc = 0.1*CPI/2        # half tick length (0.1" segments)
          emitSeg(dfb, fcx-i*spc, fcy-hlr, fcx-i*spc, fcy+hlr) for i in [1..33]
          emitSeg(dfb, fcx+i*spc, fcy-hlr, fcx+i*spc, fcy+hlr) for i in [1..34]
          emitSeg(dfb, fcx-hlc, fcy-j*spr, fcx+hlc, fcy-j*spr) for j in [1..33]
          emitSeg(dfb, fcx-hlc, fcy+j*spr, fcx+hlc, fcy+j*spr) for j in [1..34]
        when 'RECT'
          c0 = parseXY(args[0]).map(parseFloat)
          c1 = parseXY(args[1]).map(parseFloat)
          emitPolyline dfb, [[c0[0],c0[1]],[c1[0],c0[1]],[c1[0],c1[1]],
                             [c0[0],c1[1]],[c0[0],c0[1]]]

  # End the stream: branch back into the DEU's own program.
  dfb.push fcw.deuReturn()
  return dfb

replaceAt = (s, n, t) ->
    return s.substring(0, n) + t + s.substring(n + 1)

dpsFcbToStr = (dfb) ->
  screen = (" ".repeat(52) for x in [0..26])
  beamX = FCWD.COL_ORIGIN ; beamY = FCWD.ROW_ORIGIN
  homeX = beamX
  put = (ch) ->
    col = Math.round(FCWD.cellCol(beamX))
    row = Math.round(FCWD.cellRow(beamY))
    if 0 <= row < screen.length and 0 <= col < 52 and ch != ' '
      screen[row] = replaceAt(screen[row], col, ch)
    beamX += FCWD.COL_PITCH
  for word in dfb
    f = fcw.decodeFCW(word)
    continue if not f?
    switch f.nm
      when 'XPOS'
        beamX = f.v.x ; homeX = f.v.x if f.v.translate == 0
      when 'YPOS'
        beamY = f.v.y if f.v.translate == 0
      when 'CHAR2'
        for g in [f.v.g1, f.v.g2]
          if g == 0x0d
            beamX = homeX ; beamY -= FCWD.ROW_PITCH
          else if g != 0
            put fcw.DEUCharset[g] ? ' '
          # a zero is the empty half of a single-glyph word: no glyph, no
          # advance
  return screen.join("\n")

writeDFB = (dfb, path) ->
  fs.writeFileSync path, FCWD.bytesFromWords(dfb), "binary"


dfb = dpsDispToFcb process.argv[2]

console.log "-".repeat(52)
console.log dpsFcbToStr dfb
console.log "-".repeat(52)
console.log "#{dfb.length} format control words"

writeDFB dfb, process.argv[3] if process.argv[3]?
