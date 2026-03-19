import * as fs from 'fs'

import {Assembler} from 'gpc/lnkasm/assembler'
import {Linker} from 'gpc/lnkasm/linker'

export class Make
  constructor: (@configfile) ->
    @baseDir = '.'
    @outDir = '.'
    @srcFiles = []
    @compiled = {}
    @resultName = 'memImage.fcm'

    @_readConfig(@configfile)


  _readConfig: (configFile) ->
    configData = fs.readFileSync configFile, 'utf8'
    configLines = configData.split('\n')
    for l in configLines
      cmd = l.split(' ')[0]
      d = l.split(' ')[1...]
      switch cmd
        when 'd' then @baseDir = d[0]
        when 'o' then @outDir = d[0]
        when 'f' then @srcFiles.push d[0]
        when 'r' then @resultName = d[0]

  make: () ->
    for f in @srcFiles
      console.log "ASSEMBLE", f
      srcText = fs.readFileSync "#{@baseDir}/#{f}", 'utf8'
      assembler = new Assembler()
      asm = assembler.assemble f,srcText
      if asm == []
        console.log "Assembly of #{f} failed"
        return
      @compiled[f] = asm
      @compiled[f].srcText = srcText

    @linker = new Linker(@compiled,"#{@outDir}/#{@resultName}")
    @linker.link()
