import {now as simNow} from '../../com/simRuntime.coffee'
import * as THREE from 'three'
import {MDUScreen} from 'meds/mdu/mduScreen'
import {MEDSConf} from 'meds/medsConf'

export class Screen_MAINT extends MDUScreen
  setData: (@curData) ->
    if not @curData?
      @curData = {
      }
    @draw()

  data: () ->
    return @curData

  build: () ->
    @bg = new THREE.Object3D()

    @buildMEDSMaint()

    @group = new THREE.Object3D()
    @group.add @bg
    return @group

  draw: () ->
    if not @curData?
      @setData()

  buildMEDSMaint: () ->

    @geo_maint = []
    step = 147.25
    base = 53.625
    @bg.add @buildMDUBox "CDR1", base+ 0*step, 187.6875
    @bg.add @buildMDUBox "CDR2", base+ 1*step, 187.6875
    @bg.add @buildMDUBox "CRT1", base+ 2*step,  40.0000
    @bg.add @buildMDUBox "MFD1", base+ 2*step, 285.0000
    @bg.add @buildMDUBox "CRT3", base+ 3*step, 187.6875
    @bg.add @buildMDUBox "CRT2", base+ 4*step,  40.0000
    @bg.add @buildMDUBox "MFD2", base+ 4*step, 285.0000
    @bg.add @buildMDUBox "PLT1", base+ 5*step, 187.6875
    @bg.add @buildMDUBox "PLT2", base+ 6*step, 187.6875

    @bg.add @buildMDUBox "CRT4", base+ 5*step, 700
    @bg.add @buildMDUBox "AFD1", base+ 6*step, 700

    @bg.add @buildIDPBox 1, base+ .9*step, 500
    @bg.add @buildIDPBox 2, base+2.2*step, 500
    @bg.add @buildIDPBox 3, base+3.5*step, 500
    @bg.add @buildIDPBox 4, base+4.8*step, 500

    @bg.add @buildADCBox "ADC1A", base+ 0*step, 700
    @bg.add @buildADCBox "ADC1B", base+ 1*step, 700
    @bg.add @buildADCBox "ADC2A", base+ 2*step, 700
    @bg.add @buildADCBox "ADC2B", base+ 3*step, 700

  buildMDUBox: (mduName, x, y) ->
    mduData = MEDSConf.mdus[mduName]
    priPortIDP = Number(mduData.dataBus.P[-1...])
    secPortIDP = " "
    if mduData.dataBus.S?
      secPortIDP = Number(mduData.dataBus.S[-1...])

    @buildMaintBox x, y, 7, 6, 6, [
      mduName, 
      "#{priPortIDP} #{secPortIDP}", 
      "    ",
      "AUTO",
      "    ",
      "    "],
      current=false,
      isMDU=true

  buildIDPBox: (idpNum,x,y) ->
    @buildMaintBox x, y, 9, 4.55, 4, [
      "IDP#{idpNum}", 
      "    ", 
      "      ", 
      "1 2 3 4"], 
      current=false, isMDU=false,ls=.833
  
  buildADCBox: (adcId, x, y) ->
    @buildMaintBox x, y, 7, 4, 3, [
      adcId,
      "    ",
      "      "],
      current=false, isMDU=false,ls=.8333

  buildMaintBox: (xb, yb, width, height, lines, text,current=false,isMDU=false,ls=1) ->
    boxGroup = new THREE.Object3D()

    xb = @vx xb
    yb = @vy yb
    xw = width-1
    yh = height
    lh = yh/(lines-1)*ls
    fill = undefined
    fillBlue = new THREE.MeshBasicMaterial({color:@d.c2h.blue, side:THREE.DoubleSide})
    boxGroup.add @d.box xb,yb, xb+xw, yb+(yh), @d.c2h.white
    if current
      boxGroup.add @d.box xb,yb, xb+xw, yb+(yh), undefined,fillBlue
    dl_seps = new THREE.BufferGeometry()
    for l in [0...lines]
      boxGroup.add @d.line [[xb,yb+l*lh*.8333],[xb+xw,yb+l*lh*.8333]], @d.c2h.white
    if isMDU
      boxGroup.add @d.line [[ xb+xw/2, yb+1*lh*.8333],[xb+xw/2, yb+2*lh*.8333]], @d.c2h.white
    for t,i in text
      boxGroup.add (@d.strCtrReg xb,yb+i*.8333*lh+.05, t, @d.c2h.white,.8333,width)

    return boxGroup
