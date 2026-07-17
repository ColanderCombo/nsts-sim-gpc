import * as THREE from 'three'
import {MDUScreen} from 'meds/mduScreen'

export class Screen_AUTONOMOUS extends MDUScreen
  build: () ->
    @group = new THREE.Object3D()
    # @group.add @d.line [[0, 32.15], [53, 32.15]], @d.c2h.cyan
    # @group.add @d.line [[25, 10], [25, 15]], @d.c2h.cyan

    @group.add @d.str 18,15,"MDU IS AUTONOMOUS", @d.c2h.red
    @geo_msg = null
    @_drawMsg()

  # which port(s) timed out — the MDU updates this while autonomous.
  # Returns true when the displayed message changed (caller redraws).
  setTimeouts: (pri, sec) ->
    return false if pri == @priTimeout and sec == @secTimeout
    @priTimeout = pri
    @secTimeout = sec
    @_drawMsg() if @group?
    return true

  _drawMsg: () ->
    if @geo_msg?
      @group.remove @geo_msg
    msg =
      if @priTimeout and @secTimeout then "Pri/Sec Port Timeout"
      else if @secTimeout then "Sec Port Timeout"
      else "Pri Port Timeout"
    # center under the AUTONOMOUS line ("Pri/Sec..." spans cols 15-35)
    x = Math.round(15 + (20 - msg.length)/2)
    @geo_msg = @d.str x,17, msg, @d.c2h.red
    @group.add @geo_msg
