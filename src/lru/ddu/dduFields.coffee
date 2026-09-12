#
# The flight instrument display fields from the GPC's messages on one FC
# bus: what an MDU's PFD draws from the DDU words of its crew station and
# the MEDS transfer.
#
# `feed` is {ADI, HSI, AVVI, AMI, MEDS1, MEDS2}, each the message's data
# words as last heard, or absent.  A word whose control bit the GPC left
# off gives the display its invalid marker: the ADI's OFF flag, a stowed
# needle (null), the red box of a tape, and its value is null.  With
# `fresh` false, the bus quiet past the stale time, every field is
# invalid.
#

import {wordValid, wordToFrac, wordToAngle, wordToDev, devToDots, wordToBcd,
        wordToMach, wordToAlpha, wordToEas, wordToAccel,
        wordToAlt, wordToHdot, wordToRadarAlt, wordToVertAccel,
        decodeMEDS1, decodeMEDS2} from './dduConf'

STATION_DDU = {L: 1, R: 2, A: 3}

# The MDU's rate and error pointers read -5 to +5 for the DDU's full scale
# either way, the +/-5 V of table F.4.103.0-1 note 2.
POINTER_FULL_SCALE = 5

rad2deg = 180 / Math.PI

wrap360 = (d) -> ((d % 360) + 360) % 360

# ADI words to the PFD's attitude, rate and error fields.
adiFields = (w, fresh) ->
  c = w[0]
  ok = (n) -> fresh and wordValid(c, n)
  att = ok(2) and ok(3) and ok(4) and ok(5) and ok(6) and ok(7)
  f = {adiValid: att}
  if att
    f.adiRol = wrap360(Math.atan2(wordToFrac(w[2]), wordToFrac(w[3])) * rad2deg)
    f.adiPch = wrap360(Math.atan2(wordToFrac(w[4]), wordToFrac(w[5])) * rad2deg)
    f.adiYaw = wrap360(Math.atan2(wordToFrac(w[6]), wordToFrac(w[7])) * rad2deg)
  f.adiRolRate = if ok(8) then POINTER_FULL_SCALE * wordToFrac(w[8]) else null
  f.adiPchRate = if ok(9) then POINTER_FULL_SCALE * wordToFrac(w[9]) else null
  f.adiYawRate = if ok(10) then POINTER_FULL_SCALE * wordToFrac(w[10]) else null
  f.adiRolErr = if ok(11) then POINTER_FULL_SCALE * wordToFrac(w[11]) else null
  f.adiPchErr = if ok(12) then POINTER_FULL_SCALE * wordToFrac(w[12]) else null
  f.adiYawErr = if ok(13) then POINTER_FULL_SCALE * wordToFrac(w[13]) else null
  f

ADI_INVALID = {adiValid: false, adiRolRate: null, adiPchRate: null, adiYawRate: null,
               adiRolErr: null, adiPchErr: null, adiYawErr: null}

# HSI words: angles in degrees, ranges in nautical miles, deviations in
# dots.
hsiFields = (w, fresh) ->
  c = w[0]
  ok = (n) -> fresh and wordValid(c, n)
  hsiCourse: wordToAngle(w[2]), hsiCourseValid: ok(2)
  hsiHeading: wordToAngle(w[3]), hsiHeadingValid: ok(3)
  hsiPriBearing: wordToAngle(w[4]), hsiPriBearingValid: ok(4)
  hsiSecBearing: wordToAngle(w[5]), hsiSecBearingValid: ok(5)
  hsiPriRange: wordToBcd(w[6]), hsiPriRangeValid: ok(6)
  hsiSecRange: wordToBcd(w[7]), hsiSecRangeValid: ok(7)
  hsiCdi: devToDots(wordToDev(w[8])), hsiCdiValid: ok(8)
  hsiGsi: devToDots(wordToDev(w[9])), hsiGsiValid: ok(9)

HSI_INVALID = {hsiCourseValid: false, hsiHeadingValid: false, hsiPriBearingValid: false,
               hsiSecBearingValid: false, hsiPriRangeValid: false, hsiSecRangeValid: false,
               hsiCdiValid: false, hsiGsiValid: false}

# AMI words: the mach word carries mach to 4 and thousands of feet a
# second above (F.4.105, "Left/Right AMI_Mach Number"); the PFD's tape
# takes `mach` below 4 and `vel` in ft/s above.
amiFields = (w, fresh) ->
  c = w[0]
  ok = (n) -> fresh and wordValid(c, n)
  m = wordToMach(w[2])
  f = Object.assign {}, AMI_INVALID
  f.machValid = ok(2); f.alphaValid = ok(3); f.keasValid = ok(4); f.accValid = ok(5)
  if ok(2)
    f.mach = Math.min(m, 4)
    f.vel = m * 1000
  f.alpha = wordToAlpha(w[3]) if ok(3)
  f.keas = wordToEas(w[4]) if ok(4)
  f.vehicleAcceleration = wordToAccel(w[5]) if ok(5)
  f

AMI_INVALID = {machValid: false, alphaValid: false, keasValid: false, accValid: false,
               mach: null, vel: null, alpha: null, keas: null, vehicleAcceleration: null}

# AVVI words.
avviFields = (w, fresh) ->
  c = w[0]
  ok = (n) -> fresh and wordValid(c, n)
  f = Object.assign {}, AVVI_INVALID
  f.altValid = ok(2); f.hdotValid = ok(3); f.radarValid = ok(4); f.vertAccelValid = ok(5)
  f.altitude = wordToAlt(w[2]) if ok(2)
  f.hdot = wordToHdot(w[3]) if ok(3)
  f.radarAlt = wordToRadarAlt(w[4]) if ok(4)
  f.vertAccel = wordToVertAccel(w[5]) if ok(5)
  f

AVVI_INVALID = {altValid: false, hdotValid: false, radarValid: false, vertAccelValid: false,
                altitude: null, hdot: null, radarAlt: null, vertAccel: null}

# The MEDS transfer: message 1 and 2 fields the GPC marked valid, for the
# station's side of the ADI scale labels.
#
# Every field the transfer can carry is named here, so a word the GPC has
# stopped marking valid takes its field to null: "If a validity bit is off,
# the contents of the corresponding buffer word will be indeterminate and
# should not be used by the MEDS software" (STS-83-0020V3-34 F.4.128.1.2).
MEDS_INVALID =
  gpcIsPfs: null
  majorMode: null
  abortMode: null, ppa: null, rollSw: null, eoYawSteering: null
  iphase: null, islect: null
  tgEnd: null, wowlon: null
  hsiMode: null
  thetaMaxDelta: null, thetaMinDelta: null
  adiRateScale: null, adiPchErrScale: null, attSel: null
  fcsConfSBAuto: null, fcsConfThrotBlank: null
  fcsConfThrotAuto: null, fcsConfRYAuto: null
  fcsConfDAPAuto: null, fcsConfPitchAuto: null
  cdiScale: null
  dAz: null, dAzWarn: null
  hVr: null
  siteId: null
  targetNZ: null
  beta: null
  dIncl: null
  xtrk: null, xtrkDev: null, tgtIncl: null

medsFields = (m1, m2, fresh, side) ->
  f = Object.assign {medsValid: fresh}, MEDS_INVALID
  return f unless fresh and m1?
  d = decodeMEDS1(m1)
  v = d.valid
  f.gpcIsPfs = d.isPfs
  if v[8]
    f.majorMode = d.majorMode
  if v[9]
    f.abortMode = d.abortMode
    f.ppa = d.ppa
    f.rollSw = d.rollSw
    f.eoYawSteering = d.eoYawSteering
  f.iphase = d.iphase if v[10]
  f.islect = d.islect if v[11]
  if v[12]
    f.tgEnd = d.tgEnd
    f.wowlon = d.wowlon
  if v[13]
    f.hsiMode = if side == 'R' then d.hsiModeR else d.hsiModeL
  f.thetaMaxDelta = d.thetaMaxDelta if v[14]
  f.thetaMinDelta = d.thetaMinDelta if v[15]
  if v[16] and v[17] and v[18] and v[19] and v[20] and v[21]
    s = d.scale
    r = side == 'R'
    f.adiRateScale =
      roll: (if r then s.rollRateR else s.rollRateL)
      pitch: (if r then s.pitchRateR else s.pitchRateL)
      yaw: (if r then s.yawRateR else s.yawRateL)
      rollTgo: (if r then s.rollRateTgoR else s.rollRateTgoL)
      rollZeroOnRight: s.rollRate0OnRight
    f.adiPchErrScale = if r then s.pitchErrR else s.pitchErrL
    f.attSel = if r then d.attSelR else d.attSelL
    # the transfer's "DAP & Pitch" and "THROT & R/Y" indicators are one
    # field each; the PFD labels them DAP and Throt in powered flight,
    # Pitch and R/Y in gliding flight
    f.fcsConfSBAuto = d.sbAuto
    f.fcsConfThrotBlank = d.throtBlank
    f.fcsConfThrotAuto = f.fcsConfRYAuto = d.throtAuto
    f.fcsConfDAPAuto = f.fcsConfPitchAuto = d.dapAuto
  f.cdiScale = d.cdiScale if v[22]
  if v[23]
    f.dAz = d.dAz
    f.dAzWarn = d.dAzWarn
  f.hVr = d.hVr if v[24]
  f.siteId = d.siteId if v[25] and v[26] and v[27]
  f.targetNZ = d.targetNz if v[28]
  f.beta = d.beta if v[29]
  f.dIncl = d.dIncl if v[30]
  if m2?
    e = decodeMEDS2(m2)
    f.xtrk = e.xtrk if v['M2.1']
    f.xtrkDev = e.xtrkDev if v['M2.2']
    f.tgtIncl = e.tgtIncl if v['M2.3']
  f

# {screen: {field: value}} from one bus feed.
fieldsOfFeed = (station, feed, fresh = true) ->
  side = if station == 'R' then 'R' else 'L'
  f = {}
  Object.assign f, (if feed.ADI? then adiFields(feed.ADI, fresh) else ADI_INVALID)
  Object.assign f, (if feed.HSI? then hsiFields(feed.HSI, fresh) else HSI_INVALID)
  Object.assign f, (if feed.AMI? then amiFields(feed.AMI, fresh) else AMI_INVALID)
  Object.assign f, (if feed.AVVI? then avviFields(feed.AVVI, fresh) else AVVI_INVALID)
  Object.assign f, medsFields(feed.MEDS1, feed.MEDS2, fresh, side)
  {AE_PFD: f, ORBIT_PFD: f}

export {STATION_DDU, POINTER_FULL_SCALE, MEDS_INVALID, fieldsOfFeed,
        adiFields, hsiFields, amiFields, avviFields, medsFields}
