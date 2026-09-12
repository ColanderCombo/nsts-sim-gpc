# The IDP/CRT SEL switches and the keyboards they route.
#
# JSC-11174,Vol.1,Rev.F dwg 8.3 "3 MEDS IDP": each keyboard's 32 switch lines
# go to the DED cards of two IDPs, the left keyboard's to IDP 1 and IDP 3 and
# the right keyboard's to IDP 3 and IDP 2; the aft keyboard's (panel R11L)
# go to IDP 4 alone.  The LEFT IDP/CRT SEL switch on panel C2 drives the
# IDP 1 KYBD SEL B and IDP 3 KYBD SEL A discretes, the RIGHT switch IDP 3
# KYBD SEL B and IDP 2 KYBD SEL A; an IDP takes keystrokes off a channel
# while its discrete is on.  USA-007587 sect.2.6, "IDP Switches": LEFT sits
# at 1 or 3, RIGHT at 2 or 3, and with both at 3 "keystrokes from both
# keyboards are interleaved".
#
# Keyboard busses are `_KYBD1` left, `_KYBD2` right, and `_KYBD3` aft.
# This module maps switch positions `{left, right}` to IDP lines `{A, B}`.

export LEFT = 1
export RIGHT = 2
export AFT = 3
export KYBD_NAME = {1: 'left', 2: 'right', 3: 'aft'}

WIRED = {
  1: {1: 'B'}
  2: {2: 'A'}
  3: {1: 'A', 2: 'B'}
  4: {3: 'A'}
}

export class IDPSel
  @LEFT: LEFT
  @RIGHT: RIGHT
  @AFT: AFT
  @LEFT_POSITIONS: [1, 3]
  @RIGHT_POSITIONS: [2, 3]
  @DEFAULT: {left: 1, right: 2}
  @WIRED: WIRED

  @selected: (idp, kybd, s) ->
    return false unless WIRED[idp]?[kybd]?
    switch kybd
      when LEFT then s.left == idp
      when RIGHT then s.right == idp
      else true

  @keyboardFor: (idp, s) ->
    for kybd of WIRED[idp] ? {}
      return Number(kybd) if @selected(idp, Number(kybd), s)
    null

  @wiredTo: (idp) -> (Number(k) for k of WIRED[idp] ? {})

  @channelOf: (idp, kybd) -> WIRED[idp]?[kybd] ? null

  @discretes: (idp, s) ->
    d = {A: false, B: false}
    for kybd, ch of WIRED[idp] ? {}
      d[ch] = true if @selected(idp, Number(kybd), s)
    d

  @selectedByLines: (idp, kybd, lines) ->
    ch = @channelOf(idp, kybd)
    ch? and !!lines[ch]

  @keyboardForLines: (idp, lines) ->
    for kybd, ch of WIRED[idp] ? {}
      return Number(kybd) if lines[ch]
    null
