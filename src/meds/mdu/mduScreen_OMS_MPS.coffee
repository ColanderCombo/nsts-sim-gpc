import * as THREE from 'three'
import {MDUScreen,VertGauge} from 'meds/mduScreen'

export class Screen_OMS_MPS extends MDUScreen
  setData: (@curData) ->
    if not @curData?
      @curData = {
        omsHeTKP_L: 2500
        omsHeTKP_R: 0
        omsN2TKP_L: 0
        omsN2TKP_R: -1
        omsPcL: 105
        omsPcR: -1
        mpsPneuTK_P: 0
        mpsREG_P: 0
        mpsEngManf_LO2: 2
        mpsEngManf_LH2: 27
        mpsHeTKP_L: 100
        mpsHeTKP_C: 0
        mpsHeTKP_R: 140
        mpsHeREGAP_L: 20
        mpsHeREGAP_C: 44
        mpsHeREGAP_R: 40
        mpsPc_L: 67
        mpsPc_C: 67
        mpsPc_R: 67
      }
    @draw()

  data: () -> return @curData

  build: () ->
    @bg = new THREE.Object3D()
    lines = [
      [[3,3.25], [3,1], [6,1]],
      [[12,1],[31, 1]],
      [[35,1],[50,1],[50,3.25]],
      [[17,1], [17,28.5]]
    ]
    for line in lines
      @bg.add @d.line line, @d.c2h.green

    @bg.add @d.strMEDS 7.9,.36,"OMS", @d.c2h.green, scale=1.5,advance=1.0,scalex=.75
    @bg.add @d.strMEDS 31.57,.36,"MPS", @d.c2h.green, scale=1.5,advance=1.0,scalex=.75

    labels = [
      [3.5,5,"He"],[3.5,6.25,"TK"],[4,7.5,"P"],
      [3.5,13.75,"N"], [4.5,13.90,"2"], [3.5,14.75,"TK"], [4,16,"P"]
      [3.75,24.25,"Pc"],[4.25,25.75,"%"],
      [18,6.75,"TANK"],[19.5,8,"P"],
      [30,5,"He"],[29,6.25,"TANK"],[30.25,7.5,"P"],
      [19,13.75,"REG"],[20,15,"P"],
      [29,13.5,"He"],[28,14.75,"REG A"],[30,16,"P"],
      [19,19,"ENG MANF"],[22.5,22.9,"P"],[22.5,24,"S"],[22.5,25.1,"I"],[22.5,26.2,"A"],
      [35.75,24.46,"Pc"],[36.5,25.46,"%"],
      [41.5,24.46,"Pc"],[42,25.46,"%"],
      [18.75,20.25,"LO2"],[24.2,20.25,"LH2"]
    ]
    for label in labels
      l = @d.str label[0], label[1], label[2], @d.c2h.white
      @bg.add l

    defs = [
      # L(R) OMS He TK PRESS meter / psia / 0-5000 / red:0-1499, green:1500+
      {src:'omsHeTKP_L',x: 6.2,y: 3.5,l:'L', d:4, h:4, bd:-0.11, mf:false, r:[0,5000],t:[1500],s:{0:'red', 1500:'green'}}
      {src:'omsHeTKP_R',x:11.6,y: 3.5,l:'R', d:4, h:4, bd:-0.11, mf:false, r:[0,5000],t:[1500],s:{0:'red', 1500:'green'}}
      # L(R) OMS N2 TK PRESS meter / psia / 0-3000 / red:0-1199 green:1200+
      {src:'omsN2TKP_L',x: 6.2,y:11.5,l:'',  d:4, h:4, mf:false, r:[0,3000],t:[1200],s:{0:'red', 1200:'green'}}
      {src:'omsN2TKP_R',x:11.6,y:11.5,l:'',  d:4, h:4, mf:false, r:[0,3000],t:[1200],s:{0:'red', 1200:'green'}}
      # L(R) OMS Pc meter / % / 0-120 / black:0-3 red:4-79 white:80+
      {src:'omsPcL',x:6.2,y:20.41,l:'L', d:3, h:6.5,mf:true, r:[0,120],t:[80],s:{0:'black',4:'red',80:'white'}}
      {src:'omsPcR',x:11.75,y:20.41,l:'R', d:3, h:6.5,mf:true, r:[0,120],t:[80],s:{0:'black',4:'red',80:'white'}}
      # PNEU He TK PRESS meter / psia / 600-900 / red:3000-3799, green:3800+
      {src:'mpsREG_P',x:22.25,y:3.5,l:'PNEU',d:4,h:4,bd:-0.11,mf:false,r:[3000,5000],t:[3800],s:{0:'red',3800:'green'}}
      # L(C,R) ENG He TK PRESS meter / psia / 1000-5000 / red:600-679 green:680-810 red:811+
      {src:'mpsHeTKP_L',x:32.5,y:3.5,l:'L/2',d:4,h:4,bd:-0.11,mf:false,r:[1000,5000],t:[1150],s:{0:'red',680:'green',811:'red'}}
      {src:'mpsHeTKP_C',x:38.25,y:3.5,l:'C/1',d:4,h:4,mf:false,r:[1000,5000],t:[1150],s:{0:'red',680:'green',811:'red'},up:.50}
      {src:'mpsHeTKP_R',x:44,y:3.5,l:'R/3',d:4,h:4,bd:-0.11,mf:false,r:[1000,5000],t:[1150],s:{0:'red',680:'green',811:'red'}}
      # PNEU He REG PRESS meter / psia / 0-1000 / red:600-679 green:680-810 red:811+
      {src:'mpsREG_P',x:22.5,y:11.66,l:'',d:4,h:4,bd:-0.11,mf:false,r:[600,900],t:[680,810],s:{0:'red',680:'green',811:'red'}}
      # L(C,R) ENG He REG PRESS meter / psia / 0-1000 / red:600-679 green:680-810 red:811+
      {src:'mpsHeREGAP_L',x:32.5,y:11.66,l:'',d:4,h:4,bd:-0.11,mf:false,r:[600,900],t:[680,810],s:{0:'red',680:'green',811:'red'}}
      {src:'mpsHeREGAP_C',x:38.25,y:11.66,l:'',d:4,h:4,mf:false,r:[600,900],t:[680,810],s:{0:'red',680:'green',811:'red'},up:.50}
      {src:'mpsHeREGAP_R',x:44,y:11.66,l:'',d:4,h:4,bd:-0.11,mf:false,r:[600,900],t:[680,810],s:{0:'red',680:'green',811:'red'}}
      # LO2 ENG MANF PRESS meter / psia / 0-300 / green:0-249 red:250+
      {src:'mpsEngManf_LO2',x:18.75,y:21.96,l:'',d:3,h:4,bd:-0.11,mf:false,r:[0,300],t:[249],s:{0:'red',1200:'green'}}
      # LH2 ENG MANF PRESS meter / psia / 0-100 / green:0-65 red:66+
      {src:'mpsEngManf_LH2',x:24.1,y:21.96,l:'',d:3,h:4,bd:-0.11,mf:false,r:[0,100],t:[65],s:{0:'green',66:'red'}}
      # L(C,R) ENG Pc meter / % / 0-115 / red:45-64 white:66+
      {src:'mpsPc_L',x:32.4,y:20.46,l:'L/2',d:3,h:6.5,mf:true,r:[45,109],t:[67,104],s:{0:'red',66:'white'}}
      {src:'mpsPc_C',x:37.9,y:20.46,l:'C/1',d:3,h:6.5,mf:true,r:[45,109],t:[67,104],s:{0:'red',66:'white'},up:.75}
      {src:'mpsPc_R',x:43.75,y:20.46,l:'R/3',d:3,h:6.5,mf:true,r:[45,109],t:[67,104],s:{0:'red',66:'white'}}
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
                          boxDy:d.bd
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