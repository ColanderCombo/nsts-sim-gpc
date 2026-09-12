import {call, setInterval, clearInterval} from '../../com/simRuntime.coffee'
# Integrated Display Processor
#
# One IDP: the DEU protocol state machine (meds/deu/deuUnit) on its DK bus, the
# bus controller toward its two ADCs (meds/idp/idpAdc), the receivers on the
# four flight critical busses (meds/idp/idpFc), the keyboards the IDP/CRT SEL
# switches route to it (meds/idp/idpSel, meds/kybd), its discrete lines
# (meds/idp/idpDiscretes), and the 1553B bus to its MDUs, where everything
# it has for them goes as the messages tagged in meds/medsConf.  The busses
# are MEDSConf.idps in meds/medsConf.
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

import {LRU} from './../../com/lru.civet.jsx'
import {BusMsg} from './../../com/bus.civet.jsx'
import {MEDSConf, MDUMsg, powerFeedsOf} from './../medsConf'
import * as DEU from './../deu/deuProto'
import {DEUUnit} from './../deu/deuUnit'
import {KYBD} from './../kybd'
import {IDPSel} from './idpSel'
import {IDPDiscretes, IDP_BITS} from './idpDiscretes'
import {IDPAdcBC, encodeMduAdc} from './idpAdc'
import {IDPFcRx, encodeMduFc} from './idpFc'

export UNITS = Object.keys(MEDSConf.idps)

# One ADC frame: command both units, then pass each unit's last frame and
# its validity on to the MDUs.  lru/adc/adcConf SAMPLE_MS.
export ADC_FRAME_MS = 40

# The heartbeat, free-running: an MDU goes autonomous when its port is
# quiet, and the port is quiet when the IDP has stopped, so this ticks with
# or without a GPC on the DK bus.
#
# The MDU advances the DEU's flashing attribute on this beat; eight a
# second holds the flash's 5/8 : 3/8 duty cycle.  See Screen_DPS.blinkTick.
export HEARTBEAT_MS = 125

# opts:
#   unit    IDP1 to IDP4, or the number
#   ipled   true for a unit already holding its control program; false has
#           it ask the GPC for a load (poll header bit 16)
#   log     where the DEU unit's trace goes; console.log by default
#   quiet   no trace
export class IDP extends LRU
  constructor: (opts = {}) ->
    unit = "IDP#{String(opts.unit ? 1).toUpperCase().replace(/^IDP/, '')}"
    throw new Error("invalid IDP '#{opts.unit}'") unless MEDSConf.idps[unit]?
    idpConfig = Object.assign({id: unit}, MEDSConf.idps[unit],
      {power: powerFeedsOf(MEDSConf.idps[unit].powerBus), powerRule: 'all'})
    super(idpConfig)

    @idpConfig = idpConfig
    @idpNo = Number(@id.replace(/\D/g, ''))
    @quiet = !!opts.quiet
    @log = if @quiet then (->) else (opts.log ? ((text) -> console.log text))

    @mduCmdBus = @bus["_#{@id}"]
    @dkBus = @bus[@idpConfig.dkBus]
    @running = false
    @stats = {heartbeats: 0, adcFrames: 0, fcMessages: 0, keys: 0, keysDropped: 0}

    @adc = new IDPAdcBC(@idpNo, {send: (words) => @_sendWordsMDU words})

    @fcRx = {}
    for name in @idpConfig.fcBus
      @fcRx[name] = new IDPFcRx(Number(name.replace(/\D/g, '')),
                                onMessage: (m) => @_recvFcMessage(m))

    @unit = new DEUUnit
      name: @id
      ipled: opts.ipled ? true
      send: (words) => @_send words
      fill: (addr, words) => @_sendToMDUs addr, words
      reset: () => @_resetScratchPad()
      time: (t) => @_sendClock t
      poll: () => @_sendPollTick()
      load: (stage) => @_loadStage(stage)
      log: (text) => @log text

    @discretes = new IDPDiscretes @idpNo, onInput: (bit, on_) => @_input(bit, on_)
    @discretes.setLoadState(if @unit.ipled then 'complete' else 'requested')

    for id, bus of @bus
      if /^FC/.test id
        bus.onReceive @recvFC, @
      else if id == @idpConfig.dkBus
        bus.onReceive @recvDK, @
      else if id == "_#{@id}"
        bus.onReceive @recvMDU, @
      else if /^_KYBD/.test id
        bus.onReceive @recvKYBD, @

  busPorts: () ->
    ports = ("#{id}:#{bus.busDesc.port}" for id, bus of @bus)
    ports.push "#{@discretes.channel.name}:#{@discretes.channel.bus.busDesc.port}" if @discretes.channel.bus?
    ports.join(' ')

  ready: () -> Promise.all([super(), @discretes.ready()])

  close: () ->
    @halt()
    @discretes.close()
    bus.close() for id, bus of @bus
    return

  # A discrete line changed.  The LOAD momentary made asks the GPC for a
  # load; the KYBD SEL lines are read as keystrokes arrive.
  _input: (bit, on_) ->
    if bit == IDP_BITS.A.load
      @unit.requestLoad() if on_
    else
      @log "#{@id}: #{IDP_BITS.A.kybdsela == bit and 'KYBD SEL A' or 'KYBD SEL B'} #{if on_ then 'on' else 'off'}"
    return

  # The load's stages, from the DEU unit: the status lines and the MDUs
  # follow them, VM LOAD IN PROGRESS from the request to the last fill.
  _loadStage: (stage) ->
    @discretes.setLoadState(stage)
    @_sendMDU MDUMsg.LOAD, [if stage == 'complete' then 0 else 1]
    return

  start: () ->
    return if @running
    @running = true
    @_hbTimer = setInterval call(@, '_heartbeat'), HEARTBEAT_MS
    @_adcTimer = setInterval call(@, '_adcTick'), ADC_FRAME_MS
    return

  halt: () ->
    clearInterval @_hbTimer if @_hbTimer?
    clearInterval @_adcTimer if @_adcTimer?
    @_hbTimer = @_adcTimer = null
    @running = false
    return

  onStop: () -> @halt()


  # "IDPs require 28 V dc that is supplied by a main bus (IDP1 - main
  # A/FPC1, IDP2 - main B/FPC2, and IDP3 and 4 - main C/FPC3).  The IDP
  # power switches are located on panels C2 and R11" (USA-007587
  # sect.2.6).  A unit with no supply sends no heartbeat, which is what
  # its MDUs read as a lost port.
  onPowerOn: () ->
    @start()
    return

  onPowerOff: () ->
    @halt()
    return

  # The FC1-4 busses carry the GPC's flight instrument data: the DDU words
  # for the ADI, HSI, AMI and AVVI and the MEDS transfer (lru/ddu/dduConf).
  recvFC: (t, busID, msg, remote) ->
    t.fcRx[busID]?.recv(msg.data16, msg.cmd)

  _recvFcMessage: (m) ->
    @stats.fcMessages += 1
    @_sendWordsMDU encodeMduFc(MDUMsg.FC, m)

  # Display/Keyboard (DK) bus: the GPC's commands to this unit.
  recvDK: (t, busID, msg, remote) ->
    t.unit.recv msg.data16, msg.cmd

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

  _sendWordsMDU: (words) ->
    return if not @mduCmdBus? or words.length == 0
    msg = new BusMsg(words.length)
    msg.data16[i] = words[i] & 0xffff for i in [0...words.length]
    @mduCmdBus.sendMsg msg

  _sendToMDUs: (addr, words) -> @_sendMDU MDUMsg.FILL, [addr].concat(words)

  _adcTick: () ->
    @adc.tick()
    for _, u of @adc.units
      @stats.adcFrames += 1
      @_sendWordsMDU encodeMduAdc(MDUMsg.ADC, u)

  _heartbeat: () ->
    @stats.heartbeats += 1
    @_sendMDU MDUMsg.HEARTBEAT, [@idpNo]

  _sendPollTick: () -> @_sendMDU MDUMsg.POLL, [@idpNo]

  # The header clock, straight from the GPC, sent as a separate message: the
  # GPC's variable-data fill covers 0x19EE..0x1AB2, and on a real unit the
  # control program draws the clock.
  _sendClock: (t) ->
    return if not t?
    @_sendMDU MDUMsg.CLOCK, [Math.max(0, Math.round(t.mission)),
                             Math.max(0, Math.round(t.event)), t.conv]

  _resetScratchPad: () -> @_sendMDU MDUMsg.RESET_SPL

  recvMDU: (t, busID, msg, remote) ->
    t.adc.recv(msg.data16)
    return

  # A keyswitch goes into the unit's entry while the KYBD SEL line of the
  # channel it comes in on is up (meds/idp/idpSel); the major function
  # switch is the unit's, on panel C2 beside the select switch, and sets the
  # position the next poll response header reports whichever way that
  # switch points.
  recvKYBD: (t, busID, msg, remote) ->
    kybd = Number(busID.replace(/\D/g, ''))
    for w in msg.data16
      d = KYBD.decode(w)
      if d?.key?
        if IDPSel.selectedByLines(t.idpNo, kybd, t.discretes.lines())
          t.stats.keys += 1
          t.unit.pressKey d.key.gpcCode
        else
          t.stats.keysDropped += 1
          t.log "#{t.id}: #{d.key.ascii} on #{busID} not selected, dropped"
      else if d?.majorFunc?
        t.unit.majorFunc = d.majorFunc
        t.log "#{t.id}: major function #{DEU.MAJOR_FUNC_NAME[d.majorFunc]}"
      else
        t.log "#{t.id}: unknown keyboard word 0x#{(w & 0xffff).toString(16)}"
    return

  # Load a format control word stream into display memory at the display
  # header address, where a refresh starts, and send it on to the MDUs: a
  # display with no GPC on the DK bus.
  loadFCWs: (words, addr = DEU.ADDR.DISPLAY_HEADER) ->
    for w, i in words
      @unit.mem[(addr + i) & (DEU.DEU_MEMORY_WORDS - 1)] = w & 0xffff
    @_sendToMDUs(addr, Array.from(words))
