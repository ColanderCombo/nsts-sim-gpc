import * as fs from 'fs'

import {Assembler} from 'gpc/lnkasm/assembler'
import {RAM} from 'gpc/regmem'

export class Linker
  #
  # NASA-CR-178827/p.42
  #
  # PROGRAM SECTIONS AND LINKING
  # ----------------------------
  #
  #       It is often convenient, or necessary, to write a large program in
  # sections.  The sections may be assembled separately, then combined into
  # one object program.  The assembler provides facilities for creating
  # multisectiond programs and symbolically linking separately assembled
  # programs or program sections.
  #
  #       Sectioning a program is optional, and many programs can best be
  # written without sectioning them.  The programmer writing an unsectioned
  # program need not concern himself with the subsequente discussion of 
  # program sections, which are called control sections.  He need not employ
  # the CSECT instruction, which is used to identify the control sections of
  # a multisection program.  Similarly, he need not concern himself with the
  # discussion of symbolic linkages if this program neither requires a 
  # linkage to nor receives a linkage from another program.  He may, however,
  # wish to identify the program and/or specify a tentative starting location
  # for it, both of which my be done using the START instruction.  He may also
  # want to employ the dummy section feature obtained by using the DSECT
  # instruction.
  #
  # NOTE:     Program sectioning and linking is closely related to the 
  # specification of base registers for each control section.  Sectioning
  # and linking examples are provided under the heading "Addressing External
  # Control Sections."
  #
  #
  # CONTROL SECTIONS
  # ----------------
  #
  #       The concept of program sectioning is a consideration at coding
  # time, assembly time and load time.  To the programmer, a program is a
  # logical unit.  He may want to divide it into sections called control
  # sections; if so, he writes it in such a way that control passes properly
  # from one section to another regardless of the relative physical position
  # of the sections in storage.  A control section is a block of coding that
  # can be relocated, independantly of other coding, at load time without
  # altering or impairing the operating logic of the program.  It is 
  # normally identified by the CSECT instruction.  However, if it is desired
  # to specify a tentative starting location, the START instruction may be
  # used to identify the first control section.
  #
  #       To the assembler, there is no such thing as a program; instead there
  # is an assembly, which consistes of one or more control sections. (However,
  # the terms assembly and program are often used interchangeably.) An
  # unsectioned program is treated as a single control section.  To the 
  # linkage editor, there are not programs, only control sections that must
  # by fashioned into a load module.
  #
  #       The output from the assembler is called an object module.  It 
  # contains data required for linkage editor processing.  The external
  # symbol dictionary, which is part of the object module, contains 
  # information the linkage editor needs in order to complete cross-
  # referencing between control sections as it combines them into an object
  # program.  The linkage editor can take control sections from various 
  # assemblies and combine them properly with the help of the corresponding
  # control dictionaries.  Sucessful combination of separately assembled
  # control sections depends on the techniques used to provide symbolic
  # linkages between the control sections.
  #
  #

  constructor: (@files,@outPath) ->
    @sects = {}
    @entrys = {}
    @extrns = {}


  link: () ->
    for fileName,data of @files
      #console.log "LC", data
      if not data.ast?
        console.log "ERROR: #{fileName} not assembled"
        continue

      for name,sect of data.ast.sects
        @sects[name] = sect
      for name,entry of data.ast.entrys
        @entrys[name] = entry
      for name,extrn of data.ast.extrns
        @extrns[name] = extrn

    @ram = new RAM(65535)
    @curLC = 0
    @syms = {}

    #console.log data.ast

    #console.log "::::::", @sects

    if @sects['FCMPSA']?
      @sects['FCMPSA'].baseAddr = 0
      @curLC = @curLC + @sects['FCMPSA'].lc


    # Position csects one after another starting at addr=0x0000
    for name,sect of @sects
      if sect.kind == 'DSECT'
        continue
      if not sect.baseAddr?
        @sects[name].baseAddr = @curLC
        @curLC = @curLC + sect.lc
        console.log "LOAD", name, @sects[name].baseAddr
        console.log "LOAD #{name} -> #{(@sects[name].baseAddr).toString(16)} + #{(@sects[name].lc).toString(16)}"

    for name,entry of @entrys
      console.log "SET ABS", name, entry
      console.log "\t\t", entry.csect.baseAddr
      @entrys[name].absAddr = @sects[entry.csect.name].baseAddr + entry.v
      console.log "////", name, entry, @entrys[name].absAddr

    @absCompiled = {}
    a2 = new Assembler(@entrys)
    for name,file of @files
      asm = a2.assemble name,file.srcText
      @absCompiled[name] = asm

    for fileName,data of @absCompiled
      if not data.ast?
        console.log "ERROR: #{name} not assembled"
        continue

      for name,sect of data.ast.sects
        @sects[name] = sect

    @curLC = 0
    @syms = {}


    if 'FCMPSA' of @sects
      @sects['FCMPSA'].baseAddr = 0
      @curLC = @curLC + @sects['FCMPSA'].lc

    # Position csects one after another starting at addr=0x0000
    @sectList = []
    for name,sect of @sects
      if sect.kind == 'DSECT'
        continue
      if not sect.baseAddr?
        @sects[name].baseAddr = @curLC
        @curLC = @curLC + sect.lc
      @sectList.push sect

    @sectList = @sectList.sort (a,b) -> a.baseAddr - b.baseAddr

    disasm = ""

    # write to ram            
    for sect in @sectList
      if sect.kind == 'DSECT'
        continue
      console.log "LOAD #{sect.name} -> #{(sect.baseAddr).toString(16)} + #{(sect.lc).toString(16)}"
      @ram.load16(sect.baseAddr, sect.obj)
      disasm += Assembler.disassemble(sect.obj,sect)

    fs.writeFileSync(@outPath, @ram.data8,'binary')

    disasm += "\n\tSYMBOLS\n\n"
    i = 0
    for name,entry of @entrys
      if entry.csect.kind == 'DSECT'
        disasm += "#{name.rpad(" ",8)}/#{entry.v.asHex(6)}   "
      else
        disasm += "#{name.rpad(" ",8)} #{entry.absAddr.asHex(6)}   "
      i++
      if i == 4
        i = 0
        disasm += "\n"
    disasm += "\n"

    fs.writeFileSync(@outPath+".LIST",disasm)
    
