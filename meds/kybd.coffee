
import {Bus, BusMsg, busConfig} from './../com/bus.civet.jsx'
import {KYBDMsg, KYBD_MSG_MASK} from 'meds/medsConf'
import * as DEU from 'meds/deuProto'

$ = require('jquery')

export class KYBD
  @DEUKey: {
    keys : {
      ACK:        { sw: 1, ascii: 'ACK', gpcCode: 0x1c, deuCode: 0xfff9 }
      MSG_RESET:  { sw: 2, ascii: 'MSG RESET', gpcCode: 0x1d, deuCode: 0xfff1 }
      SYS_SUMM:   { sw: 3, ascii: 'SYS SUMM', gpcCode: 0x10, deuCode: 0xffe9 } 
      FAULT_SUMM: { sw: 4, ascii: 'FAULT SUMM', gpcCode: 0x13, deuCode: 0xffe1 } 
      C:          { sw: 5, ascii: 'C', gpcCode: 0x0c, deuCode: 0xffd9 }
      B:          { sw: 6, ascii: 'B', gpcCode: 0x0b, deuCode: 0xffd1 }
      A:          { sw: 7, ascii: 'A', gpcCode: 0x0a, deuCode: 0xffc9 }
      GPC_CRT:    { sw: 8, ascii: 'GPC/CRT', gpcCode: 0x19, deuCode: 0xffc1 }

      F:          { sw: 9, ascii: 'F', gpcCode: 0x0f, deuCode: 0xfffa }
      E:          { sw:10, ascii: 'E', gpcCode: 0x0e, deuCode: 0xffba }
      D:          { sw:11, ascii: 'D', gpcCode: 0x0d, deuCode: 0xff7a } 
      IO_RESET:   { sw:12, ascii: 'I/O RESET', gpcCode: 0x18, deuCode: 0xff3a } 
      3:          { sw:13, ascii: '3', gpcCode: 0x03, deuCode: 0xfefa }
      2:          { sw:14, ascii: '2', gpcCode: 0x02, deuCode: 0xfefb }
      1:          { sw:15, ascii: '1', gpcCode: 0x01, deuCode: 0xfe7a }
      ITEM:       { sw:16, ascii: 'ITEM', gpcCode: 0x14, deuCode: 0xfe3a }

      6:          { sw:17, ascii: '6', gpcCode: 0x06, deuCode: 0xfffb }
      5:          { sw:18, ascii: '5', gpcCode: 0x05, deuCode: 0xfdfb }
      4:          { sw:19, ascii: '4', gpcCode: 0x04, deuCode: 0xfbfb } 
      EXEC:       { sw:20, ascii: 'EXEC', gpcCode: 0x1e, deuCode: 0xf9fb } 
      9:          { sw:21, ascii: '9', gpcCode: 0x09, deuCode: 0xf7fb }
      8:          { sw:22, ascii: '8', gpcCode: 0x08, deuCode: 0xf5fb }
      7:          { sw:23, ascii: '7', gpcCode: 0x07, deuCode: 0xf3fb }
      OPS:        { sw:24, ascii: 'OPS ', gpcCode: 0x11, deuCode: 0xf1fb }

      PLUS:       { sw:25, ascii: '+', gpcCode: 0x16, deuCode: 0xfffc }
      0:          { sw:26, ascii: '0', gpcCode: 0x00, deuCode: 0xeffc }
      MINUS:      { sw:27, ascii: '-', gpcCode: 0x15, deuCode: 0xdffc } 
      SPEC:       { sw:28, ascii: 'SPEC', gpcCode: 0x12, deuCode: 0xcffc } 
      PRO:        { sw:29, ascii: 'PRO', gpcCode: 0x1f, deuCode: 0xbffc }
      DECIMAL:    { sw:30, ascii: '.', gpcCode: 0x17, deuCode: 0xaffc }
      CLEAR:      { sw:31, ascii: 'CLEAR', gpcCode: 0x1a, deuCode: 0x9ffc }
      RESUME:     { sw:32, ascii: 'RESUME', gpcCode: 0x1b, deuCode: 0x8ffc }
    }
  }

  @DPSKeys: {
    27: @DEUKey.keys.MSG_RESET
    8: @DEUKey.keys.CLEAR
    48: @DEUKey.keys[0]
    49: @DEUKey.keys[1]
    50: @DEUKey.keys[2]
    51: @DEUKey.keys[3]
    52: @DEUKey.keys[4]
    53: @DEUKey.keys[5]
    54: @DEUKey.keys[6]
    55: @DEUKey.keys[7]
    56: @DEUKey.keys[8]
    57: @DEUKey.keys[9]
    65: @DEUKey.keys.A
    66: @DEUKey.keys.B
    67: @DEUKey.keys.C
    68: @DEUKey.keys.D
    69: @DEUKey.keys.E
    70: @DEUKey.keys.F
    84: @DEUKey.keys.IO_RESET     # T
    79: @DEUKey.keys.OPS           # O
    # 83: @DEUKey.keys.SPEC
    83: @DEUKey.keys.SPEC
    73: @DEUKey.keys.ITEM
    # 121: @DEUKey.keys.EXEC
    13: @DEUKey.keys.EXEC
    80: @DEUKey.keys.PRO
    82: @DEUKey.keys.RESUME
    187: @DEUKey.keys.PLUS
    189: @DEUKey.keys.MINUS
    190: @DEUKey.keys.DECIMAL
    75: @DEUKey.keys.ACK
    89: @DEUKey.keys.SYS_SUMM       # Y
    85: @DEUKey.keys.FAULT_SUMM     # U
    71: @DEUKey.keys.GPC_CRT        # G
  }

  # Keyboard scan code -> the key it names, built on first use.  The scan
  # codes are the row/column strobe pattern the keyboard puts on the bus;
  # `gpcCode` is the 5-bit code the DEU protocol carries.
  @byScan: (scan) ->
    if not @_scanToKey?
      @_scanToKey = {}
      @_scanToKey[k.deuCode] = k for _, k of @DEUKey.keys
    @_scanToKey[scan & 0xffff]

  # Major Function (MF) switch keybindings:
  @MF_KEYS: {'<': 'GNC', '>': 'SM', '?': 'PL'}

  # The switch position a keydown selects, under the same rule as deuKeyFor.
  @majorFuncFor: (ev) ->
    return null unless ev?
    return null if @isEditable(ev.target)
    return null if ev.ctrlKey or ev.metaKey or ev.altKey
    @MF_KEYS[ev.key] ? null

  # The word a switch position puts on the keyboard bus.
  @majorFuncWord: (name) -> KYBDMsg.MAJOR_FUNC | DEU.MAJOR_FUNC_CODE[name]

  # One halfword off a keyboard bus: {key} for a keyswitch scan pattern,
  # {majorFunc} (the DEU code) for the switch, null for anything else.
  @decode: (w) ->
    w &= 0xffff
    k = @byScan(w)
    return {key: k} if k?
    if (w & KYBD_MSG_MASK) == KYBDMsg.MAJOR_FUNC
      code = w & ~KYBD_MSG_MASK & 0xffff
      return {majorFunc: code} if DEU.MAJOR_FUNC_NAME[code]?
    null

  @isEditable: (el) ->
    return false unless el?
    tag = el.tagName?.toLowerCase()
    return true if tag == 'input' or tag == 'textarea' or tag == 'select'
    !!el.isContentEditable

  @deuKeyFor: (ev) ->
    return null unless ev?
    return null if @isEditable(ev.target)
    return null if ev.ctrlKey or ev.metaKey or ev.altKey
    @DPSKeys[ev.keyCode] ? null

  constructor: (@kybdBus, @mdu=null) ->
    @majorFunc = DEU.MAJOR_FUNC_NAME[DEU.MAJOR_FUNC_DEFAULT]
    @_setupBus()
    $(document).keydown (ev) =>
      return if KYBD.isEditable(ev.target)
      if ev.key == 'S' and @mdu?
        ev.preventDefault()
        @mdu.screenshot()
        return
      if (ev.key == 'F12' or ev.key == 'F11') and not ev.ctrlKey and @mdu?
        # Debug: F12 / F11 cycle the DPS background through every data/*.dfb
        ev.preventDefault()
        @mdu.setCurrentDisplay('DPS')
        @mdu.screens['DPS']?.cycleBGDFB(if ev.key == 'F12' then 1 else -1)
        @mdu.redraw()
        return
      # Debug: reference-screenshot overlays, Shift cycling the opacity.
      # Images live in data/overlay_images/ and are selectable from the param
      # editor's 'reference overlay' group.  F8 is the current screen's
      # overlay, keyed by mdu.ovIdent; F7 is the DPS overlay.
      if ev.key == 'F8' and @mdu?
        ev.preventDefault()
        {key, dflt} = @mdu.ovIdent()
        if ev.shiftKey then @mdu.disp.cycleOverlayOpacity(key) else @mdu.disp.toggleOverlay(dflt, key)
        return
      if ev.key == 'F7' and @mdu?
        ev.preventDefault()
        if ev.shiftKey then @mdu.disp.cycleOverlayOpacity('dpsOverlayGeom') else @mdu.disp.toggleOverlay('dpsscreen.png','dpsOverlayGeom')
        return
      # Debug: F9 toggles the animated DEU self-test mode
      if ev.key == 'F9' and @mdu?
        ev.preventDefault()
        @mdu.setCurrentDisplay('DPS')
        @mdu.screens['DPS']?.toggleSelfTest()
        @mdu.redraw()
        return
      mf = KYBD.majorFuncFor(ev)
      if mf?
        ev.preventDefault()
        @setMajorFunc(mf)
        return
      k = KYBD.deuKeyFor(ev)
      @keyPress(k) if k?

  _setupBus: () ->
    @busName = "_KYBD#{@kybdBus}" 
    @bus = new Bus(@busName, busConfig[@busName])
    @bus.onReceive @recvKYBD

  recvKYBD: (busID, msg, remote) =>
    console.log "KYBD#{@kybdBus}: #{busID} recv #{msg}"

  # Send the position on the keyboard bus, every press, and retitle the MDU.
  setMajorFunc: (name) =>
    return unless DEU.MAJOR_FUNC_CODE[name]?
    @majorFunc = name
    msg = new BusMsg(1)
    msg.data16[0] = KYBD.majorFuncWord(name)
    @bus.sendMsg msg
    @mdu?.setMajorFunc(name)

  keyPress: (k) => 
    console.log "KYBD keyPress", k
    kybdMsg = new BusMsg(1)
    kybdMsg.data16[0] = k.deuCode
    @bus.sendMsg kybdMsg
    if @mdu
      @mdu.screens['DPS']?.recvKey(k)
