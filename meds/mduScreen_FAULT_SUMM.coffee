import * as THREE from 'three'
import {MDUScreen} from 'meds/mduScreen'

export class Screen_FAULT_SUMM extends MDUScreen
  setData: (@curData) ->
    if not @curData?
      @curData = {
        faults: [
          {msg:'MEDS I/O ERROR ADC2B', time:'000/00:00:00'},
          {msg:'MEDS I/O ERROR ADC1B', time:'000/00:00:00'},
          {msg:'MEDS I/O ERROR PLT2', time:'000/00:00:00'},
          {msg:'MEDS I/O ERROR MFD2', time:'000/00:00:00'},
          {msg:'MEDS I/O ERROR MFD1', time:'000/00:00:00'},
          {msg:'MEDS I/O ERROR CDR1', time:'000/00:00:00'},
          {msg:'', time:''},
          {msg:'', time:''},
          {msg:'', time:''},
          {msg:'', time:''},
          {msg:'', time:''},
          {msg:'', time:''},
          {msg:'', time:''},
          {msg:'', time:''},
          {msg:'', time:''},
          {msg:'', time:''}
        ]
      }

  data: () -> return @curData

  build: () ->
    @bg = new THREE.Object3D()

    @bg.add @d.line [[2,4.5],[33,4.5]], @d.c2h.white
    @bg.add @d.line [[37,4.5],[49,4.5]], @d.c2h.white

    @bg.add @d.strMEDS 14,3,"FAULT", @d.c2h.white, scale=1.5,advance=1.0,scalex=.75
    @bg.add @d.strMEDS 41,3,"TIME", @d.c2h.white, scale=1.5,advance=1.0,scalex=.75

    @errors = new THREE.Object3D()
    @errorTxt = []

    @group = new THREE.Object3D()
    @group.add @bg
    @group.add @errors

  draw: () ->
    if not @curData?
      @setData()

    for x in @errorTxt
      @errors.remove(x)
    @errorTxt = []

    for i in [0...15]
      msg = @d.str 2, (i*1.5)+5, @curData['faults'][i]['msg'], @d.c2h.white
      tme = @d.str 37, (i*1.5)+5, @curData['faults'][i]['time'], @d.c2h.white
      @errors.add msg
      @errors.add tme
      @errorTxt.push msg
      @errorTxt.push tme

