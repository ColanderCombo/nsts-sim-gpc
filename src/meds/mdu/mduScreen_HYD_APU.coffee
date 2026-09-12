import {now as simNow} from '../../com/simRuntime.coffee'
import * as THREE from 'three'
import {MDUScreen,VertGauge} from 'meds/mdu/mduScreen'

export class Screen_HYD_APU extends MDUScreen
  setData: (@curData) ->
    @curData ?= if @dev() then @sampleData() else @noData()
    @draw()

  # No ADC frame: every gauge invalid (a negative value is the red box).
  noData: () ->
    d = {}
    d[k] = -1 for k of @sampleData()
    d

  sampleData: () ->
    {
        apuFuelQty_1: -1
        apuFuelQty_2: 0
        apuFuelQty_3: 0
        apuH2OQty_1: 0
        apuH2OQty_2: 0
        apuH2OQty_3: 0
        apuFuelP_1: 0
        apuFuelP_2: 18
        apuFuelP_3: 18
        apuOilTmp_1: 74
        apuOilTmp_2: 72
        apuOilTmp_3: 70
        hydQty_1: 0
        hydQty_2: 0
        hydQty_3: 0
        hydPress_1: 2103
        hydPress_2: -1
        hydPress_3: 1050
    }

  data: () ->
    return @curData

  build: () ->
    @bg = new THREE.Object3D()
    lines = [
      # APU Header
      [[4.25,2.8], [4.25,1.5], [24.43,1.5]],
      [[28.43,1.5],[48.5,1.5],[48.5,2.8]],
      # HYDRAULIC Header
      [[2.25,21], [2.25,19.75], [21.5,19.75]],
      [[31.5,19.75],[48.5,19.75],[48.5,21]]
    ]
    for line in lines
      @bg.add @d.line line, @d.c2h.green

    @bg.add @d.strMEDS 25,1.11,"APU", @d.c2h.green, scale=1.3,advance=.9,scalex=.7
    @bg.add @d.strMEDS 22.47,19.45,"HYDRAULIC", @d.c2h.green, scale=1.3,advance=.9 ,scalex=.75

    labels = [
      [3.78,6.91,"FUEL"],[4.03,7.91,"QTY"],[5.1,9.02,"%"],
      [4.15,13.52,"H"],[6.4,13.52,"O"],[5.47,13.88,"2"],[4.22,14.63,"QTY"],[5.15,15.82,"%"],
      [27.43,6.91,"FUEL"],[29,7.96,"P"],
      [26.68,13.52,"OIL"],[24.68,14.67,"IN TEMP"], [26.43,15.77,"\xb0F"],
      [4.3,25.1,"QTY",0.9,0.9],[5.3,26.1,'%',0.9,0.9],
      [36.35,27.39,'L'], [41.36,27.39,'L'], [46.72,27.34,'L'],
      [27.05,25.75,'PRESS',0.9,0.9]
    ]
    for label in labels
      l = @d.str label[0], label[1], label[2], @d.c2h.white, (label[3] ? 1), (label[4] ? 1)
      @bg.add l

    defs = [
      {src:"apuFuelQty_1",x: 7.9,y: 4,l:'1', d:3, h:4, bt:0.16, md:0.11, mf:false, r:[0,100],t:[20],s:{0:'red', 20:'green'}}
      {src:"apuFuelQty_2",x:13.25,y: 4,l:'2', d:3, h:4, bt:0.16, md:0.11, mf:false, r:[0,100],t:[20],s:{0:'red', 20:'green'}}
      {src:"apuFuelQty_3",x:18.6,y: 4,l:'3', d:3, h:4, bt:0.16, md:0.11, mf:false, r:[0,100],t:[20],s:{0:'red', 20:'green'}}
      {src:"apuH2OQty_1",x: 7.9,y:11.16,l:'', d:3, h:4, bt:0.16, md:0.11, mf:false, r:[0,100],t:[40],s:{0:'red', 40:'green'}}
      {src:"apuH2OQty_2",x:13.25,y:11.16,l:'', d:3, h:4, bt:0.16, md:0.11, mf:false, r:[0,100],t:[40],s:{0:'red', 40:'green'}}
      {src:"apuH2OQty_3",x:18.6,y:11.16,l:'', d:3, h:4, bt:0.16, md:0.11, mf:false, r:[0,100],t:[40],s:{0:'red', 40:'green'}}
      {src:"apuFuelP_1",x:31.4,y: 4,l:'1', d:4, h:4, mf:false, r:[0,500],t:[],s:{0:'green'}}
      {src:"apuFuelP_2",x:36.75,y: 4,l:'2', d:4, h:4, mf:false, r:[0,500],t:[],s:{0:'green'}}
      {src:"apuFuelP_3",x:42.1,y: 4,l:'3', d:4, h:4, mf:false, r:[0,500],t:[],s:{0:'green'}}
      {src:"apuOilTmp_1",x:31.4,y:11.16,l:'', d:4, h:4, mf:false, r:[0,500],t:[45,290],s:{0:'red',45:'green',291:'red'}}
      {src:"apuOilTmp_2",x:36.75,y:11.16,l:'', d:4, h:4, mf:false, r:[0,500],t:[45,290],s:{0:'red',45:'green',291:'red'}}
      {src:"apuOilTmp_3",x:42.1,y:11.16,l:'', d:4, h:4, mf:false, r:[0,500],t:[45,290],s:{0:'red',45:'green',291:'red'}}
      {src:"hydQty_1",x: 7.9,y:22.61,l:'1', d:3, h:3.79, lu:0.16, md:0.05, mf:false, r:[0,100],t:[40,95],s:{0:'red', 40:'green', 96:'red'}}
      {src:"hydQty_2",x:13.25,y:22.61,l:'2', d:3, h:3.79, lu:0.16, md:0.05, mf:false, r:[0,100],t:[40,95],s:{0:'red', 40:'green', 96:'red'}}
      {src:"hydQty_3",x:18.6,y:22.61,l:'3', d:3, h:3.79, lu:0.16, md:0.05, mf:false, r:[0,100],t:[40,95],s:{0:'red', 40:'green', 96:'red'}}
      {src:"hydPress_1",x:31.4,y:22.61,l:'1', d:4, h:3.79, lu:0.16, md:0.05, mf:false, r:[0,4000],t:[500,1000,2400],s:{0:'red',501:'green',1001:'red'}}
      {src:"hydPress_2",x:36.75,y:22.61,l:'2', d:4, h:3.79, lu:0.16, md:0.05, mf:false, r:[0,4000],t:[500,1000,2400],s:{0:'red',501:'green',1001:'red'}}
      {src:"hydPress_3",x:42.1,y:22.61,l:'3', d:4, h:3.79, lu:0.16, md:0.05, mf:false, r:[0,4000],t:[500,1000,2400],s:{0:'red',501:'green',1001:'red'}}
    ]

    @instr = new THREE.Object3D()
    @gauges = []
    for d in defs
      g = new VertGauge d.x,d.y,{
                          src:d.src
                          label:d.l
                          digits:d.d
                          height:d.h
                          medsFont:d.mf
                          range:d.r
                          ticks:d.t
                          status:d.s
                          up:d.up
                          labelUp:d.lu
                          boxTop:d.bt
                          meterDn:d.md
                      }, @
      @gauges.push g
      @instr.add g.build(@d)
  
    @group = new THREE.Object3D()
    @group.add @bg
    @group.add @instr

  draw: () ->
    if not @curData?
      @setData()
    for instr in @gauges
      instr.draw(@d)
