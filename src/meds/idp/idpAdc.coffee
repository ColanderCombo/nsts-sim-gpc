# IDP bus controller for its two ADCs.
#
# The IDP is the bus controller.  Once a frame it sends each of its units
# a transmit command for the 32 samples (lru/adc/adcConf SA.SAMPLES), and
# every 25th frame the status block instead; a unit that has not answered
# the last three commands is invalid, as is a frame returned with the
# busy flag while the unit runs its self-test.
#

import {CHANNELS, unitsOfIdp, pairOf, rtAddressOf,
        TR_TRANSMIT, TR_RECEIVE, STATUS, SA, STATUS_BLOCK_WORDS, STATUS_BLOCK, COMMAND,
        encodeBC, decode1553} from './../../lru/adc/adcConf'

MISSED_LIMIT = 3
STATUS_EVERY = 25

# IDP -> MDU: the tag (meds/medsConf MDUMsg.ADC), the pair, 1 when the
# frame is valid, the BITE summary, then the 32 data words.
MDU_ADC_WORDS = 4 + CHANNELS

encodeMduAdc = (tag, u) ->
  out = [tag, u.pair, (if u.valid then 1 else 0), u.bite & 0xffff]
  for i in [0...CHANNELS] by 1
    out.push (u.data?[i] ? 0) & 0xffff
  out

decodeMduAdc = (words) ->
  return null unless words?.length >= MDU_ADC_WORDS
  {
    pair:  words[1]
    valid: words[2] != 0
    bite:  words[3]
    data:  (words[4 + i] & 0xffff for i in [0...CHANNELS] by 1)
  }

export class IDPAdcBC
  constructor: (@idpNo, opts = {}) ->
    @send = opts.send ? (->)
    @onUpdate = opts.onUpdate ? null
    @units = {}
    for id in unitsOfIdp(@idpNo)
      @units[id] = {
        id, pair: pairOf(id), rt: rtAddressOf(id)
        data: null, valid: false, missed: 0, awaiting: null
        statusFlags: 0, bite: 0, cst: 0, cstState: 0, samples: 0, version: 0
        ticks: 0, polls: 0, replies: 0
      }

  tick: () ->
    for _, u of @units
      if u.awaiting?
        u.missed += 1
        if u.missed >= MISSED_LIMIT and u.valid
          u.valid = false
          @onUpdate?(u)
      u.ticks += 1
      sa = if u.ticks % STATUS_EVERY == 0 then SA.STATUS else SA.SAMPLES
      wc = if sa == SA.STATUS then STATUS_BLOCK_WORDS else 0
      u.awaiting = sa
      u.polls += 1
      @send encodeBC({rt: u.rt, tr: TR_TRANSMIT, sa, wc})
    return

  command: (id, code) ->
    u = @units[id]
    throw new Error("IDP #{@idpNo} has no ADC #{id}") unless u
    @send encodeBC({rt: u.rt, tr: TR_RECEIVE, sa: SA.COMMAND, wc: 1}, [code])
    return

  startCst: (id) -> @command id, COMMAND.START_CST
  reset: (id) -> @command id, COMMAND.RESET

  recv: (words) ->
    m = decode1553(words)
    return false unless m?.kind == 'status'
    u = null
    for _, x of @units when x.rt == m.rt
      u = x
    return false unless u?
    u.replies += 1
    u.missed = 0
    u.awaiting = null
    u.statusFlags = m.flags
    if m.data.length == CHANNELS
      u.data = m.data
      u.valid = not (m.flags & STATUS.BUSY)
    else if m.data.length == STATUS_BLOCK_WORDS
      u.bite = m.data[STATUS_BLOCK.BITE]
      u.cst = m.data[STATUS_BLOCK.CST]
      u.cstState = m.data[STATUS_BLOCK.CST_STATE]
      u.samples = m.data[STATUS_BLOCK.SAMPLES]
      u.version = m.data[STATUS_BLOCK.VERSION]
    @onUpdate?(u)
    true

export {MISSED_LIMIT, STATUS_EVERY, MDU_ADC_WORDS, encodeMduAdc, decodeMduAdc}
