import {defc, cmdError} from './registry'
import {hex, locStr, renderMemory, renderDisasm, renderTrace, renderList} from './render'
import Instruction from 'gpc/cpu_instr'
import {formatRegDump, P} from 'gpc/dbg/trace'
import {ASCII_TO_EBCDIC} from 'gpc/ebcdic'

defc 'mem',
  summary: 'Read memory'
  aliases: ['x', 'examine', 'readmem']
  params: [
    { name: 'addr', type: 'addr', required: true }
    { name: 'count', type: 'int', default: 16 }
    { name: 'unit', type: 'str', flag: true, default: 'hw' }
  ]
  exec: (s, a) ->
    throw cmdError('badArgs', "unit: expected 'hw' or 'fw'") unless a.unit in ['hw', 'fw']
    n = Math.max(1, a.count ? 16)
    values =
      if a.unit == 'fw'
        (s.ram.get32(a.addr + i * 2, false) >>> 0 for i in [0...n])
      else
        (s.ram.get16(a.addr + i, false) for i in [0...n])
    { addr: a.addr, hex: hex(a.addr, 5), unit: a.unit, count: n, values }
  render: renderMemory

defc 'writemem',
  summary: 'Write memory, ignoring store protection'
  aliases: ['deposit', 'dep']
  params: [
    { name: 'addr', type: 'addr', required: true }
    { name: 'values', type: 'hexes', required: true }
    { name: 'unit', type: 'str', flag: true, default: 'hw' }
  ]
  exec: (s, a) ->
    throw cmdError('badArgs', "unit: expected 'hw' or 'fw'") unless a.unit in ['hw', 'fw']
    written = for v, i in a.values
      if a.unit == 'fw'
        addr = a.addr + i * 2
        s.ram.set32(addr, v >>> 0, false)
        { addr, value: v >>> 0 }
      else
        addr = a.addr + i
        s.ram.set16(addr, v & 0xffff, false)
        { addr, value: v & 0xffff }
    { unit: a.unit, written }
  render: (r) ->
    w = if r.unit == 'fw' then 8 else 4
    ("  #{hex(x.addr, 5)}: #{hex(x.value, w)}" for x in r.written).join('\n')

defc 'regs',
  summary: 'Show the register file and PSW'
  aliases: ['reg', 'registers']
  params: [{ name: 'name', type: 'str' }]
  exec: (s, a) ->
    cpu = s.gpc.cpu
    set = cpu.psw.getRegSet()
    all = {
      bank: set
      gr: (cpu.regFiles[set].r(i).get32() >>> 0 for i in [0..7])
      fp: (cpu.regFiles[2].r(i).get32() >>> 0 for i in [0..7])
      psw1: cpu.psw.psw1.get32() >>> 0
      psw2: cpu.psw.psw2.get32() >>> 0
      nia: cpu.psw.getNIA()
      cc: cpu.psw.getCC()
      bsr: cpu.psw.getBSR()
      dsr: cpu.psw.getDSR()
      waitState: !!cpu.psw.getWaitState()
      steps: s.stepCount
      simTimeSec: s.simTimeSec()
    }
    return all unless a.name?
    v = registerValue(s, a.name)
    throw cmdError('badArgs', "unknown register: #{a.name}") unless v?
    { name: a.name.toUpperCase(), value: v }
  render: (r, s) ->
    return "  #{r.name} = #{hex(r.value, 8)} (#{r.value | 0})" if r.name?
    formatRegDump(s.gpc.cpu, r.steps, { color: P }).join('\n')

regBank = (s, bank) ->
  return s.gpc.cpu.psw.getRegSet() unless bank?
  throw cmdError('badArgs', 'bank must be 0, 1 or 2') unless bank in [0, 1, 2]
  bank

registerValue = (s, name, bank = null) ->
  cpu = s.gpc.cpu
  n = String(name).toUpperCase()
  set = regBank(s, bank)
  if (m = n.match(/^R0?(\d)$/)) and +m[1] <= 7 then return cpu.regFiles[set].r(+m[1]).get32() >>> 0
  if (m = n.match(/^FP(\d)$/)) and +m[1] <= 7 then return cpu.regFiles[2].r(+m[1]).get32() >>> 0
  if (m = n.match(/^DSE(\d)$/)) and +m[1] <= 7 then return cpu.regFiles[set].getDSE(+m[1])
  switch n
    when 'NIA'  then cpu.psw.getNIA()
    when 'CC'   then cpu.psw.getCC()
    when 'PSW1' then cpu.psw.psw1.get32() >>> 0
    when 'PSW2' then cpu.psw.psw2.get32() >>> 0
    when 'BSR'  then cpu.psw.getBSR()
    when 'DSR'  then cpu.psw.getDSR()
    else null

defc 'setreg',
  summary: 'Set a register'
  aliases: ['set']
  params: [
    { name: 'name', type: 'str', required: true }
    { name: 'value', type: 'hex', required: true }
    { name: 'bank', type: 'int', flag: true }
  ]
  exec: (s, a) ->
    cpu = s.gpc.cpu
    n = a.name.toUpperCase()
    set = regBank(s, a.bank)
    ok = true
    if (m = n.match(/^R0?(\d)$/)) and +m[1] <= 7
      cpu.regFiles[set].r(+m[1]).set32(a.value)
    else if (m = n.match(/^FP(\d)$/)) and +m[1] <= 7
      cpu.regFiles[2].r(+m[1]).set32(a.value)
    else if (m = n.match(/^DSE(\d)$/)) and +m[1] <= 7
      cpu.regFiles[set].setDSE(+m[1], a.value)
    else
      switch n
        when 'NIA'  then cpu.psw.setNIA(a.value & 0x7ffff)
        when 'CC'   then cpu.psw.setCC(a.value & 0x3)
        when 'PSW1' then cpu.psw.psw1.set32(a.value)
        when 'PSW2' then cpu.psw.psw2.set32(a.value)
        else ok = false
    throw cmdError('badArgs', "cannot set #{n}") unless ok
    { name: n, bank: (if a.bank? then set else null), value: registerValue(s, n, a.bank) }
  render: (r) -> "  #{r.name} = #{hex(r.value, 8)}"

defc 'disasm',
  summary: 'Disassemble from an address'
  aliases: ['d', 'u', 'dis']
  params: [
    { name: 'addr', type: 'addr' }
    { name: 'count', type: 'int', default: 20 }
  ]
  exec: (s, a) ->
    addr = a.addr ? s.gpc.cpu.psw.getNIA()
    n = Math.max(1, a.count ? 20)
    rows = []
    for i in [0...n]
      break if addr >= 0x80000
      hw1 = s.ram.get16(addr, false)
      hw2 = s.ram.get16(addr + 1, false)
      [d, v] = Instruction.decode(hw1, hw2)
      len = if d? then d.len else 1
      rows.push Object.assign(s.location(addr), {
        hw1, hw2: (if len > 1 then hw2 else null), len
        text: if d? then Instruction.toStr(hw1, hw2) else "DC    X'#{hex(hw1)}'"
        reloc: s.relocAt(addr, len)
        breakpoint: s.breakpoints.get(addr)?.enabled ? false
      })
      addr += len
    { addr: rows[0]?.addr ? addr, rows }
  render: renderDisasm

defc 'trace',
  summary: 'Turn the instruction trace ring on or off'
  params: [
    { name: 'state', type: 'bool' }
    { name: 'limit', type: 'int', flag: true }
  ]
  exec: (s, a) ->
    return s.setTrace(a.state, a.limit) if a.state? or a.limit?
    { enabled: s.traceEnabled, limit: s.traceLimit, entries: s.traceRing.length }
  render: (r) ->
    "trace #{if r.enabled then 'on' else 'off'}, #{r.entries}/#{r.limit} entries"

defc 'tracelog',
  summary: 'The instructions the trace ring holds'
  aliases: ['tl', 'history']
  params: [
    { name: 'count', type: 'int', default: 50 }
    { name: 'clear', type: 'bool', flag: true, default: false }
  ]
  exec: (s, a) ->
    entries = s.traceLog(a.count ? 50)
    total = s.traceRing.length
    s.clearTrace() if a.clear
    { entries, total, enabled: s.traceEnabled }
  render: renderTrace

defc 'find',
  summary: 'Search memory for a run of halfwords or a string'
  params: [
    { name: 'values', type: 'hexes', default: [] }
    { name: 'text', type: 'str', flag: true }
    { name: 'encoding', type: 'str', flag: true, default: 'ascii' }
    { name: 'start', type: 'addr', flag: true }
    { name: 'end', type: 'addr', flag: true }
    { name: 'limit', type: 'int', flag: true, default: 32 }
  ]
  exec: (s, a) ->
    values = a.values ? []
    if a.text?
      throw cmdError('badArgs', "encoding: expected 'ascii' or 'ebcdic'") unless a.encoding in ['ascii', 'ebcdic']
      values = textToHalfwords(a.text, a.encoding)
    throw cmdError('badArgs', 'nothing to search for') unless values.length
    Object.assign(s.findMemory(values, {
      start: a.start, end: a.end, limit: a.limit ? 32
    }), { pattern: values })
  render: (r) ->
    head = "#{r.matches.length} match#{if r.matches.length == 1 then '' else 'es'} " +
           "in #{hex(r.start, 5)}-#{hex(r.end, 5)}#{if r.truncated then ' (limit reached)' else ''}"
    rows = renderList r.matches, 'no match', (m) ->
      "  #{locStr(m)}: #{(hex(v) for v in m.values).join(' ')}"
    "#{head}\n#{rows}"

textToHalfwords = (text, encoding) ->
  bytes = for ch in String(text)
    code = ch.charCodeAt(0)
    if encoding == 'ebcdic' then (ASCII_TO_EBCDIC[ch] ? 0x40) else (code & 0xff)
  bytes.push(if encoding == 'ebcdic' then 0x40 else 0x20) if bytes.length % 2
  (((bytes[i] << 8) | bytes[i + 1]) for i in [0...bytes.length] by 2)
