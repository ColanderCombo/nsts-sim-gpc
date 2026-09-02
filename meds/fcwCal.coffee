# fcwCal — measure the beam grid a format control word stream is written on.
#
#   node fcwCal.js <file.dfb> [...]
#
# The screen geometry in `meds/deuFCW` is a fit to streams like these.  This
# reports what a stream says about the grid it was written on, so a fit can
# be checked against the thing it was fitted to.
#
# Three measurements, and the first two need no origin at all:
#
#   LATTICE   the residue of each position word modulo the pitch, split by
#             whether the run draws characters or vectors.  Characters sit
#             on one lattice and vectors half a cell from it in both axes:
#             a box round a block of text has its edges between cells, so
#             the vector lattice is the cell boundary and the character
#             lattice is the middle of the cell.
#
#   SPAN      the widest gap between consecutive coordinates, taken round a
#             candidate wrap.  A display is 52 columns -- 988 units -- and
#             26 rows, so every coordinate has to fall inside that arc.  A
#             wrap the stream will not fit into is the wrong wrap.
#
#   ORIGIN    where cell column 0 would be, if the leftmost character is in
#             column 0.  Only meaningful once the wrap is settled.
#
import {FCW, wordsFromBytes} from '../meds/deuFCW'
import * as FCWD from '../meds/deuFCW'
import * as fs from 'fs'
process = require 'process'

fcw = new FCW()

# The position words, split by what the run they lead draws.
runs = (words) ->
  out = {text: {x: [], y: []}, vector: {x: [], y: []}}
  x = null ; y = null
  for hw in words
    d = fcw.decodeFCW hw
    continue if not d?
    if d.nm == 'XPOS' and not d.v.translate      then x = FCWD.beamFold(d.v.x)
    else if d.nm == 'YPOS' and not d.v.translate then y = FCWD.beamFold(d.v.y)
    else if d.nm == 'CHAR2' or d.nm == 'VECA'
      continue if not (x? and y?)
      k = if d.nm == 'CHAR2' then 'text' else 'vector'
      out[k].x.push x ; out[k].y.push y
  out

hist = (vals, pitch) ->
  h = {}
  h[v %% pitch] = (h[v %% pitch] ? 0) + 1 for v in vals
  ([Number(k), v] for k, v of h).sort((a, b) -> b[1] - a[1])

# The widest gap between consecutive values taken round `wrap`: everything
# a display draws has to fit in the arc the gap leaves.
arc = (vals, wrap) ->
  return 0 if vals.length < 2
  s = [...new Set(v %% wrap for v in vals)].sort((a, b) -> a - b)
  gap = wrap - s[s.length - 1] + s[0]
  gap = Math.max(gap, s[i] - s[i - 1]) for i in [1...s.length]
  wrap - gap

report = (name, words) ->
  r = runs(words)
  console.log "== #{name}"
  for [axis, pitch, extent] in [['x', FCWD.COL_PITCH, 52], ['y', FCWD.ROW_PITCH, 26]]
    t = hist(r.text[axis], pitch)
    v = hist(r.vector[axis], pitch)
    line = "   #{axis.toUpperCase()} pitch #{pitch}  text " +
           (if t.length then "#{t[0][0]} (#{t[0][1]}/#{r.text[axis].length})" else '-') +
           "  vector " +
           (if v.length then "#{v[0][0]} (#{v[0][1]}/#{r.vector[axis].length})" else '-')
    if t.length and v.length
      d = (v[0][0] - t[0][0]) %% pitch
      line += "  separation #{d} of #{pitch}" +
              (if Math.abs(d - pitch / 2) <= 0.5 then " -- half a cell" else "")
    console.log line
    all = r.text[axis].concat(r.vector[axis])
    for wrap in [FCWD.SCREEN_WRAP, FCWD.GRID]
      a = arc(all, wrap)
      fits = if a <= extent * pitch then 'fits' else "OVER by #{a - extent * pitch}"
      console.log "     wrap #{wrap}: spans #{a} units of the #{extent * pitch} " +
                  "#{extent} #{if axis == 'x' then 'columns' else 'rows'} allow -- #{fits}"

for f in process.argv[2..]
  report f, wordsFromBytes(fs.readFileSync(f))
