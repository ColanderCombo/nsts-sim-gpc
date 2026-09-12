import {defc, COMMANDS} from './registry'

GUI_WANT_ALL = ['regs', 'ints', 'intlog', 'iop', 'breakpoints', 'halucp']

GUI_MAX_WINDOW = 4096

guiRegs = (s) ->
  cpu = s.gpc.cpu
  banks = for rf in cpu.regFiles
    {
      values: (rf.r(i).get32() >>> 0 for i in [0..7])
      lastWritten: Array.from(rf.lastWritten)
      dse: rf.dse.slice()
      dseLastWritten: Array.from(rf.dseLastWritten)
    }
  {
    step: cpu.mainStorage.step
    regSet: cpu.psw.getRegSet()
    banks: banks
    psw: {
      psw1: cpu.psw.psw1.get32() >>> 0
      psw2: cpu.psw.psw2.get32() >>> 0
      lastWritten1: cpu.psw.lastWritten1
      lastWritten2: cpu.psw.lastWritten2
    }
  }

guiWindow = (s, w) ->
  addr = (w.addr ? 0) & 0x7ffff
  n = Math.max(0, Math.min(GUI_MAX_WINDOW, w.count ? 0))
  out = {
    addr: addr, count: n
    values: (s.ram.get16(addr + i, false) for i in [0...n])
  }
  if w.prot
    out.prot = ((if s.ram.getStoreProtect(addr + i) then 1 else 0) for i in [0...n])
  if w.access
    out.lastRead = (s.ram.getLastRead(addr + i) for i in [0...n])
    out.lastWritten = (s.ram.getLastWritten(addr + i) for i in [0...n])
    out.protLastWritten = (s.ram.getProtLastWritten(addr + i) for i in [0...n])
  out

defc 'guisnap',
  summary: 'One refresh of everything a GUI pane reads'
  params: [
    { name: 'windows', type: 'json', flag: true }
    { name: 'want', type: 'json', flag: true }
    { name: 'iopdisasm', type: 'json', flag: true }
    { name: 'intlogcount', type: 'int', flag: true, default: 40 }
  ]
  exec: (s, a) ->
    want = a.want ? GUI_WANT_ALL
    has = (k) -> want.indexOf(k) >= 0
    iop = s.gpc.iop
    out = {
      status: s.stopBody()
      running: !!s.running
      steps: s.stepCount
      simTimeSec: s.simTimeSec()
      speedRatio: s.speedRatio ? null
      realTime: !!s.realTime
      rtFactor: s.rtFactor
      idling: !!s.idling
      statusNote: s.statusNote ? null
      totalHW: s.ram.totalHWCount ? 0x80000
      memory: (guiWindow(s, w) for w in (a.windows ? []))
    }
    out.regs = guiRegs(s) if has('regs')
    out.ints = COMMANDS.ints.exec(s) if has('ints')
    out.intlog = COMMANDS.intlog.exec(s, { count: a.intlogcount ? 40 }) if has('intlog')
    out.iop = COMMANDS.iop.exec(s, { active: false }) if has('iop') and iop?
    if a.iopdisasm? and iop?
      wanted = if Array.isArray(a.iopdisasm) then a.iopdisasm else [a.iopdisasm]
      out.iopdisasm = for w in wanted when 0 <= w.proc <= 24
        COMMANDS.iopdisasm.exec(s, { proc: w.proc, count: w.count ? 8, addr: null })
    out.breakpoints = s.breakpointList() if has('breakpoints')
    if has('halucp')
      out.halucp = {
        active: !!s.halUCP.active
        waitingForInput: !!s.halUCP.waitingForInput
        trapAddrs: s.halUCP.trapAddrs ? null
      }
    out
  render: (r) ->
    hw = (w.count for w in r.memory).reduce(((a, b) -> a + b), 0)
    "guisnap: #{r.memory.length} window#{if r.memory.length == 1 then '' else 's'}" +
    " (#{hw} halfwords), #{r.steps} steps, " +
    "#{if r.running then 'running' else r.status.reason}"
