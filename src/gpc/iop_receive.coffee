export class BCEReceive
  constructor: (opts) ->
    @pc = opts.pc
    @addr = opts.addr & 0x3ffff
    @left = opts.count
    @sinceNs = @beganNs = opts.nowNs
    @gotAny = false
    @deliverAt = opts.deliverAt
    @turnsAt = opts.turnsAt
    @startWall = opts.startWall
    @sinceWall = opts.sinceWall

  advance: (nowNs, wallMs) ->
    @addr = (@addr + 1) & 0x3ffff
    @left -= 1
    @gotAny = true
    @sinceNs = nowNs
    @sinceWall = wallMs
    return

  complete: () -> @left == 0

  timedOut: (nowNs, timeoutNs) -> nowNs - @sinceNs >= timeoutNs
