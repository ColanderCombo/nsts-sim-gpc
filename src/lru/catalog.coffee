# LRU command catalog; one entry per `lru/<name>/spec.coffee`.

import {SPEC as adc}   from './adc/spec'
import {SPEC as adta}  from './adta/spec'
import {SPEC as ddu}   from './ddu/spec'
import {SPEC as imu}   from './imu/spec'
import {SPEC as mdm}   from './mdm/spec'
import {SPEC as mmu}   from './mmu/spec'
import {SPEC as mtu}   from './mtu/spec'
import {SPEC as nsp}   from './nsp/spec'
import {SPEC as pcmmu} from './pcmmu/spec'

export SPECS = [adc, adta, ddu, imu, mdm, mmu, mtu, nsp, pcmmu]

export specOf = (id) ->
  (s for s in SPECS when s.id == String(id).toLowerCase())[0] ? null
