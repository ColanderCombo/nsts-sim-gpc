# Telemetry format loads
# Each format is a 2048-word format memory in the layout of JSC-18611 SB
# 29 fig.29-13 (pcmmuConf.coffee).  The bandwidth of each window is the
# published one (JSC-18819 SCP 5.21, USA-002869 table 7.3-3): kbps x 2.5
# is words a downlist frame, and at 25 samples a second a toggle buffer
# word is two entries of the 25 s/s group.  What fills the OI window is
# the model's: the MTU's GMT and MET from OF1 at 100 s/s, the BITE
# register, the format ID as fill, and the front of the OI RAM at 10 s/s
# for the rest.  Every minor frame begins FA F3 20 and the frame count
# (SB 49 sect.49.2.3.1).
#
#   129  HDR fixed     TB1 51.2  TB5 12.8   OI 64      asc/orb/ent
#   161  HDR           TB1 44.8  TB2 19.2   OI 64      on-orbit
#   102  LDR           TB1 25.6  TB5  6.4   OI 32      ascent/entry
#   103  LDR           TB1 22.4  TB2 11.2   OI 30.4    on-orbit
#
# The OI window's kbps includes the four header bytes.
#

import {RATES, FMT_WORDS, FMT_GROUPS, FMT_SLOTS_BASE, FMT_ENTRIES, MINOR_FRAMES, SYNC_BYTES,
        DATA, tbDataAddr, fmtEntry, fillEntry, slotsOf, TB_WORDS} from './pcmmuConf'
import {fetchAddress} from './fetch'

MTU_WORDS = 6        # GMT and MET, three halfwords each

# A window: {rate, entries} with entries.length a multiple of 100/rate;
# it takes entries.length / (100/rate) slots of every minor frame.
tbWindow = (buffer, words, rate = 25) ->
  entries = []
  for w in [0...words] by 1
    a = tbDataAddr(buffer, w)
    entries.push fmtEntry(a, true), fmtEntry(a, false)
  {rate, entries}

ramWindow = (addr, words, rate) ->
  entries = []
  for w in [0...words] by 1
    entries.push fmtEntry(addr + w, true), fmtEntry(addr + w, false)
  {rate, entries}

fillWindow = (bytes, rate = 100) ->
  {rate, entries: (fillEntry(b) for b in bytes)}

syncWindow = () ->
  {rate: 100, entries: (fillEntry(b) for b in SYNC_BYTES).concat([fmtEntry(DATA.COUNT, false)])}

# Assemble a format memory from windows in slot order.
buildFormat = (rate, windows) ->
  slots = slotsOf(rate)
  mem = new Uint16Array(FMT_WORDS)
  groups = ({rate: r, entries: []} for r in RATES)
  slot = 0
  for w in windows
    per = MINOR_FRAMES / w.rate
    throw new Error("window at #{w.rate} s/s needs a multiple of #{per} entries, has #{w.entries.length}") if w.entries.length % per
    g = groups[RATES.indexOf(w.rate)]
    throw new Error("no such sample rate: #{w.rate}") unless g?
    n = w.entries.length / per
    throw new Error("format needs #{slot + n} slots, the frame has #{slots}") if slot + n > slots
    mem[FMT_SLOTS_BASE + slot + i] = RATES.indexOf(w.rate) for i in [0...n] by 1
    g.entries = g.entries.concat(w.entries)
    slot += n
  throw new Error("format fills #{slot} of #{slots} slots") unless slot == slots
  at = FMT_ENTRIES
  for g, i in groups
    mem[i] = at
    throw new Error("format needs #{at + g.entries.length} words, the memory has #{FMT_WORDS}") if at + g.entries.length > FMT_WORDS
    mem[at + j] = e for e, j in g.entries
    at += g.entries.length
  mem

# The OI window: `slots` bytes a minor frame, the MTU and the BSR at 100
# s/s, the format ID, then the OI RAM at 10 s/s.
oiWindows = (fetch, id, slots) ->
  mtu = fetchAddress(fetch, 'OF1', 0, 1) ? 0
  ws = [ramWindow(mtu, MTU_WORDS, 100), ramWindow(DATA.BSR, 1, 100), fillWindow([(id >>> 8) & 0xff, id & 0xff])]
  used = MTU_WORDS * 2 + 2 + 2
  rest = slots - used
  throw new Error("OI window of #{slots} slots is too small") if rest < 2
  rest -= rest % 2
  ws.push ramWindow(0, (rest * 10) / 2, 10) if rest
  ws.push fillWindow([0xff]) if (slots - used) % 2
  ws

# kbps x 2.5 = words a downlist frame; two entries a word, over four
# minor frames.
tbWords = (kbps) -> Math.round(kbps * 2.5)

FORMATS =
  129: {rate: 128, windows: [{tb: 1, kbps: 51.2}, {tb: 5, kbps: 12.8}], oi: 64,   nom: 'fixed HDR, ascent/on-orbit/entry'}
  161: {rate: 128, windows: [{tb: 1, kbps: 44.8}, {tb: 2, kbps: 19.2}], oi: 64,   nom: 'HDR on-orbit'}
  102: {rate: 64,  windows: [{tb: 1, kbps: 25.6}, {tb: 5, kbps: 6.4}],  oi: 32,   nom: 'LDR ascent/entry'}
  103: {rate: 64,  windows: [{tb: 1, kbps: 22.4}, {tb: 2, kbps: 11.2}], oi: 30.4, nom: 'LDR on-orbit'}

# The slot each window starts at, for readers of the stream.
formatLayout = (id) ->
  f = FORMATS[id]
  throw new Error("no such format: #{id}") unless f?
  layout = [{name: 'sync', slot: 0, slots: 4}]
  slot = 4
  for w in f.windows
    n = tbWords(w.kbps) * 2 / 4
    layout.push {name: "TB#{w.tb}", slot, slots: n, buffer: w.tb, words: tbWords(w.kbps)}
    slot += n
  layout.push {name: 'OI', slot, slots: slotsOf(f.rate) - slot}
  layout

buildTlmFormat = (id, fetch) ->
  f = FORMATS[id]
  throw new Error("no such format: #{id}") unless f?
  windows = [syncWindow()]
  slot = 4
  for w in f.windows
    words = tbWords(w.kbps)
    throw new Error("format #{id}: #{words} words a frame from buffer #{w.tb}") if words > TB_WORDS
    windows.push tbWindow(w.tb, words)
    slot += words * 2 / 4
  windows = windows.concat oiWindows(fetch, id, slotsOf(f.rate) - slot)
  buildFormat(f.rate, windows)

export {FORMATS, buildTlmFormat, buildFormat, formatLayout, tbWindow, ramWindow, fillWindow, syncWindow, tbWords, MTU_WORDS}
