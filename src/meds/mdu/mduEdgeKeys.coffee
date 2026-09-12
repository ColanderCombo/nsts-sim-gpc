import {call, setTimeout, clearTimeout} from '../../com/simRuntime.coffee'
$ = require('jquery')

import {KYBD} from 'meds/kybd'

# MDU edgekeys are F1..F6 (keyCodes 112..117). A key held longer than
# STUCK_MS is declared stuck: it is failed (red-X'ed via the fail callback)
# and ignored from then on. A normal press fires the handler on release.
STUCK_MS = 2000

export class MDUEdgeKeys
  constructor: () ->
    @failed = (false for [0..5])
    @downTimers = {}     # keyIdx -> pending stuck-detection timeout

    $(document).keydown (ev) =>
      return if KYBD.isEditable(ev.target)
      return unless ev.keyCode >= 112 and ev.keyCode <= 117
      ev.preventDefault()
      i = ev.keyCode - 112
      return if @failed[i]
      return if @downTimers[i]?      # already armed (OS key auto-repeat)
      @downTimers[i] = setTimeout call(@, '_stuck', i), STUCK_MS

    $(document).keyup (ev) =>
      return if KYBD.isEditable(ev.target)
      return unless ev.keyCode >= 112 and ev.keyCode <= 117
      ev.preventDefault()
      i = ev.keyCode - 112
      return if @failed[i]
      if @downTimers[i]?             # released in time -> a normal keypress
        clearTimeout @downTimers[i]
        delete @downTimers[i]
        @cb?(i)

    # Focus loss eats keyup events; cancel pending detections rather than
    # spuriously failing keys released while the window was not focused.
    $(window).on 'blur', () =>
      for i, t of @downTimers
        clearTimeout t
      @downTimers = {}

  _stuck: (i) ->
    delete @downTimers[i]
    @failed[i] = true
    @cbFail?(i)

  setHandler: (@cb, @cbFail=undefined) ->
