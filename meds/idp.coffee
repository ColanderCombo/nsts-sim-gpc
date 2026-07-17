# import * as fs from 'fs'
fs = window.fs
import 'com/util'
import {LRU} from './../com/lru.civet.jsx'
import {Bus, BusMsg} from './../com/bus.civet.jsx'
import {MEDSConf} from  'meds/medsConf'
import {FCW} from 'meds/deuFCW'
import React from 'react'

#
# Interface/Display Processor
#
# Opcodes:
#   1 = DATA FILL
#   2 = TIME FILL + POLL
#   3 = IPL FILL
#   4 = DUMP
#   5 = BITE STATUS
#   6 = RESET SPL
#   7 = CRT FMT FILL
#   8 = REMOTE FILL (not used)
#   9 = REMOTE DUMP
# 
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
#   
#   0x19EE  Display Header - ADDRESS OF DEU FILL FOR HEADER
#
#   0x1A06  Address of the Uplink Indicator
#
#   0x1A0E  Address of the Uplink Indicator - DEU BRANCH ADDRESS 
#

class DEUMsg 
  #extends PackedBits
  constructor: () ->
    @makeMsgTable()

  makeMsgTable: () ->

  msgDefs: {
    respHdr: {
      d:'ooooriiimmafktcl'
      f:{
        o: 'msgOp'
          # 0=NOT USED
          # 1=KEYBOARD MESSAGE RESPONSE
          # 2=BITE STATUS RESPONSE
          # 3=MODE STATUS RESPONSE
          # 4=MEMORY FILL
        r: 'msgResetMsg'
        i: 'deuId'
          # 5=DEU1
          # 6=DEU2
          # 7=DEU3
        m: 'majFunc'
          # 0=PAYLOAD MAINTAINENCE
          # 1=GN&C
          # 2=SYSTEMS MAINTAINENCE
          # 3=INVALID
        a: 'ackMsg'
        f: 'displayFreeze'
        k: 'kybMsgPresent'
        t: 'standaloneSelftestInProgress'
        c: 'criticaltBiteStatusPresent'
        l: 'initializationRequired'
      }
    }
    respData2: {
      d:'ffffffff___ccccc'
      f:{
        f: 'formatIndex'
        c: 'countOfKeystrokes'
      }
    }
    respDataKeys: {
      d:'aaaaabbbbbccccc_'
      f:{
        a:'key1'
        b:'key2'
        c:'key3'
      }
    }
  }


# DEU buffer size = 1627 halfwords
#
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
    @running = false

    # IDP bus config lookup (does not overwrite @idpConfig from MEDSConf)
    @idpBusConfig = {
      IDP1: {
        busses: ['FC1', 'FC2', 'FC3', 'FC4', 'DK1', '_KYBD1', '_IDP1']
        dk: 'DK1', kybd: ['_KYBD1']
      }
      IDP2: {
        busses: ['FC1', 'FC2', 'FC3', 'FC4', 'DK2', '_KYBD2', '_KYBD3', '_IDP2']
        dk: 'DK2', kybd: ['_KYBD2', '_KYBD3']
      }
      IDP3: {
        busses: ['FC1', 'FC2', 'FC3', 'FC4', 'DK3', '_KYBD1', '_KYBD2', '_IDP3']
        dk: 'DK3', kybd: ['_KYBD1', '_KYBD2']
      }
      IDP4: {
        busses: ['FC1', 'FC2', 'FC3', 'FC4', 'DK4', '_KYBD3', '_IDP4']
        dk: 'DK4', kybd: ['_KYBD3']
      }
    }

    for id,bus of @bus
      console.log "|||", id, bus
      if /FC/.test id
        bus.onReceive @recvFC,@
      else if /DK/.test id
        bus.onReceive @recvDK,@
      else if /IDP/.test id
        #console.log "recvMDU", id
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


  recvFC: (t,busID, msg, remote) ->
    console.log "IDP#{t.id}: #{busID} recv #{msg}"
    #
    # device ID's:
    #
    #     5   DEU1
    #     6   DEU2
    #     7   DEU3
    #
    # message types:
    #
    #   1 (FILL) - Memory Fill
    #   2 (POLL) - Poll
    #       word count: 1
    #   3 (KYBD) - Keyboard Request
    #       word count: 42
    #   4 (DUMP) - Dump
    #   5 (RBS)  - Bite Status Request
    #       word count: 5
    #   6 (RSPL) - Reset Scratch Pad Line
    #       word count: 0
    #

  # GPC -> IDP command traffic (DK bus).  Sim wire format (see
  # meds/gpcmd.coffee): data16[0] = DEU opcode, payload follows.
  recvDK: (t,busID, msg, remote) ->
    op = msg.data16[0]
    switch op
      when 1  # DATA FILL: FCW stream -> forward to the MDUs as a background DFB
        console.log "IDP#{t.id}: #{busID} DATA FILL (#{msg.rawData.length-2} bytes)"
        out = new BusMsg(msg.data16.length)
        out.data16[0] = 0xff00
        for i in [2...msg.rawData.length]
          out.data8[i] = msg.data8[i]
        t.mduCmdBus.sendMsg out
      when 2  # TIME FILL + POLL: met/crt in seconds (32b hi/lo each)
        met = (msg.data16[1]*0x10000 + msg.data16[2]) * 1000
        crt = (msg.data16[3]*0x10000 + msg.data16[4]) * 1000
        t._lastGpcTimeAt = Date.now()
        t.fillTime(met, crt)
      when 6  # RESET SPL -> tell the MDUs to clear the scratch pad line
        console.log "IDP#{t.id}: #{busID} RESET SPL"
        out = new BusMsg(1)
        out.data16[0] = 0xff02
        t.mduCmdBus.sendMsg out
      else
        console.log "IDP#{t.id}: #{busID} unhandled GPC op #{op}"

  recvMDU: (t,busID, msg, remote) ->
    if msg.data16[0] < 0xff00
      console.log "IDP#{t.id}: #{busID} recv #{msg}"
      #console.log msg

  recvKYBD: (t,busID, msg, remote) ->
    console.log "IDP#{t.id}: KYBD #{busID} recv #{msg}"

  execDPS: () ->
    console.log(@CONFIG)
    @bgDFB = fs.readFileSync @CONFIG.NSTS_TOP+'data/'+'TEST-9011-GPC_MEMORY.dfb'
    dfbMsg = new BusMsg(1+@bgDFB.length)
    dfbMsg.data16[0] = 0xff00
    for c,i in @bgDFB
      dfbMsg.data8[i+2] = c
    console.log "execDPS", dfbMsg
    @mduCmdBus.sendMsg dfbMsg

  fillHeader: () ->
    # POSTX OPS_Page_X_Coordinate OPS_Page_Y_Coordinates
    # CHAR2 <OPS>
    # CHAR2 <OPS>
    # CHAR1 /
    # CHAR1 <SPEC>/NOOP
    # CHAR2 <SPEC>/NOOP
    # CHAR /
    # CHAR1 <DISP>/NOOP
    # CHAR2 <DISP>/NOOP
    # POSTX GPC_ID_X_Coordinate OPS_Page_Y_Coordinate
    # CHAR1 GPC_ID

  makeDFB: (s,opt={}) ->
    dfb = []
    curFCW = {}

    if opt? and opt.xy?
      dfb.push @fcw.encodeFCW {nm:'POSTX', x:opt.xy[0], y:opt.xy[1]}
    for x in s
      if curFCW.nm == 'CHAR1'
        curFCW = {nm:'CHAR2', char1:@fcw.DEUCharset[curFCW.char], char2:x}
        dfb.pop()
        dfb.push @fcw.encodeFCW curFCW
      else
        curFCW = {nm:'CHAR1', char:x, blink:0, intensity:0}
        dfb.push @fcw.encodeFCW curFCW
    # dfb.push 0
    return dfb

  _makeTimeStr: (curTime,y=0) ->
    yearMillis = curTime
    # now = new Date(Date.now())
    # jan1 = new Date(now.getFullYear(),0,1)
    # yearMillis = now - jan1
    dayOfYear = Math.floor((yearMillis) / (24*60*60*1000))
    dayMillis = yearMillis - (dayOfYear*24*60*60*1000)
    hour = Math.floor(dayMillis / (60*60*1000))
    hourMillis = dayMillis - (hour*60*60*1000)
    min = Math.floor(hourMillis / (60*1000))
    minMillis = hourMillis - (min*60*1000)
    sec = Math.floor(minMillis /(1000))
    timeStr = "#{dayOfYear.toString().lpad('0',3)}/#{hour.toString().lpad('0',2)}:#{min.toString().lpad('0',2)}:#{sec.toString().lpad('0',2)}"
    dfb = @makeDFB(timeStr, {xy:[39,y]})
    return dfb

  fillTime: (metTime,crtTime) ->
    met = @_makeTimeStr(metTime,0)
    crt = @_makeTimeStr(crtTime,1)
    crt.push 0

    if not @dfbMsg?
      @dfbMsg = new BusMsg(1+met.length+crt.length)
      @dfbMsg.data16[0] = 0xff01
    for c,i in met
      @dfbMsg.data16[i+1] = c
    for c,i in crt
      @dfbMsg.data16[i+1+met.length] = c
    @mduCmdBus.sendMsg @dfbMsg

  _updateHSW: () ->
    # JSC-18819/4.8-2
    @HSW = 0
    # @HSW |= 1                   # bit 0: Logic 1 - Always set to 1
    # @HSW |= @IPLed << 1         # bit 1: IPL has been performed
    # @HSW |= @IPLerr << 2        # bit 2: IPL error
    # @HSW |= @IPLcce << 3        # bit 3: IPL circuit check error
    # @HSW |= @SGintError << 4    # bit 4: Symbol generator intensity parity error
    # @HSW |= @SGsincosError << 5 # bit 5: Symbol generator sin-cosine parity error
    # @HSW |= @SGactive << 6      # bit 6: Symbol generator active
    # @HSW |= @SGcharError << 7   # bit 7: Symbol generator character parity error
    # @HSW |= @OscError << 8      # bit 8: Oscillator error
    # @HSW |= @SASTP_zeroDeflErr  # bit 9: SASTP: Symbol generator analog zero deflection test error

  _buildStatusResp: () ->


  exec: () ->
    # console.log "exec", @id, @bus
    if not @hbMsg?
      @hbMsg = new BusMsg(2)
      @hbMsg.data16[0] = 0xffff
      @hbMsg.data16[1] = @id
    if @running
        @bus["_#{@id}"].sendMsg @hbMsg
        if @CONFIG.dev and not @bgDFB
          # dev mode: preload a test background DFB into the DPS display
          @execDPS()
        else if not @_lastGpcTimeAt? or (Date.now() - @_lastGpcTimeAt) > 2000
          # local time fill for the DPS header — only while no GPC is
          # sourcing time (op 2 on the DK bus takes over)
          now = new Date(Date.now())
          jan1 = new Date(now.getFullYear(),0,1)
          yearMillis = now - jan1
          @fillTime(yearMillis,0)
    window.setTimeout((()=>@exec()),500.0)


start = (CONFIG) ->
  console.log "start IDP", CONFIG
  idp = new IDP(CONFIG)
  console.log idp
  return idp

export default { start }