# IDP receiver for GPC DDU writes and MEDS transfers on one FC bus.
#
# The bus carries the GPC's 24-bit command words in command datagrams and
# the data words behind them (com/bus.civet, gpc/iop_bce).  A command to
# IUA 6, 9 or 15 with the DDU write bit opens a transfer of the word count
# it names; the words that follow fill it, and the transfer is delivered
# whole. Any command word ends a transfer still open.
#
# The IDP forwards every transfer from every FC bus, tagged with the bus
# number; the MDU keeps the four and follows the one its DATA BUS edgekey
# selects.
#

import {MSG, MSG_CODE, MSG_OF_CODE, decodeCommand} from './../../lru/ddu/dduConf'

export class IDPFcRx
  constructor: (@busNo, opts = {}) ->
    @onMessage = opts.onMessage ? null
    @pending = null
    @stats = {commands: 0, messages: 0, dropped: 0, words: 0}

  recv: (words, isCmd) ->
    return false unless words?.length
    if isCmd
      @_command(((words[0] & 0xffff) << 8) | ((words[1] >> 8) & 0xff))
    else
      taken = false
      taken = (@_data(w & 0xffff) or taken) for w in words
      taken

  _command: (cmd24) ->
    if @pending?
      @stats.dropped += 1
      @pending = null
    m = decodeCommand(cmd24)
    return false unless m?
    @stats.commands += 1
    @pending = {m, got: []}
    true

  _data: (hw) ->
    p = @pending
    return false unless p?
    p.got.push hw
    @stats.words += 1
    if p.got.length >= p.m.wc
      @pending = null
      @stats.messages += 1
      @onMessage?({bus: @busNo, iua: p.m.iua, ddu: p.m.ddu, msg: p.m.msg, words: p.got})
    true

# IDP -> MDU: the tag (meds/medsConf MDUMsg.FC), the FC bus number, the
# IUA, the message code (dduConf MSG_CODE), then the data words.
MDU_FC_HEADER = 4

encodeMduFc = (tag, m) ->
  [tag, m.bus, m.iua, MSG_CODE[m.msg]].concat((w & 0xffff for w in m.words))

decodeMduFc = (words) ->
  return null unless words?.length >= MDU_FC_HEADER
  msg = MSG_OF_CODE[words[3]]
  return null unless msg?
  wc = MSG[msg].wc
  return null unless words.length >= MDU_FC_HEADER + wc
  {
    bus: words[1]
    iua: words[2]
    msg: msg
    words: (words[MDU_FC_HEADER + i] & 0xffff for i in [0...wc] by 1)
  }

export {MDU_FC_HEADER, encodeMduFc, decodeMduFc}
