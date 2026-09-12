require 'com/util'
import Instruction from 'gpc/cpu_instr'

export hex = (v, n = 4) -> (v >>> 0).asHex(n)

export locStr = (loc) ->
  return '?' unless loc?
  s = loc.hex
  s += " <#{loc.label}>" if loc.label
  s

export renderLocationLine = (session, addr = session.gpc.cpu.psw.getNIA()) ->
  hw1 = session.ram.get16(addr, false)
  hw2 = session.ram.get16(addr + 1, false)
  [d, v] = Instruction.decode(hw1, hw2)
  len = if d? then d.len else 1
  text = if d? then Instruction.toStr(hw1, hw2) else "DC    X'#{hex(hw1)}'"
  hw2s = if len > 1 then hex(hw2) else '    '
  sect = session.formatCSect(addr)
  ">> #{hex(addr, 5)} #{sect}: #{hex(hw1)} #{hw2s}  #{text}"

export renderStop = (r, session) ->
  lines = []
  what =
    if r.description and r.description.indexOf(r.reason) == 0 then r.description
    else if r.description then "#{r.reason}: #{r.description}"
    else r.reason
  lines.push "--- #{what} (#{r.steps} steps) ---"
  lines.push "refused: #{r.refused}" if r.refused
  lines.push renderLocationLine(session, r.location.addr)
  if r.watches?.length
    lines.push renderWatchRow(w) for w in r.watches
  lines.join('\n')

export renderWatchRow = (w) ->
  v = if w.fw? then "HW=#{hex(w.hw)}  FW=#{hex(w.fw, 8)} (#{w.fw | 0})" else "#{hex(w.hw)} (#{w.hw})"
  "  #{w.name} @ #{hex(w.addr, 5)}: #{v}"

export renderMemory = (r) ->
  lines = []
  if r.unit == 'fw'
    for v, i in r.values
      lines.push "  #{hex(r.addr + i * 2, 5)}: #{hex(v, 8)} (int32: #{v | 0}, uint32: #{v >>> 0})"
    return lines.join('\n')
  row = 0
  while row < r.values.length
    cols = Math.min(8, r.values.length - row)
    parts = []
    chars = []
    for c in [0...cols]
      hw = r.values[row + c]
      parts.push hex(hw)
      for b in [(hw >> 8) & 0xff, hw & 0xff]
        chars.push(if 0x20 <= b <= 0x7e then String.fromCharCode(b) else '.')
    lines.push "  #{hex(r.addr + row, 5)}: #{parts.join(' ').rpad(' ', 39)}  |#{chars.join('')}|"
    row += cols
  lines.join('\n')

export renderDisasm = (r, session) ->
  nia = session.gpc.cpu.psw.getNIA()
  lines = []
  for row in r.rows
    lines.push "                          #{row.label}:" if row.label
    marker = if row.addr == nia then '>>' else '  '
    bp = if row.breakpoint then '*' else ' '
    hw2 = if row.len > 1 then hex(row.hw2) else '    '
    comment = if row.reloc then "  ; #{row.reloc}" else ''
    lines.push "#{marker}#{bp}#{hex(row.addr, 5)}: #{hex(row.hw1)} #{hw2}  #{row.text}#{comment}"
  lines.join('\n')

export renderTrace = (r) ->
  lines = []
  for e in r.entries
    hw2 = if e.len > 1 then hex(e.hw2) else '    '
    comment = if e.reloc then "  ; #{e.reloc}" else ''
    lines.push "[#{String(e.step).lpad(' ', 7)}] #{hex(e.addr, 5)}" +
               "#{if e.label then " <#{e.label}>" else ''}: " +
               "#{hex(e.hw1)} #{hw2}  #{e.text}#{comment}"
  if lines.length == 0 then '  (trace empty)' else lines.join('\n')

export renderList = (rows, empty, fn) ->
  return "  (#{empty})" if rows.length == 0
  (fn(r) for r in rows).join('\n')

export durationStr = (us) ->
  return "#{(us / 1e6).toFixed(3)} s" if us >= 1e6
  return "#{(us / 1e3).toFixed(3)} ms" if us >= 1e3
  "#{us} us"
