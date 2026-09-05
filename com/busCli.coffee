# The bus options a command that opens a bus takes: addBusOptions(cmd) adds
# --base-port and --bus-iface, applied before the action runs.

import {configureBus, DEFAULT_BASE_PORT, DEFAULT_IFACE} from 'com/bus'

export addBusOptions = (cmd) ->
  cmd
    .option('--base-port <n>',
            "base of the bus port block (default: NSTS_BASE_PORT, or #{DEFAULT_BASE_PORT})")
    .option('--bus-iface <addr>',
            "interface the busses live on (default: NSTS_BUS_IFACE, or #{DEFAULT_IFACE})")
    .hook 'preAction', (thisCmd, actionCmd) ->
      o = actionCmd.opts()
      try
        configureBus {basePort: o.basePort, iface: o.busIface}
      catch e
        console.error "#{actionCmd.name()}: #{e.message}"
        process.exit(2)
  cmd
