# Panel controls and indicators
#
# One bus carries crew controls and indicators keyed by panel/control number,
# for example `F6/S3`, `O6/S12`, or `C3/DS4`.
#
# `_PANEL` in com/bus.civet.  Message halfwords:
#
#     0   operation   SET = 1, REQUEST = 3, VALUE = 4
#     1   kind        NONE = 0, LOGIC = 1, ENUM = 2, WORD = 3, REAL = 4
#     2   keyLen      characters of the key
#     3   valLen      characters of the value text
#     4   nWords      value halfwords
#     5.. key         com/msgtext.coffee
#     ..  value text  the same, for a kind that carries one
#     ..  value words
#
# SET asks the holder to put a control where the message says; VALUE
# reports where it is.  A REQUEST with an empty key asks for every
# control, with a panel and no control ("F6/") for that panel's, and with
# a full key for the one.  Nothing is republished on a timer, so a
# process that attaches late asks with REQUEST.
#
# The value of each kind:
#
#   LOGIC   one halfword, 0 or 1: a light, a pushbutton, a two-position
#           switch read as a level
#   ENUM    the position's name in the value text: a rotary or a switch
#           with more than two positions, and a talkback's legend
#   WORD    one halfword: a thumbwheel or a digital readout
#   REAL    two halfwords, the IEEE-754 binary32 bit pattern high half
#           first: a meter, in the units its panel gives
#
# In addition to text, some talkbacks have 'gray', 'white', or 'barberpole'.

import {Bus, BusMsg, busConfig} from 'com/bus'
import {textWords, putText, getText} from 'com/msgtext'

export SET = 1
export REQUEST = 3
export VALUE = 4

export NONE = 0
export LOGIC = 1
export ENUM = 2
export WORD = 3
export REAL = 4

export PANEL_BUS = '_PANEL'
export HEADER_WORDS = 5

export OP_NAME = {1: 'SET', 3: 'REQUEST', 4: 'VALUE'}
export KIND_NAME = {0: 'none', 1: 'logic', 2: 'enum', 3: 'word', 4: 'real'}
export KIND_OF = {none: NONE, logic: LOGIC, enum: ENUM, word: WORD, real: REAL}

export GRAY = 'gray'
export BARBERPOLE = 'barberpole'

export key = (panel, control = null) ->
  return '' unless panel?
  "#{panel}/#{control ? ''}"

export splitKey = (k) ->
  s = String(k ? '')
  return {panel: null, control: null} unless s.length
  i = s.indexOf('/')
  return {panel: s, control: null} if i < 0
  {panel: s[0...i], control: (s[(i + 1)..] or null)}

export encodePanel = ({op, kind, key, value}) ->
  kind ?= NONE
  k = String(key ? '')
  text = ''
  words = []
  switch kind
    when LOGIC then words = [(if value then 1 else 0)]
    when WORD  then words = [Math.round(value ? 0) & 0xffff]
    when ENUM  then text = String(value ? '')
    when REAL
      buf = new DataView(new ArrayBuffer(4))
      buf.setFloat32(0, Number(value ? 0))
      words = [buf.getUint16(0), buf.getUint16(2)]
  msg = new BusMsg(HEADER_WORDS + textWords(k.length) + textWords(text.length) + words.length)
  msg.data16[0] = op & 0xffff
  msg.data16[1] = kind & 0xffff
  msg.data16[2] = k.length & 0xffff
  msg.data16[3] = text.length & 0xffff
  msg.data16[4] = words.length & 0xffff
  at = putText(msg.data16, HEADER_WORDS, k)
  at = putText(msg.data16, at, text)
  msg.data16[at + i] = words[i] & 0xffff for i in [0...words.length] by 1
  msg

export decodePanel = (msg) ->
  d = msg?.data16
  return null unless d? and d.length >= HEADER_WORDS
  op = d[0] & 0xffff
  kind = d[1] & 0xffff
  return null unless OP_NAME[op]? and KIND_NAME[kind]?
  keyLen = d[2] & 0xffff
  valLen = d[3] & 0xffff
  nWords = d[4] & 0xffff
  need = HEADER_WORDS + textWords(keyLen) + textWords(valLen) + nWords
  return null unless d.length >= need
  at = HEADER_WORDS
  k = getText(d, at, keyLen)
  at += textWords(keyLen)
  text = getText(d, at, valLen)
  at += textWords(valLen)
  words = (d[at + i] & 0xffff for i in [0...nWords] by 1)
  m = {op, opName: OP_NAME[op], kind, kindName: KIND_NAME[kind], key: k, words}
  Object.assign m, splitKey(k)
  m.value = switch kind
    when LOGIC then (words[0] ? 0) != 0
    when WORD  then (words[0] ? 0)
    when ENUM  then text
    when REAL
      buf = new DataView(new ArrayBuffer(4))
      buf.setUint16(0, words[0] ? 0)
      buf.setUint16(2, words[1] ? 0)
      buf.getFloat32(0)
    else null
  m

export fmtPanel = (m) ->
  return '' unless m?
  v = switch m.kind
    when LOGIC then (if m.value then "'1'" else "'0'")
    when ENUM  then m.value
    when WORD  then "0x#{(m.value & 0xffff).toString(16).padStart(4, '0')}"
    when REAL  then m.value.toPrecision(4)
    else ''
  "#{m.opName} #{m.key or '*'} #{v}".trim()

export class PanelChannel
  constructor: (onMessage = null) ->
    @bus = new Bus(PANEL_BUS, busConfig[PANEL_BUS])
    @bus.onReceive ((self, busID, msg) ->
      m = decodePanel(msg)
      onMessage?(m) if m?), null

  ready: () -> @bus?.ready ? Promise.resolve()

  close: () ->
    @bus?.close()
    @bus = null
    return

  send: (m) ->
    @bus?.sendMsg encodePanel(m)
    return

  report: (key, kind, value) ->
    @send {op: VALUE, kind, key, value}

  set: (key, kind, value) ->
    @send {op: SET, kind, key, value}

  request: (key = '') ->
    @send {op: REQUEST, kind: NONE, key}
