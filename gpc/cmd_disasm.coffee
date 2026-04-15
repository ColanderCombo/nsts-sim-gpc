
# gpc disasm cmd 
# disassemble a FCM memory image
#
import {AGEHarness} from 'gpc/ageharness'
import {BatchRunner} from 'gpc/cmd_run'

parseHex = (s) -> parseInt(s.replace(/^0x/i, ''), 16)

export addCommand = (program) ->
  cmd = program.command('disasm')
    .description('Disassemble an FCM memory image')
    .argument('<fcm-file>', 'FCM memory image to load')

  AGEHarness.addOptions(cmd)

  cmd
    .option('--end <addr>', 'end address in hex')
    .action (fcmPath, o) ->
      runner = new BatchRunner(Object.assign({}, o, { fcmPath }))
      endAddr = if o.end then parseHex(o.end) else null
      entryPoint = if o.start then parseHex(o.start) else null
      runner.disasm(entryPoint, endAddr)
      process.exit(0) # force electron exit
