#
# GPC stand-in for DDU and MEDS flight-instrument messages on the FC busses.
#
# The rates and errors are given in degrees a second and degrees against
# the scale the labels announce, and go out as the fraction of that scale
# (F.4.103, the LADIRR and LADIRE equations).  A pointer stows when its
# word's control bit is off.
#

import {IUA, HFE_SEQUENCE, ENCODE, encodeMEDS1, encodeMEDS2, DEV_FULL_SCALE, DEV_DOTS} from './dduConf'

# name, default, low, high, unit, what it is.  `ramp` mode runs each over
# low..high.
FIELDS = [
  ['adiRol',     0,     0,   360, 'deg',  'roll attitude']
  ['adiPch',     8,     0,   360, 'deg',  'pitch attitude']
  ['adiYaw',     0,     0,   360, 'deg',  'yaw attitude']
  ['rolRate',    0,    -5,     5, 'deg/s', 'roll rate, against rateScale']
  ['pchRate',    0,    -5,     5, 'deg/s', 'pitch rate']
  ['yawRate',    0,    -5,     5, 'deg/s', 'yaw rate']
  ['rolErr',     0,    -5,     5, 'deg',  'roll attitude error, against errScale']
  ['pchErr',     0,    -5,     5, 'deg',  'pitch attitude error']
  ['yawErr',     0,    -5,     5, 'deg',  'yaw attitude error']
  ['rateScale',  5,     1,    10, 'deg/s', 'rate pointer full scale, the label']
  ['errScale',   5,     1,    10, 'deg',  'error needle full scale, the label']
  ['heading',  180,     0,   360, 'deg',  'HSI heading']
  ['course',   150,     0,   360, 'deg',  'HSI selected course']
  ['priBearing', 200,   0,   360, 'deg',  'HSI primary bearing']
  ['secBearing',  90,   0,   360, 'deg',  'HSI secondary bearing']
  ['priRange',  45,     0,   999, 'nm',   'HSI primary range']
  ['secRange',  12,     0,   999, 'nm',   'HSI secondary range']
  ['cdi',     -0.5,    -3,     3, 'dots', 'course deviation']
  ['gsi',      0.3,    -3,     3, 'dots', 'glide slope deviation']
  ['mach',     0.8,     0,    27, 'M',    'mach to 4, thousands of ft/s above']
  ['alpha',      8,   -10,    40, 'deg',  'angle of attack']
  ['keas',     250,     0,   499, 'kt',   'equivalent airspeed']
  ['accel',    1.2,    -2,     4, 'g',    'vehicle acceleration']
  ['altitude', 25000, -1000, 400000, 'ft', 'altitude above the runway']
  ['hdot',    -150, -2900,  2900, 'ft/s', 'altitude rate']
  ['radarAlt', null,    0,  5000, 'ft',   'radar altitude, valid below 5000 ft of altitude; follows the altitude unless set']
  ['vertAccel',  0,   -12,    12, 'ft/s2', 'vertical acceleration']
  ['majorMode', 305,  null, null, '',     'major mode']
  ['iphase',     1,  null, null,  '',     'TAEM guidance phase']
  ['islect',     1,  null, null,  '',     'entry guidance phase']
  ['hsiMode',    1,  null, null,  '',     'HSI mode indicator: 1 entry, 2 TAEM, 3 approach']
  ['attSel',     2,  null, null,  '',     'ADI attitude select: 1 INRTL, 2 LVLH, 3 REF']
  ['hVr',      200,     0,   360, 'deg',  'relative velocity heading, the E pointer']
  ['thetaMaxDelta', 10, -30, 30, 'deg',  'pitch to the max theta limit']
  ['thetaMinDelta', 10, -30, 30, 'deg',  'pitch above the min theta limit']
  ['cdiScale',  50,  null, null,  '',     'CDI scale label']
  ['dAz',        5,   -90,   90,  'deg',  'delta azimuth']
  ['targetNz', 1.5,     0,    3,  'g',    'target Nz']
  ['beta',     0.5,   -10,   10,  'deg',  'sideslip']
  ['dIncl',      0,   -20,   20,  'deg',  'delta inclination']
  ['xtrk',       0,  -100,  100,  'nm',   'cross track']
  ['xtrkDev',    0,  -500,  500,  'nm',   'cross track deviation']
  ['tgtIncl', 51.6,  null, null,  'deg',  'target inclination']
]

FLAGS = [
  ['abortMode', null, 'RTLS | TAL | AOA | ATO | CA, or none']
  ['ppa',       false, 'RTLS powered pitch-around done']
  ['rollSw',    false, 'HSI heads-down']
  ['tgEnd',     false, 'TAEM guidance end']
  ['wowlon',    false, 'weight on main gear']
  ['dapAuto',   true,  'DAP and pitch auto']
  ['throtAuto', true,  'throttle and roll/yaw auto']
  ['throtBlank', false, 'throttle and roll/yaw fields blank']
  ['sbAuto',    true,  'speed brake auto']
  ['dAzWarn',   false, 'delta azimuth warning']
  ['rollTgo',   false, 'the roll rate scale reads time to go to the HAC turn']
  ['rollTgo0R', false, 'zero at the right end of that scale']
  ['siteId',   'KSC15', 'landing site, five characters']
]

defaultState = () ->
  s = {}
  s[f[0]] = f[1] for f in FIELDS
  s[f[0]] = f[1] for f in FLAGS
  s

fieldOf = (name) ->
  for f in FIELDS when f[0] == name
    return f
  for f in FLAGS when f[0] == name
    return f
  null

deg2rad = Math.PI / 180

rampState = (t, period, base) ->
  s = Object.assign {}, base
  for f, i in FIELDS when f[2]? and f[0] != 'radarAlt'
    p = period + i
    ph = (t % p) / p
    tri = if ph < 0.5 then 2 * ph else 2 - 2 * ph
    s[f[0]] = f[2] + tri * (f[3] - f[2])
  s

radarAltOf = (s) -> s.radarAlt ? Math.max(0, s.altitude - 40)

# One HFE cycle: [{iua, msg, words}] in dduConf.HFE_SEQUENCE order.
messagesOf = (s, opts = {}) ->
  clear = {}
  clear[n] = true for n in (opts.offWords ? [])
  ddus = opts.ddus ? [1, 2, 3]
  meds = opts.meds ? true
  validOf = (msg, names) ->
    v = {}
    v[i] = not clear["#{msg}.#{n}"] for n, i in names
    v
  rs = s.rateScale or 1
  es = s.errScale or 1
  adi = ENCODE.ADI {
    rollSin: Math.sin(s.adiRol * deg2rad), rollCos: Math.cos(s.adiRol * deg2rad)
    pitchSin: Math.sin(s.adiPch * deg2rad), pitchCos: Math.cos(s.adiPch * deg2rad)
    yawSin: Math.sin(s.adiYaw * deg2rad), yawCos: Math.cos(s.adiYaw * deg2rad)
    rollRate: s.rolRate / rs, pitchRate: s.pchRate / rs, yawRate: s.yawRate / rs
    rollErr: s.rolErr / es, pitchErr: s.pchErr / es, yawErr: s.yawErr / es
  }, validOf('ADI', ['control', 'test', 'rollSin', 'rollCos', 'pitchSin', 'pitchCos',
                     'yawSin', 'yawCos', 'rollRate', 'pitchRate', 'yawRate', 'rollErr', 'pitchErr', 'yawErr'])
  dots = (d) -> d / DEV_DOTS * DEV_FULL_SCALE
  hsi = ENCODE.HSI {
    course: s.course, heading: s.heading, priBearing: s.priBearing, secBearing: s.secBearing
    priRange: s.priRange, secRange: s.secRange, cdi: dots(s.cdi), gsi: dots(s.gsi)
  }, validOf('HSI', ['control', 'test', 'course', 'heading', 'priBearing', 'secBearing',
                     'priRange', 'secRange', 'cdi', 'gsi'])
  radarOk = 0 <= s.altitude < 5000 and not clear['AVVI.radarAlt']
  avviValid = validOf('AVVI', ['control', 'test', 'altitude', 'hdot', 'radarAlt', 'vertAccel'])
  avviValid[4] = radarOk
  avvi = ENCODE.AVVI {altitude: s.altitude, hdot: s.hdot, radarAlt: radarAltOf(s), vertAccel: s.vertAccel}, avviValid
  ami = ENCODE.AMI {mach: s.mach, alpha: s.alpha, eas: s.keas, accel: s.accel},
                   validOf('AMI', ['control', 'test', 'mach', 'alpha', 'eas', 'accel'])
  m1 = encodeMEDS1 {
    majorMode: s.majorMode, abortMode: s.abortMode, ppa: s.ppa, rollSw: s.rollSw
    iphase: s.iphase, islect: s.islect, tgEnd: s.tgEnd, wowlon: s.wowlon
    hsiModeL: s.hsiMode, hsiModeR: s.hsiMode
    thetaMaxDelta: Math.sin(s.thetaMaxDelta * deg2rad), thetaMinDelta: Math.sin(s.thetaMinDelta * deg2rad)
    scale: {pitchRateL: rs, pitchRateR: rs, yawRateL: rs, yawRateR: rs, rollRateL: rs, rollRateR: rs,
            pitchErrL: es, pitchErrR: es
            rollRateTgoL: s.rollTgo, rollRateTgoR: s.rollTgo, rollRate0OnRight: s.rollTgo0R}
    attSelL: s.attSel, attSelR: s.attSel
    sbAuto: s.sbAuto, throtBlank: s.throtBlank, throtAuto: s.throtAuto, dapAuto: s.dapAuto
    cdiScale: s.cdiScale, dAz: s.dAz, dAzWarn: s.dAzWarn, hVr: s.hVr, siteId: s.siteId
    targetNz: s.targetNz, beta: s.beta, dIncl: s.dIncl
  }, [7..30].concat(['M2.1', 'M2.2', 'M2.3'])
  m2 = encodeMEDS2 {xtrk: s.xtrk, xtrkDev: s.xtrkDev, tgtIncl: s.tgtIncl}
  zeros = (n) -> new Array(n).fill(0)
  wordsOf = {ADI: adi, HSI: hsi, AVVI: avvi, AMI: ami, MEDS1: m1, MEDS2: m2, MEDS3: zeros(30), MEDS4: zeros(10)}
  out = []
  for e in HFE_SEQUENCE
    if e.msg.startsWith('MEDS')
      continue unless meds
    else
      continue unless (({6: 1, 9: 2, 15: 3})[e.iua]) in ddus
    out.push {iua: e.iua, msg: e.msg, words: wordsOf[e.msg]}
  out

export {FIELDS, FLAGS, defaultState, fieldOf, rampState, messagesOf}
