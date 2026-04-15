
# GPC — Unified CLI for the AP-101 GPC Simulator
#
# Each subcommand lives in its own gpc/cmd_*.coffee file and exports an
# addCommand(program) function that registers itself.  Adding a new
# subcommand is one new file plus one import + addCommand call here.

{Command} = require 'commander'

import {addCommand as addRun}    from 'gpc/cmd_run'
import {addCommand as addDebug}  from 'gpc/cmd_debug'
import {addCommand as addGui}    from 'gpc/cmd_gui'
import {addCommand as addDump}   from 'gpc/cmd_dump'
import {addCommand as addDisasm} from 'gpc/cmd_disasm'

program = new Command()
  .name('gpc')
  .description('AP-101 GPC Simulator')
  .version('1.0.0')

addRun(program)
addDebug(program)
addGui(program)
addDump(program)
addDisasm(program)

program.parse()
