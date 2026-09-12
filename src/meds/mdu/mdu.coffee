import {call, registerType, setTimeout, clearTimeout, now as simNow} from '../../com/simRuntime.coffee'
import * as THREE from 'three'
registerType(Type) for _, Type of THREE when typeof Type == 'function' and Type.prototype?
# Rebuild graphics objects with their constructor-owned callbacks intact.
for name in ['Object3D', 'Scene', 'Group', 'Mesh', 'Line', 'LineSegments',
             'Vector2', 'Vector3', 'Vector4', 'Euler', 'Quaternion', 'Matrix3', 'Matrix4',
             'Color', 'BufferGeometry', 'ShaderMaterial', 'MeshBasicMaterial',
             'OrthographicCamera', 'PerspectiveCamera', 'Sphere', 'Box3', 'Layers']
  do (name) -> registerType(THREE[name], -> new THREE[name]())
import { createRoot } from 'react-dom/client'
import React from 'react'
# Do not mount an @react-three/fiber Canvas here: its renderer changes
# THREE.ColorManagement.enabled after screen materials have been built,
# causing rebuilt fills to use different colors.



import 'cde/cde-window'
import 'meds/mdu/style.css'
import {LRU} from '../../com/lru.civet.jsx'
import {Bus, BusMsg} from '../../com/bus.civet.jsx'

import {MEDSConf, MDUMsg, MDUMsgName, powerFeedsOf} from 'meds/medsConf'
import {sameField} from 'meds/mdu/mduScreen'
import {decodeMduAdc} from 'meds/idp/idpAdc'
import {decodeMduFc} from 'meds/idp/idpFc'
import {wordToVolts} from '../../lru/adc/adcConf'
import {fieldsOfPair} from '../../lru/adc/adcChannels'
import {fieldsOfFeed, STATION_DDU} from '../../lru/ddu/dduFields'
import {DDU_OF_IUA} from '../../lru/ddu/dduConf'
import * as DEU from 'meds/deu/deuProto'
import {VectorDisplay} from 'meds/mdu/mduVectorDisplay'
import {MDUMenuArea} from 'meds/mdu/mduMenuArea'
import {MDUEdgeKeys} from 'meds/mdu/mduEdgeKeys'
import {KYBD} from 'meds/kybd'
import {IDPSel} from 'meds/idp/idpSel'
import {IDPPanel} from 'meds/idp/idpDiscretes'
import Menus from 'meds/mdu/mduMenu'

ScreenMods = {
  'AE_PFD' : await import('./mduScreen_AE_PFD'),
  'AUTONOMOUS' : await import('./mduScreen_AUTONOMOUS'),
  'DPS' : await import('./mduScreen_DPS'),
  'FAULT_SUMM' : await import('./mduScreen_FAULT_SUMM'),
  'FILE_PATCH' : await import('./mduScreen_FILE_PATCH'),
  'HYD_APU' : await import('./mduScreen_HYD_APU'),
  'IDP_CST' : await import('./mduScreen_IDP_CST'),
  'MAINT' : await import('./mduScreen_MAINT'),
  'OMS_MPS' : await import('./mduScreen_OMS_MPS'),
  'ORBIT_PFD' : await import('./mduScreen_ORBIT_PFD'),
  'SPI' : await import('./mduScreen_SPI'),
}


for _, mod of ScreenMods
  registerType(Type) for _, Type of mod when typeof Type == 'function' and Type.prototype?

export class MDU extends LRU
  Menus: Menus

  constructor: (CONFIG) ->
    config = MEDSConf.mdus[CONFIG.config.lru]
    priPortIDP = secPortIDP = null
    if config.dataBus.P
      priPortIDP = Number(config.dataBus.P[-1...])
    if config.dataBus.S
      secPortIDP = Number(config.dataBus.S[-1...])

    lruConfig = {
      id: CONFIG.config.lru
      nom: "MEDS MDU"
      busses: []
      # A control bus works the unit's remote power controller and a main
      # bus comes through it: medsConf's `powerBus`, both needed.
      power: powerFeedsOf(config.powerBus)
      powerRule: 'all'
    }
    
    lruConfig.busses[0] = "_IDP#{priPortIDP}"
    if secPortIDP?
      lruConfig.busses[1] = "_IDP#{secPortIDP}"
    super(lruConfig)

    # The IDP/CRT SEL switches: the IDPs hold the lines they make, and the
    # panel reads the positions back from them.
    @panel = new IDPPanel(onChange: => @_selChanged())
    @panel.query()

    @screenMods = ScreenMods
    @_pollWatchdog = null        # POLL FAIL: re-armed by the GPC's poll/clock
    @_updateWatchdog = null      # big "X": re-armed by a display update
    @_idpWatchdog = null         # the port: re-armed by the IDP's heartbeat
    @_idpWatchdogSec = null
    # Initially alive so the watchdog can report the first silence.
    @_idpUp = true
    @_secTimedOut = false
    @CONFIG = CONFIG
    @config = config
    @priPortIDP = priPortIDP
    @secPortIDP = secPortIDP
    @lruConfig = lruConfig

    @bus["_IDP#{@priPortIDP}"].onReceive @recvFromPri, @
    if @secPortIDP?
      @bus["_IDP#{@secPortIDP}"].onReceive @recvFromSec, @

    @curBus = @bus["_IDP#{@priPortIDP}"]

    @mduConfig = {
      priPortIDP: @priPortIDP
      secPortIDP: @secPortIDP
      cmdPort: 1
      flightCritBus: @flightCritBus
      modeNegView: false
      portReconfigureModeAuto: true
    }

    @cmdPort = 0
    @flightCritBus = 3
    @majorFunc = DEU.MAJOR_FUNC_NAME[DEU.MAJOR_FUNC_DEFAULT]
    @portReconfigureModeAuto = false
    @modeNegView = false

    @faultLineMsg = ""
    @curDisplay = "BLANK"

    @dps_big_x = true
    @dps_poll_fail = true
    @dps_otp = false           # ...and the test page hides the "X" while it
                               # stands; see `_otpPage`

    @_edgeKeys = new MDUEdgeKeys()
    @_edgeKeys.setHandler(@handleEdgekey, @handleEdgekeyFail)

    # The subsystem display fields the commanding IDP's ADC frames gave,
    # by screen name, and the screens whose picture is behind them.
    @adcFeed = {}
    @_adcDirty = {}
    @_adcTimer = null

    # The flight instrument data heard on each FC bus: by bus number, the
    # words of each message as last heard (lru/ddu/dduConf MSG), for this crew
    # station's DDU and the MEDS transfer.  The PFD screens follow the bus
    # the DATA BUS edgekey selects.
    @station = config.station
    @fcFeed = {}
    @fcHeard = {}
    @fcFields = null
    @_fcFieldsJson = null
    @_fcDirty = false
    @_fcTimer = null
    @_fcWatchdog = null


  beforeRestoreDstore: ->
    # Rebuilt pages may need different vertex-buffer sizes.
    seen = new Set()
    release = (object) ->
      geometry = object.geometry
      if geometry? and not seen.has(geometry)
        seen.add(geometry)
        geometry.dispose()
    @disp?.scene?.traverse(release)
    screen.group?.traverse(release) for _, screen of @screens ? {}
    return

  afterRestoreDstore: ->
    @disp?.scene?.traverse (object) ->
      for _, attribute of object.geometry?.attributes ? {}
        attribute.needsUpdate = true
      materials = if Array.isArray(object.material) then object.material else [object.material]
      material.needsUpdate = true for material in materials when material?
      return
    if @disp?
      @disp.dirty = true
      @disp.render()
    return

  start: () ->
    @disp = new VectorDisplay(@CONFIG)
    @mdu_menuArea = new MDUMenuArea @disp, @CONFIG
    @updateMduData()
    @mdu_menuArea.build()

    @screens = {}
    globalThis["mdu#{@id}"] = @

    @mdu_menuArea.setCurPort(@cmdPort)
    @mdu_menuArea.setFCBus(@flightCritBus)
    @mdu_menuArea.setNegView(@modeNegView)
    @mdu_menuArea.setReconfModeAuto(@portReconfigureModeAuto)

    @setCurrentMenu(@CONFIG.init.menu)
    @setCurrentDisplay(@CONFIG.init.display)

    @watchIDP()
    @redraw()

    @kybd = new KYBD(@, @panel)

    document.addEventListener 'dblclick', (ev) => @_toggleParamEditor(ev)

  windowTitle: () ->
    "MDU / #{@CONFIG.config.lru} (#{@majorFunc})"

  setMajorFunc: (name) ->
    @majorFunc = name
    document.querySelector('cde-window')?.title = @windowTitle()
    @redraw()

  initWindow: () ->
    console.log("MDU initWindow")
    <cde-window title={@windowTitle()} resizable="false" hasFrame={not @CONFIG.window.fullscreen}>
    </cde-window>

  commandingIDP: () ->
    if @cmdPort == 1 and @secPortIDP? then @secPortIDP else @priPortIDP

  # The keyboard bars beside the IDP box on the DPS display, USA-007587
  # sect.2.6: red on the left while the commander's keyboard is switched to
  # the IDP whose display this is, yellow on the right for the pilot's.
  # IDP 4's display has neither.
  kybdBars: () ->
    idp = @commandingIDP()
    lines = @panel.lines(idp)
    left = IDPSel.selectedByLines(idp, IDPSel.LEFT, lines)
    right = IDPSel.selectedByLines(idp, IDPSel.RIGHT, lines)
    if left and right then 'both' else if left then 'left' else if right then 'right' else null

  # The IDP self-test page's switch fields, for the commanding IDP.
  idpCstData: (cur) ->
    idp = @commandingIDP()
    s = @panel.positions()
    d = @panel.lines(idp)
    Object.assign {}, cur, {
      leftIdpSel: s.left
      rightIdpSel: s.right
      activeKybd: IDPSel.keyboardForLines(idp, d) ? ''
      kybdSelA: if d.A then 'ON' else 'OFF'
      kybdSelB: if d.B then 'ON' else 'OFF'
    }

  _syncKybd: () ->
    @screens?['DPS']?.setKybd(@kybdBars())
    cst = @screens?['IDP_CST']
    cst.setData(@idpCstData(cst.data())) if cst?.data()?

  _selChanged: () ->
    s = @panel.positions()
    console.log "IDP/CRT SEL: LEFT #{s.left} RIGHT #{s.right}"
    return unless @disp?
    @_syncKybd()
    @redraw()

  updateMduData: () ->
    @mdu_menuArea.setData {
      priPortIDP: @priPortIDP
      secPortIDP: @secPortIDP
      cmdPort: @cmdPort
      flightCritBus: @flightCritBus
      portReconfigureModeAuto: @portReconfigureModeAuto
      modNegView: @modeNegView
      faultLineMsg: @faultLineMsg
      curIDP: @commandingIDP()
    }

  POLL_FAIL_MS = 3000       # DPS poll fail timer
  BIG_X_MS = 3000           # DPS display-update timer
  IDP_LOST_MS = 2000        # 'MDU Autonomous' fail timer (16 missed beats)
  STARTUP_MS = 10000        # ...but allow for an IDP that starts up slowly

  _rearm: (name, ms, expired) ->
    clearTimeout(@[name]) if @[name]?
    @[name] = setTimeout call(@, '_expireTimer', name, expired), ms

  _expireTimer: (name, expired) ->
    @[name] = null
    expired()

  _secondaryLost: () ->
    @_secTimedOut = true
    @_autonomous() if @curDisplay == 'AUTONOMOUS'

  _pollLost: () ->
    return if @dps_poll_fail
    @dps_poll_fail = true
    @screens?['DPS']?.setPollFail(true)
    @redraw()

  _pollHeard: () ->
    return if not @dps_poll_fail
    @dps_poll_fail = false
    @screens?['DPS']?.setPollFail(false)
    @redraw()

  # The big "X" is "not supported during OTP" (JSC-18820 sect.4.6.5, the note
  # under figure 4-30): it annunciates a loss of GPC display update, and the
  # operational test program's page is not a GPC display.  The watchdog goes
  # on running underneath, so what was standing comes back when OTP does.
  _otpPage: (up) ->
    return if up == @dps_otp
    @dps_otp = up
    @screens?['DPS']?.setBigX(if up then false else @dps_big_x)
    @redraw()

  _updateLost: () ->
    return if @dps_big_x
    @dps_big_x = true
    @screens?['DPS']?.setBigX(true) if not @dps_otp
    @redraw()

  _updateHeard: () ->
    return if not @dps_big_x
    @dps_big_x = false
    @screens?['DPS']?.setBigX(false) if not @dps_otp
    @redraw()

  _pollTick: () ->
    @_rearm '_pollWatchdog', POLL_FAIL_MS, call(@, '_pollLost')
    @_pollHeard()

  _updateTick: () ->
    @_rearm '_updateWatchdog', BIG_X_MS, call(@, '_updateLost')
    @_updateHeard()

  # Only the IDP's messages count as the IDP being heard; the bus also
  # carries the 1553B words between the IDP and its ADCs.
  recvFromPri: (t,busID, msg, remote) ->
    return unless MDUMsgName[msg.data16[0]]?
    t._idpHeard()
    t._rearm '_idpWatchdog', IDP_LOST_MS, call(t, '_idpLost')
    scr = t.screens?['DPS']
    switch msg.data16[0]
      when MDUMsg.HEARTBEAT
        scr?.blinkTick()
      when MDUMsg.ADC
        t._adcFrame(msg.data16)
      when MDUMsg.FC
        t._fcMessage(msg.data16)
      when MDUMsg.POLL
        t._pollTick()
      when MDUMsg.FILL, MDUMsg.LOCAL_FILL
        t._updateTick() if msg.data16[0] == MDUMsg.FILL
        if scr?
          scr.applyFill(msg.data16[1],
                        (msg.data16[i] for i in [2...msg.data16.length]))
          t.redraw()
      when MDUMsg.CLOCK
        t._pollTick()
        if scr?
          scr.setClock(msg.data16[1], msg.data16[2], msg.data16[3])
          t.redraw()
      when MDUMsg.RESET_SPL
        if scr?
          scr.spl?.clear()
          scr.setSyntaxError false
          scr.updateScratchpad()
        t.redraw()
      when MDUMsg.OTP
        t._otpPage(msg.data16[1] != 0)
      when MDUMsg.LOAD
        t.dps_vm_load = msg.data16[1] != 0
        if scr?
          scr.setVmLoad(t.dps_vm_load)
          t.redraw()
      when MDUMsg.REFRESH
        # The DEU's control program says where a refresh starts.  It is
        # the message line buffer when the program is drawing the scratch
        # pad line itself (`--dcp`), and the display header otherwise.
        if scr?
          scr.setRefreshStart(msg.data16[1])
          t.redraw()

  # The secondary port has a separate heartbeat and can drop independently
  # of the primary; the AUTONOMOUS display's timeout line reports which.
  recvFromSec: (t,busID, msg, remote) ->
    return unless MDUMsgName[msg.data16[0]]?
    if t._secTimedOut
      t._secTimedOut = false
      t._autonomous() if t.curDisplay == "AUTONOMOUS"
    t._rearm '_idpWatchdogSec', IDP_LOST_MS, call(t, '_secondaryLost')

  redraw: () ->
    @disp.dirty = true

  # The 32 samples of a pair become the fields of the subsystem displays
  # through the channel table (lru/adc/adcChannels); an invalid frame sets
  # every field to the display's invalid marker.  A field changes when its
  # value moves by a tenth of a unit, and a changed screen is redrawn at
  # most ten times a second: the gauge screens rebuild on every refresh.
  ADC_REFRESH_MS = 100

  _adcFrame: (words) ->
    f = decodeMduAdc(words)
    return unless f?
    volts = (wordToVolts(w) for w in f.data)
    for scrName, fields of fieldsOfPair(f.pair, volts, f.valid)
      feed = (@adcFeed[scrName] ?= {})
      changed = false
      for k, v of fields
        v = Math.round(v * 10) / 10 if typeof v == 'number'
        continue if feed[k] == v
        feed[k] = v
        changed = true
      continue unless changed
      Object.assign @screens[scrName].curData, feed if @screens?[scrName]?.curData?
      @_adcDirty[scrName] = true
    @_adcRefresh()
    return

  _adcRefresh: () ->
    return if @_adcTimer? or not @disp?
    @_adcTimer = setTimeout call(@, '_refreshAdcNow'), ADC_REFRESH_MS

  _refreshAdcNow: () ->
    @_adcTimer = null
    if @_adcDirty[@curDisplay] and @screens[@curDisplay]?
      @_adcDirty[@curDisplay] = false
      @screens[@curDisplay].refreshFeed?()
      @redraw()

  # A screen shown after frames arrived takes the fields it missed.
  _adcApply: (scrName) ->
    scr = @screens[scrName]
    feed = @adcFeed[scrName]
    return unless scr?.curData? and feed?
    Object.assign scr.curData, feed
    @_adcDirty[scrName] = false
    scr.refreshFeed?()

  # Each DDU write and MEDS transfer the IDP heard on an FC bus arrives
  # as an FC message.  The words of this station's DDU and of the MEDS
  # transfer are kept by bus; the selected bus's words become the PFD
  # fields through lru/ddu/dduFields ten times a second, and a bus quiet for
  # a second gives the instruments their invalid markers.
  FC_REFRESH_MS = 100
  FC_STALE_MS = 1000
  PFD_SCREENS = ['AE_PFD', 'ORBIT_PFD']

  _fcMessage: (words) ->
    m = decodeMduFc(words)
    return unless m?
    if m.msg.startsWith('MEDS')
      return unless m.iua == 15
    else
      return unless DDU_OF_IUA[m.iua] == STATION_DDU[@station]
    (@fcFeed[m.bus] ?= {})[m.msg] = m.words
    @fcHeard[m.bus] = simNow()
    return unless m.bus == @flightCritBus
    @_fcDirty = true
    @_rearm '_fcWatchdog', FC_STALE_MS, call(@, '_fcStale')
    @_fcRefresh()

  _fcStale: () ->
    @_fcDirty = true
    @_fcRefresh()

  _fcFresh: (bus) -> (simNow() - (@fcHeard[bus] ? 0)) < FC_STALE_MS

  _fcRefresh: () ->
    return if @_fcTimer? or not @disp?
    @_fcTimer = setTimeout call(@, '_refreshFcNow'), FC_REFRESH_MS

  _refreshFcNow: () ->
    @_fcTimer = null
    return unless @_fcDirty
    @_fcDirty = false
    bus = @flightCritBus
    fields = fieldsOfFeed(@station, @fcFeed[bus] ? {}, @_fcFresh(bus))
    json = JSON.stringify(fields.AE_PFD)
    return if json == @_fcFieldsJson
    @_fcFieldsJson = json
    @fcFields = fields
    @_fcApply(@curDisplay) if @curDisplay in PFD_SCREENS

  # A PFD screen takes the selected bus's fields: when shown, and when
  # they change.  The fields that moved go with them, so the screen rebuilds
  # the instruments that read one.
  _fcApply: (scrName) ->
    scr = @screens[scrName]
    f = @fcFields?[scrName]
    return unless scr?.curData? and f?
    changed = (k for k, v of f when not sameField(scr.curData[k], v))
    Object.assign scr.curData, f
    scr.refreshFeed?(changed)
    @redraw()

  handleEdgekey: (keyId) =>
    console.log "handleEdgekey", keyId, @currentMenu[keyId]
    if @currentMenu[keyId].action?
      @currentMenu[keyId].action(@)
      console.log "action", @curDisplay
      @redraw()
    if @currentMenu[keyId].link?
      @setCurrentMenu @currentMenu[keyId].link
      @redraw()

  handleEdgekeyFail: (keyId) =>
    @mdu_menuArea.setEdgekeyFailed(keyId)

  setCurrentMenu: (menuName) ->
    @currentMenuName = menuName
    @currentMenu = @Menus[menuName]
    @mdu_menuArea.setCurrentMenu(@currentMenu)
    # Persistent settings declare activeItem for the selected edgekey.
    if @currentMenu.activeItem?
      @mdu_menuArea.setActiveMenuItem(@currentMenu.activeItem(@))
    if @currentMenu.action?
      @currentMenu.action(@)

  setCurrentDisplay: (newCurDisplay, curMenuItem=null) ->
    console.log "setCurrentDisplay #{@curDisplay} -> #{newCurDisplay}"
    @mdu_menuArea.setActiveMenuItem(curMenuItem)
    if newCurDisplay != @curDisplay
      if @screens[@curDisplay]
        console.log @screens[@curDisplay].group
        @disp.scene.remove  @screens[@curDisplay].group
      @curDisplay = newCurDisplay
      if @curDisplay not of @screens
        screenModule = ScreenMods[@curDisplay]
        @screens[@curDisplay] = new screenModule["Screen_#{@curDisplay}"] @disp
      cd = @screens[@curDisplay]
      cd.draw()
      @_adcApply(@curDisplay) if @adcFeed[@curDisplay]?
      @_fcApply(@curDisplay) if @curDisplay in PFD_SCREENS
      if @curDisplay == 'DPS'
        cd.setBigX(@dps_big_x and not @dps_otp)
        cd.setPollFail(@dps_poll_fail)
        cd.setVmLoad(!!@dps_vm_load)
        cd.setIDPNo(@commandingIDP())
        cd.setKybd(@kybdBars())
      else if @curDisplay == 'IDP_CST'
        cd.setData(@idpCstData(cd.data()))
      if cd.group?
        @disp.scene.add cd.group
        @redraw()

  setFCBus: (bus) ->
    @flightCritBus = bus
    @mdu_menuArea.setFCBus(@flightCritBus)
    @_fcDirty = true
    if @_fcFresh(bus)
      @_rearm '_fcWatchdog', FC_STALE_MS, call(@, '_fcStale')
    @_fcRefresh()
    if @currentMenu?.activeItem?
      @mdu_menuArea.setActiveMenuItem(@currentMenu.activeItem(@))

  toggleCmdPort: () ->
    @cmdPort = (@cmdPort+1)%2
    @mdu_menuArea.setCurPort(@cmdPort)
    @screens?['DPS']?.setIDPNo(@commandingIDP())
    @_syncKybd()
    @redraw()

  toggleReconfigMode: () ->
    @portReconfigModeAuto = not @portReconfigModeAuto
    @mdu_menuArea.setReconfModeAuto(@portReconfigModeAuto)

  toggleNegView: () ->
    @modeNegView = not @modeNegView
    @mdu_menuArea.setNegView(@modeNegView)

  watchIDP: () ->
    return if @CONFIG.dev
    # A longer grace at startup than mid-run: the IDP's process may still be
    # coming up.
    @_rearm '_idpWatchdog', STARTUP_MS, call(@, '_idpLost')
    @_rearm '_idpWatchdogSec', STARTUP_MS, call(@, '_secondaryLost') if @secPortIDP?

  _autonomous: () ->
    if @curDisplay != "AUTONOMOUS"
      @prevDisplay = @curDisplay
      @prevMenuName = @currentMenuName
      @setCurrentDisplay('AUTONOMOUS')
      @setCurrentMenu('DISCONNECTED')
      console.log "AUTO", @prevMenuName
      @redraw()
    if @screens['AUTONOMOUS']?.setTimeouts(not @_idpUp, @_secTimedOut)
      @redraw()

  _idpLost: () ->
    return if not @_idpUp
    @_idpUp = false
    console.log "MDU#{@id}: port timeout -- no IDP heartbeat"
    @_autonomous()

  _idpHeard: () ->
    return if @_idpUp
    @_idpUp = true
    if @curDisplay == "AUTONOMOUS"
      @setCurrentDisplay(@prevDisplay)
      console.log "RESTORE", @prevMenuName
      @setCurrentMenu(@prevMenuName)
      @redraw()

  # per-screen reference-overlay identity: localStorage key + default image.
  # AE_PFD/DPS keep their legacy keys — the long-tuned placements live under
  # them; every other screen gets '<name>OverlayGeom' and defaults to the
  # first image in data/overlay_images/.
  OV_LEGACY = {AE_PFD: ['pfdOverlayGeom', 'meds_font2.png'], DPS: ['dpsOverlayGeom', 'dpsscreen.png']}
  ovIdent: (name = @curDisplay) ->
    [key, dflt] = OV_LEGACY[name] ? ["#{name}OverlayGeom", null]
    dflt ?= @disp.overlayImageNames()[0]
    {key, dflt}

  # reference-overlay control descriptors, appended to every screen's param
  # editor (placements/slots are per-screen via ovIdent; the feed-value
  # capture hooks come from the screen when it has them)
  _ovControls: () ->
    scr = @screens[@curDisplay]
    return [] unless scr?
    {key, dflt} = @ovIdent()
    d = @disp
    [
      {header: 'reference overlay'}
      {label: 'show',
       get: (=> d.overlayVisible(key)),
       set: ((v) => d.toggleOverlay(dflt, key) if v != d.overlayVisible(key))}
      {label: 'image', options: (=> d.overlayImageNames()),
       get: (=> d.overlayImageCur(key, dflt)),
       set: ((n) => d.overlayImageSelect(key, n))}
      {label: 'slot', options: (=> d.overlaySlotNames(key)),
       get: (=> d.overlaySlotCur(key)),
       set: ((n) => d.overlaySlotSelect(key, n, scr.ovHooks?()))}
      # slots capture the feed values shown in their photo; this re-applies
      # them on slot select (and immediately when checked)
      {label: 'apply values',
       get: (=> d.overlayApplyVals(key)),
       set: ((v) => d.overlayApplyValsSet(key, v, scr.ovHooks?()))}
    ]

  # Double-click outside the display canvas toggles a panel placed to the
  # right of the active area (grow the window right/left first to make
  # room). It lists the current screen's curData fields; edits apply live
  # via the screen's refreshFeed() (numbers, strings, and booleans).
  _toggleParamEditor: (ev) ->
    return if @_paramPanel? and @_paramPanel.contains(ev.target)
    r = @disp.renderer.domElement.getBoundingClientRect()
    inCanvas = ev.clientX >= r.left and ev.clientX <= r.right and
               ev.clientY >= r.top and ev.clientY <= r.bottom
    return if inCanvas
    if @_paramPanel?
      @_paramPanel.remove()
      @_paramPanel = null
      return
    scr = @screens[@curDisplay]
    data = scr?.curData
    tcs = (scr?.testControls?() ? []).concat(@_ovControls())
    if not data? and tcs.length == 0
      console.log "param editor: #{@curDisplay} has no feed data or test controls"
      return
    stopKeys = (el) ->
      for evt in ['keydown', 'keyup', 'mousedown']
        el.addEventListener evt, (e) -> e.stopPropagation()
      return
    refresh = =>
      s = @screens[@curDisplay]
      s?.refreshFeed?()
      @redraw()
    panel = document.createElement('div')
    panel.style.cssText = "position:absolute; left:#{Math.round(r.right)+12}px;
      top:#{Math.round(r.top)+8}px; z-index:10005; background:#101336;
      color:#7f7; font:12px monospace; border:1px solid #7f7;
      padding:6px 8px; max-height:#{Math.round(r.height)-40}px;
      overflow-y:auto; -webkit-app-region:no-drag;"
    hdr = document.createElement('div')
    hdr.style.cssText = 'font-weight:bold; margin-bottom:4px; color:#2df;'
    hdr.textContent = "#{@curDisplay} feed"
    panel.appendChild(hdr)
    inputs = {}
    tcSyncs = []
    reloadVals = null        # assigned below; handlers call it at event time
    # test-mode controls (screen-provided descriptors): `options` renders a
    # pulldown, plain get/set an on/off checkbox. Engaging a test rewrites
    # curData, so the value fields re-sync afterward.
    for tc in tcs
      if tc.header?
        gh = document.createElement('div')
        gh.style.cssText = 'font-weight:bold; margin:8px 0 3px; padding-top:5px; color:#2df; border-top:1px solid #345;'
        gh.textContent = tc.header
        panel.appendChild(gh)
        continue
      row = document.createElement('div')
      row.style.cssText = 'margin:1px 0 3px; white-space:nowrap;'
      lab = document.createElement('span')
      lab.style.cssText = 'display:inline-block; width:132px; color:#fd6;'
      lab.textContent = tc.label
      row.appendChild(lab)
      if tc.options?
        ctl = document.createElement('select')
        fill = do (tc, ctl) -> ->
          opts = if typeof tc.options == 'function' then tc.options() else tc.options
          ctl.innerHTML = ''
          for o in opts
            opt = document.createElement('option')
            opt.value = o
            opt.textContent = o
            ctl.appendChild(opt)
          return
        fill()
        ctl.value = tc.get()
        ctl.style.cssText = 'background:#000; color:#fd6; border:1px solid #a83; font:12px monospace;'
        do (tc, ctl, fill) =>
          ctl.addEventListener 'change', =>
            tc.set(ctl.value)
            @redraw()
            reloadVals?()
            fill()
            ctl.value = tc.get()
        tcSyncs.push do (tc, ctl, fill) -> -> (fill() ; ctl.value = tc.get())
      else
        ctl = document.createElement('input')
        ctl.type = 'checkbox'
        ctl.checked = !!tc.get()
        do (tc, ctl) =>
          ctl.addEventListener 'change', =>
            tc.set(ctl.checked)
            @redraw()
            reloadVals?()
        tcSyncs.push do (tc, ctl) -> -> ctl.checked = !!tc.get()
      stopKeys(ctl)
      row.appendChild(ctl)
      panel.appendChild(row)
    # scalar fields only: nested objects/arrays (e.g. fault lists) are not
    # editable here
    for own k, v of (data ? {}) when typeof v in ['number', 'string', 'boolean']
      t = typeof v
      row = document.createElement('div')
      row.style.cssText = 'margin:1px 0; white-space:nowrap;'
      lab = document.createElement('span')
      lab.style.cssText = 'display:inline-block; width:132px;'
      lab.textContent = k
      row.appendChild(lab)
      inp = document.createElement('input')
      if t == 'boolean'
        inp.type = 'checkbox'
        inp.checked = v
        do (k, inp) =>
          inp.addEventListener 'change', =>
            @screens[@curDisplay].curData[k] = inp.checked
            refresh()
      else
        inp.type = 'text'
        inp.size = 8
        inp.value = "#{v}"
        inp.style.cssText = 'background:#000; color:#7f7; border:1px solid #575; font:12px monospace;'
        do (k, inp, t) =>
          commit = =>
            d = @screens[@curDisplay].curData
            if t == 'number'
              n = parseFloat(inp.value)
              return unless isFinite(n)
              d[k] = n
            else
              d[k] = inp.value
            refresh()
          inp.addEventListener 'change', commit
          inp.addEventListener 'keydown', (e) -> (commit() if e.key == 'Enter')
      stopKeys(inp)
      inputs[k] = inp
      row.appendChild(inp)
      panel.appendChild(row)
    # reload re-reads live values (e.g. while a test feed is running)
    reloadVals = =>
      d2 = @screens[@curDisplay]?.curData ? {}
      for own k2, inp2 of inputs
        if inp2.type == 'checkbox' then inp2.checked = !!d2[k2]
        else inp2.value = "#{d2[k2]}"
      s() for s in tcSyncs
      return
    btn = document.createElement('button')
    btn.textContent = 'reload'
    btn.style.cssText = 'margin-top:4px; font:12px monospace;'
    btn.addEventListener 'click', reloadVals
    stopKeys(btn)
    panel.appendChild(btn)
    document.body.appendChild(panel)
    @_paramPanel = panel
    return

  screenshot: () =>

    console.log("SCREENSHOT")
    x = document.evaluate('//*[@id="screen"]', document)
    img = document.createElement('a')
    img.href = x.iterateNext().toDataURL().replace('image/png', 'image/octet-stream')
    img.download="mduScreenshot-#{(new Date).getTime()}.png" #"
    console.log("S2")
    console.log(img.download)
    img.click()

start = (CONFIG) ->
  mdu = new MDU(CONFIG)
  # dev mode preloads test screens, so the DPS skips both indications:
  if CONFIG.dev
    mdu.dps_big_x = false
    mdu.dps_poll_fail = false
  console.log mdu
  return mdu

export default { start }
