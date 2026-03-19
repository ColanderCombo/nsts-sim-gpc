  import Instruction from 'gpc/cpu_instr'
  import {BCEInstruction} from 'gpc/iop_bce_instr'
  import {FloatIBM} from 'gpc/floatIBM'

  import * as pegutil from 'pegjs-util'

  export class OpBinary
      constructor: (op,x,y) ->
          if not (@ instanceof OpBinary)
              return new @OpBinary(op,x,y)   
          @node = "OpBinary"    
          @op = op
          @x = x
          @y = y 

      eval: (ctx) ->
        # IBM-GC26-4037-0/p.52
        #
        # Absolute and Relocatable Expressions
        #
        # An expression is called absolute if its value is unaffected by
        # program relocation. An expression is called relocatable if its
        # value depends upon program relocation. The two types of
        # expressions, absolute and relocatable, take on these
        # characteristics from the term or terms composing them.
        # A description of the factors that determine whether an expression
        # is absolute or relocatable follows.
        #
        # ABSOLUTE EXPRESSION: The assembler reduces an absolute
        # expression to a single absolute value if the expression:
        #
        # 1. Is composed of a symbol with an absolute value, a
        #    self-defining term, or a symbol length attribute reference,
        #    or any arithmetic combination of absolute terms.
        # 2. Contains relocatable terms alone or in combination with
        #    absolute terms, and if all these relocatable terms are
        #    paired.
        #
        # PAIRED RELOCATABLE TERMS: An expression can be absolute even
        # though it contains relocatable terms, provided that all the
        # relocatable terms are paired. The pairing of relocatable terms
        # cancels the effect of relocation.
        #
        # The assembler reduces paired terms to single absolute terms in
        # the intermediate stages of evaluation. The assembler considers
        # relocatable terms as paired under the following conditions:
        #
        # • The paired terms must be defined in the same control section
        #   of a source module (that is, have the same relocatability
        #   attribute).
        # • The paired terms must have opposite signs after all unary
        #   operators are resolved. In an expression, the paired terms
        #   do not have to be contiguous (that is, other terms can come
        #   between the paired terms).
        # • The value represented by the paired terms is absolute.
        #
        # The following examples illustrate absolute expressions. A is an
        # absolute term; X and Y are relocatable terms with the same
        # relocatability.
        #
        #   A-Y+X
        #   A
        #   A*A
        #   X-Y+A
        #   *-Y[1]
        # [1] A reference to the location counter must be paired with
        #     another relocatable term from the same control section; that
        #     is, with the same relocatability.
        #
        xv = @x.eval(ctx)
        yv = @y.eval(ctx)
        reloc = xv.reloc or yv.reloc
        switch @op
          when '+'
            return new ExprValue(ctx,xv.v+yv.v,reloc)
          when '-'
            return new ExprValue(ctx,xv.v-yv.v,reloc)
          when '*'

            return new ExprValue(ctx,xv.v*yv.v,reloc)
          when '/'
            # IBM-GC26-4037-0/p.52
            # 3. In division it gives an integer result; any fractional
            #    portion is dropped. Division by zero gives 0.
            #
            v = if (yv.v == 0) then 0 else Math.floor(xv.v/yv.v)
            return new ExprValue(ctx,v,reloc)

  export LA =  (op, head, y, ySkip) ->
      if y.length == 0 then return head
      tail = ([e[1],e[ySkip]] for e in y)
      topExp = new @OpBinary(tail[-1..][0][0], null, tail[-1..][0][1])
      curExp = topExp
      for i in tail[..-2] by -1
          curExp.x = new @OpBinary(i[0],null,i[1])
          curExp = curExp.x
      curExp.x = head

      return topExp  

  export mkList =  (head, rest, valIndex=2) -> [head].concat(x[valIndex] for x in rest) 

  
  export symbolTable = {}
  export externSyms = {}
  export entrySyms = {}

  export defineSymbol = (s) ->
    if s.label in @symbolTable
      pegutil.errorMessage("ERROR: redeclaration of #{s.label} @ #{s.line}.  (prev @ #{@symbolTable[s.label].line}")
    else
      symbolTable[s.label] = s

  export program = []

  export class SECT
    constructor:(@name) ->
      @lc = 0
      @obj = []

    reset:() ->
      @lc = 0
      @obj = []

  export class CSECT extends SECT
    constructor:(name) ->
      super(name)
      @name = name
      @kind = 'CSECT'


  export class DSECT extends SECT
    constructor:(name) ->
      super(name)
      @name = name
      @kind = 'DSECT'


  export class Statement
    constructor: (@label, @cmd, @args,@loc=null,@comment=null) ->
      #@line = location().start.line
      @line = 1

    exec: (ctx) ->

    execForSyms: (ctx) ->


  export class stEQU extends Statement
    constructor: (@label, @expr, @loc=null,@comment=null) ->
        super()
    exec: (ctx) ->
      exprVal = @expr.eval(ctx)
      #console.log "_V_", @expr, exprVal
      #if exprVal.reloc
      #  pegutil.errorMessage("relocatable expression not allows as RHS of EQU")
      ctx.syms[@label] = exprVal

  export class stSECT extends Statement
    constructor: (@name, @op,@loc=null,@comment=null) ->
        super()
    exec: (ctx) ->
      if ctx.sects[@name]?
        ctx.cursect = ctx.sects[@name]
      else
        if @op == 'CSECT'
          ctx.cursect = new CSECT(@name)
        else
          ctx.cursect = new DSECT(@name)
        ctx.sects[@name] = ctx.cursect
        ctx.syms[@name] = new ExprValue(ctx, 0, true)
        if not ctx.entrys[@name]?
          ctx.entrys[@name] = {csect:ctx.cursect, lc:0}


  export class stDS extends Statement
    constructor: (@label, @expr,@loc=null,@comment=null)->
        super()
    exec: (ctx) ->
      if @label
        #if ctx.syms[@label]?
        #  pegutil.errorMessage("Redefinition of #{@label}, #{@loc}")
        #else
        if 1
          ctx.syms[@label] = new ExprValue(ctx,ctx.cursect.lc,true)
      #console.log "stDS.exec", @expr[0]
      obj = @expr[0].eval(ctx)
      ctx.cursect.obj = ctx.cursect.obj.concat obj
      ctx.cursect.lc += obj.length
      #console.log "DS", obj.length, obj, ctx.cursect

  export class stDC extends Statement
    constructor: (@label, @expr,@loc=null,@comment=null)->
        super(0)
    exec: (ctx) ->
      #console.log "STDC", @expr
      obj = @expr[0].obj(ctx)
      #console.log "__", obj
      if @label
        ctx.label(@label)
      ctx.cursect.obj = ctx.cursect.obj.concat obj
      ctx.cursect.lc += obj.length
      #console.log "stDC", ctx, @label, obj, ctx.cursect,ctx.syms

  export class stEXTRN extends Statement
    constructor: (@names,@loc=null,@comment=null) ->
        super()
    exec: (ctx) ->
      for name in @names
        ctx.extrns[name] = []


  export class stENTRY extends Statement
    constructor: (@names,@loc=null,@comment=null) ->
        super()
    exec: (ctx) ->
      for name in @names
        ctx.entrys[name] = {csect:ctx.cursect, lc:ctx.cursect.lc}

  export class stUSING extends Statement
    #
    # NASA-CR-178827/p.28
    #
    # USING -- Use Base Address Register
    # ----------------------------------
    # 
    #   The USING instruction indicates that one or more general registers are
    # available for use as base registers.  This instruction also states the
    # base address values that the assembler may assume will be in the 
    # registers at object time.  Note that a USING instruction does not load the
    # registers specified.  It is the programmer's responsibility to see that 
    # the specified base address values are placed in the registers specified.
    # Suggested loading methods are described in the subsection 
    # "Programming with the USING Instruction."  A reference to any name in a
    # control section cannot occur in a machine instruction or any S-type 
    # address constant before the USING statement that makes that name
    # addressable.  The format of the USING instruction statement is:
    #
    # |-----------------|-----------|-----------------------|
    # |       Name      | Operation |        Operand        |
    # |-----------------|-----------|-----------------------|
    # | A sequence      | USING     | From 2-17 expressions |
    # | symbol or blank |           | of the form v,r1,     |
    # |                 |           | r2,r3,...,r16         |
    # |-----------------|-----------|-----------------------|
    # 
    #     Operand v must be an absolute or relocatable expression. It may be a
    # negative number whose absolute value does not exceed 2**24.  No literals
    # are permitted.  Operand v specifies a value that the assmebler can use as
    # a base address.  The other operands must be absolute expressions.  The 
    # operand r1 specifies the general register that can be assumed to contain
    # the base address represented by operand v. Operands r2, r3, r3,...
    # specify registers that can be assumed to caontain v+4096, v+8192,
    # v+12288, ..., respectively.  The values of the operands r1, r2, r3, ...
    # r16 must be between 0 and 15.  For example, the statement:
    #
    # |------|-----------|---------|
    # | Name | Operation | Operand |
    # |------|-----------|---------|
    # |      | USING     | *,12,13 |
    # |------|-----------|---------|
    # 
    # tells the assembler it may assume the current value of the location 
    # counter will be in general register 12 at object time, and that the
    # current value of the location counter, incremented by 4096, will be in
    # general register 13 at object time.
    #
    #     If the programmer changes the value in a base register currently
    # being used, and wishes the assembler to compute displacement from this
    # value, the assmebler must be told the new value by means of another USING
    # statement. In the following sequence the assmebler first assumes that the
    # value of ALPHA is in register 9.  The second statement then causes the
    # assembler to assume that ALPHA+1000 is the value in register 9.
    # 
    # |------|-----------|--------------|
    # | Name | Operation |   Operand    |
    # |------|-----------|--------------|
    # |      | USING     | ALPHA,9      |
    # |      | .         |              |
    # |      | .         |              |
    # |      | USING     | ALPHA+1000,9 |
    # |------|-----------|--------------|
    # 
    #     If the programmer has to refer to the first 4096 bytes of storage, he
    # can use general register 0 as a base register subject to the following
    # conditions:
    #
    #     1.  The value of operand v must be either absolute or relocatable
    #         zero or simply relocatable
    #
    #     2.  Register 0 must be specified as operand r1.
    #
    #     The assmebler assumes that register 0 contains zero.  Therefore,
    # regardless of the value of operand v, it calculates displacements as if
    # operand v were absolute or relocatable zero. The assembler also assumes
    # that subsequent registers specified in the same USING statement contain
    # 4096, 8182, etc.
    #
    # NOTE:     If register 0 is used as a base register, the program is not
    # relocatable, despite the fact that operand v may be relocatable.  The 
    # program can be made relocatable by:
    #
    #     1.  Replacing register 0 in the USING statement.
    #
    #     2.  Loading the new register with a relocatable value.
    #
    #     3.  Reassembling the program.
    #
    constructor: (@symbol,@loc=null,@comment=null) ->
        super()
    exec: (ctx) ->
      regs = (x.eval(ctx) for x in @symbol[1...])
      ctx.using[@symbol[0].expr.sym] = regs[0].v


  export class stDROP extends Statement
    #
    # DROP -- Drop Base Register
    # --------------------------
    #
    #     The DROP instruction specifies a previously available register that
    # may no longer be used as a base register.  The format of the DROP
    # instruction statement is as follows:
    #
    # 
    # |-----------------|-----------|--------------------|
    # |       Name      | Operation |      Operand       |
    # |-----------------|-----------|--------------------|
    # | A sequence      | DROP      | Up to 16 absolute  |
    # | symbol or blank |           | expressions of the |
    # |                 |           | form r1,r2,        |
    # |                 |           | r2,...,r16         |
    # |-----------------|-----------|--------------------|
    # 
    #     The expression indicates general registers previously named in a 
    # USING statement that are now unavailable for base addressing.  The 
    # following statement, for example, prevents the assembler from using 
    # registers 7 and 11:
    #
    # |------|-----------|---------|
    # | Name | Operation | Operand |
    # |------|-----------|---------|
    # |      | DROP      | 7,11    |
    # |------|-----------|---------|
    # 
    #     It is not necessary to use a DROP statement when the base address
    # being used is changed by a USING statement; nor are DROP statements
    # needed at the end of the source program.
    #
    #     A register mad unavailable by a DROP instruction can be made
    # available again by a subsequent USING instruction.
    #
    constructor: (@symbol,@loc=null,@comment=null) ->
        super()
    exec: (ctx) ->

  export class stSPACE extends Statement
    constructor: (@loc=null,@comment=null) ->
        super()
      exec: (ctx) ->


  export class stLTORG extends Statement
    #
    # LTORG -- BEGIN LITERAL POOL
    # ---------------------------
    #
    #   The LTORG instruction causes all literals since the previous LTORG
    # (or start of the program) to be assembled at appropriate boundaries
    # starting at the first double-word boundary following the LTORG 
    # statement.  If no literals follow the LTORG statement, alignment of
    # the next instruction (which is not an LTORG instruction) will occur.
    # Bytes skipped are not zeroed.  The format of the LTORG instruction
    # statement is:
    #
    #     |-----------------|-----------|----------|
    #     |       Name      | Operation | Operand  |
    #     |-----------------|-----------|----------|
    #     | Symbol or Blank | LTORG     | Not Used |
    #     |-----------------|-----------|----------|
    #
    #   The symbol represents the address of the first byte of the literal
    # pool.  It has a length attribute of 1.
    #
    #   The literal pool is organized into four segments within which the
    # literals are stored in order of appearance, dependent on the 
    # divisibility properties of their object lengths (dup factor times
    # total explicit or implied length).  The first segment contains all 
    # literals whos object length is a multiple of eight.  Those remaining
    # literals with lengths divisible by four are stored in the second
    # segment.  The third segment holds the remaining even-length literals.
    # Any literals left over have odd lengths and are stored in the fourth
    # segment.
    #
    #   Since each literal pool begins at a double-word boundary, this 
    # guarantees that all segment one literals are double-word, segment two
    # full-word, and segment three half-word aligned, with no space wasted
    # except, possibly, at the pool origin.
    #
    #   Literals from the following statement are in the pool, in the 
    # segments indicated by the circles numbers, where (8) means multiples
    # of eight, etc.,
    #
    #   MVC  A(12),=3F'1'  (4)
    #    SH  3,=H'2'            (2)
    #    LM  0,3,=2F'1,2'  (8)
    #    IC  2,=XL1'1'          (1)
    #    AD  2,=D'2'       (8)
    # 
    #   Special Addressing Consideration
    #   --------------------------------
    #
    #     Any literals used after the last LTORG statement in a program are
    # placed at the end of the first control section.  If there are no LTORG
    # statements in a program, all literals used in the program are placed
    # at the end of the first control section.  In these circumstances the
    # programmer must ensure that the first control section is always
    # addressable.  This means that the base address register for the first
    # control section should not be changed through usage in subsesquent 
    # control sections.  If the programmer does not wish to reserve a 
    # register for this purpos, he may place an LTORG statement at the end
    # of each control section thereby ensureing that all literals appearing
    # in that section are addressable.
    #
    #   Duplicate literals
    #   ------------------
    #
    #     If duplicate literals occur within the range controlled by one
    # LTORG statement, only one literal is stored.  Literals are considered
    # duplicates only if their specifications are identical.  A literal will
    # be stored, even if it appears to duplicate another literal, if it is 
    # an A-type address constant containing any reference to the location
    # counter.
    #
    #     The following examples illustrate how the assembler stores pairs
    # of literals, if the placement of each pair is controlled by the same
    # LTORG statement.
    #
    #     X'F0'
    #               Both are stored
    #     C'0'
    #
    #     XL3'0'
    #               Both are stored
    #     HL3'0'
    #
    #     A(*+4)
    #               Both are stored
    #     A(*+4)
    #
    #     X'FFFF'
    #               Identical; the first is stored
    #     X'FFFF'
    #
    constructor: (@loc=null,@comment=null) ->
        super()
    exec: (ctx) ->


  export class stOP extends Statement
    constructor: (@label, @oo, @args=null, @loc=null,@comment=null) ->
      super()
      @op = @oo.op
      @indirect = @oo.indirect
      @autoindex = @oo.autoindex
      @rewriteBRANCH()

    rewriteBRANCH: () ->
      # bops = {   B:7, NOP:0   # unconditional
      #           BZ:4, BNZ:2,  # zero/not zero
      #           BM:2, BNM:5,  # minus/not minus | mixed/not mixed
      #           BP:1, BNP:6,  # positive/not positive
      #           BE:4, BNE:3,  # equal/not equal
      #           BO:1, BNO:6,  # ones/not ones
      #           BH:1, BNH:6,  # high/not high
      #           BL:2, BNL:5  # low/not low
      #        }
      bops = { B:7, NOP:0, BZ:4, BNZ:2,BM:2, BNM:5,BP:1, BNP:6,BE:4, BNE:3,BO:1, BNO:6,BH:1, BNH:6,BL:2, BNL:5 }
      if bops[@op]?
        @args.unshift(new Arg(v:new Expression(new SelfDefTerm(bops[@op],false))))
        @op = 'BC'

    exec: (ctx) ->
      #console.log "EXEC", @op, @args,@label
      if @label
        ctx.label(@label)

      console.log "EXEC", @

      if @op of Instruction.descByOp
        desc = Instruction.descByOp[@op]
      else if @op of Instruction.descByOp
        desc = BCEInstruction.descByOp[@op]

      console.log "stOP.exec:desc=", desc

      hasIndexed = (desc.s.length == 2)
      argStr = desc.s[0].split(' ')[1]

      y = {}

      if argStr == 'R2'
        x = {y:@args[0].evalAsReg(ctx)}
      else if argStr == 'D2(B2)'
        x = @args[0].evalAsAddr(ctx)
      else if argStr == 'R1,R2'
        x = {x:@args[0].evalAsReg(ctx)}
        y = {y:@args[1].evalAsReg(ctx)}
      else if argStr == 'R1,D2(B2)'
        x = {x:@args[0].evalAsReg(ctx)}
        y = @args[1].evalAsAddr(ctx)
      else if argStr == 'R1,D2'
        x = {x:@args[0].evalAsReg(ctx)}
        y = {d:@args[1].evalAsImm(ctx)}
      else if argStr == 'R1,Count'
        x = {x:@args[0].evalAsReg(ctx)}
        y = {d:@args[1].evalAsImm(ctx)}
      else if argStr == 'R1,Value'
        x = {x:@args[0].evalAsReg(ctx)}
        y = {d:@args[1].evalAsImm(ctx)}
      else if argStr == 'R2,Data'
        x = {y:@args[0].evalAsReg(ctx)}
        y = {d:@args[1].evalAsImm(ctx)}
      else if argStr == 'D2(B2),Data'
        x = @args[0].evalAsAddr(ctx)
        y = {I:@args[1].evalAsImm(ctx)}
      else if argStr == 'M1,R2'
        x = {x:@args[0].evalAsImm(ctx)}
        y = {y:@args[1].evalAsReg(ctx)}
      else if argStr == 'M1,D2'
        x = {x:@args[0].evalAsReg(ctx)}
        y = @args[1].evalAsDsp(ctx)
      else if argStr == 'M1,D2(B2)'
        x = {x:@args[0].evalAsImm(ctx)}
        y = @args[1].evalAsAddr(ctx)
      else
        pegutil.errorMessage("BAD ARGS STRING:", desc.s[0], @loc)

      console.log @op, argStr, x, y

      ins = {
        nm: @op
      }
      ins = Object.assign({},ins,x,y)
      console.log "INS:", ins

      encoded = Instruction.encode(ins)
      console.log "ENCODED", encoded
      if encoded[0] != -1
        ctx.cursect.obj = ctx.cursect.obj.concat(encoded)
        #console.log ctx.cursect.obj
        ctx.cursect.lc += encoded.length
      else
        pegutil.errorMessage("Unable to assemble: ",ins, @loc, @comment)


  export class stComment extends Statement
    constructor: (@text,@loc=null) ->
        super()
    exec: (ctx) ->

  export class BalContext
    constructor:(options) ->
      #console.log "=====",options
      @globalSymbols = options.symbols
      @moduleName = options.moduleName

      @sects = {}
      @cursect = undefined
      @syms = {}
      @extrns = {}
      @entrys = {}
      @using = {}
      @literals = []

    label: (name) ->
      #console.log "|| label || #{name}", @syms
      @syms[name] = new ExprValue(@,@cursect.lc,true)

    undefinedSymbol: (sym) ->
      if @failOnUndefined
        pegutil.errorMessage("ERROR: Undefined Symbol '#{sym}'")

    exec: (program) ->
      console.log ">>> exec ***************"
      console.log "    execForSyms ********"
      @execForSyms(program)
      console.log "    execForObj  ********"
      @execForObj(program)
      console.log "<<< exec ***************"

      @newEntries = {}
      for k,v of @entrys
        console.log "-------------COPY", k,v
        @newEntries[k] = @syms[k]
      @entrys = @newEntries

    execForSyms: (program) ->
      @failOnUndefined = false
      for l in program
        if l.exec?
          #console.log l
          l.exec(@)
      #console.log @sects
      for k,sect of @sects
        sect.reset()
      @using = {}
      #console.log "SYMBOLS", @.syms
      #console.log @sects

    execForObj: (program) ->
      @failOnUndefined = true
      for l in program
        if l.exec?
          #console.log l
          l.exec(@)


  export sects = {}
  export cursect = undefined
  export plc = 0



  export printSymbolTable = () ->
      for k,v of @symbolTable
        console.log "SYMBOL", k, "=", v

  export class Term
    constructor: (@ctx,@v) ->
      @reloc = false

  export class Symbol extends Term
    constructor: (@sym) ->
      super()

    eval: (ctx) -> @sym

  export class LocCountRef extends Term
    constructor: () ->
      super(0)
      @reloc = true

    eval: (ctx) -> new ExprValue(ctx, ctx.cursect.lc, @reloc)

  export class SymbolLengthAttr extends Term
    constructor: (@symName) ->
      super()
      @reloc = false

  export class OtherDataAttr extends Term
    constructor: (@ctx,@v) ->
      super()
      1
  export class SelfDefTerm extends Term
    constructor: (@v) ->
      super()
      @reloc = false

    @makeChar: (ctx,c) ->
      if c.length > 4
        pegutil.errorMessage('character self defining term must be 1 to 4 characters long')
      v = 0
      for i in [c.length...0]
        v += c[i] << (8*i)
      new @ ctx,v

    eval: (ctx) -> 
      new ExprValue(ctx,@v,@reloc)


  export class ExprValue
    constructor: (@ctx,@v,@reloc) ->
      if @reloc
        @csect = @ctx.cursect

    eval: () -> @

    obj: (ctx) -> [@v]

    absObj: (ctx) ->
      if @reloc and @absAddr
        return [@absAddr]
      else
        return [@v]

  export class UndefinedValue extends ExprValue
    constructor: (@ctx,@sym) ->
      super()
    eval: () -> @

  export class Value
    constructor: (@a) ->
      @absolute = true
    obj: (ctx) -> [@eval(ctx)]

  export class Constant extends Value
    constructor: (@t,@v,@strLen) ->
      super()
      switch @t
        when 'HEX'
          @size = Math.ceil(Math.max(1,@strLen/4))
          v = []
          for i in [@size-1..0]
            beg = Math.max(0,@strLen-4*(i+1))
            end = @strLen-4*i
            v.push parseInt(@v.slice(beg,end),16)
          @s = @v
          @v = v
        when 'BIN'
          @size = Math.ceil(Math.max(1, @strLen/(1/8)))
        when 'DEC'
          @size = Math.ceil(@v/0xffff)

      # if @size % 2
      #     @size = @size+1

    eval: (ctx) -> 
      #console.log "EVAL Constant", @v
      if typeof(@v) is 'object'
        return Array.from(@v)
      else if @v.length
        return @v[@v.length-1]
      else
        return @v

    obj: (ctx) ->
      if @v.length
        return @v
      else
        return [@v]

    absObj: (ctx) -> @obj(ctx)




  export class FloatSingleConstant extends Constant
    constructor:(@fv) ->
      super()
      if @fv.length?
        @size = @fv.length*4
      else
        @size = 4

      @v  = []
      for x,i in @fv
        fl = FloatIBM.FromFloat(x)
        @v = @v.concat fl.obj32()

    eval: (ctx) -> 
      if typeof(@v) is 'object'
        return Array.from(@v)
      else if @v.length
        return @v[@v.length-1]
      else
        return @v



  export class FloatDoubleConstant extends Constant
    constructor:(@fv) ->
      super()
      if @fv.length?
        @size = @fv.length*8
      else
        @size = 8
      buf = new ArrayBuffer(@size)
      bytes = new Uint16Array(buf)
      fl = new Float64Array(buf)
      for x,i in @fv
        fl[i] = parseFloat(x)
      #@v = [bytes[0], bytes[1], bytes[2], bytes[3]]
      console.log "FDC",@fv,bytes
      @v = Array.from(bytes)  


  export class Literal extends Value
    constructor: (@v) ->
      super()

    eval: (ctx) ->
      ctx.literals.push([@v.eval(ctx), ctx.cursect, ctx.cursect.lc])

  export class DataConstant extends Value
    constructor: (@dupeFactor, @type, @dataModifiers, @inValue) ->
      super()
      #console.log "CONS", @dupeFactor, @type, @dataModifiers, @inValue
      @dupeFactor ?= new Constant('DECIMAL',1,1)
      @type ?= 'D'
      @dataModifiers ?= {}
      @inValue ?= [0]
      # @value provided as array of strings, parse to constants:
      switch @type
        when 'X'
          #console.log "X", @value
          @value = (new Constant('HEX',x,x.length) for x in @inValue)
        when 'B'
          @value = (new Constant('BIN',parseInt(x,2),x.length) for x in @inValue)
        when 'C'
          @value = (new Constant('STR',@_evalString(@inValue), @inValue.length))
        when 'E'
          #console.log "E type", @dupeFactor, @type, @dataModifiers, @inValue
          @value = [new FloatSingleConstant(@inValue)]
          #console.log "Float", @value
        when 'D'
          @value = [new FloatDoubleConstant(@inValue)]
        else
          inVal = @inValue
          @value = []
          for x in inVal
            if typeof(x) is 'string'
              @value = @value.concat [new Constant('DECIMAL',parseInt(x,10),x.length)]
            else if typeof(x) is 'number'
              @value = @value.concat [new Constant('DECIMAL',x,x.toString(10).length)]
            else
              @value = @value.concat [x]

      #console.log "new DataConstant", @value

    _evalString: (v) ->
      # character strings are assembled as a series of 8-bit bytes
      # (EBCDIC in the 360 spec, DEU for the FC, but ASCII for now)
      # string is left-aligned in 16-bit words, padded with spaces
      #
      strBuf = Uint8Array.from(v, (x) -> x.charCodeAt())
      bLen = v.length
      if bLen%2 then bLen++      # Align on 16-bit boundary
      o = new ArrayBuffer(bLen)
      o8 = new Uint8Array(o)
      o16 = new Uint16Array(o)
      o8.fill(" ".charCodeAt())  # Pad with spaces
      o8.set(strBuf)
      return o16

    eval: (ctx) ->
      @oneValue = []
      if not @value.length
        @oneValue = @value.eval(ctx).obj(ctx)
      for v in @value
        @oneValue = @oneValue.concat(v.obj(ctx))
      #console.log "\t\t", @oneValue
      count = if @dupeFactor? then @dupeFactor.eval(ctx) else 1
      if @dataModifiers.length?
        count = count * @dataModifiers.length.eval(ctx).v
      expanded = []
      for i in [0...count]
        expanded = expanded.concat(@oneValue)
      #console.log "EXPAND",expanded
      return expanded
    obj: (ctx) -> @eval(ctx)

  export class AddrConstant extends DataConstant
    constructor: (dupeFactor, type, dataModifiers, inValue) ->
      super dupeFactor, type, dataModifiers, inValue

    eval: (ctx) ->
      #console.log "AddrConstant", @value, @value[0].eval(ctx)
      @oneValue = []
      if not @value.length
        @oneValue = @value.eval(ctx).absObj(ctx)
      for v in @value
        ev = v.eval(ctx)
        if ev.absObj?
          ev = ev.absObj(ctx)
        @oneValue = @oneValue.concat(ev)
      #console.log "\t\t", @oneValue
      count = if @dupeFactor? then @dupeFactor.eval(ctx) else 1
      if @dataModifiers.length?
        count = count * @dataModifiers.length.eval(ctx).v
      expanded = []
      for i in [0...count]
        expanded = expanded.concat(@oneValue)
      #console.log "EXPAND",expanded
      return expanded

    obj: (ctx) -> @eval(ctx)


  export class Expression extends Value
    constructor: (@expr) ->
      super()
      #console.log "Expression", @expr

    eval: (ctx) -> @expr.eval(ctx)

    obj: (ctx) -> @eval(ctx).v

  export class CurLoc extends Value
    constructor: () ->
      super()
    eval: (ctx) -> ctx.cursect.lc

  export class Length extends Value
    constructor: (@sym) ->
      super(0)
    eval: () -> "LENGTH(#{@sym})"

  export class Var extends Value
    constructor: (@sym) ->
      super()
    eval: (ctx) ->
      #console.log "Var.eval", ctx, @
      #console.log "Var->", @sym, @sym of ctx.extrns, ctx.syms[@sym], ctx.globalSymbols
      if ctx.globalSymbols? and @sym of ctx.globalSymbols
        #console.log "((((((", @sym, ctx.globalSymbols[@sym]
        #return new ExprValue(ctx,ctx.globalSymbols[@sym].absAddr,false)
        return ctx.globalSymbols[@sym]
      else if ctx.syms[@sym]?
        return ctx.syms[@sym]
      else if @sym of ctx.extrns
        #console.log "EXTERN ", @sym, ctx.extrns[@sym]
        loc = ctx.cursect.lc
        if ctx.evalPos == 2
          loc = loc + 1
        ctx.extrns[@sym].push {csect:ctx.cursect, lc:loc}
        return new ExprValue(ctx,0xfff,true)
      else
        ctx.undefinedSymbol(@sym)
        return new UndefinedValue(ctx,@sym)

  export class Arg
    constructor: ({v,d,i,b}={})  ->
      @v = v
      @d = d
      @i = i
      @b = b
      #console.log "ARG", @v, @d, @i,@b

    evalAsReg: (ctx) ->
        #console.log "evalAsReg", @
        if @d? or @i? or @b? or not @v?
            pegutil.errorMessage("Expected immediate value")
        reg = @v.eval(ctx)
        if reg.v < 0 or reg.v > 7
            pegutil.errorMessage("Register value must be between 0 and 7")
        return reg

    evalAsImm: (ctx) ->
        #console.log "evalAsImm", @
        if @d? or @i? or @b? or not @v?
            pegutil.errorMessage("Expected immediate value")
        @v.eval(ctx)

    evalAsAddr: (ctx) ->
      #console.log "evalAsAddr", @
      if @v?
        D2 = @v.eval(ctx)
        @d = @v
        delete @v
      else
        D2 = @d.eval(ctx)


      if D2.reloc == true
        # if both index and base are already specified, error
        if @i? and @b?
          pegutil.errorMessage("base-disp conversion failed; explicit base+index provided.")
        console.log "||", D2.csect.name, ctx.using[D2.csect.name], (D2.csect.name of ctx.using)
        if D2.csect.name of ctx.using
          if @b?
            @i = @b
          @b = new ExprValue(ctx,ctx.using[D2.csect.name],false)
          D2.reloc = false
          @d = D2
          return {d:D2, b:@b, i:@i}
        else
          #console.log "no using, ", @, ctx
          # no base register set, force no base addressing (RS & b=3)
          @b = new ExprValue(ctx,99,false)
          @d = D2
          if @d.absAddr
            @d.v = @d.absAddr
          return {d:D2, b:@b}
      else
        if @b
          B2 = @b.eval(ctx)
        else 
          B2 = undefined
        if @i
          I = @i.eval(ctx)
        else
          I = undefined
        return {d:D2, b:B2, i:I}

      #console.log "D2", D2, @, ctx.using

    evalAsDsp: (ctx) ->
      if @v?
        { d: @v.eval(ctx) }
      else
        if @i?
          iv = @i.eval(ctx)
          if @b?
            bv = @b.eval(ctx)
          else
            bv = 0
          if @d?
            dv = @d.eval(ctx)
          else
            dv = 0
          { d: dv, b: bv, i: iv}
        else if @b?
          { d: @d.eval(ctx),b: @b.eval(ctx)}
        else
          { d: @d.eval(ctx) }

    eval_1st: (ctx) ->
      if @v?
        return {x:@v.eval(ctx)}
      else
        return @eval_2nd(ctx)
      
    eval_2nd: (ctx) ->
      #console.log "2nd", @, @v.eval(ctx)
      if @v?
        { d: @v.eval(ctx) }
      else
        if @i?
          iv = @i.eval(ctx)
          if @b?
            bv = @b.eval(ctx)
          else
            bv = 0
          if @d?
            dv = @d.eval(ctx)
          else
            dv = 0
          { d: dv, b: bv, i: iv}
        else if @b?
          { d: @d.eval(ctx),b: @b.eval(ctx)}
        else
          { d: @d.eval(ctx) }

