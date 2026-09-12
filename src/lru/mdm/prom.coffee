#
# MDM PROM programs
#
# The FF programs overlap: location 22 for 6 instructions returns 21 words
# and location 23 for 9 returns 36, so locations 23-27 carry 20 words,
# location 22 one and locations 28-31 sixteen.
#

import {IOM, IOM_CLASS_NONE, PROM_WORDS, PROM_CLASS_WORDS, PROM_MODE,
        PROM_MAX_WORDS, encodePromWord, encodePromClass, iomType} from './mdmConf'

ones = (n) -> (1 for i in [0...n] by 1)
fours = (n) -> (4 for i in [0...n] by 1)

# Per MDM type: the programs as runs of instruction word counts.
PROGRAMS =
  FF: [
    {loc: 22, words: [1]}
    {loc: 23, words: [4, 4, 4, 4, 4]}
    {loc: 28, words: [4, 4, 4, 4]}
  ]
  FA: [
    {loc: 21, words: [6, 6, 6, 6, 5, 5]}
    {loc: 27, words: fours(12).concat([2, 2, 2])}
  ]
  LL1: [
    {loc: 20, words: [1]}
    {loc: 28, words: ones(7)}
    {loc: 35, words: ones(29)}
  ]
  LL2: [
    {loc: 100, words: ones(31)}
  ]
  LR1: [
    {loc: 160, words: [1]}
    {loc: 168, words: ones(13)}
    {loc: 181, words: ones(29)}
  ]
  LR2: [
    {loc: 245, words: ones(31)}
  ]

programsFor = (id) ->
  PROGRAMS[id] ? PROGRAMS[id.replace(/\d+$/, '')] ? []

# The next run of `n` channels on an input card, cycling through the
# unit's input cards and through each card's channels.
class Allocator
  constructor: (iom) ->
    @cards = []
    for name, slot in iom
      t = iomType(name)
      continue unless t? and t.dir in ['in', 'both']
      @cards.push {slot, type: t, next: 0}
    @cursor = 0

  take: (n) ->
    throw new Error('a unit with no input cards has no PROM programs') unless @cards.length
    for tries in [0...@cards.length * 2] by 1
      c = @cards[@cursor % @cards.length]
      @cursor += 1
      c.next = 0 if c.next + n > c.type.channels
      if n <= c.type.channels
        ch = c.next
        c.next += n
        return {card: c.slot, channel: ch, count: n}
    # No card is wide enough for the run: read the first card's channel
    # 0 as many times as it takes.
    c = @cards[0]
    {card: c.slot, channel: 0, count: Math.min(n, c.type.channels)}

# {prom: Uint16Array(512), programs: [{loc, instr: [{loc, card, channel, count}]}]}
export buildProm = (entry) ->
  prom = new Uint16Array(PROM_WORDS)
  for slot in [0...PROM_CLASS_WORDS] by 1
    t = iomType(entry.iom?[slot])
    prom[slot] = encodePromClass(if t? then t.cls else IOM_CLASS_NONE)
  alloc = new Allocator(entry.iom ? [])
  programs = []
  for prog in programsFor(entry.id)
    instr = []
    for n, i in prog.words
      throw new Error("PROM instruction of #{n} words") if n < 1 or n > PROM_MAX_WORDS
      a = alloc.take(n)
      loc = prog.loc + i
      prom[loc] = encodePromWord(PROM_MODE.INPUT, a.card, a.channel, a.count)
      instr.push {loc, card: a.card, channel: a.channel, count: a.count}
    programs.push {loc: prog.loc, instr}
  {prom, programs}

export {PROGRAMS}
