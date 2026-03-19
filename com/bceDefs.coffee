
export bceElems = {
  # JSC-18819/p.231
  #
  0x00: { nom: "EIU 1" }                          # HFE IN: EIU 1
  0x01: { nom: "EIU 2" }                          # HFE IN: EIU 2
  0x02: { nom: "EIU 3" }                          # HFE IN: EIU 3

  0x04: { nom: "FA PROM - 24/MC" }                # HFE IN: FA PROM D
  0x05: { nom: "FF PROM - 24/MC" }                # HFE IN: FA PROM B
  0x06: { nom: "ADTA" }                           # HFE IN: ADTA
  0x07: { nom: "OMS/HYD" }                        # HFE IN: OMS PC/HYD PRESS
  0x08: { nom: "FF PROM - 6/MC" }                 # HFE IN: FF PROM A
  0x09: { nom: "TACAN/RA" }                       # HFE IN: TACAN/RA
  0x0a: { nom: "MSBLS" }              
  0x0b: { nom: "IMU" }                            # MFE IN: IMU

  0x0d: { nom: "STAR TRACKER" }
  0x0e: { nom: "RNDZ RADAR" }
  0x0f: { nom: "FA PROM - 6/MC" }                 # MFE IN: FA PROM C
  0x10: { nom: "MTU" }                            # MTU IN: ACCUM

  0x13: { nom: "NSP DISCRETES" }                  # NSP IN: DISCRETES
  0x14: { nom: "NSP DATA" }                       # NSP IN: DATA

  0x16: { nom: "FF RETURN WORD" }                 # HFE IN: FF RTN WD
  0x17: { nom: "FA RETURN WORD" }                 # HFE IN: FA RTN WD

  0x1f: { nom: "XFER DATA" }                      # HI/LO XFER DATA
  0x20: { nom: "PF1" }                            # LO IN PL 1 DATA
  0x21: { nom: "PF2" }                            # LO IN PL 2 DATA
  0x22: { nom: "BCE OUT OF BOUNDS" }              # ERROR CONDITION
  0x23: { nom: "GPS" }                            # PAYLOAD INPUT 1C

  0x28: { nom: "24/MN LSN CMD FC5-8  PRI PORT" }  # HFE IN: FA LSN CMD
  0x29: { nom: "24/MN LSN CMD FC1-4  PRI PORT" }  # HFE IN: FF LSN CMD

  0x2b: { nom: "6A/MC LSN CMD FC1-4  PRI PORT" }  # NSP IN: FF LSN CMD
  0x2c: { nom: "6B/MC LSN CMD FC5-8  PRI PORT" }  # MFE IN: FA LSN CMD
  0x2d: { nom: "6B/MC LSN CMD FC1-4  PRI PORT" }  # MFE IN: FF LSN CMD
  0x2f: { nom: "1B/MC LSN CMD FC1-4  PRI PORT" }  # MTU IN: FF LSN CMD
  0x30: { nom: "XFER LSN CMD FC5-8   PRI PORT" }  # HI/LO XFER IN: XFER LSN CMDS

  0x32: { nom: "24/MC LSN CMD FC5-8  SEC PORT" }  # HFE IN: FF LSN CMD
  0x33: { nom: "24/MC LSN CMD FC1-4  SEC PORT" }  # HFE IN: FA LSN CMD
  0x34: { nom: "6A/MC LSN CMD FC5-8  SEC PORT" }  # NSP IN: FF LSN CMD

  0x36: { nom: "6B/MC LSN CMD FC5-8  SEC PORT" }  # MFE IN: FF LSN CMD
  0x37: { nom: "6B/MC LSN CMD FC5-8  SEC PORT" }  # MFE IN: FA LSN CMD
  0x38: { nom: "1B/MC LSN CMD FC1-4  SEC PORT" }  # MTU IN: FF LSN CMD

  0x3a: { nom: "XFER LSN CMD FC5-8   SEC PORT" }  # HI/LO XFER IN: XFER LSN CMDS

  0x3c: { nom: "ONE SHOT XFER" }                  # PASS G9 ONE SHOT XFER DATA
  0x3d: { nom: "ENGAGE INIT INPUTS" }             # INPUT FF/FA OUTPUT DISCRETES
  0x3e: { nom: "LDB POLL" }                       # LDB INPUTS
  0x3f: { nom: "DEU POLL" }                       # DEU INPUTS
  0x40: { nom: "24/MC FC OUTPUT (HFE)" }          # HFE OUTPUTS
  0x41: { nom: "12/MC FC OUTPUT (DDU)" }          # MFE DDU OUTPUTS (TWICE/MC)
  0x42: { nom: "6B/MC FC OUTPUT (SPI)" }          # MFE SPI OUTPUTS
  0x43: { nom: "6B/MC PYLD OUTPUT" }              # MFE PL OUTPUT S
  0x44: { nom: "UPLINK RTC PL OUTPUT" }           # RTC OUTPUTS
  0x45: { nom: "UPLINK RTC PL OUTPUT" }           # RTC PL OUTPUTS
  0x46: { nom: "6C/MC GPS OUTPUT" }               # GPS OUTPUTS

  0x50: { nom: "PCM (NON OI)" }                   # PCM INPUTS
  0x51: { nom: "PCM OI -OA02" }                   # PCM INPUTS
  0x52: { nom: "PCM OI -OA03" }                   # PCM INPUTS
  0x53: { nom: "PCM OI -OA01" }                   # PCM INPUTS
  0x54: { nom: "PCM OI -OF01" }                   # PCM INPUTS
  0x55: { nom: "PCM OI -OF02" }                   # PCM INPUTS
  0x56: { nom: "PCM OI -OF03" }                   # PCM INPUTS
  0x57: { nom: "PCM OI -OF04" }                   # PCM INPUTS
  0x58: { nom: "PCM PDI" }                        # PCM INPUTS

  0x66: { nom: "PL FLEX-IUA 6" }                  # PAYLOAD RECONF INPUTS

  0x69: { nom: "PL FLEX-IUA 9" }                  # PAYLOAD RECONF INPUTS
  0x6a: { nom: "PF1-IUA 10" }                     # PAYLOAD RECONF INPUTS

  0x6c: { nom: "PF2-IUA 12" }                     # PAYLOAD RECONF INPUTS

  0x6f: { nom: "PL FLEX-IUA 15" }                 # PAYLOAD RECONF INPUTS

  0x7d: { nom: "PL FLEX-IUA 29" }                 # PAYLOAD RECONF INPUTS
  0x7e: { nom: "PL FLEX-IUA 30" }                 # PAYLOAD RECONF INPUTS
}