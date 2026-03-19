
import * as fs from 'fs'
import * as peg from 'pegjs'
import * as pegutil from 'pegjs-util'
import * as balNodes from 'gpc/lnkasm/balNodes'
util    = require 'util'

import 'com/util'
import Instruction from 'gpc/cpu_instr'
import {BCEInstruction} from 'gpc/iop_bce_instr'

export class Assembler
  constructor: (@symbols) ->
    @parser = require 'gpc/lnkasm/bal.pegjs'

    @csects = {}
    @dsects = {}
    @labels = {}

  assemble: (fileName, str) ->
    treeStr = (tree) -> JSON.stringify tree, null, 1
    result = pegutil.parse @parser,
                            str,
                            startRule:"start",
                            symbols:@symbols,
                            moduleName:fileName,
                            balNodes:balNodes,
    if result.error
      console.log pegutil.errorMessage(result.error)
      return []
    @ast = result.ast
    return result

  @disassemble: (obj, csect) ->
    s = ""
    lc = 0
    cp = csect.baseAddr || 0

    s += "#{cp.asHex(6)}-#{(cp+csect.lc).asHex(6)} #{csect.name.rpad(" ",8)} ****\n"

    i = 0
    while i < obj.length
      curLocCntr = lc
      hw1 = obj[i]
      if i == obj.length-1
        hw2 = 0
      else
        hw2 = obj[i+1]
      d = Instruction.decode(hw1,hw2)
      if not d[0]
        decodedStr = "DC #{hw1.asHex(4)}"
        i = i+1
        lc += 1
        cp += 1
      else
        decodedStr = Instruction.toStr(hw1,hw2)
        if d[0].len == 2
          i = i+2

        if d[0].len == 1
          i = i+1
          code = "#{hw1.asHex(4)}"
          addr = "#{cp.asHex(6)}".rpad(" ",15)
        else
          code = "#{hw1.asHex(4)} #{hw2.asHex(4)}"
          addr = "#{cp.asHex(6)}-#{(cp+1).asHex(6)}".rpad(" ",15)
        lc += d[0].len
        cp += d[0].len
      s += "#{addr}#{csect.name.rpad(" ",8)}+#{curLocCntr.asHex(4)} #{code.rpad(" ",10)} #{decodedStr}\n"

    return s

  link: () ->
    @obj = Array()

    console.log "LINK", @ast.sects
    console.log @ast.syms
    for k,v of @ast.sects
      console.log "SECT", k, v
