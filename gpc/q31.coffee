# q31.coffee — AP-101S Fixed-Point Fractional Arithmetic (Q31/Q15)
#
#
# IBM-75-C67-001/p.34:
# 2.2.2 Fixed Point Data Representation
#
# Data representation is fractional, with negative numbers represented in twos
# complement form. A halfword operand is 15 bits plus sign, a fullword operand 
# is 31 bits plus sign, and a doublewordk operand is 63 bits plus sign, as 
# shown in Figure 2-3.
#
#   Q31 (fullword):  S.FFFFFFF FFFFFFFF FFFFFFFF FFFFFFF  (31 fraction bits)
#   Q15 (halfword):  S.FFFFFFF FFFFFFFF                   (15 fraction bits)
#   Q63 (register pair): S.FFF...F                         (63 fraction bits)
#
# The binary point position means that multiplying two Q31 values produces
# a Q62 result (62 fraction bits), but a Q63 register pair expects 63
# fraction bits — hence the <<1 shift in MULTIPLY.  Similarly, dividing
# Q63 by Q31 produces a Q32 raw quotient, but Q31 expects 31 fraction
# bits — hence the >>1 shift in DIVIDE.
#
# Reference: IBM-85-C67-001 §4.10 DIVIDE, §4.21 MULTIPLY

# Q31 fullword multiply: two signed 32-bit fractions → 64-bit fraction.
# Returns [hi, lo] as unsigned 32-bit values.
#
# Per spec (§4.21): "Both multiplier and multiplicand are 32-bit signed
# twos complement fractions. The product is a 64-bit, signed twos
# complement fraction."
#
# Overflow: -1 × -1 (0x80000000 × 0x80000000) cannot be represented.
export q31_mul32 = (a, b) ->
    an = BigInt(a | 0)
    bn = BigInt(b | 0)
    product = (an * bn) << 1n   # Q31 × Q31 = Q62; <<1 → Q63
    hi = Number((product >> 32n) & 0xFFFFFFFFn)
    lo = Number(product & 0xFFFFFFFFn)
    overflow = (a | 0) == (0x80000000 | 0) and (b | 0) == (0x80000000 | 0)
    {hi, lo, overflow}

# Q15 halfword multiply: two signed 16-bit fractions → 32-bit fraction.
# Returns a signed 32-bit value.
#
# Per spec (§4.21, §4.22): halfword operands use bits 0-15 (upper half
# of register), product is a 32-bit signed fraction.
export q15_mul = (a, b) ->
    product = a * b
    result = (product << 1) | 0  # Q15 × Q15 = Q30; <<1 → Q31
    overflow = a == -32768 and b == -32768
    {result, overflow}

# Q31 fullword divide: 64-bit fraction / 32-bit fraction → 32-bit fraction.
# Returns quotient as a signed 32-bit value, or null on overflow/zero.
#
# Per spec (§4.10): "The first operand is divided by the second operand.
# The unrounded quotient replaces the contents of general register R1."
# "When the relative magnitude of dividend and divisor is such that
# the quotient cannot be expressed as a 32-bit signed fraction, an
# overflow is generated."
export q31_div = (hi, lo, divisor) ->
    dividend = BigInt(hi | 0) * 0x100000000n + BigInt(lo >>> 0)
    div = BigInt(divisor | 0)
    if div == 0n
        return {quotient: 0, overflow: true}
    raw = dividend / div          # Q63 / Q31 = Q32
    quotient = Number((raw >> 1n) & 0xFFFFFFFFn)  # >>1 → Q31
    # Overflow check: quotient must fit in Q31 range [-1.0, +1.0)
    # i.e., |quotient| must be representable as signed 32-bit
    overflow = raw > 0x7FFFFFFFn or raw < -0x80000000n
    {quotient: quotient | 0, overflow}
