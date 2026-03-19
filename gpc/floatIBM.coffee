
Long = require 'long'

export class FloatIBM
  # A floating -point number consists of a signed exponent and a signed 
  # fraction. The quantity expressed by this number is the product of the
  # fraction and the number 16 raised to the power of the exponent. The
  # exponent is expressed in excess 64 binary notattion; the fraction is
  # expressed as a sign-magnitude hexadecimal number having a radix point
  # to the left of the high order digit.
  #
  # ... A normalized number is one in which the high-order hexadeximal
  # digit of the fraction is not zero or the fraction is all zero and 
  # the characteristic is the smallest possible value (zero).
  #
  #   Maximum precision is preserved in addition, subtraction, multiplication,
  # and division because all results are normalized.
  #
  #
  # DATA FORMAT
  #
  #   Floating-point data occupy a fixed-length format which may be either
  # a fullword short format or a double word long format. Both formats may
  # be used in main storage.
  #
  #   The first bit in either format is the sign bit (S). The subsequent
  # seven bit positions are occupied by the characteristic. The fraction
  # field may have either six or fourteen hexadecimal digits.
  #
  #   Although final results have six fraction hexadecimal digits in
  # short-precision, intermediate results may have one additional low-
  # order digit. This low-order digit, the guard digit, increases the 
  # precision of the final result.
  #
  # NUMBER REPRESENTATION
  # 
  #   The fraction of the floating-point number is expressed in hexadecimal
  # digits. The radix point of the fraction is assumed to be immediately
  # to the left of the high-order fraction digit. To provide the proper
  # magnitude for the floating-point number, the fraction is considered
  # to be multiplied by a power of 16. The characteristic portion,
  # bits 1 through 7 of both floating-point formats, indicates this
  # power. The bits wihthin the characteristic field can represent
  # numbers from 0 through 127. To acoomodate large and small magnitudes,
  # the characteristic is formed by adding 64 to the actual exponent.
  # The range of the exponent is thus -64 through +63. This technique
  # produces a characteristic in excess 64 notation.
  #
  #   Both positive and negative quantities have a true fraction, the 
  # difference in sign being indicated by the sign bit. The number is
  # positive or negative accordingly as the sign bit is zero or one.

  constructor: (inFloat=0.0) ->
    @rawData = new ArrayBuffer(8)
    @data8 = new Uint8Array(@rawData)

    @setFromFloat(inFloat)


  obj32: () ->
    return [
      (@data8[0] << 8) | @data8[1],
      (@data8[2] << 8) | @data8[3]
    ]


  obj64: () ->
    return [
      (@data8[0] << 8) | @data8[1],
      (@data8[2] << 8) | @data8[3],
      (@data8[4] << 8) | @data8[5],
      (@data8[6] << 8) | @data8[7]
    ]

  setFromFloat: (x) ->
    # Convert from IEEE754 64-bit floating point value (javascript native)
    # into IBM double-precision 64-bit floating point value
    # (value can later be converted to 32-bit IBM by truncating at 32-bits)
    #
    # IEEE zero (±0) is a denormal with no implicit leading 1 bit, but
    # DecodeIEEE always injects the implicit bit. Handle zero explicitly.
    if x == 0
      @data8[i] = 0 for i in [0..7]
      return

    fl = FloatIBM.DecodeIEEE(x)

    exp2 = fl.exponent
    mantBits = fl.mantissaBits  # 

    # IEEE is a 53-bit mantissa and implies a '1' in the leftmost bit position
    # IBM normalized fraction is 56-bits, <1 with a non-zero hexadecimal digit
    #   immediately to the right of the decimal
    #     ==> shift IEEE mantissa right 1 bit, OR with 0x1 in MSB's:
    #
    fracBits = mantBits.shiftRightUnsigned(0)
    exp = exp2+4

    # if exponent isn't divisible by 4, right shift to get it there:
    if exp % 4
      if exp < 0
        addlBits = -(exp%4)
      else
        addlBits = 4-(exp%4)
    else
      addlBits = 0
    exp += addlBits
    fracBits = fracBits.shiftRightUnsigned(addlBits)

    @sSign(fl.sign)
    @sExp(exp/4)
    @sFrac(fracBits)
    @normalize()

  to32: () ->
    return ((@data8[0] << 24) & 0xff000000) \
          |((@data8[1] << 16) & 0x00ff0000) \
          |((@data8[2] <<  8) & 0x0000ff00) \
          |((@data8[3]      ) & 0x000000ff)

  to64x: () -> return @to32()
  to64y: () ->
    return ((@data8[4] << 24) & 0xff000000) \
          |((@data8[5] << 16) & 0x00ff0000) \
          |((@data8[6] <<  8) & 0x0000ff00) \
          |((@data8[7]      ) & 0x000000ff)

  @FromFloat: (x) -> new FloatIBM(x)

  setFrom32: (x) ->
    @data8[0] = (x >>> 24) & 0xff
    @data8[1] = (x >>> 16) & 0xff
    @data8[2] = (x >>>  8) & 0xff
    @data8[3] = (x       ) & 0xff
    @data8[4] = @data8[5] = @data8[6] = @data8[7] = 0

  setFrom64: (x1,x2) ->
    @data8[0] = (x1 >>> 24) & 0xff
    @data8[1] = (x1 >>> 16) & 0xff
    @data8[2] = (x1 >>>  8) & 0xff
    @data8[3] = (x1       ) & 0xff
    @data8[4] = (x2 >>> 24) & 0xff
    @data8[5] = (x2 >>> 16) & 0xff
    @data8[6] = (x2 >>>  8) & 0xff
    @data8[7] = (x2       ) & 0xff

  @From32: (x) -> 
    f = new FloatIBM()
    f.setFrom32(x)
    return f

  @From64: (x1,x2) ->
    f = new FloatIBM()
    f.setFrom64(x1,x2)
    return f

  toFloat: () ->
    return @gSign() * @gFrac() * 16**@gExp()

  gSign: () ->
    if @data8[0] & 0x80
      -1
    else
      1

  sSign: (x) ->
    if x <= 0 
      @data8[0] = (@data8[0] & 0x7f) | 0x80
    else
      @data8[0] = (@data8[0] & 0x7f)

  gExp: () ->
    (@data8[0] & 0x7f) - 64

  sExp: (x) ->
    @data8[0] = (@data8[0] & 0x80) | (x + 64)

  gFrac: () ->
    high = @gFracBits().getHighBitsUnsigned() * 16**-6
    low = @gFracBits().getLowBitsUnsigned() * 16 **-14
    return high+low

  gFracBits: () ->
    high32 = @data8[1] << 16 | @data8[2] <<  8 | @data8[3]
    low32 =  @data8[4] << 24 | @data8[5] << 16 | @data8[6] << 8 | @data8[7]
    return Long.fromBits(low32, high32)

  sFrac: (l) ->
    @data8[1] = (l.high >>> 16) & 0xff
    @data8[2] = (l.high >>>  8) & 0xff
    @data8[3] = (l.high       ) & 0xff

    @data8[4] = (l.low >>> 24) & 0xff
    @data8[5] = (l.low >>> 16) & 0xff
    @data8[6] = (l.low >>>  8) & 0xff
    @data8[7] = (l.low       ) & 0xff


  normalize: () ->
    frac = @gFracBits()
    if frac.isZero()
      return
    else
      while not (frac.getHighBitsUnsigned() & 0xf00000)
        frac = frac.shiftLeft(4)
        @sExp(@gExp()-1)
      @sFrac(frac)

  unNormalizeToExp: (newExp) ->
    expDiff = newExp - @gExp()
    if expDiff > 0
      newFrac = @gFracBits().shiftRightUnsigned(expDiff*4)
    else
      newFrac = @gFracBits().shiftLeft(-expDiff*4)
    @sExp(newExp)
    @sFrac(newFrac)

  @DecodeIEEE: (x) ->
    float = new Float64Array(1)
    bytes = new Uint8Array(float.buffer)

    float[0] = x
    #console.log "#{float[0]} = #{[x.toString(16) for x in bytes]}"

    sign = bytes[7] >>> 7
    exponent = ((bytes[7] & 0x7f) << 4 | bytes[6] >>> 4) - 0x3ff
    bytes[7] = 0x3f
    bytes[6] |= 0xf0

    # We're left with a 53-bit mantissa right-justified in bytes 1-7:
    #
    low32 = ((bytes[3]) << 24) | bytes[2] << 16 | bytes[1] << 8 | bytes[0]
    high32 = ((bytes[6] & 0x1f) << 16 | bytes[5] << 8 | bytes[4]) | 0

    mantissaBits = Long.fromBits(low32, high32)
    #console.log "mB: #{mantissaBits.high.toString(2)} #{mantissaBits.low.toString(2)}"

    return {
      sign: if sign then -1 else 1
      exponent: exponent
      mantissa: float[0]
      mantissaBits: mantissaBits
    }



export addE = (x,y) ->
  #console.log "x=", x.gExp(), x.gFrac(), x.gFracBits(), x.toFloat()
  #console.log "y=", y.gExp(), y.gFrac(), y.gFracBits(), y.toFloat()

  # Align fractions
  #
  if x.gExp() != y.gExp()
    if x.gExp() > y.gExp()
      z = x
      x = y
      y = z

    shift = y.gExp() - x.gExp()
    x.sFrac(x.gFracBits().shiftRightUnsigned(shift*4))
    newExp = x.gExp()+shift
    if x.gExp() > 63
      process.stderr.write "FloatIBM.addE EXPONENT OVERFLOW", x, y
      return [null, "EXPONENT OVERFLOW"]
    x.sExp(newExp)

  #console.log "x SH=", x.gExp(), x.gFrac(), x.gFracBits(), x.toFloat()
  #console.log "y SH=", y.gExp(), y.gFrac(), y.gFracBits(), y.toFloat()

  result = new FloatIBM()

  xFrac = x.gFracBits()
  yFrac = y.gFracBits()
  if x.gSign() < 0
    xFrac = xFrac.negate()
  if y.gSign() < 0
    yFrac = yFrac.negate()

  #console.log "FRACS", xFrac, yFrac
  intFrac = xFrac.add(yFrac)
  intExp = x.gExp()
  if intFrac.isNegative()
    intFrac = intFrac.negate()
    result.sSign(-1)
  if intFrac.getHighBitsUnsigned() & 0x1000000
    intFrac = intFrac.shiftRightUnsigned(4)
    intExp += 1
    if intExp > 63
      return [null, "EXPONENT OVERFLOW"]

  #console.log "AE RESULT=", intExp.toString(16), intFrac.toString(16)
  result.sExp(intExp)
  result.sFrac(intFrac)
  result.normalize()

  #console.log "result=", result.gExp(), result.gFrac(), result.gFracBits().toString(16), result.to32().toString(16)

  return result


export subE = (x,y) ->
  y.sSign(y.gSign()*-1)
  return addE(x,y)

export compE = (x,y) ->
  r = subE(x,y)
  return r

export cvfx = (x) ->
  x.unNormalizeToExp(4)
  frac = x.gFracBits()
  intVal = ((frac.getHighBitsUnsigned() << 8) | ((frac.getLowBitsUnsigned() >>> 24) & 0xff)) >>> 0
  if x.gSign() < 0
    intVal = ((~intVal) + 1) & 0xffffffff
  return intVal

export cvfl = (x) ->
  res = new FloatIBM()
  if x < 0
    x = ((x ^ 0xffffffff) + 1) >>> 0
    res.sSign(-1)

  res.data8[1] = (x >>> 24) & 0xff
  res.data8[2] = (x >>> 16) & 0xff
  res.data8[3] = (x >>>  8) & 0xff
  res.data8[4] = (x       ) & 0xff
  res.sExp(4)
  res.normalize()
  return res