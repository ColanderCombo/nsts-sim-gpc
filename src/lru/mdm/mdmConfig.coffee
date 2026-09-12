#
# The MDM catalog: for every unit its busses, interface unit address and
# the card in each of its sixteen slots, with the signals on each channel
# where a source names them.
#
# Card mixes and signal names come from JSC-12770 Vol.5 App.A (the MDM
# tables, in card order but without channel numbers), JSC-18819 (the DPS
# console handbook, MSIDs by card/channel), JSC-12830 (EGIL), KLO-82-0071
# App.A (the GLS monitored parameters) and, for the OI MDMs,
# JSC-18611,Rev.G table 28-1.  ICD-2-14001 is the SRB MDM channelization.
# Channels marked "ALT" are the approach and landing test era
# assignments from IBM-77-SS-3576, which differ from the operational ones.
#
# The IOM type names are those of mdmConf.coffee's IOM table.
#

export MDM_CATALOG =
  FF1:
    id: 'FF1'
    nom: 'Flight Forward 1'
    busPri: 'FC1'
    busSec: 'FC5'
    iua: 10
    #
    # IMU1, NSP1, -Z STRK, ,RJDF 1B, F1 Jets
    #
    iom: [ 'TAC', # Card 0
                  #   Channel  0: TACAN 1 Bearing Word A
                  #   Channel  1: TACAN 1 Bearing Word B
                  #   Channel  2: TACAN 1 Range Word A
                  #                 TAC 1 RNG BLT-IN TST STATUS WD2B04 V74X1558B1
                  #                 TAC 1 RNG SUPR PULS PRESENT WD2B07 V74X1560B1
                  #
                  #   Channel  3: TACAN 1 Range Word B
                  #   Channel  4: RADAR ALT 1 Parent Word
                  #   Channel  5: MD1 FF01 Dscr In
                  #                 TACAN NO 1 POWER STATUS            V74X0071X1
                  #   Channel  6: MD1 FF01 Dscr In
                  #   JSC-12770 -->
                  #                 TACAN #1 PWR, BRNG, RANGE, CHAN SEL, MODE, ANTENNA
                  #                 SEL RADAR ALTIMETER #1 ALTITUDE DATA, STATUS, LOCK-ON, TEST
                  #   <-- JSC-12770
           'AID', # Card 1
                  #   Channel  0: LH RHC ROLL CMD-A                  V72K1155C1
                  #   Channel  1: LH RHC PITCH CMD-A                 V72K1156C1
                  #   Channel  2: LH RHC YAW CMD-A                   V72K1157C1
                  #   Channel  3: LEFT RUDDER PEDAL CMD-A            V72K1530C1
                  #   Channel  4: LH SBTC CMD-A
                  #   Channel  5: AFT RHC ROLL CMD-A
                  #   Channel  6: AFT RHC PITCH CMD-A
                  #   Channel  7: AFT RHC YAW CMD-A
                  # ALT -->
                  #   Channel  1: LH RHC CMD A yaw
                  #   Channel  3: LH RPTA CMD A
                  #   Channel  5: LH SBTC CMD A
                  #   Channel  6: LH RHC CMD A roll
                  #   Channel  7: LH RHC CMD A Pitch
                  # <--- ALT
                  #   JSC-12770 -->
                  #                 LH RHC ROLL, PITCH, YAW - CMD A
                  #                 LEFT RUDDER PEDAL - CMD A
                  #                 LH SBTC - CMD A
                  #                 AFT RHC ROLL, PITCH, YAW - CMD A
                  #   <-- JSC-12770
           'DOH', # Card 2
                  #   Channel  0: Discretes
                  #                 FWD VENTS 1&2 OPEN CMD 1B        V59K4051XL
                  #                 R FWD VENTS 1&2 PURGE CMD 2A       V59K4110XL
                  #                 R FWD VENTS 1&2 PURGE CMD 2A       V59K4110XL
                  #   Channel  2:
                  #                 R PB VENT 3 OPEN CMD 1B            V59K4251XL
                  #                 L PB VENT 6 OPEN CMD 1B            V59K3551XL
                  #                 R PB VENT 5 OPEN CMD 1B            V59K4451XL
                  #                 R PB VENT 3 CLOSE CMD 2A           V59K4210XL
                  #                 R PB VENT 6 CLOSE CMD 1A           V59K4500XL
                  #                 L PB VENT 5 CLOSE CMD 2A           V59K3410XL
                  #                 R PB VENT 3 CLOSE CMD 2A           V59K4210XL
                  #                 R PB VENT 6 CLOSE CMD 1A           V59K4500XL
                  #                 L PB VENT 5 CLOSE CMD 2A           V59K3410XL
                  #   JSC-12770
                  #   JSC-12770 -->
                  #                 RT FWD VENTS (1/2) - OP/CL/PURGE - CMD 1B
                  #                 RCS FWD MANF ISOL VLV #1 - OP
                  #                 RCS FWD MANF ISOL VLV #4 - CL A
                  #                 RCS FWD OX TNK ISOL VLV 3/4/5 - OP A/CL B
                  #                 RCS FWD TNK ISOL VLV 3/4/5 - CL A
                  #                 N/W STEERING - GROUND SPEED ENA CMD
                  #                 MPS STATUS AMBER LITE - ON (E1)
                  #                 LH EVENT SEQUENCE A/B/C/D/E
                  #                 DPLR XTRTR - UNIT 1
                  #                 RCS CMD R/P/Y - LAMP A - LEFT/RT
                  #                 FWD DAP AUTO-SELECT A, MANUAL-SELECT B LITES
                  #                 FWD RCS JETS NORM LITE/VERNIER LITE
                  #                 OMS - LEFT ENG ACTR SEL ACTIVE 1/2
                  #                 RT/LEFT PLB VENT 3 OP/CL - CMD 1B
                  #                 LEFT PLB VENT 6 OP/CL/PURGE 1/PURGE 2 - CMD 1B
                  #                 RT PLB VENT 5 OP/CL - CMD 1B
                  #   <-- JSC-12770
           'SIO', # Card 3
                  #   Channel  0:
                  #                 IMU 1 KT70/HAINS GOOD      WD1B0   V71X2021B1
                  #                 IMU-1 TRANS WD1 FAIL               V71X2030B1
                  #                 IMU-1 TRANS WD2 FAIL               V71X2031B1
                  # ALT --->
                  #   Channel 0: MSBLS 1
                  # <--- ALT
                  #   Channel 1: MTU 1
                  #         Wr Opcode 1: 4 words: WRITE MTU
                  #         Wr Opcode 2: 4 words: MET RESET
                  #         Rd Opcode 2: 3 words: READ MTU
                  #   JSC-12770 -->
                  #                 IMU #1 STATUS, DATA
                  #                 MTU - CHAN 1 GMT, MET, BITE STATUS, GMT/MET UPDATE
                  #                 -Z STAR TRKR STATUS, DATA, POSITION, CMD WORD
                  #   <-- JSC-12770
           'DIH', # Card 4
                  #   Channel  0: Discretes
                  #                 Bit  0: FCS MDM CHAN 3 RESET/OVERRIDE B
                  #                 Bit  1:              4 RESET/OVERRIDE C
                  #                 Bit  2: GPC UPLINK 2-STAGE BLOCK CMD A
                  #                 Bit  3: LH BODY FLAP UP   A
                  #                 Bit  4:              DOWN A
                  #                 Bit  5: MPS ME-1 SHUTDOWN CMD A
                  #                 Bit  6: RJDF 1 TRICKLE CUR CONTINUITY 1
                  #                 Bit  7: RCS FWD FU MANF ISLN VLV - 1 OP
                  #                 Bit  8:                              CL
                  #                 Bit  9:            TANK ISLN VLV - 3/4/5 OP
                  #                 Bit 10:                                  CL
                  #                 Bit 11:         HE FU PRESS VLV - A OP
                  #                 Bit 12:                             CL
                  #                 Bit 13: LH AIR DATA SOURCE SEL - LEFT (1)
                  #                 Bit 14:                        - NAV  (1)
                  #                 Bit 15:                        - RIGHT (1)
                  #   Channel  1: Discretes
                  #                 Bit  0: LH ADI ATTITUDE SEL - INERTIAL (1)
                  #                 Bit  1:                     - LV/LH (1)
                  #                 Bit  2:                     - REFERENCE (1)
                  #                 Bit  3:        RATE SCALE - HIGH (1)
                  #                 Bit  4:                   - MEDIUM (1)
                  #                 Bit  5:                   - LOW (1)
                  #                 Bit  6:        ERROR SCALE - HIGH (1)
                  #                 Bit  7:                    - MEDIUM (1)
                  #                 Bit  8:                    - LOW (1)
                  #                 Bit  9: FCS LH PITCH GAIN ENABLE A
                  #                 Bit 10:              AUTO MODE A
                  #                 Bit 11:              CSS MODE  A
                  #                 Bit 12:        R-Y GAIN ENABLE A
                  #                 Bit 13:            AUTO MODE A
                  #                 Bit 14:            CSS MODE  A
                  #                 Bit 15: LH BODY FLAP AUTO/MANUAL A
                  #   Channel  2: Discretes
                  #                 Bit  0: LH SPD BK/THROT AUTO/MAN A
                  #                 Bit  1: STAR TRKR -Z DOOR CLOSED 2
                  #                 Bit  2:                   OPEN   2
                  #                 Bit  3: ENTRY ROLL MODE NO Y JET A
                  #                 Bit  4: R PB/W VENTS 4 & 7 CLOSED 2
                  #                 Bit  5:                    OPEN   2
                  #                 Bit  6: R FWD VENTS 1 & 2 CLOSED 1
                  #                 Bit  7:                   OPEN   1
                  #                 Bit  8:                   PURGE IND 1
                  #                 Bit  9: L PB VENT 6 CLOSED 1
                  #                 Bit 10:             OPEN   1
                  #                 Bit 11:             PURGE IND 1
                  #                 Bit 12: R PB VENT 3 CLOSED 1
                  #                 Bit 13:             OPEN   1
                  #                 Bit 14:           5 CLOSED 1
                  #                 Bit 15:             OPEN   1
                  #                 R FWD VENTS 1&2 CLOSED 1           V59X4005X1
                  #                 R PB VENT 3 CLOSED 1               V59X4205X1
                  #                 L PB VENT 6 CLOSED 1               V59X3505X1
                  #                 R PB VENT 5 CLOSED 1               V59X4405X1
                  #                 R FWD VENTS 1&2 PURGE IND 1        V59X4105X1
                  #   JSC-12770 -->
                  #                 FCS MON CHAN 3 - RESET/OVERRIDE B, CHAN 4 - RESET OVERRIDE C
                  #                 FCS LH PITCH AUTO MODE A/CSS MODE A
                  #                 FCS LH R-Y AUTO MODE A/CSS MODE A
                  #                 GPC UPLINK 2-STAGE BLOCK CMD A
                  #                 LH BODY FLAP UP/DOWN CMD A, AUTO/MAN CMD A
                  #                 MPS ME 1 SHUTDOWN CMD A
                  #                 RJDF 1 TRICKLE CURRENT CONTINUITY 1
                  #                 RCS FWD FU MANF ISOL VLV 1 OP/CL
                  #                 RCS FWD FU TANK ISOL VLV 3/4/5 - OP/CL
                  #                 RCS HE FU PRESS VLV-A OP/CL
                  #                 LH AIR DATA SOURCE SEL - LEFT/NAV/RT
                  #                 LH ADI ATT SEL - INERTIAL/LVLH/REFERENCE
                  #                 LH ADI RATE SCALE - HIGH/MED/LOW
                  #                 LH ADI ERROR SCALE - HIGH/MED/LOW
                  #                 LH SPEED BRAKE/THROTTLE AUTO/MAN A
                  #                 START TRKR -Z DOOR - OP/CL-2
                  #                 ENTRY ROLL MODE AILERON A
                  #                 RT/LEFT PLB VENT 3 OP/CL-1
                  #                 RT FWD VENTS 1/2 OP/CL/PURGE IND 1
                  #                 LEFT PLB VENT 6 OP/CL/PURGE IND 1
                  #                 RT PLB VENT 5 OP/CL 1
                  #   <-- JSC-12770
           'DOL', # Card 5
                  #   Channel  0: Discretes
                  #                 Bit  0: RJDF 1B: F RCS JET F1F CMD A
                  #                 Bit  1:          F RCS JET F1L CMD A
                  #                 Bit  2:          F RCS JET F1U CMD A
                  #                 Bit  3:          F RCS JET F1D CMD A
                  #                 Bit  4: AA #1: LATERAL BITE CMD
                  #                 Bit  5:        NORMAL BITE CMD
                  #                 Bit  6:
                  #                 Bit  7:
                  #                 Bit  8:
                  #                 Bit  9:
                  #                 Bit 10:
                  #                 Bit 11:
                  #                 Bit 12:
                  #                 Bit 13:
                  #                 Bit 14:
                  #                 Bit 15:
                  #   Channel  1: Discretes
                  #                 Bit  0: FWD EVENT TIMER: ABORT TIMER-RESET
                  #                 Bit  1:
                  #                 Bit  2:
                  #                 Bit  3:
                  #                 Bit  4:
                  #                 Bit  5:
                  #                 Bit  6:
                  #                 Bit  7:
                  #                 Bit  8:
                  #                 Bit  9:
                  #                 Bit 10:
                  #                 Bit 11: C&W MATRIX: "LEFT RCS" (LEAK DETECT)
                  #                 Bit 12:
                  #                 Bit 13:
                  #                 Bit 14:
                  #                 Bit 15:
                  #   Channel  2: SPARE CHANNEL
                  #   JSC-12770 -->
                  #                 RJDF 1 JET F1F/F1L/F1U/F1D CMD A
                  #                 ACCEL ASSY 1 STATUS
                  #                 DPLR XTRTR #1 STATUS
                  #                 FWD EVENT TIMER - ABORT RESET
                  #                 LEFT RCS LEAK DET
           'DIL', # Card 6
                  #   Channel  0: Discretes
                  #                 Bit  0: RJDF 1 JET F1F CHAMBER PRESS IND
                  #                 Bit  1: RJDF 1 JET F1L CHAMBER PRESS IND
                  #                 Bit  2: RJDF 1 JET F1U CHAMBER PRESS IND
                  #                 Bit  3: RJDF 1 JET F1D CHAMBER PRESS IND
                  #                 Bit  4: LH DDU PWR SPLY A GOOD             V73X3001X1
                  #                 Bit  5: LH DDU PWR SPLY B GOOD             V73X3002X1
                  #                 Bit  6: LH DDU PWR SPLY C GOOD             V73X3003X1
                  #                 Bit  7: FWD THC POS X OUTPUT-A             V72K1315X1
                  #                 Bit  8: FWD THC NEG X OUTPUT-A             V72K1316X1
                  #                 Bit  9: FWD THC POS Y OUTPUT-A             V72K1320X1
                  #                 Bit 10: FWD THC NEG Y OUTPUT-A             V72K1321X1
                  #                 Bit 11: FWD THC POS Z OUTPUT-A             V72K1325X1
                  #                 Bit 12: FWD THC NEG Z OUTPUT-A             V72K1326X1
                  #                 Bit 13: LH SBTC TAKEOVER - A
                  #                 Bit 14:
                  #                 Bit 15:
                  #   Channel  1: Discretes
                  #                 Bit  0:
                  #                 Bit  1: LH RHC + PITCH TRIM - A
                  #                 Bit  2:        - PITCH TRIM - A
                  #                 Bit  3:        + ROLL TRIM  - A
                  #                 Bit  4:        - ROLL TRIM  - A
                  #                 Bit  5: SRB SEPARATION AUTO A CMD
                  #                 Bit  6: SRB SEPN MANUAL/AUTO ENABLE A CMD
                  #                 Bit  7: SRB SEPARATION INITITATE A CMD
                  #                 Bit  8:
                  #                 Bit  9:
                  #                 Bit 10:
                  #                 Bit 11:
                  #                 Bit 12:
                  #                 Bit 13:
                  #                 Bit 14:
                  #                 Bit 15:
                  #   Channel  2: Discretes
                  #                 Bit  0:
                  #                 Bit  1:
                  #                 Bit  2:
                  #                 Bit  3:
                  #                 Bit  4:
                  #                 Bit  5:
                  #                 Bit  6:
                  #                 Bit  7:
                  #                 Bit  8:
                  #                 Bit  9:
                  #                 Bit 10:
                  #                 Bit 11:
                  #                 Bit 12:
                  #                 Bit 13:
                  #                 Bit 14:
                  #                 Bit 15:
                  #   JSC-12770 -->
                  #                 RJDF 1 F1F/F1L/F1U/F1D CHMBR PRESS IND
                  #                 LH DDU PWR SUPPLY A/B/C STATUS
                  #                 FWD THC +/- X,Y,Z OUTPUT-A
                  #                 LH SBTC TAKEOVER-A
                  #                 LH RHC +/- PITCH, ROLL TRIM-A
                  #                 SRB SEP AUTO A CMD
                  #                 SRB SEP MAN/AUTO ENA A CMD
                  #                 SRB SEP INIT A CMD
                  #   <-- JSC-12770
           'AIS', # Card 7
                  #   Channel  0: Fwd Atch Pt Cap Volts - A
                  #   Channel  1: Hydr Sys 1 Sup Press A
                  #   Channel  8: RCS FWD HE FU TANK TEMP-1          V42T1104C1
                  #   Channel  9: RCS FWD HE FU TANK PRESS-1         V42P1113C1
                  #   Channel 10: RCS FWD OX TANK TEMP-1
                  #   Channel 11: RCS FWD HE OX TANK PRESS-2         V42P1112C1
                  #   Channel 12: RCS FWD FU TANK OUT PRESS
                  #   Channel 13: RCS FWD OX TANK ULLAGE PRESS       V42P1115C1
                  #   Channel 14: RCS FWD OX MANF PRESS-1
                  #   Channel 15: RCS FWD FU MANF PRESS-1
                  #   JSC-12770 -->
                  #                 RCS FWD OX/FU THRUST INJ TEMP F1F/F1L/F1U/F1D
                  #                 RCS FWD HE FU TANK TEMP 1/PRESS 1
                  #                 RCS FWD OX TANK TEMP A
                  #                 RCS FWD HE OX TANK PRESS 2
                  #                 RCS FWD FU TANK OUT PRESS
                  #                 RCS FWD OX OX TANK ULLAGE PRESS
                  #                 RCS FWD OX/FU MANF PRESS-1/2
                  #   <-- JSC-12770
           'AOD', # Card 8
                  #   Channel  0: MPS C ENG CHAMBER PRESS (meter/ADC)   V41P0040C
                  #   Channel  6: Nose Wheel Steering Computer CMD
                  #   The SPI block, one nine-word write from channel 7:
                  #   Channel  7: SPI SPEEDBRAKE COMMAND POSN           V72H5106C
                  #   Channel  8: SPI RUDDER POSN                       V72H5100C
                  #   Channel  9: SPI SPEEDBRAKE POSN                   V72H5105C
                  #   Channel 10: SPI L INBD ELEVON POSN                V72H5110C
                  #   Channel 11: SPI L OUTBD ELEVON POSN               V72H5112C
                  #   Channel 12: SPI R INBD ELEVON POSN                V72H5120C
                  #   Channel 13: SPI R OUTBD ELEVON POSN               V72H5122C
                  #   Channel 14: ACCEL ASSY 1 NORM TEST STIM
                  #   Channel 15: ACCEL ASSY 1 LAT TEST STIM
                  #   (MSIDs and the ADC wiring: JSC-18819,Rev.F SCP 4.9 item 8)
                  #   JSC-12770 -->
                  #                 MPS E1 MAIN CHMBR PRESS/CMPT
                  #                 RCS FWD OX/AFT OX (LEFT/RT) QTY
                  #                 RCS FWD/L AFT LOWEST PROPELLANT QTY
                  #                 OMS PBR OS TNK TOTAL QTY
                  #                 SPEED BRAKE POSN - SPI
                  #                 LH INBD/OUTBD - ELEVON POS - SPI
                  #                 RH INBD/OUTBD ELEVON POSN - SPI
                  #                 ACCEL ASSY 1 NORM/LAT TEST STIM
                  #   <-- JSC-12770
           'DIH', # Card 9
                  #   JSC-12770 -->
                  #                 RJDF 1 JET F1F/F1L/F1U/F1D DRIVER
                  #                 FWD DAP SEL A-A/SEL B-A/AUTO A/MAN A
                  #                 AFT DAP SEL A-C/SEL B-C/AUTO C/MAN C
                  #                 FCS FWD LOOP GAIN PITCH/ROLL-YAW HIGH-A/LOW-A
                  #                 SENSE SW -Z CON A/-X CON A
                  #                 ENTRY ROLL MODE AUTO-A
                  #                 FWD ROTATION R/P/Y DISC RATE A/ACCELL A/PULSE A
                  #                 FWD RCS JETS NORM A/VERNIER A
                  #                 FWD TRANSLATION X/Y/Z NORM A/PULSE A/HIGH A
                  #                 MPS LO2 FEEDLINE DUMP START A/STOP A
                  #                 LH AIR DATA PROBE DEPLOY 1/STOW 1
                  #                 ADTA 1 PWR ON CMD
                  #                 IMU 1 PWR ON CMD-B
                  #                 MSBLS #1 PWR STATUS
                  #                 TACAN #1 AUTO DISCRETE
                  #   <-- JSC-12770
                  #
                  #
                  #
                  #
                  #
           'DOH', # Card 10
                  #   Channel  0: Discretes
                  #                 R FWD VENTS 1&2 OPEN CMD 1A        V59K4050XL
                  #                 L FWD VENTS 1&2 PURGE CMD 1A       V59K3100XL
                  #                 L FWD VENTS 1&2 PURGE CMD 1A       V59K3100XL
                  #   Channel  2: Discretes
                  #                 R PB VENT 3 OPEN CMD 1A            V59K4250XL
                  #                 L PB VENT 6 OPEN CMD 1A            V59K3550XL
                  #                 R PB VENT 5 OPEN CMD 1A            V59K4450XL
                  #                 L PB VENT 3 CLOSE CMD 1A           V59K3200XL
                  #                 L PB VENT 6 CLOSE CMD 2A           V59K3510XL
                  #                 R PB VENT 5 CLOSE CMD 2A           V59K4410XL
                  #                 L PB VENT 3 CLOSE CMD 1A           V59K3200XL
                  #                 L PB VENT 6 CLOSE CMD 2A           V59K3510XL
                  #                 R PB VENT 5 CLOSE CMD 2A           V59K4410XL
                  #   JSC-12770 -->
                  #                 RT FWD VENTS 1/2 OP/CL/PURGE CMD 1A
                  #                 LH BODY FLAP AUTO
                  #                 LH SPEED BRAKE AUTO
                  #                 FCS MODE - LH P/R/Y AUTO
                  #                 RCS FWD FU TK ISOL VLV 3/4/5 OP A/CL B
                  #                 RCS FWD MANF ISOL VLV 5 CL A
                  #                 RCS FWD HW PRESS VLV A OP A/CL A
                  #                 RCS FWD MANF ISOL VLV 4 CL B
                  #                 MPS STATUS/RED LIGHT-
                  #                 FWD ROTATION R/P/Y DSCR/ACCEL/PULSE LITES
                  #                 FWD TRANSLATION X/Y/Z NORMAL/PULSE/HIGH LITES
                  #                 SM B/U C/W A CMD 1/TONE A CMD 1/ALERT A CMD 1
                  #                 RT/LEFT PLB VENT 3 OP/CL CMD 1A
                  #                 LEFT PLB VENT 6 OP/CL/PURGE 1/PURGE 2 CMD 1A
                  #                 RT PLB VENT 5 OP/CL CMD 1A
                  #   <-- JSC-12770
           'SIO', # Card 11
                  #   Channel  0: IMU 1
                  #   Channel  1: ADTA 1
                  #   JSC-12770 -->
                  #                 ADTA #1 STATUS, PRESS, TOTAL TEMP
                  #                 MSBLS #1 AZIMUTH DATA, STATUS, ELEVATION DATA, RANGE
                  #                 DPLR XTRTR 1 STATUS, STATION ID, XPNDR MODE A/B/C , XPNDR SEL
                  #                 MTU STATUS
                  #                 DPLR XTRTR 1 NSP 1/2 SEL
                  #                 DPLR COUNT/INTERVAL COUNT
                  #                 NSP 1 STATUS, CMD 1, NSP 1 CMD 2, NSP 1 CMD 3, NSP 1 CMD 4,
                  #                 NSP 1 CMD 5, NSP 1 CMD 6, NSP 1 CMD 7, NSP 1 CMD 8,
                  #                 NSP 1 CMD 9, NSP 1 CMD 10, NSP CMD VALIDITY
                  #   <-- JSC-12770
           'DIH', # Card 12
                  #   Channel  0: Discretes
                  #   Channel  1: Discretes
                  #   JSC-12770 -->
                  #                 FC MON CHAN 1 RESET/OVERRIDE B
                  #                 LH +/- P/R/Y TRIM A
                  #                 RCS FWD OX MANF ISOL VLV 1 OP/CL
                  #                 RCS FWD OX PRESS VLV-A OP/CL
                  #                 RCS FWD OX TANK ISOL VLV 3/4/5 OP/CL
                  #                 RADAR ALTM LH DISPLAY SEL NO 1/NO 2
                  #                 LH HSI MLS, NAV TACAN APPROACH /TAEM /ENTRY MODE SEL
                  #                 LH HSI SOURCE SEL 1/2/3
                  #                 LH RHC TRIM INH 4
                  #                 -Z ST PWR ON CMD
                  #                 FCS RATE GAIN PITCH MED A
                  #                 RCS MASTER XFEED FROM LEFT 1/RT 1
                  #                 ATO/AOA/RTLS ABORT REQUEST SIGNAL A
                  #                 LH ADI ATT REF PB-A/PB-B
                  #                 LEFT PLB VENT 5 PURGE 2 IND 1
                  #                 FCS RATE GAIN PITCH OFF A/ROLL-YAW MED A/ROLL-YAW OFF A
                  #                 STAR TRKR -Y DR OP 1/CL 1
                  #                 AFT RCS OPTIONS NORMAL-C/VERNIER-C
                  #   <-- JSC-12770
           'DOL', # Card 13
                  #   Channel  0: Discretes
                  #                 Bit  0: RJDF 1B: F RCS JET F1F CMD B
                  #                 Bit  1:          F RCS JET F1L CMD B
                  #                 Bit  2:          F RCS JET F1U CMD B
                  #                 Bit  3:          F RCS JET F1D CMD B
                  #                 Bit  4: ADTA #1: LOW  TEST MODE CMD
                  #                 Bit  5:          HIGH TEST MODE CMD
                  #                 Bit  6:
                  #                 Bit  7:
                  #                 Bit  8:
                  #                 Bit  9: IMU #1: IMU OPERATE MODE CMD
                  #                 Bit 10: SPI: DATA VALID CMD ("OFF" FLAG)
                  #                 Bit 11:
                  #                 Bit 12:
                  #                 Bit 13:
                  #                 Bit 14:
                  #                 Bit 15:
                  #   Channel  1: SPARE CHANNEL
                  #   Channel  2: SPARE CHANNEL
                  #   JSC-12770 -->
                  #                 RJDF 1 JET F1F/F1L/F1U/F1D CMD B
                  #                 ADTA 1 HIGH/LOW TEST MODE CMD
                  #                 IMU-1 OPERATE MODE CMD
                  #                 SPI DATA STATUS
           'AID', # Card 14
                  #   Channel  0: Norm Accel 1 signal
                  #   Channel  1: RH RHC CMD A yaw
                  #   Channel  2: Lat accel 1 signal
                  #   Channel  3: RH RPTA CMD A
                  #   Channel  5: RH SBTC CMD A
                  #   Channel  6: RH RHC CMD A roll
                  #   Channel  7: RH RHC CMD A Pitch
                  #   JSC-12770 -->
                  #                 ACCEL ASSY 1 LAT/NORM ACCEL
                  #   <-- JSC-12770
           'DIL'  # Card 15
                  #   Channel  0: Discretes
                  #                 IMU 1 PLATFORM TEMP SAFE           V71X2405X1
                  #                 IMU 1 CAPRI TEMP SAFE              V71X2407X1
                  #                 IMU 1 PLATFORM TEMP READY          V71X2404X1
                  #                 IMU 1 CAPRI TEMP READY             V71X2406X1
                  #                 IMU 1 PRESSURE/COMMUNICATION GOOD  V71X2401X1
                  #                 LH DDU GOOD                        V73X3050X1
                  #   JSC-12770 -->
                  #                 IMU 1 STATUS
                  #                 AFT THC +/- X,Y,Z OUPUT A
                  #                 ET SEP MNL ENA A/INIT A/AUTO A
                  #                 LH DDU STATUS
                  #   <-- JSC-12770
           ]
  FF2:
    id: 'FF2'
    nom: 'Flight Forward 2'
    busPri: 'FC2'
    busSec: 'FC6'
    iua: 10
    #
    # IMU2, RJDF 1A, F2 Jets
    #
    iom: [ 'TAC', # Card 0
                  #   Channel  0: TACAN 2 Bearing Word A
                  #   Channel  1: TACAN 2 Bearing Word B
                  #   Channel  2: TACAN 2 Range Word A
                  #                 TAC 2 RNG BLT-IN TST STATUS WD2B04 V74X1658B1
                  #                 TAC 2 RNG SUPR PULS PRESENT WD2B07 V74X1660B1
                  #   Channel  3: TACAN 2 Range Word B
                  #   Channel  4: RADAR ALT 2 Parent Word
                  #   Channel  5: MD1 FF02 Dscr In
                  #                 TACAN NO 2 POWER STATUS            V74X0081X1
                  #   Channel  6: MD1 FF02 Dscr In
                  #   JSC-12770
                  #                 TACAN #2 PWR, BRNG, RANGE, CHAN SEL, MODE, ANTENNA
                  #                 SEL RADAR ALTIMETER #2 ALTITUDE DATA, STATUS, LOCK-ON, TEST
           'AID', # Card 1
                  #   Channel  0: LH RHC ROLL CMD-B                  V72K1170C1
                  #   Channel  1: LH RHC PITCH CMD-B                 V72K1171C1
                  #   Channel  2: LH RHC YAW CMD-B                   V72K1172C1
                  #   Channel  3: LEFT RUDDER PEDAL CMD-B            V72K1531C1
                  #   Channel  5: LH SBTC CMD B
                  #   Channel  6: LH RHC CMD B roll
                  #   Channel  7: LH RHC CMD B Pitch
                  #   JSC-12770
                  #                 LH RHC R, P, Y - CMD B
                  #                 LEFT RUDDER PEDAL - CMD B
                  #                 LH SBTC - CMD B
                  #                 AFT RHC R, P, Y - CMD B
           'DOH', # Card 2
                  #   Channel  0: Discretes
                  #                 L FWD VENTS 1&2 OPEN CMD 2B        V59K3061XL
                  #                 L FWD VENTS 1&2 PURGE CMD 1B       V59K3101XL
                  #   JSC-12770
                  #                 LEFT FWD VENTS (1/2) - OP/CL/PURGE - CMD 2B
                  #                 RCS FWD MANF ISOL VLV 2 - OP
                  #                 RCS FWD MANF ISOL VLV 3 - CL A
                  #                 MPS E2 STATUS/AMBER LITE ON
                  #                 OMS - LEFT ENG ACTR SEL STBY 1/2
                  #                 LEFT PLB VENT 3 OP/CL CMD 2B
                  #                 LEFT PLB/W VENTS 4&7 OP/CL CMD 2B
                  #                 RT PLB VENT 6 OP/CL/PURGE 1/PURGE 2 CMD 2B
                  #                 RT PLB VENT 5 OP/CL - CMD 2B
                  #   Channel  1:
                  #                 L PB VENT 5 CLOSE CMD 1B           V59K3401XL
                  #   Channel  2:
                  #                 L PB VENT 3 OPEN CMD 2B            V59K3261XL
                  #                 R PB VENT 6 OPEN CMD 2B            V59K4561XL
                  #                 R PB VENT 5 OPEN CMD 2B            V59K4461XL
                  #                 L PB VENT 3 CLOSE CMD 1B           V59K3201XL
                  #                 R PB VENT 6 CLOSE CMD 1B           V59K4501XL
           'SIO', # Card 3
                  #   Channel 0: MSBLS 2
                  #                 IMU 2 KT70/HAINS GOOD      WD1B0   V71X3021B1
                  #                 IMU-2 TRANS WD1 FAIL               V71X3030B1
                  #                 IMU-2 TRANS WD2 FAIL               V71X3031B1
                  #   Channel 1: MTU 2
                  #         Read Opcode 2: READ 3 WORDS
                  #   JSC-12770
                  #                 IMU #2 STATUS, DATA
                  #                 MTU - CHAN 2 GMT, MET, BITE STATUS, GMT/MET UPDATE
           'DIH', # Card 4
                  #   Channel  0: Discretes
                  #   Channel  1: Discretes
                  #   Channel  2: Discretes
                  #                 L FWD VENTS 1&2 CLOSED 2           V59X3015X1
                  #                 L PB VENT 3 CLOSED 2               V59X3215X1
                  #                 R PB VENT 6 CLOSED 2               V59X4515X1
                  #                 R PB VENT 5 CLOSED 2               V59X4415X1
                  #                 L FWD VENTS 1&2 PURGE IND 2        V59X3115X1
                  #   JSC-12770
                  #                 FCS MON CHAN 2 - RESET/OVERRIDE A, CHAN 3 - RESET/OVERRIDE C
                  #                 ENTRY ROLL MODE AILERON B
                  #                 LH BODY FLAP UP/DN B, AUTO/MAN B
                  #                 MPS ME-1 SHUTDOWN CMD B
                  #                 RJDT 1 TRICKLE CURRENT CONTINUITY 2
                  #                 RCS FWD FU MANF ISOL VLV 2 OP/CL
                  #                 RCS HE FU PRESS VLV-B OP/CL
                  #                 NOSE WHEEL STEERING MAN - ON/COMPUTER-ON
                  #                 RH AIR DATA SOURCE SEL - LEFT/NAV/RT
                  #                 RH ADI ATT SEL - INERTIAL/LVLH/REFERENCE
                  #                 RH ADI RATE SCALE - HIGH/MED/LOW
                  #                 RH ADI ERROR SCALE - HIGH/MED/LOW
                  #                 FCS LH PITCH AUTO MODE B/CSS Mode B
                  #                 FCS LH R-Y AUTO MODE B/CSS MODE B
                  #                 LH SPEED BRAKE/THROT AUTO/MAN B
                  #                 MPS ENG LIMIT CNTL #1 ENA/INH/AUTO
                  #                 LEFT PLB VENT 3 OP/CL-2
                  #                 LEFT FWD VENTS (1/2) OP/CL/PURGE IND 2
                  #                 RT PLB VENT 6 OP 2/CL 2/PURGE 1 IND 2
                  #                 LEFT PLB/W VENTS 4&7 OP/CL 2
                  #                 RT PLB VENTS OP/CL 2
           'DOL', # Card 5
                  #   Channel  0: Discretes
                  #   JSC-12770
                  #                 RJDF 1 JET F2F/F2R/F2U/F2D CMD A
                  #                 ACCEL ASSY 2 BITE
           'DIL', # Card 6
                  #   Channel  0: Discretes
                  #                 RH DDU PWR SPLY A GOOD             V73X3011X1
                  #                 RH DDU PWR SPLY B GOOD             V73X3012X1
                  #                 RH DDU PWR SPLY C GOOD             V73X3013X1
                  #                 FWD THC POS X OUTPUT-B             V72K1335X1
                  #                 FWD THC NEG X OUTPUT-B             V72K1336X1
                  #                 FWD THC POS Y OUTPUT-B             V72K1340X1
                  #                 FWD THC NEG Y OUTPUT-B             V72K1341X1
                  #                 FWD THC POS Z OUTPUT-B             V72K1345X1
                  #                 FWD THC NEG Z OUTPUT-B             V72K1346X1
                  #   JSC-12770
                  #                 RJDF 1 JET F2F/F2R/F2U/F2D CHMBR PRESS IND
                  #                 RH DDU PWR SPLY A/B/C GOOD
                  #                 FWD THC POS/NEG X/Y/Z OUTPUT B
                  #                 LH SBTC TAKEOVER-B
                  #                 LH RHC +/- PITCH/ROLL TRIM B
           'AIS', # Card 7
                  #   Channel  0: Fill
                  #   Channel  1: Hydr Sys 2 Sup Press A
                  #   JSC-12770
                  #                 RCS FWD OX/FU THRUST INJ TEMP - F2F/F2R/F2D/F2U
                  #                 RCS FWD HE OX/FU PRESS-2
                  #                 RCS FWD HE FU TANK TEMP-1
           'AOD', # Card 8
                  #   Channel  0: MPS L ENG CHAMBER PRESS (meter/ADC)   V41P0041C
                  #   Channel  7: NOSE WHEEL STEERING 1A CMD (SPI block word 1)
                  #   Channel  8: SPI BODY FLAP POSN                    V72H5130C
                  #   Channel  9: SPI AILERON POSN                      V72H5131C
                  #   Channel 14: ACCEL ASSY 2 NORM TEST STIM
                  #   Channel 15: ACCEL ASSY 2 LAT TEST STIM
                  #   JSC-12770
                  #                 MPS E2 MAIN CHMBR PRESS/CMPT
                  #                 NOSE WHEEL STEERING COMPUTER CMD
                  #                 BODY FLAP POS SPI
                  #                 AILERON POS - SPI
           'DIH', # Card 9
                  #   JSC-12770
                  #                 RJDF 1 JET F2F/F2R/F2U/F2D DRIVER
                  #                 FWD DAP SEL A-B/B-B
                  #                 FWD DAP MAN B/AUTO B
                  #                 FCS FWD LOOP GAIN PITCH/ROLL-YAW HIGH-B/LOW-B
                  #                 MPS ME-2 SHUTDOWN CMD A
                  #                 SENSE SW -Z/-X CON B
                  #                 ENTRY ROLL MODE AUTO-B
                  #                 FWD ROTATION R/P/Y DISC RATE B/ACCEL B/PULSE B
                  #                 FWD RCS JETS NORM B VERNIER B
                  #                 FWD TRANSLATION X/Y/Z NORM B/PULSE B/HIGH B
                  #                 MPS LO2 FEEDLINE DUMP START B/STOP B
                  #                 LH AIR DATA PROBE DEPLOY 2/STOW 2
                  #                 ADTA 2 PWR ON CMD
                  #                 IMU-2 PWR ON CMD-B
                  #                 MSBLS 2 PWR STATUS
                  #                 TACAN 2 AUTO DISCRETE
           'DOH', # Card 10
                  #   Channel  0: Discretes
                  #                 L FWD VENTS 1&2 OPEN CMD 2A        V59K3060XL
                  #                 R FWD VENTS 1&2 PURGE CMD 1A       V59K4100XL
                  #   JSC-12770
                  #                 LEFT FWD VENTS 1/2 OP/CL/PURGE CMD 2A
                  #                 LH BODY FLAP MAN
                  #                 LH SPEED BRAKE MAN
                  #                 FCS MODE - LH PITCH/ROLL-YAW CSS
                  #                 RCS FWD MANF ISOL VLV-3 GPC CL B
                  #                 MPS E2 STATUS/RED LITE ON
                  #                 SM BU C&W A CMD 2/TONE A CMD 2/ALERT A CMD 2
                  #                 LEFT PLB VENT 3 OP?CL CMD 2A
                  #                 LEFT PLB/W VENTS 4&7 OP/CL CMD 2A
                  #                 RT PLB VENT 6 OP/CL/PURGE 1/PURGE 2 CMD 2A
                  #                 RT PLB VENT 5 OP/CL CMD 2A
                  #   Channel  2: Discretes
                  #                 L PB VENT 3 OPEN CMD 2A            V59K3260XL
                  #                 R PB VENT 6 OPEN CMD 2A            V59K4560XL
                  #                 R PB VENT 5 OPEN CMD 2A            V59K4460XL
                  #                 R PB VENT 3 CLOSE CMD 1A           V59K4200XL
                  #                 L PB VENT 6 CLOSE CMD 1A           V59K3500XL
                  #                 R PB VENT 5 CLOSE CMD 1A           V59K4400XL
           'SIO', # Card 11
                  #   Channel  0: IMU 2
                  #   Channel  1: ADTA 2
                  #   JSC-12770
                  #                 ADTA 2 STATUS DATA
                  #                 MSBLS 2 STATUS DATA
           'DIH', # Card 12
                  #   Channel  0: Discretes
                  #   Channel  1: Discretes
                  #   JSC-12770
                  #                 FCS MON CHAN 1 RESET/OVERRIDE A
                  #                 LH +/- P/R/Y TRIM B
                  #                 RCS FWD OX MANF ISOL VLV 2 OP/CL
                  #                 RCS FWD HE OX PRESS VLV B OP/CL
                  #                 NLG NO WEIGHT-ON-WHEELS #2
                  #                 NLG UPLOCKED
                  #                 RADAR ALTIM RH DISPLAY SEL 1/2
                  #                 RH HSI MLS/NAV/TACAN/SEL
                  #                 RH HSI APPROACH/TAEM/ENTRY MODE SEL
                  #                 RH HSI SOURCE SEL 1/2/3
                  #                 LH RHC TRIM INH B
                  #                 FCS RH PITCH/ROLL-YAW AUTO/CSS MODE A
                  #                 RH BODY FLAP AUTO/MAN A
                  #                 RH SPEED BRAKE/THROTTLE AUTO/MAN A
                  #                 RCS MASTER XFEED FROM LEFT-2/RT-2
                  #                 ATO/AOA/RTLS ABORT REQUEST SIGNAL B
                  #                 RH ADI ATT REF PLB A/B
                  #                 RT PLB VENT 6 PURGE 2 IND 2
                  #                 LMG NO WEIGHT ON WHEELS/UPLOCKED
                  #                 RMG DR UPLOCKED
                  #                 FCS RATE GAIN PITCH/ROLL-YAW MED B/OFF B
           'DOL', # Card 13
                  #   Channel  0: Discretes
                  #   JSC-12770
                  #                 RJDF 1 JET F2F/F2R/F2U/F2D CMD B
                  #                 ADTA 2 HIGH/LOW TEST MODE CMD
                  #                 IMU 2 OPERATE MODE CMD

           'AID', # Card 14
                  #   Channel  0:
                  #                 RH RHC ROLL CMD-A                  V72K1205C1
                  #   Channel  1:
                  #                 RH RHC PITCH CMD-A                 V72K1206C1
                  #   Channel  2:
                  #                 RH RHC YAW CMD-A                   V72K1207C1
                  #   Channel  3:
                  #                 RIGHT RUDDER PEDAL CMD-A           V72K1540C1
                  # --> ALT
                  #   Channel  0: Norm Accel 2 signal
                  #   Channel  1: RH RHC CMD B yaw
                  #   Channel  2: Lat accel 2 signal
                  #   Channel  3: RH RPTA CMD B
                  #   Channel  5: RH SBTC CMD B
                  #   Channel  6: RH RHC CMD B roll
                  #   Channel  7: RH RHC CMD B Pitch
                  # <-- ALT
                  #   JSC-12770
                  #                 RH RHC R/P/Y CMD-A
                  #                 RIGHT RUDDER PEDAL CMD-A
                  #                 RH SBTC CMD-A
                  #                 ACCEL ASSY 2 LAT/NORM ACCEL
           'DIL'  # Card 15
                  #   Channel  0: Discretes
                  #                 IMU 2 PLATFORM TEMP SAFE           V71X3405X1
                  #                 IMU 2 CAPRI TEMP SAFE              V71X3407X1
                  #                 IMU 2 PLATFORM TEMP READY          V71X3404X1
                  #                 IMU 2 CAPRI TEMP READY             V71X3406X1
                  #                 IMU 2 PRESSURE/COMMUNICATION GOOD  V71X3401X1
                  #                 RH DDU GOOD                        V73X3051X1
                  #   JSC-12770
                  #                 IMU 2 STATUS
                  #                 RH DDU STATUS
                  #                 AFT THC +/- X/Y/Z OUTPUT B
                  #                 RH SBTC TAKEOVER A
    ]
  FF3:
    id: 'FF3'
    nom: 'Flight Forward 3'
    busPri: 'FC3'
    busSec: 'FC7'
    iua: 10
    #
    # IMU3, NSP2, -Y STRK, Ku RDR, RJDF 2B, F4 Jets, F5 Jets
    #
    iom: [ 'TAC', # Card 0
                  #   Channel  0: TACAN 3 Bearing Word A
                  #   Channel  1: TACAN 3 Bearing Word B
                  #   Channel  2: TACAN 3 Range Word A
                  #                 TAC 3 RNG BLT-IN TST STATUS WD2B04 V74X1758B1
                  #                 TAC 3 RNG SUPR PULS PRESENT WD2B07 V74X1760B1
                  #                 TAC 3 RNG BLT-IN TST STATUS WD2B04 V74X1758B1
                  #                 TAC 3 RNG SUPR PULS PRESENT WD2B07 V74X1760B1
                  #   Channel  3: TACAN 3 Range Word B
                  #   Channel  4: Fill
                  #   Channel  5: MDM FF03 Dscr In
                  #                 TACAN NO 3 POWER STATUS            V74X0091X1
                  #   Channel  6: MDM FF03 Dscr In
                  #   JSC-12770 -->
                  #     tacan #3 pwr, brng, range, chan sel, mode, antenna select
                  #   <-- JSC-12770
           'AID', # Card 1
                  #   Channel  0:
                  #                 LH RHC ROLL CMD-C                  V72K1185C1
                  #   Channel  1:
                  #                 LH RHC PITCH CMD-C                 V72K1186C1
                  #   Channel  2:
                  #                 LH RHC YAW CMD-C                   V72K1187C1
                  #   Channel  3:
                  #                 LEFT RUDDER PEDAL CMD-C            V72K1532C1
                  #   Channel  5: LH SBTC CMD C
                  #   Channel  6: LH RHC CMD C roll
                  #   Channel  7: LH RHC CMD C Pitch
                  #   JSC-12770 -->
                  #     lh rhc r, p, y-cmd c
                  #     left rudder pedal cmd-c
                  #     lh sbtc-cmd c
                  #     aft rhc r, p, y-cmd c
                  #   <-- JSC-12770
           'DOH', # Card 2
                  #   Channel  0: Discretes
                  #                 L PB VENT 3 OPEN CMD 1B            V59K3251XL
                  #                 L FWD VENTS 1&2 OPEN CMD 1B        V59K3051XL
                  #                 R FWD VENTS 1&2 PURGE CMD 2B       V59K4111XL
                  #                 R FWD VENTS 1&2 PURGE CMD 2B       V59K4111XL
                  #   Channel  2: Discretes
                  #                 R PB VENT 6 OPEN CMD 1B            V59K4551XL
                  #                 L PB VENT 5 OPEN CMD 1B            V59K3451XL
                  #                 R PB VENT 3 CLOSE CMD 2B           V59K4211XL
                  #                 L PB VENT 6 CLOSE CMD 2B           V59K3511XL
                  #                 L PB VENT 5 CLOSE CMD 2B           V59K3411XL
                  #                 R PB VENT 3 CLOSE CMD 2B           V59K4211XL
                  #                 L PB VENT 6 CLOSE CMD 2B           V59K3511XL
                  #                 L PB VENT 5 CLOSE CMD 2B           V59K3411XL
                  #   JSC-12770 -->
                  #     left fwd vents 1&2 op/cl/purge cmd 1b
                  #     rcs fwd manf isol vlv 4 op
                  #     rcs fwd manf isol vlv 1 cl-a
                  #     rcs fwd ox tnk isol vlv 1/2 op a/cl b
                  #     rcs fwd tnk isol vlv 1/2 cl a
                  #     mps e3 status/amber lite on
                  #     rh event sequence a/b/c/d/e compter cont
                  #     dplr xtrtr - unit 2
                  #     rcs cmd r/p/y left/rt lamp b
                  #     rcs cmd pitch up/down b
                  #     aft dap auto (lite)/sel a (lite)
                  #     oms r eng actr sel stby 1/stby 2
                  #     aft dap man (lite)/sel b (lite)
                  #     aft rcs jets vernier (lite)/normal (lite)
                  #     rt plb/w vents 4&7 op/cl cmd 2b
                  #     left plb/w vents 4&7 op/cl cmd 1b
                  #     rt plb vent 6 op/cl/purge 1/purge 2 cmd 1b
                  #     left plb vent 5 op/cl cmd 1b
                  #   <-- JSC-12770
           'SIO', # Card 3
                  #   Channel 0: MSBLS 3
                  #                 IMU 3 KT70/HAINS GOOD      WD1B0   V71X4021B1
                  #                 IMU-3 TRANS WD1 FAIL               V71X4030B1
                  #                 IMU-3 TRANS WD2 FAIL               V71X4031B1
                  #   Channel 1: MTU 3
                  #         Read Opcode 2: READ 3 WORDS
                  #   JSC-12770 -->
                  #     imu 3 status, data
                  #     mtu chan 3 gmt/met, bite status, gmt/met update
                  #     ku-a ch 2 ant strg auto 2; a/b sel
                  #     -y star trkr status, data
                  #     ku-a ch 2 status, data
                  #   <-- JSC-12770
           'DIH', # Card 4
                  #   Channel  0: Discretes
                  #   Channel  1: Discretes
                  #   Channel  2: Discretes
                  #                 L FWD VENTS 1&2 CLOSED 1           V59X3005X1
                  #                 L PB VENT 3 CLOSED 1               V59X3205X1
                  #                 R PB VENT 6 CLOSED 1               V59X4505X1
                  #                 L PB VENT 5 CLOSED 1               V59X3405X1
                  #                 L FWD VENTS 1&2 PURGE IND 1        V59X3105X1
                  #   JSC-12770 -->
                  #     fcs mon chan 2 reset/override b
                  #     fcs chan 1 reset/override c
                  #     gpc uplink 2-stage block cmd b
                  #     rh body flap up/down a
                  #     mps me-3 shutdown cmd a
                  #     rjdf 2 trickle current continuity 4,5
                  #     rcs fwd fu manf isol vlv 4 op/cl
                  #     rcs fwd fu tank isol vlv 1/2 op/cl
                  #     rcs fwd fu manf isol vlv 5 op/cl
                  #     star trkr -z door op/cl 1
                  #     aft adi att sel inertial/lvlh/reference
                  #     aft adi rate scale high/medium/low
                  #     aft afi error scale high/medium/low
                  #     fcs lh pitch/roll-yaw auto/css mode c
                  #     lh speed brake/throt auto/man c
                  #     mps eng limit cntl #2 ena/inh/auto
                  #     rt plb/w vents 4&7 op/cl 2
                  #     left fwd vents 1&2 op/cl/purge ind 1
                  #     rt plb vent 6 op/cl/purge ind 4
                  #     left plb/w vents 4&7 op/cl 1
                  #     left plb vent 7 op/cl 1
                  #   <-- JSC-12770
           'DOL', # Card 5
                  #   Channel  0: Discretes
                  #   Channel  1:
                  #                  FLIGHT CONTROL CHANNEL FAILURE     V72X4550X1
                  #   JSC-12770 -->
                  #     rjdf 2 jet f4r/f4d/f5l/f5r cmd a
                  #     acel assy 3 bite
                  #     dplr xtrtr 2 start d time/test mode discretes
                  #     rcs fail/oms-tvc fail
                  #     oms left-ent/rt-eng abnormal
                  #     fcs channel fail
                  #     fcs saturation
                  #     imu/rh rhc/lh rhc/nav sensor/gyro accel fail
                  #     rt rcs/fwd rcs leak det
                  #   <-- JSC-12770
           'DIL', # Card 6
                  #   Channel  0: Discretes
                  #                 FWD THC POS X OUTPUT-C             V72K1355X1
                  #                 FWD THC NEG X OUTPUT-C             V72K1356X1
                  #                 FWD THC POS Y OUTPUT-C             V72K1360X1
                  #                 FWD THC NEG Y OUTPUT-C             V72K1361X1
                  #                 FWD THC POS Z OUTPUT-C             V72K1365X1
                  #                 FWD THC NEG Z OUTPUT-C             V72K1366X1
                  #   JSC-12770 -->
                  #     rjdf 2 jet f4r/f4d/f5l/f5r chmbr press ind
                  #     aft ddu pwr sply a/b/c good
                  #     fwd thc +/- x/y/z output-c
                  #     lh sbtc takeover-c
                  #   <-- JSC-12770
           'AIS', # Card 7
                  #   Channel  0: Fwd Atch Pt Cap Volts - B
                  #   Channel  1: Hydr Sys 3 Sup Press A
                  #   Channel 09:
                  #                 RCS FWD HE FU TANK PRESS-2         V42P1114C1
                  #   Channel 10:
                  #                 RCS FWD HE OX TANK TEMP-1          V42T1100C1
                  #   Channel 12:
                  #                 RCS FWD FU TANK ULLAGE PRESS       V42P1116C1
                  #   Channel 13:
                  #                 RCS FWD HE OX TANK PRESS-1         V42P1110C1
                  #   JSC-12770 -->
                  #     rcs fwd ox thrust inj temp - f4r/f4d/f5l/f5r
                  #     rcs fwd fu thrust inj temp - f4r/f4d/f5l/f5r
                  #     rcs fwd fu tank temp 1
                  #     rcs fwd he fu tank press 2
                  #     rcs fwd he ox tank temp 1/press 1
                  #     rcs fwd ox tank out press
                  #     rcs fwd fu tank ullage press
                  #     rcs fwd fu/ox manf press 3/4/5
                  #   <-- JSC-12770
           'AOD', # Card 8
                  #   Channel  0: MPS R ENG CHAMBER PRESS (meter/ADC)   V41P0042C
                  #   Channel  7: NOSE WHEEL STEERING 2A CMD (SPI block word 1)
                  #   Channel 14: ACCEL ASSY 3 NORM TEST STIM
                  #   Channel 15: ACCEL ASSY 3 LAT TEST STIM
                  #   JSC-12770 -->
                  #     mps e3 main chmbr - press/cmpt
                  #     rcs fwd/left-aft/rt-aft fu qty
                  #     rcs - rt aft lowest propellant qty
                  #     accel assy 3 norm/lat test stim
                  #   <-- JSC-12770
           'DIH', # Card 9
                  #   JSC-12770 -->
                  #     rjdf 2 jet f4r/f4d/f5r/f5l driver
                  #     aft dap sel a-a/b-a
                  #     fwd dap sel a-c/b-c
                  #     aft dap auto a/man a
                  #     fwd dap auto c/man c
                  #     fcs fwd loop gain pitch/roll-yaw high-c/low-c
                  #     mps me-2 shutdown cmd b
                  #     sense sw -z/-x con c
                  #     entry roll mode auto-c
                  #     aft rotation r/p/y disc rate/accel rate/pulse a
                  #     aft rcs jets norm a/vernier a
                  #     aft translation x/y/z pulse a/high a/norm a
                  #     mps lh2 feedline dump start a/stop a
                  #     rh air data probe deploy 1/stow 1
                  #     adta 3 pwr on cmd
                  #     imu 3 pwer on cmd b
                  #     msbls 3 pwr status
                  #     tacan 3 auto discrete
                  #   <-- JSC-12770
           'DOH', # Card 10
                  #   Channel  0: Discretes
                  #                 L PB VENT 3 OPEN CMD 1A            V59K3250XL
                  #                 L FWD VENTS 1&2 OPEN CMD 1A        V59K3050XL
                  #   Channel  2:
                  #                 R PB VENT 6 OPEN CMD 1A            V59K4550XL
                  #                 L PB VENT 5 OPEN CMD 1A            V59K3450XL
                  #                 L PB VENT 3 CLOSE CMD 2A           V59K3210XL
                  #                 R PB VENT 6 CLOSE CMD 2A           V59K4510XL
                  #                 R PB VENT 5 CLOSE CMD 1B           V59K4401XL
                  #                 L FWD VENTS 1&2 PURGE CMD 2A       V59K3110XL
                  #   JSC-12770 -->
                  #     left fwd vents 1&2 op/cl/purge cmd 1a
                  #     rh body flap auto
                  #     rh speedbrake auto
                  #     fcs mode - rh pitch/rh roll-yaw auto
                  #     rcs fwd fu tnk isol vlv 1/2 op a/cl b
                  #     rcs fwd manf isol vlv 5 op a
                  #     rcs fwd he press vlv b op/cl a
                  #     rcs fwd manf isol vlv 1 cl b
                  #     mps e3 status/red lite on
                  #     aft rotation r/p/y dscr/accel/pulse (lites)
                  #     aft translation x/y/z norm/pulse/high (lites)
                  #     sm bu c&w a cmd 3/tone a cmd 3/alert a cmd 3
                  #     rt plb/w vents 4&7 op/cl cmd 2a
                  #     left plb/w vents 4&7 op/cl cmd 1a
                  #     rt plb vent 6 op/cl/purge 1/purge 2 cmd 1a
                  #     left plb vent 5 op/cl cmd 1a
                  #   <-- JSC-12770
           'SIO', # Card 11
                  #   Channel  0: IMU 3
                  #   Channel  1: ADTA 3
                  #   JSC-12770 -->
                  #     adta 3 status, data
                  #     msbls 3 status, data
                  #     dplr xtrtr 2 status, data
                  #     nsp 2 status, data
                  #   <-- JSC-12770
           'DIH', # Card 12
                  #   Channel  0: Discretes
                  #   Channel  1: Discretes
                  #   JSC-12770 -->
                  #     fcs mon chan 4 reset/override b
                  #     rh +/- p/r/y trim a
                  #     rcs fwd ox manf isol vlv 4 op/cl
                  #     rcs fwd ox tank isol vlv 1/2 op/cl
                  #     rcs fwd ox manf isol vlv 5 op/cl
                  #     nlg no weight on wheels #1
                  #     nlg door unlocked
                  #     entry roll mode aileron c
                  #     fcs rate gain pitch/roll-yaw med/off c
                  #     -y star trkr pwr on cmd
                  #     rh rhc trim inh a
                  #     fcs rh pitch/roll-yaw auto/css mode b
                  #     rh body flap auto/man b
                  #     rh speed brake/throt auto/man b
                  #     rcs master xfeed from left-3/rt-3
                  #     aoa/ato/rtls abort request signal c
                  #     apt adi att ref plb-a/plb-b
                  #     rt plb vent 6 pruge 2 ind 1
                  #     rmg no weight on wheels
                  #     rmg uplocked
                  #     lmg door uplocked
                  #     star trkr -y dr op 2/cl 2
                  #     fwd rcs options norm c/vernier c
                  #   <-- JSC-12770
           'DOL', # Card 13
                  #   Channel  0: Discretes
                  #   JSC-12770 -->
                  #     rjdf 2 jet f4r/f4d/f5l/f5r cmd b
                  #     adta 3 high/low test mode cmd
                  #     imu 3 operate mode cmd
                  #   <-- JSC-12770
           'AID', # Card 14
                  #   Channel 00:
                  #                 RH RHC ROLL CMD-B                  V72K1220C1
                  #   Channel 01:
                  #                 RH RHC PITCH CMD-B                 V72K1221C1
                  #   Channel 02:
                  #                 RH RHC YAW CMD-B                   V72K1222C1
                  #   Channel 03:
                  #                 RIGHT RUDDER PEDAL CMD-B           V72K1541C1
                  # --> ALT
                  #   Channel  0: Norm Accel 3 signal
                  #   Channel  1: RH RHC CMD C yaw
                  #   Channel  2: Lat accel 3 signal
                  #   Channel  3: RH RPTA CMD C
                  #   Channel  5: RH SBTC CMD C
                  #   Channel  6: RH RHC CMD C roll
                  #   Channel  7: RH RHC CMD C Pitch
                  # <-- ALT
                  #   JSC-12770 -->
                  #     rh rhc roll/pitch/yaw cmd b
                  #     rt rudder pedal cmd b
                  #     rh sbtc cmd b
                  #     accel assy 3 norm/lat accel
                  #   <-- JSC-12770
           'DIL'  # Card 15
                  #   Channel  0: Discretes
                  #                 IMU 3 PLATFORM TEMP SAFE           V71X4405X1
                  #                 IMU 3 CAPRI TEMP SAFE              V71X4407X1
                  #                 IMU 3 PLATFORM TEMP READY          V71X4404X1
                  #                 IMU 3 CAPRI TEMP READY             V71X4406X1
                  #                 IMU 3 PRESSURE/COMMUNICATION GOOD  V71X4401X1
                  #   JSC-12770 -->
                  #     imu 3 status, data
                  #     aft ddu good
                  #     aft thc +/- x/y/z output c
                  #     rh sbtc takeover-b
                  #     rh rhc +/- pitch/roll trim a
                  #   <-- JSC-12770
    ]
  FF4:
    id: 'FF4'
    nom: 'Flight Forward 4'
    busPri: 'FC4'
    busSec: 'FC8'
    iua: 10
    #
    # RJDF 2A, F3 Jets
    #
    iom: [ 'TAC', # Card 0 (dummy output)
           'AID', # Card 1 (dummy input)
           'DOH', # Card 2
                  #   Channel 00:
                  #                 R PB VENT 3 OPEN CMD 2B            V59K4261XL
                  #                 R FWD VENTS 1&2 OPEN CMD 2B        V59K4061XL
                  #                 L FWD VENTS 1&2 PURGE CMD 2B       V59K3111XL
                  #   Channel 01:
                  #                 L PB VENT 5 CLOSE CMD 1A           V59K3400XL
                  #   Channel 02:
                  #                 L PB VENT 6 OPEN CMD 2B            V59K3561XL
                  #                 L PB VENT 5 OPEN CMD 2B            V59K3461XL
                  #                 L PB VENT 3 CLOSE CMD 2B           V59K3211XL
                  #                 R PB VENT 6 CLOSE CMD 2B           V59K4511XL
                  #   JSC-12770 -->
                  #     rt fwd vents 1&2 op/cl/purge cmd 2b
                  #     rcs fwd manf isol vlv 3 op
                  #     rcs fwd manf isol vlv 2 cl-a
                  #     oms - r eng actr sel active-1/active-2
                  #     rt plb vent 3 op/cl cmd 2b
                  #     rt plb/w vents 4&7 op/cl cmd 1b
                  #     left plb vent 6 op/cl/purge 1/purge 2 cmd 2b
                  #     left plb vent 5 op/cl cmd 2b
                  #   <-- JSC-12770
           'SIO', # Card 3 (dummy output)
           'DIH', # Card 4
                  #   Channel 02:
                  #                 R FWD VENTS 1&2 CLOSED 2           V59X4015X1
                  #                 R PB VENT 3 CLOSED 2               V59X4215X1
                  #                 L PB VENT 6 CLOSED 2               V59X3515X1
                  #                 L PB VENT 5 CLOSED 2               V59X3415X1
                  #                 R FWD VENTS 1&2 PURGE IND 2        V59X4115X1
                  #   JSC-12770 -->
                  #     fcs mon chan 3 reset/override a
                  #     fcs chan 2 reset/override c
                  #     rh body flap up/down b
                  #     mps me-3 shutdown cmd b
                  #     rjdf 2 trickle current continuity 3
                  #     rcs fwd fu manf isol vlv 3 op/cl
                  #     mps eng limit contorl #3 ena/inh/auto
                  #     rt plb vent 3 op/cl-2
                  #     rt fwd vents 1&2 op/cl/purge ind-2
                  #     left plb vent 6 op 2/cl 2/purge ind 2
                  #     rt plb/w vents 4&7 op/cl-1
                  #     left plb vent 5 op/cl-2
                  #   <-- JSC-12770
           'DOL', # Card 5
                  #   JSC-12770 -->
                  #     rjdf 2 jet f3f,f3l/f3u/f3d chamber press ind
                  #     accel assy 4 lat/norm bite
                  #     fwd event timer - lift-off start
                  #   <-- JSC-12770
           'DIL', # Card 6
                  #   JSC-12770 -->
                  #     rjdf 2 jet f3f/f3l/f3u/f3d cmd a
                  #     srb sep auto b cmd
                  #     srb sep man/auto ena b cmd
                  #     srb sep init b cmd
                  #   <-- JSC-12770
           'AIS', # Card 7
                  #   JSC-12770 -->
                  #     rcs fwd ox/fu thrust inj temp - f3f/f3l/f3u/f3d
                  #     rcs fwd ox/fu tank out press
                  #     rcs fwd fu tank temp 1
                  #   <-- JSC-12770
           'AOD', # Card 8
                  #   JSC-12770 -->
                  #     accel assy 4 norm/lat test stim
                  #   <-- JSC-12770
           'DIH', # Card 9
                  #   JSC-12770 -->
                  #     rjdf 2 jet f3f/f3l/f3u/f3d driver
                  #     aft dap sel a-b/b-b
                  #     aft dap auto/man b
                  #     entry roll mode auto d
                  #     aft rotation r/p/y disc rate b/accel b/pulse b
                  #     aft rcs jets norm b/vernier b
                  #     aft translation x/y/z norm b/pulse b/high b
                  #   <-- JSC-12770
           'DOH', # Card 10
                  #   Channel 00: Discretes
                  #                 PB VENT 3 OPEN CMD 2A            V59K4260XL
                  #                 FWD VENTS 1&2 OPEN CMD 2A        V59K4060XL
                  #   Channel 02:
                  #                 L PB VENT 6 OPEN CMD 2A            V59K3560XL
                  #                 L PB VENT 5 OPEN CMD 2A            V59K3460XL
                  #                 R PB VENT 3 CLOSE CMD 1B           V59K4201XL
                  #                 L PB VENT 6 CLOSE CMD 1B           V59K3501XL
                  #                 R PB VENT 5 CLOSE CMD 2B           V59K4411XL
                  #                 R FWD VENTS 1&2 PURGE CMD 1B       V59K4101XL
                  #   JSC-12770 -->
                  #     rt fwd vents 1&2 op/cl/purge cmd 2a
                  #     rh body flap man/speedbrake manual
                  #     fcs mode rh pitch/rool-yaw css
                  #     rcs fwd manf isol vlv-2 close b
                  #     sm bu c&w a cmd 4/tone a cmd 4/alerta a cmd 4
                  #     rt plb vent 3 op/cl cmd 2a
                  #     rt plb/w vents 4&7 op/cl cmd 1a
                  #     left plb vent 6 op/cl/purge 1/purge 2 cmd 2a
                  #     left plb vent 5 op/cl cmd 2a
                  #   <-- JSC-12770
           'SIO', # Card 11
                  #   Channel  1: ADTA 4
                  #   JSC-12770 -->
                  #     adta status/data
                  #   <-- JSC-12770
           'DIH', # Card 12
                  #   JSC-12770 -->
                  #     fcs mon chan 4 reset/override a
                  #    rh +/- p/r/y - trim b
                  #     rcs fwd ox manf isol vlv 3 op/cl
                  #     rh rhc trim inh b
                  #     fcs rh pitch/roll-yaw auto/css mode c
                  #     rh body flap auto/man c
                  #     rh speed brake/throt auto/man c
                  #     left plb vent 6 purge 2 ind 2
                  #     entry roll mode aileron d
                  #   <-- JSC-12770
           'DOL', # Card 13
                  #   Channel  0: Discretes
                  #   JSC-12770 -->
                  #     rjdf 2 jet f3f/f3l/f3u/f3d cmd b
                  #     adta 4 high/low test mode cmd
                  #   <-- JSC-12770
           'AID', # Card 14
                  #   Channel 00:
                  #                 RH RHC ROLL CMD-C                  V72K1235C1
                  #   Channel 01:
                  #                 RH RHC PITCH CMD-C                 V72K1236C1
                  #   Channel 02:
                  #                 RH RHC YAW CMD-C                   V72K1237C1
                  #   Channel 03:
                  #                 RIGHT RUDDER PEDAL CMD-C           V72K1542C1
                  #   JSC-12770 -->
                  #     rh rhc r, p, y cmd-c
                  #     rt rudder pedal cmd c
                  #     rh sbtc cmd-c
                  #     accel assy 4 lat/norm accel
                  #   <-- JSC-12770
           'DIL'  # Card 15
                  #   JSC-12770 -->
                  #     rhh sbtc takeover-c
                  #     rh rhc +/- pitch/roll trim-b
                  #     et sep man ena b/init b/auto b
                  #   <-- JSC-12770
        ]
  FA1:
    id: 'FA1'
    nom: 'Flight Aft 1'
    busPri: 'FC1'
    busSec: 'FC5'
    iua: 12
    #
    # L OMS PRI GIMBAL, RJDA 1B, L1 Jets, R1 Jets, L5 Jets
    #
    iom: [ 'AOD', # Card 0
                  #   Channel  1: ASA
                  #   JSC-12770 -->
                  #     lh tvc tilt actr cntrl a cmd
                  #     rh tvc rock actr cntrl a cmd
                  #     mps eng 2 y (p) actr a cmd
                  #     mps eng 1 p actr a cmd
                  #     left inbd (outbd) elevon (speed brake cmd 1, rudder cmd 1) cmd 1
                  #   <-- JSC-12770
           'AID', # Card 1
                  #   Channel  6:
                  #                 BODY FLAP POSN FDBK-1              V57H0065C1
                  # ----> ALT
                  #   Channel  0: Rudder Posn Fdbk - 1
                  #   Channel  1: Speed Brake Posn Fdbk - 1
                  #   Channel  2: Body Flap Posn Fdbk - 1
                  #   Channel  3: Rt Inbd Elevon Posn Fdbk - 1
                  #   Channel  5: Lt Indb Elevon Posn Fdbk - 1
                  #   Channel  6: Rt Outbd Elevon Posn Fdbk - 1
                  #   Channel  7: Lt Outbd Elevon Posn Fdbk - 1
                  # <---- ALT
                  #   JSC-12770 -->
                  #     left inbd (outbd) elevon posn fdbk-1
                  #     rt inbd (outbd) elevon posn fdbk-1
                  #     speed brake posn fdbk-1
                  #     rudder pson fdbk-1
                  #     body flap posn fdbk-1
                  #   <-- JSC-12770
           'DOL', # Card 2
                  #   Channel  0: Discretes
                  #   JSC-12770 -->
                  #     rjda 1 jet l1a (l1l,l1u,r1a,r1r,r1u,l5d,l5l) cmd a
                  #     mps eng 1 p actr a bypass (reset)
                  #     mps eng 2 p (y) actr a bypass (reset)
                  #     lh srb tilt actr a bypass (reset)
                  #     rh srb rock actr a bypass (reset)
                  #     left inbd (outbd) elevon actr 1 bypass (reset)
                  #     rt inbd (outbd) elevon acr 1 bypass (reset)
                  #     speed brake bypass (reset) 1
                  #     rudder bypass (reset) 1
                  #     body flap up (down) cmd 1
                  #   <-- JSC-12770
           'DIH', # Card 3
                  #   Channel  0:
                  #                 ET SEPARATION A                    V76X9111X1
                  #                 MPS LH2 17IN DISC VLV(PD2)OP IND A V41X1429X1
                  #                 ET-LH2 LOW LEVEL LIQ SENSOR NO 4   T41X1733X1
                  #                 MPS E1 LH2 PREVLV (PV4) OP IND A   V41X1104X1
                  #                 MPS LH2 TOPPING VLV (PV13) CL IND  V41X1456X1
                  #                 MPS ENG 1 P ACTR A FAIL            V79X1170X1
                  #                 MPS ENG 2 P ACTR A FAIL            V79X1270X1
                  #                 MPS ENG 3 P ACTR A FAIL            V79X1370X1
                  #   JSC-12770 -->
                  #     rt inbd (outbd) elevon actr 1 fail
                  #     rudder actr 1 fail
                  #     mps eng 1 (2,3) p actr a fail
                  #     lh srb tilt actr a fail
                  #     rd srb rock actr a fail
                  #     rjda 1 trickle current continuity 1,5l
                  #     et lh2 low level liq sensor no. 4
                  #     mps lh2 inbd fill vlv (replenish vlv) closed
                  #     mps e-1 lh2 prevlv open a
                  #     et sep a
                  #     lh srb sep ind b
                  #     oms pbk (left-pod) fu isol valve a posn op (cl)
                  #     oms - left pod vapor isol vlv 1 posn op
                  #     oms - left enf purge vlv 1 posn op
                  #     oms - left eng arm press (arm) cmd 2 op
                  #     oms - rt pod os xfeed (fu xfeed) vlv a posn op (cl)
                  #     et umb dr lch 1 lkd (stwd) ind 1
                  #     rcs rt aft fu (ox) manf isol vlv-1 (he ox/fu press vlv-a) op (cl)
                  #     rcs rt aft fu (ox) xfeed vlv-3/4/5 op (cl)
                  #   <-- JSC-12770
           'AOD', # Card 4
                  #   JSC-12770 -->
                  #     lh tvc rock actr cntrl a cmds
                  #     rh tvc tilt actr cntrl a cmds
                  #     mps eng 3 p (y) actr a cmds
                  #     mps eng 1 (y) actr a cmds
                  #     rt inbd (outbd) elevon cmd 1
                  #     oms - left eng actv p (y) actr cmds
                  #     rga 1 r (p,y) bite torque cmds
                  #   <-- JSC-12770
           'DIL', # Card 5
                  #   Channel  0: Discretes
                  #                 RGA 1 ROLL SRMD IND                V79X1860X1
                  #                 RGA 1 PITCH SMRD IND               V79X1861X1
                  #                 RGA 1 YAW SMRD IND                 V79X1862X1
                  #
                  #   JSC-12770 -->
                  #     rjda 1 jets (l1a,l1l,l1u,r1a,r1r,r1u,l5d,l5l) chmbr p ind
                  #     rga 1 r (p,y) smrd ind
                  #
                  #   <-- JSC-12770
           'AIS', # Card 6
                  #   Channel 08:
                  #                 RCS L AFT HE FU TANK TEMP-1        V42T2104C1
                  #   Channel 09:
                  #                 RCS L AFT HE FU TANK PRESS-1       V42P2113C1
                  #   Channel 11:
                  #                 RCS L AFT OX TANK ULLAGE PRESS     V42P2115C1
                  #   Channel 12:
                  #                 RCS L AFT HE OX TANK PRESS-2       V42P2112C1
                  #   Channel 17:
                  #                 OMS-L POD HE TANK PRESS 1          V43P4121C1
                  #   Channel 19:
                  #                 OMS-L POD HE TANK TEMP-UPPER       V43T4111C1
                  #   Channel 27:
                  #                 ET-LH2 ULLAGE PRESS NO 1           T41P1700C1
                  #   Channel 28:
                  #                 ET-LO2 ULLAGE PRESSURE NO.1        T41P1750C1
                  #   Channel 30:
                  #                 LH PRESS A SRM CHAMBER             B47P1300C1
                  #   Channel 31:
                  #                 LH VOLTAGE IGN PIC CAP A           B55V1603C1
                  #   JSC-12770 -->
                  #     rcs rt aft fu thrust inj temp-(r1a,r1r,r1u,l5l)
                  #     rcs r aft ox thruyst ink temp-(r1a,r1r,r1u,l5l)
                  #     rcs left aft he fu tank temp (press)-1
                  #     rcs left aft ox tank temp-1 (ullage press)
                  #     rcs left aft he ox tank press-2 (fu tank out press)
                  #     oms left pod fu tank ullage press (he tank press, temp-upper)
                  #     oms left eng ox inlet press (pneu supply press 2, reg out press)
                  #     oms rt pod ox tank ullage press
                  #     oms pbk he tank press-2
                  #     oms pbk ox (fu) aft comparetment qty
                  #     et lh2 (lo2) ullate press no. 1
                  #     hyd sys 1 supply press a
                  #     lh srm chmbr press-a (voltage ign pic cap a)
                  #   <-- JSC-12770
           'DOH', # Card 7
                  #   Channel 00:
                  #                 MPS E1 LO2 PREVLV (PV1) CL CMD B   V41K1140XL
                  #                 MPS E1 LO2 PREVLV (PV1) OP CMD B   V41K1137XL
                  #                 MPS E1 LH2 PREVLV (PV4) CL CMD B   V41K1123XL
                  #                 MPS E1 LH2 PREVLV (PV4) OP CMD B   V41K1120XL
                  #                 L AFT VENTS 8&9 OPEN CMD 1A        V59K3850XL
                  #                 L AFT VENTS 8&9 PURGE CMD 2A       V59K3910XL
                  #                 L AFT VENTS 8&9 PURGE CMD 2A       V59K3910XL
                  #                 REPLACE LH2 ULL PRESS XDCR 1 CMD   V41K1700XL
                  #   JSC-12770 -->
                  #     et umb dr cl lch 1 stow (lock) cmd 1a
                  #     et launch-umb cl/out dr cl (lch) cmd 1a
                  #     left aft vents 8&9 cl (op, purge) cmd 1a
                  #     mps e-1 lo2 (lh2) prevlv op (cl) cmd b
                  #     replace lh2 ullage press no 1 xdcr
                  #     mps e-1 mainstage cmd a
                  #     mps lh2 replenish vlv op cmd
                  #     mps lh2 manf repress no 1 op cmd
                  #     oms rt eng cntrl vlv 1 coil 2 op
                  #     oms left pod vapor isol vlv 1 op
                  #     oms left pod fu (ox) isol vlv a cmd 2 op (cl)
                  #     oms left/rt pod fu (ox) xfeed vlv a cmd 2 op (cl)
                  #     rcs left aft xfeed vlv-3/4/5 gpc gl (op) a
                  #     rcs left aft fu (ox) tank a isol vlv 1/2 gpc cl (op) b
                  #     rcs left aft manf isol vlv-1 (5) gpc op a
                  #     rcs left aft manf isol vlv-3 gpc cl a (b)
                  #     rcs left aft he press vlv-a gpc op (cl) a
                  #   <-- JSC-12770
           'DIH', # Card 8
                  #   JSC-12770 -->
                  #     rjda 1 jet driver (l1a,l1l,l1u,r1a,r1r,r1u,l5d,l5l)
                  #     et launch umb cl/out dr op (cl,ltchd,ltch rel ind)-1
                  #     et launch umb cl/out dr rdy-to-ltch ind 1 (2,3)
                  #   <-- JSC-12770
           'AID', # Card 9
                  #   Channel 00:
                  #                 L INBD ELEVON PRI DELTA PRESS 1    V58P0816C1
                  #   Channel 01:
                  #                 L OUTBD ELEVON PRI DELTA PRESS 1   V58P0866C1
                  #   Channel 02:
                  #                 R INBD ELEVON PRI DELTA PRESS 1    V58P0916C1
                  #   Channel 03:
                  #                 R OUTBD ELEVON PRI DELTA PRESS 1   V58P0966C1
                  #   JSC-12770 -->
                  #     left inbd (outbd) pri delta press 1
                  #     rt inbd (outbd) pri delta press 1
                  #     rga 1 r (p,y) rate
                  #     lh rga p (y) rate a
                  #     rh rga p (y) rate a
                  #   <-- JSC-12770
           'DOL', # Card 10
                  #   Channel  0: Discretes
                  #   JSC-12770 -->
                  #     rjda 1 jet l1a (l1l,l1v,r1a,r1r,r1u,l5d,l5l) cmd b
                  #     mps eng 1 y actr a bypass (reset)
                  #     mps eng 3 y (p) actr a bypass (reset)
                  #     rh tilt srb actr a bypass (reset)
                  #     rh rock srb actr a bypass (reset)
                  #     body flap ena cmd 1
                  #   <-- JSC-12770
           'DIH', # Card 11
                  #   Channel 00: Discretes
                  #                 MPS LO2 RIGHT ECO SENSOR 1         V41X1558X1
                  #                 MPS E1 LO2 PREVLV (PV1) OP IND     V41X1134X1
                  #                 L AFT VENTS 8&9 CLOSED 1           V59X3805X1
                  #                 L AFT VENTS 8&9 OPEN 1             V59X3855X1
                  #                 L AFT VENTS 8&9 PURGE IND 1        V59X3905X1
                  #                 MPS ENG 1 Y ACTR A FAIL            V79X1171X1
                  #                 MPS ENG 2 Y ACTR A FAIL            V79X1271X1
                  #                 MPS ENG 3 Y ACTR A FAIL            V79X1371X1
                  #   Channel 01:
                  #                 MPS LH2 17IN(PD2)LATCH LCKED IND A V41X1991X1
                  #                 MPS LO2 17IN DISC VLV(PD1)OP IND B V41X1545X1
                  #                 MPS LO2 17IN(PD1)LATCH LCKED IND A V41X1891X1
                  #
                  #
                  #   JSC-12770 -->
                  #
                  #
                  #
                  #   <-- JSC-12770
           'DOH', # Card 12
                  #   Channel 00:
                  #                 MPS LO2 POGO RECRC 1(PV20)CL CMD A V41K1815XL
                  #                 MPS E3 LO2 PREVLV (PV3) CL CMD C   V41K1341XL
                  #                 MPS E3 LO2 PREVLV (PV3) OP CMD C   V41K1338XL
                  #                 MPS E3 LH2 PREVLV (PV6) CL CMD C   V41K1324XL
                  #                 MPS E3 LH2 PREVLV (PV6) OP CMD C   V41K1321XL
                  #                 MPS LO2 POGO RECRC 1(PV20)CL CMD A V41K1815XL
                  #                 MPS E3 LH2 PREVLV (PV6) CL CMD C   V41K1324XL
                  #
                  #   JSC-12770 -->
                  #
                  #
                  #
                  #   <-- JSC-12770
           'DIL', # Card 13 (UNUSED)
           'AIS', # Card 14
                  #   Channel 08:
                  #                 RCS L AFT HE OX TANK TEMP-1        V42T2100C1
                  #   Channel 09:
                  #                 RCS L AFT HE OX TANK PRESS-1       V42P2110C1
                  #   Channel 11:
                  #                 RCS L AFT FU TANK ULLAGE PRESS     V42P2116C1
                  #   Channel 12:
                  #                 RCS L AFT HE FU TANK PRESS-2       V42P2114C1
                  #   Channel 16:
                  #                 MPS E1 LH2 INLET PRESS             V41P1100C1
                  #   Channel 19:
                  #                 MPS E1 LO2 INLET TEMP              V41T1131C1
                  #   Channel 20:
                  #                 MPS E1 HE SUPPLY BOTTLE PRESS      V41P1150C1
                  #   Channel 30:
                  #                 RH PRESS A SRM CHAMBER             B47P2300C1
                  #   Channel 31:
                  #                 RH VOLTAGE IGN PIC CAP A           B55V2603C1
                  # ----> ALT
                  #   Channel  0: LH Atch Pt Cap Volts - 1A
                  #   Channel  1: RH Atch Pt Cap Volts - 1A
                  #   Channel  2: Hydr Sys 1 Supply Press B
                  #   Channel  3: LH Atch Pt Cap Volts-2A
                  #   Channel  4: RH Atch Pt Cap Volts-2A
                  #   Channel  5: LH Atch Pt Cap Volts-3A
                  #   Channel  6: RH Atch Pt Cap Volts-3A
                  #   Channel 20: Gyro 1 Pitch Rate
                  #   Channel 21: Gyro 1 Roll Rate
                  #   Channel 23: Gyro 1 Yaw Rate
                  # <---- ALT
                  #   JSC-12770 -->
                  #     rcs left aft fu (ox) thrust inj temp-l1a (l1l,l1u,l5d)
                  #     rcs left aft he ox tank temp (press)-1
                  #     rcs left aft fu tank temp-1 (ullage press)
                  #     rcs left aft aft he fu tank presss-2
                  #     rcs left aft ox tnk out press
                  #     oms left eng actv p (y) actr posn in
                  #     mps eng 1 lh2 inlet press (temp)
                  #     mps eng 1 lo2 inlet press (temp)
                  #     mps eng 1 he sply (reg outlet) press
                  #     mps lh2 eng manf press
                  #     hyd sys 1 sply press b
                  #     rcs left aft ox manf press-1
                  #     rh srm chmbr press a
                  #     rh ign pic cap a voltage
                  #   <-- JSC-12770
           'DOH', # Card 15
                  #   Channel 00:
                  #                 MPS E2 LO2 PREVLV (PV2) CL CMD A   V41K1239XL
                  #                 MPS E2 LO2 PREVLV (PV2) OP CMD A   V41K1236XL
                  #                 MPS E2 LH2 PREVLV (PV5) CL CMD A   V41K1222XL
                  #                 MPS E2 LH2 PREVLV (PV5) OP CMD A   V41K1219XL
                  #                 L AFT VENTS 8&9 OPEN CMD 1B        V59K3851XL
                  #                 R AFT VENTS 8&9 PURGE CMD 1A       V59K4900XL
                  #   JSC-12770 -->
                  #     et umb dr cl lch 1 stow (lk) cmd 1b
                  #     et launc umb cl/out dr lch cmd 1b
                  #     left aft vents 8&9 cl (op, purge) cmd 1b
                  #     mps lo2 fdln rlf s/o vlv cl cmd b
                  #     mps e-2 lo2 prevlv op (cl) cmd a
                  #     mps e-2 lh2 prevlv op (cl) cmd a
                  #     mps lh2 inbd fill vlv op (cl) cmd b
                  #     lh2 rtls manf repress 2 op cmd
                  #     mps e-2 emer sht dn inh cmd b
                  #     oms left eng cntrl vlv 1 coil 2 op
                  #     oms left pod he isol vlv a op
                  #     oms left pod tk vlvs b cmd 1 op (cl)
                  #     et/orb sep cameras - htr on cmd
                  #     oms left pod xfeed vlvs b cmd op (cl)
                  #     oms rt pod xfeed vlvs b cmd op (cl)
                  #     rcs rt aft ox xfeed v-3/4/5 gpc op (cl) b
                  #     rcs rt aft fu xfeed v-3/4/5 gpc op (cl) b
                  #     rcs rt aft tk isol v-1/2 gpc op (cl) a
                  #     rcs rt aft manf isol vlv-1 gpc op
                  #     rcs rt aft mnaf isol v-3 (-5) gpc cl a
                  #     rcs left aft manf isol v-3 gpc cl b
                  #     rcs rt aft he press vlv-a gpc cl (op) a
                  #   <-- JSC-12770
           ]
  FA2:
    id: 'FA2'
    nom: 'Flight Aft 2'
    busPri: 'FC2'
    busSec: 'FC6'
    iua: 12
    #
    # L OMS SEC GIMBAL, RJDA 2B, L3 Jets, R3 Jets, R5 Jets
    #
    iom: [ 'AOD', # Card 0
                  #   Channel  1: ASA
           'AID', # Card 1
                  #   Channel 06:
                  #                 BODY FLAP POSN FDBK-2              V57H0066C1
                  #
                  # ----> ALT
                  #   Channel  0: Rudder Posn Fdbk - 2
                  #   Channel  1: Speed Brake Posn Fdbk - 2
                  #   Channel  2: Body Flap Posn Fdbk - 2
                  #   Channel  3: Rt Inbd Elevon Posn Fdbk - 2
                  #   Channel  5: Lt Indb Elevon Posn Fdbk - 2
                  #   Channel  6: Rt Outbd Elevon Posn Fdbk - 2
                  #   Channel  7: Lt Outbd Elevon Posn Fdbk - 2
                  # <---- ALT
           'DOL', # Card 2
                  #   Channel  0: Discretes
           'DIH', # Card 3
                  #   Channel 00:
                  #                 ET SEPARATION B                    V76X9112X1
                  #                 MPS LH2 17IN DISC VLV(PD2)CL IND A V41X1430X1
                  #                 ET-LH2 LOW LEVEL LIQ SENSOR NO 2   T41X1731X1
                  #                 MPS E2 LH2 PREVLV (PV5) OP IND A   V41X1204X1
                  #                 MPS LH2 OTBD F/D VLV (PV11) CL IND V41X1389X1
                  #                 MPS LH2 OTBD F/D VLV (PV11) CL IND V41X1389X1
                  #                 MPS ENG 1 P ACTR B FAIL            V79X1173X1
                  #                 MPS ENG 2 P ACTR B FAIL            V79X1273X1
                  #                 MPS ENG 3 P ACTR B FAIL            V79X1373X1
                  #
           'AOD', # Card 4
           'DIL', # Card 5
                  #   Channel  0: Discretes
                  #                 RGA 2 ROLL SMRD IND                V79X1865X1
                  #                 RGA 2 PITCH SMRD IND               V79X1866X1
                  #                 RGA 2 YAW SMRD IND                 V79X1867X1
           'AIS', # Card 6
                  #   Channel 08:
                  #                 RCS R AFT HE FU TANK TEMP-1        V42T3104C1
                  #   Channel 09:
                  #                 RCS R AFT HE FU TANK PRESS-1       V42P3113C1
                  #   Channel 11:
                  #                 RCS R AFT OX TANK ULLAGE PRESS     V42P3115C1
                  #   Channel 12:
                  #                 RCS R AFT HE OX TANK PRESS-2       V42P3112C1
                  #   Channel 17:
                  #                 OMS-R POD HE TANK PRESS 1          V43P5121C1
                  #   Channel 19:
                  #                 OMS-R POD HE TANK TEMP-UPPER       V43T5111C1
                  #   Channel 27:
                  #                 ET-LH2 ULLAGE PRESS NO 2           T41P1701C1
                  #   Channel 28:
                  #                 ET-LO2 ULLAGE PRESSURE NO.2        T41P1751C1
                  #   Channel 30:
                  #                 LH PRESS B SRM CHAMBER             B47P1301C1
                  #   Channel 31:
                  #                 LH VOLTAGE IGN PIC CAP B           B55V1604C1
           'DOH', # Card 7
                  #   Channel 00:
                  #                 MPS E1 LO2 PREVLV (PV1) CL CMD C   V41K1141XL
                  #                 MPS E1 LO2 PREVLV (PV1) OP CMD C   V41K1138XL
                  #                 MPS E1 LH2 PREVLV (PV4) CL CMD C   V41K1124XL
                  #                 MPS E1 LH2 PREVLV (PV4) OP CMD C   V41K1121XL
                  #                 R AFT VENTS 8&9 OPEN CMD 2A        V59K4860XL
                  #                 L AFT VENTS 8&9 PURGE CMD 1A       V59K3900XL
                  #                 L AFT VENTS 8&9 PURGE CMD 1A       V59K3900XL
                  #                 MPS E1 LH2 PREVLV (PV4) CL CMD C   V41K1124XL
                  #                 REPLACE LH2 ULL PRESS XDCR 2 CMD   V41K1701XL
                  #
                  #
                  #
           'DIH', # Card 8
           'AID', # Card 9
                  #   Channel 00:
                  #                 L INBD ELEVON PRI DELTA PRESS 2    V58P0817C1
                  #   Channel 01:
                  #                 L OUTBD ELEVON PRI DELTA PRESS 2   V58P0867C1
                  #   Channel 02:
                  #                 R INBD ELEVON PRI DELTA PRESS 2    V58P0917C1
                  #   Channel 03:
                  #                 R OUTBD ELEVON PRI DELTA PRESS 2   V58P0967C1
           'DOL', # Card 10
                  #   Channel  0: Discretes
           'DIH', # Card 11
                  #   Channel  0: Discretes
                  #                 MPS LO2 17IN DISC VLV(PD1)CL IND A V41X1530X1
                  #                 MPS LO2 LEFT ECO SENSOR 2          V41X1556X1
                  #                 MPS E2 LO2 PREVLV (PV2) OP IND     V41X1234X1
                  #                 MPS LO2 OVBD B/V (PV19) CL IND B   V41X1581X1
                  #                 R AFT VENTS 8&9 CLOSED 2           V59X4815X1
                  #                 R AFT VENTS 8&9 OPEN 2             V59X4865X1
                  #                 R AFT VENTS 8&9 PURGE IND 2        V59X4915X1
                  #                 MPS ENG 1 Y ACTR B FAIL            V79X1174X1
                  #                 MPS ENG 2 Y ACTR B FAIL            V79X1274X1
                  #                 MPS ENG 3 Y ACTR B FAIL            V79X1374X1
                  #
                  #
                  #   Channel 01:
                  #                 LH2 17IN(PD2)LATCH LCKED IND B V41X1992X1
                  #                 17IN(PD1)LATCH LCKED IND B V41X1892X1
                  #
           'DOH', # Card 12
                  #   Channel 00:
                  #                 MPS LH2 OTBD F/D VLV (PV11) CL CMD V41K1393XL
                  #                 MPS LH2 OTBD F/D VLV (PV11) OP CMD V41K1391XL
                  #                 MPS LO2 OVBD B/V (PV19) CL CMD C   V41K1586XL
                  #                 MPS LO2 POGO RECRC 2(PV21)CL CMD A V41K1825XL
                  #                 MPS E3 LO2 PREVLV (PV3) CL CMD A   V41K1339XL
                  #                 MPS E3 LO2 PREVLV (PV3) OP CMD A   V41K1336XL
                  #                 MPS E3 LH2 PREVLV (PV6) CL CMD A   V41K1322XL
                  #                 MPS E3 LH2 PREVLV (PV6) OP CMD A   V41K1319XL
                  #                 MPS LO2 POGO RECRC 2(PV21)CL CMD A V41K1825XL
                  #                 MPS E3 LH2 PREVLV (PV6) CL CMD A   V41K1322XL
                  #
           'DIL', # Card 13 (UNUSED)
           'AIS', # Card 14
                  #   Channel 08:
                  #                 RCS R AFT HE OX TANK TEMP-1        V42T3100C1
                  #   Channel 09:
                  #                 RCS R AFT HE OX TANK PRESS-1       V42P3110C1
                  #   Channel 11:
                  #                 RCS R AFT FU TANK ULLAGE PRESS     V42P3116C1
                  #   Channel 12:
                  #                 RCS R AFT HE FU TANK PRESS-2       V42P3114C1
                  #   Channel 16:
                  #                 MPS E2 LH2 INLET PRESS             V41P1200C1
                  #   Channel 19:
                  #                 MPS E2 LO2 INLET TEMP              V41T1231C1
                  #   Channel 20:
                  #                 MPS E2 HE SUPPLY BOTTLE PRESS      V41P1250C1
                  #   Channel 28:
                  #                 HYDR SYS 3 SUPPLY PRESS C          V58P0316C1
                  #   Channel 30:
                  #                 RH PRESS B SRM CHAMBER             B47P2301C1
                  #   Channel 31:
                  #                 RH VOLTAGE IGN PIC CAP B           B55V2604C1
                  # ----> ALT
                  #   Channel  0: LH Atch Pt Cap Volts - 1B
                  #   Channel  1: RH Atch Pt Cap Volts - 1B
                  #   Channel  2: Hydr Sys 2 Supply Press B
                  #   Channel  3: LH Atch Pt Cap Volts-2B
                  #   Channel  4: RH Atch Pt Cap Volts-2B
                  #   Channel  5: LH Atch Pt Cap Volts-3B
                  #   Channel  6: RH Atch Pt Cap Volts-3B
                  #   Channel 20: Gyro 2 Pitch Rate
                  #   Channel 21: Gyro 2 Roll Rate
                  #   Channel 23: Gyro 2 Yaw Rate
                  # <---- ALT
           'DOH', # Card 15
                  #   Channel  0:
                  #                 MPS E2 LO2 PREVLV (PV2) CL CMD B   V41K1240XL
                  #                 MPS E2 LO2 PREVLV (PV2) OP CMD B   V41K1237XL
                  #                 MPS E2 LH2 PREVLV (PV5) CL CMD B   V41K1223XL
                  #                 MPS E2 LH2 PREVLV (PV5) OP CMD B   V41K1220XL
                  #                 R AFT VENTS 8&9 OPEN CMD 2B        V59K4861XL
                  #                 R AFT VENTS 8&9 PURGE CMD 1B       V59K4901XL
                  #                 R AFT VENTS 8&9 PURGE CMD 1B       V59K4901XL
           ]

  FA3:
    id: 'FA3'
    nom: 'Flight Aft 3'
    busPri: 'FC3'
    busSec: 'FC7'
    iua: 12
    #
    # R OMS SEC GMBL, RJDA 1A, L2 Jets, R2 Jets
    #
    iom: [ 'AOD', # Card 0
                  #   Channel  1: ASA
           'AID', # Card 1
                  #  Channel 06:
                  #                 BODY FLAP POSN FDBK-3              V57H0067C1
                  # --> ALT
                  #   Channel  0: Rudder Posn Fdbk - 3
                  #   Channel  1: Speed Brake Posn Fdbk - 3
                  #   Channel  2: Body Flap Posn Fdbk - 3
                  #   Channel  3: Rt Inbd Elevon Posn Fdbk - 3
                  #   Channel  5: Lt Indb Elevon Posn Fdbk - 3
                  #   Channel  6: Rt Outbd Elevon Posn Fdbk - 3
                  #   Channel  7: Lt Outbd Elevon Posn Fdbk - 3
                  # <-- ALT
           'DOL', # Card 2
                  #   Channel  0: Discretes
           'DIH', # Card 3
                  #   Channel 00:
                  #                 ET SEPARATION C                    V76X9113X1
                  #                 MPS LH2 RTLS OTBD DV (PV18) CL IND V41X1919X1
                  #                 ET-LH2 LOW LEVEL LIQ SENSOR NO 1   T41X1730X1
                  #                 MPS E1 LH2 PREVLV (PV4) OP IND B   V41X1106X1
                  #                 MPS ENG 1 P ACTR C FAIL            V79X1176X1
                  #                 MPS ENG 2 P ACTR C FAIL            V79X1276X1
                  #                 MPS ENG 3 P ACTR C FAIL            V79X1376X1
           'AOD', # Card 4
           'DIL', # Card 5
                  #   Channel  0: Discretes
                  #                 RGA 3 ROLL SMRD IND                V79X1870X1
                  #                 RGA 3 PITCH SMRD IND               V79X1871X1
                  #                 RGA 3 YAW SMRD IND                 V79X1872X1
           'AIS', # Card 6
                  #   Channel 17:
                  #                 OMS-L POD HE TANK PRESS 2          V43P4122C1
                  #   Channel 27:
                  #                 ET-LH2 ULLAGE PRESS NO 3           T41P1702C1
                  #   Channel 28:
                  #                 ET-LO2 ULLAGE PRESSURE NO.3        T41P1752C1
                  #   Channel 30:
                  #                 LH PRESS C SRM CHAMBER             B47P1302C1
           'DOH', # Card 7
                  #    Channel 00:
                  #                 MPS E1 LO2 PREVLV (PV1) CL CMD A   V41K1139XL
                  #                 MPS E1 LO2 PREVLV (PV1) OP CMD A   V41K1136XL
                  #                 MPS E1 LH2 PREVLV (PV4) CL CMD A   V41K1122XL
                  #                 MPS E1 LH2 PREVLV (PV4) OP CMD A   V41K1119XL
                  #                 R AFT VENTS 8&9 OPEN CMD 1A        V59K4850XL
                  #                 R AFT VENTS 8&9 PURGE CMD 2A       V59K4910XL
                  #                 R AFT VENTS 8&9 PURGE CMD 2A       V59K4910XL
                  #                 MPS E1 LH2 PREVLV (PV4) CL CMD A   V41K1122XL
                  #                 REPLACE LH2 ULL PRESS XDCR 3 CMD   V41K1702XL
                  #    Channel 01:
                  #                 MPS E3 LO2 PREVLV (PV3) CL CMD D   V41K1342XL
                  #                 MPS E3 LO2 PREVLV (PV3) OP CMD D   V41K1343XL
           'DIH', # Card 8
                  #    Channel 00:
                  #                 MPS E3 LH2 PREVLV (PV6) OP IND B   V41X1306X1
                  #                 MPS LO2 POGO RECRC 1 (PV20) OP IND V41X1811X1
           'AID', # Card 9
                  #   Channel 00:
                  #                 L INBD ELEVON PRI DELTA PRESS 3    V58P0818C1
                  #   Channel 01:
                  #                 L OUTBD ELEVON PRI DELTA PRESS 3   V58P0868C1
                  #   Channel 02:
                  #                 R INBD ELEVON PRI DELTA PRESS 3    V58P0918C1
                  #   Channel 03:
                  #                 R OUTBD ELEVON PRI DELTA PRESS 3   V58P0968C1
           'DOL', # Card 10
                  #   Channel  0: Discretes
           'DIH', # Card 11
                  #   Channel 00:
                  #                 MPS LO2 17IN DISC VLV(PD1)CL IND B V41X1534X1
                  #                 MPS LO2 LEFT ECO SENSOR 1          V41X1555X1
                  #                 MPS LO2 OVBD B/V (PV19) CL IND A   V41X1580X1
                  #                 R AFT VENTS 8&9 CLOSED 1           V59X4805X1
                  #                 MPS LO2 OTBD F/D VLV (PV9) CL IND  V41X1514X1
                  #                 R AFT VENTS 8&9 OPEN 1             V59X4855X1
                  #                 R AFT VENTS 8&9 PURGE IND 1        V59X4905X1
                  #                 MPS ENG 1 Y ACTR C FAIL            V79X1177X1
                  #                 MPS ENG 2 Y ACTR C FAIL            V79X1277X1
                  #                 MPS ENG 3 Y ACTR C FAIL            V79X1377X1
                  #   Channel 01:
                  #                 MPS LH2 17IN DISC VLV(PD2)OP IND B V41X1445X1
                  #                 MPS LH2 17IN(PD2)LTCH UNLCKD IND A V41X1993X1
                  #                 MPS LO2 17IN(PD1)LTCH UNLCKD IND A V41X1893X1
           'DOH', # Card 12
                  #   Channel 00:
                  #                 LO2 OVBD B/V (PV19) CL CMD A   V41K1584XL
                  #                 LO2 POGO RECRC 1(PV20)CL CMD B V41K1816XL
           'DIL', # Card 13 (UNUSED)
           'AIS', # Card 14
                  #   Channel  0: Fill
                  #   Channel  1: Fill
                  #   Channel  2: Hydr Sys 3 Supply Press B
                  #   Channel 16:
                  #                 MPS E3 LH2 INLET PRESS             V41P1300C1
                  #   Channel 19:
                  #                 MPS E3 LO2 INLET TEMP              V41T1331C1
                  #   Channel 20:
                  #                 MPS E3 HE SUPPLY BOTTLE PRESS      V41P1350C1
                  #   Channel 23:
                  #                 HYDR SYS 2 SUPPLY PRESS C          V58P0216C1
                  #   Channel 30:
                  #                 RH PRESS C SRM CHAMBER             B47P2302C1
                  # --> ALT
                  #   Channel 20: Gyro 3 Pitch Rate
                  #   Channel 21: Gyro 3 Roll Rate
                  #   Channel 23: Gyro 3 Yaw Rate
                  # <-- ALT
           'DOH', # Card 15
           ]

  FA4:
    id: 'FA4'
    nom: 'Flight Aft 4'
    busPri: 'FC4'
    busSec: 'FC8'
    iua: 12
    #
    # R OMS PRI GMBL, RJDA 2A, L4 Jets, R4 Jets
    #
    iom: [ 'AOD', # Card 0
                  #   Channel  1: ASA
           'AID', # Card 1
                  #   Channel 06:
                  #                 BODY FLAP POSN FDBK-4              V57H0068C1
                  # --> ALT
                  #   Channel  0: Rudder Posn Fdbk - 4
                  #   Channel  1: Speed Brake Posn Fdbk - 4
                  #   Channel  2: Body Flap Posn Fdbk - 4
                  #   Channel  3: Rt Inbd Elevon Posn Fdbk - 4
                  #   Channel  5: Lt Indb Elevon Posn Fdbk - 4
                  #   Channel  6: Rt Outbd Elevon Posn Fdbk - 4
                  #   Channel  7: Lt Outbd Elevon Posn Fdbk - 4
                  # <-- ALT
           'DOL', # Card 2
                  #   Channel  0: Discretes
           'DIH', # Card 3
                  #   Channel 00:
                  #                 ET SEPARATION D                    V76X9114X1
                  #                 MPS LH2 17IN DISC VLV(PD2)CL IND B V41X1434X1
                  #                 MPS LO2 17IN DISC VLV(PD1)OP IND A V41X1529X1
                  #                 MPS LH2 RTLS INBD DV (PV17) CL IND V41X1929X1
                  #                 ET-LH2 LOW LEVEL LIQ SENSOR NO 3   T41X1732X1
                  #                 MPS E2 LH2 PREVLV (PV5) OP IND B   V41X1206X1
                  #                 MPS ENG 1 P ACTR D FAIL            V79X1178X1
                  #                 MPS ENG 2 P ACTR D FAIL            V79X1278X1
                  #                 MPS ENG 3 P ACTR D FAIL            V79X1378X1
           'AOD', # Card 4
           'DIL', # Card 5
                  #   Channel 00:
                  #                 RGA 4 ROLL SMRD IND                V79X1875X1
                  #                 RGA 4 PITCH SMRD IND               V79X1876X1
                  #                 RGA 4 YAW SMRD IND                 V79X1877X1
           'AIS', # Card 6
                  #   Channel 17:
                  #                 OMS-R POD HE TANK PRESS 2          V43P5122C1
                  #   Channel 29:
                  #                 HYDR SYS 1 SUPPLY PRESS C          V58P0116C1
           'DOH', # Card 7
                  #   Channel 00:
                  #                 V76K6941X L SRB BUS C RPC A ON CMD
                  #                 MPS LH2 4IN DISC VLV (PD3) CL CMD  V41K1422XL
                  #                 MPS LH2 4IN DISC VLV (PD3) OP CMD  V41K1421XL
                  #                 L AFT VENTS 8&9 OPEN CMD 2A        V59K3860XL
                  #                 R AFT VENTS 8&9 PURGE CMD 2B       V59K4911XL
                  #                 R AFT VENTS 8&9 PURGE CMD 2B       V59K4911XL
                  #   Channel 01:
                  #                 MPS E1 LO2 PREVLV (PV1) CL CMD D   V41K1142XL
                  #                 MPS E1 LO2 PREVLV (PV1) OP CMD D   V41K1143XL
                  #                 MPS E2 LO2 PREVLV (PV2) CL CMD D   V41K1242XL
                  #                 MPS E2 LO2 PREVLV (PV2) OP CMD D   V41K1243XL
           'DIH', # Card 8
                  #   Channel 00:
                  #                 MPS E3 LH2 PREVLV (PV6) OP IND A   V41X1304X1
                  #                 MPS LO2 POGO RECRC 2 (PV21) OP IND V41X1821X1
           'AID', # Card 9
                  #   Channel 00:
                  #                 L INBD ELEVON PRI DELTA PRESS 4    V58P0819C1
                  #   Channel 01:
                  #                 L OUTBD ELEVON PRI DELTA PRESS 4   V58P0869C1
                  #   Channel 02:
                  #                 R INBD ELEVON PRI DELTA PRESS 4    V58P0919C1
                  #   Channel 03:
                  #                 R OUTBD ELEVON PRI DELTA PRESS 4   V58P0969C1
           'DOL', # Card 10
           'DIH', # Card 11
                  #   Channel  0: Discretes
                  #                 MPS LO2 RIGHT ECO SENSOR 2         V41X1557X1
                  #                 MPS E3 LO2 PREVLV (PV3) OP IND     V41X1334X1
                  #                 L AFT VENTS 8&9 CLOSED 2           V59X3815X1
                  #                 L AFT VENTS 8&9 OPEN 2             V59X3865X1
                  #                 L AFT VENTS 8&9 PURGE IND 2        V59X3915X1
                  #                 MPS ENG 3 Y ACTR D FAIL            V79X1379X1
                  #                 MPS ENG 1 Y ACTR D FAIL            V79X1179X1
                  #                 MPS ENG 2 Y ACTR D FAIL            V79X1279X1
                  #   Channel 01:
                  #                 MPS LH2 17IN(PD2)LTCH UNLCKD IND B V41X1994X1
                  #                 MPS LO2 17IN(PD1)LTCH UNLCKD IND B V41X1894X1
           'DOH', # Card 12
                  #   Channel 00:
                  #                 V76K6942X R SRB BUS C RPC A ON CMD
                  #                 MPS LO2 OVBD B/V (PV19) CL CMD B   V41K1585XL
                  #                 MPS LO2 POGO RECRC 2(PV21)CL CMD B V41K1826XL
                  #                 MPS E3 LO2 PREVLV (PV3) CL CMD B   V41K1340XL
                  #                 MPS E3 LO2 PREVLV (PV3) OP CMD B   V41K1337XL
                  #                 MPS E3 LH2 PREVLV (PV6) CL CMD B   V41K1323XL
                  #                 MPS E3 LH2 PREVLV (PV6) OP CMD B   V41K1320XL
                  #                 MPS LO2 POGO RECRC 2(PV21)CL CMD B V41K1826XL
                  #                 MPS E3 LH2 PREVLV (PV6) CL CMD B   V41K1323XL
           'DIL', # Card 13 (UNUSED)
           'AIS', # Card 14
           'DOH', # Card 15
                  #   Channel 00:
                  #                 MPS LO2 OTBD F/D VLV (PV9) CL CMD  V41K1515XL
                  #                 MPS LO2 OTBD F/D VLV (PV9) OP CMD  V41K1518XL
                  #                 MPS E2 LH2 PREVLV (PV5) CL CMD C   V41K1224XL
                  #                 MPS E2 LH2 PREVLV (PV5) OP CMD C   V41K1221XL
                  #                 L AFT VENTS 8&9 OPEN CMD 2B        V59K3861XL
                  #                 L AFT VENTS 8&9 PURGE CMD 1B       V59K3901XL
                  #                 L AFT VENTS 8&9 PURGE CMD 1B       V59K3901XL
                  #                 MPS E2 LH2 PREVLV (PV5) CL CMD C   V41K1224XL
           ]

  LF1:
    id: 'LF1'
    nom: 'Launch Forward 1'
    busPri: 'LB1'
    busSec: 'LB2'
    iua: 10
    iom: [ 'DOH', # Card 0
           'DIL', # Card 1 (UNUSED)
           'DOH', # Card 2
           'AIS', # Card 3 (UNUSED)
           'AOD', # Card 4
           'DOH', # Card 5
                  #   Channel  0:
                  #                 PRSD O2 GAS SUPPLY VLV-CLOSE       V45K1196NL
           'DIH', # Card 6
           'DOL', # Card 7
           'DOL', # Card 8
           'DOH', # Card 9
                  #   Channel  1:
                  #                 FWD LCA 1 FIRE 2 INHIBIT CMD       V76K6302NL
                  #                 FWD LCA 2 FIRE 2 INHIBIT CMD       V76K6304NL
                  #                 FWD LCA 3 FIRE 2 INHIBIT CMD       V76K6306NL
           'DIH', # Card 10
           'DOH', # Card 11
                  #   Channel  1:
                  #                 FWD LCA 1 FIRE 1 INHIBIT CMD       V76K6301NL
                  #                 FWD LCA 2 FIRE 1 INHIBIT CMD       V76K6303NL
                  #                 FWD LCA 3 FIRE 1 INHIBIT CMD       V76K6305NL
                  #                 PCM MASTER 2 PWR ON B              V75K2110NL
                  #                 PCM MASTER 1 PWR ON C              V75K2108NL
                  #
           'AID', # Card 12 (UNUSED)
           'DIH', # Card 13 (UNUSED)
           'DOH', # Card 14
                  #   Channel  0:
                  #                 PRSD H2 GAS SUPPLY VLV-CLOSE       V45K2196NL
                  #   Channel  1:
                  #                 PCM MASTER 2 PWR ON A              V75K2109NL
                  #                 PCM MASTER 1 PWR ON A              V75K2107NL
           'DIL'  # Card 15 (UNUSED)
    ]
  LA1:
    id: 'LA1'
    nom: 'Launch Aft 1'
    busPri: 'LB1'
    busSec: 'LB2'
    iua: 10
    iom: [ 'DOH', # Card 0
           'DIL', # Card 1 (UNUSED)
           'DOH', # Card 2
                  #   Channel 01:
                  #                 LH2 REC VLVS(PV14,15,16)OP CMD V41K1111NL
           'AIS', # Card 3 (UNUSED)
           'AOD', # Card 4
           'DOH', # Card 5
                  #   Channel 01:
                  #                 LO2 OTBD F/D VLV (PV9) OP CMD  V41K1518NL
           'DIH', # Card 6 (UNUSED)
           'DOL', # Card 7 (UNUSED)
           'DOL', # Card 8 (UNUSED)
           'DOH', # Card 9
           'DIH', # Card 10 (UNUSED)
           'DOH', # Card 11
                  #   Channel 01:
                  #                 LH2 OTBD F/D VLV (PV11) OP CMD V41K1391NL
                  #   Channel 02:
                  #                 LH2 HI PT BL VLV(PV22)OP CMD A V41K1465NL
           'AID', # Card 12 (UNUSED)
           'DIH', # Card 13 (UNUSED)
           'DOH', # Card 14
                  #   Channel 02:
                  #                 LH2 HI PT BL VLV(PV22)OP CMD B V41K1466NL
           'DIL'  # Card 15 (UNUSED)
    ]
  PF1:
    id: 'PF1'
    nom: 'Payload Forward 1'
    busPri: 'PL1'
    busSec: 'PL2'
    iua: 10
    iom: [ 'DOL', # Card 0
                  #   JSC-12770 -->
                  #     rcdr pl pri bits 1-16
                  #     pl system activation 33-56
                  #   <-- JSC-12770
           'AID', # Card 1
                  #   JSC-12770 -->
                  #     pl caution/warning 13-25
                  #   <-- JSC-12770
           'DOH', # Card 2
                  #   Discretes
                  #   JSC-12770 -->
                  #     plbd rt op/cl cmd a
                  #     plbd rt fwd bhd lch rel/lch cmd 1
                  #     plbd rt aft bhd lch rel/lch cmd 2
                  #     plbd operation enable cmd 1a/cmd 3a/cmd 4a
                  #     flash evap cntrl pri b on (gpc)
                  #     nh3 blr cntrl pri a/b on - gpc cmd b
                  #     sm bu c&w b/tone b/alert b - cmd 1
                  #     abort advisory a
                  #     s-band fm ant sel 1 - lower/upper
                  #     s-band quad ant sel 1 - upper left/upper rt/lower left/lower rt
                  #     pl safing cmd 19-30
                  #   <-- JSC-12770
           'DIH', # Card 3
                  #   JSC-12770 -->
                  #     plbd rt fwd/aft bhd rdy for lch 1
                  #     plbd rt fwd bhd lch rel 1/lch 1
                  #     plbd rt aft bhd lch rel 2/lch 2
                  #     plbd rt op 1/cl 1
                  #     plbd op/cl cmd c
                  #   <-- JSC-12770
           'AID', # Card 4 (dummy input)
           'DIL', # Card 5
                  #   JSC-12770 -->
                  #     pl caution and warning 36-50
                  #     pl system monitor 25-32
                  #   <-- JSC-12770
           'DIH', # Card 6
                  #   JSC-12770 -->
                  #     plbd left fwd/aft bhd rdy for lch-4
                  #     plbd left fwd/aft bhd lch rel-1/lch-1
                  #     plbd left op 2/cl 2
                  #     plbd op/cl cmd b
                  #     plbd left 88 deg op 2
                  #     plbd rt 88 deg op 1
                  #     ku band radar - on
                  #   <-- JSC-12770
           'DOH', # Card 7
                  #   Channel 01: V45K0815Y FCP 1 PURGE VLVS GPC-A OPEN
                  #   Channel 01: V45K0816Y FCP 1 PURGE VLVS GPC-B OPEN
                  #   JSC-12770 -->
                  #     plbd op/cl ind 1
                  #     plbd centerline lch 1-4/5-8/9-12 lch/rel cmd 1
                  #     plbd centerline lch 13-16 lch/rel cmd 2
                  #     h2o loop 1 pump a/b cont on - gpc cmd
                  #     silts on/of
                  #     fcp 1 purge vlvs gpc a/b op
                  #     gcil decoder a sel bit a9
                  #     gcil uplink parallel cmd but a0-a8
                  #   <-- JSC-12770
           'SIO', # Card 8
                  #   JSC-12770 -->
                  #     ku-a chan 1 status/data
                  #   <-- JSC-12770
           'DIH', # Card 9
                  #   JSC-12770 -->
                  #     plbd left fwd/aft bhd rdy for lch 2
                  #     plbd centerline lch 1-4/5-8/9-12 lch 1/rel 1
                  #     plbd centerline lch 13-16 lch 2/rel 2
                  #   <-- JSC-12770
           'DOL', # Card 10
                  #   Discretes
                  #   JSC-12770 -->
                  #     rcdr ops 1 pri bits 1-16
                  #     pl system activation 57-64
                  #   <-- JSC-12770
           'AID', # Card 11
                  #   JSC-12770 -->
                  #     pl system monitor 56-64
                  #   <-- JSC-12770
           'AID', # Card 12 (UNUSED)
           'DIL', # Card 13
                  #   JSC-12770 -->
                  #     pl system monitor 33-48
                  #   <-- JSC-12770
           'DOH', # Card 14
                  #   Channel 01: V45K0825Y FCP 2 PURGE VLVS GPC-A OPEN
                  #   Channel 01: V45K0826Y FCP 2 PURGE VLVS GPC-B OPEN
                  #   JSC-12770 -->
                  #     plbd left op/cl cmd b
                  #     plbd left fwd/aft bhd lch rel/lch cmd 1
                  #     plbd operation ena cmd 1b/3b/4b
                  #     hydr sys 1/sys 2/sys 3 pump on a
                  #     fcl 2 pump b on
                  #     fcp 2 purge vlvs gpc-a/gpc-b op
                  #     pl safing cmd 31-36
                  #   <-- JSC-12770
           'SIO'  # Card 15 (UNUSED)
                  #   JSC-12770 -->
                  #     pl gn&c update - serial i/o
                  #     pl sensor serial i/o
                  #   <-- JSC-12770

    ]
  PF2:
    id: 'PF2'
    nom: 'Payload Forward 2'
    busPri: 'PL1'
    busSec: 'PL2'
    iua: 12
    iom: [ 'DOL', # Card 0
           'AID', # Card 1
           'DOH', # Card 2
                  #   Discretes
           'DIH', # Card 3
           'AID', # Card 4 (dummy input)
           'DIL', # Card 5
           'DIH', # Card 6
           'DOH', # Card 7
                  #   Channel 01: V45K0835Y FCP 3 PURGE VLVS GPC-A OPEN
                  #   Channel 01: V45K0836Y FCP 3 PURGE VLVS GPC-B OPEN
           'SIO', # Card 8
           'DIH', # Card 9
           'DOL', # Card 10
                  #   Discretes
           'AID', # Card 11
           'AOD', # Card 12
                  #   The SM writes six words here from channel 0; the
                  #   channels are the ADC 2 wiring of JSC-18819,Rev.F SCP
                  #   4.9 item 8 in its order.
                  #   Channel  0: APU 1 FUEL QUANTITY (meter/ADC)      V72Q6001V
                  #   Channel  1: APU 1 H2O QUANTITY                    V72Q6040V
                  #   Channel  2: APU 2 FUEL QUANTITY                   V72Q6002V
                  #   Channel  3: APU 2 H2O QUANTITY                    V72Q6042V
                  #   Channel  4: APU 3 H2O QUANTITY                    V72Q6044V
                  #   Channel  5: APU 3 FUEL QUANTITY                   V72Q6003V
           'DIL', # Card 13
           'DOH', # Card 14
                  #   Channel 01: V45K0604Y FCP O2/H2 PURGE HTRS GPC-A ON
                  #   Channel 01: V45K0605Y FCP O2/H2 PURGE HTRS GPC-B ON
           'SIO'  # Card 15 (UNUSED)
    ]
  LL1:
    id: 'LL1'
    nom: 'SRB MDM LL01'
    busPri: 'LB1'
    busSec: 'LB2'
    iua: 9
    srb: true
    iom: [ 'DOL', # Card 0
                  #   Channel  0:       Set: B72M3000P  Reset: B72M3001P
                  #        Bit  0:  RATE GYRO A POWER ON CMD           B79K3003X J10-26
                  #        Bit  1:  RATE GYRO A PITCH POS TORQUE CMD   B79K3028X J10-15
                  #        Bit  2:  RATE GYRO A PITCH NEG TORQUE CMD   B79K3029X J10-17
                  #        Bit  3:  RATE GYRO A YAW POS TORQUE CMD     B79K3034X J10-10
                  #        Bit  4:  RATE GYRO A YAW NEG TORQUE CMD     B79K3035X J10-19
                  #        Bit  5:  RSS S+A DEVICE ARM CMD             B55K3044X J10-30
                  #        Bit  6:  ET RSS POWER A ON CMD              T55K3101X J10-8
                  #        Bit  7:  ET RSS POWER A OFF CMD             T55K3102X J10-25
                  #        Bit  8:  ET RSS S+A DVC SAFE 1 CMD          T55K3111X J10-18
                  #        Bit  9:  ET RSS S+A DVC SAFE 2 CMD          T55K3112X J10-1
                  #        Bit 10:  ET RSS S+A DVC ARM CMD             T55K3110X J10-9
                  #        Bit 11:  IGN A F2 TEST PWR ON CMD           B55K3047X J10-11
                  #        Bit 12:
                  #        Bit 13:
                  #        Bit 14:
                  #        Bit 15:  MDM LOCK VERIF TEST DISCRETE CMD   B75K3065X J10-27
                  #
                  #   Channel  1:       Set: B72M3010P  Reset: B72M3011P
                  #        Bit  0:  RATE GYRO C PITCH POS TORQUE CMD   B79K3032X J8-117
                  #        Bit  1:  RATE GYRO C PITCH NEG TORQUE CMD   B79K3033X J8-115
                  #        Bit  2:  RATE GYRO C YAW POS TORQUE CMD     B79K3038X J8-98
                  #        Bit  3:  RATE GYRO C YAW NEG TORQUE CMD     B79K3039X J8-110
                  #        Bit  4:  IGN S+A DEVICE ARM CMD             B55K3000X J8-100
                  #        Bit  5:  IGN S+A DEVICE SAFE CMD 1 CMD      B55K3001X J8-105
                  #        Bit  6:  IGN S+A DEVICE SAFE CMD 2 CMD      B55K3002X J8-122
                  #        Bit  7:  FWD PIC A RTST ON CMD              B55K3008X J8-106
                  #        Bit  8:  FDM AUTO CALIBRATION CMD           B78K5002X J8-97
                  #        Bit  9:  SRM CHAMBER PRESS A SIM CMD        B47K3005X J8-107
                  #        Bit 10:  SRM CHAMBER PRESS C SIM CMD        B47K3007X J8-116
                  #        Bit 11:  RANGE SAFETY POWER A ON CMD        B55K3042X J8-109
                  #        Bit 12:  DFI SYSTEM POWER ON CMD            B78K5000X J8-104
                  #        Bit 13:  DFI SYSTEM POWER OFF CMD           B78K5001X J8-114
                  #        Bit 14:  FLT RCDR RECORD INHIBIT CMD        B78K5003X J8-103
                  #        Bit 15:  FLT RCDR REVERSE CMD               B78K5004X J8-124
                  #
                  #   Channel 2:       Set: B72M3020P  Reset: B72M3021P
                  #                 SPARE
           'DIL', # Card 1
                  #   Channel  0:                                      B72M1200P
                  #        Bit  0:  EV RATE GYRO A PITCH SMRD          B79X1844X  J10-60
                  #        Bit  1:  EV RATE GYRO A YAW SMRD            B79X1847X  J10-48
                  #        Bit  2:  EV IGN PIC A RTST OK               B55X1806X  J10-50
                  #        Bit  3:  EV FWD THRUST PIN PIC A RTST OK    B55X1808X  J10-52
                  #        Bit  4:  EV FWD SEPN MOTOR PIC A RTST OK    B55X1816X  J10-64
                  #        Bit  5:  EV IGN PIC A LOAD TEST OK          B55X1824X  J10-38
                  #        Bit  6:  EV FWD THRUST PIN PIC A L/T OK     B55X1826X  J10-36
                  #        Bit  7:  EV FWD SEPN MOTOR PIC A L/T OK     B55X1834X  J10-59
                  #        Bit  8:  EV RSS PIC A RTST OK               B55X1873X  J10-63
                  #        Bit  9:  EV RSS PIC A LOAD TEST OK          B55X1875X  J10-39
                  #        Bit 10:  EV RSS A INHIBIT                   B55X1881X  J10-51
                  #        Bit 11:  EV EVENT RSS PIC A RTST OK         T55X1883X  J10-53
                  #        Bit 12:  EV EVENT RSS PIC A LOAD TEST OK    T55X1884X  J10-42
                  #        Bit 13:  EV EVENT RSS A INHIBIT INDICATOR   T55X1885X  J10-54
                  #        Bit 14:  EV EVENT RSS S+A DVC SAFED         T55X1869X  J10-49
                  #        Bit 15:  EV EVENT RSS S+A DVC ARMED         T55X1870X  J10-61
                  #   Channel  1:                                      B72M1201P
                  #        Bit  0:  EVENT RG C PITCH SMRD              B79X1846X  J8-72
                  #        Bit  1:  EVENT RG C YAW SMRD                B79X1849X  J8-82
                  #        Bit  2:  EVENT RG C PITCH POS TORQUE CMD    B79X1891X  J8-74
                  #        Bit  3:  EVENT RG C YAW POS TORQUE CMD      B79X1894X  J8-88
                  #        Bit  4:  EVENT RG A PITCH NEG TORQUE CMD    B79X1895X  J8-76
                  #        Bit  5:  EVENT RG C PITCH NEG TORQUE CMD    B79X1897X  J8-95
                  #        Bit  6:  EVENT RG A YAW NEG TORQUE CMD      B79X1898X  J8-94
                  #        Bit  7:  EVENT RG C YAW NEG TORQUE CMD      B79X1900X  J8-96
                  #        Bit  8:  EVENT RG A PITCH POS TORQUE CMD    B79X1889X  J8-73
                  #        Bit  9:  EVENT RG A YAW POS TORQUE CMD      B79X1892X  J8-85
                  #        Bit 10:
                  #        Bit 11:
                  #        Bit 12:
                  #        Bit 13:
                  #        Bit 14:
                  #        Bit 15:
                  #
                  #   Channel  2:                                      B72M1202P
                  #        Bit  0:  EV PCM MULTIPLEXER 1 OK            B78X7889X
                  #        Bit  1:  EV PCM MULTIPLEXER 2 OK            B78X7890X
                  #        Bit  2:  EV TIME CODE GENERATOR OK          B78X7914X
                  #        Bit  3:  EV FDM 1 MUX 1A OUT TO TRK 5 OK    B78X7916X
                  #        Bit  4:  EV FDM 1 MUX 1B OUT TO TRK 2 OK    B78X7917X
                  #        Bit  5:  EV FDM 1 MUXR 1 OUT TO ORB RCDR OK B78X7918X
                  #        Bit  6:  EV FDM 1 MUX 2A OUT TO TRK 7 OK    B78X7919X
                  #        Bit  7:  EV FDM 1 MUX 2B OUT TO TRK 4 OK    B78X7920X
                  #        Bit  8:  EV FDM 2 MUX 1A OUT TO TRK 9 OK    B78X7921X
                  #        Bit  9:  EV FDM 2 MUX 1B OUT TO TRK 10 OK   B78X7922X
                  #        Bit 10:  EV FDM 2 MUX 2A OUT TO TRK 11 OK   B78X7923X
                  #        Bit 11:  EV FDM 2 MUX 2B OUT TO TRK 12 OK   B78X7924X
                  #        Bit 12:
                  #        Bit 13:
                  #        Bit 14:
                  #        Bit 15:
                  #
           'DIH', # Card 2
                  #   Channel  0:                                      B72M1300P
                  #        Bit  0: EVENT IGN S+A DEVICE ARMED          B55X1842X J10-94
                  #        Bit  1: EVENT IGN S+A DEVICE SAFED          B55X1843X J10-96
                  #        Bit  2: EVENT RSS S+A DEVICE SAFED          B55X1869X J10-72
                  #        Bit  3: EVENT RSS S+A DEVICE ARMED          B55X1870X J10-88
                  #        Bit  4: EVENT SRM CHAMBER PRESS A SIM CMD   B47X1901X J10-74
                  #        Bit  5: EVENT SRM CHAMBER PRESS C SIM CMD   B47X1903X J10-86
                  #        Bit  6:
                  #        Bit  7: EVENT IGN A F2 TEST PWR ON CMD      B55X1916X J10-82
                  #        Bit  8:
                  #        Bit  9:
                  #        Bit 10:
                  #        Bit 11:
                  #        Bit 12:
                  #        Bit 13:
                  #        Bit 14:
                  #        Bit 15:
                  #
                  #   Channel  1:                                      B72M1301P
                  #        Bit  0: EV RSS ARM LTCH SW A OUTPUT         B55X1865X J8-50
                  #        Bit  1: EV RSS PIC A FIRED                  B55X1867X J8-59
                  #        Bit  2: EV RSS DECODER A ON/CHK TONE OFF    B55X1871X J8-64
                  #        Bit  3: EV RSS ARM CMD FROM DCDR A          B55X1877X J8-52
                  #        Bit  4: EV RSS FIRE CMD FROM DCDR A         B55X1879X J8-40
                  #        Bit  5:
                  #        Bit  6:
                  #        Bit  7:
                  #        Bit  8:
                  #        Bit  9:
                  #        Bit 10:
                  #        Bit 11:
                  #        Bit 12:
                  #        Bit 13:
                  #        Bit 14:
                  #        Bit 15:
                  #
                  #   Channel  2:                                      B72M1302P
                  #        Bit  0: ET EVENT RSS PIC A FIRED            T55X1867X J10-70
                  #        Bit  1:
                  #        Bit  2:
                  #        Bit  3:
                  #        Bit  4:
                  #        Bit  5:
                  #        Bit  6:
                  #        Bit  7:
                  #        Bit  8:
                  #        Bit  9:
                  #        Bit 10:
                  #        Bit 11:
                  #        Bit 12:
                  #        Bit 13:
                  #        Bit 14:
                  #        Bit 15:

           'AID', # Card 3
                  #   Channel  0:   POWER, RSS RCVR SIG STRENGTH A     B55E1100C J10-126/125
                  #   Channel  1:   VOLTAGE, FWD THRUST PIN PIC CAP A  B55V1605C J10-119/118
                  #   Channel  2:   VOLTAGE, FWD SEPN MOTOR PIC CAP A  B55V1613C J10-127/120
                  #   Channel  3:   SPARE
                  #   Channel  4:   VOLTAGE, RSS BATTERY 1             B55V1625C J10-102/101
                  #   Channel  5:   VOLTAGE, OPERATIONAL BUS A         B55V1600C J10-128/121
                  #   Channel  6:   CURRENT, RSS BATTERY 1             B55C1051C J10-114/113
                  #   Channel  7:   VOLTAGE, RSS PIC CAP A             B55V1623C J10-104/103
                  #   Channel  8:
                  #   Channel  9:
                  #   Channel 10:
                  #   Channel 11:
                  #   Channel 12:
                  #   Channel 13:   SPARE                                        J8-6/5
                  #   Channel 14:   SPARE                                        J8-24/23
                  #   Channel 15:   SPARE                                        J8-14/7
                  #   Channel 16:   SPARE                                        J10-122/115
                  #   Channel 17:   SPARE                                        J10-106/105
                  #   Channel 18:   SPARE                                        J10-124/123
                  #   Channel 19:   SPARE                                        J10-117/116
                  #   Channel 20:
                  #   Channel 21:
                  #   Channel 22:
                  #   Channel 23:
                  #   Channel 24:
                  #   Channel 25:
                  #   Channel 26:
                  #   Channel 27:
                  #   Channel 28:
                  #   Channel 29:
                  #   Channel 30:
                  #   Channel 31:
                  #                 LF FWD MDM PS SEP1 SW SNSR VOLTS   B75V1630CL
                  #
                  #
           'DOL', # Card 4
                  #   Channel  0:          Set: B72M3100P  Reset: B72M3101P
                  #        Bit  0:  RATE GYRO B POWER ON CMD           B79K3004X J5-26
                  #        Bit  1:  RATE GYRO B PITCH POS TORQUE CMD   B79K3030X J5-15
                  #        Bit  2:  RATE GYRO B PITCH NEG TORQUE CMD   B79K3031X J5-17
                  #        Bit  3:  RATE GYRO B YAW POS TORQUE CMD     B79K3036X J5-10
                  #        Bit  4:  RATE GYRO B YAW NEG TORQUE CMD     B79K3037X J5-19
                  #        Bit  5:  RECOVERY SYSTEM RESET CMD          B52K3015X J5-30
                  #        Bit  6:
                  #        Bit  7:
                  #        Bit  8:
                  #        Bit  9:
                  #        Bit 10:
                  #        Bit 11:  IGN B F2 TEST PWR ON CMD           B55K3048X J5-11
                  #        Bit 12:
                  #        Bit 13:
                  #        Bit 14:
                  #        Bit 15:  MDM LOCK VERIF TEST DISCRETE CMD   B75K3066X J5-27
                  #
                  #
                  #   Channel  1:          Set: B72M3110P  Reset: B72M3111P
                  #        Bit  0:
                  #        Bit  1:
                  #        Bit  2:
                  #        Bit  3:
                  #        Bit  4:  FWD PIC B RTST ON CMD              B55K3010X J9-100
                  #        Bit  5:  WATER IMPATCT SW SIMULATE CMD      B52K3014X J9-105
                  #        Bit  6:  BARO SW LOW ALT SIM CMD            B52K3013X J9-122
                  #        Bit  7:
                  #        Bit  8:  BARO SW HIGH ALT SIMULATE CMD      B52K3012X J9-97
                  #        Bit  9:  RANGE SAFETY POWER B ON CMD        B55K3043X J9-107
                  #        Bit 10:  SRM CHAMBER PRESS B SIM CMD        B47K3006X J9-116
                  #        Bit 11:
                  #        Bit 12:
                  #        Bit 13:
                  #        Bit 14:
                  #        Bit 15:
                  #
                  #                 LH IGNITION S&A DEVICE,SAFE CMD 1  B55K3001XL
                  #
                  #   Channel 2:           Set: B72M3120P  Reset: B72M3121P
                  #                 SPARE
                  #
           'DIL', # Card 5
                  #   Channel  0:                                      B72M1210P
                  #        Bit  0: EVENT RATE GYRO B PITCH SMRD        B79X1845X J5-60
                  #        Bit  1: EVENT RATE GYRO B YAW SMRD          B79X1848X J5-48
                  #        Bit  2: EVENT IGN PIC B RTST OK             B55X1807X J5-50
                  #        Bit  3: EVENT FWD THRUST PIN PIC R RTST OK  B55X1809X J5-52
                  #        Bit  4: EVENT FWD SEPN MOTOR PIC B RTST OK  B55X1817X J5-64
                  #        Bit  5: EVENT IGN PIC B LOAD TEST OK        B55X1825X J5-38
                  #        Bit  6: EVENT FWD THRUST PIN PIC B L/T OK   B55X1827X J5-36
                  #        Bit  7: EVENT FWD SEPN MOTOR PIC B L/T OK   B55X1835X J5-59
                  #        Bit  8:
                  #        Bit  9:
                  #        Bit 10: EVENT NOSE CAP RELEASE PIC RTST OK  B55X1820X J5-51
                  #        Bit 11: EVENT NOSE CAP RELEASE PIC L/T OK   B55X1838X J5-53
                  #        Bit 12: EVENT FRUSTUM RELEASE PIC RTST OK   B55X1821X J5-42
                  #        Bit 13: EVENT FRUSTUM RELEASE PIC L/T OK    B55X1839X J5-54
                  #        Bit 14: EVENT MAIN CHUTE DISC PIC RTST OK   B55X1823X J5-49
                  #        Bit 15: EVENT MAIN CHUTE DISC PIC L/T OK    B55X1841X J5-61
                  #
                  #   Channel  1:                                      B72M1211P
                  #        Bit  0: EVENT RSS PIC B RTST OK             B55X1874X J9-72
                  #        Bit  1: EVENT RSS PIC B LOAD TEST OK        B55X1876X J9-82
                  #        Bit  2: EVENT RSS RSS B INHIBIT             B55X1882X J9-74
                  #        Bit  3:
                  #        Bit  4:
                  #        Bit  5:
                  #        Bit  6:
                  #        Bit  7:
                  #        Bit  8:
                  #        Bit  9:
                  #        Bit 10:
                  #        Bit 11:
                  #        Bit 12:
                  #        Bit 13:
                  #        Bit 14:
                  #        Bit 15:
                  #
                  #   Channel  2:                                      B72M1212P
                  #        Bit  0: EVENT RG B PITCH POS TORQUE CMD     B79X1890X J5-47
                  #        Bit  1: EVENT RG B YAW POS TORQUE CMD       B79X1893X J5-58
                  #        Bit  2: EVENT RG B PITCH NEG TORQUE CMD     B79X1896X J5-44
                  #        Bit  3: EVENT RG B YAW NEG TORQUE CMD       B79X1899X J5-34
                  #        Bit  4: EVENT RECOVERY SYSTEM RESET CMD     B52X1907X J5-33
                  #        Bit  5: EVENT WATER IMPACT SW SIM CMD       B52X1906X J5-45
                  #        Bit  6:
                  #        Bit  7:
                  #        Bit  8:
                  #        Bit  9:
                  #        Bit 10:
                  #        Bit 11:
                  #        Bit 12:
                  #        Bit 13:
                  #        Bit 14:
                  #        Bit 15:
                  #
           'DIH', # Card 6
                  #   Channel  0:                                      B72M1310P
                  #        Bit  0: EV RSS ARM LTCH SW B OUTPUT         B55X1866X J5-94
                  #        Bit  1: EV RSS PIC B FIRED                  B55X1868X J5-96
                  #        Bit  2: EV RSS DECODER B ON/CHK TONE OFF    B55X1872X J5-72
                  #        Bit  3: EV RSS ARM CMD FROM DCDR B          B55X1878X J5-88
                  #        Bit  4: EV RSS FIRE CMD FROM DCDR B         B55X1880X J5-74
                  #        Bit  5: EV BARO SW HIGH ALT SIM CMD         B52X1904X J5-86
                  #        Bit  6: EV BARO SW LOW ALT SIM CMD          B52X1905X J5-95
                  #        Bit  7: EV MAIN CHUTE DISC PIC FIRE CMD     B52X1938X J5-82
                  #        Bit  8:
                  #        Bit  9:
                  #        Bit 10:
                  #        Bit 11:
                  #        Bit 12:
                  #        Bit 13:
                  #        Bit 14:
                  #        Bit 15:
                  #
                  #   Channel  1:                                      B72M1311P
                  #        Bit  0: EVENT SRM CHAMBER PRESS B SIM CMD   B47X1902X J9-50
                  #        Bit  1: EVENT IGN B F2 TEST PWR ON CMD      B55X1917X J9-64
                  #        Bit  2:
                  #        Bit  3:
                  #        Bit  4:
                  #        Bit  5:
                  #        Bit  6:
                  #        Bit  7:
                  #        Bit  8:
                  #        Bit  9:
                  #        Bit 10:
                  #        Bit 11:
                  #        Bit 12:
                  #        Bit 13:
                  #        Bit 14:
                  #        Bit 15:
                  #
                  #   Channel  2:                                      B72M1312P
                  #        Bit  0:EVENT FLT RCDR MALFUNCTION           B78X7887X J5-70
                  #        Bit  1:EVENT FLT RCDR RECORD INDICATION     B78X7888X J5-80
                  #        Bit  2:
                  #        Bit  3:EVENT FLT RCDR REVERSE CMD           B78X7925X J5-93
                  #        Bit  4:EVENT FDM AUTO CAL CMD               B78X7926X J5-81
                  #        Bit  5:
                  #        Bit  6:
                  #        Bit  7:
                  #        Bit  8:
                  #        Bit  9:
                  #        Bit 10:
                  #        Bit 11:
                  #        Bit 12:
                  #        Bit 13:
                  #        Bit 14:
                  #        Bit 15:
           'AID', # Card 7
                  #   Channel  0:   POWER, RSS RCVR SIG STRENGTH B     B55E1101C J5-126/125
                  #   Channel  1:   VOLTAGE, FWD THRUST PIN PIC CAP B  B55V1606C J5-119/118
                  #   Channel  2:   VOLTAGE, FWD SEPN MOTOR PIC CAP B  B55V1614C J5-127/120
                  #   Channel  3:   SPARE                              B70U1103C J5-112/111
                  #   Channel  4:   VOLTAGE, DEVELOPMENT FLT BATTERY   B76V7730C J5-102/101
                  #   Channel  5:   CURRENT, DEVELOPMENT FLT BATTERY   B76C7050C J5-128/121
                  #   Channel  6:   VOLTAGE, RECOVERY BATTERY          B76V1602C J5-114/113
                  #   Channel  7:   CURRENT, RECOVERY BATTERY          B76C1050C J5-104/103
                  #   Channel  8:   VOLTAGE, OPERATIONAL BUS B         B76V1601C J9-32/31
                  #   Channel  9:   SPARE                              B70U1109C J9-21/20
                  #   Channel 10:   SPARE                              B70U1110C J9-12/11
                  #   Channel 11:   VOLTAGE, RSS PIC CAP B             B55V1624C J9-4/3
                  #   Channel 12:   VOLTAGE, NOSE CAP RELEASE PIC CAP  B55V1617C J9-22/13
                  #   Channel 13:   VOLTAGE, FRUSTUM RELEASE PIC CAP   B55V1618C J9-6/5
                  #   Channel 14:   VOLTAGE, MAIN CHUTE DISC PIC CAP   B55V1620C J9-24/23
                  #   Channel 15:   SPARE                              B70U1115C J9-14/7
                  #   Channel 16:   TEMP, DEVELOPMENT FLIGHT BATTERY   B76T7529C J5-122/115
                  #   Channel 17:   TEMP, FLT RCDR                     B78T7530C J5-106/105
                  #   Channel 18:
                  #                 LH VOLTAGE MN CHUTE DISC PIC CAP   B55V1620C1
                  #   Channel 19:   SPARE                              B70U1119C J5-117/116
                  #   Channel 20:   TEMP, RECOVERY BATTERY             B76T1500C J5-108/107
                  #   Channel 21:
                  #   Channel 22:
                  #   Channel 23:   SPARE                              B70U1123C J5-100/99
                  #   Channel 24:   SPARE                              B70U1124C J9-26/25
                  #   Channel 25:   SPARE                              B70U1125C J9-15/8
                  #   Channel 26:
                  #   Channel 27:
                  #   Channel 28:
                  #   Channel 29:
                  #   Channel 30:
                  #   Channel 31:
                  #                 LF FWD MDM PS SEP2 SW SNSR VOLTS   B75V1631CL

    ]
  LL2:
    id: 'LL2'
    nom: 'SRB MDM LL02'
    busPri: 'LB1'
    busSec: 'LB2'
    iua: 6
    srb: true
    iom: [ 'DOL', # Card 0
                  #   Channel  0:
                  #                 LH HYD PUMP A BYPASS VLV OPEN CMD  B58K3020XL
                  #                 LH APU-A GG HTR 1 ON CMD           B46K3022XL
                  #                 LH HPU SYSTEM A-2 START CMD        B58K3017XL
                  #                 MDM LOCK VERIF TEST DISC,LL02=0DOL B75K3067XL
                  #
                  #   Channel  1:
                  #                 LH HPU SYSTEM A-1 START CMD        B58K3016XL
           'DIL', # Card 1
           'DIH', # Card 2
                  #   Channel  0:
                  #                 LH EVENT APU A ISLN VALVE CLOSED   B46X1853X1
                  #                 LH EVENT APU A ISLN VALVE OPEN     B46X1851X1
                  #                 LH EV APU SEC SP CON VLV CLD,SYS A B46X1861X1
                  #                 LH EVENT SEP A F2 TEST PWR ON CMD  B55X1914XL
                  #                 LH EV APU PRI SP CON VLV OP,SYS A  B46X1862X1
                  #
           'AID', # Card 3
                  #   Channel  0:
                  #                 LH POSITION TVC ROCK ACTUATOR      B58H1150C1
                  #   Channel  1:
                  #                 LH POSITION TVC TILT ACTUATOR      B58H1151C1
                  #   Channel  2:
                  #                 LH VOLTAGE AFT UPR BRC PIC CAP A   B55V1607C1
                  #
                  #   Channel  3:
                  #                 LH VOLTAGE AFT MID BRC PIC CAP A   B55V1609C1
                  #   Channel  4:
                  #                 LH VOLTAGE AFT LWR BRC PIC CAP A   B55V1611C1
                  #   Channel  5:
                  #                 LH VOLTAGE AFT SEPN MOT PIC CAP A  B55V1615C1
                  #   Channel  9:
                  #                 LH RATE APU A TURBINE SPEED SNSR 2 B46R1408C1
                  #   Channel 14:
                  #                 LH LEVEL HYDR FLUID RSVR SYS A     B58Q1350C1
                  #   Channel 16:
                  #                 LH PRESS HYDR FLUID SUPPLY 1       B58P1303C1
                  #   Channel 17:
                  #                 LH PRESS N2H4/GN2 BOTTLE OUT SYS A B46P1305C1
                  #   Channel 31:
                  #                 LF AFT MDM PS SEP1 SW SEN VOLTS    B75V1632C1
           'DOL', # Card 4
                  #   Channel  0:
                  #                 LH HYD PUMP B BYPASS VLV OPEN CMD  B58K3021XL
                  #                 LH APU-B GG HTR 1 ON CMD           B46K3024XL
                  #                 LH HPU SYSTEM B-2 START CMD        B58K3019XL
                  #                 LH HYD PUMP B BYPASS VLV OPEN CMD  B58K3021XL
                  #                 MDM LOCK VERIF TEST DISC,LL02=4DOL B75K3068XL
                  #
                  #

                  #   Channel  1:
                  #                 LH HPU SYSTEM B-1 START CMD        B58K3018XL
           'DIL', # Card 5
           'DIH', # Card 6
                  #   Channel  0:
                  #                 LH EVENT APU B ISLN VALVE CLOSED   B46X1854X1
                  #                 LH EVENT APU B ISLN VALVE OPEN     B46X1852X1
                  #                 LH EV APU SEC SP CON VLV CLD,SYS B B46X1863X1
                  #                 LH EVENT SEP B F2 TEST PWR ON CMD  B55X1915XL
                  #                 LH EV APU PRI SP CON VLV OP,SYS B  B46X1864X1
                  #
                  #
                  #
                  #
           'AID', # Card 7
                  #   Channel  0:
                  #                 LH VOLTAGE AFT SEPN MOT PIC CAP B  B55V1616C1
                  #   Channel  1:
                  #                 LH VOLTAGE AFT UPR BRC PIC CAP B   B55V1608C1
                  #   Channel  2:
                  #                 LH VOLTAGE AFT MID BRC PIC CAP B   B55V1610C1
                  #   Channel  3:
                  #                 LH VOLTAGE AFT LWR BRC PIC CAP B   B55V1612C1
                  #   Channel  6:
                  #                 LH RATE APU B TURBINE SPEED SNSR 2 B46R1409C1
                  #   Channel  8:
                  #                 LH VOLTAGE NOZ EXT SEV PIC CAP     B55V1619C1
                  #   Channel 11:
                  #                 LH LEVEL HYDR FLUID RSVR SYS B     B58Q1351C1
                  #   Channel 13:
                  #                 LH PRESS HYDR FLUID SUPPLY 2       B58P1304C1
                  #   Channel 14:
                  #                 LH PRESS N2H4/GN2 BOTTLE OUT SYS B B46P1306C1
                  #   Channel 31:
                  #                 LF AFT MDM PS SEP2 SW SEN VOLTS    B75V1633C1
    ]
  LR1:
    id: 'LR1'
    nom: 'SRB MDM LR01'
    busPri: 'LB1'
    busSec: 'LB2'
    iua: 15
    srb: true
    iom: [ 'DOL', # Card 0
                  #   Channel 0:
                  #                 RH RSS S&A DEVICE ARM CMD          B55K4044XL
                  #                 MDM LOCK VERIF TEST DISC,LR01=0DOL B75K4065XL
                  #   Channel 1:
                  #                 RH IGNITION S&A DEVICE,SAFE CMD 2  B55K4002XL
                  #                 RH IGNITION S&A DEVICE, ARM CMD    B55K4000XL
                  #
                  #
           'DIL', # Card 1
                  #   Channel 00:
                  #                 RH EVENT RSS A INHIBIT             B55X2881X1
                  #   Channel 01:
                  #                 SRGA 4 PITCH SMRD                  B79X2846X1
           'DIH', # Card 2
                  #   Channel 00:
                  #                 RH EVENT IGN S&A DEVICE ARMED      B55X2842X1
                  #                 RH EVENT IGN S&A DEVICE SAFED      B55X2843X1
                  #                 RH EVENT RSS S&A DEVICE SAFED      B55X2869X1
                  #                 RH EVENT RSS S&A DEVICE ARMED      B55X2870X1
                  #                 RH EVENT IGN A F2 TEST PWR ON CMD  B55X2916XL
                  #
                  #   Channel 01:
                  #                 RH EV RSS DCDR A ON/CHK TONE OFF   B55X2871X1
                  #                 RH EV RSS ARM CMD FROM DCDR A      B55X2877X1
                  #                 RH EV RSS FIRE CMD FROM DCDR A     B55X2879X1
                  #
                  #
                  #
                  #
                  #
           'AID', # Card 3
                  #   Channel 01:
                  #                 RH VOLTAGE FWD THR PIN PIC CAP A   B55V2605C1
                  #   Channel 02:
                  #                 RH VOLTAGE FWD SEPN MOT PIC CAP A  B55V2613C1
                  #   Channel 03:
                  #
                  #   Channel 04:
                  #                 RH VOLTAGE RSS BATTERY NO 1        B55V2625C1
                  #   Channel 05:
                  #                 RH VOLTAGE OPERATIONAL BUS A       B76V2600C1
                  #   Channel 06:
                  #                 RH CURRENT RSS BATTERY NO 1        B55C2051C1
                  #   Channel 07:
                  #                 RH VOLTAGE RSS PIC CAP A           B55V2623C1
                  #   Channel 31:
                  #                 RT FWD MDM PS SEP1 SW SNSR VOLTS   B75V2630CL
           'DOL', # Card 4
                  #   Channel 00:
                  #                 MDM LOCK VERIF TEST DISC,LR01=4DOL B75K4066XL
                  #   Channel 01:
                  #                 RH IGNITION S&A DEVICE,SAFE CMD 1  B55K4001XL
           'DIL', # Card 5
                  #   Channel 00:
                  #                 SRGA 2 PITCH SMRD                  B79X2845X1
                  #                 SRGA 2 YAW SMRD                    B79X2848X1
                  #   Channel 01:
                  #                 RH EVENT RSS B INHIBIT             B55X2882X1
                  #   Channel 02:
                  #                 RH EVENT RECOVERY SYSTEM RESET CMD B52X2907XL
           'DIH', # Card 6
                  #   Channel 00:
                  #                 RH EV RSS DCDR B ON/CHK TONE OFF   B55X2872X1
                  #                 RH EV RSS ARM CMD FROM DCDR B      B55X2878X1
                  #                 RH EV RSS FIRE CMD FROM DCDR B     B55X2880X1
                  #   Channel 01:
                  #                 RH EVENT IGN B F2 TEST PWR ON CMD  B55X2917XL
           'AID', # Card 7
                  #   Channel 00:
                  #
                  #   Channel 01:
                  #                 RH VOLTAGE FWD THR PIN PIC CAP B   B55V2606C1
                  #   Channel 02:
                  #                 RH VOLTAGE FWD SEPN MOT PIC CAP B  B55V2614C1
                  #   Channel 06:
                  #                 RH VOLTAGE RECOVERY BATTERY        B76V2602C1
                  #   Channel 07:
                  #                 RH CURRENT RECOVERY BATTERY        B76C2050C1
                  #   Channel 08:
                  #                 RH VOLTAGE OPERATIONAL BUS B       B76V2601C1
                  #   Channel 11:
                  #                 RH VOLTAGE RSS PIC CAP B           B55V2624C1
                  #   Channel 12:
                  #                 RH VOLTAGE NOSE CAP RLSE PIC CAP   B55V2617C1
                  #   Channel 13:
                  #                 RH VOLTAGE FRUSTUM RLSE PIC CAP    B55V2618C1
                  #   Channel 18:
                  #                 RH VOLTAGE MN CHUTE DISC PIC CAP   B55V2620C1
                  #   Channel 31:
                  #                 RT FWD MDM PS SEP2 SW SNSR VOLTS   B75V2631CL

    ]
  LR2:
    id: 'LR2'
    nom: 'SRB MDM LR02'
    busPri: 'LB1'
    busSec: 'LB2'
    iua: 18
    srb: true
    iom: [ 'DOL', # Card 0
                  #    Channel 00:
                  #                 RH HYD PUMP A BYPASS VLV OPEN CMD  B58K4020XL
                  #                 RH APU-A GG HTR 1 ON CMD           B46K4022XL
                  #                 RH HPU SYSTEM A-2 START CMD        B58K4017XL
                  #                 RH HYD PUMP A BYPASS VLV OPEN CMD  B58K4020XL
                  #                 MDM LOCK VERIF TEST DISC,LR02=0DOL B75K4067XL
                  #                 RH HYD PUMP A BYPASS VLV OPEN CMD  B58K4020XL
                  #                 RH HPU SYSTEM A-2 START CMD        B58K4017XL
                  #    Channel 01:
                  #                 RH HPU SYSTEM A-1 START CMD        B58K4016XL
           'DIL', # Card 1
           'DIH', # Card 2
                  #    Channel 00:
                  #                 RH EVENT APU A ISLN VALVE CLOSED   B46X2853X1
                  #                 RH EVENT APU A ISLN VALVE OPEN     B46X2851X1
                  #                 RH EV APU SEC SP CON VLV CLD,SYS A B46X2861X1
                  #                 RH EVENT SEP A F2 TEST PWR ON CMD  B55X2914XL
                  #                 RH EVENT APU A ISLN VALVE OPEN     B46X2851X1
                  #                 RH EVENT APU A ISLN VALVE CLOSED   B46X2853X1
                  #                 RH EV APU SEC SP CON VLV CLD,SYS A B46X2861X1
                  #                 RH EV APU PRI SP CON VLV OP,SYS A  B46X2862X1
           'AID', # Card 3
                  #    Channel 00:
                  #                 RH POSITION TVC ROCK ACTUATOR      B58H2150C1
                  #    Channel 01:
                  #                 RH POSITION TVC TILT ACTUATOR      B58H2151C1
                  #    Channel 02:
                  #                 RH VOLTAGE AFT UPR BRC PIC CAP A   B55V2607C1
                  #    Channel 03:
                  #                 RH VOLTAGE AFT MID BRC PIC CAP A   B55V2609C1
                  #    Channel 04:
                  #                 RH VOLTAGE AFT LWR BRC PIC CAP A   B55V2611C1
                  #    Channel 05:
                  #                 RH VOLTAGE AFT SEPN MOT PIC CAP A  B55V2615C1
                  #    Channel 09:
                  #                 RH RATE APU A TURBINE SPEED SNSR 2 B46R2408C
                  #    Channel 14:
                  #                 RH LEVEL HYDR FLUID RSVR SYS A     B58Q2350C1
                  #    Channel 16:
                  #                 RH PRESS HYDR FLUID SUPPLY 1       B58P2303C1
                  #    Channel 17:
                  #                 RH PRESS N2H4/GN2 BOTTLE OUT SYS A B46P2305C1
                  #    Channel 31:
                  #                 RT AFT MDM PS SEP1 SW SEN VOLTS    B75V2632C1
           'DOL', # Card 4
                  #    Channel 00:
                  #                 RH HYD PUMP B BYPASS VLV OPEN CMD  B58K4021XL
                  #                 RH APU-B GG HTR 1 ON CMD           B46K4024XL
                  #                 RH HPU SYSTEM B-2 START CMD        B58K4019XL
                  #                 RH HYD PUMP B BYPASS VLV OPEN CMD  B58K4021XL
                  #                 MDM LOCK VERIF TEST DISC,LR02=4DOL B75K4068XL
                  #                 RH HYD PUMP B BYPASS VLV OPEN CMD  B58K4021XL
                  #                 RH HPU SYSTEM B-2 START CMD        B58K4019XL
                  #    Channel 01:
                  #                 RH HPU SYSTEM B-1 START CMD        B58K4018XL
           'DIL', # Card 5
           'DIH', # Card 6
                  #    Channel 00:
                  #                 RH EVENT APU B ISLN VALVE CLOSED   B46X2854X1
                  #                 RH EVENT APU B ISLN VALVE OPEN     B46X2852X1
                  #                 RH EV APU SEC SP CON VLV CLD,SYS B B46X2863X1
                  #                 RH EVENT SEP B F2 TEST PWR ON CMD  B55X2915XL
                  #                 RH EVENT APU B ISLN VALVE OPEN     B46X2852X1
                  #                 RH EVENT APU B ISLN VALVE CLOSED   B46X2854X1
                  #                 RH EV APU SEC SP CON VLV CLD,SYS B B46X2863X1
                  #                 RH EV APU PRI SP CON VLV OP,SYS B  B46X2864X1
           'AID', # Card 7
                  #    Channel 00:
                  #                 RH VOLTAGE AFT SEPN MOT PIC CAP B  B55V2616C1
                  #    Channel 01:
                  #                 RH VOLTAGE AFT UPR BRC PIC CAP B   B55V2608C1
                  #    Channel 02:
                  #                 RH VOLTAGE AFT MID BRC PIC CAP B   B55V2610C1
                  #    Channel 03:
                  #                 RH VOLTAGE AFT LWR BRC PIC CAP B   B55V2612C1
                  #    Channel 06:
                  #                 RH RATE APU B TURBINE SPEED SNSR 2 B46R2409C1
                  #    Channel 08:
                  #                 RH VOLTAGE NOZ EXT SEV PIC CAP     B55V2619C1
                  #    Channel 11:
                  #                 RH LEVEL HYDR FLUID RSVR SYS B     B58Q2351C1
                  #    Channel 13:
                  #                 RH PRESS HYDR FLUID SUPPLY 2       B58P2304C1
                  #    Channel 14:
                  #                 RH PRESS N2H4/GN2 BOTTLE OUT SYS B B46P2306C1
                  #    Channel 31:
                  #                 RT AFT MDM PS SEP2 SW SEN VOLTS    B75V2633C1
    ]
  OF1:
    id: 'OF1'
    nom: 'OI MDM Forward 1'
    iua: 12
    busPri: 'OI1'
    busSec: 'OI2'
    iom: [ 'SIO', # Card 0
                  #   Channel 01: MTU1
           'AIS', # Card 1
                  #   Channel 04:
                  #                 FUEL CELL NO 1 CONDENSER EXIT TEMP V45T0130A
                  #   Channel 05:
                  #                 FUEL CELL 1 COOLANT PRESSURE       V45P0147A1
                  #   Channel 06:
                  #                 PRSD O2 TK 3 HTR ASSY 1 TEMP(MBK)  V45T1307A1
                  #   Channel 07:
                  #                 PRSD H2 TK 3 FLUID TEMP (MBK)      V45T2301A
                  #   Channel 08:
                  #                 CONTROL BUS AB1 VOLTAGE            V76V0120A
                  #   Channel 10:
                  #                 SMOKE DETECTOR CONCN A-AV BAY 3    V62Q0628A
                  #   Channel 13:
                  #                 AVNS BAY 3 OUTLET AIR TEMP         V61T2661A1
                  #   Channel 15:
                  #                 PSRD H2 TK 2 QUANTITY              V45Q2205A
                  #   Channel 17:
                  #                 LOOP 1 AVNS BAY 3A H2O OUTLET TEMP V61T2630A1
                  #   Channel 18:
                  #                 PRSD H2 TK 3 PRESS (MID BODY KIT)  V45P2300A1
                  #   Channel 19:
                  #                 CABIN FAN DELTA PRESS              V61P2556A1
                  #   Channel 22:
                  #                 FCL 1 PAYLOAD HX FLOWRATE          V63R1103A1
                  #   Channel 24:
                  #                 FCP NO 2 SUBSTACK 1 DELTA VOLTAGE  V45V0202A1
                  #   Channel 25:
                  #                 IMU DELTA PRESS                    V61P2869A1
                  #   Channel 27:
                  #                 FCP NO 2 SUBSTACK 2 DELTA VOLTAGE  V45V0203A1
                  #   Channel 29:
                  #                 FCP NO 2 SUBSTACK 3 DELTA VOLTAGE  V45V0204A1
           'DIL', # Card 2
                  #   Channel 00:
                  #                 FUEL CELL NO 1 H2O CONDITION       V45X0410E1
                  #   Channel 02:
                  #                 BAY1 DSC                           V75X2171E1
           'AIS', # Card 3
                  #   Channel 00:
                  #                 EXTRA VEHICULAR LSS BAT CHG CUR 1  V64C0211A
                  #   Channel 01:
                  #                 EXTRA VEHICULAR LSS BAT CHG CUR 2  V64C0214A
                  #   Channel 04:
                  #                 PRSD O2 MANF 1 PRESSURE            V45P1140A
                  #   Channel 07:
                  #                 LOOP 2 AVNS BAY 3 HX OUT TEMP      V61T2622A1
                  #   Channel 08:
                  #                 SMOKE DETR CONCN RTN AIR-CAB HX    V62Q0595A
                  #   Channel 09:
                  #                 CONTROL BUS AB2 VOLTAGE            V76V0121A
                  #   Channel 13:
                  #                 PRSD O2 TK 1 QUANTITY              V45Q1105A
                  #   Channel 17:
                  #                 H2O LOOP 1 INTERCHANGER FLOW       V61R2742A1
                  #   Channel 18:
                  #                 PRSD O2 TK 4(&5) HTR CONT PRESS    V45P1410A1
                  #   Channel 20:
                  #                 PRSD O2 TK 5 PRESS(MID BODY KIT)   V45P1500A1
                  #   Channel 21:
                  #                 PRSD H2 TK 5 PRESS(MID BODY KIT)   V45P2500A1
                  #   Channel 22:
                  #                 PRSD O2 TK 5 ANNULUS VACUUM (MBK)  V45P1504A
                  #   Channel 23:
                  #                 PRSD H2 TK 5 ANNULUS VACCUM (MBK)  V45P2504A
           'DIH', # Card 4
                  #   Channel 00:
                  #                 FWD MCA 1 OPERATIONAL STATUS 1     V76X2111E1
                  #                 FWD MCA 1 OPERATIONAL STATUS 2     V76X2112E1
                  #                 MID MCA 1 OPERATIONAL STATUS 1     V76X2211E1
                  #                 MID MCA 1 OPERATIONAL STATUS 2     V76X2212E1
                  #                 MID MCA 3 OPERATIONAL STATUS 1     V76X2231E1
                  #                 MID MCA 3 OPERATIONAL STATUS 2     V76X2232E1
                  #                 MID MCA 4 OPERATIONAL STATUS 1     V76X2241E1
                  #                 MID MCA 4 OPERATIONAL STATUS 2     V76X2242E1
                  #
                  #   Channel 01: V76X4351E RPC A: GPC1
                  #               V72X7015E CICU:GPC6 'I-FAIL'
                  #                 PCA IMU NO 3 RPC NO A ON           V76X4257E1
                  #                 MAIN BUS A CONT BUS AB1/CA1 RPC ON V76X0124E1
                  #                 INVERTER BUS NO 1 O/V-U/V          V76X1505E
                  #
                  #   Channel 02: V72X7011E      GPC1 'I-FAIL'
                  #                 MAIN BUS A ESS 2CA RPC ON          V76X0136E1
                  #                 PRSD O2 TK 1 HTR B1-ON             V45X1108E1
                  #                 AC BUS 1 PHASE A INPUT ON          V76X1537E
                  #
                  #
                  #
           'AIS', # Card 5
                  #   Channel 01:
                  #                 MID MCA 1 OPERATIONAL STATUS 7     V76X2218E
                  #   Channel 03:
                  #                 FUEL CELL NO 1 STACK COOL OUT TEMP V45T0120A
                  #   Channel 05:
                  #                 FUEL CELL NO 3 COOLANT RETURN TEMP V45T0345A
                  #   Channel 06:
                  #                 PRSD H2 TK 5 HTR CONT SNSR C/O     V45P2515A
                  #   Channel 07:
                  #                 PRSD O2 TK 1 HTR CONTROL PRESS     V45P1110A1
                  #   Channel 09:
                  #                 SMOKE DETECTOR CONCN A-AV BAY 2    V62Q0608A
                  #   Channel 10:
                  #                 CONTROL BUS AB3 VOLTAGE            V76V0122A
                  #   Channel 12:
                  #                 PRSD O2 TK 1 PRESSURE              V45P1100A1
                  #   Channel 13:
                  #                 EXTRA VEHICULAR LSS BAT CHG VOLT 2 V64V0213A
                  #   Channel 28:
                  #                 PRSD O2 TK 6 HTR CONT PRESS        V45P3110A
                  #   Channel 29:
                  #                 PRSD H2 TK 6 HRT CONT PRESS        V45P4110A
           'DIH', # Card 6
                  #   Channel 00:
                  #                 FWD MCA 1 OPERATIONAL STATUS 3     V76X2113E1
                  #                 FWD MCA 1 OPERATIONAL STATUS 4     V76X2114E1
                  #                 MID MCA 1 OPERATIONAL STATUS 3     V76X2213E1
                  #                 MID MCA 1 OPERATIONAL STATUS 4     V76X2214E1
                  #                 MID MCA 2 OPERATIONAL STATUS 1     V76X2221E1
                  #                 MID MCA 2 OPERATIONAL STATUS 2     V76X2222E1
                  #                 MID MCA 3 OPERATIONAL STATUS 3     V76X2233E1
                  #                 MID MCA 3 OPERATIONAL STATUS 4     V76X2234E1
                  #                 MID MCA 4 OPERATIONAL STATUS 3     V76X2243E1
                  #                 MID MCA 4 OPERATIONAL STATUS 4     V76X2244E1
                  #   Channel 01:
                  #                 MAIN BUS A CONT BUS AB2/CA2 RPC ON V76X0125E1
                  #                 PRSD O2 TK 1 HTR B2-ON             V45X1113E1
                  #                 PCA-PCM NO 1 RPC A ON              V76X4265E1
                  #                 AC BUS 1 PHASE B INPUT ON          V76X1538E
                  #   Channel 02:
                  #                 PRSD O2 TK 1 HTR A2-ON             V45X1111E1
                  #                 FUEL CELL H2/O2 PGE HTR-RPC A ON   V76X0155E
                  #                 AC BUS 1 OVERLOAD                  V76X1506E
           'AIS', # Card 7
                  #   Channel 01:
                  #                 AC BUS 1 PHASE A VOLT              V76V1500A1
                  #   Channel 02:
                  #                 LDG GR LH OUTBD BRAKE PRESS NO 2A  V51P0722A1
                  #   Channel 04:
                  #                 FWD PCA MAIN BUS A AMPS            V76C3075A
                  #   Channel 05:
                  #                 FUEL CELL NO 1 VOLTAGE             V45V0100A1
                  #   Channel 06:
                  #                 LDG GR LH INBD BRAKE PRESS NO 1A   V51P0728A1
                  #   Channel 07:
                  #                 FUEL CELL NO 1 H2 FLOW             V45R0170A
                  #   Channel 08:
                  #                 AC BUS 1 PHASE C CURRENT           V76C1542A1
                  #   Channel 09:
                  #                 AC BUS 1 PHASE A CURRENT           V76C1540A1
                  #   Channel 22:
                  #                 AVN FEXT AV BAY 3A PYRO CAP VOLT   V76V4700A1
           'AID', # Card 8 (UNUSED)
           'AIS', # Card 9
                  #   Channel 01:
                  #                 PRSD H2 TK 5 HTR CONT PRESS        V45P2510A1
                  #   Channel 04:
                  #                 PRSD O2 TK 1 HTR ASSY 1 TEMP       V45T1107A1
                  #   Channel 05:
                  #                 FCP NO 1 PRODUCT H2O LINE TEMP     V45T0181A
                  #   Channel 11:
                  #                 O2 PARTIAL PRESSURE-A              V61P2511A1
                  #   Channel 12:
                  #                 EXTRA VEHICULAR LSS BAT CHG VOLT 1 V64V0210A
                  #   Channel 13:
                  #                 PRSD H2 TK1 PRESSURE               V45P2100A1
                  #   Channel 16:
                  #                 AVIONICS BAY 3 DELTA PRESS         V61P2658A1
                  #   Channel 18:
                  #                 FCL 1 PUMP INLET PRESS             V63P1108A1
                  #   Channel 19:
                  #                 FCL 2 ACCUMULATOR QUANTITY         V63Q1330A1
                  #   Channel 24:
                  #                 LOOP 1 AVNS BAY 2 H2O OUTLET TEMP  V61T2627A1
                  #   Channel 26:
                  #                 PRSD O2 TK 4 PRESS (MID BODY KIT)  V45P1400A1
           'DIL', # Card 10
                  #   Channel 01:
                  #                 AVN FEXT AV BAY 3A PYRO L/T        V76X4705E
                  #                 AVN FEXT AV BAY 3A PYRO RTST       V76X4710E
                  #                 ORB/ET FWD SEP PYRO L/T A          V76X6930E
                  #                 ORB/ET FWD SEP PYRO RTST A         V76X6932E
           'AIS', # Card 11
                  #   Channel 00:
                  #                 MAIN BUS C VOLTAGE                 V76V0300A1
                  #   Channel 01:
                  #                 MIN PCA MAIN BUS A AMPS            V76C3085A
                  #   Channel 03:
                  #                 AC BUS 1 PHASE B VOLT              V76V1501A1
                  #   Channel 04:
                  #                 AC BUS 1 PHASE C VOLT              V76V1502A1
                  #   Channel 05:
                  #                 FUEL CELL NO 1 O2 FLOW             V45R0160A
                  #   Channel 06:
                  #                 AC BUS 1 PHASE B CURRENT           V76C1541A1
                  #   Channel 20:
                  #                 FWD PCA-1 VOLTAGE                  V76V3071A
                  #   Channel 27:
                  #                 MPS E2 REG A HE OUTLET PRESS       V41P1254A1
           'DIH', # Card 12
                  #   Channel 00:
                  #                 PRSD O2 TK 1 HTR CUR SNSR 1A-TRIP  V45X1185E1
                  #                 PRSD O2 TK 1 HTR CUR SNSR 2B-TRIP  V45X1188E1
                  #                 PRSD O2 TK 1 HTR A1-ON             V45X1106E1
                  #                 PCA-PCM NO 2 RPC A ON              V76X4272E1
                  #                 AC BUS 1 VOLTAGE SENSOR AUTO       V76S1503E
                  #                 ARRAY 1 MN BUS A PWR TO INV PH C   V76X1812E
                  #   Channel 01:
                  #                 BRAKE/SKID SUB BUS C/A RPC PWR A   V76X5800E1
                  #                 PRSD O2 GAS SPLY VLV-CLOSED        V45X1195E1
                  #                 ARRAY 1 MN BUS A PWR TO INV PH A   V76X1804E
                  #                 MID MCA 1 OPERATIONAL STATUS 10    V76X2162E
                  #
                  #   Channel 02:
                  #                 PRSD O2 TK 1 HTR CUR SNSR 1B-TRIP  V45X1187E1
                  #                 MAIN BUS A CONT BUS AB3/CA3 RPC ON V76X0126E1
                  #                 PRSD H2 TK 1 HTR B-ON              V45X2108E1
                  #                 AC BUS 1 PHASE C INPUT ON          V76X1539E
           'AIS', # Card 13
                  #   Channel 04:
                  #                 PRSD H2 TK 1 HTR ASSY TEMP         V45T2107A1
                  #   Channel 05:
                  #                 FUEL CELL NO 3 STACK INLET TEMP    V45T0313A1
                  #   Channel 06:
                  #                 ESS BUS 3AB VOLTAGE                V76V0330A
                  #   Channel 07:
                  #                 LOOP 1 AVNS BAY 3 HX OUT TEMP      V61T2621A1
                  #   Channel 08:
                  #                 FC NO 1 H2O RELIEF VALVE TEMP      V45T0412A
                  #   Channel 09:
                  #                 PRSD H2 TK 3 HTR CONT PRESS (MBK)  V45P2310A1
                  #   Channel 11:
                  #                 FCP NO 3 H2 PUMP MTR CONDITION     V45V0314A1
                  #   Channel 15:
                  #                 PRSD O2 TK 1 HTR CTRL SNSR C/O     V45P1115A
           'DIH', # Card 14
                  #   Channel 00:
                  #                 PRSD O2 TK 1 HTR CUR SNSR 2A-TRIP  V45X1186E1
                  #                 N/W STEERING FAILED                V51X0645E1
                  #                 ARRAY 1 MN BUS A PWR TO INV PH B   V76X1808E
                  #   Channel 01:
                  #                 NLG STR ACTR SHUTTLE V GR DN RDY   V58X1825E1
                  #                 PCA FLT CONT ACCEL 3 RPC A ON      V76X4297E1
                  #                 AC BUS 1 VOLTAGE SENSOR MONITOR    V76S1504E
                  #   Channel 02:
                  #                 PCA IMU NO 1 RPC NO A ON           V76X4250E1
                  #                 MAIN BUS A ESS 3AB RPC ON          V76X0135E1
                  #                 PAYLOAD AUX RPC A ON               V76X2868E1
                  #                 PRSD H2 TK 1 HTR A-ON              V45X2106E1
                  #                 FCP NO 1 CONTROL POWER             V45S0180E
                  #                 FIRE SUPPRESION AV BAY 3 ARM       V45X2106E
                  #                 MID MCA 1 OPERATIONAL STATUS 9     V76X2161E
           'AIS'  # Card 15
                  #   Channel 22:
                  #                 MPS E3 REG A HE OUTLET PRESS       V41P1354A1
                  #   Channel 24:
                  #                 MPS E1 REG A HE OUTLET PRESS       V41P1154A1
                  #
                  #
                  #
    ]
  OF2:
    id: 'OF2'
    nom: 'OI MDM Forward 2'
    iua: 15
    busPri: 'OI1'
    busSec: 'OI2'
    iom: [ 'SIO', # Card 0
           'AIS', # Card 1
                  #   Channel 00:
                  #
                  #   Channel 03:
                  #                 PRSD O2 TK 5 HTR ASSY 1 TEMP(MBK)  V45T1507A1
                  #   Channel 04:
                  #
                  #   Channel 06:
                  #
                  #   Channel 07:
                  #
                  #   Channel 18:
                  #                 FCL 2 PAYLOAD HX FLOWRATE          V63R1303A1
                  #   Channel 20:
                  #                 PRSD O2 TK 6 PRESS                 D45V310011
                  #   Channel 21:
                  #                 PRSD O2 TK 8 PRESS                 D45V330011
                  #   Channel 22:
                  #                 PRSD H2 TK 6 PRESS                 D45V410011
                  #   Channel 23:
                  #                 PRSD H2 TK 8 PRESS                 D45V430011
           'DIL', # Card 2
                  #   Channel 00:
                  #                 FUEL CELL NO 2 H2O CONDITION       V45X0420E1
                  #   Channel 01:
           'AIS', # Card 3
                  #   Channel 00:
                  #
                  #   Channel 01:
                  #
                  #   Channel 02:
                  #                 FUEL CELL 2 COOLANT PRESSURE       V45P0247A1
                  #   Channel 03:
                  #
                  #   Channel 04:
                  #
                  #   Channel 05:
                  #
                  #   Channel 07:
                  #                 PRSD H2 TK 1 HTR CONTROL PRESS     V45P2110A1
                  #   Channel 09:
                  #
                  #   Channel 11:
                  #                 FCL 1 INTERCHANGER FLOWRATE        V63R1100A1
                  #   Channel 14:
                  #                 LOOP 2 AVNS BAY 2 H2O OUTLET TEMP  V61T2628A1
                  #   Channel 15:
                  #                 H2O LOOP 2 INTERCHANGER FLOW       V61R2722A1
                  #   Channel 17:
                  #
                  #   Channel 18:
                  #
                  #   Channel 20:
                  #
                  #   Channel 21:
                  #
                  #   Channel 22:
                  #
                  #   Channel 23:
                  #
                  #   Channel 24:
                  #
                  #   Channel 25:
                  #
                  #   Channel 26:
                  #
                  #   Channel 27:
                  #
           'DIH', # Card 4
                  #   Channel 00:
                  #                 FWD MCA 2 OPERATIONAL STATUS 1     V76X2121E1
                  #                 FWD MCA 2 OPERATIONAL STATUS 2     V76X2122E1
                  #                 MID MCA 1 OPERATIONAL STATUS 5     V76X2215E1
                  #                 MID MCA 1 OPERATIONAL STATUS 6     V76X2216E1
                  #                 MID MCA 3 OPERATIONAL STATUS 5     V76X2235E1
                  #                 MID MCA 3 OPERATIONAL STATUS 6     V76X2236E1
                  #   Channel 01:
                  #                 MAIN BUS B ESS 1BC RPC ON          V76X0236E1
                  #                 PCA FLT CONT ACCEL 4 RPC B ON      V76X4300E1
                  #                 PCA-PCM NO 2 RPC B ON              V76X4274E1
                  #                 PCA-PCM NO 2 RPC B ON              V76X4274E1
                  #   Channel 02:
                  #                 NLG/DOOR UPLOCKED                  V51X0315E1
                  #                 MAIN BUS B CONT BUS AB1/BC1 RPC ON V76X0224E1
           'AIS', # Card 5
                  #   Channel 00:
                  #   Channel 02:
                  #   Channel 04:
                  #   Channel 05:
                  #                 PRSD H2 TK 4(&5) HTR CONT PRESS    V45P2410A1
                  #   Channel 11:
                  #                 RCDR OPS 2 HEAD TEMPERATURE        V75T2617A1
                  #   Channel 12:
                  #                 LOOP 2 AVNS BAY 3A H2O OUTLET TEMP V61T2631A1
                  #   Channel 16:
                  #                 LOOP 1 AVNS BAY 1 HX OUTLET TEMP   V61T2615A1
                  #   Channel 17:
                  #                 LOOP 2 AVNS BAY 1 HX OUTLET TEMP   V61T2616A1
                  #   Channel 18:
                  #                 AVIONICS BAY 1 DELTA PRESS         V61P2642A1
                  #   Channel 20:
                  #   Channel 21:
                  #   Channel 22:
                  #   Channel 23:
           'DIH', # Card 6
                  #   Channel 00:
                  #                 FWD MCA 2 OPERATIONAL STATUS 3     V76X2123E1
                  #                 FWD MCA 2 OPERATIONAL STATUS 4     V76X2124E1
                  #                 MID MCA 1 OPERATIONAL STATUS 7     V76X2217E1
                  #                 MID MCA 1 OPERATIONAL STATUS 8     V76X2218E1
                  #                 MID MCA 3 OPERATIONAL STATUS 7     V76X2237E1
                  #                 MID MCA 3 OPERATIONAL STATUS 8     V76X2238E1
                  #   Channel 01:
                  #   Channel 02:
                  #                 BRAKE/SKID SUB BUS B/C RPC PWR B   V76X5805E1
                  #                 MAIN BUS B CONT BUS AB2/BC2 RPC ON V76X0225E1
           'AIS', # Card 7
                  #   Channel 08:
                  #                 LDG GR RH OUTBD BRAKE PRESS NO 4A  V51P0744A1
                  #   Channel 09:
                  #                 LDG GR RH INBD BRAKE PRESS NO 1A   V51P0748A1
                  #   Channel 10:
                  #                 FUEL CELL NO 2 VOLTAGE             V45V0200A1
                  #   Channel 12:
                  #                 AC BUS 2 PHASE A VOLT              V76V1600A1
                  #   Channel 13:
                  #                 AC BUS 2 PHASE C VOLT              V76V1602A1
                  #   Channel 14:
                  #   Channel 15:
                  #   Channel 16:
                  #                 AC BUS 2 PHASE A CURRENT           V76C1640A1
                  #   Channel 17:
                  #                 AC BUS 2 PHASE C CURRENT           V76C1642A1
                  #   Channel 20:
                  #                 LMG EMER EXT PYRO B CAP VOLT       V76V4902A1
                  #   Channel 22:
                  #                 NLG PYRO EXTEND ACTR-CAP VOLT-2    V76V4821A1
                  #   Channel 23:
                  #                 NLG EMER EXT PYRO B CAP VOLT       V76V4832A1
           'AID', # Card 8
           'AIS', # Card 9
                  #   Channel 00:
                  #                 PRSD H2 TK 2 HTR ASSY TEMP         V45T2207A1
                  #   Channel 01:
                  #                 PRSD O2 TK 5 HTR CONT PRESS        V45P1510A
                  #   Channel 02:
                  #   Channel 05:
                  #   Channel 07:
                  #   Channel 08:
                  #                 H2O LOOP 1 PUMP OUTLET PRESS       V61P2600A1
                  #   Channel 11:
                  #   Channel 12:
                  #                 LOOP 1 AVNS BAY 1 H2O OUTLET TEMP  V61T2624A1
                  #   Channel 13:
                  #                 FCP NO 3 SUBSTACK 1 DELTA VOLTAGE  V45V0302A1
                  #   Channel 17:
                  #                 FCL 2 PUMP INLET PRESS             V63P1308A1
                  #   Channel 18:
                  #                 FCL 1 ACCUMULATOR QUANTITY         V63Q1130A1
                  #   Channel 24:
                  #   Channel 25:
                  #   Channel 27:
                  #                 FCP NO 3 SUBSTACK 2 DELTA VOLTAGE  V45V0303A1
                  #   Channel 28:
                  #                 FCP NO 3 SUBSTACK 3 DELTA VOLTAGE  V45V0304A1
           'DIL', # Card 10
                  #   Channel 00:
                  #   Channel 01:
           'AIS', # Card 11
                  #   Channel 01:
                  #                 AC BUS 2 PHASE B VOLT              V76V1601A1
                  #   Channel 02:
                  #                 MAIN BUS A VOLTAGE                 V76V0100A1
                  #   Channel 03:
                  #   Channel 04:
                  #   Channel 05:
                  #                 AC BUS 2 PHASE B CURRENT           V76C1641A1
                  #   Channel 21:
                  #                 RMG EMER EXT PYRO B CAP VOLT       V76V4952A1
                  #   Channel 22:
                  #                 AVN FEXT AV BAY 1 PYRO CAP VOLT    V76V4736A1
                  #   Channel 24:
           'DIH', # Card 12
                  #   Channel 00:
                  #   Channel 01:
                  #                 LMG/DOOR UPLOCKED                  V51X0115E1
                  #                 MAIN BUS B CONT BUS AB3/BC3 RPC ON V76X0226E1
                  #   Channel 02:
                  #                 PCA IMU NO 1 RPC NO B ON           V76X4251E1
           'AIS', # Card 13
                  #   Channel 01:
                  #                 PRSD O2 TK 2 HTR ASSY 2 TEMP       V45T1209A1
                  #   Channel 02:
                  #                 FUEL CELL NO 1 STACK INLET TEMP    V45T0113A1
                  #   Channel 03:
                  #   Channel 07:
                  #                 PRSD H2 TK 4 HTR ASSY TEMP(MBK)    V45T2407A1
                  #   Channel 08:
                  #   Channel 09:
                  #                 O2 PARTIAL PRESSURE-B              V61P2513A1
                  #   Channel 11:
                  #                 FCP NO 1 H2 PUMP MTR CONDITION     V45V0114A1
                  #   Channel 14:
                  #                 AVNS BAY 1 OUTLET AIR TEMP         V61T2645A1
                  #   Channel 15:
                  #                 LOOP 2 AVNS BAY 1 H2O OUTLET TEMP  V61T2625A1
                  #   Channel 16:
                  #   Channel 17:
                  #                 H2O LOOP 1 PUMP DELTA PRESS        V61P2605A1
                  #   Channel 20:
                  #   Channel 21:
                  #   Channel 22:
                  #   Channel 23:
           'DIH', # Card 14
                  #   Channel 00:
                  #                 MAIN BUS B ESS 3AB RPC ON          V76X0235E1
                  #   Channel 02:
                  #                 PCA IMU NO 2 RPC NO B ON           V76X4253E1
                  #                 PAYLOAD AUX RPC B ON               V76X2869E1
           'AIS'  # Card 15
    ]
  OF3:
    id: 'OF3'
    nom: 'OI MDM Forward 3'
    iua: 17
    busPri: 'OI1'
    busSec: 'OI2'
    iom: [ 'SIO', # Card 0 (UNUSED)
           'AIS', # Card 1
                  #   Channel 00:
                  #              PRSD O2 TK 1 HTR ASSY 2 TEMP       V45T1109A1
                  #   Channel 01:
                  #              FUEL CELL 3 COOLANT PRESSURE       V45P0347A1
                  #   Channel 03:
                  #
                  #   Channel 07:
                  #
                  #   Channel 08:
                  #              PRSD O2 TK 2 HTR ASSY 1 TEMP       V45T1207A1
                  #   Channel 09:
                  #
                  #   Channel 11:
                  #
                  #   Channel 12:
                  #
                  #   Channel 14:
                  #              PRSD H2 TK 2 PRESSURE              V45P2200A1
                  #   Channel 17:
                  #
                  #   Channel 18:
                  #
                  #   Channel 20:
                  #
                  #   Channel 21:
                  #
                  #   Channel 22:
                  #
                  #   Channel 23:
                  #
           'DIL', # Card 2
                  #   Channel 00:
                  #              C/W MASTER ALARM TLM OUTPUT        V73X1567E1
                  #
                  #   Channel 01:
                  #              NSP FRAME SYNC LOCK 1              V74X5176E1
                  #   Channel 02:
                  #              BAY3 DSC                           V75X2173E1
           'AIS', # Card 3
                  #   Channel 00:
                  #
                  #   Channel 01:
                  #
                  #   Channel 03:
                  #
                  #   Channel 05:
                  #
                  #   Channel 08:
                  #
                  #   Channel 09:
                  #
                  #   Channel 11:
                  #              PRSD H2 TK 4 PRESS (MID BODY KIT)  V45P2400A1
                  #   Channel 16:
                  #              H2O LOOP 2 PUMP DELTA PRESS        V61P2705A1
                  #   Channel 20:
                  #              PRSD O2 TK 3 HTR ASSY 2 TEMP(MBK)  V45T1309A1
                  #   Channel 21:
                  #
                  #   Channel 22:
                  #
                  #   Channel 23:
                  #              FUEL CELL NO 2 STACK INLET TEMP    V45T0213A1
                  #   Channel 24:
                  #              PRSD O2 TK 3 HTR CONT PRESS (MBK)  V45P1310A1
                  #   Channel 25:
                  #
                  #   Channel 26:
                  #              PRSD H2 TK 5 HTR ASSY TEMP(MBK)    V45T2507A1
                  #   Channel 28:
                  #
                  #   Channel 29:
                  #              PRSD O2 TK 5 HTR ASSY 2 TEMP(MBK)  V45T1509A1
           'DIH', # Card 4
                  #   Channel 00:
                  #              FWD MCA 3 OPERATIONAL STATUS 1     V76X2131E1
                  #              FWD MCA 3 OPERATIONAL STATUS 2     V76X2132E1
                  #              FWD MCA 3 OPERATIONAL STATUS 3     V76X2133E1
                  #              FWD MCA 3 OPERATIONAL STATUS 4     V76X2134E1
                  #              MID MCA 2 OPERATIONAL STATUS 3     V76X2223E1
                  #              MID MCA 2 OPERATIONAL STATUS 4     V76X2224E1
                  #              MID MCA 2 OPERATIONAL STATUS 5     V76X2225E1
                  #              MID MCA 2 OPERATIONAL STATUS 6     V76X2226E1
                  #              MID MCA 2 OPERATIONAL STATUS 7     V76X2227E1
                  #              MID MCA 2 OPERATIONAL STATUS 8     V76X2228E1
                  #   Channel 01:
                  #              PCA IMU NO 2 RPC NO C ON           V76X4254E1
                  #              MAIN BUS C ESS 1BC RPC ON          V76X0335E1
                  #              PRSD O2 TK 2 HTR A1-ON             V45X1206E1
                  #   Channel 02:
                  #
           'AIS', # Card 5
                  #   Channel 01:
                  #
                  #   Channel 02:
                  #              PRSD O2 TK 4 HTR ASSY 1 TEMP(MBK)  V45T1407A1
                  #   Channel 05:
                  #
                  #   Channel 06:
                  #
                  #   Channel 07:
                  #              PRSD H2 TK 3 HTR ASSY TEMP(MBK)    V45T2307A1
                  #   Channel 08:
                  #
                  #   Channel 12:
                  #              PRSD O2 TK 2 PRESSURE              V45P1200A1
                  #   Channel 13:
                  #
                  #   Channel 14:
                  #
                  #   Channel 20:
                  #
                  #   Channel 21:
                  #              PRSD O2 TK 4 HTR ASSY 2 TEMP(MBK)  V45T1409A1
                  #   Channel 22:
                  #
                  #   Channel 23:
                  #
                  #   Channel 24:
                  #              LOOP 2 AVNS BAY 2 HX OUTLET TEMP   V61T2619A1
                  #   Channel 25:
                  #              AVIONICS BAY 2 DELTA PRESS         V61P2647A1
                  #   Channel 26:
                  #              PRSD O2 TK 2 HTR CONTROL PRESS     V45P1210A1
                  #   Channel 27:
                  #              LOOP 1 AVNS BAY 2 HX OUTLET TEMP   V61T2618A1
                  #   Channel 28:
                  #
                  #   Channel 29:
                  #
           'DIH', # Card 6
                  #   Channel 00:
                  #              PRSD O2 TK 2 HTR CUR SNSR 1A-TRIP  V45X1285E1
                  #              BRAKE/SKID SUB BUS B/C RPC PWR C   V76X5806E1
                  #              RMG/DOOR UPLOCKED                  V51X0215E1
                  #
                  #   Channel 01:
                  #              PCA IMU NO 3 RPC NO C ON           V76X4256E1
                  #              MAIN BUS C CONT BUS BC1/CA1 RPC ON V76X0324E1
                  #              PRSD O2 TK 2 HTR B1-ON             V45X1208E
                  #   Channel 02:
                  #              MAIN BUS C ESS 2CA RPC ON          V76X0336E1
                  #              GCIL ACTIVE                        V74X5052E1
                  #              PRSD H2 TK 2 HEATER A-ON           V45X2206E1
                  #
                  #
           'AIS', # Card 7
                  #   Channel 02:
                  #              LDG GR RH OUTBD BRAKE PRESS NO 2A  V51P0742A1
                  #   Channel 03:
                  #              LDG GR RH INBD BRAKE PRESS NO 3A   V51P0746A1
                  #   Channel 04:
                  #
                  #   Channel 05:
                  #              AC BUS 3 PHASE A CURRENT           V76C1740A1
                  #   Channel 06:
                  #
                  #   Channel 07:
                  #              FUEL CELL NO 3 VOLTAGE             V45V0300A1
                  #   Channel 09:
                  #              AC BUS 3 PHASE A VOLT              V76V1700A1
                  #   Channel 10:
                  #              AC BUS 3 PHASE C VOLT              V76V1702A1
                  #   Channel 20:
                  #              RMG EMER EXT PYRO A CAP VOLT       V76V4950A1
                  #   Channel 23:
                  #              NLG EMER EXT PYRO A CAP VOLT       V76V4830A1
           'AID', # Card 8
           'AIS', # Card 9
                  #   Channel 05:
                  #
                  #   Channel 07:
                  #
                  #   Channel 09:
                  #
                  #   Channel 16:
                  #
                  #   Channel 17:
                  #              O2 PARTIAL PRESSURE-C              V61P2515A1
                  #   Channel 19:
                  #              PRSD H2 TK 2 HTR CONTROL PRESS     V45P2210A1
                  #   Channel 22:
                  #
                  #   Channel 24:
                  #
                  #   Channel 25:
                  #
                  #   Channel 26:
                  #
           'DIL', # Card 10
                  #   Channel 01:
                  #              FUEL CELL NO 3 H2O CONDITION       V45X0430E1
                  #              NSP FRAME SYNC LOCK 2              V74X5177E1
                  #
                  #
                  #
                  #
           'AIS', # Card 11
                  #   Channel 00:
                  #              MAIN BUS B VOLTAGE                 V76V0200A1
                  #   Channel 01:
                  #              AC BUS 3 PHASE B VOLT              V76V1701A1
                  #   Channel 02:
                  #
                  #   Channel 04:
                  #
                  #   Channel 05:
                  #              AC BUS 3 PHASE B CURRENT           V76C1741A1
                  #   Channel 06:
                  #
                  #   Channel 08:
                  #              LDG GR LH INBD BRAKE PRESS NO 3A   V51P0726A1
                  #   Channel 09:
                  #              LDG GR LH OUTBD BRAKE PRESS NO 4A  V51P0724A1
                  #   Channel 16:
                  #              LMG EMER EXT PYRO A CAP VOLT       V76V4900A1
                  #   Channel 23:
                  #
           'DIH', # Card 12
                  #   Channel 00:
                  #              MAIN BUS C CONT BUS BC2/CA2 RPC ON V76X0325E1
                  #              PRSD H2 TK 2 HEATER B-ON           V45X2208E1
                  #   Channel 01:
                  #              PCA FLT CONT ACCEL 3 RPC C ON      V76X4298E1
                  #              PRSD H2 GAS SPLY VLV-CLOSED        V45X2195E1
                  #   Channel 02:
                  #              PRSD O2 TK 2 HTR CUR SNSR 2A-TRIP  V45X1286E1
                  #              BRAKE/SKID SUB BUS C/A RPC PWR C   V76X5811E1
                  #              RMG STR ACTR SHUTTLE V GR DN RDY   V58X1775E1
                  #              PRSD O2 TK 2 HTR A2-ON             V45X1211E1
                  #              PCA-PCM NO 1 RPC C ON              V76X4267E1
                  #
           'AIS', # Card 13
                  #   Channel 00:
                  #              V45P1145A: PRSD O2 MANF 2 PRESSURE
                  #   Channel 02:
                  #
                  #   Channel 06:
                  #
                  #   Channel 07:
                  #
                  #   Channel 10:
                  #              PRSD O2 TK 3 PRESS (MID BODY KIT)  V45P1300A1
                  #   Channel 11:
                  #
                  #   Channel 15:
                  #              FCP NO 2 H2 PUMP MTR CONDITION     V45V0214A1
                  #   Channel 17:
                  #              H2O LOOP 2 PUMP OUTLET PRESS       V61P2700A1
                  #   Channel 18:
                  #              FCL 2 INTERCHANGER FLOWRATE        V63R1300A1
                  #   Channel 19:
                  #              AVNS BAY 2 OUTLET AIR TEMP         V61T2650A1
                  #   Channel 20:
                  #
                  #   Channel 21:
                  #
                  #   Channel 22:
                  #
                  #   Channel 23:
                  #
                  #   Channel 24:
                  #              ME-1 AFV DOWNSTREAM TEMP #1        E41T1155A1
                  #   Channel 25:
                  #              ME-3 AFV DOWNSTREAM TEMP #2        E41T3156A1
           'DIH', # Card 14
                  #   Channel 00:
                  #              PRSD O2 TK 2 HTR CUR SNSR 2B-TRIP  V45X1288E1
                  #              PCA FLT CONT ACCEL 4 RPC C ON      V76X4299E1
                  #
                  #
                  #   Channel 01:
                  #              PRSD O2 TK 2 HTR CUR SNSR 1B-TRIP  V45X1287E1
                  #              MAIN BUS C CONT BUS BC3/CA3 RPC ON V76X0326E1
                  #
                  #
                  #   Channel 02:
                  #              LMG STR ACTR SHUTTLE V GR DN RDY   V58X1725E1
                  #              PRSD O2 TK 2 HTR B2-ON             V45X1213E1
                  #
                  #
           'AIS'  # Card 15
                  #   Channel 00:
                  #              V45C0101A FUEL CELL NO 1 CURRENT
                  #   Channel 01:
                  #              V45C0201A FUEL CELL NO 2 CURRENT
                  #   Channel 02:
                  #              V45C0301A FUEL CELL NO 3 CURRENT
                  #   Channel 06:
                  #              AC BUS 3 PHASE C CURRENT           V76C1742A1
                  #   Channel 19:
                  #              AVN FEXT AV BAY 2 PYRO CAP VOLT    V76V4716A1
                  #   Channel 20:
                  #              NLG PYRO EXTEND ACTR-CAP VOLT-1    V76V4820A1
    ]
  OF4:
    id: 'OF4'
    nom: 'OI MDM Forward 4'
    iua: 18
    busPri: 'OI1'
    busSec: 'OI2'
    iom: [ 'DIL', # Card 0
           'AIS', # Card 1
                  #   Channel 19:
                  #                 FCP NO 1 SUBSTACK 1 DELTA VOLTAGE  V45V0102A1
                  #   Channel 21:
                  #                 FCP NO 1 SUBSTACK 2 DELTA VOLTAGE  V45V0103A1
                  #   Channel 22:
                  #                 FCP NO 1 SUBSTACK 3 DELTA VOLTAGE  V45V0104A1
           'DIH', # Card 2
                  #   Channel 01: V73S2012E CRT 2: STBY STATUS
                  #   Channel 02:
                  #                 PRSD FCP 3 O2 REAC VLV-OPEN        V45X1160E1
                  #                 SMOKE DETECTOR-A AV BAY-1          V62X0620E1
           'DIL', # Card 3
                  #   Channel 02:
                  #                 RCDR OPS 2 BITE                    V75X2629E1
                  #                 RCDR OPS 2 TAPE MOTION             V75X2623E1
           'DIH', # Card 4
                  #   Channel 01:
                  #                 V74X4890E PSP 1: PWR STATUS
                  #                 V73S2021E CRT 3: PWR STATUS
                  #                 FUEL CELL NO 1 COOLANT PUMP STATUS V45X0143E1
                  #   Channel 02:
                  #                 PRSD H2 MANF 1 ISLN VLV-OPEN       V45X2141E1
                  #                 SMOKE DETECTOR-B AV BAY-1          V62X0621E1
                  #                 FUEL CELL 1 TO ESS BUS 1BC-ON      V76S0163E1
           'DIH', # Card 5
                  #   Channel 01: V73S2022E CRT 3: STBY STATUS
                  #   Channel 02:
                  #                 V74X4891E PSP 2: PWR STATUS
                  #                 PRSD H2 MANF 2 ISLN VLV-OPEN       V45X2146E1
                  #                 FIRE BOTTLE AV BAY 2 FULL/EMPTY    V62X0622E1
                  #                 ACCEL ASSY 1 PWR ON CMD A          V79S2004E1
           'AIS', # Card 6
                  #   Channel 04:
                  #                 APU 1 FUEL PUMP DRAIN LINE PRESS 1 V46P0190A1
                  #   Channel 05:
                  #                 APU 2 FUEL PUMP DRAIN LINE PRESS 1 V46P0290A1
                  #   Channel 06:
                  #                 APU 3 FUEL PUMP DRAIN LINE PRESS 1 V46P0390A1
           'DIH', # Card 7
                  #   Channel 00:
                  #                 FUEL CELL NO 2 COOLANT PUMP STATUS V45X0243E1
                  #                 SMOKE DET-RTN AIR TO CAB HX        V62X0596E1
                  #   Channel 01:
                  #                 SMOKE DETECTOR-LEFT FLIGHT DECK    V62X0606E1
                  #   Channel 02:
                  #                 PRSD FCP 1 H2 REAC VLV-OPEN        V45X2150E1
                  #                 SMOKE DETECTOR-A AV BAY 3          V62X0630E1
                  #                 FUEL CELL 2 TO ESS BUS 2CA-ON      V76S0263E1
           'DIL', # Card 8 (UNUSED)
           'AIS', # Card 9
                  #   Channel 04:
                  #                 APU 1 FUEL PUMP DRAIN LINE PRESS 2 V46P0191A1
                  #   Channel 05:
                  #                 APU 2 FUEL PUMP DRAIN LINE PRESS 2 V46P0291A1
                  #   Channel 06:
                  #                 APU 3 FUEL PUMP DRAIN LINE PRESS 2 V46P0391A1
                  #   Channel 16:
                  #                 ME-1 AFV DOWNSTREAM TEMP #2        E41T1156A1
                  #   Channel 17:
                  #                 ME-3 AFV DOWNSTREAM TEMP #1        E41T3155A1
           'DIH', # Card 10
                  #   Channel 00:
                  #                 PRSD O2 MANF 1 ISLN VLV-OPEN       V45X1141E1
                  #   Channel 01:
                  #                 SMOKE DETECTOR-RIGHT FLIGHT DECK   V62X0607E1
                  #   Channel 02:
                  #                 PRSD FCP 2 H2 REAC VLV-OPEN        V45X2155E1
                  #                 SMOKE DETECTOR-B AV BAY 3          V62X0631E1
           'AIS', # Card 11
                  #  Channel 00:
                  #                 PRSD O2 TK 7 PRESS                 D45V320011
                  #  Channel 01:
                  #                 PRSD O2 TK 9 PRESS                 D45V340011
                  #  Channel 02:
                  #                 PRSD H2 TK 7 PRESS                 D45V420011
                  #  Channel 03:
                  #                 PRSD H2 TK 9 PRESS                 D45V440011
           'DIH', # Card 12
                  #   Channel  0:
                  #                 PRSD O2 MANF 2 ISLN VLV-OPEN       V45X1146E1
                  #   Channel  1:
                  #                 FUEL CELL NO 3 COOLANT PUMP STATUS V45X0343E1
                  #                 SMOKE DETECTOR-A AV BAY-2          V62X0610E1
                  #   Channel  2:
                  #                 PRSD FCP 3 H2 REAC VLV-OPEN        V45X2160E1
                  #                 FIRE BOTTLE AV BAY 3 FULL/EMPTY    V62X0632E1
                  #                 FUEL CELL 3 TO ESS BUS 3AB-ON      V76S0363E1
           'DIH', # Card 13
                  #   Channel  0:
                  #                 PRSD FCP 1 O2 REAC VLV-OPEN        V45X1150E1
                  #   Channel  1:
                  #                 SMOKE DETECTOR-B AV BAY-2          V62X0611E1
           'AIS', # Card 14
           'DIH'  # Card 15
                  #   Channel  0:
                  #                 FIRE BOTTLE AV BAY 1 FULL/EMPTY    V62X0612E1
                  #                 ACCEL ASSY 2 PWR ON CMD B          V79S2007E1
                  #   Channel  1:
                  #                 PRSD FCP 2 O2 REAC VLV-OPEN        V45X1155E1
    ]
  OA1:
    id: 'OA1'
    nom: 'OI MDM Aft 1'
    iua: 10
    busPri: 'OI1'
    busSec: 'OI2'
    iom: [ 'AIS', # Card 0
                  #   Channel 10:
                  #                 APU 3 GEARBOX LUBE OIL OUT TEMP    V46T0354A1
                  #   Channel 15:
                  #                 APU 1 GEARBOX LUBE OIL RETURN TEMP V46T0150A1
                  #   Channel 16:
                  #                 NH3 SYS A TANK PRESS               V63P1196A1
                  #   Channel 18:
                  #                 MPS E3 AFT FUSELAGE HE SUPPLY TEMP V41T1351A1
                  #   Channel 21:
                  #                 MPS E1 MID FUSELAGE HE SUPPLY TEMP V41T1152A1
                  #   Channel 23:
                  #                 ME-1 OPOV LOX SUPPLY LINE TEMP #1  E41T1151A1
           'DIH', # Card 1
                  #   Channel 00:
                  #                 AFT MCA 1 OPERATIONAL STATUS 1     V76X2251E1
                  #                 HYD SYS 1 LDG/NWS ISLN VLV CL IND  V58X0199E1
                  #                 MPS LH2 INBD F/D VLV CL PWR (LV35) V41X1405E1
                  #                 MPS LO2 FDLN RLF SOV (PV7) CL IND  V41X1542E1
                  #                 MPS E1 LO2 PREVLV CL PWR 1 (LV13)  V41X1132E1
                  #                 MPS E1 HE ISO VLV A (LV1) OP PWR   V41X1158E1
                  #                 BODY FLAP ENABLE 1 OUTPUT          V79X3201E1
                  #                 MPS E3 LO2 PREVLV (PV3) CL IND     V41X1335E1
                  #                 MPS E3 LH2 PREVLV (PV6) CL IND     V41X1305E1
                  #   Channel 01:
                  #                 MPS LH2 RTLS OTBD DV (PV18) OP IND V41X1917E1
                  #                 MPS LH2 RTLS INBD DV (PV17) OP IND V41X1927E1
                  #                 PCA-MPS LH2 PREVLV 3 CL RPC A ON   V76X4126E1
                  #                 PRSD O2 TK 3 HTR A1-ON (MBK)       V45X1306E1
                  #                 PCA HYDRAULIC PUMP 1 RPC A ON      V76X4020E1
                  #   Channel 02:
                  #                 PCA FLT CONT ASA 1 RPC A ON        V76X4201E1
                  #                 PCA FLT CONT RGA 1 RPC A ON        V76X4293E1
                  #                 PCA L SRB BUS C RPC A ON           V76X4399E1
                  #                 PRSD O2 TK 3 HTR B2-ON (MBK)       V45X1313E1
                  #                 APU 3 FUEL ISLN VLV B OPEN/PWR ON  V46X0334E1
           'AIS', # Card 2
                  #   Channel 00:
                  #                 MPS ENG 3 PITCH SEC DELTA PRESS A  V58P1381A1
                  #   Channel 01:
                  #                 RUDDER DELTA PRESS 1               V57P0160A1
                  #   Channel 02:
                  #                 L INBD ELEVON SEC DELTA PRESS 1    V58P0812A1
                  #   Channel 03:
                  #                 R INBD ELEVON SEC DELTA PRESS 1    V58P0912A1
                  #   Channel 04:
                  #                 LH DELTA PRESS SECONDARY A ROCK    B58P1311A1
                  #   Channel 05:
                  #                 RH DELTA PRESS SECONDARY A ROCK    B58P2311A1
                  #   Channel 06:
                  #                 MPS ENG 1 PITCH SEC DELTA PRESS A  V58P1181A1
                  #   Channel 07:
                  #                 MPS ENG 2 PITCH SEC DELTA PRESS A  V58P1281A1
                  #   Channel 11:
                  #                 MPS PNEU VLVS REG HE OUTLET PRESS  V41P1605A1
                  #   Channel 17:
                  #                 MPS E1 REG B HE OUTLET PRESS       V41P1153A1
                  #   Channel 18:
                  #                 MPS E2 REG B HE OUTLET PRESS       V41P1253A1
                  #   Channel 19:
                  #                 MPS E3 REG B HE OUTLET PRESS       V41P1353A1
                  #   Channel 20:
                  #                 RUDDER ACTR CHAN 1 POSN            V57H0150A
                  #   Channel 25:
                  #                 HYD SYS 1 BOOTSTRAP ACCUM GN2 P    V58P0167A1
                  #   Channel 26:
                  #                 APU 1 GN2 BOTTLE PRESS             V46P0152A1
                  #   Channel 27:
                  #                 HYD SYS 1 CIRC PUMP PRESS          V58P0137A1
                  #   Channel 29:
                  #                 HYD SYS 1 RSVR FLUID PRESS         V58P0131A1
           'DIL', # Card 3
                  #   Channel 01:
                  #
                  #
                  #   Channel 02:
                  #
                  #
                  #
                  #
           'AIS', # Card 4
                  #   Channel 18:
                  #                 APU-1 GEARBOX LUBE OIL OUT PRESS   V46P0153A1
                  #   Channel 20:
                  #                 APU 3 GEARBOX BEARING TEMP NO2     V46T0362A1
           'DIH', # Card 5
                  #   Channel 00:
                  #                 PRSD O2 TK 3 HTR CUR SNSR 1A-TRIP  V45X1385E1
                  #                 PCA FLT CONT ATVC 4 RPC A ON       V76X4292E1
                  #                 PCA HYDRAULIC PUMP 3 RPC A ON      V76X4028E1
                  #   Channel 01:
                  #                 PCA FLT CONT RGA 4 RPC A ON        V76X4295E1
                  #                 PCA R SRB BUS C RPC A ON           V76X4390E1
                  #                 PRSD H2 TK 3 HTR A-ON (MBK)        V45X2306E1
                  #                 PCA APU CONTROLLER 1 RPC A ON      V76X4001E1
                  #   Channel 02:
                  #                 PCA FLT CONT ASA 2 RPC 3 ON        V76X4206E1
                  #                 L SRB BUS A BU PWR ON              V76X6775E1
                  #                 R SRB BUS A BU PWR ON              V76X6776E1
           'AIS', # Card 6
                  #   Channel 00:
                  #                 SPEED BRAKE DELTA PRESS 1          V57P0260A1
                  #   Channel 01:
                  #                 L OUTBD ELEVON SEC DELTA PRESS 1   V58P0862A1
                  #   Channel 02:
                  #                 R OUTBD ELEVON SEC DELTA PRESS 1   V58P0962A
                  #   Channel 03:
                  #                 LH DELTA PRESS SECONDARY A TILT    B58P1315A1
                  #   Channel 04:
                  #                 RH DELTA PRESS SECONDARY A TILT    B58P2315A1
                  #   Channel 05:
                  #                 MPS ENG 1 YAW SEC DELTA PRESS A    V58P1186A1
                  #   Channel 06:
                  #                 MPS ENG 2 YAW SEC DELTA PRESS A    V58P1286A1
                  #   Channel 07:
                  #                 MPS ENG 3 YAW SEC DELTA PRESS A    V58P1386A
                  #   Channel 11:
                  #                 APU 1 TURBINE SPEED                V46R0135A1
                  #   Channel 14:
                  #                 APU-1 GEARBOX GN2 PRESS            V46P0151A1
                  #   Channel 17:
                  #                 MPS PNEU VLVS HE SUP BOTTLE PRESS  V41P1600A1
                  #   Channel 19:
                  #                 HYD SYS 1 RSVR FLUID VOLUME        V58Q0102A1
                  #   Channel 22:
                  #                 DRAG CHUTE DEPLOY 1 CAP VOLTS      V76V0940A1
           'DIH', # Card 7
                  #   Channel 00:
                  #                 AFT MCA 1 OPERATIONAL STATUS 3     V76X2253E1
                  #                 AFT MCA 1 OPERATIONAL STATUS 4     V76X2254E1
                  #                 MEC 2 CORE B RPC A ON              V76X4397E1
                  #                 MPS LO2 FDLN RLF SOV (PV7) OP IND  V41X1541E1
                  #                 MPS E1 LH2 PREVLV OP PWR (LV18)    V41X1103E1
                  #                 MPS E1 LO2 PREVLV OP PWR 1 (LV12)  V41X1133E1
                  #                 MPS PNEU HE ISO VLV 1 (LV7) OP PWR V41X1645E1
                  #                 MPS HE SPLY BLWDWN 1 (LV26) OP PWR V41X1632E1
                  #                 MPS GH2 PRESS FCV 1 (LV56) CL PWR  V41X1661E1
                  #                 BODY FLAP DOWN 1 OUTPUT            V79X3203E1
                  #                 MPS LO2 POGO RECRC 1 (PV20) CL IND V41X1818E1
                  #   Channel 01:
                  #                 PRSD O2 TK 3 HTR CUR SNSR 2A-TRIP  V45X1386E1
                  #                 PCA-MPS LH2 PREVLV 1 OP RPC A ON   V76X4110E1
                  #                 MPS E3 HE INTCN IN (LV63) OP PWR   V41X1364E1
                  #                 PRSD O2 TK 3 HTR B1-ON (MBK)       V45X1308E1
                  #                 APU 1 FUEL ISLN VLV A OPEN/PWR ON  V46X0115E1
                  #   Channel 02:
                  #                 PCA FLT CONT ATVC 1 RPC A ON       V76X4285E1
                  #                 PCA APU CONTROLLER 3 RPC A ON      V76X4007E1
           'DIL', # Card 8
                  #   Channel 02:
                  #              PRSD O2 TK 5 HTR CUR SNSR 1A TRIP  V45X1585E1
                  #              PRSD O2 TK 5 HTR CUR SNSR 1B TRIP  V45X1587E1
           'AIS', # Card 9
                  #   Channel 02:
                  #                 NH3 SYS B TANK TEMP                V63T1188A1
                  #   Channel 05:
                  #                 PRSD O2 TK 8 HTR CONT PRESS        D45V331011
                  #   Channel 21:
                  #                 PRSD H2 TK 8 HTR CONT PRESS        D45V431011
           'DIH', # Card 10
                  #   Channel 00:
                  #                 AFT MCA 1 OPERATIONAL STATUS 2     V76X2252E1
                  #                 MPS LH2 INBD F/D VLV OP PWR (LV34) V41X1406E1
                  #                 MPS E1 LH2 PREVLV CL PWR (LV19)    V41X1102E1
                  #                 MPS E3 LO2 PREVLV CL PWR 2 (LV82)  V41X1344E1
                  #                 MPS E3 HE ISO VLV B (LV6) OP PWR   V41X1359E1
                  #                 MPS HE SPLY BLWDWN 2 (LV27) OP PWR V41X1634E1
                  #                 BODY FLAP UP 1 OUTPUT              V79X3202E1
                  #                 MPS LH2 HI PT BL VLV (PV22) CL IND V41X1469E1
                  #   Channel 01:
                  #                 PCA FLT CONT ATVC 3 RPC A ON       V76X4289E1
                  #                 PCA-MPS LH2 PREVLV 1 CL RPC A ON   V76X4113E1
                  #                 PRSD H2 TK 3 HTR B-ON (MBK)        V45X2308E1
                  #   Channel 02:
                  #                 PRSD O2 TK 3 HTR CUR SNSR 1B-TRIP  V45X1387E1
                  #                 PCA FLT CONT ASA 4 RPC A ON        V76X4211E1
           'AIS', # Card 11
                  #   Channel 00:
                  #                 L INBD ELEVON ACTR CHAN 1 POSN     V58H0802A1
                  #   Channel 01:
                  #                 R INBD ELEVON ACTR CHAN 1 POSN     V58H0902A1
                  #   Channel 08:
                  #                 SPEED BRAKE ACTR CHAN 1 POSN       V57H0250A1
                  #   Channel 21:
                  #                 MPS ENG 3 P ACTR POSN              V58H1300A1
                  #   Channel 22:
                  #                 MPS ENG 1 Y ACTR POSN              V58H1150A1
                  #   Channel 23:
                  #                 MPS ENG 2 Y ACTR POSN              V58H1250A1
                  #   Channel 24:
                  #                 MPS ENG 2 P ACTR POSN              V58H1200A1
                  #   Channel 25:
                  #                 MPS ENG 3 Y ACTR POSN              V58H1350A
                  #   Channel 26:
                  #                 PS ENG 1 P ACTR POSN              V58H1100A1

           'DIH', # Card 12
                  #   Channel 00:
                  #                 PRSD O2 TK 3 HTR CUR SNSR 2B-TRIP  V45X1388E1
                  #                 MPS E1 HE INTCN OUT (LV60) OP PWR  V41X1170E1
                  #                 MPS LH2 RTLS REPRSS 2(LV75) OP PWR V41X1902E1
                  #   Channel 01:
                  #                 PCA FLT CONT ASA 3 RPC A ON        V76X4208E1
                  #                 PRSD O2 TK 3 HTR A2-ON (MBK)       V45X1311E1
                  #   Channel 02:
                  #                 PCA-MPS LH2 PREVLV 3 OP RPC A ON   V76X4123E1
                  #                 MPS E1 LO2 PREVLV OP PWR 2 (LV83)  V41X1145E1
           'AIS', # Card 13
                  #   Channel 02:
                  #                 ME-1 MFV DOWNSTREAM TEMP #2        E41T1154A1
                  #   Channel 11:
                  #                 APU 1 GEARBOX BEARING TEMP NO1     V46T0161A1
                  #   Channel 15:
                  #                 FCL 1 COLDPLATE NETWORK FLOWRATE   V63R1105A1
                  #   Channel 16:
                  #                 MPS LH2 17IN FEED MANF DISC TEMP   V41T1428A1
                  #   Channel 25:
                  #                 ME-1 OPOV LOX SUPPLY LINE TEMP #2  E41T1152A1
           'DIL', # Card 14
                  #   Channel 00:
                  #
                  #
                  #
           'AIS'  # Card 15
                  #   Channel 06:
                  #                 HYDR SYS 2 SUPPLY PRESS B          V58P0215A1
                  #   Channel 20:
                  #                 L OUTBD ELEVON ACTR CHAN 1 POSN    V58H0852A1
                  #   Channel 21:
                  #                 R OUTBD ELEVON ACTR CHAN 1 POSN    V58H0952A1

    ]
  OA2:
    id: 'OA2'
    nom: 'OI MDM Aft 2'
    iua: 6
    busPri: 'OI1'
    busSec: 'OI2'
    iom: [ 'AIS', # Card 0
                  #   Channel 10:
                  #                 APU 1 GEARBOX LUBE OIL OUT TEMP    V46T0154A1
                  #   Channel 14:
                  #                 L INBD ELEVON ACTR CHAN 2 POSN     V58H0803A1
                  #   Channel 15:
                  #                 APU 2 GEARBOX LUBE OIL RETURN TEMP V46T0250A1
                  #   Channel 18:
                  #                 MPS E1 AFT FUSELAGE HE SUPPLY TEMP V41T1151A1
                  #   Channel 19:
                  #                 MPS E2 MID FUSELAGE HE SUPPLY TEMP V41T1252A1
                  #   Channel 20:
                  #                 ME-2 OPOV LOX SUPPLY LINE TEMP #1  E41T2151A1
           'DIH', # Card 1
                  #   Channel 00:
                  #                 AFT MCA 2 OPERATIONAL STATUS 2     V76X2262E1
                  #                 MPS LO2 17IN DISC VLV OP PWR(LV46) V41X1807E1
                  #                 MPS LO2 17IN DISC LOCK PWR(LV65)   V41X1808E1
                  #                 MPS E2 LO2 PREVLV CL PWR 1 (LV15)  V41X1232E1
                  #                 MPS E2 HE ISO VLV A (LV3) OP PWR   V41X1258E1
                  #                 MPS LH2 MANF REPRSS 2(LV43) OP PWR V41X1438E1
                  #                 MPS LO2 INBD F/D VLV CL PWR (LV31) V41X1505E1
                  #                 BODY FLAP ENABLE 2 OUTPUT          V79X3204E1
                  #                 MPS E1 LO2 PREVLV (PV1) CL IND     V41X1135E1
                  #                 MPS E1 LH2 PREVLV (PV4) CL IND     V41X1105E1
                  #                 MPS LO2 OVBD B/V (PV19) OP IND     V41X1587E1
                  #                 MPS E1 LO2 PREVLV (PV1) CL IND     V41X1135E1
                  #   Channel 01:
                  #                 MID MCA 4 OPERATIONAL STATUS 5     V76X2245E1
                  #                 MID MCA 4 OPERATIONAL STATUS 6     V76X2246E1
                  #                 MID MCA 4 OPERATIONAL STATUS 7     V76X2247E1
                  #                 MID MCA 4 OPERATIONAL STATUS 8     V76X2248E1
                  #                 PCA-MPS LH2 FEED D/V OP RPC B ON   V76X4186E1
                  #                 PRSD O2 TK 4 HTR A1-ON (MBK)       V45X1406E1
                  #                 PCA HYDRAULIC PUMP 1 RPC B ON      V76X4021E1
                  #   Channel 02:
                  #                 PRSD O2 TK 4 HTR CUR SNSR 2A-TRIP  V45X1486E1
                  #                 PCA FLT CONT ASA 1 RPC B ON        V76X4202E1
                  #                 APU 1 FUEL ISLN VLV B OPEN/PWR ON  V46X0134E1
           'AIS', # Card 2
                  #   Channel 00:
                  #                 MPS ENG 3 PITCH SEC DELTA PRESS B  V58P1382A1
                  #   Channel 01:
                  #                 RUDDER DELTA PRESS 2               V57P0161A1
                  #   Channel 02:
                  #                 L INBD ELEVON SEC DELTA PRESS 2    V58P0813A1
                  #   Channel 03:
                  #                 R INBD ELEVON SEC DELTA PRESS 2    V58P0913A1
                  #   Channel 04:
                  #                 LH DELTA PRESS SECONDARY B ROCK    B58P1312A1
                  #   Channel 05:
                  #                 RH DELTA PRESS SECONDARY B ROCK    B58P2312A1
                  #   Channel 06:
                  #                 MPS ENG 1 PITCH SEC DELTA PRESS B  V58P1182A1
                  #   Channel 07:
                  #                 MPS ENG 2 PITCH SEC DELTA PRESS B  V58P1282A1
                  #   Channel 08:
                  #
                  #   Channel 09:
                  #                 HYD SYS 2 RSVR FLUID PRESS         V58P0231A1
                  #   Channel 17:
                  #
           'DIL', # Card 3
                  #   Channel 02:
           'AIS', # Card 4
                  #   Channel 05:
                  #   Channel 11:
                  #                 FCL 1 EVAP OUT TEMP                V63T1207A1
                  #   Channel 13:
                  #                 L OUTBD ELEVON ACTR CHAN 2 POSN    V58H0853A1
                  #   Channel 17:
                  #                 APU 1 GEARBOX BEARING TEMP NO2     V46T0162A1
                  #   Channel 21:
                  #                 ME-2 AFV DOWNSTREAM TEMP #1        E41T2155A1
           'DIH', # Card 5
                  #   Channel 00:
                  #                 PRSD O2 TK 4/5 HTR CUR SNSR 1B/1A  V45X1487E1
                  #                 PAYLOAD AFT MAIN B PWR-ON          V76X2810E1
                  #                 MPS-LH2 FD DISC LOCK VLV RPC B ON  V76X4430E1
                  #                 PCA HYDRAULIC PUMP 2 RPC B ON      V76X4024E1
                  #                 PCA HYDRAULIC PUMP 2 RPC B ON      V76X4024E1
                  #   Channel 01:
                  #                 CA-MPS LOX FEED D/V CL RPC B ON   V76X4199E1
                  #                 RSD O2 TK 4/5 HTR B1/A1-ON        V45X1408E1
                  #                 CA APU CONTROLLER 1 RPC B ON      V76X4002E1
                  #   Channel 02:
                  #                 PCA FLT CONT ASA 2 RPC B ON        V76X4204E1
                  #                 L SRB BUS B BU PWR ON              V76X6777E1
                  #                 R SRB BUS B BU PWR ON              V76X6778E1
                  #                 MEC 1 CORE B RPC B ON              V76X4395E1
                  #                 PCA-MPS LH2 PREVLV 2 CL RPC B ON   V76X4119E1
           'AIS', # Card 6
                  #   Channel 00:
                  #                 SPEED BRAKE DELTA PRESS 2          V57P0261A1
                  #   Channel 01:
                  #                 L OUTBD ELEVON SEC DELTA PRESS 2   V58P0863A1
                  #   Channel 02:
                  #                 R OUTBD ELEVON SEC DELTA PRESS 2   V58P0963A1
                  #   Channel 03:
                  #                 LH DELTA PRESS SECONDARY B TILT    B58P1316A1
                  #   Channel 04:
                  #                 RH DELTA PRESS SECONDARY B TILT    B58P2316A1
                  #   Channel 05:
                  #                 MPS ENG 1 YAW SEC DELTA PRESS B    V58P1187A1
                  #   Channel 06:
                  #                 MPS ENG 2 YAW SEC DELTA PRESS B    V58P1287A1
                  #   Channel 07:
                  #                 MPS ENG 3 YAW SEC DELTA PRESS B    V58P1387A1
                  #   Channel 11:
                  #                 APU 2 TURBINE SPEED                V46R0235A1
                  #   Channel 14:
                  #                 APU-2 GEARBOX GN2 PRESS            V46P0251A1
                  #   Channel 15:
                  #                 HYD SYS 2 RSVR FLUID VOLUME        V58Q0202A1
                  #   Channel 17:
                  #                 MPS PNEU ACCUMULATOR PRESSURE      V41P1650A1
                  #   Channel 19:
                  #
                  #   Channel 20:
                  #                 APU 2 GN2 BOTTLE PRESS             V46P0252A1
                  #   Channel 21:
                  #                 APU 3 GN2 BOTTLE PRESS             V46P0352A1
                  #   Channel 22:
                  #                 DRAG CHUTE DEPLOY 2 CAP VOLTS      V76V0946A1
                  #   Channel 26:
                  #                 HYD SYS 2 CIRC PUMP PRESS          V58P0237A1
                  #   Channel 27:
                  #                 HYD SYS 2 BOOTSTRAP ACCUM GN2 P    V58P0267A1
           'DIH', # Card 7
                  #   Channel 00:
                  #                 AFT MCA 2 OPERATIONAL STATUS 1     V76X2261E1
                  #                 MPS LH2 17IN DISC VLV OP PWR(LV48) V41X1382E1
                  #                 MPS LH2 17IN DISC LOCK PWR(LV67)   V41X1383E1
                  #                 MPS LO2 17IN DISC VLV CL PWR(LV47) V41X1806E1
                  #                 MPS E2 LH2 PREVLV OP PWR (LV20)    V41X1203E1
                  #                 MPS E2 LO2 PREVLV OP PWR 1 (LV14)  V41X1233E1
                  #                 MPS PNEU HE ISO VLV 2 (LV8) OP PWR V41X1646E1
                  #                 MPS GH2 PRESS FCV 2 (LV57) CL PWR  V41X1662E1
                  #                 BODY FLAP DOWN 2 OUTPUT            V79X3206E1
                  #   Channel 01:
                  #                 PRSD O2 TK 4/5 HTR CUR SNSR 2B/2A  V45X1488E1
                  #                 PCA FLT CONT ATVC 1 RPC B ON       V76X4286E1
                  #                 MPS-LO2 FD DISC LOCK VLV RPC B ON  V76X4420E1
                  #                 PCA-MPS LH2 PREVLV 1 OP RPC B ON   V76X4111E1
                  #                 MPS E1 HE INTCN IN (LV59) OP PWR   V41X1164E1
                  #                 APU 2 FUEL ISLN VLV A OPEN/PWR ON  V46X0215E1
                  #   Channel 02:
                  #                 PCA-MPS LOX FEED D/V OP RPC B ON   V76X4196E1
                  #                 PRSD O2 TK 4 HTR A2-ON (MBK)       V45X1411E1
                  #                 PCA APU CONTROLLER 2 RPC B ON      V76X4004E1
           'DIL', # Card 8
                  #   Channel 02:
           'AIS', # Card 9
                  #   Channel 02:
                  #                 NH3 SYS A TANK TEMP                V63T1180A1
                  #   Channel 05:
                  #                 R INBD ELEVON ACTR CHAN 2 POSN     V58H0903A1
                  #   Channel 12:
                  #                 APU 2 GEARBOX BEARING TEMP NO1     V46T0261A1
                  #   Channel 15:
                  #                 APU-2 GEARBOX LUBE OIL OUT PRESS   V46P0253A1
           'DIH', # Card 10
                  #   Channel 00:
                  #                 AFT MCA 2 OPERATIONAL STATUS 3     V76X2263E1
                  #                 AFT MCA 2 OPERATIONAL STATUS 4     V76X2264E1
                  #                 MPS LH2 17IN DISC VLV CL PWR(LV49) V41X1381E1
                  #                 MPS E2 LH2 PREVLV CL PWR (LV21)    V41X1202E1
                  #                 MPS E1 LO2 PREVLV CL PWR 2 (LV80)  V41X1144E1
                  #                 MPS E1 HE ISO VLV B (LV2) OP PWR   V41X1159E1
                  #                 MPS LH2 MANF REPRSS 1(LV42) OP PWR V41X1436E1
                  #                 MPS LO2 INBD F/D VLV OP PWR (LV30) V41X1506E1
                  #                 BODY FLAP UP 2 OUTPUT              V79X3205E1
                  #                 MPS LO2 POGO RECRC 2 (PV21) CL IND V41X1828E1
                  #                 BODY FLAP UP 2 OUTPUT              V79X3205E1
                  #                 BODY FLAP UP 2 OUTPUT              V79X3205E1
                  #   Channel 01:
                  #                 PCA FLT CONT ATVC 2 RPC B ON       V76X4287E1
                  #                 PCA-MPS LH2 PREVLV 1 CL RPC B ON   V76X4114E1
                  #                 PRSD H2 TK 4(&5) HTR A-ON          V45X2456E1
                  #                 PRSD O2 TK 4/5 HTR B2/A2-ON        V45X1413E1
                  #   Channel 02:
                  #                 MPS PT SENSOR ELEC RPC B ON        V76X3050E1
           'AIS', # Card 11
                  #   Channel 02:
                  #                 HYDR SYS 1 SUPPLY PRESS B          V58P0115A1
                  #   Channel 28:
                  #                 RUDDER ACTR CHAN 2 POSN            V57H0151A1
           'DIH', # Card 12
                  #   Channel 00:
                  #                 MPS-LO2 FD DISC UNLOCK V RPC B ON  V76X4422E1
                  #                 PCA-MPS LH2 PREVLV 2 OP RPC B ON   V76X4116E1
                  #                 PRSD H2 TK 4(&5) HTR B-ON          V45X2458E1
                  #   Channel 01:
                  #                 PCA FLT CONT ASA 3 RPC 3 ON        V76X4209E1
                  #                 MPS-LH2 FD DISC UNLOCK V RPC B ON  V76X4432E1
                  #   Channel 02:
                  #                 PRSD O2 TK 4 HTR CUR SNSR 1A-TRIP  V45X1485E1
                  #                 PCA-MPS LH2 FEED D/V CL RPC B ON   V76X4189E1
                  #                 MPS E2 LO2 PREVLV OP PWR 2 (LV84)  V41X1245E1
                  #                 MPS E2 HE INTCN OUT (LV62) OP PWR  V41X1270E1
           'AIS', # Card 13
                  #   Channel 14:
                  #                 R OUTBD ELEVON ACTR CHAN 2 POSN    V58H0953A1
                  #   Channel 27:
                  #
                  #   Channel 28:
                  #                 ME-2 OPOV LOX SUPPLY LINE TEMP #2  E41T2152A1
                  #   Channel 29:
                  #                 ME-2 MFV DOWNSTREAM TEMP #2        E41T2154A1
           'DIL', # Card 14
           'AIS'  # Card 15
                  #   Channel 18:
                  #                 SPEED BRAKE ACTR CHAN 2 POSN       V57H0251A1
    ]
  OA3:
    id: 'OA3'
    nom: 'OI MDM Aft 3'
    iua: 9
    busPri: 'OI1'
    busSec: 'OI2'
    iom: [ 'AIS', # Card 0
                  #   Channel 10:
                  #                 APU 2 GEARBOX LUBE OIL OUT TEMP    V46T0254A1
                  #   Channel 16:
                  #                 APU 3 GEARBOX LUBE OIL RETURN TEMP V46T0350A1
                  #   Channel 20:
                  #                 ME-2 AFV DOWNSTREAM TEMP #2        E41T2156A1
                  #   Channel 22:
                  #                 L INBD ELEVON ACTR CHAN 3 POSN     V58H0804A1
                  #   Channel 23:
                  #                 R OUTBD ELEVON ACTR CHAN 4 POSN    V58H0955A1
                  #   Channel 24:
                  #                 NH3 SYS B TANK PRESS               V63P1197A1
                  #   Channel 25:
                  #              PRSD O2 TK 9 HTR CONT PRESS           V45P3410A
                  #                 PRSD O2 TK 9 HTR CONT PRESS        D45V341011
                  #   Channel 28:
                  #
                  #   Channel 29:
                  #              PRSD H2 TK 9 HTR CONT PRESS           V45X4410A
                  #                 PRSD H2 TK 9 HTR CONT PRESS        D45V441011
           'DIH', # Card 1
                  #   Channel 00:
                  #                 AFT MCA 3 OPERATIONAL STATUS 1     V76X2271E1
                  #                 MPS LH2 4IN DISC VLV OP PWR (LV50) V41X1440E1
                  #                 MPS LO2 17IN DISC UNLOCK PWR(LV66) V41X1809E1
                  #                 MPS LH2 FDLN RLF SOV (PV8)CL PWR   V41X1449E1
                  #                 MPS E3 HE ISO VLV A (LV5) OP PWR   V41X1358E1
                  #                 MPS REG HE XOVER VLV (LV10) OP PWR V41X1614E1
                  #                 MPS GH2 PRESS FCV 3 (LV58) CL PWR  V41X1663E1
                  #                 BODY FLAP ENABLE 3 OUTPUT          V79X3207E1
                  #                 MPS GH2 PRESS FCV 3 (LV58) CL PWR  V41X1663E1
                  #                 MPS E2 LO2 PREVLV (PV2) CL IND     V41X1235E1
                  #                 MPS E2 LH2 PREVLV (PV5) CL IND     V41X1205E1
                  #                 BODY FLAP ENABLE 3 OUTPUT          V79X3207E1
                  #   Channel 01:
                  #                 PAYLOAD AFT MAIN C PWR-ON          V76X2821E1
                  #                 MPS LO2 FDLN RLF SOV (PV7) CL PWR  V41X1549E1
                  #                 PCA-MPS LH2 PREVLV 3 OP RPC C ON   V76X4122E1
                  #                 MPS E2 LO2 PREVLV CL PWR 2 (LV81)  V41X1244E1
                  #                 PCA HYDRAULIC PUMP 2 RPC C ON      V76X4025E1
                  #                 PCA HYDRAULIC PUMP 2 RPC C ON      V76X4025E1
                  #              PAYLOAD AFT MAIN C PWR-ON             V45X2821E
                  #   Channel 02:
                  #                 PCA FLT CONT ASA 1 RPC 3 ON        V76X4203E1
                  #                 PCA-MPS LH2 FEED D/V OP RPC C ON   V76X4187E1
                  #                 MPS-LH2 FD DISC LOCK VLV RPC C ON  V76X4431E1
                  #                 APU 2 FUEL ISLN VLV B OPEN/PWR ON  V46X0234E1
           'AIS', # Card 2
                  #   Channel 00:
                  #                 RUDDER DELTA PRESS 3               V57P0162A1
                  #   Channel 01:
                  #                 SPEED BRAKE DELTA PRESS 4          V57P0263A1
                  #   Channel 02:
                  #                 L INBD ELEVON SEC DELTA PRESS 3    V58P0814A1
                  #   Channel 03:
                  #                 L OUTBD ELEVON SEC DELTA PRESS 4   V58P0865A1
                  #   Channel 04:
                  #                 R INBD ELEVON SEC DELTA PRESS 3    V58P0914A1
                  #   Channel 05:
                  #                 R OUTBD ELEVON SEC DELTA PRESS 4   V58P0965A1
                  #   Channel 06:
                  #                 LH DELTA PRESS SECONDARY C ROCK    B58P1313A1
                  #   Channel 07:
                  #                 LH DELTA PRESS SECONDARY D TILT    B58P1318A1
                  #   Channel 08:
                  #                 RH DELTA PRESS SECONDARY C ROCK    B58P2313A1
                  #   Channel 09:
                  #                 RH DELTA PRESS SECONDARY D TILT    B58P2318A1
                  #   Channel 10:
                  #                 MPS ENG 1 PITCH SEC DELTA PRESS C  V58P1183A1
                  #   Channel 11:
                  #                 MPS ENG 1 YAW SEC DELTA PRESS D    V58P1189A1
                  #   Channel 12:
                  #                 MPS ENG 2 PITCH SEC DELTA PRESS C  V58P1283A1
                  #   Channel 13:
                  #                 MPS ENG 2 YAW SEC DELTA PRESS D    V58P1289A1
                  #   Channel 14:
                  #                 MPS ENG 3 PITCH SEC DELTA PRESS C  V58P1383A1
                  #   Channel 15:
                  #                 MPS ENG 3 YAW SEC DELTA PRESS D    V58P1389A1
                  #   Channel 16:
                  #              AFT PCA-6 VOLTAGE                     V45X3093A
                  #   Channel 19:
                  #                 HYD SYS 3 RSVR FLUID PRESS         V58P0331A1
                  #   Channel 23:
                  #              PAYLOAD AFT MAIN C CURRENT            V45X2822A
           'DIL', # Card 3
                  #   Channel 01:
                  #              PRSD O2 TK 3 ISO VENT VALVE CLOSE     V45X1393E
                  #              PRSD O2 TK 3 ISO FILL VALVE CLOSE     V45X1394E
                  #              PRSD O2 TK 8 VENT VALVE CLOSE         V45X3344E
                  #              PRSD O2 TK 8 FILL VALVE CLOSE         V45X3345E
                  #              PRSD O2 TK 9 VENT VALVE CLOSE         V45X3444E
                  #              PRSD O2 TK 9 FILL VALVE CLOSE         V45X3445E
                  #   Channel 02:
                  #              PRSD O2 TK 6 HTR A1-ON                V45X3106E
                  #              PRSD O2 TK 6 HTR A2-ON                V45X3111E
                  #              PRSD O2 TK 6 HTR CUR SNSR 1A-TRIP     V45X3185E
                  #              PRSD O2 TK 6 HTR CUR SNSR 1B-TRIP     V45X3187E
                  #              PRSD O2 TK 8 HTR A1-ON                V45X3306E
                  #              PRSD O2 TK 8 HTR A2-ON                V45X3311E
                  #              PRSD O2 TK 8 HTR CUR SNSR 1A-TRIP     V45X3385E
                  #              PRSD O2 TK 8 HTR CUR SNSR 1B-TRIP     V45X3387E
                  #              PRSD O2 TK 6 HTR A-ON                 V45X4106E
                  #              PRSD O2 TK 8 HTR A-ON                 V45X4306E
                  #              PALLET DSC 2 BITE                     V75X2185E
                  #
           'AIS', # Card 4
                  #   Channel 08:
                  #                 FCL 2 EVAP OUT TEMP                V63T1407A1
                  #   Channel 11:
                  #                 ME-2 MFV DOWNSTREAM TEMP #1        E41T2153A1
                  #   Channel 13:
                  #                 ME-3 MFV DOWNSTREAM TEMP #1        E41T3153A1
                  #   Channel 14:
                  #                 L OUTBD ELEVON ACTR CHAN 4 POSN    V58H0855A1
                  #   Channel 15:
                  #                 R INBD ELEVON ACTR CHAN 4 POSN     V58H0905A1
                  #   Channel 17:
                  #                 APU 2 GEARBOX BEARING TEMP NO2     V46T0262A1
                  #   Channel 29:
                  #                 ME-1 MFV DOWNSTREAM TEMP #1        E41T1153A1
           'DIH', # Card 5
                  #   Channel 00:
                  #                 PCA-MPS LH2 PREVLV 3 CL RPC C ON   V76X4125E1
                  #                 PCA HYDRAULIC PUMP 3 RPC C ON      V76X4027E1
                  #   Channel 01:
                  #                 PCA-MPS LOX FEED D/V CL RPC C ON   V76X4200E1
                  #                 PCA APU CONTROLLER 2 RPC C ON      V76X4005E1
                  #   Channel 02:
                  #                 PCA FLT CONT ASA 2 RPC C ON        V76X4205E1
                  #                 MEC 1 CORE B RPC C ON              V76X4396E1
                  #                 MPS LH2 RTLS REPRSS 1(LV74) OP PWR V41X1901E1
                  #                 PCA FLT CONT RGA 4 RPC C ON        V76X4296E1
           'AIS', # Card 6
                  #   Channel 00:
                  #                 RUDDER DELTA PRESS 4               V57P0163A1
                  #   Channel 01:
                  #                 SPEED BRAKE DELTA PRESS 3          V57P0262A1
                  #   Channel 02:
                  #                 L INBD ELEVON SEC DELTA PRESS 4    V58P0815A1
                  #   Channel 03:
                  #                 L OUTBD ELEVON SEC DELTA PRESS 3   V58P0864A1
                  #   Channel 04:
                  #                 R INBD ELEVON SEC DELTA PRESS 4    V58P0915A1
                  #   Channel 05:
                  #                 R OUTBD ELEVON SEC DELTA PRESS 3   V58P0964A1
                  #   Channel 06:
                  #                 LH DELTA PRESS SECONDARY D ROCK    B58P1314A1
                  #   Channel 07:
                  #                 LH DELTA PRESS SECONDARY C TILT    B58P1317A1
                  #   Channel 08:
                  #                 RH DELTA PRESS SECONDARY D ROCK    B58P2314A1
                  #   Channel 09:
                  #                 RH DELTA PRESS SECONDARY C TILT    B58P2317A1
                  #   Channel 10:
                  #                 MPS ENG 1 PITCH SEC DELTA PRESS D  V58P1184A1
                  #   Channel 11:
                  #                 MPS ENG 1 YAW SEC DELTA PRESS C    V58P1188A1
                  #   Channel 12:
                  #                 MPS ENG 2 PITCH SEC DELTA PRESS D  V58P1284A1
                  #   Channel 13:
                  #                 MPS ENG 2 YAW SEC DELTA PRESS C    V58P1288A1
                  #   Channel 14:
                  #                 MPS ENG 3 PITCH SEC DELTA PRESS D  V58P1384A1
                  #   Channel 15:
                  #                 MPS ENG 3 YAW SEC DELTA PRESS C    V58P1388A1
                  #   Channel 21:
                  #                 APU 3 TURBINE SPEED                V46R0335A1
                  #   Channel 24:
                  #                 APU-3 GEARBOX GN2 PRESS            V46P0351A
                  #   Channel 25:
                  #              AFT PCA MAIN BUS C AMPS               V76C3097A
                  #   Channel 26:
                  #                 HYD SYS 3 RSVR FLUID VOLUME        V58Q0302A1
           'DIH', # Card 7
                  #   Channel 00:
                  #              AFT MCA 3 OPERATIONAL STATUS 4        V76X2274E
                  #                 AFT MCA 3 OPERATIONAL STATUS 4     V76X2274E1
                  #                 MEC 2 CORE B RPC C ON              V76X4398E1
                  #                 MPS LH2 17IN DISC UNLOCK PWR(LV68) V41X1384E1
                  #                 MPS LH2 FDLN RLF SOV (PV8)OP IND   V41X1441E1
                  #                 MPS LH2 RTLS OTBD DV (PV18) OP PWR V41X1911E1
                  #                 MPS E3 LH2 PREVLV OP PWR (LV22)    V41X1303E1
                  #                 MPS E3 LO2 PREVLV OP PWR 1 (LV16)  V41X1333E1
                  #                 MPS LO2 MANF REPRSS 2(LV41) OP PWR V41X1539E1
                  #                 BODY FLAP DOWN 3 OUTPUT            V79X3209E1
                  #                 MPS LH2 4IN DISC VLV (PD3) CL IND  V41X1420E1
                  #                 MPS LH2 4IN DISC VLV (PD3) CL IND  V41X1420E1
                  #                 BODY FLAP DOWN 3 OUTPUT            V79X3209E1
                  #                 BODY FLAP DOWN 3 OUTPUT            V79X3209E1
                  #  Channel 01:
                  #                 PCA-MPS LOX FEED D/V OP RPC C ON   V76X4197E1
                  #                 MPS-LO2 FD DISC LOCK VLV RPC C ON  V76X4421E1
                  #                 PCA-MPS LH2 PREVLV 2 OP RPC C ON   V76X4117E1
                  #                 MPS E2 HE INTCN IN (LV61) OP PWR   V41X1264E1
                  #                 APU 3 FUEL ISLN VLV A OPEN/PWR ON  V46X0315E1
                  #  Channel 02:
                  #                 PCA FLT CONT ATVC 2 RPC C ON       V76X4288E1
                  #                 PCA APU CONTROLLER 3 RPC C ON      V76X4008E1
           'DIL', # Card 8
                  #   Channel 02:
                  #              PRSD O2 TK 5 HTR B1-ON
                  #                 PRSD O2 TK 5 HTR CUR SNSR 2A TRIP  V45X1586E1
           'AIS', # Card 9
                  #   Channel 13:
                  #                 APU-3 GEARBOX LUBE OIL OUT PRESS   V46P0353A1
                  #   Channel 14:
                  #                 APU 3 GEARBOX BEARING TEMP NO1     V46T0361A1
                  #   Channel 15:
                  #                 L OUTBD ELEVON ACTR CHAN 3 POSN    V58H0854A1
                  #   Channel 26:
                  #                 R INBD ELEVON ACTR CHAN 3 POSN     V58H0904A1
                  #   Channel 27:
                  #                 MPS E2 AFT FUSELAGE HE SUPPLY TEMP V41T1251A1
                  #   Channel 28:
                  #                 ME-3 OPOV LOX SUPPLY LINE TEMP #1  E41T3151A1
                  #   Channel 29:
                  #                 MPS E3 MID FUSELAGE HE SUPPLY TEMP V41T1352A1
           'DIH', # Card 10
                  #   Channel 00:
                  #                 AFT MCA 3 OPERATIONAL STATUS 2     V76X2272E1
                  #                 AFT MCA 3 OPERATIONAL STATUS 3     V76X2273E1
                  #                 MPS-LH2 FD DISC UNLOCK V RPC C ON  V76X4433E1
                  #                 MPS LH2 4IN DISC VLV CL PWR (LV51) V41X1439E1
                  #                 MPS-LO2 FD DISC UNLOCK V RPC C ON  V76X4423E1
                  #                 MPS LH2 FDLN RLF SOV (PV8)CL IND   V41X1442E1
                  #                 MPS LH2 RTLS INBD DV (PV17) OP PWR V41X1921E1
                  #                 MPS E3 LH2 PREVLV CL PWR (LV23)    V41X1302E1
                  #                 MPS E3 LO2 PREVLV OP PWR 2 (LV85)  V41X1345E1
                  #                 MPS E3 LO2 PREVLV CL PWR 1 (LV17)  V41X1332E1
                  #                 MPS E2 HE ISO VLV B (LV4) OP PWR   V41X1259E1
                  #                 MPS LO2 MANF REPRSS 1(LV40) OP PWR V41X1538E1
                  #                 BODY FLAP UP 3 OUTPUT              V79X3208E1
                  #                 BODY FLAP UP 3 OUTPUT              V79X3208E1
                  #                 BODY FLAP UP 3 OUTPUT              V79X3208E1
                  #  Channel 01:
                  #                 PCA FLT CONT ATVC 3 RPC C ON       V76X4290E1
                  #                 PCA-MPS LH2 PREVLV 2 CL RPC C ON   V76X4120E1
                  #  Channel 02:
                  #                 PCA FLT CONT ASA 4 RPC C ON        V76X4210E1
           'AIS', # Card 11
                  #   Channel 02:
                  #                 HYDR SYS 3 SUPPLY PRESS B          V58P0315A1
                  #   Channel 04:
                  #                 RUDDER ACTR CHAN 4 POSN            V57H0153A1
                  #   Channel 05:
                  #                 SPEED BRAKE ACTR CHAN 4 POSN       V57H0253A1
                  #   Channel 19:
                  #                 HYD SYS 3 CIRC PUMP PRESS          V58P0337A1
           'DIH', # Card 12
                  #   Channel 00:
                  #                 PCA FLT CONT ATVC 4 RPC C ON       V76X4291E1
                  #   Channel 01:
                  #                 PCA FLT CONT ASA 3 RPC C ON        V76X4207E1
                  #   Channel 02:
                  #                 PCA-MPS LH2 FEED D/V CL RPC C ON   V76X4190E1
                  #                 MPS PT SENSOR ELEC RPC C ON        V76X3055E1
                  #                 MPS E3 HE INTCN OUT (LV64) OP PWR  V41X1370E1
                  #                 PCA L SRB BUS C RPC C ON           V76X4393E1
                  #                 PCA R SRB BUS C RPC C ON           V76X4394E1
           'AIS', # Card 13
                  #   Channel 02:
                  #                 ME-3 MFV DOWNSTREAM TEMP #2        E41T3154A1
                  #   Channel 12:
                  #                 FCL 2 COLDPLATE NETWORK FLOWRATE   V63R1305A1
                  #   Channel 14:
                  #                 L INBD ELEVON ACTR CHAN 4 POSN     V58H0805A1
                  #   Channel 15:
                  #                 R OUTBD ELEVON ACTR CHAN 3 POSN    V58H0954A1

           'DIL', # Card 14
                  #   Channel 00:
                  #   Channel 01:
                  #                 FUEL CELL H2O CONDUCTIVITY         V45X0462E1
           'AIS'  # Card 15
                  #   Channel 00:
                  #                 RUDDER ACTR CHAN 3 POSN            V57H0152A1
                  #   Channel 01:
                  #                 SPEED BRAKE ACTR CHAN 3 POSN       V57H0252A1
                  #   Channel 19:
                  #                 HYD SYS 3 BOOTSTRAP ACCUM GN2 P    V58P0367A1
    ]
