
# GPC Trace Utilities
#
# Shared formatting functions for instruction trace output and register dumps.
# Used by both batch (plain) and debug (ANSI color) CLI modes.
#
# The color palette (C = ANSI, P = no-op) is selected by the caller and
# applied unconditionally — since P's fields are all empty strings, the same
# format string works for both without branching.

require 'com/util'

# ANSI color codes
C =
  reset:   '\x1b[0m'
  bold:    '\x1b[1m'
  dim:     '\x1b[2m'
  red:     '\x1b[31m'
  green:   '\x1b[32m'
  yellow:  '\x1b[33m'
  blue:    '\x1b[34m'
  magenta: '\x1b[35m'
  cyan:    '\x1b[36m'
  white:   '\x1b[37m'
  bgRed:   '\x1b[41m'

# No-op color palette — every field an empty string.
# Auto-generated from C's keys so we can't get out of sync.
P = {}
P[k] = '' for own k of C

export { C, P }

# Format a register value for display
export formatRegVal = (name, val) ->
  if name == 'CC' or name == 'NIA'
    return val.toString()
  return (val >>> 0).asHex(8)

# Format a trace line for a single instruction.
#   opts.color:     C for ANSI, P for plain (default: P)
#   opts.sym:       SymbolTable instance (optional, for section offset)
#   opts.stepWidth: width of the step-count field (default: 6)
#   opts.niaWidth:  width of the NIA hex field (default: 5)
export formatTraceLine = (step, nia, hw1, hw2, disasm, instrLen, changes, opts = {}) ->
  c = opts.color or P
  sym = opts.sym or null
  stepWidth = opts.stepWidth or 6
  niaWidth = opts.niaWidth or 5

  stepStr = step.toString().lpad(" ", stepWidth)
  niaStr = nia.asHex(niaWidth)
  sectStr = if sym? then " " + (sym.formatCSect?(nia) or "") else ""
  hw1Str = hw1.asHex(4)
  hw2Str = if instrLen > 1 then hw2.asHex(4) else "    "
  changesStr = ""
  if changes.length > 0
    parts = ("#{ch.name}: #{formatRegVal(ch.name, ch.old)}->#{formatRegVal(ch.name, ch.new)}" for ch in changes)
    changesStr = "  " + parts.join(", ")
  "#{c.dim}[#{stepStr}]#{c.reset} #{niaStr}#{sectStr}: #{hw1Str} #{hw2Str}  #{disasm.rpad(' ', 28)}#{c.yellow}#{changesStr}#{c.reset}"

# Format a full register dump block.  Returns an array of lines.
export formatRegDump = (cpu, step, opts = {}) ->
  c = opts.color or P
  lines = []
  grSet = cpu.psw.getRegSet()

  lines.push "#{c.bold}--- Registers (step #{step}, bank #{grSet}) ---#{c.reset}"

  # General registers — two rows of 4
  for row in [0, 4]
    parts = []
    for i in [row..row+3]
      name = "R#{i.toString().padStart(2, '0')}"
      val = cpu.regFiles[grSet].r(i).get32()
      parts.push "#{c.cyan}#{name}#{c.reset}=#{(val >>> 0).asHex(8)}"
    lines.push "  " + parts.join("  ")

  # Floating-point registers — two rows of 4
  for row in [0, 4]
    parts = []
    for i in [row..row+3]
      val = cpu.regFiles[2].r(i).get32()
      parts.push "#{c.cyan}FP#{i}#{c.reset}=#{(val >>> 0).asHex(8)}"
    lines.push "  " + parts.join("  ")

  # PSW
  psw1 = cpu.psw.psw1.get32()
  psw2 = cpu.psw.psw2.get32()
  nia = cpu.psw.getNIA()
  cc = cpu.psw.getCC()
  bsr = cpu.psw.getBSR()
  dsr = cpu.psw.getDSR()
  lines.push "  #{c.cyan}PSW1#{c.reset}=#{(psw1 >>> 0).asHex(8)}  #{c.cyan}PSW2#{c.reset}=#{(psw2 >>> 0).asHex(8)}  #{c.cyan}NIA#{c.reset}=#{nia.asHex(5)}  #{c.cyan}CC#{c.reset}=#{cc}  #{c.cyan}BSR#{c.reset}=#{bsr}  #{c.cyan}DSR#{c.reset}=#{dsr}"

  return lines
