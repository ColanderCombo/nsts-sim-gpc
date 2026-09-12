# Text in a bus message
#
# A name or a value carried as characters: two a halfword, the first in
# the high byte, the low byte 0 where the count is odd.  The message
# carries the character count beside the words, so the odd byte is not
# read back.

export textWords = (n) -> Math.ceil(n / 2)

export putText = (data16, at, s) ->
  for i in [0...textWords(s.length)] by 1
    hi = s.charCodeAt(2 * i) & 0xff
    lo = if 2 * i + 1 < s.length then s.charCodeAt(2 * i + 1) & 0xff else 0
    data16[at + i] = (hi << 8) | lo
  at + textWords(s.length)

export getText = (data16, at, len) ->
  out = ''
  for i in [0...len] by 1
    w = data16[at + (i >> 1)] & 0xffff
    out += String.fromCharCode(if i % 2 == 0 then (w >>> 8) & 0xff else w & 0xff)
  out
