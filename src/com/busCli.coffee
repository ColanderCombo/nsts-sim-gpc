# Shared transport, clock, scheduling, and power options for bus clients.

import {configureBus, DEFAULT_BASE_PORT, DEFAULT_IFACE} from 'com/bus'
import {configureBarrier} from 'com/simbarrier'
import {configurePower, DEFAULT_POWER} from 'com/power'

{apply: applySched, DEFAULT_POLICY} = require './../native/rtpolicy.coffee'

export addBusOptions = (cmd) ->
  cmd
    .option('--base-port <n>',
            "bus port base (env NSTS_BASE_PORT; default #{DEFAULT_BASE_PORT})")
    .option('--bus-iface <addr>',
            "bus interface (env NSTS_BUS_IFACE; default #{DEFAULT_IFACE})")
    .option('--bus-shm <set>',
            'shared-memory busses: ic, headless, gui, all, off, or names')
    .option('--barrier <us>',
            'maximum simulated-time lead in microseconds (default off)')
    .option('--sched <policy>',
            "scheduler: off, qos, fixed, or rt (default #{DEFAULT_POLICY})")
    .option('--power-default <state>',
            "unreported power input: on, off, or volts (default #{DEFAULT_POWER})")
    .hook 'preAction', (thisCmd, actionCmd) ->
      o = actionCmd.opts()
      applySched(o.sched)
      try
        configureBus {basePort: o.basePort, iface: o.busIface, shm: o.busShm}
        configureBarrier {barrier: o.barrier}
        configurePower {dflt: o.powerDefault}
      catch e
        console.error "#{actionCmd.name()}: #{e.message}"
        process.exit(2)
  cmd
