import * as THREE from 'three'
#
# USA-007587/p.250
#
# MEDS Generic Screen Format
#
# Each MDU screen follows a generic screen format. The top portion of
# the screen is denoted as the MEDS display format. The lower portion
# contains the MEDS internal configuration information. A horizontal
# cyan line separates the two portions. The upper portion is blank or
# displays the selected MEDS display. At the bottom, the legends for the
# edgekeys are displayed in the six boxes that are aligned with their
# respective edgekeys. The color of the boxes and the labels normally
# are cyan, unless they correspond to the current MEDS display, in which
# case they are white. A blank edgekey legend means no option is
# available for that edgekey. If the edgekey is pressed, the IDP ignores
# it. The menu title is displayed above the edgekey boxes and legend.
# The MEDS fault message line is the line above the menu title. Any
# MEDS-generated messages are displayed in white on this line. Any GPC
# generated messages are displayed on the DPS display in orange (above
# the cyan horizontal line).
#
# MEDS configuration information is displayed to the left and the right
# of the menu bars. The information to the left indicates which MDU port
# is selected and which IDP is connected to each MDU port. “P” indicates
# primary port and “S” indicates the secondary port. The numbers next to
# the P and S indicate the IDP that is connected to that port of the
# MDU. An asterisk indicates which port (and thus which IDP) is selected
# to command the MDU. The infor- mation displayed to the right of the
# menu bars indicates the port select configuration and flight-critical
# data bus selected for that MDU. The flight-critical data bus selected
# is the number displayed next to “FC.” The port reconfiguration mode is
# displayed below the flight critical data bus information. “AUT” is
# displayed when automatic port reconfiguration capability has been
# selected and “MAN” is displayed when manual reconfiguration capability
# has been selected. Each MDU retains its current configuration through
# a power cycle (except for the menu, which reverts to the menu
# associated with the display on the MDU).
# 

export class MDUMenuArea
  constructor: (@d,@CONFIG={}) ->
    @menuItemTxt = []
    @edgekeyFailed = [false, false, false, false, false, false]

  setData: (@data) ->
    @priPortIDP = @data.priPortIDP
    @secPortIDP = @data.secPortIDP
    @cmdPort = @data.cmdPort
    @flightCritBus = @data.flightCritBus
    @portReconfigureModeAuto = @data.portReconfigureModeAuto
    @modNegView = @data.modeNegView
    @faultLineMsg = @data.faultLineMsg
    @curIDP = @data.curIDP

  setFaultLine: (msg,blink=true) ->
    if msg != @faultLineMsg or blink != @faultLineBlink
      @group.remove @faultLine
      @faultLineMsg = msg
      @faultLineBlink = blink
      # TODO: implement blink support for fault line text
      color = @d.c2h.white
      @faultLine = @d.str(3,32,@faultLineMsg, color,1,.9)
      @group.add @faultLine
      @d.dirty = true

  setCurPort: (newCmdPort) ->
    if newCmdPort != @cmdPort
      @cmdPort = newCmdPort
      @mduStatGrp.remove @curIDPStarP
      @mduStatGrp.remove @curIDPStarS
      if @cmdPort == 0
        @mduStatGrp.add @curIDPStarP
      else if @cmdPort == 1
        @mduStatGrp.add @curIDPStarS
      @d.dirty = true

  # single draw path for the FC bus status label — build() and later bus
  # changes must render identically (position, advance, colour)
  _drawFCBusLabel: () ->
    if @FCBusLabel?
      @mduStatGrp.remove @FCBusLabel
      @FCBusLabel.traverse (o) -> o.geometry?.dispose()
    @FCBusLabel = @d.strCond 49.75,34.15, "FC#{@flightCritBus}", @d.c2h.cyan, 1.0, 0.85
    @mduStatGrp.add @FCBusLabel
    @d.dirty = true

  setFCBus: (newFlightCritBus) ->
    if newFlightCritBus != @flightCritBus
      @flightCritBus = newFlightCritBus
      @_drawFCBusLabel()

  setNegView: (newMduModeNegView) ->
    if newMduModeNegView != @mduModeNegView
      @mduStatGrp.remove @mduModeNegView
      if @modeNegView == true
        @mduStatGrp.add @mduModeNegView
      @d.dirty = true

  setReconfModeAuto: (newReconfModeAuto) ->
    console.log "setReconfModeAuto", newReconfModeAuto, @portReconfigureModeAuto
    if newReconfModeAuto != @portReconfigureModeAuto
      @mduStatGrp.remove @mduReconfigAut
      @mduStatGrp.remove @mduReconfigMan
      @portReconfigureModeAuto = newReconfModeAuto
      if @portReconfigureModeAuto == true
        @mduStatGrp.add @mduReconfigAut
      else
        @mduStatGrp.add @mduReconfigMan
      @d.dirty = true

  setCurrentMenu: (@currentMenu) ->
    title = @currentMenu.title

    @group.remove @menuTitle
    adv = 8/9                                         # title ~8/9 its former width
    tx = 13.90                                         # ~5 chars left of the old 'SUBSYS STATUS'-aligned spot
    ty = 33.16
    if title.trim() == 'SUBSYSTEM MENU'   # SUBSYSTEM MENU: right ~3 cells, down ~1px
      tx += 3 - 0.15
      ty += 0.05
    # grow slightly, anchored bottom-left (y up to keep the baseline in place)
    @menuTitle = @d.str(tx, ty, title, @d.c2h.cyan, 1.05, adv+0.007, 0.91)
    @group.add @menuTitle

    # a new menu starts with no active edgekey: the highlight belongs to a
    # selection made *within* this menu (setCurrentDisplay passes it back)
    prev = @activeMenuItem
    @activeMenuItem = null
    @_drawKeyBox(prev) if prev?
    for i in [0..5]
      @_drawKeyItem(i)

  # colour rule: the edgekey for the currently active page is white (text and
  # frame); every other edgekey is cyan
  _keyColor: (i) ->
    if i == @activeMenuItem then @d.c2h.white else @d.c2h.cyan

  _drawKeyBox: (i) ->
    if @menuBoxGeo[i]?
      @menuGrp.remove @menuBoxGeo[i]
      @menuBoxGeo[i].traverse (o) -> o.geometry?.dispose()
    [xl, xr] = @menuBoxX[i]
    @menuBoxGeo[i] = @d.line [
                    [xl,36.2]
                    [xl,34.30]
                    [xr,34.30]
                    [xr,36.2]], @_keyColor(i)
    @menuGrp.add @menuBoxGeo[i]
    @d.dirty = true

  _drawKeyItem: (i) ->
    return if not @currentMenu?
    if @menuItemTxt[i]?
      @group.remove @menuItemTxt[i]
      @menuItemTxt[i].traverse (o) -> o.geometry?.dispose()
    @menuItemTxt[i] = @buildMenu i, @currentMenu[i].keyTitle, @_keyColor(i)
    @group.add @menuItemTxt[i]
    @d.dirty = true

  setActiveMenuItem: (i) ->
    return if not i? or i == @activeMenuItem
    prev = @activeMenuItem
    @activeMenuItem = i
    for k in [prev, i] when k?
      @_drawKeyBox(k)
      @_drawKeyItem(k)

  setEdgekeyFailed: (key,failed=true) ->
    # Other indications of loss of communication between the IDP and
    # GPC are the big “X” and POLL FAIL (Figure 3-48). Big “X”
    # appears when the IDP does not receive display update data for
    # 3 seconds. POLL FAIL appears in the lower right-hand corner
    # when the IDP does not receive poll or time update commands for
    # 3 seconds. Although they normally serve to indicate a problem,
    # both of these are also displayed whenever a powered IDP is not
    # assigned to any GPC (not a failure indication).
    #   
    @edgekeyFailed[key] = failed
    for i in [0..5]
      if @edgekeyFailed[i]
        @group.add @menuRedXs[i]
      else
        @group.remove @menuRedXs[i]
    @d.dirty = true

  build: () ->
    @group = new THREE.Object3D(name="MDUMenuArea")#"
    # return @group

    # Dividing line between app area and menu area:
    # @group.add @d.line [[0, 31.70], [53, 31.70]], @d.c2h.cyan
    @group.add @d.line [[0, 32.2], [53, 32.2]], @d.c2h.cyan

    @faultLine = @d.str(3,32,@faultLineMsg,@d.c2h['white'],1,.9) #BLINK
    @group.add @faultLine

    @menuGrp = new THREE.Object3D()
    @menuBoxX = []              # per-key frame x extents
    @menuBoxGeo = []            # per-key frame geometry (rebuilt on active change)
    @menuRedXs = []
    for x in [0..5]
      x0 = 3.3 + x*7.75
      x0 += 0.05 if x >= 3        # right 3 edgekey boxes: right ~1px
      lo = 0.10 ; ro = 7.40       # per-box left/right side offsets
      ro = 7.45 if x == 3         # 4th edgekey: right side +1px
      if x == 4                   # 5th edgekey: both sides +2px
        lo = 0.20 ; ro = 7.50
      lo = 0.20 if x == 5         # 6th edgekey: left side +2px
      @menuBoxX.push [x0+lo, x0+ro]
      @menuBoxGeo.push null
      @_drawKeyBox(x)
      redX = new THREE.Object3D()
      redX.add @d.line([[x0+lo, 36.2], [x0+ro, 34.30]], @d.c2h['red'])
      redX.add @d.line([[x0+lo, 34.30], [x0+ro, 36.2]], @d.c2h['red'])
      redX.position.set(0,0,-0.99)
      # redX.position.set(0,0,1)
      @menuRedXs.push redX
    @group.add @menuGrp

    SADV = 0.85                                       # slightly narrower spacing for edgekey status labels
    @mduStatGrp = new THREE.Object3D()
    @mduStatGrp.add @d.strCond 0.41, 34.185, "P#{@priPortIDP}", @d.c2h.cyan, 1.0, SADV
    if @secPortIDP?
      @mduStatGrp.add @d.strCond 0.41, 35.185, "S#{@secPortIDP}", @d.c2h.cyan, 1.0, SADV
    @curIDPStarP = @d.strCond 2.15,34.15,"*"
    @curIDPStarS = @d.strCond 2.15,35.15,"*"
    @FCBusLabel = null
    @_drawFCBusLabel()
    @mduReconfigAut = @d.strCond 49.75,35.11, "AUT", @d.c2h.cyan, 1.0, SADV
    @mduReconfigMan = @d.strCond 49.75,35.11, "MAN", @d.c2h.cyan, 1.0, SADV
    if @portReconfigureModeAuto == true
      @mduStatGrp.add @mduReconfigAut
    else
      @mduStatGrp.add @mduReconfigMan
    @mduModeNegView = @d.strCond 44.5,33,'NEG VIEW'
    if @modeNegView == true
      @mduStatGrp.add @mduModeNegView

    @group.add @mduStatGrp

    # Background-coloured fill for the menu strip: masks display geometry
    # (e.g. the PFD) that bleeds into the menu area. Drawn in the bg colour and
    # behind every menu element (labels, boxes, red-Xs at z -0.99) so they show.
    menuMask = new THREE.PlaneGeometry(52, 5)
    matMenuMask = new THREE.MeshBasicMaterial {side:THREE.DoubleSide, wireframe:false, color:@d.c2h.black}
    mMenuMask = new THREE.Mesh(menuMask, matMenuMask)
    mMenuMask.position.set(25.5,34.5,-1.0)
    maskGroup = new THREE.Object3D(name="maskGroup")#"
    maskGroup.add mMenuMask
    @group.add maskGroup

    @group.position.set(0,0.307,-0.9)   # menu area down (was 0.27, +1px)

    @d.add [@group]

  buildMenu: (i,s,color) ->
    txtGrp = new THREE.Object3D("menuTxt")

    x = 3 + i*7.9
    strs = s.split('\n')
    if strs.length == 1
      strs = [strs[0], ""]
    edx = 0.32 ; edy = 0.11        # nudge all edgekey titles right ~6px, down ~2px
    if strs[0] == 'UP'
      txtGrp.add @d.arrow x
      txtGrp.add @d.str x+3+edx-0.22, 34.6+edy, "UP", color   # UP text left ~3px
    else
      xup = 3 + i*8
      if i == 1                # FLT INST: right ~1 cell
        xup = xup + 1
      if i == 2                # SUBSYS STATUS: right ~0.48 cell
        xup = xup + 0.48
      if i == 3                # DPS: right ~2px
        xup = xup + 0.10
      if i == 4
        xup = Math.floor(xup)
      if i == 5
        xup = xup-0.5
      if strs[0] == 'OMS/ '    # OMS/MPS: left ~3px
        xup = xup - 0.22
      if strs[0] == 'PORT'     # PORT SELECT: left ~4px
        xup = xup - 0.29
      eadv = 0.92              # slightly tighter edgekey-title spacing
      eyi = if i == 2 then -0.01 else 0   # SUBSYS STATUS up ~1px more than the others
      if strs[0]
        ctr = (6-strs[0].length)/2
        txtGrp.add @d.strCond xup+ctr+edx,34.25+edy+eyi,strs[0], color, 1.0, eadv
      if strs[1]
        ctr = (6-strs[1].length)/2
        txtGrp.add @d.strCond xup+ctr+edx,35.32+edy+eyi,strs[1], color, 1.0, eadv
    
    return txtGrp


  # updateTouchbarMenu: () ->
  #   if not @CONFIG.
  # enableTouchbar
  #       return
  #   @remote = require('electron').remote
  #   TouchBar = @remote.TouchBar
  #   menu = []
  #   for i in [0..5]
  #     cc = (t) ->
  #     if @currentMenu[i].action?
  #       cc = @currentMenu[i].action
  #     else if @currentMenu[i].link?
  #       do (i) -> cc = (t) -> t.setCurrentMenu t.currentMenu[i].link

  #     do (i,cc) =>
  #       menu.push new TouchBar.TouchBarButton {
  #         label: @currentMenu[i].keyTitle or " "
  #         labelColor: "#00ffff",
  #         click: () => cc(@); @draw()
  #       }
  #   @tb = new TouchBar menu
  #   @remote.getCurrentWindow().setTouchBar @tb

  # makeKybd: () ->
  #   if not @CONFIG.enableTouchbar
  #       return
    
  #   @remote = require('electron').remote
  #   TouchBar = @remote.TouchBar
  #   @kybd = [
  #     new (TouchBar.TouchBarButton)({label: "UP",labelColor:"00ffff", click: () -> @cmdHOME() }),
  #     new (TouchBar.TouchBarButton)({label: " ", labelColor: "00ffff", click: () -> @cmdXMIT() }),
  #     new (TouchBar.TouchBarButton)({label: " ", labelColor: "00ffff", click: () -> @cmdXMIT() }),
  #     new (TouchBar.TouchBarButton)({label: " ", labelColor: "00ffff", click: () -> @cmdEXEC() }),
  #     new (TouchBar.TouchBarButton)({label: "MEDS MSG RST", label3Color: "00ffff", click: () -> @cmdXMIT() }),
  #     new (TouchBar.TouchBarButton)({label: "MEDS MSG ACK", label3Color: "00ffff", click: () -> @cmdXMIT() }),
  #   ]
  #   @tb = new TouchBar(@kybd)
  #   w = @remote.getCurrentWindow()
  #   w.setTouchBar @tb
