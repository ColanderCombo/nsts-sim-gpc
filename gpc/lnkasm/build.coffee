
# import {Make} from './make'

import {Make} from 'gpc/lnkasm/make'

console.log "Building #{process.argv[2]}"

make = new Make(process.argv[2])
make.make()