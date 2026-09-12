# ADC input signals and their simulation routes.
#
# JSC-18819,Rev.F SCP 4.9 item 8 "MEDS Analog/Digital Signal Input
# Channelization" lists the 32 channels of each pair with the signal, its
# MSID and its source. `channel` is the handbook's 1-based channel number
# less one. Signals marked "***" there are "wired
# to ADCs but not currently displayed by MEDS" and have no `field`.
#
# `tap` is the corresponding MDM card and channel (mdmConfig.coffee); a
# channel without a tap is supplied only by its pair's analog bus.
#
# The volts scale is fitted with no direct documentation: 0 V at `lo`, 5 V
# at `hi`, linear between, for every signal.  `lo` and `hi` are the meter
# scales of SCP 4.9 item 6 and the subsystem displays.
#

CHANNEL_VOLTS_MIN = 0
CHANNEL_VOLTS_MAX = 5

ch = (channel, msid, source, signal, screen, field, units, lo, hi, nominal, tap) ->
  {channel, msid, source, signal, screen, field, units, lo, hi, nominal, tap}

t = (mdm, card, channel) -> {mdm, card, channel}

PAIR_CHANNELS =
  1: [
    ch  0, 'V72H5130C', 'MDM FF2', 'SPI Body Flap Position',          'SPI',     'bodyFlapPc',       '%',     0,  100,   34, t('FF2', 8,  8)
    ch  1, 'V72H5131C', 'MDM FF2', 'SPI Aileron Position',            'SPI',     'aileronDeg',       'deg',  -5,    5,    0, t('FF2', 8,  9)
    ch  2, 'V72H5110C', 'MDM FF1', 'SPI Left Inboard Elevon Pos.',    'SPI',     'elevonDeg_LR',     'deg', -35,   20,    0, t('FF1', 8, 10)
    ch  3, 'V72H5112C', 'MDM FF1', 'SPI Left Outboard Elevon Pos.',   'SPI',     'elevonDeg_LL',     'deg', -35,   20,    0, t('FF1', 8, 11)
    ch  4, 'V72H5120C', 'MDM FF1', 'SPI Right Inboard Elevon Pos.',   'SPI',     'elevonDeg_RL',     'deg', -35,   20,    0, t('FF1', 8, 12)
    ch  5, 'V72H5122C', 'MDM FF1', 'SPI Right Outboard Elevon Pos.',  'SPI',     'elevonDeg_RR',     'deg', -35,   20,    0, t('FF1', 8, 13)
    ch  6, 'V72H5105C', 'MDM FF1', 'SPI Speedbrake Pos.',             'SPI',     'speedbrakePc_ACT', '%',     0,  100,    0, t('FF1', 8,  9)
    ch  7, 'V72H5100C', 'MDM FF1', 'SPI Rudder Pos.',                 'SPI',     'rudderDeg',        'deg', -30,   30,    0, t('FF1', 8,  8)
    ch  9, 'V72H5106C', 'MDM FF1', 'SPI Speedbrake Command Pos.',     'SPI',     'speedbrakePc_CMD', '%',     0,  100,    0, t('FF1', 8,  7)
    ch 10, 'V41P0040C', 'MDM FF1', 'MPS Center Eng. Cham. Press.',    'OMS_MPS', 'mpsPc_C',          '%',     0,  115,    0, t('FF1', 8,  0)
    ch 11, 'V41P0041C', 'MDM FF2', 'MPS Left Eng. Chamber Press.',    'OMS_MPS', 'mpsPc_L',          '%',     0,  115,    0, t('FF2', 8,  0)
    ch 12, 'V41P0042C', 'MDM FF3', 'MPS Right Eng. Cham. Press.',     'OMS_MPS', 'mpsPc_R',          '%',     0,  115,    0, t('FF3', 8,  0)
    ch 13, 'V41P1433C', 'DSC OA1', 'MPS LH2 Eng. Manif. Press.',      'OMS_MPS', 'mpsEngManf_LH2',   'psia',  0,  100,   30, null
    ch 14, 'V41P1250C', 'DSC OA1', 'MPS Left Eng. He Tank Press.',    'OMS_MPS', 'mpsHeTKP_L',       'psia',  0, 5000, 4300, t('FA2', 14, 20)
    ch 15, 'V41P1254C', 'DSC OA1', 'MPS Left Eng. He Reg. Press.',    'OMS_MPS', 'mpsHeREGAP_L',     'psia',  0, 1000,  750, t('OF1', 11, 27)
    ch 16, 'V41P1600A', 'DSC OA1', 'MPS PNEU He Tank Press.',         'OMS_MPS', 'mpsPneuTK_P',      'psia',  0, 5000, 4400, t('OA1', 6, 17)
    ch 17, 'V41P1605A', 'DSC OA1', 'MPS PNEU He Reg. Press.',         'OMS_MPS', 'mpsREG_P',         'psia',  0, 1000,  750, t('OA1', 2, 11)
    ch 18, 'V41P1533A', 'DSC OA2', 'MPS LO2 Eng. Manif. Press.',      'OMS_MPS', 'mpsEngManf_LO2',   'psia',  0,  300,   20, null
    ch 19, 'V41P1150C', 'DSC OA2', 'MPS Center Eng. He Tank Press.',  'OMS_MPS', 'mpsHeTKP_C',       'psia',  0, 5000, 4300, t('FA1', 14, 20)
    ch 20, 'V41P1154A', 'DSC OA2', 'MPS Center Eng. He Reg. Press.',  'OMS_MPS', 'mpsHeREGAP_C',     'psia',  0, 1000,  750, null
    ch 21, 'V41P1350C', 'DSC OA3', 'MPS Right Eng. He Tank Press.',   'OMS_MPS', 'mpsHeTKP_R',       'psia',  0, 5000, 4300, t('FA3', 14, 20)
    ch 22, 'V41P1354A', 'DSC OA3', 'MPS Right Eng. He Reg. Press.',   'OMS_MPS', 'mpsHeREGAP_R',     'psia',  0, 1000,  750, null
    ch 23, 'V43P4121C', 'DSC OL1', 'Left OMS He Tank Press.',         'OMS_MPS', 'omsHeTKP_L',       'psia',  0, 5000, 4200, t('FA1', 6, 17)
    ch 24, 'V43P4547C', 'DSC OL2', 'Left OMS N2 Tank Press.',         'OMS_MPS', 'omsN2TKP_L',       'psia',  0, 3000, 2400, null
    ch 25, 'V43P4649C', 'DSC OL2', 'Left OMS Chamber Press.',         'OMS_MPS', 'omsPcL',           '%',     0,  160,    0, null
    ch 26, 'V43T4111C', 'DSC OL2', 'Left OMS Aux. He Tank Press.***', null,      null,               'psia',  0, 5000, 4200, t('FA1', 6, 19)
    ch 27, 'V43P5121C', 'DSC OR1', 'Right OMS He Tank Press.',        'OMS_MPS', 'omsHeTKP_R',       'psia',  0, 5000, 4200, t('FA2', 6, 17)
    ch 28, 'V43P5547C', 'DSC OR2', 'Right OMS N2 Tank Press.',        'OMS_MPS', 'omsN2TKP_R',       'psia',  0, 3000, 2400, null
    ch 29, 'V43P5649C', 'DSC OR2', 'Right OMS Chamber Press.',        'OMS_MPS', 'omsPcR',           '%',     0,  160,    0, null
  ]
  2: [
    ch  0, 'V72Q6001V', 'MDM PL2', 'APU 1 Fuel Quantity',             'HYD_APU', 'apuFuelQty_1',     '%',     0,  100,   98, t('PF2', 12, 0)
    ch  1, 'V72Q6040V', 'MDM PL2', 'APU 1 H2O Quantity',              'HYD_APU', 'apuH2OQty_1',      '%',     0,  100,   96, t('PF2', 12, 1)
    ch  2, 'V72Q6002V', 'MDM PL2', 'APU 2 Fuel Quantity',             'HYD_APU', 'apuFuelQty_2',     '%',     0,  100,   98, t('PF2', 12, 2)
    ch  3, 'V72Q6042V', 'MDM PL2', 'APU 2 H2O Quantity',              'HYD_APU', 'apuH2OQty_2',      '%',     0,  100,   96, t('PF2', 12, 3)
    ch  4, 'V72Q6044V', 'MDM PL2', 'APU 3 H2O Quantity',              'HYD_APU', 'apuH2OQty_3',      '%',     0,  100,   96, t('PF2', 12, 4)
    ch  5, 'V72Q6003V', 'MDM PL2', 'APU 3 Fuel Quantity',             'HYD_APU', 'apuFuelQty_3',     '%',     0,  100,   98, t('PF2', 12, 5)
    ch  6, 'V46P0100A', 'DSC OA1', 'APU 1 Fuel Press.',               'HYD_APU', 'apuFuelP_1',       'psia',  0,  500,  250, null
    ch  7, 'V46T0150A', 'DSC OA1', 'APU 1 Oil Temp.',                 'HYD_APU', 'apuOilTmp_1',      'degF',  0,  500,   70, t('OA1', 0, 15)
    ch  8, 'V46T0142A', 'DSC OA1', 'APU 1 EGT ***',                   null,      null,               'degF',  0, 2000,  200, null
    ch  9, 'V58P0114C', 'DSC OA1', 'Hydraulic Subsystem 1 Press.',    'HYD_APU', 'hydPress_1',       'psia',  0, 4000,   65, t('FF1', 7, 1)
    ch 10, 'V58Q0102A', 'DSC OA1', 'Hydraulic Subsystem 1 Quantity',  'HYD_APU', 'hydQty_1',         '%',     0,  100,   72, t('OA1', 6, 19)
    ch 11, 'V46P0200A', 'DSC OA2', 'APU 2 Fuel Press.',               'HYD_APU', 'apuFuelP_2',       'psia',  0,  500,  250, null
    ch 12, 'V46T0250A', 'DSC OA2', 'APU 2 Oil Temp.',                 'HYD_APU', 'apuOilTmp_2',      'degF',  0,  500,   70, t('OA2', 0, 15)
    ch 13, 'V46T0242A', 'DSC OA2', 'APU 2 EGT ***',                   null,      null,               'degF',  0, 2000,  200, null
    ch 14, 'V58P0214C', 'DSC OA2', 'Hydraulic Subsystem 2 Press.',    'HYD_APU', 'hydPress_2',       'psia',  0, 4000,   65, t('FF2', 7, 1)
    ch 15, 'V58Q0202A', 'DSC OA2', 'Hydraulic Subsystem 2 Quantity',  'HYD_APU', 'hydQty_2',         '%',     0,  100,   72, t('OA2', 6, 15)
    ch 16, 'V46P0300A', 'DSC OA3', 'APU 3 Fuel Press.',               'HYD_APU', 'apuFuelP_3',       'psia',  0,  500,  250, null
    ch 17, 'V46T0350A', 'DSC OA3', 'APU3 Oil Temp.',                  'HYD_APU', 'apuOilTmp_3',      'degF',  0,  500,   70, t('OA3', 0, 16)
    ch 18, 'V46T0342A', 'DSC OA3', 'APU 3 EGT ***',                   null,      null,               'degF',  0, 2000,  200, null
    ch 19, 'V58P0314C', 'DSC OA3', 'Hydraulic Subsystem 3 Press.',    'HYD_APU', 'hydPress_3',       'psia',  0, 4000,   65, t('FF3', 7, 1)
    ch 20, 'V58Q0302A', 'DSC OA3', 'Hydraulic Subsystem 3 Quantity',  'HYD_APU', 'hydQty_3',         '%',     0,  100,   72, t('OA3', 6, 26)
  ]

channelsOfPair = (pair) -> PAIR_CHANNELS[pair] ? []

channelByField = (pair, field) ->
  for c in channelsOfPair(pair) when c.field == field
    return c
  null

channelOf = (pair, n) ->
  for c in channelsOfPair(pair) when c.channel == n
    return c
  null

# A channel given as a number, a field name or an MSID.
parseChannel = (pair, s) ->
  t = String(s).trim()
  if /^\d+$/.test(t)
    n = parseInt(t, 10)
    return (if 0 <= n < 32 then n else null)
  for c in channelsOfPair(pair) when c.field == t or c.msid == t.toUpperCase()
    return c.channel
  null

euToVolts = (c, eu) ->
  v = CHANNEL_VOLTS_MIN + (eu - c.lo) / (c.hi - c.lo) * (CHANNEL_VOLTS_MAX - CHANNEL_VOLTS_MIN)
  Math.max(CHANNEL_VOLTS_MIN, Math.min(CHANNEL_VOLTS_MAX, v))

voltsToEu = (c, v) ->
  f = (v - CHANNEL_VOLTS_MIN) / (CHANNEL_VOLTS_MAX - CHANNEL_VOLTS_MIN)
  f = Math.max(0, Math.min(1, f))
  c.lo + f * (c.hi - c.lo)

# Display fields from one pair: {screen: {field: value}}.
INVALID_VALUE = {OMS_MPS: -1, HYD_APU: -1, SPI: null}

fieldsOfPair = (pair, volts, valid = true) ->
  out = {}
  for c in channelsOfPair(pair) when c.field?
    out[c.screen] ?= {}
    out[c.screen][c.field] = if valid then voltsToEu(c, volts[c.channel] ? 0) else INVALID_VALUE[c.screen]
  out.SPI.adcValid = valid if out.SPI?
  out

# The taps of a pair grouped by MDM: {FF1: [{channel, card, chan}, ...]}.
tapsOfPair = (pair) ->
  out = {}
  for c in channelsOfPair(pair) when c.tap?
    (out[c.tap.mdm] ?= []).push {channel: c.channel, card: c.tap.card, chan: c.tap.channel}
  out

export {
  CHANNEL_VOLTS_MIN, CHANNEL_VOLTS_MAX, PAIR_CHANNELS, INVALID_VALUE
  channelsOfPair, channelByField, channelOf, parseChannel
  euToVolts, voltsToEu, fieldsOfPair, tapsOfPair
}
