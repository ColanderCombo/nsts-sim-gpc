#
# The DEU Stand-Alone Self Test (SAST)
#
# The SAST is a self-contained assembly program that replaces the DCP
# on the DEU and draws an animated display exercising the features of
# the DEU display generator.
#
# STS-83-0020V2-34/sect.4.6.8 describes the display in inches and degrees per
# second, and its Figure 4.6.8-1 gives the layout against rulers marked in
# addressable units.  Two things fall out of reading the two together:
#
#   * one addressable unit is 7/1024 inch, so the grid is exactly 7.000 by
#     4.997 inches.  At that scale every dimension in the specification is a
#     whole number of units -- the four circle radii are 21, 60, 127 and 160,
#     the ten brightness lines are 1, 2, 4 ... 512, the windmill's square is
#     108 a side, the bug's lines run from 30 out to 60, the travelling
#     squares move 497 and 126.
#
#   * every rate is a whole number of steps per 55 Hz refresh frame.  The
#     letters revolve 7 angle units a frame (4096/7 = 585 frames = 10.64 s,
#     the specified figure); the bug spins 11; the squares move one unit;
#     the intensity ramp climbs one of its 128 levels, which is the width of
#     the symbol generator's intensity register.
#
# The windmill is the one that proves it.  Its rotation is specified as
# VARIABLE -- 3.15 deg/s near the diagonals, 6.30 deg/s near the
# perpendicular, exactly 2:1.  That is what stepping a tangent SLOPE linearly
# looks like: for m = tan(theta), d(theta)/dt = (dm/dt)/(1+m^2), which is
# twice as fast at m=0 as at m=1.  512 steps sweep 45 degrees, two sweeps
# make the 90 degrees the pattern repeats on, and 1024 frames is 18.6 s
# against the specified 18.2.  So the program stepped the slope field of an
# op-A word once a frame, and never computed an angle at all.
#
# Nothing below is in inches and nothing is driven from the wall clock: the
# caller passes a frame number and gets the format control words for that
# frame.  With the model of the machine right, the specified display
# falls out of integer arithmetic.
#
import {FCW} from 'meds/deuFCW'
import * as FCWD from 'meds/deuFCW'

export FRAME_HZ = 55

# --- the layout in addressable units --------------------------------------
#
# Columns and rows come off Figure 4.6.8-1's rulers: the column marks run
# 28, 66, 104 ... 38 apart, which is two character columns, and the row marks
# 14, 68, 122 ... 54 apart, which is two rows.  Text lands on a 19 x 27 grid,
# the first line at y 79.
export COL0 = 9                  # addressable unit of character column 0
export ROW0 = 79                 # ... and of the first text line
export colAU = (c) -> COL0 + FCWD.COL_PITCH * c
export rowAU = (r) -> ROW0 + FCWD.ROW_PITCH * r

# The beam grid is modular and the renderer works in character cells, so an
# X left of cell column 0 -- addressable unit 18 -- does not come out on the
# left of the screen, it wraps to column 107 and off the right.  The format
# area starts there, so that is the left edge anything positioned may use.
export X_MIN = 0                  # the grid's own left edge; see cellCol
export X_MAX = FCWD.AU_WIDTH - 1
export Y_MIN = 0
export Y_MAX = FCWD.AU_HEIGHT - 1

# ...and nothing is drawn right up against that edge.  A vector's slope is
# quantised to nine bits, so the far end of a long line can land a unit or
# two off where it was aimed -- and one unit past the boundary does not
# clamp, it wraps to the far side of the modular grid.  A line aimed at the
# top edge of the screen came out at cell row 75.
export EDGE = 3

# (5) the concentric circles, and (14) the letters that revolve in them.
# The radii are the specification's; the centre is read off the figure, where
# the X at the top of the largest circle sits exactly 160 units above it.
export CIRCLE_CX = 170
export CIRCLE_CY = 353
export CIRCLE_R = [21, 60, 127, 160]
export CIRCLE_DASHED = 60        # "the second smallest is dashed"

# (4) the square the windmill turns inside.  0.7383 inch is 108 units.
export BOX = 108
# "Below the third line of text", which ends at unit 160; the figure puts it
# at 176 to 284 on its scale.
export BOX_X = 400               # its left edge, off the figure
export BOX_Y = 176               # ... and its top

# (8) the resolution tick marks: 33 one side of centre and 34 the other,
# 0.0273 inch -- four units -- apart.
#
# "The tick marks are short, straight line segments from the symbol
# generator character matrix", so they are characters, and the character
# generator's advance spaces them: MAJOR INCREMENT carries the four-unit
# pitch and FCW1's axis bit turns the advance down the screen for the
# vertical array.  A full-cell rule is 24 units on the long axis, which is
# the length Figure 4.6.8-1 shows.  The two arrays are 82 halfwords.
export TICK_STEP = 4
export TICK_BEFORE = 33
export TICK_AFTER = 34
export TICK_CX = 490
export TICK_CY = 420             # the arrays begin just below the square
export TICK_VERTICAL = 0x7c      # the full-cell vertical rule
export TICK_HORIZONTAL = 0x17    # ... and the horizontal one

# The three codes the bottom line's plus-or-minus is struck from.
export PLUS = 0x2b
export BACKSPACE = 0x08
export UNDERSCORE = 0x7d

# (10) the ten brightness lines, right ends aligned, each twice the last.
export RAMP_LEN = (1 << k for k in [0..9])
export RAMP_RIGHT = 985
export RAMP_TOP = 545
export RAMP_STEP = 13            # vertical spacing
export RAMP_PERIOD = 128         # frames for the intensity cycle: 2.33 s

# (11)(12) the two travelling squares, one unit a frame.
#
# The specification over-determines these and its numbers do not quite
# close: the stated travels are 3.3975 and 0.8613 inch, which are 497 and
# 126 units, but the stated cycles are 18.62 and 4.63 seconds, which at one
# unit a frame are 512 and 128.  The cycles are taken as authoritative,
# because the specification also says the two squares coincide every fourth
# cycle, and only 512 against 128 makes that exactly true.
export SQ_H_TRAVEL = 512         # 18.62 s at 55 Hz; the stated travel is 497
export SQ_V_TRAVEL = 128         # 4.65 s; the stated travel is 126
export SQ_H_CYCLE = 2 * SQ_H_TRAVEL
export SQ_V_CYCLE = 2 * SQ_V_TRAVEL
export SQ_X = 460                # the left end of the horizontal travel
export SQ_Y = 440
export SQ_GLYPH = 0x1a           # the empty square in the DEU character set

# (13) the spinning bug: sixteen lines in a sunburst, 30 units out to 60.
export BUG_R0 = 30
export BUG_R1 = 60
export BUG_LINES = 16
export BUG_SPIN = 11             # angle units a frame: 53.17 deg/s

# The bug's centre slides up and to the right along the screen's diagonal.
# The specification gives both a speed, 1.536 in/s, and a cycle, 26.48
# seconds, and they are irreconcilable: 26.48 s is 1456 frames, and 728
# frames each way at 1.536 in/s is 2912 units of travel -- well over twice
# the 1258-unit screen diagonal.  Note the factor: the stated speed is
# exactly four times what the stated cycle allows.
#
# The cycle is taken, for three reasons.  It is the quantity a person with a
# stopwatch can actually check.  One unit a frame keeps the integer step
# every other element on this display has.  And 728 units each
# way is a sweep across most of the screen, which is what the figure shows;
# at four units a frame the bug crosses a corner of it in under two seconds.
#
# The cost is that the specification also describes the bug as "an emblem at
# the center of a rolling wheel with about four times the diameter", and
# that appearance needs the faster translation: at one unit a frame against
# the specified 53.17 deg/s spin it rolls like a wheel of that diameter.
export BUG_STEP = 1
export BUG_TRAVEL = 728          # units each way: 1456 frames, 26.47 s
export BUG_CYCLE = 2 * BUG_TRAVEL // BUG_STEP
export BUG_X0 = 216              # the low end of the sweep, on the band's
export BUG_Y0 = 576              # ... centre line through the screen centre

# (14) the revolving letters.  Seven angle units a frame is 33.84 deg/s, and
# 4096/7 = 585 frames is the specified 10.64 second cycle.
export LETTER_SPIN = 7
export LETTER_ORBIT = 143        # midway between the 127 and 160 circles
export LETTER_PAIR = 12          # half the separation of the two glyphs

# A character's beam position is the middle of its cell (meds/deuFCW), so
# anything meant to be centred on a point -- the two X's on the circles, the
# four revolving letters, the resolution ticks -- is positioned at that
# point and nothing is set back.

# (15) the boxed windmill: one slope step a frame, 512 to a 45 degree sweep.
#
# A slope field can only carry a ratio up to 1, so 45 degrees is as far as
# one sweep reaches.  The next 45 come from the same field stepped back down
# with the major axis swapped -- the ratio is then the cotangent, and an arm
# at 45 degrees is the one position where both readings agree, so the two
# sweeps meet without a seam.  Stepping the field up again instead would
# throw the arm back to the perpendicular, which is a visible jump of 45
# degrees at every boundary.
#
# "Every 90 degrees of rotation the pattern repeats" -- so two sweeps are a
# whole cycle, and 1024 frames is 18.6 s against the specified 18.2.
export WINDMILL_STEPS = 512
export WINDMILL_CYCLE = 2 * WINDMILL_STEPS

# A frame is always this many halfwords, padded with no-ops past the
# end-of-refresh word.  Fixed length is what lets one frame be written
# straight over the last without leaving any of it standing.
export FRAME_WORDS = 320

# (6) the diagonals are 0.8980 inch apart, so 66 units either side of centre.
export DIAGONAL_OFFSET = 66

# Which way a positive rotation word turns a glyph, against the sense the
# letters orbit in.  The rotation field and the beam's Y run opposite ways,
# so the two are related by a sign and this is it: if the revolving C and D
# and the centre X spin the wrong way round, this is the one thing to flip.
ROT_SIGN = -1

ANGLE_MASK = FCWD.ANGLE_UNITS - 1

# A triangle wave: 0 up to `half`, back down, period 2*half.
tri = (n, half) ->
  p = ((n % (2 * half)) + 2 * half) % (2 * half)
  if p <= half then p else 2 * half - p

export class SelfTest
  constructor: (fcw) ->
    @f = fcw ? new FCW()

  # --- helpers ------------------------------------------------------------
  #
  # Everything is positioned in addressable units.  A position run is the
  # zero word the DEU leads one with, then the two axis words.
  at: (x, y) ->
    [@f.noop(), @f.xPosition(@f.absX(Math.round(x))),
     @f.yPosition(@f.absY(Math.round(y)))]

  text: (x, y, s) -> @at(x, y).concat(@f.chars(s))

  # One glyph with its middle at (x, y).
  centred: (x, y, s) -> @text(x, y, s)

  glyphs: (x, y, codes) ->
    out = @at(x, y)
    i = 0
    while i < codes.length
      if i + 1 < codes.length
        out.push @f.glyphPair(codes[i], codes[i + 1])
      else
        out.push @f.glyphSingle(codes[i])
      i += 2
    out

  # One array of resolution ticks: 68 characters four units apart, the one
  # at the centre a space so the arrays cross in a gap.  `down` runs the
  # advance along Y instead of X, which is what FCW1's axis bit is for.
  tickArray: (glyph, down) ->
    f = @f
    n = TICK_BEFORE + TICK_AFTER + 1
    codes = ((if i == TICK_BEFORE then 0x20 else glyph) for i in [0...n])
    span = TICK_BEFORE * TICK_STEP
    [x, y] = if down then [TICK_CX, TICK_CY - span] else [TICK_CX - span, TICK_CY]
    [f.majorInc(if down then -TICK_STEP else TICK_STEP), f.attrMode({axisY: down})]
      .concat(@glyphs(x, y, codes))
      .concat([f.majorInc(FCWD.COL_PITCH), f.attrMode({})])

  # One straight segment in addressable units.  The major axis carries the
  # signed extent and the slope word the minor/major ratio at nine bits.
  line: (x0, y0, x1, y1) ->
    dx = Math.round(x1 - x0)
    dy = -Math.round(y1 - y0)                 # beam Y decreases going down
    yMajor = Math.abs(dy) > Math.abs(dx)
    major = if yMajor then dy else dx
    minor = Math.abs(if yMajor then dx else dy)
    am = Math.abs(major)
    slope = if minor and am
      2 * Math.min(Math.floor((minor * 1024 + am) / (2 * am)), 511)
    else 0
    [@f.vectorBegin(),
     @f.xPosition(@f.absX(Math.round(x0))), @f.yPosition(@f.absY(Math.round(y0))),
     @f.vecSlope({yMajor: yMajor, signDiffer: dx * dy < 0, slope: slope}),
     @f.vecExtent(major),
     @f.charMode({})]

  # A circle is drawn about the beam, which it does not move.
  circleAt: (x, y, r) ->
    @at(x, y).concat(@f.circleRun(r, @f.charMode({})))

  # --- the static display, paragraphs 1 to 9 and 16 -----------------------
  #
  # Paragraph 7's area is deliberately empty: it is there to show that
  # blanking works, and carries "BLK (FAIL)" only when it does not.
  PANGRAM = 'pack my box with five dozen liquor jugs'

  # (3) the third line, in the six groups of five the specification lists.
  LINE3 = [[0x02, 0x07, 0x5d, 0x1b, 0x01],   # [ . overscore degree ]
           [0x28, 0x21, 0x22, 0x24, 0x29],   # ( ! sinusoid check )
           [0x05, 0x3f, 0x04, 0x18, 0x05],   # dots ? dot half-line dots
           [0x1c, 0x26, 0x27, 0x2c, 0x1d],   # up & ' , down
           [0x1e, 0x2e, 0x2f, 0x3a, 0x1f],   # right . / : left
           [0x0b, 0x3b, 0x17, 0x16, 0x0c]]   # head ; half-line _ head

  # (9) the twenty symbols the other lines do not reach, five high and four
  # wide: Greek, del, the TACAN wye, the diamond, and the two Shuttle
  # outlines.
  SYMBOLS = [[0x10, 0x14, 0x7b, 0x0f]
             [0x11, 0x5c, 0x5f, 0x19]
             [0x40, 0x7e, 0x15, 0x0a]
             [0x7f, 0x5e, 0x13, 0x0e]
             [0x06, 0x12, 0x5b, 0x60]]
  SYMBOL_COL = 28
  SYMBOL_ROW = 16

  # (9) the bottom line: numerals at normal intensity, the mathematical
  # symbols after them bright.  The first of the nine is a plus-or-minus,
  # which the character set has no glyph for: it is a `+` backspaced over
  # and struck again with the full-cell underscore.
  BOTTOM_DIGITS = '0123456789'
  BOTTOM_MATH = [PLUS, BACKSPACE, UNDERSCORE,
                 0x2b, 0x2d, 0x3d, 0x23, 0x25, 0x3e, 0x3c, 0x2a]

  staticWords: (o = {}) ->
    f = @f
    w = [f.majorInc(FCWD.COL_PITCH), f.minorInc(-FCWD.ROW_PITCH),
         f.attrMode({}), f.charMode({})]

    # (1) the lower-case pangram, bright, and (2) the upper-case one three
    # columns to its left at normal intensity.
    w.push f.attrMode({intensity: true})
    w = w.concat @text(colAU(4), rowAU(0), PANGRAM)
    w.push f.attrMode({})
    w = w.concat @text(colAU(1), rowAU(1), PANGRAM.toUpperCase())

    # (3) the character line, bright, groups of five separated by a space.
    w.push f.attrMode({intensity: true})
    codes = []
    for g, i in LINE3
      codes.push(0x20) if i > 0
      codes = codes.concat g
    w = w.concat @glyphs(colAU(1), rowAU(2), codes)
    w.push f.attrMode({})

    # (4) the square the windmill turns in.
    w = w.concat @line(BOX_X, BOX_Y, BOX_X + BOX, BOX_Y)
    w = w.concat @line(BOX_X + BOX, BOX_Y, BOX_X + BOX, BOX_Y + BOX)
    w = w.concat @line(BOX_X + BOX, BOX_Y + BOX, BOX_X, BOX_Y + BOX)
    w = w.concat @line(BOX_X, BOX_Y + BOX, BOX_X, BOX_Y)

    # (5) the four concentric circles, the 60 one dashed, and the two X's on
    # the largest -- at the top and at the right.
    for r in CIRCLE_R
      w.push f.attrMode({dash: true}) if r == CIRCLE_DASHED
      w = w.concat @circleAt(CIRCLE_CX, CIRCLE_CY, r)
      w.push f.attrMode({}) if r == CIRCLE_DASHED
    big = CIRCLE_R[CIRCLE_R.length - 1]
    w = w.concat @centred(CIRCLE_CX, CIRCLE_CY - big, 'X')
    w = w.concat @centred(CIRCLE_CX + big, CIRCLE_CY, 'X')

    # (6) the two diagonals.  0.8980 inch apart is 131 units, so each passes
    # 66 from the centre of the screen, and they run at the angle of the
    # screen's diagonal -- atan(731/1024) is 35.53 degrees, the specified
    # 35.54.  The upper one is dashed.
    for sep, i in [-DIAGONAL_OFFSET, DIAGONAL_OFFSET]
      [a, b] = @_diagonal(sep)
      w.push f.attrMode({dash: i == 0})
      w = w.concat @line(a[0], a[1], b[0], b[1])
    w.push f.attrMode({})

    # (8) the resolution ticks.
    w = w.concat @tickArray(TICK_VERTICAL, false)
    w = w.concat @tickArray(TICK_HORIZONTAL, true)

    # (9) the twenty remaining symbols, and the bottom line.
    for row, r in SYMBOLS
      w = w.concat @glyphs(colAU(SYMBOL_COL), rowAU(SYMBOL_ROW + r), row)
    w = w.concat @text(colAU(1), rowAU(22), BOTTOM_DIGITS)
    w.push f.attrMode({intensity: true})
    w = w.concat @glyphs(colAU(11), rowAU(22), BOTTOM_MATH)
    w.push f.attrMode({})

    # (16) the keyboard, major function and BITE test block, and (17) the
    # status line.  The key code shown is the last one pressed; before any
    # key is pressed both adapters show two asterisks.
    kb = o.keys ? ['**', '**']
    w = w.concat @text(colAU(37), rowAU(9),  "KBUA #{kb[0]}")
    w = w.concat @text(colAU(37), rowAU(10), "KBUB #{kb[1]}")
    w = w.concat @text(colAU(37), rowAU(11), "MF #{o.majorFunc ? 'GNC'}")
    w = w.concat @text(colAU(44), rowAU(11), 'ERR') if o.mfError
    w = w.concat @text(colAU(37), rowAU(12), 'TEST 1' + (if o.testRunning then ' *' else ''))
    w = w.concat @text(colAU(21), rowAU(22), 'STATUS')
    st = o.status ? [0x8200, 0x8000, 0x8000, 0x2000]
    for v, i in st
      w = w.concat @text(colAU(28 + 5 * i), rowAU(22),
                         (v & 0xffff).toString(16).toUpperCase().padStart(4, '0'))
    w

  # --- the dynamic display, paragraphs 10 to 15 ---------------------------
  #
  # `n` is the refresh frame number.  Every quantity below is an integer
  # function of it.
  frameWords: (n) ->
    f = @f
    w = @preamble()
      .concat(@rampWords(n))
      .concat(@squareWords(n))
      .concat(@bugWords(n))
      .concat(@letterWords(n))
      .concat(@windmillWords(n))
    w.push f.endOfRefresh()
    throw new Error("self test frame is #{w.length} halfwords, over " +
                    "FRAME_WORDS #{FRAME_WORDS}") if w.length > FRAME_WORDS
    w.push f.noop() while w.length < FRAME_WORDS
    w

  # The four words a frame opens with: the character pitches and the two
  # mode registers, so a frame does not inherit whatever the static half
  # left standing.
  preamble: () ->
    [@f.majorInc(FCWD.COL_PITCH), @f.minorInc(-FCWD.ROW_PITCH),
     @f.attrMode({}), @f.charMode({})]

  # (10) the ten brightness lines.  The five shortest flash; the five
  # longest ramp through the intensity register's 128 levels, which the
  # DEU renders as its one intensity bit.
  rampWords: (n) ->
    f = @f
    w = []
    lit = (n % (2 * RAMP_PERIOD)) < RAMP_PERIOD
    bright = tri(n, RAMP_PERIOD / 2) >= RAMP_PERIOD / 4
    for len, k in RAMP_LEN
      y = RAMP_TOP + k * RAMP_STEP
      dark = k < 5 and not lit
      w.push f.attrMode({intensity: (k >= 5 and bright)})
      # A dark line keeps its slot and draws nothing: the beam is positioned
      # and the extent is zero.
      w = w.concat @line((if dark then RAMP_RIGHT else RAMP_RIGHT - len), y,
                         RAMP_RIGHT, y)
    w.push f.attrMode({})
    w = w.concat @line(RAMP_RIGHT, RAMP_TOP, RAMP_RIGHT,
                       RAMP_TOP + 9 * RAMP_STEP)

    w

  # (11)(12) the two travelling squares, a unit a frame.  The vertical
  # one's cycle is exactly a quarter of the horizontal one's, which is why
  # they meet at the corner every fourth cycle.
  squareWords: (n) ->
    w = []
    hx = SQ_X + tri(n, SQ_H_TRAVEL)
    w = w.concat @glyphs(hx, SQ_Y, [SQ_GLYPH])
    vy = SQ_Y - tri(n, SQ_V_TRAVEL)
    w = w.concat @glyphs(SQ_X + SQ_H_TRAVEL, vy, [SQ_GLYPH])

    w

  # (13) the bug: sixteen lines in a sunburst about a centre that slides up
  # and to the right along the diagonal.
  bugWords: (n) ->
    w = []
    slide = tri(n, Math.floor(BUG_TRAVEL / BUG_STEP)) * BUG_STEP
    diag = Math.hypot(FCWD.AU_WIDTH, FCWD.AU_HEIGHT)
    bugX = BUG_X0 + slide * FCWD.AU_WIDTH / diag
    bugY = BUG_Y0 - slide * FCWD.AU_HEIGHT / diag
    spin = (n * BUG_SPIN) & ANGLE_MASK
    for i in [0...BUG_LINES]
      a = 2 * Math.PI * ((spin / FCWD.ANGLE_UNITS) + i / BUG_LINES)
      ca = Math.cos(a) ; sa = Math.sin(a)
      w = w.concat @line(bugX + BUG_R0 * ca, bugY - BUG_R0 * sa,
                         bugX + BUG_R1 * ca, bugY - BUG_R1 * sa)

    w

  # (14) AB and CD revolving in the annulus, and the X spinning at the
  # centre.  All three go clockwise, so with the screen's Y running down
  # the sine adds: at phase 0 the pair is to the right of the centre, at a
  # quarter turn it is below it.
  #
  # AB stay upright as they go round, and B leads A -- so B sits a half
  # separation ahead along the direction of travel, which for a clockwise
  # orbit is (-sin, +cos).  CD turns with the pattern instead, so that the
  # feet of the letters face the centre.  The first letter of each pair is
  # the large one.
  letterWords: (n) ->
    f = @f
    w = []
    ang = (n * LETTER_SPIN) & ANGLE_MASK
    turn = 2 * Math.PI * ang / FCWD.ANGLE_UNITS
    for [pair, phase] in [[['A', 'B'], 0], [['C', 'D'], Math.PI]]
      p = turn + phase
      cx = CIRCLE_CX + LETTER_ORBIT * Math.cos(p)
      cy = CIRCLE_CY + LETTER_ORBIT * Math.sin(p)
      tx = -Math.sin(p) ; ty = Math.cos(p)        # the way it is travelling
      # "the bottom of the letters is toward the center": the up vector
      # of the letter has to point radially out, at (cos p, sin p).
      rot = if pair[0] == 'C' then ROT_SIGN * (p + Math.PI / 2) else 0
      for g, k in pair
        s = if k == 0 then -1 else 1             # the large one trails
        w.push f.rotation(rot * 180 / Math.PI)
        w.push f.charMode({large: k == 0, rotated: rot != 0})
        w = w.concat @centred(cx + s * LETTER_PAIR * tx,
                              cy + s * LETTER_PAIR * ty, g)
    w.push f.rotation(ROT_SIGN * turn * 180 / Math.PI)
    w.push f.charMode({rotated: true})
    w = w.concat @centred(CIRCLE_CX, CIRCLE_CY, 'X')
    w.push f.rotation(0)
    w.push f.charMode({})

    w

  # (15) the boxed windmill.  The slope steps once a frame: 512 steps sweep
  # 45 degrees, and the axis the sweep runs on swaps every 512 so a full
  # quarter turn takes 1024.  Two lines at right angles, each drawn as two
  # half-lines so they can be clipped to the sides of the square.
  windmillWords: (n) ->
    w = []
    cx = BOX_X + BOX / 2 ; cy = BOX_Y + BOX / 2
    step = n % WINDMILL_CYCLE
    m = (step % WINDMILL_STEPS) / WINDMILL_STEPS      # the slope field, 0..1
    base = if step < WINDMILL_STEPS
      Math.atan(m)                                    # X major: tangent up
    else
      Math.PI / 2 - Math.atan(1 - m)                  # Y major: cotangent down
    for i in [0...4]
      a = base + i * Math.PI / 2
      [ex, ey] = @_boxRay(cx, cy, BOX_X, BOX_Y, BOX_X + BOX, BOX_Y + BOX, a)
      w = w.concat @line(cx, cy, ex, ey)

    w

  # The two diagonals, as endpoints clipped to the drawable area.  `sep` is
  # the perpendicular offset from the centre of the screen.
  _diagonal: (sep) ->
    dx = FCWD.AU_WIDTH ; dy = -FCWD.AU_HEIGHT       # up to the right
    len = Math.hypot(dx, dy)
    ux = dx / len ; uy = dy / len
    cx = FCWD.AU_WIDTH / 2 + sep * -uy              # the perpendicular
    cy = FCWD.AU_HEIGHT / 2 + sep * ux
    lo = -Infinity ; hi = Infinity
    for [c, u, min, max] in [[cx, ux, X_MIN + EDGE, X_MAX - EDGE],
                             [cy, uy, Y_MIN + EDGE, Y_MAX - EDGE]]
      if Math.abs(u) < 1e-9
        return [[cx, cy], [cx, cy]] if c < min or c > max
      else
        t0 = (min - c) / u ; t1 = (max - c) / u
        [t0, t1] = [t1, t0] if t0 > t1
        lo = Math.max(lo, t0) ; hi = Math.min(hi, t1)
    [[cx + ux * lo, cy + uy * lo], [cx + ux * hi, cy + uy * hi]]

  # Where a ray from the centre of the square meets its border.
  _boxRay: (cx, cy, x0, y0, x1, y1, a) ->
    dc = Math.cos(a) ; dr = -Math.sin(a)
    t = Infinity
    t = Math.min(t, (x1 - cx) / dc) if dc > 1e-9
    t = Math.min(t, (x0 - cx) / dc) if dc < -1e-9
    t = Math.min(t, (y1 - cy) / dr) if dr > 1e-9
    t = Math.min(t, (y0 - cy) / dr) if dr < -1e-9
    [cx + dc * t, cy + dr * t]
