
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
    ((@data8[0] << 24) | (@data8[1] << 16) | (@data8[2] << 8) | @data8[3]) >>> 0

  to64x: () -> return @to32()
  to64y: () ->
    ((@data8[4] << 24) | (@data8[5] << 16) | (@data8[6] << 8) | @data8[7]) >>> 0

  @FromFloat: (x) -> new FloatIBM(x)

  setFrom32: (x) ->
    x = x >>> 0
    @data8[0] = (x >>> 24) & 0xff
    @data8[1] = (x >>> 16) & 0xff
    @data8[2] = (x >>>  8) & 0xff
    @data8[3] = (x       ) & 0xff
    @data8[4] = @data8[5] = @data8[6] = @data8[7] = 0

  setFrom64: (x1,x2) ->
    # Ensure unsigned 32-bit interpretation: get32() may return signed values
    x1 = x1 >>> 0
    x2 = x2 >>> 0
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



# POO 8.11 anomaly
#
# When two operands' fractions differ by exactly x'80 0000' after
# prealignment (in 56-bit fraction form), the AP-101S compare instruction
# reports them as equal even though they are not.
#
# Returns CC: 0 = equal, 1 = a > b, 3 = a < b.  Used by CER/CE/CEDR/CED.
export compE_anomalous = (x, y) ->
  # Snapshot fields up-front so we never mutate the caller's operands.
  aSign = x.gSign() < 0
  aExp  = x.gExp() + 64
  aMant = x.gFracBits().toUnsigned()
  bSign = y.gSign() < 0
  bExp  = y.gExp() + 64
  bMant = y.gFracBits().toUnsigned()

  # POO: zero-fraction operands compare equal
  # regardless of sign or characteristic.
  aZero = aMant.isZero()
  bZero = bMant.isZero()
  if aZero and bZero then return 0
  if aZero then return (if bSign then 1 else 3)
  if bZero then return (if aSign then 3 else 1)

  # Prealign with guard digit (mirrors _addsubE).
  if aExp == bExp
    aMant = aMant.shiftLeft(4)
    bMant = bMant.shiftLeft(4)
  else if aExp < bExp
    shift = bExp - aExp - 1
    if shift > 0
      if shift >= 14
        return (if bSign then 1 else 3)
      aMant = aMant.shiftRightUnsigned(shift * 4)
      if aMant.isZero()
        return (if bSign then 1 else 3)
    bMant = bMant.shiftLeft(4)
  else
    shift = aExp - bExp - 1
    if shift > 0
      if shift >= 14
        return (if aSign then 3 else 1)
      bMant = bMant.shiftRightUnsigned(shift * 4)
      if bMant.isZero()
        return (if aSign then 3 else 1)
    aMant = aMant.shiftLeft(4)

  # Signed-fraction subtract for compare.
  if aSign != bSign
    rMant = aMant.add(bMant)
    rSign = aSign
  else if aMant.greaterThanOrEqual(bMant)
    rMant = aMant.subtract(bMant)
    rSign = aSign
  else
    rMant = bMant.subtract(aMant)
    rSign = not aSign

  # POO 8.11 anomaly: false equality when |a-b| in the post-prealign
  # 60-bit form equals exactly 0x8000000.  Documented for CEDR/CED
  # (long compare); POO 8.12 does not list this anomaly for short
  # compare, so SP-shaped operands still see it (they go through the
  # same compare logic) but we don't add a separate SP threshold.
  ANOMALY = Long.fromBits(0x08000000, 0, true)
  if rMant.equals(ANOMALY) then return 0

  if rMant.isZero() then return 0
  return (if rSign then 3 else 1)


# Exception-aware DP arithmetic.  Returns {result: FloatIBM, exc: int}.
# Exception codes match POO 2.5.2 interrupt codes: the same numeric
# values used by the CPU's signal* methods.

export FP_EXC =
  OK:               0
  EXP_OVERFLOW:     0x000B
  EXP_UNDERFLOW:    0x0009
  SIGNIFICANCE:     0x0005
  DIVIDE:           0x000C
  CONVERT_OVERFLOW: 0x000A

export addE = (x, y) -> _addsubE(x, y, false)
export subE = (x, y) -> _addsubE(x, y, true)
# compE never raises per POO 8.11, so discard exc and return the result.
# (Compare instructions use _addsubE(true) directly to inspect the
# fraction sign; this wrapper exists for callers that want a plain
# subtract-as-FloatIBM convenience.)
export compE = (x, y) -> _addsubE(x, y, true).result

# Internal addsub.  Modeled on tools/floatIBM/ibmFloat.c
# ibm_dp_addsub_exc and Hercules add_lf.  Returns {result, exc}.
#
# Result/exceptions per POO 8.8:
#   OK           - result valid; caller writes back, sets CC.
#   EXP_OVERFLOW - result holds the would-be-wrapped value for trace.
#                  Caller must not write back ("operation terminated").
#   EXP_UNDERFLOW- result = true zero.  Caller writes back only when PSW
#                  exp-underflow mask bit 22 is 0; signals always.
#   SIGNIFICANCE - result = true zero.  Caller always writes back, CC 00.
#                  Mask bit 23 only gates the interrupt.
_addsubE = (xIn, yIn, subtract_b) ->
  # Snapshot fields up-front so we never mutate the caller's operands.
  aSign = xIn.gSign() < 0
  aExp  = xIn.gExp() + 64    # work in biased characteristic 0..127
  aMant = xIn.gFracBits().toUnsigned()
  bSign = yIn.gSign() < 0
  bExp  = yIn.gExp() + 64
  bMant = yIn.gFracBits().toUnsigned()
  if subtract_b then bSign = not bSign

  ZERO = Long.fromBits(0, 0, true)

  aZero = aMant.isZero()
  bZero = bMant.isZero()

  if not bZero and not aZero
    # Both non-zero: align with guard digit, then signed add.
    if aExp == bExp
      aMant = aMant.shiftLeft(4)
      bMant = bMant.shiftLeft(4)
    else if aExp < bExp
      shift = bExp - aExp - 1   # minus guard digit
      aExp = bExp
      if shift > 0
        if shift >= 14
          aMant = ZERO
        else
          aMant = aMant.shiftRightUnsigned(shift * 4)
        if aMant.isZero()
          # a effectively zero: result is just b (no guard).
          aSign = bSign
          aMant = bMant
          return _packAddsubResult(aSign, aExp, aMant, false)
      bMant = bMant.shiftLeft(4)   # guard digit on b
    else
      shift = aExp - bExp - 1
      if shift > 0
        if shift >= 14
          bMant = ZERO
        else
          bMant = bMant.shiftRightUnsigned(shift * 4)
        if bMant.isZero()
          # b effectively zero: keep a (no guard).
          return _packAddsubResult(aSign, aExp, aMant, false)
      aMant = aMant.shiftLeft(4)

    # Compute with guard digit (60-bit mantissas).
    if aSign == bSign
      rSign = aSign
      rMant = aMant.add(bMant)
    else if aMant.equals(bMant)
      # True cancellation: SIGNIFICANCE, true zero.
      return {result: new FloatIBM(), exc: FP_EXC.SIGNIFICANCE}
    else if aMant.greaterThan(bMant)
      rSign = aSign
      rMant = aMant.subtract(bMant)
    else
      rSign = bSign
      rMant = bMant.subtract(aMant)

    # Post-add: handle overflow / drop guard / renormalize.
    if rMant.getHighBitsUnsigned() & 0xF0000000
      # Overflow into bit 60+: shift right 1 hex (cancels guard +
      # absorbs overflow), bump expo.
      rMant = rMant.shiftRightUnsigned(8)
      aExp += 1
    else if rMant.getHighBitsUnsigned() & 0x0F000000
      # Top guard-hex set: drop guard, already normalized.
      rMant = rMant.shiftRightUnsigned(4)
    else
      # Leading zero hex in 60-bit form: re-interpret as 56-bit form
      # (the implicit <<4 from the format change is absorbed by the
      # exp decrement) and normalize within 56-bit.
      aExp -= 1
      if rMant.isZero()
        return {result: new FloatIBM(), exc: FP_EXC.SIGNIFICANCE}
      while not (rMant.getHighBitsUnsigned() & 0x00F00000)
        rMant = rMant.shiftLeft(4)
        aExp -= 1

    return _packAddsubResult(rSign, aExp, rMant, false)

  if bZero and aZero
    # POO 8.9: zero+zero -> SIGNIFICANCE with true-zero result.
    return {result: new FloatIBM(), exc: FP_EXC.SIGNIFICANCE}
  if aZero
    aSign = bSign
    aExp  = bExp
    aMant = bMant
  # (else: a not zero, b zero, so keep a unchanged.)
  return _packAddsubResult(aSign, aExp, aMant, true)

# Pack addsub helper.  Returns {result, exc}.  needsRenorm=true means
# we may have an unnormalized mantissa (the "one operand zero" path).
_packAddsubResult = (sign, biasedExp, mant, needsRenorm) ->
  if needsRenorm
    if mant.isZero()
      # FIXER pattern: mant=0 with exp!=0 canonicalizes to true zero
      # via SIGNIFICANCE (matches Hyperion add_lf:1442-1452).
      return {result: new FloatIBM(), exc: FP_EXC.SIGNIFICANCE}
    while not (mant.getHighBitsUnsigned() & 0x00F00000)
      mant = mant.shiftLeft(4)
      biasedExp -= 1

  result = new FloatIBM()
  if biasedExp > 127
    # EXP_OVERFLOW: per POO, operation is terminated, operands unchanged.
    # We still pack a wrapped value for caller's trace use (caller is
    # contractually obliged not to write back).
    if sign then result.sSign(-1)
    result.sExp((biasedExp & 0x7F) - 64)
    result.sFrac(mant)
    return {result, exc: FP_EXC.EXP_OVERFLOW}
  if biasedExp < 0
    # EXP_UNDERFLOW: result is true zero (the masked-off-write value).
    return {result, exc: FP_EXC.EXP_UNDERFLOW}
  if sign then result.sSign(-1)
  result.sExp(biasedExp - 64)   # sExp adds bias back
  result.sFrac(mant)
  return {result, exc: FP_EXC.OK}


export mulE = (x, y) ->
  # 56x56 -> 112 multiply, keeping top 56 bits.  Returns {result, exc}.
  # Per POO 8.17 a zero operand forces true-zero result, no exception.
  xFrac = x.gFracBits().toUnsigned()
  yFrac = y.gFracBits().toUnsigned()

  if xFrac.isZero() or yFrac.isZero()
    return {result: new FloatIBM(), exc: FP_EXC.OK}

  resultSign = x.gSign() * y.gSign()

  # Renormalize both operands so each has top hex set, matching the C
  # reference's IBM_DP_RENORMALIZE_56.  Operating on biased characteristic.
  xBiasedExp = x.gExp() + 64
  yBiasedExp = y.gExp() + 64
  while not (xFrac.getHighBitsUnsigned() & 0x00F00000)
    xFrac = xFrac.shiftLeft(4)
    xBiasedExp -= 1
  while not (yFrac.getHighBitsUnsigned() & 0x00F00000)
    yFrac = yFrac.shiftLeft(4)
    yBiasedExp -= 1

  # 32-bit splits to match the C reference exactly: a_lo = low 32, a_hi
  # = high 24 (since the 56-bit fraction sits in the low 56 of a Long).
  toUL  = (n) -> Long.fromBits(n | 0, 0, true)
  aLo32 = xFrac.getLowBitsUnsigned() >>> 0
  aHi32 = xFrac.getHighBitsUnsigned() >>> 0
  bLo32 = yFrac.getLowBitsUnsigned() >>> 0
  bHi32 = yFrac.getHighBitsUnsigned() >>> 0
  aLo = toUL(aLo32); aHi = toUL(aHi32)
  bLo = toUL(bLo32); bHi = toUL(bHi32)

  # Per ibm_dp_mul_exc:
  #   wk = (a_lo*b_lo) >> 32; wk += a_lo*b_hi; wk += a_hi*b_lo;
  #   v  = wk & 0xFFFFFFFF;
  #   hi = (wk >> 32) + (a_hi*b_hi);
  ll = aLo.multiply(bLo)
  wk = ll.shiftRightUnsigned(32).add(aLo.multiply(bHi)).add(aHi.multiply(bLo))
  v  = wk.getLowBitsUnsigned() >>> 0
  hi = wk.shiftRightUnsigned(32).add(aHi.multiply(bHi))

  if hi.getHighBitsUnsigned() & 0x0000F000
    # Top hex of product at bits 60..63 of `hi`'s view; pack with <<8.
    rMant = hi.shiftLeft(8).or(Long.fromBits(v >>> 24, 0, true))
    rBiasedExp = xBiasedExp + yBiasedExp - 64
  else
    # One hex below: pack with <<12 and decrement biased exp by 1.
    rMant = hi.shiftLeft(12).or(Long.fromBits(v >>> 20, 0, true))
    rBiasedExp = xBiasedExp + yBiasedExp - 65

  # Truncate to 56-bit form (drop high byte where sign would go).
  rMant = rMant.and(Long.fromBits(0xFFFFFFFF, 0x00FFFFFF, true))

  result = new FloatIBM()
  if rBiasedExp > 127
    if resultSign < 0 then result.sSign(-1)
    result.sExp((rBiasedExp & 0x7F) - 64)
    result.sFrac(rMant)
    return {result, exc: FP_EXC.EXP_OVERFLOW}
  if rBiasedExp < 0
    return {result, exc: FP_EXC.EXP_UNDERFLOW}
  if resultSign < 0 then result.sSign(-1)
  result.sExp(rBiasedExp - 64)
  result.sFrac(rMant)
  return {result, exc: FP_EXC.OK}


# The AP-101 C/M's quasi-extended operand preparation, shared by the
# extended multiply and the extended divide.  IBM-6246156B 8-25: the
# quasi-extended operands are formed "by truncating the fraction portion
# to 31 bits and then rounding into the 31st bit based upon the 32nd
# bit".  Takes and returns [56-bit fraction, biased characteristic] --
# a round that carries out of the fraction renormalizes and bumps the
# characteristic.
QE_ROUND_BIT = Long.fromBits(0x01000000, 0, true)         # 1 << 24
QE_CLEAR_BOT = Long.fromBits(0xFE000000, 0xFFFFFFFF, true) # ~((1<<25)-1)
QE_CARRY_OUT = Long.fromBits(0, 0x01000000, true)         # 1 << 56

qeRound31 = (mant, biasedExp) ->
  rounded = mant.add(QE_ROUND_BIT)
  if not rounded.and(QE_CARRY_OUT).isZero()
    rounded = rounded.shiftRightUnsigned(4)
    biasedExp += 1
  [rounded.and(QE_CLEAR_BOT), biasedExp]


# AP-101 C/M quasi-extended multiply (MEDR/MED).  Pre-truncate each
# operand's 56-bit mantissa to 31 bits with round-into-bit-31 from
# bit 32.  Then multiply at the truncated precision.  Returns
# {result, exc} like mulE.  Mirrors tools/floatIBM/ibmFloat.c
# ibm_dp_mul_qe_exc.  The AP-101S does not do this; see mulQeS.
#
# POO programming note: rounding can cause exponent overflow (e.g.
# 7FFFFFFFFF000000 rounds up to 8000000000000000, so the char bumps).
mulQeE = (x, y) ->
  xFrac = x.gFracBits().toUnsigned()
  yFrac = y.gFracBits().toUnsigned()
  if xFrac.isZero() or yFrac.isZero()
    return {result: new FloatIBM(), exc: FP_EXC.OK}

  resultSign = x.gSign() * y.gSign()
  xBiasedExp = x.gExp() + 64
  yBiasedExp = y.gExp() + 64
  while not (xFrac.getHighBitsUnsigned() & 0x00F00000)
    xFrac = xFrac.shiftLeft(4)
    xBiasedExp -= 1
  while not (yFrac.getHighBitsUnsigned() & 0x00F00000)
    yFrac = yFrac.shiftLeft(4)
    yBiasedExp -= 1

  [xFrac, xBiasedExp] = qeRound31(xFrac, xBiasedExp)
  [yFrac, yBiasedExp] = qeRound31(yFrac, yBiasedExp)

  if xBiasedExp > 127 or yBiasedExp > 127
    result = new FloatIBM()
    if resultSign < 0 then result.sSign(-1)
    result.sExp((127 & 0x7F) - 64)
    return {result, exc: FP_EXC.EXP_OVERFLOW}

  # Both mantissas now have at most 31 significant bits in the upper
  # half.  Shift each down by 25 to get a 31-bit Number (fits 32-bit).
  a31 = xFrac.shiftRightUnsigned(25).toUnsigned()
  b31 = yFrac.shiftRightUnsigned(25).toUnsigned()
  prod = a31.multiply(b31)        # up to 62 bits, fits in unsigned Long

  # target_mant = prod >> 6  (algebra: prod = frac×frac × 2^62, want ×2^56)
  target = prod.shiftRightUnsigned(6)

  result = new FloatIBM()
  if target.isZero()
    return {result, exc: FP_EXC.OK}

  rMant = null
  rBiasedExp = 0
  if not target.and(Long.fromBits(0, 0x00F00000, true)).isZero()
    # Top hex (bits 52..55) of target is set: already normalized.
    rMant = target.and(Long.fromBits(0xFFFFFFFF, 0x00FFFFFF, true))
    rBiasedExp = xBiasedExp + yBiasedExp - 64
  else
    # Postnormalize one hex digit.  The C/M shifts the 62-bit intermediate
    # and fills the vacated low-order positions with ZEROS -- it does not
    # reach back into the product for four more bits.  Taking prod>>2
    # here did, and came out 1 ulp high on every postnormalizing
    # product.
    rMant = target.shiftLeft(4).and(Long.fromBits(0xFFFFFFFF, 0x00FFFFFF, true))
    rBiasedExp = xBiasedExp + yBiasedExp - 65

  if rBiasedExp > 127
    if resultSign < 0 then result.sSign(-1)
    result.sExp((rBiasedExp & 0x7F) - 64)
    result.sFrac(rMant)
    return {result, exc: FP_EXC.EXP_OVERFLOW}
  if rBiasedExp < 0
    return {result, exc: FP_EXC.EXP_UNDERFLOW}
  if resultSign < 0 then result.sSign(-1)
  result.sExp(rBiasedExp - 64)
  result.sFrac(rMant)
  return {result, exc: FP_EXC.OK}

# AP-101S extended multiply (MEDR/MED), IBM-85-C67-001 8.x:
#
#   "Fraction multiplication is accomplished by multiplying the three most
#    significant fullword partial sum pairs and adding the results (to 68
#    bits), followed by normalization and truncation to 56 bits."
#
# The two 56-bit fractions split into 28-bit halves (A:B and C:D); the
# three most significant partial products are AC, AD and BC, and BD -- the
# least significant -- does not participate.  That is the whole difference
# from the AP-101 C/M, which instead throws away everything below 31 bits
# of each OPERAND before multiplying (mulQeE above).  The S keeps far
# more: it lands within an ulp of the exact product where the C/M is
# millions of ulps out, which is why the two machines visibly disagree.
mulQeS = (x, y) ->
  xFrac = x.gFracBits().toUnsigned()
  yFrac = y.gFracBits().toUnsigned()
  if xFrac.isZero() or yFrac.isZero()
    return {result: new FloatIBM(), exc: FP_EXC.OK}

  resultSign = x.gSign() * y.gSign()
  xBiasedExp = x.gExp() + 64
  yBiasedExp = y.gExp() + 64
  while not (xFrac.getHighBitsUnsigned() & 0x00F00000)
    xFrac = xFrac.shiftLeft(4)
    xBiasedExp -= 1
  while not (yFrac.getHighBitsUnsigned() & 0x00F00000)
    yFrac = yFrac.shiftLeft(4)
    yBiasedExp -= 1

  MASK28 = Long.fromBits(0x0FFFFFFF, 0, true)
  MASK56 = Long.fromBits(0xFFFFFFFF, 0x00FFFFFF, true)
  a = xFrac.shiftRightUnsigned(28)
  b = xFrac.and(MASK28)
  c = yFrac.shiftRightUnsigned(28)
  d = yFrac.and(MASK28)

  # The 112-bit product is AC<<56 + (AD+BC)<<28 + BD, and BD -- the least
  # significant partial product -- is the one that does not participate.
  # The hardware accumulates 68 bits of that; 64 is carried here (the top
  # of the product, = product >> 48), which is all the postnormalization
  # can reach: two normalized fractions multiply to at least 1/256, so at
  # most one hex digit of left shift is ever needed, and eight guard bits
  # cover it.  A 68-bit intermediate does not fit a 64-bit Long.
  ac = a.multiply(c)
  mid = a.multiply(d).add(b.multiply(c))
  inter = ac.shiftLeft(8).add(mid.shiftRightUnsigned(20))

  if inter.isZero()
    return {result: new FloatIBM(), exc: FP_EXC.OK}

  frac = inter.shiftRightUnsigned(8).and(MASK56)
  rBiasedExp = xBiasedExp + yBiasedExp - 64
  if not (frac.getHighBitsUnsigned() & 0x00F00000)
    # Postnormalize one hex digit within the intermediate, then truncate.
    frac = inter.shiftRightUnsigned(4).and(MASK56)
    rBiasedExp -= 1

  result = new FloatIBM()
  if rBiasedExp > 127
    if resultSign < 0 then result.sSign(-1)
    result.sExp((rBiasedExp & 0x7F) - 64)
    result.sFrac(frac)
    return {result, exc: FP_EXC.EXP_OVERFLOW}
  if rBiasedExp < 0
    return {result, exc: FP_EXC.EXP_UNDERFLOW}
  if resultSign < 0 then result.sSign(-1)
  result.sExp(rBiasedExp - 64)
  result.sFrac(frac)
  return {result, exc: FP_EXC.OK}

export {mulQeE, mulQeS}


# divE is the AP-101S extended divide: a full 56-bit quotient.  divQeE
# is the AP-101 C/M's quasi-extended divide, which prepares its operands
# the same way the C/M's quasi-extended multiply does (31 bits, rounded
# in from the 32nd) and delivers a quotient good to 31 bits.  That is
# the mechanism behind the C/M POO's warning that DED/DEDR "does not
# always produce a quotient which is accurate to 31 bits" -- rounding
# the DIVISOR up perturbs the quotient in exactly the low-order bits the
# note describes.  The signature is unmistakable: a C/M quotient's low
# 25 bits read as zero, and its value is not any rounding of the true
# quotient -- it is the quotient of the two ROUNDED operands.  The short
# divides DE/DER are exempt (C/M POO: "does not have this problem").
export divE = (x, y, qe = false) ->
  # 56-bit hex-FP divide via iterative hex-digit long-division.
  # Returns {result, exc}.  Modeled on tools/floatIBM/ibmFloat.c
  # ibm_dp_div_exc.  Per POO 8.8 divide-by-zero is reported as
  # FP_DIVIDE: the CPU layer must suppress the writeback.
  xFrac = x.gFracBits().toUnsigned()
  yFrac = y.gFracBits().toUnsigned()

  if yFrac.isZero()
    # FP_DIVIDE: the caller must not write back.  Result is a sentinel
    # (DEADBEEFDEADBEEF) so any accidental use crashes loud, matching
    # the C ref's IBM_FP_DIVIDE_SENTINEL_DP.  All 8 bytes are set
    # including the high byte so to64x()/to64y() reproduce the sentinel
    # exactly in the runner output.
    sentinel = new FloatIBM()
    sentinel.data8[0] = 0xDE
    sentinel.data8[1] = 0xAD
    sentinel.data8[2] = 0xBE
    sentinel.data8[3] = 0xEF
    sentinel.data8[4] = 0xDE
    sentinel.data8[5] = 0xAD
    sentinel.data8[6] = 0xBE
    sentinel.data8[7] = 0xEF
    return {result: sentinel, exc: FP_EXC.DIVIDE}
  if xFrac.isZero()
    # POO 8.15: dividend zero -> true zero result, no exception.
    return {result: new FloatIBM(), exc: FP_EXC.OK}

  resultSign = x.gSign() * y.gSign()

  # Work in biased characteristic; renormalize each operand so top hex
  # is set (mirrors C ibm_dp_div_exc).
  xBiasedExp = x.gExp() + 64
  yBiasedExp = y.gExp() + 64
  while not (xFrac.getHighBitsUnsigned() & 0x00F00000)
    xFrac = xFrac.shiftLeft(4)
    xBiasedExp -= 1
  while not (yFrac.getHighBitsUnsigned() & 0x00F00000)
    yFrac = yFrac.shiftLeft(4)
    yBiasedExp -= 1

  if qe
    [xFrac, xBiasedExp] = qeRound31(xFrac, xBiasedExp)
    [yFrac, yBiasedExp] = qeRound31(yFrac, yBiasedExp)

  # Position dividend / compute quotient biased exp.
  if xFrac.lessThan(yFrac)
    rBiasedExp = xBiasedExp - yBiasedExp + 64
  else
    rBiasedExp = xBiasedExp - yBiasedExp + 65
    yFrac = yFrac.shiftLeft(4)

  # Long division: 14 hex digits of quotient.
  wk2 = xFrac.divide(yFrac)
  wk  = xFrac.subtract(wk2.multiply(yFrac)).shiftLeft(4)
  i = 13
  while i > 0
    wk2 = wk2.shiftLeft(4).or(wk.divide(yFrac))
    wk  = wk.subtract(wk.divide(yFrac).multiply(yFrac)).shiftLeft(4)
    i -= 1
  resultFrac = wk2.shiftLeft(4).or(wk.divide(yFrac))
  # The C/M's quotient register holds 31 bits; the rest reads as zero.
  if qe
    resultFrac = resultFrac.and(QE_CLEAR_BOT)

  result = new FloatIBM()
  if rBiasedExp > 127
    if resultSign < 0 then result.sSign(-1)
    result.sExp((rBiasedExp & 0x7F) - 64)
    result.sFrac(resultFrac)
    return {result, exc: FP_EXC.EXP_OVERFLOW}
  if rBiasedExp < 0
    return {result, exc: FP_EXC.EXP_UNDERFLOW}
  if resultSign < 0 then result.sSign(-1)
  result.sExp(rBiasedExp - 64)
  result.sFrac(resultFrac)
  return {result, exc: FP_EXC.OK}


export divQeE = (x, y) -> divE(x, y, true)


export cvfx = (x) ->
  # Convert short FP to two's-complement int32, binary point between
  # bits 15 and 16 (POO 8.13).  Returns {result: int32, exc}.  Caller
  # must not update R1 on CONVERT_OVERFLOW per spec.
  #
  # Mirrors tools/floatIBM/ibmFloat.c ibm_cvfx: work out the shift
  # algebraically from the biased characteristic, then range-check.
  if x.gFracBits().isZero()
    return {result: 0, exc: FP_EXC.OK}

  # Take a working copy so we don't mutate the caller (gFracBits is a
  # snapshot: but unNormalizeToExp / sExp / sFrac would mutate `x`).
  work = new FloatIBM()
  work.setFrom64(x.to64x(), x.to64y())
  # Renormalize to ensure top hex of fraction is set.
  work.normalize()
  sign = work.gSign() < 0
  chr  = (work.data8[0] & 0x7F)        # biased characteristic
  mant = work.gFracBits().toUnsigned() # 56-bit fraction in low 56

  # FloatIBM stores SP as a DP-shaped 56-bit fraction (low 32 bits
  # zero).  fp_value = (mant_56 / 2^56) × 16^(chr - 64).  Integer-form
  # = fp_value × 2^16 = mant_56 × 2^(4*chr - 296).
  shift = 4 * chr - 296
  if shift > 8
    # mant occupies bits 0..55 of the Long; left-shift by >8 pushes its
    # top bit past bit 63 and Long.js wraps mod 64.  Any value that
    # large is unambiguously beyond INT32 range: declare overflow
    # before the shift loses data.
    return {result: 0, exc: FP_EXC.CONVERT_OVERFLOW}

  if shift >= 0
    mag64 = mant.shiftLeft(shift)
  else
    rs = -shift
    if rs >= 64
      mag64 = Long.fromInt(0, true)
    else
      mag64 = mant.shiftRightUnsigned(rs)
  magHi = mag64.getHighBitsUnsigned()
  magLo = mag64.getLowBitsUnsigned() >>> 0

  # Range check via 64-bit Long: positive max = 0x7FFFFFFF; negative max
  # = 0x80000000 (latter encodes INT32_MIN).
  if magHi != 0
    return {result: 0, exc: FP_EXC.CONVERT_OVERFLOW}
  if sign
    if magLo > 0x80000000
      return {result: ((-(magLo & 0x7FFFFFFF)) | 0), exc: FP_EXC.CONVERT_OVERFLOW}
    if magLo == 0
      return {result: 0, exc: FP_EXC.OK}
    return {result: ((-magLo) | 0), exc: FP_EXC.OK}
  else
    if magLo > 0x7FFFFFFF
      return {result: ((magLo & 0x7FFFFFFF) | 0), exc: FP_EXC.CONVERT_OVERFLOW}
    return {result: magLo | 0, exc: FP_EXC.OK}

export cvfl = (x) ->
  # POO 8.14: fixed-point zero produces floating-point true zero.
  # The previous implementation packed char 0x44 with mant=0 (= 0x44000000),
  # which is numerically zero but not the true-zero canonical form.
  return new FloatIBM() if x == 0

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
