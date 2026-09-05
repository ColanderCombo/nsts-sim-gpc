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
# The keyboard busses are the switch lines: _KYBD1 the left keyboard, _KYBD2
# the right, _KYBD3 the aft.  The _IDPSW bus carries the two switch
# positions as three words, a tag and then LEFT and RIGHT.  STATE goes out
# on every change and in answer to a QUERY, which an MDU sends when it
# opens; an IDP answers.

import {BusMsg} from './../com/bus.civet.jsx'

export LEFT = 1
export RIGHT = 2
export AFT = 3
export KYBD_NAME = {1: 'left', 2: 'right', 3: 'aft'}

# The keyboards wired to each IDP, with the channel each comes in on.
WIRED = {
  1: {1: 'B'}
  2: {2: 'A'}
  3: {1: 'A', 2: 'B'}
  4: {3: 'A'}
}

export TAG = {STATE: 0x0001, QUERY: 0x0002}

export class IDPSel
  @LEFT: LEFT
  @RIGHT: RIGHT
  @AFT: AFT
  @LEFT_POSITIONS: [1, 3]
  @RIGHT_POSITIONS: [2, 3]

  # Whether the switches put keyboard `kybd` on IDP `idp`.
  @selected: (idp, kybd, s) ->
    return false unless WIRED[idp]?[kybd]?
    switch kybd
      when LEFT then s.left == idp
      when RIGHT then s.right == idp
      else true

  # The keyboard IDP `idp` is taking keystrokes from, or null.  With both
  # forward switches at 3, the left one.
  @keyboardFor: (idp, s) ->
    for kybd of WIRED[idp] ? {}
      return Number(kybd) if @selected(idp, Number(kybd), s)
    null

  # The keyboards hardwired to IDP `idp`, selected or not.
  @wiredTo: (idp) -> (Number(k) for k of WIRED[idp] ? {})

  # The KYBD SEL A and B discretes IDP `idp` sees.
  @discretes: (idp, s) ->
    d = {A: false, B: false}
    for kybd, ch of WIRED[idp] ? {}
      d[ch] = true if @selected(idp, Number(kybd), s)
    d

  @encode: (tag, s) ->
    msg = new BusMsg(3)
    msg.data16[0] = tag
    msg.data16[1] = s.left
    msg.data16[2] = s.right
    msg

  # {tag, left, right} off the bus, or null for anything else.
  @decode: (words) ->
    return null unless words.length >= 3
    tag = words[0] & 0xffff
    return null unless tag == TAG.STATE or tag == TAG.QUERY
    {tag: tag, left: words[1] & 0xffff, right: words[2] & 0xffff}

  constructor: (@bus = null, {@answers = false} = {}) ->
    @left = 1
    @right = 2
    @_cbs = []
    @bus?.onReceive @_recv, @

  state: () -> {left: @left, right: @right}

  onChange: (cb) -> @_cbs.push cb

  set: (left, right) ->
    return false unless left in IDPSel.LEFT_POSITIONS and right in IDPSel.RIGHT_POSITIONS
    return false if left == @left and right == @right
    @left = left
    @right = right
    @_announce()
    @_notify()
    true

  toggleLeft: () -> @set (if @left == 1 then 3 else 1), @right
  toggleRight: () -> @set @left, (if @right == 2 then 3 else 2)

  query: () -> @_send TAG.QUERY
  _announce: () -> @_send TAG.STATE

  _send: (tag) ->
    return unless @bus?
    @bus.sendMsg IDPSel.encode(tag, @state())

  _notify: () ->
    cb(@state()) for cb in @_cbs
    return

  # Bus calls the handler as (cbObj, busID, msg, remote).
  _recv: (t, busID, msg, remote) -> t._onMsg msg.data16

  _onMsg: (words) ->
    d = IDPSel.decode(words)
    return unless d?
    if d.tag == TAG.QUERY
      @_announce() if @answers
      return
    return unless d.left in IDPSel.LEFT_POSITIONS and d.right in IDPSel.RIGHT_POSITIONS
    return if d.left == @left and d.right == @right
    @left = d.left
    @right = d.right
    @_notify()
