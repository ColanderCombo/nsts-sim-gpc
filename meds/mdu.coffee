import * as THREE from 'three'
import { createRoot } from 'react-dom/client'
import React from 'react'
# NOTE: do NOT mount an @react-three/fiber <Canvas> here — R3F's renderer
# setup flips THREE.ColorManagement.enabled globally (after our screens
# have already built), which silently sRGB->linear converts the colour of
# every material created from then on: live-rebuilt fills (tape readout
# boxes, faces, bars) render near-black while startup-built ones stay
# correct. Cost a long debugging session (July 2026).



import 'cde/cde-window'
import 'meds/style.css'
import {LRU} from '../com/lru.civet.jsx'
import {Bus, BusMsg} from '../com/bus.civet.jsx'

import {MEDSConf} from  'meds/medsConf'
import {VectorDisplay} from 'meds/mduVectorDisplay'
import {MDUMenuArea} from 'meds/mduMenuArea'
import {MDUEdgeKeys} from 'meds/mduEdgeKeys'
import {KYBD} from 'meds/kybd'
import Menus from 'meds/mduMenu'

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
      id: "MDU"
      nom: "MEDS MDU"
      busses: []
    }
    
    lruConfig.busses[0] = "_IDP#{priPortIDP}"
    if secPortIDP?
      lruConfig.busses[1] = "_IDP#{secPortIDP}"
    super(lruConfig)

    @screenMods = ScreenMods
    @_heartbeatTimer = 3
    @_heartbeatTimerSec = 3
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
    @gpcNo = 3
    @kybd = 'left'
    @portReconfigureModeAuto = false
    @modeNegView = false

    @faultLineMsg = ""
    #@faultLineMsg = "MEDS I/O ERROR CDR1            1"
    @curDisplay = "BLANK"

    @dps_poll_fail = true

    @dps_bg_cmds = []
    @queued_keys = []
    @dps_syntax_error = false
    @dps_blinking = []

    @_edgeKeys = new MDUEdgeKeys()
    @_edgeKeys.setHandler(@handleEdgekey, @handleEdgekeyFail)


  start: () ->
    @disp = new VectorDisplay(@CONFIG)
    @mdu_menuArea = new MDUMenuArea @disp, @CONFIG
    @updateMduData()
    @mdu_menuArea.build()

    @screens = {}

    @mdu_menuArea.setCurPort(@cmdPort)
    @mdu_menuArea.setFCBus(@flightCritBus)
    @mdu_menuArea.setNegView(@modeNegView)
    @mdu_menuArea.setReconfModeAuto(@portReconfigureModeAuto)

    @setCurrentMenu(@CONFIG.init.menu)
    @setCurrentDisplay(@CONFIG.init.display)

    @handleHeartbeat()
    @redraw()

    @kybd = new KYBD(1,@)

    # Debug: double-click outside the display canvas (e.g. in space opened
    # by dragging the window edges out) toggles a live feed-parameter editor
    document.addEventListener 'dblclick', (ev) => @_toggleParamEditor(ev)


    

  initWindow: () ->
    console.log("MDU initWindow")
    <cde-window title={"MDU / " + @CONFIG.config.lru} resizable="false" hasFrame={not @CONFIG.window.fullscreen}>
    </cde-window>

  updateMduData: () ->
    @mdu_menuArea.setData {
      priPortIDP: @priPortIDP
      secPortIDP: @secPortIDP
      cmdPort: 1
      flightCritBus: @flightCritBus
      portReconfigureModeAuto: @portReconfigureModeAuto
      modNegView: @modeNegView
      faultLineMsg: @faultLineMsg
      curIDP: @priPortIDP
    }

  recvFromPri: (t,busID, msg, remote) ->
    #console.log "MDU recvFromPri", t, busID, msg, remote
    t._heartbeatTimer = 3
    if msg.data16[0] == 0xff00  # dfb update
      # an IDP is delivering DPS format data — poll is good
      t.dps_poll_fail = false
      if t.screens? and t.screens['DPS']?
        t.screens['DPS'].setBGDFB(msg)
        t.screens['DPS'].setPollFail(false)
        t.redraw()
    if msg.data16[0] == 0xff01  # time fill
      if t.screens? and t.screens['DPS']?
       t.screens['DPS'].setTime(msg)
    if msg.data16[0] == 0xff02  # reset scratch pad line
      t.queued_keys = []
      t.dps_syntax_error = false
      scr = t.screens?['DPS']
      if scr?
        scr.queued_keys = []
        scr.setSyntaxError false
        scr.updateScratchpad()
      t.redraw()


  recvFromSec: (t,busID, msg, remote) ->
    #console.log "MDU recvFromSec", t, busID, msg, remote
    t._heartbeatTimerSec = 3

  redraw: () ->
    @disp.dirty = true

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

  keyPress: (k) ->
    if k in KYBD.DPSKeys
      console.log("Keypress: ", k)

    if k == KYBD.DPSKeys[27]
      @queued_keys = []
      @dps_syntax_error = false
    else if k == KYBD.DPSKeys[8]
      @queued_keys.pop()
    else
      @queued_keys.push k
    # if k == MDU.DPSKeys[121]
    #     if @queued_keys[0] == MDU.DPSKeys[118]

  setCurrentMenu: (menuName) ->
    @currentMenuName = menuName
    @currentMenu = @Menus[menuName]
    @mdu_menuArea.setCurrentMenu(@currentMenu)
    # menus that reflect a persistent setting (e.g. DATA BUS SELECT) declare
    # activeItem to pre-highlight the edgekey matching the current state
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
        # screenModule = await import("mduScreen_#{@curDisplay}.coffee")
        # screenModule = require 'meds/mduScreen_DPS.coffee'
        # screenModule = require './mduScreen_#{@curDisplay}.coffee'
        screenModule = ScreenMods[@curDisplay]
        @screens[@curDisplay] = new screenModule["Screen_#{@curDisplay}"] @disp
      cd = @screens[@curDisplay]
      cd.draw()
      if @curDisplay == 'DPS'
        cd.setPollFail(@dps_poll_fail)
      if cd.group?
        @disp.scene.add cd.group
        @redraw()

  setFCBus: (bus) ->
    @flightCritBus = bus
    #@updateMduData()
    @mdu_menuArea.setFCBus(@flightCritBus)
    # keep the DATA BUS SELECT highlight in sync however the bus was set
    if @currentMenu?.activeItem?
      @mdu_menuArea.setActiveMenuItem(@currentMenu.activeItem(@))

  toggleCmdPort: () ->
    @cmdPort = (@cmdPort+1)%2
    #@updateMduData()
    @mdu_menuArea.setCurPort(@cmdPort)

  toggleReconfigMode: () ->
    @portReconfigModeAuto = not @portReconfigModeAuto
    #@updateMduData()
    @mdu_menuArea.setReconfModeAuto(@portReconfigModeAuto)

  toggleNegView: () ->
    @modeNegView = not @modeNegView
    #@updateMduData()
    @mdu_menuArea.setNegView(@modeNegView)

  handleHeartbeat: () ->
    # dev mode: MDU is standalone — no IDP heartbeat gating
    return if @CONFIG.dev
    @_heartbeatTimer--
    @_heartbeatTimerSec-- if @secPortIDP?
    if @_heartbeatTimer < 0
      if @curDisplay != "AUTONOMOUS"
        @prevDisplay = @curDisplay
        @prevMenuName = @currentMenuName
        @setCurrentDisplay('AUTONOMOUS')
        @setCurrentMenu('DISCONNECTED')
        #@currentMenu = @Menus['DISCONNECTED']
        console.log "AUTO", @prevMenuName
        @redraw()
      # keep the timeout-reason line current (the sec port can drop
      # after the pri port did)
      secTimedOut = @secPortIDP? and @_heartbeatTimerSec < 0
      if @screens['AUTONOMOUS']?.setTimeouts(true, secTimedOut)
        @redraw()
    else
      if @curDisplay == "AUTONOMOUS"
        @setCurrentDisplay(@prevDisplay)
        console.log "RESTORE", @prevMenuName
        #@currentMenu = @prevMenu
        @setCurrentMenu(@prevMenuName)
        @redraw()
    window.setTimeout((()=>@handleHeartbeat()),500.0)

  # per-screen reference-overlay identity: localStorage key + default image.
  # AE_PFD/DPS keep their legacy keys — the long-tuned placements live under
  # them; every other screen gets '<name>OverlayGeom' and defaults to the
  # first image in data/overlay_images/.
  OV_LEGACY = {AE_PFD: ['pfdOverlayGeom', 'meds_font2.png'], DPS: ['dpsOverlayGeom', 'dpsscreen.png']}
  ovIdent: (name = @curDisplay) ->
    [key, dflt] = OV_LEGACY[name] ? ["#{name}OverlayGeom", null]
    dflt ?= @disp.overlayImageNames()[0]
    {key, dflt}

  # reference-overlay control descriptors, appended to EVERY screen's param
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

  # ---- live feed-parameter editor (debug) ----------------------------------
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
    # every screen gets the reference-overlay group appended, so the panel
    # opens on every page (screens without feed data show just the overlay)
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
      # {header: '...'} descriptors start a titled group (e.g. the
      # reference-overlay controls) rather than adding a control row
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
        # options may be a function (dynamic lists — e.g. overlay slots,
        # where 'new' grows the list); refill on every sync
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
  # dev mode preloads test screens, so the DPS skips POLL FAIL; otherwise
  # the flag stays set until an IDP delivers a background DFB
  mdu.dps_poll_fail = false if CONFIG.dev
  console.log mdu
  return mdu

export default { start }