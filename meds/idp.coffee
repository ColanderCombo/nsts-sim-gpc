fs = window.fs
import 'com/util'
import {LRU} from './../com/lru.civet.jsx'
import {Bus, BusMsg} from './../com/bus.civet.jsx'
import {MEDSConf, MDUMsg} from 'meds/medsConf'
import {FCW, wordsFromBytes} from 'meds/deuFCW'
import * as DEU from 'meds/deuProto'
import {DEUUnit} from 'meds/deuUnit'
import {KYBD} from 'meds/kybd'
import React from 'react'

#
# Interface/Display Processor
#

# DEU Display Control Program (DCP) info
#  (DCP 8.07)
#
# DEU has 8192x17bit words (16+1parity)
#
# Ref SSSH Dwg.8.6:
#   0x0000  Low Core
#   0x0100  Critical Format Buffer
#   0x0F48  Format Checksum
#   0x0F49  DEU Control Program
#   0x19BC  Message Line Buffer
#   0x19EE  Display Buffer
#   0x1FE5  I/O Buffer
#
# Mem map:
#   0x0100  Critical Format Index Table
#     ->
#   0x09EE  DEU ADDR FOR VARIABLE DATA - HEADER
#   0x0A06  DEU ADDR FOR VARIABLE DATA - NO HDR
#   0x0F48  CF Buffer Checksum Word
#   0x0F49  Error keycode buffer
#     ->
#   0x0F50
#   0x0F51  Error register buffer
#     ->
#   0x0F56
#     ...
#   0x0F95  poll response keyboard buffer
#     ->
#   0x0FA4
#     ...
#   0x0FB4
#     ->
#   0x0FD4  keyswitch code table
#   
#   0x19EE  Display Header - ADDRESS OF DEU FILL FOR HEADER
#
#   0x1A06  Address of the Uplink Indicator
#
#   0x1A0E  Address of the Uplink Indicator - DEU BRANCH ADDRESS 
#


export class IDP extends LRU
  constructor: (CONFIG) ->
    idpConfig = MEDSConf.idps[CONFIG.config.lru]
    idpConfig.id = CONFIG.config.lru
    super(idpConfig)

    @CONFIG = CONFIG
    @idpConfig = idpConfig

    @keyBuf = []

    @fcw = new FCW()
    @mduCmdBus = @bus["_#{@id}"]
    @dkBus = @bus[@idpConfig.dkBus]
    @running = false

    @unit = new DEUUnit
      name: "IDP#{@id}"
      ipled: @CONFIG.config?.ipled
      send: (words) => @_send words
      fill: (addr, words) => @_sendToMDUs addr, words
      reset: () => @_resetScratchPad()
      time: (t) => @_sendClock t
      poll: () => @_sendPollTick()
      log: (text) => console.log text

    for id,bus of @bus
      console.log "|||", id, bus
      if /FC/.test id
        bus.onReceive @recvFC,@
      else if /DK/.test id
        bus.onReceive @recvDK,@
      else if /IDP/.test id
        bus.onReceive @recvMDU,@
      else if /KYBD/.test id
        bus.onReceive @recvKYBD,@
      else
        console.log "Bad bus name #{id}"

  start: () ->
    @running = true
    @exec()

  initWindow: () ->
    <cde-window title="IDP" resizable="false">
      <canvas id="screen"></canvas>
    </cde-window>


  # The FC1-4 busses carry flight instrument (a.k.a. "steam gauge")
  # data from the ADC.  Not yet implemented.
  #
  #
  recvFC: (t,busID, msg, remote) ->

  # Display/Keyboard (DK) busses
  #
  recvDK: (t,busID, msg, remote) ->
    t.unit.recv msg.data16

  # `DEUUnit` has already counted these in `stats.wordsOut`.
  _send: (words) ->
    return if not @dkBus? or words.length == 0
    msg = new BusMsg(words.length)
    msg.data16[i] = words[i] & 0xffff for i in [0...words.length]
    @dkBus.sendMsg msg

  # The IDP -> MDU messages; the tags are `MDUMsg` in meds/medsConf.
  _sendMDU: (tag, words = []) ->
    return if not @mduCmdBus?
    msg = new BusMsg(1 + words.length)
    msg.data16[0] = tag
    msg.data16[1 + i] = words[i] & 0xffff for i in [0...words.length]
    @mduCmdBus.sendMsg msg

  _sendToMDUs: (addr, words) -> @_sendMDU MDUMsg.FILL, [addr].concat(words)

  # The GPC polled this unit, which is what holds POLL FAIL off the MDU's
  # DPS display.  See `_heartbeat`.
  _sendPollTick: () -> @_sendMDU MDUMsg.POLL, [@id]

  # The heartbeat, free-running: an MDU goes autonomous when its port is
  # quiet, and the port is quiet when the IDP has stopped, so this ticks with
  # or without a GPC on the DK bus.
  #
  # The MDU advances the DEU's flashing attribute on this beat; eight a
  # second holds the flash's 5/8 : 3/8 duty cycle.  See Screen_DPS.blinkTick.
  HEARTBEAT_MS = 125

  _heartbeat: () ->
    return if @_hbTimer?
    @_hbTimer = window.setInterval (() => @_sendMDU MDUMsg.HEARTBEAT, [@id]),
                                   HEARTBEAT_MS

  # The header clock, straight from the GPC, sent as a separate message: the
  # GPC's variable-data fill covers 0x19EE..0x1AB2, and on a real unit the
  # control program draws the clock.
  _sendClock: (t) ->
    return if not t?
    @_sendMDU MDUMsg.CLOCK, [Math.max(0, Math.round(t.mission)),
                             Math.max(0, Math.round(t.event)), t.conv]

  _resetScratchPad: () -> @_sendMDU MDUMsg.RESET_SPL

  recvMDU: (t,busID, msg, remote) ->
    if msg.data16[0] < MDUMsg.FILL
      console.log "IDP#{t.id}: #{busID} recv #{msg}"
      #console.log msg

  # Keyboard Handling
  #
  # A keyswitch goes into the unit's entry; the major function switch sets
  # the position the next poll response header reports.
  recvKYBD: (t,busID, msg, remote) ->
    for w in msg.data16
      d = KYBD.decode(w)
      if d?.key?
        t.unit.pressKey d.key.gpcCode
      else if d?.majorFunc?
        t.unit.majorFunc = d.majorFunc
        console.log "IDP#{t.id}: major function #{DEU.MAJOR_FUNC_NAME[d.majorFunc]}"
      else
        console.log "IDP#{t.id}: unknown keyboard word " +
                    "0x#{(w & 0xffff).toString(16)}"

  #
  # Dev mode (--dev)
  #
  # Load a raw format control word stream into display memory at the display
  # header address, which is where a refresh starts.
  loadFCWs: (words, addr = DEU.ADDR.DISPLAY_HEADER) ->
    for w, i in words
      @unit.mem[(addr + i) & (DEU.DEU_MEMORY_WORDS - 1)] = w & 0xffff
    @_sendToMDUs(addr, Array.from(words))

  execDPS: () ->
    @bgDFB = fs.readFileSync @CONFIG.NSTS_TOP+'data/'+'TEST-9011-GPC_MEMORY.dfb'
    @loadFCWs wordsFromBytes(@bgDFB)

  exec: () ->
    @_heartbeat()
    # dev mode has no GPC, so the test background is loaded once here
    @execDPS() if @CONFIG.dev and not @bgDFB


start = (CONFIG) ->
  console.log "start IDP", CONFIG
  idp = new IDP(CONFIG)
  console.log idp
  return idp

export default { start }