#

import {AGEHarness} from 'gpc/ageharness'
import {checkFCMFits} from 'gpc/machine'
import Instruction from 'gpc/cpu_instr'
require 'com/util'

parseHex = (s) -> parseInt(s.replace(/^0x/i, ''), 16)

icRelNote = (age, d, v, addr) ->
  target = Instruction.icRelTarget(d, v, addr)
  return "" unless target?
  label = age.sym.getLabelAt?(target)
  "   ; -> X'#{target.asHex(4)}'" + (if label then " <#{label}>" else "")

disasm = (age, write, fcmPath, byteCount, startAddr, endAddr) ->
  startAddr ?= age.sym.symbols?.entryPoint ? 0
  hwCount = byteCount / 2
  if not endAddr?
    endAddr = hwCount - 1
    while endAddr > 0 and age.mainStorage.get16(endAddr) == 0
      endAddr--
    endAddr++

  write "=== GPC Disassembly ==="
  write "FCM: #{fcmPath} (#{byteCount} bytes, #{hwCount} halfwords)"
  write "Range: 0x#{startAddr.asHex(4)} - 0x#{endAddr.asHex(4)}"
  if age.sym.symbols?
    write "Entry Point: 0x#{age.sym.symbols.entryPoint?.asHex(4) or 'N/A'}"
  write ""

  currentSection = null
  addr = startAddr
  while addr < endAddr
    if age.sym.symbols?
      for sect in age.sym.sectionsByAddr
        if sect.address == addr
          write ""
          write ";" + "=".repeat(60)
          write "; SECTION: #{sect.name} (#{sect.size} halfwords, module: #{sect.module})"
          write ";" + "=".repeat(60)
          currentSection = sect.name
          break

    syms = age.sym.getSymbolsAt(addr)
    if syms.length > 0
      for sym in syms
        typeStr = if sym.type == 'entry' then 'ENTRY' else 'LABEL'
        write "                      #{sym.name}:  ; #{typeStr}"

    hw1 = age.mainStorage.get16(addr)
    hw2 = age.mainStorage.get16(addr + 1)
    [d, v] = Instruction.decode(hw1, hw2)
    if d?
      instrLen = d.len
      disasmStr = Instruction.toStr(hw1, hw2) + icRelNote(age, d, v, addr)
      hw1Str = hw1.asHex(4)
      if instrLen > 1
        hw2Str = hw2.asHex(4)
      else
        hw2Str = "    "
      write "#{addr.asHex(6)}: #{hw1Str} #{hw2Str}  #{disasmStr}"
    else
      write "#{addr.asHex(6)}: #{hw1.asHex(4)}       DC    X'#{hw1.asHex(4)}'"
      instrLen = 1
    addr += instrLen


export addCommand = (program) ->
  cmd = program.command('disasm')
    .description('Disassemble an FCM memory image')
    .argument('<fcm-file>', 'FCM memory image to load')

  AGEHarness.addOptions(cmd)

  cmd
    .option('--end <addr>', 'end address in hex')
    .action (fcmPath, o) ->
      checkFCMFits(fcmPath, o.machine)
      age = new AGEHarness(gpc: o.gpc, mode: o.mode)
      info = age.configureFromOpts(fcmPath, o)
      write = (s) -> process.stdout.write(s + '\n')
      disasm(age, write, fcmPath, info.byteCount,
             (if o.start then parseHex(o.start) else null),
             (if o.end then parseHex(o.end) else null))
      process.exit(0) # force electron exit
