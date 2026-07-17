
# fs = require 'fs'

import {PackedBits} from '../gpc/util'
import {FCW} from '../meds/deuFCW'

import * as fs from 'fs'
process = require 'process'

fcw = new FCW()

parseXY = (arg) -> arg.match(/\(([0-9.]+),([0-9.]+)\)/)[1..2]

xy2rt = (xy) ->
  r = Math.sqrt(xy[0]**2 + xy[1]**2)
  t = Math.atan2(xy[1],xy[0])
  return [r,t]

rt2xy = (rt) ->
  x = rt[0]*Math.cos(rt[1])
  y = rt[0]*Math.sin(rt[1])
  return [x,y]

# emit a single straight segment (col/row) as POSX,POSY,THETA,LENGT (as GRIDLINES does)
emitSeg = (dfb, x0, y0, x1, y1) ->
  dfb.push fcw.encodeFCW {nm:'POSX', x: Math.floor((x0/53)*511)}
  dfb.push fcw.encodeFCW {nm:'POSY', y: Math.floor(((y0+1)/26)*511)}
  dxy = [(x1-x0)/53, (y1-y0)/26]
  rt = xy2rt(dxy)
  theta = ((Math.floor(512*(rt[1]/(2*Math.PI))) % 512) + 512) % 512
  if Math.abs(dxy[0]) > Math.abs(dxy[1])
    yLonger = 0 ; length = Math.floor(Math.abs(dxy[0])*512)
  else
    yLonger = 1 ; length = Math.floor(Math.abs(dxy[1])*512)
  dfb.push fcw.encodeFCW {nm:'THETA', r: theta}
  dfb.push fcw.encodeFCW {nm:'LENGT', yLonger: yLonger, length: length}

dpsDispToFcb = (path) ->
  dspFile = fs.readFileSync path

  lines = dspFile.toString().split('\n')

  mn = lines[4...28]
  stText = ((x[3...]+"        ")[...52] for x in mn)

  dfb = []

  cx = 0
  cy = 2
  inSpace = true
  curFCW = {}

  for line in stText
    for c in line
      if c != ' '
        if inSpace
          curFCW = {nm:'POSTX',x:cx,y:cy}
          console.log curFCW
          dfb.push fcw.encodeFCW curFCW
          inSpace = false
        if curFCW.nm == 'CHAR1'
          curFCW = {nm:'CHAR2', char1:fcw.DEUCharset[curFCW.char], char2:c}
          console.log curFCW
          dfb.pop()
          dfb.push fcw.encodeFCW curFCW
        else
          curFCW = {nm:'CHAR1', char:c, blink:0,intensity:0}
          console.log curFCW
          dfb.push fcw.encodeFCW curFCW
      else
        inSpace = true
      cx++
    cy++
    cx=0
    dfb.push fcw.encodeFCW {nm:'POSTX',x:cx,y:cy}

  console.log "<<<<<<<<<<<<<<BLOCKBLOCKBLOCKBLOCK>>>>>>>>>>>>>>>>>"

  blocks = dspFile.toString().split('----\n')
  if blocks.length > 1
    cmds = blocks[1].split('\n')
    for cmd in cmds
      cargs = cmd.split(' ')
      op = cargs[0]
      args = cargs[1..]
      console.log "BLOCK CMD", op, args
      switch op
        when 'POSTX'
          [x,y] = args[0].match(/\(([0-9.]+),([0-9.]+)\)/)[1..2]
          xv = (x/53)*511
          yv = (y/26)*511
          # console.log "///",x,y,xv,yv
          dfb.push fcw.encodeFCW {nm:'POSX', x:xv}
          dfb.push fcw.encodeFCW {nm:'POSY', y:yv}
        when 'CHAR', 'CHAR1'
          #console.log args[0]
          dfb.push fcw.encodeFCW {nm:'CHAR1', char: args[0]}
        when 'CHARXF'
          # CHARXF (rot,scale): emulator char transform (rot 0..511, scale index 0..7)
          [r,s] = args[0].match(/\(([0-9.]+),([0-9.]+)\)/)[1..2]
          dfb.push fcw.encodeFCW {nm:'CHARXF', rot: Math.round(parseFloat(r)), scale: Math.round(parseFloat(s))}
        when 'STRING'
          char2 = []
          for c in args[0..].join(" ")
            char2.push c
            if char2.length == 2
              dfb.push fcw.encodeFCW {nm:'CHAR2', char1:char2[0], char2:char2[1]}
              char2 = []
          if char2.length == 1
            dfb.push fcw.encodeFCW {nm:'CHAR1', char:char2[0]}
        when 'DASHON'
          dfb.push fcw.encodeFCW {nm:'FEAT', lineDash:1}
        when 'DASHOFF'
          dfb.push fcw.encodeFCW {nm:'FEAT', lineDash:0}
        when 'BLINKON'
          dfb.push fcw.encodeFCW {nm:'FEAT', blink:1}
        when 'BLINKOFF'
          dfb.push fcw.encodeFCW {nm:'FEAT', blink:0}
        when 'OVERBRIGHTON'
          dfb.push fcw.encodeFCW {nm:'FEAT', overbright:1}
        when 'OVERBRIGHTOFF'
          dfb.push fcw.encodeFCW {nm:'FEAT', overbright:0}
        when 'GRIDLINES'
          # console.log "GRIDLINES", args
          xy = parseXY(args[0])
          
          xv = Math.floor((parseFloat(xy[0])/53)*511)
          yv = Math.floor(((parseFloat(xy[1])+1)/26)*511)

          #console.log "++", xy, [xv,yv]

          dfb.push fcw.encodeFCW {nm:'POSX', x:xv}
          dfb.push fcw.encodeFCW {nm:'POSY', y:yv}
          for coord in args[1..]
            xy1 = parseXY(coord)
            dxy = [(xy1[0]-xy[0])/53, (xy1[1]-xy[1])/26]
            rt = xy2rt(dxy)
            #console.log rt
            theta = Math.floor(512*(rt[1]/(2*Math.PI)))
            if Math.abs(dxy[0]) > Math.abs(dxy[1])
              yLonger=0
              length = Math.floor(Math.abs(dxy[0])*512)
            else
              yLonger=1
              length = Math.floor(Math.abs(dxy[1])*512)
            #console.log "XY1: #{xy1} DXY: #{dxy} THETA: #{theta} LEN:#{length}"
            dfb.push fcw.encodeFCW {nm:'THETA', r:theta}
            dfb.push fcw.encodeFCW {nm:'LENGT', yLonger:yLonger, length:length}
            xy = xy1
        when 'CIRCLE'
          radius = Math.floor((parseFloat(args[0])/53)*512)
          dfb.push fcw.encodeFCW {nm:'CIRC', radius:radius}
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
          # RECT (x0,y0) (x1,y1): draw the rectangle as a closed polyline of
          # its four corners, using the same segment encoding as GRIDLINES.
          c0 = parseXY(args[0])
          c1 = parseXY(args[1])
          x0 = parseFloat(c0[0]); y0 = parseFloat(c0[1])
          x1 = parseFloat(c1[0]); y1 = parseFloat(c1[1])
          corners = [[x0,y0],[x1,y0],[x1,y1],[x0,y1],[x0,y0]]

          xv = Math.floor((x0/53)*511)
          yv = Math.floor(((y0+1)/26)*511)
          dfb.push fcw.encodeFCW {nm:'POSX', x:xv}
          dfb.push fcw.encodeFCW {nm:'POSY', y:yv}

          prev = corners[0]
          for pt in corners[1..]
            dxy = [(pt[0]-prev[0])/53, (pt[1]-prev[1])/26]
            rt = xy2rt(dxy)
            theta = Math.floor(512*(rt[1]/(2*Math.PI)))
            if Math.abs(dxy[0]) > Math.abs(dxy[1])
              yLonger = 0
              length = Math.floor(Math.abs(dxy[0])*512)
            else
              yLonger = 1
              length = Math.floor(Math.abs(dxy[1])*512)
            dfb.push fcw.encodeFCW {nm:'THETA', r:theta}
            dfb.push fcw.encodeFCW {nm:'LENGT', yLonger:yLonger, length:length}
            prev = pt

  return dfb

replaceAt = (s, n, t) ->
    return s.substring(0, n) + t + s.substring(n + 1)

dpsFcbToStr = (dfb) ->
  screen = []
  for x in [0..26]
    screen.push " ".repeat(52)

  # console.log screen

  cx = 0
  cy = 0

  for fc in dfb
    f = fcw.decodeFCW(fc)
    console.log "D",fc, f.nm, f.v
    if f.nm == 'POSTX'
      cx = f.v.x
      cy = f.v.y
    if f.nm == 'CHAR1'
      screen[cy] = replaceAt(screen[cy], cx, f.v.char)
      cx++
      if cx > 52
        cy++
        cx = 0
    if f.nm == 'CHAR2'
      screen[cy] = replaceAt(screen[cy],cx, f.v.char1)
      screen[cy] = replaceAt(screen[cy],cx+1, f.v.char2)
      cx = cx+2

  return screen.join("\n")

writeDFB = (dfb,path) ->
  data = new ArrayBuffer(dfb.length*2)
  data16 = new Uint16Array(data)
  data8 = new Uint8Array(data)
  i = 0
  for f in dfb
    data16[i] = f
    i++
  fs.writeFileSync path,data8,"binary"


dfb = dpsDispToFcb process.argv[2]

fcws=  dpsFcbToStr dfb
console.log "-".repeat(52)
console.log fcws
console.log "-".repeat(52)

writeDFB dfb, process.argv[3]

# f = fcw.encodeFCW {nm:'CHAR2', char1:'9', char2:'A'}
# console.log asHex(f)
# console.log asBin(f)
# console.log fcw.decodeFCW f


