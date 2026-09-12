
# GPC: Unified CLI for the AP-101 GPC Simulator
#
# Each subcommand lives in its own gpc/cmd_*.coffee file and exports an
# addCommand(program) function that registers itself.  Adding a new
# subcommand is one new file plus one import + addCommand call here.

{Command} = require 'commander'

import {addCommand as addRun}    from 'gpc/cmd_run'
import {addCommand as addDebug}  from 'gpc/cmd_debug'
import {addCommand as addDbgServe}  from 'gpc/cmd_dbgserve'
import {addCommand as addDbgClient} from 'gpc/cmd_dbgclient'
import {addCommand as addGui}    from 'gpc/cmd_gui'
import {addCommand as addDump}   from 'gpc/cmd_dump'
import {addCommand as addDisasm} from 'gpc/cmd_disasm'
import {addCommand as addDiscretes} from 'gpc/cmd_discretes'

program = new Command()
  .enablePositionalOptions()   # `dbg-client <cmd> --opt` gives --opt to <cmd>
  .name('gpc')
  .description('AP-101 GPC Simulator')
  .version('1.0.0')

addRun(program)
addDebug(program)
addDbgServe(program)
addDbgClient(program)
addGui(program)
addDump(program)
addDisasm(program)
addDiscretes(program)

program.parseAsync()
