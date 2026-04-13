import {FloatIBM} from 'gpc/floatIBM'
import {EBCDIC_TO_ASCII, ASCII_TO_EBCDIC} from 'gpc/ebcdic'



# HAL/S Runtime Error Groups (AERROR macro GROUP parameter)
SVC_ERROR_GROUPS = {
    1: "RUNTIME"
    2: "RUNTIME"
    3: "RUNTIME"
    4: "RUNTIME"
    5: "RUNTIME"
    6: "RUNTIME"
}

# HAL/S Runtime Error Messages (AERROR macro NUM parameter)
SVC_ERROR_MESSAGES = {
    4:  "EXPONENTIATION OF ZERO TO POWER < = 0"
    5:  "SQRT HAS ARGUMENT < 0 "
    6:  "EXP FUNCTION HAS ARGUMENT > 174.673"
    7:  "LOG FUNCTION (NATURAL LOG) HAS ARGUMENT < = 0"
    8:  "TSIN OR COS FUNCTION HAS |ARGUMENT| > ~2**18Π (823,296)"
    9:  "SINH OR COSH FUNCTION HAS ARGUMENT > 175,366"
    10: "ARCSIN OR ARCCOS FUNCTION HAS ⏐ARGUMENT⏐ > 1"
    11: "TAN FUNCTION HAS |ARGUMENT| > ~2**18Π (823,549.625) (SP) OR ~2**50Π (3.537 X 10**15) (DP)"
    12: "TAN FUNCTION TOO CLOSE TO SINGULARITY"
    14: "NO RETURN STATEMENT IN FUNCTION"
    15: "SCALAR TOO LARGE FOR INTEGER CONVERSION"
    16: "DIVISION BY ZERO IN REMAINDER"
    17: "ILLEGAL CHARACTER SUBSCRIPT"
    18: "BAD LENGTH IN LJUST OR RJUST"
    19: "MOD DOMAIN ERROR "
    20: "CHARACTER TO SCALAR CONVERSION"
    22: "CHARACTER TO INTEGEgpc/halUCP.coffeegpc/halUCP.coffeeR CONVERSION"
    24: "NEGATIVE BASE IN EXPONENTIATION"
    25: "VECTOR/MATRIX DIVISION BY ZERO"
    27: "ARGUMENT OF INVERSE IS A SINGULAR MATRIX"
    28: "ARGUMENT OF UNIT FUNCTION IS NULL VECTOR"
    29: "ILLEGAL BIT STRING "
    30: "ILLEGAL SUBBIT SUBSCRIPT "
    31: "BIT@OCT - INVALID CHARACTER"
    32: "BIT@HEX - INVALID CHARACTER"
    33: "MOD RELATIVE MAGNITUDE ERROR"
    50: "ERROR IN HAL/S SOURCE "
    59: "ARCCOSH FUNCTION HAS ARGUMENT <1"
    60: "ARCTANH FUNCTION HAS ⏐ARGUMENT⏐ >= 1"
    62: "ARCTAN2 ARGUMENTS ARE ZERO"
}

export class HalUCP
  # Emulate the HAL User Control Program
  #
  # The actual AP-101 hardware doesn't directly provide anything like
  # terminal/console I/O.  When running simulated on the 360, the
  # runtime provides READ & WRITE routines supported by the HalUCP
  # which monitors trap addresses to detect READ & WRITE calls.
  #
  # In the runtime IOINIT csect, IOCODE is written to to indicate
  # the operation, and IOBUF is used to send or receive data.
  # HalUCP monitors three addresses; INTRAP, OUTRAP, CNTRAP.
  # When any one of those addresses are executed HalUCP takes over
  # and performs the requested operation.
  #
  # HalUCP also intercepts SVC instructions:
  #   SVC 0         -> program halt (sets wait state)
  #   SVC AERROR    -> SEND ERROR (logs error, continues execution)
  #
  # HAL-S also specifies a FILE statement. HAL/S-FC will compile it 
  # but the original runtime explicitly *did not* support it. There 
  # just isn't an implementation if the original HALUCP.
  #
  # This class is used from both the batch and interactive execution
  # loops.
  #
  # The I/O ops perform conversion to/from the GPC format in IOBUF.
  #
  # Strings may be in ASCII, EBCDIC or DEU format on the GPC.
  # Example HAL programs are in ASCII, so we're defaulting to that
  # for now.
  #
  constructor: (@cpu) ->
    @trapAddrs = null       # { outrap, intrap, cntrap }
    @iocodeAddr = null      # address of IOCODE halfword
    @iobufAddr = null       # address of IOBUF (129 halfwords)
    @waitingForInput = false
    @pendingIocode = null   # iocode that triggered input wait
    @outputCallback = null  # function(text, channel) called to emit output text
    @inputCallback = null   # function(channel, iocode) called to request input
    @controlCallback = null # function(iocode, param, channel) called for control ops
    @errorCallback = null   # function(msg) called for SVC error messages
    @trapSvcError = true    # intercept SEND ERROR SVCs instead of loading new PSW
    @svcTrapped = false     # set true when handleSVC intercepts; caller can check & clear
    @active = false
    @wasRunning = false     # whether we were in run() when input blocked
    @skipTrap = false       # set after provideInput so the trap instruction (BR R4) can execute
    @iobufEncoding = 'ebcdic'  # 'ebcdic' or 'ascii' — determined from symTypes
    @channel = 0            # current I/O channel (set by IOINIT)
    @channelMode = {}       # channel -> 'paged'|'unpaged' (set by IOINIT iocode)
    @inputBuffer = ''       # buffered input text; fields separated by commas, semicolons, or blanks
    @readTerminated = false # set when a semicolon terminates the current READ statement
    @formatNumBlanks = 5    # number of blanks between WRITE fields (spec 12.2 default)
    @verbose = false        # when false, suppress informational/debug stderr output

    # READ/WRITE formatting conventions:
    # The precise rules for how both output formatting and input parsing are derived from:
    #   USA-003087/p.139,sect.12.0 INPUT/OUTPUT STATEMENTS
    #     - lots of detail
    #   USA-003090/p.77,sect.6.0 HAL/S INPUT-OUTPUT OPERATIONS
    #
    # PASS/BFS note: this implements PASS behavior only.
    #
    #
    # * Per-channel WRITE positioning state
    # IOINIT records the default positioning (down 1 line, col 1) 
    # into @deferred[ch] but deferrs emission until the write. 
    # Subsequent SKIP/LINE/PAGE/TAB/COLUMN at the start of a WRITE 
    # modify the deferred state.  When we encounter an actual field,
    # we commit the moves.
    #
    #   * @firstWrite[ch]      false after the first WRITE has been issued
    #                          on that channel (12.2: first WRITE
    #                          positions at line 1 col 1; subsequent WRITEs
    #                          move down a line + col 1)
    #   * @firstField[ch]      true at the start of every WRITE; cleared
    #                          after the first field; gates the 5-blank
    #                          field separator (spec 12.2)
    #   * @column[ch]          1-indexed
    #   * @lineNumber[ch]      1-indexed 
    #   * @deferred[ch]        { downLines, toCol } 
    #   * @suppressNextSep[ch] set true after a TAB/COLUMN; tells the next
    #                          field to skip the standard 5-blank separator
    #                          (12.4: "If a TAB or COLUMN appears
    #                          between two expressions in a WRITE statement,
    #                          it overrides the standard data field
    #                          separation").
    @lineWidth = 132        # spec: 132 for paged
    @linesPerPage = 60      # 60 is a guess
    @firstWrite = {}
    @firstField = {}
    @column = {}
    @lineNumber = {}
    @deferred = {}
    @suppressNextSep = {}

  _log: (s) ->
    process.stderr.write s if @verbose

  # Handle an SVC instruction.  Returns true if the SVC was intercepted
  # (caller should skip the standard PSW swap), false otherwise.
  #
  # ea: effective address of the SVC operand
  # r1: contents of R1 (program data block pointer)
  #
  # SVC 0 (halt) is generated by %SVCI(0) as "SVC 0(R1)", so EA == R1.
  # SEND ERROR is generated by AERROR macro; EA points to ERRPARMS block
  # whose first halfword is 0x0014, second is (group<<8 | num).
  handleSVC: (ea, r1) ->
    return false unless @trapSvcError

    # Debug: dump EA, R1, and memory at EA
    hw0 = if ea >= 0 then @cpu.mainStorage.get16(ea) else 0
    hw1 = if ea >= 0 then @cpu.mainStorage.get16(ea + 1) else 0
    nia = @cpu.psw.getNIA()
    dbg = "SVC DEBUG: ea=0x#{ea.toString(16)} R1=0x#{r1.toString(16)} NIA=0x#{nia.toString(16)}" +
      " mem[ea]=0x#{hw0.toString(16).padStart(4,'0')} mem[ea+1]=0x#{hw1.toString(16).padStart(4,'0')}"
    @_log dbg + "\n"

    # The SVC code is the first halfword at the effective address:
    #   0x0014 = SEND ERROR (AERROR macro)
    #   0x0015 = PROGRAM HALT (%SVCI(0))
    svcCode = if ea >= 0 then @cpu.mainStorage.get16(ea) else 0

    if svcCode == 0x0015
      # Program halt — %SVCI(0) generates SVC D(R1) where D varies by
      # program; the halt is identified by the code 0x0015 at the EA.
      if @inputBuffer.length > 0
        warnMsg = "HalUCP: WARNING: unconsumed buffered input: #{@inputBuffer}"
        if @errorCallback
          @errorCallback(warnMsg)
        else
          @_log warnMsg + "\n"
        @inputBuffer = ''

      # Emit a trailing newline on every channel that has had output;
      for ch of @firstWrite
        @outputCallback?('\n', Number(ch))

      msg = "HAL/S PROGRAM HALT (SVC 0)"
      if @errorCallback
        @errorCallback(msg)
      else
        process.stderr.write msg + "\n"
      @cpu.psw.setWaitState(true)
      @svcTrapped = true
      return true

    if svcCode == 0x0014
      # SEND ERROR — ERRPARMS block at EA: second halfword is descriptor
      errDesc = @cpu.mainStorage.get16(ea + 1)
      errGroup = (errDesc >>> 8) & 0xff
      errNum = errDesc & 0xff
      groupName = SVC_ERROR_GROUPS[errGroup] ? "GROUP #{errGroup}"
      errMsg = SVC_ERROR_MESSAGES[errNum] ? "ERROR #{errNum}"
      msg = "HAL/S SEND ERROR: #{groupName}: ##{errNum} #{errMsg}"
      if @errorCallback
        @errorCallback(msg)
      else
        process.stderr.write msg + "\n"
      # ON ERROR:
      # if the caller has an ON ERROR handler that matches (group, num), 
      # transfer control to the handler instead of returning for standard 
      # fixup. _tryOnErrorDispatch performs a
      # SRET-equivalent unwind and sets NIA to the handler address.
      @_tryOnErrorDispatch(errGroup, errNum)
      # Whether or not dispatch succeeded, we've handled the SVC.
      # On success: PSW now points to the handler.
      # On failure: NIA still points past the SVC → standard fixup runs.
      return true

    # Unknown SVC
    msg = "HAL/S SVC trapped (ea=0x#{ea.toString(16)}, R1=0x#{r1.toString(16)}, code=0x#{svcCode.toString(16)})"
    if @errorCallback
      @errorCallback(msg)
    else
      process.stderr.write msg + "\n"
    @svcTrapped = true
    return true

  initFromSymbols: (symbols, symTypes) ->
    return unless symbols?.sections? and symbols?.symbols?

    # Find IOINIT section base address
    ioinitBase = null
    for sect in symbols.sections
      if sect.name == 'IOINIT'
        ioinitBase = sect.address
        break

    unless ioinitBase?
      @_log "HalUCP: IOINIT section not found in symbols\n"
      return

    # Find INTRAP entry address
    intrapAddr = null
    iocodeAddr = null
    iobufAddr = null
    for sym in symbols.symbols
      switch sym.name
        when 'INTRAP'
          intrapAddr = sym.address if sym.type == 'entry'
        when 'IOCODE'
          iocodeAddr = sym.address if sym.type == 'entry'
        when 'IOBUF'
          iobufAddr = sym.address if sym.type == 'entry'

    unless intrapAddr? and iocodeAddr? and iobufAddr?
      @_log "HalUCP: Missing required symbols (INTRAP=#{intrapAddr}, IOCODE=#{iocodeAddr}, IOBUF=#{iobufAddr})\n"
      return

    # These trap instructions don't have their own labels, but
    # since the code isn't gonna change we can just hardcode their
    # offsets;
    outrap = ioinitBase + 0x11 # in HOUT: BCR 0,0
    cntrap = ioinitBase + 0x40 # # BCR 7,4

    @trapAddrs = { outrap, intrap: intrapAddr, cntrap }
    @iocodeAddr = iocodeAddr
    @iobufAddr = iobufAddr

    # Determine IOBUF character encoding from symTypes
    # Check section-qualified key first, then bare name (same logic as watch pane)
    @iobufEncoding = 'ebcdic'
    if symTypes
      iobufSection = null
      for sect in symbols.sections
        if iobufAddr >= sect.address and iobufAddr < sect.address + sect.size
          iobufSection = sect.name
          break
      typeInfo = null
      if iobufSection
        typeInfo = symTypes["#{iobufSection}.IOBUF"]
      typeInfo ?= symTypes["IOBUF"]
      if typeInfo?.type == 'ascii'
        @iobufEncoding = 'ascii'

    @active = true

    @_log "HalUCP: Trap addresses resolved - OUTRAP=0x#{outrap.toString(16)}, INTRAP=0x#{intrapAddr.toString(16)}, CNTRAP=0x#{cntrap.toString(16)}\n"
    @_log "HalUCP: IOCODE=0x#{iocodeAddr.toString(16)}, IOBUF=0x#{iobufAddr.toString(16)}, encoding=#{@iobufEncoding}\n"

  isTrapAddr: (nia) ->
    return false unless @trapAddrs?
    if @skipTrap
      @skipTrap = false
      return false
    nia == @trapAddrs.outrap or nia == @trapAddrs.intrap or nia == @trapAddrs.cntrap

  checkTrap: (nia) ->
    return 'continue' unless @trapAddrs?

    if nia == @trapAddrs.outrap
      @handleOutput()
      return 'continue'
    else if nia == @trapAddrs.cntrap
      @handleControl()
      return 'continue'
    else if nia == @trapAddrs.intrap
      return @handleInput()
    else
      return 'continue'

  # Return the mode of the current channel: 'paged' or 'unpaged'.
  #   output-only channels default to PAGED,
  #   input channels default to UNPAGED.
  # Set with the code passed to IOINIT
  getChannelMode: (ch) ->
    return @channelMode[ch ? @channel] ? 'paged'

  setChannelMode: (ch, mode) ->
    @channelMode[ch] = mode

  isPaged: (ch) ->
    return @getChannelMode(ch) == 'paged'

  # Format integer for WRITE output: right-justified in 11-character field,
  # leading zeros suppressed, minus sign if negative.
  #
  formatInteger: (val) ->
    str = val.toString()
    if str.length < 11
      str = ' '.repeat(11 - str.length) + str
    return str

  # Format scalar for WRITE output matching ETOC/DTOC format:
  #   SP: sd.dddddddE±dd   (14 chars: sign + d.7digits + E±dd)
  #   DP: sd.ddddddddddddddddE±dd  (23 chars: sign + d.16digits + E±dd)
  #
  formatScalar: (ibmFloat, fracDigits, totalWidth) ->
    v = ibmFloat.toFloat()
    if v == 0
      return (' 0.0').padEnd(totalWidth, ' ')
    sign = if v < 0 then '-' else ' '
    av = Math.abs(v)
    exp = Math.floor(Math.log10(av))
    mantissa = av / Math.pow(10, exp)
    if mantissa >= 10
      mantissa /= 10
      exp += 1
    else if mantissa < 1 and mantissa > 0
      mantissa *= 10
      exp -= 1
    mantissaStr = mantissa.toFixed(fracDigits)
    # toFixed rounding can push mantissa to 10.0 (e.g. 9.9999999x rounds up);
    # renormalize if the decimal point isn't at position 1.
    if mantissaStr.indexOf('.') != 1
      mantissa = mantissa / 10
      exp += 1
      mantissaStr = mantissa.toFixed(fracDigits)
    expSign = if exp >= 0 then '+' else '-'
    expStr = 'E' + expSign + Math.abs(exp).toString().padStart(2, '0')
    return sign + mantissaStr + expStr

  # Emit a single newline to the output stream and bump the line counter
  # (and reset column to 1). Used by both line-wrap and positioning code.
  _newline: (ch) ->
    @outputCallback?('\n', ch)
    @lineNumber[ch] = (@lineNumber[ch] ? 1) + 1
    @column[ch] = 1

  # Notify that an interactive input cycle (prompt newline + user Enter)
  # has moved the shared terminal cursor to a fresh line.  The next
  # WRITE on outputChannel should NOT emit its default line advance
  # because the terminal is already at column 1 of a new line.
  notifyInteractiveInput: (outputChannel) ->
    ch = outputChannel
    @column[ch] = 1
    @suppressNextAdvance ?= {}
    @suppressNextAdvance[ch] = true

  # Apply any deferred positioning from IOINIT/SKIP/LINE/PAGE/TAB/COLUMN
  # to the output stream, then clear it. Called as the first step of every
  # field emission so that the WRITE statement's leading positioning (and
  # any leading SKIP/LINE/PAGE/TAB/COLUMN that overrode the defaults) takes
  # effect just before the first field is written.
  #
  #   12.2 - If the `WRITE` statement is the first to be executed for the 
  #   specified device, the device mechanism positions itself at column 1 
  #   of line 1 (on page 1 if the device is paged). Otherwise, the device 
  #   mechanism moves down one line from its current position, and 
  #   repositions itself at column 1.
  #
  #   12.4 
  #     - If a `SKIP`, `LINE`, or `PAGE` appears at the beginning of a 
  #       `READ` or `WRITE` statement, it overrides the default downward 
  #       movement of one line. 
  #     - If a `TAB` or `COLUMN` appears at the beginning of a `READ` or 
  #       `WRITE` statement, it overrides the default positioning at column 
  #        1. It does not of itself inhibit movement onto the next line.
  #
  #
  _flushPositioning: (ch) ->
    return unless @deferred[ch]?
    pos = @deferred[ch]
    @deferred[ch] = null
    @column[ch] ?= 1
    @lineNumber[ch] ?= 1
    if pos.downLines > 0
      for _ in [0...pos.downLines]
        @_newline(ch)
    if pos.toCol > @column[ch]
      @outputCallback?(' '.repeat(pos.toCol - @column[ch]), ch)
      @column[ch] = pos.toCol
    # Backward column movement (pos.toCol < @column[ch]) is not supported on
    # a stream-based device; we silently leave the cursor where it is.

  # Emit one data field through @outputCallback, applying the inter-field
  # separator and line-wrap rules from the WRITE statement spec:
  #
  #   12.2 
  #     - Data fields are written from left to right along the line, each 
  #       field being separated from the next by 5 blanks†.
  #     - When the end of a line is reached, the device mechanism moves to 
  #       column 1 of the next line and continues writing data fields. Unless 
  #       the data field is of character type, the device does not attempt to 
  #       break it over a line boundary if there is not room for it at the end 
  #       of a line. Instead, it begins writing it on the next line.
  #     - After finishing execution, the device mechanism is left positioned 
  #       one column to the right of the end of the last data field written. 
  #       Alternatively, if the data field abuts the end of a line, it is 
  #       positioned at column 1 of the next line.
  #     - If no expressions are supplied in the `WRITE` statement, the device 
  #       merely performs its initial positioning.
  #
  _emitField: (fieldText, isChar) ->
    ch = @channel
    @_flushPositioning(ch)
    @column[ch] ?= 1

    # 12.4 - If a `TAB` or `COLUMN` appears between two expressions in a 
    #        `WRITE` statement, it overrides the standard data field 
    #        separation..
    needSep = (not @firstField[ch]) and (not @suppressNextSep[ch])
    @suppressNextSep[ch] = false
    sep = if needSep then ' '.repeat(@formatNumBlanks) else ''

    if not isChar
      # Non-character: must fit on one line; otherwise wrap to next line
      # and skip the separator (the line break itself separates the fields).
      if @column[ch] + sep.length + fieldText.length - 1 > @lineWidth
        @_newline(ch)
        @outputCallback?(fieldText, ch)
        @column[ch] += fieldText.length
      else
        if sep.length > 0
          @outputCallback?(sep, ch)
          @column[ch] += sep.length
        @outputCallback?(fieldText, ch)
        @column[ch] += fieldText.length
    else
      # Character: break mid-field as needed.
      # The separator is also breakable (drop it if no room remains).
      if sep.length > 0
        if @column[ch] + sep.length > @lineWidth + 1
          @_newline(ch)
        else
          @outputCallback?(sep, ch)
          @column[ch] += sep.length
      pos = 0
      while pos < fieldText.length
        if @column[ch] > @lineWidth
          @_newline(ch)
        remaining = @lineWidth - @column[ch] + 1
        take = Math.min(remaining, fieldText.length - pos)
        @outputCallback?(fieldText.substring(pos, pos + take), ch)
        @column[ch] += take
        pos += take

    @firstField[ch] = false

  handleOutput: () ->
    iocode = @cpu.mainStorage.get16(@iocodeAddr)
    text = ''
    isChar = false
    switch iocode
      when 8  # BOUT - bit string
        len = @cpu.mainStorage.get16(@iobufAddr)
        bits = @get32(@iobufAddr + 2)  # ST R5,IOBUF+2 → IOBUF + 2 halfwords
        # Format as binary string of specified length
        bitStr = (bits >>> 0).toString(2).padStart(32, '0').substring(32 - len)
        # Insert blank after every 4th digit
        groups = []
        for j in [0...bitStr.length] by 4
          groups.push bitStr.substring(j, j + 4)
        spaced = groups.join(' ')
        if @isPaged()
          # PAGED: binary digits with blanks between groups
          text = spaced
        else
          # UNPAGED: enclosed in apostrophes
          text = "'" + spaced + "'"
      when 9  # IOUT - int32
        val = @get32(@iobufAddr)
        # Sign-extend from 32-bit
        if val & 0x80000000
          val = val - 0x100000000
        text = @formatInteger(val)
      when 10 # HOUT - int16
        val = @cpu.mainStorage.get16(@iobufAddr)
        # Sign-extend from 16-bit
        if val & 0x8000
          val = val - 0x10000
        text = @formatInteger(val)
      when 11 # EOUT - float SP
        w = @get32(@iobufAddr)
        f = FloatIBM.From32(w)
        text = @formatScalar(f, 7, 14)
      when 12 # DOUT - float DP
        w1 = @get32(@iobufAddr)
        w2 = @get32(@iobufAddr + 2)
        f = FloatIBM.From64(w1, w2)
        text = @formatScalar(f, 16, 23)
      when 13 # COUT - character string
        isChar = true
        text = @readCharString()
        unless @isPaged()
          # UNPAGED: enclose in apostrophes, double internal apostrophes
          text = "'" + text.replace(/'/g, "''") + "'"
      else
        text = "[IOCODE=#{iocode}?]"

    @_emitField(text, isChar)

  handleControl: () ->
    iocode = @cpu.mainStorage.get16(@iocodeAddr)
    param = @cpu.mainStorage.get16(@iobufAddr)
    # TAB param is signed (STH from a register that may be negative)
    if iocode == 6 and param & 0x8000
      param = param - 0x10000

    # (ref. RUNASM/IOINIT.asm):
    #   IOINIT: iocode = mode (0=READ, 1=READALL, 2=WRITE, 3=PRINT),
    #           IOBUF[0] = channel number
    #   LINE:   iocode 4, IOBUF[0] = absolute line number
    #   COLUMN: iocode 5, IOBUF[0] = absolute column number
    #   TAB:    iocode 6, IOBUF[0] = relative column delta (signed)
    #   PAGE:   iocode 7, IOBUF[0] = relative page count (positive)
    #   SKIP:   iocode 8, IOBUF[0] = relative line count (>= 0; 0 = noop)
    switch iocode
      when 0, 1, 2, 3 # IOINIT - channel init (param=device number, iocode=mode)
        ch = param
        @channel = ch
        if iocode <= 1
          # READ/READALL: 
          #   10.1.1
          #     3. Unless overridden by explicit `<i/o control>` or 
          #        `<format list>`, the device mechanism is automatically 
          #        moved to the leftmost column position and advanced to 
          #        the next line prior to reading the first `<variable>`. 
          #        A `SKIP`, `LINE`, or `PAGE` before the first `<variable>` 
          #        overrides the automatic line advancement. A `TAB` or 
          #        `COLUMN` overrides the automatic column position.
          @readTerminated = false
          @inputBuffer = ''
        else
          # WRITE/PRINT — set up output positioning.
          # Empty WRITE handling: flush any unflushed deferred from
          # a previous WRITE (12.2: "the device merely performs its
          # initial positioning" for empty WRITEs).
          @_flushPositioning(ch) if @deferred[ch]?
          # 12.2 — If the WRITE statement is the first to be executed
          # for the specified device, the device mechanism positions
          # itself at column 1 of line 1.  Otherwise, the device
          # mechanism moves down one line from its current position,
          # and repositions itself at column 1."
          if @firstWrite[ch] != false
            @firstWrite[ch] = false
            @deferred[ch] = { downLines: 0, toCol: 1 }
          else if @suppressNextAdvance?[ch]
            # Interactive input already moved the terminal to a fresh line;
            # suppress the default line advance so we don't get a blank line.
            delete @suppressNextAdvance[ch]
            @deferred[ch] = { downLines: 0, toCol: 1 }
          else
            @deferred[ch] = { downLines: 1, toCol: 1 }
          @firstField[ch] = true
          @suppressNextSep[ch] = false
      when 4  # LINE - position at absolute line number
        ch = @channel
        @lineNumber[ch] ?= 1
        curLine = @lineNumber[ch]
        if @isPaged(ch)
          # 10.1.3 rule 5 — Paged: if K >= current line, stay on current page;
          # if K < current line, advance to line K of the next page.
          if param >= curLine
            delta = param - curLine
          else
            delta = (@linesPerPage - curLine) + param
        else
          # 10.1.3 rule 5 — Unpaged: absolute line positioning; backward illegal.
          delta = param - curLine
          if delta < 0
            @_log "HalUCP: LINE(#{param}) cannot move upward from line #{curLine}\n"
            delta = 0
        if @deferred[ch]?
          # 12.4 — overrides default downward movement at start of WRITE
          @deferred[ch].downLines = delta
        else
          for _ in [0...delta]
            @_newline(ch)
      when 5  # COLUMN - position at absolute column number
        ch = @channel
        if param < 1
          @_log "HalUCP: COLUMN(#{param}) below column 1\n"
        else if @deferred[ch]?
          # 12.4 — overrides default positioning at column 1 at start of WRITE
          @deferred[ch].toCol = param
        else
          @column[ch] ?= 1
          if param > @column[ch]
            @outputCallback?(' '.repeat(param - @column[ch]), ch)
            @column[ch] = param
          else
            @_log "HalUCP: COLUMN(#{param}); CUR=#{@column[ch]} backwards, umimplemented.\n"
        # 12.4 — TAB or COLUMN between two expressions overrides the
        # standard data field separation.
        @suppressNextSep[ch] = true
      when 6  # TAB - relative column movement (signed)
        ch = @channel
        if @deferred[ch]?
          newCol = @deferred[ch].toCol + param
          if newCol < 1
            @_log "HalUCP: TAB(#{param}) cannot move left of column 1\n"
            newCol = 1
          @deferred[ch].toCol = newCol
        else
          @column[ch] ?= 1
          target = @column[ch] + param
          if target < 1
            @_log "HalUCP: TAB(#{param}) cannot move left of column 1\n"
            target = 1
          if target > @column[ch]
            @outputCallback?(' '.repeat(target - @column[ch]), ch)
            @column[ch] = target
          else
            @_log "HalUCP: TAB(#{param}); negative tab, umimplemented.\n"
        @suppressNextSep[ch] = true
      when 7  # PAGE - move down N pages (paged devices only; provisional)
        ch = @channel
        # 10.1.3 rule 6 — PAGE(K) specifies page movement relative to
        # current page.  K=0 is a no-op.
        #   - emit pagefeed ctrl char?
        if param > 0
          downLines = param * @linesPerPage
          if @deferred[ch]?
            @deferred[ch].downLines = downLines
          else
            for _ in [0...downLines]
              @_newline(ch)
      when 8  # SKIP - move down N lines (relative)
        ch = @channel
        if param < 0
          # 12.4 — alpha may not be negative
          @_log "HalUCP: SKIP(#{param}) negative count not allowed\n"
        else if @deferred[ch]?
          # 12.4 — overrides default downward movement; SKIP(0) suppresses it.
          @deferred[ch].downLines = param
        else
          for _ in [0...param]
            @_newline(ch)
      else
        @_log "HalUCP: Unknown control IOCODE=#{iocode}\n"



  # ---------------------------------------------------------------------------
  # Input field extraction (10.1.1 rules 4-6)
  #
  # Fields are separated by commas, semicolons, or blanks.
  #   - Commas/semicolons between fields can produce null fields (rule 6).
  #   - Semicolons terminate the READ statement (rule 5).
  #   - Blanks separate fields but do not create null fields.
  #   - Character and bit strings are enclosed in apostrophes (Appendix E).
  # ---------------------------------------------------------------------------

  # Extract the next field from @inputBuffer for the given iocode.
  # Returns:
  #   { value: string }     — a normal field
  #   { isNull: true }      — a null field (variable left unchanged)
  #   { terminated: true }  — semicolon terminated the READ
  #   null                  — buffer exhausted, need more input
  _extractNextField: (iocode) ->
    buf = @inputBuffer

    # Skip leading whitespace (not commas/semicolons — those are significant)
    i = 0
    i++ while i < buf.length and (buf[i] == ' ' or buf[i] == '\t' or buf[i] == '\n' or buf[i] == '\r')

    if i >= buf.length
      @inputBuffer = ''
      return null  # buffer exhausted

    c = buf[i]

    if c == ';'
      # 10.1.1 rule 5 — semicolon terminates the READ statement.
      @inputBuffer = buf.substring(i + 1)
      return { terminated: true }

    if c == ','
      # 10.1.1 rule 6 — comma when data expected: null field.
      # The comma is consumed; the data after it (if any) is for the NEXT field.
      @inputBuffer = buf.substring(i + 1)
      return { isNull: true }

    # --- Extract an actual field value ---

    if c == "'" and (iocode == 13 or iocode == 8)
      # Appendix E — character/bit strings are enclosed in apostrophes.
      result = @_parseQuotedString(buf, i)
      @inputBuffer = result.rest
      @_consumeTrailingSeparator()
      return { value: result.value }

    # Numeric or unquoted text: collect until next separator
    j = i
    j++ while j < buf.length and buf[j] != ',' and buf[j] != ';' and
                buf[j] != '\n' and buf[j] != '\r' and
                buf[j] != ' ' and buf[j] != '\t'
    field = buf.substring(i, j)
    @inputBuffer = buf.substring(j)
    @_consumeTrailingSeparator()
    return { value: field }

  # After extracting a field, consume the trailing separator so the next
  # call starts clean.  Whitespace is always consumed.  A single comma is
  # consumed (it separated this field from the next).  Semicolons are NOT
  # consumed — they must be seen by the next call to trigger termination.
  _consumeTrailingSeparator: () ->
    buf = @inputBuffer
    i = 0
    i++ while i < buf.length and (buf[i] == ' ' or buf[i] == '\t')
    if i < buf.length and buf[i] == ','
      i++  # consume one comma separator
    @inputBuffer = buf.substring(i)

  # Parse an apostrophe-enclosed string starting at buf[pos].
  # Apostrophe pairs inside the string represent a single apostrophe.
  _parseQuotedString: (buf, pos) ->
    i = pos + 1  # skip opening apostrophe
    result = ''
    while i < buf.length
      if buf[i] == "'"
        if i + 1 < buf.length and buf[i + 1] == "'"
          result += "'"  # apostrophe pair → single apostrophe
          i += 2
        else
          i++  # closing apostrophe
          break
      else
        result += buf[i]
        i++
    return { value: result, rest: buf.substring(i) }

  handleInput: () ->
    iocode = @cpu.mainStorage.get16(@iocodeAddr)

    # channels used for input default to UNPAGED
    unless @channelMode[@channel]?
      @channelMode[@channel] = 'unpaged'

    # 10.1.1 rule 5 — semicolon terminated a previous field in this READ;
    # all remaining variables are left unchanged.
    if @readTerminated
      @_log "HalUCP: Input IOCODE=#{iocode} skipped (READ terminated by semicolon)\n"
      @skipTrap = true
      return 'continue'

    # Try to extract the next field from the buffer
    field = @_extractNextField(iocode)

    if field?
      if field.terminated
        @readTerminated = true
        @inputBuffer = ''  # discard rest of line after semicolon
        @_log "HalUCP: Input IOCODE=#{iocode} — semicolon terminates READ\n"
        @skipTrap = true
        return 'continue'
      if field.isNull
        # 10.1.1 rule 6 — null field: variable left unchanged
        @_log "HalUCP: Input IOCODE=#{iocode} — null field (unchanged)\n"
        @skipTrap = true
        return 'continue'
      # Normal field
      @_log "HalUCP: Input IOCODE=#{iocode} field=\"#{field.value}\" (remaining: \"#{@inputBuffer}\")\n"
      @pendingIocode = iocode
      @_writeInputValue(field.value)
      @pendingIocode = null
      @skipTrap = true
      return 'continue'

    # Buffer exhausted — request more input
    @waitingForInput = true
    @pendingIocode = iocode
    @_log "HalUCP: Input requested, IOCODE=#{iocode}\n"
    @inputCallback?(@channel, iocode)
    return 'block'

  provideInput: (text) ->
    return unless @waitingForInput

    @inputBuffer += text
    iocode = @pendingIocode

    field = @_extractNextField(iocode)
    unless field?
      # Still not enough data (shouldn't normally happen with a full line)
      @_log "HalUCP: provideInput — still no field after appending\n"
      return

    @waitingForInput = false

    if field.terminated
      @readTerminated = true
      @inputBuffer = ''  # discard rest of line after semicolon
      @_log "HalUCP: Input IOCODE=#{iocode} — semicolon terminates READ\n"
    else if field.isNull
      @_log "HalUCP: Input IOCODE=#{iocode} — null field (unchanged)\n"
    else
      @_log "HalUCP: Input IOCODE=#{iocode} field=\"#{field.value}\" (remaining: \"#{@inputBuffer}\")\n"
      @_writeInputValue(field.value)

    @pendingIocode = null
    @skipTrap = true  # let the trap instruction (BR R4) execute to return to caller

  # Signal end-of-file on an input channel while the program is blocked
  # in a READ. HAL/S programs can install an ON ERROR$(IO:5) handler to
  # catch this; if one is present we unwind the one-deep SCAL frame and
  # branch to the handler. If not, the program is stuck in a READ that
  # can never complete — halt cleanly so it's obvious.
  provideEof: () ->
    return unless @waitingForInput
    # IO = 10, EOF = 5.
    if @_tryOnErrorDispatch(10, 5)
      @waitingForInput = false
      @pendingIocode = null
      @skipTrap = true
      return
    @_log "HalUCP: EOF on input channel #{@channel}, no ON ERROR handler — halting\n"
    msg = "HalUCP: READ exhausted input on channel #{@channel} with no ON ERROR handler installed"
    if @errorCallback
      @errorCallback(msg)
    else
      process.stderr.write msg + "\n"
    @cpu.psw.setWaitState(true)
    @svcTrapped = true
    @waitingForInput = false
    @pendingIocode = null
    @skipTrap = true

  # Simplified ON ERROR handler
  #
  # walks exactly one SCAL frame and checks the single slot at 
  # `caller_stack_end - {2,1}`. This is enough for programs where 
  # `MAXERR=1` and no workspace follows the error
  #
  # Slot layout from HALINCL/GENCLAS0.xpl SET_ERRLOC (line 386):
  #   VAL(OP) = SHL(ERRNUM, 6) + VAL(OP)          -- (num << 6) | group
  #   FIXV    = SHL(TAG, 12) + VAL(LEFTOP)         -- (line 4145)
  #   i.e. FIXV = (TAG << 12) | ((num & 0x3F) << 6) | (group & 0x3F)
  #   TAG = 0 user DO block / 1 SYSTEM / 3 IGNORE
  #   Bare `ON ERROR` → VAL(OP) = "3F" (63, catch-all sentinel)
  _tryOnErrorDispatch: (errGroup, errNum) ->
    # Current R0 points into the RTL routine's SCAL save area (SA).
    # SCAL layout (cpu_instr.coffee:4971): SA..SA+1 = saved PSW1, then
    # R0..R7 each as two halfwords at SA+2+2i and SA+2+2i+1.
    sa = (@cpu.r(0).get32() >>> 16) & 0xffff
    callerR0Hi = @cpu.mainStorage.get16(sa + 2)
    callerR0Lo = @cpu.mainStorage.get16(sa + 3)
    stackEnd = (callerR0Hi + callerR0Lo) & 0xffff
    fixv = @cpu.mainStorage.get16(stackEnd - 2)
    handlerAddr16 = @cpu.mainStorage.get16(stackEnd - 1)

    unless @_matchErrorHandler(fixv, errGroup, errNum)
      @_log "HalUCP: ON ERROR slot FIXV=0x#{fixv.toString(16)} at hw 0x#{(stackEnd-2).toString(16)} does not match (group=#{errGroup},num=#{errNum})\n"
      return false

    # SRET unwind: restore caller's PSW1 and regs:
    psw1hi = @cpu.mainStorage.get16(sa)
    psw1lo = @cpu.mainStorage.get16(sa + 1)
    newPsw1 = ((psw1hi << 16) | psw1lo) >>> 0
    for i in [0..7]
      hi = @cpu.mainStorage.get16(sa + 2 + i * 2)
      lo = @cpu.mainStorage.get16(sa + 2 + i * 2 + 1)
      @cpu.r(i).set32(((hi << 16) | lo) >>> 0)
    @cpu.psw.psw1.set32(newPsw1)

    # Restore BSR/DSR:
    if handlerAddr16 & 0x8000
      handler19 = (@cpu.psw.getBSR() << 15) | (handlerAddr16 & 0x7FFF)
    else
      handler19 = handlerAddr16
    @cpu.psw.setNIA(handler19)
    @_log "HalUCP: dispatched (group=#{errGroup},num=#{errNum}) to ON ERROR handler at 0x#{handler19.toString(16)}\n"
    return true

  # Return true if the given FIXV slot value matches (errGroup, errNum).
  # See PASS1.PROCS/ERRORSUB.xpl and HALINCL/GENCLAS0.xpl (SET_ERRLOC, line 386)
  # for the encoding. 
  # Only user DO: block handled  (TAG=0) (user DO block)
  # SYSTEM and IGNORE not handled
  #
  _matchErrorHandler: (fixv, errGroup, errNum) ->
    return false if fixv == 0
    return true if fixv == 63  # bare ON ERROR catch-all
    tag = (fixv >> 12) & 0x0F
    return false if tag != 0
    numField = (fixv >> 6) & 0x3F
    grpField =  fixv       & 0x3F
    groupOk = (grpField == 0x3F) or (grpField == errGroup)
    numOk   = (numField == 0x3F) or (numField == errNum)
    return groupOk and numOk

  # Write a single input value to IOBUF based on @pendingIocode.
  _writeInputValue: (text) ->
    switch @pendingIocode
      when 8  # BIN - bit string (Appendix E: string of 1s and 0s)
        bits = parseInt(text.replace(/[^01]/g, ''), 2) or 0
        @set32(@iobufAddr, bits >>> 0)
      when 9  # IIN - int32
        val = parseInt(text, 10) or 0
        if val < 0
          val = val + 0x100000000
        @set32(@iobufAddr, val >>> 0)
      when 10 # HIN - int16
        val = parseInt(text, 10) or 0
        if val < 0
          val = val + 0x10000
        @cpu.mainStorage.set16(@iobufAddr, val & 0xFFFF)
      when 11 # EIN - float SP (IEEE -> IBM hex)
        fval = parseFloat(text) or 0.0
        f = new FloatIBM(fval)
        @set32(@iobufAddr, f.to32())
      when 12 # DIN - float DP (IEEE -> IBM hex)
        fval = parseFloat(text) or 0.0
        f = new FloatIBM(fval)
        @set32(@iobufAddr, f.to64x())
        @set32(@iobufAddr + 2, f.to64y())
      when 13 # CIN - character string
        @writeCharString(text)
      else
        @_log "HalUCP: Unknown input IOCODE=#{@pendingIocode}\n"

  # Helper: read 32-bit value from two consecutive halfwords
  get32: (addr) ->
    hi = @cpu.mainStorage.get16(addr)
    lo = @cpu.mainStorage.get16(addr + 1)
    return ((hi << 16) | lo) >>> 0

  # Helper: write 32-bit value as two consecutive halfwords
  set32: (addr, val) ->
    @cpu.mainStorage.set16(addr, (val >>> 16) & 0xFFFF)
    @cpu.mainStorage.set16(addr + 1, val & 0xFFFF)

  # Read character string from IOBUF
  # Format: first halfword = [maxlen:8][curlen:8], followed by packed bytes
  # Encoding depends on @iobufEncoding (determined from symTypes)
  readCharString: () ->
    descriptor = @cpu.mainStorage.get16(@iobufAddr)
    len = descriptor & 0xFF  # current length in low byte
    chars = []
    for i in [0...len]
      hwOffset = Math.floor(i / 2)
      hw = @cpu.mainStorage.get16(@iobufAddr + 1 + hwOffset)
      if i % 2 == 0
        byte = (hw >> 8) & 0xFF  # high byte
      else
        byte = hw & 0xFF         # low byte
      if @iobufEncoding == 'ascii'
        # AP-101S DEU encoding: ASCII except 0x00 = '"' and 0x16 = '_'
        if byte == 0x00
          chars.push('"')
        else if byte == 0x16
          chars.push('_')
        else if byte >= 0x20 and byte < 0x7F
          chars.push(String.fromCharCode(byte))
        else
          chars.push('.')
      else
        chars.push(EBCDIC_TO_ASCII[byte] or '?')
    return chars.join('')

  # Write character string to IOBUF
  # Format: first halfword = [maxlen:8][curlen:8], followed by packed bytes
  writeCharString: (text) ->
    descriptor = @cpu.mainStorage.get16(@iobufAddr)
    maxLen = (descriptor >> 8) & 0xFF  # max length in high byte
    len = if maxLen > 0 then Math.min(text.length, maxLen) else text.length
    # Preserve maxlen in high byte, set curlen in low byte
    @cpu.mainStorage.set16(@iobufAddr, (maxLen << 8) | (len & 0xFF))
    for i in [0...len] by 2
      if @iobufEncoding == 'ascii'
        # DEU encoding: '"' → 0x00, '_' → 0x16
        hiByte = if text[i] == '"' then 0x00 else if text[i] == '_' then 0x16 else text.charCodeAt(i) & 0xFF
        loByte = if i + 1 >= len then 0x20 else if text[i+1] == '"' then 0x00 else if text[i+1] == '_' then 0x16 else text.charCodeAt(i + 1) & 0xFF
      else
        hiByte = ASCII_TO_EBCDIC[text[i]] or 0x40
        loByte = if i + 1 < len then (ASCII_TO_EBCDIC[text[i+1]] or 0x40) else 0x40
      @cpu.mainStorage.set16(@iobufAddr + 1 + Math.floor(i / 2), (hiByte << 8) | loByte)

  # Map iocode to human-readable type name (for input iocodes)
  @iocodeTypeName: (iocode) ->
    switch iocode
      when 8  then 'BIT'
      when 9  then 'INTEGER'
      when 10 then 'SHORT INTEGER'
      when 11 then 'SCALAR'
      when 12 then 'DOUBLE SCALAR'
      when 13 then 'CHARACTER'
      else "UNKNOWN(#{iocode})"

  # Validate that text is convertible to the type required by iocode.
  # Returns null if valid, or an error string if not.
  @validateInput: (text, iocode) ->
    switch iocode
      when 8  # BIT - binary string
        cleaned = text.replace(/[^01]/g, '')
        if cleaned.length == 0
          return "expected binary string (0s and 1s)"
        return null
      when 9  # INTEGER (32-bit)
        if not /^-?\d+$/.test(text.trim())
          return "expected integer"
        val = parseInt(text.trim(), 10)
        if val < -2147483648 or val > 2147483647
          return "integer out of 32-bit range"
        return null
      when 10 # SHORT INTEGER (16-bit)
        if not /^-?\d+$/.test(text.trim())
          return "expected integer"
        val = parseInt(text.trim(), 10)
        if val < -32768 or val > 32767
          return "integer out of 16-bit range"
        return null
      when 11, 12 # SCALAR / DOUBLE SCALAR
        if not isFinite(parseFloat(text.trim()))
          return "expected number"
        return null
      when 13 # CHARACTER
        return null  # any string is valid
      else
        return "unknown iocode #{iocode}"
