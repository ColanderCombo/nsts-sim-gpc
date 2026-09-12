import * as THREE from 'three'

# JSC-48025/p.230
#
#          PERFORM IDP SELF-TEST
#
# MDU      52. MAIN MENU:MEDS MAINT:CST:START IDP
#                √MEDS MAINT DISPLAY appears on MDU
#                √“IDP 1 (2,3) INTERACTIVE CST” appears on
#                   bottom of screen
# C2       53. L(R) IDP/CRT SEL sw – 1(2,3) (IFM’ed IDP)
# MDU      54. √All KYBD entries echoed next to “KEYSTROKE:”
#                on lower RH corner of display by pressing each
#                key on KYBD 
#          If IDP 3 C/O:
# C2             55. R(L) IDP/CRT SEL sw – 3 (alt KYBD)
#                    Repeat step 54 w/alt KYBD
#          56. L(R) IDP/CRT SEL sw (both) – (non IFM’ed IDP)
#              √“ACTIVE KYBD:” blank on bottom middle of
#                display
# O6       57. IDP 1(2,3) LOAD – LOAD
#             √“IDP LOAD: LOAD” on bottom left of display
# MDU      58. MAIN MENU:MEDS MAINT: CST:START
#               IDP:HW CST
#                Expect ‘I/O ERROR CRT 1(2,3)’ msg
#                Wait up to 60 sec
#               √IDP 1(2,3) box, rows 2,3 show all zeroes 
#
import * as machina from 'machina'

import {MDUScreen} from 'meds/mduScreen'

export class Screen_IDP_CST extends MDUScreen
  setData: (@curData) ->
    if not @curData?
      @curData = {
        majorFunc: 'GNC'
        idpLoad: ''
        activeKybd: '2'
        keystroke: ''
        leftIdpSel: '1'
        rightIdpSel: '3'
        kybdSelA: 'OFF'
        kybdSelB: 'ON'
      }
    @draw()

  data: () ->
    return @curData

  build: () ->
    @group = new THREE.Object3D()

  draw: () ->
    if not @curData?
      @setData()
    if @txt?
      @group.remove @txt
      @txt.traverse (o) -> o.geometry?.dispose()
    @txt = new THREE.Object3D()
    c = @curData
    @txt.add @d.str  6,28,"MAJOR FUNC:#{c.majorFunc}",      @d.c2h.white, scale=.75,advance=.75
    @txt.add @d.str  6,29,"IDP LOAD  :#{c.idpLoad}",        @d.c2h.white, scale=.75,advance=.75
    @txt.add @d.str 10.5,30,"ACTIVE KYBD:#{c.activeKybd}",  @d.c2h.white, scale=.75,advance=.75
    @txt.add @d.str 25,30,"KEYSTROKE:#{c.keystroke}",       @d.c2h.white, scale=.75,advance=.75
    @txt.add @d.str 18,28,"LEFT IDP SEL:#{c.leftIdpSel}",   @d.c2h.white, scale=.75,advance=.75
    @txt.add @d.str 18,29,"RIGHT IDP SEL: #{c.rightIdpSel}",@d.c2h.white, scale=.75,advance=.75
    @txt.add @d.str 32,28,"KYBD SEL A:#{c.kybdSelA}",       @d.c2h.white, scale=.75,advance=.75
    @txt.add @d.str 32,29,"KYBD SEL B:#{c.kybdSelB}",       @d.c2h.white, scale=.75,advance=.75
    @group.add @txt

  _handle_CST_test: (state) ->
    fillMat = (color) ->
      new THREE.MeshBasicMaterial({color: color, side: THREE.DoubleSide})
    switch state
      when 'mdu_cst_blank'
        @d.add @d.box 0,0,53,36.25, undefined, fillMat(@d.c2h.black)
      when 'mdu_cst_red'
        @d.add @d.box 0,0,53,36.25, undefined, fillMat(@d.c2h.red)
      when 'mdu_cst_green'
        @d.add @d.box 0,0,53,36.25, undefined, fillMat(@d.c2h.green)
      when 'mdu_cst_blue'
        @d.add @d.box 0,0,53,36.25, undefined, fillMat(@d.c2h.blue)
      when 'mdu_cst_white'
        @d.add @d.box 0,0,53,36.25, undefined, fillMat(@d.c2h.white)
      when 'mdu_cst_test'
        @d.add @d.box 0,0,53,36.25, undefined, fillMat(@d.c2h.black)

  seq_mdu_selftest: () ->
    #
    # JSC-48025/p.246
    #
    #         PERFORM MDU SELF-TEST
    #
    #         MDU     48. MAIN MENU:MEDS MAINT:CST:START MDU
    #
    #                                NOTE
    #                     Expect “MEDS I/O ERROR” msg
    #                     annunciated for affected MDU.
    #                     Do not perform MEDS MSG
    #                     RST(ACK) until CST complete
    #
    #                 49. Verify following displays appeared for ~10 sec
    #                      each:
    #                     a. Blank
    #                     b. All red
    #                     c. All Green
    #                     d. All Blue
    #                     e. All White
    #                     f. Graphics Test Pattern 
    # 
    #                                   NOTE
    #                   During next step, pressing an edgekey
    #                   twice will cause CST to fail
    #
    #                50. Verify white dots appear above each edgekey
    #                    Press,release each edgekey
    #                    Verify white dot above edgekey disappears
    #                51. Wait until system status display appears
    #                    Check affected MDU line 6 of SYSTEM
    #                     STATUS = 0000FF
    #                52. Reconfig MEDS as desired
    #                     √NEG viewing angle
    #                     √FC Bus assignment
    #                     √MDU Port assignment 
    #  

    mdu = @

    console.log 'seq_mdu_selftest'
    @sequence = new machina.Fsm {
      initialState: 'STEP_1'
      states: {
        STEP_1: {
          _onEnter: () ->
            mdu.curDisplay = "mdu_cst_blank"
            mdu.draw()
            @timer = setTimeout (() => @transition("STEP_2")), 10000
        }
        STEP_2: {
          _onEnter: () ->
            mdu.curDisplay = "mdu_cst_red"
            mdu.draw()
            @timer = setTimeout (() => @transition("STEP_3")), 10000
        }
        STEP_3: {
          _onEnter: () ->
            mdu.curDisplay = "mdu_cst_green"
            mdu.draw()
            @timer = setTimeout (() => @transition("STEP_4")), 10000
        }
        STEP_4: {
          _onEnter: () ->
            mdu.curDisplay = "mdu_cst_blue"
            mdu.draw()
            @timer = setTimeout (() => @transition("STEP_5")), 10000
        }
        STEP_5: {
          _onEnter: () ->
            mdu.curDisplay = "mdu_cst_white"
            mdu.draw()
            @timer = setTimeout (() => @transition("STEP_6")), 10000
        }
        STEP_6: {
          _onEnter: () ->
            mdu.curDisplay = "mdu_cst_test"
            mdu.draw()
            @timer = setTimeout (() => @transition("STEP_7")), 10000
        }
        STEP_7: {
          _onEnter: () ->
            mdu.curDisplay = "Maint"
            mdu.draw()
        }
      }
    }
