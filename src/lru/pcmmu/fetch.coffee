# PCMMU fetch program
# JSC-18611 SB 29 sect.29.2.4 gives the shape: 4096 commands of 44 bits,
# each an MDM command word (up to 32 response words) and the RAM slot the
# response goes to, cycled once a second, every parameter at 1, 2, 5, 10,
# 20, 25, 50 or 100 samples a second.  The program here reads every input
# card of every OI MDM in the catalog (lru/mdm/mdmConfig.coffee), the
# discrete and analog cards whole at 1 s/s and the serial channels with a
# device on them at 10 s/s: the MTU's two instrumentation outputs, seven
# words each (lru/mtu/mtuConf.coffee OI_OUTPUT).  MTU 1's seven words sit at
# RAM 2043: the PASS reads three words there at initialization in OPS 0
# (command 6cff62, measured on IP4), the GMT it calls PMU time.  MTU 2's
# follow at 2050.  The card reads take RAM slots in catalog order from
# address 0, OF1 first.
#

import {MDM_CATALOG} from './../mdm/mdmConfig'
import {iomType, cardChannels} from './../mdm/mdmConf'
import {OI_OUTPUT, OI_CARD, OI_CHANNEL, READ_WORDS} from './../mtu/mtuConf'
import {OI_MDMS, RAM_WORDS, MAX_WORDS} from './pcmmuConf'

SERIAL_WORDS = READ_WORDS
SERIAL_RATE  = 10
CARD_RATE    = 1

# The serial channels with a device and their RAM slots: {mdm: [[card,
# channel, ram]]}.
MTU1_RAM = 2043
SERIAL_DEVICES = {}
for n, o of OI_OUTPUT
  (SERIAL_DEVICES[o.mdm] ?= []).push [OI_CARD, OI_CHANNEL, MTU1_RAM + (n - 1) * SERIAL_WORDS]

# `mdms`: the units to read, OI_MDMS unless given.  Returns {entries,
# words}: each entry {mdm, iua, card, channel, count, ram, rate, type}.
buildFetch = (opts = {}) ->
  entries = []
  reserved = []
  for _, devs of SERIAL_DEVICES
    reserved.push [r, r + SERIAL_WORDS] for [c, ch, r] in devs
  ram = 0
  # The next free slot of `n` words at or after `at`.
  free = (at, n) ->
    for [lo, hi] in reserved when at < hi and at + n > lo
      return free(hi, n)
    at
  for id in (opts.mdms ? OI_MDMS)
    entry = MDM_CATALOG[id]
    throw new Error("no MDM '#{id}' in the catalog") unless entry?
    for slot in [0...16] by 1
      t = iomType(entry.iom?[slot])
      continue unless t? and t.dir in ['in', 'both']
      n = cardChannels(t, entry, true)
      if t.kind == 'serial'
        for [card, ch, r] in (SERIAL_DEVICES[id] ? []) when card == slot and ch < n
          entries.push {mdm: id, iua: entry.iua, card: slot, channel: ch, count: SERIAL_WORDS, ram: r, rate: SERIAL_RATE, type: t.name}
      else if t.kind in ['discrete', 'analog']
        for ch in [0...n] by MAX_WORDS
          c = Math.min(MAX_WORDS, n - ch)
          ram = free(ram, c)
          entries.push {mdm: id, iua: entry.iua, card: slot, channel: ch, count: c, ram, rate: CARD_RATE, type: t.name}
          ram += c
  words = Math.max(ram, (r + SERIAL_WORDS for [lo, r] in reserved)...)
  throw new Error("fetch program needs #{words} RAM words, the unit has #{RAM_WORDS}") if words > RAM_WORDS
  {entries, words}

# The RAM address of a card's channel, or null.
fetchAddress = (fetch, mdm, card, channel) ->
  for e in fetch.entries when e.mdm == mdm and e.card == card and channel >= e.channel and channel < e.channel + (if e.type == 'SIO' then 1 else e.count)
    return if e.type == 'SIO' then e.ram else e.ram + (channel - e.channel)
  null

# The entry holding a RAM address, or null.
fetchEntryAt = (fetch, addr) ->
  for e in fetch.entries when addr >= e.ram and addr < e.ram + e.count
    return e
  null

export {buildFetch, fetchAddress, fetchEntryAt, SERIAL_WORDS, SERIAL_RATE, CARD_RATE, MTU1_RAM}
