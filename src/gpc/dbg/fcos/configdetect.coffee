# Detect the resident configuration from memory and flight-software state.

fs = require 'fs'
path = require 'path'

# Samples per phase's protected text.
PHASE_PROBES = 512

# Resident-MC fields in confidence order; ARC_CURRENT_MC can remain stale.
MC_VARIABLES = ['CDJV_SELF_RESIDENT_MC', 'CZ2V_OPS_MC', 'ARXVL_MC_SELF']
GRT_VARIABLE = 'CZ2V_GRT_PHASES'

export class ConfigDetector
  constructor: (@root) ->
    @_candidates = null
    @_probes = null

  @rootFor: (fcmPath) ->
    return null unless fcmPath?
    path.dirname(path.dirname(path.resolve(fcmPath)))

  candidates: () ->
    return @_candidates if @_candidates?
    out = []
    try
      dirs = fs.readdirSync(@root, { withFileTypes: true })
    catch e
      return @_candidates = []
    for d in dirs when d.isDirectory()
      name = d.name
      fcm = path.join(@root, name, "#{name}.fcm")
      sym = path.join(@root, name, "#{name}.sym.json")
      continue unless fs.existsSync(fcm) and fs.existsSync(sym)
      try
        manifest = JSON.parse(fs.readFileSync(sym, 'utf8'))
      catch e
        continue
      repro = manifest.repro ? {}
      continue unless repro.tool == 'mmu2fcm'
      sdl = path.join(@root, name, "#{name}.sdl.json")
      sp = manifest.storeProtect
      out.push({
        name: repro.config ? name
        fcm: fcm, sym: sym
        sdl: if fs.existsSync(sdl) then sdl else null
        phases: repro.phases ? []
        mcfPhases: repro.mcfPhases ? null
        runs: manifest.ownerPhaseRunsHW ? []
        protect: if sp?.unit == 'halfword' then (sp.ranges ? null) else null
      })
    @_candidates = out.sort (a, b) -> a.name.localeCompare(b.name)


  phaseProbes: () ->
    return @_probes if @_probes?
    seen = {}
    out = {}
    for c in @candidates()
      continue unless c.runs.length
      img = fs.readFileSync(c.fcm)
      limit = img.length >> 1
      for run, i in c.runs
        ph = run[1]
        continue unless ph > 0
        lo = run[0]
        hi = if i + 1 < c.runs.length then c.runs[i + 1][0] else limit
        hi = Math.min(hi, limit)
        for a in [lo...hi]
          continue if seen[a]
          continue if c.protect? and not inRanges(c.protect, a)
          seen[a] = true
          (out[ph] ?= []).push([a, img.readUInt16BE(a << 1)])
    probes = {}
    for ph, rows of out
      stride = Math.max(1, Math.ceil(rows.length / PHASE_PROBES))
      probes[ph] = (rows[i] for i in [0...rows.length] by stride)
    @_probes = probes

  phaseResidency: (readHw) ->
    rows = []
    for ph, probes of @phaseProbes()
      matched = 0
      for [a, v] in probes
        matched++ if readHw(a) == v
      rows.push({ phase: Number(ph), matched, probed: probes.length,
                  score: matched / probes.length })
    rows.sort (a, b) -> a.phase - b.phase

  fingerprint: (readHw) ->
    res = @phaseResidency(readHw)
    byPhase = {}
    byPhase[r.phase] = r for r in res
    rows = []
    for c in @candidates()
      want = c.mcfPhases ? c.phases
      have = (byPhase[p] for p in want when byPhase[p]?)
      continue unless have.length
      worst = have[0]
      worst = h for h in have when h.score < worst.score
      rows.push({
        config: c.name, phases: have, want: want
        matched: worst.matched, probed: worst.probed, score: worst.score
        depth: want.length
      })
    rows.sort (a, b) -> b.score - a.score or b.depth - a.depth
    { residency: res, configs: rows }

  choose: (rows, min) ->
    best = null
    for r in rows when r.score >= min
      best = r if not best? or r.depth > best.depth
    best


  fromFcos: (sdl, readHw) ->
    return null unless sdl?
    read = []
    for name in MC_VARIABLES
      hits = sdl.lookup(name)
      continue unless hits.length == 1
      v = sdl.read(hits[0], readHw).values?[0]?.value
      read.push({ variable: name, mc: v }) if v?
    return null unless read.length
    taken = (r for r in read when r.mc > 0)[0] ? read[0]
    mc = taken.mc
    out = { variable: taken.variable, mc, read, phases: null, config: null }
    return out unless mc > 0
    grt = sdl.lookup(GRT_VARIABLE)
    return out unless grt.length == 1
    row = sdl.read(grt[0], readHw, { limit: mc })
    copy = row.copies?[mc - 1]
    return out unless copy?
    phases = []
    for f in copy.fields
      for v in (f.values ? []) when v.value > 0
        phases.push(v.value)
    out.phases = phases.sort (a, b) -> a - b
    return out unless phases.length
    want = sortedSet(phases.concat([2, 13]))
    for c in @candidates() when c.mcfPhases?
      out.config = c.name if sameSet(sortedSet(c.mcfPhases), want)
    out

sortedSet = (xs) ->
  seen = {}
  out = (x for x in xs when not seen[x] and (seen[x] = true))
  out.sort (a, b) -> a - b

sameSet = (a, b) ->
  return false unless a.length == b.length
  for v, i in a
    return false unless v == b[i]
  true

inRanges = (ranges, addr) ->
  lo = 0
  hi = ranges.length - 1
  while lo <= hi
    mid = (lo + hi) >> 1
    r = ranges[mid]
    if addr < r[0] then hi = mid - 1
    else if addr >= r[1] then lo = mid + 1
    else return true
  false

export {PHASE_PROBES, inRanges}
